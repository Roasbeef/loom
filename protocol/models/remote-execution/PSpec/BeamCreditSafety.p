// This monitor remembers facts independently of the implementation's booleans.
spec BeamCreditSafety observes mCreditGrant, mCreditAsk, mCreditAnswer,
  mCreditDrain, mCreditRelease, mCreditRetired, mCreditClosed,
  mCreditScopeFence, mCreditScopeSnapshot, mCreditUnusable {
  var current: map[int, int];
  var lanes: map[int, tCreditLane];
  var scopeOf: map[int, int]; var fenced: set[int]; var unusable: set[int];
  var asked: set[int]; var answered: set[int];
  var drained: set[int]; var retired: set[int];
  var closed: bool; var dataSlots: int; var control: int;
  start state Watching {
    on mCreditGrant do (p: tCreditGrant) {
      assert !closed, "credit granted after ingress closed";
      assert p.scope >= 1 && p.scope <= 16, "credit granted outside fixed scope table";
      assert !(p.scope in fenced), "credit granted after its scope fence";
      assert !(p.slot in unusable), "dead idle or busy credit was reminted";
      scopeOf[p.run] = p.scope;
      assert !(p.slot in current), "credit reused while original custody remained";
      current[p.slot] = p.run; lanes[p.run] = p.lane;
      if (p.lane == CreditData) { dataSlots = dataSlots + 1; }
      else { control = control + 1; }
      assert dataSlots <= 4 && control <= 2, "scope multiplied the shared credit bound";
    }
    on mCreditAsk do (p: tCreditAsk) {
      assert p.slot in current && current[p.slot] == p.run && p.source == p.run,
        "stale handoff admitted against a reused credit";
      assert !(p.run in asked), "same credit admitted a second service ask";
      asked += (p.run);
    }
    on mCreditAnswer do (p: tCreditCompletion) {
      assert p.slot in current && current[p.slot] == p.run && p.run == p.source,
        "stale completion changed current assignment";
      answered += (p.run);
    }
    on mCreditDrain do (p: tCreditCompletion) {
      assert p.slot in current && current[p.slot] == p.run && p.run == p.source,
        "stale completion changed current assignment";
      drained += (p.run);
    }
    on mCreditScopeFence do (scope: int) { fenced += (scope); }
    on mCreditScopeSnapshot do (p: tCreditSnapshot) {
      var entries: seq[int]; var i: int;
      if (p.drain != CreditDrained) { return; }
      assert p.scope in fenced, "scope reported drained before its fence";
      entries = keys(scopeOf);
      while (i < sizeof(entries)) {
        assert scopeOf[entries[i]] != p.scope || !(entries[i] in retired),
          "scope reported drained after retired credit";
        i = i + 1;
      }
      entries = keys(current); i = 0;
      while (i < sizeof(entries)) {
        assert scopeOf[current[entries[i]]] != p.scope,
          "scope reported drained before original run discharge";
        i = i + 1;
      }
    }
    on mCreditUnusable do (p: (slot: int, run: int)) {
      if (p.run == 0) {
        assert !(p.slot in current), "idle credit death discarded original assignment";
      } else {
        assert p.slot in current && current[p.slot] == p.run && p.run in retired,
          "busy credit death forgot original uncertainty";
      }
      unusable += (p.slot);
    }
    on mCreditRetired do (run: int) { retired += (run); }
    on mCreditClosed do { closed = true; }
    on mCreditRelease do (run: int) {
      var entries: seq[int]; var i: int;
      assert run in drained, "credit released before transport AllDelivered";
      assert !(run in asked) || run in answered, "queued service ask released without actual answer";
      assert !(run in retired), "lost run restored retired credit";
      entries = keys(current);
      while (i < sizeof(entries)) {
        if (current[entries[i]] == run) { current -= (entries[i]); }
        i = i + 1;
      }
      if (lanes[run] == CreditData) { dataSlots = dataSlots - 1; }
      else { control = control - 1; }
    }
  }
}

// Directed scenarios assert their real replies before announcing completion.
// Probe cases invert that final witness to make dead or refused paths visible.
spec BeamCreditReachability observes mCreditEnd {
  start state Watching {
    on mCreditEnd do (mode: tCreditMode) {
      if (mode == CreditStale) { assert false, "witness: stale handoff refused after same credit reuse and current work completed"; }
      if (mode == CreditPending) { assert false, "witness: caller loss and drain retained service ask until its actual answer"; }
      if (mode == CreditShared) { assert false, "witness: two scopes shared four data and two control credits and closure refused admission"; }
      if (mode == CreditScopeFence) { assert false, "witness: scoped fence refused original traffic while sibling progressed and late handoff stayed stale"; }
      if (mode == CreditScopePending) { assert false, "witness: scoped drain stayed busy until actual answer and original producer drain"; }
      if (mode == CreditScopeLost) { assert false, "witness: service DOWN and later answer drain retained scoped uncertainty while sibling drained"; }
      if (mode == CreditScopeStale) { assert false, "witness: stale answer and drain preserved reused sibling assignment before exact completion"; }
      if (mode == CreditScopeIdle) { assert false, "witness: idle credit death reduced capacity without scope obligation and busy death retained original uncertainty"; }
      if (mode == CreditScopeOwner) { assert false, "witness: applied owner DOWN fenced idle and busy rows while prior assignment stayed uncertain and sibling progressed"; }
      if (mode == CreditLost) { assert false, "witness: lost run remained retired after actual answer and drain"; }
    }
  }
}
