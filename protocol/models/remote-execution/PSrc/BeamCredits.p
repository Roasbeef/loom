// A transport credit is not native-effect custody. The model records only
// service asks and joined local transport runs; no DOWN proves native retirement.
enum tCreditLane { CreditData, CreditControl }
enum tCreditAction { CreditReserve, CreditHandoff, CreditAnswer, CreditDrain,
  CreditConsumerGone, CreditRunLost, CreditQuiesce, CreditFenceScope, CreditSnapshot, CreditServiceDown, CreditCreditDown, CreditOwnerDown }
enum tCreditOutcome { CreditGranted, CreditRefused, CreditStepped }
enum tCreditMode { CreditStale, CreditPending, CreditShared, CreditLost, CreditScopeFence, CreditScopePending, CreditScopeLost, CreditScopeStale, CreditScopeIdle, CreditScopeOwner }
enum tCreditScopeGate { CreditScopeActive, CreditScopeFenced }
enum tCreditDrainState { CreditBusy, CreditDrained, CreditUncertain }
type tCreditCommand = (action: tCreditAction, slot: int, run: int,
  scope: int, lane: tCreditLane);
type tCreditSlot = (run: int, scope: int, pending: bool, network: bool, retired: bool);
type tCreditView = (outcome: tCreditOutcome, slot: int, run: int,
  dataSlots: int, control: int, drain: tCreditDrainState);
type tCreditGrant = (slot: int, run: int, scope: int, lane: tCreditLane);
type tCreditAsk = (slot: int, run: int, source: int);
event eCreditCommand: tCreditCommand;
event eCreditView: tCreditView;
event mCreditGrant: tCreditGrant;
event mCreditAsk: tCreditAsk;
type tCreditCompletion = (slot: int, run: int, source: int);
type tCreditSnapshot = (scope: int, drain: tCreditDrainState);
event mCreditAnswer: tCreditCompletion;
event mCreditDrain: tCreditCompletion;
event mCreditScopeFence: int;
event mCreditScopeSnapshot: tCreditSnapshot;
event mCreditRelease: int;
event mCreditRetired: int;
event mCreditUnusable: (slot: int, run: int);
event mCreditClosed;
event mCreditStale: int;
event mCreditEnd: tCreditMode;

