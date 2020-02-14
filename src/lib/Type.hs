-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Type (
    getType, instantiateTVs, abstractTVs, topEnvType,
    tangentBunType, flattenType, asForall,
    litType, traversePrimExprType, binOpType, unOpType, PrimExprType,
    tupTy, pairTy, isData, IsModule (..), IsModuleBody (..),
    checkLinFModule, LinApplicative (..), LinearTraversable (..)) where

import Control.Applicative
import Control.Monad
import Control.Monad.Except hiding (Except)
import Control.Monad.Reader
import Data.List (elemIndex)
import Data.Foldable
import Data.Text.Prettyprint.Doc

import Syntax
import Env
import Record
import PPrint
import Cat

type TypeM a = ReaderT TypeEnv (Either Err) a

class HasType a where
  getType :: a -> Type

runTypeM :: TypeEnv -> TypeM a -> Except a
runTypeM env m = runReaderT m env

-- === Module interfaces ===

class IsModule a where
  checkModule  :: a -> Except ()
  moduleType   :: a -> ModuleType

class IsModuleBody a where
  checkModuleBody  :: TypeEnv -> a -> Except TypeEnv

instance (IsModuleBody body) => IsModule (ModuleP body) where
  checkModule (Module (imports, exports) body) = do
    exports' <- checkModuleBody imports body
    assertEq exports exports' "Module exports"
  moduleType (Module ty _) = ty

instance IsModuleBody FModBody where
  checkModuleBody env (FModBody decls) =
    runTypeM env $ catFold checkTypeFDecl decls

instance IsModuleBody ModBody where
  checkModuleBody env (ModBody decls result) = runTypeM env $ do
    env' <- catFold checkDecl decls
    extendR env' $ traverse checkTyOrKind result

topEnvType :: SubstEnv -> TypeEnv
topEnvType env = fmap getTyOrKind env

checkTyOrKind :: LorT Atom Type -> TypeM (LorT Type Kind)
checkTyOrKind (L x) = liftM L $ checkAtom x
checkTyOrKind (T _) = return $ T $ Kind []

getTyOrKind :: LorT Atom Type -> LorT Type Kind
getTyOrKind (L x) = L $ getType x
getTyOrKind (T _) = T $ Kind []

-- === type-checking pass on FExpr ===

instance HasType FExpr where
  getType expr = case expr of
    FDecl _ body -> getType body
    FVar (_:>ty) _ -> ty
    FPrimExpr e -> getPrimType e'
      where e' = fmapExpr e id getType getFLamType
    Annot e _    -> getType e
    SrcAnnot e _ -> getType e

instance HasType (RecTree Var) where
  getType (RecLeaf (_:>ty)) = ty
  getType (RecTree r) = RecType $ fmap getType r

getFLamType :: FLamExpr -> (Type, Type)
getFLamType (FLamExpr p body) = (getType p, getType body)

checkTypeFExpr :: FExpr -> TypeM Type
checkTypeFExpr expr = case expr of
  FVar v@(_:>annTy) ts -> do
    mapM_ checkTy ts
    x <- asks $ flip envLookup v
    case x of
      Just (L ty) -> do
        assertEq annTy ty "Var annotation"
        let (kinds, body) = asForall ty
        assertEq (length kinds) (length ts) "Number of type args"
        zipWithM_ checkClassConstraints kinds ts
        return $ instantiateTVs ts body
      _ -> throw CompilerErr $ "Lookup failed:" ++ pprint v
  FDecl decl body -> do
    env <- checkTypeFDecl decl
    extendR env (checkTypeFExpr body)
  FPrimExpr e -> do
    eTy <- traverseExpr e return checkTypeFExpr checkTypeFlam
    checkPrimType eTy
  SrcAnnot e pos -> addSrcContext (Just pos) $ checkTypeFExpr e
  Annot e ty     -> do
    ty' <- checkTypeFExpr e
    assertEq ty ty' "Type annotation"
    return ty'

