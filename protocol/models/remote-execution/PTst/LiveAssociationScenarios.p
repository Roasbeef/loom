// The driver delays actual association/permit answers. It never supplies Admit,
// association, Intent or helper facts; those belong to the shared real actors.
enum tLiveCase { LiveOrderCase, LiveLossCase, LiveClaimCase, LiveControlCase }
machine LiveAssociationScenario {
  var kind: tLiveCase;
  var owner: machine;
  var executor: machine;
  var helper: machine;
  var service: machine;
  var productOwner: machine;
  var stage: int;
  var association: tAssociationRequest;
  var first: tAssociationRequest;
  var before: bool;
  var stale: bool;
  var refused: bool;
  var recovered: bool;
  var queried: bool;
  var hostile: int;
  var outerOne: bool;
  var nativeOne: bool;
  start state Init {
    entry (k: tLiveCase) {
      kind = k; announce mScenarioBegin;
      executor = new Executor((driver = this, mode = Reliable));
      helper = new Helper(); owner = new Owner((driver = this, executor = executor, mode = Reliable));
      service = new ProductExecutor((driver = this, mode = ProductLiveAssociation));
      productOwner = new ProductOwner((driver = this, service = service, nativeOwner = owner, mode = ProductLiveAssociation));
      send executor, eConnect, (owner = owner, helper = helper);
      send helper, eHelperConnect, executor;
      send productOwner, eProductBegin, productService(1);
      before = choose(); stale = choose(); goto Driving;
    }
  }
  state Driving {
    on eLiveAssociationView do (a: tAssociationRequest) {
      association = a;
      if (kind == LiveOrderCase && before) {
        stage = 1; send service, eCompileCleanup, 1; send service, eLiveReleaseAssociation;
      } else if (kind == LiveClaimCase && stage == 0) {
        stage = 1;
        a.command.claim.incarnation = 2;
        send service, eAssociateForeignClaim, a;
      } else { stage = 2; send service, eLiveReleaseAssociation; }
    }
    on eLiveAssociationRefused do (a: tAssociationRequest) {
      var changed: tLiveClaim;
      var cmd: tCommand;
      if (kind == LiveClaimCase && stage == 1) {
        assert a.command.claim != association.command.claim, "changed Claim input never reached association";
        if (hostile == 0) {
          hostile = 1; a = association; changed = a.command.claim; changed.issuer = owner;
          cmd = a.command; cmd.claim = changed; a.command = cmd;
          send service, eAssociateForeignClaim, a;
        } else { stage = 2; send service, eLiveReleaseAssociation; }
      } else if (kind == LiveOrderCase && before) {
        refused = true;
        send owner, eRetry, association.command.prepared.native;
      } else if (kind == LiveLossCase) { refused = true; lossDone(); }
    }
    on eLivePermitView do (a: tAssociationRequest) {
      assert a == association, "association permit changed original continuation";
      if (kind == LiveLossCase) {
        stage = 3;
        if (stale) { send executor, eCrash; }
        else { send executor, eLoseCommandReply, a; }
      } else if (kind == LiveClaimCase) {
        stage = 3;
        // Duplicate association reaches the real resource handler before launch.
        send service, eAssociateForeignClaim, association;
        send service, eLiveReleasePermit;
      } else {
        stage = 3;
        if (kind == LiveOrderCase) { send service, eCompileCleanup, 1; }
        send service, eLiveReleasePermit;
      }
    }
    on eControlDone do {
      if (kind == LiveLossCase && stage == 3) {
        if (stale) { send service, eLiveReleasePermit; }
        else { loseReply(); }
      }
    }
    on eLivePermitRefused do (a: tAssociationRequest) {
      assert kind == LiveLossCase && stale, "original live permit unexpectedly refused";
      loseReply();
    }
    on eCompileRecovered do { recovered = true; lossDone(); }
    on eCompileView do (v: tCompileView) {
      if (kind == LiveOrderCase && before) {
        assert !v.associated && !v.retained && v.preparation == ResourceReleased, "fence-before association retained a native association";
      }
    }
    on eLiveControlAnswer do (p: (control: tCommandControl, forwarded: bool)) {
      if (kind == LiveOrderCase && before) {
        assert !p.forwarded, "unassociated duplicate escaped control guard"; finish();
      } else if (kind == LiveControlCase && stage == 8) {
        assert !p.forwarded, "foreign command control escaped association guard";
        hostile = hostile + 1;
        if (hostile < 4) { foreignControl(); }
        else { stage = 9; send owner, eOwnerReconcile, association.command.prepared.native; }
      }
    }
    on eView do (v: tReply) {
      send productOwner, eProductView, v;
      if (v.answer != Prior) { return; }
      if (kind == LiveLossCase && stage == 4 && v.row.phase == Admitted) {
        queried = true; lossDone();
      } else if (v.row.phase == Running && stage == 3) {
        if (kind == LiveOrderCase) { stage = 5; send owner, eOwnerCancel, v.request; }
        else if (kind == LiveControlCase && v.request.key.execution == 2) {
          stage = 8; hostile = 0; foreignControl();
        } else { stage = 6; send helper, eFinishNative; }
      } else if (kind == LiveOrderCase && stage == 5 && v.row.phase == Running) {
        stage = 6; send helper, eDeliverCancel; send helper, eFinishNative;
      } else if (kind == LiveControlCase && stage == 9 && v.row.phase == Running) {
        assert v.request == association.command.prepared.native && !v.row.receipt && !v.row.retired,
          "refused foreign controls changed genuine native row";
        stage = 6; send helper, eFinishNative;
      } else if (kind == LiveControlCase && v.request.key.execution == 1 && v.row.phase == Terminal) {
        if (stage == 6) { stage = 7; send owner, eOwnerReceipt, v.request; send helper, eRetireNative; }
        else if (stage == 7 && rowSafe(v.row)) { nativeOne = true; second(); }
      }
    }
    on eProductOuterDone do (p: tProductResult) {
      if (kind != LiveControlCase || p.service.id == 2) { finish(); }
      else { outerOne = true; second(); }
    }
    ignore eProductResourceObserved;
  }
  state Finished {
    ignore eView, eControlDone, eCompileView, eProductOuterDone, eProductResourceObserved,
      eLiveAssociationRefused, eLiveControlAnswer, eCompileRecovered;
  }
  fun second() {
    // Both actual outer completion and native retirement precede slot reuse.
    if (nativeOne && outerOne && stage == 7) { stage = 10; first = association; send productOwner, eProductBegin, productService(2); }
  }
  fun loseReply() {
    stage = 4;
    send service, eProductExecutorCrash;
    send service, eAssociateForeignClaim, association;
    send owner, eRetry, association.command.prepared.native;
  }
  fun lossDone() { if (refused && recovered && queried) { finish(); } }
  fun foreignControl() {
    var c: tCommandControl;
    var cmd: tCommand;
    var prepared: tPreparedProduct;
    var native: tRequest;
    var offer: tOffer;
    var original: tService;
    cmd = association.command;
    prepared = cmd.prepared;
    offer = prepared.offer;
    original = offer.service;
    native = prepared.native;
    c = (command = cmd, wire = association.wire, operation = CommandQuery);
    // Rebuild each parent value after a child edit. Nested field writes in P
    // can alias a saved tuple, which would corrupt the genuine comparison input.
    if (hostile == 0) {
      cmd = first.command; prepared = cmd.prepared;
      prepared.native = native; cmd.prepared = prepared; c.command = cmd;
      c.operation = CommandCancel;
    } else if (hostile == 1) {
      native.digest = 2; prepared.native = native; cmd.prepared = prepared;
      c.command = cmd; c.wire = (owner = association.wire.owner, request = native, connection = association.wire.connection);
      c.operation = CommandReceipt;
    } else {
      if (hostile == 2) { original.requestDigest = 2; c.operation = CommandStdin; }
      else { original.scope = 2; }
      offer.service = original; prepared.offer = offer; cmd.prepared = prepared; c.command = cmd;
    }
    send service, eCommandControl, c;
  }
  fun finish() { announce mScenarioEnd; goto Finished; }
}

