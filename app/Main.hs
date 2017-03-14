{-# LANGUAGE LambdaCase #-}

module Main where

import Lib
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

main :: IO ()
main = print "HI"

type Time = Integer

type Capacity = Integer

divCeil :: Integral a => a -> a -> a
divCeil n d = case n `divMod` d of
  (v, 0) -> v
  (v, _) -> succ v

drip :: Capacity -> Time -> Time -> Time -> (Integer, Maybe (Time, Time))
drip capacity timePerDrip dripAvailableAt now =
  let size = max (dripAvailableAt - now) 0 `divCeil` timePerDrip
  in (size, if size < capacity
    then let nextDrip = now + size * timePerDrip in Just (nextDrip, nextDrip + timePerDrip)
    else Nothing)

mkDrip :: Capacity -> Time -> IO (IO Bool)
mkDrip capacity timePerDrip = do
  dripAvailableAt <- atomically $ newTVar 0
  let doTime = toNanoSecs <$> getTime Monotonic
  let doDrip = drip capacity timePerDrip
  let doWait = \d -> threadDelay $ fromIntegral $ d `div` 10^3
  return $ do
    now <- doTime
    tzf <- atomically $ readTVar dripAvailableAt
    print $ fst $ doDrip tzf now
    x <- atomically $ do
      dripAvailableAt' <- readTVar dripAvailableAt
      case snd $ doDrip dripAvailableAt' now of
        Nothing -> return Nothing
        Just (dripAt, nextDripAt) -> do
          writeTVar dripAvailableAt nextDripAt
          return $ Just $ dripAt - now
    case x of
      Nothing -> return False
      Just v -> doWait v >> return True

thing :: IO ()
thing = do
  dripAvailableAt <- atomically $ newTVar 0
  reqAction <- mkDrip 3 (1 * 10^9)
  threads <- mapM (\i -> async $ reqAction >>= \b -> print (i, b)) [1 .. 5]
  mapM_ wait threads
  return ()

pipe producer consumer = do
  (output, input, seal) <- spawn' unbounded
  ap <- async $ runEffect $ (producer >> lift (atomically seal)) >-> toOutput output
  ac <- async $ runEffect $ fromInput input >-> consumer
  return (ap, ac, seal)

thing2 = do
  doDrip <- mkDrip 10 (1 * 10^9)
  let req (i, _) = do {
    print i;
    b <- doDrip;
    print (i, b);
  }
  let threadProducer = P.zip (each [1 .. ]) P.stdinLn >-> P.mapM (async . req)
  (output, input, seal) <- spawn' unbounded
  (ap, ac, seal) <- threadProducer `pipe` (P.mapM_ wait)
  installHandler keyboardSignal (Catch $ cancel ap >> cancel ac) Nothing
  waitAnyCatchCancel [ap, ac]

lnseal pipe c = do
  (output, input, seal) <- spawn' unbounded
  ap <- async . runEffect $ P.stdinLn >-> P.mapM (\x -> x <$ when (null x) (atomically seal)) >-> pipe >-> toOutput output
  ac <- async . runEffect $ fromInput input >-> c
  -- installHandler keyboardSignal (Catch $ atomically seal >> cancel ap >> cancel ac) Nothing
  waitBoth ap ac

superthing n = do
  cControl <- mkCControl
  doDrip <- mkDrip 10 (floor $ 0.5 * 10^9)
  v <- atomically $ newTVar (take n [1 .. ])
  let prod = do {
    vv <- lift $ atomically $ do {
      bleh <- readTVar v;
      writeTVar v (tailSafe bleh);
      return $ headMay bleh;
    };
    case vv of
      Nothing -> return ()
      Just x -> yield x >> prod;
  }
  let other vz = do {
    b <- doDrip;
    putChunkLn $ chunk (show vz) & fore (if b then green else red);
    unless b $ do {
      atomically $ modifyTVar v (vz :);
    };
    return b;
  }
  let p = prod >-> P.map other >-> cControl
  let c = P.mapM_ wait
  (ap, ac, _) <- p `pipe` c
  waitBoth ap ac