checkTypeFlam :: FLamExpr -> TypeM (Type, Type)
checkTypeFlam (FLamExpr p body) = do
  checkTy pTy >> checkShadowPat p
  bodyTy <- extendR (foldMap lbind p) $ checkTypeFExpr body
  return (pTy, bodyTy)
  where pTy = getType p

checkTypeFDecl :: FDecl -> TypeM TypeEnv
checkTypeFDecl decl = case decl of
  LetMono p rhs -> do
    checkShadowPat p
    ty <- checkTypeFExpr rhs
    assertEq (getType p) ty "LetMono"
    return (foldMap lbind p)
  LetPoly b@(_:>ty) tlam -> do
    checkShadow b
    ty' <- checkTypeTLam tlam
    assertEq ty ty' "TLam"
    return $ b @> L ty
  FRuleDef _ _ _ -> return mempty  -- TODO
  TyDef tv _ -> return $ tbind tv

asForall :: Type -> ([Kind], Type)
asForall (Forall ks body) = (ks, body)
asForall ty = ([], ty)

checkTypeTLam :: FTLam -> TypeM Type
checkTypeTLam (FTLam tbs body) = do
  mapM_ checkShadow tbs
  let env = foldMap (\b -> b @> T (varAnn b)) tbs
  ty <- extendR env (checkTypeFExpr body)
  return $ Forall (map varAnn tbs) (abstractTVs tbs ty)

checkTy :: Type -> TypeM ()
checkTy _ = return () -- TODO: check kind and unbound type vars

checkShadow :: Pretty b => VarP b -> TypeM ()
checkShadow v = do
  env <- ask
  if v `isin` env
    then throw CompilerErr $ pprint v ++ " shadowed"
    else return ()

checkShadowPat :: (Pretty b, Traversable f) => f (VarP b) -> TypeM ()
checkShadowPat pat = mapM_ checkShadow pat -- TODO: check mutual shadows!

checkRuleDefType :: RuleAnn -> Type -> TypeM ()
checkRuleDefType (LinearizationDef v) linTy = do
  ~ty@(Forall kinds body) <- asks $ fromL . (!(v:>()))
  (a, b) <- case body of
              ArrowType _ a b -> return (a, b)
              _ -> throw TypeErr $
                     "Bad type for linearization-annotated function: " ++ pprint ty
  let linTyExpected = Forall kinds $ a --> pairTy b (a --@ b)
  unless (linTy == linTyExpected) $ throw TypeErr $
     "Annotation should have type: " ++ pprint linTyExpected

litType :: LitVal -> BaseType
litType v = case v of
  IntLit  _ -> IntType
  RealLit _ -> RealType
  StrLit  _ -> StrType
  BoolLit _ -> BoolType

instantiateTVs :: [Type] -> Type -> Type
instantiateTVs vs x = subAtDepth 0 sub x
  where sub depth tvar =
          case tvar of
            Left v -> TypeVar v
            Right i | i >= depth -> if i' < length vs && i >= 0
                                      then vs !! i'
                                      else error $ "Bad index: "
                                             ++ show i' ++ " / " ++ pprint vs
                                             ++ " in " ++ pprint x
                    | otherwise  -> BoundTVar i
              where i' = i - depth

abstractTVs :: [TVar] -> Type -> Type
abstractTVs vs x = subAtDepth 0 sub x
  where sub depth tvar = case tvar of
                           Left v -> case elemIndex (varName v) (map varName vs) of
                                       Nothing -> TypeVar v
                                       Just i  -> BoundTVar (depth + i)
                           Right i -> BoundTVar i

subAtDepth :: Int -> (Int -> Either TVar Int -> Type) -> Type -> Type
subAtDepth d f ty = case ty of
    BaseType _    -> ty
    TypeVar v     -> f d (Left v)
    ArrowType m a b -> ArrowType (recur m) (recur a) (recur b)
    TabType a b   -> TabType (recur a) (recur b)
    RecType r     -> RecType (fmap recur r)
    ArrayType _ _ -> ty
    TypeApp a b   -> TypeApp (recur a) (map recur b)
    Monad eff a   -> Monad (fmap recur eff) (recur a)
    Lens a b      -> Lens (recur a) (recur b)
    Forall    ks body -> Forall    ks (recurWith (length ks) body)
    TypeAlias ks body -> TypeAlias ks (recurWith (length ks) body)
    IdxSetLit _   -> ty
    BoundTVar n   -> f d (Right n)
    Mult l        -> Mult l
    NoAnn         -> NoAnn
  where recur        = subAtDepth d f
        recurWith d' = subAtDepth (d + d') f

