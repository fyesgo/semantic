{-# LANGUAGE GADTs, GeneralizedNewtypeDeriving, KindSignatures, ScopedTypeVariables, TypeOperators, UndecidableInstances #-}

module Analysis.Abstract.TypeChecking
( TypeChecking
) where

import Control.Abstract.Analysis
import Data.Abstract.Type
import Prologue hiding (TypeError)

newtype TypeChecking m (effects :: [* -> *]) a = TypeChecking { runTypeChecking :: m effects a }
  deriving (Alternative, Applicative, Functor, Effectful, Monad)

deriving instance MonadEvaluator location term value effects m => MonadEvaluator location term value effects (TypeChecking m)

instance ( Effectful m
         , Alternative (m effects)
         , MonadAnalysis location term Type effects m
         , Member (Resumable TypeError) effects
         , Member NonDet effects
         , MonadValue location Type effects (TypeChecking m)
         )
      => MonadAnalysis location term Type effects (TypeChecking m) where
  analyzeTerm eval term =
    resume @TypeError (liftAnalyze analyzeTerm eval term) (
        \yield err -> case err of
          -- TODO: These should all yield both sides of the exception,
          -- but something is mysteriously busted in the innards of typechecking,
          -- so doing that just yields an empty list in the result type, which isn't
          -- extraordinarily helpful. Better for now to just die with an error and
          -- tackle this issue in a separate PR.
          BitOpError{}       -> throwResumable err
          NumOpError{}       -> throwResumable err
          UnificationError{} -> throwResumable err
        )

  analyzeModule = liftAnalyze analyzeModule

instance ( Interpreter effects (Either (SomeExc TypeError) result) rest m
         , MonadEvaluator location term value effects m
         )
      => Interpreter (Resumable TypeError ': effects) result rest (TypeChecking m) where
  interpret
    = interpret
    . runTypeChecking
    . raiseHandler runError
