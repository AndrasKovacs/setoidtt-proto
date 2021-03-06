
module Syntax where

import IO
import Data.Bits
import qualified Data.IntSet.Internal as IS

import Common

--------------------------------------------------------------------------------

type UMax = IS.IntSet

forUMax :: UMax -> (UMetaVar -> IO ()) -> IO ()
forUMax us f =
  let go :: RW -> Int -> RW
      go (RW s) (UMetaVar -> x) = case unIO (f x) s of (# s , _ #) -> RW s
  in IO \s -> case IS.foldl' go (RW s) us of
                RW s -> (# s , () #)
{-# inline forUMax #-}

--------------------------------------------------------------------------------

type U = S WU
data U2 = U2 U U
data WU
  = WSet
  | WProp
  | WMax UMax   -- ^ Maximum of a non-empty set of universe metas.
  deriving (Eq, Show)
pattern Set    = S WSet
pattern Prop   = S WProp
pattern Max xs = S (WMax xs)
{-# complete Set, Prop, Max #-}

instance Semigroup U where
  u <> u' = case u of
    Set     -> Set
    Prop    -> u'
    Max xs -> case u' of
      Set      -> Set
      Prop     -> Max xs
      Max xs' -> Max (xs <> xs')
  {-# inline (<>) #-}

instance Monoid U where
  mempty = Prop
  {-# inline mempty #-}

matchSingleton :: UMax -> Maybe UMetaVar
matchSingleton xs = case xs of
  IS.Tip pref mask | popCount mask == 1 ->
    Just $! UMetaVar $! pref + countTrailingZeros mask
  _ ->
    Nothing
{-# inline matchSingleton #-}

pattern UVar :: UMetaVar -> U
pattern UVar x <- ((\case Max xs -> matchSingleton xs; _ -> Nothing) -> Just x) where
  UVar (UMetaVar x) = Max (IS.singleton x)

type Locals = S WLocals
data WLocals
  = WEmpty
  | WDefine Locals Name Tm Ty U
  | WBind Locals Name Ty U
  deriving Show

pattern Empty = S WEmpty
pattern Define ls x t a u = S (WDefine ls x t a u)
pattern Bind ls x a u     = S (WBind ls x a u)
{-# complete Empty, Define, Bind #-}

type Ty = Tm
type Tm = S WTm
type WTy = WTm

data WTm
  = WLocalVar Ix
  | WTopDef Lvl

  -- Note: we bring term constructors to the front because the first 6 consructors
  -- are dispatched on pointer tags, and the rest on info table, so we want
  -- the first 6 constructors to be the most commonly occurring.
  | WLam Name Icit Ty U Tm    -- ^ λ(x : A : U).t  or  λ{x : A : U}.t
  | WApp Tm Tm U Icit         -- ^ t u  or  t {u}, last Ty is u's universe

  | WPair Tm U Tm U
  | WProjField Tm Name Int
  | WProj1 Tm
  | WProj2 Tm

  | WPi Name Icit Ty U Ty     -- ^ (x : A : U) → B)  or  {x : A : U} → B
  | WSg Name Ty U Ty U

  | WPostulate Lvl
  | WInsertedMeta MetaVar Locals
  | WMeta MetaVar
  | WLet Name Ty U Tm Tm

  | WU U                      -- ^ U u : Set
  | WTop                      -- ^ Top : Prop
  | WTt                       -- ^ Tt  : Top
  | WBot                      -- ^ Bot : Prop
  | WEq Ty Tm Tm              -- ^ {A : Set} → A → A → Prop
  | WCoe Ty Ty Tm Tm          -- ^ {A B : Set} → Eq {Set} A B → A → B
  | WRefl Ty Tm               -- ^ {A : Set}(x : A) → Eq x x
  | WSym Ty Tm Tm Tm          -- ^ {A : Set}{x y : A} → Eq x y → Eq y x
  | WTrans Ty Tm Tm Tm Tm Tm  -- ^ {A : Set}{x y z : A} → Eq x y → Eq y z → Eq x z
  | WAp Ty Ty Tm Tm Tm Tm     -- ^ {A B : Set}(f : A → B){x y : A} → Eq x y → Eq (f x) (f y)
  | WExfalso U Ty Tm          -- ^ {A : U i} → Bot → A
  deriving Show

pattern LocalVar x        = S (WLocalVar x)
pattern TopDef x          = S (WTopDef x)
pattern Postulate x       = S (WPostulate x)
pattern Meta x            = S (WMeta x)
pattern InsertedMeta m ls = S (WInsertedMeta m ls)
pattern Let x a au t u    = S (WLet x a au t u )
pattern Pi x i a au b     = S (WPi x i a au b)
pattern Lam x i a au t    = S (WLam x i a au t)
pattern App t u uu i      = S (WApp t u uu i)
pattern Sg x a au b bu    = S (WSg x a au b bu )
pattern Proj1 t           = S (WProj1 t)
pattern Proj2 t           = S (WProj2 t)
pattern ProjField t x n   = S (WProjField t x n)
pattern Pair t tu u uu    = S (WPair t tu u uu)
pattern U u               = S (WU u)
pattern Top               = S (WTop)
pattern Tt                = S (WTt)
pattern Bot               = S (WBot)
pattern Eq a t u          = S (WEq a t u )
pattern Coe a b p t       = S (WCoe a b p t)
pattern Refl a t          = S (WRefl a t )
pattern Sym a t u p       = S (WSym a t u p)
pattern Trans a t u v p q = S (WTrans a t u v p q)
pattern Ap a b f t u p    = S (WAp a b f t u p)
pattern Exfalso u a t     = S (WExfalso u a t)

{-# complete
  LocalVar, TopDef, Postulate, Meta, Let, Pi, Lam, App, Sg, Proj1, InsertedMeta,
  Proj2, ProjField, Pair, U, Top, Tt, Bot, Eq, Coe, Refl, Sym, Trans, Ap, Exfalso #-}
