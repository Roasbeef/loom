// Product equality classes retain command, scope and result identity separately.
// Native identities and lifecycle events remain owned by the original actors.
enum tProductMode { ProductLifecycle, ProductOfferConflict, ProductResourceUnknown,
  ProductLeaseRecovery, ProductLaunchLoss, ProductChildAddresses, ProductChildOnlyRecovery, ProductFaults, ProductCompileUnknown,
  ProductCompileLeaseRecovery, ProductDeadResource, ProductForeignAssociation, ProductForeignArtifact, ProductForeignNativeTerminal,
  ProductBadFingerprint, ProductBudgetZero, ProductBudgetBelowOne, ProductBudgetOne,
  ProductBudgetBelowCap, ProductBudgetCap, ProductBudgetCold, ProductBudgetReduced, ProductExpiredOffer,
  ProductPostSendDelay, ProductColdRun, CompileFailLateReady, CompileSubmitUnassociated, CompilePayloadPending, CompileIndependentReceipts, ProductLiveAssociation }
enum tProductWitness { ProductComplete, ProductClearedPending, ProductConflict,
  ProductUnknownResource, ProductRecoveredLease, ProductUnknownLaunch,
  ProductDistinctChildren, ProductUnknownFinal }
type tService = (id: int, requestDigest: int, scope: int, artifact: int,
  compileRequest: int, resources: int, deadline: int, ceiling: int, association: int, enrollment: int, tokenCommitment: int);
type tOffer = (service: tService, commandRef: int, commandDigest: int,
  registration: int, purpose: int, wall: int, deadline: int);
type tPreparedProduct = (offer: tOffer, native: tRequest);
enum tCompletionProvenance { NativeCompletion, BeforeNativeFailure }
type tProductResult = (service: tService, resultDigest: int, kind: int, artifact: int, provenance: tCompletionProvenance);
type tLease = (service: tService, artifact: int, compileRequest: int, scope: int, resources: int);
type tAddress = (tag: int, name: int, ordinal: int, purpose: int, role: int, namespace: int);
type tChildCandidate = (logical: tAddress, address: tAddress);
event eProductBegin: tService;
event eProductReserve: (owner: machine, service: tService);
event eProductOffer: tOffer;
event eProductSubmit: tOffer;
event eProductView: tReply;
type tProductTerminal = (native: tRequest, evidence: tRow, payload: tTerminalPayload);
event eProductNativeTerminal: tProductTerminal;
event eProductCompleted: tProductResult;
event eProductReceipt: tProductResult;
event eProductOuterDone: tProductResult;
event eProductResourceQuery;
enum tResourceViewKind { ResourceReplyLost, ResourceUnknown, ResourceLease, ResourceLeaseRecovered }
type tResourceView = (service: tService, kind: tResourceViewKind, lease: tLease);
event eProductResourceView: tResourceView;
event eProductResourceObserved: tResourceViewKind;
event mProductResourceObserved: tResourceView;
event eProductQuery;
event eProductLoseLaunch;
event eProductRelease;
event eProductRecoverFinal;
event eProductLossDone;
event eProductChild: (logical: tAddress, capacity: int);
event eProductChildDone: bool;
event eProductExecutorCrash;
event eProductReplay;
event eProductOwnerCrash;
event mProductCustody: tService;
event mProductAdmission: tService;
event mProductCleared: tOffer;
event mProductNativeReserved: tPreparedProduct;
event mProductOfferRejected: tOffer;
event mProductChildCandidate: tChildCandidate;
event mProductChildReserved: tChildCandidate;
event mProductResourceIntent: tService;
event mProductResourceCreated: tService;
event mProductClaimRevoked: tService;
event mProductLease: tLease;
event mProductCompleted: tProductResult;
event mProductOwnerStored: tProductResult;
event mProductReceipt: tProductResult;
event mProductFinalStored: int;
event mProductFinalRecovered: int;
event mProductLaunchObservation: (native: tKey, neverLaunched: bool);
event mProductCleanupObservation: (native: tKey, retired: bool);
event mProductWitness: tProductWitness;
fun productService(id: int): tService {
  return (id = id, requestDigest = 1, scope = 1, artifact = 1, compileRequest = 1, resources = 1, deadline = 300000, ceiling = 180, association = 2, enrollment = 1, tokenCommitment = 1);
}
fun productOffer(s: tService): tOffer {
  return (service = s, commandRef = s.id, commandDigest = 1, registration = 1, purpose = s.id, wall = 180, deadline = s.deadline);
}

