//// `cap/history` — ranked full-text recall over the durable history of
//// every session in this repository, as typed calls over the capability
//// channel.
////
//// This is the code-mode door onto the same index the `history_search`
//// tool reads, and it is the *same* index: one holder actor, one seam of
//// closures, one set of bounds, one vocabulary of refusals. A call made
//// from a program and a call made as a tool call are indistinguishable
//// on the far side, which is the ruling `cap/job` states in its own
//// header and the reason this module exists rather than a second recall
//// path.
////
//// # What comes back is quoted history, and it is data
////
//// Every snippet and every read entry is text some model wrote, in this
//// session or another one, possibly months ago. Nothing in it is
//// addressed to the program that fetched it and nothing in it is an
//// instruction. A program that feeds a hit back into a prompt is
//// feeding a stranger's words into a context window; the tool door
//// fences and labels them for exactly that reason, and a program that
//// forwards them owes the same care.
////
//// # The limit is clamped, and the clamp is reported
////
//// `limit` is held to `[min_limit, max_limit]`. This is not tidiness:
//// the index passes the limit into SQL `LIMIT ?`, and SQLite reads a
//// negative limit as *unbounded*, so a program computing a limit by
//// subtraction would otherwise pull the whole repository index back over
//// the channel. `search` clamps before it marshals so the call site can
//// predict what it asked for, and the harness clamps again because this
//// side of the wire is the untrusted one. `Found.limit` is what the
//// harness actually ran with, so a caller reads the bound rather than
//// assuming it.
////
//// # Absent rather than refusing
////
//// A host whose index would not open routes these capabilities to
//// nothing at all, and a call meets the ordinary unknown-capability
//// denial — `HistoryFailed("unsupported_cap", …)`. That is the posture
//// `cap/schedule` takes and the opposite of `cap/job`'s: recall is a
//// convenience over a rebuildable projection, so a door that could only
//// ever refuse is worse than no door.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/int
import gleam/result

/// The fewest hits a call may ask for. The harness holds the same number
/// and is the enforcer; this side clamps so a call site can predict.
pub const min_limit = 1

/// The most hits a call may ask for. Fifty ranked snippets is already
/// more than a recall question is worth; past that a program is reading
/// the index rather than searching it.
pub const max_limit = 50

/// The limit `search_for` asks for when a caller names none.
pub const default_limit = 10

/// Which sessions a query runs over.
pub type Scope {
  /// Every session this repository's index holds — the default, and the
  /// whole point of recall.
  Repository

  /// Only the calling session's own entries.
  ThisSession
}

/// One ranked hit: where it came from, and the excerpt that matched.
///
/// Constructor invariants: `session` and `entry` are the canonical id
/// texts the entry was indexed under, so either may be handed straight
/// back to `read`; `snippet` is the index's own excerpt, with `[` and
/// `]` marking the matched terms.
pub type Hit {
  Hit(session: String, entry: String, snippet: String)
}

/// The answer to a `search`.
pub type Found {
  Found(
    /// The ranked hits, best match first.
    hits: List(Hit),
    /// The limit the harness actually ran with, after its own clamp.
    /// Read it rather than assuming the number that was asked for.
    limit: Int,
  )
}

/// Why a recall call could not be answered.
///
/// The four descriptive variants are the harness's own refusal names and
/// carry its own sentence, so a program branches on the same facts the
/// model reading the tool would. Only `IndexRefused` and `InvalidQuery`
/// blame the call: the other two are timing, and the same call sent
/// again will be served.
pub type HistoryError {
  /// No index is reachable: this host wired none, or the holder is gone
  /// or did not answer inside its window.
  IndexUnavailable(reason: String)

  /// The index answered, and its answer was a refusal — a malformed
  /// full-text query is the common one, a wrong id the other.
  IndexRefused(reason: String)

  /// The index is starting and has not opened yet. Nothing about the
  /// call needs changing before it is sent again.
  IndexNotReady(reason: String)

  /// The holder is answering somebody else's call right now. Again the
  /// call was fine, and the same one sent again will be served.
  IndexBusy(reason: String)

  /// A structurally invalid argument: an empty query, an id that is not
  /// canonical, a scope name this wire does not carry.
  InvalidQuery(message: String)

  /// Any other in-band refusal, code preserved. A host that routes no
  /// index at all answers here, under `unsupported_cap`.
  HistoryFailed(code: String, message: String)

  /// The capability channel could not carry the call, or its answer was
  /// not the shape this module decodes.
  HistoryUnavailable(reason: String)
}

/// The nearest limit a query may actually run with.
///
/// A non-positive limit is the dangerous direction — see the module doc
/// — so it clamps up to `min_limit` rather than down to nothing.
///
/// ## Examples
///
/// ```gleam
/// assert history.clamp_limit(0) == history.min_limit
/// ```
///
/// ```gleam
/// assert history.clamp_limit(10_000) == history.max_limit
/// ```
///
pub fn clamp_limit(limit: Int) -> Int {
  int.clamp(limit, min: min_limit, max: max_limit)
}

