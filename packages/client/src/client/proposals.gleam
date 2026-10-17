//// The proposal queue: standing rules a model suggests and a person decides.
////
//// A model that has learned something worth binding later sessions may call
//// `propose`. The call files a pending proposal in a durable queue and returns.
//// A person reads the queue through the owner's session commands and approves
//// or rejects each entry. Only an approval writes anything, and what it writes
//// is `loom-rules.md`, a file the host owns beside the domain's memory store.
//// The next session's system prompt carries that file in its own fence, after
//// the operator's instruction files.
////
//// ## Flow
////
//// `seam` → `submit` → `decide` → `settle` → `edited` → `write_rules` → `guidance`
////
//// 1. `seam` hands the tool a `Proposals` value over one `Wiring`, and `admin`
////    hands the gateway the operator's half over the same wiring, so the two
////    doors cannot disagree about the queue.
//// 2. `submit` takes the memory store's writer lease, reads the rules file,
////    refuses a full queue, builds the proposal, checks with `edited` that it
////    would apply, and claims the cell `proposal/<id>` on its absence.
//// 3. `decide` takes the same lease and reads the cell, refusing anything that
////    is no longer `Pending`. A rejection goes straight to `settle`.
//// 4. An approval reads the rules file as it is now. If its digest is not the
////    proposal's base digest, or `edited` finds that its old text no longer matches
////    exactly once, the proposal is marked `Stale` and nothing is written. Text
////    that names the prompt's `<instructions` fence is refused here as well,
////    by the one predicate `propose.closes_fence`.
//// 5. Otherwise `write_rules` replaces the file atomically and `settle` marks
////    the proposal `Approved`. The same commit deletes decided rows past the
////    newest hundred, so the prefix cannot grow without bound.
//// 6. `guidance` is the prompt's reader of the same file, bounded and total.
////
//// ## One queue per domain, in the memory store
////
//// The rules file exists once per domain, so the queue that edits it does
//// too. The cells live in the domain's `loom-memory.db`, the file
//// `client/memory` opens under a writer lease, and every session of the domain
//// reads and decides the same rows. A proposal records the session that made
//// it (`Source`), so a reviewer can still say where it came from.
////
//// The lease is what makes decisions safe. Every write (a submission, a
//// settlement, the retirement of old rows) happens while this module holds
//// the store's one writer lease, and an approval holds that single lease from
//// reading the rules file to marking the proposal. Two approvals therefore
//// run one after the other, and the second reads the file the first wrote.
//// There is no read-then-write gap between sessions for a second approval to
//// slip through, and no compare-and-set to lose. A caller that finds the lease
//// held (by a `remember` call or by another decision) is told so in band
//// (`Busy`) and may try again; nothing here waits or retries.
////
//// Listing takes no lease. It reads the store the way the memory overview does
//// (`sqlite.list_registers_at`), so the review pane never delays a writer or
//// waits on one.
////
//// ## Why the rules file and not the workspace's AGENTS.md
////
//// Rules are operator configuration. `client/rules` holds that line for the
//// `[[rule]]` tables, and the same argument applies to a file the system
//// prompt will carry. The workspace's `AGENTS.md` is also the wrong place to
//// write: in this repository it is a byte-identical generated mirror of
//// `CLAUDE.md` and a check fails when they differ, and in any repository it is
//// project-authored text which the prompt already frames as information about
//// the code, never as authority. A model-authored rule must not be able to
//// reach either. So the target is a file the host owns, fixed by the host,
//// outside the editable workspace, protected from every jail
//// (`workspace_policy.protecting_rules`), and carried by the prompt under its
//// own origin so the model can tell an approved rule from a project's text
//// (protocol-change/086).
////
//// ## What a proposal is, and what it cannot be
////
//// `State` is closed: `Pending`, `Approved`, `Rejected` or `Stale`, and only
//// `Pending` can change. `Kind` has one constructor, and the target is derived
//// from the kind, so a stored row naming another file is refused by the
//// decoder rather than followed. The base digest is the digest of the rules
//// file's exact text (`tools/hashline.digest`), computed only by `rules`, so
//// no `Rules` value carries a digest that disagrees with its text.
////
//// ## Ordering, and the one failure left open
////
//// An approval writes the file and then marks the proposal, both under the
//// lease. If the process dies between the write and the mark, the proposal is
//// still pending and the file has changed. Deciding it again finds a
//// different digest and marks it `Stale`, so a rule is never applied twice.
//// The cost is that this one proposal reads as stale although its text is in
//// the file.
////
//// ## Bounds
////
//// At most `propose.max_pending` proposals wait. The queue refuses the next
//// one in band. Decided proposals are kept for the review pane, but only the
//// newest `max_listed` of them: every settlement deletes the older decided
//// rows, oldest first, in the commit that records the decision. The prefix
//// therefore holds at most `max_pending` pending rows and `max_listed`
//// decided ones, and so does every read of it, including the one each
//// submission makes.
////
//// The cells are `fact.custom` cells of the memory store, not of any session
//// store. A session's snapshot capture copies only that session's own
//// `client/` facts, so a queue a model can fill is never in a capture.
////
//// The `proposals` board is bounded too: `board` drops the oldest decided
//// rows, then the oldest pending ones, until the encoded board fits
//// `max_board_bytes`, and reports how many it dropped in `omitted`.
////
//// ## Telling open clients
////
//// A change publishes `ProposalsChanged` on the bus under `channel`, a key
//// derived from the store's path. Every gateway of the domain subscribes to
//// that one key (`Admin.channel`), so an owner page open in any session
//// re-reads the queue when a proposal is filed or decided in another.
////
//// ## Logging
////
//// Each transition that commits logs `memory.proposal` at info level with the
//// `decision` (`submitted`, `approved`, `rejected` or `stale`), the `kind` and
//// the `id`, and never any proposal text.

