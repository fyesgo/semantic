{-# LANGUAGE DataKinds, GeneralizedNewtypeDeriving, MultiParamTypeClasses, ScopedTypeVariables, StandaloneDeriving, TypeApplications, TypeFamilies, TypeOperators, UndecidableInstances #-}
module Analysis.Abstract.Evaluating
( type Evaluating
, evaluate
, evaluates
) where

import Control.Abstract.Evaluator
import Control.Monad.Effect hiding (run)
import Control.Monad.Effect.Fail
import Control.Monad.Effect.Fresh
import Control.Monad.Effect.NonDet
import Control.Monad.Effect.Reader
import Control.Monad.Effect.State
import Data.Abstract.Configuration
import Data.Abstract.Evaluatable
import Data.Abstract.ModuleTable
import Data.Abstract.Value
import Data.Blob
import qualified Data.ByteString.Char8 as BC
import Data.List.Split (splitWhen)
import qualified Data.Map as Map
import Prelude hiding (fail)
import Prologue
import System.FilePath.Posix

-- | Evaluate a term to a value.
evaluate :: forall value term effects
         .  ( effects ~ RequiredEffects term value (Evaluating term value effects)
            , Evaluatable (Base term)
            , FreeVariables term
            , MonadAddressable (LocationFor value) value (Evaluating term value effects)
            , MonadValue term value (Evaluating term value effects)
            , Recursive term
            )
         => term
         -> Final effects value
evaluate = runAnalysis @(Evaluating term value) . evaluateModule

-- | Evaluate terms and an entry point to a value.
evaluates :: forall value term effects
          .  ( effects ~ RequiredEffects term value (Evaluating term value effects)
             , Evaluatable (Base term)
             , FreeVariables term
             , MonadAddressable (LocationFor value) value (Evaluating term value effects)
             , MonadValue term value (Evaluating term value effects)
             , Recursive term
             )
          => [(Blob, term)] -- List of (blob, term) pairs that make up the program to be evaluated
          -> (Blob, term)   -- Entrypoint
          -> Final effects value
evaluates pairs (b, t) = runAnalysis @(Evaluating term value) (withModules b pairs (evaluateModule t))

-- | Run an action with the passed ('Blob', @term@) pairs available for imports.
withModules :: MonadAnalysis term value m => Blob -> [(Blob, term)] -> m a -> m a
withModules Blob{..} pairs = localModuleTable (const moduleTable)
  where
    moduleTable = ModuleTable (Map.fromList (map (first moduleName) pairs))
    rootDir = dropFileName blobPath
    moduleName Blob{..} = toName (dropExtensions (makeRelative rootDir blobPath))
    toName str = qualifiedName (fmap BC.pack (splitWhen (== pathSeparator) str))

-- | An analysis evaluating @term@s to @value@s with a list of @effects@ using 'Evaluatable', and producing incremental results of type @a@.
newtype Evaluating term value effects a = Evaluating (Eff effects a)
  deriving (Applicative, Functor, Effectful, Monad)


deriving instance Member Fail      effects => MonadFail   (Evaluating term value effects)
deriving instance Member Fresh     effects => MonadFresh  (Evaluating term value effects)
deriving instance Member NonDetEff effects => Alternative (Evaluating term value effects)
deriving instance Member NonDetEff effects => MonadNonDet (Evaluating term value effects)

-- | Effects necessary for evaluating (whether concrete or abstract).
type EvaluatingEffects term value
  = '[ Fail                                        -- Failure with an error message
     , Reader (EnvironmentFor value)               -- Local environment (e.g. binding over a closure)
     , State  (EnvironmentFor value)               -- Global (imperative) environment
     , State  (StoreFor value)                     -- The heap
     , Reader (ModuleTable term)                   -- Cache of unevaluated modules
     , State  (ModuleTable (EnvironmentFor value)) -- Cache of evaluated modules
     ]

instance Members '[Reader (EnvironmentFor value), State (EnvironmentFor value)] effects => MonadEnvironment value (Evaluating term value effects) where
  getGlobalEnv = raise get
  putGlobalEnv = raise . put

  askLocalEnv = raise ask
  localEnv f a = raise (local f (lower a))

instance Member (State (StoreFor value)) effects => MonadStore value (Evaluating term value effects) where
  getStore = raise get
  putStore = raise . put

instance Members '[Reader (ModuleTable term), State (ModuleTable (EnvironmentFor value))] effects => MonadModuleTable term value (Evaluating term value effects) where
  getModuleTable = raise get
  putModuleTable = raise . put

  askModuleTable = raise ask
  localModuleTable f a = raise (local f (lower a))

instance Members (EvaluatingEffects term value) effects => MonadEvaluator term value (Evaluating term value effects) where
  getConfiguration term = Configuration term mempty <$> askLocalEnv <*> getStore

instance ( Evaluatable (Base term)
         , FreeVariables term
         , Members (EvaluatingEffects term value) effects
         , MonadAddressable (LocationFor value) value (Evaluating term value effects)
         , MonadValue term value (Evaluating term value effects)
         , Recursive term
         )
         => MonadAnalysis term value (Evaluating term value effects) where
  type RequiredEffects term value (Evaluating term value effects) = EvaluatingEffects term value

  analyzeTerm = eval
