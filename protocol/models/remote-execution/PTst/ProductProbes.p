// Each reachability failure names a fact emitted by its owning transition.
spec ProbeProductComplete observes mProductWitness {
 start state Watching { on mProductWitness do (p: tProductWitness) {
 assert p != ProductComplete, "witness: product completion retained before outer receipt";
 } } }
test tcProbeProductComplete [main = TestProductLifecycle]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, ProbeProductComplete in (union ProductSystem, { TestProductLifecycle });
spec ProbeProductClearedPending observes mProductWitness {
 start state Watching { on mProductWitness do (p: tProductWitness) {
 assert p != ProductClearedPending, "witness: command cleared before native admission";
 } } }
test tcProbeProductClearedPending [main = TestProductLifecycle]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, ProbeProductClearedPending in (union ProductSystem, { TestProductLifecycle });
spec ProbeProductOfferConflict observes mProductWitness {
 start state Watching { on mProductWitness do (p: tProductWitness) {
 assert p != ProductConflict, "witness: changed command offer refused without replacement";
 } } }
test tcProbeProductOfferConflict [main = TestProductOfferConflict]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, ProbeProductOfferConflict in (union ProductSystem, { TestProductOfferConflict });
spec ProbeProductResourceUnknown observes mProductResourceCreated, mProductClaimRevoked, mProductWitness {
 var created: set[int];
 var revoked: set[int];
 start state Watching {
   on mProductResourceCreated do (p: tService) { created += (p.id); }
   on mProductClaimRevoked do (p: tService) { revoked += (p.id); }
   on mProductWitness do (p: tProductWitness) {
     assert !(p == ProductUnknownResource && 2 in created && 2 in revoked),
       "witness: resource creation remained unknown after reply loss";
   }
 }
}
test tcProbeProductResourceUnknown [main = TestProductResourceUnknown]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, ProbeProductResourceUnknown in (union ProductSystem, { TestProductResourceUnknown });
spec ProbeProductLeaseRecovered observes mProductWitness {
 start state Watching { on mProductWitness do (p: tProductWitness) {
 assert p != ProductRecoveredLease, "witness: issued lease recovered under original service identity";
 } } }
test tcProbeProductLeaseRecovered [main = TestProductLeaseRecovery]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, ProbeProductLeaseRecovered in (union ProductSystem, { TestProductLeaseRecovery });
spec ProbeProductLaunchUnknown observes mStart, mProductWitness {
 var started: set[int];
 start state Watching {
   on mStart do (p: tNative) { started += (p.key.execution); }
   on mProductWitness do (p: tProductWitness) {
     assert !(p == ProductUnknownLaunch && 2 in started),
       "witness: lost launch reply preserved possible native work";
   }
 }
}
test tcProbeProductLaunchUnknown [main = TestProductLaunchLoss]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, ProbeProductLaunchUnknown in (union ProductSystem, { TestProductLaunchLoss });
spec ProbeProductDistinctChildren observes mProductChildReserved {
 var children: set[tAddress];
 start state Watching { on mProductChildReserved do (p: tChildCandidate) {
 children += (p.logical);
 assert !(p.logical.namespace == 1 && sizeof(children) == 2), "witness: equal ordinals from distinct capabilities reserved distinct children";
 } } }
test tcProbeProductDistinctChildren [main = TestProductChildAddresses]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, ProbeProductDistinctChildren in (union ProductSystem, { TestProductChildAddresses });
spec ProbeProductFinalUnknown observes mReceipt, mProductOwnerStored, mProductFinalStored, mProductWitness {
 var nativeReceipts: set[int];
 var outerStored: set[int];
 var finalStored: int;
 start state Watching {
   on mReceipt do (p: tRequest) { nativeReceipts += (p.key.execution); }
   on mProductOwnerStored do (p: tProductResult) { outerStored += (p.service.id); }
   on mProductFinalStored do (p: int) { finalStored = p; }
   on mProductWitness do (p: tProductWitness) {
     assert !(p == ProductUnknownFinal && sizeof(nativeReceipts) == 2 && sizeof(outerStored) == 2 && finalStored == 0),
       "witness: retained children did not reconstruct final tool outcome";
   }
 }
}
test tcProbeProductFinalUnknown [main = TestProductChildOnlyRecovery]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, ProbeProductFinalUnknown in (union ProductSystem, { TestProductChildOnlyRecovery });

// Histories belong to the real resource, Helper and cleanup transitions.
// The driver stage cannot establish that the mixed workload reached live Launch.
spec ProbeProductMixedFaults observes mProductResourceIntent, mProductResourceCreated, mProductLease, mStart, mRetired, mProductCleanupObservation {
 var intents: set[int];
 var created: set[int];
 var issued: set[int];
 var started: set[tKey];
 var retired: set[tKey];
 start state Watching {
   on mProductResourceIntent do (p: tService) { intents += (p.id); }
   on mProductResourceCreated do (p: tService) { created += (p.id); }
   on mProductLease do (p: tLease) { issued += (p.service.id); }
   on mStart do (p: tNative) { started += (p.key); }
   on mRetired do (p: tKey) { retired += (p); }
   on mProductCleanupObservation do (p: (native: tKey, retired: bool)) {
     assert !(p.native.execution == 2 && p.native in started && !(p.native in retired) &&
              2 in intents && 2 in created && 2 in issued && !p.retired),
       "witness: mixed faults reached live launch resource cleanup";
   }
 }
}
test tcProbeProductMixedFaults [main = TestProductFaults]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, ProbeProductMixedFaults in (union ProductSystem, { TestProductFaults });
