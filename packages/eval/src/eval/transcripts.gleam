//// Session transcripts for the failure taxonomy: a scrubbed, per-session
//// JSONL export of what the daemon already recorded, and a reproducible
//// stratified sample of it for people to label.
////
//// The failure taxonomy has to come from what agents actually did, before
//// anyone writes a task to test for it (design note §9). The daemon's session
//// databases are that record, but they are the live conversation: they hold
//// the writer lease, and anything read from them is not safe to leave lying
//// about. So the export never opens an original. Each database (and its WAL
//// and shared-memory siblings, which carry the commits not yet checkpointed)
//// is copied under `<out>/.copies/`, never `/tmp`, where the code-mode jail
//// replaces the directory; the copy is opened, walked and deleted whether or
//// not the walk succeeded. A copy of a session whose daemon still holds an
//// unexpired lease is refused by the copy's own open, and that session is
//// reported in the census as a failure rather than read around the lease:
//// stop the daemon, or let the lease lapse, and export again.
////
//// ## Flow
////
//// 1. `export` finds `<state>/sessions/*.db`; `export_dbs` takes an explicit
////    list instead.
//// 2. `export_session` copies, opens, walks entries and the usage ledger,
////    asks the evolution trace's own reader for each assistant entry's
////    operator mark, and writes `<out>/<stem>.jsonl`.
//// 3. `sample` reads only the first line of each file, the header, groups the
////    sessions by model id and outcome, shuffles within each group with a
////    seeded generator and deals round-robin so every group is represented.
////
//// ## What a file holds
////
//// One header line, then one record per entry in sequence order, then the
//// usage rows. The header states the scrubber's limits verbatim, because a
//// reader who takes the export for sanitised will be wrong: the scrubber is a
//// heuristic. The file is for the owner's eyes and is not committed.
////
//// Thinking blocks, signatures and images are excluded, as the trace excerpt
//// excludes them. Tool calls keep their name, the keys of their arguments and
//// a 256-byte scrubbed preview; tool results keep `is_error` and the last 512
//// bytes of their text, scrubbed, because a failing command says why at its
//// end. An assistant entry's outcome is read through `trace.join`, the one
//// public reader of the operator mark, and is the explicit word `unmarked`
//// when no mark exists: absence of a verdict is never a failure or a success.

import client/evolution/record
import client/evolution/trace
import client/internal/ffi_os
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import evalstat/prng
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import session/session
import simplifile
import storage/storage
import telemetry/field

/// The scrubber's limits as `client/evolution/trace` documents them, printed
/// in every file header so no reader mistakes the scrub for a guarantee.
pub const scrubber_limits =
  "This version is a heuristic: short unlabelled secrets and private prose can remain. Thinking, opaque signatures, images and provider diagnostics are excluded. A missing operator mark is `Unmarked`, never a failed or successful task."

