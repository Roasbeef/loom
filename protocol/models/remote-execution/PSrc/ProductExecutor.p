// Resource intent removes replay permission. Only the original live claim
// creates once; a durable issued lease can be read after its reply is lost.
machine ProductExecutor {
  var owner: machine;
  var driver: machine;
  var mode: tProductMode;
  var rows: map[int, tService];
  var completed: map[int, tProductResult];
  var resourceIntent: bool;
  var liveClaim: bool;
  var created: bool;
  var issued: bool;
  var lease: tLease;
  start state Init {
    entry (p: (driver: machine, mode: tProductMode)) {
      driver = p.driver; mode = p.mode; goto Ready;
    }
  }
  state Ready {
    on eProductReserve do (p: (owner: machine, service: tService)) {
      var changed: tOffer;
      var s: tService;
      s = p.service; owner = p.owner;
      if (s.id in rows) {
        if (rows[s.id] != s) { return; }
        // Lost duplicate offers or results preserve the same retained row.
        if (mode == ProductFaults && s.id == 2 && choose()) { return; }
        if (s.id in completed) { send owner, eProductCompleted, completed[s.id]; }
        else { send owner, eProductOffer, productOffer(s); }
        return;
      }
      if (sizeof(rows) == 2) { return; }
      rows[s.id] = s;
      announce mProductAdmission, s;
      if (s.id == 1) {
        send owner, eProductOffer, productOffer(s);
        if (mode == ProductOfferConflict) {
          changed = productOffer(s); changed.commandDigest = 2;
          send owner, eProductOffer, changed;
        }
      } else {
        resourceIntent = true;
        liveClaim = true;
        announce mProductResourceIntent, s;
        createResource(s);
        if (mode == ProductResourceUnknown) {
          liveClaim = false;
          announce mProductClaimRevoked, s;
          send owner, eProductResourceView, (service = s, kind = ResourceReplyLost, lease = default(tLease));
        } else {
          if (mode == ProductOfferConflict) {
            lease = (service = s, artifact = 2, compileRequest = 1, scope = 2, resources = 2);
            acceptLease(lease);
          }
          lease = (service = s, artifact = 1, compileRequest = 1, scope = 1, resources = 1);
          acceptLease(lease);
          if (mode == ProductLeaseRecovery) {
            // Issue is durable, while the observer receives only unknown.
            send owner, eProductResourceView, (service = s, kind = ResourceReplyLost, lease = default(tLease));
          } else {
            send owner, eProductResourceView, (service = s, kind = ResourceLease, lease = lease);
            send owner, eProductOffer, productOffer(s);
          }
        }
      }
    }
    on eProductNativeTerminal do (n: tRequest) {
      var p: tProductResult;
      if (!(n.key.execution in completed)) {
        p = (service = rows[n.key.execution], resultDigest = 2, kind = n.key.execution);
        completed[n.key.execution] = p;
        announce mProductCompleted, p;
        // Compile is a reliable bootstrap; only Launch completion replies may be lost.
        if (mode != ProductFaults || n.key.execution == 1 || !choose()) { send owner, eProductCompleted, p; }
      }
    }
    on eProductReceipt do (p: tProductResult) {
      if (p.service.id in completed && completed[p.service.id] == p) {
        announce mProductReceipt, p;
        if (p.service.id == 2) { announce mProductWitness, ProductComplete; }
      }
    }
    on eProductResourceQuery do {
      if (issued) {
        announce mProductLease, lease;
        send owner, eProductResourceView, (service = rows[2], kind = ResourceLeaseRecovered, lease = lease);
      } else {
        liveClaim = false;
        if (liveClaim) { createResource(rows[2]); }
        send owner, eProductResourceView, (service = rows[2], kind = ResourceUnknown, lease = default(tLease));
      }
    }
    on eProductExecutorCrash do {
      if (resourceIntent && !issued) {
        liveClaim = false;
        announce mProductClaimRevoked, rows[2];
      }
    }
  }
  fun createResource(s: tService) {
    if (liveClaim) {
      created = true;
      announce mProductResourceCreated, s;
    }
  }
  fun acceptLease(candidate: tLease) {
    if (candidate.artifact == rows[2].artifact && candidate.scope == rows[2].scope &&
        candidate.compileRequest == rows[1].requestDigest && candidate.resources == rows[2].resources) {
      issued = true;
      lease = candidate;
      announce mProductLease, candidate;
    }
  }
}
