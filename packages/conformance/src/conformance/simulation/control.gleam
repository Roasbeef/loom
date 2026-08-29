//// The simulation's side channel: one actor that outlives the session
//// tree.
////
//// Everything a fault schedule needs to be reproducible is a count of
//// something that must survive a crash — how many commits have landed,
//// how many effects have been dispatched, whether a one-shot fault has
//// already fired. Keeping those in a process the tree does not own is
//// what makes "kill after commit 7" mean commit 7 of the *session*
//// rather than commit 7 of whichever writer incarnation is running.
////
//// The runtime handle lives here too, so an effect script can steer or
//// abort the very session it is running inside without the runner
//// threading a handle through every closure.
////
//// It also owns `attempt`, the way anything reaches into a session tree
//// that may be mid-restart, and with it the simulation's one remaining
//// piece of wall clock. `attempt`'s docs say exactly how much clock is
//// left, why it cannot be made logical, and how a run that touched it
//// says so — `Report.waits` in the runner is fed from here.
////
//// And it is the rendezvous `await_intervention`/`take_pending_
//// interventions` use to move a scripted intervention's *decision* out
//// of the effect it used to fire from. A `DuringTurn`/`DuringCall`
//// trigger is reached from inside a real effect process — one a
//// `RestartStrand` fault can reap mid-flight — and an effect that fired
//// the intervention itself, via `attempt`, was the thing meant to
//// observe and record what became of it; reaping that effect before
//// `attempt` returned meant the observation never happened; even the
//// bare `intervening@path` the claim opened could go unexplained. The
//// runner never sits inside the tree a fault schedule can reach, so it
//// is the one thing safe to hand the admission to; the effect merely
//// registers that it has reached a live trigger and blocks until the
//// runner has fired whatever the script placed there and let it go.
////
//// This module is test infrastructure: `let assert` appears here (as in
//// `conformance/storage_suite`) because a runner whose control actor
//// will not start has nothing to say.

import conformance/simulation/script.{type Trigger}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/set.{type Set}
import runtime/api