-- === Built-in typeclasses ===

checkClassConstraints :: Kind -> Type -> TypeM ()
checkClassConstraints (Kind cs) ty = mapM_ (flip checkClassConstraint ty) cs

checkClassConstraint :: ClassName -> Type -> TypeM ()
checkClassConstraint c ty = do
  env <- ask
  liftEither $ checkClassConstraint' env c ty

checkClassConstraint' :: TypeEnv -> ClassName -> Type -> Except ()
checkClassConstraint' env c ty = case c of
  VSpace -> checkVSpace env ty
  IdxSet -> checkIdxSet env ty
  Data   -> checkData   env ty

checkVSpace :: TypeEnv -> Type -> Except ()
checkVSpace env ty = case ty of
  TypeVar v         -> checkVarClass env VSpace v
  BaseType RealType -> return ()
  TabType _ a       -> recur a
  RecType r         -> mapM_ recur r
  _                 -> throw TypeErr $ " Not a vector space: " ++ pprint ty
  where recur = checkVSpace env

checkIdxSet :: TypeEnv -> Type -> Except ()
checkIdxSet env ty = case ty of
  TypeVar v   -> checkVarClass env IdxSet v
  IdxSetLit _ -> return ()
  RecType r   -> mapM_ recur r
  _           -> throw TypeErr $ " Not a valid index set: " ++ pprint ty
  where recur = checkIdxSet env

checkData :: TypeEnv -> Type -> Except ()
checkData env ty = case ty of
  TypeVar v   -> checkVarClass env IdxSet v `catchError`
                    const (checkVarClass env Data v)
  BaseType _  -> return ()
  TabType _ a -> recur a
  RecType r   -> mapM_ recur r
  IdxSetLit _ -> return ()
  _           -> throw TypeErr $ " Not serializable data: " ++ pprint ty
  where recur = checkData env

isData :: Type -> Bool
isData ty = case checkData mempty ty of Left _ -> False
                                        Right _ -> True

-- TODO: check annotation too
checkVarClass :: TypeEnv -> ClassName -> TVar -> Except ()
checkVarClass env c v = do
  case envLookup env v of
    Just (T (Kind cs)) ->
      unless (c `elem` cs) $ throw TypeErr $ " Type variable \""  ++ pprint v ++
                                             "\" not in class: " ++ pprint c
    _ -> throw CompilerErr $ "Lookup of kind failed:" ++ pprint v

-- -- === Normalized IR ===

instance HasType Expr where
  getType expr = case expr of
    Decl _ e -> getType e
    CExpr e  -> getType e
    Atom x   -> getType x

instance HasType Atom where
  getType expr = case expr of
    Var (_:>ty) -> ty
    TLam vs body -> Forall (map varAnn vs) $ abstractTVs vs (getType body)
    Con con -> getPrimType $ ConExpr $ fmapExpr con id getType getLamType

instance HasType CExpr where
  getType op = getPrimType $ OpExpr $ fmapExpr op id getType getLamType

instance HasType FTLam where
  getType (FTLam tbs body) = Forall (map varAnn tbs) body'
    where body' = abstractTVs tbs (getType body)

getLamType :: LamExpr -> (Type, Type)
getLamType (LamExpr (_:>ty) body) = (ty, getType body)

checkExpr :: Expr -> TypeM Type
checkExpr expr = case expr of
  Decl decl body -> do
    env <- checkDecl decl
    extendR env $ checkExpr body
  CExpr e -> checkCExpr e
  Atom x  -> checkAtom x

checkCExpr :: CExpr -> TypeM Type
checkCExpr op = do
  primType <- traverseExpr op return checkAtom checkLam
  checkPrimType (OpExpr primType)

