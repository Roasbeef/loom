// Four directed controls use real actor replies before advancing. Native facts
// remain owned by Executor/Helper, and outer storage by ProductOwner.
machine CompileCustodyScenario {
  var mode: tProductMode;
  var owner: machine;
  var executor: machine;
  var helper: machine;
  var productOwner: machine;
  var service: machine;
  var stage: int;
  var crashBeforeFailure: bool;
  var lateRefused: bool;
  var beforeStored: bool;
  var beforeRetained: bool;
  var payload: tTerminalPayload;
  var latest: tReply;
  start state Init {
    entry (p: tProductMode) {
      mode = p; announce mScenarioBegin;
      if (mode == CompilePayloadPending) { executor = new Executor((driver = this, mode = TerminalCommitPaused)); }
      else { executor = new Executor((driver = this, mode = Reliable)); }
      helper = new Helper(); owner = new Owner((driver = this, executor = executor, mode = Reliable));
      service = new ProductExecutor((driver = this, mode = mode));
      productOwner = new ProductOwner((driver = this, service = service, nativeOwner = owner, mode = mode));
      send executor, eConnect, (owner = owner, helper = helper);
      send helper, eHelperConnect, executor;
      send productOwner, eProductBegin, productService(1);
      if (mode == CompileFailLateReady) { crashBeforeFailure = choose(); }
      goto Driving;
    }
  }
  state Driving {
    on eCompileCreated do (id: int) {
      if (crashBeforeFailure) { stage = 20; send service, eProductExecutorCrash; }
      else {
        stage = 1; send service, eCompileFailPreparation, compileBefore(productService(1));
        send service, eProductCommitReady, 1;
      }
    }
    on eCompileReadyRefused do (id: int) { lateRefused = true; beforeAdvance(); }
    on eCompileAssociationRefused do (p: tPreparedProduct) {
      assert mode == CompileSubmitUnassociated && stage == 0, "request-only association was not refused";
      stage = 1; send productOwner, eCompileContinueSubmit;
    }
    on eCompileRecovered do {
      if (mode == CompileFailLateReady) {
        if (stage == 20) { stage = 21; send service, eCompileFailPreparation, compileBefore(productService(1)); }
        else if (stage == 2) {
          stage = 3; send service, eCompileFailPreparation, compileBefore(productService(1));
          send service, eCompileQuery, 1;
        }
      } else if (mode == CompileIndependentReceipts && stage == 12) {
        stage = 13; send service, eCompileQuery, 2;
      }
    }
    on eNativePayloadView do (p: tTerminalPayload) {
      assert mode == CompilePayloadPending && stage == 1, "unexpected paused native payload";
      payload = p; stage = 2; send executor, eCrash;
    }
    on eControlDone do {
      if (mode == CompilePayloadPending && stage == 2) { send owner, eOwnerReconcile, request(1, 1, 1); }
    }
    on eView do (v: tReply) {
      latest = v; send productOwner, eProductView, v;
      if (v.answer != Prior) { return; }
      if (mode == CompileSubmitUnassociated && v.row.phase == Admitted && stage == 1) {
        stage = 2; send service, eCompileFailPreparation, compileBefore(productService(1));
      } else if (mode == CompileSubmitUnassociated && v.row.phase == Running && stage == 3) {
        send helper, eFinishNative;
      } else if (mode == CompilePayloadPending && v.row.phase == Running) {
        if (stage == 0) { stage = 1; send helper, eFinishNative; }
        else if (stage == 2) {
          stage = 3; send service, eProductNativeTerminal, (native = v.request, evidence = v.row, payload = payload);
        }
      } else if (mode == CompileIndependentReceipts) { receiptView(v); }
    }
    on eProductOuterDone do (p: tProductResult) {
      if (mode == CompileFailLateReady) { beforeStored = true; beforeAdvance(); }
      else if (mode == CompileIndependentReceipts) {
        if (p.service.id == 1 && stage == 1) { stage = 2; send productOwner, eCompileAcknowledge, 1; }
        else if (p.service.id == 2 && stage == 8) {
          stage = 9; send owner, eOwnerReceipt, request(2, 1, 1); send helper, eRetireNative;
        }
      } else { send service, eCompileQuery, 1; }
    }
    on eCompileView do (v: tCompileView) {
      if (mode == CompileFailLateReady) {
        if (stage == 21) {
          assert !v.retained && v.preparation == ResourceUncertain, "recovered Preparing granted Before failure";
          finish();
        } else if (stage == 1) { beforeRetained = v.retained; beforeAdvance(); }
        else if (stage == 3) {
          assert v.retained && v.result == compileBefore(productService(1)), "recovered failure lost historical exact result";
          stage = 4; send productOwner, eCompileAcknowledge, 1;
        } else if (stage == 4 && v.acknowledged) { finish(); }
      } else if (mode == CompileSubmitUnassociated) {
        if (stage == 2) {
          assert !v.retained && !v.associated, "Ready plus in-flight Submit accepted Before failure";
          stage = 3; send productOwner, eCompileReleaseAssociation;
        } else if (stage == 3 && v.retained) { assert v.result.provenance == NativeCompletion, "normal native settlement did not resume"; finish(); }
      } else if (mode == CompilePayloadPending) {
        if (stage == 3) {
          assert !v.retained, "half-committed native payload settled outer result";
          stage = 4; send executor, eCommitNativeTerminal, payload.native;
        } else if (stage == 4 && v.retained) { finish(); }
      } else { receiptStatus(v); }
    }
    ignore eProductResourceObserved;
  }
  state Finished {
    ignore eView, eControlDone, eCompileView, eProductOuterDone, eProductResourceObserved,
      eCompileRecovered, eCompileReadyRefused;
  }
  fun beforeAdvance() {
    if (stage == 1 && lateRefused && beforeStored && beforeRetained) {
      stage = 2; send service, eProductExecutorCrash;
    }
  }
  fun receiptView(v: tReply) {
    if (v.request.key.execution == 1) {
      if (stage == 0 && v.row.phase == Running) { stage = 1; send helper, eFinishNative; }
      else if (stage == 3) {
        assert !v.row.receipt && !v.row.retired, "outer ACK fabricated native receipt or retirement";
        stage = 4; send service, eCompileCleanup, 1;
      } else if (stage == 5) {
        assert !v.row.receipt && !v.row.retired, "cleanup fabricated native receipt or retirement";
        stage = 6; send owner, eOwnerReceipt, request(1, 1, 1); send helper, eRetireNative;
      } else if (stage == 6 && rowSafe(v.row)) {
        stage = 7; send productOwner, eProductBegin, productService(2);
      }
    } else {
      if (stage == 7 && v.row.phase == Running) { stage = 8; send helper, eFinishNative; }
      else if (stage == 9 && rowSafe(v.row)) { stage = 10; send service, eCompileQuery, 2; }
    }
  }
  fun receiptStatus(v: tCompileView) {
    if (stage == 2) {
      assert v.acknowledged, "outer ACK not retained";
      stage = 3; send owner, eOwnerReconcile, request(1, 1, 1);
    } else if (stage == 4) {
      assert v.preparation == ResourceReleased && v.acknowledged && v.retained, "cleanup erased outer custody";
      stage = 5; send owner, eOwnerReconcile, request(1, 1, 1);
    } else if (stage == 10) {
      assert v.retained && !v.acknowledged, "native receipt fabricated outer ACK";
      stage = 11; send productOwner, eCompileAcknowledge, 2;
    } else if (stage == 11 && v.acknowledged) {
      stage = 12; send service, eProductExecutorCrash;
    } else if (stage == 13) {
      assert v.retained && v.acknowledged, "recovery erased exact outer receipt"; finish();
    }
  }
  fun finish() { announce mScenarioEnd; goto Finished; }
}

