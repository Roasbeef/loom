//// The workspace seam's recall router: `history.search`, `history.read`
//// and `memory.remember`, answered inside the harness over the very
//// seams the `history_search` and `remember` tools call.
////
//// # Why this is its own module
////
//// For the reason `codemode/search` is one: the module a program imports
//// is the unit of authorization. `cap/history` reads a repository's past
//// and writes nothing; `cap/memory` writes one durable note and reads
//// nothing. Folding either into `codemode/workspace` would put "may read
//// every session this repository has ever had" and "may write a file"
//// behind one import, and a reader asking what a program can reach would
//// have to subtract one list out of another by eye.
////
//// The two capabilities are in *one* module rather than two because they
//// are one plane from the host's side: both are durable session stores
//// beside this session's file, both are probed at boot, and both are
//// absent on a host where that probe failed. A program still names them
//// separately, because it imports them separately.
////
//// # One implementation behind both doors
////
//// Nothing here decides anything. The closures are `tools/history.History`
//// and `tools/remember.Memory` — the tool seams verbatim, filled by
//// `client/serve` with the same holder actor and the same memory session
//// the tool calls reach. So a query issued from a program runs over the
//// same index with the same bounds and comes back with the same refusals
//// as the identical query issued as a tool call. The types are the tools'
//// own directly, for the reason `codemode/search` takes `tools/search`'s:
//// `codemode` already depends on `tools`, and a private copy of a recall
//// vocabulary would be a second place to keep in step for no isolation
//// gained.
////
//// # What this module *does* own: the two guards the closure contract names
////
//// `tools/history.History` says its `search` is called with an
//// already-trimmed, non-empty query and a limit already inside
//// `[min_limit, max_limit]`. The tool's `run` is one caller that meets
//// that contract; this router is the other, and it meets it the same
//// way — `history.clamp_limit` is the tool's own function, and the
//// emptiness check is here because the index answers an empty query
//// with a fault about full-text syntax, which tells a program nothing it
//// can repair. Both guards are therefore restatements of a contract
//// rather than a second policy: the numbers are `tools/history`'s
//// constants and are not spelled again.
////
//// The clamp runs here and not only in `cap/history` because this side
//// of the wire is the trusted one. A satellite runs model-authored code
//// and can put any integer on the wire it likes.
////
//// # Every plan is `ServedHere`
////
//// A search over an index the harness already holds and a commit into a
//// session file the harness already owns spawn no process, open no
//// socket and cross no namespace, so a composed `SandboxPolicy` would be
//// a policy whose enforcer is not present — the argument
//// `codemode/workspace`'s module doc makes at length.
////
//// # Absent rather than refusing
////
//// Each half is an `Option`, and a `None` leaves its capabilities
//// **unrouted** rather than routed to a closure that always refuses. A
//// program then meets `unsupported_cap` from the innermost router, which
//// is the honest answer for a host whose index or memory store would not
//// open: both are gated on a boot probe, both log one line saying so,
//// and neither tool is registered either. This is `cap/schedule`'s
//// posture and deliberately not `cap/job`'s — recall and memory hold
//// authority over nothing, so a program that cannot reach them carries
//// on.