// Preparation phases are durable; the live claim and resource owner are not.
// The finite elapsed profiles inject time rather than adding a ticking actor.
enum tPreparation { Reserved, Preparing, PreparedResource, ResourceUncertain, ResourceReleased }
event eProductCreate: int;
event eProductCommitReady: int;
event eProductFingerprint: int;
event eProductResourceOwnerDeath;
event eProductResourceQueryFor: int;
event eProductConstruct: int;
event eProductClearOffer: int;
event eProductAdvanceTime: int;
event eProductRecoverCommand: int;
event eProductBudgetDone;
type tProductAdmission = (prepared: tPreparedProduct, evidence: tReply);
event eProductNativeAdmission: tProductAdmission;
event mProductReady: tLease;
event mProductAssociationChecked: (service: tService, producer: tProductResult);
event mProductAssociationRefused: tService;
event mProductFingerprintChecked: (service: tService, fingerprint: int);
event mProductFingerprintRefused: tService;
event mProductResourceOwnerDead: tService;
event mProductLeaseUsable: tLease;
event mProductWallSelected: (offer: tOffer, remaining: int, allowance: int);
event mProductWallRefused: (service: tService, remaining: int);
event mProductOfferRetained: tOffer;
event mProductTime: int;
event mProductClearanceAttempt: (offer: tOffer, remaining: int, allowance: int);
event mProductClearanceRefused: tOffer;
event mProductNativeAssociated: tPreparedProduct;
event mProductTerminalAssociated: tPreparedProduct;
event mProductTerminalRefused: tRequest;
event mProductNativeQuery: tPreparedProduct;
event mProductControlComplete: tPreparedProduct;
event mProductCompileRunElapsed: int;
fun productAllowance(): int { return 38000 + 2 * 5000; }
fun productWall(remaining: int, ceiling: int): int {
  var w: int;
  if (remaining < 1100 + productAllowance() + 1000) { return 0; }
  w = (remaining - 1100 - productAllowance()) / 1000;
  if (w > ceiling) { w = ceiling; }
  return w;
}
fun budgetProfile(mode: tProductMode): bool {
  return mode == ProductBudgetZero || mode == ProductBudgetBelowOne || mode == ProductBudgetOne ||
    mode == ProductBudgetBelowCap || mode == ProductBudgetCap || mode == ProductBudgetCold || mode == ProductBudgetReduced;
}
fun preparationElapsed(mode: tProductMode, id: int): int {
  if (id != 1) { return 0; }
  if (mode == ProductBudgetReduced) { return 150000; }
  if (mode == ProductBudgetZero) { return 300000; }
  if (mode == ProductBudgetBelowOne) { return 300000 - 50099; }
  if (mode == ProductBudgetOne) { return 300000 - 50100; }
  if (mode == ProductBudgetBelowCap) { return 300000 - 229099; }
  if (mode == ProductBudgetCap) { return 300000 - 229100; }
  return 30000;
}
event eProductCompileElapsed;
event eProductRunTimeDone;

// Compile custody controls use actual transition replies, never scenario facts.
type tCompileView = (service: tService, retained: bool, result: tProductResult,
  acknowledged: bool, associated: bool, preparation: tPreparation);
event eCompileFailPreparation: tProductResult;
event eCompileQuery: int;
event eCompileView: tCompileView;
event eCompileCleanup: int;
event eCompileCreated: int;
event eCompileReadyRefused: int;
event eCompileAssociationRefused: tPreparedProduct;
event eCompileContinueSubmit;
event eCompileReleaseAssociation;
event eCompileAcknowledge: int;
event eCompileRecovered;
event mCompileBeforeCommitted: tProductResult;
event mCompileFailureRefused: tCompileView;
event mCompileReadyRefused: int;
event mCompileReadback: tCompileView;
event mCompileAssociationRefused: tPreparedProduct;
event mCompileTerminalPending: tProductTerminal;
event mCompileNativeSettled: tProductTerminal;
event mCompileReleased: tService;

fun compileBefore(s: tService): tProductResult {
  return (service = s, resultDigest = 2, kind = s.id, artifact = 0, provenance = BeforeNativeFailure);
}
fun compileControl(mode: tProductMode): bool {
  return mode == CompileFailLateReady || mode == CompileSubmitUnassociated ||
    mode == CompilePayloadPending || mode == CompileIndependentReceipts;
}

event mCompileRecovered: tCompileView;

// The original continuation is volatile identity, not a recovered bearer grant.
// Two incarnation classes suffice to distinguish original from reconstructed work.
type tLiveClaim = (issuer: machine, service: tService, incarnation: int);
type tCommand = (prepared: tPreparedProduct, claim: tLiveClaim, resource: machine);
type tCommandWire = (command: tCommand, wire: tWire);
type tAssociationRequest = (command: tCommand, executor: machine, wire: tWire, boot: int, evidence: tReply);
enum tCommandOperation { CommandQuery, CommandCancel, CommandReceipt, CommandStdin }
type tCommandControl = (command: tCommand, wire: tWire, operation: tCommandOperation);
event eOriginalClaim: tLiveClaim;
event ePrepareCommand: tCommand;
event eAdmitCommand: tCommandWire;
event eAssociateCommand: tAssociationRequest;
event eCommandPermit: tAssociationRequest;
event eCommandAssociationRefused: tAssociationRequest;
event eCommandControl: tCommandControl;
event eAssociatedControl: tCommandControl;
event eCommandControlRefused: tCommandControl;
event mOriginalClaim: tLiveClaim;
event mLiveClaimRevoked: tLiveClaim;
event mCommandPending: tAssociationRequest;
event mCommandPermitIssued: tAssociationRequest;
event mCommandPermitConsumed: tAssociationRequest;
event mCommandPermitRefused: tAssociationRequest;
event mCommandAssociationRefused: tAssociationRequest;
event mCommandControlForwarded: tCommandControl;
event mCommandControlRefused: tCommandControl;
event mCommandNativeRecovered: int;
event eLiveReleaseAssociation;

// Directed barriers delay actual answers, without supplying admission facts.
event eLiveAssociationView: tAssociationRequest;
event eLivePermitView: tAssociationRequest;
event eLiveReleasePermit;
event eLiveAssociationRefused: tAssociationRequest;
event eLivePermitRefused: tAssociationRequest;
event eLiveControlAnswer: (control: tCommandControl, forwarded: bool);
event eStdin: tWire;
event eOwnerStdin: tRequest;

event eAssociateForeignClaim: tAssociationRequest;

event eLoseCommandReply: tAssociationRequest;
event mCommandReplyLost: tAssociationRequest;
