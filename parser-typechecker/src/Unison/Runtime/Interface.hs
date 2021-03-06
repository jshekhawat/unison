{-# language DataKinds #-}
{-# language PatternGuards #-}
{-# language ScopedTypeVariables #-}

module Unison.Runtime.Interface
  ( startRuntime
  ) where

import GHC.Stack (HasCallStack)

import Control.Exception (try)
import Control.Monad (foldM, (<=<))

import Data.Bifunctor (first)
import Data.Foldable
import Data.IORef
import Data.Set as Set (Set, (\\), singleton, map, notMember, filter)
import Data.Traversable (for)
import Data.Word (Word64)

import qualified Data.Map.Strict as Map

import qualified Unison.ABT as Tm (substs)
import qualified Unison.Term as Tm
import Unison.Var (Var)

import Unison.DataDeclaration (declFields, declDependencies, Decl)
import qualified Unison.LabeledDependency as RF
import Unison.Reference (Reference)
import qualified Unison.Reference as RF

import Unison.Util.EnumContainers as EC

import Unison.Codebase.CodeLookup (CodeLookup(..))
import Unison.Codebase.Runtime (Runtime(..), Error)
import Unison.Codebase.MainTerm (builtinMain)

import Unison.Parser (Ann(External))
import Unison.PrettyPrintEnv
import Unison.TermPrinter

import Unison.Runtime.ANF
import Unison.Runtime.Builtin
import Unison.Runtime.Decompile
import Unison.Runtime.Exception
import Unison.Runtime.Machine (SEnv(SEnv), apply0)
import Unison.Runtime.MCode
import Unison.Runtime.Pattern
import Unison.Runtime.Stack

type Term v = Tm.Term v ()

data EvalCtx v
  = ECtx
  { freshTy :: Word64
  , freshTm :: Word64
  , refTy :: Map.Map RF.Reference Word64
  , refTm :: Map.Map RF.Reference Word64
  , combs :: EnumMap Word64 Combs
  , dspec :: DataSpec
  , backrefTy :: EnumMap Word64 RF.Reference
  , backrefTm :: EnumMap Word64 (Term v)
  , backrefComb :: EnumMap Word64 RF.Reference
  }

uncurryDspec :: DataSpec -> Map.Map (Reference,Int) Int
uncurryDspec = Map.fromList . concatMap f . Map.toList
  where
  f (r,l) = zipWith (\n c -> ((r,n),c)) [0..] $ either id id l

baseContext :: forall v. Var v => EvalCtx v
baseContext
  = ECtx
  { freshTy = fty
  , freshTm = ftm
  , refTy = builtinTypeNumbering
  , refTm = builtinTermNumbering
  , combs = mapSingleton 0
          . emitComb @v emptyRNs 0 mempty
        <$> numberedTermLookup
  , dspec = builtinDataSpec
  , backrefTy = builtinTypeBackref
  , backrefTm = Tm.ref () <$> builtinTermBackref
  , backrefComb = builtinTermBackref
  }
  where
  ftm = 1 + maximum builtinTermNumbering
  fty = 1 + maximum builtinTypeNumbering

allocTerm
  :: Var v
  => EvalCtx v
  -> RF.Reference
  -> Term v
  -> EvalCtx v
allocTerm ctx r tm = snd $ allocTerm' ctx r tm

allocTerm'
  :: Var v
  => EvalCtx v
  -> RF.Reference
  -> Term v
  -> (Word64, EvalCtx v)
allocTerm' ctx r tm
  | Just w <- Map.lookup r (refTm ctx) = (w, ctx)
  | rt <- freshTm ctx
  = (rt, ctx
       { refTm = Map.insert r rt $ refTm ctx
       , backrefTm = mapInsert rt tm $ backrefTm ctx
       , backrefComb = mapInsert rt r $ backrefComb ctx
       , freshTm = rt+1
       })

allocTermRef
  :: Var v
  => CodeLookup v IO ()
  -> EvalCtx v
  -> RF.Reference
  -> IO (EvalCtx v)
allocTermRef _  _   b@(RF.Builtin _)
  = die $ "Unknown builtin term reference: " ++ show b
allocTermRef cl ctx r@(RF.DerivedId i)
  = getTerm cl i >>= \case
      Nothing -> die $ "Unknown term reference: " ++ show r
      Just tm -> pure $ allocTerm ctx r tm

allocType
  :: EvalCtx v
  -> RF.Reference
  -> Either [Int] [Int]
  -> IO (EvalCtx v)
allocType _ b@(RF.Builtin _) _
  = die $ "Unknown builtin type reference: " ++ show b
allocType ctx r cons
  = pure $ ctx
         { refTy = Map.insert r rt $ refTy ctx
         , backrefTy = mapInsert rt r $ backrefTy ctx
         , dspec = Map.insert r cons $ dspec ctx
         , freshTy = fresh
         }
  where
  (rt, fresh)
    | Just rt <- Map.lookup r $ refTy ctx = (rt, freshTy ctx)
    | frsh <- freshTy ctx = (frsh, frsh + 1)

recursiveDeclDeps
  :: Var v
  => Set RF.LabeledDependency
  -> CodeLookup v IO ()
  -> Decl v ()
  -> IO (Set Reference, Set Reference)
recursiveDeclDeps seen0 cl d = do
    rec <- for (toList newDeps) $ \case
      RF.DerivedId i -> getTypeDeclaration cl i >>= \case
        Just d -> recursiveDeclDeps seen cl d
        Nothing -> pure mempty
      _ -> pure mempty
    pure $ (deps, mempty) <> fold rec
  where
  deps = declDependencies d
  newDeps = Set.filter (\r -> notMember (RF.typeRef r) seen0) deps
  seen = seen0 <> Set.map RF.typeRef deps

categorize :: RF.LabeledDependency -> (Set Reference, Set Reference)
categorize
  = either ((,mempty) . singleton) ((mempty,) . singleton)
  . RF.toReference

recursiveTermDeps
  :: Var v
  => Set RF.LabeledDependency
  -> CodeLookup v IO ()
  -> Term v
  -> IO (Set Reference, Set Reference)
recursiveTermDeps seen0 cl tm = do
    rec <- for (RF.toReference <$> toList (deps \\ seen0)) $ \case
      Left (RF.DerivedId i) -> getTypeDeclaration cl i >>= \case
        Just d -> recursiveDeclDeps seen cl d
        Nothing -> pure mempty
      Right (RF.DerivedId i) -> getTerm cl i >>= \case
        Just tm -> recursiveTermDeps seen cl tm
        Nothing -> pure mempty
      _ -> pure mempty
    pure $ foldMap categorize deps <> fold rec
  where
  deps = Tm.labeledDependencies tm
  seen = seen0 <> deps

collectDeps
  :: Var v
  => CodeLookup v IO ()
  -> Term v
  -> IO ([(Reference, Either [Int] [Int])], [Reference])
collectDeps cl tm = do
  (tys, tms) <- recursiveTermDeps mempty cl tm
  (, toList tms) <$> traverse getDecl (toList tys)
  where
  getDecl ty@(RF.DerivedId i) =
    (ty,) . maybe (Right []) declFields
      <$> getTypeDeclaration cl i
  getDecl r = pure (r,Right [])

loadDeps
  :: Var v
  => CodeLookup v IO ()
  -> EvalCtx v
  -> Term v
  -> IO (EvalCtx v)
loadDeps cl ctx tm = do
  (tys, tms) <- collectDeps cl tm
  -- TODO: terms
  ctx <- foldM (uncurry . allocType) ctx $ Prelude.filter p tys
  ctx <- foldM (allocTermRef cl) ctx $ Prelude.filter q tms
  pure $ foldl' compileAllocated ctx $ Prelude.filter q tms
  where
  p (r@RF.DerivedId{},_)
    =  r `Map.notMember` dspec ctx
    || r `Map.notMember` refTy ctx
  p _ = False

  q r@RF.DerivedId{} = r `Map.notMember` refTm ctx
  q _ = False

compileAllocated
  :: HasCallStack => Var v => EvalCtx v -> Reference -> EvalCtx v
compileAllocated ctx r
  | Just w <- Map.lookup r (refTm ctx)
  , Just tm <- EC.lookup w (backrefTm ctx)
  = compileTerm w tm ctx
  | otherwise
  = error "compileAllocated: impossible"

addCombs :: EvalCtx v -> Word64 -> Combs -> EvalCtx v
addCombs ctx w m = ctx { combs = mapInsert w m $ combs ctx }

-- addTermBackrefs :: EnumMap Word64 (Term v) -> EvalCtx v -> EvalCtx v
-- addTermBackrefs refs ctx = ctx { backrefTm = refs <> backrefTm ctx }

-- refresh :: Word64 -> EvalCtx v -> EvalCtx v
-- refresh w ctx = ctx { freshTm = w }

ref :: HasCallStack => Ord k => Show k => Map.Map k v -> k -> v
ref m k
  | Just x <- Map.lookup k m = x
  | otherwise = error $ "unknown reference: " ++ show k

compileTerm
  :: HasCallStack => Var v => Word64 -> Term v -> EvalCtx v -> EvalCtx v
compileTerm w tm ctx
  = addCombs ctx w
  . emitCombs (RN (ref $ refTy ctx) (ref $ refTm ctx)) w
  . superNormalize
  . lamLift
  . splitPatterns (dspec ctx)
  . saturate (uncurryDspec $ dspec ctx)
  $ tm

prepareEvaluation
  :: HasCallStack => Var v => Term v -> EvalCtx v -> (EvalCtx v, Word64)
prepareEvaluation (Tm.LetRecNamed' bs mn0) ctx0 = (ctx4, mid)
  where
  hcs = fmap (first RF.DerivedId) . Tm.hashComponents $ Map.fromList bs
  mn = Tm.substs (Map.toList $ Tm.ref () . fst <$> hcs) mn0
  rmn = RF.DerivedId $ Tm.hashClosedTerm mn

  ctx1 = foldl (uncurry . allocTerm) ctx0 hcs
  ctx2 = foldl (\ctx (r, _) -> compileAllocated ctx r) ctx1 hcs
  (mid, ctx3) = allocTerm' ctx2 rmn mn
  ctx4 = compileTerm mid mn ctx3
prepareEvaluation mn ctx0 = (ctx2, mid)
  where
  rmn = RF.DerivedId $ Tm.hashClosedTerm mn
  (mid, ctx1) = allocTerm' ctx0 rmn mn
  ctx2 = compileTerm mid mn ctx1


watchHook :: IORef Closure -> Stack 'UN -> Stack 'BX -> IO ()
watchHook r _ bstk = peek bstk >>= writeIORef r

evalInContext
  :: Var v
  => PrettyPrintEnv
  -> EvalCtx v
  -> Word64
  -> IO (Either Error (Term v))
evalInContext ppe ctx w = do
  r <- newIORef BlackHole
  let hook = watchHook r
      senv = SEnv
               (combs ctx)
               builtinForeigns
               (backrefComb ctx)
               (backrefTy ctx)
  result <- traverse (const $ readIORef r)
          . first prettyError
        <=< try $ apply0 (Just hook) senv w
  pure $ decom =<< result
  where
  decom = decompile (`EC.lookup`backrefTm ctx)
  prettyError (PE p) = p
  prettyError (BU c) = either id (pretty ppe) $ decom c

startRuntime :: Var v => IO (Runtime v)
startRuntime = do
  ctxVar <- newIORef baseContext
  pure $ Runtime
       { terminate = pure ()
       , evaluate = \cl ppe tm -> do
           ctx <- readIORef ctxVar
           ctx <- loadDeps cl ctx tm
           writeIORef ctxVar ctx
           (ctx, init) <- pure $ prepareEvaluation tm ctx
           evalInContext ppe ctx init
       , mainType = builtinMain External
       , needsContainment = False
       }
