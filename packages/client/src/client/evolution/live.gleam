//// A session's custody of promoted executable generations.
////
//// The owner decides which generation a call may use and when a replacement
//// may begin. It never runs a tool. A caller asks for a lease, runs its whole
//// before-tool, tool and after-tool fold on its own process against the
//// generation the lease names, and returns the lease when it finishes. A
//// replacement, a publication or a retirement waits until every outstanding
//// lease has been returned, so no call runs against a generation that is
//// being replaced or torn down, and calls do not wait for one another.
////
//// Each generation keeps callable schema, implementation, policy and hook
//// bus in one immutable value, and a lease carries that value to the caller.
//// Native retirement must succeed before a central selection is committed.
//// A failed witness retains custody and forbids additional staging.
////
//// ## Flow
////
//// `run` → `leased` → `lease` → `leasing` → `released` → `replacing`
////
//// 1. `run`, `fold`, `invoke` and `execute` each wrap their work in `leased`,
////    which asks the owner for a lease, runs the work on the caller and then
////    returns the lease.
//// 2. `lease` sends one request to the owner and treats silence as a refusal,
////    returning the request's identity so a late grant cannot strand custody.
//// 3. `leasing` admits the request on the owner when no replacement is
////    waiting, revalidates the active generation, and monitors the caller.
//// 4. `released` runs when the caller returns the lease or dies, and opens
////    the owner again once the last lease is gone.
//// 5. `replacing` holds an activation or a close until that moment, by
////    postponing it and refusing new leases meanwhile.
//// 6. `notice` queues a notify-only hook for `notify`, a runner that takes
////    one lease per notice, in arrival order.
////
//// ## Admission, not execution, is bounded
////
//// The `waiting` argument of `run`, `fold`, `invoke` and `execute` bounds
//// only how long a caller waits to be admitted. A lease is granted before the
//// deadline or refused, and a call that runs longer than the deadline still
//// returns its own result. While a replacement waits for a long call, new
//// calls queue behind the replacement until their own deadlines pass.
////
//// A holder must not ask for a second lease while it holds one: when a
//// replacement is waiting, the second request queues behind it while the
//// replacement waits for the first, and only the deadline ends the stalemate.
//// The same holds across processes. A holder must not block on a process that
//// will need a lease, because the replacement waits for the holder and the
//// process waits for the replacement. A subagent wait is therefore not leased,
//// and `strand.wait` inside `code_mode` is bounded only by its own 300 second
//// deadline. A future capability that reaches an evolution operation from
//// inside a running call has to take its generation from the enclosing lease.
////
//// The admission deadline is read from the session clock. A frozen clock
//// never expires a request, so a request queued behind a replacement is
//// granted even after its caller gave up and holds the lease until that
//// caller exits; tests that queue requests use a ticking clock.
////
//// After this change the owner runs no work at all: tools, hook folds,
//// invocations, programs, author tests and snapshots are all leased, and the
//// owner answers only admission, release, catalogue, retention, recovery,
//// activation and close.
////
//// ## Weft
////
//// The owner is a `weft/state_machine`. `Open` admits leases. `Draining` is
//// entered when an activation or close arrives while leases are outstanding;
//// it postpones both that message and every later lease request, and the
//// release of the last lease moves the machine back to `Open`, which replays
//// them in arrival order. The ledger of monitored holders is a plain list
//// because weft has no primitive that monitors a pre-existing pid from inside
//// a machine; `docs/weft.md` records the gap.
////
//// <!-- transitions: live.Phase -->
////
//// | state | lease | release or holder death | activate or close |
//// | --- | --- | --- | --- |
//// | `Open` | granted, or refused when expired or custody is retained | the last release stays `Open` | runs at once when no lease is held, else `Draining` with the message postponed |
//// | `Draining` | postponed | the last release returns to `Open` and replays the postponed messages | postponed again |

