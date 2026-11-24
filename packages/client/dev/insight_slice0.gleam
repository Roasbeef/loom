//// Slice 0 of insight triage: the offline test of whether a cheap model's
//// order beats newest first at putting the rows the owner would open first
//// among the top three (`docs/design-notes/insight-triage.md`, sections 8.3
//// and 9). It is a developer script. It adds no protocol change and no daemon
//// code, and it reads only copies of the owner's stores.
////
//// ```text
//// gleam dev -m insight_slice0 -- select  <dir>
//// gleam dev -m insight_slice0 -- sheet   <dir>
//// gleam dev -m insight_slice0 -- run     <dir> <loom.toml> <role>
//// gleam dev -m insight_slice0 -- verdict <dir>
//// ```
////
//// `<dir>` holds `store/catalogue.db` and `store/sessions/<id>.db`, which are
//// copies made with `sqlite3 <source> ".backup '<copy>'"`. Nothing here opens
//// a live store: the session layer takes a writer lease on open, and a copy
//// is the only file it may take one on. A copy of a live session may carry
//// an unexpired lease, so the stores are opened under a clock far in the
//// future, which makes any such lease expired.
////
//// ## Flow
////
//// `select` → `sheet` → the owner marks the sheet → `run` → `verdict`
////
//// 1. `select` rebuilds each finished session's lane with the projection the
////    web view uses (`client/insight/lane`), lifts its rows with the
////    classifier, keeps the sessions with at least `minimum_rows` insight
////    rows, and writes the most recent `wanted` of them to `selection.json`.
//// 2. `sheet` writes `label-sheet.md` for the owner and `rows.json` beside it.
//// 3. `run` builds each session's request, sends it through the provider
////    code under the owner's routing for a role, and records the request and
////    the answer under `runs/`. A session whose record already holds the same
////    request is replayed from it and costs nothing.
//// 4. `verdict` reads the marked sheet and the records and prints the
////    comparison, the minimum detectable effect first.
////
//// ## What is never printed
////
//// The catalogue names the environment variable a key is read from, and the
//// secret store reads it at dispatch. This module prints the role, the entry
//// and the model identifier a record names, and never a key.

import argv
import client/auxiliary
import client/catalog
import client/insight/answer
import client/insight/lane
import client/insight/record
import client/insight/request
import client/insight/score
import client/insight/sheet
import client/internal/ffi_os
import core/clock
import core/register
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/strand
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/secret
import session/session
import session_view/turns.{type Piece}
import simplifile
import sqlight
import storage/storage
import web_view/view/lifted

/// How many insight rows a session needs to be a candidate for the test.
const minimum_rows = 8

/// How many sessions the sheet asks the owner to mark.
const wanted = 30

/// The time the stores are opened at, in Unix milliseconds: far enough ahead
/// that a writer lease copied from a live session has expired.
const far_future = 4_000_000_000_000

/// The most a session's request may wait for the model, in milliseconds.
const answer_timeout_ms = 120_000

/// The ceiling on the model's answer, from the design note's cost table.
const answer_tokens = 400

/// Runs the command named on the command line.
pub fn main() {
  case argv.load().arguments {
    ["select", dir] -> finish(select(dir))
    ["sheet", dir] -> finish(write_sheet(dir))
    ["run", dir, config, role] -> finish(run(dir, config, role))
    ["verdict", dir] -> finish(verdict(dir))
    _ -> io.println(usage)
  }
}

/// What a bad command line prints.
const usage =
  "usage: gleam dev -m insight_slice0 -- select <dir>
       gleam dev -m insight_slice0 -- sheet <dir>
       gleam dev -m insight_slice0 -- run <dir> <loom.toml> <role>
       gleam dev -m insight_slice0 -- verdict <dir>"

/// Prints a command's report, or its failure and a non-zero exit.
fn finish(outcome: Result(String, String)) -> Nil {
  case outcome {
    Ok(report) -> io.println(report)
    Error(reason) -> {
      io.println_error("error: " <> reason)
      ffi_os.halt(1)
    }
  }
}

// --- select ----------------------------------------------------------------

/// A finished session's lane and when it last moved.
type Opened {
  Opened(
    /// The lane's pieces, oldest first.
    pieces: List(Piece),
    /// When the newest entry was stored, in Unix milliseconds.
    at: Int,
  )
}

/// What the census learned about one store.
type Studied {
  /// The session finished, and these are the rows its lane lifts.
  Studied(id: String, at: Int, rows: List(lane.Candidate))

  /// The session had an operation in flight, or never ran.
  Unfinished

  /// The store could not be read.
  Unreadable(reason: String)
}

