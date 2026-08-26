//// Parking: what a production tool call does when the broker refuses it
//// on policy (design §5.3, decision D1 on issue #11).
////
//// A policy refusal is the one tool outcome a human can *change*. The
//// broker composes `base ⊕ requirements ⊕ grants` before it reserves
//// anything, so a refusal costs no budget and dispatches no jail — the
//// call is simply standing at a door it is not allowed through, holding
//// the exact diff that would open it. This module is what happens next:
////
////  1. **Raise, always.** Every policy refusal writes a durable,
////     call-scoped escalation record. Whether any record interrupts a
////     person is a *client-surface* decision — the gateway already emits
////     escalation events and lists pending ones in its snapshot — so the
////     runtime records them all and encodes no interruption policy. That
////     keeps approval fatigue tunable in a UI instead of frozen in a
////     deploy.
////  2. **Park, when someone is there to decide.** The refused call is
////     held open rather than settled, and an approval re-clears *the same
////     call* under the widened policy. Parking is what makes a scoped
////     approval spendable at all: the re-clearance carries the same call
////     id the approval was minted against, so there is no id to match up
////     and no retry loop to complete the round trip. A model that read an
////     in-band refusal and retried would arrive under a *new* call id,
////     which the approval can never match.
////  3. **Settle in band, otherwise.** A denial, a decision that never
////     comes, a session with nobody attached, a host that wired no
////     escalation plane — all of them end in the ordinary in-band refusal
////     the model gets today, alongside the record.
////
//// ## Where the waiting happens, and why it is safe there
////
//// The park loop runs on the *tool effect process* — the process the
//// strand driver spawns per call and monitors — never on the driver.
//// That is not an implementation detail: the driver must keep serving
//// `Nudge`, `RequestAbort` and `PollTick` while a call is held, or a
//// human who changes their mind could not abort the very run they are
//// being asked about. It also means the wait needs no timer and leaks no
//// process: the effect process is linked to the driver's reaper, so a
//// driver restart or an abort kills the parked call outright and the
//// driver settles it in band through the ordinary monitor path.
////
//// ## The two deadlines
////
//// A park is bounded by the smaller of the configured window and *the
//// call's own budget deadline*. The second bound is not politeness: the
//// broker's ledger refuses a reservation past `deadline_ms`, so a
//// re-clearance after that instant is a `BudgetRefused`, not a
//// resumption. Holding a call past its own budget would trade an
//// honest "policy refused" for a confusing "deadline passed".
////
//// ## The bootstrap knot
////
//// `api.open` *takes* the `Effects` record and *returns* the `Runtime`,
//// and `Runtime` contains `effects` — so a closure reachable from
//// `Effects` cannot capture the `Runtime`. `client/agency` documents the
//// fix and this module reuses it verbatim: `seam(config)` closes over a
//// process *name*, `start(config, runtime)` stands a one-message holder
//// up under that name after the open, and a refusal arriving before the
//// holder exists (or after it dies) settles in band, which is what the
//// model should see anyway.
////
//// ## Spending, and the two orderings it inherits
////
//// An approval is spent through `runtime/api.consume_escalation`, whose
//// CAS moves the record `Approved -> Consumed` before this module hands
//// the grants to anything — the same consume-before-clear ordering the
//// driver's own clearance path uses, for the same reason: the capability
//// is *exercised* the moment the grants compose into a policy, so the
//// commit that makes it single-use has to win before that moment, not
//// after it. And the record's `CallScope` is checked against the call in
//// hand first, so an approval minted for one call can never widen
//// another. Both directions fail safe: a lost CAS, an unattributable
//// record, a decode failure and a crash all end in the in-band refusal.

import broker/escalation.{type Denial}
import broker/policy.{type Grant}
import client/grants
import core/clock.{type Clock}
import core/ids.{type OpId}
import core/json
import gleam/bit_array
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/string
import runtime/api
import runtime/escalation as durable
import tools/blob
import tools/tool

/// The holder's mailbox: one message, answered with a plain data value.
pub type Message {
  /// Hand back the live runtime. The caller does the work itself.
  Borrow(reply: Subject(api.Runtime))
}

/// How this host escalates.
///
/// Constructor invariants: `name` is the holder's process name, minted
/// before `api.open` and never reused across sessions; `clock` shares the
/// session's time base (spec §0.2, "one clock per session" — the park
/// deadline is compared against a budget deadline computed on the tool
/// side, so clocks whose eras disagree would close every window
/// instantly); `interactive` answers "is anyone there to decide?" and is
/// consulted afresh on every poll, so a client that disconnects mid-park
/// un-parks the call at the next slice; `park_timeout_ms` is the longest
/// a refusal may hold its call, always further clamped by that call's own
/// budget deadline; `poll_interval_ms` is positive; `rest` is the sleep
/// the park loop uses, injected so tests run on logical time;
/// `holder_timeout_ms` bounds the call that borrows the runtime.
pub type Config {
  Config(
    name: Name(Message),
    clock: Clock,
    interactive: fn() -> Bool,
    park_timeout_ms: Int,
    poll_interval_ms: Int,
    rest: fn(Int) -> Nil,
    holder_timeout_ms: Int,
  )
}