/// What an export saw across every session it was asked to read.
pub type Census {
  Census(
    /// Sessions written to a file.
    sessions: Int,
    /// Entries written, across all sessions.
    entries: Int,
    /// Assistant entries carrying an operator mark.
    marked: Int,
    /// Assistant entries with no operator mark.
    unmarked: Int,
    /// Sessions left out because no entry was at or after the cut-off.
    skipped: Int,
    /// Assistant entries per `provider/model` id, sorted by id.
    by_model: List(#(String, Int)),
    /// Sessions that could not be exported, each with its reason.
    failed: List(Failure),
  )
}

/// One session the export could not read.
pub type Failure {
  Failure(
    /// The database path the caller named or the state directory held.
    path: String,
    /// Why it was refused, naming the step that failed.
    reason: String,
  )
}

/// What one session contributed, before it is folded into the census.
type Summary {
  /// The session had nothing at or after the cut-off.
  Skipped

  /// The session was written.
  Written(entries: Int, marked: Int, unmarked: Int, models: List(String))
}

/// Which end of a text a byte budget keeps.
type Keep {
  Head
  Tail
}

/// Exports every session database under `<state_dir>/sessions` that holds an
/// entry at or after `since_ms`, one scrubbed JSONL file per session in
/// `out_dir`.
///
/// ## Examples
///
/// ```gleam
/// // transcripts.export("/var/lib/loom", 1_760_000_000_000, "/home/o/transcripts")
/// ```
pub fn export(
  state_dir: String,
  since_ms: Int,
  out_dir: String,
) -> Result(Census, String) {
  use dbs <- result.try(discover(state_dir))
  export_dbs(dbs, since_ms, out_dir)
}

/// Exports the named databases. The copies directory exists only for the
/// duration of the call; a copy that cannot be removed is an error, because a
/// stray copy is a second, unscrubbed transcript.
///
/// ## Examples
///
/// ```gleam
/// // transcripts.export_dbs(["/var/lib/loom/sessions/a.db"], 0, "/home/o/out")
/// ```
pub fn export_dbs(
  dbs: List(String),
  since_ms: Int,
  out_dir: String,
) -> Result(Census, String) {
  let copies = out_dir <> "/.copies"
  use Nil <- result.try(distinct_stems(dbs))
  use Nil <- result.try(make_private_directory(out_dir))
  use Nil <- result.try(make_private_directory(copies))

  let census =
    list.index_fold(dbs, empty_census(), fn(census, db, index) {
      let summary = export_session(db, index, since_ms, out_dir, copies)
      add_to_census(census, db, summary)
    })

  // The directory is removed last and unconditionally; per-session cleanup
  // has already run, so anything left here is a copy that escaped it.
  use Nil <- result.try(
    simplifile.delete(copies)
    |> result.map_error(fn(error) {
      "could not remove " <> copies <> ": " <> simplifile.describe_error(error)
    }),
  )

  Ok(finish_census(census))
}

/// Chooses a stratified sample of the session files in `census_dir`, at most
/// `n`, by model id and operator outcome. The same directory, `n` and `seed`
/// always give the same list, so a labelling batch can be reissued; the
/// round-robin deal guarantees that a rare stratum is represented before a
/// common one is represented twice.
///
/// ## Examples
///
/// ```gleam
/// // transcripts.sample("/home/o/transcripts", 40, "taxonomy-2026-10")
/// ```
pub fn sample(census_dir: String, n: Int, seed: String) -> List(String) {
  let strata =
    jsonl_files(census_dir)
    |> list.filter_map(fn(path) {
      read_stratum(path) |> result.map(fn(stratum) { #(stratum, path) })
    })
    |> list.group(fn(pair) { pair.0 })
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })

  let #(_, queues) =
    list.map_fold(strata, prng.from_string(seed), fn(generator, group) {
      shuffle(list.map(group.1, fn(pair) { pair.1 }), generator)
    })

  deal(queues, n, [])
}

// The sessions the daemon keeps under `sessions/`, one database each. Only
// the `.db` files are listed; the `-wal` and `-shm` siblings are copied with
// their database, not exported as sessions of their own.

/// Lists `<state_dir>/sessions/*.db`, sorted so a census is reproducible.
fn discover(state_dir: String) -> Result(List(String), String) {
  let directory = state_dir <> "/sessions"

  use names <- result.try(
    simplifile.read_directory(directory)
    |> result.map_error(fn(error) {
      directory <> ": " <> simplifile.describe_error(error)
    }),
  )

  Ok(
    names
    |> list.filter(string.ends_with(_, ".db"))
    |> list.sort(string.compare)
    |> list.map(fn(name) { directory <> "/" <> name }),
  )
}

/// Refuses a list in which two databases would write the same output file.
fn distinct_stems(dbs: List(String)) -> Result(Nil, String) {
  let stems = list.map(dbs, stem)

  // Two stems alike would have the second export overwrite the first.
  case list.length(list.unique(stems)) == list.length(stems) {
    True -> Ok(Nil)
    False ->
      Error("two databases share a file name; their exports would collide")
  }
}

/// The file name without its directory or `.db` suffix.
fn stem(path: String) -> String {
  // A path with no separator is already a bare name.
  let name = case list.last(string.split(path, "/")) {
    Ok(name) -> name
    Error(Nil) -> path
  }

  // Only the database suffix is dropped; a name without it is kept whole.
  case string.ends_with(name, ".db") {
    True -> string.drop_end(name, 3)
    False -> name
  }
}

/// Creates a directory only its owner can read, since what lands in it is a
/// transcript.
fn make_private_directory(path: String) -> Result(Nil, String) {
  use Nil <- result.try(
    simplifile.create_directory_all(path)
    |> result.map_error(fn(error) {
      path <> ": " <> simplifile.describe_error(error)
    }),
  )

  simplifile.set_permissions_octal(path, 0o700)
  |> result.map_error(fn(error) {
    path <> ": " <> simplifile.describe_error(error)
  })
}

/// Exports one session and removes its copy on every path, so the result is
/// the walk's own outcome and never a cleanup error masking it.
fn export_session(
  db: String,
  index: Int,
  since_ms: Int,
  out_dir: String,
  copies: String,
) -> Result(Summary, String) {
  let copy = copies <> "/" <> int.to_string(index) <> ".db"
  let walked = {
    use Nil <- result.try(copy_database(db, copy))
    walk_copy(copy, stem(db), since_ms, out_dir)
  }
  let removed = remove_copy(copy)

  // A walk that failed reports its own reason first; a clean walk with a
  // copy left behind is still a failure.
  case walked, removed {
    Error(reason), _ -> Error(reason)
    Ok(_), Error(reason) -> Error(reason)
    Ok(summary), Ok(Nil) -> Ok(summary)
  }
}

/// The suffixes a SQLite database may carry beside its main file.
const siblings = ["", "-wal", "-shm"]

/// Copies the database and whichever of its siblings exist. The WAL holds
/// commits not yet in the main file, so a copy without it would read a past
/// state of the session.
fn copy_database(db: String, copy: String) -> Result(Nil, String) {
  // A missing or unreadable original is reported before any copy is made.
  use Nil <- result.try(case simplifile.is_file(db) {
    Ok(True) -> Ok(Nil)
    Ok(False) | Error(_) -> Error(db <> ": not a readable file")
  })

  list.try_each(siblings, fn(suffix) {
    case simplifile.is_file(db <> suffix) {
      Ok(True) ->
        simplifile.copy_file(db <> suffix, copy <> suffix)
        |> result.map_error(fn(error) {
          db <> suffix <> ": " <> simplifile.describe_error(error)
        })
      Ok(False) | Error(_) -> Ok(Nil)
    }
  })
}

/// Deletes the copy and its siblings; a file that is already absent is fine.
fn remove_copy(copy: String) -> Result(Nil, String) {
  list.try_each(siblings, fn(suffix) {
    case simplifile.is_file(copy <> suffix) {
      Ok(True) ->
        simplifile.delete(copy <> suffix)
        |> result.map_error(fn(error) {
          copy <> suffix <> ": " <> simplifile.describe_error(error)
        })
      Ok(False) | Error(_) -> Ok(Nil)
    }
  })
}

/// Opens the copy, writes the session's file, and closes the copy so its own
/// lease is released before the copy is deleted.
fn walk_copy(
  copy: String,
  name: String,
  since_ms: Int,
  out_dir: String,
) -> Result(Summary, String) {
  use opened <- result.try(
    session.open_sqlite(
      path: copy,
      owner: "eval-transcripts",
      lease_ttl_ms: 30_000,
      clock: clock.from_function(ffi_os.system_time_ms),
    )
    |> result.map_error(fn(error) { "open failed: " <> string.inspect(error) }),
  )
  let written = write_session(opened, name, since_ms, out_dir)
  let closed = session.close(opened)

  // The walk's own failure outranks a close failure, which it may have caused.
  case written, closed {
    Error(reason), _ -> Error(reason)
    Ok(_), Error(error) -> Error("close failed: " <> string.inspect(error))
    Ok(summary), Ok(Nil) -> Ok(summary)
  }
}

/// Reads one open copy and writes `<out_dir>/<name>.jsonl`, or reports that
/// nothing in it is recent enough.
fn write_session(
  source: session.Session,
  name: String,
  since_ms: Int,
  out_dir: String,
) -> Result(Summary, String) {
  use all <- result.try(
    storage.scan_entries(source.store, storage.entry_scan())
    |> result.map_error(fn(error) {
      "entries unreadable: " <> string.inspect(error)
    }),
  )
  let recent = list.filter(all, fn(row) { entry_ts(row) >= since_ms })

  // A session with nothing recent leaves no file, only a count.
  case recent {
    [] -> Ok(Skipped)
    _ -> {
      use rows <- result.try(
        storage.scan_usage(source.store, storage.usage_scan())
        |> result.map_error(fn(error) {
          "usage unreadable: " <> string.inspect(error)
        }),
      )
      use records <- result.try(list.try_map(recent, entry_records(source, _)))
      let marks = list.flatten(list.map(records, fn(pair) { pair.1 }))
      let lines = list.flatten(list.map(records, fn(pair) { pair.0 }))
      let usage = list.map(rows, usage_record)
      let head = header(name, since_ms, marks)

      use Nil <- result.try(write_lines(
        out_dir <> "/" <> name <> ".jsonl",
        list.flatten([[head], lines, usage]),
      ))

      Ok(summarise(list.length(recent), marks))
    }
  }
}

/// The timestamp every entry kind carries.
fn entry_ts(row: entry.Entry) -> Int {
  case row {
    entry.MessageEntry(ts:, ..)
    | entry.CompactionEntry(ts:, ..)
    | entry.BranchSummaryEntry(ts:, ..)
    | entry.CustomEntry(ts:, ..) -> ts
  }
}

/// One assistant entry's model id and operator mark, kept for the header and
/// the census.
type Mark {
  Mark(model: String, outcome: trace.Outcome)
}

/// The records one entry becomes, and the mark it contributes if it is an
/// assistant turn. A custom entry and a custom message are application data
/// the taxonomy has no use for and are left out.
fn entry_records(
  source: session.Session,
  row: entry.Entry,
) -> Result(#(List(json.JsonValue), List(Mark)), String) {
  // Each entry kind has its own records; custom rows carry none.
  case row {
    entry.MessageEntry(id:, ts:, message: message.UserMessage(content:, ..), ..) ->
      Ok(#([user_record(id, ts, content)], []))

    entry.MessageEntry(
      id:,
      ts:,
      message: message.AssistantMessage(..) as assistant,
      ..,
    ) -> assistant_records(source, row, id, ts, assistant)

    entry.MessageEntry(
      id:,
      ts:,
      message: message.ToolResultMessage(
        tool_call_id:,
        tool_name:,
        content:,
        is_error:,
        ..,
      ),
      ..,
    ) -> {
      // The flag becomes a named state before it reaches the record builder.
      let status = case is_error {
        True -> ToolFailed
        False -> ToolSucceeded
      }

      Ok(
        #(
          [
            tool_result_record(id, ts, tool_call_id, tool_name, content, status),
          ],
          [],
        ),
      )
    }

    entry.MessageEntry(message: message.CustomMessage(..), ..) -> Ok(#([], []))

    entry.CompactionEntry(id:, ts:, summary:, tokens_before:, ..) ->
      Ok(
        #([compaction_record("compaction", id, ts, summary, tokens_before)], []),
      )

    entry.BranchSummaryEntry(id:, ts:, summary:, ..) ->
      Ok(#([compaction_record("branch_summary", id, ts, summary, 0)], []))

    entry.CustomEntry(..) -> Ok(#([], []))
  }
}

/// Fields every record carries: what it is, which entry, and when.
fn base(
  kind: String,
  id: ids.EntryId,
  ts: Int,
) -> List(#(String, json.JsonValue)) {
  [
    #("kind", json.String(kind)),
    #("entry", json.String(ids.entry_id_to_string(id))),
    #("ts", json.Int(ts)),
  ]
}

/// A user turn's text. Images are dropped; a turn of only images keeps an
/// empty text so the turn is still visible in the sequence.
fn user_record(
  id: ids.EntryId,
  ts: Int,
  content: List(message.UserBlock),
) -> json.JsonValue {
  let text =
    list.filter_map(content, fn(block) {
      case block {
        message.UserText(text:, ..) -> Ok(text)
        message.UserImage(..) -> Error(Nil)
      }
    })
    |> string.join("\n")

  json.Object(
    list.append(base("user", id, ts), [#("text", json.String(excerpt(text)))]),
  )
}

/// An assistant turn: one record for its text and, for each tool call, one
/// more. The operator mark is read here, beside the turn it describes.
fn assistant_records(
  source: session.Session,
  row: entry.Entry,
  id: ids.EntryId,
  ts: Int,
  turn: message.AgentMessage,
) -> Result(#(List(json.JsonValue), List(Mark)), String) {
  // Only an assistant turn has a model and a mark; any other kind is not here.
  case turn {
    message.AssistantMessage(content:, provider:, model:, api:, ..) -> {
      use outcome <- result.try(read_outcome(
        source,
        row,
        record.ModelScope(provider, model, api),
      ))
      let text =
        list.filter_map(content, fn(block) {
          case block {
            message.AssistantText(text:, ..) -> Ok(text)
            message.AssistantThinking(..) | message.AssistantToolCall(..) ->
              Error(Nil)
          }
        })
        |> string.join("\n")
      let calls =
        list.filter_map(content, fn(block) {
          case block {
            message.AssistantToolCall(call) ->
              Ok(tool_call_record(id, ts, call))
            message.AssistantText(..) | message.AssistantThinking(..) ->
              Error(Nil)
          }
        })
      let turn_record =
        json.Object(
          list.append(base("assistant", id, ts), [
            #("model", json.String(model_id(provider, model))),
            #("api", json.String(api)),
            #("outcome", json.String(outcome_word(outcome))),
            #("text", json.String(excerpt(text))),
          ]),
        )

      Ok(#([turn_record, ..calls], [Mark(model_id(provider, model), outcome)]))
    }

    message.UserMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> Ok(#([], []))
  }
}

/// Asks the trace's own reader for one assistant entry's mark. `trace.join`
/// is the public door to it; it matches on the entry's own model, so the
/// excerpt it returns is always this entry, and it is bounded to one.
fn read_outcome(
  source: session.Session,
  row: entry.Entry,
  scope: record.ModelScope,
) -> Result(trace.Outcome, String) {
  let bounds = trace.Bounds(1, 1, 1, 1, 65_536)

  use brief <- result.try(trace.join(source, scope, [row], [], bounds))

  // The join keeps exactly the one entry it was handed, or something is wrong.
  case brief.excerpts {
    [found] -> Ok(found.outcome)
    [] | [_, _, ..] -> Error("the outcome lookup did not return one excerpt")
  }
}

/// `provider/model`, the id the census and the sample stratify on.
fn model_id(provider: String, model: String) -> String {
  provider <> "/" <> model
}

/// The explicit word for an outcome; `unmarked` is a value, not an absence.
fn outcome_word(outcome: trace.Outcome) -> String {
  case outcome {
    trace.Unmarked -> "unmarked"
    trace.Succeeded -> "succeeded"
    trace.Failed -> "failed"
  }
}

/// Scrubbed prose, clipped to the trace excerpt's own grapheme ceiling.
fn excerpt(text: String) -> String {
  trace.scrub_excerpt(text, 4096)
}

/// A tool call: its name, the keys of its arguments and a short scrubbed
/// preview. Values are never kept whole; the keys say what shape the model
/// chose, which is what the taxonomy needs.
fn tool_call_record(
  id: ids.EntryId,
  ts: Int,
  call: message.ToolCall,
) -> json.JsonValue {
  // Only an object has argument names; any other shape has none to list.
  let keys = case call.arguments {
    json.Object(fields) -> list.map(fields, fn(pair) { json.String(pair.0) })
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> []
  }

  let preview =
    scrub_json(call.arguments)
    |> json.to_string
    |> trace.scrub_excerpt(256)
    |> clip_bytes(256, Head)

  json.Object(
    list.append(base("tool_call", id, ts), [
      #("call", json.String(call.id)),
      #("name", json.String(call.name)),
      #("arg_keys", json.Array(keys)),
      #("preview", json.String(preview)),
    ]),
  )
}

/// Redacts credential-named fields at any depth and scrubs every string.
/// `trace` keeps its own copy private, and a text scrub alone would leave
/// `{"x-api-key": "short"}` intact, so the structure is walked here. A
/// hyphen is read as an underscore, because `secret_key` names `api_key` and
/// HTTP header names spell it `x-api-key`.
fn scrub_json(value: json.JsonValue) -> json.JsonValue {
  case value {
    json.Object(fields) ->
      json.Object(
        list.map(fields, fn(pair) {
          #(pair.0, case field.secret_key(string.replace(pair.0, "-", "_")) {
            True -> json.String(field.redacted_marker)
            False -> scrub_json(pair.1)
          })
        }),
      )
    json.Array(items) -> json.Array(list.map(items, scrub_json))
    json.String(text) -> json.String(field.scrub_text(text))
    json.Int(_) | json.Float(_) | json.Bool(_) | json.Null -> value
  }
}

/// Whether a tool reported failure.
type ToolStatus {
  /// The tool ran and returned a result.
  ToolSucceeded

  /// The tool reported an error.
  ToolFailed
}

/// A tool result: whether it failed and the scrubbed end of its text. The
/// window is cut before the scrub only far enough to bound the work, and
/// its first partial token is dropped so a clipped credential cannot pass
/// as an ordinary word.
fn tool_result_record(
  id: ids.EntryId,
  ts: Int,
  call_id: String,
  tool: String,
  content: List(message.ToolResultBlock),
  status: ToolStatus,
) -> json.JsonValue {
  let text =
    list.filter_map(content, fn(block) {
      case block {
        message.ToolResultText(text:, ..) -> Ok(text)
        message.ToolResultImage(..) -> Error(Nil)
      }
    })
    |> string.join("\n")
  let tail = tail_window(text) |> field.scrub_text |> clip_bytes(512, Tail)

  json.Object(
    list.append(base("tool_result", id, ts), [
      #("call", json.String(call_id)),
      #("tool", json.String(tool)),
      #("is_error", json.Bool(status == ToolFailed)),
      #("tail", json.String(tail)),
    ]),
  )
}

/// The last 16384 graphemes of a text, without a leading partial token.
fn tail_window(text: String) -> String {
  let graphemes = string.to_graphemes(text)
  let excess = list.length(graphemes) - 16_384

  // A short text is kept whole; a long one is cut to its end.
  case excess > 0 {
    False -> text
    True -> {
      let window = graphemes |> list.drop(excess) |> string.concat

      // The cut may land inside a token, so the first partial one is dropped.
      case string.split_once(window, " ") {
        Ok(#(_, rest)) -> rest
        Error(Nil) -> window
      }
    }
  }
}

/// Keeps whole graphemes from one end of a text up to a byte budget.
fn clip_bytes(text: String, budget: Int, keep: Keep) -> String {
  case keep {
    Head ->
      string.to_graphemes(text)
      |> take_bytes(budget, [])
      |> list.reverse
      |> string.concat
    Tail ->
      string.to_graphemes(text)
      |> list.reverse
      |> take_bytes(budget, [])
      |> string.concat
  }
}

/// Accumulates graphemes until the next would overrun the budget; the result
/// is in reverse order of the input.
fn take_bytes(
  graphemes: List(String),
  budget: Int,
  kept: List(String),
) -> List(String) {
  // The walk ends at the input's end or at the first grapheme that overruns.
  case graphemes {
    [] -> kept
    [grapheme, ..rest] -> {
      let cost = bit_array.byte_size(<<grapheme:utf8>>)

      // A multi-byte grapheme is never split to fill the budget exactly.
      case cost > budget {
        True -> kept
        False -> take_bytes(rest, budget - cost, [grapheme, ..kept])
      }
    }
  }
}

/// A compaction or branch summary: the checkpoint that replaced earlier turns.
/// A context-overflow failure shows up as one of these preceding the end.
fn compaction_record(
  kind: String,
  id: ids.EntryId,
  ts: Int,
  summary: String,
  tokens_before: Int,
) -> json.JsonValue {
  json.Object(
    list.append(base(kind, id, ts), [
      #("tokens_before", json.Int(tokens_before)),
      #("summary", json.String(trace.scrub_excerpt(summary, 1024))),
    ]),
  )
}

/// One ledger row. A row not tied to an entry keeps `entry` null.
fn usage_record(row: entry.UsageRow) -> json.JsonValue {
  let usage = row.usage

  json.Object([
    #("kind", json.String("usage")),
    #("entry", case row.entry_id {
      Some(id) -> json.String(ids.entry_id_to_string(id))
      None -> json.Null
    }),
    #("adjustment", json.Bool(row.adjustment)),
    #("input", json.Int(usage.input)),
    #("output", json.Int(usage.output)),
    #("cache_read", json.Int(usage.cache_read)),
    #("cache_write", json.Int(usage.cache_write)),
    #("total_tokens", json.Int(usage.total_tokens)),
    #("cost_total", json.Float(usage.cost.total)),
  ])
}

/// The first line of a session file: who it is, what the scrub does not
/// promise, and the two facts `sample` stratifies on.
fn header(name: String, since_ms: Int, marks: List(Mark)) -> json.JsonValue {
  json.Object([
    #("kind", json.String("header")),
    #("v", json.Int(1)),
    #("session", json.String(name)),
    #("scrubber", json.String(trace.scrub_version)),
    #("limits", json.String(scrubber_limits)),
    #("since_ms", json.Int(since_ms)),
    #("model", json.String(primary_model(marks))),
    #("outcome", json.String(session_outcome(marks))),
  ])
}

/// The model with the most assistant turns, ties to the smaller id; `none`
/// for a session with no assistant turn.
fn primary_model(marks: List(Mark)) -> String {
  count_models(list.map(marks, fn(mark) { mark.model }))
  |> list.sort(fn(a, b) {
    order.break_tie(int.compare(b.1, a.1), string.compare(a.0, b.0))
  })
  |> list.first
  |> result.map(fn(pair) { pair.0 })
  |> result.unwrap("none")
}

/// `failed` if any turn was marked failed, else `succeeded` if any was marked
/// so, else `unmarked`.
fn session_outcome(marks: List(Mark)) -> String {
  let outcomes = list.map(marks, fn(mark) { mark.outcome })

  // A failure anywhere outranks a success, so one bad turn is not hidden.
  case
    list.contains(outcomes, trace.Failed),
    list.contains(outcomes, trace.Succeeded)
  {
    True, _ -> "failed"
    False, True -> "succeeded"
    False, False -> "unmarked"
  }
}

/// Counts occurrences of each model id, sorted by id.
fn count_models(models: List(String)) -> List(#(String, Int)) {
  models
  |> list.group(fn(model) { model })
  |> dict.to_list
  |> list.map(fn(pair) { #(pair.0, list.length(pair.1)) })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

/// Writes one JSON value per line, readable by its owner alone.
fn write_lines(
  path: String,
  lines: List(json.JsonValue),
) -> Result(Nil, String) {
  let body = string.join(list.map(lines, json.to_string), "\n") <> "\n"

  use Nil <- result.try(
    simplifile.write(path, body)
    |> result.map_error(fn(error) {
      path <> ": " <> simplifile.describe_error(error)
    }),
  )

  simplifile.set_permissions_octal(path, 0o600)
  |> result.map_error(fn(error) {
    path <> ": " <> simplifile.describe_error(error)
  })
}

/// Reduces a written session to the counts the census needs.
fn summarise(entries: Int, marks: List(Mark)) -> Summary {
  let marked = list.count(marks, fn(mark) { mark.outcome != trace.Unmarked })

  Written(
    entries:,
    marked:,
    unmarked: list.length(marks) - marked,
    models: list.map(marks, fn(mark) { mark.model }),
  )
}

/// The census before any session.
fn empty_census() -> Census {
  Census(
    sessions: 0,
    entries: 0,
    marked: 0,
    unmarked: 0,
    skipped: 0,
    by_model: [],
    failed: [],
  )
}

/// Folds one session's outcome in. `by_model` is kept as a flat list of ids
/// during the fold and counted once at the end.
fn add_to_census(
  census: Census,
  db: String,
  summary: Result(Summary, String),
) -> Census {
  case summary {
    Error(reason) ->
      Census(..census, failed: [Failure(db, reason), ..census.failed])
    Ok(Skipped) -> Census(..census, skipped: census.skipped + 1)
    Ok(Written(entries:, marked:, unmarked:, models:)) ->
      Census(
        ..census,
        sessions: census.sessions + 1,
        entries: census.entries + entries,
        marked: census.marked + marked,
        unmarked: census.unmarked + unmarked,
        by_model: list.append(
          census.by_model,
          list.map(models, fn(model) { #(model, 1) }),
        ),
      )
  }
}

/// Collapses the per-turn ids into counts and puts failures in input order.
fn finish_census(census: Census) -> Census {
  Census(
    ..census,
    by_model: count_models(list.map(census.by_model, fn(pair) { pair.0 })),
    failed: list.reverse(census.failed),
  )
}

/// The session files in a census directory, sorted.
fn jsonl_files(dir: String) -> List(String) {
  case simplifile.read_directory(dir) {
    Ok(names) ->
      names
      |> list.filter(string.ends_with(_, ".jsonl"))
      |> list.sort(string.compare)
      |> list.map(fn(name) { dir <> "/" <> name })
    Error(_) -> []
  }
}

/// The stratum a session file declares in its header line.
fn read_stratum(path: String) -> Result(String, Nil) {
  use text <- result.try(simplifile.read(path) |> result.replace_error(Nil))
  use line <- result.try(
    string.split(text, "\n") |> list.first |> result.replace_error(Nil),
  )
  use parsed <- result.try(json.parse(line) |> result.replace_error(Nil))

  // Only a JSON object can be a header.
  case parsed {
    json.Object(fields) ->
      // A header missing either stratifying field cannot be sampled.
      case list.key_find(fields, "model"), list.key_find(fields, "outcome") {
        Ok(json.String(model)), Ok(json.String(outcome)) ->
          Ok(model <> " | " <> outcome)
        _, _ -> Error(Nil)
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}

/// Orders one stratum's files by a seeded draw, so the choice within it is
/// random but reproducible; the path breaks a tie.
fn shuffle(
  paths: List(String),
  generator: prng.Prng,
) -> #(prng.Prng, List(String)) {
  let #(generator, keyed) =
    list.map_fold(paths, generator, fn(generator, path) {
      let #(key, next) = prng.below(generator, 1_000_000_000)
      #(next, #(key, path))
    })
  let ordered =
    list.sort(keyed, fn(a, b) {
      order.break_tie(int.compare(a.0, b.0), string.compare(a.1, b.1))
    })

  #(generator, list.map(ordered, fn(pair) { pair.1 }))
}

/// Takes one file from each non-empty stratum in turn until `remaining` runs
/// out, so no stratum is visited twice before every other has been visited
/// once.
fn deal(
  queues: List(List(String)),
  remaining: Int,
  taken: List(String),
) -> List(String) {
  let live = list.filter(queues, fn(queue) { queue != [] })

  // The deal ends when the quota is met or every stratum is empty.
  case remaining > 0, live {
    False, _ | True, [] -> list.reverse(taken)
    True, _ -> {
      let #(taken, remaining, next) =
        list.fold(live, #(taken, remaining, []), fn(state, queue) {
          let #(taken, remaining, next) = state

          // Each stratum gives up its next file while the quota lasts.
          case remaining > 0, queue {
            True, [head, ..tail] -> #([head, ..taken], remaining - 1, [
              tail,
              ..next
            ])
            True, [] | False, _ -> #(taken, remaining, [queue, ..next])
          }
        })

      deal(list.reverse(next), remaining, taken)
    }
  }
}
