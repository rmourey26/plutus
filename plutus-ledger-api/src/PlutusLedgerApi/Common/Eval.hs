-- editorconfig-checker-disable-file
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData        #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeApplications  #-}

module PlutusLedgerApi.Common.Eval
    ( EvaluationError (..)
    , EvaluationContext (..)
    , AsScriptDecodeError (..)
    , LogOutput
    , VerboseMode (..)
    , evaluateScriptRestricting
    , evaluateScriptCounting
    , mkDynEvaluationContext
    , toMachineParameters
    , assertWellFormedCostModelParams
    ) where

import Control.Lens
import PlutusCore
import PlutusCore as ScriptPlutus (Version, defaultVersion)
import PlutusCore.Data as Plutus
import PlutusCore.Default
import PlutusCore.Evaluation.Machine.CostModelInterface as Plutus
import PlutusCore.Evaluation.Machine.ExBudget as Plutus
import PlutusCore.Evaluation.Machine.ExBudgetingDefaults qualified as Plutus
import PlutusCore.Evaluation.Machine.MachineParameters.Default
import PlutusCore.MkPlc qualified as UPLC
import PlutusCore.Pretty
import PlutusLedgerApi.Common.SerialisedScript
import PlutusLedgerApi.Common.Versions
import PlutusPrelude
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.Evaluation.Machine.Cek qualified as UPLC


import Control.Monad.Except
import Control.Monad.Writer
import Data.Text as Text
import Data.Tuple
import NoThunks.Class
import Prettyprinter

-- | Errors that can be thrown when evaluating a Plutus script.
data EvaluationError =
    CekError (UPLC.CekEvaluationException NamedDeBruijn DefaultUni DefaultFun) -- ^ An error from the evaluator itself
    | DeBruijnError FreeVariableError -- ^ An error in the pre-evaluation step of converting from de-Bruijn indices
    | CodecError ScriptDecodeError -- ^ A deserialisation error
    | IncompatibleVersionError (ScriptPlutus.Version ()) -- ^ An error indicating a version tag that we don't support
    -- TODO: make this error more informative when we have more information about what went wrong
    | CostModelParameterMismatch -- ^ An error indicating that the cost model parameters didn't match what we expected
    deriving stock (Show, Eq)
makeClassyPrisms ''EvaluationError

instance AsScriptDecodeError EvaluationError where
    _ScriptDecodeError = _CodecError

instance Pretty EvaluationError where
    pretty (CekError e)      = prettyClassicDef e
    pretty (DeBruijnError e) = pretty e
    pretty (CodecError e) = viaShow e
    pretty (IncompatibleVersionError actual) = "This version of the Plutus Core interface does not support the version indicated by the AST:" <+> pretty actual
    pretty CostModelParameterMismatch = "Cost model parameters were not as we expected"

-- | A simple toggle indicating whether or not we should accumulate logs during script execution.
data VerboseMode =
    Verbose -- ^ accumulate all traces
    | Quiet -- ^ don't accumulate anything
    deriving stock (Eq)

{-| The type of the executed script's accumulated log output: a list of 'Text'.

It will be an empty list if the `VerboseMode` is set to `Quiet`.
-}
type LogOutput = [Text.Text]

{-| Shared helper for the evaluation functions: 'evaluateScriptCounting' and 'evaluateScriptRestricting',

Given a 'SerialisedScript':

1) deserialises to a plutus 'Term' and checks its ast version
2) applies the term to a list of 'Data' arguments (e.g. Datum, Redeemer, `ScriptContext`)
3) checks that the applied-term is well-scoped
4) returns the applied-term
-}
mkTermToEvaluate
    :: (MonadError EvaluationError m)
    => LedgerPlutusVersion -- ^ the ledger Plutus version of the script under execution.
    -> ProtocolVersion -- ^ which protocol version to run the operation in
    -> SerialisedScript -- ^ the script to evaluate in serialised form
    -> [Plutus.Data] -- ^ the arguments that the script's underlying term will be applied to
    -> m (UPLC.Term UPLC.NamedDeBruijn DefaultUni DefaultFun ())
mkTermToEvaluate lv pv bs args = do
    -- It decodes the program through the optimized ScriptForExecution. See `ScriptForExecution`.
    ScriptForExecution (UPLC.Program _ v t) <- fromSerialisedScript lv pv bs
    unless (v == ScriptPlutus.defaultVersion ()) $ throwError $ IncompatibleVersionError v
    let termArgs = fmap (UPLC.mkConstant ()) args
        appliedT = UPLC.mkIterApp () t termArgs

    -- make sure that term is closed, i.e. well-scoped
    through (liftEither . first DeBruijnError . UPLC.checkScope) appliedT