import client/memory.{type MemoryFault, type Opened}
import client/system_prompt.{type GuidanceFile, GuidanceFile}
import core/clock.{type Clock}
import core/ids
import core/json.{type JsonValue}
import core/register
import core/tx.{DeleteRegister, Expect, SetRegister, Tx}
import events/bus.{type Bus}
import filepath
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import simplifile
import storage/sqlite
import storage/storage
import telemetry/field
import telemetry/log.{type Logger}
import tools/hashline
import tools/propose

/// The rules file's name, which is also the `target` every proposal carries.
/// The file lives beside the domain's memory store; a proposal never holds its
/// directory.
pub const rules_file = "loom-rules.md"

/// The prefix of the queue's cells in the memory store, one per proposal.
pub const key_prefix = "proposal/"

/// The name this module gives the memory store's writer lease, which a refused
/// caller is told is holding the queue.
pub const lease_owner = "loom-proposals"

/// The most bytes the rules file may hold, for the prompt's sake: it is
/// carried whole in every new session. An edit that would grow it past this is
/// refused when proposed, and a file that is already larger is left out of the
/// prompt with a warning.
pub const max_rules_bytes = 16_384

/// The most decided proposals the queue keeps, newest first. Settling a
/// proposal deletes the decided rows beyond this, oldest first.
pub const max_listed = 100

/// The most bytes the encoded `proposals` board may be. `board` omits rows to
/// stay within it and says how many.
pub const max_board_bytes = 48_000

/// What a proposal changes. One constructor, so far: a rule in the rules
/// file. A kind that targets configuration is left for the work that carries
/// a configuration edit door.
pub type Kind {
  Rule
}

/// Where a proposal stands.
///
/// `Pending` is the only state a decision can leave. The other three are
/// final: `Approved` wrote the file, `Rejected` wrote nothing on purpose, and
/// `Stale` wrote nothing because the file moved.
pub type State {
  /// Waiting for a person.
  Pending

  /// A person approved it and its text is in the rules file.
  Approved

  /// A person rejected it.
  Rejected

  /// An approval found that the rules file no longer matched what the
  /// proposal was written against, and applied nothing.
  Stale
}

/// A person's answer to a pending proposal.
pub type Decision {
  Approve
  Reject
}

/// The words that prompted a proposal, so a reviewer can see them.
///
/// Constructor invariants: `session` is the proposing session's id as text;
/// `entry` is the canonical text of an entry id, or absent when the model did
/// not name one.
pub type Source {
  Source(session: String, entry: Option(String))
}

/// One proposal.
///
/// Constructor invariants: `id` satisfies `is_id`; `target` is always
/// `rules_file`, which the decoder enforces, so no stored row can point the
/// host at another file; `base_digest` is `rules_digest` of the rules file
/// the proposal was judged against; `old` is empty to append, otherwise text
/// that matched that file exactly once; `new` is at most
/// `propose.max_new_bytes`.
pub type Proposal {
  Proposal(
    id: String,
    kind: Kind,
    target: String,
    base_digest: String,
    old: String,
    new: String,
    rationale: String,
    source: Source,
    created_ms: Int,
    state: State,
  )
}

/// Every held proposal, newest first (at most `propose.max_pending` pending
/// and `max_listed` decided), and how many of them are pending.
pub type Listing {
  Listing(proposals: List(Proposal), pending: Int)
}

/// The rules file's exact text with the digest of that text.
///
/// Opaque, so the only way to hold one is `rules`, and the digest and the text
/// cannot disagree.
pub opaque type Rules {
  Rules(text: String, digest: String)
}

/// Why an edit cannot be made to the rules file.
pub type EditRefusal {
  /// The proposal's text names the prompt's `<instructions` fence.
  Fenced

  /// `old` is not in the file.
  NotFound

  /// `old` is in the file this many times, and must be in it once.
  Ambiguous(count: Int)

  /// The edited file would be this many bytes, over `max_rules_bytes`.
  TooLarge(bytes: Int)
}

/// Why a decision did not settle a proposal.
pub type DecideRefusal {
  /// No proposal has this id.
  NoSuchProposal

  /// The proposal was decided already, so nothing was written.
  AlreadyDecided(state: State)

  /// Another writer holds the memory store, so nothing was read or written.
  /// Deciding again later is safe.
  Busy(owner: String)

  /// The rules file could not be read or written. The proposal stays
  /// pending and can be decided again.
  CannotApply(reason: String)

  /// The queue could not be read or written.
  Unavailable(reason: String)
}

