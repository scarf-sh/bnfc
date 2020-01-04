{-
    BNF Converter: Happy Generator
    Copyright (C) 2004  Author:  Markus Forberg, Aarne Ranta

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, 51 Franklin Street, Fifth Floor, Boston, MA 02110-1335, USA
-}

module BNFC.Backend.Haskell.CFtoHappy (cf2Happy, convert) where

import Prelude hiding ((<>))

import Data.Char
import Data.List (intersperse)

import BNFC.CF
import BNFC.Backend.Common.StrUtils (escapeChars)
import BNFC.Backend.Haskell.Utils
import BNFC.Options (HappyMode(..), TokenText(..))
import BNFC.PrettyPrint
import BNFC.Utils

-- Type declarations

type Rules       = [(NonTerminal,[(Pattern,Action)])]
type Pattern     = String
type Action      = String
type MetaVar     = String

-- default naming

tokenName   = "Token"

-- | Generate a happy parser file from a grammar.

cf2Happy
  :: ModuleName -- ^ This module's name.
  -> ModuleName -- ^ Abstract syntax module name.
  -> ModuleName -- ^ Lexer module name.
  -> HappyMode  -- ^ Happy mode.
  -> TokenText  -- ^ Use @ByteString@ or @Text@?
  -> Bool       -- ^ AST is a functor?
  -> CF         -- ^ Grammar.
  -> String     -- ^ Generated code.
cf2Happy name absName lexName mode tokenText functor cf = unlines
  [ header name absName lexName tokenText
  , render $ declarations mode (allEntryPoints cf)
  , render $ tokens cf
  , delimiter
  , specialRules absName tokenText cf
  , render $ prRules absName functor (rulesForHappy absName functor cf)
  , finalize absName functor cf
  ]

-- | Construct the header.
header :: ModuleName -> ModuleName -> ModuleName -> TokenText -> String
header modName absName lexName tokenText = unlines $ concat
  [ [ "-- This Happy file was machine-generated by the BNF converter"
    , "{"
    , "{-# OPTIONS_GHC -fno-warn-incomplete-patterns -fno-warn-overlapping-patterns #-}"
    , "module " ++ modName ++ " where"
    , "import qualified " ++ absName
    , "import " ++ lexName
    ]
  , tokenTextImport tokenText
  , [ "}"
    ]
  ]

-- | The declarations of a happy file.
-- >>> declarations Standard [Cat "A", Cat "B", ListCat (Cat "B")]
-- %name pA A
-- %name pB B
-- %name pListB ListB
-- -- no lexer declaration
-- %monad { Either String } { (>>=) } { return }
-- %tokentype {Token}
declarations :: HappyMode -> [Cat] -> Doc
declarations mode ns = vcat
    [ vcat $ map generateP ns
    , case mode of
        Standard -> "-- no lexer declaration"
        GLR      -> "%lexer { myLexer } { Either String _ }",
      "%monad { Either String } { (>>=) } { return }",
      "%tokentype" <+> braces (text tokenName)
    ]
  where
  generateP n = "%name" <+> parserName n <+> text (identCat n)

-- The useless delimiter symbol.
delimiter :: String
delimiter = "\n%%\n"

-- | Generate the list of tokens and their identifiers.
tokens :: CF -> Doc
tokens cf
  -- Andreas, 2019-01-02: "%token" followed by nothing is a Happy parse error.
  -- Thus, if we have no tokens, do not output anything.
  | null ts   = empty
  | otherwise = "%token" $$ (nest 2 $ vcat ts)
  where
    ts            = map prToken (cfTokens cf) ++ map text (specialToks cf)
    prToken (t,k) = hsep [ convert t, lbrace, text ("PT _ (TS _ " ++ show k ++ ")"), rbrace ]

-- Happy doesn't allow characters such as åäö to occur in the happy file. This
-- is however not a restriction, just a naming paradigm in the happy source file.
convert :: String -> Doc
convert = quotes . text . escapeChars

rulesForHappy :: ModuleName -> Bool -> CF -> Rules
rulesForHappy absM functor cf = for (ruleGroups cf) $ \ (cat, rules) ->
  (cat, map (constructRule absM functor) rules)