toMachineParameters :: ProtocolVersion -> EvaluationContext -> DefaultMachineParameters
toMachineParameters _ = machineParameters

{-| An opaque type that contains all the static parameters that the evaluator needs to evaluate a
script.  This is so that they can be computed once and cached, rather than being recomputed on every
evaluation.
-}
newtype EvaluationContext = EvaluationContext
    { machineParameters :: DefaultMachineParameters
    }
    deriving stock Generic
    deriving anyclass (NFData, NoThunks)

{-|  Create an 'EvaluationContext' for a given plutus-builtins' version.

The input is a `Map` of `Text`s to cost integer values (aka `Plutus.CostModelParams`, `Alonzo.CostModel`)
See Note [Inlining meanings of builtins].

IMPORTANT: The evaluation context of every Plutus version must be recreated upon a protocol update
with the updated cost model parameters.
-}
mkDynEvaluationContext :: MonadError CostModelApplyError m => BuiltinVersion DefaultFun -> Plutus.CostModelParams -> m EvaluationContext
mkDynEvaluationContext ver newCMP =
    EvaluationContext <$> mkMachineParametersFor ver newCMP

-- FIXME: remove this function
assertWellFormedCostModelParams :: MonadError CostModelApplyError m => Plutus.CostModelParams -> m ()
assertWellFormedCostModelParams = void . Plutus.applyCostModelParams Plutus.defaultCekCostModel

{-| Evaluates a script, with a cost model and a budget that restricts how many
resources it can use according to the cost model. Also returns the budget that
was actually used.

Can be used to calculate budgets for scripts, but even in this case you must give
a limit to guard against scripts that run for a long time or loop.

Note: Parameterized over the ledger-plutus-version since the builtins allowed (during decoding) differs.
-}
evaluateScriptRestricting
    :: LedgerPlutusVersion -- ^ The ledger Plutus version of the script under execution.
    -> ProtocolVersion -- ^ Which protocol version to run the operation in
    -> VerboseMode     -- ^ Whether to produce log output
    -> EvaluationContext -- ^ Includes the cost model to use for tallying up the execution costs
    -> ExBudget        -- ^ The resource budget which must not be exceeded during evaluation
    -> SerialisedScript          -- ^ The script to evaluate
    -> [Plutus.Data]          -- ^ The arguments to the script
    -> (LogOutput, Either EvaluationError ExBudget)
evaluateScriptRestricting lv pv verbose ectx budget p args = swap $ runWriter @LogOutput $ runExceptT $ do
    appliedTerm <- mkTermToEvaluate lv pv p args

    let (res, UPLC.RestrictingSt (ExRestrictingBudget final), logs) =
            UPLC.runCekDeBruijn
                (toMachineParameters pv ectx)
                (UPLC.restricting $ ExRestrictingBudget budget)
                (if verbose == Verbose then UPLC.logEmitter else UPLC.noEmitter)
                appliedTerm

    tell logs
    liftEither $ first CekError $ void res
    pure (budget `minusExBudget` final)

{-| Evaluates a script, returning the minimum budget that the script would need
to evaluate successfully. This will take as long as the script takes, if you need to
limit the execution time of the script also, you can use 'evaluateScriptRestricting', which
also returns the used budget.

Note: Parameterized over the ledger-plutus-version since the builtins allowed (during decoding) differs.
-}
evaluateScriptCounting
    :: LedgerPlutusVersion -- ^ The ledger Plutus version of the script under execution.
    -> ProtocolVersion -- ^ Which protocol version to run the operation in
    -> VerboseMode     -- ^ Whether to produce log output
    -> EvaluationContext -- ^ Includes the cost model to use for tallying up the execution costs
    -> SerialisedScript          -- ^ The script to evaluate
    -> [Plutus.Data]          -- ^ The arguments to the script
    -> (LogOutput, Either EvaluationError ExBudget)
evaluateScriptCounting lv pv verbose ectx p args = swap $ runWriter @LogOutput $ runExceptT $ do
    appliedTerm <- mkTermToEvaluate lv pv p args

    let (res, UPLC.CountingSt final, logs) =
            UPLC.runCekDeBruijn
                (toMachineParameters pv ectx)
                UPLC.counting
                (if verbose == Verbose then UPLC.logEmitter else UPLC.noEmitter)
                appliedTerm

    tell logs
    liftEither $ first CekError $ void res
    pure final