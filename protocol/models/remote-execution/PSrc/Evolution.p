// Governed evolution on a remote workspace (protocol-change/098, proposed).
//
// The code does not exist yet, so the names below are the proposal's. Three
// machines stand for the parts whose interleavings carry risk:
//
//   EvolutionPlane  the host's `evolution` plane on the executor: the
//                   generations and prepared transitions that `EvolutionStage`,
//                   `EvolutionPrepare`, `EvolutionPublish`, `EvolutionAbort` and
//                   `EvolutionRetire` act on, filed under the scope's custody.
//   Catalogue       the orchestrator's authority: the durable selection, the
//                   receipt of a catalogue compare-and-set. It also supervises
//                   the session's opens.
//   LiveOwner       the live owner and its `machine.remote` stubs: one process
//                   per open (or per runtime inside an open), which stages the
//                   selection, drives a stateful migration as a two-phase
//                   transaction, and retires superseded generations.
//
// `EvolutionRun` is not modelled. It is admitted in the execution ledger by
// key exactly as `Run` is, with the tool column `evolution:<name>`, so the
// `Host` machine already checks it (README.md, "The evolution path"). The
// ledger's token and incarnation rules are restated here for the messages that
// are not ledgered, because the plane applies them itself.
//
// One session, one candidate, two generations. Generation 1 is staged from the
// selection. A migration moves the session to generation 2 in three steps:
// prepare a successor on the executor, compare-and-set the selection on the
// orchestrator, publish the successor on the executor. The catalogue is the
// authority: the executor must never serve generation 2 before the selection
// names it.

// A generation's phase on the executor. A serving generation answers tool
// runs. A prepared successor holds the migrated state and answers none. A
// retiring generation was superseded by a publish and waits for its retire.
enum tInstPhase { IP_SERVING, IP_PREPARED, IP_RETIRING }

// A prepared transition's phase, kept by the predecessor's handle.
enum tTrPhase { TR_PREPARED, TR_PUBLISHED, TR_ABORTED }

// The evolution operations the plane acts on, for the spec that checks what a
// message carried when it acted.
enum tOp { OP_STAGE, OP_PREPARE, OP_PUBLISH, OP_ABORT, OP_RETIRE }

// The result of the catalogue's compare-and-set as the live owner hears it.
// CAS_UNKNOWN is a commit whose reply was lost: the owner learns the truth from
// the durable receipt.
enum tCas { CAS_COMMITTED, CAS_REJECTED, CAS_UNKNOWN }

// The durable receipt of the compare-and-set, as `evolution/store` keeps it: the
// request's signature and the selection, written in the same transaction as the
// selection. It holds no handle and no published phase, because executor handles
// do not survive a VM restart. A live owner whose reply was lost reads it to
// learn whether the compare-and-set committed. A new open never uses it to
// finish a migration: it stages the selection.
enum tRPhase { R_NONE, R_COMMITTED }

type tInst = (gen: int, inc: int, phase: tInstPhase);
type tTrans = (target: int, succ: int, phase: tTrPhase);
type tReceipt = tRPhase;

// What an open reads from the catalogue when it starts.
type tCatalogueView = (selection: int, attemptsLeft: int);

// --- announcements the evolution specs observe ------------------------------

// A generation started on the executor, or ended (retired, aborted, or lost
// with the VM).
event eInstStarted: (handle: int, gen: int, inc: int);
event eInstEnded: int;

// The scope attached at an incarnation and token, was closed, or the VM
// restarted and emptied the plane.
event eScopeAttached: (inc: int, token: int);
event eScopeClosed: int;
event eVmCrashed;

// The plane is about to stage, prepare, publish or abort, with what the
// message carried and what the scope held.
event eActed: (op: tOp, handle: int, msgInc: int, msgToken: int, scopeInc: int, scopeToken: int);

// A migration was applied (a publish moved state), and a transition was
// published or aborted.
event eMigrated: (handle: int, target: int);
event eTrPublished: (handle: int, succ: int);
event eTrAborted: (handle: int, succ: int);

// The generation the executor serves changed (0 for none).
event eServedNow: int;

// The executor's slot after a change: the generations that serve and the
// prepared successors that do not.
event eSlot: (serving: int, prepared: int);

// The catalogue's durable selection.
event eSelected: int;

// The live owner saw a retirement confirmed, and the catalogue dropped a
// cleanup obligation.
event eRetireSeen: int;
event eObligationDropped: int;

