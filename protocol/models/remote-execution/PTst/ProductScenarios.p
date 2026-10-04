// The scenario schedules actual native work; views are forwarded only after
// the existing Owner handles them. No product actor emits a native fact.
machine ProductScenario {
  var mode: tProductMode;
  var owner: machine;
  var executor: machine;
  var helper: machine;
  var productOwner: machine;
  var productExecutor: machine;
  var stage: int;
  var outerDone: set[int];
  var nativeDone: set[int];
  var receiptRequested: set[int];
  var remaining: int;
  start state Init {
    entry (p: tProductMode) {
      mode = p;
      announce mScenarioBegin;
      executor = new Executor((driver = this, mode = Reliable));
      helper = new Helper();
      owner = new Owner((driver = this, executor = executor, mode = Reliable));
      productExecutor = new ProductExecutor((driver = this, mode = mode));
      productOwner = new ProductOwner((driver = this, service = productExecutor, nativeOwner = owner, mode = mode));
      send executor, eConnect, (owner = owner, helper = helper);
      send helper, eHelperConnect, executor;
      if (mode == ProductChildAddresses) {
        send productOwner, eProductChild, (logical = child(2, 1, 1), capacity = 4);
      } else {
        send productOwner, eProductBegin, productService(1);
      }
      goto Driving;
    }
  }
  state Driving {
    on eView do (v: tReply) {
      send productOwner, eProductView, v;
      if (v.answer == Prior && v.row.phase == Running) {
        if (v.request.key.execution == 1 && mode == ProductColdRun && stage == 0) {
          stage = 4; send productOwner, eProductCompileElapsed;
        } else if (v.request.key.execution == 1 && mode == ProductPostSendDelay && stage == 0) {
          stage = 5;
          send productOwner, eProductAdvanceTime, 120000;
          send productOwner, eProductOwnerCrash;
          send productOwner, eProductRecoverCommand, 1;
        } else if (v.request.key.execution == 2 && mode == ProductLaunchLoss && stage == 1) {
          stage = 2;
          send productOwner, eProductLoseLaunch;
        } else if (mode == ProductFaults && v.request.key.execution == 2 && stage == 1) {

          // Faults begin after the reliable compile bootstrap and actual Launch start.
          stage = 3; remaining = 12; send this, eTick;
        } else if (stage < 2 && (mode != ProductFaults || v.request.key.execution == 1)) {
          send helper, eFinishNative;
        }
      }
      if (v.answer == Prior && v.row.phase == Terminal) {
        if (!(v.request.key.execution in receiptRequested)) {
          receiptRequested += (v.request.key.execution);
          send owner, eOwnerReceipt, v.request;
          send helper, eRetireNative;
        }
        if (rowSafe(v.row)) { nativeDone += (v.request.key.execution); advance(); }
      }
    }
    on eProductRunTimeDone do { stage = 0; send helper, eFinishNative; }
    on eProductBudgetDone do {
      if (mode == ProductExpiredOffer && stage == 0) {
        stage = 6; send productOwner, eProductOwnerCrash; send productOwner, eProductRecoverCommand, 1;
      } else { finish(); }
    }
    on eProductOuterDone do (p: tProductResult) { outerDone += (p.service.id); advance(); }
    on eProductResourceObserved do (status: tResourceViewKind) {
      if (status == ResourceReplyLost) { send productExecutor, eProductResourceQuery; }
      else if (mode != ProductFaults) { finish(); }
    }
    on eProductLossDone do { if (mode != ProductFaults) { finish(); } }
    on eProductChildDone do (accepted: bool) {
      if (stage == 0) {
        assert accepted, "first capability refused"; stage = 1;
        send productOwner, eProductChild, (logical = child(2, 2, 1), capacity = 4);
      } else if (stage == 1) {
        assert accepted, "distinct capability refused"; stage = 2;
        send productOwner, eProductChild, (logical = child(3, 0, 1), capacity = 4);
      } else if (stage == 2) {
        assert accepted, "legacy child refused"; stage = 3;
        send productOwner, eProductChild,
          (logical = (tag = 2, name = 1, ordinal = 0, purpose = 2, role = 0, namespace = 1), capacity = 4);
      } else if (stage == 3) {
        assert accepted, "distinct native purpose refused"; stage = 4;
        // A separate owner gives the capacity-one subcase its own address namespace.
        productOwner = new ProductOwner((driver = this, service = productExecutor, nativeOwner = owner, mode = mode));
        send productOwner, eProductChild, (logical = child(2, 1, 2), capacity = 1);
      } else if (stage == 4) {
        assert accepted, "capacity-one first child refused"; stage = 5;
        send productOwner, eProductChild, (logical = child(2, 2, 2), capacity = 1);
      } else {
        assert !accepted, "capacity-one replaced a retained child";
        finish();
      }
    }
    on eTick do {
      var action: int;
      if (remaining == 0) { finish(); return; }
      remaining = remaining - 1; action = choose(13);
      if (action == 0) { send owner, eRetry, request(2, 1, 1); }
      else if (action == 1) { send owner, eOwnerReconcile, request(2, 1, 1); }
      else if (action == 2) { send owner, eOwnerCancel, request(2, 1, 1); }
      else if (action == 3) { send productOwner, eProductOwnerCrash; }
      else if (action == 4) { send executor, eCrash; }
      else if (action == 5) { send productExecutor, eProductExecutorCrash; }
      else if (action == 6) { send productOwner, eProductRelease; }
      else if (action == 7) { send helper, eFinishNative; }
      else if (action == 8) { send helper, eRetireNative; }
      else if (action == 9) { send helper, eDeliverCancel; }
      else if (action == 10) { send productOwner, eProductReplay; }
      else if (action == 11) { send productOwner, eProductQuery; }
      else { send productExecutor, eProductResourceQuery; }
      send this, eTick;
    }
    ignore eControlDone;
  }
  state Finished { ignore eProductBudgetDone, eProductRunTimeDone, eView, eProductOuterDone, eProductResourceObserved, eProductLossDone, eControlDone, eTick; }
  fun advance() {
    var launch: tService;
    if (stage == 0 && 1 in outerDone && 1 in nativeDone) {
      stage = 1; launch = productService(2);
      if (mode == ProductForeignAssociation) { launch.association = 1; }
      if (mode == ProductForeignArtifact) { launch.artifact = 2; }
      send productOwner, eProductBegin, launch;
    } else if (stage == 1 && 2 in outerDone && 2 in nativeDone) {
      stage = 2;
      if (mode == ProductChildOnlyRecovery) { send productOwner, eProductRecoverFinal; }
      else { finish(); }
    }
  }
  fun finish() { announce mScenarioEnd; goto Finished; }
  fun child(tag: int, name: int, namespace: int): tAddress {
    return (tag = tag, name = name, ordinal = 0, purpose = 1, role = 0, namespace = namespace);
  }
}
