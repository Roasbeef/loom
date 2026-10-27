//// The operator board: one bounded JSON answer for a page that draws the whole
//// evolution catalogue.
////
//// The older read actions answer a question about one item and page their
//// replies, so a panel built on them would need a call per candidate to learn
//// its kind, approval or evidence. `board` answers the whole panel at once,
//// and this module is the place its shape and its size bound are decided. It
//// is pure: `control` gathers the catalogue read, the live generation and the
//// queue's waiting transitions, and this module turns them into JSON. That
//// keeps the bound testable without a catalogue.
////
//// ## Flow
////
//// `value` renders each candidate and each audit entry once, and measures it.
//// `shed` then drops the oldest audit entries, and after them the oldest
//// candidates, until the encoded board fits in the byte bound. `render`
//// assembles what is left, with counts of what was dropped, so a reader never
//// mistakes a cut board for a complete one. A selection leaves with its
//// candidate, because the board's selections are those of the candidates it
//// still shows.
////
//// The reply is a snapshot of a bounded window and not a ledger. The audit
//// journal stays in the catalogue, and the command line's inspect and evidence
//// actions read what the board leaves out.

import client/evolution/queue
import client/evolution/record
import client/evolution/store
import core/json
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The reply's byte bound, which is also the bound on a command's arguments.
pub const max_bytes = 49_152

/// The wire version of the board's shape.
pub const version = 1

/// The generation a session currently runs, as the board reports it.
pub type Published {
  Published(
    /// The selection the running generation implements.
    selection: record.Selection,
    /// The native helper census of its dedicated plane, or `Null`.
    inventory: json.JsonValue,
  )
}

/// Everything `value` needs, gathered by the caller.
pub type Input {
  Input(
    /// The session the board describes.
    session_id: String,
    /// The host's current evaluator identity, which decides which candidates
    /// and observations are still current.
    identity: record.Identity,
    /// The catalogue read, already filtered to what the caller may see.
    board: store.Board,
    /// The running generation, when there is one.
    published: Option(Published),
    /// The transitions accepted and not finished.
    waiting: List(queue.Waiting),
  )
}

// A rendered row and the bytes it will take, so shedding never encodes twice.
type Sized(a) {
  Sized(item: a, value: json.JsonValue, bytes: Int)
}

/// Renders the board and trims it to `max_bytes`.
///
/// ## Examples
///
/// ```gleam
/// // board.value(Input(session_id, identity, read, published, waiting))
/// ```
pub fn value(input: Input) -> json.JsonValue {
  let selections = list.map(input.board.selections, selection_row(_, input))
  let candidates =
    list.map(input.board.rows, fn(row) {
      charged(candidate_row(input.identity, row), selections)
    })
  let history = list.map(input.board.history, event_row)
  let fixed = fixed_bytes(input, candidates, history)
  let total = fixed + list.fold(candidates, 0, add) + list.fold(history, 0, add)

  // History goes first. A reader who needs an old decision can still read the
  // journal through the CLI, and a candidate cannot be drawn from anywhere else.
  let #(history, history_dropped, excess) =
    shed(history, int.max(0, total - max_bytes))
  let #(candidates, candidates_dropped, _) = shed(candidates, excess)

  render(
    input,
    candidates,
    selections,
    history,
    candidates_dropped,
    input.board.history_omitted + history_dropped,
  )
}

fn add(total: Int, row: Sized(a)) -> Int {
  total + row.bytes + 1
}

/// Incorporates the serialized byte size of associated selections into a candidate row's
/// charged byte size to ensure joint truncation.
fn charged(
  row: Sized(store.Row),
  selections: List(Sized(record.Selection)),
) -> Sized(store.Row) {
  let id = row.item.candidate.id
  let owed =
    list.filter(selections, fn(selection) { selection.item.candidate_id == id })
    |> list.fold(0, add)
  Sized(..row, bytes: row.bytes + owed)
}

/// Computes the fixed baseline JSON byte size of the board structure excluding dynamically
/// pruned candidate rows and history entries.
fn fixed_bytes(
  input: Input,
  candidates: List(Sized(store.Row)),
  history: List(Sized(store.Event)),
) -> Int {
  render(
    input,
    [],
    [],
    [],
    list.length(candidates),
    input.board.history_omitted + list.length(history),
  )
  |> json.to_string
  |> string.byte_size
}

