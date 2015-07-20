{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
module CTT where

import Control.Applicative
import Data.List
import Data.Maybe
import Data.Map (Map,(!),filterWithKey,elems)
import qualified Data.Map as Map
import Text.PrettyPrint as PP

import Connections

--------------------------------------------------------------------------------
-- | Terms

data Loc = Loc { locFile :: String
               , locPos  :: (Int,Int) }
  deriving Eq

type Ident  = String
type LIdent = String

-- Telescope (x1 : A1) .. (xn : An)
type Tele   = [(Ident,Ter)]

data Label = OLabel LIdent Tele -- Object label
           | PLabel LIdent Tele [Name] (System Ter) -- Path label
  deriving (Eq,Show)

-- OBranch of the form: c x1 .. xn -> e
-- PBranch of the form: c x1 .. xn i1 .. im -> e
data Branch = OBranch LIdent [Ident] Ter
            | PBranch LIdent [Ident] [Name] Ter
  deriving (Eq,Show)

-- Declarations: x : A = e
type Decl   = (Ident,(Ter,Ter))

declIdents :: [Decl] -> [Ident]
declIdents decls = [ x | (x,_) <- decls ]

declTers :: [Decl] -> [Ter]
declTers decls = [ d | (_,(_,d)) <- decls ]

declTele :: [Decl] -> Tele
declTele decls = [ (x,t) | (x,(t,_)) <- decls ]

declDefs :: [Decl] -> [(Ident,Ter)]
declDefs decls = [ (x,d) | (x,(_,d)) <- decls ]

labelTele :: Label -> (LIdent,Tele)
labelTele (OLabel c ts) = (c,ts)
labelTele (PLabel c ts _ _) = (c,ts)

labelName :: Label -> LIdent
labelName = fst . labelTele

labelTeles :: [Label] -> [(LIdent,Tele)]
labelTeles = map labelTele

lookupLabel :: LIdent -> [Label] -> Maybe Tele
lookupLabel x xs = lookup x (labelTeles xs)

lookupPLabel :: LIdent -> [Label] -> Maybe (Tele,[Name],System Ter)
lookupPLabel x xs = listToMaybe [ (ts,is,es) | PLabel y ts is es <- xs, x == y ]

branchName :: Branch -> LIdent
branchName (OBranch c _ _) = c
branchName (PBranch c _ _ _) = c

lookupBranch :: LIdent -> [Branch] -> Maybe Branch
lookupBranch _ []      = Nothing
lookupBranch x (b:brs) = case b of
  OBranch c _ _   | x == c    -> Just b
                  | otherwise -> lookupBranch x brs
  PBranch c _ _ _ | x == c    -> Just b
                  | otherwise -> lookupBranch x brs

-- Terms
data Ter = App Ter Ter
         | Pi Ter
         | Lam Ident Ter Ter
         | Where Ter [Decl]
         | Var Ident
         | U
           -- Sigma types:
         | Sigma Ter
         | Pair Ter Ter
         | Fst Ter
         | Snd Ter
           -- constructor c Ms
         | Con LIdent [Ter]
         | PCon LIdent Ter [Ter] [Formula] -- c A ts phis (A is the data type)
           -- branches c1 xs1  -> M1,..., cn xsn -> Mn
         | Split Ident Loc Ter [Branch]
           -- labelled sum c1 A1s,..., cn Ans (assumes terms are constructors)
         | Sum Loc Ident [Label] -- TODO: should only contain OLabels
         | HSum Loc Ident [Label]
           -- undefined and holes
         | Undef Loc Ter -- Location and type
         | Hole Loc
           -- Id type
         | IdP Ter Ter Ter
         | Path Name Ter
         | AppFormula Ter Formula
           -- Kan composition and filling
         | Comp Ter Ter (System Ter)
         | Fill Ter Ter (System Ter)
           -- Glue
         | Glue Ter (System Ter)
         | GlueElem Ter (System Ter)
           -- guarded recursive types
         | Later Clock DelSubst Ter
         | Next Clock DelSubst Ter
         | DFix Clock Ter Ter
         | Prev Clock Ter
         | CLam Clock Ter
         | CApp Ter Clock
         | Forall Clock Ter
  deriving Eq

newtype Clock = Clock String deriving Eq

-- Binding for delayed substitution: (x : A) <- t
newtype DelBind' a = DelBind (Ident,(a,a))
                   deriving (Eq, Show)

type DelBind = DelBind' Ter
type DelSubst = [DelBind]
type VDelSubst = [DelBind' Val]

lookDS :: Ident -> DelSubst -> Maybe Ter
lookDS x = fmap (\ (DelBind (_,(_,t))) -> t) . find (\ (DelBind (y,(_,t))) -> x == y)

-- For an expression t, returns (u,ts) where u is no application and t = u ts
unApps :: Ter -> (Ter,[Ter])
unApps = aux []
  where aux :: [Ter] -> Ter -> (Ter,[Ter])
        aux acc (App r s) = aux (s:acc) r
        aux acc t         = (t,acc)

mkApps :: Ter -> [Ter] -> Ter
mkApps (Con l us) vs = Con l (us ++ vs)
mkApps t ts          = foldl App t ts

mkWheres :: [[Decl]] -> Ter -> Ter
mkWheres []     e = e
mkWheres (d:ds) e = Where (mkWheres ds e) d

--------------------------------------------------------------------------------
-- | Values

data Val = VU
         | Ter Ter Env
         | VPi Val Val
         | VSigma Val Val
         | VPair Val Val
         | VCon LIdent [Val]
         | VPCon LIdent Val [Val] [Formula]

           -- Id values
         | VIdP Val Val Val
         | VPath Name Val
         | VComp Val Val (System Val)

           -- Glue values
         | VGlue Val (System Val)
         | VGlueElem Val (System Val)

           -- Composition for HITs; the type is constant
         | VHComp Val Val (System Val)

           -- Guarded recursive types
           -- inside later/next is a closure
         -- | VLater Ter Env
         | VLater Val -- try just propagating the closures down to the variables
         -- | VNext Ter Env
         | VNext Val
         | VDFix Val Val
           -- Neutral values:
         | VVar Ident Val
         | VFst Val
         | VSnd Val
         | VUnGlueElem Val Val (System Val)
         | VSplit Val Val
         | VApp Val Val
         | VAppFormula Val Formula
         | VLam Ident Val Val
  deriving Eq

isNeutral :: Val -> Bool
isNeutral v = case v of
  Ter Undef{} _  -> True
  Ter Hole{} _   -> True
  VVar{}         -> True
  VComp{}        -> True
  VFst{}         -> True
  VSnd{}         -> True
  VSplit{}       -> True
  VApp{}         -> True
  VAppFormula{}  -> True
  VUnGlueElem{}  -> True
  _              -> False

isNeutralSystem :: System Val -> Bool
isNeutralSystem = any isNeutral . elems

-- isNeutralPath :: Val -> Bool
-- isNeutralPath (VPath _ v) = isNeutral v
-- isNeutralPath _ = True

mkVar :: Int -> String -> Val -> Val
mkVar k x = VVar (x ++ show k)

mkVarNice :: [String] -> String -> Val -> Val
mkVarNice xs x = VVar (head (ys \\ xs))
  where ys = x:map (\n -> x ++ show n) [0..]

unCon :: Val -> [Val]
unCon (VCon _ vs) = vs
unCon v           = error $ "unCon: not a constructor: " ++ show v

isCon :: Val -> Bool
isCon VCon{} = True
isCon _      = False

-- Constant path: <_> v
constPath :: Val -> Val
constPath = VPath (Name "_")


--------------------------------------------------------------------------------
-- | Environments

data Ctxt = Empty
          | Upd Ident Ctxt
          | Sub Name Ctxt
          | Def [Decl] Ctxt
          | DelDef VDelSubst Ctxt
          | DelUpd Ident Ctxt -- Delayed Substitution update.
  deriving (Show,Eq)

-- The Idents and Names in the Ctxt refer to the elements in the two
-- lists. This is more efficient because acting on an environment now
-- only need to affect the lists and not the whole context.
-- The last [Val] is for delayed substitutions.
type Env = (Ctxt,[Val],[Formula],[Val])

emptyEnv :: Env
emptyEnv = (Empty,[],[],[])

def :: [Decl] -> Env -> Env
def ds (rho,vs,fs,ws) = (Def ds rho,vs,fs,ws)

delDef :: VDelSubst -> Env -> Env
delDef ds (rho,vs,fs,ws) = (DelDef ds rho,vs,fs,ws)

sub :: (Name,Formula) -> Env -> Env
sub (i,phi) (rho,vs,fs,ws) = (Sub i rho,vs,phi:fs,ws)

upd :: (Ident,Val) -> Env -> Env
upd (x,v) (rho,vs,fs,ws) = (Upd x rho,v:vs,fs,ws)

delUpd :: (Ident,Val) -> Env -> Env
delUpd (x,w) (rho,vs,fs,ws) = (DelUpd x rho,vs,fs,w:ws)

upds :: [(Ident,Val)] -> Env -> Env
upds xus rho = foldl (flip upd) rho xus

updsTele :: Tele -> [Val] -> Env -> Env
updsTele tele vs = upds (zip (map fst tele) vs)

subs :: [(Name,Formula)] -> Env -> Env
subs iphis rho = foldl (flip sub) rho iphis

-- mapEnv :: (Val -> Val) -> (Formula -> Formula) -> Env -> Env
-- mapEnv f g (rho,vs,fs) = (rho,map f vs,map g fs)

valAndFormulaOfEnv :: Env -> ([Val],[Formula])
valAndFormulaOfEnv (_,vs,fs,_) = (vs,fs)

valOfEnv :: Env -> [Val]
valOfEnv = fst . valAndFormulaOfEnv

formulaOfEnv :: Env -> [Formula]
formulaOfEnv = snd . valAndFormulaOfEnv

domainEnv :: Env -> [Name]
domainEnv (rho,_,_,_) = domCtxt rho
  where domCtxt rho = case rho of
          Empty    -> []
          Upd _ e  -> domCtxt e
          Def ts e -> domCtxt e
          DelDef ts e -> domCtxt e
          Sub i e  -> i : domCtxt e
          DelUpd _ e -> domCtxt e

-- Extract the context from the environment, used when printing holes
contextOfEnv :: Env -> [String]
contextOfEnv rho = case rho of
  (Empty,_,_,_)               -> []
  (Upd x e,VVar n t:vs,fs,ws) -> (n ++ " : " ++ show t) : contextOfEnv (e,vs,fs,ws)
  (Upd x e,v:vs,fs,ws)        -> (x ++ " = " ++ show v) : contextOfEnv (e,vs,fs,ws)
  (Def _ e,vs,fs,ws)          -> contextOfEnv (e,vs,fs,ws)
  (DelDef _ e,vs,fs,ws)          -> contextOfEnv (e,vs,fs,ws)
  (Sub i e,vs,phi:fs,ws)      -> (show i ++ " = " ++ show phi) : contextOfEnv (e,vs,fs,ws)
  (DelUpd x e, vs,fs,VVar n t:ws) -> (n ++ " >: " ++ show t) : contextOfEnv (e,vs,fs,ws)
  (DelUpd x e, vs,fs,w:ws)        -> ("next " ++ x ++ " = " ++ show w) : contextOfEnv (e,vs,fs,ws)

--------------------------------------------------------------------------------
-- | Pretty printing

instance Show Env where
  show = render . showEnv True

showEnv :: Bool -> Env -> Doc
showEnv b e =
  let -- This decides if we should print "x = " or not
      names x = if b then text x <+> equals else PP.empty

      showEnv1 e = case e of
        (Upd x env,u:us,fs,ws)   -> showEnv1 (env,us,fs,ws) <> names x <+> showVal u <> comma
        (Sub i env,us,phi:fs,ws) -> showEnv1 (env,us,fs,ws) <> names (show i) <+> text (show phi) <> comma
        (DelUpd x env,us,fs,w:ws) -> showEnv1 (env,us,fs,ws) <> names ("next " ++ x) <+> showVal w <> comma
        _                     -> showEnv b e
  in case e of
    (Empty,_,_,_)           -> PP.empty
    (Def _ env,vs,fs,ws)     -> showEnv b (env,vs,fs,ws)
    (DelDef _ env,vs,fs,ws)     -> showEnv b (env,vs,fs,ws)
    (Upd x env,u:us,fs,ws)   -> parens (showEnv1 (env,us,fs,ws) <+> names x <+> showVal u)
    (DelUpd x env,us,fs,w:ws)   -> parens (showEnv1 (env,us,fs,ws) <+> names ("next " ++ x) <+> showVal w)
    (Sub i env,us,phi:fs,ws) -> parens (showEnv1 (env,us,fs,ws) <+> names (show i) <+> text (show phi))

instance Show Loc where
  show = render . showLoc

showLoc :: Loc -> Doc
showLoc (Loc name (i,j)) = text (show (i,j) ++ " in " ++ name)

showFormula :: Formula -> Doc
showFormula phi = case phi of
  _ :\/: _ -> parens (text (show phi))
  _ :/\: _ -> parens (text (show phi))
  _ -> text $ show phi

instance Show Ter where
  show = render . showTer

showTer :: Ter -> Doc
showTer v = case v of
  U                  -> char 'U'
  App e0 e1          -> showTer e0 <+> showTer1 e1
  Pi e0              -> text "Pi" <+> showTer e0
  Lam x t e          -> char '\\' <> parens (text x <+> colon <+> showTer t) <+>
                          text "->" <+> showTer e
  Fst e              -> showTer1 e <> text ".1"
  Snd e              -> showTer1 e <> text ".2"
  Sigma e0           -> text "Sigma" <+> showTer1 e0
  Pair e0 e1         -> parens (showTer e0 <> comma <> showTer e1)
  Where e d          -> showTer e <+> text "where" <+> showDecls d
  Var x              -> text x
  Con c es           -> text c <+> showTers es
  PCon c a es phis   -> text c <+> braces (showTer a) <+> showTers es
                        <+> hsep (map ((char '@' <+>) . showFormula) phis)
  Split f _ _ _      -> text f
  Sum _ n _          -> text n
  HSum _ n _         -> text n
  Undef{}            -> text "undefined"
  Hole{}             -> text "?"
  IdP e0 e1 e2       -> text "IdP" <+> showTers [e0,e1,e2]
  Path i e           -> char '<' <> text (show i) <> char '>' <+> showTer e
  AppFormula e phi   -> showTer1 e <+> char '@' <+> showFormula phi
  Comp e t ts        -> text "comp" <+> showTers [e,t] <+> text (showSystem ts)
  Fill e t ts        -> text "fill" <+> showTers [e,t] <+> text (showSystem ts)
  Glue a ts          -> text "glue" <+> showTer1 a <+> text (showSystem ts)
  GlueElem a ts      -> text "glueElem" <+> showTer1 a <+> text (showSystem ts)

  Later k ds t         -> text "|>" <+> showDelSubst ds <+> showTer t
  Next k ds t          -> text "next" <+> showDelSubst ds <+> showTer t
  DFix k a t            -> text "dfix" <+> showTer a <+> showTer t

showTers :: [Ter] -> Doc
showTers = hsep . map showTer1

showTer1 :: Ter -> Doc
showTer1 t = case t of
  U        -> char 'U'
  Con c [] -> text c
  Var{}    -> showTer t
  Undef{}  -> showTer t
  Hole{}   -> showTer t
  Split{}  -> showTer t
  Sum{}    -> showTer t
  HSum{}   -> showTer t
  Fst{}    -> showTer t
  Snd{}    -> showTer t
  _        -> parens (showTer t)

showDelSubst :: DelSubst -> Doc
showDelSubst ds = text "[" <+> showDelBinds ds <+> text "]"

showDelBind :: DelBind -> Doc
showDelBind (DelBind (f,(a,t))) =
  parens (text f <+> colon <+> showTer a) <+> text "<-" <+> showTer t

showDelBinds :: [DelBind] -> Doc
showDelBinds [] = text ""
showDelBinds [d] = showDelBind d
showDelBinds (d : ds) =
  showDelBinds ds <+> text "," <+>
  showDelBind d

showDecls :: [Decl] -> Doc
showDecls defs = hsep $ punctuate comma
                      [ text x <+> equals <+> showTer d | (x,(_,d)) <- defs ]

instance Show Val where
  show = render . showVal

showVal :: Val -> Doc
showVal v = case v of
  VU                -> char 'U'
  -- VLater a rho      -> text "|>" <+> showEnv True rho <+> showTer a
  VLater v          -> text "|>" <+> showVal v
  -- VNext t rho       -> text "next" <+> showEnv True rho <+> showTer t
  VNext v           -> text "next" <+> showVal v
  VDFix a t         -> text "dfix" <+> showVal a <+> showVal t
  Ter t@Sum{} rho   -> showTer t <+> showEnv False rho
  Ter t@HSum{} rho  -> showTer t <+> showEnv False rho
  Ter t@Split{} rho -> showTer t <+> showEnv False rho
  Ter t rho         -> showTer1 t <+> showEnv True rho
  VCon c us         -> text c <+> showVals us
  VPCon c a us phis -> text c <+> braces (showVal a) <+> showVals us
                       <+> hsep (map ((char '@' <+>) . showFormula) phis)
  VHComp v0 v1 vs   -> text "hComp" <+> showVals [v0,v1] <+> text (showSystem vs)
  VPi a l@(VLam x t b)
    | "_" `isPrefixOf` x -> showVal a <+> text "->" <+> showVal1 b
    | otherwise          -> char '(' <> showLam v
  VPi a b           -> text "Pi" <+> showVals [a,b]
  VPair u v         -> parens (showVal u <> comma <> showVal v)
  VSigma u v        -> text "Sigma" <+> showVals [u,v]
  VApp u v          -> showVal u <+> showVal1 v
  VLam{}            -> text "\\(" <> showLam v
  VPath{}           -> char '<' <> showPath v
  VSplit u v        -> showVal u <+> showVal1 v
  VVar x _          -> text x
  VFst u            -> showVal1 u <> text ".1"
  VSnd u            -> showVal1 u <> text ".2"
  VUnGlueElem v b hs  -> text "unGlueElem" <+> showVals [v,b]
                         <+> text (showSystem hs)
  VIdP v0 v1 v2     -> text "IdP" <+> showVals [v0,v1,v2]
  VAppFormula v phi -> showVal v <+> char '@' <+> showFormula phi
  VComp v0 v1 vs    ->
    text "comp" <+> showVals [v0,v1] <+> text (showSystem vs)
  VGlue a ts        -> text "glue" <+> showVal1 a <+> text (showSystem ts)
  VGlueElem a ts    -> text "glueElem" <+> showVal1 a <+> text (showSystem ts)

showPath :: Val -> Doc
showPath e = case e of
  VPath i a@VPath{} -> text (show i) <+> showPath a
  VPath i a         -> text (show i) <> char '>' <+> showVal a
  _                 -> showVal e

-- Merge lambdas of the same type
showLam :: Val -> Doc
showLam e = case e of
  VLam x t a@(VLam _ t' _)
    | t == t'   -> text x <+> showLam a
    | otherwise ->
      text x <+> colon <+> showVal t <> char ')' <+> text "->" <+> showVal a
  VPi _ (VLam x t a@(VPi _ (VLam _ t' _)))
    | t == t'   -> text x <+> showLam a
    | otherwise ->
      text x <+> colon <+> showVal t <> char ')' <+> text "->" <+> showVal a
  VLam x t e         ->
    text x <+> colon <+> showVal t <> char ')' <+> text "->" <+> showVal e
  VPi _ (VLam x t e) ->
    text x <+> colon <+> showVal t <> char ')' <+> text "->" <+> showVal e
  _ -> showVal e

showVal1 :: Val -> Doc
showVal1 v = case v of
  VU        -> showVal v
  VCon c [] -> showVal v
  VVar{}    -> showVal v
  VFst{}    -> showVal v
  VSnd{}    -> showVal v
  _         -> parens (showVal v)

showVals :: [Val] -> Doc
showVals = hsep . map showVal1