checkAtom :: Atom -> TypeM Type
checkAtom atom = case atom of
  Var v@(_:>ty) -> do
    x <- asks $ flip envLookup v
    case x of
      Just (L ty') -> do
        assertEq ty' ty "NVar annot"
        return ty
      _ -> throw CompilerErr $ "Lookup failed:" ++ pprint v
  TLam tvs body -> do
    bodyTy <- extendR (foldMap tbind tvs) (checkExpr body)
    return $ Forall (map varAnn tvs) (abstractTVs tvs bodyTy)
  Con con -> do
    primType <- traverseExpr con return checkAtom checkLam
    checkPrimType (ConExpr primType)

checkLam :: LamExpr -> TypeM (Type, Type)
checkLam (LamExpr b@(_:>ty) body) = do
  bodyTy <- extendR (b @> L ty) $ checkExpr body
  return (ty, bodyTy)

checkDecl :: Decl -> TypeM TypeEnv
checkDecl decl = case decl of
  Let b expr -> do
    checkNBinder b
    t <- checkCExpr expr
    assertEq (varAnn b) t "Decl"
    return $ binderEnv b

binderEnv :: Var -> TypeEnv
binderEnv b@(_:>ty) = b @> L ty

checkNTy :: Type -> TypeM ()
checkNTy _ = return () -- TODO!

checkNBinder :: Var -> TypeM ()
checkNBinder b = do
  checkNTy (varAnn b)
  checkNShadow b

checkNShadow :: Pretty b => VarP b -> TypeM ()
checkNShadow v = do
  env <- ask
  if v `isin` env
    then throw CompilerErr $ pprint v ++ " shadowed"
    else return ()

pairTy :: Type -> Type -> Type
pairTy x y = tupTy [x, y]

tupTy :: [Type] -> Type
tupTy xs = RecType $ Tup xs

tangentBunType :: Type -> Type
tangentBunType ty = case ty of
  BaseType b -> case b of RealType -> pairTy ty ty
                          _ -> ty
  TypeVar _ -> ty  -- can only be an index set
  ArrowType l a b -> ArrowType l (recur a) (recur b)
  TabType n a   -> TabType n (recur a)
  IdxSetLit _ -> ty
  BoundTVar _ -> ty
  _ -> error "Not implemented"
  where recur = tangentBunType

-- === primitive ops and constructors ===

type PrimExprType = PrimExpr Type Type (Type, Type)

getPrimType :: PrimExprType -> Type
getPrimType e = ignoreExcept $ traversePrimExprType e ignoreConstraint ignoreClass
  where ignoreConstraint _ _ = return ()
        ignoreClass      _ _ = return ()

checkPrimType :: PrimExprType -> TypeM Type
checkPrimType e = traversePrimExprType e checkConstraint (flip checkClassConstraint)
  where
    checkConstraint :: Type -> Type -> TypeM ()
    checkConstraint ty1 ty2 | ty1 == ty2 = return ()
                            | otherwise  = throw TypeErr $
                                pprint ty1 ++ " != " ++ pprint ty2

traversePrimExprType :: MonadError Err m
                     => PrimExprType
                     -> (Type -> Type      -> m ()) -- add equality constraint
                     -> (Type -> ClassName -> m ()) -- add class constraint
                     -> m Type
traversePrimExprType (OpExpr op) eq inClass = case op of
  App l (ArrowType l' a b) a' -> do
    eq a a'
    eq l l'
    return b
  TApp (Forall _ body) ts -> return $ instantiateTVs ts body  --TODO: check kinds
  For (n,a) -> inClass n IdxSet >> inClass a Data >> return (TabType n a)
  TabCon n ty xs ->
    inClass ty Data >> mapM_ (eq ty) xs >> eq n n' >> return (n ==> ty)
    where n' = IdxSetLit (length xs)
  TabGet (TabType i a) i' -> eq i i' >> return a
  RecGet (RecType r) i    -> return $ recGet r i
  ArrayGep (ArrayType (_:shape) b) i -> do
    eq (BaseType IntType) i
    return $ ArrayType shape b
  LoadScalar (ArrayType [] b) -> return $ BaseType b
  ScalarBinOp binop t1 t2 -> do
    eq (BaseType t1') t1
    eq (BaseType t2') t2
    return $ BaseType tOut
    where (t1', t2', tOut) = binOpType binop
  -- TODO: check index set constraint
  ScalarUnOp IndexAsInt _ -> return $ BaseType IntType
  ScalarUnOp unop ty -> eq (BaseType ty') ty >> return (BaseType outTy)
    where (ty', outTy) = unOpType unop
  -- TODO: check vspace constraints
  VSpaceOp ty VZero        -> inClass ty VSpace >> return ty
  VSpaceOp ty (VAdd e1 e2) -> inClass ty VSpace >> eq ty e1 >> eq ty e2 >> return ty
  Cmp _  ty   a b -> eq ty a >> eq ty b >> return (BaseType BoolType)
  Select ty p a b -> eq ty a >> eq ty b >> eq (BaseType BoolType) p >> return ty
  MonadRun r s (Monad (Effect r' w s') a) -> do
    eq r r' >> eq s s'
    return $ tupTy [a, w, s]
  LensGet a (Lens a' b) -> eq a a' >> return b
  Linearize (a, b) -> return (a --> pairTy b (a --@ b))
  Transpose (a, b) -> return (b --@ a)
  IntAsIndex ty i  -> eq (BaseType IntType) i >> return ty
  IdxSetSize _     -> return $ BaseType IntType
  NewtypeCast ty _ -> return ty
  FFICall _ argTys ansTy argTys' -> zipWithM_ eq argTys argTys' >> return ansTy
  _ -> error $ "Unexpected primitive type: " ++ pprint op
traversePrimExprType (ConExpr con) eq inClass = case con of
  Lit l       -> return $ BaseType $ litType l
  Lam l (a,b) -> return $ ArrowType l a b
  RecCon r    -> return $ RecType r
  AFor n a                -> return $ TabType n a
  AGet (ArrayType _ b) -> return $ BaseType b  -- TODO: check shape matches AFor scope
  AsIdx n e -> eq e (BaseType IntType) >> return (IdxSetLit n)
  Bind (Monad eff a) (a', (Monad eff' b)) -> do
    zipWithM_ eq (toList eff) (toList eff')
    eq a a'
    return $ Monad eff b
  MonadCon eff@(Effect r w s) x l m -> case m of
    MAsk     -> eq (Lens r x) l            >> return (Monad eff x)
    MTell x' -> eq (Lens w x) l >> eq x x' >> return (Monad eff unitTy)
    MGet     -> eq (Lens s x) l            >> return (Monad eff x)
    MPut  x' -> eq (Lens s x) l >> eq x x' >> return (Monad eff unitTy)
  Return eff a -> return (Monad eff a)
  LensCon l -> case l of
    IdxAsLens ty n -> return $ Lens (TabType n ty) ty
    LensId ty      -> return $ Lens ty ty
    LensCompose (Lens a b) (Lens b' c) -> eq b b' >> return (Lens a c)
  Seq (n, Monad eff a) -> return $ Monad eff (TabType n a)
  ArrayRef (Array shape b _) -> return $ ArrayType shape b
  Todo ty     -> return ty
  _ -> error $ "Unexpected primitive type: " ++ pprint con

binOpType :: ScalarBinOp -> (BaseType, BaseType, BaseType)
binOpType op = case op of
  IAdd   -> (i, i, i);  ISub   -> (i, i, i)
  IMul   -> (i, i, i);  ICmp _ -> (i, i, b)
  Pow    -> (i, i, i);  Rem    -> (i, i, i)
  FAdd   -> (r, r, r);  FSub   -> (r, r, r)
  FMul   -> (r, r, r);  FCmp _ -> (r, r, b)
  FDiv   -> (r, r, r);  And    -> (b, b, b)
  Or     -> (b, b, b)
  where b = BoolType
        i = IntType
        r = RealType

unOpType :: ScalarUnOp -> (BaseType, BaseType)
unOpType op = case op of
  Not        -> (BoolType, BoolType)
  FNeg       -> (RealType, RealType)
  IntToReal  -> (IntType, RealType)
  BoolToInt  -> (BoolType, IntType)
  _ -> error $ show op

flattenType :: Type -> [(BaseType, [Int])]
flattenType ty = case ty of
  BaseType b  -> [(b, [])]
  RecType r -> concat $ map flattenType $ toList r
  TabType (IdxSetLit n) a -> [(b, n:shape) | (b, shape) <- flattenType a]
  IdxSetLit _ -> [(IntType, [])]
  -- temporary hack. TODO: fix
  TabType _             a -> [(b, 0:shape) | (b, shape) <- flattenType a]
  TypeVar _               -> [(IntType, [])]
  _ -> error $ "Unexpected type: " ++ show ty

-- === linearity-aware traversal ===

class Applicative f => LinApplicative f where
  tensPure   :: a -> f a
  tensLiftA2 :: (a -> b -> c) -> f a -> f b -> f c
  withoutLin :: f a -> f a

class LinearTraversable f where
  traverseLin :: LinApplicative m
              => f e lam -> (e -> m e') -> (lam -> m lam') -> m (f e' lam')

instance LinearTraversable (PrimExpr Type) where
  traverseLin (OpExpr  e) f flam = liftA OpExpr  $ traverseLin e f flam
  traverseLin (ConExpr e) f flam = liftA ConExpr $ traverseLin e f flam

instance LinearTraversable (PrimOp Type) where
  traverseLin e f flam = case e of
    ScalarUnOp  FNeg x    -> liftA  (ScalarUnOp  FNeg) (f x)
    ScalarBinOp FAdd x y  -> liftA2 (ScalarBinOp FAdd) (f x) (f y)
    ScalarBinOp FSub x y  -> liftA2 (ScalarBinOp FSub) (f x) (f y)
    ScalarBinOp FDiv x y  -> tensLiftA2 (ScalarBinOp FDiv) (f x) (withoutLin (f y))
    ScalarBinOp FMul x y  -> tensLiftA2 (ScalarBinOp FMul) (f x) (f y)
    App (Mult Lin   ) fun x -> tensLiftA2 (App (Mult Lin)) (f fun) (f x)
    App (Mult NonLin) fun x ->   liftA2 (App (Mult NonLin)) (f fun) (withoutLin (f x))
    _ -> withoutLin $ traverseExpr e pure f flam

instance LinearTraversable (PrimCon Type) where
  traverseLin e f flam = case e of
    Lit (RealLit 0.0) -> pure $ Lit (RealLit 0.0)
    RecCon r -> liftA RecCon $ traverse f r
    _ -> withoutLin $ traverseExpr e pure f flam

-- === linearity ===

data Spent = Spent (Env ()) Bool  -- flag means 'may consume any linear vars'
newtype LinCheckM a = LinCheckM
  { runLinCheckM :: (ReaderT (Env Spent) (Either Err)) (a, Spent) }

checkLinFModule :: FModule -> Except ()
checkLinFModule (Module _ (FModBody decls)) =
  void $ runReaderT (runLinCheckM $ mapM_ checkLinFDecl decls) mempty

checkLinFExpr :: FExpr -> LinCheckM ()
checkLinFExpr expr = case expr of
  FVar v _ -> do
    env <- ask
    case envLookup env v of
      Nothing -> return ()
      Just s  -> spend s
  FDecl decl body -> do
    env <- checkLinFDecl decl
    extendR env (checkLinFExpr body)
  FPrimExpr (ConExpr (Lam (Mult Lin) (FLamExpr p body))) -> do
    v <- getPatName p
    let s = asSpent v
    checkSpent v (pprint p) $ extendR (foldMap (@>s) p) $ checkLinFExpr body
  FPrimExpr (ConExpr (Lam (Mult NonLin) lam)) -> checkLinFLam lam
  FPrimExpr e -> void $ traverseLin e checkLinFExpr checkLinFLam
  SrcAnnot e pos -> addSrcContext (Just pos) $ checkLinFExpr e
  Annot e _      -> checkLinFExpr e

checkLinFLam :: FLamExpr -> LinCheckM ()
checkLinFLam (FLamExpr _ body) = checkLinFExpr body

checkLinFDecl :: FDecl -> LinCheckM (Env Spent)
checkLinFDecl decl = case decl of
  LetMono p rhs -> do
    ((), spent) <- captureSpent $ checkLinFExpr rhs
    return $ foldMap (@>spent) p
  LetPoly _ (FTLam _ expr) -> do
    void $ checkLinFExpr expr
    return mempty
  _ -> return mempty

getPatName :: (MonadError Err m, Traversable f) => f Var -> m Name
getPatName p = case toList p of
  []  -> throw LinErr $
           "empty patterns not allowed for linear lambda (for silly reasons)"
  (v:>_):_ -> return v

spend :: Spent -> LinCheckM ()
spend s = LinCheckM $ return ((), s)

checkSpent :: Name -> String -> LinCheckM a -> LinCheckM a
checkSpent v vStr m = do
  (ans, Spent vs consumes) <- captureSpent m
  unless  (consumes || v' `isin` vs) $ throw LinErr $ "pattern never spent: " ++ vStr
  spend (Spent (vs `envDiff` (v'@>())) consumes)
  return ans
   where v' = v:>()

asSpent :: Name -> Spent
asSpent v = Spent ((v:>())@>()) False

tensCat :: Spent -> Spent -> Except Spent
tensCat (Spent vs consumes) (Spent vs' consumes') = do
  let overlap = envIntersect vs vs'
  unless (null overlap) $ throw LinErr $ "pattern spent twice: "
                                       ++ pprint (Spent overlap False)
  return $ Spent (vs <> vs') (consumes || consumes')

cartCat :: Spent -> Spent -> Except Spent
cartCat s1@(Spent vs consumes) s2@(Spent vs' consumes') = do
  unless (consumes  || vs' `containedWithin` vs ) $ throw LinErr errMsg
  unless (consumes' || vs  `containedWithin` vs') $ throw LinErr errMsg
  return $ Spent (vs <> vs') (consumes && consumes')
  where containedWithin x y = null $ x `envDiff` y
        errMsg = "different consumption by Cartesian product elements: "
                  ++ pprint s1 ++ " vs " ++ pprint s2

tensId :: Spent
tensId = Spent mempty False

cartId :: Spent
cartId = Spent mempty True

captureSpent :: LinCheckM a -> LinCheckM (a, Spent)
captureSpent m = LinCheckM $ do
  (x, s) <- runLinCheckM m
  return ((x, s), cartId)

instance Pretty Spent where
  pretty (Spent vs True ) = pretty (envNames vs ++ ["*"])
  pretty (Spent vs False) = pretty (envNames vs)

instance Functor LinCheckM where
  fmap = liftM

instance Applicative LinCheckM where
  pure x = LinCheckM $ return (x, cartId)
  (<*>) = ap

instance Monad LinCheckM where
  m >>= f = LinCheckM $ do
    (x, s1) <- runLinCheckM m
    (y, s2) <- runLinCheckM (f x)
    s <- liftEither $ cartCat s1 s2
    return (y, s)

instance MonadReader (Env Spent) LinCheckM where
  ask = LinCheckM $ do
    env <- ask
    return (env, cartId)
  local env (LinCheckM m) = LinCheckM $ local env m

instance MonadError Err LinCheckM where
  throwError err = LinCheckM $ throwError err
  catchError (LinCheckM m) f = LinCheckM $ catchError m (runLinCheckM . f)

instance LinApplicative LinCheckM where
  tensPure x = LinCheckM $ return (x, tensId)
  tensLiftA2 f x y = LinCheckM $ do
    (x', sx) <- runLinCheckM x
    (y', sy) <- runLinCheckM y
    sxy <- liftEither $ tensCat sx sy
    return (f x' y', sxy)
  withoutLin (LinCheckM m) = LinCheckM $ do
    (ans, s@(Spent vs _)) <- m
    unless (null vs) $ throw LinErr $
      "nonlinear function consumed linear data: " ++ pprint s
    return (ans, tensId)
