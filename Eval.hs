{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
module Eval where

import Debug.Trace
import Control.Monad
import Data.List
import Data.Monoid ((<>), mempty)
import Data.Maybe (fromMaybe)
import Data.Map (Map,(!),mapWithKey,assocs,filterWithKey
                ,elems,intersectionWith,intersection,keys
                ,member,notMember,empty)
import qualified Data.Map as Map

import Connections
import CTT

-----------------------------------------------------------------------
-- Lookup functions

look :: String -> Env -> Val
look x (Upd y rho,v:vs,fs,ws) | x == y = v
                              | otherwise = look x (rho,vs,fs,ws)
look x r@(Def decls rho,vs,fs,ws) = case lookup x decls of
  Just (_,t) -> eval r t
  Nothing    -> look x (rho,vs,fs,ws)
look x r@(DelDef ds rho,vs,fs,ws) = case lookup x (map (\(DelBind x) -> x) ds) of
  Just (_,v) -> Ter (Var x) r
  Nothing    -> look x (rho,vs,fs,ws)
look x (Sub _ rho,vs,_:fs,ws) = look x (rho,vs,fs,ws)
look x r@(DelUpd y rho,vs,fs,w:ws) | x == y = Ter (Var y) r
                                   | otherwise  = look x (rho,vs,fs,ws)
look x _ = error $ "look: not found " ++ show x

lookDel :: String -> Env -> Either Val Val
lookDel x (Upd y rho,v:vs,fs,ws) | x == y = Left v
                                 | otherwise = lookDel x (rho,vs,fs,ws)
lookDel x r@(Def decls rho,vs,fs,ws) = case lookup x decls of
  Just (_,t) -> Left (eval r t)
  Nothing    -> lookDel x (rho,vs,fs,ws)
lookDel x r@(DelDef ds rho,vs,fs,ws) = case lookup x (map (\(DelBind x) -> x) ds) of
  Just (_,v) -> Right v
  Nothing    -> lookDel x (rho,vs,fs,ws)
lookDel x (Sub _ rho,vs,_:fs,ws) = lookDel x (rho,vs,fs,ws)
lookDel x (DelUpd y rho,vs,fs,w:ws) | x == y = Right w
                                    | otherwise  = lookDel x (rho,vs,fs,ws)

lookType :: String -> Env -> Val
lookType x (Upd y rho,VVar _ a:vs,fs,ws)
  | x == y    = a
  | otherwise = lookType x (rho,vs,fs,ws)
lookType x r@(Def decls rho,vs,fs,ws) = case lookup x decls of
  Just (a,_) -> eval r a
  Nothing -> lookType x (rho,vs,fs,ws)
lookType x r@(DelDef ds rho,vs,fs,ws) = case lookup x (map (\(DelBind x) -> x) ds) of
  Just (a,_) -> a
  Nothing -> lookType x (rho,vs,fs,ws)
lookType x (Sub _ rho,vs,_:fs,ws) = lookType x (rho,vs,fs,ws)
lookType x (DelUpd y rho,vs,fs,VVar _ a:ws) -- correct?
  | x == y    = a
  | otherwise = lookType x (rho,vs,fs,ws)
lookType x _                   = error $ "lookType: not found " ++ show x


lookName :: Name -> Env -> Formula
-- lookName i Empty       = error $ "lookName: not found " ++ show i
lookName i (Upd _ rho,v:vs,fs,ws)    = lookName i (rho,vs,fs,ws)
lookName i (DelUpd _ rho,vs,fs,w:ws) = lookName i (rho,vs,fs,ws)
lookName i (Def _ rho,vs,fs,ws)      = lookName i (rho,vs,fs,ws)
lookName i (DelDef _ rho,vs,fs,ws)      = lookName i (rho,vs,fs,ws)
lookName i (Sub j rho,vs,phi:fs,ws) | i == j    = phi
                                    | otherwise = lookName i (rho,vs,fs,ws)
lookName i _ = error $ "lookName: not found " ++ show i

todo = True

-----------------------------------------------------------------------
-- Nominal instances

instance Nominal Ctxt where
  support _ = []
  act e _   = e
  swap e _  = e

instance Nominal Val where
  support v = case v of
    VU                      -> []
    Ter _ e                 -> support e
    VPi u v                 -> support [u,v]
    VComp a u ts            -> support (a,u,ts)
    VIdP a v0 v1            -> support [a,v0,v1]
    VPath i v               -> i `delete` support v
    VSigma u v              -> support (u,v)
    VPair u v               -> support (u,v)
    VFst u                  -> support u
    VSnd u                  -> support u
    VCon _ vs               -> support vs
    VPCon _ a vs phis       -> support (a,vs,phis)
    VHComp a u ts           -> support (a,u,ts)
    VVar _ v                -> support v
    VApp u v                -> support (u,v)
    VLam _ u v              -> support (u,v)
    VAppFormula u phi       -> support (u,phi)
    VSplit u v              -> support (u,v)
    VGlue a ts              -> support (a,ts)
    VGlueElem a ts          -> support (a,ts)
    VUnGlueElem a b hs      -> support (a,b,hs)
    -- VLater _ e -> support e
    VLater v -> support v
    -- VNext _ e -> support e
    VNext v -> support v
    VFix a v -> support (a,v)

  act u (i, phi) | i `notElem` support u = u
                 | otherwise =
    let acti :: Nominal a => a -> a
        acti u = act u (i, phi)
        sphi = support phi
    in case u of
         VU           -> VU
         Ter t e      -> Ter t (acti e)
         VPi a f      -> VPi (acti a) (acti f)
         VComp a v ts -> compLine (acti a) (acti v) (acti ts)
         VIdP a u v   -> VIdP (acti a) (acti u) (acti v)
         VPath j v | j == i -> u
                   | j `notElem` sphi -> VPath j (acti v)
                   | otherwise -> VPath k (acti (v `swap` (j,k)))
              where k = fresh (v,Atom i,phi)
         VSigma a f              -> VSigma (acti a) (acti f)
         VPair u v               -> VPair (acti u) (acti v)
         VFst u                  -> fstVal (acti u)
         VSnd u                  -> sndVal (acti u)
         VCon c vs               -> VCon c (acti vs)
         VPCon c a vs phis       -> pcon c (acti a) (acti vs) (acti phis)
         VHComp a u us           -> hComp (acti a) (acti u) (acti us)
         VVar x v                -> VVar x (acti v)
         VAppFormula u psi       -> acti u @@ acti psi
         VApp u v                -> app (acti u) (acti v)
         VLam x t u              -> VLam x (acti t) (acti u)
         VSplit u v              -> app (acti u) (acti v)
         VGlue a ts              -> glue (acti a) (acti ts)
         VGlueElem a ts          -> glueElem (acti a) (acti ts)
         VUnGlueElem a b hs      -> unGlue (acti a) (acti b) (acti hs)
         -- VLater a e -> VLater a (acti e)
         VLater v -> VLater (acti v)
         -- VNext t e -> VNext t (acti e)
         VNext v -> VNext (acti v)

  -- This increases efficiency as it won't trigger computation.
  swap u ij@(i,j) =
    let sw :: Nominal a => a -> a
        sw u = swap u ij
    in case u of
         VU                      -> VU
         Ter t e                 -> Ter t (sw e)
         VPi a f                 -> VPi (sw a) (sw f)
         VComp a v ts            -> VComp (sw a) (sw v) (sw ts)
         VIdP a u v              -> VIdP (sw a) (sw u) (sw v)
         VPath k v               -> VPath (swapName k ij) (sw v)
         VSigma a f              -> VSigma (sw a) (sw f)
         VPair u v               -> VPair (sw u) (sw v)
         VFst u                  -> VFst (sw u)
         VSnd u                  -> VSnd (sw u)
         VCon c vs               -> VCon c (sw vs)
         VPCon c a vs phis       -> VPCon c (sw a) (sw vs) (sw phis)
         VHComp a u us           -> VHComp (sw a) (sw u) (sw us)
         VVar x v                -> VVar x (sw v)
         VAppFormula u psi       -> VAppFormula (sw u) (sw psi)
         VApp u v                -> VApp (sw u) (sw v)
         VLam x u v              -> VLam x (sw u) (sw v)
         VSplit u v              -> VSplit (sw u) (sw v)
         VGlue a ts              -> VGlue (sw a) (sw ts)
         VGlueElem a ts          -> VGlueElem (sw a) (sw ts)
         VUnGlueElem a b hs      -> VUnGlueElem (sw a) (sw b) (sw hs)
         VLater v                -> VLater (sw v)
         VNext v                 -> VNext (sw v)
         VFix a v                -> VFix (sw a) (sw v)
         v -> error $ "swap:\n" ++ show v ++ "\n not handled"

instance Nominal Ter where
-----------------------------------------------------------------------
-- The evaluator

eval :: Env -> Ter -> Val
eval rho v = case v of
  U                   -> VU
  App r s             -> app (eval rho r) (eval rho s)
  Var i               -> look i rho
  Pi t@(Lam _ a _)    -> VPi (eval rho a) (eval rho t)
  Sigma t@(Lam _ a _) -> VSigma (eval rho a) (eval rho t)
  Pair x y            -> VPair (eval rho x) (eval rho y)
  Fst a               -> fstVal (eval rho a)
  Snd a               -> sndVal (eval rho a)
  Where t decls       -> eval (def decls rho) t
  Con name ts         -> VCon name (map (eval rho) ts)
  PCon name a ts phis  ->
    pcon name (eval rho a) (map (eval rho) ts) (map (evalFormula rho) phis)
  Lam{}               -> Ter v rho
  Split{}             -> Ter v rho
  Sum{}               -> Ter v rho
  HSum{}              -> Ter v rho
  Undef{}             -> Ter v rho
  Hole{}              -> Ter v rho
  IdP a e0 e1         -> VIdP (eval rho a) (eval rho e0) (eval rho e1)
  Path i t            -> let j = fresh rho
                         in VPath j (eval (sub (i,Atom j) rho) t)
  AppFormula e phi    -> eval rho e @@ evalFormula rho phi
  Comp a t0 ts        ->
    compLine (eval rho a) (eval rho t0) (evalSystem rho ts)
  Fill a t0 ts        ->
    fillLine (eval rho a) (eval rho t0) (evalSystem rho ts)
  Glue a ts           -> glue (eval rho a) (evalSystem rho ts)
  GlueElem a ts       -> glueElem (eval rho a) (evalSystem rho ts)
  Later xi t          -> VLater (Ter t (pushDelSubst (evalDelSubst rho xi) rho))
  Next xi t           -> VNext  (Ter t (pushDelSubst (evalDelSubst rho xi) rho))
  Fix a t             -> app (eval rho t) (VNext (Ter (Fix a t) rho))
  _                   -> error $ "Cannot evaluate " ++ show v

evalDelSubst :: Env -> DelSubst -> VDelSubst
evalDelSubst rho ds = case ds of
  []                        -> []
  (DelBind (f,(a,t)):ds')   -> DelBind (f, (eval rho a, eval rho t))
                                 : evalDelSubst rho ds'

pushDelSubst :: VDelSubst -> Env -> Env
pushDelSubst [] rho = rho
pushDelSubst (DelBind (f,(_va,vt)) : ds) rho =
  case vt of
   -- VNext t' rho' -> upd    (f,eval rho' t') (pushDelSubst ds rho)
   VNext v       -> upd (f, v) (pushDelSubst ds rho) -- v has been evalDel'd not eval'd
   _             -> delUpd (f,vt)           (pushDelSubst ds rho)


unfoldOneFix :: Val -> Val
unfoldOneFix (VFix a v) = app v (VNext (VFix a v))
unfoldOneFix (VLater v) = VLater (unfoldOneFix v)
unfoldOneFix (VIdP v1 v2 v3) = VIdP (unfoldOneFix v1) (unfoldOneFix v2) (unfoldOneFix v3)
unfoldOneFix (VPath n v) = VPath n (unfoldOneFix v)
unfoldOneFix v = v -- TODO: rest of this pattern matching

evals :: Env -> [(Ident,Ter)] -> [(Ident,Val)]
evals env bts = [ (b,eval env t) | (b,t) <- bts ]

evalFormula :: Env -> Formula -> Formula
evalFormula rho phi = case phi of
  Atom i         -> lookName i rho
  NegAtom i      -> negFormula (lookName i rho)
  phi1 :/\: phi2 -> evalFormula rho phi1 `andFormula` evalFormula rho phi2
  phi1 :\/: phi2 -> evalFormula rho phi1 `orFormula` evalFormula rho phi2
  _              -> phi

evalSystem :: Env -> System Ter -> System Val
evalSystem rho ts =
  let out = concat [ let betas = meetss [ invFormula (lookName i rho) d
                                        | (i,d) <- assocs alpha ]
                     in [ (beta,eval (rho `face` beta) talpha) | beta <- betas ]
                   | (alpha,talpha) <- assocs ts ]
  in mkSystem out

app :: Val -> Val -> Val
app u v = case (u,v) of -- trace ("app: " ++ show u ++ " $ " ++ show v) $ case (u,v) of
--  (VLam _ _ b,_)                      -> b -- assuming b is closed
  (Ter (Lam x _ t) e,_)               -> eval (upd (x,v) e) t
  (Ter (Split _ _ _ nvs) e,VCon c vs) -> case lookupBranch c nvs of
    Just (OBranch _ xs t) -> eval (upds (zip xs vs) e) t
    _     -> error $ "app: missing case in split for " ++ c
  (Ter (Split _ _ _ nvs) e,VPCon c _ us phis) -> case lookupBranch c nvs of
    Just (PBranch _ xs is t) -> eval (subs (zip is phis) (upds (zip xs us) e)) t
    _ -> error $ "app: missing case in split for " ++ c
  (Ter (Split _ _ ty hbr) e,VHComp a w ws) -> case eval e ty of
    VPi _ f -> let j   = fresh (e,v)
                   wsj = Map.map (@@ j) ws
                   w'  = app u w
                   ws' = mapWithKey (\alpha -> app (u `face` alpha)) wsj
                   -- a should be constant
               in comp j (app f (fill j a w wsj)) w' ws'
    _ -> error $ "app: Split annotation not a Pi type " ++ show u
  (Ter Split{} _,_) | isNeutral v         -> VSplit u v
  (VComp (VPath i (VPi a f)) li0 ts,vi1) ->
    let j   = fresh (u,vi1)
        (aj,fj) = (a,f) `swap` (i,j)
        tsj = Map.map (@@ j) ts
        v       = transFillNeg j aj vi1
        vi0     = transNeg j aj vi1
    in comp j (app fj v) (app li0 vi0)
              (intersectionWith app tsj (border v tsj))
  _ | isNeutral u       -> VApp u v
  _                     -> error $ "app \n  " ++ show u ++ "\n  " ++ show v

fstVal, sndVal :: Val -> Val
fstVal (VPair a b)     = a
fstVal u | isNeutral u = VFst u
fstVal u               = error $ "fstVal: " ++ show u ++ " is not neutral."
sndVal (VPair a b)     = b
sndVal u | isNeutral u = VSnd u
sndVal u               = error $ "sndVal: " ++ show u ++ " is not neutral."

-- infer the type of a neutral value
inferType :: Val -> Val
inferType v = case v of
  VVar _ t -> t
  Ter (Undef _ t) rho -> eval rho t
  VFst t -> case inferType t of
    VSigma a _ -> a
    ty         -> error $ "inferType: expected Sigma type for " ++ show v
                  ++ ", got " ++ show ty
  VSnd t -> case inferType t of
    VSigma _ f -> app f (VFst t)
    ty         -> error $ "inferType: expected Sigma type for " ++ show v
                  ++ ", got " ++ show ty
  VSplit s@(Ter (Split _ _ t _) rho) v1 -> case eval rho t of
    VPi _ f -> app f v1
    ty      -> error $ "inferType: Pi type expected for split annotation in "
               ++ show v ++ ", got " ++ show ty
  VApp t0 t1 -> case inferType t0 of
    VPi _ f -> app f t1
    ty      -> error $ "inferType: expected Pi type for " ++ show v
               ++ ", got " ++ show ty
  VAppFormula t phi -> case inferType t of
    VIdP a _ _ -> a @@ phi
    ty         -> error $ "inferType: expected IdP type for " ++ show v
                  ++ ", got " ++ show ty
  VComp a _ _ -> a @@ One
  VUnGlueElem _ b _  -> b
  Ter (Var x) rho -> case lookDel x rho of
                       Left v  -> inferType v
                       Right v -> case inferType v of
                                    VLater w -> w
                                    w -> error $ "inferType: not a later: \n" ++ show w
  _ -> error $ "inferType: not neutral " ++ show v

(@@) :: ToFormula a => Val -> a -> Val
(VPath i u) @@ phi         = u `act` (i,toFormula phi)
v@(Ter Hole{} _) @@ phi    = VAppFormula v (toFormula phi)
v @@ phi | isNeutral v     = case (inferType v,toFormula phi) of
  (VIdP  _ a0 _,Dir 0) -> a0
  (VIdP  _ _ a1,Dir 1) -> a1
  _                    -> VAppFormula v (toFormula phi)
v @@ phi                   = error $ "(@@): " ++ show v ++ " should be neutral."


-------------------------------------------------------------------------------
-- Composition and filling

comp :: Name -> Val -> Val -> System Val -> Val
comp i a u ts | eps `member` ts = (ts ! eps) `face` (i ~> 1)
comp i a u ts = case a of
  VIdP p v0 v1 -> let j = fresh (Atom i,a,u,ts)
                  in VPath j $ comp i (p @@ j) (u @@ j) $
                       insertsSystem [(j ~> 0,v0),(j ~> 1,v1)] (Map.map (@@ j) ts)
  VSigma a f -> VPair ui1 comp_u2
    where (t1s, t2s) = (Map.map fstVal ts, Map.map sndVal ts)
          (u1,  u2)  = (fstVal u, sndVal u)
          fill_u1    = fill i a u1 t1s
          ui1        = comp i a u1 t1s
          comp_u2    = comp i (app f fill_u1) u2 t2s
  VPi{} -> VComp (VPath i a) u (Map.map (VPath i) ts)
  VU    -> glue u (Map.map (eqToIso . VPath i) ts)
  VGlue b isos -> compGlue i b isos u ts
  Ter (Sum _ _ nass) env -> case u of
    VCon n us | all isCon (elems ts) -> case lookupLabel n nass of
      Just as -> let tsus = transposeSystemAndList (Map.map unCon ts) us
                 in VCon n $ comps i as env tsus
      Nothing -> error $ "comp: missing constructor in labelled sum " ++ n
    _ -> VComp (VPath i a) u (Map.map (VPath i) ts)
  Ter (HSum _ _ nass) env -> compHIT i a u ts
  _ -> VComp (VPath i a) u (Map.map (VPath i) ts)

compNeg :: Name -> Val -> Val -> System Val -> Val
compNeg i a u ts = comp i (a `sym` i) u (ts `sym` i)

compLine :: Val -> Val -> System Val -> Val
compLine a u ts = comp i (a @@ i) u (Map.map (@@ i) ts)
  where i = fresh (a,u,ts)

comps :: Name -> [(Ident,Ter)] -> Env -> [(System Val,Val)] -> [Val]
comps i []         _ []         = []
comps i ((x,a):as) e ((ts,u):tsus) =
  let v   = fill i (eval e a) u ts
      vi1 = comp i (eval e a) u ts
      vs  = comps i as (upd (x,v) e) tsus
  in vi1 : vs
comps _ _ _ _ = error "comps: different lengths of types and values"

fill :: Name -> Val -> Val -> System Val -> Val
fill i a u ts =
  comp j (a `conj` (i,j)) u (insertSystem (i ~> 0) u (ts `conj` (i,j)))
  where j = fresh (Atom i,a,u,ts)

fillNeg :: Name -> Val -> Val -> System Val -> Val
fillNeg i a u ts = (fill i (a `sym` i) u (ts `sym` i)) `sym` i

fillLine :: Val -> Val -> System Val -> Val
fillLine a u ts = VPath i $ fill i (a @@ i) u (Map.map (@@ i) ts)
  where i = fresh (a,u,ts)

-- fills :: Name -> [(Ident,Ter)] -> Env -> [(System Val,Val)] -> [Val]
-- fills i []         _ []         = []
-- fills i ((x,a):as) e ((ts,u):tsus) =
--   let v  = fill i (eval e a) ts u
--       vs = fills i as (Upd e (x,v)) tsus
--   in v : vs
-- fills _ _ _ _ = error "fills: different lengths of types and values"


-----------------------------------------------------------
-- Transport and squeeze (defined using comp)

trans :: Name -> Val -> Val -> Val
trans i v0 v1 = comp i v0 v1 empty

transNeg :: Name -> Val -> Val -> Val
transNeg i a u = trans i (a `sym` i) u

transLine :: Val -> Val -> Val
transLine u v = trans i (u @@ i) v
  where i = fresh (u,v)

transNegLine :: Val -> Val -> Val
transNegLine u v = transNeg i (u @@ i) v
  where i = fresh (u,v)

transps :: Name -> [(Ident,Ter)] -> Env -> [Val] -> [Val]
transps i []         _ []     = []
transps i ((x,a):as) e (u:us) =
  let v   = transFill i (eval e a) u
      vi1 = trans i (eval e a) u
      vs  = transps i as (upd (x,v) e) us
  in vi1 : vs
transps _ _ _ _ = error "transps: different lengths of types and values"

transFill :: Name -> Val -> Val -> Val
transFill i a u = fill i a u empty

transFillNeg :: Name -> Val -> Val -> Val
transFillNeg i a u = (transFill i (a `sym` i) u) `sym` i

-- Given u of type a "squeeze i a u" connects in the direction i
-- trans i a u(i=0) to u(i=1)
squeeze :: Name -> Val -> Val -> Val
squeeze i a u = comp i (a `disj` (i,j)) u $ mkSystem [ (j ~> 1, ui1) ]
  where j   = fresh (Atom i,a,u)
        ui1 = u `face` (i ~> 1)

squeezeFill :: Name -> Val -> Val -> Val
squeezeFill i a u = fill i (a `disj` (i,j)) u $ mkSystem [ (j ~> 1, ui1) ]
  where j   = fresh (Atom i,a,u)
        ui1 = u `face` (i ~> 1)

squeezes :: Name -> [(Ident,Ter)] -> Env -> [Val] -> [Val]
squeezes i []         _ []     = []
squeezes i ((x,a):as) e (u:us) =
  let v   = squeezeFill i (eval e a) u
      vi1 = squeeze i (eval e a) u
      vs  = squeezes i as (upd (x,v) e) us
  in vi1 : vs
squeezes _ _ _ _ = error "squeezes: different lengths of types and values"

-- squeezeNeg :: Name -> Val -> Val -> Val
-- squeezeNeg i a u = transNeg j (a `conj` (i,j)) u
--   where j = fresh (Atom i,a,u)


-------------------------------------------------------------------------------
-- | HITs

pcon :: LIdent -> Val -> [Val] -> [Formula] -> Val
pcon c a@(Ter (HSum _ _ lbls) rho) us phis = case lookupPLabel c lbls of
  Just (tele,is,ts) | eps `member` vs -> vs ! eps
                    | otherwise       -> VPCon c a us phis
    where rho' = subs (zip is phis) (updsTele tele us rho)
          vs   = evalSystem rho' ts
  Nothing           -> error "pcon"
pcon c a us phi     = VPCon c a us phi

compHIT :: Name -> Val -> Val -> System Val -> Val
compHIT i a u us
  | isNeutral u || isNeutralSystem us =
      VComp (VPath i a) u (Map.map (VPath i) us)
  | otherwise =
      hComp (a `face` (i ~> 1)) (transpHIT i a u) $
        mapWithKey (\alpha uAlpha ->
                     VPath i $ squeezeHIT i (a `face` alpha) uAlpha) us

transpHIT :: Name -> Val -> Val -> Val
transpHIT i a u = squeezeHIT i a u `face` (i ~> 0)

-- given u(i) of type a(i) "squeezeHIT i a u" connects in the direction i
-- transHIT i a u(i=0) to u(i=1) in a(1)
squeezeHIT :: Name -> Val -> Val -> Val
squeezeHIT i a@(Ter (HSum _ _ nass) env) u =
 let j = fresh (a,u)
     aij = swap a (i,j)
 in
 case u of
  VCon n us -> case lookupLabel n nass of
    Just as -> VCon n (squeezes i as env us)
    Nothing -> error $ "squeezeHIT: missing constructor in labelled sum " ++ n
  VPCon c _ ws0 phis -> case lookupLabel c nass of
    Just as -> pcon c (a `face` (i ~> 1)) (squeezes i as env ws0) phis
    Nothing -> error $ "squeezeHIT: missing path constructor " ++ c
  VHComp _ v vs ->
    hComp (a `face` (i ~> 1)) (squeezeHIT i a v) $
      mapWithKey (\alpha vAlpha ->
                   VPath j $ squeezeHIT j (aij `face` alpha) (vAlpha @@ j)) vs
  _ -> error $ "squeezeHIT: neutral " ++ show u

hComp :: Val -> Val -> System Val -> Val
hComp a u us | eps `member` us = (us ! eps) @@ One
             | otherwise       = VHComp a u us

-------------------------------------------------------------------------------
-- | Glue
--
-- An iso for a type b is a five-tuple: (a,f,g,r,s)   where
--  a : U
--  f : a -> b
--  g : b -> a
--  s : forall (y : b), f (g y) = y
--  t : forall (x : a), g (f x) = x

-- Extraction functions for getting a, f, g, s and t:
isoDom :: Val -> Val
isoDom = fstVal

isoFun :: Val -> Val
isoFun = fstVal . sndVal

isoInv :: Val -> Val
isoInv = fstVal . sndVal . sndVal

isoSec :: Val -> Val
isoSec = fstVal . sndVal . sndVal . sndVal

isoRet :: Val -> Val
isoRet = sndVal . sndVal . sndVal . sndVal

-- -- Every path in the universe induces an iso
eqToIso :: Val -> Val
eqToIso e = VPair e1 (VPair f (VPair g (VPair s t)))
  where e1 = e @@ One
        (i,j,x,y,ev) = (Name "i",Name "j",Var "x",Var "y",Var "E")
        inv t = Path i $ AppFormula t (NegAtom i)
        evinv = inv ev
        (ev0, ev1) = (AppFormula ev (Dir Zero),AppFormula ev (Dir One)) -- (b,a)
        eenv     = upd ("E",e) emptyEnv
        -- eplus : e0 -> e1
        eplus z  = Comp ev z empty
        -- eminus : e1 -> e0
        eminus z = Comp evinv z empty
        -- NB: edown is *not* transNegFill
        eup z   = Fill ev z empty
        edown z = Fill evinv z empty
        f = Ter (Lam "x" ev1 (eminus x)) eenv
        g = Ter (Lam "y" ev0 (eplus y)) eenv
        -- s : (y : e0) -> eminus (eplus y) = y
        ssys = mkSystem [(j ~> 1, inv (eup y))
                        ,(j ~> 0, edown (eplus y))]
        s = Ter (Lam "y" ev0 $ Path j $ Comp evinv (eplus y) ssys) eenv
        -- t : (x : e1) -> eplus (eminus x) = x
        tsys = mkSystem [(j ~> 0, eup (eminus x))
                        ,(j ~> 1, inv (edown x))]
        t = Ter (Lam "x" ev1 $ Path j $ Comp ev (eminus x) tsys) eenv

glue :: Val -> System Val -> Val
glue b ts | eps `member` ts = isoDom (ts ! eps)
          | otherwise       = VGlue b ts

glueElem :: Val -> System Val -> Val
glueElem v us | eps `member` us = us ! eps
              | otherwise       = VGlueElem v us

unGlue :: Val -> Val -> System Val -> Val
unGlue w b isos | eps `member` isos = app (isoFun (isos ! eps)) w
                | otherwise         = case w of
                                        VGlueElem v us -> v
                                        _ -> VUnGlueElem w b isos

compGlue :: Name -> Val -> System Val -> Val -> System Val -> Val
compGlue i b isos wi0 ws = glueElem vi1'' usi1''
  where bi1 = b `face` (i ~> 1)
        vs   = mapWithKey
                 (\alpha wAlpha -> unGlue wAlpha
                                     (b `face` alpha) (isos `face` alpha)) ws
        vsi1 = vs `face` (i ~> 1) -- same as: border vi1 vs
        vi0  = unGlue wi0 (b `face` (i ~> 0)) (isos `face` (i ~> 0)) -- in b(i0)

        v    = fill i b vi0 vs           -- in b
        vi1  = comp i b vi0 vs           -- is v `face` (i ~> 1) in b(i1)

        isosI1 = isos `face` (i ~> 1)
        isos'  = filterWithKey (\alpha _ -> i `notMember` alpha) isos
        isos'' = filterWithKey (\alpha _ -> alpha `notMember` isos) isosI1

        us'    = mapWithKey (\gamma isoG ->
                   fill i (isoDom isoG) (wi0 `face` gamma) (ws `face` gamma))
                 isos'
        usi1'  = mapWithKey (\gamma isoG ->
                   comp i (isoDom isoG) (wi0 `face` gamma) (ws `face` gamma))
                 isos'

        ls'    = mapWithKey (\gamma isoG ->
                   pathComp i (b `face` gamma) (v `face` gamma)
                     (app (isoFun isoG) (us' ! gamma)) (vs `face` gamma))
                 isos'

        vi1' = compLine (constPath bi1) vi1
                 (ls' `unionSystem` Map.map constPath vsi1)

        wsi1 = ws `face` (i ~> 1)

        -- for gamma in isos'', (i1) gamma is in isos, so wsi1 gamma
        -- is in the domain of isoGamma
        uls'' = mapWithKey (\gamma isoG ->
                  gradLemma (bi1 `face` gamma) isoG
                    ((usi1' `face` gamma) `unionSystem` (wsi1 `face` gamma))
                    (vi1' `face` gamma))
                  isos''

        vsi1' = Map.map constPath $ border vi1' isos' `unionSystem` vsi1

        vi1'' = compLine (constPath bi1) vi1'
                  (Map.map snd uls'' `unionSystem` vsi1')

        usi1'' = mapWithKey (\gamma _ ->
                     if gamma `member` usi1' then usi1' ! gamma
                     else fst (uls'' ! gamma))
                   isosI1

-- assumes u and u' : A are solutions of us + (i0 -> u(i0))
-- The output is an L-path in A(i1) between u(i1) and u'(i1)
pathComp :: Name -> Val -> Val -> Val -> System Val -> Val
pathComp i a u u' us = VPath j $ comp i a (u `face` (i ~> 0)) us'
  where j   = fresh (Atom i,a,us,u,u')
        us' = insertsSystem [(j ~> 0, u), (j ~> 1, u')] us

-- Grad Lemma, takes an iso f, a system us and a value v, s.t. f us =
-- border v. Outputs (u,p) s.t. border u = us and a path p between v
-- and f u.
gradLemma :: Val -> Val -> System Val -> Val -> (Val, Val)
gradLemma b iso us v = (u, VPath i theta'')
  where i:j:_   = freshs (b,iso,us,v)
        (a,f,g,s,t) = (isoDom iso,isoFun iso,isoInv iso,isoSec iso,isoRet iso)
        us'     = mapWithKey (\alpha uAlpha ->
                                   app (t `face` alpha) uAlpha @@ i) us
        gv      = app g v
        theta   = fill i a gv us'
        u       = comp i a gv us'  -- Same as "theta `face` (i ~> 1)"
        ws      = insertSystem (i ~> 0) gv $
                  insertSystem (i ~> 1) (app t u @@ j) $
                  mapWithKey
                    (\alpha uAlpha ->
                      app (t `face` alpha) uAlpha @@ (Atom i :/\: Atom j)) us
        theta'  = compNeg j a theta ws
        xs      = insertSystem (i ~> 0) (app s v @@ j) $
                  insertSystem (i ~> 1) (app s (app f u) @@ j) $
                  mapWithKey
                    (\alpha uAlpha ->
                      app (s `face` alpha) (app (f `face` alpha) uAlpha) @@ j) us
        theta'' = comp j b (app f theta') xs

-------------------------------------------------------------------------------

-- Addition?: (Name == Formula) constraints, to handle dimensions defined in the environment
type VarConstr  = [(Ident,Ident)]

abstractVC :: Ident -> Ident -> VarConstr -> Maybe VarConstr
abstractVC x y c = do
    guard $ all (== (x,y)) (zy ++ xz)
    return $ [ p | p@(a,b) <- c, a /= x]
  where
    zy = [ p |  p@(_,b) <- c, b == y ]
    xz = [ p |  p@(a,_) <- c, a == x ]

(<+>) :: (Monoid a, Monad m) => m a -> m a -> m a
m <+> n = liftM2 (<>) m n

class Alpha a where
  alpha :: a -> a -> Maybe VarConstr

instance Alpha a => Alpha [a] where
  alpha ts ts' = foldr (<+>) (return mempty) (zipWith alpha ts ts')

instance Alpha Formula where
  alpha phi phi' = guard (conv [] phi phi') >> return mempty -- TODO: handle defined names

instance Alpha a => Alpha (System a) where
  alpha ts ts' = do
     guard (keys ts == keys ts') -- TODO: handle defined names
     foldr (<+>) (return mempty) (elems (intersectionWith alpha ts ts'))

instance (Alpha a, Alpha b, Alpha c) => Alpha (a,b,c) where
  alpha (a,b,c) (a',b',c') = alpha a a' <+> alpha b b' <+> alpha c c'

instance (Alpha a, Alpha b) => Alpha (a,b) where
  alpha (a,b) (a',b') = alpha a a' <+> alpha b b'

instance Alpha Ter where
  alpha t t' = case (t,t') of
    ( App t u, App t' u') -> alpha t t' <+> alpha u u'
    ( Pi t, Pi t')        -> alpha t t'
    ( Lam x a t, Lam x' a' t') -> abstractVC x x' =<< alpha t t'
    ( Where t ds, Where t' ds') -> Nothing -- TODO
    ( Var x, Var y)       -> return $ [(x,y)]
    ( U, U)               -> return mempty
             -- Sigma types:
    ( Sigma t, Sigma t') -> alpha t t'
    ( Pair t u, Pair t' u') -> alpha t t' <+> alpha u u'
    ( Fst t, Fst t') -> alpha t t'
    ( Snd t, Snd t') -> alpha t t'
             -- constructor c Ms
    ( Con l ts, Con l' ts') -> guard (l == l') >> alpha ts ts'
    ( PCon l t ts phis, PCon l' t' ts' phis') -> guard (l == l') >> (alpha t t' <+> alpha ts ts' <+> alpha phis phis')
                -- c A ts phis (A is the data type)
             -- branches c1 xs1  -> M1,..., cn xsn -> Mn
    ( Split _ p _ _, Split _ p' _ _) -> guard (p == p') >> return mempty
             -- labelled sum c1 A1s,..., cn Ans (assumes terms are constructors)
    ( Sum p _ _, Sum p' _ _) -> guard (p == p') >> return mempty

             -- undefined and holes
    ( Undef p _, Undef p' _) -> guard (p == p') >> return mempty
    ( Hole p, Hole p')       -> guard (p == p') >> return mempty

    ( IdP a t u, IdP a' t' u') -> alpha (a,t,u) (a',t',u')
    ( Path i t, Path i' t')
            -> let j = fresh (t,t') in alpha (t `swap` (i,j)) (t' `swap` (i',j))
    ( AppFormula t phi, AppFormula t' phi') -> alpha (t,phi) (t',phi')
             -- Kan Composition
    ( Comp a t ts, Comp a' t' ts') -> alpha (a,t,ts) (a',t',ts')
    -- ( Trans a t, Trans a' t')      -> alpha (a,t) (a',t')
             -- Composition in the Universe
    -- ( CompElem t ts u us, CompElem t' ts' u' us') -> alpha t t' <+> alpha (ts,u,us) (ts',u',us')
    -- ( ElimComp t ts u, ElimComp t' ts' u') -> alpha (t,ts,u) (t',ts',u')
    --          -- Glue
    -- ( Glue t ts, Glue t' ts') -> alpha (t,ts) (t',ts')
    -- ( GlueElem t ts, GlueElem t' ts') -> alpha (t,ts) (t',ts')
    --          -- GlueLine: connecting any type to its glue with identities
    -- ( GlueLine t phi psi, GlueLine t' phi' psi') -> alpha (t,phi,psi) (t',phi',psi')
    -- ( GlueLineElem t phi psi, GlueLineElem t' phi' psi') -> alpha (t,phi,psi) (t',phi',psi')

             -- guarded recursive types
    ( Later xi t, Later xi' t') -> do c <- alpha t t'; alphaDelSubst c xi xi'
    ( Next xi t, Next xi' t')   -> do c <- alpha t t'; alphaDelSubst c xi xi'
    ( Fix _ t, Fix _ t')        -> alpha t t'
    _ -> trace ("alpha:\n" ++ show t ++ "\nvs.\n" ++ show t') $ Nothing

alphaDelSubst :: VarConstr -> DelSubst -> DelSubst -> Maybe VarConstr
alphaDelSubst c xi xi' = foldr (<+>) (return mempty) [ alpha (lookDS' x xi) (lookDS' y xi')  | (x,y) <- c ]
  where
   lookDS' x xi = maybe (Next [] (Var x)) id (lookDS x xi)

convEnv :: [String] -> VarConstr -> Env -> Env -> Bool
convEnv ns c rho rho' = and [ conv ns (lookDel x rho) (lookDel y rho') | (x,y) <- c ]

-- | Conversion

class Convertible a where
  conv :: [String] -> a -> a -> Bool

isCompSystem :: (Nominal a, Convertible a) => [String] -> System a -> Bool
isCompSystem ns ts = and [ conv ns (getFace alpha beta) (getFace beta alpha)
                         | (alpha,beta) <- allCompatible (keys ts) ]
    where getFace a b = face (ts ! a) (b `minus` a)

instance Convertible Val where
  conv ns u v | u == v    = True
              | otherwise =
    let j = fresh (u,v)
    in case (u,v) of
      (Ter (Lam x a u) e,Ter (Lam x' a' u') e') ->
        let v@(VVar n _) = mkVarNice ns x (eval e a)
        in conv (n:ns) (eval (upd (x,v) e) u) (eval (upd (x',v) e') u')
      (Ter (Lam x a u) e,u') ->
        let v@(VVar n _) = mkVarNice ns x (eval e a)
        in conv (n:ns) (eval (upd (x,v) e) u) (app u' v)
      (u',Ter (Lam x a u) e) ->
        let v@(VVar n _) = mkVarNice ns x (eval e a)
        in conv (n:ns) (app u' v) (eval (upd (x,v) e) u)
      (Ter (Split _ p _ _) e,Ter (Split _ p' _ _) e') -> (p == p') && conv ns e e'
      (Ter (Sum p _ _) e,Ter (Sum p' _ _) e')         -> (p == p') && conv ns e e'
      (Ter (HSum p _ _) e,Ter (HSum p' _ _) e')       -> (p == p') && conv ns e e'
      (Ter (Undef p _) e,Ter (Undef p' _) e') -> p == p' && conv ns e e'
      (Ter (Hole p) e,Ter (Hole p') e') -> p == p' && conv ns e e'
      -- (Ter Hole{} e,_) -> True
      -- (_,Ter Hole{} e') -> True
      (VPi u v,VPi u' v') ->
        let w@(VVar n _) = mkVarNice ns "X" u
        in conv ns u u' && conv (n:ns) (app v w) (app v' w)
      (VSigma u v,VSigma u' v') ->
        let w@(VVar n _) = mkVarNice ns "X" u
        in conv ns u u' && conv (n:ns) (app v w) (app v' w)
      (VCon c us,VCon c' us')   -> (c == c') && conv ns us us'
      (VPCon c v us phis,VPCon c' v' us' phis') ->
        (c == c') && conv ns (v,us,phis) (v',us',phis')
      (VPair u v,VPair u' v')    -> conv ns u u' && conv ns v v'
      (VPair u v,w)              -> conv ns u (fstVal w) && conv ns v (sndVal w)
      (w,VPair u v)              -> conv ns (fstVal w) u && conv ns (sndVal w) v
      (VFst u,VFst u')           -> conv ns u u'
      (VSnd u,VSnd u')           -> conv ns u u'
      (VApp u v,VApp u' v')      -> conv ns u u' && conv ns v v'
      (VSplit u v,VSplit u' v')  -> conv ns u u' && conv ns v v'
      (VVar x _, VVar x' _)      -> x == x'
      (VIdP a b c,VIdP a' b' c') -> conv ns a a' && conv ns b b' && conv ns c c'
      (VPath i a,VPath i' a')    -> conv ns (a `swap` (i,j)) (a' `swap` (i',j))
      (VPath i a,p')             -> conv ns (a `swap` (i,j)) (p' @@ j)
      (p,VPath i' a')            -> conv ns (p @@ j) (a' `swap` (i',j))
      (VAppFormula u x,VAppFormula u' x')    -> conv ns (u,x) (u',x')
      (VComp a u ts,VComp a' u' ts')         -> conv ns (a,u,ts) (a',u',ts')
      (VHComp a u ts,VHComp a' u' ts')       -> conv ns (a,u,ts) (a',u',ts')
      (VGlue v isos,VGlue v' isos')          -> conv ns (v,isos) (v',isos')
      (VGlueElem u us,VGlueElem u' us')      -> conv ns (u,us) (u',us')
      (VUnGlueElem u _ _,VUnGlueElem u' _ _) -> conv ns u u'
      (Ter (Var i) e,Ter (Var i') e') -> conv ns (lookDel i e) (lookDel i' e')
      (VLater (Ter t rho), VLater (Ter t' rho')) -> maybe False (\ c -> convEnv ns c rho rho') (alpha t t')
      (VNext (Ter t rho), VNext (Ter t' rho')) -> maybe False (\ c -> convEnv ns c rho rho') (alpha t t')
      -- (VNext v, u) -> let x = "$x" in alpha ns Map.empty Map.empty v (Ter (Var x) (delUpd (x,u) empty))
      -- (u, VNext v) -> let x = "$x" in alpha ns Map.empty Map.empty v (Ter (Var x) (delUpd (x,u) empty))
      _                         -> False


getDelVals :: DelSubst -> [(Ident,Ter)]
getDelVals ds = map (\ (DelBind (f,(a,t))) -> (f,t)) ds

freshVar :: Env -> Ident
freshVar e = gensymV (envVars e)

gensymV :: [Ident] -> Ident
gensymV xs = ('$' : show max)
  where max = maximum' [ read x | ('$':x) <- xs ]
        maximum' [] = 0
        maximum' xs = maximum xs + 1

envVars :: Env -> [Ident]
envVars (c,_,_,_) = go c
  where
    go c = case c of
      Empty -> []
      Sub _ c -> go c
      Upd i c -> i : go c
      DelUpd i c -> i : go c

instance Convertible Ctxt where
  conv _ _ _ = True

instance Convertible () where
  conv _ _ _ = True

-- instance Convertible Char where
--   conv _ = (==)

-- instance (Ord k, Convertible a) => Convertible (Map k a) where
--   conv ns f g = keys f == keys g &&
--                 and (elems (intersectionWith (conv ns) f g))

instance Convertible (Map Ident Val) where
  -- we want this to be antisymmetric: f \subseteq g
  -- f <= g <=> f == (f /\ g)
  conv ns f g = keys f == keys (f `Map.intersection` g) &&
                and (elems (intersectionWith (conv ns) f g))


instance (Convertible a, Convertible b) => Convertible (Either a b) where
  conv ns (Left v) (Left v')   = conv ns v v'
  conv ns (Right v) (Right v') = conv ns v v'
  conv _  _ _                  = False

instance (Convertible a, Convertible b) => Convertible (a, b) where
  conv ns (u, v) (u', v') = conv ns u u' && conv ns v v'

instance (Convertible a, Convertible b, Convertible c)
      => Convertible (a, b, c) where
  conv ns (u, v, w) (u', v', w') = conv ns (u,(v,w)) (u',(v',w'))

instance (Convertible a,Convertible b,Convertible c,Convertible d)
      => Convertible (a,b,c,d) where
  conv ns (u,v,w,x) (u',v',w',x') = conv ns (u,v,(w,x)) (u',v',(w',x'))

instance Convertible a => Convertible [a] where
  conv ns us us' = length us == length us' &&
                  and [conv ns u u' | (u,u') <- zip us us']

instance Convertible a => Convertible (System a) where
  conv ns ts ts' = keys ts == keys ts' &&
                   and (elems (intersectionWith (conv ns) ts ts'))

instance Convertible Formula where
  conv _ phi psi = dnf phi == dnf psi


-------------------------------------------------------------------------------
-- | Normalization

class Normal a where
  normal :: [String] -> a -> a

instance Normal Val where
  normal ns v = case v of
    VU                  -> VU
    Ter (Lam x t u) e   ->
      let w = eval e t
          v@(VVar n _) = mkVarNice ns x w
      in VLam n (normal ns w) $ normal (n:ns) (eval (upd (x,v) e) u)
    Ter t e             -> Ter t (normal ns e)
    VPi u v             -> VPi (normal ns u) (normal ns v)
    VSigma u v          -> VSigma (normal ns u) (normal ns v)
    VPair u v           -> VPair (normal ns u) (normal ns v)
    VCon n us           -> VCon n (normal ns us)
    VPCon n u us phis   -> VPCon n (normal ns u) (normal ns us) phis
    VIdP a u0 u1        -> VIdP (normal ns a) (normal ns u0) (normal ns u1)
    VPath i u           -> VPath i (normal ns u)
    VComp u v vs        -> compLine (normal ns u) (normal ns v) (normal ns vs)
    VHComp u v vs       -> hComp (normal ns u) (normal ns v) (normal ns vs)
    VGlue u isos        -> glue (normal ns u) (normal ns isos)
    VGlueElem u us      -> glueElem (normal ns u) (normal ns us)
    VUnGlueElem u b hs  -> unGlue (normal ns u) (normal ns b) (normal ns hs)
    VVar x t            -> VVar x t -- (normal ns t)
    VFst t              -> fstVal (normal ns t)
    VSnd t              -> sndVal (normal ns t)
    VSplit u t          -> VSplit (normal ns u) (normal ns t)
    VApp u v            -> app (normal ns u) (normal ns v)
    VAppFormula u phi   -> VAppFormula (normal ns u) (normal ns phi)
    VNext v             -> VNext (normal ns v)
    VLater v            -> VLater (normal ns v)
    _                   -> v

instance Normal Ctxt where
  normal _ = id

instance Normal Formula where
  normal _ = fromDNF . dnf

instance Normal a => Normal (Map k a) where
  normal ns = Map.map (normal ns)

instance (Normal a,Normal b) => Normal (a,b) where
  normal ns (u,v) = (normal ns u,normal ns v)

instance (Normal a,Normal b,Normal c) => Normal (a,b,c) where
  normal ns (u,v,w) = (normal ns u,normal ns v,normal ns w)

instance (Normal a,Normal b,Normal c,Normal d) => Normal (a,b,c,d) where
  normal ns (u,v,w,x) =
    (normal ns u,normal ns v,normal ns w, normal ns x)

instance Normal a => Normal [a] where
  normal ns = map (normal ns)
