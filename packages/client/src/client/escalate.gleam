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
////     call* under the widened policy. Parking is what makes the round
////     trip a single call's business: the re-clearance is the same call
////     that was refused, so an approval is spent while the thing it
////     authorizes is still standing at the door.
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
//// ## One record per want, and which call holds it
////
//// A record's id is a digest of `{strand, tool, wanted diff}` and not of
//// the call — one row and one prompt however many times a want is
//// asked. What that costs is that the call which first raised a record
//// is usually gone by the time anyone answers: a model that reads an
//// in-band refusal retries under a call id the provider mints fresh. So
//// a raise does not merely file the record, it *claims* it
//// (`api.claim_escalation`): the scope moves to the call standing at the
//// door now, and a decided record — consumed or rejected — re-opens as a
//// new question. Exactly one call holds the claim at any instant, and
//// `escalation.scoped_to` is still exact equality, so an approval is
//// still spent by exactly one call, exactly once.
////
//// Two consequences worth stating. Two calls wanting precisely the same
//// thing at once share one prompt and therefore one authorization —
//// whichever holds the claim resumes and the other takes the ordinary
//// in-band refusal. And approving a want does not make it unaskable
//// forever: the next call wanting it asks again, because one approval is
//// one execution and a standing permission is a wider base policy, not
//// an approval that never expires.
////
//// ## The two deadlines
////
//// A park is bounded by the smaller of the configured window and *the
//// call's own budget deadline*, and the deadline is re-read immediately
//// before the consuming commit. The second bound is not politeness: the
//// broker's ledger refuses a reservation past `deadline_ms`, so a
//// re-clearance after that instant is a `BudgetRefused`, not a
//// resumption. Holding a call past its own budget would trade an
//// honest "policy refused" for a confusing "deadline passed" — and
//// consuming past it would spend the approval on the way to that
//// refusal, leaving a record marked spent for an execution that never
//// happened.
////
//// What the budget bounds is *admission*, not total elapsed time. The
//// resumed call re-enters `broker.reserve_budget` with its `CallSpec`
//// unchanged, so the helper is handed the original `wall_s`: a call that
//// parked for a hundred seconds of its budget still runs with a full
//// wall limit afterwards, and a parked call's lifetime is `park + wall`
//// rather than `wall`. Defensible, and not something an operator sizing
//// a deadline would guess.
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
//// hand first — exact equality, unchanged — so an approval whose claim
//// another call has taken over widens nothing here. Both directions fail
//// safe: a lost CAS, a claim lost to another call, a closed budget
//// window, an unattributable record, a decode failure and a crash all
//// end in the in-band refusal.

import broker/escalation.{type Denial}
import broker/policy.{type Grant}
import client/grants
import core/clock.{type Clock}
import core/ids.{type OpId}
import core/json
import gleam/bit_array
import gleam/bool
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
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
/// `holder_timeout_ms` bounds the call that borrows the runtime, and a
/// holder that misses it is treated as absent rather than fatal;
/// `max_records` is the most *distinct* wants a session will ever file,
/// past which a refusal that would open a new record settles in band.
pub type Config {
  Config(
    name: Name(Message),
    clock: Clock,
    interactive: fn() -> Bool,
    park_timeout_ms: Int,
    poll_interval_ms: Int,
    rest: fn(Int) -> Nil,
    holder_timeout_ms: Int,
    max_records: Int,
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
/// The record cap is a different kind of number: 256 distinct wants in
/// one session is already far past what a person would work through, and
/// every record above it costs a decode on every tool clearance and a
/// scan on every commit hint. Reaching it is a sign something is
/// generating refusals rather than a sign of a busy session.
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
    max_records: 256,
  )
}

/// Starts the holder under `config.name`, after `api.open` has returned
/// the runtime it holds.
///
/// `client/serve` runs it as a supervised worker in the services
/// supervisor, alongside the Agency's holder and the gateway hub, and
/// that is the right tier for it: the holder is addressed by *name*, so
/// a restart under the same name is the same address and every later
/// refusal finds it again. A death costs only the refusals that arrive
/// during the restart window, and those settle in band with **no record
/// raised at all** — `decide` borrows before it raises, and a borrow
/// that finds no holder settles without writing anything. That is the
/// fail-safe direction (a refusal the model is told about, an audit line
/// missing) rather than the safe-seeming one, and it is the reason the
/// holder does nothing but hand back a value: the less it can do, the
/// less there is to die of.
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
/// Deriving it rather than minting it is what makes a retry loop cheap:
/// the second identical denial finds the record already there and takes
/// the claim on it instead of adding a row, and a strand that crashes
/// while parked re-raises onto the same record when it replans rather
/// than orphaning the one a human is looking at. The call id is
/// deliberately *not* in the digest — it is in the record's scope, which
/// is what an approval is spent against, and putting it in the id would
/// give a retry loop one record per attempt.
///
/// The wanted diff is order-insensitive: the same set of grants written
/// two ways is the same want. It is also *magnitude*-insensitive for a
/// limit grant, because that magnitude can be model-supplied; see
/// `dedup_key`.
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
    |> list.map(dedup_key)
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

