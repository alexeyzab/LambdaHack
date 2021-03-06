-- | Game action monads and basic building blocks for human and computer
-- player actions. Has no access to the main action type.
-- Does not export the @liftIO@ operation nor a few other implementation
-- details.
module Game.LambdaHack.Server.MonadServer
  ( -- * The server monad
    MonadServer( getsServer
               , modifyServer
               , chanSaveServer  -- exposed only to be implemented, not used
               , liftIO  -- exposed only to be implemented, not used
               )
  , MonadServerAtomic(..)
    -- * Assorted primitives
  , getServer, putServer, debugPossiblyPrint, debugPossiblyPrintAndExit
  , serverPrint, saveServer, dumpRngs, restoreScore, registerScore
  , rndToAction, getSetGen
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

-- Cabal
import qualified Paths_LambdaHack as Self (version)

import qualified Control.Exception as Ex hiding (handle)
import qualified Control.Monad.Trans.State.Strict as St
import qualified Data.EnumMap.Strict as EM
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Time.Clock.POSIX
import           Data.Time.LocalTime
import           System.Exit (exitFailure)
import           System.FilePath
import           System.IO (hFlush, stdout)
import qualified System.Random as R

import           Game.LambdaHack.Atomic
import           Game.LambdaHack.Client
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.File
import qualified Game.LambdaHack.Common.HighScore as HighScore
import qualified Game.LambdaHack.Common.Kind as Kind
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Perception
import           Game.LambdaHack.Common.Random
import qualified Game.LambdaHack.Common.Save as Save
import           Game.LambdaHack.Common.State
import           Game.LambdaHack.Content.ModeKind
import           Game.LambdaHack.Content.RuleKind
import           Game.LambdaHack.Server.ServerOptions
import           Game.LambdaHack.Server.State

class MonadStateRead m => MonadServer m where
  getsServer     :: (StateServer -> a) -> m a
  modifyServer   :: (StateServer -> StateServer) -> m ()
  chanSaveServer :: m (Save.ChanSave (State, StateServer))
  -- We do not provide a MonadIO instance, so that outside
  -- nobody can subvert the action monads by invoking arbitrary IO.
  liftIO         :: IO a -> m a

-- | The monad for executing atomic game state transformations.
class MonadServer m => MonadServerAtomic m where
  -- | Execute an atomic command that changes the state
  -- on the server and on all clients that can notice it.
  execUpdAtomic :: UpdAtomic -> m ()
  -- | Execute an atomic command that changes the state
  -- on the server only.
  execUpdAtomicSer :: UpdAtomic -> m Bool
  -- | Execute an atomic command that changes the state
  -- on the given single client only.
  execUpdAtomicFid :: FactionId -> UpdAtomic -> m ()
  -- | Execute an atomic command that changes the state
  -- on the given single client only.
  -- Catch 'AtomicFail' and indicate if it was in fact raised.
  execUpdAtomicFidCatch :: FactionId -> UpdAtomic -> m Bool
  -- | Execute an atomic command that only displays special effects.
  execSfxAtomic :: SfxAtomic -> m ()
  execSendPer :: FactionId -> LevelId
              -> Perception -> Perception -> Perception -> m ()

getServer :: MonadServer m => m StateServer
getServer = getsServer id

putServer :: MonadServer m => StateServer -> m ()
putServer s = modifyServer (const s)

debugPossiblyPrint :: MonadServer m => Text -> m ()
debugPossiblyPrint t = do
  debug <- getsServer $ sdbgMsgSer . soptions
  when debug $ liftIO $ do
    T.hPutStrLn stdout t
    hFlush stdout

debugPossiblyPrintAndExit :: MonadServer m => Text -> m ()
debugPossiblyPrintAndExit t = do
  debug <- getsServer $ sdbgMsgSer . soptions
  when debug $ liftIO $ do
    T.hPutStrLn stdout t
    hFlush stdout
    exitFailure

serverPrint :: MonadServer m => Text -> m ()
serverPrint t = liftIO $ do
  T.hPutStrLn stdout t
  hFlush stdout

saveServer :: MonadServer m => m ()
saveServer = do
  s <- getState
  ser <- getServer
  toSave <- chanSaveServer
  liftIO $ Save.saveToChan toSave (s, ser)

-- | Dumps RNG states from the start of the game to stdout.
dumpRngs :: MonadServer m => RNGs -> m ()
dumpRngs rngs = liftIO $ do
  T.hPutStrLn stdout $ tshow rngs
  hFlush stdout

-- | Read the high scores dictionary. Return the empty table if no file.
restoreScore :: forall m. MonadServer m => Kind.COps -> m HighScore.ScoreDict
restoreScore Kind.COps{corule} = do
  bench <- getsServer $ sbenchmark . sclientOptions . soptions
  mscore <- if bench then return Nothing else do
    let stdRuleset = Kind.stdRuleset corule
        scoresFile = rscoresFile stdRuleset
    dataDir <- liftIO appDataDir
    let path bkp = dataDir </> bkp <> scoresFile
    configExists <- liftIO $ doesFileExist (path "")
    res <- liftIO $ Ex.try $
      if configExists then do
        (vlib2, s) <- strictDecodeEOF (path "")
        if vlib2 == Self.version
        then return $ Just s
        else do
          let msg = "High score file from old version of game detected."
          fail msg
      else return Nothing
    let handler :: Ex.SomeException -> m (Maybe a)
        handler e = do
          let msg = "High score restore failed. The old file moved aside. The error message is:"
                    <+> (T.unwords . T.lines) (tshow e)
          serverPrint msg
          liftIO $ renameFile (path "") (path "bkp.")
          return Nothing
    either handler return res
  maybe (return HighScore.empty) return mscore

-- | Generate a new score, register it and save.
registerScore :: MonadServer m => Status -> FactionId -> m ()
registerScore status fid = do
  cops@Kind.COps{corule} <- getsState scops
  fact <- getsState $ (EM.! fid) . sfactionD
  total <- getsState $ snd . calculateTotal fid
  let stdRuleset = Kind.stdRuleset corule
      scoresFile = rscoresFile stdRuleset
  dataDir <- liftIO appDataDir
  -- Re-read the table in case it's changed by a concurrent game.
  scoreDict <- restoreScore cops
  gameModeId <- getsState sgameModeId
  time <- getsState stime
  date <- liftIO getPOSIXTime
  tz <- liftIO $ getTimeZone $ posixSecondsToUTCTime date
  curChalSer <- getsServer $ scurChalSer . soptions
  factionD <- getsState sfactionD
  bench <- getsServer $ sbenchmark . sclientOptions . soptions
  let path = dataDir </> scoresFile
      outputScore (worthMentioning, (ntable, pos)) =
        -- If not human, probably debugging, so dump instead of registering.
        if bench || isAIFact fact then
          debugPossiblyPrint $ T.intercalate "\n"
          $ HighScore.showScore tz (pos, HighScore.getRecord pos ntable)
        else
          let nScoreDict = EM.insert gameModeId ntable scoreDict
          in when worthMentioning $ liftIO $
               encodeEOF path (Self.version, nScoreDict :: HighScore.ScoreDict)
      chal | fhasUI $ gplayer fact = curChalSer
           | otherwise = curChalSer
                           {cdiff = difficultyInverse (cdiff curChalSer)}
      theirVic (fi, fa) | isAtWar fact fi
                          && not (isHorrorFact fa) = Just $ gvictims fa
                        | otherwise = Nothing
      theirVictims = EM.unionsWith (+) $ mapMaybe theirVic $ EM.assocs factionD
      ourVic (fi, fa) | isAllied fact fi || fi == fid = Just $ gvictims fa
                      | otherwise = Nothing
      ourVictims = EM.unionsWith (+) $ mapMaybe ourVic $ EM.assocs factionD
      table = HighScore.getTable gameModeId scoreDict
      registeredScore =
        HighScore.register table total time status date chal
                           (T.unwords $ tail $ T.words $ gname fact)
                           ourVictims theirVictims
                           (fhiCondPoly $ gplayer fact)
  outputScore registeredScore

-- | Invoke pseudo-random computation with the generator kept in the state.
rndToAction :: MonadServer m => Rnd a -> m a
rndToAction r = do
  gen <- getsServer srandom
  let (gen1, gen2) = R.split gen
  modifyServer $ \ser -> ser {srandom = gen1}
  return $! St.evalState r gen2

-- | Gets a random generator from the arguments or, if not present,
-- generates one.
getSetGen :: MonadServer m => Maybe R.StdGen -> m R.StdGen
getSetGen mrng = case mrng of
  Just rnd -> return rnd
  Nothing -> liftIO R.newStdGen