/// Prunes rows starting from the oldest until the total byte excess has been reclaimed.
fn shed(rows: List(Sized(a)), excess: Int) -> #(List(Sized(a)), Int, Int) {
  list.fold(list.reverse(rows), #([], 0, excess), fn(state, row) {
    let #(kept, dropped, owed) = state

    // Drop the row if excess bytes are still owed.
    case owed > 0 {
      True -> #(kept, dropped + 1, owed - row.bytes - 1)
      False -> #([row, ..kept], dropped, owed)
    }
  })
}

/// Renders the complete evolution board JSON document from retained candidates, active
/// selections, history events, and omission counters.
fn render(
  input: Input,
  candidates: List(Sized(store.Row)),
  selections: List(Sized(record.Selection)),
  history: List(Sized(store.Event)),
  candidates_omitted: Int,
  history_omitted: Int,
) -> json.JsonValue {
  let shown =
    list.map(candidates, fn(row) { record.id_string(row.item.candidate.id) })
  let selections =
    list.filter(selections, fn(row) {
      list.contains(shown, record.id_string(row.item.candidate_id))
    })

  json.Object([
    #("version", json.Int(version)),
    #("session", json.String(input.session_id)),
    #("candidates", json.Array(list.map(candidates, fn(row) { row.value }))),
    #("selections", json.Array(list.map(selections, fn(row) { row.value }))),
    #("published", published_value(input.published)),
    #("pending", json.Array(list.map(input.waiting, waiting_value))),
    #("history", json.Array(list.map(history, fn(row) { row.value }))),
    #(
      "omitted",
      json.Object([
        #("candidates", json.Int(candidates_omitted)),
        #("history", json.Int(history_omitted)),
      ]),
    ),
  ])
}

fn sized(item: a, value: json.JsonValue) -> Sized(a) {
  Sized(item:, value:, bytes: string.byte_size(json.to_string(value)))
}

/// Serializes and measures a candidate table row including approval status and test evidence.
fn candidate_row(
  identity: record.Identity,
  row: store.Row,
) -> Sized(store.Row) {
  let candidate = row.candidate
  sized(
    row,
    json.Object([
      #("candidate_id", json.String(record.id_string(candidate.id))),
      #("name", json.String(candidate.name)),
      #("kind", json.String(kind_word(candidate.kind))),
      #("scope", scope_value(candidate.scope)),
      #("description", json.String(candidate.description)),
      #("parent", case candidate.origin.parent {
        Some(parent) -> json.String(record.id_string(parent))
        None -> json.Null
      }),
      #(
        "origin",
        json.Object([
          #("session", json.String(candidate.origin.session_id)),
          #("strand", json.String(candidate.origin.strand)),
        ]),
      ),
      #("identity_current", json.Bool(candidate.identity == identity)),
      #("approval", approval_value(row.approval)),
      #(
        "evidence",
        json.Array(list.map(row.evidence, evidence_value(identity, _))),
      ),
      #("selected", case row.selected {
        Some(selection) ->
          json.Object([
            #("generation", json.Int(selection.generation)),
            #(
              "evidence_id",
              json.String(record.evidence_string(selection.evidence_id)),
            ),
          ])
        None -> json.Null
      }),
    ]),
  )
}

/// Returns the string representation of an evolution candidate kind variant.
fn kind_word(kind: record.Kind) -> String {
  case kind {
    record.Extension -> "extension"
    record.Program -> "program"
    record.Prompt -> "prompt"
  }
}

/// Encodes an evolution candidate scope definition into a JSON object.
fn scope_value(scope: record.Scope) -> json.JsonValue {
  case scope {
    record.Session(id) ->
      json.Object([
        #("kind", json.String("session")),
        #("session", json.String(id)),
      ])
    record.Workspace(path) ->
      json.Object([
        #("kind", json.String("workspace")),
        #("workspace", json.String(path)),
      ])
    record.ExactModel(target) ->
      json.Object([
        #("kind", json.String("model")),
        #("provider", json.String(target.provider)),
        #("model", json.String(target.model)),
        #("api", json.String(target.api)),
      ])
  }
}

