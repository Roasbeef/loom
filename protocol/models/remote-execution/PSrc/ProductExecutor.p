// Each service reserves once, commits Preparing, creates on its live claim,
// then commits Ready in a separate turn. Recovered preparation grants no claim.
machine ProductExecutor {
  var owner: machine;
  var driver: machine;
  var mode: tProductMode;
  var rows: map[int, tService];
  var completed: map[int, tProductResult];
  var phases: map[int, tPreparation];
  var claims: set[int];
  var liveClaims: map[int, tLiveClaim];
  var incarnation: int;
  var created: set[int];
  var leases: map[int, tLease];
  var resourceOwnerAlive: bool;
  var associated: map[int, tPreparedProduct];
  var outerReceipts: set[int];
  var deferredLiveAssociation: tAssociationRequest;
  var deferredLivePermit: tAssociationRequest;
  start state Init {
    entry (p: (driver: machine, mode: tProductMode)) {
      driver = p.driver; mode = p.mode; resourceOwnerAlive = true; incarnation = 1; goto Ready;
    }
  }
  state Ready {
    on eProductReserve do (p: (owner: machine, service: tService)) {
      var s: tService;
      s = p.service; owner = p.owner;
      if (s.id in rows) {
        if (rows[s.id] != s) { return; }
        // Exact replay returns history; it cannot bypass resource liveness.
        if (mode == ProductFaults && s.id == 2 && choose()) { return; }
        if (s.id in completed) { send owner, eProductCompleted, completed[s.id]; }
        else { queryResource(s.id); }
        return;
      }
      if (sizeof(rows) == 2) { return; }
      rows[s.id] = s; phases[s.id] = Reserved;
      announce mProductAdmission, s;
      if (s.id == 2) {
        if (!(1 in completed) || !acceptAssociation(s, completed[1])) {
          announce mProductAssociationRefused, s;
          send owner, eProductResourceView, (service = s, kind = ResourceUnknown, lease = default(tLease));
          return;
        }
        announce mProductAssociationChecked, (service = s, producer = completed[1]);
      }
      // The irreversible intent commits before the first creation message.
      phases[s.id] = Preparing; claims += (s.id);
      announce mProductResourceIntent, s;
      liveClaims[s.id] = (issuer = this, service = s, incarnation = incarnation);
      announce mOriginalClaim, liveClaims[s.id];
      send owner, eOriginalClaim, liveClaims[s.id];
      send this, eProductCreate, s.id;
    }
    on eProductCreate do (id: int) {
      if (id in claims && phases[id] == Preparing) {
        createResource(rows[id]);
        if ((id == 2 && mode == ProductResourceUnknown) || (id == 1 && mode == ProductCompileUnknown)) {
          send this, eProductExecutorCrash;
        } else if (mode == CompileFailLateReady) { send driver, eCompileCreated, id; }
        else { send this, eProductCommitReady, id; }
      }
    }
    on eProductCommitReady do (id: int) {
      var candidate: tLease;
      if (!(id in claims) || phases[id] != Preparing || !(id in created)) {
        if (compileControl(mode)) {
          announce mCompileReadyRefused, id; send driver, eCompileReadyRefused, id;
        }
        return;
      }
      if (mode == ProductOfferConflict && id == 2) {
        candidate = (service = rows[id], artifact = 2, compileRequest = 1, scope = 2, resources = 2);
        acceptLease(candidate);
      }
      candidate = (service = rows[id], artifact = rows[id].artifact, compileRequest = rows[id].compileRequest,
        scope = rows[id].scope, resources = rows[id].resources);
      acceptLease(candidate);
      phases[id] = PreparedResource; claims -= (id);
      announce mProductReady, leases[id];
      send owner, eProductAdvanceTime, preparationElapsed(mode, id);
      // Fingerprint checking is distinct from the retained artifact association.
      // It occurs before any native start, without an offer-confirmation exchange.
      send this, eProductFingerprint, id;
    }
    on eProductFingerprint do (id: int) {
      var changed: tOffer;
      var fingerprint: int;
      fingerprint = 1;
      if (id == 2 && mode == ProductBadFingerprint) { fingerprint = 2; }
      if (id == 2 && fingerprint != rows[id].artifact) {
        phases[id] = ResourceUncertain;
        announce mProductFingerprintRefused, rows[id];
        send owner, eProductResourceView, (service = rows[id], kind = ResourceUnknown, lease = default(tLease));
        return;
      }
      if (id == 2) { announce mProductFingerprintChecked, (service = rows[id], fingerprint = fingerprint); }
      if ((id == 2 && mode == ProductLeaseRecovery) || (id == 1 && mode == ProductCompileLeaseRecovery)) {
        send owner, eProductResourceView, (service = rows[id], kind = ResourceReplyLost, lease = default(tLease));
      } else { publishReady(id, ResourceLease); }
      if (mode == ProductOfferConflict && id == 1) {
        changed = productOffer(rows[id]); changed.commandDigest = 2;
        send owner, eProductOffer, changed;
      }
    }
    on eProductNativeAdmission do (read: tProductAdmission) {
      announce mCompileAssociationRefused, read.prepared;
      if (compileControl(mode)) { send driver, eCompileAssociationRefused, read.prepared; }
    }
    on eAssociateCommand do (a: tAssociationRequest) {
      if (mode == CompileSubmitUnassociated || mode == ProductLiveAssociation) {
        deferredLiveAssociation = a;
        if (mode == ProductLiveAssociation) { send driver, eLiveAssociationView, a; }
        return;
      }
      associateLive(a);
    }
    on eAssociateForeignClaim do (a: tAssociationRequest) { associateLive(a); }
    on eLiveReleaseAssociation do { associateLive(deferredLiveAssociation); }
    on eLiveReleasePermit do { if (deferredLivePermit.boot > 0) { send deferredLivePermit.executor, eCommandPermit, deferredLivePermit; } }
    on eCommandControl do (c: tCommandControl) {
      control(c);
    }
    on eProductNativeTerminal do (read: tProductTerminal) {
      var n: tRequest;
      var p: tProductResult;
      var candidate: tPreparedProduct;
      n = read.native;
      if (!(n.key.execution in associated)) { return; }
      candidate = associated[n.key.execution];
      candidate.native = n;
      if (candidate.native != associated[n.key.execution].native) {
        announce mProductTerminalRefused, n;
        return;
      }
      announce mProductTerminalAssociated, candidate;
      if (read.payload.request != n || read.evidence.request != n) { return; }
      if (read.evidence.phase != Terminal || read.evidence.terminalDigest != read.payload.digest) {
        if (compileControl(mode)) {
          announce mCompileTerminalPending, read; send driver, eCompileView, compileView(n.key.execution);
        }
        return;
      }
      announce mCompileNativeSettled, read;
      if (!(n.key.execution in completed)) {
        p = (service = rows[n.key.execution], resultDigest = 2, kind = n.key.execution, artifact = 1, provenance = NativeCompletion);
        completed[n.key.execution] = p;
        announce mProductCompleted, p;
        if (mode != ProductFaults || n.key.execution == 1 || !choose()) { send owner, eProductCompleted, p; }
      }
    }
    on eProductReceipt do (p: tProductResult) {
      if (p.service.id in completed && completed[p.service.id] == p) {
        outerReceipts += (p.service.id);
        announce mProductReceipt, p;
        if (mode == CompileIndependentReceipts || mode == CompileFailLateReady) { send driver, eCompileView, compileView(p.service.id); }
        if (p.service.id == 2) { announce mProductWitness, ProductComplete; }
      }
    }
    on eCompileFailPreparation do (p: tProductResult) {
      var id: int;
      id = p.service.id;
      if (!(id in rows) || rows[id] != p.service || id != 1 || p != compileBefore(rows[id])) { return; }
      // Exact historical retry never consults volatile claims or a native endpoint.
      if (id in completed) {
        if (completed[id] == p) { send driver, eCompileView, compileView(id); }
        return;
      }
      if (phases[id] != Preparing || !(id in claims) || id in leases || id in associated) {
        announce mCompileFailureRefused, compileView(id); send driver, eCompileView, compileView(id);
        return;
      }
      // One durable transaction retains failure and fences every queued late Ready.
      completed[id] = p; phases[id] = ResourceUncertain; claims -= (id);
      revokeLive(id);
      announce mCompileBeforeCommitted, p;
      announce mProductClaimRevoked, rows[id];
      send owner, eProductCompleted, p;
      send driver, eCompileView, compileView(id);
    }
    on eCompileQuery do (id: int) {
      announce mCompileReadback, compileView(id); send driver, eCompileView, compileView(id);
    }
    on eCompileCleanup do (id: int) {
      if (id in rows) { phases[id] = ResourceReleased; claims -= (id); revokeLive(id); announce mCompileReleased, rows[id]; }
      send driver, eCompileView, compileView(id);
    }
    on eProductResourceQuery do {
      if (mode == ProductCompileUnknown || mode == ProductCompileLeaseRecovery) { queryResource(1); }
      else { queryResource(2); }
    }
    on eProductResourceQueryFor do (id: int) { queryResource(id); }
    on eProductExecutorCrash do {
      var id: int;
      incarnation = 2;
      deferredLiveAssociation = default(tAssociationRequest);
      deferredLivePermit = default(tAssociationRequest);
      revokeLive(1); revokeLive(2);
      id = 1;
      while (id <= 2) {
        if (id in phases && phases[id] == Preparing) {
          revoke(id);
          if (mode == ProductResourceUnknown || mode == ProductCompileUnknown) {
            send owner, eProductResourceView, (service = rows[id], kind = ResourceReplyLost, lease = default(tLease));
          }
        }
        id = id + 1;
      }
      if (compileControl(mode) || mode == ProductLiveAssociation) { announce mCompileRecovered, compileView(1); send driver, eCompileRecovered; }
    }
    on eProductResourceOwnerDeath do {
      resourceOwnerAlive = false;
      revokeLive(1); revokeLive(2);
      if (2 in rows) {
        if (phases[2] == PreparedResource) { phases[2] = ResourceReleased; }
        announce mProductResourceOwnerDead, rows[2];
      }
    }
  }
  fun associateLive(a: tAssociationRequest) {
    var id: int;
    id = a.command.prepared.offer.service.id;

    // Only the original live claim can commit a fresh native association.
    // A matching retained row or duplicate is historical data, never a permit.
    if (!(id in rows) || rows[id] != a.command.prepared.offer.service ||
        phases[id] != PreparedResource || !(id in leases) || id in completed ||
        !(id in liveClaims) || liveClaims[id] != a.command.claim ||
        a.command.resource != this || id in associated ||
        a.evidence.answer != Prior || a.evidence.request != a.command.prepared.native ||
        a.evidence.row.request != a.command.prepared.native || a.evidence.row.phase != Admitted) {
      announce mCommandAssociationRefused, a;
      if (mode == ProductLiveAssociation) { send driver, eLiveAssociationRefused, a; }
      if (!(id in associated)) { send a.executor, eCommandAssociationRefused, a; }
      return;
    }

    // The immutable association commits before its original permit is issued.
    associated[id] = a.command.prepared;
    announce mProductNativeAssociated, a.command.prepared;
    liveClaims -= (id);
    announce mCommandPermitIssued, a;
    if (mode == ProductLiveAssociation) {
      deferredLivePermit = a;
      send driver, eLivePermitView, a;
    } else { send a.executor, eCommandPermit, a; }
  }
  fun control(c: tCommandControl) {
    var id: int;
    id = c.command.prepared.offer.service.id;
    if (id in associated && associated[id] == c.command.prepared &&
        c.command.resource == this && c.wire.request == c.command.prepared.native) {
      announce mCommandControlForwarded, c;
      if (mode == ProductLiveAssociation) { send driver, eLiveControlAnswer, (control = c, forwarded = true); }
      send c.wire.owner, eAssociatedControl, c;
    } else {
      announce mCommandControlRefused, c;
      if (mode == ProductLiveAssociation) { send driver, eLiveControlAnswer, (control = c, forwarded = false); }
      send c.wire.owner, eCommandControlRefused, c;
    }
  }
  fun compileView(id: int): tCompileView {
    var v: tCompileView;
    v = (service = rows[id], retained = false, result = default(tProductResult),
      acknowledged = id in outerReceipts, associated = id in associated, preparation = phases[id]);
    if (id in completed) { v.retained = true; v.result = completed[id]; }
    return v;
  }
  fun acceptAssociation(s: tService, producer: tProductResult): bool {
    return producer.provenance == NativeCompletion && s.association == producer.resultDigest && s.artifact == producer.artifact && s.compileRequest == producer.service.requestDigest &&
      s.scope == producer.service.scope && s.enrollment == producer.service.enrollment &&
      s.tokenCommitment == 1;
  }
  fun createResource(s: tService) {
    if (s.id in claims) {
      created += (s.id);
      announce mProductResourceCreated, s;
    }
  }
  fun revokeLive(id: int) {
    if (id in liveClaims) { announce mLiveClaimRevoked, liveClaims[id]; liveClaims -= (id); }
  }
  fun revoke(id: int) {
    revokeLive(id);
    claims -= (id); phases[id] = ResourceUncertain;
    announce mProductClaimRevoked, rows[id];
  }
  fun acceptLease(candidate: tLease) {
    if (candidate.artifact == rows[candidate.service.id].artifact && candidate.scope == rows[candidate.service.id].scope &&
        candidate.compileRequest == rows[1].requestDigest && candidate.resources == rows[candidate.service.id].resources) {
      leases[candidate.service.id] = candidate;
      announce mProductLease, candidate;
    }
  }
  fun publishReady(id: int, kind: tResourceViewKind) {
    announce mProductLeaseUsable, leases[id];
    send owner, eProductResourceView, (service = rows[id], kind = kind, lease = leases[id]);
  }
  fun queryResource(id: int) {
    if (!(id in rows)) { return; }
    if (id in leases && (id == 1 || resourceOwnerAlive) && phases[id] == PreparedResource) {
      announce mProductLease, leases[id];
      publishReady(id, ResourceLeaseRecovered);
    } else {
      claims -= (id);
      if (id in claims) { createResource(rows[id]); }
      send owner, eProductResourceView, (service = rows[id], kind = ResourceUnknown, lease = default(tLease));
    }
  }
}