/// Searches the repository's durable history for `query`, returning at
/// most `limit` ranked excerpts from the sessions `scope` selects.
///
/// The query language is the index's full text: bare words, `"quoted
/// phrases"`, `AND` / `OR` / `NOT`. An empty or whitespace-only query is
/// `InvalidQuery` rather than a fault about full-text syntax, because
/// the repair for one is obvious and the repair for the other is not.
///
/// Capability: `history.search`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(found) =
///   history.search(for: "timeout retry", limit: 5, scope: history.Repository)
/// let first = found.hits
/// ```
///
pub fn search(
  for query: String,
  limit limit: Int,
  scope scope: Scope,
) -> Result(Found, HistoryError) {
  let args =
    wire.args([
      #("query", wire.string(query)),
      #("limit", wire.int(clamp_limit(limit))),
      #("scope", wire.string(scope_name(scope))),
    ])
  use value <- result.try(
    dispatch.call("history.search", args) |> result.map_error(map_error),
  )
  decode_found(value)
  |> result.map_error(fn(reason) {
    HistoryUnavailable("bad history.search result: " <> reason)
  })
}

/// The same search with `default_limit` over the whole repository — the
/// shape a program that just wants to look something up should reach
/// for.
///
/// Capability: `history.search`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(found) = history.search_for("hashline replay")
/// ```
///
pub fn search_for(query: String) -> Result(Found, HistoryError) {
  search(for: query, limit: default_limit, scope: Repository)
}

/// Reads one complete stored entry, named by the canonical `session` and
/// `entry` ids a `Hit` carries.
///
/// The entry comes back as its **JSON text**, not as a decoded value.
/// The prelude has no JSON vocabulary a program may import, so a decoded
/// tree would be a type nothing could take apart; the text is what a
/// program can search, report through `cap/report`, or hand to a
/// subprocess. It is quoted history like a snippet is, and the whole
/// entry rather than an excerpt — including the arguments of whatever
/// tool call it recorded.
///
/// The entry travels inline, so a very large one is bounded by the
/// channel's own 16 MiB frame cap rather than by a spill: past that the
/// call answers `HistoryUnavailable`. Nothing the repository's own
/// writer admits comes close.
///
/// Capability: `history.read`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(found) = history.search_for("budget pooling")
/// let assert [hit, ..] = found.hits
/// let assert Ok(text) = history.read(session: hit.session, entry: hit.entry)
/// ```
///
pub fn read(
  session session: String,
  entry entry: String,
) -> Result(String, HistoryError) {
  let args =
    wire.args([
      #("session", wire.string(session)),
      #("entry", wire.string(entry)),
    ])
  use value <- result.try(
    dispatch.call("history.read", args) |> result.map_error(map_error),
  )
  wire.string_field(value, "entry")
  |> result.map_error(fn(reason) {
    HistoryUnavailable("bad history.read result: " <> reason)
  })
}

// --- the wire vocabulary -------------------------------------------------

// The two scope names, spelled here and decoded by the harness's own
// arm. They are the tool's `scope` enum verbatim, so a reader who knows
// one door knows the other.
fn scope_name(scope: Scope) -> String {
  case scope {
    Repository -> "repository"

    ThisSession -> "session"
  }
}

// --- total decoders ------------------------------------------------------

fn decode_found(value: MsgPackValue) -> Result(Found, String) {
  use hits <- result.try(wire.array_of(value, "hits", of: decode_hit))
  use limit <- result.try(wire.int_field(value, "limit"))
  Ok(Found(hits:, limit:))
}

fn decode_hit(value: MsgPackValue) -> Result(Hit, String) {
  use session <- result.try(wire.string_field(value, "session"))
  use entry <- result.try(wire.string_field(value, "entry"))
  use snippet <- result.try(wire.string_field(value, "snippet"))
  Ok(Hit(session:, entry:, snippet:))
}

// The codes are `codemode/recall`'s own constants, which are in turn the
// strings the `history_search` tool puts in its failure details — so a
// refusal a model reads through the tool and one a program branches on
// here are one fact under one name.
fn map_error(error: CallError) -> HistoryError {
  case error {
    Unreachable(reason:) -> HistoryUnavailable(reason:)

    Denied(code:, message:) ->
      case code {
        "history_unavailable" -> IndexUnavailable(reason: message)

        "history_refused" -> IndexRefused(reason: message)

        "history_not_ready" -> IndexNotReady(reason: message)

        "history_busy" -> IndexBusy(reason: message)

        "invalid_argument" -> InvalidQuery(message:)

        _other -> HistoryFailed(code:, message:)
      }
  }
}