import broker/internal/call
import client/evolution/record
import client/evolution/retirement
import client/evolution/store
import client/extension/archive
import client/extension/hooks
import core/clock.{type Clock}
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process.{type Pid, type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import runtime/effects
import tools/tool.{type Ctx, type Tool, type ToolOutcome}
import weft/actor
import weft/state_machine as sm

/// One complete prepared version and its native cleanup witness.
pub type Generation {
  Generation(
    /// The exact catalogue selection this version will implement.
    selection: record.Selection,
    /// The native activation mechanism, separate from the artifact generation.
    mode: Mode,
    /// The immutable callable declarations and implementations.
    tools: List(Tool),
    /// The promoted hooks, separate from installed native hooks.
    hooks: Option(hooks.Bus),
    /// Stops hosts and proves orderly dedicated executor/pool retirement.
    retire: retirement.Task,
    /// Revalidates current approval, revocation, selection and compatibility.
    validate: fn() -> Result(Nil, store.Refusal),
    /// Bounded native helper census for the dedicated generation plane.
    inventory: fn() -> Result(JsonValue, String),
  )
}

/// The native activation mechanism admitted for this generation.
pub type Mode {
  /// Ordinary extensions replace their persistent satellite.
  ReplacementOnly

  /// Compatible opted-in code migrates the same jailed state owner.
  Stateful(
    prepare: fn(record.Selection) -> Result(PreparedUpgrade, store.Refusal),
  )
}

/// A state migration awaiting the central generation-fenced selection CAS.
pub type PreparedUpgrade {
  PreparedUpgrade(
    /// The successor declarations share the predecessor's native resource owner.
    generation: Generation,
    /// Publishes or reconciles the exact committed transition receipt.
    publish: fn() -> Result(Nil, store.Refusal),
    /// Compensates an unpublished transition and resumes the old callbacks.
    abort: fn() -> Result(Nil, store.Refusal),
  )
}

/// Only the native assembly can provide staging and adoption capabilities.
pub type Config {
  Config(
    /// Session clock used for queued request expiry.
    clock: Clock,
    /// Builds and starts one approved immutable candidate's isolated plane.
    stage: fn(record.Selection) -> Result(Generation, store.Refusal),
    /// Records the idempotent session adoption audit before publication.
    adopt: fn(record.Selection) -> Result(Nil, store.Refusal),
    /// Rebuilds the central committed selection after a crash or stale CAS.
    recover: fn() -> Result(Option(Generation), store.Refusal),
  )
}

/// A finite transition request; expiry survives mailbox queueing.
pub type Transition {
  Transition(
    /// Caller identity for resolving a lost acknowledgement.
    request_id: String,
    /// Absolute clock deadline after which publication is forbidden.
    expires_at: Int,
    /// Exact approved candidate and expected next generation.
    selection: record.Selection,
    /// Performs the catalogue approval/revocation/selection CAS.
    commit: fn() -> Result(record.Selection, store.Refusal),
    /// Reads the exact durable request receipt after an uncertain CAS reply.
    reconcile: fn() -> Result(Option(record.Selection), store.Refusal),
  )
}

/// The owner's two phases; the table in the module doc says what each does.
type Phase {
  /// Leases are admitted, and a replacement runs once none are held.
  Open

  /// A replacement is waiting for the last lease, so new requests queue.
  Draining
}

/// Why a caller did not receive a lease.
type Denial {
  /// The request's admission deadline passed before the owner reached it.
  Expired

  /// Native custody is retained, so no generation is callable.
  Retained

  /// The owner did not answer within the caller's admission deadline.
  Silent

  /// The owner has stopped.
  Gone
}

/// A granted lease: the generation the caller may use until it returns it.
type Granted {
  Granted(
    /// The identity the caller returns the lease under.
    id: Reference,
    /// The published generation, whether or not it still validates.
    active: Option(Generation),
    /// Revalidation of that generation at the moment of admission.
    validation: Result(Nil, store.Refusal),
  )
}

/// One outstanding lease on the owner's ledger.
type Held {
  Held(
    /// The caller-chosen identity of this lease.
    id: Reference,
    /// Fires when the holder dies without returning the lease.
    monitor: process.Monitor,
  )
}

/// The generation owner's sealed message vocabulary.
pub opaque type Message {
  Activate(Transition, Subject(Result(record.Selection, store.Refusal)))
  Lease(Reference, Pid, Int, Subject(Result(Granted, Denial)))
  Release(Reference)
  Abandoned(process.Down)
  Catalogue(Subject(Result(Option(Generation), store.Refusal)))
  Retain(retirement.Task, Subject(Nil))
  Recover(Subject(Result(Nil, store.Refusal)))
  Close(Subject(Result(Nil, store.Refusal)))
}

/// The notice runner's sealed message vocabulary.
pub opaque type Notification {
  Notify(fn(Option(Generation)) -> Nil)
  Stop
}

/// An opaque subject; callers cannot bypass version or expiry checks.
pub opaque type Live {
  Live(subject: Subject(Message), clock: Clock, notices: Subject(Notification))
}

type State {
  State(
    config: Config,
    active: Option(Generation),
    held: List(Generation),
    pending: List(retirement.Task),
    leases: List(Held),
  )
}

/// The longest a queued notice waits for admission before it is dropped.
const notice_admission_ms = 60_000

/// Starts with no executable generation and no helper allocation.
///
/// ## Examples
///
/// ```gleam
/// // live.start(config)
/// ```
///
pub fn start(config: Config) -> Result(Live, actor.StartError) {
  use owner <- result.try(
    sm.new_with_initialiser(1000, fn(subject) {
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(Abandoned)
      sm.initialised(
        Open,
        State(config:, active: None, held: [], pending: [], leases: []),
      )
      |> sm.selecting(selector)
      |> sm.returning(subject)
      |> Ok
    })
    |> sm.on_event(handle)
    |> sm.start,
  )

  // The runner is a peer of the owner rather than part of it, so a slow
  // tracer never occupies the owner's mailbox. It holds a handle on the owner
  // only to ask for leases.
  use runner <- result.map(
    actor.new_with_initialiser(1000, fn(self) {
      actor.initialised(Live(owner.data, config.clock, self))
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(notify)
    |> actor.start,
  )
  Live(subject: owner.data, clock: config.clock, notices: runner.data)
}

/// Stages, retires the predecessor, commits selection, audits and publishes.
///
/// The activation waits until every outstanding lease has been returned.
///
/// ## Examples
///
/// ```gleam
/// // live.activate(owner, transition, waiting: 60_000)
/// ```
///
pub fn activate(
  owner: Live,
  transition: Transition,
  waiting waiting: Int,
) -> Result(record.Selection, store.Refusal) {
  call.try_call(owner.subject, waiting:, sending: fn(reply) {
    Activate(transition, reply)
  })
  |> result.replace_error(store.Busy)
  |> result.flatten
}

/// Returns the currently published generation, refusing stranded custody.
///
/// ## Examples
///
/// ```gleam
/// // live.catalogue(owner)
/// ```
///
pub fn catalogue(owner: Live) -> Result(Option(Generation), store.Refusal) {
  call.try_call(owner.subject, waiting: 1000, sending: Catalogue)
  |> result.replace_error(store.Busy)
  |> result.flatten
}

/// Invokes precisely the advertised immutable candidate and generation.
///
/// The invocation runs on the caller under a lease. `waiting` bounds only
/// admission to that lease, not the invocation.
///
/// ## Examples
///
/// ```gleam
/// // live.invoke(owner, id, generation, name, ctx, args, 60_000)
/// ```
///
pub fn invoke(
  owner: Live,
  id: String,
  generation: Int,
  name: String,
  ctx: Ctx,
  args: JsonValue,
  waiting: Int,
) -> ToolOutcome {
  leased(
    owner,
    waiting,
    fn(denial) {
      case denial {
        Expired -> tool.failure("Busy: invocation expired before admission")
        Retained ->
          tool.failure("CleanupUnconfirmed: generation custody is retained")
        Silent | Gone ->
          tool.failure("Busy: the generation owner did not answer")
      }
    },
    fn(granted) {
      case granted.validation {
        Error(error) -> tool.failure(store.describe(error))
        Ok(Nil) -> invoked(granted.active, id, generation, name, ctx, args)
      }
    },
  )
}

/// Executes a whole hook fold on the caller, under a lease.
///
/// The fold captures only its predecessor slot and inputs, never an Effects
/// sibling record. A fold that is not admitted in time yields the caller's
/// supplied fallback. `waiting` bounds only admission, not the fold.
///
/// ## Examples
///
/// ```gleam
/// // live.fold(owner, fn(generation) { ... }, fallback, 60_000)
/// ```
///
pub fn fold(
  owner: Live,
  work: fn(Option(Generation)) -> JsonValue,
  fallback: JsonValue,
  waiting: Int,
) -> JsonValue {
  leased(owner, waiting, fn(_denial) { fallback }, fn(granted) {
    work(usable(granted))
  })
}

/// Runs a complete before-tool, invocation and after-tool fold on the caller.
///
/// The caller holds a lease for the whole fold, so a replacement cannot begin
/// under it, yet other calls run beside it. `waiting` bounds only admission:
/// a tool that runs longer returns its own result.
///
/// ## Examples
///
/// ```gleam
/// // live.run(owner, work, 60_000)
/// ```
///
pub fn run(
  owner: Live,
  work: fn(Option(Generation)) -> effects.ToolOutcome,
  waiting: Int,
) -> effects.ToolOutcome {
  leased(
    owner,
    waiting,
    fn(denial) {
      case denial {
        Expired -> effects.ToolFailed("Busy: queued fold expired")
        Retained ->
          effects.ToolFailed("CleanupUnconfirmed: retained native custody")
        Silent | Gone ->
          effects.ToolFailed("Busy: generation owner did not answer")
      }
    },
    fn(granted) { work(usable(granted)) },
  )
}

/// Proves cleanup, retaining every unconfirmed generation for a later retry.
///
/// ## Examples
///
/// ```gleam
/// // live.close(owner, 30_000)
/// ```
///
pub fn close(owner: Live, waiting: Int) -> Result(Nil, store.Refusal) {
  call.try_call(owner.subject, waiting:, sending: Close)
  |> result.replace_error(store.Busy)
  |> result.flatten
  |> result.map(fn(closed) {
    process.send(owner.notices, Stop)
    closed
  })
  |> result.map_error(fn(error) {
    // The actor owns its replacement tasks. A caller retries through that
    // owner, rather than independently performing a copy of its obligations.
    store.CleanupUnconfirmed(
      store.describe(error),
      retirement.repeat(fn() {
        close(owner, waiting) |> result.map_error(store.describe)
      }),
    )
  })
}

// Every tool-shaped call goes through here. The lease is returned after the
// work, and a holder that dies instead is found by the owner's monitor, so
// the work itself needs no cleanup path.
/// Runs caller work while holding a generation lease, then returns that lease to the owner.
fn leased(
  owner: Live,
  waiting: Int,
  refused: fn(Denial) -> a,
  work: fn(Granted) -> a,
) -> a {
  // The lease result decides whether to refuse the call or run it under custody.
  case lease(owner, waiting) {
    Error(denial) -> refused(denial)
    Ok(granted) -> {
      let answer = work(granted)
      process.send(owner.subject, Release(granted.id))
      answer
    }
  }
}

// The request names itself so that a caller which gave up can still return
// it. A grant that crosses the caller's timeout is returned here rather than
// held until the caller exits, and a request still queued behind a
// replacement is refused as expired when its turn comes.
/// Requests a bounded lease and returns a grant that crosses the caller timeout to the owner.
fn lease(owner: Live, waiting: Int) -> Result(Granted, Denial) {
  let id = reference.new()
  let #(now, _) = clock.read(owner.clock)

  // A timeout returns the outstanding request instead of leaving its grant unowned.
  case
    call.try_call(owner.subject, waiting:, sending: fn(reply) {
      Lease(id, process.self(), now + waiting, reply)
    })
  {
    Ok(answer) -> answer
    Error(call.NoReply) -> {
      process.send(owner.subject, Release(id))
      Error(Silent)
    }
    Error(call.CalleeGone) -> Error(Gone)
  }
}

// A generation that no longer validates is not served, but the call still
// runs, without promoted hooks, exactly as it did before the generation was
// published.
fn usable(granted: Granted) -> Option(Generation) {
  case granted.validation {
    Ok(Nil) -> granted.active
    Error(_) -> None
  }
}

// One notice at a time, in arrival order, each under its own lease. A notice
// that cannot be admitted, or whose generation no longer validates, is
// dropped, as it was when the owner ran notices inline.
/// Processes one notice at a time under a lease so replacement cannot overtake active hook work.
fn notify(
  runner: Live,
  message: Notification,
) -> actor.Next(Live, Notification) {
  case message {
    Stop -> actor.stop()
    Notify(work) ->
      case lease(runner, notice_admission_ms) {
        Error(Gone) -> actor.stop()
        Error(Expired) | Error(Retained) | Error(Silent) ->
          actor.continue(runner)
        Ok(granted) -> {
          // The notice is either stopped, dropped, or run under a validated generation lease.
          case granted.validation {
            Ok(Nil) -> work(granted.active)
            Error(_) -> Nil
          }

          process.send(runner.subject, Release(granted.id))
          actor.continue(runner)
        }
      }
  }
}

/// Applies lease, replacement, retirement, and recovery messages to the owner state machine.
fn handle(
  phase: Phase,
  state: State,
  message: Message,
) -> sm.Next(Phase, State, Message) {
  // Dispatch each owner message to the transition that preserves its custody rules.
  case message {
    Lease(id, holder, expires, reply) ->
      leasing(phase, state, id, holder, expires, reply)
    Release(id) -> {
      let #(returned, remaining) =
        list.partition(state.leases, fn(held) { held.id == id })
      list.each(returned, fn(held) { process.demonitor_process(held.monitor) })
      released(state, remaining)
    }
    Abandoned(down) -> {
      // Dispatch each owner message to the transition that preserves its custody rules.
      let monitor = case down {
        process.ProcessDown(monitor:, ..) | process.PortDown(monitor:, ..) ->
          monitor
      }

      released(
        state,
        list.filter(state.leases, fn(held) { held.monitor != monitor }),
      )
    }
    Activate(transition, reply) ->
      replacing(state, fn(state) {
        let #(next, answer) = changing(state, transition)
        process.send(reply, answer)
        sm.keep(next)
      })
    Close(reply) -> replacing(state, fn(state) { closing(state, reply) })
    Catalogue(reply) -> {
      // Dispatch each owner message to the transition that preserves its custody rules.
      let answer = case state.held, state.pending {
        [], [] -> Ok(state.active)
        _, [_, ..] | [_, ..], [] ->
          Error(cleanup_refusal("generation custody remains", state.held))
      }

      process.send(reply, answer)
      sm.keep(state)
    }
    Retain(retire, reply) -> {
      process.send(reply, Nil)
      sm.keep(State(..state, pending: [retire, ..state.pending]))
    }
    Recover(reply) -> {
      let #(next, answer) = recovered(state)
      process.send(reply, answer)
      sm.keep(next)
    }
  }
}

// A lease request is admitted only while the machine is `Open`. While
// `Draining` it is postponed, which is what keeps a steady stream of calls
// from starving the replacement that is waiting for them. Admission
// revalidates the active generation, because the lease promises the caller a
// generation that is still approved, and it monitors the holder so that a
// caller which dies mid-call cannot keep a replacement waiting forever.
/// Admits leases only while open and postpones them while a replacement drains existing calls.
fn leasing(
  phase: Phase,
  state: State,
  id: Reference,
  holder: Pid,
  expires: Int,
  reply: Subject(Result(Granted, Denial)),
) -> sm.Next(Phase, State, Message) {
  // Only an open phase admits a lease; draining postpones requests until replacement settles.
  case phase {
    Draining -> sm.keep(state) |> sm.postpone
    Open -> {
      let #(next, validation) = validate_active(state)

      // Only an open phase admits a lease; draining postpones requests until replacement settles.
      let admission = case
        expired(next.config.clock, expires),
        next.held,
        next.pending
      {
        True, _, _ -> Error(Expired)
        False, [], [] -> Ok(Granted(id:, active: next.active, validation:))
        False, _, _ -> Error(Retained)
      }

      // Only an open phase admits a lease; draining postpones requests until replacement settles.
      let admitted = case admission {
        Ok(_) ->
          State(..next, leases: [
            Held(id:, monitor: process.monitor(holder)),
            ..next.leases
          ])
        Error(_) -> next
      }

      process.send(reply, admission)
      sm.keep(admitted)
    }
  }
}

// Returning a lease, or the holder dying, shrinks the ledger. Moving to
// `Open` when the ledger empties is the moment postponed activations and
// leases replay, in the order they arrived; from `Open` it is not a state
// change, so it replays nothing.
/// Updates the lease ledger and reopens the machine when the final holder leaves.
fn released(
  state: State,
  leases: List(Held),
) -> sm.Next(Phase, State, Message) {
  let next = State(..state, leases:)

  // This branch resolves the released operation while preserving generation custody.
  case leases {
    [] -> sm.transition(to: Open, data: next)
    [_, ..] -> sm.keep(next)
  }
}

// A replacement or retirement must not overlap a call that holds a
// generation. With leases outstanding the message is postponed and the
// machine starts to drain; otherwise it runs at once.
/// Waits for every active lease before starting a generation replacement or retirement.
fn replacing(
  state: State,
  replace: fn(State) -> sm.Next(Phase, State, Message),
) -> sm.Next(Phase, State, Message) {
  case state.leases {
    [_, ..] -> sm.transition(to: Draining, data: state) |> sm.postpone
    [] -> replace(state)
  }
}

/// Retires active and pending generations, stopping only after cleanup is confirmed.
fn closing(
  state: State,
  reply: Subject(Result(Nil, store.Refusal)),
) -> sm.Next(Phase, State, Message) {
  let held = list.append(state.held, active_list(state.active))
  let unconfirmed =
    list.filter_map(held, fn(generation) {
      case retirement.perform(generation.retire) {
        Ok(Nil) -> Error(Nil)
        Error(failed) -> Ok(Generation(..generation, retire: failed.retry))
      }
    })
  let pending =
    list.filter_map(state.pending, fn(retire) {
      case retirement.perform(retire) {
        Ok(Nil) -> Error(Nil)
        Error(failed) -> Ok(failed.retry)
      }
    })

  // Deliver the shutdown answer and transition to the target state.
  let answer = case unconfirmed, pending {
    [], [] -> Ok(Nil)
    _, [_, ..] | [_, ..], [] ->
      Error(cleanup_refusal("native retirement did not confirm", unconfirmed))
  }

  process.send(reply, answer)

  // This branch resolves the closing operation while preserving generation custody.
  case answer {
    Ok(Nil) -> sm.stop()
    Error(_) ->
      sm.keep(State(..state, active: None, held: unconfirmed, pending:))
  }
}

/// Stages a replacement only when custody is clean and the request has not expired.
fn changing(
  state: State,
  transition: Transition,
) -> #(State, Result(record.Selection, store.Refusal)) {
  case
    list.is_empty(state.held) && list.is_empty(state.pending),
    expired(state.config.clock, transition.expires_at)
  {
    False, _ -> #(
      state,
      Error(cleanup_refusal("retained generation forbids staging", state.held)),
    )
    True, True -> #(state, Error(store.Busy))
    True, False ->
      case state.active {
        Some(previous) if previous.selection.name != transition.selection.name -> #(
          state,
          Error(store.Bounds("one executable evolution slot per session")),
        )
        Some(previous) -> {
          case previous.mode {
            ReplacementOnly ->
              staged(
                state,
                transition,
                state.config.stage(transition.selection),
              )
            Stateful(prepare) ->
              in_place(state, transition, prepare(transition.selection))
          }
        }
        None ->
          staged(state, transition, state.config.stage(transition.selection))
      }
  }
}

