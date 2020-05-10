{-# LANGUAGE TypeOperators, FlexibleContexts, Rank2Types #-}

module TestQueens where


import Criterion.Main

import Control.Monad
import Control.Applicative
import Data.Maybe
import Debug.Trace

import Control.Ev.Eff
import Control.Ev.Util

safeAddition :: [Int] -> Int -> Int -> Bool
safeAddition [] _ _ = True
safeAddition (r:rows) row i =
   row /= r &&
   abs (row - r) /= i &&
   safeAddition rows row (i + 1)

-- hand-coded solution to the n-queens problem
queensPure :: Int -> [[Int]]
queensPure n = foldM f [] [1..n] where
    f rows _ = [row : rows |
                row <- [1..n],
                safeAddition rows row 1]

------------------------
-- Choose
------------------------

data Choose e ans = Choose { choose :: forall b. Op [b] b e ans }

failed :: (Choose :? e) => Eff e b
failed = perform choose []

queensComp :: (Choose :? e) => Int -> Eff e [Int]
queensComp n = foldM f [] [1..n] where
    f rows _ = do row <- perform choose [1..n]
                  if (safeAddition rows row 1)
                    then return (row : rows)
                    else failed

------------------------
-- MAYBE
------------------------

maybeResult :: Eff (Choose :* e) ans -> Eff e (Maybe ans)
maybeResult
  = handlerRet Just (Choose{ choose = operation $ \xs k ->
    let firstJust ys = case ys of
                         []      -> return Nothing
                         (y:yy) -> do res <- k y
                                      case res of
                                        Nothing -> firstJust yy
                                        _       -> return res
    in firstJust xs })

queensMaybe :: Int -> Eff e (Maybe [Int])
queensMaybe n = maybeResult $ queensComp n


------------------------
-- FIRST
------------------------

newtype Stack e a = Stack ([Eff (Local (Stack e a) :* e) a])


firstResult :: Eff (Choose :* e) ans -> Eff e ans -- Choose (State (Stack e ans) :* e) ans
firstResult
  = handlerLocal (Stack []) $
    Choose { choose = operation (\xs k ->
      case xs of
        []     -> do (Stack stack) <- localGet
                     case stack of
                       []     -> error "no possible solutions"
                       (z:zs) -> do localPut (Stack zs)
                                    z
        (y:ys) -> do localUpdate (\(Stack zs) -> Stack (map k ys ++ zs))
                     k y
   )}

queensFirst :: Int -> Eff () [Int]
queensFirst n = firstResult $ queensComp n


------------------------
--

pureTest       n = head $ queensPure n
maybeTest      n = runEff $ queensMaybe n
firstTest      n = runEff $ queensFirst n

comp n = [ bench "monad"          $ whnf pureTest n
         , bench "effect maybe"   $ whnf maybeTest n
         , bench "effect first "  $ whnf firstTest n
         ]


main :: IO ()
main = defaultMain
       [ bgroup "20" (comp 20) ]