/// The default policy: park for at most five minutes, polling every
/// second, and never park at all unless the host says someone is
/// attached.
///
/// Five minutes is a compromise between the two ways this can go wrong.
/// Longer and a call held for a decision nobody is coming back for keeps
/// an exclusive tool's slot and a strand's turn alive well past the point
/// the model could have routed around the refusal; shorter and a human
/// who stepped away from a prompt loses a decision they were going to
/// make. Neither is a safety property — the record survives either way —
/// so a host that knows its operators may set whatever it likes.
///
/// ## Examples
///
/// ```gleam
/// // escalate.default_config(name, clock)
/// ```
///
pub fn default_config(name: Name(Message), clock: Clock) -> Config {
  Config(
    name:,
    clock:,
    interactive: fn() { False },
    park_timeout_ms: 300_000,
    poll_interval_ms: 1000,
    rest: process.sleep,
    holder_timeout_ms: 5000,
  )
}

/// Starts the holder under `config.name`, after `api.open` has returned
/// the runtime it holds.
///
/// Deliberately unsupervised, for the same reason the Agency's holder is:
/// the boot process links it and a death there ends the server rather
/// than leaving a session that records no escalations and quietly stops
/// parking.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_holder) = escalate.start(config, runtime)
/// ```
///
pub fn start(
  config: Config,
  runtime: api.Runtime,
) -> actor.StartResult(Subject(Message)) {
  actor.new(runtime)
  |> actor.on_message(fn(state, message) {
    case message {
      Borrow(reply:) -> {
        process.send(reply, state)
        actor.continue(state)
      }
    }
  })
  |> actor.named(config.name)
  |> actor.start
}

/// One policy-refused call, as the seam sees it.
///
/// Constructor invariants: every coordinate is the *driver's* — the tool
/// context carries them from `effects.ToolRun`, never from anything the
/// model supplied — so the scope an approval is attributed to names one
/// real call in the tree; `denial` is the broker's structured refusal,
/// whose `wanted` is the exact diff an approval may grant; `deadline_ms`
/// is the call's own budget deadline, past which no re-clearance can
/// reserve.
pub type Refused {
  Refused(
    operation: OpId,
    strand: String,
    step_id: String,
    source_index: Int,
    call_id: String,
    tool: String,
    denial: Denial,
    deadline_ms: Int,
  )
}

/// What the seam decided about a refused call.
pub type Decision {
  /// Nothing to spend: settle the refusal in band, as the harness always
  /// has. The durable record (if one was written) stands as the audit
  /// line and the passive queue entry.
  Settle
  /// An approval was consumed for exactly this call. Re-clear it once
  /// under these additional grants.
  Resume(grants: List(Grant))
}

/// The escalation seam, as production wiring holds it.
pub type Escalations {
  Escalations(refused: fn(Refused) -> Decision)
}

/// A seam that escalates nothing: every refusal settles in band exactly
/// as it did before any of this existed. The default for a host with no
/// escalation plane, and for tests that are about something else.
///
/// ## Examples
///
/// ```gleam
/// assert escalate.none().refused(refused) == escalate.Settle
/// ```
///
pub fn none() -> Escalations {
  Escalations(refused: fn(_refused) { Settle })
}

/// The escalation seam, closed over the holder's *name* rather than over
/// a runtime that does not exist yet. Safe to build before `api.open`.
///
/// ## Examples
///
/// ```gleam
/// // wiring.Config(..config, escalations: escalate.seam(config))
/// ```
///
pub fn seam(config: Config) -> Escalations {
  Escalations(refused: fn(refused) { decide(config, refused) })
}

/// The durable id a refusal's record is filed under: a digest of
/// `{strand, tool, wanted diff}` and nothing else.
///
/// Deriving it rather than minting it is what makes a retry loop cheap.
/// `api.raise_escalation_for` refuses a duplicate id, so the second
/// identical denial finds its record already pending instead of adding a
/// row — and a strand that crashes while parked re-raises onto the same
/// record when it replans, rather than orphaning the one a human is
/// looking at. The call id is deliberately *not* in the digest: it is in
/// the record's scope, which is what an approval is spent against, and
/// putting it in the id would give a retry loop one record per attempt,
/// which is the thing the derivation exists to prevent.
///
/// The wanted diff is order-insensitive: the same set of grants written
/// two ways is the same want.
///
/// ## Examples
///
/// ```gleam
/// // escalate.record_id("main", "bash", denial.wanted)
/// ```
///
pub fn record_id(strand: String, tool: String, wanted: List(Grant)) -> String {
  let diff =
    wanted
    |> list.map(fn(grant) { json.to_string(grants.encode(grant)) })
    |> list.sort(string.compare)
    |> string.join(with: "\u{1e}")
  let digest =
    blob.ref_for(bit_array.from_string(
      strand <> "\u{1e}" <> tool <> "\u{1e}" <> diff,
    ))
  // `ref_for` renders `sha256-<64 hex>`; half of it is 128 bits, which
  // is more than a session's escalation set can collide in and short
  // enough to read in a client.
  "policy-" <> string.slice(digest, at_index: 7, length: 32)
}