/// What the host gives this module, as plain functions and values.
///
/// Constructor invariants: `store_path` is the absolute path of the domain's
/// memory store, which holds the queue; `rules_path` is the absolute path of
/// the rules file beside it, both chosen by the host from the domain and never
/// by a client or a model; `session` is the id of the session that holds this
/// wiring, as text, and is what a proposal records as its source; `entropy` is
/// any source of integers; `logger` receives `memory.proposal` lines and never
/// any proposal text.
pub type Wiring {
  Wiring(
    store_path: String,
    rules_path: String,
    session: String,
    clock: Clock,
    entropy: fn() -> Int,
    bus: Bus,
    logger: Logger,
  )
}

/// The operator's half of the queue, for the gateway.
///
/// Constructor invariants: both functions are total; `channel` is the bus key
/// every change to the queue is published under, the same for every session of
/// the domain.
pub type Admin {
  Admin(
    list: fn() -> Result(Listing, String),
    decide: fn(String, Decision) -> Result(Proposal, DecideRefusal),
    channel: bus.SessionKey,
  )
}

// --- the two doors ----------------------------------------------------------

/// The model's door: the `propose` tool's seam over one wiring.
///
/// ## Examples
///
/// ```gleam
/// // propose.tool(proposals.seam(wiring))
/// ```
///
pub fn seam(wiring: Wiring) -> propose.Proposals {
  propose.Proposals(submit: fn(submission) { submit(wiring, submission) })
}

/// The operator's door over the same wiring.
///
/// ## Examples
///
/// ```gleam
/// // gateway.with_proposals(options, proposals.admin(wiring))
/// ```
///
pub fn admin(wiring: Wiring) -> Admin {
  Admin(
    list: fn() { listing(wiring) },
    decide: fn(id, decision) { decide(wiring, id, decision) },
    channel: channel(wiring),
  )
}

/// The bus key a domain's queue publishes `ProposalsChanged` under: derived
/// from the memory store's path, so every session of the domain computes the
/// same one and no session id enters it.
///
/// ## Examples
///
/// ```gleam
/// // bus.subscribe(bus, session: proposals.channel(wiring), topic: bus.Outputs)
/// ```
///
pub fn channel(wiring: Wiring) -> bus.SessionKey {
  bus.unidentified_key(name: "proposals:" <> wiring.store_path)
}

// --- the lease ----------------------------------------------------------------

// Runs `run` while this module holds the memory store's writer lease, and
// releases the lease whatever `run` answers, so no path leaves it held and
// refuses every later caller. A lease someone else holds is a `MemoryHeld`
// handed to `refused`, and nothing has been read or written.
fn holding(
  wiring: Wiring,
  refused: fn(MemoryFault) -> failure,
  run: fn(Opened) -> Result(value, failure),
) -> Result(value, failure) {
  let generator = ids.generator(wiring.clock, seed: wiring.entropy())
  use opened <- result.try(
    memory.open(
      path: wiring.store_path,
      owner: lease_owner,
      lease_ttl_ms: memory.lease_ttl_ms,
      clock: wiring.clock,
      generator:,
    )
    |> result.map_error(refused),
  )
  let outcome = run(opened)
  memory.close(opened)
  outcome
}

fn fault_text(fault: MemoryFault) -> String {
  case fault {
    memory.MemoryHeld(owner:) -> "the memory store is held by " <> owner
    memory.MemoryFailed(reason:) -> reason
  }
}

// --- submitting ---------------------------------------------------------------

/// Validates and queues one proposal, answering its id.
///
/// The lease is held from reading the rules file to committing the cell, so
/// the file the proposal is judged against is the one a decision made next
/// will see unless a person edits it by hand.
///
/// ## Examples
///
/// ```gleam
/// // proposals.submit(wiring, propose.Submission("", "Run make check.", "why", None))
/// ```
///
pub fn submit(
  wiring: Wiring,
  submission: propose.Submission,
) -> Result(String, propose.Refusal) {
  use proposal <- result.map(filed(wiring, submission))
  record(wiring, "submitted", proposal)
  announce(wiring)
  proposal.id
}

fn filed(
  wiring: Wiring,
  submission: propose.Submission,
) -> Result(Proposal, propose.Refusal) {
  use opened <- holding(wiring, submit_refusal)
  use current <- result.try(
    read_rules(wiring.rules_path) |> result.map_error(unavailable),
  )
  use held <- result.try(queue_in(opened) |> result.map_error(unavailable))
  use <- bool.guard(
    when: held.pending >= propose.max_pending,
    return: Error(propose.QueueFull(limit: propose.max_pending)),
  )
  let #(now, _clock) = clock.read(wiring.clock)
  let proposal = proposal_from(wiring, submission, current, now)

  // The proposal must be able to apply to the file as it stands now, or the
  // reviewer is shown a suggestion that could never be approved.
  use _text <- result.try(
    edited(current, proposal, now)
    |> result.map_error(fn(refusal) { propose.Invalid(describe(refusal)) }),
  )
  use Nil <- result.try(claim(opened, proposal))
  Ok(proposal)
}

fn submit_refusal(fault: MemoryFault) -> propose.Refusal {
  case fault {
    memory.MemoryHeld(owner:) -> propose.Busy(reason: "held by " <> owner)
    memory.MemoryFailed(reason:) -> propose.Unavailable(reason:)
  }
}

