{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE DeriveTraversable       #-}
{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE PatternGuards       #-}
-- |
-- Copyright   : (c) 2019 Robert Künnemann
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Robert Künnemann <robert@kunnemann.de>
-- Portability : GHC only
--
-- Data types for SAPIC processes in theories
module Theory.Sapic (
    Process
    , ProcessCombinator(..)
    , AnProcess(..)
    , SapicAction(..)
    , SapicTerm
    , paddAnn
    , applyProcess
    , pfoldMap
    , ProcessPosition
    , lhs
    , rhs
    , prettySapic'
    , prettySapicAction'
    , prettySapicComb
    , prettySapicTopLevel'
    , prettyPosition
    , LetExceptions (..)
    , prettyLetExceptions
) where

import Data.Binary
import Data.Data
import GHC.Generics (Generic)
import Control.Parallel.Strategies
import Theory.Model.Fact
import Term.LTerm
import Theory.Text.Pretty
import Term.Substitution
import Control.Monad.Catch

-- | A process data structure
-- | In general, terms we use in the translation have logical veriables
type SapicTerm = LNTerm

-- | Actions are parts of the process that maybe connected with ";"
data SapicAction = 
                   Rep
                 | New LVar
                 | ChIn (Maybe SapicTerm) SapicTerm
                 | ChOut (Maybe SapicTerm) SapicTerm
                 | Insert SapicTerm SapicTerm
                 | Delete SapicTerm 
                 | Lock SapicTerm 
                 | Unlock SapicTerm 
                 | Event LNFact 
                 | MSR ([LNFact], [LNFact], [LNFact])
        deriving( Show, Eq, Ord, Generic, NFData, Binary, Data )

-- | When the process tree splits, it is connected with one of these connectives
data ProcessCombinator = Parallel | NDC | Cond LNFact 
        | CondEq SapicTerm SapicTerm | Lookup SapicTerm LVar
    deriving (Generic, NFData, Binary, Show, Eq, Data )

-- | The process tree is terminated with null processes, and either splits
-- (parallel and other combinators) or describes a sequence of actions with
-- only one daughter
data AnProcess ann =  
        ProcessNull ann
    |   ProcessComb ProcessCombinator ann (AnProcess ann) (AnProcess ann)
    -- |   ProcessIdentifier String ann 
    |   ProcessAction SapicAction ann (AnProcess ann)
     deriving(Generic, Data )
instance (Ord ann) => Ord (AnProcess ann)
deriving instance (NFData ann) => NFData (AnProcess ann)
deriving instance (Binary ann) => Binary (AnProcess ann)
deriving instance (Eq ann) => Eq (AnProcess ann)
deriving instance (Show ann) => Show (AnProcess ann)
deriving instance (Semigroup ann) => Semigroup (AnProcess ann)
deriving instance (Monoid ann) => Monoid (AnProcess ann)
deriving instance Foldable (AnProcess)
deriving instance Traversable (AnProcess)

-- This instance is useful for modifying annotations, but not for much more.
instance Functor AnProcess where
    fmap f (ProcessNull an) = ProcessNull (f an)
    fmap f (ProcessComb c an pl pr)  = ProcessComb c (f an) (fmap f pl) (fmap f pr)
    fmap f (ProcessAction a an p)   =  ProcessAction a (f an) (fmap f p)

instance Apply ProcessCombinator where
    apply subst c 
        | (Cond f) <- c = Cond $ apply subst f
        | (CondEq t1 t2) <- c = CondEq (apply subst t1) (apply subst t2)
        | (Lookup t v) <- c = Lookup (apply subst t) v
        | otherwise = c 

data CapturedTag = CapturedIn | CapturedLookup | CapturedNew
    deriving (Typeable, Show)
data LetExceptions = CapturedEx CapturedTag LVar 
    deriving (Typeable, Show, Exception)
    -- deriving (Typeable)

prettyLetExceptions (CapturedEx tag v) = "Problem with let expression. Variable "++ show v ++ " captured in " ++ pretty tag ++ ". Please rename." 
    where pretty CapturedIn = "input"
          pretty CapturedLookup = "lookup"
          pretty CapturedNew = "new"

applyProcessCombinatorError subst c 
        | (Lookup t v) <- c  = if v `elem` dom (subst) then 
                                  throwM $ CapturedEx CapturedLookup v
                               else 
                                  return $ Lookup (apply subst t) v
        | otherwise = return $ apply subst c

instance Apply SapicAction where
    apply subst ac 
        | (New v) <- ac        = (New v)
        | (ChIn  mt t) <- ac   = (ChIn (apply subst mt) t)
        | (ChOut mt t) <- ac   = (ChOut (apply subst mt) (apply subst t))
        | (Insert t1 t2) <- ac = (Insert (apply subst t1) (apply subst t2))
        | (Delete t) <- ac     = (Delete (apply subst t))
        | (Lock t) <- ac       = (Lock (apply subst t))
        | (Unlock t) <- ac     = (Unlock (apply subst t))
        | (Event f) <- ac      = (Event (apply subst f))
        | (MSR (l,a,r)) <- ac  = (MSR (apply subst (l,a,r)))
        | Rep <- ac            = Rep

applySapicActionError subst ac
        | (New v) <- ac =  if v `elem` dom subst then 
                                  throwM $ CapturedEx CapturedNew v
                               else 
                                  return $ New v
        | (ChIn mt t) <- ac,  Lit (Var v) <-  viewTerm t =
                            if v `elem` dom subst then 
                                  -- t is a single variable that is captured by the let. This is likely unintended, so we warn.
                                  throwM $ CapturedEx CapturedIn v
                            else
                                  return $ ChIn (apply subst mt) t 
        | otherwise = return $ apply subst ac

instance Apply (AnProcess ann) where
-- We are ignoring capturing here, use applyProcess below to get warnings.
    apply subst (ProcessNull ann) = ProcessNull ann
    apply subst (ProcessComb c ann pl pr) =
                ProcessComb (apply subst c) ann (apply subst pl) (apply subst pr)
    apply subst (ProcessAction ac ann p') =
                ProcessAction (apply subst ac) ann (apply subst p')

applyProcess subst (ProcessNull ann) = return $ ProcessNull ann
applyProcess subst (ProcessComb c ann pl pr) = do
                c' <- applyProcessCombinatorError subst c
                pl' <- applyProcess subst pl
                pr' <- applyProcess subst pr
                return $ ProcessComb c' ann pl' pr'
applyProcess subst (ProcessAction ac ann p) = do
                ac' <- applySapicActionError subst ac
                p' <- applyProcess subst p
                return $ ProcessAction ac' ann p'

-- | After parsing, the process is already annotated wth a list of process
--   identifiers. Any identifier in this in this list was inlined to give this
--   comment, e.g., 
--    let A = 0
--    let B = A | A
--    !B
--    has two Null-rules with annotation [A,B].
--  This will be helpful to recognise protocols roles and visualise them.

type ProcessName = String -- String used in annotation to identify processes
type ProcessAnnotation = [ProcessName]
type Process = AnProcess ProcessAnnotation
type ProcessPosition = [Int]

-- | Positions are to be read left-to-right, 1 is left, 2 is right.
lhs :: [Int] -> ProcessPosition
lhs p = (p++[1]) :: ProcessPosition

rhs :: [Int] -> ProcessPosition
rhs p = (p++[2]) :: ProcessPosition
-- rhs :: ProcessPosition = 2

-- | Add another element to the existing annotations, e.g., yet another identifier.
paddAnn :: Process -> ProcessAnnotation -> Process
paddAnn (ProcessNull ann) ann' = ProcessNull $ ann `mappend` ann'
paddAnn (ProcessComb c ann pl pr ) ann' = ProcessComb c (ann `mappend` ann')  pl pr 
paddAnn (ProcessAction a ann p ) ann' = ProcessAction a (ann `mappend` ann')  p

-- | folding on the process tree, used, e.g., for printing
pfoldMap :: Monoid a => (AnProcess ann -> a) -> AnProcess ann -> a
pfoldMap f (ProcessNull an) = f (ProcessNull an)
pfoldMap f (ProcessComb c an pl pr)  = 
        pfoldMap f pl
        `mappend` 
        f (ProcessComb c an pl pr)
        `mappend` 
        pfoldMap f pr
pfoldMap f (ProcessAction a an p)   = 
        f (ProcessAction a an p)
        `mappend` 
        pfoldMap f p

prettyPosition:: ProcessPosition -> String
prettyPosition = foldl (\ s n -> s ++ show n ) ""

-- | Printer for SAPIC actions. 
-- Note: Need to give the pretty printer for rules as a parameter as otherwise
-- we would have circular dependencies.
-- Instantiated in Theory.Sapic.Print later
prettySapicAction' :: 
                   ( [LNFact] -> [LNFact] -> [LNFact] -> String)
                    -> SapicAction  -> String
prettySapicAction' _ (New n) = "new "++ show n
prettySapicAction' _ Rep  = "!"
prettySapicAction' _ (ChIn (Just t1) t2 )  = "in(" ++ render (prettyLNTerm t1) ++ "," ++ render ( prettyLNTerm t2) ++ ")"
prettySapicAction' _ (ChIn Nothing t2 )  = "in(" ++ render (prettyLNTerm t2) ++ ")"
prettySapicAction' _ (ChOut (Just t1) t2 )  = "out(" ++ render (prettyLNTerm t1) ++ "," ++ render (prettyLNTerm t2) ++ ")"
prettySapicAction' _ (ChOut Nothing t2 )  = "out(" ++ render (prettyLNTerm t2) ++ ")"
prettySapicAction' _ (Insert t1 t2)  = "insert " ++ render (prettyLNTerm t1) ++ "," ++ render (prettyLNTerm t2)
prettySapicAction' _ (Delete t )  = "delete " ++ render (prettyLNTerm t)
prettySapicAction' _ (Lock t )  = "lock " ++ render (prettyLNTerm t)
prettySapicAction' _ (Unlock t )  = "unlock " ++ render (prettyLNTerm t)
prettySapicAction' _ (Event a )  = "event " ++ render (prettyLNFact a)
prettySapicAction' prettyRule' (MSR (p,a,c)) = prettyRule' p a c

prettySapicComb :: ProcessCombinator -> [Char]
prettySapicComb Parallel = "|"
prettySapicComb NDC = "+"
prettySapicComb (Cond a) = "if "++ render (prettyLNFact a)
prettySapicComb (CondEq t t') = "if "++ p t ++ "=" ++ p t'
                                    where p = render . prettyLNTerm
prettySapicComb (Lookup t v) = "lookup "++ p t ++ " as " ++ show v
                                    where p = render . prettyLNTerm

-- | Printer for SAPIC processes.. 
-- TODO At the moment, the process structure is not used to properly print how
-- elements are associated.
-- Should do it, but then we cannot use pfoldMap anymore.
prettySapic' :: ([LNFact] -> [LNFact] -> [LNFact] -> String) -> AnProcess ann -> String
prettySapic' prettyRule = pfoldMap f 
    where f (ProcessNull _) = "0"
          f (ProcessComb c _ _ _)  = prettySapicComb c 
          f (ProcessAction Rep _ _)  = prettySapicAction' prettyRule Rep 
          f (ProcessAction a _ _)  = prettySapicAction' prettyRule a ++ ";"

-- | Printer for the top-level process, used, e.g., for rule names.
prettySapicTopLevel' :: ([LNFact] -> [LNFact] -> [LNFact] -> String) -> AnProcess ann -> String
prettySapicTopLevel' _ (ProcessNull _) = "0"
prettySapicTopLevel' _ (ProcessComb c _ _ _)  = prettySapicComb c 
prettySapicTopLevel' prettyRule (ProcessAction Rep _ _)  = prettySapicAction' prettyRule Rep 
prettySapicTopLevel' prettyRule (ProcessAction a _ _)  = prettySapicAction' prettyRule a ++ ";"

