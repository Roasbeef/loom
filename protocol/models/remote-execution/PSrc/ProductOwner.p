// Outer custody and native custody have independent stores and receipts.
// Only the retained, accepted offer can populate a native Prepared envelope.
machine ProductOwner {
  var driver: machine;
  var service: machine;
  var nativeOwner: machine;
  var mode: tProductMode;
  var retained: map[int, tService];
  var cleared: map[int, tOffer];
  var nativeRows: map[int, tRequest];
  var completions: map[int, tProductResult];
  var children: map[tAddress, tAddress];
  var finalResult: int;
  var resourceObservation: map[int, tResourceView];
  start state Init {
    entry (p: (driver: machine, service: machine, nativeOwner: machine, mode: tProductMode)) {
      driver = p.driver; service = p.service; nativeOwner = p.nativeOwner; mode = p.mode;
      goto Ready;
    }
  }
  state Ready {
    on eProductBegin do (s: tService) {
      if (!(s.id in retained)) {
        retained[s.id] = s;
        announce mProductCustody, s;
      }
      send service, eProductReserve, (owner = this, service = s);
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
      if (p.kind != ResourceLease) { send driver, eProductResourceObserved, p.kind; }
    }
    on eProductOffer do (o: tOffer) {
      if (!(o.service.id in retained) || retained[o.service.id] != o.service ||
          o != productOffer(retained[o.service.id]) ||
          (o.commandRef in cleared && cleared[o.commandRef] != o) ||
          (o.commandRef == 2 && (!(2 in resourceObservation) ||
            (resourceObservation[2].kind != ResourceLease && resourceObservation[2].kind != ResourceLeaseRecovered)))) {
        announce mProductOfferRejected, o;
        announce mProductWitness, ProductConflict;
        return;
      }
      if (!(o.commandRef in cleared)) {
        cleared[o.commandRef] = o;
        announce mProductCleared, o;
        announce mProductWitness, ProductClearedPending;
        // Submission is another turn: clearance alone grants no native fact.
        send this, eProductSubmit, o;
      }
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
      send nativeOwner, ePrepare, n;
    }
    on eProductView do (v: tReply) {
      // The existing Owner commits the native terminal before this view.
      if (v.answer == Prior && v.row.phase == Terminal) {
        send service, eProductNativeTerminal, v.request;
      }
    }
    on eProductCompleted do (p: tProductResult) {
      if (!(p.service.id in retained) || retained[p.service.id] != p.service || p.kind != p.service.id) { return; }
      if (!(p.service.id in completions)) {
        completions[p.service.id] = p;
        announce mProductOwnerStored, p;
        send service, eProductReceipt, p;
        if (p.service.id == 2 && mode != ProductChildOnlyRecovery) {
          finalResult = 1;
          announce mProductFinalStored, finalResult;
        }
        send driver, eProductOuterDone, p;
      }
    }
    on eProductLoseLaunch do {
      announce mProductLaunchObservation, (native = nativeRows[2].key, neverLaunched = false);
      announce mProductWitness, ProductUnknownLaunch;
      send this, eProductQuery;
      send this, eProductRelease;
    }
    on eProductQuery do {
      var original: tRequest;
      if (2 in nativeRows) {
        original = nativeRows[2];
        original.key.execution = nativeRows[2].key.execution;
        announce mProductNativeReserved, (offer = cleared[2], native = original);
        send nativeOwner, eOwnerReconcile, original;
      }
    }
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
      send service, eProductReserve, (owner = this, service = retained[2]);
    }
    on eProductOwnerCrash do {
      // The abstract atomic stores survive. Recovery does not rerun a tool.
      send nativeOwner, eOwnerCrash;
    }
  }
}