/// Formats operator approval details including timestamp and grantor identity into JSON.
fn approval_value(approval: Option(store.Approval)) -> json.JsonValue {
  case approval {
    None -> json.Null
    Some(approval) ->
      json.Object([
        #(
          "evidence_id",
          json.String(record.evidence_string(approval.evidence_id)),
        ),
        #("by", json.String(approval.principal)),
        #("via", json.String(approval.via)),
      ])
  }
}

/// Formats candidate evaluation evidence and indicates whether it matches the current build identity.
fn evidence_value(
  identity: record.Identity,
  evidence: record.Evidence,
) -> json.JsonValue {
  // Map evaluation verdict variants to string labels and reason text.
  let #(verdict, reason) = case evidence.verdict {
    record.Passed -> #("passed", "")
    record.Failed -> #("failed", "")
    record.Inconclusive(reason) -> #("inconclusive", reason)
  }

  json.Object([
    #("evidence_id", json.String(record.evidence_string(evidence.id))),
    #("purpose", json.String(purpose_word(evidence.purpose))),
    #("verdict", json.String(verdict)),
    #("reason", json.String(reason)),
    #("at_ms", json.Int(evidence.at_ms)),
    #("identity_current", json.Bool(evidence.identity == identity)),
  ])
}

fn purpose_word(purpose: record.Purpose) -> String {
  case purpose {
    record.AuthorTests -> "author_tests"
    record.IndependentRollout -> "independent_rollout"
  }
}

/// Formats a selection entry and checks if it corresponds to the currently published live version.
fn selection_row(
  selection: record.Selection,
  input: Input,
) -> Sized(record.Selection) {
  // Determine if this selection is the currently active published selection.
  let running = case input.published {
    Some(published) -> published.selection == selection
    None -> False
  }

  sized(
    selection,
    json.Object([
      #("scope", scope_value(selection.scope)),
      #("name", json.String(selection.name)),
      #("candidate_id", json.String(record.id_string(selection.candidate_id))),
      #(
        "evidence_id",
        json.String(record.evidence_string(selection.evidence_id)),
      ),
      #("generation", json.Int(selection.generation)),
      #("published", json.Bool(running)),
    ]),
  )
}

/// Encodes the currently published evolution candidate selection and its exposed tool inventory.
fn published_value(published: Option(Published)) -> json.JsonValue {
  // Encode active published candidate metadata or emit null if none is published.
  case published {
    None -> json.Null
    Some(published) -> {
      let selection = published.selection
      json.Object([
        #("candidate_id", json.String(record.id_string(selection.candidate_id))),
        #("name", json.String(selection.name)),
        #("generation", json.Int(selection.generation)),
        #("inventory", published.inventory),
      ])
    }
  }
}

/// Serializes an in-flight evolution queue item into JSON format.
fn waiting_value(waiting: queue.Waiting) -> json.JsonValue {
  json.Object([
    #("request_id", json.String(waiting.request_id)),
    #(
      "state",
      json.String(case waiting.phase {
        queue.Staging -> "running"
        queue.Accepted -> "queued"
      }),
    ),
    #("candidate_id", json.String(record.id_string(waiting.candidate_id))),
    #("expires_at_ms", json.Int(waiting.expires_at)),
  ])
}

/// Formats and measures an audit event row in the evolution board log.
fn event_row(event: store.Event) -> Sized(store.Event) {
  sized(
    event,
    json.Object([
      #("seq", json.Int(event.seq)),
      #("at_ms", json.Int(event.at_ms)),
      #("event", json.String(event.kind)),
      #("candidate_id", json.String(event.candidate_id)),
      #("name", json.String(event.name)),
      #("generation", case event.generation {
        Some(generation) -> json.Int(generation)
        None -> json.Null
      }),
      #("principal", json.String(event.principal)),
      #("via", json.String(event.via)),
      #("reason", json.String(event.reason)),
      #("request_id", json.String(event.request_id)),
    ]),
  )
}
