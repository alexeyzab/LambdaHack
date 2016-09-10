{-# LANGUAGE TupleSections #-}
-- | Display game data on the screen using one of the available frontends
-- (determined at compile time with cabal flags).
module Game.LambdaHack.Client.UI.DrawM
  ( targetDescLeader, drawBaseFrame
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , targetDesc, targetDescXhair
  , drawArenaStatus, drawLeaderStatus, drawLeaderDamage, drawSelected
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Ord
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Client.Bfs
import Game.LambdaHack.Client.BfsM
import Game.LambdaHack.Client.CommonM
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.Frame
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Client.UI.Overlay
import Game.LambdaHack.Client.UI.SessionUI
import Game.LambdaHack.Common.Actor as Actor
import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Color as Color
import qualified Game.LambdaHack.Common.Dice as Dice
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemDescription
import Game.LambdaHack.Common.ItemStrongest
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Common.Vector
import qualified Game.LambdaHack.Content.ItemKind as IK
import Game.LambdaHack.Content.TileKind (isUknownSpace)
import qualified Game.LambdaHack.Content.TileKind as TK

targetDesc :: MonadClientUI m => Maybe Target -> m (Text, Maybe Text)
targetDesc target = do
  arena <- getArenaUI
  lidV <- viewedLevelUI
  mleader <- getsClient _sleader
  case target of
    Just (TEnemy aid _) -> do
      side <- getsClient sside
      b <- getsState $ getActorBody aid
      actorAspect <- getsClient sactorAspect
      let ar = case EM.lookup aid actorAspect of
            Just aspectRecord -> aspectRecord
            Nothing -> assert `failure` aid
          percentage = 100 * bhp b `div` xM (max 5 $ aMaxHP ar)
          stars | percentage < 20  = "[____]"
                | percentage < 40  = "[*___]"
                | percentage < 60  = "[**__]"
                | percentage < 80  = "[***_]"
                | otherwise        = "[****]"
          hpIndicator = if bfid b == side then Nothing else Just stars
      return (bname b, hpIndicator)
    Just (TEnemyPos _ lid p _) -> do
      let hotText = if lid == lidV && arena == lidV
                    then "hot spot" <+> tshow p
                    else "a hot spot on level" <+> tshow (abs $ fromEnum lid)
      return (hotText, Nothing)
    Just (TPoint lid p) -> do
      pointedText <-
        if lid == lidV && arena == lidV
        then do
          bag <- getsState $ getCBag (CFloor lid p)
          case EM.assocs bag of
            [] -> return $! "exact spot" <+> tshow p
            [(iid, kit@(k, _))] -> do
              localTime <- getsState $ getLocalTime lid
              itemToF <- itemToFullClient
              let (_, name, stats) = partItem CGround localTime (itemToF iid kit)
              return $! makePhrase $ if k == 1
                                     then [name, stats]  -- "a sword" too wordy
                                     else [MU.CarWs k name, stats]
            _ -> return $! "many items at" <+> tshow p
        else return $! "an exact spot on level" <+> tshow (abs $ fromEnum lid)
      return (pointedText, Nothing)
    Just TVector{} ->
      case mleader of
        Nothing -> return ("a relative shift", Nothing)
        Just aid -> do
          tgtPos <- aidTgtToPos aid lidV target
          let invalidMsg = "an invalid relative shift"
              validMsg p = "shift to" <+> tshow p
          return (maybe invalidMsg validMsg tgtPos, Nothing)
    Nothing -> return ("crosshair location", Nothing)

targetDescLeader :: MonadClientUI m => ActorId -> m (Text, Maybe Text)
targetDescLeader leader = do
  tgt <- getsClient $ getTarget leader
  targetDesc tgt

targetDescXhair :: MonadClientUI m => m (Text, Maybe Text)
targetDescXhair = do
  sxhair <- getsClient sxhair
  targetDesc $ Just sxhair

-- TODO: split up and generally rewrite.
-- | Draw the whole screen: level map and status area.
-- Pass at most a single page if overlay of text unchanged
-- to the frontends to display separately or overlay over map,
-- depending on the frontend.
drawBaseFrame :: MonadClientUI m => ColorMode -> LevelId -> m SingleFrame
drawBaseFrame dm drawnLevelId = do
  cops <- getsState scops
  SessionUI{sselected, saimMode, smarkVision, smarkSmell, swaitTimes, sitemSel}
    <- getSession
  mleader <- getsClient _sleader
  tgtPos <- leaderTgtToPos
  xhairPos <- xhairToPos
  let anyPos = fromMaybe originPoint xhairPos
        -- if xhair invalid, e.g., on a wrong level; @draw@ ignores it later on
      bfsAndpathFromLeader leader = Just <$> getCacheBfsAndPath leader anyPos
      pathFromLeader leader = (Just . (,NoPath)) <$> getCacheBfs leader
  bfsmpath <- if isJust saimMode
              then maybe (return Nothing) bfsAndpathFromLeader mleader
              else maybe (return Nothing) pathFromLeader mleader
  (tgtDesc, mtargetHP) <-
    maybe (return ("------", Nothing)) targetDescLeader mleader
  (xhairDesc, mxhairHP) <- targetDescXhair
  s <- getState
  StateClient{seps, sexplored, smarkSuspect} <- getClient
  per <- getPerFid drawnLevelId
  let Kind.COps{cotile=Kind.Ops{okind=tokind}, coTileSpeedup} = cops
      (lvl@Level{lxsize, lysize, lsmell, ltime}) = sdungeon s EM.! drawnLevelId
      (bline, mblid, mbpos) = case (xhairPos, mleader) of
        (Just xhair, Just leader) ->
          let Actor{bpos, blid} = getActorBody leader s
          in if blid /= drawnLevelId
             then ( [], Just blid, Just bpos )
             else ( maybe [] (delete xhair)
                    $ bla lxsize lysize seps bpos xhair
                  , Just blid
                  , Just bpos )
        _ -> ([], Nothing, Nothing)
      deleteXhair = maybe id (\xhair -> delete xhair) xhairPos
      mpath = maybe Nothing
                    (\(_, mp) -> if null bline
                                 then Nothing
                                 else case mp of
                                   NoPath -> Nothing
                                   AndPath {pathList} ->
                                     Just $ deleteXhair pathList)
                    bfsmpath
      actorsHere = actorAssocs (const True) drawnLevelId s
      xhairHere = find (\(_, m) -> xhairPos == Just (Actor.bpos m))
                        actorsHere
      shiftedBTrajectory = case xhairHere of
        Just (_, Actor{btrajectory = Just p, bpos = prPos}) ->
          deleteXhair $ trajectoryToPath prPos (fst p)
        _ -> []
      dis pos0 =
        let tile = lvl `at` pos0
            tk = tokind tile
            floorBag = EM.findWithDefault EM.empty pos0 $ lfloor lvl
-- TODO: too costly right now
-- unless I add reverse itemSlots, to avoid latency in menus;
-- wait and see if there's latency in the browser due to that
--            (itemSlots, _) = sslots cli
--            bagItemSlots = EM.filter (`EM.member` floorBag) itemSlots
--            floorIids = EM.elems bagItemSlots  -- first slot will be shown
            floorIids = reverse $ EM.keys floorBag  -- sorted by key order
            sml = EM.findWithDefault timeZero pos0 lsmell
            smlt = sml `timeDeltaToFrom` ltime
            viewActor Actor{bsymbol, bcolor, bhp, bproj} =
              (symbol, Color.Attr{fg=bcolor, bg=Color.defBG})
             where
              symbol | bhp <= 0 && not bproj = '%'
                     | otherwise = bsymbol
            rainbow p = Color.defAttr {Color.fg =
                                         toEnum $ fromEnum p `rem` 14 + 1}
            -- smarkSuspect is an optional overlay, so let's overlay it
            -- over both visible and invisible tiles.
            vcolor
              | smarkSuspect && Tile.isSuspect coTileSpeedup tile = Color.BrCyan
              | vis = TK.tcolor tk
              | otherwise = TK.tcolor2 tk
            fgOnPathOrLine = case (vis, Tile.isWalkable coTileSpeedup tile) of
              _ | isUknownSpace tile -> Color.BrBlack
              _ | Tile.isSuspect coTileSpeedup tile -> Color.BrCyan
              (True, True)   -> Color.BrGreen
              (True, False)  -> Color.BrRed
              (False, True)  -> Color.Green
              (False, False) -> Color.Red
            atttrOnPathOrLine = Color.defAttr {Color.fg = fgOnPathOrLine}
            maidBody = find (\(_, m) -> pos0 == Actor.bpos m) actorsHere
            (char, attr0) =
              case snd <$> maidBody of
                _ | isJust saimMode
                    && (elem pos0 bline || elem pos0 shiftedBTrajectory) ->
                  ('*', atttrOnPathOrLine)  -- line takes precedence over path
                _ | isJust saimMode
                    && maybe False (elem pos0) mpath ->
                  (';', atttrOnPathOrLine)
                Just m -> viewActor m
                _ | smarkSmell && sml > ltime ->
                  (timeDeltaToDigit smellTimeout smlt, rainbow pos0)
                  | otherwise ->
                  case floorIids of
                    [] -> (TK.tsymbol tk, Color.defAttr {Color.fg=vcolor})
                    iid : _ -> viewItem $ getItemBody iid s
            vis = ES.member pos0 $ totalVisible per
            maid = fst <$> maidBody
            a = case dm of
                  ColorBW -> Color.defAttr
                  ColorFull -> if | mleader == maid && isJust maid ->
                                    attr0 {Color.bg = Color.BrRed}
                                  | Just pos0 == xhairPos ->
                                    attr0 {Color.bg = Color.BrYellow}
                                  | maybe False (`ES.member` sselected) maid ->
                                    attr0 {Color.bg = Color.BrBlue}
                                  | smarkVision && vis ->
                                    attr0 {Color.bg = Color.Blue}
                                  | otherwise ->
                                    attr0
        in Color.AttrChar a char
      widthX = 80
      widthTgt = 39
      widthStats = widthX - widthTgt
      arenaStatus = drawArenaStatus (ES.member drawnLevelId sexplored) lvl
                                    widthStats
      displayPathText mp mt =
        let (plen, llen) = case (mp, bfsmpath, mbpos) of
              (Just target, Just (bfs, _), Just bpos)
                | mblid == Just drawnLevelId ->
                  (fromMaybe 0 (accessBfs bfs target), chessDist bpos target)
              _ -> (0, 0)
            pText | plen == 0 = ""
                  | otherwise = "p" <> tshow plen
            lText | llen == 0 = ""
                  | otherwise = "l" <> tshow llen
            text = fromMaybe (pText <+> lText) mt
        in if T.null text then "" else " " <> text
      -- The indicators must fit, they are the actual information.
      pathCsr = displayPathText xhairPos mxhairHP
      trimTgtDesc n t = assert (not (T.null t) && n > 2) $
        if T.length t <= n then t
        else let ellipsis = "..."
                 fitsPlusOne = T.take (n - T.length ellipsis + 1) t
                 fits = if T.last fitsPlusOne == ' '
                        then T.init fitsPlusOne
                        else let lw = T.words fitsPlusOne
                             in T.unwords $ init lw
             in fits <> ellipsis
      xhairText =
        let n = widthTgt - T.length pathCsr - 8
        in (if isJust saimMode then "x-hair>" else "X-hair:")
           <+> trimTgtDesc n xhairDesc
      xhairGap = emptyAttrLine (widthTgt - T.length pathCsr
                                         - T.length xhairText)
      xhairStatus = textToAL xhairText ++ xhairGap ++ textToAL pathCsr
      leaderStatusWidth = 22
  leaderStatus <- drawLeaderStatus swaitTimes
  (selectedStatusWidth, selectedStatus)
    <- drawSelected drawnLevelId (widthStats - leaderStatusWidth) sselected
  damageStatus <- drawLeaderDamage (widthStats - leaderStatusWidth
                                               - selectedStatusWidth)
  let tgtOrItem n = do
        let tgtBlurb = "Target:" <+> trimTgtDesc n tgtDesc
        case (sitemSel, mleader) of
          (Just (fromCStore, iid), Just leader) -> do  -- TODO: factor out
            bag <- getsState $ getActorBag leader fromCStore
            case iid `EM.lookup` bag of
              Nothing -> return $! tgtBlurb
              Just kit@(k, _) -> do
                b <- getsState $ getActorBody leader
                localTime <- getsState $ getLocalTime (blid b)
                itemToF <- itemToFullClient
                let (_, name, stats) =
                      partItem fromCStore localTime (itemToF iid kit)
                    t = makePhrase
                        $ if k == 1
                          then [name, stats]  -- "a sword" too wordy
                          else [MU.CarWs k name, stats]
                return $! "Object:" <+> trimTgtDesc n t
          _ -> return $! tgtBlurb
      statusGap = emptyAttrLine (widthStats - leaderStatusWidth
                                            - selectedStatusWidth
                                            - length damageStatus)
      -- The indicators must fit, they are the actual information.
      pathTgt = displayPathText tgtPos mtargetHP
  targetText <- tgtOrItem $ widthTgt - T.length pathTgt - 8
  let targetGap = emptyAttrLine (widthTgt - T.length pathTgt
                                          - T.length targetText)
      targetStatus = textToAL targetText ++ targetGap ++ textToAL pathTgt
      sfBottom =
        [ arenaStatus ++ xhairStatus
        , selectedStatus ++ statusGap ++ damageStatus ++ leaderStatus
          ++ targetStatus ]
      fLine y = map (\x -> dis $ Point x y) [0..lxsize-1]
      singleFrame = emptyAttrLine lxsize : map fLine [0..lysize-1] ++ sfBottom
  return $! SingleFrame{..}

-- Comfortably accomodates 3-digit level numbers and 25-character
-- level descriptions (currently enforced max).
drawArenaStatus :: Bool -> Level -> Int -> AttrLine
drawArenaStatus explored Level{ldepth=AbsDepth ld, ldesc, lseen, lclear} width =
  let seenN = 100 * lseen `div` max 1 lclear
      seenTxt | explored || seenN >= 100 = "all"
              | otherwise = T.justifyLeft 3 ' ' (tshow seenN <> "%")
      lvlN = T.justifyLeft 2 ' ' (tshow ld)
      seenStatus = "[" <> seenTxt <+> "seen] "
  in textToAL $ T.justifyLeft width ' '
              $ T.take 29 (lvlN <+> T.justifyLeft 26 ' ' ldesc) <+> seenStatus

drawLeaderStatus :: MonadClient m => Int -> m AttrLine
drawLeaderStatus waitT = do
  let calmHeaderText = "Calm"
      hpHeaderText = "HP"
  mleader <- getsClient _sleader
  case mleader of
    Just leader -> do
      actorAspect <- getsClient sactorAspect
      s <- getState
      let ar = case EM.lookup leader actorAspect of
            Just aspectRecord -> aspectRecord
            Nothing -> assert `failure`leader
          (darkL, bracedL, hpDelta, calmDelta,
           ahpS, bhpS, acalmS, bcalmS) =
            let b@Actor{bhp, bcalm} = getActorBody leader s
            in ( not (actorInAmbient b s)
               , braced b, bhpDelta b, bcalmDelta b
               , show $ max 0 $ aMaxHP ar, show (bhp `divUp` oneM)
               , show $ max 0 $ aMaxCalm ar, show (bcalm `divUp` oneM))
          -- This is a valuable feedback for the otherwise hard to observe
          -- 'wait' command.
          slashes = ["/", "|", "\\", "|"]
          slashPick = slashes !! (max 0 (waitT - 1) `mod` length slashes)
          addColor c t = map (Color.AttrChar $ Color.Attr c Color.defBG) t
          checkDelta ResDelta{..}
            | resCurrentTurn < 0 || resPreviousTurn < 0
              = addColor Color.BrRed  -- alarming news have priority
            | resCurrentTurn > 0 || resPreviousTurn > 0
              = addColor Color.BrGreen
            | otherwise = stringToAL  -- only if nothing at all noteworthy
          calmAddAttr = checkDelta calmDelta
          darkPick | darkL   = "."
                   | otherwise = ":"
          calmHeader = calmAddAttr $ calmHeaderText <> darkPick
          calmText = bcalmS <> (if darkL then slashPick else "/") <> acalmS
          bracePick | bracedL   = "}"
                    | otherwise = ":"
          hpAddAttr = checkDelta hpDelta
          hpHeader = hpAddAttr $ hpHeaderText <> bracePick
          hpText = bhpS <> (if bracedL then slashPick else "/") <> ahpS
          justifyRight n t = replicate (n - length t) ' ' ++ t
      return $! calmHeader <> stringToAL (justifyRight 6 calmText <> " ")
                <> hpHeader <> stringToAL (justifyRight 6 hpText <> " ")
    Nothing -> return $! stringToAL $ calmHeaderText <> ": --/-- "
                                   <> hpHeaderText <> ": --/-- "

drawLeaderDamage :: MonadClient m => Int -> m AttrLine
drawLeaderDamage width = do
  mleader <- getsClient _sleader
  let addColor s = map (Color.AttrChar $ Color.Attr Color.BrCyan Color.defBG) s
  stats <- case mleader of
    Just leader -> do
      allAssocsRaw <- fullAssocsClient leader [CEqp, COrgan]
      let allAssocs = filter (isMelee . itemBase . snd) allAssocsRaw
      actorSk <- actorSkillsClient leader
      actorAspect <- getsClient sactorAspect
      strongest <- pickWeaponM allAssocs actorSk actorAspect leader False
      let damage = case strongest of
            [] -> "0"
            (_averageDmg, (_, itemFull)) : _ ->
              let getD :: IK.Effect -> Maybe Dice.Dice -> Maybe Dice.Dice
                  getD (IK.Hurt dice) acc = Just $ dice + fromMaybe 0 acc
                  getD (IK.Burn dice) acc = Just $ dice + fromMaybe 0 acc
                  getD _ acc = acc
                  mdice = case itemDisco itemFull of
                    Just ItemDisco{itemKind=IK.ItemKind{IK.ieffects}} ->
                      foldr getD Nothing ieffects
                    Nothing -> Nothing
                  tdice = case mdice of
                    Nothing -> "0"
                    Just dice -> show dice
                  bonus = aHurtMelee $ actorAspect EM.! leader
                  unknownBonus = unknownMelee $ map snd allAssocs
                  tbonus = if bonus == 0
                           then if unknownBonus then "+?" else ""
                           else (if bonus > 0 then "+" else "")
                                <> show bonus
                                <> if unknownBonus then "%?" else "%"
             in tdice <> tbonus
      return $! damage
    Nothing -> return ""
  return $! if null stats || length stats >= width then []
            else addColor $ stats <> " "

-- TODO: colour some texts using the faction's colour
drawSelected :: MonadClient m
             => LevelId -> Int -> ES.EnumSet ActorId -> m (Int, AttrLine)
drawSelected drawnLevelId width selected = do
  mleader <- getsClient _sleader
  side <- getsClient sside
  ours <- getsState $ filter (not . bproj . snd)
                      . actorAssocs (== side) drawnLevelId
  let viewOurs (aid, Actor{bsymbol, bcolor, bhp}) =
        let bg = if | mleader == Just aid -> Color.BrRed
                    | ES.member aid selected -> Color.BrBlue
                    | otherwise -> Color.defBG
            sattr = Color.Attr {Color.fg = bcolor, bg}
        in Color.AttrChar sattr $ if bhp > 0 then bsymbol else '%'
      maxViewed = width - 2
      len = length ours
      star = let fg = case ES.size selected of
                   0 -> Color.BrBlack
                   n | n == len -> Color.BrWhite
                   _ -> Color.defFG
                 char = if len > maxViewed then '$' else '*'
             in Color.AttrChar Color.defAttr{Color.fg} char
      viewed = map viewOurs $ take maxViewed
               $ sortBy (comparing keySelected) ours
  return (len + 2, [star] ++ viewed ++ [Color.spaceAttr])
