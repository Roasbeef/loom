// Histories are recorded before effects. Native facts come from the unchanged
// actors, rather than a scenario stage or a copied product row flag.
spec ProductSafety observes mProductCustody, mProductAdmission, mProductCleared,
  mProductNativeReserved, mCustody, mAdmit, mStart, mIntent, mOwnerStored,
  mRetired, mProductChildCandidate, mProductResourceIntent, mProductResourceCreated,
  mProductClaimRevoked, mProductLease, mProductResourceObserved, mProductCompleted, mProductOwnerStored,
  mProductReceipt, mProductFinalStored, mProductFinalRecovered,
  mProductLaunchObservation, mProductCleanupObservation {
  var custody: map[int, tService];
  var cleared: map[int, tOffer];
  var native: map[int, tRequest];
  var nativeStored: set[tKey];
  var retired: set[tKey];
  var possible: set[tKey];
  var children: map[tAddress, tAddress];
  var resourceIntents: set[int];
  var created: set[int];
  var revoked: set[int];
  var issued: map[int, tLease];
  var completed: map[int, tProductResult];
  var stored: map[int, tProductResult];
  var finalStored: int;
  start state Watching {
    on mProductCustody do (s: tService) { custody[s.id] = s; }
    on mProductAdmission do (s: tService) {
      assert s.id in custody && custody[s.id] == s, "product admission lacked retained owner request";
    }
    on mProductCleared do (o: tOffer) { cleared[o.commandRef] = o; }
    on mProductNativeReserved do (p: tPreparedProduct) {
      assert p.offer.commandRef in cleared && cleared[p.offer.commandRef] == p.offer &&
        p.native.digest == cleared[p.offer.commandRef].commandDigest,
        "native command differed from owner-cleared offer";
      if (p.offer.commandRef in native) {
        assert native[p.offer.commandRef] == p.native,
          "uncertain command allocated replacement identity";
      } else { native[p.offer.commandRef] = p.native; }
    }
    on mCustody do (n: tRequest) { checkNative(n); possible += (n.key); }
    on mAdmit do (n: tRequest) { checkNative(n); }
    on mIntent do (n: tNative) { possible += (n.key); }
    on mStart do (n: tNative) { possible += (n.key); }
    on mOwnerStored do (n: tRequest) { nativeStored += (n.key); }
    on mRetired do (n: tKey) { retired += (n); }
    on mProductChildCandidate do (p: tChildCandidate) {
      if (p.address in children) {
        assert children[p.address] == p.logical, "distinct product children shared an address";
      } else { children[p.address] = p.logical; }
    }
    on mProductResourceIntent do (s: tService) { resourceIntents += (s.id); }
    on mProductClaimRevoked do (s: tService) { revoked += (s.id); }
    on mProductResourceCreated do (s: tService) {
      assert s.id in resourceIntents && !(s.id in created) && !(s.id in revoked),
        "resource created without original live claim";
      created += (s.id);
    }
    on mProductLease do (p: tLease) {
      assert p.service.id in custody && p.service.id in created && p.service == custody[p.service.id] &&
        p.artifact == custody[p.service.id].artifact && p.scope == custody[p.service.id].scope &&
        p.compileRequest == custody[1].requestDigest && p.compileRequest == custody[p.service.id].compileRequest &&
        p.resources == custody[p.service.id].resources,
        "issued resource did not match admitted artifact";
      if (p.service.id in issued) {
        assert issued[p.service.id] == p, "issued resource did not match admitted artifact";
      } else { issued[p.service.id] = p; }
    }
    on mProductResourceObserved do (p: tResourceView) {
      assert p.service == custody[p.service.id], "resource observation changed original service";
      if (p.kind == ResourceLease || p.kind == ResourceLeaseRecovered) {
        assert p.service.id in issued && issued[p.service.id] == p.lease,
          "issued resource did not match admitted artifact";
      }
    }
    on mProductCompleted do (p: tProductResult) {
      assert p.service == custody[p.service.id] && p.kind == p.service.id, "outer completion changed service type or identity";
      assert native[p.service.id].key in nativeStored, "outer completion preceded native owner storage";
      completed[p.service.id] = p;
    }
    on mProductOwnerStored do (p: tProductResult) {
      assert p.service.id in completed && completed[p.service.id] == p,
        "owner retained changed outer completion";
      stored[p.service.id] = p;
    }
    on mProductReceipt do (p: tProductResult) {
      assert p.service.id in stored && stored[p.service.id] == p,
        "outer receipt preceded exact owner completion";
    }
    on mProductFinalStored do (p: int) { finalStored = p; }
    on mProductFinalRecovered do (p: int) {
      assert finalStored != 0 && p == finalStored, "child evidence fabricated final tool outcome";
    }
    on mProductLaunchObservation do (p: (native: tKey, neverLaunched: bool)) {
      assert !p.neverLaunched || !(p.native in possible), "possible native launch reported never launched";
    }
    on mProductCleanupObservation do (p: (native: tKey, retired: bool)) {
      assert !p.retired || p.native in retired, "resource cleanup fabricated native retirement";
    }
  }
  fun checkNative(n: tRequest) {
    assert n.key.execution in native && native[n.key.execution] == n,
      "native command differed from owner-cleared offer";
  }
}