/// Reads every copied store and writes the most recent qualifying sessions
/// to `selection.json`.
fn select(dir: String) -> Result(String, String) {
  use names <- result.try(session_names(dir <> "/store/catalogue.db"))
  use files <- result.try(
    simplifile.get_files(dir <> "/store/sessions")
    |> result.replace_error("the copied sessions directory cannot be read"),
  )
  let stores =
    list.filter(files, string.ends_with(_, ".db"))
    |> list.sort(string.compare)
  let studied = list.map(stores, study)
  let finished =
    list.filter(studied, fn(found) {
      case found {
        Studied(..) -> True
        Unfinished | Unreadable(..) -> False
      }
    })
  let qualifying =
    list.filter(finished, fn(found) { enough_rows(found) })
    |> list.sort(fn(left, right) { int.compare(at_of(right), at_of(left)) })
  let picked = list.take(qualifying, wanted)

  use _ <- result.try(
    list.filter_map(picked, fn(found) { sheet_session(found, names) })
    |> sheet.selection_json
    |> simplifile.write(dir <> "/selection.json", _)
    |> result.replace_error("selection.json cannot be written"),
  )

  Ok(census(studied, finished, qualifying, picked))
}

/// Whether a studied session has the rows the test needs.
fn enough_rows(found: Studied) -> Bool {
  case found {
    Studied(rows:, ..) -> list.length(rows) >= minimum_rows
    Unfinished | Unreadable(..) -> False
  }
}

/// When a studied session last moved.
fn at_of(found: Studied) -> Int {
  case found {
    Studied(at:, ..) -> at
    Unfinished | Unreadable(..) -> 0
  }
}

/// The count lines `select` prints.
fn census(
  studied: List(Studied),
  finished: List(Studied),
  qualifying: List(Studied),
  picked: List(Studied),
) -> String {
  let count = fn(items: List(Studied)) { int.to_string(list.length(items)) }
  let unreadable =
    list.filter(studied, fn(found) {
      case found {
        Unreadable(..) -> True
        Studied(..) | Unfinished -> False
      }
    })

  string.join(
    [
      "stores copied: " <> count(studied),
      "finished: " <> count(finished),
      "unreadable: " <> count(unreadable),
      "qualified, with at least "
        <> int.to_string(minimum_rows)
        <> " insight rows: "
        <> count(qualifying),
      "selected, most recent first: " <> count(picked),
    ],
    "\n",
  )
}

/// A session's rows as the sheet shows them: at most one request's worth,
/// newest first.
fn sheet_session(
  found: Studied,
  names: Dict(String, String),
) -> Result(sheet.SheetSession, Nil) {
  case found {
    Unfinished | Unreadable(..) -> Error(Nil)
    Studied(id:, at:, rows:) ->
      Ok(sheet.SheetSession(
        id:,
        name: dict.get(names, id) |> result.unwrap(id),
        at:,
        rows: list.take(rows, request.standard.max_rows)
          |> list.map(fn(candidate) {
            sheet.SheetRow(
              key: candidate.row.key,
              kind: lifted.kind_word(candidate.row),
              head: candidate.row.head,
            )
          }),
      ))
  }
}

/// Reads one copied store.
fn study(path: String) -> Studied {
  case open_lane(path) {
    Error(reason) -> Unreadable(reason)
    Ok(None) -> Unfinished
    Ok(Some(opened)) ->
      Studied(
        id: session_id(path),
        at: opened.at,
        rows: lane.candidates(opened.pieces),
      )
  }
}

/// The session a store file holds, from its name.
fn session_id(path: String) -> String {
  string.split(path, "/")
  |> list.last
  |> result.unwrap(path)
  |> string.replace(".db", "")
}

/// The store file of a session under the copied directory.
fn store_path(dir: String, id: String) -> String {
  dir <> "/store/sessions/" <> id <> ".db"
}

/// Opens a copied store, reads the primary strand's branch and closes it. A
/// session whose primary strand has an operation in flight, or no leaf, is
/// `None`.
fn open_lane(path: String) -> Result(Option(Opened), String) {
  use opened <- result.try(
    session.open_sqlite(
      path:,
      owner: "insight-slice0",
      lease_ttl_ms: 600_000,
      clock: clock.fixed(at: far_future),
    )
    |> result.map_error(fn(error) { "open failed: " <> string.inspect(error) }),
  )
  let read = read_lane(opened)
  let _ = session.close(opened)

  read
}

