// Reachability controls require histories from actual preparation/time/native actions.
spec ProbeProductCompileUnknown observes mProductResourceCreated, mProductClaimRevoked, mProductResourceObserved {
 var created: set[int]; var revoked: set[int];
 start state Watching { 
 on mProductResourceCreated do (p: tService) { created += (p.id); }
 on mProductClaimRevoked do (p: tService) { revoked += (p.id); }
 on mProductResourceObserved do (p: tResourceView) {
   assert !(p.service.id == 1 && p.kind == ResourceUnknown && 1 in created && 1 in revoked),
     "witness: compile creation crash retained original unknown preparation";
 } }
}
test tcProbeProductCompileUnknown [main = TestProductCompileUnknown]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductCompileUnknown in (union ProductSystem, { TestProductCompileUnknown });
spec ProbeProductCompileReadyRecovery observes mProductResourceCreated, mProductReady, mProductResourceObserved {
 var created: set[int]; var ready: map[int, tLease];
 start state Watching { 
 on mProductResourceCreated do (p: tService) { created += (p.id); }
 on mProductReady do (p: tLease) { ready[p.service.id] = p; }
 on mProductResourceObserved do (p: tResourceView) {
   assert !(p.service.id == 1 && p.kind == ResourceLeaseRecovered && 1 in created && 1 in ready && p.lease == ready[1]),
     "witness: original compile locations recovered after ready reply loss";
 } }
}
test tcProbeProductCompileReadyRecovery [main = TestProductCompileReadyRecovery]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductCompileReadyRecovery in (union ProductSystem, { TestProductCompileReadyRecovery });
spec ProbeProductDeadResource observes mProductReady, mProductResourceOwnerDead, mProductResourceObserved {
 var issued: set[int]; var dead: set[int];
 start state Watching { 
 on mProductReady do (p: tLease) { issued += (p.service.id); }
 on mProductResourceOwnerDead do (p: tService) { dead += (p.id); }
 on mProductResourceObserved do (p: tResourceView) {
   assert !(p.service.id == 2 && p.kind == ResourceUnknown && 2 in issued && 2 in dead),
     "witness: issued launch lease became unusable after resource owner death";
 } }
}
test tcProbeProductDeadResource [main = TestProductDeadResource]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductDeadResource in (union ProductSystem, { TestProductDeadResource });
spec ProbeProductForeignAssociation observes mProductCompleted, mProductAssociationRefused {
 var producer: tProductResult;
 start state Watching { 
 on mProductCompleted do (p: tProductResult) { if (p.service.id == 1) { producer = p; } }
 on mProductAssociationRefused do (p: tService) {
   assert !(producer.service.id == 1 && p.id == 2 && p.association != producer.resultDigest),
     "witness: foreign compile completion refused before launch preparation";
 } }
}
test tcProbeProductForeignAssociation [main = TestProductForeignAssociation]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductForeignAssociation in (union ProductSystem, { TestProductForeignAssociation });
spec ProbeProductBadFingerprint observes mProductReady, mProductFingerprintRefused {
 var ready: set[int];
 start state Watching { 
 on mProductReady do (p: tLease) { ready += (p.service.id); }
 on mProductFingerprintRefused do (p: tService) {
   assert !(p.id == 2 && 2 in ready), "witness: physical fingerprint refused after resource ready before native launch";
 } }
}
test tcProbeProductBadFingerprint [main = TestProductBadFingerprint]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductBadFingerprint in (union ProductSystem, { TestProductBadFingerprint });
spec ProbeProductBudgetOne observes mProductWallSelected, mProductOfferRetained {
 var selected: tOffer;
 start state Watching { 
 on mProductWallSelected do (p: (offer: tOffer, remaining: int, allowance: int)) {
   if (p.remaining == 50100 && p.offer.wall == 1) { selected = p.offer; }
 }
 on mProductOfferRetained do (p: tOffer) {
   assert !(selected == p && p.commandRef == 1), "witness: ready remaining 50100 selected immutable wall 1";
 } }
}
test tcProbeProductBudgetOne [main = TestProductBudgetOne]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductBudgetOne in (union ProductSystem, { TestProductBudgetOne });
spec ProbeProductBudgetBelowCap observes mProductWallSelected, mProductOfferRetained {
 var selected: tOffer;
 start state Watching { 
 on mProductWallSelected do (p: (offer: tOffer, remaining: int, allowance: int)) {
   if (p.remaining == 229099 && p.offer.wall == 179) { selected = p.offer; }
 }
 on mProductOfferRetained do (p: tOffer) {
   assert !(selected == p && p.commandRef == 1), "witness: ready remaining 229099 selected immutable wall 179";
 } }
}
test tcProbeProductBudgetBelowCap [main = TestProductBudgetBelowCap]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductBudgetBelowCap in (union ProductSystem, { TestProductBudgetBelowCap });
spec ProbeProductBudgetCap observes mProductWallSelected, mProductOfferRetained {
 var selected: tOffer;
 start state Watching { 
 on mProductWallSelected do (p: (offer: tOffer, remaining: int, allowance: int)) {
   if (p.remaining == 229100 && p.offer.wall == 180) { selected = p.offer; }
 }
 on mProductOfferRetained do (p: tOffer) {
   assert !(selected == p && p.commandRef == 1), "witness: ready remaining 229100 selected immutable wall 180";
 } }
}
test tcProbeProductBudgetCap [main = TestProductBudgetCap]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductBudgetCap in (union ProductSystem, { TestProductBudgetCap });
spec ProbeProductBudgetCold observes mProductWallSelected, mProductOfferRetained {
 var selected: tOffer;
 start state Watching { 
 on mProductWallSelected do (p: (offer: tOffer, remaining: int, allowance: int)) {
   if (p.remaining == 270000 && p.offer.wall == 180) { selected = p.offer; }
 }
 on mProductOfferRetained do (p: tOffer) {
   assert !(selected == p && p.commandRef == 1), "witness: ready remaining 270000 selected immutable wall 180";
 } }
}
test tcProbeProductBudgetCold [main = TestProductBudgetCold]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductBudgetCold in (union ProductSystem, { TestProductBudgetCold });
spec ProbeProductBudgetZero observes mProductReady, mProductWallRefused, mProductNativeReserved {
 var ready: set[int]; var native: set[int];
 start state Watching { 
 on mProductReady do (p: tLease) { ready += (p.service.id); }
 on mProductNativeReserved do (p: tPreparedProduct) { native += (p.offer.commandRef); }
 on mProductWallRefused do (p: (service: tService, remaining: int)) {
   assert !(p.service.id == 1 && p.remaining == 0 && 1 in ready && !(1 in native)), "witness: ready remaining 0 refused before native reservation";
 } }
}
test tcProbeProductBudgetZero [main = TestProductBudgetZero]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductBudgetZero in (union ProductSystem, { TestProductBudgetZero });
spec ProbeProductBudgetBelowOne observes mProductReady, mProductWallRefused, mProductNativeReserved {
 var ready: set[int]; var native: set[int];
 start state Watching { 
 on mProductReady do (p: tLease) { ready += (p.service.id); }
 on mProductNativeReserved do (p: tPreparedProduct) { native += (p.offer.commandRef); }
 on mProductWallRefused do (p: (service: tService, remaining: int)) {
   assert !(p.service.id == 1 && p.remaining == 50099 && 1 in ready && !(1 in native)), "witness: ready remaining 50099 refused before native reservation";
 } }
}
test tcProbeProductBudgetBelowOne [main = TestProductBudgetBelowOne]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductBudgetBelowOne in (union ProductSystem, { TestProductBudgetBelowOne });
spec ProbeProductExpiredOffer observes mProductOfferRetained, mProductTime, mProductClearanceRefused, mProductNativeReserved {
 var retained: tOffer; var elapsed: int; var refused: int; var native: set[int];
 start state Watching { 
 on mProductOfferRetained do (p: tOffer) { retained = p; }
 on mProductTime do (p: int) { elapsed = p; }
 on mProductNativeReserved do (p: tPreparedProduct) { native += (p.offer.commandRef); }
 on mProductClearanceRefused do (p: tOffer) {
   refused = refused + 1;
   assert !(refused == 2 && p == retained && p.wall == 180 && elapsed == 150000 && !(1 in native)),
     "witness: delayed immutable offer refused again on original identity recovery";
 } }
}
test tcProbeProductExpiredOffer [main = TestProductExpiredOffer]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductExpiredOffer in (union ProductSystem, { TestProductExpiredOffer });
spec ProbeProductPostSendDelay observes mStart, mProductTime, mProductNativeQuery {
 var started: set[tKey]; var elapsed: int;
 start state Watching { 
 on mStart do (p: tNative) { started += (p.key); }
 on mProductTime do (p: int) { elapsed = p; }
 on mProductNativeQuery do (p: tPreparedProduct) {
   assert !(p.native.key in started && p.offer.commandRef == 1 && p.offer.wall == 180 && elapsed == 150000),
     "witness: delayed post-start recovery queried original native child without clearance";
 } }
}
test tcProbeProductPostSendDelay [main = TestProductPostSendDelay]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductPostSendDelay in (union ProductSystem, { TestProductPostSendDelay });
spec ProbeProductColdRun observes mProductControlComplete, mStart, mProductCompileRunElapsed, mProductCompleted {
 var control: tPreparedProduct; var started: set[tKey]; var run: int;
 start state Watching { 
 on mProductControlComplete do (p: tPreparedProduct) { control = p; }
 on mStart do (p: tNative) { started += (p.key); }
 on mProductCompileRunElapsed do (p: int) { run = p; }
 on mProductCompleted do (p: tProductResult) {
   assert !(p.service.id == 1 && control.offer.wall == 180 && control.native.key in started && run == 70000),
     "witness: cold preparation control and native compile completed under original authority";
 } }
}
test tcProbeProductColdRun [main = TestProductColdRun]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductColdRun in (union ProductSystem, { TestProductColdRun });
spec ProbeProductActualServiceAdmission observes mAdmit, mProductNativeAssociated, mProductTerminalAssociated {
 var admitted: map[tKey, tRequest]; var associated: map[int, tPreparedProduct];
 start state Watching { 
 on mAdmit do (p: tRequest) { admitted[p.key] = p; }
 on mProductNativeAssociated do (p: tPreparedProduct) { associated[p.offer.commandRef] = p; }
 on mProductTerminalAssociated do (p: tPreparedProduct) {
   assert !(p.offer.commandRef == 2 && p.offer.commandRef in associated && associated[2] == p &&
     p.native.key in admitted && admitted[p.native.key] == p.native),
     "witness: owner-derived launch completed through actual native admission association";
 } }
}
test tcProbeProductActualServiceAdmission [main = TestProductLifecycle]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductActualServiceAdmission in (union ProductSystem, { TestProductLifecycle });
spec ProbeProductBudgetReduced observes mProductWallSelected, mProductOfferRetained {
 var selected: tOffer;
 start state Watching {
   on mProductWallSelected do (p: (offer: tOffer, remaining: int, allowance: int)) {
     if (p.remaining == 150000 && p.offer.wall == 100) { selected = p.offer; }
   }
   on mProductOfferRetained do (p: tOffer) {
     assert !(selected == p && p.commandRef == 1), "witness: ready remaining 150000 selected immutable wall 100";
   }
 }
}
test tcProbeProductBudgetReduced [main = TestProductBudgetReduced]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductBudgetReduced in (union ProductSystem, { TestProductBudgetReduced });
spec ProbeProductForeignArtifact observes mProductCompleted, mProductAssociationRefused {
 var producer: tProductResult;
 start state Watching {
   on mProductCompleted do (p: tProductResult) { if (p.service.id == 1) { producer = p; } }
   on mProductAssociationRefused do (p: tService) {
     assert !(producer.service.id == 1 && p.id == 2 && p.artifact != producer.artifact),
       "witness: foreign issued artifact refused before launch preparation";
   }
 }
}
test tcProbeProductForeignArtifact [main = TestProductForeignArtifact]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductForeignArtifact in (union ProductSystem, { TestProductForeignArtifact });