/// Checks a staged generation deadline before retiring its predecessor or discarding it.
fn staged(
  state: State,
  transition: Transition,
  staged: Result(Generation, store.Refusal),
) -> #(State, Result(record.Selection, store.Refusal)) {
  case staged {
    Error(reason) -> #(retained_refusal(state, reason), Error(reason))
    Ok(candidate) -> {
      case expired(state.config.clock, transition.expires_at) {
        True -> discard(state, candidate, store.Busy)
        False -> retiring(state, transition, candidate)
      }
    }
  }
}

/// Retires the predecessor before committing the staged generation and records failed cleanup.
fn retiring(
  state: State,
  transition: Transition,
  candidate: Generation,
) -> #(State, Result(record.Selection, store.Refusal)) {
  // This branch resolves the retiring operation while preserving generation custody.
  let retired = case state.active {
    None -> Ok(Nil)
    Some(previous) -> retirement.perform(previous.retire)
  }

  // This branch resolves the retiring operation while preserving generation custody.
  case retired {
    Error(failed) -> {
      let held =
        list.map(active_list(state.active), fn(previous) {
          Generation(..previous, retire: failed.retry)
        })

      // The predecessor is already retained in `held`. Its refusal transports
      // the witness to the caller without adding a second native obligation.
      discard_owned(
        State(..state, active: None, held:),
        candidate,
        cleanup_refusal(failed.reason, held),
      )
    }
    Ok(Nil) ->
      committed(
        State(..state, active: None),
        transition,
        candidate,
        case expired(state.config.clock, transition.expires_at) {
          True -> Error(store.Busy)
          False -> transition.commit()
        },
      )
  }
}

