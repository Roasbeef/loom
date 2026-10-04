// Product equality classes retain command, scope and result identity separately.
// Native identities and lifecycle events remain owned by the original actors.
enum tProductMode { ProductLifecycle, ProductOfferConflict, ProductResourceUnknown,
  ProductLeaseRecovery, ProductLaunchLoss, ProductChildAddresses, ProductChildOnlyRecovery, ProductFaults }
enum tProductWitness { ProductComplete, ProductClearedPending, ProductConflict,
  ProductUnknownResource, ProductRecoveredLease, ProductUnknownLaunch,
  ProductDistinctChildren, ProductUnknownFinal }
type tService = (id: int, requestDigest: int, scope: int, artifact: int,
  compileRequest: int, resources: int);
type tOffer = (service: tService, commandRef: int, commandDigest: int,
  registration: int, purpose: int);
type tPreparedProduct = (offer: tOffer, native: tRequest);
type tProductResult = (service: tService, resultDigest: int, kind: int);
type tLease = (service: tService, artifact: int, compileRequest: int, scope: int, resources: int);
type tAddress = (tag: int, name: int, ordinal: int, purpose: int, role: int, namespace: int);
type tChildCandidate = (logical: tAddress, address: tAddress);
event eProductBegin: tService;
event eProductReserve: (owner: machine, service: tService);
event eProductOffer: tOffer;
event eProductSubmit: tOffer;
event eProductView: tReply;
event eProductNativeTerminal: tRequest;
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
  return (id = id, requestDigest = 1, scope = 1, artifact = 1, compileRequest = 1, resources = 1);
}
fun productOffer(s: tService): tOffer {
  return (service = s, commandRef = s.id, commandDigest = 1, registration = 1, purpose = s.id);
}
