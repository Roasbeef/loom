//// The host's side of `ask` and `notice`: it turns a validated request into a
//// durable record in the session store (protocol-change/119).
////
//// ## Flow
////
//// `seam` → `ask` or `notice` → `try_insert`, and `read` → `settle`
////
//// 1. `seam` closes over a `Wiring` and answers the tools' `Attention` seam.
//// 2. `ask` and `notice` build the record's header from the caller's own
////    durable coordinates, the call's clock and the strand's lineage, then
////    hand the encoded record to `try_insert`.
//// 3. `try_insert` reads the prefix's guard cell and its records, refuses at the
////    open bound, and commits the new record, the guard's replacement and the
////    removal of any retired settled record in one transaction.
//// 4. A lost race re-reads and decides again, a bounded number of times.
//// 5. `read` answers a record and its revision, and `settle` rewrites it as
////    answered or closed under that revision.
////
//// ## Why the guard cell
////
//// The bound says two concurrent calls cannot both take the last slot. The
//// session writer serializes commits but expects only the keys a transaction
//// names, and a scan of a prefix is not a key. A new record's key is absent
//// from everything another call read, so two inserts that each counted 31
//// open asks would both succeed and leave 33.
////
//// So every insertion also replaces one cell per prefix, `core/attention`'s
//// `guard_key`, guarded by the seq it read before it counted. Two inserts that
//// counted the same records share that seq, and the second one's transaction
//// finds the cell moved and loses with `RaceLost`. It then re-reads, counts
//// the first insert's record, and either fits or is refused at the bound. The
//// count and the write are one decision, with no process of ours standing
//// between the store and the caller. The guard's suffix is not an id, so no
//// scan counts it.
////
//// ## Reading and settling (protocol-change/120)
////
//// `read` answers one record with its revision, the sequence number of its
//// cell. `settle` rewrites an open record as answered or closed, expecting the
//// cell to be at the revision the caller read, so a person's answer to a
//// record that has since changed is refused rather than written over it. Both
//// reads and the one write are made in the session's own serialized actor.
////
//// ## Pruning
////
//// Settled records are retired by `core/attention.retired` in the commit that
//// settles them, as `settle` does, and `try_insert` also prunes with the scan
//// it already holds. That keeps the prefix bounded however a settled record
//// came to exist.
////
//// ## The catalogue summary
////
//// Home reads a saved session's counts from a row in the catalogue
//// (protocol-change/122), because it must not open the session to count. The
//// row is a cache of the records, so whoever commits a change to one of them
//// tells a `Report` afterwards. `summary` reads the escalations, asks and
//// finds and `summarize` turns them into the four figures; `reporter` sends
//// the result to the registry without waiting. `settled` is the call the
//// settle path makes after it answers an ask or closes a find, and session
//// open makes the same call once to repair a row that lagged.
////
//// ## What is left to the caller
////
//// The tools check everything the arguments decide. This module checks what
//// only the session knows: that `to` names a strand of it, and that the open
//// bound has room.

import core/attention
import core/clock.{type Clock}
import core/json.{type JsonValue}
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/escalation
import runtime/lineage
import storage/catalogue.{type AttentionSummary, AttentionSummary}
import tools/agent.{type Caller}
import tools/attention as tool_attention

/// How many times an insertion that lost its race to another insertion reads
/// and decides again. The guard is session-wide and a `notice` is `Concurrent`,
/// so any number of calls can contend, but each round has one winner, so
/// `attempts` at least as large as the contenders always succeeds. Sixteen is
/// above any batch a model plans, and the bound exists so a fault cannot spin.
const attempts = 16

/// How far up the lineage the parent chain is followed. The spawning depth cap
/// is far below it; the bound only ends a ledger that held a cycle.
const max_parent_hops = 64