/// Publishes a successfully committed selection or recovers the previous generation on failure.
fn committed(
  state: State,
  transition: Transition,
  candidate: Generation,
  committed: Result(record.Selection, store.Refusal),
) -> #(State, Result(record.Selection, store.Refusal)) {
  case committed {
    Error(reason) -> recover_previous(discard(state, candidate, reason))
    Ok(selection) ->
      published(
        state,
        transition,
        candidate,
        selection,
        state.config.adopt(selection),
      )
  }
}

/// Completes adoption after central selection commits, retaining the candidate if audit fails.
fn published(
  state: State,
  _transition: Transition,
  candidate: Generation,
  selection: record.Selection,
  audited: Result(Nil, store.Refusal),
) -> #(State, Result(record.Selection, store.Refusal)) {
  // Successful central CAS ends deadline admission. The committed selection
  // must complete its adoption even if that durable audit crosses the deadline.
  case audited {
    Error(reason) -> discard(state, candidate, reason)
    Ok(Nil) -> #(
      State(..state, active: Some(Generation(..candidate, selection:))),
      Ok(selection),
    )
  }
}

/// Discards a prepared generation while preserving any cleanup refusal in owner custody.
fn discard(
  state: State,
  candidate: Generation,
  reason: store.Refusal,
) -> #(State, Result(record.Selection, store.Refusal)) {
  discard_owned(retained_refusal(state, reason), candidate, reason)
}

