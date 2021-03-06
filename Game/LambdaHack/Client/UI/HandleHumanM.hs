-- | Semantics of human player commands.
module Game.LambdaHack.Client.UI.HandleHumanM
  ( cmdHumanSem
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , noRemoteHumanCmd, cmdAction, addNoError, fmapTimedToUI
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Game.LambdaHack.Client.Request
import Game.LambdaHack.Client.UI.HandleHelperM
import Game.LambdaHack.Client.UI.HandleHumanGlobalM
import Game.LambdaHack.Client.UI.HandleHumanLocalM
import Game.LambdaHack.Client.UI.HumanCmd
import Game.LambdaHack.Client.UI.MonadClientUI

-- | The semantics of human player commands in terms of the client monad.
--
-- Some time cosuming commands are enabled even in aiming mode, but cannot be
-- invoked in aiming mode on a remote level (level different than
-- the level of the leader), which is caught here.
cmdHumanSem :: MonadClientUI m => HumanCmd -> m (Either MError ReqUI)
cmdHumanSem cmd =
  if noRemoteHumanCmd cmd then do
    -- If in aiming mode, check if the current level is the same
    -- as player level and refuse performing the action otherwise.
    arena <- getArenaUI
    lidV <- viewedLevelUI
    if arena /= lidV then
      weaveJust <$> failWith
        "command disabled on a remote level, press ESC to switch back"
    else cmdAction cmd
  else cmdAction cmd

-- | Commands that are forbidden on a remote level, because they
-- would usually take time when invoked on one, but not necessarily do
-- what the player expects. Note that some commands that normally take time
-- are not included, because they don't take time in aiming mode
-- or their individual sanity conditions include a remote level check.
noRemoteHumanCmd :: HumanCmd -> Bool
noRemoteHumanCmd cmd = case cmd of
  Wait          -> True
  Wait10        -> True
  MoveItem{}    -> True
  Apply{}       -> True
  AlterDir{}    -> True
  AlterWithPointer{} -> True
  MoveOnceToXhair -> True
  RunOnceToXhair -> True
  ContinueToXhair -> True
  _ -> False

cmdAction :: MonadClientUI m => HumanCmd -> m (Either MError ReqUI)
cmdAction cmd = case cmd of
  Macro kms -> addNoError $ macroHuman kms
  ByArea l -> byAreaHuman cmdAction l
  ByAimMode{..} ->
    byAimModeHuman (cmdAction exploration) (cmdAction aiming)
  ByItemMode{..} ->
    byItemModeHuman ts (cmdAction notChosen) (cmdAction chosen)
  ComposeIfLocal cmd1 cmd2 ->
    composeIfLocalHuman (cmdAction cmd1) (cmdAction cmd2)
  ComposeUnlessError cmd1 cmd2 ->
    composeUnlessErrorHuman (cmdAction cmd1) (cmdAction cmd2)
  Compose2ndLocal cmd1 cmd2 ->
    compose2ndLocalHuman (cmdAction cmd1) (cmdAction cmd2)
  LoopOnNothing cmd1 ->
    loopOnNothingHuman (cmdAction cmd1)

  Wait -> weaveJust <$> Right <$> fmapTimedToUI waitHuman
  Wait10 -> weaveJust <$> Right <$> fmapTimedToUI waitHuman10
  MoveDir v ->
    weaveJust <$> (ReqUITimed <$$> moveRunHuman True True False False v)
  RunDir v -> weaveJust <$> (ReqUITimed <$$> moveRunHuman True True True True v)
  RunOnceAhead -> runOnceAheadHuman
  MoveOnceToXhair -> weaveJust <$> (ReqUITimed <$$> moveOnceToXhairHuman)
  RunOnceToXhair  -> weaveJust <$> (ReqUITimed <$$> runOnceToXhairHuman)
  ContinueToXhair -> weaveJust <$> (ReqUITimed <$$> continueToXhairHuman)
  MoveItem cLegalRaw toCStore mverb auto ->
    weaveJust
    <$> (fmapTimedToUI <$> moveItemHuman cLegalRaw toCStore mverb auto)
  Project ts -> weaveJust <$> (fmapTimedToUI <$> projectHuman ts)
  Apply ts -> weaveJust <$> (fmapTimedToUI <$> applyHuman ts)
  AlterDir ts -> weaveJust <$> (fmapTimedToUI <$> alterDirHuman ts)
  AlterWithPointer ts -> weaveJust
                         <$> (fmapTimedToUI <$> alterWithPointerHuman ts)
  Help -> helpHuman cmdAction
  ItemMenu -> itemMenuHuman cmdAction
  ChooseItemMenu dialogMode -> chooseItemMenuHuman cmdAction dialogMode
  MainMenu -> mainMenuHuman cmdAction
  GameDifficultyIncr -> gameDifficultyIncr >> challengesMenuHuman cmdAction
  GameWolfToggle -> gameWolfToggle >> challengesMenuHuman cmdAction
  GameFishToggle -> gameFishToggle >> challengesMenuHuman cmdAction
  GameScenarioIncr -> gameScenarioIncr >> mainMenuHuman cmdAction

  GameRestart -> weaveJust <$> gameRestartHuman
  GameExit -> weaveJust <$> fmap Right gameExitHuman
  GameSave -> weaveJust <$> fmap Right gameSaveHuman
  Tactic -> weaveJust <$> tacticHuman
  Automate -> weaveJust <$> automateHuman

  Clear -> addNoError clearHuman
  SortSlots -> addNoError sortSlotsHuman
  ChooseItem dialogMode -> Left <$> chooseItemHuman dialogMode
  ChooseItemProject ts -> Left <$> chooseItemProjectHuman ts
  ChooseItemApply ts -> Left <$> chooseItemApplyHuman ts
  PickLeader k -> Left <$> pickLeaderHuman k
  PickLeaderWithPointer -> Left <$> pickLeaderWithPointerHuman
  MemberCycle -> Left <$> memberCycleHuman
  MemberBack -> Left <$> memberBackHuman
  SelectActor -> addNoError selectActorHuman
  SelectNone -> addNoError selectNoneHuman
  SelectWithPointer -> Left <$> selectWithPointerHuman
  Repeat n -> addNoError $ repeatHuman n
  Record -> addNoError recordHuman
  History -> addNoError historyHuman
  MarkVision -> markVisionHuman >> settingsMenuHuman cmdAction
  MarkSmell -> markSmellHuman >> settingsMenuHuman cmdAction
  MarkSuspect -> markSuspectHuman >> settingsMenuHuman cmdAction
  SettingsMenu -> settingsMenuHuman cmdAction
  ChallengesMenu -> challengesMenuHuman cmdAction

  Cancel -> addNoError cancelHuman
  Accept -> addNoError acceptHuman
  TgtClear -> addNoError tgtClearHuman
  ItemClear -> addNoError itemClearHuman
  MoveXhair v k -> Left <$> moveXhairHuman v k
  AimTgt -> Left <$> aimTgtHuman
  AimFloor -> addNoError aimFloorHuman
  AimEnemy -> addNoError aimEnemyHuman
  AimItem -> addNoError aimItemHuman
  AimAscend k -> Left <$> aimAscendHuman k
  EpsIncr b -> addNoError $ epsIncrHuman b
  XhairUnknown -> Left <$> xhairUnknownHuman
  XhairItem -> Left <$> xhairItemHuman
  XhairStair up -> Left <$> xhairStairHuman up
  XhairPointerFloor -> addNoError xhairPointerFloorHuman
  XhairPointerEnemy -> addNoError xhairPointerEnemyHuman
  AimPointerFloor -> addNoError aimPointerFloorHuman
  AimPointerEnemy -> addNoError aimPointerEnemyHuman

addNoError :: Monad m => m () -> m (Either MError ReqUI)
addNoError cmdCli = cmdCli >> return (Left Nothing)

fmapTimedToUI :: Monad m => m (RequestTimed a) -> m ReqUI
fmapTimedToUI mr = ReqUITimed . RequestAnyAbility <$> mr
