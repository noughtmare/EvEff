-----------------------------------------------------
-- Copyright 2020, Daan Leijen, Ningning Xie.
-----------------------------------------------------
{-# LANGUAGE  TypeOperators,            -- h :* e                     (looks nice but not required)
              ConstraintKinds,          -- type (h ?: e) = In h e     (looks nice but not required)
              FlexibleInstances,        -- instance Sub () e          (non type variable in head)
              FlexibleContexts,         -- (State Int ?: e) => ...    (non type variable argument)
              DataKinds, TypeFamilies,  -- type family HEqual h h' :: Bool
              UndecidableInstances,     -- InEq (HEqual h h') h h' e => ... (duplicate instance variable)
              GADTs,
              MultiParamTypeClasses,
              Rank2Types
#-}

module Control.Ev.Eff(
              Eff
            , runEff          -- :: Eff () a -> a
            , (:*)
            , In, (:?)

            -- operations
            , Op
            , value
            , function
            , operation
            , except
            , perform         -- :: In h e => (forall e' ans. h e' ans -> Op a b e' ans) -> a -> Eff e b
            , mask

            -- handling
            , handler         -- :: h e ans -> Eff (h :* e) ans -> Eff e ans
            , handlerRet
            , handlerHide

            -- local variables
            , Local
            , localGet
            , localSet
            , localUpdate
            , handlerLocal
            , handlerLocalRet
            ) where

import Prelude hiding (read,flip)
import Control.Monad( ap, liftM )
import Data.Type.Equality( (:~:)( Refl ) )
import Control.Ev.Ctl hiding (Local)
import Data.IORef

-- import Unsafe.Coerce     (unsafeCoerce)

infixr 5 :*

-------------------------------------------------------
-- The handler context
-------------------------------------------------------
data (h :: * -> * -> *) :* e

data Hide h e = forall ans. Hide !(Marker ans) !(h e ans)

data Context e where
  CCons :: !(Marker ans) -> !(h e ans) -> !(Context e) -> Context (h :* e)
  HCons :: !(Marker ans) -> !(Hide h' e) -> !(h (h' :* e) ans) -> !(Context e) -> Context (h :* e)
  CNil  :: Context ()

ctail :: Context (h :* e) -> Context e
ctail ctx
  = case ctx of
      CCons _ _ ctx'   -> ctx'
      HCons _ _ _ ctx' -> ctx'


-------------------------------------------------------
-- The Effect monad
-------------------------------------------------------
newtype Eff e a = Eff (Context e -> Ctl a)

lift :: Ctl a -> Eff e a
{-# INLINE lift #-}
lift ctl = Eff (\_ -> ctl)

under :: Context e -> Eff e a -> Ctl a
{-# INLINE under #-}
under ctx (Eff eff)  = eff ctx


instance Functor (Eff e) where
  fmap  = liftM
instance Applicative (Eff e) where
  pure  = return
  (<*>) = ap
instance Monad (Eff e) where
  return x      = Eff (\ctx -> pure x)
  Eff eff >>= f = Eff (\ctx -> do ctl <- eff ctx
                                  under ctx (f ctl))


handler :: h e ans -> Eff (h :* e) ans -> Eff e ans
handler h action
  = Eff (\ctx -> mprompt $ \m ->                  -- set a fresh prompt with marker `m`
                 do under (CCons m h ctx) action) -- and call action with the extra evidence

runEff :: Eff () a -> a
runEff (Eff eff)  = runCtl (eff CNil)

handlerRet :: (ans -> a) -> h e a -> Eff (h :* e) ans -> Eff e a
handlerRet f h action
  = handler h (do x <- action; return (f x))




-- A handler that hides one handler h' that it runs under itself
handlerHide :: h (h' :* e) ans -> Eff (h :* e) ans -> Eff (h' :* e) ans
handlerHide h action
  = Eff (\ctx -> case ctx of
                   CCons m' h' ctx' -> mprompt $ \m -> under (HCons m (Hide m' h') h ctx') action
                   _ -> error "Control.Ev.Eff.handlerHide: cannot hide already hidden handlers")


-- Efficient (and safe) Local state handler
data Local a e ans = Local (IORef a)

{-# INLINE localGet #-}
localGet :: Eff (Local a :* e) a
localGet = Eff (\(CCons _ (Local r) _) -> unsafeIO (readIORef r))

{-# INLINE localSet #-}
localSet :: a -> Eff (Local a :* e) ()
localSet x = Eff (\(CCons _ (Local r) _) -> unsafeIO (writeIORef r x))

{-# INLINE localUpdate #-}
localUpdate :: (a -> a) -> Eff (Local a :* e) a
localUpdate f = Eff (\(CCons _ (Local r) _) -> unsafeIO (do{ x <- readIORef r; writeIORef r (f x); return x }))

local :: a -> Eff (Local a :* e) ans -> Eff e ans
local init action
  = do r <- lift $ unsafeIO (newIORef init)
       handler (Local r) action


-- Expose a local state handler to just one handler's operations
handlerLocalRet :: a -> (ans -> a -> b) -> (h (Local a :* e) ans) -> Eff (h :* e) ans -> Eff e b
handlerLocalRet init ret h action
  = local init $ do x <- handlerHide h action
                    y <- localGet
                    return (ret x y)

handlerLocal :: a -> (h (Local a :* e) ans) -> Eff (h :* e) ans -> Eff e ans
handlerLocal init h action
  = local init (handlerHide h action)



mask :: Eff e ans -> Eff (h :* e) ans
mask (Eff f) = Eff (\ctx -> f (ctail ctx))


---------------------------------------------------------
-- In, Context
---------------------------------------------------------
type h :? e = In h e

class In h e where
  subContext :: Context e -> SubContext h

data SubContext h  = forall e. SubContext !(Context (h :* e))


instance (InEq (HEqual h h') h h' w) => In h (h' :* w)  where
  subContext = subContextEq


type family HEqual (h :: * -> * -> *) (h' :: * -> * -> *) :: Bool where
  HEqual h h  = 'True
  HEqual h h' = 'False

class (iseq ~ HEqual h h') => InEq iseq h h' e  where
  subContextEq :: Context (h' :* e) -> SubContext h

instance (h ~ h') => InEq 'True h h' e where
  subContextEq ctx = SubContext ctx

instance ('False ~ HEqual h h', In h e) => InEq 'False h h' e where
  subContextEq ctx = subContext (ctail ctx)

withSubContext :: (In h e) => (SubContext h -> Ctl a) -> Eff e a
{-# INLINE withSubContext #-}
withSubContext f
  = Eff (\ctx -> f (subContext ctx))


------------------------------------------------------------------------
-- Allow giving closed type signature (like `State Int :* Amb :* ()`)
-- and later open it up in another context
------------------------------------------------------------------------
{-
class Sub e1 e2 where
  open :: Eff e1 a -> Eff e2 a

instance Sub () e where
  open eff = Eff $ \w -> under CNil eff

instance (SubH h, Sub e1 e2) => Sub (h :* e1) (h :* e2) where
  open eff = Eff $ \(CCons m h ctx) ->
    under ctx $ open (Eff $ \subctx -> under (CCons m (subH ctx h) subctx) eff)

{-
openOp :: (Sub e1 e2) => Context e2 -> Op a b e2 ans -> Op a b e1 ans
openOp w (Op f) = Op $ \a g ->
                  Eff $ \_ -> under w $ f a (\b -> open (g b))
-}
-- openOp w (Tail f)   = Tail $ \a ->
--                        Eff $ \_ -> under w (f a)

class SubH h where
  subH :: Sub e1 e2  => Context e2 -> h e2 a -> h e1 a
-}


------------------------------------
-- Operations
-------------------------------------
-- Operations of type `a -> b` in a handler context `ans`
newtype Op a b e ans = Op { useOp :: Marker ans -> Context e -> a -> Ctl b}

-- Given evidence and an operation selector, perform the operation
-- perform :: In h e => (forall e' ans. Handler h e' ans -> Clause a b e' ans) -> a -> Eff e b
perform :: In h e => (forall e' ans. h e' ans -> Op a b e' ans) -> a -> Eff e b
{-# INLINE perform #-}
perform selectOp x
  = withSubContext $ \(SubContext sctx) ->
    case sctx of
      CCons m h ctx              -> useOp (selectOp h) m ctx x
      HCons m (Hide m' h') h ctx -> useOp (selectOp h) m (CCons m' h' ctx) x


-- tail-resumptive value operation (reader)
value :: a -> Op () a e ans
value x = function (\() -> return x)

-- tail-resumptive operation (almost all operations)
function :: (a -> Eff e b) -> Op a b e ans
function f = Op (\_ ctx x -> under ctx (f x))

-- general operation with a resumption (exceptions, async/await, etc)
operation :: (a -> (b -> Eff e ans) -> Eff e ans) -> Op a b e ans
operation f = Op (\m ctx x -> mcontrol m $ \ctlk ->
                              let k y = Eff (\ctx' -> guard ctx ctx' ctlk y)
                              in under ctx (f x k))

-- operation that never resumes
except :: (a -> Eff e ans) -> Op a b e ans
except f = operation (\x _ -> f x)


guard :: Context e -> Context e -> (b -> Ctl a) -> b -> Ctl a
guard ctx1 ctx2 k x = if (ctx1 == ctx2) then k x else error "Control.Ev.Eff.guard: unscoped resumption under a different handler context"

instance Eq (Context e) where
  CNil               == CNil                = True
  (CCons m1 h1 ctx1) == (CCons m2 h2 ctx2)  = (markerEq m1 m2) && (ctx1 == ctx2)
