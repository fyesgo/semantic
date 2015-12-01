module Main where

import Categorizable
import Diff
import Interpreter
import Patch
import Syntax
import Term
import Unified
import Control.Comonad.Cofree
import Control.Monad
import Control.Monad.Free hiding (unfoldM)
import qualified Data.Map as Map
import qualified Data.ByteString.Char8 as ByteString
import Data.Maybe
import Data.Set
import System.Environment

import Foreign
import Foreign.C
import Foreign.C.Types
import Foreign.C.String
import Foreign.ForeignPtr.Unsafe

data TSLanguage = TsLanguage deriving (Show, Eq)
foreign import ccall "prototype/doubt-difftool/doubt-difftool-Bridging-Header.h ts_language_c" ts_language_c :: IO (Ptr TSLanguage)

data TSDocument = TsDocument deriving (Show, Eq)
foreign import ccall "prototype/External/tree-sitter/include/tree_sitter/runtime.h ts_document_make" ts_document_make :: IO (Ptr TSDocument)
foreign import ccall "prototype/External/tree-sitter/include/tree_sitter/runtime.h ts_document_set_language" ts_document_set_language :: Ptr TSDocument -> Ptr TSLanguage -> IO ()
foreign import ccall "prototype/External/tree-sitter/include/tree_sitter/runtime.h ts_document_set_input_string" ts_document_set_input_string :: Ptr TSDocument -> CString -> IO ()
foreign import ccall "prototype/External/tree-sitter/include/tree_sitter/runtime.h ts_document_parse" ts_document_parse :: Ptr TSDocument -> IO ()
foreign import ccall "prototype/External/tree-sitter/include/tree_sitter/runtime.h ts_document_free" ts_document_free :: Ptr TSDocument -> IO ()

data TSLength = TsLength { bytes :: CSize, chars :: CSize }
  deriving (Show, Eq)

data TSNode = TsNode { _data :: Ptr (), offset :: TSLength }
  deriving (Show, Eq)

instance Storable TSNode where
  alignment n = 24
  sizeOf n = 24
  peek p = error "Haskell code should never read TSNode values directly."
  poke p n = error "Haskell code should never write TSNode values directly."

foreign import ccall "app/bridge.h ts_document_root_node_p" ts_document_root_node_p :: Ptr TSDocument -> Ptr TSNode -> IO ()
foreign import ccall "app/bridge.h ts_node_p_name" ts_node_p_name :: Ptr TSNode -> Ptr TSDocument -> IO CString
foreign import ccall "app/bridge.h ts_node_p_named_child_count" ts_node_p_named_child_count :: Ptr TSNode -> IO CSize
foreign import ccall "app/bridge.h ts_node_p_named_child" ts_node_p_named_child :: Ptr TSNode -> CSize -> Ptr TSNode -> IO CSize
foreign import ccall "app/bridge.h ts_node_p_pos_chars" ts_node_p_pos_chars :: Ptr TSNode -> IO CSize
foreign import ccall "app/bridge.h ts_node_p_size_chars" ts_node_p_size_chars :: Ptr TSNode -> IO CSize

main :: IO ()
main = do
  args <- getArgs
  output <- let (a, b) = files args in do
    aContents <- readFile a
    bContents <- readFile b
    aTerm <- parseTreeSitterFile aContents
    bTerm <- parseTreeSitterFile bContents
    unified (interpret comparable aTerm bTerm) aContents bContents
  ByteString.putStr output

parseTreeSitterFile :: String -> IO (Term String Info)
parseTreeSitterFile contents = do
  document <- ts_document_make
  language <- ts_language_c
  ts_document_set_language document language
  withCString contents (\source -> do
    ts_document_set_input_string document source
    ts_document_parse document
    term <- documentToTerm document contents
    ts_document_free document
    return term)

documentToTerm :: Ptr TSDocument -> String -> IO (Term String Info)
documentToTerm document contents = alloca $ \root -> do
  ts_document_root_node_p document root
  snd <$> toTerm root where
    toTerm :: Ptr TSNode -> IO (String, Term String Info)
    toTerm node = do
      name <- ts_node_p_name node document
      name <- peekCString name
      children <- withNamedChildren node toTerm
      range <- range node
      annotation <- return . Info range $ singleton name
      return (name, annotation :< case children of
        [] -> Leaf $ substring range contents
        _ | member name keyedProductions -> Keyed $ Map.fromList children
        _ | member name fixedProductions -> Fixed $ fmap snd children
        _ | otherwise -> Indexed $ fmap snd children)

keyedProductions = fromList [ "object" ]
fixedProductions = fromList [ "pair", "rel_op", "math_op", "bool_op", "bitwise_op", "type_op", "math_assignment", "assignment", "subscript_access", "member_access", "new_expression", "function_call", "function", "ternary" ]

withNamedChildren :: Ptr TSNode -> (Ptr TSNode -> IO (String, a)) -> IO [(String, a)]
withNamedChildren node transformNode = do
  count <- ts_node_p_named_child_count node
  if count == 0
    then return []
    else mapM (alloca . getChild) [0..pred count] where
      getChild n out = do
        ts_node_p_named_child node n out
        transformNode out

range :: Ptr TSNode -> IO Range
range node = do
  pos <- ts_node_p_pos_chars node
  size <- ts_node_p_size_chars node
  return Range { start = fromEnum $ toInteger pos, end = (fromEnum $ toInteger pos) + (fromEnum $ toInteger size) }

files (a : as) = (a, file as) where
  file (a : as) = a
files [] = error "expected two files to diff"