// Witnesses for the probes.
event eStageJoined: bool;
event ePublishJoined: bool;
event ePrepareJoined: int;
event eAbortRefused: int;
event eStaleRefused: tOp;
event ePrepareReplaced: int;
event eAbortStale: int;
event eSuperseded: int;
event eStaleGeneration: int;
event eRecoveryStage: int;
event eCasReconciled: tRPhase;
event eCleanupUnconfirmed: int;

// --- the catalogue and its owners talk on one node --------------------------

event eOwnerAttached: int;
event eAttemptBegin: int;
event eCasRequest: (gen: int, handle: int, succ: int);
event eCasReply: (gen: int, result: tCas);
event eReceiptRead: int;
event eAfterSend: (gen: int, kind: tKind);
event eReceiptIs: (gen: int, receipt: tReceipt);

// The environment closes the session's scope and opens it again at the next
// incarnation.
event eReopen;

fun inSeq(xs: seq[int], x: int): bool {
  var v: int;
  foreach (v in xs) {
    if (v == x) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// The executor's evolution plane.
// ---------------------------------------------------------------------------

// The scope (`scopeInc`, `scopeToken`, `scopeOpen`) is durable, as the ledger's
// scope row is, and so is the handle counter, so a handle is never reused. The
// plane itself (`placed`, `insts`, `trans`) is the VM's memory: a crash empties
// it, and no scope has a plane again until the next attach (README.md, "The
// host and the ledger": nothing re-attaches inside an open).
//
// Every message that acts on a scope carries the incarnation and the token and
// is admitted only when both equal the scope's. `EvolutionRetire` carries no
// token in the proposal, only the incarnation.
machine EvolutionPlane {
  var wire: machine;
  var cleanupFaults: int;
  var scopeInc: int;
  var scopeToken: int;
  var scopeOpen: bool;
  var nextHandle: int;
  var placed: bool;
  var insts: map[int, tInst];
  var trans: map[int, tTrans];

  start state Up {
    entry (p: (wire: machine, cleanupFaults: int)) {
      wire = p.wire;
      cleanupFaults = p.cleanupFaults;
    }

    on eNet do (m: tMsg) {
      if (m.kind == K_ATTACH) {
        attach(m);
      } else if (m.kind == K_E_CLOSE) {
        close(m);
      } else if (m.kind == K_E_STAGE) {
        stage(m);
      } else if (m.kind == K_E_PREPARE) {
        prepare(m);
      } else if (m.kind == K_E_PUBLISH) {
        publish(m);
      } else if (m.kind == K_E_ABORT) {
        abort(m);
      } else if (m.kind == K_E_RETIRE) {
        retire(m);
      }
    }

    // The plane holds no waiters: an evolution request is answered or lost.
    ignore eNoConn;

    on eCrash do {
      restart();
    }
  }

  // --- admission ------------------------------------------------------------

  // The scope checks of `remote/host`: a plane must exist in this VM, the scope
  // must be open at the message's incarnation, and the attach token must be the
  // scope's by value.
  fun admit(m: tMsg, op: tOp, needToken: bool): tVerdict {
    if (!placed) {
      return V_NOPLANE;
    }
    if (m.inc != scopeInc || !scopeOpen) {
      announce eStaleRefused, op;
      return V_STALE;
    }
    if (needToken && m.token != scopeToken) {
      announce eStaleRefused, op;
      return V_STALE;
    }
    return V_OK;
  }

  fun acted(m: tMsg, op: tOp) {
    announce eActed, (op = op, handle = m.handle, msgInc = m.inc, msgToken = m.token, scopeInc = scopeInc, scopeToken = scopeToken);
  }

  // --- scope ----------------------------------------------------------------

  // host.attach: the token replaces the scope's, and a higher incarnation
  // retires every generation of the one before (the custody of `Evolution` in
  // `executor_plane`). An attach at the same incarnation adopts what is there.
  fun attach(m: tMsg) {
    if (m.inc < scopeInc) {
      reply(m, K_ATTACHED, V_STALE, 0, 0);
      return;
    }
    if (m.inc > scopeInc) {
      retireAll();
      scopeInc = m.inc;
    }
    scopeToken = m.token;
    scopeOpen = true;
    placed = true;
    announce eScopeAttached, (inc = scopeInc, token = scopeToken);
    changed();
    reply(m, K_ATTACHED, V_OK, 0, 0);
  }

  // host.close: the scope's custody is released, so every generation goes. A
  // close for an incarnation the scope has left is stale and does nothing.
  fun close(m: tMsg) {
    if (m.inc != scopeInc || !scopeOpen) {
      return;
    }
    retireAll();
    scopeOpen = false;
    announce eScopeClosed, scopeInc;
    changed();
  }

  // The VM restarted: generations and prepared transitions are gone with it.
  fun restart() {
    retireAll();
    placed = false;
    announce eVmCrashed;
    changed();
  }

  fun retireAll() {
    var hs: seq[int];
    var h: int;
    hs = keys(insts);
    foreach (h in hs) {
      endInst(h);
    }
    trans = default(map[int, tTrans]);
  }

  // --- stage ----------------------------------------------------------------

  // EvolutionStage for the catalogue's current selection. A stage for a
  // generation older than a live one is refused (`StaleGeneration`). A session has one
  // executable slot, and the plane keeps that rule. A serving generation of
  // exactly this generation answers its handle, so a re-send and a stage from a
  // restarted runtime join it. Otherwise the stage aborts any prepared
  // successor of this generation, which does not serve and is never joined,
  // starts the generation, and reports every older generation still live
  // (serving, or superseded by a publish and not yet retired) so the owner
  // retires it. An older serving generation stops serving here.
  fun stage(m: tMsg) {
    var v: tVerdict;
    var h: int;
    var older: seq[int];
    v = admit(m, OP_STAGE, true);
    if (v != V_OK) {
      reply(m, K_E_STAGED, v, 0, 0);
      return;
    }
    if (newerThan(m.gen)) {
      announce eStaleGeneration, m.gen;
      reply(m, K_E_STAGED, V_STALE_GENERATION, 0, 0);
      return;
    }
    h = findServing(m.gen);
    if (h != 0) {
      announce eStageJoined, m.resent;
      replyStaged(m, h, olderThan(m.gen));
      return;
    }
    acted(m, OP_STAGE);
    abortPreparedFor(m.gen);
    older = olderThan(m.gen);
    demote(older);
    if (sizeof(older) > 0) {
      announce eSuperseded, sizeof(older);
    }
    h = startInst(m.gen, IP_SERVING);
    changed();
    replyStaged(m, h, older);
  }

  // --- the two-phase migration ----------------------------------------------

  // EvolutionTransition, step Prepare. On a serving handle it replaces any
  // unpublished transition and prepares a fresh successor from the handle's
  // current state; it never joins an earlier one, whose state may be older than
  // the predecessor's. A handle that is not serving is refused.
  fun prepare(m: tMsg) {
    var v: tVerdict;
    var s: int;
    v = admit(m, OP_PREPARE, true);
    if (v != V_OK) {
      reply(m, K_E_PREPARED, v, 0, 0);
      return;
    }
    if (!(m.handle in insts) || insts[m.handle].phase != IP_SERVING) {
      reply(m, K_E_PREPARED, V_UNKNOWN_HANDLE, 0, 0);
      return;
    }
    acted(m, OP_PREPARE);
    if (m.handle in trans && trans[m.handle].phase == TR_PREPARED) {
      announce ePrepareReplaced, trans[m.handle].succ;
      dropSuccessor(m.handle);
    }
    s = startInst(m.gen, IP_PREPARED);
    trans[m.handle] = (target = m.gen, succ = s, phase = TR_PREPARED);
    changed();
    reply(m, K_E_PREPARED, V_OK, m.handle, s);
  }

  // EvolutionTransition, step Publish, which names its successor. Idempotent: a second publish of a published transition
  // answers the same receipt and migrates nothing. A publish of an aborted
  // transition, or of one the plane does not hold, is refused.
  fun publish(m: tMsg) {
    var v: tVerdict;
    var tr: tTrans;
    v = admit(m, OP_PUBLISH, true);
    if (v != V_OK) {
      reply(m, K_E_PUBLISHED, v, 0, 0);
      return;
    }
    if (!(m.handle in trans) || trans[m.handle].succ != m.succ) {
      reply(m, K_E_PUBLISHED, V_UNKNOWN_HANDLE, 0, 0);
      return;
    }
    tr = trans[m.handle];
    if (tr.phase == TR_ABORTED) {
      reply(m, K_E_PUBLISHED, V_UNKNOWN_HANDLE, 0, 0);
      return;
    }
    if (tr.phase == TR_PREPARED) {
      applyPublish(m, tr);
    } else {
      announce ePublishJoined, m.resent;
    }
    reply(m, K_E_PUBLISHED, V_OK, m.handle, m.succ);
  }

  // The migration is applied once, here: the successor serves and the
  // predecessor waits for its retire.
  fun applyPublish(m: tMsg, tr: tTrans) {
    var pi: tInst;
    var si: tInst;
    acted(m, OP_PUBLISH);
    announce eMigrated, (handle = m.handle, target = tr.target);
    if (tr.succ in insts) {
      si = insts[tr.succ];
      si.phase = IP_SERVING;
      insts[tr.succ] = si;
    }
    if (m.handle in insts) {
      pi = insts[m.handle];
      pi.phase = IP_RETIRING;
      insts[m.handle] = pi;
    }
    tr.phase = TR_PUBLISHED;
    trans[m.handle] = tr;
    announce eTrPublished, (handle = m.handle, succ = tr.succ);
    changed();
  }

  // EvolutionTransition, step Abort, which names its successor. A transition
  // the plane does not hold, or holds with another successor, has nothing to
  // compensate. An abort of a published transition is refused with
  // `AlreadyPublished`. No honest sender reaches that refusal, since an abort
  // names a successor that a later prepare never reuses; it stays as the guard.
  fun abort(m: tMsg) {
    var v: tVerdict;
    var tr: tTrans;
    v = admit(m, OP_ABORT, true);
    if (v != V_OK) {
      reply(m, K_E_ABORTED, v, 0, 0);
      return;
    }
    if (!(m.handle in trans) || trans[m.handle].succ != m.succ) {
      announce eAbortStale, m.handle;
      reply(m, K_E_ABORTED, V_OK, 0, 0);
      return;
    }
    tr = trans[m.handle];
    if (tr.phase == TR_PUBLISHED) {
      announce eAbortRefused, m.handle;
      reply(m, K_E_ABORTED, V_ALREADY_PUBLISHED, 0, 0);
      return;
    }
    if (tr.phase != TR_ABORTED) {
      acted(m, OP_ABORT);
      announce eTrAborted, (handle = m.handle, succ = tr.succ);
      if (tr.succ in insts) {
        endInst(tr.succ);
      }
      tr.phase = TR_ABORTED;
      trans[m.handle] = tr;
      changed();
    }
    reply(m, K_E_ABORTED, V_OK, 0, 0);
  }

  // --- retire ---------------------------------------------------------------

  // EvolutionRetire stops a generation and answers `AllRetired` or
  // `UnknownCleanup`, the verdict a scope close gives. It is admitted like the
  // rest, so a dead runtime's retire is refused. A plane that is gone, or a
  // handle the plane does not hold, has nothing left to stop. An unconfirmed
  // retirement leaves the generation in place, so a second retire can finish it.
  fun retire(m: tMsg) {
    var v: tVerdict;
    if (!placed) {
      reply(m, K_E_RETIRED, V_ALL_RETIRED, m.handle, 0);
      return;
    }
    v = admit(m, OP_RETIRE, true);
    if (v != V_OK) {
      reply(m, K_E_RETIRED, v, m.handle, 0);
      return;
    }
    if (m.handle in insts) {
      if (cleanupFaults > 0 && $) {
        cleanupFaults = cleanupFaults - 1;
        announce eCleanupUnconfirmed, m.handle;
        reply(m, K_E_RETIRED, V_UNKNOWN_CLEANUP, m.handle, 0);
        return;
      }
      acted(m, OP_RETIRE);
      endInst(m.handle);
      changed();
    }
    reply(m, K_E_RETIRED, V_ALL_RETIRED, m.handle, 0);
  }

  // --- generations ----------------------------------------------------------

  // The serving generation of exactly this generation number, or 0.
  fun findServing(gen: int): int {
    var hs: seq[int];
    var h: int;
    hs = keys(insts);
    foreach (h in hs) {
      if (insts[h].gen == gen && insts[h].phase == IP_SERVING) {
        return h;
      }
    }
    return 0;
  }

  // A live generation of this number in any phase, a prepared successor
  // included, or 0.
  fun findGen(gen: int): int {
    var hs: seq[int];
    var h: int;
    hs = keys(insts);
    foreach (h in hs) {
      if (insts[h].gen == gen) {
        return h;
      }
    }
    return 0;
  }

  // Whether a generation that serves, or served before a publish, is newer than
  // `gen`. A prepared successor is not: it has not been selected. The
  // selection's generation only increases, so a stage for an older one is a dead
  // runtime's message arriving late under the same token.
  fun newerThan(gen: int): bool {
    var hs: seq[int];
    var h: int;
    hs = keys(insts);
    foreach (h in hs) {
      if (insts[h].gen > gen && insts[h].phase != IP_PREPARED) {
        return true;
      }
    }
    return false;
  }

  // The live generations older than `gen`.
  fun olderThan(gen: int): seq[int] {
    var hs: seq[int];
    var h: int;
    var out: seq[int];
    hs = keys(insts);
    foreach (h in hs) {
      if (insts[h].gen < gen) {
        out += (sizeof(out), h);
      }
    }
    return out;
  }

  // An older serving generation stops serving and waits for its retire.
  fun demote(hs: seq[int]) {
    var h: int;
    var i: tInst;
    foreach (h in hs) {
      i = insts[h];
      if (i.phase == IP_SERVING) {
        i.phase = IP_RETIRING;
        insts[h] = i;
      }
    }
  }

  // Ends the prepared successor of this generation, whichever handle prepared
  // it.
  fun abortPreparedFor(gen: int) {
    var hs: seq[int];
    var h: int;
    hs = keys(trans);
    foreach (h in hs) {
      if (trans[h].phase == TR_PREPARED && trans[h].target == gen) {
        dropSuccessor(h);
      }
    }
  }

  // Aborts the unpublished transition on a handle and ends its successor.
  fun dropSuccessor(h: int) {
    var tr: tTrans;
    tr = trans[h];
    announce eTrAborted, (handle = h, succ = tr.succ);
    if (tr.succ in insts) {
      endInst(tr.succ);
    }
    tr.phase = TR_ABORTED;
    trans[h] = tr;
  }

  fun startInst(gen: int, phase: tInstPhase): int {
    nextHandle = nextHandle + 1;
    insts[nextHandle] = (gen = gen, inc = scopeInc, phase = phase);
    announce eInstStarted, (handle = nextHandle, gen = gen, inc = scopeInc);
    return nextHandle;
  }

  fun endInst(h: int) {
    insts -= (h);
    announce eInstEnded, h;
  }

  // The generation the executor serves: the highest one that answers tool runs.
  fun changed() {
    var hs: seq[int];
    var h: int;
    var served: int;
    var serving: int;
    var prepared: int;
    hs = keys(insts);
    foreach (h in hs) {
      if (insts[h].phase == IP_SERVING) {
        serving = serving + 1;
        if (insts[h].gen > served) {
          served = insts[h].gen;
        }
      }
      if (insts[h].phase == IP_PREPARED) {
        prepared = prepared + 1;
      }
    }
    announce eSlot, (serving = serving, prepared = prepared);
    announce eServedNow, served;
  }

  fun replyStaged(m: tMsg, handle: int, superseded: seq[int]) {
    var r: tMsg;
    r = default(tMsg);
    r.kind = K_E_STAGED;
    r.dest = m.from;
    r.from = this;
    r.attempt = m.attempt;
    r.verdict = V_OK;
    r.handle = handle;
    r.superseded = superseded;
    send wire, eSend, (sender = this, msg = r);
  }

  fun reply(m: tMsg, kind: tKind, verdict: tVerdict, handle: int, succ: int) {
    var r: tMsg;
    r = default(tMsg);
    r.kind = kind;
    r.dest = m.from;
    r.from = this;
    r.attempt = m.attempt;
    r.verdict = verdict;
    r.handle = handle;
    r.succ = succ;
    send wire, eSend, (sender = this, msg = r);
  }
}

// ---------------------------------------------------------------------------
// The orchestrator's catalogue.
// ---------------------------------------------------------------------------

// The durable half. Its selection and receipt survive every open.
// It also stands for the code that opens a session: an open crash mints a new
// attach token at the same incarnation, a runtime restart starts a new owner
// under the same token, and a reopen closes the scope and attaches at the next
// incarnation. A write from an owner that is no longer current is dropped,
// which is the generation fence of the real catalogue.
//
// The compare-and-set is rejected `casFailures` times (another writer moved the
// selection, then moved it back) and may commit with its reply lost, as often
// as `casLost` allows. An owner dies at the moments the case names: after any
// request, as often as `deaths` allows, or after a request of the kind
// `deathAt`, `deathsAt` times. The wire holds the last request of an owner that
// is about to die (it stalls the owner's queue), which puts a dead owner's
// request in flight beside its successor's at a chosen point.
machine Catalogue {
  var wire: machine;
  var executor: machine;
  var inc: int;
  var token: int;
  var selection: int;
  var receipt: tReceipt;
  var attemptsLeft: int;
  var casFailures: int;
  var casLost: int;
  var deaths: int;
  var deathAt: tKind;
  var deathsAt: int;
  var owner: machine;
  var ownerGen: int;

  start state Init {
    entry (p: (wire: machine, executor: machine, attempts: int, casFailures: int, casLost: int, deaths: int, deathAt: tKind, deathsAt: int)) {
      wire = p.wire;
      executor = p.executor;
      attemptsLeft = p.attempts;
      casFailures = p.casFailures;
      casLost = p.casLost;
      deaths = p.deaths;
      deathAt = p.deathAt;
      deathsAt = p.deathsAt;
      inc = 1;
      token = 1;
      selection = 1;
      announce eSelected, 1;
      startOwner(true);
      goto Attaching;
    }
  }

  // The open attaches once before anything else, and the environment cannot end
  // it in this state (a delayed attach of a dead open could replace the token a
  // later one holds, which README.md leaves unexplored).
  state Attaching {
    defer eOpenCrash, eRuntimeRestart, eReopen;

    on eOwnerAttached do (g: int) {
      if (g == ownerGen) {
        goto Serving;
      }
    }

    on eAfterSend do (a: (gen: int, kind: tKind)) { }

    on eAttemptBegin do (g: int) {
      begin(g);
    }

    on eCasRequest do (r: (gen: int, handle: int, succ: int)) {
      cas(r);
    }

    on eReceiptRead do (g: int) {
      readReceipt(g);
    }
  }

  state Serving {
    on eOpenCrash do {
      stopOwner();
      token = token + 1;
      startOwner(true);
      goto Attaching;
    }

    on eRuntimeRestart do {
      stopOwner();
      startOwner(false);
    }

    on eReopen do {
      var m: tMsg;
      stopOwner();
      m = default(tMsg);
      m.kind = K_E_CLOSE;
      m.dest = executor;
      m.from = this;
      m.inc = inc;
      send wire, eSend, (sender = this, msg = m);
      inc = inc + 1;
      token = token + 1;
      startOwner(true);
      goto Attaching;
    }

    on eOwnerAttached do (g: int) { }

    // The owner died right after it handed a request to the wire, which is the
    // moment that leaves a dead owner's request in flight beside its
    // successor's: its runtime restarted under the same token, or its open
    // ended and the next one attaches with a new token.
    on eAfterSend do (a: (gen: int, kind: tKind)) {
      if (a.gen == ownerGen && a.kind == deathAt && deathsAt > 0) {
        deathsAt = deathsAt - 1;
        stopOwner();
        startOwner(false);
        return;
      }
      if (a.gen == ownerGen && deaths > 0 && $) {
        deaths = deaths - 1;
        stopOwner();
        if ($) {
          token = token + 1;
          startOwner(true);
          goto Attaching;
        }
        startOwner(false);
      }
    }

    on eAttemptBegin do (g: int) {
      begin(g);
    }

    on eCasRequest do (r: (gen: int, handle: int, succ: int)) {
      cas(r);
    }

    on eReceiptRead do (g: int) {
      readReceipt(g);
    }
  }

  // An owner starts from what the catalogue holds now.
  fun startOwner(attach: bool) {
    ownerGen = ownerGen + 1;
    owner = new LiveOwner((wire = wire, executor = executor, cat = this, gen = ownerGen, inc = inc, token = token, attach = attach, view = (selection = selection, attemptsLeft = attemptsLeft), deathAt = deathKind()));
  }

  // The kind of request after which the next owner dies, or K_E_CLOSE (which
  // no owner sends) when the budget is spent.
  fun deathKind(): tKind {
    if (deathsAt > 0) {
      return deathAt;
    }
    return K_E_CLOSE;
  }

  fun stopOwner() {
    send wire, eWireStall, owner;
    send owner, halt;
  }

  fun begin(g: int) {
    if (g == ownerGen && attemptsLeft > 0) {
      attemptsLeft = attemptsLeft - 1;
    }
  }

  // The compare-and-set of the selection from 1 to 2. A commit writes the new
  // selection and the receipt in one step.
  fun cas(r: (gen: int, handle: int, succ: int)) {
    if (r.gen != ownerGen) {
      return;
    }
    if (selection != 1 || casFailures > 0) {
      if (selection == 1) {
        casFailures = casFailures - 1;
      }
      send owner, eCasReply, (gen = r.gen, result = CAS_REJECTED);
      return;
    }
    selection = 2;
    receipt = R_COMMITTED;
    announce eSelected, 2;
    if (casLost > 0 && $) {
      casLost = casLost - 1;
      send owner, eCasReply, (gen = r.gen, result = CAS_UNKNOWN);
    } else {
      send owner, eCasReply, (gen = r.gen, result = CAS_COMMITTED);
    }
  }

  fun readReceipt(g: int) {
    if (g == ownerGen) {
      send owner, eReceiptIs, (gen = g, receipt = receipt);
    }
  }
}

// ---------------------------------------------------------------------------
// The live owner and its remote machine.
// ---------------------------------------------------------------------------

// One owner per open, or per runtime inside an open. It exchanges one request
// with the executor at a time and, as `surface.send_and_wait` does, sends the
// same request again when the connection drops (`resent` marks the repeat).
//
// Its steps:
//
//   attach (a new open only), then stage the catalogue's selection. A new open
//   always stages: it does not try to finish a migration its predecessor began,
//   because the receipt holds no handle and executor handles do not survive a VM
//   restart. The stage reports the older generations still live, and each
//   becomes a retire obligation.
//   If the selection is still generation 1 and the catalogue allows an attempt,
//   prepare generation 2.
//   compare-and-set the selection. Committed: publish. Rejected: abort. Reply
//   lost: read the durable receipt and take whichever arm it names.
//   after a publish, the predecessor becomes an obligation.
//   retire the obligations one at a time. The list is this owner's memory: it
//   dies with the owner, and the next open learns the generations through the
//   stage. An unconfirmed retirement is retried and its obligation is kept.
//
// A refusal that says the plane is gone ends the owner's work: nothing
// re-attaches inside an open.
machine LiveOwner {
  var wire: machine;
  var executor: machine;
  var cat: machine;
  var gen: int;
  var inc: int;
  var token: int;
  var attempt: int;
  var view: tCatalogueView;
  var req: tMsg;
  var resent: bool;
  var pred: int;
  var succ: int;
  var queue: seq[int];
  var deathAt: tKind;

  start state Init {
    entry (p: (wire: machine, executor: machine, cat: machine, gen: int, inc: int, token: int, attach: bool, view: tCatalogueView, deathAt: tKind)) {
      wire = p.wire;
      executor = p.executor;
      cat = p.cat;
      gen = p.gen;
      inc = p.inc;
      token = p.token;
      view = p.view;
      deathAt = p.deathAt;
      if (p.attach) {
        request(K_ATTACH, 0, 0, 0);
        goto Attaching;
      }
      recover();
    }
  }

  state Attaching {
    on eNet do (m: tMsg) {
      if (m.kind == K_ATTACHED && m.attempt == attempt) {
        if (m.verdict != V_OK) {
          goto Dormant;
        }
        send cat, eOwnerAttached, gen;
        recover();
      }
    }

    on eNoConn do {
      resend();
    }

    ignore eCasReply, eReceiptIs;
  }

  state Staging {
    on eNet do (m: tMsg) {
      if (m.kind == K_E_STAGED && m.attempt == attempt) {
        if (m.verdict != V_OK) {
          goto Dormant;
        }
        pred = m.handle;
        owe(m.superseded);
        afterStage();
      }
    }

    on eNoConn do {
      resend();
    }

    ignore eCasReply, eReceiptIs;
  }

  state Preparing {
    on eNet do (m: tMsg) {
      if (m.kind == K_E_PREPARED && m.attempt == attempt) {
        if (m.verdict != V_OK) {
          goto Dormant;
        }
        succ = m.succ;
        send cat, eCasRequest, (gen = gen, handle = pred, succ = succ);
        goto CasWait;
      }
    }

    on eNoConn do {
      resend();
    }

    ignore eCasReply, eReceiptIs;
  }

  // The compare-and-set is a local step on the orchestrator. Nothing is
  // outstanding on the wire.
  state CasWait {
    on eCasReply do (r: (gen: int, result: tCas)) {
      if (r.gen != gen) {
        return;
      }
      if (r.result == CAS_COMMITTED) {
        startPublish();
      } else if (r.result == CAS_REJECTED) {
        startAbort();
      } else {
        send cat, eReceiptRead, gen;
        goto Reconciling;
      }
    }

    ignore eNet, eNoConn, eReceiptIs;
  }

  // The reply to the compare-and-set was lost. The durable receipt says whether
  // it committed.
  state Reconciling {
    on eReceiptIs do (r: (gen: int, receipt: tReceipt)) {
      if (r.gen != gen) {
        return;
      }
      announce eCasReconciled, r.receipt;
      if (r.receipt == R_COMMITTED) {
        startPublish();
      } else {
        startAbort();
      }
    }

    ignore eNet, eNoConn, eCasReply;
  }

  state Publishing {
    on eNet do (m: tMsg) {
      if (m.kind == K_E_PUBLISHED && m.attempt == attempt) {
        if (m.verdict == V_OK) {
          published();
        } else if (m.verdict == V_UNKNOWN_HANDLE) {
          // The executor holds no such transition (a new VM or a new
          // incarnation): the selection is generation 2, so stage it.
          view.selection = 2;
          request(K_E_STAGE, 2, 0, 0);
          goto Staging;
        } else {
          goto Dormant;
        }
      }
    }

    on eNoConn do {
      resend();
    }

    ignore eCasReply, eReceiptIs;
  }

  state Aborting {
    on eNet do (m: tMsg) {
      if (m.kind == K_E_ABORTED && m.attempt == attempt) {
        if (m.verdict == V_OK) {
          startRetire();
        } else {
          goto Dormant;
        }
      }
    }

    on eNoConn do {
      resend();
    }

    ignore eCasReply, eReceiptIs;
  }

  state Retiring {
    on eNet do (m: tMsg) {
      if (m.kind == K_E_RETIRED && m.attempt == attempt) {
        if (m.verdict == V_ALL_RETIRED) {
          announce eRetireSeen, queue[0];
          announce eObligationDropped, queue[0];
          queue -= (0);
          startRetire();
        } else if (m.verdict == V_UNKNOWN_CLEANUP) {
          request(K_E_RETIRE, 0, queue[0], 0);
        } else {
          goto Dormant;
        }
      }
    }

    on eNoConn do {
      resend();
    }

    ignore eCasReply, eReceiptIs;
  }

  state Idle {
    ignore eNet, eNoConn, eCasReply, eReceiptIs;
  }

  state Dormant {
    ignore eNet, eNoConn, eCasReply, eReceiptIs;
  }

  // What an open does first: stage the selection.
  fun recover() {
    if (view.selection == 2) {
      announce eRecoveryStage, 2;
    }
    request(K_E_STAGE, view.selection, 0, 0);
    goto Staging;
  }

  fun afterStage() {
    if (view.selection == 1 && view.attemptsLeft > 0) {
      view.attemptsLeft = view.attemptsLeft - 1;
      send cat, eAttemptBegin, gen;
      request(K_E_PREPARE, 2, pred, 0);
      goto Preparing;
    }
    startRetire();
  }

  fun startPublish() {
    request(K_E_PUBLISH, 2, pred, succ);
    goto Publishing;
  }

  fun startAbort() {
    request(K_E_ABORT, 2, pred, succ);
    goto Aborting;
  }

  // The publish is confirmed: the superseded generation becomes an obligation,
  // and every obligation is retired.
  fun published() {
    var one: seq[int];
    one += (0, pred);
    owe(one);
    startRetire();
  }

  // Adds retire obligations, each once.
  fun owe(hs: seq[int]) {
    var h: int;
    foreach (h in hs) {
      if (!inSeq(queue, h)) {
        queue += (sizeof(queue), h);
      }
    }
  }

  // Retires the obligations one at a time, each until it is confirmed.
  fun startRetire() {
    if (sizeof(queue) == 0) {
      goto Idle;
    }
    request(K_E_RETIRE, 0, queue[0], 0);
    goto Retiring;
  }

  fun request(kind: tKind, g: int, h: int, s: int) {
    attempt = attempt + 1;
    req = default(tMsg);
    req.kind = kind;
    req.dest = executor;
    req.from = this;
    req.inc = inc;
    req.token = token;
    req.gen = g;
    req.handle = h;
    req.succ = s;
    transmit();
  }

  fun resend() {
    attempt = attempt + 1;
    resent = true;
    transmit();
    resent = false;
  }

  fun transmit() {
    req.attempt = attempt;
    req.resent = resent;
    if (req.kind == deathAt) {
      send wire, eWireStall, this;
    }
    send wire, eSend, (sender = this, msg = req);
    send cat, eAfterSend, (gen = gen, kind = req.kind);
  }
}