// The normal directed case requires actual refusal before genuine completion.
// A successful workflow that never delivered the foreign input cannot pass.
spec ForeignTerminalRefusalSafety observes mProductNativeAssociated, mProductTerminalRefused, mProductCompleted {
 var original: tRequest;
 var refused: tRequest;
 start state Watching {
 on mProductNativeAssociated do (p: tPreparedProduct) { if (p.offer.commandRef == 1) { original = p.native; } }
 on mProductTerminalRefused do (n: tRequest) { if (n.key == original.key && n.digest == 2) { refused = n; } }
 on mProductCompleted do (p: tProductResult) {
   if (p.service.id == 1) {
     assert original.digest == 1 && refused.key == original.key && refused.digest == 2,
       "foreign terminal control completed without prior exact refusal";
   }
 } }
}
spec ProbeProductForeignNativeTerminal observes mProductNativeAssociated, mProductTerminalRefused, mProductCompleted {
 var original: tRequest;
 var completed: set[int];
 start state Watching {
 on mProductNativeAssociated do (p: tPreparedProduct) { if (p.offer.commandRef == 1) { original = p.native; } }
 on mProductCompleted do (p: tProductResult) { completed += (p.service.id); }
 on mProductTerminalRefused do (n: tRequest) {
   assert !(original.key.execution == 1 && n.key == original.key && original.digest == 1 && n.digest == 2 && !(1 in completed)),
     "witness: same-key foreign native terminal refused before genuine completion";
 } }
}
test tcProbeProductForeignNativeTerminal [main = TestProductForeignNativeTerminal]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, ProbeProductForeignNativeTerminal in (union ProductSystem, { TestProductForeignNativeTerminal });