/// What the seam needs from the session.
///
/// Constructor invariants: `runtime` answers `Error(Nil)` until the session's
/// runtime exists, as the Agency's holder does, and the seam turns that into an
/// in-band refusal; `clock` is the call clock, in Unix milliseconds, and never
/// a monotonic one.
pub type Wiring {
  Wiring(
    /// Borrows the session's runtime. A closure rather than a value because
    /// the tools are built before `api.open` returns the runtime.
    runtime: fn() -> Result(api.Runtime, Nil),
    /// The call clock.
    clock: Clock,
    /// A source of entropy for ids, forty bits of which are kept.
    entropy: fn() -> Int,
    /// Told after a record commits, so the catalogue's summary follows it
    /// (protocol-change/122). `silent()` for a host with no catalogue.
    report: Report,
  )
}

/// The call a committer makes after a change to an escalation, an ask or a
/// find, with the session's runtime. It reads the records and has the summary
/// written to the catalogue; it never waits for the write and never fails the
/// caller, because the record has already committed and the summary can lag it.
pub type Report =
  fn(api.Runtime) -> Nil

/// A report that writes nothing, for a host with no catalogue and for tests
/// about something else.
///
/// ## Examples
///
/// ```gleam
/// // attention.Wiring(runtime:, clock:, entropy:, report: attention.silent())
/// ```
pub fn silent() -> Report {
  fn(_runtime) { Nil }
}

/// A report that makes the summary on `clock` and hands it to `send`, which
/// the daemon connects to the registry's fire-and-forget `RecordAttention`.
/// A summary that cannot be made, because a record read failed, is handed to
/// `failed` with the reason and nothing is sent, so the old row stands.
///
/// ## Examples
///
/// ```gleam
/// // attention.reporter(clock, fn(summary) { manager.record_attention(registry, id, summary) }, log_it)
/// ```
pub fn reporter(
  clock: Clock,
  send: fn(AttentionSummary) -> Nil,
  failed: fn(String) -> Nil,
) -> Report {
  fn(runtime) {
    let #(now, _clock) = clock.read(clock)

    // A summary that was made goes to the registry; one that could not be made
    // is reported and sends nothing, so the row the catalogue holds stands.
    case summary(runtime, now) {
      Ok(made) -> send(made)
      Error(reason) -> failed(reason)
    }
  }
}

/// The hook the settle path of protocol-change/120 calls after it commits an
/// ask's answer or a find's close, so the lowered count reaches the catalogue.
/// It is the whole of what that path owes the summary. The open-time reconcile
/// calls the report directly and does not use it; this name is kept for the
/// settle path so a reader can find the one call that path must make.
///
/// ## Examples
///
/// ```gleam
/// // attention.settled(report, runtime)
/// ```
pub fn settled(report: Report, runtime: api.Runtime) -> Nil {
  report(runtime)
}

/// Reads the session's own records and counts what is open.
///
/// ## Examples
///
/// ```gleam
/// // attention.summary(runtime, now)
/// ```
pub fn summary(
  runtime: api.Runtime,
  now: Int,
) -> Result(AttentionSummary, String) {
  use escalations <- result.try(
    api.escalations(runtime) |> result.map_error(string.inspect),
  )
  use open_asks <- result.try(asks(runtime))
  use open_finds <- result.map(finds(runtime))
  summarize(escalations, open_asks, open_finds, now)
}

/// The four figures of the summary, from records already read.
///
/// An approval counts while its status is pending. An ask counts while it is
/// open and routed to the owner, since an ask to a strand needs no person. A
/// find counts while it is open. `oldest_open_at` is the smallest creation
/// time over those asks and finds, and says nothing of approvals, which carry
/// no raise time.
///
/// ## Examples
///
/// ```gleam
/// assert attention.summarize([], [], [], 5).oldest_open_at == None
/// ```
pub fn summarize(
  escalations: List(escalation.Escalation),
  asks: List(attention.Ask),
  finds: List(attention.Find),
  now: Int,
) -> AttentionSummary {
  let pending =
    list.count(escalations, fn(record) { record.status == escalation.Pending })
  let owner_asks =
    list.filter(asks, fn(ask) {
      ask.state == attention.AskOpen && ask.header.routing == attention.ToOwner
    })
  let open_finds =
    list.filter(finds, fn(find) { find.state == attention.FindOpen })
  let times =
    list.append(
      list.map(owner_asks, fn(ask) { ask.header.created_at }),
      list.map(open_finds, fn(find) { find.header.created_at }),
    )
  AttentionSummary(
    pending_approvals: pending,
    open_asks: list.length(owner_asks),
    open_finds: list.length(open_finds),
    oldest_open_at: list.reduce(times, int.min) |> option.from_result,
    updated_at: now,
  )
}

