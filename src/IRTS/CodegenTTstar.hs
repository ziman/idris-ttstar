{-# LANGUAGE PatternGuards #-}
module IRTS.CodegenTTstar (codegenTTstar) where

import IRTS.CodegenCommon
import IRTS.Lang hiding (lift)
import IRTS.Simplified
import IRTS.Defunctionalise hiding (lift)

import Idris.Core.TT
import Idris.Core.Evaluate

import Numeric
import Data.Maybe
import Data.Char
import Data.List
import Data.Ord
import qualified Data.Text as T
import qualified Data.Map as M

import Control.Applicative hiding (empty, Const)
import Control.Monad
import Control.Monad.Trans.State.Lazy
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Class

import Util.PrettyPrint

indent :: Doc -> Doc
indent = nest 2

blankLine :: Doc
blankLine = text ""

-- The prefix "_" makes all names "hidden".
-- This is useful when you import the generated module from Python code.
mangle :: Name -> String
mangle n = "_idris_" ++ concatMap mangleChar (showCG n)
  where
    mangleChar x
        | isAlpha x || isDigit x = [x]
        | otherwise = "_" ++ show (ord x) ++ "_"

-- Let's not mangle /that/ much. Especially function parameters
-- like e0 and e1 are nicer when readable.
cgName :: Name -> Doc
cgName (MN i n) | all (\x -> isAlpha x || x `elem` "_") (T.unpack n)
    = text $ T.unpack n ++ show i
cgName n = text (mangle n)  -- <?> show n  -- uncomment this to get a comment for *every* mangled name

-- We could generate from:
-- simpleDecls / defunDecls / liftDecls
codegenTTstar :: CodeGenerator
codegenTTstar ci = writeFile (outputFile ci) (render "-- " source)
  where
    source = vcat [cgDecl d $$ blankLine | d <- ttDecls ci]

cgDecl :: (Name, TTDecl) -> Doc
cgDecl (name, (def, rigCount, injectivity, accessibility, totality, metaInfo))
    = cgDef name def

cgDef :: Name -> Def -> Doc
cgDef n (Function ty body) =
    cgName n <+> text "\\:" <+> cgTm ty <+> text "=" <+> cgTm body <> dot
cgDef n (TyDecl ntype ty) =
    text "postulate" <+> cgName n <+> colon <+> cgTm ty <> dot
cgDef n (Operator ty arity defn) =
    text "-- operator" <+> cgName n <+> colon <+> cgTm ty
cgDef n (CaseOp cinfo ty args defn defn_simp cdefs) =
    cgName n <+> colon <+> cgTm ty <> dot
    $$ indent (vcat [
        cgClause n c | c <- defn
      ])

cgClause :: Name -> Either Term (Term, Term) -> Doc
cgClause fn (Left tm) = cgName fn <+> text "left:" <+> cgTm tm <> dot
cgClause fn (Right (lhs, rhs)) = cgTm lhs <+> text "=" <+> cgTm rhs <> dot

cgTm :: TT Name -> Doc
cgTm tm = text "(term)"

dot :: Doc
dot = text "."

    {-
    -- main file
    decls = defunDecls ci
    ctors = M.fromList [(n, tag) | (n, DConstructor n' tag arity) <- decls]
    definitions = vcat $ map (cgDef ctors) [d | d@(_, DFun _ _ _) <- decls]

    -- all exports
    exports = vcat $ concatMap cgExport (exportDecls ci)
    -}

{-
cgExport :: ExportIFace -> [Doc]
cgExport (Export _ffiName _fileName es) = map cgExportDecl es

cgExportDecl :: Export -> Doc
cgExportDecl (ExportFun fn (FStr en) (FIO ret) argTys)
    = cgExportFun fn en (length argTys)
cgExportDecl _ = empty  -- ignore everything else
-- Example: ExportFun Main.exports, greet (FStr "greet") (FIO (FCon PyUnit)) [] 

cgExportFun :: Name -> String -> Int -> Doc
cgExportFun fn en argCnt
    = (empty <?> "export: " ++ show fn)
    $+$ text "def" <+> cgApp (text en) (map text args) <> colon
    $+$ indent (
        cgApp
            (cgName (sMN 0 "APPLY"))
            [ cgApp (cgName fn)
                $ map text args
            , text "World"
            ]
    )
    $+$ text ""
  where
    args = ["arg" ++ show i | i <- [1..argCnt]]

bigParens :: Doc -> Doc
bigParens d = lparen $+$ indent d $+$ rparen

bigBraces :: Doc -> Doc
bigBraces d = lbrace $+$ indent d $+$ rbrace

cgTuple :: Int -> [Expr] -> Expr
cgTuple maxSize [] = parens empty  -- don't split empty tuples
cgTuple maxSize xs
    | size oneLiner <= maxSize = oneLiner
    | allSmall  = bigParens $ vsepLines lines  -- for arg lists where every item is just a token
    | otherwise = bigParens $ vsepLines xs
  where
    oneLiner = parens (hsep $ punctuate comma xs)
    vsepLines = vcat . punctuate comma
    allSmall = and [size x < 8 | x <- xs]
    lines = wrapLines 60 empty xs

    wrapLines :: Int -> Doc -> [Doc] -> [Doc]
    wrapLines w curLine []
        | size curLine == 0 = []
        | otherwise         = [curLine]
    wrapLines w curLine (x : xs)
        | curSize >= w = curLine : wrapLines w x xs
        | curSize == 0 = wrapLines w x xs
        | otherwise = wrapLines w (curLine <> comma <+> x) xs
      where
        curSize = size curLine

cgApp :: Expr -> [Expr] -> Expr
cgApp f args = f <> cgTuple maxWidth args
  where
    maxWidth = 80 - width f

-- Process one definition. The caller deals with constructor declarations,
-- we only deal with function definitions.
cgDef :: M.Map Name Int -> (Name, DDecl) -> Doc
cgDef ctors (n, DFun name' args body) =
    (empty <?> show name')
    $+$ (text "def" <+> cgApp (cgName n) (map cgName args) <> colon)
    $+$ indent (
        text "while" <+> text "True" <> colon  -- for tail calls
        $+$ indent (
                -- trace $+$  -- uncomment this line to enable printing traces
                statements
                $+$ text "return" <+> retVal
            )
        )
    $+$ text ""  -- empty line separating definitions
  where
    (statements, retVal) = evalState (runReaderT body' initCtx) initState
    body' = runCG . cgExp True $ body
    initCtx = CGCtx ctors (n, args)
    initState = CGState 1

    -- used only for debugging
    trace = text "print" <+> text (show $ mangle n ++ "(" ++ argfmt ++ ")")
                <+> text "%" <+> cgTuple 80 [text "repr" <> parens (cgName a) | a <- args]
    argfmt = intercalate ", " ["%s" | _ <- args]

cgVar :: LVar -> Expr
cgVar (Loc  i)
    | i >= 0    = text "loc" <> int i
    | otherwise = text "aux" <> int (-i)
cgVar (Glob n) = cgName n

cgError :: String -> Expr
cgError msg = text "_idris_error" <> parens (text $ show msg)

cgExtern :: String -> [Expr] -> Expr
cgExtern "prim__null" args = text "None"
cgExtern n args = cgError $ "unimplemented external: " ++ n

-- Notation for python bracketed[indexing].
(!) :: Expr -> String -> Expr
x ! i = x <> brackets (text i)

cgPOp :: String -> [Expr] -> Expr
cgPOp op [x, y] = parens $ x <+> text op <+> y

cgPFun :: String -> [Expr] -> Expr
cgPFun fun = cgApp $ text fun

cgPrim :: PrimFn -> [Expr] -> Expr
cgPrim (LPlus  _) = cgPOp "+"
cgPrim (LMinus _) = cgPOp "-"
cgPrim (LTimes _) = cgPOp "*"
cgPrim (LUDiv  _) = cgPOp "/"
cgPrim (LSDiv  _) = cgPOp "/"
cgPrim (LURem  _) = cgPOp "%"
cgPrim (LSRem  _) = cgPOp "%"

cgPrim (LAnd   _) = cgPOp "&"
cgPrim (LOr    _) = cgPOp "|"
cgPrim (LXOr   _) = cgPOp "^"
cgPrim (LSHL   _) = cgPOp "<<"
cgPrim (LASHR  _) = cgPOp ">>"
cgPrim (LLSHR  _) = cgPOp ">>"  -- because Python numbers have an infinite number of bits, LSHR and ASHR coincide
cgPrim (LCompl _) = \[x] -> text "~" <> x

cgPrim (LEq    _) = cgPOp "=="
cgPrim (LLt    _) = cgPOp "<"
cgPrim (LSLt   _) = cgPOp "<"
cgPrim (LLe    _) = cgPOp "<="
cgPrim (LSLe   _) = cgPOp "<="
cgPrim (LGt    _) = cgPOp ">"
cgPrim (LSGt   _) = cgPOp ">"
cgPrim (LGe    _) = cgPOp ">="
cgPrim (LSGe   _) = cgPOp ">="

-- this is probably not entirely right
cgPrim (LSExt _ _) = head
cgPrim (LZExt _ _) = head
cgPrim (LTrunc _ _) = head
cgPrim (LBitCast _ _) = head

cgPrim (LIntStr _) = cgPFun "str"
cgPrim (LStrInt _) = cgPFun "int"
cgPrim  LStrRev    = \[x] -> x ! "::-1"
cgPrim  LStrConcat = cgPOp "+"
cgPrim  LStrCons   = cgPOp "+"
cgPrim  LStrLt     = cgPOp "<"
cgPrim  LStrEq     = cgPOp "=="
cgPrim  LStrHead   = \[x] -> x ! "0"
cgPrim  LStrTail   = \[x] -> x ! "1:"
cgPrim  LStrIndex  = \[x,i] -> x <> brackets i
cgPrim  LStrLen    = cgPFun "len"

cgPrim LStrSubstr = \[ofs,len,s] -> s <> brackets (ofs <> colon <> cgPOp "+" [ofs,len])

cgPrim  (LChInt _) = cgPFun "ord"
cgPrim  (LIntCh _) = cgPFun "unichr"

cgPrim  LWriteStr = \[world, s] -> text "sys.stdout.write" <> parens s
cgPrim  LReadStr  = \_ -> text "sys.stdin.readline()"

cgPrim (LExternal n) = cgExtern $ show n
cgPrim (LIntFloat _) = cgPFun "float"
cgPrim (LFloatInt _) = cgPFun "int"
cgPrim LFloatStr = cgPFun "str"
cgPrim LStrFloat = cgPFun "float"

cgPrim LFExp = cgPFun "math.exp"
cgPrim LFLog = cgPFun "math.log"
cgPrim LFSin = cgPFun "math.sin"
cgPrim LFCos = cgPFun "math.cos"
cgPrim LFTan = cgPFun "math.tan"
cgPrim LFASin = cgPFun "math.asin"
cgPrim LFACos = cgPFun "math.acos"
cgPrim LFATan = cgPFun "math.atan"
cgPrim LFSqrt = cgPFun "math.sqrt"
cgPrim LFFloor = cgPFun "math.floor"
cgPrim LFCeil  = cgPFun "math.ceil"
cgPrim LFNegate = \[x] -> text "-" <> x

cgPrim f = \args -> cgError $ "unimplemented prim: " ++ show f ++ ", args = " ++ show args

cgConst :: Const -> Expr
cgConst (I i) = text $ show i
cgConst (BI i) = text $ show i
cgConst (Fl f) = text $ show f
cgConst (Ch c) = text $ pyShowStr [c]
cgConst (Str s) = text $ pyShowStr s
cgConst c = cgError $ "unimplemented constant: " ++ show c

pyShowStr :: String -> String
pyShowStr s = "u'" ++ concatMap pyShowChr s ++ "'"

pyShowChr :: Char -> String
pyShowChr '\'' = "\\'"
pyShowChr '\\' = "\\\\"
pyShowChr c
    | c >= ' ' && c < '\x7F'  = [c]
    | c <= '\xFFFF' = "\\u" ++ showHexN 4 (ord c)
    | otherwise     = "\\U" ++ showHexN 8 (ord c)

showHexN :: Int -> Int -> String
showHexN 0 _ = ""
showHexN w n =
  let (p,q) = n `divMod` 16
    in showHexN (w-1) p ++ showHex q ""

cgCtor :: Int -> Name -> [Expr] -> Expr
cgCtor tag n [] = parens (int tag <> comma) <?> show n
cgCtor tag n args = cgTuple 80 $ (int tag <?> show n) : args

cgAssign :: LVar -> Expr -> Stmts
cgAssign v e = cgVar v <+> text "=" <+> e

cgAssignN :: Name -> Expr -> Stmts
cgAssignN n e = cgName n <+> text "=" <+> e

cgAssignMany :: [Name] -> [Expr] -> Stmts
cgAssignMany ns es =
  hsep [cgName n <> comma | n <- ns]
  <+> text "="
  <+> hsep [e <> comma | e <- es]

-- pattern-matching / tuple decomposition
cgMatch :: [LVar] -> LVar -> Stmts
cgMatch []  rhs = empty
cgMatch [v] rhs = cgVar v <+> text "=" <+> cgVar rhs <> text "[1]"
cgMatch lhs rhs =
  hsep (punctuate comma $ map cgVar lhs)
  <+> text "="
  <+> cgVar rhs <> text "[1:]"

cgTailCall :: [Name] -> [Expr] -> CG Expr
cgTailCall argNames args = do
    emit $ cgAssignMany argNames args
    emit $ text "continue"
    return $ cgError "unreachable due to tail call"

cgExp :: Bool -> DExp -> CG Expr
cgExp tailPos (DV var) = return $ cgVar var
cgExp tailPos (DApp tc n args) = do
    tag <- ctorTag n
    case tag of
        Just t  -> cgExp True (DC Nothing t n args)  -- application of ctor
        Nothing -> do
            (curFn, argNames) <- currentFn
            if tailPos && n == curFn
               then cgTailCall argNames =<< mapM (cgExp False) args  -- tail call!
               else cgApp (cgName n)    <$> mapM (cgExp False) args  -- ordinary call

cgExp tailPos (DLet n v e) = do
    emit . cgAssignN n =<< cgExp False v
    cgExp tailPos e

cgExp tailPos (DUpdate n e) = return . cgError $ "unimplemented SUpdate for " ++ show n ++ " and " ++ show e

cgExp tailPos (DC _ tag n args)
    | Just (ctor, test, match) <- specialCased n = ctor <$> mapM (cgExp False) args
    | otherwise = cgCtor tag n <$> mapM (cgExp False) args

-- if the scrutinee is something big, save it into a variable
-- because we'll copy it into a possibly long chain of if-elif-...
cgExp tailPos (DCase caseType (DV var) alts) = cgCase tailPos var alts
cgExp tailPos (DCase caseType e alts) = do
    scrutinee <- fresh
    emit . cgAssign scrutinee =<< cgExp False e
    cgCase tailPos scrutinee alts

cgExp tailPos (DChkCase (DV var) alts) = cgCase tailPos var alts
cgExp tailPos (DChkCase e alts) = do
    scrutinee <- fresh
    emit . cgAssign scrutinee =<< cgExp False e
    cgCase tailPos scrutinee alts

cgExp tailPos (DProj e i) = do
    e <- cgExp False e
    return $ e ! show (i+1)

cgExp tailPos (DConst c) = return $ cgConst c

cgExp tailPos (DForeign fdesc (FStr fn) args) = cgApp (text fn) <$> mapM (cgExp False . snd) args
cgExp tailPos (DForeign fdesc rdesc args) = error $ "unrecognised foreign: " ++ show (fdesc, rdesc, args)
cgExp tailPos (DOp prim args) = cgPrim prim <$> mapM (cgExp False) args
cgExp tailPos  DNothing      = return $ text "None"
cgExp tailPos (DError msg) = return $ cgError msg

data IfElif = If | Elif | Else | Assert

zipIfElif :: [a] -> [(IfElif, a)]
zipIfElif [] = []
zipIfElif [x] = [(Assert, x)]
zipIfElif (x : xs) = (If, x) : elif xs
  where
    elif [x] = [(Else, x)]
    elif (x : xs) = (Elif, x) : elif xs
    elif [] = error "elif: can't happen"

-- We assume that all tags are different here
cgAltTree :: Int -> Int -> Maybe LVar -> LVar -> [(Int, DAlt)] -> CG ()
cgAltTree groupSize altCount retVar scrutinee alts
    | altCount > groupSize
    = do
        emit $ text "if" <+> cgVar scrutinee <> text "[0] <" <+> int firstHi <> colon
        sindent $ cgAltTree groupSize lo retVar scrutinee (take lo alts)
        emit $ text "else" <> colon
        sindent $ cgAltTree groupSize (altCount - lo) retVar scrutinee (drop lo alts)
  where
    lo = altCount `div` 2
    firstHi = fst (alts !! lo)

cgAltTree groupSize altCount retVar scrutinee alts
    = mapM_ (cgAlt scrutinee retVar) (zipIfElif $ map snd alts)

cgDictCase :: LVar -> [(Const, Expr)] -> [Expr] -> Expr
cgDictCase scrutinee items dflt =
    bigBraces (vcat $ punctuate comma items')
    <> case dflt of
        []  -> brackets $ cgVar scrutinee
        d:_ -> text ".get" <> parens (cgVar scrutinee <> comma <+> d)
  where
    items' = [ cgConst c <> colon <+> e | (c, e) <- items]

-- Returns True iff the CG action generates no statements.
isPureExpr :: CG Expr -> CG Bool
isPureExpr (CG e) = CG $ do
    (stmts, expr) <- e
    return (empty, size stmts == 0)

-- For case-expressions, we:
-- 1. generate a fresh var
-- 2. emit statements containing an if-elif-... chain that assigns to the var
-- 3. use the assigned var as the expression standing for the result
cgCase :: Bool -> LVar -> [DAlt] -> CG Expr
cgCase tailPos var [DDefaultCase e] = cgExp tailPos e

-- compile big constant-cases into dict lookups
cgCase tailPos var alts
    | length alts > 8
    , all isConstant alts = do
        exprs <- mapM (cgExp False) [e | DConstCase c e <- alts]        
        dflt  <- mapM (cgExp False) [e | DDefaultCase e <- alts]
        return $ cgDictCase
            var
            (zip [c | DConstCase c e <- alts] exprs)
            dflt
  where
    isConstant :: DAlt -> Bool
    isConstant (DConstCase _ _) = True
    isConstant (DDefaultCase _) = True
    isConstant _ = False

-- compile big constructor-cases into binary search on tags
cgCase tailPos var alts
    | altCount >= 2 * groupSize  -- there would be at least 2 full groups
    , DDefaultCase def : alts' <- reverse alts
    , all isConCase alts' = do
        taggedAlts <- sortBy (comparing fst) <$> mapM getTag alts'
        case tailPos of
            True -> do
                cgAltTree groupSize altCount Nothing var taggedAlts
                return $ cgError "unreachable due to case in tail position"
            False -> do
                retVar <- fresh
                cgAltTree groupSize altCount (Just retVar) var taggedAlts
                return $ cgVar retVar
  where
    groupSize = 3  -- smallest group size: (groupSize+1) `div` 2
    altCount = length alts

    isConCase :: DAlt -> Bool
    isConCase (DConCase _ _ _ _) = True
    isConCase _ = False

    getTag :: DAlt -> CG (Int, DAlt)
    getTag alt@(DConCase _ n _ _) = do
        Just tag <- ctorTag n
        return (tag, alt)

-- otherwise just do the linear if-elif thing
cgCase tailPos var alts
    | tailPos = do
        mapM_ (cgAlt var Nothing) (zipIfElif alts)
        return $ cgError "unreachable due to case in tail position"

    | not tailPos = do
        retVar <- fresh
        mapM_ (cgAlt var $ Just retVar) (zipIfElif alts)
        return $ cgVar retVar

ifCond :: IfElif -> Expr -> Stmts
ifCond If     cond = text "if" <+> cond <> colon
ifCond Elif   cond = text "elif" <+> cond <> colon
ifCond Else   cond = text "else" <> colon
ifCond Assert cond = text "assert" <+> cond

indentCond :: IfElif -> CG () -> CG ()
indentCond Assert = id
indentCond _      = sindent

cgAlt :: LVar -> Maybe LVar -> (IfElif, DAlt) -> CG ()
cgAlt v retVar (ie, DConCase tag' ctorName args e) = do
    case special of
        -- normal constructors
        Nothing -> do
            -- DConCase does not contain useful tags yet
            -- we need to find out by looking up by name
            Just tag <- ctorTag ctorName
            emit $ ifCond ie (cgVar v <> text "[0] ==" <+> int tag) <?> show ctorName

        -- special-cased constructors
        Just (ctor, test, match) ->
            emit $ ifCond ie (test $ cgVar v) <?> show ctorName

    -- statements conditioned by the if
    indentCond ie $ do
        -- project out the args
        case args of
            [] -> return ()
            _  -> emit $ case special of
                Nothing
                    -> cgMatch (map Glob args) v
                Just (ctor, test, match)
                    -> match (map cgName args) (cgVar v)

        -- evaluate the expression
        returnValue retVar e
  where
    special = specialCased ctorName

cgAlt v retVar (ie, DConstCase c e) = do
    emit $ ifCond ie (cgVar v <+> text "==" <+> cgConst c)
    indentCond ie $ returnValue retVar e

cgAlt v retVar (ie, DDefaultCase e) = do
    emit $ ifCond ie (text "True")  -- the Bool will hopefully never be used
    indentCond ie $ returnValue retVar e

returnValue :: Maybe LVar -> DExp -> CG ()
returnValue Nothing  e = emit . (text "return" <+>) =<< cgExp True e  -- we are in a tail position
returnValue (Just r) e = emit . cgAssign r =<< cgExp False e  -- we are not in a tail position

-- special-cased constructors
type SCtor  = [Expr] -> Expr
type STest  = Expr -> Expr
type SMatch = [Expr] -> Expr -> Expr

specialCased :: Name -> Maybe (SCtor, STest, SMatch)
specialCased n = lookup n
    -- Compile lists to a custom type that's iterable in Python (i.e. easy to call list() on).
    [ item "Prelude.List"  "::"      cons id        uncons
    , item "Prelude.List"  "Nil"     nil  falseTest nomatch

    -- Compile Idris booleans to Python booleans.
    , item "Prelude.Bool"  "True"    (\[] -> text "True")  id        nomatch
    , item "Prelude.Bool"  "False"   (\[] -> text "False") falseTest nomatch

    -- Compile (Just x) to (x) and Nothing to None.
    --
    -- Warning: no other value is allowed to compile to "None"!
    --
    -- If any value `n` of any type compiles to None, matching on `Just n`
    -- will take the `Nothing` branch, which is clearly incorrect.
    , item "Prelude.Maybe" "Just"    (\[x] -> x)          notNoneTest match
    , item "Prelude.Maybe" "Nothing" (\[] -> text "None") noneTest    nomatch

    -- Due to the above, Unit must compile to a custom constant, not None.
    , item ""              "MkUnit"  unit  noinspect nomatch
    , item "Builtins"      "MkPair"  tuple constTrue match
    ]
  where
    constTrue e = text "True"
    noneTest e = e <+> text "is None"
    notNoneTest e = e <+> text "is not None"
    falseTest e = text "not" <+> e
    nomatch args e = cgError $ show n ++ " should never be deconstructed"
    noinspect e = cgError $ show n ++ " should never be tested"

    unit  []   = text "Unit"
    tuple args = parens (hsep $ punctuate comma args)
    cons [h,t] = t <> text ".cons" <> parens h
    nil  []    = text "ConsList()"
    skip [x]   = x

    uncons args e = match args (e <> text ".head" <> comma <+> e <> text ".tail")
    match args e = hsep (punctuate comma args) <+> text "=" <+> e

    -- Every item says:
    -- 1. what the namespace is
    -- 2. what the name is
    -- 3. how to construct the thing, given its arguments
    -- 4. what to put in the if-statement to test for the thing, given the expression to test
    -- 5. how to project fields from the thing
    item :: String -> String -> SCtor -> STest -> SMatch -> (Name, (SCtor, STest, SMatch))
    item "" n ctor test match = (sUN n, (ctor, test, match))
    item ns n ctor test match = (sNS (sUN n) (reverse $ split '.' ns), (ctor, test, match))

    split :: Char -> String -> [String]
    split c "" = [""]
    split c (x : xs)
        | c == x    = "" : split c xs
        | otherwise = let ~(h:t) = split c xs in ((x:h) : t)
-}
