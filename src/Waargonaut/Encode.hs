{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
-- | Types and functions to encode your data types to 'Json'.
--
-- We will work through a basic example, using the following type:
--
-- @
-- data Person = Person
--   { _personName                    :: Text
--   , _personAge                     :: Int
--   , _personAddress                 :: Text
--   , _personFavouriteLotteryNumbers :: [Int]
--   }
--   deriving (Eq, Show)
-- @
--
-- To create an 'Waargonaut.Encode.Encoder' for our @Person@ record, we will encode it as a "map
-- like object", that is we have decided that there are no duplicate keys allowed. We can then use
-- the following functions to build up the structure we want:
--
-- @
-- mapLikeObj
--   :: ( AsJType Json ws a
--      , Semigroup ws         -- This library supports GHC 7.10.3 and 'Semigroup' wasn't a superclass of 'Monoid' then.
--      , Monoid ws
--      , Applicative f
--      )
--   => (i -> MapLikeObj ws a -> MapLikeObj ws a)
--   -> Encoder f i
-- @
--
-- And:
--
-- @
-- atKey'
--   :: ( At t
--      , IxValue t ~ Json
--      )
--   => Index t
--   -> Encoder' a
--   -> a
--   -> t
--   -> t
-- @
--
-- These types may seem pretty wild, but their usage is mundane. The 'Waargonaut.Encode.mapLikeObj'
-- function is used when we want to encode some particular type @i@ as a JSON object. In such a way
-- as to prevent duplicate keys from appearing. The 'Waargonaut.Encode.atKey'' function is designed
-- such that it can be composed with itself to build up an object with multiple keys.
--
-- @
-- import Waargonaut.Encode (Encoder)
-- import qualified Waargonaut.Encode as E
-- @
--
-- @
-- personEncoder :: Applicative f => Encoder f Person
-- personEncoder = E.mapLikeObj $ \\p ->
--   E.atKey' \"name\" E.text (_personName p) .
--   E.atKey' \"age\" E.int (_personAge p) .
--   E.atKey' \"address\" E.text (_personAddress p) .
--   E.atKey' \"numbers\" (E.list E.int) (_personFavouriteLotteryNumbers p)
-- @
--
-- The JSON RFC leaves the handling of duplicate keys on an object as a choice. It is up to the
-- implementor of a JSON handling package to decide what they will do. Waargonaut passes on this
-- choice to you. In both encoding and decoding, the handling of duplicate keys is up to you.
-- Waargonaut provides functionality to support /both/ use cases.
--
-- To then turn these values into JSON output:
--
-- @
-- simpleEncodeText         :: Applicative f => Encoder f a -> a -> f Text
-- simpleEncodeTextNoSpaces :: Applicative f => Encoder f a -> a -> f Text
--
-- simpleEncodeByteString         :: Applicative f => Encoder f a -> a -> f ByteString
-- simpleEncodeByteStringNoSpaces :: Applicative f => Encoder f a -> a -> f ByteString
-- @
--
-- Or
--
-- @
-- simplePureEncodeText         :: Encoder' a -> a -> Text
-- simplePureEncodeTextNoSpaces :: Encoder' a -> a -> Text
--
-- simplePureEncodeByteString         :: Encoder' a -> a -> ByteString
-- simplePureEncodeByteStringNoSpaces :: Encoder' a -> a -> ByteString
-- @
--
-- The latter functions specialise the @f@ to be 'Data.Functor.Identity'.
--
-- Then, like the use of the 'Waargonaut.Decode.Decoder' you select the 'Waargonaut.Encode.Encoder'
-- you wish to use and run it against a value of a matching type:
--
-- @
-- simplePureEncodeTextNoSpaces personEncoder (Person \"Krag\" 33 \"Red House 4, Three Neck Lane, Greentown.\" [86,3,32,42,73])
-- =
-- "{\"name\":\"Krag\",\"age\":88,\"address\":\"Red House 4, Three Neck Lane, Greentown.\",\"numbers\":[86,3,32,42,73]}"
-- @
--
module Waargonaut.Encode
  (
    -- * Encoder type
    Encoder
  , Encoder'
  , ObjEncoder
  , ObjEncoder'

    -- * Creation
  , encodeA
  , encodePureA
  , jsonEncoder
  , objEncoder

    -- * Runners
  , runPureEncoder
  , runEncoder
  , simpleEncodeWith
  , simplePureEncodeWith
  , simpleEncodeText
  , simpleEncodeTextNoSpaces
  , simpleEncodeByteString
  , simpleEncodeByteStringNoSpaces
  , simplePureEncodeText
  , simplePureEncodeTextNoSpaces
  , simplePureEncodeByteString
  , simplePureEncodeByteStringNoSpaces

    -- * Provided encoders
  , int
  , integral
  , scientific
  , bool
  , string
  , text
  , null
  , either
  , maybe
  , maybeOrNull
  , traversable
  , list
  , nonempty
  , mapToObj
  , json
  , prismE
  , asJson

    -- * Object encoder helpers
  , mapLikeObj
  , atKey
  , atOptKey
  , intAt
  , textAt
  , boolAt
  , traversableAt
  , listAt
  , nonemptyAt
  , encAt
  , keyValuesAsObj
  , onObj
  , keyValueTupleFoldable
  , extendObject
  , extendMapLikeObject
  , combineObjects

    -- * Encoders specialised to Identity
  , int'
  , integral'
  , scientific'
  , bool'
  , string'
  , text'
  , null'
  , either'
  , maybe'
  , maybeOrNull'
  , traversable'
  , nonempty'
  , list'
  , atKey'
  , atOptKey'
  , mapLikeObj'
  , mapToObj'
  , keyValuesAsObj'
  , json'
  , asJson'
  , onObj'
  , generaliseEncoder
  ) where


import           Control.Applicative                  (Applicative (..), (<$>))
import           Control.Category                     (id, (.))
import           Control.Lens                         (AReview, At, Index,
                                                       IxValue, Prism', at,
                                                       cons, review, ( # ),
                                                       (?~), _Empty, _Wrapped)
import qualified Control.Lens                         as L

import           Data.Foldable                        (Foldable, foldr, foldrM)
import           Data.Function                        (const, flip, ($), (&))
import           Data.Functor                         (Functor, fmap)
import           Data.Functor.Contravariant           ((>$<))
import           Data.Functor.Contravariant.Divisible (divide)
import           Data.Functor.Identity                (Identity (..))
import           Data.Traversable                     (Traversable, traverse)
import           Prelude                              (Bool, Int, Integral,
                                                       Monad, String,
                                                       fromIntegral, fst)

import           Data.Either                          (Either)
import qualified Data.Either                          as Either
import           Data.List.NonEmpty                   (NonEmpty)
import           Data.Maybe                           (Maybe)
import qualified Data.Maybe                           as Maybe
import           Data.Scientific                      (Scientific)

import           Data.Monoid                          (Monoid, mempty)
import           Data.Semigroup                       (Semigroup)

import           Data.Map                             (Map)
import qualified Data.Map                             as Map
import           Data.String                          (IsString)

import qualified Data.ByteString.Lazy                 as BL
import qualified Data.ByteString.Lazy.Builder         as BB

import           Data.Text                            (Text)
import qualified Data.Text.Lazy                       as LT
import qualified Data.Text.Lazy.Builder               as TB

import           Waargonaut.Encode.Types              (Encoder, Encoder',
                                                       ObjEncoder, ObjEncoder',
                                                       finaliseEncoding,
                                                       generaliseEncoder,
                                                       initialEncoding,
                                                       jsonEncoder, objEncoder,
                                                       runEncoder,
                                                       runPureEncoder)

import           Waargonaut.Types                     (AsJType (..),
                                                       JAssoc (..), JObject,
                                                       Json, MapLikeObj (..),
                                                       WS, stringToJString,
                                                       toMapLikeObj,
                                                       _JNumberInt,
                                                       _JNumberScientific,
                                                       _JStringText)

import           Waargonaut.Encode.Builder            (textBuilder, bsBuilder,
                                                       waargonautBuilder)
import           Waargonaut.Encode.Builder.Types      (Builder)
import           Waargonaut.Encode.Builder.Whitespace (wsBuilder, wsRemover)


-- | Create an 'Encoder'' for @a@ by providing a function from 'a -> f Json'.
encodeA :: (a -> f Json) -> Encoder f a
encodeA = jsonEncoder

-- | As 'encodeA' but specialised to 'Identity' when the additional flexibility
-- isn't needed.
encodePureA :: (a -> Json) -> Encoder' a
encodePureA f = encodeA (Identity . f)

-- | Encode an @a@ directly to some output text type using the provided
-- 'Waargonaut.Encode.Builder.Types.Builder' and 'Encoder'.
simpleEncodeWith
  :: ( Applicative f
     , Monoid b
     , IsString t
     )
  => Builder t b
  -> (b -> out)
  -> (Builder t b -> WS -> b)
  -> Encoder f a
  -> a
  -> f out
simpleEncodeWith builder buildRunner wsB enc =
  fmap (buildRunner . waargonautBuilder wsB builder) . runEncoder enc

-- | Encode an @a@ directly to a 'LT.Text' using the provided 'Encoder'.
simpleEncodeText
  :: Applicative f
  => Encoder f a
  -> a
  -> f LT.Text
simpleEncodeText =
  simpleEncodeWith textBuilder TB.toLazyText wsBuilder

-- | Encode an @a@ directly to a 'LT.Text' using the provided 'Encoder'.
simpleEncodeTextNoSpaces
  :: Applicative f
  => Encoder f a
  -> a
  -> f LT.Text
simpleEncodeTextNoSpaces =
  simpleEncodeWith textBuilder TB.toLazyText wsRemover

-- | Encode an @a@ directly to a 'BL.ByteString' using the provided 'Encoder'.
simpleEncodeByteString
  :: Applicative f
  => Encoder f a
  -> a
  -> f BL.ByteString
simpleEncodeByteString =
  simpleEncodeWith bsBuilder BB.toLazyByteString wsBuilder

-- | Encode an @a@ directly to a 'BL.ByteString' using the provided 'Encoder'.
simpleEncodeByteStringNoSpaces
  :: Applicative f
  => Encoder f a
  -> a
  -> f BL.ByteString
simpleEncodeByteStringNoSpaces =
  simpleEncodeWith bsBuilder BB.toLazyByteString wsRemover

-- | Encode an @a@ directly to a 'LT.Text' using the provided 'Encoder'.
simplePureEncodeWith
  :: ( Monoid b
     , IsString t
     )
  => Builder t b
  -> (b -> out)
  -> (Builder t b -> WS -> b)
  -> Encoder Identity a
  -> a
  -> out
simplePureEncodeWith builder buildRunner wsB enc =
  runIdentity . simpleEncodeWith builder buildRunner wsB enc

-- | As per 'simpleEncodeText' but specialised the @f@ to 'Data.Functor.Identity'.
simplePureEncodeText
  :: Encoder Identity a
  -> a
  -> LT.Text
simplePureEncodeText enc =
  runIdentity . simpleEncodeText enc

-- | As per 'simpleEncodeTextNoSpaces' but specialised the @f@ to 'Data.Functor.Identity'.
simplePureEncodeTextNoSpaces
  :: Encoder Identity a
  -> a
  -> LT.Text
simplePureEncodeTextNoSpaces enc =
  runIdentity . simpleEncodeTextNoSpaces enc

-- | As per 'simpleEncodeByteString' but specialised the @f@ to 'Data.Functor.Identity'.
simplePureEncodeByteString
  :: Encoder Identity a
  -> a
  -> BL.ByteString
simplePureEncodeByteString enc =
  runIdentity . simpleEncodeByteString enc

-- | As per 'simpleEncodeByteStringNoSpaces' but specialised the @f@ to 'Data.Functor.Identity'.
simplePureEncodeByteStringNoSpaces
  :: Encoder Identity a
  -> a
  -> BL.ByteString
simplePureEncodeByteStringNoSpaces enc =
  runIdentity . simpleEncodeByteStringNoSpaces enc

-- | Transform the given input using the 'Encoder' to its 'Json' data structure representation.
asJson :: Applicative f => Encoder f a -> a -> f Json
asJson = runEncoder
{-# INLINE asJson #-}

-- | As per 'asJson', but with the 'Encoder' specialised to 'Identity'
asJson' :: Encoder Identity a -> a -> Json
asJson' e = runIdentity . runEncoder e
{-# INLINE asJson' #-}

-- | 'Encoder'' for a Waargonaut 'Json' data structure
json :: Applicative f => Encoder f Json
json = encodeA pure
{-# INLINE json #-}

-- Internal function for creating an 'Encoder' from an 'Control.Lens.AReview'.
encToJsonNoSpaces
  :: ( Monoid t
     , Applicative f
     )
  => AReview Json (b, t)
  -> (a -> b)
  -> Encoder f a
encToJsonNoSpaces c f =
  encodeA (pure . review c . (,mempty) . f)

-- | Build an 'Encoder' using a 'Control.Lens.Prism''
prismE
  :: Prism' a b
  -> Encoder f a
  -> Encoder f b
prismE p e =
  L.review p >$< e
{-# INLINE prismE #-}

-- | Encode an 'Int'
int :: Applicative f => Encoder f Int
int = encToJsonNoSpaces _JNum (_JNumberInt #)

-- | Encode an 'Scientific'
scientific :: Applicative f => Encoder f Scientific
scientific = encToJsonNoSpaces _JNum (_JNumberScientific #)

-- | Encode a numeric value of the typeclass 'Integral'
integral :: (Applicative f, Integral n) => Encoder f n
integral = encToJsonNoSpaces _JNum (review _JNumberScientific . fromIntegral)

-- | Encode a 'Bool'
bool :: Applicative f => Encoder f Bool
bool = encToJsonNoSpaces _JBool id

-- | Encode a 'String'
string :: Applicative f => Encoder f String
string = encToJsonNoSpaces _JStr stringToJString

-- | Encode a 'Text'
text :: Applicative f => Encoder f Text
text = encToJsonNoSpaces _JStr (_JStringText #)

-- | Encode an explicit 'null'.
null :: Applicative f => Encoder f ()
null = encodeA $ const (pure $ _JNull # mempty)

-- | Encode a 'Maybe' value, using the provided 'Encoder''s to handle the
-- different choices.
maybe
  :: Functor f
  => Encoder f ()
  -> Encoder f a
  -> Encoder f (Maybe a)
maybe encN = encodeA
  . Maybe.maybe (runEncoder encN ())
  . runEncoder

-- | Encode a 'Maybe a' to either 'Encoder a' or 'null'
maybeOrNull
  :: Applicative f
  => Encoder f a
  -> Encoder f (Maybe a)
maybeOrNull =
  maybe null

-- | Encode an 'Either' value using the given 'Encoder's
either
  :: Functor f
  => Encoder f a
  -> Encoder f b
  -> Encoder f (Either a b)
either eA = encodeA
  . Either.either (runEncoder eA)
  . runEncoder

-- | Encode some 'Traversable' of @a@ into a JSON array.
traversable
  :: ( Applicative f
     , Traversable t
     )
  => Encoder f a
  -> Encoder f (t a)
traversable = encodeWithInner
  (\xs -> _JArr # (_Wrapped # foldr cons mempty xs, mempty))

-- | Encode a 'Map' in a JSON object.
mapToObj
  :: Applicative f
  => Encoder f a
  -> (k -> Text)
  -> Encoder f (Map k a)
mapToObj encodeVal kToText =
  let
    mapToCS = Map.foldrWithKey (\k v -> at (kToText k) ?~ v) (_Empty # ())
  in
    encodeWithInner (\xs -> _JObj # (fromMapLikeObj $ mapToCS xs, mempty)) encodeVal

-- | Encode a 'NonEmpty' list
nonempty
  :: Applicative f
  => Encoder f a
  -> Encoder f (NonEmpty a)
nonempty =
  traversable

-- | Encode a list
list
  :: Applicative f
  => Encoder f a
  -> Encoder f [a]
list =
  traversable

-- | As per 'json' but with the @f@ specialised to 'Data.Functor.Identity'.
json' :: Encoder' Json
json' = json

-- | As per 'int' but with the @f@ specialised to 'Data.Functor.Identity'.
int' :: Encoder' Int
int' = int

-- | As per 'integral' but with the @f@ specialised to 'Data.Functor.Identity'.
integral' :: Integral n => Encoder' n
integral' = integral

-- | As per 'scientific' but with the @f@ specialised to 'Data.Functor.Identity'.
scientific' :: Encoder' Scientific
scientific' = scientific

-- | As per 'bool' but with the @f@ specialised to 'Data.Functor.Identity'.
bool' :: Encoder' Bool
bool' = bool

-- | As per 'string' but with the @f@ specialised to 'Data.Functor.Identity'.
string' :: Encoder' String
string' = string

-- | As per 'text' but with the @f@ specialised to 'Data.Functor.Identity'.
text' :: Encoder' Text
text' = text

-- | As per 'null' but with the @f@ specialised to 'Data.Functor.Identity'.
null' :: Encoder' ()
null' = null

-- | As per 'maybe' but with the @f@ specialised to 'Data.Functor.Identity'.
maybe'
  :: Encoder' ()
  -> Encoder' a
  -> Encoder' (Maybe a)
maybe' =
  maybe

-- | As per 'maybeOrNull' but with the @f@ specialised to 'Data.Functor.Identity'.
maybeOrNull'
  :: Encoder' a
  -> Encoder' (Maybe a)
maybeOrNull' =
  maybeOrNull

-- | As per 'either' but with the @f@ specialised to 'Data.Functor.Identity'.
either'
  :: Encoder' a
  -> Encoder' b
  -> Encoder' (Either a b)
either' =
  either

-- | As per 'nonempty' but with the @f@ specialised to 'Data.Functor.Identity'.
nonempty'
  :: Encoder' a
  -> Encoder' (NonEmpty a)
nonempty' =
  traversable

-- | As per 'list' but with the @f@ specialised to 'Data.Functor.Identity'.
list'
  :: Encoder' a
  -> Encoder' [a]
list' =
  traversable

-- | Encode some @a@ that is contained with another @t@ structure.
encodeWithInner
  :: ( Applicative f
     , Traversable t
     )
  => (t Json -> Json)
  -> Encoder f a
  -> Encoder f (t a)
encodeWithInner f g =
  jsonEncoder $ fmap f . traverse (runEncoder g)

-- | As per 'traversable' but with the @f@ specialised to 'Data.Functor.Identity'.
traversable'
  :: Traversable t
  => Encoder' a
  -> Encoder' (t a)
traversable' =
  traversable

-- | Using the given function to convert the @k@ type keys to a 'Text' value,
-- encode a 'Map' as a JSON object.
mapToObj'
  :: Encoder' a
  -> (k -> Text)
  -> Encoder' (Map k a)
mapToObj' =
  mapToObj

-- | When encoding a 'MapLikeObj', this function lets you encode a value at a specific key
atKey
  :: ( At t
     , IxValue t ~ Json
     , Applicative f
     )
  => Index t
  -> Encoder f a
  -> a
  -> t
  -> f t
atKey k enc v t =
  (\v' -> t & at k ?~ v') <$> runEncoder enc v

-- | Optionally encode an @a@ if it is a @Just a@. A @Nothing@ will result in the key being absent from the object.
atOptKey
  :: ( At t
     , IxValue t ~ Json
     , Applicative f
     )
  => Index t
  -> Encoder f a
  -> Maybe a
  -> t
  -> f t
atOptKey k enc =
  Maybe.maybe pure (atKey k enc)

-- | Encode an @a@ at the given index on the JSON object.
atKey'
  :: ( At t
     , IxValue t ~ Json
     )
  => Index t
  -> Encoder' a
  -> a
  -> t
  -> t
atKey' k enc v =
  at k ?~ asJson' enc v
{-# INLINE atKey' #-}

-- | Optionally encode a @key : value@ pair on an object.
--
-- @
-- encoder = E.mapLikeObj \$ \\a ->
--   atKey' \"A\" E.text (_getterA a)
--   atOptKey' \"B\" E.int (_maybeB a)
--
-- simplePureEncodeByteString encoder (Foo "bob" (Just 33)) = "{\"A\":\"bob\",\"B\":33}"
--
-- simplePureEncodeByteString encoder (Foo "bob" Nothing) = "{\"A\":\"bob\"}"
--
-- @
--
atOptKey'
  :: ( At t
     , IxValue t ~ Json
     )
  => Index t
  -> Encoder' a
  -> Maybe a
  -> t
  -> t
atOptKey' k enc =
  Maybe.maybe id (atKey' k enc)
{-# INLINE atOptKey' #-}

-- | Encode an 'Int' at the given 'Text' key.
intAt
  :: Text
  -> Int
  -> MapLikeObj WS Json
  -> MapLikeObj WS Json
intAt =
  flip atKey' int

-- | Encode a 'Text' value at the given 'Text' key.
textAt
  :: Text
  -> Text
  -> MapLikeObj WS Json
  -> MapLikeObj WS Json
textAt =
  flip atKey' text

-- | Encode a 'Bool' at the given 'Text' key.
boolAt
  :: Text
  -> Bool
  -> MapLikeObj WS Json
  -> MapLikeObj WS Json
boolAt =
  flip atKey' bool

-- | Encode a 'Foldable' of @a@ at the given index on a JSON object.
traversableAt
  :: ( At t
     , Traversable f
     , IxValue t ~ Json
     )
  => Encoder' a
  -> Index t
  -> f a
  -> t
  -> t
traversableAt enc =
  flip atKey' (traversable enc)

-- | Encode a standard Haskell list at the given index on a JSON object.
listAt
  :: ( At t
     , IxValue t ~ Json
     )
  => Encoder' a
  -> Index t
  -> [a]
  -> t
  -> t
listAt =
  traversableAt

-- | Encode a 'NonEmpty' list at the given index on a JSON object.
nonemptyAt
  :: ( At t
     , IxValue t ~ Json
     )
  => Encoder' a
  -> Index t
  -> NonEmpty a
  -> t
  -> t
nonemptyAt =
  traversableAt

-- | Apply a function to update a 'MapLikeObj' and encode that as a JSON object.
--
-- For example, given the following data type:
--
-- @
-- data Image = Image
--   { _imageW        :: Int
--   , _imageH        :: Int
--   , _imageTitle    :: Text
--   , _imageAnimated :: Bool
--   , _imageIDs      :: [Int]
--   }
-- @
--
-- We can use this function to create an encoder, composing the individual
-- update functions to set the keys and values as desired.
--
-- @
-- encodeImage :: Applicative f => Encoder f Image
-- encodeImage = mapLikeObj $ \\img ->
--   intAt \"Width\" (_imageW img) .           -- ^ Set an 'Int' value at the \"Width\" key.
--   intAt \"Height\" (_imageH img) .
--   textAt \"Title\" (_imageTitle img) .
--   boolAt \"Animated\" (_imageAnimated img) .
--   listAt int \"IDs\" (_imageIDs img) -- ^ Set an @[Int]@ value at the \"IDs\" key.
-- @
--
mapLikeObj
  :: ( AsJType Json ws a
     , Monoid ws
     , Semigroup ws
     , Applicative f
     )
  => (i -> MapLikeObj ws a -> MapLikeObj ws a)
  -> Encoder f i
mapLikeObj f = encodeA $ \a ->
  pure $ _JObj # (fromMapLikeObj $ f a (_Empty # ()), mempty)

-- | As per 'mapLikeObj' but specialised for 'Identity' as the 'Applicative'.
mapLikeObj'
  :: ( AsJType Json ws a
     , Semigroup ws
     , Monoid ws
     )
  => (i -> MapLikeObj ws a -> MapLikeObj ws a)
  -> Encoder' i
mapLikeObj' f = encodePureA $ \a ->
  _JObj # (fromMapLikeObj $ f a (_Empty # ()), mempty)

-- |
-- This function allows you to extend the fields on a JSON object created by a
-- separate encoder.
--
extendObject
  :: Functor f
  => ObjEncoder f a
  -> a
  -> (JObject WS Json -> JObject WS Json)
  -> f Json
extendObject encA a f =
  finaliseEncoding encA . f <$> initialEncoding encA a

-- |
-- This function lets you extend the fields on a JSON object but enforces the
-- uniqueness of the keys by working through the 'MapLikeObj' structure.
--
-- This will keep the first occurence of each unique key in the map. So be sure
-- to check your output.
--
extendMapLikeObject
  :: Functor f
  => ObjEncoder f a
  -> a
  -> (MapLikeObj WS Json -> MapLikeObj WS Json)
  -> f Json
extendMapLikeObject encA a f =
  finaliseEncoding encA . floopObj <$> initialEncoding encA a
  where
    floopObj = fromMapLikeObj . f . fst . toMapLikeObj

-- |
-- Given encoders for things that are represented in JSON as @objects@, and a
-- way to get to the @b@ and @c@ from the @a@. This function lets you create an
-- encoder for @a@. The two objects are combined to make one single JSON object.
--
-- Given
--
-- @
-- encodeFoo :: ObjEncoder f Foo
-- encodeBar :: ObjEncoder f Bar
-- -- and some wrapping type:
-- data A = { _foo :: Foo, _bar :: Bar }
-- @
--
-- We can use this function to utilise our already defined 'ObjEncoder'
-- structures to give us an encoder for @A@:
--
-- @
-- combineObjects (\aRecord -> (_foo aRecord, _bar aRecord)) encodeFoo encodeBar :: ObjEncoder f Bar
-- @
--
combineObjects
  :: Applicative f
  => (a -> (b, c))
  -> ObjEncoder f b
  -> ObjEncoder f c
  -> ObjEncoder f a
combineObjects =
  divide

-- | When encoding a JSON object that may contain duplicate keys, this function
-- works the same as the 'atKey' function for 'MapLikeObj'.
onObj
  :: Applicative f
  => Text
  -> b
  -> Encoder f b
  -> JObject WS Json
  -> f (JObject WS Json)
onObj k b encB o = (\j -> o & _Wrapped L.%~ L.cons j)
  . JAssoc (_JStringText # k) mempty mempty <$> asJson encB b

-- | As per 'onObj' but the @f@ is specialised to 'Identity'.
onObj'
  :: Text
  -> b
  -> Encoder' b
  -> JObject WS Json
  -> JObject WS Json
onObj' k b encB o = (\j -> o & _Wrapped L.%~ L.cons j)
  . JAssoc (_JStringText # k) mempty mempty $ asJson' encB b

-- | Encode key value pairs as a JSON object, allowing duplicate keys.
keyValuesAsObj
  :: ( Foldable g
     , Monad f
     )
  => g (a -> JObject WS Json -> f (JObject WS Json))
  -> Encoder f a
keyValuesAsObj xs = encodeA $ \a ->
  (\v -> _JObj # (v,mempty)) <$> foldrM (\f -> f a) (_Empty # ()) xs

-- | Encode some 'Data.Foldable.Foldable' of @(Text, a)@ as a JSON object. This permits duplicate
-- keys.
keyValueTupleFoldable
  :: ( Monad f
     , Foldable g
     )
  => Encoder f a
  -> Encoder f (g (Text, a))
keyValueTupleFoldable eA = encodeA $
  fmap (\v -> _JObj # (v,mempty)) . foldrM (\(k,v) o -> onObj k v eA o) (_Empty # ())

-- | As per 'keyValuesAsObj' but with the @f@ specialised to 'Identity'.
keyValuesAsObj'
  :: ( Foldable g
     , Functor g
     )
  => g (a -> JObject WS Json -> JObject WS Json)
  -> Encoder' a
keyValuesAsObj' =
  keyValuesAsObj . fmap (\f a -> Identity . f a)

-- | Using a given 'Encoder', encode a key value pair on the JSON object, using
-- the accessor function to retrieve the value.
encAt
  :: Applicative f
  => Encoder f b
  -> Text
  -> (a -> b)
  -> a
  -> JObject WS Json
  -> f (JObject WS Json)
encAt e k f a =
  onObj k (f a) e