// Internal generation custody stays in `held`; only a foreign refusal belongs
// in `pending`. Removing the prepared successor must preserve that distinction.
/// Removes a prepared generation and records any failed retirement as held custody.
fn discard_owned(
  state: State,
  candidate: Generation,
  reason: store.Refusal,
) -> #(State, Result(record.Selection, store.Refusal)) {
  // This branch resolves the discard_owned operation while preserving generation custody.
  case retirement.perform(candidate.retire) {
    Ok(Nil) -> #(state, Error(reason))
    Error(cleanup) -> {
      let held = [Generation(..candidate, retire: cleanup.retry), ..state.held]
      #(State(..state, held:), Error(cleanup_refusal(cleanup.reason, held)))
    }
  }
}

/// Dispatches a tool call only when an active approved generation exists.
fn invoked(
  active: Option(Generation),
  id: String,
  generation: Int,
  name: String,
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  case active {
    None -> tool.failure("NotApproved: no promoted generation is active")
    Some(current) -> invoke_exact(current, id, generation, name, ctx, args)
  }
}

/// Checks the discovered candidate identity and generation before resolving its declared tool.
fn invoke_exact(
  current: Generation,
  id: String,
  generation: Int,
  name: String,
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  case
    record.id_string(current.selection.candidate_id) == id
    && current.selection.generation == generation
  {
    False ->
      tool.failure("Stale: discover the current candidate and generation")
    True ->
      case list.find(current.tools, fn(one) { one.name == name }) {
        Error(Nil) ->
          tool.failure("Unknown: this candidate declares no such tool")
        Ok(declared) -> promoted_call(current, declared, ctx, args)
      }
  }
}

