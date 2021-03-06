{-# LANGUAGE TupleSections #-}
-- | Server operations common to many modules.
module Game.LambdaHack.Server.CommonM
  ( execFailure, revealItems, moveStores, deduceQuits, deduceKilled
  , electLeader, supplantLeader, updatePer, recomputeCachePer
  , addActor, registerActor, addActorIid, projectFail, discoverIfNoEffects
  , pickWeaponServer, currentSkillsServer, generalMoveItem
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM
import qualified Data.Text as T
import qualified Text.Show.Pretty as Show.Pretty

import           Game.LambdaHack.Atomic
import           Game.LambdaHack.Client
import qualified Game.LambdaHack.Common.Ability as Ability
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Item
import           Game.LambdaHack.Common.ItemStrongest
import qualified Game.LambdaHack.Common.Kind as Kind
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Perception
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.Random
import           Game.LambdaHack.Common.ReqFailure
import           Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Content.ItemKind (ItemKind)
import qualified Game.LambdaHack.Content.ItemKind as IK
import           Game.LambdaHack.Content.ModeKind
import           Game.LambdaHack.Content.RuleKind
import           Game.LambdaHack.Server.Fov
import           Game.LambdaHack.Server.ItemM
import           Game.LambdaHack.Server.ItemRev
import           Game.LambdaHack.Server.MonadServer
import           Game.LambdaHack.Server.ServerOptions
import           Game.LambdaHack.Server.State

execFailure :: MonadServerAtomic m
            => ActorId -> RequestTimed a -> ReqFailure -> m ()
execFailure aid req failureSer = do
  -- Clients should rarely do that (only in case of invisible actors)
  -- so we report it to the client, but do not crash
  -- (server should work OK with stupid clients, too).
  body <- getsState $ getActorBody aid
  let fid = bfid body
      msg = showReqFailure failureSer
      impossible = impossibleReqFailure failureSer
      debugShow :: Show a => a -> Text
      debugShow = T.pack . Show.Pretty.ppShow
      possiblyAlarm = if impossible
                      then debugPossiblyPrintAndExit
                      else debugPossiblyPrint
  possiblyAlarm $
    "execFailure:" <+> msg <> "\n"
    <> debugShow body <> "\n" <> debugShow req <> "\n" <> debugShow failureSer
  execSfxAtomic $ SfxMsgFid fid $ SfxUnexpected failureSer

revealItems :: MonadServerAtomic m => Maybe FactionId -> m ()
revealItems mfid = do
  itemToF <- getsState $ itemToFull
  let discover aid store iid k =
        let itemFull = itemToF iid k
            c = CActor aid store
        in case itemDisco itemFull of
          Just ItemDisco{itemKindId} -> do
            seed <- getsServer $ (EM.! iid) . sitemSeedD
            execUpdAtomic $ UpdDiscover c iid itemKindId seed
          _ -> error $ "" `showFailure` (mfid, c, iid, itemFull)
      f aid = do
        b <- getsState $ getActorBody aid
        let ourSide = maybe True (== bfid b) mfid
        -- Don't ID projectiles, because client may not see them.
        when (not (bproj b) && ourSide) $
          -- CSha is IDed for each actor of each faction, which is OK,
          -- even though it may introduce a slight lag.
          -- AI clients being sent this is a bigger waste anyway.
          join $ getsState $ mapActorItems_ (discover aid) b
  as <- getsState $ EM.keys . sactorD
  mapM_ f as

moveStores :: MonadServerAtomic m
           => Bool -> ActorId -> CStore -> CStore -> m ()
moveStores verbose aid fromStore toStore = do
  b <- getsState $ getActorBody aid
  let g iid (k, _) = do
        move <- generalMoveItem verbose iid k (CActor aid fromStore)
                                              (CActor aid toStore)
        mapM_ execUpdAtomic move
  mapActorCStore_ fromStore g b

-- | Generate the atomic updates that jointly perform a given item move.
generalMoveItem :: MonadStateRead m
                => Bool -> ItemId -> Int -> Container -> Container
                -> m [UpdAtomic]
generalMoveItem verbose iid k c1 c2 =
  case (c1, c2) of
    (CActor aid1 cstore1, CActor aid2 cstore2) | aid1 == aid2
                                                 && cstore1 /= CSha
                                                 && cstore2 /= CSha ->
      return [UpdMoveItem iid k aid1 cstore1 cstore2]
    _ -> containerMoveItem verbose iid k c1 c2

containerMoveItem :: MonadStateRead m
                  => Bool -> ItemId -> Int -> Container -> Container
                  -> m [UpdAtomic]
containerMoveItem verbose iid k c1 c2 = do
  bag <- getsState $ getContainerBag c1
  case iid `EM.lookup` bag of
    Nothing -> error $ "" `showFailure` (iid, k, c1, c2)
    Just (_, it) -> do
      item <- getsState $ getItemBody iid
      return [ UpdLoseItem verbose iid item (k, take k it) c1
             , UpdSpotItem verbose iid item (k, take k it) c2 ]

quitF :: MonadServerAtomic m =>  Status -> FactionId -> m ()
quitF status fid = do
  fact <- getsState $ (EM.! fid) . sfactionD
  let oldSt = gquit fact
  case stOutcome <$> oldSt of
    Just Killed -> return ()    -- Do not overwrite in case
    Just Defeated -> return ()  -- many things happen in 1 turn.
    Just Conquer -> return ()
    Just Escape -> return ()
    _ -> do
      when (fhasUI $ gplayer fact) $ do
        keepAutomated <- getsServer $ skeepAutomated . soptions
        when (isAIFact fact
              && fleaderMode (gplayer fact) /= LeaderNull
              && not keepAutomated) $
          execUpdAtomic $ UpdAutoFaction fid False
        revealItems (Just fid)
        registerScore status fid
      execUpdAtomic $ UpdQuitFaction fid oldSt $ Just status
      modifyServer $ \ser -> ser {squit = True}  -- check game over ASAP

-- Send any UpdQuitFaction actions that can be deduced from factions'
-- current state.
deduceQuits :: MonadServerAtomic m => FactionId -> Status -> m ()
deduceQuits fid0 status@Status{stOutcome}
  | stOutcome `elem` [Defeated, Camping, Restart, Conquer] =
    error $ "no quitting to deduce" `showFailure` (fid0, status)
deduceQuits fid0 status = do
  fact0 <- getsState $ (EM.! fid0) . sfactionD
  let factHasUI = fhasUI . gplayer
      quitFaction (stOutcome, (fid, _)) = quitF status{stOutcome} fid
      mapQuitF outfids = do
        let (withUI, withoutUI) =
              partition (factHasUI . snd . snd)
                        ((stOutcome status, (fid0, fact0)) : outfids)
        mapM_ quitFaction (withoutUI ++ withUI)
      inGameOutcome (fid, fact) = do
        let mout | fid == fid0 = Just $ stOutcome status
                 | otherwise = stOutcome <$> gquit fact
        case mout of
          Just Killed -> False
          Just Defeated -> False
          Just Restart -> False  -- effectively, commits suicide
          _ -> True
  factionD <- getsState sfactionD
  let assocsInGame = filter inGameOutcome $ EM.assocs factionD
      assocsKeepArena = filter (keepArenaFact . snd) assocsInGame
      assocsUI = filter (factHasUI . snd) assocsInGame
      nonHorrorAIG = filter (not . isHorrorFact . snd) assocsInGame
      worldPeace =
        all (\(fid1, _) -> all (\(_, fact2) -> not $ isAtWar fact2 fid1)
                           nonHorrorAIG)
        nonHorrorAIG
      othersInGame = filter ((/= fid0) . fst) assocsInGame
  if | null assocsUI ->
       -- Only non-UI players left in the game and they all win.
       mapQuitF $ zip (repeat Conquer) othersInGame
     | null assocsKeepArena ->
       -- Only leaderless and spawners remain (the latter may sometimes
       -- have no leader, just as the former), so they win,
       -- or we could get stuck in a state with no active arena
       -- and so no spawns.
       mapQuitF $ zip (repeat Conquer) othersInGame
     | worldPeace ->
       -- Nobody is at war any more, so all win (e.g., horrors, but never mind).
       mapQuitF $ zip (repeat Conquer) othersInGame
     | stOutcome status == Escape -> do
       -- Otherwise, in a game with many warring teams alive,
       -- only complete Victory matters, until enough of them die.
       let (victors, losers) = partition (flip isAllied fid0 . snd) othersInGame
       mapQuitF $ zip (repeat Escape) victors ++ zip (repeat Defeated) losers
     | otherwise -> quitF status fid0

-- | Tell whether a faction that we know is still in game, keeps arena.
-- Keeping arena means, if the faction is still in game,
-- it always has a leader in the dungeon somewhere.
-- So, leaderless factions and spawner factions do not keep an arena,
-- even though the latter usually has a leader for most of the game.
keepArenaFact :: Faction -> Bool
keepArenaFact fact = fleaderMode (gplayer fact) /= LeaderNull
                     && fneverEmpty (gplayer fact)

-- We assume the actor in the second argument has HP <= 0 or is going to be
-- dominated right now. Even if the actor is to be dominated,
-- @bfid@ of the actor body is still the old faction.
deduceKilled :: MonadServerAtomic m => ActorId -> m ()
deduceKilled aid = do
  Kind.COps{corule} <- getsState scops
  body <- getsState $ getActorBody aid
  let firstDeathEnds = rfirstDeathEnds $ Kind.stdRuleset corule
  fact <- getsState $ (EM.! bfid body) . sfactionD
  when (fneverEmpty $ gplayer fact) $ do
    actorsAlive <- anyActorsAlive (bfid body) aid
    when (not actorsAlive || firstDeathEnds) $
      deduceQuits (bfid body) $ Status Killed (fromEnum $ blid body) Nothing

anyActorsAlive :: MonadServer m => FactionId -> ActorId -> m Bool
anyActorsAlive fid aid = do
  as <- getsState $ fidActorNotProjAssocs fid
  return $! map fst as /= [aid]

electLeader :: MonadServerAtomic m => FactionId -> LevelId -> ActorId -> m ()
electLeader fid lid aidDead = do
  mleader <- getsState $ _gleader . (EM.! fid) . sfactionD
  when (mleader == Just aidDead) $ do
    actorD <- getsState sactorD
    let ours (_, b) = bfid b == fid && not (bproj b)
        party = filter ours $ EM.assocs actorD
    onLevel <- getsState $ fidActorRegularIds fid lid
    let mleaderNew = case filter (/= aidDead) $ onLevel ++ map fst party of
          [] -> Nothing
          aid : _ -> Just aid
    execUpdAtomic $ UpdLeadFaction fid mleader mleaderNew

supplantLeader :: MonadServerAtomic m => FactionId -> ActorId -> m ()
supplantLeader fid aid = do
  fact <- getsState $ (EM.! fid) . sfactionD
  unless (fleaderMode (gplayer fact) == LeaderNull) $ do
    -- First update and send Perception so that the new leader
    -- may report his environment.
    b <- getsState $ getActorBody aid
    valid <- getsServer $ (EM.! blid b) . (EM.! fid) . sperValidFid
    unless valid $ updatePer fid (blid b)
    execUpdAtomic $ UpdLeadFaction fid (_gleader fact) (Just aid)

updatePer :: MonadServerAtomic m => FactionId -> LevelId -> m ()
{-# INLINE updatePer #-}
updatePer fid lid = do
  modifyServer $ \ser ->
    ser {sperValidFid = EM.adjust (EM.insert lid True) fid $ sperValidFid ser}
  sperFidOld <- getsServer sperFid
  let perOld = sperFidOld EM.! fid EM.! lid
  knowEvents <- getsServer $ sknowEvents . soptions
  -- Performed in the State after action, e.g., with a new actor.
  perNew <- recomputeCachePer fid lid
  let inPer = diffPer perNew perOld
      outPer = diffPer perOld perNew
  unless (nullPer outPer && nullPer inPer) $
    unless knowEvents $  -- inconsistencies would quickly manifest
      execSendPer fid lid outPer inPer perNew

recomputeCachePer :: MonadServer m => FactionId -> LevelId -> m Perception
recomputeCachePer fid lid = do
  total <- getCacheTotal fid lid
  fovLucid <- getCacheLucid lid
  let perNew = perceptionFromPTotal fovLucid total
      fper = EM.adjust (EM.insert lid perNew) fid
  modifyServer $ \ser -> ser {sperFid = fper $ sperFid ser}
  return perNew

-- The missile item is removed from the store only if the projection
-- went into effect (no failure occured).
projectFail :: MonadServerAtomic m
            => ActorId    -- ^ actor projecting the item (is on current lvl)
            -> Point      -- ^ target position of the projectile
            -> Int        -- ^ digital line parameter
            -> ItemId     -- ^ the item to be projected
            -> CStore     -- ^ whether the items comes from floor or inventory
            -> Bool       -- ^ whether the item is a blast
            -> m (Maybe ReqFailure)
projectFail source tpxy eps iid cstore isBlast = do
  Kind.COps{coTileSpeedup} <- getsState scops
  sb <- getsState $ getActorBody source
  let lid = blid sb
      spos = bpos sb
  lvl@Level{lxsize, lysize} <- getLevel lid
  case bla lxsize lysize eps spos tpxy of
    Nothing -> return $ Just ProjectAimOnself
    Just [] -> error $ "projecting from the edge of level"
                       `showFailure` (spos, tpxy)
    Just (pos : restUnlimited) -> do
      bag <- getsState $ getBodyStoreBag sb cstore
      case EM.lookup iid bag of
        Nothing ->  return $ Just ProjectOutOfReach
        Just kit -> do
          itemToF <- getsState $ itemToFull
          actorSk <- currentSkillsServer source
          ar <- getsState $ getActorAspect source
          let skill = EM.findWithDefault 0 Ability.AbProject actorSk
              itemFull@ItemFull{itemBase} = itemToF iid kit
              forced = isBlast || bproj sb
              calmE = calmEnough sb ar
              legal = permittedProject forced skill calmE "" itemFull
          case legal of
            Left reqFail -> return $ Just reqFail
            Right _ -> do
              let lobable = IK.Lobable `elem` jfeature itemBase
                  rest = if lobable
                         then take (chessDist spos tpxy - 1) restUnlimited
                         else restUnlimited
                  t = lvl `at` pos
              if not $ Tile.isWalkable coTileSpeedup t
                then return $ Just ProjectBlockTerrain
                else do
                  lab <- getsState $ posToAssocs pos lid
                  if not $ all (bproj . snd) lab
                    then if isBlast && bproj sb then do
                           -- Hit the blocking actor.
                           projectBla source spos (pos:rest) iid cstore isBlast
                           return Nothing
                         else return $ Just ProjectBlockActor
                    else do
                      if isBlast && bproj sb && eps `mod` 2 == 0 then
                        -- Make the explosion a bit less regular.
                        projectBla source spos (pos:rest) iid cstore isBlast
                      else
                        projectBla source pos rest iid cstore isBlast
                      return Nothing

projectBla :: MonadServerAtomic m
           => ActorId    -- ^ actor projecting the item (is on current lvl)
           -> Point      -- ^ starting point of the projectile
           -> [Point]    -- ^ rest of the trajectory of the projectile
           -> ItemId     -- ^ the item to be projected
           -> CStore     -- ^ whether the items comes from floor or inventory
           -> Bool       -- ^ whether the item is a blast
           -> m ()
projectBla source pos rest iid cstore isBlast = do
  sb <- getsState $ getActorBody source
  item <- getsState $ getItemBody iid
  let lid = blid sb
  localTime <- getsState $ getLocalTime lid
  unless isBlast $ execSfxAtomic $ SfxProject source iid cstore
  bag <- getsState $ getBodyStoreBag sb cstore
  case iid `EM.lookup` bag of
    Nothing -> error $ "" `showFailure` (source, pos, rest, iid, cstore)
    Just kit@(_, it) -> do
      let btime = absoluteTimeAdd timeEpsilon localTime
      addProjectile pos rest iid kit lid (bfid sb) btime isBlast
      let c = CActor source cstore
      execUpdAtomic $ UpdLoseItem False iid item (1, take 1 it) c

-- | Create a projectile actor containing the given missile.
--
-- Projectile has no organs except for the trunk.
addProjectile :: MonadServerAtomic m
              => Point -> [Point] -> ItemId -> ItemQuant -> LevelId
              -> FactionId -> Time -> Bool
              -> m ()
addProjectile bpos rest iid (_, it) blid bfid btime _isBlast = do
  itemToF <- getsState $ itemToFull
  let itemFull@ItemFull{itemBase} = itemToF iid (1, take 1 it)
      (trajectory, (speed, _)) = itemTrajectory itemBase (bpos : rest)
      tweakBody b = b { bhp = oneM
                      , bproj = True
                      , btrajectory = Just (trajectory, speed)
                      , beqp = EM.singleton iid (1, take 1 it)
                      , borgan = EM.empty }  -- don't confer bonuses from trunk
  void $ addActorIid iid itemFull True bfid bpos blid tweakBody btime

addActor :: MonadServerAtomic m
         => GroupName ItemKind -> FactionId -> Point -> LevelId
         -> (Actor -> Actor) -> Time
         -> m (Maybe ActorId)
addActor actorGroup bfid pos lid tweakBody time = do
  -- We bootstrap the actor by first creating the trunk of the actor's body
  -- that contains the constant properties.
  let trunkFreq = [(actorGroup, 1)]
  m5 <- rollItem 0 lid trunkFreq
  case m5 of
    Nothing -> return Nothing
    Just (itemKnownRaw, itemFullRaw, itemDisco, seed, _) ->
      registerActor itemKnownRaw itemFullRaw itemDisco seed
                    bfid pos lid tweakBody time

registerActor :: MonadServerAtomic m
              => ItemKnown -> ItemFull -> ItemDisco -> ItemSeed
              -> FactionId -> Point -> LevelId -> (Actor -> Actor) -> Time
              -> m (Maybe ActorId)
registerActor (kindIx, ar, damage, _) itemFullRaw itemDisco seed
              bfid pos lid tweakBody time = do
  let container = CTrunk bfid lid pos
  -- Other code adds to @sdiscoBenefit@ only @iid@ and not any other items
  -- that share the same @jkindIx@, so this is broken if such items
  -- are not fully IDed from the start, so check that before risking a copy
  -- of the same item, but with different @jfid@.
      jfid = if IK.Identified `elem` IK.ifeature (itemKind itemDisco)
             then Just bfid
             else Nothing
      itemKnown = (kindIx, ar, damage, jfid)
      itemFull = itemFullRaw {itemBase = (itemBase itemFullRaw) {jfid}}
  trunkId <- registerItem itemFull itemKnown seed container False
  addActorIid trunkId itemFull False bfid pos lid tweakBody time

addActorIid :: MonadServerAtomic m
            => ItemId -> ItemFull -> Bool -> FactionId -> Point -> LevelId
            -> (Actor -> Actor) -> Time
            -> m (Maybe ActorId)
addActorIid trunkId trunkFull@ItemFull{..} bproj
            bfid pos lid tweakBody time = do
  let trunkKind = case itemDisco of
        Just ItemDisco{itemKind} -> itemKind
        Nothing -> error $ "" `showFailure` trunkFull
      aspects = fromJust $ itemAspect $ fromJust itemDisco
  -- Initial HP and Calm is based only on trunk and ignores organs.
      hp = xM (max 2 $ aMaxHP aspects) `div` 2
      -- Hard to auto-id items that refill Calm, but reduced sight at game
      -- start is more confusing and frustrating:
      calm = xM (max 0 $ aMaxCalm aspects)
  -- Create actor.
  factionD <- getsState sfactionD
  let fact = factionD EM.! bfid
  curChalSer <- getsServer $ scurChalSer . soptions
  nU <- nUI
  -- If difficulty is below standard, HP is added to the UI factions,
  -- otherwise HP is added to their enemies.
  -- If no UI factions, their role is taken by the escapees (for testing).
  let diffBonusCoeff = difficultyCoeff $ cdiff curChalSer
      hasUIorEscapes Faction{gplayer} =
        fhasUI gplayer || nU == 0 && fcanEscape gplayer
      boostFact = not bproj
                  && if diffBonusCoeff > 0
                     then hasUIorEscapes fact
                          || any hasUIorEscapes
                                 (filter (`isAllied` bfid) $ EM.elems factionD)
                     else any hasUIorEscapes
                              (filter (`isAtWar` bfid) $ EM.elems factionD)
      diffHP | boostFact = if cdiff curChalSer `elem` [1, difficultyBound]
                           then xM 999 - hp -- as much as UI can stand
                           else hp * 2 ^ abs diffBonusCoeff
             | otherwise = hp
      bonusHP = fromEnum $ (diffHP - hp) `divUp` oneM
      healthOrgans = [(Just bonusHP, ("bonus HP", COrgan)) | bonusHP /= 0]
      b = actorTemplate trunkId diffHP calm pos lid bfid
      -- Insert the trunk as the actor's organ.
      withTrunk = b { borgan = EM.singleton trunkId (itemK, itemTimer)
                    , bweapon = if isMelee itemBase then 1 else 0 }
  aid <- getsServer sacounter
  modifyServer $ \ser -> ser {sacounter = succ aid}
  execUpdAtomic $ UpdCreateActor aid (tweakBody withTrunk) [(trunkId, itemBase)]
  modifyServer $ \ser ->
    ser {sactorTime = updateActorTime bfid lid aid time $ sactorTime ser}
  -- Create, register and insert all initial actor items, including
  -- the bonus health organs from difficulty setting.
  forM_ (healthOrgans ++ map (Nothing,) (IK.ikit trunkKind))
        $ \(mk, (ikText, cstore)) -> do
    let container = CActor aid cstore
        itemFreq = [(ikText, 1)]
    mIidEtc <- rollAndRegisterItem lid itemFreq container False mk
    case mIidEtc of
      Nothing -> error $ "" `showFailure` (lid, itemFreq, container, mk)
      Just (iid, (itemFull, _)) -> discoverIfNoEffects container iid itemFull
  return $ Just aid

discoverIfNoEffects :: MonadServerAtomic m
                    => Container -> ItemId -> ItemFull -> m ()
discoverIfNoEffects c iid itemFull = case itemFull of
  ItemFull{itemDisco=Just ItemDisco{itemKind=IK.ItemKind{IK.ieffects}}}
    | any IK.forIdEffect ieffects -> return ()  -- discover by use
  ItemFull{itemDisco=Just ItemDisco{itemKindId}} -> do
    seed <- getsServer $ (EM.! iid) . sitemSeedD
    execUpdAtomic $ UpdDiscover c iid itemKindId seed
  _ -> error "server doesn't fully know item"

pickWeaponServer :: MonadServer m => ActorId -> m (Maybe (ItemId, CStore))
pickWeaponServer source = do
  eqpAssocs <- getsState $ fullAssocs source [CEqp]
  bodyAssocs <- getsState $ fullAssocs source [COrgan]
  actorSk <- currentSkillsServer source
  sb <- getsState $ getActorBody source
  let allAssocsRaw = eqpAssocs ++ bodyAssocs
      forced = bproj sb
      allAssocs | forced = allAssocsRaw  -- for projectiles, anything is weapon
                | otherwise = filter (isMelee . itemBase . snd) allAssocsRaw
  -- Server ignores item effects or it would leak item discovery info.
  -- In particular, it even uses weapons that would heal opponent,
  -- and not only in case of projectiles.
  strongest <- pickWeaponM Nothing allAssocs actorSk source
  case strongest of
    [] -> return Nothing
    iis@((maxS, _) : _) -> do
      let maxIis = map snd $ takeWhile ((== maxS) . fst) iis
      (iid, _) <- rndToAction $ oneOf maxIis
      let cstore = if isJust (lookup iid bodyAssocs) then COrgan else CEqp
      return $ Just (iid, cstore)

-- @MonadStateRead@ would be enough, but the logic is sound only on server.
currentSkillsServer :: MonadServer m => ActorId -> m Ability.Skills
currentSkillsServer aid  = do
  body <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid body) . sfactionD
  let mleader = _gleader fact
  getsState $ actorSkills mleader aid

getCacheLucid :: MonadServer m => LevelId -> m FovLucid
getCacheLucid lid = do
  fovClearLid <- getsServer sfovClearLid
  fovLitLid <- getsServer sfovLitLid
  fovLucidLid <- getsServer sfovLucidLid
  let getNewLucid = getsState $ \s ->
        lucidFromLevel fovClearLid fovLitLid s lid (sdungeon s EM.! lid)
  case EM.lookup lid fovLucidLid of
    Just (FovValid fovLucid) -> return fovLucid
    _ -> do
      newLucid <- getNewLucid
      modifyServer $ \ser ->
        ser {sfovLucidLid = EM.insert lid (FovValid newLucid)
                            $ sfovLucidLid ser}
      return newLucid

getCacheTotal :: MonadServer m => FactionId -> LevelId -> m CacheBeforeLucid
getCacheTotal fid lid = do
  sperCacheFidOld <- getsServer sperCacheFid
  let perCacheOld = sperCacheFidOld EM.! fid EM.! lid
  case ptotal perCacheOld of
    FovValid total -> return total
    FovInvalid -> do
      actorAspect <- getsState sactorAspect
      fovClearLid <- getsServer sfovClearLid
      getActorB <- getsState $ flip getActorBody
      let perActorNew =
            perActorFromLevel (perActor perCacheOld) getActorB
                              actorAspect (fovClearLid EM.! lid)
          -- We don't check if any actor changed, because almost surely one is.
          -- Exception: when an actor is destroyed, but then union differs, too.
          total = totalFromPerActor perActorNew
          perCache = PerceptionCache { ptotal = FovValid total
                                     , perActor = perActorNew }
          fperCache = EM.adjust (EM.insert lid perCache) fid
      modifyServer $ \ser -> ser {sperCacheFid = fperCache $ sperCacheFid ser}
      return total
