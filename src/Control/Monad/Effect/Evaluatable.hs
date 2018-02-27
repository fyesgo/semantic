{-# LANGUAGE MultiParamTypeClasses, Rank2Types, GADTs, TypeOperators, DefaultSignatures, UndecidableInstances, ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
module Control.Monad.Effect.Evaluatable
( Evaluatable(..)
, step
, Recursive(..)
, Base
) where

import Control.Monad.Effect.Fail
import Control.Monad.Effect.Internal
import Control.Monad.Effect.Reader
import Control.Monad.Effect.State
import Data.Abstract.Environment
import Data.Abstract.FreeVariables
import Data.Abstract.Value
import Data.Functor.Classes
import Data.Functor.Foldable (Base, Recursive(..), project)
import Data.Proxy
import Data.Term
import Data.Union (Apply)
import Prelude hiding (fail)
import qualified Data.Union as U


-- | The 'Evaluatable' class defines the necessary interface for a term to be evaluated. While a default definition of 'eval' is given, instances with computational content must implement 'eval' to perform their small-step operational semantics.
class Evaluatable es term v constr where
  eval :: constr term -> Eff es v
  default eval :: (Fail :< es, Show1 constr) => (constr term -> Eff es v)
  eval expr = fail $ "Eval unspecialized for " ++ liftShowsPrec (const (const id)) (const id) 0 expr ""

-- | If we can evaluate any syntax which can occur in a 'Union', we can evaluate the 'Union'.
instance (Apply (Evaluatable es t v) fs) => Evaluatable es t v (Union fs) where
  eval = U.apply (Proxy :: Proxy (Evaluatable es t v)) eval

-- | Evaluating a 'TermF' ignores its annotation, evaluating the underlying syntax.
instance (Evaluatable es t v s) => Evaluatable es t v (TermF s a) where
  eval In{..} = eval termFOut

-- | Evaluate by first projecting a term to recurse one level.
step :: forall v term es. (Evaluatable es term v (Base term), Recursive term)
     => term -> Eff es v
step = eval . project


-- Instances

-- | '[]' is treated as an imperative sequence of statements/declarations s.t.:
--
--   1. Each statement’s effects on the store are accumulated;
--   2. Each statement can affect the environment of later statements (e.g. by 'modify'-ing the environment); and
--   3. Only the last statement’s return value is returned.
instance ( Ord (LocationFor v)
         , Show (LocationFor v)
         , (State (EnvironmentFor v) :< es)
         , (Reader (EnvironmentFor v) :< es)
         , AbstractValue v
         , FreeVariables t
         , Evaluatable es t v (Base t)
         , Recursive t
         )
         => Evaluatable es t v [] where
  eval []     = pure unit -- Return unit value if this is an empty list of terms
  eval [x]    = step x    -- Return the value for the last term
  eval (x:xs) = do
    _ <- step @v x                 -- Evaluate the head term
    env <- get @(EnvironmentFor v) -- Get the global environment after evaluation
                                   -- since it might have been modified by the
                                   -- 'step' evaluation above ^.

    -- Finally, evaluate the rest of the terms, but do so by calculating a new
    -- environment each time where the free variables in those terms are bound
    -- to the global environment.
    local (const (bindEnv (freeVariables1 xs) env)) (eval xs)