// One wanted grant, as the digest sees it.
//
// A limit contributes the *field* it would raise and not the number,
// because that number can be the model's. `bash` turns its
// `timeout_ms` argument into the `wall_s` it asks the broker for, so
// under a base narrower than the tool asks for the shortfall carries a
// model-chosen integer into the wanted diff; if it reached the digest, a
// retry loop stepping the timeout would mint a durable record — and,
// with a client attached, a human prompt — per attempt. That is exactly
// the approval fatigue the deduplication exists to prevent, driven by
// the party it exists to constrain. Collapsing the magnitude leaves the
// space bounded by the six limit fields instead.
//
// Nothing is lost to the human: the magnitude is in the record's stored
// denial, which is what the client renders and what an approval grants
// against, and a claim refreshes that denial on a pending record. A call
// that lands on an approval granted for a *different* magnitude of the
// same field simply gets those grants — never more than a human chose —
// and if they do not cover it the re-clearance is refused in band, which
// is where it started.
//
// Every other grant keeps its whole encoded form: the rest of a tool's
// requirements are static, declared in its `call_spec` rather than
// derived from arguments.
fn dedup_key(grant: Grant) -> String {
  case grant {
    policy.GrantLimit(field:, value: _) -> "limit:" <> limit_field(field)
    other -> json.to_string(grants.encode(other))
  }
}

fn limit_field(field: policy.LimitField) -> String {
  case field {
    policy.CpuSeconds -> "cpu_s"
    policy.WallSeconds -> "wall_s"
    policy.MemBytes -> "mem_bytes"
    policy.Pids -> "pids"
    policy.FsizeBytes -> "fsize_bytes"
    policy.OutputBytes -> "output_bytes"
  }
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
      case raise(config, runtime, id, refused, scope) && config.interactive() {
        False -> Settle
        True ->
          park(config, runtime, id, scope, refused, until(config, refused))
      }
    }
  }
}

// Files the record and takes the claim on it — which, under a
// deterministic record id, is the ordinary case rather than the
// exception. `api.claim_escalation` writes the record when there is
// none and otherwise moves the scope to this call under a CAS, so the
// one row a want ever occupies follows whichever call is currently
// standing at the door. Without that a retry — and a model that reads
// an in-band refusal always retries under a freshly minted call id —
// would park on a record scoped to a call that has gone, an approval
// scoped to that call could never be spent by anything, and the operator
// would watch an approved record do nothing for the rest of the session.
//
// Anything else — a commit fault, a lost writer, a set already at its
// cap — means there is no durable record this call can spend, so there
// is nothing to park on and the refusal settles in band, exactly as it
// did before any of this existed.
fn raise(
  config: Config,
  runtime: api.Runtime,
  id: String,
  refused: Refused,
  scope: durable.CallScope,
) -> Bool {
  use <- bool.guard(when: !within_cap(config, runtime, id), return: False)
  case
    api.claim_escalation(
      runtime,
      id,
      tool.denial_to_json(refused.denial),
      scope: scope,
    )
  {
    Ok(_record) -> True
    Error(_error) -> False
  }
}

// Whether one more *distinct* want may be filed. A refusal that lands on
// a record already there costs no row and is always allowed; a refusal
// that would open a new one is refused in band once the session is at
// its cap.
//
// The cap is what keeps the escalation set a bounded thing. Two paths
// that run constantly read the whole `escalation/` prefix — a tool
// clearance looks for approvals attributed to it, and the gateway's pull
// turns new records into events — so an unbounded set is a cost on every
// tool call and every commit hint. The digest already collapses the one
// model-controlled input (`dedup_key`); this bounds the rest.
fn within_cap(config: Config, runtime: api.Runtime, id: String) -> Bool {
  case api.escalation(runtime, id) {
    Ok(_already_filed) -> True
    Error(_absent) ->
      case api.escalations_below(runtime, config.max_records) {
        Ok(room) -> room
        Error(_error) -> False
      }
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
// path, a claim taken over by another call, and the window closing all
// un-park the call at the next slice.
fn park(
  config: Config,
  runtime: api.Runtime,
  id: String,
  scope: durable.CallScope,
  refused: Refused,
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
        Ok(record) ->
          park_on_record(config, runtime, id, scope, refused, until, record)
      }
  }
}

