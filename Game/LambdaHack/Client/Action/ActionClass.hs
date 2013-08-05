{-# LANGUAGE FunctionalDependencies #-}
-- | Basic type classes for game actions.
-- This module should not be imported anywhere except in 'Action'
-- and 'TypeAction'.
module Game.LambdaHack.Client.Action.ActionClass where

import Control.Monad.Writer.Strict (WriterT (WriterT), lift, runWriterT)
import Data.Monoid

import Game.LambdaHack.Client.Binding
import Game.LambdaHack.Client.State
import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.ClientCmd
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Frontend

-- | The information that is constant across a client playing session,
-- including many consecutive games in a single session,
-- but is completely disregarded and reset when a new playing session starts.
-- Auxiliary AI and computer player clients have no @sfs@ nor @sbinding@.
data SessionUI = SessionUI
  { sfsess   :: !FrontendSession  -- ^ frontend session information
  , sfconn   :: ConnFrontend      -- ^ connection with the frontend
  , sbinding :: !Binding          -- ^ binding of keys to commands
  }

class MonadActionRO m => MonadClient m where
  getClient    :: m StateClient
  getsClient   :: (StateClient -> a) -> m a
  modifyClient :: (StateClient -> StateClient) -> m ()
  putClient    :: StateClient -> m ()
  -- We do not provide a MonadIO instance, so that outside of Action/
  -- nobody can subvert the action monads by invoking arbitrary IO.
  liftIO       :: IO a -> m a

instance (Monoid a, MonadClient m) => MonadClient (WriterT a m) where
  getClient    = lift getClient
  getsClient   = lift . getsClient
  modifyClient = lift . modifyClient
  putClient    = lift . putClient
  liftIO       = lift . liftIO

class MonadClient m => MonadClientUI m where
  getsSession  :: (SessionUI -> a) -> m a

instance (Monoid a, MonadClientUI m) => MonadClientUI (WriterT a m) where
  getsSession  = lift . getsSession

class MonadClient m => MonadConnClient c m | m -> c where
  getsConn  :: (ConnServer c -> a) -> m a

-- | The bottom of the action monads class semilattice.
class MonadClient m => MonadClientAbort m where
  -- Set the current exception handler. First argument is the handler,
  -- second is the computation the handler scopes over.
  tryWith      :: (Msg -> m a) -> m a -> m a
  -- Abort with the given message.
  abortWith    :: Msg -> m a

instance (Monoid a, MonadClientAbort m) => MonadClientAbort (WriterT a m) where
  tryWith exc m =
    WriterT $ tryWith (\msg -> runWriterT (exc msg)) (runWriterT m)
  abortWith   = lift . abortWith