/// Where a record stands for the purposes of the bound and of pruning.
type Standing {
  /// Counts against the open bound, and is never pruned.
  StillOpen

  /// Settled at the given Unix milliseconds, so a candidate for pruning.
  SettledAt(at: Int)
}

/// The two tools' seam over one wiring.
///
/// ## Examples
///
/// ```gleam
/// // contributions.attention_tools(attention.seam(wiring))
/// ```
pub fn seam(wiring: Wiring) -> tool_attention.Attention {
  tool_attention.Attention(
    ask: fn(caller, request) { ask(wiring, caller, request) },
    notice: fn(caller, request) { notice(wiring, caller, request) },
  )
}

/// Records an ask and answers its id.
///
/// ## Examples
///
/// ```gleam
/// // attention.ask(wiring, caller, request)
/// ```
pub fn ask(
  wiring: Wiring,
  caller: Caller,
  request: tool_attention.AskRequest,
) -> Result(String, tool_attention.Refusal) {
  use runtime <- result.try(borrow(wiring))
  use routing <- result.try(routing_of(runtime, caller.strand, request.to))
  let #(now, _clock) = clock.read(wiring.clock)
  let parents = parents_of(runtime, caller.strand)
  try_insert(
    runtime,
    wiring.entropy,
    now,
    ask_lane,
    fn(id) {
      attention.Ask(
        header: header(id, now, routing, caller, parents),
        why: request.why,
        questions: request.questions,
        state: attention.AskOpen,
      )
      |> attention.encode_ask
    },
    attempts,
  )
  |> reported(wiring, runtime)
}

/// Records a find and answers its id.
///
/// ## Examples
///
/// ```gleam
/// // attention.notice(wiring, caller, request)
/// ```
pub fn notice(
  wiring: Wiring,
  caller: Caller,
  request: tool_attention.NoticeRequest,
) -> Result(String, tool_attention.Refusal) {
  use runtime <- result.try(borrow(wiring))
  let #(now, _clock) = clock.read(wiring.clock)
  let parents = parents_of(runtime, caller.strand)
  try_insert(
    runtime,
    wiring.entropy,
    now,
    find_lane,
    fn(id) {
      attention.Find(
        header: header(id, now, attention.ToOwner, caller, parents),
        kind: request.kind,
        text: request.text,
        path: request.path,
        line: request.line,
        state: attention.FindOpen,
      )
      |> attention.encode_find
    },
    attempts,
  )
  |> reported(wiring, runtime)
}

/// Tells the report about a record that committed, and leaves a refusal alone:
/// nothing changed, so there is nothing to summarize.
fn reported(
  inserted: Result(String, tool_attention.Refusal),
  wiring: Wiring,
  runtime: api.Runtime,
) -> Result(String, tool_attention.Refusal) {
  use id <- result.map(inserted)
  wiring.report(runtime)
  id
}

/// Reads every ask in the session, open and settled, leaving out a cell that
/// does not decode as a damaged proposal is left out of the queue.
///
/// ## Examples
///
/// ```gleam
/// // attention.asks(runtime)
/// ```
pub fn asks(runtime: api.Runtime) -> Result(List(attention.Ask), String) {
  use cells <- result.map(read_prefix(runtime, attention.ask_prefix))
  list.filter_map(cells, fn(cell) {
    attention.decode_ask(cell.1) |> result.replace_error(Nil)
  })
}

/// Reads every find in the session, open and closed, leaving out a cell that
/// does not decode.
///
/// ## Examples
///
/// ```gleam
/// // attention.finds(runtime)
/// ```
pub fn finds(runtime: api.Runtime) -> Result(List(attention.Find), String) {
  use cells <- result.map(read_prefix(runtime, attention.find_prefix))
  list.filter_map(cells, fn(cell) {
    attention.decode_find(cell.1) |> result.replace_error(Nil)
  })
}