fn proposal_from(
  wiring: Wiring,
  submission: propose.Submission,
  current: Rules,
  now: Int,
) -> Proposal {
  Proposal(
    id: mint_id(wiring.entropy()),
    kind: Rule,
    target: rules_file,
    base_digest: current.digest,
    old: submission.old,
    new: submission.new,
    rationale: submission.rationale,
    source: Source(session: wiring.session, entry: submission.source_entry),
    created_ms: now,
    state: Pending,
  )
}

// The cell is claimed on its absence, so a colliding id loses to the first
// writer and is reported rather than overwriting a proposal a person may be
// reading. Forty bits of entropy make a collision a once-in-a-trillion event,
// and a retry costs the model one sentence, so there is no retry loop here.
fn claim(opened: Opened, proposal: Proposal) -> Result(Nil, propose.Refusal) {
  let key = key_of(proposal.id)
  storage.commit(
    opened.session.store,
    Tx(
      writes: [
        SetRegister(
          ns: register.FactCustom,
          key:,
          value: register.value(encode(proposal)),
        ),
      ],
      expected: [Expect(ns: register.FactCustom, key:, seq: None)],
    ),
  )
  |> result.replace(Nil)
  |> result.map_error(fn(error) {
    unavailable("the queue could not be written: " <> string.inspect(error))
  })
}

// Forty bits of the entropy source, as ten lowercase hexadecimal digits.
fn mint_id(entropy: Int) -> String {
  let digits =
    int.bitwise_and(entropy, 0xFFFFFFFFFF)
    |> int.to_base16
    |> string.lowercase
    |> string.pad_start(to: 10, with: "0")
  "prop-" <> digits
}

/// Whether `text` has the shape of a proposal id: `prop-` and ten lowercase
/// hexadecimal digits. A wire value is checked with this before it names a
/// cell, so a client cannot address another key.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.is_id("prop-0123456789")
/// assert !proposals.is_id("prop-../../x")
/// ```
///
pub fn is_id(text: String) -> Bool {
  case string.split_once(text, "prop-") {
    Ok(#("", digits)) ->
      string.length(digits) == 10
      && list.all(string.to_graphemes(digits), fn(digit) {
        string.contains("0123456789abcdef", digit)
      })
    Ok(_) | Error(Nil) -> False
  }
}

fn key_of(id: String) -> String {
  key_prefix <> id
}

// --- reading the queue --------------------------------------------------------

/// Every held proposal, newest first, with the pending count.
///
/// The read takes no lease: it opens the memory store read-only, so it neither
/// delays a writer nor waits on one, and a store that does not exist yet holds
/// an empty queue. The queue holds at most `propose.max_pending` pending rows
/// and `max_listed` decided ones, so this and the read each submission makes
/// are one scan of at most that many cells.
///
/// A row that does not decode is left out and not counted: the queue is
/// advisory data a person reads, and one damaged cell must not hide the rest.
///
/// ## Examples
///
/// ```gleam
/// // proposals.listing(wiring)
/// ```
///
pub fn listing(wiring: Wiring) -> Result(Listing, String) {
  case simplifile.is_file(wiring.store_path) {
    Ok(False) -> Ok(listing_of([]))
    Ok(True) -> read_beside(wiring.store_path)
    Error(error) ->
      Error("the proposal queue could not be found: " <> string.inspect(error))
  }
}

// The store is read the way the memory overview reads it: through the
// identity-checked, lease-free path, never opened. A store with no identity
// yet has had no first write, so it holds no proposals.
fn read_beside(path: String) -> Result(Listing, String) {
  use #(identity, _parent) <- result.try(
    sqlite.identity(path:)
    |> result.map_error(fn(error) { unreadable(string.inspect(error)) }),
  )
  case identity {
    None -> Ok(listing_of([]))
    Some(text) -> {
      use session <- result.try(
        ids.parse_session_id(text)
        |> result.map_error(fn(_report) {
          unreadable("the store's identity is damaged")
        }),
      )
      sqlite.list_registers_at(
        path:,
        session:,
        ns: register.FactCustom,
        prefix: Some(key_prefix),
      )
      |> result.map(listing_of)
      |> result.map_error(fn(error) { unreadable(string.inspect(error)) })
    }
  }
}

// The same read under the writer lease, for a caller that is about to write
// on what it saw.
fn queue_in(opened: Opened) -> Result(Listing, String) {
  storage.list_registers(
    opened.session.store,
    register.FactCustom,
    Some(key_prefix),
  )
  |> result.map(listing_of)
  |> result.map_error(fn(error) { unreadable(string.inspect(error)) })
}

fn unreadable(reason: String) -> String {
  "the proposal queue could not be read: " <> reason
}