/// The primary strand's lane, when the strand has finished.
fn read_lane(opened: session.Session) -> Result(Option(Opened), String) {
  use state <- result.try(
    session.strand_state(opened, lane.primary) |> failed("strand state"),
  )
  use leaf <- result.try(
    session.strand_leaf(opened, lane.primary) |> failed("strand leaf"),
  )

  case state, leaf {
    Some(session.Cell(
      value: strand.StrandState(current_operation: None, ..),
      ..,
    )),
      Some(session.Cell(value: Some(newest), ..))
    -> {
      use entries <- result.try(
        storage.scan_branch(opened.store, storage.branch_scan(from: newest))
        |> failed("branch scan"),
      )
      use leaves <- result.try(
        storage.list_registers(opened.store, register.StrandLeaf, None)
        |> failed("strand list"),
      )
      let at = case entries {
        [latest, ..] -> latest.ts
        [] -> 0
      }

      Ok(
        Some(Opened(
          pieces: lane.pieces(
            entries,
            strands: list.map(leaves, fn(pair) { pair.0 }),
          ),
          at:,
        )),
      )
    }
    _, _ -> Ok(None)
  }
}

/// Words a store error for the census.
fn failed(read: Result(a, e), what: String) -> Result(a, String) {
  result.map_error(read, fn(error) { what <> ": " <> string.inspect(error) })
}

