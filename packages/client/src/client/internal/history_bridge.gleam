//// The translation between the tool package's recall vocabulary and the
//// search index's.
////
//// `tools/history` cannot import `events/search`, so the tool states a query
//// and a hit in its own types and the host maps them. Two hosts do the
//// mapping, the per-session holder (`client/history`) and the shared domain
//// owner (`client/internal/shared_history`), and both go through this module
//// so a field added to either side is mapped in one place. The search counter
//// sits here for the same reason: both hosts wrap their seam in `counted`, so
//// a recall call is one log line whichever owner answered it.

import core/ids
import events/search
import gleam/list
import gleam/option
import gleam/result
import telemetry/field
import telemetry/log.{type Logger}
import tools/history as tool

/// The index query a tool query asks for. The tool's typed entry id becomes
/// the canonical text the index compares, and its syntax and kind map one to
/// one. The scope is not part of the index query: it decides which `search`
/// function the host calls.
///
/// ## Examples
///
/// ```gleam
/// // history_bridge.index_query(tool.query("retry", 10, tool.Repository))
/// ```
pub fn index_query(query: tool.Query) -> search.Query {
  search.Query(
    text: query.text,
    syntax: case query.syntax {
      tool.Words -> search.Words
      tool.Raw -> search.Raw
    },
    kind: query.kind,
    before: option.map(query.before, ids.entry_id_to_string),
    limit: query.limit,
  )
}

/// A tool hit from an index hit.
///
/// ## Examples
///
/// ```gleam
/// // history_bridge.tool_hit(hit).kind == hit.kind
/// ```
pub fn tool_hit(hit: search.Hit) -> tool.Hit {
  tool.Hit(
    session: hit.session,
    entry: hit.entry,
    kind: hit.kind,
    ts: hit.ts,
    snippet: hit.snippet,
  )
}

/// Wraps a recall seam so every `search` and `recent` call writes one
/// `memory.search_called` info line.
///
/// The line carries the scope, the number of hits (`hits`) and how many of
/// them were remembered notes (`note_hits`). It never carries the query text:
/// what the model asked about is its own business, and the counter exists to
/// say how often recall is used and whether it finds notes, not what for. A
/// refused call writes nothing, because it has no result count to report.
/// `read` is a lookup by identity rather than a search, so it is not counted.
///
/// ## Examples
///
/// ```gleam
/// // history_bridge.counted(raw_seam, logger)
/// ```
pub fn counted(seam: tool.History, logger: Logger) -> tool.History {
  tool.History(
    ..seam,
    search: fn(query) {
      seam.search(query) |> noted(logger, scope_name(query.scope), _)
    },
    recent: fn(limit) {
      seam.recent(limit) |> noted(logger, scope_name(tool.ThisSession), _)
    },
  )
}

fn noted(
  logger: Logger,
  scope: String,
  answer: Result(List(tool.Hit), tool.Refusal),
) -> Result(List(tool.Hit), tool.Refusal) {
  let _counted =
    result.map(answer, fn(hits) {
      log.info(logger, "memory.search_called", [
        field.text(key: "scope", value: scope),
        field.count(key: "hits", value: list.length(hits)),
        field.count(
          key: "note_hits",
          value: list.count(hits, fn(hit) { hit.kind == "note" }),
        ),
      ])
    })
  answer
}

fn scope_name(scope: tool.Scope) -> String {
  case scope {
    tool.Repository -> "repository"
    tool.ThisSession -> "this_session"
  }
}