// --- reading and settling --------------------------------------------------

/// One stored record and its revision.
pub type Stored {
  /// An ask, at the sequence number of its cell.
  StoredAsk(ask: attention.Ask, revision: Int)

  /// A find, at the sequence number of its cell.
  StoredFind(find: attention.Find, revision: Int)
}

/// Why a record could not be read.
pub type ReadFault {
  /// The id has no record's shape, no cell holds it, or the cell does not
  /// decode. A record a prune removed is the same, so a reader cannot tell the
  /// three apart, and none of them is worth telling apart.
  NoSuchRecord

  /// The store could not be read, and why.
  Unreadable(reason: String)
}

/// What settles a record: an answer, or a closure.
pub type Settlement {
  /// An ask is answered. The answer carries who gave it.
  Answering(answer: attention.Answer)

  /// A find is closed by `by`.
  Closing(closure: attention.Closure, by: String)
}

/// Why a record was not settled.
pub type SettleFault {
  /// There is no such record, as for `ReadFault`.
  Missing

  /// The record is not at the revision the caller read: another write, or
  /// another settlement, got there first.
  Moved

  /// The settlement is of the other kind of record: an answer to a find, or a
  /// closure of an ask.
  WrongKind

  /// The record is already settled. A settled record is not settled again.
  AlreadySettled

  /// The store could not be used, and why.
  Failed(reason: String)
}

/// Reads one record and its revision, by id. The id's shape picks the prefix,
/// so a wire value cannot address any other cell.
///
/// ## Examples
///
/// ```gleam
/// // attention.read(runtime, "ask-3f9c01a2b4")
/// ```
pub fn read(runtime: api.Runtime, id: String) -> Result(Stored, ReadFault) {
  // The id's shape picks the prefix, so a wire value cannot address another cell.
  use cell <- result.try(
    case attention.is_ask_id(id), attention.is_find_id(id) {
      True, _ -> cell_of(runtime, attention.ask_key(id))
      False, True -> cell_of(runtime, attention.find_key(id))
      False, False -> Error(NoSuchRecord)
    },
  )

  // The same shape picks the decoder, and a cell that does not decode is no record.
  case attention.is_ask_id(id) {
    True ->
      attention.decode_ask(cell.value)
      |> result.replace_error(NoSuchRecord)
      |> result.map(StoredAsk(_, cell.seq))
    False ->
      attention.decode_find(cell.value)
      |> result.replace_error(NoSuchRecord)
      |> result.map(StoredFind(_, cell.seq))
  }
}

/// Settles an open record under the revision the caller read, and answers the
/// record's new revision.
///
/// The write is the record's replacement guarded by `revision`, together with
/// the removal of the settled records `core/attention.retired` names, in one
/// commit. A settlement that loses to another write is `Moved`, and nothing is
/// written.
///
/// ## Examples
///
/// ```gleam
/// // attention.settle(runtime, clock, "ask-3f9c01a2b4", 41, attention.Answering(answer))
/// ```
pub fn settle(
  runtime: api.Runtime,
  time: Clock,
  id: String,
  revision: Int,
  settlement: Settlement,
) -> Result(Int, SettleFault) {
  use stored <- result.try(
    read(runtime, id)
    |> result.map_error(fn(fault) {
      case fault {
        NoSuchRecord -> Missing
        Unreadable(reason:) -> Failed(reason)
      }
    }),
  )
  use <- bool.guard(when: revision_of(stored) != revision, return: Error(Moved))
  let #(now, _clock) = clock.read(time)
  use #(lane, encoded) <- result.try(settled_form(stored, settlement, now))
  use edits <- result.try(settling_edits(
    runtime,
    lane,
    id,
    revision,
    encoded,
    now,
  ))

  // The write is the replacement and the retirements together, so a lost race
  // writes nothing.
  case api.edit_reserved_facts(runtime, edits) {
    Ok(Nil) ->
      case read(runtime, id) {
        Ok(after) -> Ok(revision_of(after))
        Error(_) -> Error(Failed("the settled record could not be read back"))
      }
    Error(api.RaceLost) -> Error(Moved)
    Error(error) ->
      Error(Failed(
        "the session store could not be used: " <> string.inspect(error),
      ))
  }
}