// --- deciding one refusal --------------------------------------------------

fn decide(config: Config, refused: Refused) -> Decision {
  case borrow(config) {
    Error(Nil) -> Settle
    Ok(runtime) -> {
      let id = record_id(refused.strand, refused.tool, refused.denial.wanted)
      let scope =
        durable.CallScope(
          operation: refused.operation,
          strand: refused.strand,
          step_id: refused.step_id,
          source_index: refused.source_index,
          call_id: refused.call_id,
        )
      case raise(runtime, id, refused, scope) && config.interactive() {
        False -> Settle
        True -> park(config, runtime, id, scope, until(config, refused))
      }
    }
  }
}

// Files the record. A duplicate id is the deduplication working, not a
// failure: the record a human is already looking at is the one this
// refusal belongs to. Anything else — a commit fault, a lost writer —
// means there is no durable record to approve, so there is nothing to
// park on and the refusal settles.
fn raise(
  runtime: api.Runtime,
  id: String,
  refused: Refused,
  scope: durable.CallScope,
) -> Bool {
  case
    api.raise_escalation_for(
      runtime,
      id,
      tool.denial_to_json(refused.denial),
      scope: scope,
    )
  {
    Ok(Nil) -> True
    Error(api.EscalationExists(id: _)) -> True
    Error(_other) -> False
  }
}

// The instant the park window closes: the configured window, clamped by
// the call's own budget deadline. See the module doc — a re-clearance
// past the budget deadline cannot reserve, so holding past it trades an
// honest refusal for a confusing one.
fn until(config: Config, refused: Refused) -> Int {
  let #(now, _clock) = clock.read(config.clock)
  int.min(now + config.park_timeout_ms, refused.deadline_ms)
}

// The park loop. Every pass re-asks whether anyone is still attached and
// re-reads the record, so a disconnect, a denial, a decision by another
// path, and the window closing all un-park the call at the next slice.
fn park(
  config: Config,
  runtime: api.Runtime,
  id: String,
  scope: durable.CallScope,
  until: Int,
) -> Decision {
  let #(now, _clock) = clock.read(config.clock)
  case now >= until {
    True -> Settle
    False ->
      case api.escalation(runtime, id) {
        // The record went away underneath the park (a reset store, a
        // read fault). Nothing to wait for.
        Error(_error) -> Settle
        Ok(record) -> park_on_record(config, runtime, id, scope, until, record)
      }
  }
}

// The record's own status, once read: settled either way, or (still
// pending) another slice of the same park.
fn park_on_record(
  config: Config,
  runtime: api.Runtime,
  id: String,
  scope: durable.CallScope,
  until: Int,
  record: durable.Escalation,
) -> Decision {
  case record.status {
    durable.Approved -> spend(runtime, id, record, scope)
    durable.Rejected | durable.Consumed -> Settle
    durable.Pending -> park_pending(config, runtime, id, scope, until)
  }
}

fn park_pending(
  config: Config,
  runtime: api.Runtime,
  id: String,
  scope: durable.CallScope,
  until: Int,
) -> Decision {
  case config.interactive() {
    False -> Settle
    True -> {
      config.rest(config.poll_interval_ms)
      park(config, runtime, id, scope, until)
    }
  }
}

// Consume, then hand over — never the other way round. The scope check
// comes first: an approval that names a different call must widen
// nothing, and skipping a record can only narrow what this call
// receives, which is the safe direction.
fn spend(
  runtime: api.Runtime,
  id: String,
  record: durable.Escalation,
  scope: durable.CallScope,
) -> Decision {
  case durable.scoped_to(record, scope) {
    False -> Settle
    True ->
      case api.consume_escalation(runtime, id) {
        // A concurrent consumer won the CAS: one approval is worth one
        // widened execution, and it was not this one.
        Error(_error) -> Settle
        Ok(payloads) ->
          case grants.decode_all(payloads) {
            Error(_report) -> Settle
            Ok(typed) -> Resume(grants: typed)
          }
      }
  }
}

// --- borrowing the runtime -------------------------------------------------

// The holder is checked alive before it is called, because
// `process.call` exits the caller when the callee is gone and an
// unstarted holder is the ordinary case for a host that wired no
// escalation plane. The residual window — the holder dying between the
// check and the reply — settles in band anyway: this runs on the tool's
// own effect process, whose death the driver turns into a synthetic
// error result rather than a fault.
fn borrow(config: Config) -> Result(api.Runtime, Nil) {
  let subject = process.named_subject(config.name)
  case process.subject_owner(subject) {
    Error(Nil) -> Error(Nil)
    Ok(pid) ->
      case process.is_alive(pid) {
        False -> Error(Nil)
        True -> Ok(process.call(subject, config.holder_timeout_ms, Borrow))
      }
  }
}
