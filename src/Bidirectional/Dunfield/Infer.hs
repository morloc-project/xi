module Bidirectional.Dunfield.Infer ( infer ) where

import Bidirectional.Dunfield.Data
import Bidirectional.Dunfield.Parser
import Control.Applicative ((<|>))

-- | substitute all appearances of a given variable with an existential
-- [t/v]A
substitute :: TVar -> Type -> Type
substitute v t@(VarT v')
  | v == v' = ExistT v
  | otherwise = t
substitute v (FunT t1 t2) = FunT (substitute v t1) (substitute v t2)
substitute v t@(Forall x t')
  | v /= x = Forall x (substitute v t')
  | otherwise = t -- allows shadowing of the variable
substitute _ t = t


-- | Apply a context to a type (See Dunfield Figure 8).
apply :: Gamma -> Type -> Type
-- [G]l = l
apply _ UniT = UniT
-- [G]a = a
apply _ a@(VarT v) = a
-- [G](A->B) = ([G]A -> [G]B)
apply g (FunT a b) = FunT (apply g a) (apply g b)
-- [G]Forall a.a = forall a. [G]a
apply g (Forall x a) = Forall x (apply g a)
-- [G[a=t]]a = [G[a=t]]t
apply g a@(ExistT v) = case lookupT v g of
  (Just t') -> apply g t' -- reduce an existential; strictly smaller term
  Nothing -> a


-- | Ensure a given type variable is not free within a given type
occursCheck :: Type -> TVar -> Stack TVar
occursCheck UniT v = return v
occursCheck (VarT v') v 
  | v' == v = throwError OccursCheckFail
  | otherwise = return v
occursCheck (FunT t1 t2) v = do
  occursCheck t1 v
  occursCheck t2 v
occursCheck (Forall v' t) v
  | v' == v = return v -- variable is bound, we are done
  | otherwise = occursCheck t v -- else recurse
occursCheck (ExistT v') v
  | v' == v = throwError OccursCheckFail -- existentials count
  | otherwise = return v'


-- | type 1 is more polymorphic than type 2 (Dunfield Figure 9)
subtype :: Type -> Type -> Gamma -> Stack Gamma
--
-- ----------------------------------------- Unit
--  G |- 1 <: 1 -| G
subtype UniT UniT g = return g
--
-- ----------------------------------------- <:Var
--  G[a] |- a <: a -| G[a]
subtype (VarT a1) (VarT a2) g
  | a1 == a2 = return g -- reflexivity
  | otherwise = throwError SubtypeError
--
-- ----------------------------------------- <:Exvar
--  G[E.a] |- Ea <: Ea -| G[E.a]
subtype (ExistT a1) (ExistT a2) g
  | a1 == a2 = return g
  | otherwise = throwError SubtypeError -- subtyping of unequal existentials?
--  g1 |- A1 <: B1 -| g2
--  g2 |- [g2]A2 <: [g2]B2 -| g3
-- ----------------------------------------- <:-->
--  g1 |- A1 -> A2 <: B1 -> B2 -| g3
subtype (FunT a1 a2) (FunT b1 b2) g1  = do
  g2 <- subtype a1 b1 g1
  subtype (apply g2 a2) (apply g2 b2) g2
--  g1,>Ea,Ea |- [Ea/x]A <: B -| g2,>Ea,g3
-- ----------------------------------------- <:ForallL
--  g1 |- Forall x . A <: B -| g2
subtype (Forall x a) b g =
  subtype (substitute x a) b (g +> MarkG x +> ExistG x) >>= cut (MarkG x)
--  g1,a |- A :> B -| g2,a,g3
-- ----------------------------------------- <:ForallR
--  g1 |- A <: Forall a. B -| g2
subtype a t@(Forall v b) g = subtype a b (g +> VarG v) >>= cut (VarG v)
--  Ea not in FV(a)
--  g1[Ea] |- Ea <=: A -| g2
-- ----------------------------------------- <:InstantiateL
--  g1[Ea] |- Ea <: A -| g2
subtype a@(ExistT v) b g = do
  occursCheck b v
  instantiate a b g 
--  Ea not in FV(a)
--  g1[Ea] |- A <=: Ea -| g2
-- ----------------------------------------- <:InstantiateR
--  g1[Ea] |- A <: Ea -| g2
subtype a b@(ExistT v) g = do
  occursCheck a v
  instantiate a b g 


-- | Dunfield Figure 10 -- type-level structural recursion
instantiate :: Type -> Type -> Gamma -> Stack Gamma

-- ==== Left rules: Ea <: B ===================================================
--  g1 |- t
-- ----------------------------------------- instLSolve
--  g1,Ea,g2 |- Ea <=: t -| g1,Ea=t,g2
instantiate ea@(ExistT v) b@(VarT _) g = accessWith (const (SolvedG v b)) ea g
--  g1[Ea2, Ea1, Ea=Ea1->Ea2] |- A1 <=: Ea1 -| g2
--  g2 |- Ea2 <=: [g2]A2 -| g3
-- ----------------------------------------- InstLArr
--  g1[Ea] |- Ea <=: A1 -> A2 -| g3
instantiate (ExistT v) (FunT t1 t2) g1 = do
  ea1 <- newvar
  ea2 <- newvar
  g2 <- instantiate t1 ea1 (g1 +> ea2 +> ea1 +> SolvedG v (FunT ea1 ea2))
  g3 <- instantiate ea2 (apply g2 t2) g2
  return g3
--
-- ----------------------------------------- InstLAllR
--
instantiate a@(ExistT _) (Forall v2 t2) g =
  instantiate a t2 (g +> VarG v2) >>= cut (VarG v2)

-- ==== Symmetric rule: Ea <: Eb ==============================================
-- InstLReach or instRReach -- each rule eliminates an existential
-- Replace the rightmost with leftmost (G[a][b] --> L,a,M,b=a,R)
instantiate a@(ExistT v1) b@(ExistT v2) g =
  case access2 a b g of
    -- InstLReach
    (Just (ls, x, ms, _, rs)) -> return $ ls <> (x:ms) <> (SolvedG v2 a:rs)
    Nothing -> case access2 b a g of
      -- InstRReach
      (Just (ls, x, ms, _, rs)) -> return $ ls <> (x:ms) <> (SolvedG v1 b:rs)
      Nothing -> throwError UnknownError

-- ==== Right rules: A <: Eb ==================================================
--  g1 |- t
-- ----------------------------------------- InstRSolve
--  g1,Ea,g2 |- t <=: Ea -| g1,Ea=t,g2
instantiate a@(VarT t) b@(ExistT v) g = accessWith (const (SolvedG v a)) b g
--  g1[Ea2,Ea1,Ea=Ea1->Ea2] |- Ea1 <=: A1 -| g2
--  g2 |- [g2]A2 <=: Ea2 -| g3
-- ----------------------------------------- InstRArr
--  g1[Ea] |- A1 -> A2 <=: Ea -| g3
instantiate (FunT t1 t2) (ExistT v) g1 = do
  ea1 <- newvar
  ea2 <- newvar
  g2 <- instantiate ea1 t1 $ g1 +> ea2 +> ea1 +> SolvedG v (FunT ea1 ea2)
  g3 <- instantiate (apply g2 t2) ea2 g2
  return g3
--  g1[Ea],>Eb,Eb |- [Eb/x]B <=: Ea -| g2,>Eb,g3
-- ----------------------------------------- InstRAllL
--  g1[Ea] |- Forall x. B <=: Ea -| g2
instantiate (Forall x b) ea@(ExistT _) g
  = instantiate
      (substitute x b)             -- [Eb/x]B
      ea                           -- Ea
      (g +> MarkG x +> ExistG x)   -- g1[Ea],>Eb,Eb
  >>= cut (MarkG x)


infer :: Gamma -> Expr -> Stack (Gamma, Type)
--
-- ----------------------------------------- 1l=>
--  g |- () => 1 -| g
infer g UniE = return (g, UniT) 
--  (x:A) in g
-- ----------------------------------------- Var
--  g |- x => A -| g
infer g e@(VarE v) = case lookupE e g of
  (Just t) -> return (g, t)
  Nothing  -> throwError UnboundVariable
--  g1,Ea,Eb,x:Ea |- e <= Eb -| g2,x:Ea,g3
-- ----------------------------------------- -->I=>
--  g1 |- \x.e => Ea -> Eb
infer g1 e@(LamE v e2) = do
  a <- newvar
  b <- newvar
  let ann = AnnG (VarE v) a
  (g'', t) <- check (g1 +> a +> b +> ann) b e
  g2 <- cut ann g''
  return (g2, t)
--  g1 |- e1 => A -| g2
--  g2 |- [g2]A o e2 =>> C -| g3
-- ----------------------------------------- -->E
--  g1 |- e1 e2 => C -| g3
infer g1 (AppE e1 e2) = do
  (g2, a) <- infer g1 e1
  derive g2 e2 (apply g2 a)
--  g1 |- A
--  g1 |- e <= A -| g2
-- ----------------------------------------- Anno
--  g1 |- (e:A) => A -| g2
infer g (AnnE e t) = check g t e


-- | Pattern matches against each type
check :: Gamma -> Type -> Expr -> Stack (Gamma, Type)
--
-- ----------------------------------------- 1l
--  g |- () <= 1 -| g
check g UniT UniE = return (g, UniT)
--  g1 |- e => A -| g2
--  g2 |- [g2]A <: [g2]B -| g3
-- ----------------------------------------- Sub
--  g1 |- e <= B -| g3
check g1 b@(VarT v) e = do
  (g2, a) <- infer g1 e
  g3 <- subtype (apply g2 a) (apply g2 b) g2
  case lookupT v g3 of
    (Just t) -> return (g3, t)
    Nothing -> throwError UnknownError
--  g1,x:A |- e <= B -| g2,x:A,g3
-- ----------------------------------------- -->I
--  g1 |- \x.e <= A -> B -| g2
check g (FunT a b) (LamE v e) = do
  -- define x:A
  let ann = AnnG (VarE v) a
  -- check that e has the expected output type
  (g', t') <- check (g +> ann) b e
  -- ignore the trailing context and (x:A), since it is out of scope
  g2 <- cut ann g'
  return (g2, t')
--  g1,x |- e <= A -| g2,x,g3
-- ----------------------------------------- Forall.I
--  g1 |- e <= Forall x.A -| g2
check g1 (Forall x a) e = do
  (g', t') <- check (g1 +> VarG x) a e
  g2 <- cut (VarG x) g'
  return (g2, t')


derive :: Gamma -> Expr -> Type -> Stack (Gamma, Type)
--  g1 |- e <= A -| g2
-- ----------------------------------------- -->App
--  g1 |- A->C o e =>> C -| g2
derive g e (FunT a b) = check g a e
--  g1,Ea |- [Ea/a]A o e =>> C -| g2
-- ----------------------------------------- Forall App
--  g1 |- Forall x.A o e =>> C -| g2
derive g e (Forall x t) = do
  derive (g +> ExistG x) e (substitute x t)
--  g1[Ea2, Ea1, Ea=Ea1->Ea2] |- e <= Ea1 -| g2
-- ----------------------------------------- EaApp
--  g1[Ea] |- Ea o e =>> Ea2 -| g2
derive g e (ExistT v) = do
  a <- newvar
  b <- newvar
  let g' = g +> a +> b +> SolvedG v (FunT a b)
  check g' a e
derive _ _ _ = throwError NonFunctionDerive
