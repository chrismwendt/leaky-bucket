module Lib where

import Control.Concurrent hiding (yield)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import System.Clock
import Control.Monad
import Pipes
import qualified Pipes.Prelude as P
import Pipes.Concurrent
import System.Posix.Signals
import Rainbow
import Safe

mkCControl :: MonadIO m => IO (Pipe (IO Bool) (Async ()) m ())
mkCControl = do
  v <- newEmptyMVar
  let rlylog s = do putMVar v () >> print s >> takeMVar v
  -- let rlylog s = return ()
  tWaiting <- atomically $ newTVar False
  ready <- newEmptyMVar :: IO (MVar ())
  tState <- atomically $ newTVar ((0, 1.0) :: (Integer, Double))
  let update True False size cwnd = (pred size, cwnd)
      update True True size cwnd = (pred size, cwnd + 1 / cwnd)
      update False _ size cwnd = (pred size, max 1 (cwnd / 2))

  return $ P.mapM $ \req -> liftIO $ do
    full <- atomically $ do
      (size, cwnd) <- readTVar tState
      writeTVar tState (succ size, cwnd)
      let w = succ size >= floor cwnd
      writeTVar tWaiting w
      return w
    s <- atomically $ readTVar tState
    putChunkLn $ chunk (show s) & fore yellow
    a <- async $ do
      wasSuccessful <- req
      triggered <- atomically $ do
        (size, cwnd) <- readTVar tState
        let (size', cwnd') = update wasSuccessful full size cwnd
        writeTVar tState (size', cwnd')

        if size >= floor cwnd && size' < floor cwnd'
          then do
            w <- readTVar tWaiting
            writeTVar tWaiting False
            return w
          else return False
      when triggered $ putMVar ready ()
    when full $ takeMVar ready
    return a


-- pipe producer consumer = do
--   (output, input, seal) <- spawn' unbounded
--   ap <- async $ runEffect $ (producer >> lift (atomically seal)) >-> toOutput output
--   ac <- async $ runEffect $ fromInput input >-> consumer
--   return (ap, ac, seal)
-- 
-- 
-- 
--   foreal' <- foreal
--   v <- atomically $ newTVar (take n [1 .. ])
--   let prod = do {
--     vv <- lift $ atomically $ do {
--       bleh <- readTVar v;
--       writeTVar v (tailSafe bleh);
--       return $ headMay bleh;
--     };
--     case vv of
--       Nothing -> return ()
--       Just x -> yield x >> prod;
--   }
--   let other vz = do {
--     b <- bulk;
--     putChunkLn $ chunk (show vz) & fore (if b then green else red);
--     unless b $ do {
--       atomically $ modifyTVar v (vz :);
--     };
--     return b;
--   }
--   let p = prod >-> P.map other >-> foreal'
--   let c = P.mapM_ wait
--   (ap, ac, _) <- p `pipe` c
--   waitBoth ap ac
