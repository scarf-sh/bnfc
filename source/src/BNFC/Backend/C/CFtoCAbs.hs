{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE PatternGuards     #-}
{-# LANGUAGE OverloadedStrings #-}

{-
    BNF Converter: C Abstract syntax
    Copyright (C) 2004  Author:  Michael Pellauer

    Description   : This module generates the C Abstract Syntax
                    tree classes. It generates both a Header file
                    and an Implementation file, and Appel's C
                    method.

    Author        : Michael Pellauer
    Created       : 15 September, 2003
-}

module BNFC.Backend.C.CFtoCAbs (cf2CAbs) where

import Prelude hiding ((<>))
import Data.Char     ( toLower )
import Data.Either   ( lefts )
import Data.Function ( on )
import Data.List     ( groupBy, intercalate, nub, sort )
import Data.Maybe    ( mapMaybe )

import BNFC.CF
import BNFC.PrettyPrint
import BNFC.Options  ( RecordPositions(..) )
import BNFC.Utils    ( (+++), uncurry3, unless )
import BNFC.Backend.Common.NamedVariables


-- | The result is two files (.H file, .C file)
cf2CAbs
  :: RecordPositions
  -> String -- ^ Ignored.
  -> CF     -- ^ Grammar.
  -> (String, String) -- ^ @.H@ file, @.C@ file.
cf2CAbs rp _ cf = (mkHFile rp classes datas cf, mkCFile datas cf)
  where
  datas :: [Data]
  datas = getAbstractSyntax cf
  classes :: [String]
  classes = nub $ map (identCat . fst) datas

{- **** Header (.H) File Functions **** -}

-- | Makes the Header file.

mkHFile :: RecordPositions -> [String] -> [Data] -> CF -> String
mkHFile rp classes datas cf = unlines $ concat
  [ [ "#ifndef ABSYN_HEADER"
    , "#define ABSYN_HEADER"
    , ""
    , "/* C++ Abstract Syntax Interface generated by the BNF Converter.*/"
    , ""
    , prTypeDefs user
    , "/********************   Forward Declarations    ***********************/"
    ]
  , map prForward classes

  , [ "/********************   Abstract Syntax Classes    ********************/"
    , ""
    ]
  , map (prDataH rp) datas

  , unless (null classes) $ concat
    [ destructorComment
    , map prFreeH classes
    , [ "" ]
    ]

  , unless (null definedConstructors)
    [ "/********************   Defined Constructors    ***********************/"
    , ""
    ]
  , map (uncurry3 (prDefH user)) definedConstructors

  , [ ""
    , "#endif"
    ]
  ]
  where
  user  :: [TokenCat]
  user   = tokenNames cf
  prForward :: String -> String
  prForward s = unlines
    [ "struct " ++ s ++ "_;"
    , "typedef struct " ++ s ++ "_ *" ++ s ++ ";"
    ]
  prFreeH :: String -> String
  prFreeH s = "void free" ++ s ++ "(" ++ s ++ " p);"
  definedConstructors = [ (funName f, xs, e) | FunDef f xs e <- cfgPragmas cf ]

destructorComment :: [String]
destructorComment =
  [ "/********************   Recursive Destructors    **********************/"
  , ""
  , "/* These free an entire abstract syntax tree"
  , " * including all subtrees and strings."
  , " */"
  , ""
  ]

-- | For @define@d constructors, make a CPP definition.
--
-- >>> prDefH [] "iSg" ["i"] (App "ICons" [Var "i", App "INil" []])
-- "#define make_iSg(i) make_ICons(i,make_INil())"
--
-- >>> prDefH [] "snoc" ["xs","x"] (App "Cons" [Var "x", Var "xs"])
-- "#define make_snoc(xs,x) make_Cons(x,xs)"
--
prDefH
  :: [TokenCat] -- ^ Names of the token constructors (silent in C backend).
  -> String     -- ^ Name of the defined constructor.
  -> [String]   -- ^ Names of the arguments.
  -> Exp        -- ^ Definition (referring to arguments and rule labels).
  -> String
prDefH tokenCats f xs e = concat [ "#define make_", f, "(", intercalate "," xs, ") ", prExp e ]
  where
  prExp :: Exp -> String
  prExp = \case
    Var x       -> x
    -- Andreas, 2021-02-13, issue #338
    -- Token categories are just @typedef@s in C, so no constructor needed.
    App g [e] | g `elem` tokenCats
                -> prExp e
    App g es    -> concat [ "make_", g, "(", intercalate "," (map prExp es), ")" ]
    LitInt    i -> show i
    LitDouble d -> show d
    LitChar   c -> show c
    LitString s -> concat [ "strdup(", show s, ")" ]  -- so that free() does not crash!

-- | Prints struct definitions for all categories.
prDataH :: RecordPositions -> Data -> String
prDataH rp (cat, rules)
  | isList cat = unlines
      [ "struct " ++ c' ++ "_"
      , "{"
      , "  " ++ mem +++ varName mem ++ ";"
      , "  " ++ c' +++ varName c' ++ ";"
      , "};"
      , ""
      , c' ++ " make_" ++ c' ++ "(" ++ mem ++ " p1, " ++ c' ++ " p2);"
      ]
  | otherwise = unlines $ concat
    [ [ "struct " ++ show cat ++ "_"
      , "{"
      ]
    , [ "  int line_number, char_number;" | rp == RecordPositions ]
    , [ "  enum { " ++ intercalate ", " (map prKind rules) ++ " } kind;"
      , "  union"
      , "  {"
      , concatMap prUnion rules ++ "  } u;"
      , "};"
      , ""
      ]
    , concatMap (prRuleH cat) rules
    ]
  where
    c' = identCat (normCat cat)
    mem = identCat (normCatOfList cat)
    prKind (fun, _) = "is_" ++ fun
    prUnion (_, []) = ""
    prUnion (fun, cats) = "    struct { " ++ (render $ prInstVars (getVars cats)) ++ " } " ++ (memName fun) ++ ";\n"


-- | Interface definitions for rules vary on the type of rule.
prRuleH :: Cat -> (Fun, [Cat]) -> [String]
prRuleH c (fun, cats)
  | isNilFun fun || isOneFun fun || isConsFun fun = [] -- these are not represented in the AbSyn
  | otherwise = return $ concat
      [ catToStr c, " make_", fun, "(", prParamsH (getVars cats), ");" ]
  where
    prParamsH :: [(String, a)] -> String
    prParamsH [] = "void"
    prParamsH ps = intercalate ", " $ zipWith par ps [0..]
      where par (t, _) n = t ++ " p" ++ show n

-- typedefs in the Header make generation much nicer.
prTypeDefs user = unlines $ concat
  [ [ "/********************   TypeDef Section    ********************/"
    , ""
    , "typedef int Integer;"
    , "typedef char Char;"
    , "typedef double Double;"
    , "typedef char* String;"
    , "typedef char* Ident;"
    ]
  , map prUserDef user
  ]
  where
    prUserDef s = "typedef char* " ++ s ++ ";"

-- | A class's instance variables. Print the variables declaration by grouping
-- together the variables of the same type.
-- >>> prInstVars [("A", 1)]
-- A a_1;
-- >>> prInstVars [("A",1),("A",2),("B",1)]
-- A a_1, a_2; B b_1;
prInstVars :: [IVar] -> Doc
prInstVars =
    hsep . map prInstVarsOneType . groupBy ((==) `on` fst) . sort
  where
    prInstVarsOneType ivars = text (fst (head ivars))
                              <+> hsep (punctuate comma (map prIVar ivars))
                              <> semi
    prIVar (s, i) = text (varName s) <> text (showNum i)

{- **** Implementation (.C) File Functions **** -}

-- | Makes the .C file
mkCFile :: [Data] -> CF -> String
mkCFile datas cf = concat
  [ header
  , render $ vsep $ concatMap prDataC datas
  , unlines [ "", "" ]
  , unlines destructorComment
  , unlines $ concatMap prDestructorC datas
  ]
  where
  header = unlines
    [ "/* C Abstract Syntax Implementation generated by the BNF Converter. */"
    , ""
    , "#include <stdio.h>"
    , "#include <stdlib.h>"
    , "#include \"Absyn.h\""
    , ""
    ]

-- |
-- >>> text $ unlines $ prDestructorC (Cat "Exp", [("EInt", [TokenCat "Integer"]), ("EAdd", [Cat "Exp", Cat "Exp"])])
-- void freeExp(Exp p)
-- {
--   switch(p->kind)
--   {
--   case is_EInt:
--     break;
-- <BLANKLINE>
--   case is_EAdd:
--     freeExp(p->u.eadd_.exp_1);
--     freeExp(p->u.eadd_.exp_2);
--     break;
-- <BLANKLINE>
--   default:
--     fprintf(stderr, "Error: bad kind field when freeing Exp!\n");
--     exit(1);
--   }
--   free(p);
-- }
-- <BLANKLINE>
-- <BLANKLINE>
prDestructorC :: Data -> [String]
prDestructorC (cat, rules)
  | isList cat = concat
    [ [ "void free" ++ cl ++ "("++ cl +++ vname ++ ")"
      , "{"
      , "  if (" ++ vname +++ "!= 0)"
      , "  {"
      ]
    , map ("    " ++) visitMember
    , [ "    free" ++ cl ++ "(" ++ vname ++ "->" ++ vname ++ "_);"
      , "    free(" ++ vname ++ ");"
      , "  }"
      , "}"
      , ""
      ]
    ]
  | otherwise = concat
    [ [ "void free" ++ cl ++ "(" ++ cl ++ " p)"
      , "{"
      , "  switch(p->kind)"
      , "  {"
      ]
    , concatMap prFreeRule rules
    , [ "  default:"
      , "    fprintf(stderr, \"Error: bad kind field when freeing " ++ cl ++ "!\\n\");"
      , "    exit(1);"
      , "  }"
      , "  free(p);"
      , "}"
      , ""
      ]
    ]
  where
  cl          = identCat cat
  vname       = map toLower cl
  visitMember =
    case ecat of
      TokenCat c
        | c `elem` ["Char", "Double", "Integer"] -> []
        | otherwise -> [ "free" ++ rest ]
      _             -> [ "free" ++ ecl ++ rest ]
    where
    rest   = "(" ++ vname ++ "->" ++ member ++ "_);"
    member = map toLower ecl
    ecl    = identCat ecat
    ecat   = normCatOfList cat

  prFreeRule :: (String, [Cat]) -> [String]
  prFreeRule (fun, cats) | not (isCoercion fun) = concat
    [ [ "  case is_" ++ fnm ++ ":"
      ]
    , map ("    " ++) $ mapMaybe (prFreeCat fnm) $ lefts $ numVars $ map Left cats
    , [ "    break;"
      , ""
      ]
    ]
    where
    fnm = funName fun
  prFreeRule _ = []

  -- | This goes on to recurse to the instance variables.

  prFreeCat :: String -> (Cat, Doc) -> Maybe String
  prFreeCat fnm (TokenCat c, nt)
    | c `elem` ["Char", "Double", "Integer"] = Nothing
      -- Only pointer need to be freed.
  prFreeCat fnm (cat, nt) = Just $ concat
      [ "free"
      , maybe (identCat $ normCat cat) (const "") $ maybeTokenCat cat
      , "(p->u."
      , map toLower fnm
      , "_.", render nt, ");"
      ]



prDataC :: Data -> [Doc]
prDataC (cat, rules) = map (prRuleC cat) rules

-- | Classes for rules vary based on the type of rule.
--
-- * Empty list constructor, these are not represented in the AbSyn
--
-- >>> prRuleC (ListCat (Cat "A")) ("[]", [Cat "A", Cat "B", Cat "B"])
-- <BLANKLINE>
--
-- * Linked list case. These are all built-in list functions.
-- Later we could include things like lookup, insert, delete, etc.
--
-- >>> prRuleC (ListCat (Cat "A")) ("(:)", [Cat "A", Cat "B", Cat "B"])
-- /********************   ListA    ********************/
-- <BLANKLINE>
-- ListA make_ListA(A p1, ListA p2)
-- {
--     ListA tmp = (ListA) malloc(sizeof(*tmp));
--     if (!tmp)
--     {
--         fprintf(stderr, "Error: out of memory when allocating ListA!\n");
--         exit(1);
--     }
--     tmp->a_ = p1;
--     tmp->lista_ = p2;
--     return tmp;
-- }
--
-- * Standard rule
--
-- >>> prRuleC (Cat "A") ("funa", [Cat "A", Cat "B", Cat "B"])
-- /********************   funa    ********************/
-- <BLANKLINE>
-- A make_funa(A p1, B p2, B p3)
-- {
--     A tmp = (A) malloc(sizeof(*tmp));
--     if (!tmp)
--     {
--         fprintf(stderr, "Error: out of memory when allocating funa!\n");
--         exit(1);
--     }
--     tmp->kind = is_funa;
--     tmp->u.funa_.a_ = p1;
--     tmp->u.funa_.b_1 = p2;
--     tmp->u.funa_.b_2 = p3;
--     return tmp;
-- }
prRuleC :: Cat -> (String, [Cat]) -> Doc
prRuleC _ (fun, _) | isNilFun fun || isOneFun fun = empty
prRuleC cat (fun, _) | isConsFun fun = vcat'
    [ "/********************   " <> c <> "    ********************/"
    , ""
    , c <+> "make_" <> c <> parens (text m <+> "p1" <> "," <+> c <+> "p2")
    , lbrace
    , nest 4 $ vcat'
        [ c <+> "tmp = (" <> c <> ") malloc(sizeof(*tmp));"
        , "if (!tmp)"
        , lbrace
        , nest 4 $ vcat'
            [ "fprintf(stderr, \"Error: out of memory when allocating " <> c <> "!\\n\");"
            , "exit(1);" ]
        , rbrace
        , text $ "tmp->" ++ m' ++ " = " ++ "p1;"
        , "tmp->" <> v <+> "=" <+> "p2;"
        , "return tmp;" ]
    , rbrace ]
  where
    icat = identCat (normCat cat)
    c = text icat
    v = text (map toLower icat ++ "_")
    ListCat c' = cat            -- We're making a list constructor, so we
                                -- expect a list category
    m = identCat (normCat c')
    m' = map toLower m ++ "_"
prRuleC c (fun, cats) = vcat'
    [ text $ "/********************   " ++ fun ++ "    ********************/"
    , ""
    , prConstructorC c fun vs cats ]
  where
    vs = getVars cats

-- | The constructor just assigns the parameters to the corresponding instance
-- variables.
-- >>> prConstructorC (Cat "A") "funa" [("A",1),("B",2)] [Cat "O", Cat "E"]
-- A make_funa(O p1, E p2)
-- {
--     A tmp = (A) malloc(sizeof(*tmp));
--     if (!tmp)
--     {
--         fprintf(stderr, "Error: out of memory when allocating funa!\n");
--         exit(1);
--     }
--     tmp->kind = is_funa;
--     tmp->u.funa_.a_ = p1;
--     tmp->u.funa_.b_2 = p2;
--     return tmp;
-- }
prConstructorC :: Cat -> String -> [IVar] -> [Cat] -> Doc
prConstructorC cat c vs cats = vcat'
    [ text (cat' ++ " make_" ++ c) <> parens args
    , lbrace
    , nest 4 $ vcat'
        [ text $ cat' ++ " tmp = (" ++ cat' ++ ") malloc(sizeof(*tmp));"
        , text "if (!tmp)"
        , lbrace
        , nest 4 $ vcat'
            [ text ("fprintf(stderr, \"Error: out of memory when allocating " ++ c ++ "!\\n\");")
            , text "exit(1);" ]
        , rbrace
        , text $ "tmp->kind = is_" ++ c ++ ";"
        , prAssigns c vs params
        , text "return tmp;" ]
    , rbrace ]
  where
    cat' = identCat (normCat cat)
    (types, params) = unzip (prParams cats)
    args = hsep $ punctuate comma $ zipWith (<+>) types params

-- | Prints the constructor's parameters. Returns pairs of type * name
-- >>> prParams [Cat "O", Cat "E"]
-- [(O,p1),(E,p2)]
prParams :: [Cat] -> [(Doc, Doc)]
prParams = zipWith prParam [1..]
  where
    prParam n c = (text (identCat c), text ("p" ++ show n))

-- | Prints the assignments of parameters to instance variables.
-- >>> prAssigns "A" [("A",1),("B",2)] [text "abc", text "def"]
-- tmp->u.a_.a_ = abc;
-- tmp->u.a_.b_2 = def;
prAssigns :: String -> [IVar] -> [Doc] -> Doc
prAssigns c vars params = vcat $ zipWith prAssign vars params
  where
    prAssign (t,n) p =
        text ("tmp->u." ++ c' ++ "_." ++ vname t n) <+> char '=' <+> p <> semi
    vname t n
      | n == 1, [_] <- filter ((t ==) . fst) vars
                  = varName t
      | otherwise = varName t ++ showNum n
    c' = map toLower c

{- **** Helper Functions **** -}

memName s = map toLower s ++ "_"