machine BeamCredits {
  var driver: machine;
  var slots: map[int, tCreditSlot];

  // Scope rows are fixed administrative facts for this endpoint lifetime.
  var scopes: map[int, tCreditScopeGate];
  var nextRun: int;
  var open: bool;

  start state Ready {
    entry (owner: machine) {
      var i: int;
      driver = owner; open = true; nextRun = 1;
      while (i < 16) { scopes[i + 1] = CreditScopeActive; i = i + 1; }
      i = 0;
      while (i < 6) {
        slots[i] = (run = 0, scope = 0, pending = false, network = false, retired = false);
        i = i + 1;
      }
    }
    on eCreditCommand do (p: tCreditCommand) {
      var slot: tCreditSlot;
      if (p.action == CreditReserve) { reserve(p); return; }
      if (p.action == CreditQuiesce) {
        open = false; announce mCreditClosed; view(CreditStepped, 0, 0); return;
      }
      if (p.action == CreditFenceScope || p.action == CreditOwnerDown) {
        assert p.scope in scopes, "driver fenced an unconfigured scope";
        scopes[p.scope] = CreditScopeFenced; announce mCreditScopeFence, p.scope;
        view(CreditStepped, 0, 0); return;
      }
      if (p.action == CreditSnapshot) {
        snapshot(p.scope); return;
      }
      slot = slots[p.slot];

      // A joined run may have sent a handoff whose delivery is still delayed.
      // Reuse never changes that message's reference into the next run's ref.
      if (p.action == CreditHandoff && slot.run != p.run) {
        announce mCreditStale, p.run; view(CreditStepped, p.slot, slot.run); return;
      }

      // A late answer or drain still names its original run, even after reuse.
      if ((p.action == CreditAnswer || p.action == CreditDrain) && slot.run != p.run) {
        announce mCreditStale, p.run; view(CreditStepped, p.slot, slot.run); return;
      }
      if (p.action == CreditHandoff) {
        assert !slot.pending && !slot.retired, "driver sent two current service asks";
        slot.pending = true; slots[p.slot] = slot;
        announce mCreditAsk, (slot = p.slot, run = slot.run, source = p.run);
      } else if (p.action == CreditAnswer) {
        assert slot.pending, "driver answered no current service ask";
        announce mCreditAnswer, (slot = p.slot, run = slot.run, source = p.run);
        slot.pending = false; slots[p.slot] = slot; maybeRelease(p.slot);
      } else if (p.action == CreditDrain) {
        assert slot.network, "driver drained no current run";
        announce mCreditDrain, (slot = p.slot, run = slot.run, source = p.run);
        slot.network = false; slots[p.slot] = slot; maybeRelease(p.slot);
      } else if (p.action == CreditRunLost) {
        slot.retired = true; slots[p.slot] = slot;
        announce mCreditRetired, p.run;
      } else if (p.action == CreditServiceDown) {
        // DOWN loses observation; it supplies neither answer nor producer drain.
        slot.retired = true; slots[p.slot] = slot;
        announce mCreditRetired, p.run;
      } else if (p.action == CreditCreditDown) {
        // An idle dead credit has no original scope; a busy one retains its run.
        slot.retired = true; slots[p.slot] = slot;
        if (slot.run != 0) { announce mCreditRetired, slot.run; }
        announce mCreditUnusable, (slot = p.slot, run = slot.run);
      } else if (p.action == CreditConsumerGone) {
        // Losing the caller does not answer a queued service ask or join a run.
      }
      view(CreditStepped, p.slot, slots[p.slot].run);
    }
  }

  fun reserve(p: tCreditCommand) {
    var i: int; var end: int;
    if (!open) { view(CreditRefused, 0, 0); return; }
    if (!(p.scope in scopes)) { view(CreditRefused, 0, 0); return; }
    if (scopes[p.scope] == CreditScopeFenced) { view(CreditRefused, 0, 0); return; }
    if (p.lane == CreditData) { i = 0; end = 4; }
    else { i = 4; end = 6; }
    while (i < end) {
      if (slots[i].run == 0 && !slots[i].retired) {
        slots[i] = (run = nextRun, scope = p.scope, pending = false,
          network = true, retired = false);
        announce mCreditGrant, (slot = i, run = nextRun, scope = p.scope, lane = p.lane);
        nextRun = nextRun + 1; view(CreditGranted, i, nextRun - 1); return;
      }
      i = i + 1;
    }
    view(CreditRefused, 0, 0);
  }

  fun maybeRelease(index: int) {
    if (!slots[index].network && !slots[index].pending && !slots[index].retired) {
      announce mCreditRelease, slots[index].run;
      slots[index].run = 0; slots[index].scope = 0;
    }
  }

  fun snapshot(scope: int) {
    var i: int; var drain: tCreditDrainState;
    drain = CreditBusy;
    if (scope in scopes && scopes[scope] == CreditScopeFenced) {
      drain = CreditDrained;
      while (i < 6) {
        if (slots[i].scope == scope && slots[i].retired) { drain = CreditUncertain; break; }
        if (slots[i].scope == scope && slots[i].run != 0 && !slots[i].retired) { drain = CreditBusy; }
        i = i + 1;
      }
    }
    announce mCreditScopeSnapshot, (scope = scope, drain = drain);
    viewDrain(CreditStepped, 0, 0, drain);
  }

  fun view(outcome: tCreditOutcome, index: int, run: int) {
    viewDrain(outcome, index, run, CreditBusy);
  }

  fun viewDrain(outcome: tCreditOutcome, index: int, run: int, drain: tCreditDrainState) {
    var i: int; var dataSlots: int; var control: int;
    while (i < 6) {
      if (slots[i].run == 0 && !slots[i].retired) {
        if (i < 4) { dataSlots = dataSlots + 1; } else { control = control + 1; }
      }
      i = i + 1;
    }
    send driver, eCreditView, (outcome = outcome, slot = index, run = run,
      dataSlots = dataSlots, control = control, drain = drain);
  }
}
