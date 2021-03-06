
module EvalCxt
  (eval, force, quote, Eval.forceU, Eval.vProj1, Eval.vProj2, Eval.vApp, vEq,
   Eval.vAppSE, Eval.vAppSI, Eval.vAppPE, Eval.vAppPI)
  where

import Lens.Micro.Platform

import Types
import qualified Evaluation as Eval

eval :: Dbg => Cxt -> Tm -> Val
eval cxt = Eval.eval (cxt^.vals) (cxt^.len)
{-# inline eval #-}

force :: Cxt -> Val -> Val
force cxt = Eval.force (cxt^.len)
{-# inline force #-}

quote :: Cxt -> Val -> Tm
quote cxt = Eval.quote (cxt^.len)
{-# inline quote #-}

vEq :: Dbg => Cxt -> Val -> Val -> Val -> Val
vEq cxt = Eval.vEq (cxt^.len)
{-# inline vEq #-}
