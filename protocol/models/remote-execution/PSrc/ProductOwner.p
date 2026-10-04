// Outer custody and native custody have independent stores and receipts.
// Only the retained, accepted offer can populate a native Prepared envelope.
machine ProductOwner {
  var driver: machine;
  var service: machine;
  var nativeOwner: machine;
  var mode: tProductMode;
  var retained: map[int, tService];
  var offers: map[int, tOffer];
  var elapsed: int;
  var notified: set[int];
  var cleared: map[int, tOffer];
  var nativeRows: map[int, tRequest];
  var completions: map[int, tProductResult];
  var children: map[tAddress, tAddress];
  var finalResult: int;
  var resourceObservation: map[int, tResourceView];
  var deferredAssociation: tProductAdmission;
  var deferredSubmit: tRequest;
  var originalClaims: map[int, tLiveClaim];
  var deferredCommand: tCommand;
  start state Init {
    entry (p: (driver: machine, service: machine, nativeOwner: machine, mode: tProductMode)) {
      driver = p.driver; service = p.service; nativeOwner = p.nativeOwner; mode = p.mode;
      goto Ready;
    }
  }
  state Ready {
    on eOriginalClaim do (c: tLiveClaim) { originalClaims[c.service.id] = c; }
    on eProductBegin do (s: tService) {
      if (!(s.id in retained)) {
        retained[s.id] = s;
        announce mProductCustody, s;
      }
      send service, eProductReserve, (owner = this, service = s);
    }
    on eProductAdvanceTime do (delta: int) {
      elapsed = elapsed + delta;
      announce mProductTime, elapsed;
    }
    on eProductCompileElapsed do {
      elapsed = elapsed + 70000;
      announce mProductTime, elapsed;
      announce mProductCompileRunElapsed, 70000;
      send driver, eProductRunTimeDone;
    }
    on eProductResourceView do (p: tResourceView) {
      if (!(p.service.id in retained) || retained[p.service.id] != p.service) { return; }
      if (p.kind == ResourceLease || p.kind == ResourceLeaseRecovered) {
        if (p.lease.service != p.service || p.lease.scope != p.service.scope ||
            p.lease.artifact != p.service.artifact || p.lease.compileRequest != p.service.compileRequest ||
            p.lease.resources != p.service.resources) { return; }
      }
      // This original-service observation survives owner crash with the request.
      resourceObservation[p.service.id] = p;
      announce mProductResourceObserved, p;
      if (p.kind == ResourceUnknown) { announce mProductWitness, ProductUnknownResource; }
      if (p.kind == ResourceLeaseRecovered) { announce mProductWitness, ProductRecoveredLease; }
      if (mode == ProductDeadResource && p.service.id == 2 && p.kind == ResourceLease) {
        send service, eProductResourceOwnerDeath;
        send service, eProductResourceQueryFor, 2;
      } else if (p.kind == ResourceLease || p.kind == ResourceLeaseRecovered) {
        send this, eProductConstruct, p.service.id;
      }
      if (p.kind != ResourceLease) { send driver, eProductResourceObserved, p.kind; }
    }
    on eProductConstruct do (id: int) {
      var o: tOffer;
      var w: int;
      if (id in offers) { return; }
      w = productWall(retained[id].deadline - elapsed, retained[id].ceiling);
      if (w < 1) {
        announce mProductWallRefused, (service = retained[id], remaining = retained[id].deadline - elapsed);
        send driver, eProductBudgetDone;
        return;
      }
      o = productOffer(retained[id]); o.wall = w;
      announce mProductWallSelected, (offer = o, remaining = retained[id].deadline - elapsed, allowance = productAllowance());
      offers[id] = o;
      announce mProductOfferRetained, o;
      if (budgetProfile(mode)) { send driver, eProductBudgetDone; return; }
      if (mode == ProductExpiredOffer && id == 1) {
        send this, eProductAdvanceTime, 120000;
      }
      send this, eProductClearOffer, id;
    }
    on eProductOffer do (o: tOffer) {
      // A foreign proposal cannot replace the owner-derived canonical offer.
      if (!(o.commandRef in offers) || offers[o.commandRef] != o) {
        announce mProductOfferRejected, o;
        announce mProductWitness, ProductConflict;
      }
    }
    on eProductClearOffer do (id: int) { clearOffer(id); }
    on eProductRecoverCommand do (id: int) {
      if (id in nativeRows) {
        queryNative(id);
        if (mode == ProductPostSendDelay) { send driver, eProductLossDone; }
      } else { clearOffer(id); }
    }
    on eProductSubmit do (accepted: tOffer) {
      var candidate: tOffer;
      var n: tRequest;
      var address: tAddress;
      address = (tag = 1, name = 0, ordinal = 0, purpose = 2, role = accepted.commandRef, namespace = 1);
      announce mProductChildCandidate, (logical = address, address = address);
      if (!(address in children) && sizeof(children) < 4) {
        children[address] = address;
        announce mProductChildReserved, (logical = address, address = address);
      }
      candidate = accepted;
      candidate.commandDigest = accepted.commandDigest;
      n = request(accepted.commandRef, 1, 1);
      n.digest = candidate.commandDigest;
      nativeRows[accepted.commandRef] = n;
      announce mProductNativeReserved, (offer = candidate, native = n);
      if (mode == ProductColdRun && accepted.commandRef == 1) {
        elapsed = elapsed + 6000;
        announce mProductTime, elapsed;
        announce mProductControlComplete, (offer = candidate, native = n);
      }
      deferredCommand = (prepared = (offer = candidate, native = n), claim = originalClaims[accepted.commandRef], resource = service);
      if (mode == CompileSubmitUnassociated) {
        deferredSubmit = n;
        // A canonical Request/Prepared without a native row is not admission.
        send service, eProductNativeAdmission, (prepared = (offer = candidate, native = n), evidence = default(tReply));
      } else { send nativeOwner, ePrepareCommand, deferredCommand; }
    }
    on eProductView do (v: tReply) {
      var foreign: tRequest;
      // Matching retained native evidence, rather than clearance, admits the
      // physical service's association. The original Owner owns these facts.
      if (v.answer == Prior && v.request.key.execution in nativeRows &&
          nativeRows[v.request.key.execution] == v.request) {
        if (!(v.request.key.execution in notified)) {
          notified += (v.request.key.execution);
          deferredAssociation = (prepared = (offer = offers[v.request.key.execution], native = v.request), evidence = v);
          // Native Executor owns association before launch; views carry history only.
        }
        // This directed boundary input uses the existing changed-digest class.
        // FIFO from this sender places it after association and before the
        // genuine terminal, so the control must exercise the real refusal.
        if (mode == ProductForeignNativeTerminal && v.request.key.execution == 1 && v.row.phase == Running) {
          foreign = v.request; foreign.digest = 2;
          send service, eProductNativeTerminal, terminalRead(foreign, v.row);
        }
        if (v.row.phase == Terminal) { send service, eProductNativeTerminal, terminalRead(v.request, v.row); }
      }
    }
    on eProductCompleted do (p: tProductResult) {
      if (!(p.service.id in retained) || retained[p.service.id] != p.service || p.kind != p.service.id) { return; }
      if (!(p.service.id in completions)) {
        completions[p.service.id] = p;
        announce mProductOwnerStored, p;
        if (mode != CompileIndependentReceipts && mode != CompileFailLateReady) { send service, eProductReceipt, p; }
        if (p.service.id == 2 && mode != ProductChildOnlyRecovery) {
          finalResult = 1;
          announce mProductFinalStored, finalResult;
        }
        send driver, eProductOuterDone, p;
      }
    }
    on eCompileContinueSubmit do { send nativeOwner, ePrepareCommand, deferredCommand; }
    on eCompileReleaseAssociation do { send service, eLiveReleaseAssociation; }
    on eCompileAcknowledge do (id: int) {
      if (id in completions) { send service, eProductReceipt, completions[id]; }
    }
    on eProductLoseLaunch do {
      announce mProductLaunchObservation, (native = nativeRows[2].key, neverLaunched = false);
      announce mProductWitness, ProductUnknownLaunch;
      send this, eProductQuery;
      send this, eProductRelease;
    }
    on eProductQuery do { if (2 in nativeRows) { queryNative(2); } }
    on eProductRelease do {
      if (2 in nativeRows) {
        // Resource custody ends independently of the still-running Helper.
        announce mProductCleanupObservation, (native = nativeRows[2].key, retired = false);
      }
      send driver, eProductLossDone;
    }
    on eProductRecoverFinal do {
      if (finalResult != 0) {
        announce mProductFinalRecovered, finalResult;
      } else {
        announce mProductWitness, ProductUnknownFinal;
      }
      send driver, eProductLossDone;
    }
    on eProductChild do (p: (logical: tAddress, capacity: int)) {
      var address: tAddress;
      address = p.logical;
      address.name = p.logical.name;
      announce mProductChildCandidate, (logical = p.logical, address = address);
      if (address in children) {
        send driver, eProductChildDone, children[address] == p.logical;
      } else if (sizeof(children) < p.capacity) {
        children[address] = p.logical;
        announce mProductChildReserved, (logical = p.logical, address = address);
        send driver, eProductChildDone, true;
      } else {
        send driver, eProductChildDone, false;
      }
    }
    on eProductReplay do {
      if (2 in nativeRows) { queryNative(2); }
      else { send service, eProductReserve, (owner = this, service = retained[2]); }
    }
    on eProductOwnerCrash do {
      // The abstract atomic stores survive. Recovery does not rerun a tool.
      send nativeOwner, eOwnerCrash;
    }
  }
  fun terminalRead(n: tRequest, row: tRow): tProductTerminal {
    return (native = n, evidence = row,
      payload = (request = n, native = (key = n.key, boot = row.launchBoot),
        digest = row.terminalDigest, outcome = row.outcome));
  }
  fun clearOffer(id: int) {
    var o: tOffer;
    if (!(id in offers)) { return; }
    if (id in nativeRows) { queryNative(id); return; }
    if (id in cleared) { return; }
    o = offers[id];
    announce mProductClearanceAttempt, (offer = o, remaining = retained[id].deadline - elapsed, allowance = productAllowance());
    if (o.wall * 1000 + 1100 + productAllowance() > retained[id].deadline - elapsed) {
      announce mProductClearanceRefused, o;
      send driver, eProductBudgetDone;
      return;
    }
    cleared[id] = o;
    announce mProductCleared, o;
    announce mProductWitness, ProductClearedPending;
    send this, eProductSubmit, o;
  }
  fun queryNative(id: int) {
    var original: tRequest;
    original = nativeRows[id];
    original.key.execution = nativeRows[id].key.execution;
    announce mProductNativeReserved, (offer = cleared[id], native = original);
    announce mProductNativeQuery, (offer = offers[id], native = original);
    send nativeOwner, eOwnerReconcile, original;
  }
}