import broker/framing.{type CapOutcome}
import codemode/internal/args
import codemode/satellite.{
  type CapDenial, type CapPlan, type CapRequest, type CapRouter, CapDenial,
  ServedHere,
}
import core/ids
import core/json
import core/msgpack.{type MsgPackValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/history
import tools/remember

// --- the capability names ----------------------------------------------------

/// The capability a program searches the repository's durable history
/// with.
pub const search_cap = "history.search"

/// The capability a program reads one complete stored entry with.
pub const read_cap = "history.read"

/// The capability a program writes one durable note with.
pub const remember_cap = "memory.remember"

/// Every capability this router services, in the order a program meets
/// them. Published so the tool description a model reads states the real
/// set rather than a copy that can drift — and read per host rather than
/// statically, because a host whose probes failed services none of them.
pub const serviced_caps = [search_cap, read_cap, remember_cap]

// --- the wire's refusal vocabulary ----------------------------------------------

/// The code a structurally invalid argument travels under: an empty
/// query, an id that is not canonical, a scope name this wire does not
/// carry. `codemode/internal/args`' own constant, referenced rather than
/// restated, for the reason every other router here references it.
pub const invalid_argument_code = args.invalid_argument_code

/// The code a recall call travels under when no index is reachable.
///
/// The five constants below and the four beneath them are the strings
/// the two tools already put in their own failure details, restated here
/// because the tools keep theirs private. They are half of a contract
/// whose other half is `cap/history.map_error` and
/// `cap/memory.map_error`; `recall_test` drives each tool's own
/// `refusal_outcome` and asserts the spelling, so the two halves cannot
/// drift apart in silence.
pub const history_unavailable_code = "history_unavailable"

/// The code an index refusal travels under — a malformed query, a wrong
/// id.
pub const history_refused_code = "history_refused"

/// The code a not-yet-open index travels under. Transient.
pub const history_not_ready_code = "history_not_ready"

/// The code a busy holder travels under. Transient.
pub const history_busy_code = "history_busy"

/// The code a held memory lease travels under. Transient.
pub const memory_busy_code = "memory_busy"

/// The code an unopenable memory store travels under.
pub const memory_unavailable_code = "memory_unavailable"

/// The code an over-long note travels under, measured after redaction.
pub const note_too_long_code = "note_too_long"

/// The code a memory session at its lifetime ceiling travels under.
pub const memory_full_code = "memory_full"

/// The code an empty note travels under.
pub const note_empty_code = "note_empty"

// --- the seam ----------------------------------------------------------------

/// The harness-side seams this router calls: the recall index and the
/// memory door, each present only where its boot probe succeeded.
///
/// Both are the tools' own seam records rather than copies, which is
/// what makes "one implementation behind both doors" a fact about the
/// code instead of a claim in a comment.
pub type Recall {
  Recall(
    /// The recall index the two `history.*` capabilities read, or `None`
    /// on a host whose index would not open.
    index: Option(history.History),
    /// The memory session `memory.remember` writes into, or `None` on a
    /// host whose store would not open.
    store: Option(remember.Memory),
  )
}

/// A seam with neither plane: every capability unrouted, which is what a
/// host that probed and found nothing serves.
///
/// ## Examples
///
/// ```gleam
/// assert recall.none().index == option.None
/// ```
///
pub fn none() -> Recall {
  Recall(index: None, store: None)
}

/// The capabilities one seam actually services, which is the subset of
/// `serviced_caps` whose plane this host opened.
///
/// Read off the record rather than assumed, for the reason
/// `client/mcp.serviced_caps` is: the sentence a model is charged for on
/// every request must not be able to claim a door this host did not
/// open. A program that imports `cap/history` on a host with no index
/// still compiles and still meets `unsupported_cap` — what this stops is
/// the description *promising* it would not.
///
/// ## Examples
///
/// ```gleam
/// assert recall.serviced_caps_on(recall.none()) == []
/// ```
///
pub fn serviced_caps_on(seam: Recall) -> List(String) {
  list.append(index_caps(seam.index), store_caps(seam.store))
}

fn index_caps(index: Option(history.History)) -> List(String) {
  case index {
    Some(_index) -> [search_cap, read_cap]

    None -> []
  }
}

fn store_caps(store: Option(remember.Memory)) -> List(String) {
  case store {
    Some(_store) -> [remember_cap]

    None -> []
  }
}

/// The recall router, in front of `inner`.
///
/// Composed rather than total, like every other arm of the workspace
/// seam: it answers three names and hands everything else down.
///
/// ## Examples
///
/// ```gleam
/// // recall.routing(seam, over: satellite.default_router)
/// ```
///
pub fn routing(seam: Recall, over inner: CapRouter) -> CapRouter {
  fn(request: CapRequest) {
    // Gleam patterns cannot name a constant, so the arms below are string
    // literals while `serviced_caps` holds the constants — two lists that
    // could drift. `recall_test` walks `serviced_caps` and asserts each
    // one routes, which is what keeps them the same list.
    case request.cap {
      "history.search" -> over_index(seam, request, inner, search_plan)
      "history.read" -> over_index(seam, request, inner, read_plan)
      "memory.remember" -> over_store(seam, request, inner)
      _other -> inner(request)
    }
  }
}

// An index arm, or the inner router when this host opened no index. The
// fall-through is what makes an absent plane answer `unsupported_cap`
// rather than a refusal of its own; see the module doc.
fn over_index(
  seam: Recall,
  request: CapRequest,
  inner: CapRouter,
  plan: fn(history.History, CapRequest) -> Result(CapPlan, CapDenial),
) -> Result(CapPlan, CapDenial) {
  case seam.index {
    Some(index) -> plan(index, request)

    None -> inner(request)
  }
}

// The memory arm, falling through for the same reason.
fn over_store(
  seam: Recall,
  request: CapRequest,
  inner: CapRouter,
) -> Result(CapPlan, CapDenial) {
  case seam.store {
    Some(store) -> remember_plan(store, request)

    None -> inner(request)
  }
}

// --- the arms -----------------------------------------------------------------

fn search_plan(
  index: history.History,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use query <- result.try(args.string(request.args, "query"))
  use asked <- result.try(args.int(request.args, "limit"))
  use scope <- result.try(scope_arg(request.args))
  use text <- result.try(searchable(query))

  // Both guards are `tools/history`'s contract, met here exactly as the
  // tool's own `run` meets it. The clamp is the tool's function, so the
  // two doors cannot come to hold different numbers.
  let limit = history.clamp_limit(asked)
  Ok(
    ServedHere(fn() {
      case index.search(text, limit, scope) {
        Error(refusal) -> refused(history_denial(refusal))

        Ok(hits) ->
          answered([
            #("hits", msgpack.ArrayValue(list.map(hits, hit_value))),
            // The bound the query actually ran with, not the one that
            // was asked for: a caller that computed a limit reads back
            // what the harness did with it.
            #("limit", msgpack.IntValue(limit)),
          ])
      }
    }),
  )
}

fn read_plan(
  index: history.History,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use session_text <- result.try(args.string(request.args, "session"))
  use entry_text <- result.try(args.string(request.args, "entry"))
  use session <- result.try(
    ids.parse_session_id(session_text)
    |> result.replace_error(args.invalid(
      "`session` must be a canonical session ID from a search hit",
    )),
  )
  use entry <- result.try(
    ids.parse_entry_id(entry_text)
    |> result.replace_error(args.invalid(
      "`entry` must be a canonical entry ID from a search hit",
    )),
  )
  Ok(
    ServedHere(fn() {
      case index.read(session, entry) {
        Error(refusal) -> refused(history_denial(refusal))

        // The entry's JSON text rather than a decoded tree: the prelude
        // has no JSON vocabulary a program may import, so a tree would
        // be a value nothing on the far side could take apart. The tool
        // door renders the same string.
        Ok(value) ->
          answered([#("entry", msgpack.StringValue(json.to_string(value)))])
      }
    }),
  )
}

fn remember_plan(
  store: remember.Memory,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use note <- result.try(args.string(request.args, "note"))
  Ok(
    ServedHere(fn() {
      case store.remember(note) {
        Error(refusal) -> refused(memory_denial(refusal))

        // An empty map rather than a field: there is nothing to report
        // about a note that was written, and `cap/memory.remember`
        // discards the value.
        Ok(Nil) -> answered([])
      }
    }),
  )
}

// --- argument decoding -----------------------------------------------------------

// The wire carries the scope as one of two names, which are the tool's
// own `scope` enum verbatim. An unrecognised one is refused rather than
// defaulted: a program that wrote `"repo"` meant something, and running
// the whole repository's history under a guess is the wrong way to be
// wrong.
fn scope_arg(value: MsgPackValue) -> Result(history.Scope, CapDenial) {
  use name <- result.try(args.string(value, "scope"))
  case name {
    "repository" -> Ok(history.Repository)

    "session" -> Ok(history.ThisSession)

    other ->
      Error(args.invalid(
        "`scope` must be `repository` or `session`, not `" <> other <> "`",
      ))
  }
}

// The index answers an empty query with a fault about full-text syntax,
// which tells a program nothing it can act on. Refused here instead, in
// the words of the thing it should do next — and refused at *plan* time,
// so the closure the tool contract describes is never called with one.
fn searchable(query: String) -> Result(String, CapDenial) {
  case string.trim(query) {
    "" ->
      Error(args.invalid(
        "`query` is empty. Give the words you are looking for — a name, an "
        <> "error string, a decision — rather than an empty search",
      ))

    trimmed -> Ok(trimmed)
  }
}

// --- rendering ------------------------------------------------------------------

fn answered(fields: List(#(String, MsgPackValue))) -> CapOutcome {
  framing.CapOk(
    value: msgpack.MapValue(
      list.map(fields, fn(entry) { #(msgpack.StringValue(entry.0), entry.1) }),
    ),
  )
}

fn hit_value(hit: history.Hit) -> MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("session"), msgpack.StringValue(hit.session)),
    #(msgpack.StringValue("entry"), msgpack.StringValue(hit.entry)),
    #(msgpack.StringValue("snippet"), msgpack.StringValue(hit.snippet)),
  ])
}

// --- refusals -------------------------------------------------------------------

fn refused(denial: CapDenial) -> CapOutcome {
  let CapDenial(code:, message:) = denial
  framing.CapErr(code:, message:)
}

/// The in-band code and message one recall refusal travels under.
///
/// Public because it is half of a contract whose other half is
/// `cap/history.map_error`: each code is turned back into the variant of
/// the same name on the far side, and the sentence is the harness's own
/// words, carried verbatim rather than reworded here.
///
/// ## Examples
///
/// ```gleam
/// // recall.history_denial(history.IndexBusy(reason: "…")).code
/// //   == recall.history_busy_code
/// ```
///
pub fn history_denial(refusal: history.Refusal) -> CapDenial {
  case refusal {
    history.IndexUnavailable(reason:) ->
      CapDenial(code: history_unavailable_code, message: reason)

    history.IndexRefused(reason:) ->
      CapDenial(code: history_refused_code, message: reason)

    history.IndexNotReady(reason:) ->
      CapDenial(code: history_not_ready_code, message: reason)

    history.IndexBusy(reason:) ->
      CapDenial(code: history_busy_code, message: reason)
  }
}

/// The in-band code and message one memory refusal travels under, with
/// `cap/memory.map_error` as the other half of the contract.
///
/// The two arithmetic refusals render their numbers into the sentence
/// rather than putting them on the wire as fields: the far side has the
/// same two constants, so a field would be a number sent to be compared
/// against itself.
///
/// ## Examples
///
/// ```gleam
/// // recall.memory_denial(remember.NothingToRemember).code
/// //   == recall.note_empty_code
/// ```
///
pub fn memory_denial(refusal: remember.Refusal) -> CapDenial {
  case refusal {
    remember.MemoryBusy(reason:) ->
      CapDenial(code: memory_busy_code, message: reason)

    remember.MemoryUnavailable(reason:) ->
      CapDenial(code: memory_unavailable_code, message: reason)

    remember.NoteTooLong(chars:, limit:) ->
      CapDenial(
        code: note_too_long_code,
        message: "that note is "
          <> int.to_string(chars)
          <> " characters after redaction and the limit is "
          <> int.to_string(limit)
          <> "; write the lesson rather than the transcript",
      )

    remember.CeilingReached(limit:) ->
      CapDenial(
        code: memory_full_code,
        message: "this repository's memory has taken its lifetime limit of "
          <> int.to_string(limit)
          <> " notes and accepts no more",
      )

    remember.NothingToRemember ->
      CapDenial(
        code: note_empty_code,
        message: "`note` is empty; give the lesson in a sentence or two",
      )
  }
}