/// Tests whether the configured clock has reached a request deadline.
fn expired(clock: Clock, deadline: Int) -> Bool {
  let #(now, _) = clock.read(clock)
  now >= deadline
}

// Both hook phases use the same captured value as the callable. The generic
// invocation wrapper never reacquires the owner while this callback runs.
/// Runs a declared tool directly or routes it through the active generation hooks.
fn promoted_call(
  current: Generation,
  declared: Tool,
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  case current.hooks {
    None -> declared.run(ctx, args)
    Some(bus) ->
      gated_call(
        bus,
        declared,
        ctx,
        args,
        hooks.gate(bus, ctx.op_id, declared.name, args, ctx.source_index),
      )
  }
}

/// Applies the hook verdict before execution and folds tool output after an allowed call.
fn gated_call(
  bus: hooks.Bus,
  declared: Tool,
  ctx: Ctx,
  args: JsonValue,
  verdict: hooks.Verdict,
) -> ToolOutcome {
  // A blocking hook refuses before execution; an allowed call folds the result afterward.
  case verdict {
    hooks.Block(extension:, reason:) ->
      tool.failure(extension <> " blocked " <> declared.name <> ": " <> reason)
    hooks.Allow -> {
      let outcome = declared.run(ctx, args)
      let reply = tool.to_result_message(outcome, "evolution", declared.name, 0)

      // A blocking hook refuses before execution; an allowed call folds the result afterward.
      case hooks.fold_tool_result(bus, reply) {
        message.ToolResultMessage(content:, ..) ->
          tool.ToolOutcome(..outcome, content:)
        message.UserMessage(..)
        | message.AssistantMessage(..)
        | message.CustomMessage(..) -> outcome
      }
    }
  }
}

/// Combines held generation retirement tasks into one refusal carrying cleanup authority.
fn cleanup_refusal(reason: String, held: List(Generation)) -> store.Refusal {
  let task =
    list.fold(held, retirement.done(), fn(task, generation) {
      retirement.sequence(task, generation.retire)
    })
  store.CleanupUnconfirmed(reason, task)
}

/// Retains a failed catalogue retirement capability before wording its error.
///
/// ## Examples
///
/// ```gleam
/// // live.retain(owner, refusal)
/// ```
///
pub fn retain(owner: Live, refusal: store.Refusal) -> Nil {
  // This branch resolves the cleanup_refusal operation while preserving generation custody.
  case refusal {
    store.CleanupUnconfirmed(_, retire) -> {
      let _ =
        call.try_call(owner.subject, waiting: 1000, sending: fn(reply) {
          Retain(retire, reply)
        })
      Nil
    }
    _ordinary -> Nil
  }
}