fn listing_of(cells: List(#(String, storage.Register))) -> Listing {
  let rows =
    cells
    |> list.filter_map(fn(cell) { decode({ cell.1 }.value.payload) })
    |> list.sort(by: newest_first)
  Listing(
    proposals: rows,
    pending: list.count(rows, fn(row) { row.state == Pending }),
  )
}

fn newest_first(left: Proposal, right: Proposal) -> order.Order {
  case int.compare(right.created_ms, left.created_ms) {
    order.Eq -> string.compare(left.id, right.id)
    other -> other
  }
}

// --- deciding -----------------------------------------------------------------

/// Settles one pending proposal.
///
/// A rejection records the decision and touches no file. An approval applies
/// the exact edit to the rules file if, and only if, the file still has the
/// digest the proposal was written against and `old` still matches once.
/// Otherwise the proposal is marked `Stale` and the answer is that stale
/// proposal, not a refusal: the person asked for a decision and the queue
/// recorded the one the file allowed.
///
/// The whole decision runs under the memory store's writer lease. A lease that
/// someone else holds is answered `Busy` with nothing read or written.
///
/// ## Examples
///
/// ```gleam
/// // proposals.decide(wiring, "prop-0123456789", proposals.Approve)
/// ```
///
pub fn decide(
  wiring: Wiring,
  id: String,
  decision: Decision,
) -> Result(Proposal, DecideRefusal) {
  use <- bool.guard(when: !is_id(id), return: Error(NoSuchProposal))
  use settled <- result.map(resolved(wiring, id, decision))
  record(wiring, state_name(settled.state), settled)
  announce(wiring)
  settled
}

fn resolved(
  wiring: Wiring,
  id: String,
  decision: Decision,
) -> Result(Proposal, DecideRefusal) {
  use opened <- holding(wiring, decide_refusal)
  use proposal <- result.try(read_pending(opened, id))
  case decision {
    Reject -> settle(opened, proposal, Rejected)
    Approve -> approve(opened, wiring, proposal)
  }
}

fn decide_refusal(fault: MemoryFault) -> DecideRefusal {
  case fault {
    memory.MemoryHeld(owner:) -> Busy(owner:)
    memory.MemoryFailed(reason:) -> Unavailable(reason:)
  }
}

fn read_pending(opened: Opened, id: String) -> Result(Proposal, DecideRefusal) {
  use cell <- result.try(
    memory.cell(opened, key_of(id))
    |> result.map_error(fn(fault) { Unavailable(fault_text(fault)) }),
  )
  case cell {
    None -> Error(NoSuchProposal)
    Some(#(value, _seq)) ->
      case decode(value) {
        Error(reason) ->
          Error(Unavailable("a stored proposal is damaged: " <> reason))
        Ok(proposal) ->
          case proposal.state {
            Pending -> Ok(proposal)
            decided -> Error(AlreadyDecided(state: decided))
          }
      }
  }
}

// The two checks an approval makes against the file as it is now, in the
// order that gives the better reason: the digest says the file moved at all,
// and a failed match says the moved file no longer holds the text to replace.
// Either one settles the proposal as stale and writes nothing.
fn approve(
  opened: Opened,
  wiring: Wiring,
  proposal: Proposal,
) -> Result(Proposal, DecideRefusal) {
  use current <- result.try(
    read_rules(wiring.rules_path) |> result.map_error(CannotApply),
  )
  let #(now, _clock) = clock.read(wiring.clock)
  case current.digest == proposal.base_digest, edited(current, proposal, now) {
    True, Ok(text) -> {
      use Nil <- result.try(
        write_rules(wiring.rules_path, text) |> result.map_error(CannotApply),
      )
      settle(opened, proposal, Approved)
    }
    True, Error(TooLarge(..) as refusal) | True, Error(Fenced as refusal) ->
      Error(CannotApply(describe(refusal)))
    True, Error(NotFound) | True, Error(Ambiguous(..)) | False, _ ->
      settle(opened, proposal, Stale)
  }
}

// The decision and the retirement of old rows are one commit, so the prefix
// is never seen over its bound by a reader that comes between them, and a
// failed commit leaves the proposal pending.
fn settle(
  opened: Opened,
  proposal: Proposal,
  state: State,
) -> Result(Proposal, DecideRefusal) {
  let settled = Proposal(..proposal, state:)
  use held <- result.try(
    queue_in(opened) |> result.map_error(fn(reason) { Unavailable(reason) }),
  )
  let marked =
    SetRegister(
      ns: register.FactCustom,
      key: key_of(settled.id),
      value: register.value(encode(settled)),
    )
  let retired =
    list.map(retired_ids(held.proposals, settled), fn(id) {
      DeleteRegister(ns: register.FactCustom, key: key_of(id))
    })
  storage.commit(
    opened.session.store,
    Tx(writes: [marked, ..retired], expected: []),
  )
  |> result.replace(settled)
  |> result.map_error(fn(error) { Unavailable(string.inspect(error)) })
}

// The decided rows beyond the newest `max_listed`, oldest first, once
// `settled` counts as decided, so the prefix cannot grow without bound. The
// row just settled is never retired: approving an old pending proposal while
// a full page of newer rows is decided would otherwise sort it past the cut
// and delete the owner's decision in the call that recorded it.
fn retired_ids(held: List(Proposal), settled: Proposal) -> List(String) {
  held
  |> list.map(fn(row) {
    case row.id == settled.id {
      True -> settled
      False -> row
    }
  })
  |> list.filter(fn(row) { row.state != Pending })
  |> list.drop(max_listed)
  |> list.filter(fn(row) { row.id != settled.id })
  |> list.map(fn(row) { row.id })
}

// One info line per committed transition. It names the decision, the kind
// and the id, and nothing the model wrote.
fn record(wiring: Wiring, decision: String, proposal: Proposal) -> Nil {
  log.info(wiring.logger, "memory.proposal", [
    field.text(key: "decision", value: decision),
    field.text(key: "kind", value: kind_name(proposal.kind)),
    field.ident(key: "id", value: proposal.id),
  ])
}

// Open clients of every session in the domain re-read on this. It carries no
// data, and a lost one costs a client nothing the next read does not repair.
// It is sent after the lease is released, so a client that re-reads at once
// finds the store free.
fn announce(wiring: Wiring) -> Nil {
  bus.publish(wiring.bus, session: channel(wiring), event: bus.ProposalsChanged)
}

fn unavailable(reason: String) -> propose.Refusal {
  propose.Unavailable(reason:)
}

// --- the rules file -----------------------------------------------------------

/// The rules file's text as `Rules`, which carries the digest of exactly that
/// text.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.rules_digest(proposals.rules(""))
///   == "cbf29ce484222325-0"
/// ```
///
pub fn rules(text: String) -> Rules {
  Rules(text:, digest: hashline.digest(text))
}

/// The text a `Rules` holds.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.rules_text(proposals.rules("a")) == "a"
/// ```
///
pub fn rules_text(rules: Rules) -> String {
  rules.text
}

/// The digest of the text a `Rules` holds.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.rules_digest(proposals.rules("")) == hashline.digest("")
/// ```
///
pub fn rules_digest(rules: Rules) -> String {
  rules.digest
}

/// Reads the rules file. A file that does not exist is the empty rules, which
/// is the state before the first approval. A file over `max_rules_bytes`, or
/// one that is not text, is an error, so a decision is never made against a
/// file this module could not have written.
///
/// ## Examples
///
/// ```gleam
/// // proposals.read_rules("/state/domains/d/loom-rules.md")
/// ```
///
pub fn read_rules(path: String) -> Result(Rules, String) {
  case simplifile.read_bits(path) {
    Error(simplifile.Enoent) -> Ok(rules(""))
    Error(error) ->
      Error("the rules file is unreadable: " <> string.inspect(error))
    Ok(bytes) ->
      case bit_array.byte_size(bytes) > max_rules_bytes {
        True ->
          Error(
            "the rules file is larger than "
            <> int.to_string(max_rules_bytes)
            <> " bytes",
          )
        False ->
          bit_array.to_string(bytes)
          |> result.replace_error("the rules file is not text")
          |> result.map(rules)
      }
  }
}

/// Replaces the rules file with `text`, atomically: the text is written
/// beside it and renamed over it, so a reader sees the old file or the new
/// one and never part of either.
///
/// ## Examples
///
/// ```gleam
/// // proposals.write_rules("/state/domains/d/loom-rules.md", "### Rule ...")
/// ```
///
pub fn write_rules(path: String, text: String) -> Result(Nil, String) {
  let staged = path <> ".staged"
  let written = {
    use Nil <- result.try(
      simplifile.create_directory_all(filepath.directory_name(path)),
    )
    use Nil <- result.try(simplifile.write(staged, text))
    simplifile.rename(at: staged, to: path)
  }
  written
  |> result.map_error(fn(error) {
    "the rules file could not be written: " <> string.inspect(error)
  })
}

/// The rules text after applying a proposal, or why it cannot apply.
///
/// An empty `old` appends the proposal as a new rule under a header naming the
/// proposal, the approval date and the source session, so the prompt can say
/// where each rule came from. A non-empty `old` must occur in the file exactly
/// once and is replaced by `new`; the header of the rule it sits in is left as
/// it was, so a replaced rule keeps the date it was first approved. The result
/// must fit in `max_rules_bytes`. Neither field may name the prompt's
/// `<instructions` fence (`propose.closes_fence`), and neither may the
/// finished text unless the current file already did: a tag can form across
/// the join, `<` ending the text before it and `/instructions>` starting the
/// replacement, though neither field holds one. The check on the finished
/// text is the one that carries the property; the check on the fields is the
/// early, readable refusal.
///
/// ## Examples
///
/// ```gleam
/// // proposals.edited(proposals.rules("a b"), proposal_replacing_b, 0)
/// ```
///
pub fn edited(
  current: Rules,
  proposal: Proposal,
  approved_ms: Int,
) -> Result(String, EditRefusal) {
  use <- bool.guard(
    when: propose.closes_fence(proposal.new)
      || propose.closes_fence(proposal.old),
    return: Error(Fenced),
  )
  use text <- result.try(case proposal.old {
    "" -> Ok(appended(current.text, proposal, approved_ms))
    old ->
      case string.split(current.text, on: old) {
        [_only] -> Error(NotFound)
        [before, after] -> Ok(before <> proposal.new <> after)
        many -> Error(Ambiguous(count: list.length(many) - 1))
      }
  })
  use <- bool.guard(
    when: propose.closes_fence(text) && !propose.closes_fence(current.text),
    return: Error(Fenced),
  )
  let size = bit_array.byte_size(<<text:utf8>>)
  case size > max_rules_bytes {
    True -> Error(TooLarge(bytes: size))
    False -> Ok(text)
  }
}

fn appended(text: String, proposal: Proposal, approved_ms: Int) -> String {
  let rule =
    "### Rule "
    <> proposal.id
    <> " (approved "
    <> date_of(approved_ms)
    <> ", from session "
    <> proposal.source.session
    <> ")\n\n"
    <> string.trim(proposal.new)
    <> "\n"
  case text {
    "" -> rule
    _ -> string.trim_end(text) <> "\n\n" <> rule
  }
}

// The UTC calendar date of a millisecond timestamp, as `YYYY-MM-DD`.
fn date_of(ms: Int) -> String {
  let #(date, _time) =
    timestamp.from_unix_seconds(ms / 1000)
    |> timestamp.to_calendar(calendar.utc_offset)
  int.to_string(date.year)
  <> "-"
  <> two_digits(calendar.month_to_int(date.month))
  <> "-"
  <> two_digits(date.day)
}

fn two_digits(number: Int) -> String {
  string.pad_start(int.to_string(number), to: 2, with: "0")
}

/// The words for a refusal to edit, as the model and the reviewer read them.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.describe(proposals.NotFound)
///   == "`old` is not in the rules file; leave `old` out to append a new rule"
/// ```
///
pub fn describe(refusal: EditRefusal) -> String {
  case refusal {
    Fenced -> "the proposal names the system prompt's `<instructions` fence"
    NotFound ->
      "`old` is not in the rules file; leave `old` out to append a new rule"
    Ambiguous(count:) ->
      "`old` is in the rules file "
      <> int.to_string(count)
      <> " times and must match exactly once"
    TooLarge(bytes:) ->
      "the rules file would be "
      <> int.to_string(bytes)
      <> " bytes and the limit is "
      <> int.to_string(max_rules_bytes)
  }
}

// --- the prompt's reader ------------------------------------------------------

/// The rules file as the prompt carries it: one `ApprovedRule` guidance file,
/// or nothing, with a warning when the file exists and cannot be used.
///
/// Total and bounded. A missing or blank file is the ordinary case and says
/// nothing; a file over `max_rules_bytes` or one that is not text is left out
/// and named in a warning, never truncated, because half a rule is not what
/// anyone approved. The file is named in the prompt by `rules_file` alone, not
/// by its path, which belongs to the host.
///
/// The prompt is pinned for the life of a session, so a rule approved while a
/// session runs reaches the sessions opened after it and not that one.
///
/// ## Examples
///
/// ```gleam
/// // proposals.guidance("/state/domains/d/loom-rules.md")
/// ```
///
pub fn guidance(path: String) -> #(Option(GuidanceFile), List(String)) {
  case read_rules(path) {
    Error(reason) -> #(None, [
      "loom-rules.md was left out of the prompt: " <> reason,
    ])
    Ok(found) ->
      case string.trim(found.text) {
        "" -> #(None, [])
        text -> #(
          Some(GuidanceFile(
            path: rules_file,
            origin: system_prompt.ApprovedRule,
            text:,
          )),
          [],
        )
      }
  }
}

