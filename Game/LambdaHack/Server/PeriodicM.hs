-- | Server operations performed periodically in the game loop
-- and related operations.
module Game.LambdaHack.Server.PeriodicM
  ( spawnMonster, addAnyActor
  , advanceTime, overheadActorTime, swapTime
  , leadLevelSwitch, udpateCalm
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Int (Int64)

import Game.LambdaHack.Atomic
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Frequency
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.ItemKind (ItemKind)
import qualified Game.LambdaHack.Content.ItemKind as IK
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Server.CommonM
import Game.LambdaHack.Server.ItemM
import Game.LambdaHack.Server.MonadServer
import Game.LambdaHack.Server.State

-- | Spawn, possibly, a monster according to the level's actor groups.
-- We assume heroes are never spawned.
spawnMonster :: MonadServerAtomic m => m ()
spawnMonster = do
  arenas <- getsServer sarenas
  -- Do this on only one of the arenas to prevent micromanagement,
  -- e.g., spreading leaders across levels to bump monster generation.
  arena <- rndToAction $ oneOf arenas
  totalDepth <- getsState stotalDepth
  Level{ldepth, lactorCoeff, lactorFreq} <- getLevel arena
  lvlSpawned <- getsServer $ fromMaybe 0 . EM.lookup arena . snumSpawned
  rc <- rndToAction
        $ monsterGenChance ldepth totalDepth lvlSpawned lactorCoeff
  when rc $ do
    modifyServer $ \ser ->
      ser {snumSpawned = EM.insert arena (lvlSpawned + 1) $ snumSpawned ser}
    localTime <- getsState $ getLocalTime arena
    maid <- addAnyActor lactorFreq arena localTime Nothing
    case maid of
      Nothing -> return ()
      Just aid -> do
        b <- getsState $ getActorBody aid
        mleader <- getsState $ _gleader . (EM.! bfid b) . sfactionD
        when (isNothing mleader) $ supplantLeader (bfid b) aid

addAnyActor :: MonadServerAtomic m
            => Freqs ItemKind -> LevelId -> Time -> Maybe Point
            -> m (Maybe ActorId)
addAnyActor actorFreq lid time mpos = do
  -- We bootstrap the actor by first creating the trunk of the actor's body
  -- that contains the constant properties.
  cops <- getsState scops
  lvl <- getLevel lid
  factionD <- getsState sfactionD
  lvlSpawned <- getsServer $ fromMaybe 0 . EM.lookup lid . snumSpawned
  m4 <- rollItem lvlSpawned lid actorFreq
  case m4 of
    Nothing -> return Nothing
    Just (itemKnownRaw, itemFullRaw, itemDisco, seed, _) -> do
      let ik = itemKind itemDisco
          freqNames = map fst $ IK.ifreq ik
          f fact = fgroups (gplayer fact)
          factGroups = concatMap f $ EM.elems factionD
          fidNames = case freqNames `intersect` factGroups of
            [] -> [nameOfHorrorFact]  -- fall back
            l -> l
      fidName <- rndToAction $ oneOf fidNames
      let g (_, fact) = fidName `elem` fgroups (gplayer fact)
          nameFids = map fst $ filter g $ EM.assocs factionD
          !_A = assert (not (null nameFids) `blame` (factionD, fidName)) ()
      fid <- rndToAction $ oneOf nameFids
      pers <- getsServer sperFid
      let allPers = ES.unions $ map (totalVisible . (EM.! lid))
                    $ EM.elems $ EM.delete fid pers  -- expensive :(
          -- Checking skill would be more accurate, but skills can be
          -- inside organs, equipment, tmp organs, created organs, etc.
          mobile = "mobile" `elem` freqNames
      pos <- case mpos of
        Just pos -> return pos
        Nothing -> do
          rollPos <- getsState $ rollSpawnPos cops allPers mobile lid lvl fid
          rndToAction rollPos
      registerActor itemKnownRaw itemFullRaw itemDisco seed
                    fid pos lid id time

rollSpawnPos :: Kind.COps -> ES.EnumSet Point
             -> Bool -> LevelId -> Level -> FactionId -> State
             -> Rnd Point
rollSpawnPos Kind.COps{coTileSpeedup} visible
             mobile lid lvl@Level{ltile, lxsize, lysize, lstair} fid s = do
  let -- Monsters try to harass enemies ASAP, instead of catching up from afar.
      inhabitants = warActorRegularList fid lid s
      nearInh df p = all (\b -> df $ chessDist (bpos b) p) inhabitants
      -- Monsters often appear from deeper levels or at least we try
      -- to suggest that.
      deeperStairs = (if fromEnum lid > 0 then fst else snd) lstair
      nearStairs df p = any (\pstair -> df $ chessDist pstair p) deeperStairs
      -- I actors near deep stairs, risk if close enemy spawns is higher.
      -- Also, spawns are common midway between actors and stairs.
      distantSo df p _ = nearInh df p && nearStairs df p
      middlePos = Point (lxsize `div` 2) (lysize `div` 2)
      distantMiddle d p _ = chessDist p middlePos < d
      condList | mobile =
        [ distantSo (<= 10)
        , distantSo (<= 15)
        , distantSo (<= 20)
        ]
               | otherwise =
        [ distantMiddle 5
        , distantMiddle 10
        , distantMiddle 20
        , distantMiddle 50
        , distantMiddle 100
        ]
  -- Not considering TK.OftenActor, because monsters emerge from hidden ducts,
  -- which are easier to hide in crampy corridors that lit halls.
  findPosTry2 (if mobile then 500 else 100) ltile
    ( \p t -> Tile.isWalkable coTileSpeedup t
              && not (Tile.isNoActor coTileSpeedup t)
              && null (posToAidsLvl p lvl))
    condList
    (\p t -> distantSo (> 4) p t  -- otherwise actors in dark rooms swarmed
             && not (p `ES.member` visible))  -- visibility and plausibility
    [ \p t -> distantSo (> 3) p t
              && not (p `ES.member` visible)
    , \p t -> distantSo (> 2) p t -- otherwise actors hit on entering level
              && not (p `ES.member` visible)
    , \p _ -> not (p `ES.member` visible)
    ]

-- | Advance the move time for the given actor
advanceTime :: MonadServerAtomic m => ActorId -> Int -> m ()
advanceTime aid percent = do
  b <- getsState $ getActorBody aid
  ar <- getsState $ getActorAspect aid
  let t = timeDeltaPercent (ticksPerMeter $ bspeed b ar) percent
  -- @t@ may be negative; that's OK.
  modifyServer $ \ser ->
    ser {sactorTime = ageActor (bfid b) (blid b) aid t $ sactorTime ser}

-- Add communication overhead time delta to all non-projectile, non-dying
-- faction's actors (except the leader). Effectively, this limits moves of
-- a faction to 10, regardless of the number of actors and their speeds.
-- To discourage micromanagement distributing actors among active arenas,
-- overhead applies to all actors in active arenas.
--
-- Leader is immune from overhead and so he is faster than other faction
-- members and of equal speed to leaders of other factions (of equal
-- base speed) regardless how numerous the faction is.
-- Thanks to this, there is no problem with leader of a numerous faction
-- having very long UI turns, introducing UI lag.
overheadActorTime :: MonadServerAtomic m => FactionId -> m ()
overheadActorTime fid = do
  actorTime <- getsServer $ (EM.! fid) . sactorTime
  s <- getState
  mleader <- getsState $ _gleader . (EM.! fid) . sfactionD
  arenas <- getsServer sarenas
  let f !aid !time =
        let body = getActorBody aid s
        in if isNothing (btrajectory body)
              && bhp body > 0
              && Just aid /= mleader  -- leader fast, for UI to be fast
           then timeShift time (Delta timeClip)
           else time
      g !acc !lid = EM.adjust (EM.mapWithKey f) lid acc
      actorTimeNew = foldl' g actorTime arenas
  modifyServer $ \ser ->
    ser {sactorTime = EM.insert fid actorTimeNew $ sactorTime ser}

-- | Swap the relative move times of two actors (e.g., when switching
-- a UI leader).
swapTime :: MonadServerAtomic m => ActorId -> ActorId -> m ()
swapTime source target = do
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  slvl <- getsState $ getLocalTime (blid sb)
  tlvl <- getsState $ getLocalTime (blid tb)
  btime_sb <- getsServer $ (EM.! source) . (EM.! blid sb) . (EM.! bfid sb) . sactorTime
  btime_tb <- getsServer $ (EM.! target) . (EM.! blid tb) . (EM.! bfid tb) . sactorTime
  let lvlDelta = slvl `timeDeltaToFrom` tlvl
      bDelta = btime_sb `timeDeltaToFrom` btime_tb
      sdelta = timeDeltaSubtract lvlDelta bDelta
      tdelta = timeDeltaReverse sdelta
  -- Equivalent, for the assert:
  let !_A = let sbodyDelta = btime_sb `timeDeltaToFrom` slvl
                tbodyDelta = btime_tb `timeDeltaToFrom` tlvl
                sgoal = slvl `timeShift` tbodyDelta
                tgoal = tlvl `timeShift` sbodyDelta
                sdelta' = sgoal `timeDeltaToFrom` btime_sb
                tdelta' = tgoal `timeDeltaToFrom` btime_tb
            in assert (sdelta == sdelta' && tdelta == tdelta'
                       `blame` ( slvl, tlvl, btime_sb, btime_tb
                               , sdelta, sdelta', tdelta, tdelta' )) ()
  when (sdelta /= Delta timeZero) $ modifyServer $ \ser ->
    ser {sactorTime = ageActor (bfid sb) (blid sb) source sdelta $ sactorTime ser}
  when (tdelta /= Delta timeZero) $ modifyServer $ \ser ->
    ser {sactorTime = ageActor (bfid tb) (blid tb) target tdelta $ sactorTime ser}

udpateCalm :: MonadServerAtomic m => ActorId -> Int64 -> m ()
udpateCalm target deltaCalm = do
  tb <- getsState $ getActorBody target
  ar <- getsState $ getActorAspect target
  let calmMax64 = xM $ aMaxCalm ar
  execUpdAtomic $ UpdRefillCalm target deltaCalm
  when (bcalm tb < calmMax64
        && bcalm tb + deltaCalm >= calmMax64) $
    return ()
    -- We don't dominate the actor here, because if so, players would
    -- disengage after one of their actors is dominated and wait for him
    -- to regenerate Calm. This is unnatural and boring. Better fight
    -- and hope he gets his Calm again to 0 and then defects back.

leadLevelSwitch :: MonadServerAtomic m => m ()
leadLevelSwitch = do
  let canSwitch fact = fst (autoDungeonLevel fact)
                       -- a hack to help AI, until AI client can switch levels
                       || case fleaderMode (gplayer fact) of
                            LeaderNull -> False
                            LeaderAI _ -> True
                            LeaderUI _ -> False
      flipFaction fact | not $ canSwitch fact = return ()
      flipFaction fact =
        case _gleader fact of
          Nothing -> return ()
          Just leader -> do
            body <- getsState $ getActorBody leader
            s <- getState
            let leaderStuck = waitedLastTurn body
                ourLvl (lid, lvl) =
                  ( lid
                  , EM.size (lfloor lvl)
                  , -- Drama levels skipped, hence @Regular@.
                    fidActorRegularIds (bfid body) lid s )
            ours <- getsState $ map ourLvl . EM.assocs . sdungeon
            -- Non-humans, being born in the dungeon, have a rough idea of
            -- the number of items left on the level and will focus
            -- on levels they started exploring and that have few items
            -- left. This is to to explore them completely, leave them
            -- once and for all and concentrate forces on another level.
            -- In addition, sole stranded actors tend to become leaders
            -- so that they can join the main force ASAP.
            let freqList = [ (k, (lid, a))
                           | (lid, itemN, a : rest) <- ours
                           , lid /= blid body || not leaderStuck
                           , let len = 1 + min 7 (length rest)
                                 divisor = 3 * itemN + len
                                 k = 1000000 `div` divisor ]
            unless (null freqList) $ do
              (lid, a) <- rndToAction $ frequency
                                      $ toFreq "leadLevel" freqList
              unless (lid == blid body) $  -- flip levels rather than actors
                supplantLeader (bfid body) a
  factionD <- getsState sfactionD
  mapM_ flipFaction $ EM.elems factionD
