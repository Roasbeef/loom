// These independent histories check readiness, immutable time authority and
// actual native association. Actor flags cannot establish their own evidence.
spec PreparationSafety observes mProductCustody, mProductCompleted, mProductResourceIntent,
  mProductReady, mProductResourceObserved, mProductAssociationChecked,
  mProductFingerprintChecked, mProductResourceOwnerDead, mProductLeaseUsable,
  mProductWallSelected, mProductWallRefused, mProductOfferRetained, mProductTime,
  mProductClearanceAttempt, mProductCleared, mProductNativeReserved, mAdmit, mStart,
  mProductNativeAssociated, mProductTerminalAssociated, mProductNativeQuery,
  mOriginalClaim, mLiveClaimRevoked, mCommandPending, mCommandPermitIssued,
  mCommandPermitConsumed, mCommandControlForwarded, mCommandNativeRecovered, mIntent, mCommandReplyLost {
  var custody: map[int, tService];
  var completed: map[int, tProductResult];
  var intents: set[int];
  var ready: map[int, tLease];
  var observed: set[int];
  var artifactAssociated: set[int];
  var fingerprint: set[int];
  var dead: set[int];
  var selected: map[int, tOffer];
  var offers: map[int, tOffer];
  var cleared: set[int];
  var native: map[int, tPreparedProduct];
  var admitted: map[tKey, tRequest];
  var associated: map[int, tPreparedProduct];
  var remainingAtClear: map[int, int];
  var elapsed: int;
  var liveClaims: map[int, tLiveClaim];
  var pendingCommands: map[tKey, tAssociationRequest];
  var issuedPermits: map[tKey, tAssociationRequest];
  var consumedPermits: map[tKey, tAssociationRequest];
  var nativeBoot: int;
  var lostReplies: set[tKey];
  start state Watching {
    entry { nativeBoot = 1; }
    on mOriginalClaim do (c: tLiveClaim) {
      assert !(c.service.id in liveClaims), "original live Claim was recreated";
      liveClaims[c.service.id] = c;
    }
    on mLiveClaimRevoked do (c: tLiveClaim) { liveClaims -= (c.service.id); }
    on mCommandPending do (a: tAssociationRequest) {
      assert a.command.prepared.native.key in admitted && admitted[a.command.prepared.native.key] == a.command.prepared.native,
        "command continuation preceded actual native Admit";
      pendingCommands[a.command.prepared.native.key] = a;
    }
    on mCommandReplyLost do (a: tAssociationRequest) { lostReplies += (a.command.prepared.native.key); }
    on mCommandNativeRecovered do (boot: int) { nativeBoot = boot; }
    on mCommandPermitIssued do (a: tAssociationRequest) {
      var id: int;
      id = a.command.prepared.offer.service.id;
      assert id in liveClaims && liveClaims[id] == a.command.claim &&
        a.command.prepared.offer.commandRef in associated && associated[a.command.prepared.offer.commandRef] == a.command.prepared &&
        !(a.command.prepared.native.key in issuedPermits), "permit lacked unique original live Claim and exact committed association";
      issuedPermits[a.command.prepared.native.key] = a;
      liveClaims -= (id);
    }
    on mCommandPermitConsumed do (a: tAssociationRequest) {
      assert a.command.prepared.native.key in issuedPermits && issuedPermits[a.command.prepared.native.key] == a &&
        a.command.prepared.native.key in pendingCommands && pendingCommands[a.command.prepared.native.key] == a &&
        a.boot == nativeBoot && !(a.command.prepared.native.key in consumedPermits) && !(a.command.prepared.native.key in lostReplies),
        "native launch consumed absent stale or duplicate original permit";
      consumedPermits[a.command.prepared.native.key] = a;
    }
    on mCommandControlForwarded do (c: tCommandControl) {
      assert c.command.prepared.offer.commandRef in associated && associated[c.command.prepared.offer.commandRef] == c.command.prepared &&
        c.wire.request == c.command.prepared.native, "command control lacked exact retained association";
    }
    on mIntent do (n: tNative) {
      if (n.key.execution in native) {
        assert n.key in consumedPermits && consumedPermits[n.key].boot == n.boot &&
          consumedPermits[n.key].command.prepared.offer.commandRef in associated &&
          associated[consumedPermits[n.key].command.prepared.offer.commandRef] == consumedPermits[n.key].command.prepared,
          "command Intent preceded exact association and original live permit";
      }
    }
    on mProductCustody do (s: tService) {
      if (s.id in custody) { assert custody[s.id] == s, "original service input changed"; }
      custody[s.id] = s;
    }
    on mProductCompleted do (p: tProductResult) { completed[p.service.id] = p; }
    on mProductResourceIntent do (s: tService) {
      assert !(s.id in intents), "preparation claim was renewed";
      if (s.id == 2) { assert s.id in artifactAssociated, "launch preparation lacked compile association"; }
      intents += (s.id);
    }
    on mProductAssociationChecked do (p: (service: tService, producer: tProductResult)) {
      assert 1 in completed && p.producer == completed[1] && p.service.association == p.producer.resultDigest && p.service.artifact == p.producer.artifact &&
        p.service.compileRequest == p.producer.service.requestDigest && p.service.scope == p.producer.service.scope &&
        p.service.enrollment == p.producer.service.enrollment && p.service.tokenCommitment == 1,
        "launch ready changed retained compile or launch input";
      artifactAssociated += (p.service.id);
    }
    on mProductReady do (p: tLease) {
      assert p.service.id in intents, "ready preceded preparation intent";
      if (p.service.id in ready) { assert ready[p.service.id] == p, "ready evidence changed"; }
      ready[p.service.id] = p;
    }
    on mProductResourceObserved do (p: tResourceView) {
      if (p.kind == ResourceLease || p.kind == ResourceLeaseRecovered) {
        assert p.service.id in ready && ready[p.service.id] == p.lease, "usable lease preceded durable ready";
        observed += (p.service.id);
      }
    }
    on mProductResourceOwnerDead do (s: tService) { dead += (s.id); }
    on mProductLeaseUsable do (p: tLease) {
      assert !(p.service.id in dead), "dead resource owner restored launch authority";
    }
    on mProductFingerprintChecked do (p: (service: tService, fingerprint: int)) {
      assert p.fingerprint == p.service.artifact, "launch fingerprint mismatch admitted";
      fingerprint += (p.service.id);
    }
    on mStart do (n: tNative) {
      if (n.key.execution == 2) { assert 2 in fingerprint, "native launch preceded fingerprint verification"; }
      assert n.key.execution in native && native[n.key.execution].offer.wall * 1000 + 1100 <=
        custody[n.key.execution].deadline - elapsed, "native start exceeded original remaining authority";
    }
    on mProductTime do (now: int) {
      assert now >= elapsed, "original elapsed authority moved backwards";
      elapsed = now;
    }
    on mProductWallSelected do (p: (offer: tOffer, remaining: int, allowance: int)) {
      var allowed: int;
      assert p.offer.service.id in observed, "wall selected before resource ready";
      assert p.offer.deadline == custody[p.offer.service.id].deadline &&
        p.remaining == custody[p.offer.service.id].deadline - elapsed,
        "retained offer or original deadline changed";
      assert p.allowance == 48000 && p.offer.wall > 0 && p.offer.wall <= custody[p.offer.service.id].ceiling &&
        p.offer.wall * 1000 + 1100 + p.allowance <= p.remaining,
        "selected wall exceeded original remaining authority";
      allowed = (p.remaining - 1100 - p.allowance) / 1000;
      if (allowed > custody[p.offer.service.id].ceiling) { allowed = custody[p.offer.service.id].ceiling; }
      assert p.offer.wall == allowed, "selected wall did not use exact floor and ceiling";
      if (p.offer.commandRef in selected) {
        assert selected[p.offer.commandRef] == p.offer, "retained offer or original deadline changed";
      }
      selected[p.offer.commandRef] = p.offer;
    }
    on mProductWallRefused do (p: (service: tService, remaining: int)) {
      assert p.remaining == custody[p.service.id].deadline - elapsed && p.remaining < 50100,
        "wall refusal did not follow original remaining authority";
    }
    on mProductOfferRetained do (o: tOffer) {
      assert o.commandRef in selected && selected[o.commandRef] == o, "retained offer or original deadline changed";
      if (o.commandRef in offers) { assert offers[o.commandRef] == o, "retained offer or original deadline changed"; }
      offers[o.commandRef] = o;
    }
    on mProductClearanceAttempt do (p: (offer: tOffer, remaining: int, allowance: int)) {
      assert !(p.offer.commandRef in native), "native custody authorized a second clearance";
      assert p.offer.commandRef in offers && offers[p.offer.commandRef] == p.offer &&
        p.remaining == custody[p.offer.service.id].deadline - elapsed,
        "retained offer or original deadline changed";
      remainingAtClear[p.offer.commandRef] = p.remaining;
    }
    on mProductCleared do (o: tOffer) {
      assert !(o.commandRef in native) && !(o.commandRef in cleared), "native custody authorized a second clearance";
      assert o.commandRef in offers && offers[o.commandRef] == o, "clearance preceded exact offer retention";
      assert o.wall * 1000 + 49100 <= remainingAtClear[o.commandRef], "expired offer reached clearance";
      cleared += (o.commandRef);
    }
    on mProductNativeReserved do (p: tPreparedProduct) {
      if (!(p.offer.commandRef in native)) { native[p.offer.commandRef] = p; }
    }
    on mAdmit do (n: tRequest) { admitted[n.key] = n; }
    on mProductNativeAssociated do (p: tPreparedProduct) {
      assert p.native.key in admitted && admitted[p.native.key] == p.native &&
        p.offer.commandRef in native && native[p.offer.commandRef] == p,
        "service admission lacked actual native evidence";
      assert p.offer.service.id in liveClaims && liveClaims[p.offer.service.id].service == p.offer.service &&
        !(p.offer.commandRef in associated), "fresh association lacked original live Claim";
      associated[p.offer.commandRef] = p;
    }
    on mProductTerminalAssociated do (p: tPreparedProduct) {
      assert p.offer.commandRef in associated && associated[p.offer.commandRef] == p,
        "outer completion used a different native child";
    }
    on mProductNativeQuery do (p: tPreparedProduct) {
      assert p.offer.commandRef in native && native[p.offer.commandRef] == p && offers[p.offer.commandRef] == p.offer,
        "retained offer or original deadline changed";
    }
  }
}