machine TestCompileFailPreparationLateReady { start state Init { entry { new CompileCustodyScenario(CompileFailLateReady); } } }
machine TestCompileReadySubmitUnassociated { start state Init { entry { new CompileCustodyScenario(CompileSubmitUnassociated); } } }
machine TestCompileTerminalPayloadPending { start state Init { entry { new CompileCustodyScenario(CompilePayloadPending); } } }
machine TestCompileIndependentReceipts { start state Init { entry { new CompileCustodyScenario(CompileIndependentReceipts); } } }

// Positive probes require independently owned actions and completed readbacks.
spec ProbeCompileFailPreparationLateReady observes mProductResourceCreated, mCompileBeforeCommitted,
  mCompileReadyRefused, mCompileRecovered, mCompileReadback, mProductReceipt {
  var created: bool; var failed: bool; var late: bool; var recovered: bool; var historical: bool;
  start state Watching {
    on mProductResourceCreated do (s: tService) { if (s.id == 1) { created = true; } }
    on mCompileBeforeCommitted do (p: tProductResult) { failed = p.provenance == BeforeNativeFailure; }
    on mCompileReadyRefused do (id: int) { late = id == 1; }
    on mCompileRecovered do (v: tCompileView) { recovered = v.retained && v.result.provenance == BeforeNativeFailure; }
    on mCompileReadback do (v: tCompileView) { historical = v.retained && v.result.provenance == BeforeNativeFailure; }
    on mProductReceipt do (p: tProductResult) {
      assert !(created && failed && late && recovered && historical && p.provenance == BeforeNativeFailure),
        "witness: original Preparing failure fenced late Ready and recovered exact acknowledged error";
    }
  }
}
spec ProbeCompileReadySubmitUnassociated observes mProductReady, mProductNativeReserved, mAdmit,
  mCompileAssociationRefused, mCompileFailureRefused, mProductNativeAssociated, mProductCompleted,
  mCommandPermitConsumed, mIntent, mStart {
  var ready: bool; var reserved: bool; var refusedRequest: bool; var admitted: bool; var pending: bool; var associated: bool;
  var permitted: bool; var intended: bool; var started: bool;
  start state Watching {
    on mProductReady do (p: tLease) { ready = p.service.id == 1; }
    on mProductNativeReserved do (p: tPreparedProduct) { reserved = p.offer.service.id == 1; }
    on mCompileAssociationRefused do (p: tPreparedProduct) { refusedRequest = reserved && !admitted; }
    on mAdmit do (p: tRequest) { if (p.key.execution == 1) { admitted = true; } }
    on mCompileFailureRefused do (v: tCompileView) { pending = ready && admitted && !v.associated && !v.retained; }
    on mProductNativeAssociated do (p: tPreparedProduct) { associated = pending; }
    on mCommandPermitConsumed do (a: tAssociationRequest) { if (a.command.prepared.native.key.execution == 1) { permitted = associated; } }
    on mIntent do (n: tNative) { if (n.key.execution == 1) { intended = permitted; } }
    on mStart do (n: tNative) { if (n.key.execution == 1) { started = intended; } }
    on mProductCompleted do (p: tProductResult) {
      assert !(refusedRequest && pending && associated && started && p.service.id == 1),
        "witness: Request-only and Ready in-flight Submit refused Before then exact native association settled";
    }
  }
}
spec ProbeCompileTerminalPayloadPending observes mNativePayloadRetained, mRecovered, mCompileTerminalPending,
  mNativeTerminalCommitted, mProductCompleted {
  var payload: bool; var recovered: bool; var refused: bool; var committed: bool;
  start state Watching {
    on mNativePayloadRetained do (p: tTerminalPayload) { payload = true; }
    on mRecovered do (p: (boot: int, rows: map[tKey, tRow])) { recovered = payload; }
    on mCompileTerminalPending do (p: tProductTerminal) { refused = recovered && !committed && p.evidence.phase == Running; }
    on mNativeTerminalCommitted do (p: tTerminalPayload) { committed = true; }
    on mProductCompleted do (p: tProductResult) {
      assert !(payload && recovered && refused && committed),
        "witness: recovered terminal payload refused before reducer commit then exact native terminal settled";
    }
  }
}
spec ProbeCompileIndependentReceipts observes mProductReceipt, mCompileReleased, mAnswer, mCompileReadback {
  var ackOne: bool; var released: bool; var independentCleanup: bool; var nativeTwo: bool;
  start state Watching {
    on mProductReceipt do (p: tProductResult) { if (p.service.id == 1) { ackOne = true; } }
    on mCompileReleased do (s: tService) { if (s.id == 1) { released = true; } }
    on mAnswer do (p: tReply) {
      if (p.answer == Prior && p.request.key.execution == 1 && ackOne && released && !p.row.receipt && !p.row.retired) { independentCleanup = true; }
      if (p.answer == Prior && p.request.key.execution == 2 && p.row.receipt && p.row.retired) { nativeTwo = true; }
    }
    on mCompileReadback do (v: tCompileView) {
      assert !(independentCleanup && nativeTwo && v.service.id == 2 && v.retained && !v.acknowledged),
        "witness: outer ACK cleanup native receipt and retirement retained independently";
    }
  }
}

