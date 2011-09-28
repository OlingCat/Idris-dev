{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances #-}

{- A high level language of tactic composition, for building
   elaborators from a high level language into the core theory.

   This is our interface to proof construction, rather than
   ProofState, because this gives us a language to build derived
   tactics out of the primitives.
-}

module Elaborate(module Elaborate, module ProofState) where

import ProofState
import Core
import Evaluate
import Typecheck

import Control.Monad.State
import Data.Char
import Debug.Trace

-- I don't really want this here, but it's useful for the test shell
data Command = Theorem Name Raw
             | Eval Raw
             | Quit
             | Print Name
             | Tac (Elab ())

type Elab a = StateT (ProofState, String) TC a

runElab :: Elab a -> ProofState -> TC (ProofState, String)
runElab e ps = execStateT e (ps, "")

initElaborator :: Name -> Context -> Type -> ProofState
initElaborator = newProof

processTactic' t = do (p, logs) <- get
                      (p', log) <- lift $ processTactic t p
                      put (p', logs ++ log)
                      return ()

-- Some handy gadgets for pulling out bits of state

-- get the global context
get_context :: Elab Context
get_context = do (p, _) <- get
                 return (context p)

-- get the local context at the currently in focus hole
get_env :: Elab Env
get_env = do (p, _) <- get
             lift $ envAtFocus p

-- get the current goal type
goal :: Elab Type
goal = do (p, _) <- get
          lift $ goalAtFocus p

-- typecheck locally
get_type :: Raw -> Elab Type
get_type tm = do ctxt <- get_context
                 env <- get_env
                 (val, ty) <- lift $ check ctxt env tm
                 return (vToP ty)

-- given a desired hole name, return a unique hole name
unique_hole :: Name -> Elab Name
unique_hole n = do env <- get_env
                   return (uniq n (map fst env))
  where
    uniq n hs | n `elem` hs = uniq (next n) hs
              | otherwise   = n

next (MN i n)    = MN (i+1) n
next (UN (x:xs)) = let (num', nm') = span isDigit (reverse x)
                       nm = reverse nm'
                       num = readN (reverse num') in
                           UN ((nm ++ show (num+1)) : xs)
  where
    readN "" = 0
    readN x  = read x

log :: String -> Elab ()
log str = do (p, logs) <- get
             put (p, logs ++ str ++ "\n")

-- The primitives, from ProofState

attack :: Elab ()
attack = processTactic' Attack

claim :: Name -> Raw -> Elab ()
claim n t = processTactic' (Claim n t)

fill :: Raw -> Elab ()
fill t = processTactic' (Fill t)

unify_fill :: Raw -> Elab ()
unify_fill t = processTactic' (UnifyFill t)

solve :: Elab ()
solve = processTactic' Solve

regret :: Elab ()
regret = processTactic' Regret

compute :: Elab ()
compute = processTactic' Compute

eval_in :: Raw -> Elab ()
eval_in t = processTactic' (EvalIn t)

check_in :: Raw -> Elab ()
check_in t = processTactic' (CheckIn t)

intro :: Name -> Elab ()
intro n = processTactic' (Intro n)

forall :: Name -> Raw -> Elab ()
forall n t = processTactic' (Forall n t)

focus :: Name -> Elab ()
focus n = processTactic' (Focus n)

movelast :: Name -> Elab ()
movelast n = processTactic' (MoveLast n)

proofstate :: Elab ()
proofstate = processTactic' ProofState

qed :: Elab ()
qed = processTactic' QED

prepare_apply :: Raw -> [Bool] -> Elab [Name]
prepare_apply fn imps =
    do ty <- get_type fn
       let claims = getArgs ty imps
       mapM doClaim claims
  where
    getArgs (Bind n (Pi t) sc) (i : is) = (n, t, i):getArgs sc is
    getArgs t i = []

    doClaim (n', t, i) =
        do n <- unique_hole n'
           claim n (forget t)
           when i (movelast n)
           return n

apply :: Raw -> [Bool] -> Elab ()
apply fn imps = 
    do args <- prepare_apply fn imps
       unify_fill (raw_apply fn (map Var args))

-- Some combinators on elaborations

-- Sequencing
-- infixr 5 ==>

-- (==>) :: Elab -> Elab -> Elab
-- (==>) t1 t2 ps = do (ps',  log')  <- t1 ps
--                     (ps'', log'') <- t2 ps'
--                     return (ps'', log' ++ log')
--              
-- -- Try a tactic, if it fails, try another
-- try :: Elab -> Elab -> Elab
-- try t1 t2 ps = case t1 ps of
--                     OK v -> return v
--                     _ -> t2 ps
-- 