/// Reconciles committed central selection and its audit before serving calls.
///
/// ## Examples
///
/// ```gleam
/// // live.recover(owner, 120_000)
/// ```
///
pub fn recover(owner: Live, waiting: Int) -> Result(Nil, store.Refusal) {
  call.try_call(owner.subject, waiting:, sending: Recover)
  |> result.replace_error(store.Busy)
  |> result.flatten
}

/// Moves cleanup authority from a refusal into pending owner custody.
fn retained_refusal(state: State, refusal: store.Refusal) -> State {
  case refusal {
    store.CleanupUnconfirmed(_, retire) ->
      State(..state, pending: [retire, ..state.pending])
    _ordinary -> state
  }
}

/// Restores the active generation only when no other generation custody remains.
fn recovered(state: State) -> #(State, Result(Nil, store.Refusal)) {
  case state.active, state.held, state.pending {
    Some(_), _, _ -> #(state, Ok(Nil))
    None, [], [] ->
      case state.config.recover() {
        Ok(active) -> #(State(..state, active:), Ok(Nil))
        Error(reason) -> #(retained_refusal(state, reason), Error(reason))
      }
    None, [_, ..], _ | None, [], [_, ..] -> #(
      state,
      Error(cleanup_refusal("retained custody forbids recovery", state.held)),
    )
  }
}

fn active_list(active: Option(Generation)) -> List(Generation) {
  case active {
    None -> []
    Some(generation) -> [generation]
  }
}

/// Attempts to restore the prior generation after discarding a failed successor.
fn recover_previous(
  discarded: #(State, Result(record.Selection, store.Refusal)),
) -> #(State, Result(record.Selection, store.Refusal)) {
  let #(state, answer) = discarded
  let #(next, _) = recovered(state)
  #(next, answer)
}

/// Evaluates immutable author tests on the caller, under a lease.
///
/// Author tests do not touch the serving generation, but they allocate native
/// helpers, so they are admitted only while custody is clean. A refusal that
/// carries cleanup authority is retained by the owner before it is returned.
/// The test runs for as long as it needs; the 120 second wait bounds
/// admission only, and other calls proceed beside it.
///
/// ## Examples
///
/// `live.evaluate(owner, run_tests)` retains an uncertain cleanup before replying.
pub fn evaluate(
  owner: Live,
  work: fn() -> Result(record.Evidence, store.Refusal),
) -> Result(record.Evidence, store.Refusal) {
  leased(owner, 120_000, fn(_denial) { Error(store.Busy) }, fn(_granted) {
    retained(owner, work())
  })
}

// A failed piece of leased work may carry a cleanup witness. The owner keeps
// it before the caller learns of the failure, so that no later allocation is
// admitted on the strength of a reply that has not yet been read.
/// Keeps refusal cleanup authority in the owner before returning the original outcome.
fn retained(
  owner: Live,
  outcome: Result(a, store.Refusal),
) -> Result(a, store.Refusal) {
  // Successful work leaves custody unchanged; a refusal is retained before being returned.
  case outcome {
    Ok(_) -> outcome
    Error(error) -> {
      retain(owner, error)
      outcome
    }
  }
}

/// Revalidates the current generation and retains cleanup authority when validation fails.
fn validate_active(state: State) -> #(State, Result(Nil, store.Refusal)) {
  // No active generation needs no validation; a failed check retains its cleanup witness.
  case state.active {
    None -> #(state, Ok(Nil))
    Some(current) -> {
      let checked = current.validate()

      // No active generation needs no validation; a failed check retains its cleanup witness.
      case checked {
        Error(error) -> #(retained_refusal(state, error), checked)
        Ok(_) -> #(state, checked)
      }
    }
  }
}

/// Queues a notify-only hook without blocking its strand driver.
///
/// A runner takes one lease per notice, in arrival order, so a slow tracer
/// delays only later notices and a replacement still waits for the notice
/// that is running.
///
/// ## Examples
///
/// `live.notice(owner, notified)` preserves generation ordering.
pub fn notice(owner: Live, work: fn(Option(Generation)) -> Nil) -> Nil {
  process.send(owner.notices, Notify(work))
}

/// Detaches the generation owner after its cleanup capability is published.
///
/// ## Examples
///
/// `live.detach(owner)` transfers lifetime custody to the instance owner.
pub fn detach(owner: Live) -> Nil {
  [process.subject_owner(owner.subject), process.subject_owner(owner.notices)]
  |> list.each(fn(owned) {
    case owned {
      Ok(pid) -> process.unlink(pid)
      Error(_) -> Nil
    }
  })
}

/// Captures model-authored source on the caller, under a lease.
///
/// Like `evaluate`, it is admitted only while custody is clean and retains a
/// refusal's cleanup authority before returning it.
///
/// ## Examples
///
/// `live.snapshot(owner, capture)` refuses further allocation on lost retirement.
pub fn snapshot(
  owner: Live,
  work: fn() -> Result(archive.Tree, store.Refusal),
) -> Result(archive.Tree, store.Refusal) {
  leased(owner, 120_000, fn(_denial) { Error(store.Busy) }, fn(_granted) {
    retained(owner, work())
  })
}