machine TestLiveAssociationOrder { start state Init { entry { new LiveAssociationScenario(LiveOrderCase); } } }
machine TestLiveAssociationLoss { start state Init { entry { new LiveAssociationScenario(LiveLossCase); } } }
machine TestLiveAssociationClaim { start state Init { entry { new LiveAssociationScenario(LiveClaimCase); } } }
machine TestLiveAssociationControls { start state Init { entry { new LiveAssociationScenario(LiveControlCase); } } }
module LiveAssociationSystem = { Owner, Executor, Helper, ProductOwner, ProductExecutor, LiveAssociationScenario };
test tcLiveAssociationOrder [main = TestLiveAssociationOrder]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, DirectedProgress in (union LiveAssociationSystem, { TestLiveAssociationOrder });
test tcLiveAssociationLoss [main = TestLiveAssociationLoss]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, DirectedProgress in (union LiveAssociationSystem, { TestLiveAssociationLoss });
test tcLiveAssociationClaim [main = TestLiveAssociationClaim]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, DirectedProgress in (union LiveAssociationSystem, { TestLiveAssociationClaim });
test tcLiveAssociationControls [main = TestLiveAssociationControls]: assert AdmissionSafety, LaunchSafety, ReceiptSafety, CancelSafety, ProductSafety, PreparationSafety, CompileCustodySafety, DirectedProgress in (union LiveAssociationSystem, { TestLiveAssociationControls });
