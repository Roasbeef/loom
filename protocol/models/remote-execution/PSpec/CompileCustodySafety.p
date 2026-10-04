// Histories come from the resource/native actors' actual durable decisions.
// Missing local association never supplies a negative Submit fact.
spec CompileCustodySafety observes mProductResourceIntent, mProductClaimRevoked,
  mProductReady, mCompileBeforeCommitted, mProductNativeAssociated,
  mNativePayloadRetained, mNativeTerminalCommitted, mCompileNativeSettled,
  mProductCompleted, mProductOwnerStored, mProductReceipt, mCompileReadback,
  mCompileRecovered, mCompileReleased {
  var live: set[int];
  var ready: set[int];
  var associated: map[int, tPreparedProduct];
  var completed: map[int, tProductResult];
  var stored: map[int, tProductResult];
  var acknowledged: set[int];
  var payloads: map[tKey, tTerminalPayload];
  var terminal: map[tKey, tTerminalPayload];
  start state Watching {
    on mProductResourceIntent do (s: tService) { live += (s.id); }
    on mProductClaimRevoked do (s: tService) { live -= (s.id); }
    on mProductReady do (p: tLease) {
      assert !(p.service.id in completed) || completed[p.service.id].provenance != BeforeNativeFailure,
        "ready committed after before-native completion";
      live -= (p.service.id); ready += (p.service.id);
    }
    on mCompileBeforeCommitted do (p: tProductResult) {
      assert !(p.service.id in ready), "before-native completion followed durable ready";
      assert p.service.id in live && !(p.service.id in associated), "before-native failure lacked original live Preparing claim";
      assert p.provenance == BeforeNativeFailure && p.artifact == 0, "before-native failure fabricated artifact";
      if (p.service.id in completed) { assert completed[p.service.id] == p, "retained outer completion changed"; }
      completed[p.service.id] = p; live -= (p.service.id);
    }
    on mProductNativeAssociated do (p: tPreparedProduct) {
      assert p.offer.service.id in ready && !(p.offer.service.id in completed), "native association lacked pending ready service";
      associated[p.offer.commandRef] = p;
    }
    on mNativePayloadRetained do (p: tTerminalPayload) {
      if (p.request.key in payloads) { assert payloads[p.request.key] == p, "retained native payload changed"; }
      payloads[p.request.key] = p;
    }
    on mNativeTerminalCommitted do (p: tTerminalPayload) {
      assert p.request.key in payloads && payloads[p.request.key] == p, "native terminal commit changed retained payload";
      terminal[p.request.key] = p;
    }
    on mCompileNativeSettled do (p: tProductTerminal) {
      assert p.native.key in terminal && terminal[p.native.key] == p.payload,
        "outer completion preceded exact native terminal commit";
      assert p.native.key.execution in associated && associated[p.native.key.execution].native == p.native,
        "outer completion changed actual native association";
    }
    on mProductCompleted do (p: tProductResult) {
      assert p.provenance == NativeCompletion, "untagged completion bypassed native evidence";
      if (p.service.id in completed) { assert completed[p.service.id] == p, "retained outer completion changed"; }
      completed[p.service.id] = p;
    }
    on mProductOwnerStored do (p: tProductResult) {
      assert p.service.id in completed && completed[p.service.id] == p, "outer owner stored changed completion";
      stored[p.service.id] = p;
    }
    on mProductReceipt do (p: tProductResult) {
      assert p.service.id in stored && stored[p.service.id] == p, "outer receipt preceded exact owner completion";
      acknowledged += (p.service.id);
    }
    on mCompileReadback do (v: tCompileView) { checkView(v); }
    on mCompileRecovered do (v: tCompileView) { checkView(v); }
    on mCompileReleased do (s: tService) { live -= (s.id); }
  }
  fun checkView(v: tCompileView) {
    assert v.retained == (v.service.id in completed), "recovery changed retained completion presence";
    if (v.retained) { assert completed[v.service.id] == v.result, "retained outer completion changed"; }
    assert v.acknowledged == (v.service.id in acknowledged), "recovery confused outer and native receipt";
  }
}