/// Executes a selected reusable program and its hooks in one generation fold.
///
/// The program runs on the caller under a lease. The 120 second wait bounds
/// admission to the lease, not the program.
///
/// ## Examples
///
/// `live.execute(owner, name, ctx, args, invoke)` preserves the captured hooks.
pub fn execute(
  owner: Live,
  name: String,
  ctx: Ctx,
  args: JsonValue,
  work: fn() -> Result(ToolOutcome, store.Refusal),
) -> ToolOutcome {
  leased(
    owner,
    120_000,
    fn(denial) {
      case denial {
        Expired | Retained -> tool.failure(store.describe(store.Busy))
        Silent | Gone -> tool.failure("Busy: selected program did not settle")
      }
    },
    fn(granted) {
      // No active generation needs no validation; a failed check retains its cleanup witness.
      case execute_with(usable(granted), name, ctx, args, work) {
        Ok(outcome) -> outcome
        Error(error) -> {
          // A refusal may carry cleanup authority, which the owner keeps.
          retain(owner, error)
          tool.failure(store.describe(error))
        }
      }
    },
  )
}

/// Runs work directly without hooks, or applies the captured hook gate and result fold.
fn execute_with(
  active: Option(Generation),
  name: String,
  ctx: Ctx,
  args: JsonValue,
  work: fn() -> Result(ToolOutcome, store.Refusal),
) -> Result(ToolOutcome, store.Refusal) {
  case option.then(active, fn(current) { current.hooks }) {
    None -> work()
    Some(bus) -> {
      // Without hooks the work runs directly; otherwise the hook gate controls execution and folding.
      case hooks.gate(bus, ctx.op_id, name, args, ctx.source_index) {
        hooks.Block(extension:, reason:) ->
          Ok(tool.failure(extension <> " blocked " <> name <> ": " <> reason))
        hooks.Allow -> {
          use outcome <- result.try(work())
          let reply =
            tool.to_result_message(outcome, "evolution", name, ctx.source_index)

          // Without hooks the work runs directly; otherwise the hook gate controls execution and folding.
          case hooks.fold_tool_result(bus, reply) {
            message.ToolResultMessage(content:, ..) ->
              Ok(tool.ToolOutcome(..outcome, content:))
            message.UserMessage(..)
            | message.AssistantMessage(..)
            | message.CustomMessage(..) -> Ok(outcome)
          }
        }
      }
    }
  }
}

/// Commits a prepared stateful upgrade and retains its generation if reconciliation fails.
fn in_place(
  state: State,
  transition: Transition,
  prepared: Result(PreparedUpgrade, store.Refusal),
) -> #(State, Result(record.Selection, store.Refusal)) {
  // A preparation failure retains its cleanup authority; a prepared upgrade follows commit reconciliation.
  case prepared {
    Error(reason) -> #(retained_refusal(state, reason), Error(reason))
    Ok(prepared) -> {
      let committed = transition.commit()

      // A preparation failure retains its cleanup authority; a prepared upgrade follows commit reconciliation.
      let state = case committed {
        Ok(_) -> state
        Error(reason) -> retained_refusal(state, reason)
      }

      // A preparation failure retains its cleanup authority; a prepared upgrade follows commit reconciliation.
      case committed_in_place(transition, committed) {
        Ok(Error(reason)) -> {
          case prepared.abort() {
            Ok(Nil) -> #(state, Error(reason))
            Error(failure) -> #(
              retained_refusal(
                State(..state, active: None, held: active_list(state.active)),
                failure,
              ),
              Error(failure),
            )
          }
        }
        Ok(Ok(selection)) -> publish_in_place(state, prepared, selection)
        Error(reason) -> #(
          retained_refusal(
            State(..state, active: None, held: [prepared.generation]),
            reason,
          ),
          Error(reason),
        )
      }
    }
  }
}

/// Reconciles an uncertain commit acknowledgement before reporting the selection result.
fn committed_in_place(
  transition: Transition,
  committed: Result(record.Selection, store.Refusal),
) -> Result(Result(record.Selection, store.Refusal), store.Refusal) {
  // A lost commit acknowledgement is reconciled before deciding whether publication succeeded.
  case committed {
    Ok(selection) -> Ok(Ok(selection))
    Error(reason) -> {
      use receipt <- result.try(transition.reconcile())

      // A lost commit acknowledgement is reconciled before deciding whether publication succeeded.
      case receipt {
        Some(selection) -> Ok(Ok(selection))
        None -> Ok(Error(reason))
      }
    }
  }
}

/// Publishes and adopts a committed upgrade, retaining it if publication cannot complete.
fn publish_in_place(
  state: State,
  prepared: PreparedUpgrade,
  selection: record.Selection,
) -> #(State, Result(record.Selection, store.Refusal)) {
  let published = {
    use Nil <- result.try(prepared.publish())
    state.config.adopt(selection)
  }

  // Publication failure retains the prepared generation; success adopts the selection.
  case published {
    Error(reason) -> #(
      retained_refusal(
        State(..state, active: None, held: [prepared.generation]),
        reason,
      ),
      Error(reason),
    )
    Ok(Nil) -> #(
      State(
        ..state,
        active: Some(Generation(..prepared.generation, selection:)),
      ),
      Ok(selection),
    )
  }
}
