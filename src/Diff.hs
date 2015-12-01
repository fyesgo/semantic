module Diff where

import Syntax
import Data.Set
import Control.Monad.Free
import Patch
import Term
import Categorizable

data Annotated a annotation f = Annotated annotation (Syntax a f)
  deriving (Functor, Eq, Show, Foldable)

data Range = Range { start :: Int, end :: Int }
  deriving (Eq, Show)

type Category = String
data Info = Info Range (Set Category)
  deriving (Eq, Show)

instance Categorizable Info where
  categories (Info _ c) = c

type Diff a annotation = Free (Annotated a (annotation, annotation)) (Patch (Term a annotation))

diffSum :: (Patch (Term a annotation) -> Integer) -> Diff a annotation -> Integer
diffSum patchCost diff = sum $ fmap patchCost diff

diffCost :: Diff a annotation -> Integer
diffCost = diffSum $ patchSum termSize