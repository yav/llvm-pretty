{-# LANGUAGE CPP #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DeriveFunctor, DeriveGeneric #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecordWildCards #-}

#ifndef MIN_VERSION_base
#define MIN_VERSION_base(x,y,z) 1
#endif

module Text.LLVM.AST where

import Text.LLVM.Util (breaks,uncons)

import Control.Monad (MonadPlus(mzero,mplus),(<=<),msum,guard,liftM,liftM3)
import Data.Int (Int32,Int64)
import Data.List (genericIndex,genericLength)
import qualified Data.Map as Map
import Data.String (IsString(fromString))
import Data.Word (Word8,Word16,Word32,Word64)
import GHC.Generics (Generic, Generic1)

#if !(MIN_VERSION_base(4,8,0))
import Control.Applicative ((<$))
import Data.Foldable (Foldable(foldMap))
import Data.Monoid (Monoid(..))
import Data.Traversable (Traversable(sequenceA))
#endif


-- Modules ---------------------------------------------------------------------

data Module = Module
  { modSourceName :: Maybe String
  , modDataLayout :: DataLayout
  , modTypes      :: [TypeDecl]
  , modNamedMd    :: [NamedMd]
  , modUnnamedMd  :: [UnnamedMd]
  , modGlobals    :: [Global]
  , modDeclares   :: [Declare]
  , modDefines    :: [Define]
  , modInlineAsm  :: InlineAsm
  , modAliases    :: [GlobalAlias]
  } deriving (Show)

instance Monoid Module where
  mempty = emptyModule
  mappend m1 m2 = Module
    { modSourceName = modSourceName m1 `mplus`   modSourceName m2
    , modDataLayout = modDataLayout m1 `mappend` modDataLayout m2
    , modTypes      = modTypes      m1 `mappend` modTypes      m2
    , modUnnamedMd  = modUnnamedMd  m1 `mappend` modUnnamedMd  m2
    , modNamedMd    = modNamedMd    m1 `mappend` modNamedMd    m2
    , modGlobals    = modGlobals    m1 `mappend` modGlobals    m2
    , modDeclares   = modDeclares   m1 `mappend` modDeclares   m2
    , modDefines    = modDefines    m1 `mappend` modDefines    m2
    , modInlineAsm  = modInlineAsm  m1 `mappend` modInlineAsm  m2
    , modAliases    = modAliases    m1 `mappend` modAliases    m2
    }

emptyModule :: Module
emptyModule  = Module
  { modSourceName = mempty
  , modDataLayout = mempty
  , modTypes      = mempty
  , modNamedMd    = mempty
  , modUnnamedMd  = mempty
  , modGlobals    = mempty
  , modDeclares   = mempty
  , modDefines    = mempty
  , modInlineAsm  = mempty
  , modAliases    = mempty
  }


-- Named Metadata --------------------------------------------------------------

data NamedMd = NamedMd
  { nmName   :: String
  , nmValues :: [Int]
  } deriving (Show)


-- Unnamed Metadata ------------------------------------------------------------

data UnnamedMd = UnnamedMd
  { umIndex  :: !Int
  , umValues :: ValMd
  , umDistinct :: Bool
  } deriving (Show)


-- Aliases ---------------------------------------------------------------------

data GlobalAlias = GlobalAlias
  { aliasName   :: Symbol
  , aliasType   :: Type
  , aliasTarget :: Value
  } deriving (Show)


-- Data Layout -----------------------------------------------------------------

type DataLayout = [LayoutSpec]

data LayoutSpec
  = BigEndian
  | LittleEndian
  | PointerSize   !Int !Int (Maybe Int)
  | IntegerSize   !Int !Int (Maybe Int)
  | VectorSize    !Int !Int (Maybe Int)
  | FloatSize     !Int !Int (Maybe Int)
  | AggregateSize !Int !Int (Maybe Int)
  | StackObjSize  !Int !Int (Maybe Int)
  | NativeIntSize [Int]
  | StackAlign    !Int
  | Mangling Mangling
    deriving (Show)

data Mangling = ElfMangling
              | MipsMangling
              | MachOMangling
              | WindowsCoffMangling
                deriving (Show,Eq)

-- | Parse the data layout string.
parseDataLayout :: MonadPlus m => String -> m DataLayout
parseDataLayout  = mapM parseLayoutSpec . breaks (== '-')

-- | Parse a single layout specification from a string.
parseLayoutSpec :: MonadPlus m => String -> m LayoutSpec
parseLayoutSpec str = msum
  [ guard (str == "E") >> return BigEndian
  , guard (str == "e") >> return LittleEndian
  , do (i,rest) <- uncons str
       let body = breaks (== ':') rest
       case i of

         'S' -> do align <- parseInt rest
                   return (StackAlign align)

         'p' -> build PointerSize (tail body)
         'i' -> build IntegerSize       body
         'v' -> build VectorSize        body
         'f' -> build FloatSize         body
         'a' -> build AggregateSize     body
         's' -> build StackObjSize      body

         'n' -> do ints <- mapM parseInt body
                   return (NativeIntSize ints)

         'm' -> case tail body of
                  ["e"] -> return (Mangling ElfMangling)
                  ["m"] -> return (Mangling MipsMangling)
                  ["o"] -> return (Mangling MachOMangling)
                  ["w"] -> return (Mangling WindowsCoffMangling)
                  _     -> mzero

         _   -> mzero
  ]

  where

  build f lst = case lst of
    [sz,abi,pref] -> liftM3 f (parseInt sz) (parseInt abi) (parsePref pref)
    [sz,abi]      -> liftM3 f (parseInt sz) (parseInt abi) (return Nothing)
    _             -> mzero

  parsePref = liftM Just . parseInt

  parseInt s = case reads s of
    [(i,[])] -> return i
    _        -> mzero


-- Inline Assembly -------------------------------------------------------------

type InlineAsm = [String]

-- Identifiers -----------------------------------------------------------------

newtype Ident = Ident String
    deriving (Show,Eq,Ord)

instance IsString Ident where
  fromString = Ident

-- Symbols ---------------------------------------------------------------------

newtype Symbol = Symbol String
    deriving (Show,Eq,Ord)

instance Monoid Symbol where
  mappend (Symbol a) (Symbol b) = Symbol (mappend a b)
  mempty                        = Symbol mempty

instance IsString Symbol where
  fromString = Symbol

-- Types -----------------------------------------------------------------------

data PrimType
  = Label
  | Void
  | Integer Int32
  | FloatType FloatType
  | X86mmx
  | Metadata
    deriving (Eq, Ord, Show)

data FloatType
  = Half
  | Float
  | Double
  | Fp128
  | X86_fp80
  | PPC_fp128
    deriving (Eq, Ord, Show)

type Type = Type' Ident

data Type' ident
  = PrimType PrimType
  | Alias ident
  | Array Int32 (Type' ident)
  | FunTy (Type' ident) [Type' ident] Bool
  | PtrTo (Type' ident)
  | Struct [Type' ident]
  | PackedStruct [Type' ident]
  | Vector Int32 (Type' ident)
  | Opaque
    deriving (Eq, Ord, Show, Functor)

-- | Traverse a type, updating or removing aliases.
updateAliases :: (a -> Type' b) -> (Type' a -> Type' b)
updateAliases f = loop
  where
  loop ty = case ty of
    Array len ety    -> Array len    (loop ety)
    FunTy res ps var -> FunTy        (loop res) (map loop ps) var
    PtrTo pty        -> PtrTo        (loop pty)
    Struct fs        -> Struct       (map loop fs)
    PackedStruct fs  -> PackedStruct (map loop fs)
    Alias lab        -> f lab
    PrimType pty     -> PrimType pty
    Vector len ety   -> Vector len (loop ety)
    Opaque           -> Opaque


isFloatingPoint :: PrimType -> Bool
isFloatingPoint (FloatType _) = True
isFloatingPoint _             = False

isAlias :: Type -> Bool
isAlias Alias{} = True
isAlias _       = False

isPrimTypeOf :: (PrimType -> Bool) -> Type -> Bool
isPrimTypeOf p (PrimType pt) = p pt
isPrimTypeOf _ _             = False

isLabel :: PrimType -> Bool
isLabel Label = True
isLabel _     = False

isInteger :: PrimType -> Bool
isInteger Integer{} = True
isInteger _         = False

isVector :: Type -> Bool
isVector Vector{} = True
isVector _        = False

isVectorOf :: (Type -> Bool) -> Type -> Bool
isVectorOf p (Vector _ e) = p e
isVectorOf _ _            = False

isArray :: Type -> Bool
isArray ty = case ty of
  Array _ _ -> True
  _         -> False

isPointer :: Type -> Bool
isPointer (PtrTo _) = True
isPointer _         = False


-- Null Values -----------------------------------------------------------------

data NullResult lab
  = HasNull (Value' lab)
  | ResolveNull Ident

primTypeNull :: PrimType -> Value' lab
primTypeNull (Integer 1)    = ValBool False
primTypeNull (Integer _)    = ValInteger 0
primTypeNull (FloatType ft) = floatTypeNull ft
primTypeNull _              = ValZeroInit

floatTypeNull :: FloatType -> Value' lab
floatTypeNull Float = ValFloat 0
floatTypeNull _     = ValDouble 0 -- XXX not sure about this

typeNull :: Type -> NullResult lab
typeNull (PrimType pt) = HasNull (primTypeNull pt)
typeNull PtrTo{}       = HasNull ValNull
typeNull (Alias i)     = ResolveNull i
typeNull _             = HasNull ValZeroInit

-- Type Elimination ------------------------------------------------------------

elimFunTy :: MonadPlus m => Type -> m (Type,[Type],Bool)
elimFunTy (FunTy ret args va) = return (ret,args,va)
elimFunTy _                   = mzero

elimAlias :: MonadPlus m => Type -> m Ident
elimAlias (Alias i) = return i
elimAlias _         = mzero

elimPtrTo :: MonadPlus m => Type -> m Type
elimPtrTo (PtrTo ty) = return ty
elimPtrTo _          = mzero

elimVector :: MonadPlus m => Type -> m (Int32,Type)
elimVector (Vector n pty) = return (n,pty)
elimVector _              = mzero

elimArray :: MonadPlus m => Type -> m (Int32, Type)
elimArray (Array n ety) = return (n, ety)
elimArray _             = mzero

elimFunPtr :: MonadPlus m => Type -> m (Type,[Type],Bool)
elimFunPtr  = elimFunTy <=< elimPtrTo

elimPrimType :: MonadPlus m => Type -> m PrimType
elimPrimType (PrimType pt) = return pt
elimPrimType _             = mzero

elimFloatType :: MonadPlus m => PrimType -> m FloatType
elimFloatType (FloatType ft) = return ft
elimFloatType _              = mzero

-- | Eliminator for array, pointer and vector types.
elimSequentialType :: MonadPlus m => Type -> m Type
elimSequentialType ty = case ty of
  Array _ elTy -> return elTy
  PtrTo elTy   -> return elTy
  Vector _ pty -> return pty
  _            -> mzero


-- Top-level Type Aliases ------------------------------------------------------

data TypeDecl = TypeDecl
  { typeName  :: Ident
  , typeValue :: Type
  } deriving (Show)


-- Globals ---------------------------------------------------------------------

data Global = Global
  { globalSym   :: Symbol
  , globalAttrs :: GlobalAttrs
  , globalType  :: Type
  , globalValue :: Maybe Value
  , globalAlign :: Maybe Align
  } deriving Show

addGlobal :: Global -> Module -> Module
addGlobal g m = m { modGlobals = g : modGlobals m }

data GlobalAttrs = GlobalAttrs
  { gaLinkage    :: Maybe Linkage
  , gaConstant   :: Bool
  } deriving (Show)

emptyGlobalAttrs :: GlobalAttrs
emptyGlobalAttrs  = GlobalAttrs
  { gaLinkage  = Nothing
  , gaConstant = False
  }


-- Declarations ----------------------------------------------------------------

data Declare = Declare
  { decRetType :: Type
  , decName    :: Symbol
  , decArgs    :: [Type]
  , decVarArgs :: Bool
  } deriving (Show)

-- | The function type of this declaration
decFunType :: Declare -> Type
decFunType Declare { .. } = PtrTo (FunTy decRetType decArgs decVarArgs)


-- Function Definitions --------------------------------------------------------

data Define = Define
  { defAttrs    :: FunAttrs
  , defRetType  :: Type
  , defName     :: Symbol
  , defArgs     :: [Typed Ident]
  , defVarArgs  :: Bool
  , defSection  :: Maybe String
  , defBody     :: [BasicBlock]
  , defMetadata :: FnMdAttachments
  } deriving (Show)

defFunType :: Define -> Type
defFunType Define { .. } =
  PtrTo (FunTy defRetType (map typedType defArgs) defVarArgs)

addDefine :: Define -> Module -> Module
addDefine d m = m { modDefines = d : modDefines m }

data FunAttrs = FunAttrs
  { funLinkage :: Maybe Linkage
  , funGC      :: Maybe GC
  } deriving (Show)

emptyFunAttrs :: FunAttrs
emptyFunAttrs  = FunAttrs
  { funLinkage = Nothing
  , funGC      = Nothing
  }

-- Basic Block Labels ----------------------------------------------------------

data BlockLabel
  = Named Ident
  | Anon Int
    deriving (Eq,Ord,Show)

instance IsString BlockLabel where
  fromString str = Named (fromString str)

-- Basic Blocks ----------------------------------------------------------------

data BasicBlock' lab = BasicBlock
  { bbLabel :: Maybe lab
  , bbStmts :: [Stmt' lab]
  } deriving (Show)

type BasicBlock = BasicBlock' BlockLabel

brTargets :: BasicBlock' lab -> [lab]
brTargets (BasicBlock _ stmts) =
  case stmtInstr (last stmts) of
    Br _ t1 t2         -> [t1, t2]
    Invoke _ _ _ to uw -> [to, uw]
    Jump t             -> [t]
    Switch _ l ls      -> l : map snd ls
    IndirectBr _ ls    -> ls
    _                  -> []

-- Attributes ------------------------------------------------------------------

-- | Symbol Linkage
data Linkage
  = Private
  | LinkerPrivate
  | LinkerPrivateWeak
  | LinkerPrivateWeakDefAuto
  | Internal
  | AvailableExternally
  | Linkonce
  | Weak
  | Common
  | Appending
  | ExternWeak
  | LinkonceODR
  | WeakODR
  | External
  | DLLImport
  | DLLExport
    deriving (Eq,Show)

newtype GC = GC
  { getGC :: String
  } deriving (Show)

-- Typed Things ----------------------------------------------------------------

data Typed a = Typed
  { typedType  :: Type
  , typedValue :: a
  } deriving (Show,Functor)

instance Foldable Typed where
  foldMap f t = f (typedValue t)

instance Traversable Typed where
  sequenceA t = mk `fmap` typedValue t
    where
    mk b = t { typedValue = b }

mapMTyped :: Monad m => (a -> m b) -> Typed a -> m (Typed b)
mapMTyped f t = do
  b <- f (typedValue t)
  return t { typedValue = b }

-- Instructions ----------------------------------------------------------------

data ArithOp
  = Add Bool Bool
    {- ^ * Integral addition.
         * First boolean flag: check for unsigned overflow.
         * Second boolean flag: check for signed overflow.
         * If the checks fail, then the result is poisoned. -}
  | FAdd
    -- ^ Floating point addition.

  | Sub Bool Bool
    {- ^ * Integral subtraction.
         * First boolean flag: check for unsigned overflow.
         * Second boolean flag: check for signed overflow.
         * If the checks fail, then the result is poisoned. -}

  | FSub
    -- ^ Floating point subtraction.

  | Mul Bool Bool
    {- ^ * Integral multiplication.
         * First boolean flag: check for unsigned overflow.
         * Second boolean flag: check for signed overflow.
         * If the checks fail, then the result is poisoned. -}

  | FMul
    -- ^ Floating point multiplication.

  | UDiv Bool
    {- ^ * Integral unsigned division.
         * Boolean flag: check for exact result.
         * If the check fails, then the result is poisoned. -}

  | SDiv Bool
    {- ^ * Integral signed division.
         * Boolean flag: check for exact result.
         * If the check fails, then the result is poisoned. -}

  | FDiv
    -- ^ Floating point division.

  | URem
    -- ^ Integral unsigned reminder resulting from unsigned division.
    -- Division by 0 is undefined.

  | SRem
    -- ^ * Integral signded reminder resulting from signed division.
    --   * The sign of the reminder matches the divident (first parameter).
    --   * Division by 0 is undefined.

  | FRem
    -- ^ * Floating point reminder resulting from floating point division.
    --   * The reminder has the same sign as the divident (first parameter).

    deriving (Eq,Show)

isIArith :: ArithOp -> Bool
isIArith Add{}  = True
isIArith Sub{}  = True
isIArith Mul{}  = True
isIArith UDiv{} = True
isIArith SDiv{} = True
isIArith URem   = True
isIArith SRem   = True
isIArith _      = False

isFArith :: ArithOp -> Bool
isFArith  = not . isIArith

data BitOp
  = Shl Bool Bool
    {- ^ * Shift left.
         * First bool flag: check for unsigned overflow (i.e., shifted out a 1).
         * Second bool flag: check for signed overflow
              (i.e., shifted out something that does not match the sign bit)

         If a check fails, then the result is poisoned.

         The value of the second parameter must be strictly less than the
           nubmer of bits in the first parameter,
           otherwise the result is undefined.  -}

  | Lshr Bool
    {- ^ * Logical shift right.
         * The boolean is for exact check: posion the result,
              if we shift out a 1 bit (i.e., had to round).

    The value of the second parameter must be strictly less than the
    nubmer of bits in the first parameter, otherwise the result is undefined.
    -}

  | Ashr Bool
    {- ^ * Arithmetic shift right.
         * The boolean is for exact check: posion the result,
                if we shift out a 1 bit (i.e., had to round).

    The value of the second parameter must be strictly less than the
    nubmer of bits in the first parameter, otherwise the result is undefined.
    -}

  | And
  | Or
  | Xor
    deriving Show

data ConvOp
  = Trunc
  | ZExt
  | SExt
  | FpTrunc
  | FpExt
  | FpToUi
  | FpToSi
  | UiToFp
  | SiToFp
  | PtrToInt
  | IntToPtr
  | BitCast
    deriving Show

type Align = Int

data Instr' lab
  = Ret (Typed (Value' lab))
    {- ^ * Return from function with the given value.
         * Ends basic block. -}

  | RetVoid
    {- ^ * Return from function.
         * Ends basic block. -}

  | Arith ArithOp (Typed (Value' lab)) (Value' lab)
    {- ^ * Binary arithmetic operation, both operands have the same type.
         * Middle of basic block.
         * The result is the same as parameters. -}

  | Bit BitOp (Typed (Value' lab)) (Value' lab)
    {- ^ * Binary bit-vector operation, both operands have the same type.
         * Middle of basic block.
         * The result is the same as parameters. -}

  | Conv ConvOp (Typed (Value' lab)) Type
    {- ^ * Convert a value from one type to another.
         * Middle of basic block.
         * The result matches the 3rd parameter. -}

  | Call Bool Type (Value' lab) [Typed (Value' lab)]
    {- ^ * Call a function.
            The boolean is tail-call hint (XXX: needs to be updated)
         * Middle of basic block.
         * The result is as indicated by the provided type. -}

  | Alloca Type (Maybe (Typed (Value' lab))) (Maybe Int)
    {- ^ * Allocated space on the stack:
           type of elements;
           how many elements (1 if 'Nothing');
           required alignment.
         * Middle of basic block.
         * Returns a pointer to hold the given number of elemets. -}

  | Load (Typed (Value' lab)) (Maybe Align)
    {- ^ * Read a value from the given address:
           address to read from;
           assumptions about alignment of the given pointer.
         * Middle of basic block.
         * Returns a value of type matching the pointer. -}

  | Store (Typed (Value' lab)) (Typed (Value' lab)) (Maybe Align)
    {- ^ * Write a value to memory:
             value to store;
             pointer to location where to store;
             assumptions about the alignment of the given pointer.
         * Middle of basic block.
         * Effect. -}

  | ICmp ICmpOp (Typed (Value' lab)) (Value' lab)
    {- ^ * Compare two integral values.
         * Middle of basic block.
         * Returns a boolean value. -}

  | FCmp FCmpOp (Typed (Value' lab)) (Value' lab)
    {- ^ * Compare two floating point values.
         * Middle of basic block.
         * Returns a boolean value. -}

  | Phi Type [(Value' lab,lab)]
    {- ^ * Join point for an SSA value: we get one value per predecessor
           basic block.
         * Middle of basic block.
         * Returns a value of the specified type. -}

  | GEP Bool (Typed (Value' lab)) [Typed (Value' lab)]
    {- ^ * "Get element pointer",
            compute the address of a field in a structure:
            inbounds check (value poisoned if this fails);
            pointer to parent strucutre;
            path to a sub-component of a strucutre.
         * Middle of basic block.
         * Returns the address of the requiested member.

    The types in path are the types of the index, not the fields.

    The indexes are in units of a fields (i.e., the first element in
    a struct is field 0, the next one is 1, etc., regardless of the size
    of the fields in bytes). -}

  | Select (Typed (Value' lab)) (Typed (Value' lab)) (Value' lab)
    {- ^ * Local if-then-else; the first argument is boolean, if
           true pick the 2nd argument, otherwise evaluate to the 3rd.
         * Middle of basic block.
         * Returns either the 2nd or the 3rd argument. -}

  | ExtractValue (Typed (Value' lab)) [Int32]
    {- ^ * Get the value of a member of an aggregate value:
           the first argument is an aggregate value (not a pointer!),
           the second is a path of indexes, similar to the one in 'GEP'. 
         * Middle of basic block.
         * Returns the given member of the aggregate value. -}

  | InsertValue (Typed (Value' lab)) (Typed (Value' lab)) [Int32]
    {- ^ * Set the value for a member of an aggregate value:
           the first argument is the value to insert, the second is the
           aggreagate value to be modified.
         * Middle of basic block.
         * Returns an updated aggregate value. -}

  | ExtractElt (Typed (Value' lab)) (Value' lab)
    {- ^ * Get an element from a vector: the first argument is a vector,
           the second an index.
         * Middle of basic block.
         * Returns the element at the given positoin. -}

  | InsertElt (Typed (Value' lab)) (Typed (Value' lab)) (Value' lab)
    {- ^ * Modify an element of a vector: the first argument is the vector,
           the second the value to be inserted, the third is the index where
           to insert the value.
         * Middle of basic block.
         * Returns an updated vector. -}


  | ShuffleVector (Typed (Value' lab)) (Value' lab) (Typed (Value' lab))


  | Jump lab
    {- ^ * Jump to the given basic block.
         * Ends basic block. -}

  | Br (Typed (Value' lab)) lab lab
    {- ^ * Conditional jump: if the value is true jump to the first basic
           block, otherwise jump to the second.
         * Ends basic block. -}

  | Invoke Type (Value' lab) [Typed (Value' lab)] lab lab

  | Comment String
    -- ^ Comment

  | Unreachable
    -- ^ No defined sematics, we should not get to here.

  | Unwind
  | VaArg (Typed (Value' lab)) Type
  | IndirectBr (Typed (Value' lab)) [lab]

  | Switch (Typed (Value' lab)) lab [(Integer,lab)]
    {- ^ * Multi-way branch: the first value determines the direction 
           of the branch, the label is a default direction, if the value
           does not appear in the jump table, the last argument is the
           jump table.
         * Ends basic block. -}

  | LandingPad Type (Typed (Value' lab)) Bool [Clause' lab]

  | Resume (Typed (Value' lab))

    deriving (Show,Functor,Generic)

type Instr = Instr' BlockLabel

data Clause' lab
  = Catch  (Typed (Value' lab))
  | Filter (Typed (Value' lab))
    deriving (Show,Functor,Generic,Generic1)

type Clause = Clause' BlockLabel


isTerminator :: Instr' lab -> Bool
isTerminator instr = case instr of
  Ret{}        -> True
  RetVoid      -> True
  Jump{}       -> True
  Br{}         -> True
  Unreachable  -> True
  Unwind       -> True
  Invoke{}     -> True
  IndirectBr{} -> True
  Switch{}     -> True
  Resume{}     -> True
  _            -> False

isComment :: Instr' lab -> Bool
isComment Comment{} = True
isComment _         = False

isPhi :: Instr' lab -> Bool
isPhi Phi{} = True
isPhi _     = False

data ICmpOp = Ieq | Ine | Iugt | Iuge | Iult | Iule | Isgt | Isge | Islt | Isle
  deriving (Show)

data FCmpOp = Ffalse  | Foeq | Fogt | Foge | Folt | Fole | Fone
            | Ford    | Fueq | Fugt | Fuge | Fult | Fule | Fune
            | Funo    | Ftrue
    deriving (Show)


-- Values ----------------------------------------------------------------------

data Value' lab
  = ValInteger Integer
  | ValBool Bool
  | ValFloat Float
  | ValDouble Double
  | ValIdent Ident
  | ValSymbol Symbol
  | ValNull
  | ValArray Type [Value' lab]
  | ValVector Type [Value' lab]
  | ValStruct [Typed (Value' lab)]
  | ValPackedStruct [Typed (Value' lab)]
  | ValString String
  | ValConstExpr (ConstExpr' lab)
  | ValUndef
  | ValLabel lab
  | ValZeroInit
  | ValAsm Bool Bool String String
  | ValMd (ValMd' lab)
    deriving (Show,Functor,Generic,Generic1)

type Value = Value' BlockLabel

data ValMd' lab
  = ValMdString String
  | ValMdValue (Typed (Value' lab))
  | ValMdRef Int
  | ValMdNode [Maybe (ValMd' lab)]
  | ValMdLoc (DebugLoc' lab)
  | ValMdDebugInfo (DebugInfo' lab)
    deriving (Show,Functor,Generic,Generic1)

type ValMd = ValMd' BlockLabel

type KindMd = String
type FnMdAttachments = Map.Map KindMd ValMd

data DebugLoc' lab = DebugLoc
  { dlLine  :: Word32
  , dlCol   :: Word32
  , dlScope :: ValMd' lab
  , dlIA    :: Maybe (ValMd' lab)
  } deriving (Show,Functor,Generic,Generic1)

type DebugLoc = DebugLoc' BlockLabel

isConst :: Value' lab -> Bool
isConst ValInteger{}   = True
isConst ValBool{}      = True
isConst ValFloat{}     = True
isConst ValDouble{}    = True
isConst ValConstExpr{} = True
isConst ValZeroInit    = True
isConst ValNull        = True
isConst _              = False

-- Value Elimination -----------------------------------------------------------

elimValSymbol :: MonadPlus m => Value' lab -> m Symbol
elimValSymbol (ValSymbol sym) = return sym
elimValSymbol _               = mzero

elimValInteger :: MonadPlus m => Value' lab -> m Integer
elimValInteger (ValInteger i) = return i
elimValInteger _              = mzero

-- Statements ------------------------------------------------------------------

data Stmt' lab
  = Result Ident (Instr' lab) [(String,ValMd' lab)]
  | Effect (Instr' lab) [(String,ValMd' lab)]
    deriving (Show,Functor,Generic,Generic1)

type Stmt = Stmt' BlockLabel

stmtInstr :: Stmt' lab -> Instr' lab
stmtInstr (Result _ i _) = i
stmtInstr (Effect i _)   = i

stmtMetadata :: Stmt' lab -> [(String,ValMd' lab)]
stmtMetadata stmt = case stmt of
  Result _ _ mds -> mds
  Effect _ mds   -> mds

extendMetadata :: (String,ValMd' lab) -> Stmt' lab -> Stmt' lab
extendMetadata md stmt = case stmt of
  Result r i mds -> Result r i (md:mds)
  Effect i mds   -> Effect i (md:mds)


-- Constant Expressions --------------------------------------------------------

data ConstExpr' lab
  = ConstGEP Bool (Maybe Type) [Typed (Value' lab)]
  -- ^ Element type introduced in LLVM 3.7
  | ConstConv ConvOp (Typed (Value' lab)) Type
  | ConstSelect (Typed (Value' lab)) (Typed (Value' lab)) (Typed (Value' lab))
  | ConstBlockAddr Symbol lab
  | ConstFCmp FCmpOp (Typed (Value' lab)) (Typed (Value' lab))
  | ConstICmp ICmpOp (Typed (Value' lab)) (Typed (Value' lab))
  | ConstArith ArithOp (Typed (Value' lab)) (Value' lab)
  | ConstBit BitOp (Typed (Value' lab)) (Value' lab)
    deriving (Show,Functor,Generic,Generic1)

type ConstExpr = ConstExpr' BlockLabel

-- DWARF Debug Info ------------------------------------------------------------

data DebugInfo' lab
  = DebugInfoBasicType DIBasicType
  | DebugInfoCompileUnit (DICompileUnit' lab)
  | DebugInfoCompositeType (DICompositeType' lab)
  | DebugInfoDerivedType (DIDerivedType' lab)
  | DebugInfoExpression DIExpression
  | DebugInfoFile DIFile
  | DebugInfoGlobalVariable (DIGlobalVariable' lab)
  | DebugInfoLexicalBlock (DILexicalBlock' lab)
  | DebugInfoLexicalBlockFile (DILexicalBlockFile' lab)
  | DebugInfoLocalVariable (DILocalVariable' lab)
  | DebugInfoSubprogram (DISubprogram' lab)
  | DebugInfoSubrange DISubrange
  | DebugInfoSubroutineType (DISubroutineType' lab)
  deriving (Show,Functor,Generic,Generic1)

type DebugInfo = DebugInfo' BlockLabel

-- TODO: Turn these into sum types
-- See https://github.com/llvm-mirror/llvm/blob/release_38/include/llvm/Support/Dwarf.def
type DwarfAttrEncoding = Word8
type DwarfLang = Word16
type DwarfTag = Word16
type DwarfVirtuality = Word8
-- See https://github.com/llvm-mirror/llvm/blob/release_38/include/llvm/IR/DebugInfoMetadata.h#L175
type DIFlags = Word32
-- This seems to be defined internally as a small enum, and defined
-- differently across versions. Maybe turn this into a sum type once
-- it stabilizes.
type DIEmissionKind = Word8

data DIBasicType = DIBasicType
  { dibtTag :: DwarfTag
  , dibtName :: String
  , dibtSize :: Word64
  , dibtAlign :: Word64
  , dibtEncoding :: DwarfAttrEncoding
  } deriving (Show)

data DICompileUnit' lab = DICompileUnit
  { dicuLanguage           :: DwarfLang
  , dicuFile               :: Maybe (ValMd' lab)
  , dicuProducer           :: Maybe String
  , dicuIsOptimized        :: Bool
  , dicuFlags              :: DIFlags
  , dicuRuntimeVersion     :: Word16
  , dicuSplitDebugFilename :: Maybe FilePath
  , dicuEmissionKind       :: DIEmissionKind
  , dicuEnums              :: Maybe (ValMd' lab)
  , dicuRetainedTypes      :: Maybe (ValMd' lab)
  , dicuSubprograms        :: Maybe (ValMd' lab)
  , dicuGlobals            :: Maybe (ValMd' lab)
  , dicuImports            :: Maybe (ValMd' lab)
  , dicuMacros             :: Maybe (ValMd' lab)
  , dicuDWOId              :: Word64
  }
  deriving (Show,Functor,Generic,Generic1)

type DICompileUnit = DICompileUnit' BlockLabel

data DICompositeType' lab = DICompositeType
  { dictTag            :: DwarfTag
  , dictName           :: Maybe String
  , dictFile           :: Maybe (ValMd' lab)
  , dictLine           :: Word32
  , dictScope          :: Maybe (ValMd' lab)
  , dictBaseType       :: Maybe (ValMd' lab)
  , dictSize           :: Word64
  , dictAlign          :: Word64
  , dictOffset         :: Word64
  , dictFlags          :: DIFlags
  , dictElements       :: Maybe (ValMd' lab)
  , dictRuntimeLang    :: DwarfLang
  , dictVTableHolder   :: Maybe (ValMd' lab)
  , dictTemplateParams :: Maybe (ValMd' lab)
  , dictIdentifier     :: Maybe String
  }
  deriving (Show,Functor,Generic,Generic1)

type DICompositeType = DICompositeType' BlockLabel

data DIDerivedType' lab = DIDerivedType
  { didtTag :: DwarfTag
  , didtName :: Maybe String
  , didtFile :: Maybe (ValMd' lab)
  , didtLine :: Word32
  , didtScope :: Maybe (ValMd' lab)
  , didtBaseType :: Maybe (ValMd' lab)
  , didtSize :: Word64
  , didtAlign :: Word64
  , didtOffset :: Word64
  , didtFlags :: DIFlags
  , didtExtraData :: Maybe (ValMd' lab)
  }
  deriving (Show,Functor,Generic,Generic1)

type DIDerivedType = DIDerivedType' BlockLabel

data DIExpression = DIExpression
  { dieElements :: [Word64]
  }
  deriving (Show)

data DIFile = DIFile
  { difFilename  :: FilePath
  , difDirectory :: FilePath
  } deriving (Show)

data DIGlobalVariable' lab = DIGlobalVariable
  { digvScope                :: Maybe (ValMd' lab)
  , digvName                 :: Maybe String
  , digvLinkageName          :: Maybe String
  , digvFile                 :: Maybe (ValMd' lab)
  , digvLine                 :: Word32
  , digvType                 :: Maybe (ValMd' lab)
  , digvIsLocal              :: Bool
  , digvIsDefinition         :: Bool
  , digvVariable             :: Maybe (ValMd' lab)
  , digvDeclaration          :: Maybe (ValMd' lab)
  }
  deriving (Show,Functor,Generic,Generic1)

type DIGlobalVariable = DIGlobalVariable' BlockLabel

data DILexicalBlock' lab = DILexicalBlock
  { dilbScope  :: Maybe (ValMd' lab)
  , dilbFile   :: Maybe (ValMd' lab)
  , dilbLine   :: Word32
  , dilbColumn :: Word16
  }
  deriving (Show,Functor,Generic,Generic1)

type DILexicalBlock = DILexicalBlock' BlockLabel

data DILexicalBlockFile' lab = DILexicalBlockFile
  { dilbfScope         :: ValMd' lab
  , dilbfFile          :: Maybe (ValMd' lab)
  , dilbfDiscriminator :: Word32
  }
  deriving (Show,Functor,Generic,Generic1)

type DILexicalBlockFile = DILexicalBlockFile' BlockLabel

data DILocalVariable' lab = DILocalVariable
  { dilvScope :: Maybe (ValMd' lab)
  , dilvName :: Maybe String
  , dilvFile :: Maybe (ValMd' lab)
  , dilvLine :: Word32
  , dilvType :: Maybe (ValMd' lab)
  , dilvArg :: Word16
  , dilvFlags :: DIFlags
  }
  deriving (Show,Functor,Generic,Generic1)

type DILocalVariable = DILocalVariable' BlockLabel

data DISubprogram' lab = DISubprogram
  { dispScope          :: Maybe (ValMd' lab)
  , dispName           :: Maybe String
  , dispLinkageName    :: Maybe String
  , dispFile           :: Maybe (ValMd' lab)
  , dispLine           :: Word32
  , dispType           :: Maybe (ValMd' lab)
  , dispIsLocal        :: Bool
  , dispIsDefinition   :: Bool
  , dispScopeLine      :: Word32
  , dispContainingType :: Maybe (ValMd' lab)
  , dispVirtuality     :: DwarfVirtuality
  , dispVirtualIndex   :: Word32
  , dispFlags          :: DIFlags
  , dispIsOptimized    :: Bool
  , dispTemplateParams :: Maybe (ValMd' lab)
  , dispDeclaration    :: Maybe (ValMd' lab)
  , dispVariables      :: Maybe (ValMd' lab)
  }
  deriving (Show,Functor,Generic,Generic1)

type DISubprogram = DISubprogram' BlockLabel

data DISubrange = DISubrange
  { disrCount :: Int64
  , disrLowerBound :: Int64
  }
  deriving (Show)

data DISubroutineType' lab = DISubroutineType
  { distFlags :: DIFlags
  , distTypeArray :: Maybe (ValMd' lab)
  }
  deriving (Show,Functor,Generic,Generic1)

type DISubroutineType = DISubroutineType' BlockLabel

-- Aggregate Utilities ---------------------------------------------------------

data IndexResult
  = Invalid                             -- ^ An invalid use of GEP
  | HasType Type                        -- ^ A resolved type
  | Resolve Ident (Type -> IndexResult) -- ^ Continue, after resolving an alias

isInvalid :: IndexResult -> Bool
isInvalid ir = case ir of
  Invalid -> True
  _       -> False

-- | Resolves the type of a GEP instruction. Type aliases are resolved
-- using the given function. An invalid use of GEP or one relying
-- on unknown type aliases will return 'Nothing'
resolveGepFull ::
  (Ident -> Maybe Type) {- ^ Type alias resolution -} ->
  Type                  {- ^ Pointer type          -} ->
  [Typed (Value' lab)]  {- ^ Path                  -} ->
  Maybe Type            {- ^ Type of result        -}
resolveGepFull env t ixs = go (resolveGep t ixs)
  where
  go Invalid                = Nothing
  go (HasType result)       = Just result
  go (Resolve ident resume) = go . resume =<< env ident


-- | Resolve the type of a GEP instruction.  Note that the type produced is the
-- type of the result, not necessarily a pointer.
resolveGep :: Type -> [Typed (Value' lab)] -> IndexResult
resolveGep (PtrTo ty0) (v:ixs0)
  | isGepIndex v =
    resolveGepBody ty0 ixs0
resolveGep ty0@PtrTo{} (v:ixs0)
  | Just i <- elimAlias (typedType v) =
    Resolve i (\ty' -> resolveGep ty0 (Typed ty' (typedValue v):ixs0))
resolveGep (Alias i) ixs =
    Resolve i (\ty' -> resolveGep ty' ixs)
resolveGep _ _ = Invalid

-- | Resolve the type of a GEP instruction.  This assumes that the input has
-- already been processed as a pointer.
resolveGepBody :: Type -> [Typed (Value' lab)] -> IndexResult
resolveGepBody (Struct fs) (v:ixs)
  | Just i <- isGepStructIndex v, genericLength fs > i =
    resolveGepBody (genericIndex fs i) ixs
resolveGepBody (PackedStruct fs) (v:ixs)
  | Just i <- isGepStructIndex v, genericLength fs > i =
    resolveGepBody (genericIndex fs i) ixs
resolveGepBody (Alias name) is
  | not (null is) =
    Resolve name (\ty' -> resolveGepBody ty' is)
resolveGepBody (Array _ ty') (v:ixs)
  | isGepIndex v =
    resolveGepBody ty' ixs
resolveGepBody (Vector _ tp) [val]
  | isGepIndex val =
    HasType tp
resolveGepBody ty (v:ixs)
  | Just i <- elimAlias (typedType v) =
    Resolve i (\ty' -> resolveGepBody ty (Typed ty' (typedValue v):ixs))
resolveGepBody ty [] =
    HasType ty
resolveGepBody _ _ =
    Invalid

isGepIndex :: Typed (Value' lab) -> Bool
isGepIndex tv = isPrimTypeOf isInteger (typedType tv)

isGepStructIndex :: Typed (Value' lab) -> Maybe Integer
isGepStructIndex tv = do
  guard (isGepIndex tv)
  elimValInteger (typedValue tv)

resolveValueIndex :: Type -> [Int32] -> IndexResult
resolveValueIndex ty is@(ix:ixs) = case ty of
  Struct fs | genericLength fs > ix
    -> resolveValueIndex (genericIndex fs ix) ixs

  PackedStruct fs | genericLength fs > ix
    -> resolveValueIndex (genericIndex fs ix) ixs

  Array n ty' | fromIntegral ix < n
    -> resolveValueIndex ty' ixs

  Alias name
    -> Resolve name (\ty' -> resolveValueIndex ty' is)

  _ -> Invalid
resolveValueIndex ty [] = HasType ty