// The record's own status, once read: settled either way, or (still
// pending) another slice of the same park.
//
// A record that no longer names this call is settled rather than waited
// on. Another call wanting the same thing has taken the claim, and the
// decision a human is about to make will be spent by that one — waiting
// for it here could only end in the scope check refusing, one slice
// before the window closes.
fn park_on_record(
  config: Config,
  runtime: api.Runtime,
  id: String,
  scope: durable.CallScope,
  refused: Refused,
  until: Int,
  record: durable.Escalation,
) -> Decision {
  use <- bool.guard(when: !durable.scoped_to(record, scope), return: Settle)
  case record.status {
    durable.Approved -> spend(config, runtime, id, record, scope, refused)
    durable.Rejected | durable.Consumed -> Settle
    durable.Pending -> park_pending(config, runtime, id, scope, refused, until)
  }
}

fn park_pending(
  config: Config,
  runtime: api.Runtime,
  id: String,
  scope: durable.CallScope,
  refused: Refused,
  until: Int,
) -> Decision {
  case config.interactive() {
    False -> Settle
    True -> {
      config.rest(config.poll_interval_ms)
      park(config, runtime, id, scope, refused, until)
    }
  }
}

// Consume, then hand over — never the other way round. Two checks come
// before the CAS, and the order is the whole of this function.
//
// **The scope**, because an approval that names a different call must
// widen nothing; skipping a record can only narrow what this call
// receives, which is the safe direction.
//
// **The budget deadline**, because the CAS is a writer round trip and
// the slice that admitted this poll may have been the last one inside
// the window. `broker.reserve_budget` refuses past `deadline_ms`, so a
// consume committed after that instant would spend the approval on the
// way to a `BudgetRefused`: the record would read `Consumed`, the model
// would get a deadline error rather than the widened run a human
// authorized, and the decision would have bought nothing. Checking here
// rather than after makes the ordering match what the module doc claims.
//
// A residual window remains — the clock is read before the commit, not
// during it — and it is now recoverable rather than terminal: a record
// consumed without an execution re-opens on the next raise of the same
// want (`escalation.claimed`), so the worst case is one wasted approval
// and a fresh prompt, not a want the session can never escalate again.
fn spend(
  config: Config,
  runtime: api.Runtime,
  id: String,
  record: durable.Escalation,
  scope: durable.CallScope,
  refused: Refused,
) -> Decision {
  use <- bool.guard(when: !durable.scoped_to(record, scope), return: Settle)
  let #(now, _clock) = clock.read(config.clock)
  use <- bool.guard(when: now >= refused.deadline_ms, return: Settle)
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

// --- borrowing the runtime -------------------------------------------------

// Borrowing never kills the borrower. `process.call` *exits its caller*
// when no reply arrives in time — it does not return an error — so a
// holder that is merely slow (restarting under its supervisor, or behind
// a busy writer) would take the tool's effect process down with it. The
// driver would settle that as a death with no stated reason where this
// module's doc promises an in-band policy refusal, and the two are not
// the same thing to a model: one is a decision it can reason about, the
// other is an effect that vanished.
//
// So the request is sent by hand and the reply waited for with a
// selector that also watches the holder's monitor: an absent holder, a
// dead one, one that dies mid-answer, and one that is simply too slow
// all arrive as `Error(Nil)` and settle in band.
fn borrow(config: Config) -> Result(api.Runtime, Nil) {
  ask(process.named_subject(config.name), config.holder_timeout_ms, Borrow)
}

fn ask(
  subject: Subject(message),
  waiting timeout: Int,
  sending make_request: fn(Subject(reply)) -> message,
) -> Result(reply, Nil) {
  use owner <- result.try(process.subject_owner(subject))
  let monitor = process.monitor(owner)
  let reply_to = process.new_subject()
  process.send(subject, make_request(reply_to))
  let answer =
    process.new_selector()
    |> process.select_map(reply_to, Ok)
    |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
    |> process.selector_receive(within: timeout)
  process.demonitor_process(monitor)
  result.flatten(answer)
}
