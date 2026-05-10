{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Walk a Cardano ImmutableDB and emit a per-block CSV with size and
-- transaction features. Reuses the 'HasAnalysis' typeclass from
-- @unstable-cardano-tools@, whose @CardanoBlock@ instance dispatches to
-- per-era helpers — Byron via 'Cardano.Tools.DBAnalyser.Block.Byron',
-- Shelley/Allegra/Mary/Alonzo/Babbage/Conway via the unified
-- 'Cardano.Tools.DBAnalyser.Block.Shelley' instance.
module Main (main) where

import Cardano.Crypto.Init (cryptoInit)
import qualified Cardano.Ledger.Alonzo.Scripts as Alonzo
  ( ExUnits (..)
  , plutusScriptLanguage
  , toPlutusScript
  )
import qualified Cardano.Ledger.Alonzo.Tx as Alonzo (totExUnits)
import qualified Cardano.Ledger.Alonzo.TxWits as Alonzo (AlonzoEraTxWits)
import qualified Cardano.Ledger.Babbage.TxBody as Babbage
  ( BabbageEraTxBody (referenceInputsTxBodyL)
  )
import qualified Cardano.Ledger.Babbage.TxOut as Babbage
  ( BabbageEraTxOut (dataTxOutL, referenceScriptTxOutL)
  )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import qualified Cardano.Ledger.Core as Core
  ( EraBlockBody (txSeqBlockBodyL)
  , EraTx (bodyTxL, witsTxL)
  , EraTxBody (inputsTxBodyL, outputsTxBodyL)
  , EraTxWits (scriptTxWitsL)
  )
import qualified Cardano.Ledger.Plutus.Language as Plutus (Language (..))
import qualified Cardano.Ledger.Shelley.API as SL (Block (Block))
import qualified Cardano.Tools.DBAnalyser.Block.Cardano ()
import qualified Cardano.Tools.DBAnalyser.HasAnalysis as HasAnalysis
import Control.Monad (when)
import Control.ResourceRegistry (runWithTempRegistry, withRegistry)
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8 as BS8
import Data.Foldable (foldl', toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Proxy (Proxy (..))
import qualified Data.Set as Set
import Data.Word (Word16, Word64)
import GenesisSyncAccelerator.Types (StandardBlock)
import GenesisSyncAccelerator.Util (fpToHasFS, getTopLevelConfig)
import Lens.Micro ((^.))
import Main.Utf8 (withStdTerminalHandles)
import Options.Applicative
import Ouroboros.Consensus.Block
  ( BlockNo (..)
  , ConvertRawHash (toRawHash)
  , HeaderHash
  , Point (GenesisPoint)
  , SlotNo (..)
  , blockHash
  , blockNo
  , blockSlot
  )
import Ouroboros.Consensus.Cardano.Block
  ( pattern BlockAllegra
  , pattern BlockAlonzo
  , pattern BlockBabbage
  , pattern BlockConway
  , pattern BlockMary
  , pattern BlockShelley
  )
import Ouroboros.Consensus.Config (configCodec, configStorage)
import Ouroboros.Consensus.Node.InitStorage
  ( NodeInitStorage (nodeCheckIntegrity, nodeImmutableDbChunkInfo)
  )
import qualified Ouroboros.Consensus.Shelley.Ledger.Block as Shelley
import Ouroboros.Consensus.Storage.Common (BlockComponent (..))
import qualified Ouroboros.Consensus.Storage.ImmutableDB as ImmDB
import Ouroboros.Network.SizeInBytes (SizeInBytes (..))
import System.FS.API (SomeHasFS (..))
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)

-- ---------------------------------------------------------------------------
-- CLI
-- ---------------------------------------------------------------------------

data Opts = Opts
  { immDBDir :: FilePath
  , configFile :: FilePath
  , progressEvery :: Int
  -- ^ Print a progress line on stderr every N blocks (0 = silent).
  }

optsParser :: ParserInfo Opts
optsParser =
  info (helper <*> parse) $
    fullDesc
      <> progDesc
        "Walk a Cardano ImmutableDB and emit a per-block features CSV"
 where
  parse = do
    immDBDir <-
      strOption $
        long "db" <> metavar "PATH" <> help "Path to the ImmutableDB"
    configFile <-
      strOption $
        long "config"
          <> metavar "PATH"
          <> help "Path to the cardano-node config (same format as db-analyser)"
    progressEvery <-
      option auto $
        long "progress-every"
          <> metavar "N"
          <> value 100000
          <> showDefault
          <> help "Print a progress line on stderr every N blocks (0 to disable)"
    pure Opts{immDBDir, configFile, progressEvery}

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------

main :: IO ()
main = withStdTerminalHandles $ do
  cryptoInit
  Opts{immDBDir, configFile, progressEvery} <- execParser optsParser
  hSetBuffering stdout LineBuffering

  cfg <- getTopLevelConfig configFile

  let hasFS = fpToHasFS immDBDir
      storageCfg = configStorage cfg
      codecCfg = configCodec cfg

  putStrLn
    "block_no,slot,hash,header_size,block_size,num_txs,txs_size,\
    \num_tx_inputs,num_tx_outputs,\
    \script_exec_steps,script_exec_mem,\
    \plutus_v1_steps,plutus_v1_mem,plutus_v2_steps,plutus_v2_mem,\
    \plutus_v3_steps,plutus_v3_mem,\
    \num_reference_inputs,num_reference_scripts,num_inline_datums"

  withRegistry $ \registry -> do
    let immDBArgs =
          ImmDB.defaultArgs
            { ImmDB.immCheckIntegrity = nodeCheckIntegrity storageCfg
            , ImmDB.immChunkInfo = nodeImmutableDbChunkInfo storageCfg
            , ImmDB.immCodecConfig = codecCfg
            , ImmDB.immRegistry = registry
            , ImmDB.immHasFS = SomeHasFS hasFS
            }
    ImmDB.withDB
      (ImmDB.openDB immDBArgs runWithTempRegistry)
      $ \immDB -> do
        countRef <- newIORef (0 :: Int)
        itr <-
          ImmDB.streamAfterKnownPoint
            immDB
            registry
            blockComponent
            (GenesisPoint :: Point StandardBlock)
        let go = do
              r <- ImmDB.iteratorNext itr
              case r of
                ImmDB.IteratorExhausted -> pure ()
                ImmDB.IteratorResult (blk, hdrSize, blkSize) -> do
                  emitRow blk hdrSize blkSize
                  modifyIORef' countRef (+ 1)
                  when (progressEvery > 0) $ do
                    n <- readIORef countRef
                    when (n `mod` progressEvery == 0) $
                      hPutStrLn stderr $
                        "  " <> show n <> " blocks processed"
                  go
        go
        final <- readIORef countRef
        hPutStrLn stderr $ "done; emitted " <> show final <> " rows"

-- ---------------------------------------------------------------------------
-- per-block extraction
-- ---------------------------------------------------------------------------

blockComponent ::
  BlockComponent StandardBlock (StandardBlock, Word16, SizeInBytes)
blockComponent = (,,) <$> GetBlock <*> GetHeaderSize <*> GetBlockSize

emitRow :: StandardBlock -> Word16 -> SizeInBytes -> IO ()
emitRow blk hdrSize blkSize = do
  let !slot = unSlotNo (blockSlot blk)
      !bno = unBlockNo (blockNo blk)
      !hashHex = hashToHex (blockHash blk)
      !txSizes = HasAnalysis.blockTxSizes blk
      !numTxs = length txSizes
      !txsSize = sum (map (fromIntegral . getSizeInBytes) txSizes) :: Int
      !numIns = blockNumInputs blk
      !numOuts = HasAnalysis.countTxOutputs blk
      !(execSteps, execMem) = blockExUnits blk
      !(v1s, v1m, v2s, v2m, v3s, v3m) = blockPlutusLangExUnits blk
      !(numRefIns, numRefScripts, numInlineDatums) = blockBabbageFeats blk
  putStrLn $
    show bno
      <> ","
      <> show slot
      <> ","
      <> hashHex
      <> ","
      <> show hdrSize
      <> ","
      <> show (getSizeInBytes blkSize)
      <> ","
      <> show numTxs
      <> ","
      <> show txsSize
      <> ","
      <> show numIns
      <> ","
      <> show numOuts
      <> ","
      <> show execSteps
      <> ","
      <> show execMem
      <> ","
      <> show v1s
      <> ","
      <> show v1m
      <> ","
      <> show v2s
      <> ","
      <> show v2m
      <> ","
      <> show v3s
      <> ","
      <> show v3m
      <> ","
      <> show numRefIns
      <> ","
      <> show numRefScripts
      <> ","
      <> show numInlineDatums

hashToHex :: HeaderHash StandardBlock -> String
hashToHex h = BS8.unpack (B16.encode (toRawHash (Proxy :: Proxy StandardBlock) h))

-- | Per-block sum of @num_tx_inputs@ across transactions. Shelley+ eras
-- use the standard @inputsTxBodyL@ lens; Byron has a different ledger
-- type and is reported as 0. The Alonzo+ analysis cares about within-era
-- slope, so a Byron-baseline offset is irrelevant.
blockNumInputs :: StandardBlock -> Int
blockNumInputs = \case
  BlockShelley b -> sumNumInputs b
  BlockAllegra b -> sumNumInputs b
  BlockMary b -> sumNumInputs b
  BlockAlonzo b -> sumNumInputs b
  BlockBabbage b -> sumNumInputs b
  BlockConway b -> sumNumInputs b
  _ -> 0

sumNumInputs ::
  forall proto era.
  Core.EraBlockBody era =>
  Shelley.ShelleyBlock proto era ->
  Int
sumNumInputs blk = case Shelley.shelleyBlockRaw blk of
  SL.Block _ body -> foldl' addTx 0 (body ^. Core.txSeqBlockBodyL)
 where
  addTx !acc tx =
    acc + Set.size (tx ^. Core.bodyTxL ^. Core.inputsTxBodyL)

-- | Sum of (script_exec_steps, script_exec_mem) over all transactions in the
-- block. Returns @(0, 0)@ for pre-Alonzo eras (no redeemers possible).
blockExUnits :: StandardBlock -> (Word64, Word64)
blockExUnits = \case
  BlockAlonzo b -> sumExUnits b
  BlockBabbage b -> sumExUnits b
  BlockConway b -> sumExUnits b
  _ -> (0, 0)

-- | Sum (steps, mem) per Plutus language across all transactions in the
-- block. Tagging strategy (witness-set only, no UTxO walk):
--
--   * For each tx, inspect @wits ^. scriptTxWitsL@ and collect the set of
--     'Plutus.Language' values appearing as 'PlutusScript' witnesses.
--   * If exactly one language is present, attribute the tx's @totExUnits@
--     entirely to that language.
--   * If multiple languages, attribute proportionally (each language gets
--     @totExUnits / k@ where @k@ is the language count). This affects <1%
--     of mainnet txs.
--   * If the witness set has *no* Plutus scripts but the tx has non-zero
--     exUnits (reference-script-only tx, Babbage+), fall back to the era
--     default: BlockBabbage→V2, BlockConway→V3, BlockAlonzo→V1 (which only
--     has V1 anyway). This bias is bounded by the ref-script fraction
--     within Babbage (single-digit % of txs in our subsample).
--
-- Returns @(v1_steps, v1_mem, v2_steps, v2_mem, v3_steps, v3_mem)@.
-- Pre-Alonzo: all zeros.
blockPlutusLangExUnits ::
  StandardBlock -> (Word64, Word64, Word64, Word64, Word64, Word64)
blockPlutusLangExUnits = \case
  BlockAlonzo b -> sumPlutusLang Plutus.PlutusV1 b
  BlockBabbage b -> sumPlutusLang Plutus.PlutusV2 b
  BlockConway b -> sumPlutusLang Plutus.PlutusV3 b
  _ -> (0, 0, 0, 0, 0, 0)

sumPlutusLang ::
  forall proto era.
  ( Core.EraBlockBody era
  , Alonzo.AlonzoEraTxWits era
  ) =>
  Plutus.Language ->
  Shelley.ShelleyBlock proto era ->
  (Word64, Word64, Word64, Word64, Word64, Word64)
sumPlutusLang eraDefault blk = case Shelley.shelleyBlockRaw blk of
  SL.Block _ body -> foldl' addTx (0, 0, 0, 0, 0, 0) (body ^. Core.txSeqBlockBodyL)
 where
  addTx acc@(!v1s, !v1m, !v2s, !v2m, !v3s, !v3m) tx =
    case Alonzo.totExUnits tx of
      Alonzo.ExUnits 0 0 -> acc
      Alonzo.ExUnits m s ->
        let scriptsMap = tx ^. Core.witsTxL ^. Core.scriptTxWitsL
            langs =
              Set.fromList
                [ Alonzo.plutusScriptLanguage ps
                | Just ps <- map Alonzo.toPlutusScript (toList scriptsMap)
                ]
            steps = fromIntegral s :: Word64
            mem = fromIntegral m :: Word64
            chosenLangs
              | Set.null langs = Set.singleton eraDefault
              | otherwise = langs
            k = fromIntegral (Set.size chosenLangs) :: Word64
            stepsPer = steps `div` max 1 k
            memPer = mem `div` max 1 k
            -- Add to whichever languages appeared. Integer division means
            -- the trace amount lost to floor() on multi-language txs is at
            -- most (k-1)/k of one step, totally negligible at the per-block
            -- aggregate. The invariant Σ vN_steps == script_exec_steps may
            -- be off by O(num_txs * (k-1)/k) per block; the join script
            -- asserts equality with a small tolerance.
            addLang (a1s, a1m, a2s, a2m, a3s, a3m) lang =
              case lang of
                Plutus.PlutusV1 -> (a1s + stepsPer, a1m + memPer, a2s, a2m, a3s, a3m)
                Plutus.PlutusV2 -> (a1s, a1m, a2s + stepsPer, a2m + memPer, a3s, a3m)
                Plutus.PlutusV3 -> (a1s, a1m, a2s, a2m, a3s + stepsPer, a3m + memPer)
                _ -> (a1s, a1m, a2s, a2m, a3s, a3m)
         in foldl' addLang (v1s, v1m, v2s, v2m, v3s, v3m) (Set.toList chosenLangs)

sumExUnits ::
  forall proto era.
  (Core.EraBlockBody era, Alonzo.AlonzoEraTxWits era) =>
  Shelley.ShelleyBlock proto era ->
  (Word64, Word64)
sumExUnits blk = case Shelley.shelleyBlockRaw blk of
  SL.Block _ body -> foldl' addTx (0, 0) (body ^. Core.txSeqBlockBodyL)
 where
  addTx (!steps, !mem) tx =
    case Alonzo.totExUnits tx of
      Alonzo.ExUnits m s ->
        ( steps + fromIntegral s
        , mem + fromIntegral m
        )

-- | Babbage-era introductions: reference inputs (read state without spending),
-- reference scripts (script attached to a UTxO for others to use), inline
-- datums (datum embedded in output rather than hashed). All zero pre-Babbage;
-- summed across every tx in Babbage and Conway blocks.
--
-- Returns @(num_reference_inputs, num_reference_scripts, num_inline_datums)@.
blockBabbageFeats :: StandardBlock -> (Int, Int, Int)
blockBabbageFeats = \case
  BlockBabbage b -> sumBabbageFeats b
  BlockConway b -> sumBabbageFeats b
  _ -> (0, 0, 0)

sumBabbageFeats ::
  forall proto era.
  ( Core.EraBlockBody era
  , Babbage.BabbageEraTxBody era
  ) =>
  Shelley.ShelleyBlock proto era ->
  (Int, Int, Int)
sumBabbageFeats blk = case Shelley.shelleyBlockRaw blk of
  SL.Block _ body -> foldl' addTx (0, 0, 0) (body ^. Core.txSeqBlockBodyL)
 where
  addTx (!ri, !rs, !nDatums) tx =
    let txBody = tx ^. Core.bodyTxL
        nRefIn = Set.size (txBody ^. Babbage.referenceInputsTxBodyL)
        outs = toList (txBody ^. Core.outputsTxBodyL)
        countSJust f = length [() | o <- outs, SJust _ <- [o ^. f]]
        nRefScripts = countSJust Babbage.referenceScriptTxOutL
        nInlineDatums = countSJust Babbage.dataTxOutL
     in (ri + nRefIn, rs + nRefScripts, nDatums + nInlineDatums)
