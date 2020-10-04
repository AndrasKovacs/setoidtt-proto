
module Eval where

import IO
import qualified Data.IntSet as IS

import Common
import ElabState
import Syntax (U(..), Tm, pattern Prop, pattern UVar, type UMax)
import Value
import qualified Syntax as S
import Exceptions


-- Evaluation
--------------------------------------------------------------------------------

vLocalVar :: Env -> Ix -> Val
vLocalVar (EDef _ v)   0 = v
vLocalVar (EDef env _) x = vLocalVar env (x - 1)
vLocalVar _ _            = impossible

vMeta :: Meta -> Val
vMeta x = case runIO (readMeta x) of
  MEUnsolved{} -> Flex (FHMeta x) SNil
  MESolved v   -> Unfold (UHMeta x) SNil v
{-# inline vMeta #-}

vTopDef :: Lvl -> Val
vTopDef x = case runIO (readTop x) of
  TEDef v _ _ _ _ -> Unfold (UHTopDef x) SNil v
  _               -> impossible
{-# inline vTopDef #-}

infixl 2 $$
($$) :: Closure -> Val -> Val
($$) cl ~u = case cl of
  CFun t       -> t u
  CClose env t -> eval (EDef env u) t
{-# inline ($$) #-}

vApp :: Val -> Val -> U -> Icit -> Val
vApp t ~u un i = case t of
  Lam _ _ _ _ t -> t $$ u
  Rigid h sp    -> Rigid  h (SApp sp u un i)
  Flex h sp     -> Flex   h (SApp sp u un i)
  Unfold h sp t -> Unfold h (SApp sp u un i) (vApp t u un i)
  _             -> impossible

vProj1 :: Val -> U -> Val
vProj1 t tu = case t of
  Pair t _ u _  -> t
  Rigid h sp    -> Rigid  h (SProj1 sp tu)
  Flex h sp     -> Flex   h (SProj1 sp tu)
  Unfold h sp t -> Unfold h (SProj1 sp tu) (vProj1 t tu)
  _             -> impossible

vProj2 :: Val -> U -> Val
vProj2 t tu = case t of
  Pair t _ u _  -> u
  Rigid h sp    -> Rigid  h (SProj2 sp tu)
  Flex h sp     -> Flex   h (SProj2 sp tu)
  Unfold h sp t -> Unfold h (SProj2 sp tu) (vProj2 t tu)
  _             -> impossible

vProjField :: Val -> Name -> Int -> U -> Val
vProjField t x n tu = case t of
  Pair t tu u uu -> case n of 0 -> t
                              n -> vProjField u x (n - 1) uu
  Rigid h sp     -> Rigid  h (SProjField sp x n tu)
  Flex h sp      -> Flex   h (SProjField sp x n tu)
  Unfold h sp t  -> Unfold h (SProjField sp x n tu) (vProjField t x n tu)
  _              -> impossible

vCoe :: Val -> Val -> Val -> Val -> Val
vCoe ~a ~b ~p ~t = case (a, b) of
  (topA@(Pi x i a (forceU -> au) b), topB@(Pi x' i' a' (forceU -> au') b'))
    | i /= i'   -> VExfalso Set (Pi x' i' a' au' b') p
    | otherwise -> case convU au au' of
        CUSet     -> Lam (pick x x') i a' Set $ CFun \ ~a1 ->
                     let ~p1 = vProj1 p Prop
                         ~p2 = vProj2 p Prop
                         ~a0 = vCoe a' a (VSym VSet a a' p1) a1
                     in vCoe (b $$ a0) (b' $$ a1) (vApp p2 a0 Set Expl) (vApp t a0 Set i)
        CUProp    -> Lam (pick x x') i a' Prop $ CFun \ ~a1 ->
                     let ~p1 = vProj1 p Prop
                         ~p2 = vProj2 p Prop
                         ~a0 = vCoeP (VSym VProp a a' p1) a1
                     in vCoe (b $$ a0) (b' $$ a1) (vApp p2 a0 Prop Expl) (vApp t a0 Prop i)
        CUDiff    -> VExfalso Set (Pi x' i' a' au' b') p
        CUUMax au -> Flex (FHCoeUMax au topA topB p t) SNil

  (topA@(Sg x a (forceU -> au) b (forceU -> bu)),
   topB@(Sg x' a' (forceU -> au') b' (forceU -> bu'))) ->
    case (convU au au', convU bu bu') of
      (CUSet, CUSet)   -> let ~p1  = vProj1 t Set
                              ~p2  = vProj2 t Set
                              ~p1' = vCoe a a' (vProj1 p Prop) p1
                              ~p2' = vCoe (b $$ p1) (b' $$ p1') (vProj2 p Prop) p2
                          in Pair p1' Set p2' Set
      (CUSet, CUProp)  -> let ~p1  = vProj1 t Set
                              ~p2  = vProj2 t Set
                              ~p1' = vCoe a a' (vProj1 p Prop) p1
                              ~p2' = vCoeP (vProj2 p Prop) p2
                          in Pair p1' Set p2' Prop
      (CUProp, CUSet)  -> let ~p1  = vProj1 t Set
                              ~p2  = vProj2 t Set
                              ~p1' = vCoeP (vProj1 p Prop) p1
                              ~p2' = vCoe (b $$ p1) (b' $$ p1') (vProj2 p Prop) p2
                          in Pair p1' Prop p2' Set
      (CUProp, CUProp) -> impossible
      (CUDiff, _)      -> VExfalso Set topB p
      (_ , CUDiff)     -> VExfalso Set topB p
      (CUUMax au, _)   -> Flex (FHCoeUMax au topA topB p t) SNil
      (_, CUUMax bu)   -> Flex (FHCoeUMax bu topA topB p t) SNil

  (Flex h sp    , b            ) -> Flex h (SCoeSrc sp b p t)
  (Unfold h sp a, b            ) -> Unfold h (SCoeSrc sp b p t) (vCoe a b p t)
  (a            , Flex h sp    ) -> Flex h (SCoeTgt a sp p t)
  (a            , Unfold h sp b) -> Unfold h (SCoeTgt a sp p t) (vCoe a b p t)
  (a            , b            ) -> vCoeComp a b p t

-- | Try to compute coercion composition.
vCoeComp :: Val -> Val -> Val -> Val -> Val
vCoeComp ~a ~b ~p t = case t of
  Flex h sp                     -> Flex h (SCoeComp a b p sp)
  Unfold h sp t                 -> Unfold h (SCoeComp a b p sp) (vCoeComp a b p t)
  Rigid (RHCoe a' _ p' t') SNil -> vCoeRefl a' b (VTrans VSet a' a b p' p) t'
  t                             -> vCoeRefl a b p t

-- | Try to compute reflexive coercion.
vCoeRefl :: Val -> Val -> Val -> Val -> Val
vCoeRefl ~a ~b ~p ~t = case conv undefined a b of
  CSame    -> t
  CDiff    -> Rigid (RHCoe a b p t) SNil
  CMeta x  -> Flex (FHCoeRefl x a b p t) SNil
  CUMax xs -> Flex (FHCoeUMax xs a b p t) SNil

-- | coeP : {A B : Prop} -> A = B -> A -> B
vCoeP :: Val -> Val -> Val
vCoeP p ~t = vApp (vProj1 p Prop) t Prop Expl
{-# inline vCoeP #-}

vEq :: Val -> Val -> Val -> Val
vEq a ~t ~u = case a of
  U un -> case forceU un of
    Set     -> vEqSet t u
    Prop    -> vEqProp t u
    UMax xs -> Flex (FHEqUMax xs a t u) SNil

  -- funext always computes to Expl function
  topA@(Pi x i a au b) -> Eq topA t u $
    Pi x Expl a au $ CFun \ ~x -> vEq (b $$ x) (vApp t x au i) (vApp u x au i)

  -- equality of Prop fields is automatically skipped
  topA@(Sg x a (forceU -> au) b (forceU -> bu)) ->
    let ~p1t = vProj1 t Set
        ~p1u = vProj1 u Set
        ~p2t = vProj2 t Set
        ~p2u = vProj2 u Set in
    case (au, bu) of
      (Set, Prop)  -> vEq a p1t p1u
      (Set, Set )  -> Eq topA t u $
                        PiEP "p" (vEq a p1t p1u) \ ~p ->
                        vEq (b $$ p1u)
                            (vCoe (b $$ p1t) (b $$ p1u)
                                  (VAp a VSet (Lam x Expl a Set b) p1t p1u p) p2t)
                            p2u
      (Prop, Set)  -> vEq (b $$ p1t) p2t p2u
      (Prop, Prop) -> impossible
      (UMax xs, _) -> Flex (FHEqUMax xs topA t u) SNil
      (_, UMax xs) -> Flex (FHEqUMax xs topA t u) SNil

  Rigid  h sp   -> Rigid  h (SEqType sp t u)
  Flex   h sp   -> Flex   h (SEqType sp t u)
  Unfold h sp a -> Unfold h (SEqType sp t u) (vEq a t u)
  _             -> impossible

vEqProp :: Val -> Val -> Val
vEqProp ~a ~b = Eq VProp a b (vAnd (vImpl a b) (vImpl b a))
{-# inline vEqProp #-}

-- | Equality of Set-s.
vEqSet :: Val -> Val -> Val
vEqSet a b = case (a, b) of
  (U (forceU -> u), U (forceU -> u')) -> case convU u u' of
    CUProp     -> Eq VSet (U u) (U u') Top
    CUSet      -> Eq VSet (U u) (U u') Top
    CUDiff     -> Eq VSet (U u) (U u') Bot
    CUUMax xs  -> Flex (FHEqUMax xs VSet (U u) (U u')) SNil

  (topA@(Pi x i a (forceU -> au) b), topB@(Pi x' i' a' (forceU -> au') b')) ->
    let eq = Eq VSet topA topB in
    case convU au au' of
      CUProp      -> eq $ SgPP "p" (vEqProp a a') \ ~p →
                     PiEP (pick x x') a \ ~x -> vEqSet (b $$ x) (b' $$ vCoeP p x)
      CUSet       -> eq $ SgPP "p" (vEqSet a a') \ ~p →
                     PiEP (pick x x') a \ ~x -> vEqSet (b $$ x) (b' $$ vCoe a a' p x)
      CUDiff      -> eq Bot
      CUUMax au   -> Flex (FHEqUMax au VSet topA topB) SNil

  (topA@(Sg x  a  (forceU -> au)  b  (forceU -> bu)),
   topB@(Sg x' a' (forceU -> au') b' (forceU -> bu'))) ->
    let eq = Eq VSet topA topB in
    case (convU au au', convU bu bu') of
      (CUSet,  CUSet )  -> eq $ SgPP "p" (vEqSet a a') \ ~p ->
                           PiEP (pick x x') a \ ~x -> vEqSet (b $$ x) (b' $$ vCoe a a' p x)
      (CUSet,  CUProp)  -> eq $ SgPP "p" (vEqSet a a') \ ~p ->
                           PiEP (pick x x') a \ ~x -> vEqProp (b $$ x) (b' $$ vCoeP p x)
      (CUProp, CUSet )  -> eq $ SgPP "p" (vEqProp a a') \ ~p ->
                           PiEP (pick x x') a \ ~x -> vEqSet (b $$ x) (b' $$ vCoe a a' p x)
      (CUProp, CUProp)  -> impossible
      (CUDiff, _    )   -> eq Bot
      (_    , CUDiff)   -> eq Bot
      (CUUMax au, _)    -> Flex (FHEqUMax au VSet topA topB) SNil
      (_, CUUMax bu)    -> Flex (FHEqUMax bu VSet topA topB) SNil

  (Flex h sp    , b            ) -> Flex h (SEqSetLhs sp b)
  (Unfold h sp a, b            ) -> Unfold h (SEqSetLhs sp b) (vEqSet a b)
  (a            , Flex h sp    ) -> Flex h (SEqSetRhs a sp)
  (a            , Unfold h sp b) -> Unfold h (SEqSetRhs a sp) (vEqSet a b)
  (a            , b            ) -> Eq VSet a b Bot

vAppSp :: Val -> Spine -> Val
vAppSp ~v = go where
  go SNil                    = v
  go (SApp sp t tu i)        = vApp (go sp) t tu i

  go (SProj1 sp spu)         = vProj1 (go sp) spu
  go (SProj2 sp spu)         = vProj2 (go sp) spu
  go (SProjField sp x n spu) = vProjField (go sp) x n spu

  go (SCoeSrc a b p t)       = vCoe (go a) b p t
  go (SCoeTgt a b p t)       = vCoe a (go b) p t
  go (SCoeComp a b p t)      = vCoeComp a b p (go t)

  go (SEqType a t u)         = vEq (go a) t u
  go (SEqSetLhs t u)         = vEqSet (go t) u
  go (SEqSetRhs t u)         = vEqSet t (go u)

eval :: Env -> Tm -> Val
eval ~env = go where
  go = \case
    S.LocalVar x         -> vLocalVar env x
    S.TopDef x           -> vTopDef x
    S.Postulate x        -> Rigid (RHPostulate x) SNil
    S.MetaVar x          -> vMeta x
    S.Let _ _ _ t u      -> eval (EDef env (go t)) u
    S.Pi x i a au b      -> Pi x i (go a) au (CClose env b)
    S.Sg x a au b bu     -> Sg x (go a) au (CClose env b) bu
    S.Lam x i a au t     -> Lam x i (go a) au (CClose env t)
    S.App t u uu i       -> vApp (go t) (go u) uu i
    S.Proj1 t tu         -> vProj1 (go t) tu
    S.Proj2 t tu         -> vProj2 (go t) tu
    S.ProjField t x n tu -> vProjField (go t) x n tu
    S.Pair t tu u uu     -> Pair (go t) tu (go u) uu
    S.U u                -> U u
    S.Top                -> Top
    S.Tt                 -> Tt
    S.Bot                -> Bot
    S.Eq                 -> LamIS "A" VSet \ ~a -> LamES "x" a \ ~x -> LamES "y" a \ ~y ->
                            vEq a x y
    S.Coe                -> LamIS "A" VSet \ ~a -> LamIS "B" VSet \ ~b ->
                            LamEP "p" (vEq VSet a b) \ ~p -> LamES "t" a \ ~t ->
                            vCoe a b p t
    S.Refl               -> LamIS "A" VSet \ ~a -> LamIS "x" a \ ~x -> VRefl a x
    S.Sym                -> LamIS "A" VSet \ ~a -> LamIS "x" a \ ~x ->
                            LamIS "y" a \ ~y -> LamEP "p" (vEq a x y) \ ~p ->
                            VSym a x y p
    S.Trans              -> LamIS "A" VSet \ ~a -> LamIS "x" a \ ~x ->
                            LamIS "y" a \ ~y -> LamIS "z" a \ ~z ->
                            LamEP "p" (vEq a x y) \ ~p -> LamEP "q" (vEq a y z) \ ~q ->
                            VTrans a x y z p q
    S.Ap                 -> LamIS "A" VSet \ ~a -> LamIS "B" VSet \ ~b ->
                            LamES "f" (PiES "_" a (const b)) \ ~f -> LamIS "x" a \ ~x ->
                            LamIS "y" a \ ~y -> LamEP "p" (vEq a x y) \ ~p ->
                            VAp a b f x y p
    S.Exfalso u          -> LamIS "A" (U u) \ ~a -> LamEP "p" Bot \ ~t -> VExfalso u a t

-- Forcing
--------------------------------------------------------------------------------

forceUMax :: UMax -> U
forceUMax xs = IS.foldl' go Prop xs where
  go u x = u <> maybe (UVar (UMeta x)) forceU (runIO (readUMeta (UMeta x)))
  {-# inline go #-}

forceU :: U -> U
forceU = \case
  Set     -> Set
  Prop    -> Prop
  UMax xs -> forceUMax xs

forceFlexHead :: FlexHead -> Spine -> Val
forceFlexHead h sp = case h of
  FHMeta x -> case runIO (readMeta x) of
    MESolved v -> force (vAppSp v sp)
    _          -> Flex (FHMeta x) sp
  FHCoeRefl x a b p t -> case runIO (readMeta x) of
    MESolved v -> force (vCoeRefl a b p t)
    _          -> Flex (FHCoeRefl x a b p t) sp
  FHCoeUMax xs a b p t -> case forceUMax xs of
    Set     -> force (vAppSp (vCoe a b p t) sp)
    Prop    -> force (vAppSp (vCoe a b p t) sp)
    UMax xs -> Flex (FHCoeUMax xs a b p t) sp
  FHEqUMax xs a t u -> case forceUMax xs of
    Set     -> force (vAppSp (vEq a t u) sp)
    Prop    -> force (vAppSp (vEq a t u) sp)
    UMax xs -> Flex (FHEqUMax xs a t u) sp

-- | Force everything.
force :: Val -> Val
force = \case
  Flex h sp    -> forceFlexHead h sp
  Unfold _ _ v -> force v
  Eq _ _ _ v   -> force v
  v            -> v

-- Conversion checks
--------------------------------------------------------------------------------

envLvl :: Env -> Lvl
envLvl = go 0 where
  go acc ENil         = acc
  go acc (EDef env _) = go (acc + 1) env

data ConvU = CUProp | CUSet | CUDiff | CUUMax IS.IntSet

-- | We don't care about equal UMax-es, because we can't compute anyway on unknown universes.
convU :: U -> U -> ConvU
convU ~u ~u' = case (u, u') of
  (Set      , Set     ) -> CUSet
  (Prop     , Prop    ) -> CUProp
  (Set      , Prop    ) -> CUDiff
  (Prop     , Set     ) -> CUDiff
  (UMax xs  , _       ) -> CUUMax xs
  (_        , UMax xs ) -> CUUMax xs

conv :: Env -> Val -> Val -> Conv
conv env t u = runIO ((CSame <$ convIO (envLvl env) Set t u) `catch` pure)
{-# inline conv #-}

convIO :: Lvl -> U -> Val -> Val -> IO ()
convIO l un t u = go un t u where
  go :: U -> Val -> Val -> IO ()
  go un t u = undefined
