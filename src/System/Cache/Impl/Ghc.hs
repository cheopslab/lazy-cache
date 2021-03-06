{-# LANGUAGE RecursiveDo #-}
-- | Caching based on the GHC heap object properties and 
-- relies on lazyness.
module System.Cache.Impl.Ghc
  ( new
  ) where

import           Control.Exception
import           Data.AdditiveGroup
import           Data.Hashable
import           Data.HashPSQ as PSQ
import           Data.IORef
import           Data.Tuple
import           Control.Monad

import System.Cache.Internal.Interface

data Lazy a = Lazy { getLazy :: a}

-- | Create new cache service.
--
new
  :: (Show a, Hashable a, Ord a)
  => Config
  -> IO (Handle a b)
new Config {..} = do
  ref <- newIORef PSQ.empty
  pure $ Handle
    { requestOrInternal = \tm k f -> mdo
      mbox <-
        atomicModifyIORef ref
        $ swap
        . PSQ.alter
            (\case
              Just (p, ~v) | p >= tm ^-^ configLongestAge ->
                (Just v, Just (p, v))
              _ -> (Nothing, Just (tm, Lazy eresult))
            )
            k
      eresult <- try $ maybe
        (f k)
        (\r -> do
          evaluate (getLazy r) >>= \case
            Left s -> throwIO s
            Right x -> pure x
        )
        mbox
      result <- case eresult of
        Left (s::SomeException) -> do
          atomicModifyIORef' ref $ \v -> (PSQ.delete k v,  ())
          throwIO s
        Right x -> pure x
      atomicModifyIORef' ref $ swap . PSQ.alterMin
        (\case
          Nothing -> ((), Nothing)
          Just (kk, p, v)
            | p < tm ^-^ configLongestAge -> ((), Nothing)
            | otherwise -> ((), Just (kk, p, v))
        )
      pure result
    , remove = \k -> do
       void $ atomicModifyIORef ref $ swap . PSQ.alter (const ((), Nothing)) k
    }