/// Every session's name, from the copied catalogue: the owner's rename when
/// there is one, and the name the session was created with otherwise.
fn session_names(path: String) -> Result(Dict(String, String), String) {
  use db <- result.try(sqlight.open(path) |> failed("catalogue"))
  let named =
    sqlight.query(
      "select s.session_id, coalesce(n.name, s.name) from catalogue_sessions s
       left join catalogue_session_names n on n.session_id = s.session_id",
      on: db,
      with: [],
      expecting: {
        use id <- decode.field(0, decode.string)
        use name <- decode.field(1, decode.string)
        decode.success(#(id, name))
      },
    )
  let _ = sqlight.close(db)

  named |> result.map(dict.from_list) |> failed("catalogue names")
}

// --- sheet -----------------------------------------------------------------

/// Writes the sheet the owner marks and its machine-readable twin.
fn write_sheet(dir: String) -> Result(String, String) {
  use selection <- result.try(read_selection(dir))
  use _ <- result.try(
    simplifile.write(dir <> "/label-sheet.md", sheet.render(selection))
    |> failed("label-sheet.md"),
  )
  use _ <- result.try(
    simplifile.write(dir <> "/rows.json", sheet.rows_json(selection))
    |> failed("rows.json"),
  )

  Ok(
    "sheet written for "
    <> int.to_string(list.length(selection))
    <> " sessions: "
    <> dir
    <> "/label-sheet.md",
  )
}

/// The sessions `select` chose.
fn read_selection(dir: String) -> Result(List(sheet.SheetSession), String) {
  use text <- result.try(
    simplifile.read(dir <> "/selection.json")
    |> failed("selection.json (run select first)"),
  )

  sheet.read_selection(text)
}

// --- run -------------------------------------------------------------------

/// Sends each selected session's request to the model the owner's catalogue
/// routes for `role_name`, and records the answers under `runs/`.
fn run(
  dir: String,
  config: String,
  role_name: String,
) -> Result(String, String) {
  use selection <- result.try(read_selection(dir))
  use role <- result.try(role_of(role_name))
  use text <- result.try(simplifile.read(config) |> failed("the config file"))
  use catalogue <- result.try(catalog.parse(text))
  let gateway =
    catalog.gateway(
      catalogue,
      transport: http.httpc_transport(),
      secrets: secret.env(),
      clock: clock.from_function(ffi_os.system_time_ms),
    )
  use routed <- result.try(
    provider_gateway.resolve(gateway, role)
    |> result.replace_error("the catalogue routes no model for " <> role_name),
  )
  let summarizer =
    auxiliary.capped_gateway_summarizer(
      gateway,
      model.ForRole(role:, thinking: Some(model.ThinkingOff)),
      timeout_ms: answer_timeout_ms,
      max_output_tokens: answer_tokens,
    )
  use _ <- result.try(
    simplifile.create_directory_all(dir <> "/runs") |> failed("runs directory"),
  )
  let identity = routed.provider <> " " <> routed.model_id

  list.try_map(selection, run_session(dir, role_name, identity, summarizer, _))
  |> result.map(string.join(_, "\n"))
}

/// The role a command line names.
fn role_of(name: String) -> Result(model.Role, String) {
  case name {
    "main" -> Ok(model.Main)
    "subagent" -> Ok(model.Subagent)
    "plan" -> Ok(model.Plan)
    "summarize" -> Ok(model.Summarize)
    "vision" -> Ok(model.Vision)
    "advisor" -> Ok(catalog.advisor_role)
    "router" -> Ok(catalog.router_role)
    other -> Error(other <> " is not a role the catalogue can route")
  }
}

/// One session's request, replayed from its record when the record holds the
/// same prompt and sent to the model otherwise.
fn run_session(
  dir: String,
  role_name: String,
  identity: String,
  summarizer: auxiliary.Summarizer,
  chosen: sheet.SheetSession,
) -> Result(String, String) {
  use opened <- result.try(open_lane(store_path(dir, chosen.id)))
  use found <- result.try(option.to_result(
    opened,
    chosen.id <> " no longer reads as finished",
  ))
  let candidates = lane.candidates(found.pieces)
  let shown = list.take(candidates, request.standard.max_rows)

  // The sheet was marked against these rows, so a store that now lifts others
  // would score the owner's marks against the wrong rows.
  use _ <- result.try(
    case
      list.map(shown, fn(candidate) { candidate.row.key })
      == list.map(chosen.rows, fn(row) { row.key })
    {
      True -> Ok(Nil)
      False -> Error(chosen.id <> " lifts different rows than the sheet shows")
    },
  )
  let built = request.build(found.pieces, candidates, request.standard)
  let path = dir <> "/runs/" <> chosen.id <> ".json"

  case replayed(path, built.prompt) {
    True -> Ok(chosen.id <> ": replayed, no spend")
    False ->
      summarizer.ask(built.prompt)
      |> result.map_error(fn(failure) { chosen.id <> ": " <> failure.reason })
      |> result.try(fn(reply) {
        record.Record(
          session: chosen.id,
          role: role_name,
          model: identity,
          prompt: built.prompt,
          answer: reply.text,
          rows: list.map(built.rows, fn(candidate) { candidate.row.key }),
        )
        |> record.encode
        |> simplifile.write(path, _)
        |> failed(path)
        |> result.replace(chosen.id <> ": answered")
      })
  }
}

/// Whether a record on disk holds exactly this prompt.
fn replayed(path: String, prompt: String) -> Bool {
  case
    simplifile.read(path) |> result.try(fn(text) { Ok(record.decode(text)) })
  {
    Ok(Ok(held)) -> held.prompt == prompt
    Ok(Error(_)) | Error(_) -> False
  }
}

// --- verdict ---------------------------------------------------------------

/// Scores the recorded answers against the owner's marks.
fn verdict(dir: String) -> Result(String, String) {
  use selection <- result.try(read_selection(dir))
  use counts_text <- result.try(
    simplifile.read(dir <> "/rows.json") |> failed("rows.json"),
  )
  use counts <- result.try(sheet.row_counts(counts_text))
  use marked <- result.try(
    simplifile.read(dir <> "/label-sheet.md") |> failed("label-sheet.md"),
  )
  let marks = sheet.marks(marked)
  use judged <- result.try(
    list.try_map(selection, judge(dir, counts, marks, _)),
  )
  let refused = list.count(judged, fn(each) { each.1 == Refused })

  Ok(
    score.render(score.report(list.map(judged, fn(each) { each.0 })))
    <> "\n\nAnswers refused whole (scored as all normal): "
    <> int.to_string(refused),
  )
}

/// Whether a session's answer was usable.
type Reading {
  Read
  Refused
}

/// One session's rows, marked and weighed.
fn judge(
  dir: String,
  counts: Dict(String, Int),
  marks: Dict(String, List(#(Int, sheet.Mark))),
  chosen: sheet.SheetSession,
) -> Result(#(score.Judged, Reading), String) {
  let rows = list.length(chosen.rows)

  use _ <- result.try(case dict.get(counts, chosen.id) {
    Ok(held) if held == rows -> Ok(Nil)
    _ -> Error(chosen.id <> ": rows.json does not number the rows selected")
  })
  use marked <- result.try(
    dict.get(marks, chosen.id)
    |> result.replace_error(chosen.id <> ": the sheet has no marks for it"),
  )
  use _ <- result.try(case list.length(marked) == rows {
    True -> Ok(Nil)
    False -> Error(chosen.id <> ": the sheet lost or added a row")
  })
  use text <- result.try(
    simplifile.read(dir <> "/runs/" <> chosen.id <> ".json")
    |> failed(chosen.id <> " has no record, so run it first"),
  )
  use held <- result.try(record.decode(text))
  let asked = list.length(held.rows)
  let opened =
    list.filter_map(marked, fn(mark) {
      case mark.1 {
        sheet.Open -> Ok(mark.0)
        sheet.Skip -> Error(Nil)
      }
    })
  let #(labels, reading) = case answer.parse(held.answer, asked) {
    Ok(parsed) -> #(parsed, Read)
    Error(_) -> #([], Refused)
  }

  Ok(#(
    score.Judged(session: chosen.id, rows: score.rank(asked, labels, opened)),
    reading,
  ))
}
