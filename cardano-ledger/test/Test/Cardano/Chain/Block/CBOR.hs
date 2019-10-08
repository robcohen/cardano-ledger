{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns -fno-warn-orphans #-}

module Test.Cardano.Chain.Block.CBOR
  ( tests
  , exampleBlockSignature
  , exampleBody
  , exampleHeader
  , exampleProof
  , exampleToSign
  )
where

import Cardano.Prelude
import Test.Cardano.Prelude

import Data.Coerce (coerce)
import Data.Maybe (fromJust)

import Hedgehog (Property)
import qualified Hedgehog as H

import Cardano.Binary (decodeFullDecoder, dropBytes, serializeEncoding, decodeAnnotatedDecoder, goldenTestExplicit)
import Cardano.Chain.Block
  ( BlockSignature(..)
  , Block
  , Body
  , ABoundaryBlock(boundaryBlockLength)
  , pattern Body
  , Header
  , HeaderHash
  , Proof(..)
  , pattern Proof
  , ToSign(..)
  , dropBoundaryBody
  , fromCBORABoundaryBlock
  , fromCBORBoundaryConsensusData
  , fromCBORABoundaryHeader
  , fromCBORBOBBlock
  , fromCBORHeaderToHash
  , mkHeaderExplicit
  , toCBORBOBBlock
  , toCBORABoundaryBlock
  , toCBORHeaderToHash
  )
import qualified Cardano.Chain.Delegation as Delegation
import Cardano.Chain.Slotting
  ( EpochNumber(..)
  , EpochSlots(EpochSlots)
  , WithEpochSlots(WithEpochSlots)
  , unWithEpochSlots
  )
import Cardano.Chain.Ssc (SscPayload(..), SscProof(..))
import Cardano.Crypto
  ( ProtocolMagicId(..)
  , SignTag(..)
  , abstractHash
  , hash
  , noPassSafeSigner
  , sign
  , toVerification
  )

import Test.Cardano.Binary.Helpers.GoldenRoundTrip
  ( deprecatedGoldenDecode
  , goldenTestCBOR
  , roundTripsCBORAnnotatedShow
  , roundTripsCBORAnnotatedBuildable
  , roundTripsCBORBuildable
  , roundTripsCBORShow
  )
import Test.Cardano.Chain.Block.Gen
import Test.Cardano.Chain.Common.Example (exampleChainDifficulty)
import Test.Cardano.Chain.Delegation.Example (exampleCertificates)
import Test.Cardano.Chain.Slotting.Example (exampleEpochAndSlotCount, exampleSlotNumber)
import Test.Cardano.Chain.Slotting.Gen (feedPMEpochSlots, genWithEpochSlots)
import Test.Cardano.Chain.UTxO.Example (exampleTxPayload, exampleTxProof)
import qualified Test.Cardano.Chain.Update.Example as Update
import Test.Cardano.Crypto.Example (exampleSigningKeys)
import Test.Cardano.Crypto.Gen (feedPM)
import Test.Options (TSGroup, TSProperty, concatTSGroups, eachOfTS)


--------------------------------------------------------------------------------
-- Header
--------------------------------------------------------------------------------

-- | Number of slots-per-epoch to be used throughout the examples in this
-- module.
exampleEs :: EpochSlots
exampleEs = EpochSlots 50

goldenHeader :: Property
goldenHeader = goldenTestExplicit
  "Header"
  (toCBORHeader exampleEs)
  (fromCBORHeader exampleEs)
  exampleHeader
  "test/golden/cbor/block/Header"

-- | Round-trip test the backwards compatible header encoding/decoding functions
ts_roundTripHeaderCompat :: TSProperty
ts_roundTripHeaderCompat = eachOfTS
  10
  (feedPMEpochSlots $ genWithEpochSlots genHeader)
  roundTripsHeaderCompat
 where
  roundTripsHeaderCompat :: WithEpochSlots Header -> H.PropertyT IO ()
  roundTripsHeaderCompat esh@(WithEpochSlots es _) = trippingBuildable
    esh
    (serializeEncoding . toCBORHeaderToHash . unWithEpochSlots)
    ( fmap (WithEpochSlots es . fromJust)
    . decodeAnnotatedDecoder "Header" (fromCBORHeaderToHash es)
    )

--------------------------------------------------------------------------------
-- Block
--------------------------------------------------------------------------------

-- | Round-trip test the backwards compatible block encoding/decoding functions
ts_roundTripBlockCompat :: TSProperty
ts_roundTripBlockCompat = eachOfTS
  10
  (feedPM genBlockWithEpochSlots)
  roundTripsBlockCompat
 where
  roundTripsBlockCompat :: WithEpochSlots Block -> H.PropertyT IO ()
  roundTripsBlockCompat esb@(WithEpochSlots es _) = trippingBuildable
    esb
    (serializeEncoding . toCBORBOBBlock . unWithEpochSlots)
    ( fmap (WithEpochSlots es . fromJust)
    . decodeAnnotatedDecoder "Block" (fromCBORBOBBlock es)
    )


--------------------------------------------------------------------------------
-- BlockSignature
--------------------------------------------------------------------------------
{-- TODO!
goldenBlockSignature :: Property
goldenBlockSignature =
  goldenTestCBOR exampleBlockSignature "test/golden/cbor/block/BlockSignature"
--}

ts_roundTripBlockSignatureCBOR :: TSProperty
ts_roundTripBlockSignatureCBOR =
  eachOfTS 10 (feedPMEpochSlots genBlockSignature) roundTripsCBORAnnotatedBuildable


--------------------------------------------------------------------------------
-- BoundaryBlockHeader
--------------------------------------------------------------------------------

goldenDeprecatedBoundaryBlockHeader :: Property
goldenDeprecatedBoundaryBlockHeader = deprecatedGoldenDecode
  "BoundaryBlockHeader"
  (void fromCBORABoundaryHeader)
  "test/golden/cbor/block/BoundaryBlockHeader"

ts_roundTripBoundaryBlock :: TSProperty
ts_roundTripBoundaryBlock = eachOfTS
    10
    (feedPM genBVDWithPM)
    roundTripsBVD
  where
    -- We ignore the size of the BVD here, since calculating it is annoying.
    roundTripsBVD :: (ProtocolMagicId, ABoundaryBlock ()) -> H.PropertyT IO ()
    roundTripsBVD (pm, bvd) = trippingBuildable
      bvd
      (serializeEncoding . toCBORABoundaryBlock pm)
      (fmap (dropSize . fmap (const ())) <$> decodeFullDecoder "BoundaryBlock" fromCBORABoundaryBlock)

    genBVDWithPM :: ProtocolMagicId -> H.Gen (ProtocolMagicId, ABoundaryBlock ())
    genBVDWithPM pm = (,) <$> pure pm <*> genBoundaryBlock

    dropSize :: ABoundaryBlock a -> ABoundaryBlock a
    dropSize bvd = bvd { boundaryBlockLength = 0 }


--------------------------------------------------------------------------------
-- BoundaryBody
--------------------------------------------------------------------------------

goldenDeprecatedBoundaryBody :: Property
goldenDeprecatedBoundaryBody = deprecatedGoldenDecode
  "BoundaryBody"
  dropBoundaryBody
  "test/golden/cbor/block/BoundaryBody"


--------------------------------------------------------------------------------
-- BoundaryConsensusData
--------------------------------------------------------------------------------

goldenDeprecatedBoundaryConsensusData :: Property
goldenDeprecatedBoundaryConsensusData = deprecatedGoldenDecode
  "BoundaryConsensusData"
  (void fromCBORBoundaryConsensusData)
  "test/golden/cbor/block/BoundaryConsensusData"


--------------------------------------------------------------------------------
-- HeaderHash
--------------------------------------------------------------------------------

goldenHeaderHash :: Property
goldenHeaderHash =
  goldenTestCBOR exampleHeaderHash "test/golden/cbor/block/HeaderHash"

ts_roundTripHeaderHashCBOR :: TSProperty
ts_roundTripHeaderHashCBOR =
  eachOfTS 1000 genHeaderHash roundTripsCBORBuildable


--------------------------------------------------------------------------------
-- BoundaryProof
--------------------------------------------------------------------------------

goldenDeprecatedBoundaryProof :: Property
goldenDeprecatedBoundaryProof = deprecatedGoldenDecode
  "BoundaryProof"
  dropBytes
  "test/golden/cbor/block/BoundaryProof"


--------------------------------------------------------------------------------
-- Body
--------------------------------------------------------------------------------

--goldenBody :: Property
--goldenBody = goldenTestCBOR exampleBody "test/golden/cbor/block/Body"

ts_roundTripBodyCBOR :: TSProperty
ts_roundTripBodyCBOR = eachOfTS 20 (feedPM genBody) roundTripsCBORAnnotatedShow


--------------------------------------------------------------------------------
-- Proof
--------------------------------------------------------------------------------

{-- TODO!
goldenProof :: Property
goldenProof = goldenTestCBOR exampleProof "test/golden/cbor/block/Proof"
--}

ts_roundTripProofCBOR :: TSProperty
ts_roundTripProofCBOR = eachOfTS 20 (feedPM genProof) roundTripsCBORAnnotatedBuildable


--------------------------------------------------------------------------------
-- SigningHistory
--------------------------------------------------------------------------------

-- TODO:
-- goldenSigningHistory :: Property
-- goldenSigningHistory =
--   goldenTestCBOR exampleSigningHistory "test/golden/cbor/block/SigningHistory"

ts_roundTripSigningHistoryCBOR :: TSProperty
ts_roundTripSigningHistoryCBOR =
  eachOfTS 20 genSigningHistory roundTripsCBORShow


--------------------------------------------------------------------------------
-- ToSign
--------------------------------------------------------------------------------

{-- TODO!
goldenToSign :: Property
goldenToSign = goldenTestCBOR exampleToSign "test/golden/cbor/block/ToSign"
--}

ts_roundTripToSignCBOR :: TSProperty
ts_roundTripToSignCBOR =
  eachOfTS 20 (feedPMEpochSlots genToSign) roundTripsCBORAnnotatedShow


--------------------------------------------------------------------------------
-- Example golden datatypes
--------------------------------------------------------------------------------

exampleHeader :: Header
exampleHeader = mkHeaderExplicit
  (ProtocolMagicId 7)
  exampleHeaderHash
  exampleChainDifficulty
  exampleEs
  (exampleSlotNumber exampleEs)
  delegateSk
  certificate
  exampleBody
  Update.exampleProtocolVersion
  Update.exampleSoftwareVersion
 where
  pm          = ProtocolMagicId 7
  [delegateSk, issuerSk] = exampleSigningKeys 5 2
  certificate = Delegation.signCertificate
    pm
    (toVerification delegateSk)
    (EpochNumber 5)
    (noPassSafeSigner issuerSk)

exampleBlockSignature :: BlockSignature
exampleBlockSignature = BlockSignature cert sig
 where
  cert = Delegation.signCertificate
    pm
    (toVerification delegateSK)
    (EpochNumber 5)
    (noPassSafeSigner issuerSK)

  sig = sign pm (SignBlock (toVerification issuerSK)) delegateSK exampleToSign

  [delegateSK, issuerSK] = exampleSigningKeys 5 2
  pm = ProtocolMagicId 7

exampleProof :: Proof
exampleProof = Proof
  exampleTxProof
  SscProof
  (abstractHash dp)
  Update.exampleProof
  where dp = Delegation.unsafePayload (take 4 exampleCertificates)

exampleHeaderHash :: HeaderHash
exampleHeaderHash = coerce (hash ("HeaderHash" :: Text))

exampleBody :: Body
exampleBody = Body exampleTxPayload SscPayload dp Update.examplePayload
  where dp = Delegation.unsafePayload (take 4 exampleCertificates)

exampleToSign :: ToSign
exampleToSign = ToSign
  exampleHeaderHash
  exampleProof
  exampleEpochAndSlotCount
  exampleChainDifficulty
  Update.exampleProtocolVersion
  Update.exampleSoftwareVersion


-----------------------------------------------------------------------
-- Main test export
-----------------------------------------------------------------------

tests :: TSGroup
tests = concatTSGroups [const $$discoverGolden, $$discoverRoundTripArg]