/// The edits that settle a record: its replacement, guarded by the revision the
/// caller read, and the removal of the settled records that
/// `core/attention.retired` names once this one counts as settled. The record
/// itself is never among the removals.
fn settling_edits(
  runtime: api.Runtime,
  lane: Lane,
  id: String,
  revision: Int,
  encoded: JsonValue,
  now: Int,
) -> Result(List(api.ReservedFactEdit), SettleFault) {
  use cells <- result.map(
    read_prefix(runtime, lane.prefix) |> result.map_error(Failed),
  )
  let key = lane.key(id)
  let standings =
    standings_of(cells, lane)
    |> list.map(fn(entry) {
      case entry.0 == key {
        True -> #(entry.0, SettledAt(at: now))
        False -> entry
      }
    })
  let retired =
    retiring(runtime, standings, now)
    |> list.filter(fn(edit) { edit_key(edit) != key })
  [
    api.ReservedFactSet(api.ReservedFactChange(
      key:,
      value: encoded,
      expected: Some(revision),
    )),
    ..retired
  ]
}

/// The revision a stored record was read at.
pub fn revision_of(stored: Stored) -> Int {
  case stored {
    StoredAsk(revision:, ..) | StoredFind(revision:, ..) -> revision
  }
}

/// The cell under `key`, or the fault for its absence or an unreadable store.
fn cell_of(
  runtime: api.Runtime,
  key: String,
) -> Result(api.FactCell, ReadFault) {
  case api.fact_cell(runtime, key) {
    Ok(Some(cell)) -> Ok(cell)
    Ok(None) -> Error(NoSuchRecord)
    Error(error) -> Error(Unreadable(string.inspect(error)))
  }
}

/// The record rewritten as settled, with the lane it lives in, or the reason it
/// cannot be: already settled, or settled by the other kind of settlement.
fn settled_form(
  stored: Stored,
  settlement: Settlement,
  now: Int,
) -> Result(#(Lane, JsonValue), SettleFault) {
  case stored, settlement {
    StoredAsk(ask: attention.Ask(state: attention.AskOpen, ..) as ask, ..),
      Answering(answer:)
    ->
      Ok(#(
        ask_lane,
        attention.encode_ask(
          attention.Ask(..ask, state: attention.Answered(at: now, answer:)),
        ),
      ))
    StoredFind(find: attention.Find(state: attention.FindOpen, ..) as find, ..),
      Closing(closure:, by:)
    ->
      Ok(#(
        find_lane,
        attention.encode_find(
          attention.Find(
            ..find,
            state: attention.Closed(at: now, closure:, by:),
          ),
        ),
      ))
    StoredAsk(ask: attention.Ask(state: attention.Answered(..), ..), ..), _
    | StoredFind(find: attention.Find(state: attention.Closed(..), ..), ..), _
    -> Error(AlreadySettled)
    StoredAsk(..), Closing(..) | StoredFind(..), Answering(..) ->
      Error(WrongKind)
  }
}

/// The key a reserved-fact edit names.
fn edit_key(edit: api.ReservedFactEdit) -> String {
  case edit {
    api.ReservedFactSet(change:) -> change.key
    api.ReservedFactRemove(key:, ..) -> key
  }
}

// --- the header ------------------------------------------------------------

/// The fields every record shares, all taken from the driver's own identity
/// and clock and none from the model.
fn header(
  id: String,
  now: Int,
  routing: attention.Routing,
  caller: Caller,
  parents: List(String),
) -> attention.Header {
  attention.Header(
    id:,
    created_at: now,
    routing:,
    anchor: attention.Anchor(
      operation: caller.operation,
      step_id: caller.step_id,
      source_index: caller.source_index,
    ),
    strand: caller.strand,
    parents:,
  )
}