-- | For every non-terminal, we construct a set of rules. A rule is a sequence
-- of terminals and non-terminals, and an action to be performed.
--
-- >>> constructRule "Foo" False (Rule "EPlus" (Cat "Exp") [Left (Cat "Exp"), Right "+", Left (Cat "Exp")] Parsable)
-- ("Exp '+' Exp","Foo.EPlus $1 $3")
--
-- If we're using functors, it adds void value:
--
-- >>> constructRule "Foo" True (Rule "EPlus" (Cat "Exp") [Left (Cat "Exp"), Right "+", Left (Cat "Exp")] Parsable)
-- ("Exp '+' Exp","Foo.EPlus () $1 $3")
--
-- List constructors should not be prefixed by the abstract module name:
--
-- >>> constructRule "Foo" False (Rule "(:)" (ListCat (Cat "A")) [Left (Cat "A"), Right",", Left (ListCat (Cat "A"))] Parsable)
-- ("A ',' ListA","(:) $1 $3")
--
-- >>> constructRule "Foo" False (Rule "(:[])" (ListCat (Cat "A")) [Left (Cat "A")] Parsable)
-- ("A","(:[]) $1")
--
-- Coercion are much simpler:
--
-- >>> constructRule "Foo" True (Rule "_" (Cat "Exp") [Right "(", Left (Cat "Exp"), Right ")"] Parsable)
-- ("'(' Exp ')'","$2")
--
constructRule :: String -> Bool -> Rule -> (Pattern, Action)
constructRule absName functor (Rule fun _cat rhs Parsable) = (pattern, action)
  where
    (pattern, metavars) = generatePatterns rhs
    action | isCoercion fun                 = unwords metavars
           | isNilCons fun                  = unwords (qualify fun : metavars)
           | functor                        = unwords (qualify fun : "()" : metavars)
           | otherwise                      = unwords (qualify fun : metavars)
    qualify f
      | isConsFun f || isNilCons f = f
      | isDefinedRule f = f ++ "_"  -- Definitions are local to Par.hs, not in Abs.hs
      | otherwise       = absName ++ "." ++ f


-- | Generate patterns and a set of metavariables (de Bruijn indices) indicating
--   where in the pattern the non-terminal are locate.
--
-- >>> generatePatterns [ Left (Cat "Exp"), Right "+", Left (Cat "Exp") ]
-- ("Exp '+' Exp",["$1","$3"])
--
generatePatterns :: SentForm -> (Pattern, [MetaVar])
generatePatterns []  = ("{- empty -}", [])
generatePatterns its =
  ( unwords $ for its $ either {-non-term:-} identCat {-term:-} (render . convert)
  , [ ('$' : show i) | (i, Left{}) <- zip [1 :: Int ..] its ]
  )

-- We have now constructed the patterns and actions,
-- so the only thing left is to merge them into one string.

-- |
-- >>> prRules "Foo" False [(Cat "Expr", [("Integer", "Foo.EInt $1"), ("Expr '+' Expr", "Foo.EPlus $1 $3")])]
-- Expr :: { Foo.Expr }
-- Expr : Integer { Foo.EInt $1 } | Expr '+' Expr { Foo.EPlus $1 $3 }
--
-- if there's a lot of cases, print on several lines:
-- >>> prRules "" False [(Cat "Expr", [("Abcd", "Action"), ("P2", "A2"), ("P3", "A3"), ("P4", "A4"), ("P5","A5")])]
-- Expr :: { Expr }
-- Expr : Abcd { Action }
--      | P2 { A2 }
--      | P3 { A3 }
--      | P4 { A4 }
--      | P5 { A5 }
--
-- >>> prRules "" False [(Cat "Internal", [])] -- nt has only internal use
-- <BLANKLINE>
--
-- The functor case:
-- >>> prRules "" True [(Cat "Expr", [("Integer", "EInt () $1"), ("Expr '+' Expr", "EPlus () $1 $3")])]
-- Expr :: { (Expr ()) }
-- Expr : Integer { EInt () $1 } | Expr '+' Expr { EPlus () $1 $3 }
--
-- A list with coercion: in the type signature we need to get rid of the
-- coercion.
--
-- >>> prRules "" True [(ListCat (CoercCat "Exp" 2), [("Exp2", "(:[]) $1"), ("Exp2 ',' ListExp2","(:) $1 $3")])]
-- ListExp2 :: { [Exp ()] }
-- ListExp2 : Exp2 { (:[]) $1 } | Exp2 ',' ListExp2 { (:) $1 $3 }
--
prRules :: ModuleName -> Bool -> Rules -> Doc
prRules absM functor = vcat . map prOne
  where
    prOne (_ , []      ) = empty -- nt has only internal use
    prOne (nt, (p,a):ls) =
        hsep [ nt', "::", "{", type' nt, "}" ]
        $$ nt' <+> sep (pr ":" (p, a) : map (pr "|") ls)
      where
        nt' = text (identCat nt)
        pr pre (p,a) = hsep [pre, text p, "{", text a , "}"]
    type' = catToType qualify $ if functor then "()" else empty
    qualify
      | null absM = id
      | otherwise = ((text absM <> ".") <>)