// --- the wire and the store ---------------------------------------------------

/// A proposal as one JSON object: the stored cell and the wire row are the
/// same value.
///
/// ```json
/// {"id":"prop-0123456789","kind":"rule","target":"loom-rules.md",
///  "base_digest":"cbf29ce484222325-0","old":"","new":"Run make check.",
///  "rationale":"it failed twice","source":{"session":"s1","entry":"e1"},
///  "created_ms":1790000000000,"state":"pending"}
/// ```
///
/// `source.entry` is absent when the model named none.
///
/// ## Examples
///
/// ```gleam
/// // proposals.decode(proposals.encode(proposal)) == Ok(proposal)
/// ```
///
pub fn encode(proposal: Proposal) -> JsonValue {
  json.Object([
    #("id", json.String(proposal.id)),
    #("kind", json.String(kind_name(proposal.kind))),
    #("target", json.String(proposal.target)),
    #("base_digest", json.String(proposal.base_digest)),
    #("old", json.String(proposal.old)),
    #("new", json.String(proposal.new)),
    #("rationale", json.String(proposal.rationale)),
    #("source", encode_source(proposal.source)),
    #("created_ms", json.Int(proposal.created_ms)),
    #("state", json.String(state_name(proposal.state))),
  ])
}

fn encode_source(source: Source) -> JsonValue {
  json.Object(
    list.append([#("session", json.String(source.session))], case source.entry {
      Some(entry) -> [#("entry", json.String(entry))]
      None -> []
    }),
  )
}

/// Reads a proposal from its JSON object, refusing anything that is not
/// exactly the shape `encode` writes: an id that fails `is_id`, a kind or
/// state this build does not know, a `target` other than `rules_file`, or a
/// field of the wrong type. Total.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.decode(json.Null) == Error("a proposal is an object")
/// ```
///
pub fn decode(value: JsonValue) -> Result(Proposal, String) {
  case value {
    json.Object(fields) -> decode_fields(fields)
    _ -> Error("a proposal is an object")
  }
}

fn decode_fields(
  fields: List(#(String, JsonValue)),
) -> Result(Proposal, String) {
  use id <- result.try(text_field(fields, "id"))
  use <- bool.guard(!is_id(id), Error("`id` is not a proposal id"))
  use kind <- result.try(text_field(fields, "kind") |> result.try(kind_of))
  use target <- result.try(text_field(fields, "target"))
  use <- bool.guard(
    target != rules_file,
    Error("`target` is not the rules file"),
  )
  use base_digest <- result.try(text_field(fields, "base_digest"))
  use old <- result.try(text_field(fields, "old"))
  use new <- result.try(text_field(fields, "new"))
  use rationale <- result.try(text_field(fields, "rationale"))
  use source <- result.try(
    list.key_find(fields, "source")
    |> result.replace_error("`source` is missing")
    |> result.try(decode_source),
  )
  use created_ms <- result.try(case list.key_find(fields, "created_ms") {
    Ok(json.Int(ms)) if ms >= 0 -> Ok(ms)
    _ -> Error("`created_ms` is not a non-negative integer")
  })
  use state <- result.try(text_field(fields, "state") |> result.try(state_of))
  Ok(Proposal(
    id:,
    kind:,
    target:,
    base_digest:,
    old:,
    new:,
    rationale:,
    source:,
    created_ms:,
    state:,
  ))
}

fn decode_source(value: JsonValue) -> Result(Source, String) {
  case value {
    json.Object(fields) -> {
      use session <- result.try(text_field(fields, "session"))
      case list.key_find(fields, "entry") {
        Error(Nil) -> Ok(Source(session:, entry: None))
        Ok(json.String(entry)) -> Ok(Source(session:, entry: Some(entry)))
        Ok(_) -> Error("`source.entry` is not text")
      }
    }
    _ -> Error("`source` is not an object")
  }
}

fn text_field(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(text)) -> Ok(text)
    Ok(_) -> Error("`" <> name <> "` is not text")
    Error(Nil) -> Error("`" <> name <> "` is missing")
  }
}