/// The routing an ask's `to` names. A name must be a strand of the session,
/// because an ask for a strand that does not exist could never be answered.
fn routing_of(
  runtime: api.Runtime,
  caller_strand: String,
  to: Option(String),
) -> Result(attention.Routing, tool_attention.Refusal) {
  case to {
    None -> Ok(attention.ToOwner)

    // An ask to the asking strand itself could never be answered: the answer
    // would arrive in the run that has ended its turn waiting for it.
    Some(name) if name == caller_strand ->
      Error(tool_attention.Invalid(
        "`to` names your own strand; leave it out to ask the owner",
      ))
    Some(name) ->
      case api.strands(runtime) {
        Ok(known) ->
          case list.contains(known, name) {
            True -> Ok(attention.ToStrand(name))
            False -> Error(tool_attention.NoSuchStrand(name))
          }
        Error(error) -> Error(unavailable(error))
      }
  }
}

/// The strand's parents, nearest first, from the lineage cells. A strand with
/// no cell is a root, and a cell that does not decode ends the chain there:
/// the chain is for display, so a damaged one is shorter rather than a refusal.
fn parents_of(runtime: api.Runtime, strand: String) -> List(String) {
  climb(runtime, strand, max_parent_hops)
}

/// Follows `parent` edges upward.
fn climb(runtime: api.Runtime, strand: String, hops: Int) -> List(String) {
  use <- bool.guard(when: hops <= 0, return: [])

  // A strand with no cell, an unreadable one and one that does not decode all
  // end the chain: it is for display, so a short chain is better than a refusal.
  case api.fact_cell(runtime, lineage.register_key(strand)) {
    Ok(Some(cell)) ->
      case lineage.decode(cell.value) {
        Ok(found) -> [found.parent, ..climb(runtime, found.parent, hops - 1)]
        Error(_) -> []
      }
    Ok(None) | Error(_) -> []
  }
}

// --- the insertion ---------------------------------------------------------

/// What differs between the two prefixes, so one `insert` serves both.
type Lane {
  Lane(
    /// The reserved prefix the records live under.
    prefix: String,
    /// The most records that may be open.
    limit: Int,
    /// What the records are called in a refusal.
    records: String,
    /// Makes an id from entropy.
    mint: fn(Int) -> String,
    /// Names the cell of an id.
    key: fn(String) -> String,
    /// Whether a stored cell is open or settled, or damaged.
    standing: fn(JsonValue) -> Result(Standing, Nil),
  )
}

/// The ask records' lane.
const ask_lane =
  Lane(
    prefix: attention.ask_prefix,
    limit: attention.max_open_asks,
    records: "asks",
    mint: attention.mint_ask_id,
    key: attention.ask_key,
    standing: ask_standing,
  )

/// The find records' lane.
const find_lane =
  Lane(
    prefix: attention.find_prefix,
    limit: attention.max_open_finds,
    records: "finds",
    mint: attention.mint_find_id,
    key: attention.find_key,
    standing: find_standing,
  )

/// Records one record of a lane, refusing at the open bound.
///
/// `encode` builds the payload once the id is minted. The whole read, count
/// and write is retried when another insertion moved the guard in between,
/// with `left` attempts remaining including this one.
fn try_insert(
  runtime: api.Runtime,
  entropy: fn() -> Int,
  now: Int,
  lane: Lane,
  encode: fn(String) -> JsonValue,
  left: Int,
) -> Result(String, tool_attention.Refusal) {
  let guard = attention.guard_key(lane.prefix)

  // The guard is read before the records are counted, so a record committed
  // after the count moves the seq this attempt's commit expects.
  use cell <- result.try(
    api.fact_cell(runtime, guard) |> result.map_error(unavailable),
  )
  use cells <- result.try(
    read_prefix(runtime, lane.prefix)
    |> result.map_error(tool_attention.Unavailable),
  )
  let standings = standings_of(cells, lane)
  let open = list.count(standings, fn(entry) { entry.1 == StillOpen })
  use <- bool.guard(
    when: open >= lane.limit,
    return: Error(tool_attention.Full(lane.records, lane.limit)),
  )
  let id = lane.mint(entropy())
  let key = lane.key(id)
  let retired = retiring(runtime, standings, now)
  let edits =
    list.flatten([
      [
        api.ReservedFactSet(api.ReservedFactChange(
          key: guard,
          value: json.Int(inserted_before(cell) + 1),
          expected: option.map(cell, fn(found) { found.seq }),
        )),
        api.ReservedFactSet(api.ReservedFactChange(
          key:,
          value: encode(id),
          expected: None,
        )),
      ],
      retired,
    ])

  // A lost race is the expected loser of a tie, and is answered by reading
  // again, which counts the winner's record.
  case api.edit_reserved_facts(runtime, edits), left > 1 {
    Ok(Nil), _ -> Ok(id)
    Error(api.RaceLost), True ->
      try_insert(runtime, entropy, now, lane, encode, left - 1)
    Error(error), _ -> Error(unavailable(error))
  }
}