module CompileCustodySystem = { Owner, Executor, Helper, ProductOwner, ProductExecutor, CompileCustodyScenario };
test tcCompileFailPreparationLateReady [main = TestCompileFailPreparationLateReady]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, DirectedProgress in (union CompileCustodySystem, { TestCompileFailPreparationLateReady });
test tcProbeCompileFailPreparationLateReady [main = TestCompileFailPreparationLateReady]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, ProbeCompileFailPreparationLateReady in (union CompileCustodySystem, { TestCompileFailPreparationLateReady });
test tcCompileReadySubmitUnassociated [main = TestCompileReadySubmitUnassociated]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, DirectedProgress in (union CompileCustodySystem, { TestCompileReadySubmitUnassociated });
test tcProbeCompileReadySubmitUnassociated [main = TestCompileReadySubmitUnassociated]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, ProbeCompileReadySubmitUnassociated in (union CompileCustodySystem, { TestCompileReadySubmitUnassociated });
test tcCompileTerminalPayloadPending [main = TestCompileTerminalPayloadPending]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, DirectedProgress in (union CompileCustodySystem, { TestCompileTerminalPayloadPending });
test tcProbeCompileTerminalPayloadPending [main = TestCompileTerminalPayloadPending]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, ProbeCompileTerminalPayloadPending in (union CompileCustodySystem, { TestCompileTerminalPayloadPending });
test tcCompileIndependentReceipts [main = TestCompileIndependentReceipts]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, DirectedProgress in (union CompileCustodySystem, { TestCompileIndependentReceipts });
test tcProbeCompileIndependentReceipts [main = TestCompileIndependentReceipts]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, ProbeCompileIndependentReceipts in (union CompileCustodySystem, { TestCompileIndependentReceipts });
