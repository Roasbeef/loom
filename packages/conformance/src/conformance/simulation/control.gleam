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
//// This module is test infrastructure: `let assert` appears here (as in
//// `conformance/storage_suite`) because a runner whose control actor
//// will not start has nothing to say.

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
  Mark(path: String)
  Marks(reply: Subject(List(String)))
  Shutdown
}

type State {
  State(
    counters: Dict(String, Int),
    claimed: Set(String),
    commits: Int,
    events: Int,
    runtime: Option(api.Runtime),
    armed: Bool,
    seam_open: Bool,
    crashed: Bool,
    notes: List(String),
    marks: Set(String),
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
    actor.new(State(
      counters: dict.new(),
      claimed: set.new(),
      commits: 0,
      events: 0,
      runtime: None,
      armed: False,
      seam_open: False,
      crashed: False,
      notes: [],
      marks: set.new(),
    ))
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
      // A crash *is* the seam not finishing: the writer was killed
      // inside it, so waiting for it to close would wait forever.
      process.send(reply, !state.seam_open || state.crashed)
      actor.continue(state)
    }
    Arm(reply:) -> {
      process.send(reply, Nil)
      actor.continue(State(..state, armed: True, commits: 0, seam_open: False))
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
    NoteCrash -> actor.continue(State(..state, crashed: True))
    Note(text:) -> actor.continue(State(..state, notes: [text, ..state.notes]))
    Notes(reply:) -> {
      process.send(reply, list.reverse(state.notes))
      actor.continue(state)
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

/// Runs `action` on a disposable process and waits up to `within_ms`
/// for its result.
///
/// Anything that reaches into the session tree from outside it — a steer
/// admitted by an effect script, an abort requested from the writer —
/// has to survive the tree being mid-restart, where addressing a named
/// process raises rather than returning. Doing it on a process that may
/// die keeps the caller alive; waiting for the reply keeps the action
/// ordered before whatever the caller does next.
///
/// ## Examples
///
/// ```gleam
/// // control.attempt(fn() { api.steer_quietly(rt, message) }, within_ms: 1000)
/// ```
///
pub fn attempt(action: fn() -> a, within_ms within_ms: Int) -> Option(a) {
  let reply: Subject(a) = process.new_subject()
  let pid: Pid = process.spawn_unlinked(fn() { process.send(reply, action()) })
  case process.receive(reply, within_ms) {
    Ok(value) -> Some(value)
    Error(Nil) -> {
      process.kill(pid)
      None
    }
  }
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

/// Whether no post-commit seam is still running.
///
/// A commit becomes visible in the store before the writer runs the seam
/// that a crash schedule fires from, so a runner that took the terminal
/// result the moment it appeared could end a run while the fault aimed
/// at its last commit was still queued behind an intervention. Waiting
/// for the seam is what makes a commit-indexed fault's chance to fire
/// part of the run rather than a race against the observer.
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
