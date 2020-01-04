{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

-- | Type checker for defined syntax constructors @define f xs = e@.

module BNFC.TypeChecker
  ( -- * Type checker entry point
    checkDefinitions
  , Base(..)
  , -- * Backdoor for rechecking defined syntax constructors for list types
    checkDefinition'
  , buildContext, ctxTokens, isToken
  , ListConstructors(LC)
  ) where

import Control.Monad
import Control.Monad.Except (MonadError(..))

import Data.Char
import Data.Function (on)
import Data.List

import BNFC.CF

type Err = Either String

data Base = BaseT String
          | ListT Base
    deriving (Eq)

data Type = FunT [Base] Base
    deriving (Eq)

instance Show Base where
    show (BaseT x) = x
    show (ListT t) = "[" ++ show t ++ "]"

instance Show Type where
    show (FunT ts t) = unwords $ map show ts ++ ["->", show t]

data Context = Ctx
  { ctxLabels :: [(String, Type)]
  , ctxTokens :: [String]
  }

buildContext :: CF -> Context
buildContext cf@CFG{..} = Ctx
  { ctxLabels =
      [ (f, mkType cat args)
        | Rule f cat args _ <- cfgRules
        , not (isCoercion f)
        , not (isNilCons f)
      ]
  , ctxTokens =
      ("Ident" : tokenNames cf)
  }
  where
    mkType cat args = FunT [ mkBase t | Left t <- args ]
                           (mkBase cat)
    mkBase t
        | isList t  = ListT $ mkBase $ normCatOfList t
        | otherwise = BaseT $ show $ normCat t

isToken :: String -> Context -> Bool
isToken x ctx = elem x $ ctxTokens ctx

extendContext :: Context -> [(String,Type)] -> Context
extendContext ctx xs = ctx { ctxLabels = xs ++ ctxLabels ctx }

lookupCtx :: String -> Context -> Err Type
lookupCtx x ctx
    | isToken x ctx = return $ FunT [BaseT "String"] (BaseT x)
    | otherwise     =
    case lookup x $ ctxLabels ctx of
        Nothing -> throwError $ "Undefined symbol '" ++ x ++ "'."
        Just t  -> return t

-- | Entry point.
checkDefinitions :: CF -> Err ()
checkDefinitions cf =
    do  checkContext ctx
        sequence_ [checkDefinition ctx f xs e | FunDef f xs e <- cfgPragmas cf]
    where
        ctx = buildContext cf

checkContext :: Context -> Err ()
checkContext ctx =
    mapM_ checkEntry $ groupSnd $ ctxLabels ctx
    where
        -- This is a very handy function which transforms a lookup table
        -- with duplicate keys to a list valued lookup table with no duplicate
        -- keys.
        groupSnd :: Ord a => [(a,b)] -> [(a,[b])]
        groupSnd =
            map (\ ps -> (fst (head ps), map snd ps))
            . groupBy ((==) `on` fst)
            . sortBy (compare `on` fst)

        checkEntry (f,ts) =
            case nub ts of
                [_] -> return ()
                ts' ->
                    throwError $ "The symbol '" ++ f ++ "' is used at conflicting types:\n" ++
                            unlines (map (("  " ++) . show) ts')

checkDefinition :: Context -> String -> [String] -> Exp -> Err ()
checkDefinition ctx f xs e =
    void $ checkDefinition' dummyConstructors ctx f xs e

data ListConstructors = LC
        { nil   :: Base -> String
        , cons  :: Base -> String
        }

dummyConstructors :: ListConstructors
dummyConstructors = LC (const "[]") (const "(:)")

checkDefinition' :: ListConstructors -> Context -> String -> [String] -> Exp -> Err ([(String,Base)],(Exp,Base))
checkDefinition' list ctx f xs e =
    do  unless (isLower $ head f) $ throwError "Defined functions must start with a lowercase letter."
        t@(FunT ts t') <- lookupCtx f ctx `catchError` \_ ->
                                throwError $ "'" ++ f ++ "' must be used in a rule."
        let expect = length ts
            given  = length xs
        unless (expect == given) $ throwError $ "'" ++ f ++ "' is used with type " ++ show t ++ " but defined with " ++ show given ++ " argument" ++ plural given ++ "."
        e' <- checkExp list (extendContext ctx $ zip xs (map (FunT []) ts)) e t'
        return (zip xs ts, (e', t'))
    `catchError` \err -> throwError $ "In the definition " ++ unwords (f : xs ++ ["=",show e,";"]) ++ "\n  " ++ err
    where
        plural 1 = ""
        plural _ = "s"

checkExp :: ListConstructors -> Context -> Exp -> Base -> Err Exp
checkExp list ctx = curry $ \case
  (App "[]" []     , ListT t        ) -> return (App (nil list t) [])
  (App "[]" _      , _              ) -> throwError $
    "[] is applied to too many arguments."

  (App "(:)" [e,es], ListT t        ) -> do
    e'  <- checkExp list ctx e t
    es' <- checkExp list ctx es (ListT t)
    return $ App (cons list t) [e',es']

  (App "(:)" es    , _              ) -> throwError $
    "(:) takes 2 arguments, but has been given " ++ show (length es) ++ "."

  (e@(App x es)    , t              ) -> checkApp e x es t
  (e@(Var x)       , t              ) -> e <$ checkApp e x [] t
  (e@LitInt{}      , BaseT "Integer") -> return e
  (e@LitDouble{}   , BaseT "Double" ) -> return e
  (e@LitChar{}     , BaseT "Char"   ) -> return e
  (e@LitString{}   , BaseT "String" ) -> return e
  (e               , t              ) -> throwError $
    show e ++ " does not have type " ++ show t ++ "."
  where
  checkApp e x es t = do
    FunT ts t' <- lookupCtx x ctx
    es' <- matchArgs ts
    unless (t == t') $ throwError $ show e ++ " has type " ++ show t' ++ ", but something of type " ++ show t ++ " was expected."
    return $ App x es'
    where
    matchArgs ts
      | expect /= given   = throwError $ "'" ++ x ++ "' takes " ++ show expect ++ " arguments, but has been given " ++ show given ++ "."
      | otherwise         = zipWithM (checkExp list ctx) es ts
      where
        expect = length ts
        given  = length es