/// How many insertions the guard has counted, which is only ever read to make
/// each commit change the cell. A missing or odd value counts as none.
fn inserted_before(cell: Option(api.FactCell)) -> Int {
  case cell {
    Some(api.FactCell(value: json.Int(count), ..)) -> count
    Some(_) | None -> 0
  }
}

/// Reads the cells under a prefix that name a record, leaving out the guard.
/// The guard shares the prefix but is not a record, and a listing must not
/// count it.
fn read_prefix(
  runtime: api.Runtime,
  prefix: String,
) -> Result(List(#(String, JsonValue)), String) {
  use cells <- result.map(
    api.reserved_facts(runtime, prefix:)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  list.filter(cells, fn(cell) { cell.0 != attention.guard_key(prefix) })
}

/// Each decodable cell's id and standing. A cell that does not decode is
/// absent: it is left out of every count and listing.
fn standings_of(
  cells: List(#(String, JsonValue)),
  lane: Lane,
) -> List(#(String, Standing)) {
  list.filter_map(cells, fn(cell) {
    use standing <- result.map(lane.standing(cell.1))
    #(cell.0, standing)
  })
}

/// The edits that remove the settled records `core/attention.retired` names,
/// each guarded by the seq read now. A record that cannot be read is left for
/// the next commit rather than failing this one. The cell's own key stands in
/// for the id, since it is what a removal needs and it orders as the id does.
fn retiring(
  runtime: api.Runtime,
  standings: List(#(String, Standing)),
  now: Int,
) -> List(api.ReservedFactEdit) {
  let settled =
    list.filter_map(standings, fn(entry) {
      case entry.1 {
        StillOpen -> Error(Nil)
        SettledAt(at:) -> Ok(attention.Settled(id: entry.0, at:))
      }
    })
  list.filter_map(attention.retired(settled, now:), fn(key) {
    case api.fact_cell(runtime, key) {
      Ok(Some(cell)) -> Ok(api.ReservedFactRemove(key:, expected: cell.seq))
      Ok(None) | Error(_) -> Error(Nil)
    }
  })
}

/// The standing of a stored ask.
fn ask_standing(value: JsonValue) -> Result(Standing, Nil) {
  use ask <- result.map(
    attention.decode_ask(value) |> result.replace_error(Nil),
  )

  // An answered ask is settled and so can be pruned; an open one counts
  // against the bound and is never removed.
  case ask.state {
    attention.AskOpen -> StillOpen
    attention.Answered(at:, ..) -> SettledAt(at:)
  }
}

/// The standing of a stored find.
fn find_standing(value: JsonValue) -> Result(Standing, Nil) {
  use find <- result.map(
    attention.decode_find(value) |> result.replace_error(Nil),
  )

  // A closed find is settled and so can be pruned; an open one counts against
  // the bound and is never removed.
  case find.state {
    attention.FindOpen -> StillOpen
    attention.Closed(at:, ..) -> SettledAt(at:)
  }
}

/// A refusal for a runtime fault, with the reason the model may relay.
fn unavailable(error: api.ApiError) -> tool_attention.Refusal {
  tool_attention.Unavailable(
    "the session store could not be used: " <> string.inspect(error),
  )
}

/// The session's runtime, or the refusal for a session that is not yet up.
fn borrow(wiring: Wiring) -> Result(api.Runtime, tool_attention.Refusal) {
  wiring.runtime()
  |> result.replace_error(tool_attention.Unavailable(
    "the session is not ready to record that yet",
  ))
}