/// Messages understood by the control actor. Opaque: callers use the
/// wrapper functions.
pub opaque type Message {
  Bump(key: String, reply: Subject(Int))
  Read(key: String, reply: Subject(Int))
  Once(key: String, reply: Subject(Bool))
  CommitStarted(reply: Subject(Nil))
  CommitSucceeded(reply: Subject(Int))
  CommitFailed(reply: Subject(Nil))
  NoteCommit(reply: Subject(Int))
  SeamDone
  SeamQuiet(reply: Subject(Bool))
  Arm(reply: Subject(Nil))
  Commits(reply: Subject(Int))
  Events(reply: Subject(Int))
  SetRuntime(runtime: api.Runtime)
  GetRuntime(reply: Subject(Option(api.Runtime)))
  NoteCrash
  Crashed(reply: Subject(Bool))
  Note(text: String)
  Notes(reply: Subject(List(String)))
  NoteWait(text: String)
  Waits(reply: Subject(List(String)))
  ClaimIntervention(key: String, path: String, reply: Subject(Bool))
  Intervened(path: String)
  AwaitIntervention(trigger: Trigger, reply: Subject(Nil))
  TakePendingInterventions(reply: Subject(List(#(Trigger, Subject(Nil)))))
  Mark(path: String)
  Marks(reply: Subject(List(String)))
  Shutdown
}

type State {
  State(
    counters: Dict(String, Int),
    claimed: Set(String),
    commits_in_flight: Int,
    commits: Int,
    events: Int,
    runtime: Option(api.Runtime),
    armed: Bool,
    seam_open: Bool,
    crashed: Bool,
    notes: List(String),
    waits: List(String),
    marks: Set(String),
    pending_interventions: List(#(Trigger, Subject(Nil))),
  )
}

/// A running control actor.
pub type Control {
  Control(subject: Subject(Message), pid: Pid)
}

/// Starts a control actor with everything at zero.
///
/// ## Examples
///
/// ```gleam
/// // let ctl = control.start()
/// ```
///
pub fn start() -> Control {
  let assert Ok(started) =
    actor.new(
      State(
        counters: dict.new(),
        claimed: set.new(),
        commits_in_flight: 0,
        commits: 0,
        events: 0,
        runtime: None,
        armed: False,
        seam_open: False,
        crashed: False,
        notes: [],
        waits: [],
        marks: set.new(),
        pending_interventions: [],
      ),
    )
    |> actor.on_message(handle)
    |> actor.start
    as "the simulation control actor must start"
  Control(subject: started.data, pid: started.pid)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Bump(key:, reply:) -> {
      let count = current(state, key) + 1
      process.send(reply, count)
      actor.continue(
        State(
          ..state,
          counters: dict.insert(state.counters, key, count),
          events: state.events + 1,
        ),
      )
    }
    Read(key:, reply:) -> {
      process.send(reply, current(state, key))
      actor.continue(state)
    }
    Once(key:, reply:) ->
      case set.contains(state.claimed, key) {
        True -> {
          process.send(reply, False)
          actor.continue(state)
        }
        False -> {
          process.send(reply, True)
          actor.continue(
            State(..state, claimed: set.insert(state.claimed, key)),
          )
        }
      }
    CommitStarted(reply:) -> {
      let next = case state.commits_in_flight < 0 {
        True -> state
        False -> State(..state, commits_in_flight: state.commits_in_flight + 1)
      }
      process.send(reply, Nil)
      actor.continue(next)
    }
    CommitSucceeded(reply:) -> {
      let commits = state.commits + 1
      let next = case state.commits_in_flight > 0 {
        True ->
          State(
            ..state,
            commits_in_flight: state.commits_in_flight - 1,
            commits:,
            events: state.events + 1,
            // Hand the accounting fence directly to the writer's
            // post-commit seam. No observer can see both as closed.
            seam_open: state.armed,
          )
        False -> poison_accounting(state)
      }
      process.send(reply, commits)
      actor.continue(next)
    }
    CommitFailed(reply:) -> {
      let next = case state.commits_in_flight > 0 {
        True -> State(..state, commits_in_flight: state.commits_in_flight - 1)
        False -> poison_accounting(state)
      }
      process.send(reply, Nil)
      actor.continue(next)
    }
    NoteCommit(reply:) -> {
      let commits = state.commits + 1
      process.send(reply, commits)
      actor.continue(
        State(
          ..state,
          commits:,
          events: state.events + 1,
          // The writer runs its post-commit seam between applying this
          // commit and replying for it. Until that seam finishes, a
          // schedule aimed at this commit has not had its chance.
          seam_open: state.armed,
        ),
      )
    }
    SeamDone -> actor.continue(State(..state, seam_open: False))
    SeamQuiet(reply:) -> {
      process.send(reply, state.commits_in_flight == 0 && !state.seam_open)
      actor.continue(state)
    }
    Arm(reply:) -> {
      process.send(reply, Nil)
      actor.continue(
        State(
          ..state,
          armed: True,
          commits_in_flight: 0,
          commits: 0,
          seam_open: False,
        ),
      )
    }
    Commits(reply:) -> {
      // Unarmed, the answer is a number no schedule can name, so a fault
      // cannot fire on a commit made before the run began.
      process.send(reply, case state.armed {
        True -> state.commits
        False -> -1
      })
      actor.continue(state)
    }
    Events(reply:) -> {
      process.send(reply, state.events)
      actor.continue(state)
    }
    SetRuntime(runtime:) ->
      actor.continue(State(..state, runtime: Some(runtime)))
    GetRuntime(reply:) -> {
      process.send(reply, state.runtime)
      actor.continue(state)
    }
    NoteCrash ->
      // The killed writer cannot close its seam. Close that specific seam
      // here, while leaving later commits responsible for closing their own.
      actor.continue(State(..state, seam_open: False, crashed: True))
    Note(text:) -> actor.continue(State(..state, notes: [text, ..state.notes]))
    Notes(reply:) -> {
      process.send(reply, list.reverse(state.notes))
      actor.continue(state)
    }
    // Deliberately not counted in `events`: the runner reads that
    // counter to tell a working session from a quiescent one, and an
    // observation about the harness is not the session doing work.
    NoteWait(text:) ->
      actor.continue(State(..state, waits: [text, ..state.waits]))
    Waits(reply:) -> {
      process.send(reply, list.reverse(state.waits))
      actor.continue(state)
    }
    // Claiming a scripted intervention and registering it as in flight
    // are one actor step, so there is no instant at which the one-shot
    // is spent and the run does not yet know an admission is owed.
    ClaimIntervention(key:, path:, reply:) ->
      case set.contains(state.claimed, key) {
        True -> {
          process.send(reply, False)
          actor.continue(state)
        }
        False -> {
          process.send(reply, True)
          actor.continue(
            State(..state, claimed: set.insert(state.claimed, key), waits: [
              "intervening@" <> path,
              ..state.waits
            ]),
          )
        }
      }
    Intervened(path:) ->
      actor.continue(
        State(..state, waits: ["intervened@" <> path, ..state.waits]),
      )
    // Registering the wait and handing out the reply subject are the
    // same actor step as everything else here, which is what lets the
    // runner discover "an effect is waiting on this trigger" with
    // nothing lost between the effect asking and the runner looking.
    AwaitIntervention(trigger:, reply:) ->
      actor.continue(
        State(..state, pending_interventions: [
          #(trigger, reply),
          ..state.pending_interventions
        ]),
      )
    // Taking the queue clears it in the same step, so a trigger the
    // runner has just serviced cannot be handed out to it (or to a
    // corroboration re-run's own control actor, which starts fresh
    // anyway) a second time.
    TakePendingInterventions(reply:) -> {
      process.send(reply, list.reverse(state.pending_interventions))
      actor.continue(State(..state, pending_interventions: []))
    }
    Mark(path:) ->
      actor.continue(State(..state, marks: set.insert(state.marks, path)))
    Marks(reply:) -> {
      process.send(reply, set.to_list(state.marks))
      actor.continue(state)
    }
    Shutdown -> actor.stop()
    Crashed(reply:) -> {
      process.send(reply, state.crashed)
      actor.continue(state)
    }
  }
}

fn current(state: State, key: String) -> Int {
  case dict.get(state.counters, key) {
    Ok(count) -> count
    Error(Nil) -> 0
  }
}

fn poison_accounting(state: State) -> State {
  case state.commits_in_flight < 0 {
    True -> state
    False ->
      State(..state, commits_in_flight: -1, notes: [
        "commit accounting underflow",
        ..state.notes
      ])
  }
}

/// Increments a named counter and returns its new value.
///
/// ## Examples
///
/// ```gleam
/// // control.bump(ctl, "effect")
/// ```
///
pub fn bump(ctl: Control, key: String) -> Int {
  process.call_forever(ctl.subject, Bump(key, _))
}

/// Reads a named counter (zero when never bumped).
///
/// ## Examples
///
/// ```gleam
/// // control.read(ctl, "tool:write:c0write")
/// ```
///
pub fn read(ctl: Control, key: String) -> Int {
  process.call_forever(ctl.subject, Read(key, _))
}

/// Claims a one-shot: `True` the first time this key is claimed and
/// `False` ever after, across tree restarts. Every fault and every
/// intervention fires through this, which is what keeps a schedule from
/// firing twice when recovery re-runs the step it was aimed at.
///
/// ## Examples
///
/// ```gleam
/// // case control.claim(ctl, "crash@c7") { True -> kill() False -> Nil }
/// ```
///
pub fn claim(ctl: Control, key: String) -> Bool {
  process.call_forever(ctl.subject, Once(key, _))
}

/// Opens the accounting fence before a storage commit can become visible.
///
/// The instrumented store performs its bookkeeping after the inner backend
/// answers. The fence prevents the runner from accepting a terminal result in
/// the interval between that answer and the corresponding counter updates.
///
/// ## Examples
///
/// ```gleam
/// // control.commit_started(ctl)
/// ```
///
pub fn commit_started(ctl: Control) -> Nil {
  process.call_forever(ctl.subject, CommitStarted)
}

/// Atomically hands a successful commit's accounting fence to its seam.
///
/// The returned ordinal records the commit in the same actor transition that
/// closes the fence and opens the post-commit seam, so an observer can never
/// see both phases as quiet.
///
/// ## Examples
///
/// ```gleam
/// // control.commit_succeeded(ctl)
/// ```
///
pub fn commit_succeeded(ctl: Control) -> Int {
  process.call_forever(ctl.subject, CommitSucceeded)
}

/// Closes one accounting fence after the inner backend refuses a commit.
///
/// ## Examples
///
/// ```gleam
/// // control.commit_failed(ctl)
/// ```
///
pub fn commit_failed(ctl: Control) -> Nil {
  process.call_forever(ctl.subject, CommitFailed)
}

/// Records one successful commit and returns the session-wide ordinal.
///
/// ## Examples
///
/// ```gleam
/// // control.note_commit(ctl)
/// ```
///
pub fn note_commit(ctl: Control) -> Int {
  process.call_forever(ctl.subject, NoteCommit)
}

/// The number of commits that have landed in this session.
///
/// ## Examples
///
/// ```gleam
/// // control.commits(ctl)
/// ```
///
pub fn commits(ctl: Control) -> Int {
  process.call_forever(ctl.subject, Commits)
}

/// A monotone count of everything observable the session has done:
/// commits plus effect dispatches plus hook calls. The runner watches it
/// to tell a busy session from a quiescent one.
///
/// ## Examples
///
/// ```gleam
/// // control.events(ctl)
/// ```
///
pub fn events(ctl: Control) -> Int {
  process.call_forever(ctl.subject, Events)
}

/// Publishes the runtime handle to the effect scripts.
///
/// ## Examples
///
/// ```gleam
/// // control.set_runtime(ctl, runtime)
/// ```
///
pub fn set_runtime(ctl: Control, runtime: api.Runtime) -> Nil {
  process.send(ctl.subject, SetRuntime(runtime:))
}

/// The published runtime handle, if `set_runtime` has run.
///
/// ## Examples
///
/// ```gleam
/// // control.runtime(ctl)
/// ```
///
pub fn runtime(ctl: Control) -> Option(api.Runtime) {
  process.call_forever(ctl.subject, GetRuntime)
}

/// Records that a crash fault actually fired. A schedule whose crash
/// never fired would make its run vacuous, so the runner checks this.
///
/// ## Examples
///
/// ```gleam
/// // control.note_crash(ctl)
/// ```
///
pub fn note_crash(ctl: Control) -> Nil {
  process.send(ctl.subject, NoteCrash)
}

/// Whether a crash fault fired.
///
/// ## Examples
///
/// ```gleam
/// // control.crashed(ctl)
/// ```
///
pub fn crashed(ctl: Control) -> Bool {
  process.call_forever(ctl.subject, Crashed)
}

/// What became of an action run on a disposable process.
///
/// The three cases are not three degrees of failure. `Answered` is the
/// only one that says anything about the session; **both** other cases
/// mean *the reply was not observed*, which is emphatically not the same
/// as "the action did not happen". A commit whose reply is lost may
/// already be durable. Callers must therefore treat `Raised` and
/// `Expired` alike — ask the durable state what happened rather than
/// concluding anything — and the two are kept apart only so a run can
/// say which of them it went through.
pub type Attempted(value) {
  /// The action returned, and this is what it returned.
  Answered(value: value)
  /// The carrier process died before answering: the action raised.
  /// Addressing a named process the tree has not re-registered raises,
  /// and so does `process.call_forever` when the callee it monitors
  /// dies mid-call — which is exactly what a writer killed inside its
  /// post-commit seam looks like from a caller. Observed through a
  /// monitor, so it is reported the instant it happens and costs no
  /// wall-clock time: an idle box and a loaded one see the same event
  /// at the same point in the run.
  Raised
  /// The wall clock ran out with the carrier still alive, and the
  /// carrier was killed. This is the one outcome in the simulation that
  /// a busy host can manufacture, and the only reason `attempt` still
  /// reads a real clock at all — see `attempt`'s own docs.
  Expired
}

/// Runs `action` on a disposable process and waits for it to answer or
/// to die, giving up after `within_ms` of *real* time if it does
/// neither.
///
/// Anything that reaches into the session tree from outside it — a steer
/// admitted by an effect script, an abort requested from the writer —
/// has to survive the tree being mid-restart, where addressing a named
/// process raises rather than returning. Doing it on a process that may
/// die keeps the caller alive; waiting for the reply keeps the action
/// ordered before whatever the caller does next.
///
/// # Not simulation-safe
///
/// The `within_ms` budget is real milliseconds, not logical ones, and
/// nothing in the simulation controls it. It cannot be made logical: the
/// action blocks on a real OTP call, the logical clock only moves when
/// the runner moves it, and the runner is the process blocked here — a
/// logical deadline would have nobody left to fire it. So the wall clock
/// stays, demoted to what it can honestly be: a **deadlock backstop**, a
/// bound that keeps a wedged call from hanging a CI job forever rather
/// than a bound anything is expected to reach.
///
/// What used to reach it routinely was the carrier *dying* — the
/// overwhelmingly common non-answer, and one with nothing timing-shaped
/// about it. That is now observed through a monitor and returned as
/// `Raised` immediately, which takes the wall clock off the ordinary
/// path entirely. Every `Expired` that does happen is recorded through
/// `note_wait`, reaches the runner as `Report.waits`, and is named in
/// the failure a run reports, so a seed that touched the wall clock says
/// so instead of looking like a behaviour difference.
///
/// # Perturbation
///
/// An `Expired` carrier is killed, and the kill is not free: the action
/// it was running may already have committed and be waiting only for a
/// reply it will now never deliver. That is why the outcome is `Expired`
/// and not `Failed` — it says the reply was lost, and nothing else. The
/// kill is still the right move, because a carrier left running could
/// land its admission *after* the caller has retried and land the same
/// turn twice, which corrupts a run far worse than losing a reply does.
///
/// ## Examples
///
/// ```gleam
/// // control.attempt(ctl, at: "steer", action: fn() {
/// //   api.steer_quietly(rt, message)
/// // }, within_ms: 1000)
/// ```
///
pub fn attempt(
  ctl: Control,
  at at: String,
  action action: fn() -> value,
  within_ms within_ms: Int,
) -> Attempted(value) {
  let reply: Subject(value) = process.new_subject()
  let pid: Pid = process.spawn_unlinked(fn() { process.send(reply, action()) })
  // Monitoring after the spawn is safe even when the carrier is already
  // gone: `erlang:monitor/2` answers a dead pid with an immediate
  // `noproc` down rather than with silence. And a carrier that replied
  // and then exited normally leaves both messages queued, reply first,
  // so the selector reads the reply — a scan of the mailbox in arrival
  // order, not a race.
  let monitor = process.monitor(pid)
  let outcome =
    process.new_selector()
    |> process.select_map(reply, Answered)
    |> process.select_specific_monitor(monitor, fn(_down) { Raised })
    |> process.selector_receive(within: within_ms)
    |> expired_when_silent(pid)
  process.demonitor_process(monitor)
  record_attempt(ctl, at, outcome)
  outcome
}

// The one place the wall clock actually decides something: no reply and
// no death inside the budget. The carrier is killed on the way out (see
// the perturbation note on `attempt`).
fn expired_when_silent(
  received: Result(Attempted(value), Nil),
  pid: Pid,
) -> Attempted(value) {
  case received {
    Ok(outcome) -> outcome
    Error(Nil) -> {
      process.kill(pid)
      Expired
    }
  }
}

// An answered attempt is the ordinary case and says nothing worth
// recording. The other two are what a reader of a failing run needs, and
// they are labelled by call site so the record names *which* admission
// went unobserved rather than merely that one did.
fn record_attempt(ctl: Control, at: String, outcome: Attempted(value)) -> Nil {
  case outcome {
    Answered(..) -> Nil
    Raised -> note_wait(ctl, "raised@" <> at)
    Expired -> note_wait(ctl, "expired@" <> at)
  }
}

/// Claims a scripted intervention's one-shot and, in the same actor
/// step, registers that the run now owes an admission for it.
///
/// The two halves cannot be separated. The claim outlives every restart,
/// so a run that spent it owes the transcript a turn; if the process
/// that spent it is reaped before the admission lands, the run is one
/// scripted turn short of the fault-free run for a reason that has
/// nothing to do with the code under test. Registering here means the
/// runner can see that debt — `waits` carries an `intervening@` with no
/// `intervened@` after it — rather than discovering it only as an
/// unexplained divergence at the end.
///
/// ## Examples
///
/// ```gleam
/// // control.claim_intervention(ctl, "intervention:Steer(..)", "steer")
/// ```
///
pub fn claim_intervention(ctl: Control, key: String, path: String) -> Bool {
  process.call_forever(ctl.subject, ClaimIntervention(key, path, _))
}

/// Reports that a claimed intervention's admission has finished, however
/// it finished. Settles the debt `claim_intervention` opened.
///
/// ## Examples
///
/// ```gleam
/// // control.intervened(ctl, "steer-during-effect")
/// ```
///
pub fn intervened(ctl: Control, path: String) -> Nil {
  process.send(ctl.subject, Intervened(path:))
}

/// Registers that a running effect has reached `trigger` and blocks
/// until the runner has fired every scripted intervention due there and
/// released it.
///
/// This is the handoff #57 exists for. Firing an intervention from
/// inside the effect that reached its trigger ties the admission's fate
/// to that effect's own process, and a `RestartStrand` fault reaps
/// exactly that process — taking the claim and the carrier down before
/// the admission ever lands, with nothing else positioned to retry it.
/// The runner's own process is never a target of any fault in the
/// taxonomy, so handing the decision to it (via `take_pending_
/// interventions`, serviced from the drive loop) is what makes a reap
/// survivable: the caller here only has to survive long enough to be
/// released, not to carry the admission itself.
///
/// The wait is bounded because it is still real milliseconds — the
/// runner's poll cadence, not a promise — and a caller that gives up
/// proceeds rather than hangs, exactly like `attempt`'s own deadlock
/// backstop. In ordinary operation the runner services the queue on
/// every drive pass, so this returns within a poll or two; reaching the
/// bound is recorded, not silently absorbed.
///
/// ## Examples
///
/// ```gleam
/// // control.await_intervention(ctl, script.DuringTurn(turn: 1), within_ms: 3000)
/// ```
///
pub fn await_intervention(
  ctl: Control,
  trigger: Trigger,
  within_ms within_ms: Int,
) -> Nil {
  let reply: Subject(Nil) = process.new_subject()
  process.send(ctl.subject, AwaitIntervention(trigger, reply))
  case process.receive(reply, within_ms) {
    Ok(Nil) -> Nil
    Error(Nil) -> note_wait(ctl, "expired@await-intervention")
  }
}

/// Takes every trigger currently awaiting the runner's attention,
/// clearing the queue in the same step. The runner's drive loop calls
/// this on every pass; each entry's reply subject is how it releases the
/// effect that is blocked on `await_intervention`.
///
/// ## Examples
///
/// ```gleam
/// // control.take_pending_interventions(ctl)
/// ```
///
pub fn take_pending_interventions(
  ctl: Control,
) -> List(#(Trigger, Subject(Nil))) {
  process.call_forever(ctl.subject, TakePendingInterventions)
}

/// Records that an `attempt` did not observe its reply, and how. The
/// runner collects these into `Report.waits`.
///
/// ## Examples
///
/// ```gleam
/// // control.note_wait(ctl, "expired@admit")
/// ```
///
pub fn note_wait(ctl: Control, text: String) -> Nil {
  process.send(ctl.subject, NoteWait(text:))
}

/// Every unobserved reply this run went through, oldest first, each
/// labelled `raised@<site>` or `expired@<site>`.
///
/// An `expired@` entry is the whole of the simulation's exposure to the
/// host's clock, so a run that reports none of them did not have one
/// available to blame.
///
/// ## Examples
///
/// ```gleam
/// // control.waits(ctl)
/// ```
///
pub fn waits(ctl: Control) -> List(String) {
  process.call_forever(ctl.subject, Waits)
}

/// Records a violation (or any other observation) seen deep inside the
/// commit path, where returning a failure would only be swallowed.
///
/// ## Examples
///
/// ```gleam
/// // control.note(ctl, "placement/queued-id: ...")
/// ```
///
pub fn note(ctl: Control, text: String) -> Nil {
  process.send(ctl.subject, Note(text:))
}

/// Everything `note` recorded, oldest first.
///
/// ## Examples
///
/// ```gleam
/// // control.notes(ctl)
/// ```
///
pub fn notes(ctl: Control) -> List(String) {
  process.call_forever(ctl.subject, Notes)
}

/// Runs `action` on a disposable process without waiting for it. Use it
/// where the action must not be allowed to raise into the caller and its
/// completion does not need to be ordered — ringing a doorbell at a
/// strand that may be mid-restart, for instance.
///
/// ## Examples
///
/// ```gleam
/// // control.detached(fn() { api.nudge(runtime) })
/// ```
///
pub fn detached(action: fn() -> a) -> Nil {
  let _pid = process.spawn_unlinked(fn() { action() })
  Nil
}

/// Stops the control actor, releasing everything it counted.
///
/// ## Examples
///
/// ```gleam
/// // control.stop(ctl)
/// ```
///
pub fn stop(ctl: Control) -> Nil {
  process.send(ctl.subject, Shutdown)
}

/// Marks a code path as reached. The runner reports the marks of a run,
/// which is how the suite proves it generates sessions that get to the
/// deferred, compaction, structural, and navigation paths rather than
/// merely hoping it does.
///
/// ## Examples
///
/// ```gleam
/// // control.mark(ctl, "deferred-poll")
/// ```
///
pub fn mark(ctl: Control, path: String) -> Nil {
  process.send(ctl.subject, Mark(path:))
}

/// Every path this run reached, unordered.
///
/// ## Examples
///
/// ```gleam
/// // control.marks(ctl)
/// ```
///
pub fn marks(ctl: Control) -> List(String) {
  process.call_forever(ctl.subject, Marks)
}

/// Arms the schedule and restarts the commit count at zero.
///
/// Seeding a fresh session's strand registers commits before the writer
/// exists, and those commits have no post-commit seam to fire a crash
/// from — refusing one would break the session rather than test it. So
/// nothing fires until the runner has seeded the strand and is about to
/// start the tree, and commit ordinal 1 means the first commit a
/// schedule can actually reach.
///
/// ## Examples
///
/// ```gleam
/// // control.arm(ctl)
/// ```
///
pub fn arm(ctl: Control) -> Nil {
  process.call_forever(ctl.subject, Arm)
}

/// Reports that the writer has finished its post-commit seam for the
/// commit that most recently landed.
///
/// ## Examples
///
/// ```gleam
/// // control.seam_done(ctl)
/// ```
///
pub fn seam_done(ctl: Control) -> Nil {
  process.send(ctl.subject, SeamDone)
}

/// Whether no commit accounting or post-commit seam is still running.
///
/// A commit becomes visible in the store before the writer runs the seam
/// that a crash schedule fires from, so a runner that took the terminal
/// result the moment it appeared could end a run while the fault aimed
/// at its last commit was still queued behind an intervention. Waiting
/// for both phases is what makes the bookkeeping complete and a
/// commit-indexed fault's chance to fire part of the run rather than a race
/// against the observer.
///
/// ## Examples
///
/// ```gleam
/// // case control.seam_quiet(ctl) { True -> take_result() False -> wait() }
/// ```
///
pub fn seam_quiet(ctl: Control) -> Bool {
  process.call_forever(ctl.subject, SeamQuiet)
}