fn kind_name(kind: Kind) -> String {
  case kind {
    Rule -> "rule"
  }
}

fn kind_of(name: String) -> Result(Kind, String) {
  case name {
    "rule" -> Ok(Rule)
    other -> Error("unknown proposal kind `" <> other <> "`")
  }
}

/// The wire name of a state: `pending`, `approved`, `rejected` or `stale`.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.state_name(proposals.Stale) == "stale"
/// ```
///
pub fn state_name(state: State) -> String {
  case state {
    Pending -> "pending"
    Approved -> "approved"
    Rejected -> "rejected"
    Stale -> "stale"
  }
}

fn state_of(name: String) -> Result(State, String) {
  case name {
    "pending" -> Ok(Pending)
    "approved" -> Ok(Approved)
    "rejected" -> Ok(Rejected)
    "stale" -> Ok(Stale)
    other -> Error("unknown proposal state `" <> other <> "`")
  }
}

/// The `proposals` snapshot's board: the newest proposals, the pending count
/// over all of them, and the queue's bound.
///
/// ```json
/// {"proposals":[ ...rows... ],"pending":3,"limit":64,"omitted":2}
/// ```
///
/// The encoded board is kept within `max_board_bytes` by omitting the oldest
/// decided rows first and then the oldest pending ones. `omitted` counts the
/// rows left out and is absent when there are none, so a board that fits is
/// byte-for-byte the one clients already decode. `pending` still counts every
/// pending proposal.
///
/// ## Examples
///
/// ```gleam
/// // proposals.board(Listing(proposals: [], pending: 0))
/// ```
///
pub fn board(listing: Listing) -> JsonValue {
  let sized =
    list.map(listing.proposals, fn(row) {
      let value = encode(row)
      #(row, value, string.byte_size(json.to_string(value)) + 1)
    })
  let kept = fit(sized, max_board_bytes - board_overhead_bytes)
  let omitted = list.length(sized) - list.length(kept)
  json.Object(
    list.append(
      [
        #("proposals", json.Array(list.map(kept, fn(row) { row.1 }))),
        #("pending", json.Int(listing.pending)),
        #("limit", json.Int(propose.max_pending)),
      ],
      case omitted {
        0 -> []
        _ -> [#("omitted", json.Int(omitted))]
      },
    ),
  )
}

// The board's own fields: the keys, the three integers and the brackets.
const board_overhead_bytes = 128

// Drops the oldest decided row, or the oldest pending one when none is
// decided, until the rows' encoded sizes fit the budget. The rows arrive
// newest first, so the oldest is the last.
fn fit(
  rows: List(#(Proposal, JsonValue, Int)),
  budget: Int,
) -> List(#(Proposal, JsonValue, Int)) {
  let total = list.fold(rows, 0, fn(sum, row) { sum + row.2 })
  case total > budget, list.reverse(rows) {
    False, _ | True, [] -> rows
    True, oldest_first ->
      oldest_first
      |> drop_first_decided
      |> list.reverse
      |> fit(budget)
  }
}

fn drop_first_decided(
  oldest_first: List(#(Proposal, JsonValue, Int)),
) -> List(#(Proposal, JsonValue, Int)) {
  case list.any(oldest_first, is_decided) {
    True -> remove_first(oldest_first, is_decided)
    False -> list.drop(oldest_first, 1)
  }
}

fn is_decided(row: #(Proposal, JsonValue, Int)) -> Bool {
  let #(proposal, _value, _size) = row
  proposal.state != Pending
}

fn remove_first(items: List(a), matches: fn(a) -> Bool) -> List(a) {
  case items {
    [] -> []
    [head, ..rest] ->
      case matches(head) {
        True -> rest
        False -> [head, ..remove_first(rest, matches)]
      }
  }
}