-- Finally, some haskell code.

finalize :: ModuleName -> Bool -> CF -> String
finalize absM functor cf = unlines $ concat $
  [ [ "{"
    , ""
    , "happyError :: [" ++ tokenName ++ "] -> Either String a"
    , "happyError ts = Left $"
    , "  \"syntax error at \" ++ tokenPos ts ++ "
    , "  case ts of"
    , "    []      -> []"
    , "    [Err _] -> \" due to lexer error\""
    , unwords
      [ "    t:_     -> \" before `\" ++"
      , "(prToken t)"
      -- , tokenTextUnpack tokenText "(prToken t)"
      , "++ \"'\""
      ]
    , ""
    , "myLexer = tokens"
    ]
  , definedRules absM functor cf
  , [ "}"
    ]
  ]

-- | Generate Haskell code for the @define@d constructors.
definedRules :: ModuleName -> Bool -> CF -> [String]
definedRules absM functor cf = [ mkDef f xs e | FunDef f xs e <- cfgPragmas cf ]
    where
        mkDef f xs e = unwords $ (f ++ "_") : xs' ++ ["=", show e']
            where
                xs' = addFunctorArg id $ map (++ "_") xs
                e'  = underscore e
        underscore (App x es)
            | isLower $ head x  = App (x ++ "_") es'
            | otherwise         = App (qual x)   es'
          where es' = addFunctorArg (`App` []) $ map underscore es
        underscore (Var x)      = Var (x ++ "_")
        underscore e@LitInt{}    = e
        underscore e@LitDouble{} = e
        underscore e@LitChar{}   = e
        underscore e@LitString{} = e
        qual x
          | null absM = x
          | otherwise = concat [ absM, ".", x ]
        -- Functor argument
        addFunctorArg g
          | functor = (g "_a" :)
          | otherwise = id

-- | GF literals.
specialToks :: CF -> [String]
specialToks cf = (`map` literals cf) $ \case
  "Ident"   -> "L_Ident  { PT _ (TV $$) }"
  "String"  -> "L_quoted { PT _ (TL $$) }"
  "Integer" -> "L_integ  { PT _ (TI $$) }"
  "Double"  -> "L_doubl  { PT _ (TD $$) }"
  "Char"    -> "L_charac { PT _ (TC $$) }"
  own       -> "L_" ++ own ++ " { PT _ (T_" ++ own ++ " " ++ posn ++ ") }"
    where posn = if isPositionCat cf own then "_" else "$$"

specialRules :: ModuleName -> TokenText -> CF -> String
specialRules absName tokenText cf = unlines . intersperse "" . (`map` literals cf) $ \case
    -- "Ident"   -> "Ident   :: { Ident }"
    --         ++++ "Ident    : L_ident  { Ident $1 }"
    "String"  -> "String  :: { String }"
            ++++ "String   : L_quoted { " ++ stringUnpack "$1" ++ " }"
    "Integer" -> "Integer :: { Integer }"
            ++++ "Integer  : L_integ  { (read (" ++ stringUnpack "$1" ++ ")) :: Integer }"
    "Double"  -> "Double  :: { Double }"
            ++++ "Double   : L_doubl  { (read (" ++ stringUnpack "$1" ++ ")) :: Double }"
    "Char"    -> "Char    :: { Char }"
            ++++ "Char     : L_charac { (read (" ++ stringUnpack "$1" ++ ")) :: Char }"
    own       -> own ++ " :: { " ++ qualify own ++ "}"
            ++++ own ++ "  : L_" ++ own ++ " { " ++ qualify own ++ posn ++ " }"
      where posn = if isPositionCat cf own then " (mkPosToken $1)" else " $1"
  where
    stringUnpack = tokenTextUnpack tokenText
    qualify
      | null absName = id
      | otherwise    = ((absName ++ ".") ++)
