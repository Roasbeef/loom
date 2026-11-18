//// The host's side of `ask` and `notice`: it turns a validated request into a
//// durable record in the session store (protocol-change/119).
////
//// ## Flow
////
//// `seam` → `ask` or `notice` → `insert` → `try_insert`
////
//// 1. `seam` closes over a `Wiring` and answers the tools' `Attention` seam.
//// 2. `ask` and `notice` build the record's header from the caller's own
////    durable coordinates, the call's clock and the strand's lineage, then
////    hand the encoded record to `insert`.
//// 3. `insert` reads the prefix's guard cell and its records, refuses at the
////    open bound, and commits the new record, the guard's replacement and the
////    removal of any retired settled record in one transaction.
//// 4. A lost race re-reads and decides again, a bounded number of times.
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
//// ## Pruning
////
//// Settled records are retired by `core/attention.retired` in the commit that
//// settles them. Nothing settles a record yet, because answering and closing
//// are the feed's (protocol-change/120), so `insert` also prunes with the scan
//// it already holds. That keeps the prefix bounded however a settled record
//// came to exist, and it is a no-op for every session today.
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
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/lineage
import tools/agent.{type Caller}
import tools/attention as tool_attention

/// How many times an insertion that lost its race to another insertion reads
/// and decides again. Two or three callers contend at most, since asks are
/// `Exclusive` per batch, so four re-reads are ample and the bound exists only
/// so a fault cannot spin.
const attempts = 4

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
  use routing <- result.try(routing_of(runtime, request.to))
  let #(now, _clock) = clock.read(wiring.clock)
  let parents = parents_of(runtime, caller.strand)
  insert(
    runtime,
    wiring.entropy,
    now,
    Lane(
      prefix: attention.ask_prefix,
      limit: attention.max_open_asks,
      records: "asks",
      mint: attention.mint_ask_id,
      key: attention.ask_key,
      standing: ask_standing,
    ),
    fn(id) {
      attention.Ask(
        header: header(id, now, routing, caller, parents),
        why: request.why,
        questions: request.questions,
        state: attention.AskOpen,
      )
      |> attention.encode_ask
    },
  )
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
  insert(
    runtime,
    wiring.entropy,
    now,
    Lane(
      prefix: attention.find_prefix,
      limit: attention.max_open_finds,
      records: "finds",
      mint: attention.mint_find_id,
      key: attention.find_key,
      standing: find_standing,
    ),
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
  )
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
  to: Option(String),
) -> Result(attention.Routing, tool_attention.Refusal) {
  case to {
    None -> Ok(attention.ToOwner)
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

/// Records one record of a lane, refusing at the open bound.
///
/// `encode` builds the payload once the id is minted. The whole read, count
/// and write is retried when another insertion moved the guard in between.
fn insert(
  runtime: api.Runtime,
  entropy: fn() -> Int,
  now: Int,
  lane: Lane,
  encode: fn(String) -> JsonValue,
) -> Result(String, tool_attention.Refusal) {
  try_insert(runtime, entropy, now, lane, encode, attempts)
}

/// One attempt of `insert`, with `left` attempts remaining including this one.
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
