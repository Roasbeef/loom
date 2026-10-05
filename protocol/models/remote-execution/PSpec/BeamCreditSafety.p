// This monitor remembers facts independently of the implementation's booleans.
spec BeamCreditSafety observes mCreditGrant, mCreditAsk, mCreditAnswer,
  mCreditDrain, mCreditRelease, mCreditRetired, mCreditClosed {
  var current: map[int, int];
  var lanes: map[int, tCreditLane];
  var asked: set[int]; var answered: set[int];
  var drained: set[int]; var retired: set[int];
  var closed: bool; var dataSlots: int; var control: int;
  start state Watching {
    on mCreditGrant do (p: tCreditGrant) {
      assert !closed, "credit granted after ingress closed";
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
    on mCreditAnswer do (run: int) { answered += (run); }
    on mCreditDrain do (run: int) { drained += (run); }
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
      if (mode == CreditLost) { assert false, "witness: lost run remained retired after actual answer and drain"; }
    }
  }
}
