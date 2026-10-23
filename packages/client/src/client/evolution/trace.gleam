//// Bounded trace excerpts join native source identity, ledger usage and outcomes.
////
//// The source conversation remains faithful. Only the brief is scrubbed, using
//// telemetry's credential-shape rules plus credential-named JSON fields. This
//// version is a heuristic: short unlabelled secrets and private prose can remain.
//// Thinking, opaque signatures, images and provider diagnostics are excluded.
//// A missing operator mark is `Unmarked`, never a failed or successful task.

import client/evolution/record
import core/codec
import core/entry
import core/ids.{type EntryId}
import core/json
import core/message
import core/register
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import session/session
import storage/snapshot
import storage/storage
import telemetry/field

/// The exact scrub policy in this brief; changes require a new version.
pub const scrub_version = "telemetry-shapes-and-json-keys-1"

/// An operator's independently supplied task outcome.
pub type Outcome {
  /// The operator has not supplied a task verdict.
  Unmarked

  /// Required work was verified independently of the source model.
  Succeeded

  /// Required work failed the operator's criterion.
  Failed
}

/// Native admission bounds. All rows and retained text have hard ceilings.
pub type Bounds {
  Bounds(
    /// Maximum conversation rows inspected, up to 256.
    entries: Int,
    /// Maximum ledger rows inspected, up to 1024.
    usage_rows: Int,
    /// Maximum retained model turns, up to 64.
    excerpts: Int,
    /// Maximum excerpt graphemes, up to 4096.
    graphemes: Int,
    /// Maximum combined retained UTF-8 bytes, up to 64 KiB.
    bytes: Int,
  )
}

/// One model turn, identified by its real durable source and joined evidence.
pub type Excerpt {
  Excerpt(
    /// Hosting source session identity supplied by native session visibility.
    session_id: String,
    /// Exact immutable source entry.
    entry_id: EntryId,
    /// Actual provider/model/API identity in the settled message.
    target: record.ModelScope,
    /// Scrubbed bounded answer and tool-call text, with no thinking.
    text: String,
    /// Ledger attribution; absence is distinct from zero cost.
    usage: Option(message.Usage),
    /// Authenticated native outcome or absence.
    outcome: Outcome,
  )
}

/// A bounded brief and the limits that explain incomplete source coverage.
pub type Brief {
  Brief(
    /// Ordered retained source excerpts, newest first.
    excerpts: List(Excerpt),
    /// Version of the documented heuristic scrubber.
    scrubber: String,
    /// Admission bounds used for both scans and retained text.
    bounds: Bounds,
    /// Nonempty when a scan or retained-output ceiling limited coverage.
    limitations: List(String),
  )
}

/// Selects a source session through its already authorized native handle.
/// Limits apply before broad scans. Outcome lookup is one bounded read per turn.
///
/// ## Examples
///
/// ```gleam
/// // trace.select(source, exact_model, trace.Bounds(64, 256, 12, 1024, 16384))
/// ```
pub fn select(
  source: session.Session,
  target: record.ModelScope,
  bounds: Bounds,
) -> Result(Brief, String) {
  use Nil <- result.try(validate(bounds))
  use #(entries, source_notes) <- result.try(read_entries(
    source,
    bounds.entries,
  ))
  use rows <- result.try(
    storage.scan_usage(
      source.store,
      storage.usage_scan()
        |> storage.usage_order(storage.NewestFirst)
        |> storage.usage_limit(bounds.usage_rows),
    )
    |> result.map_error(fn(_) { "trace source usage is unreadable" }),
  )
  use brief <- result.try(join(source, target, entries, rows, bounds))
  let notes = case
    list.length(entries) == bounds.entries
    || list.length(rows) == bounds.usage_rows
  {
    True -> [
      "source scan ceiling reached",
      ..list.append(source_notes, brief.limitations)
    ]
    False -> list.append(source_notes, brief.limitations)
  }
  Ok(Brief(..brief, limitations: notes))
}

/// Reads the strand's latest actual assistant target through a bounded source cut.
/// Native resolution is used only before this strand has an assistant message.
/// A clipped or missing ancestor refuses rather than attributing another strand
/// or silently replacing a settled fallback target with its requested model.
///
/// ## Examples
///
/// ```gleam
/// // trace.actual_model(source, ctx.strand, native_resolved_default)
/// ```
pub fn actual_model(
  source: session.Session,
  strand: String,
  fallback: record.ModelScope,
) -> Result(record.ModelScope, String) {
  use leaf <- result.try(
    session.strand_leaf(source, strand)
    |> result.replace_error("the native strand leaf is unreadable"),
  )
  use #(entries, _) <- result.try(read_entries(source, 100))
  latest_model(
    option.map(leaf, fn(cell) { cell.value }),
    entries,
    fallback,
    100,
  )
}

fn latest_model(
  leaf: Option(Option(EntryId)),
  entries: List(entry.Entry),
  fallback: record.ModelScope,
  remaining: Int,
) -> Result(record.ModelScope, String) {
  use Nil <- result.try(case remaining > 0 {
    True -> Ok(Nil)
    False ->
      Error("actual model ancestry exceeds the bounded native source window")
  })
  case leaf {
    None | Some(None) -> Ok(fallback)
    Some(Some(id)) -> {
      use entry <- result.try(
        list.find(entries, fn(entry) { entry.id == id })
        |> result.replace_error(
          "the actual model exceeds the bounded native source window",
        ),
      )
      case entry {
        entry.MessageEntry(
          message: message.AssistantMessage(provider:, model:, api:, ..),
          ..,
        ) -> Ok(record.ModelScope(provider, model, api))
        entry.MessageEntry(..)
        | entry.CompactionEntry(..)
        | entry.BranchSummaryEntry(..)
        | entry.CustomEntry(..) ->
          latest_model(Some(entry.parent), entries, fallback, remaining - 1)
      }
    }
  }
}

// Payload descriptors are admitted before any source bytes are copied. One
// excerpt source is at most 16 KiB and the entire scan copies at most one MiB.
fn read_entries(
  source: session.Session,
  limit: Int,
) -> Result(#(List(entry.Entry), List(String)), String) {
  let window = int.min(limit, 100)
  use cut <- result.try(
    source.snapshot_reader.capture(
      snapshot.Plan(selections: [], references: [], recent_entries: window),
      5000,
    )
    |> result.map_error(fn(_) {
      "bounded trace source descriptors are unreadable"
    }),
  )
  use #(entries, _, notes) <- result.try(
    list.try_fold(list.reverse(cut.recent), #([], 0, []), fn(acc, descriptor) {
      let #(entries, copied, notes) = acc
      case
        descriptor.byte_length > 16_384
        || copied + descriptor.byte_length > 1_048_576
      {
        True ->
          Ok(
            #(entries, copied, [
              "source payload ceiling excluded an entry",
              ..notes
            ]),
          )
        False -> {
          use bytes <- result.try(
            source.snapshot_reader.fragment(descriptor, 0, 5000)
            |> result.map_error(fn(_) {
              "bounded trace source fragment is unreadable"
            }),
          )
          use text <- result.try(
            bit_array.to_string(bytes)
            |> result.map_error(fn(_) { "trace source bytes are not UTF-8" }),
          )
          use value <- result.try(
            json.parse(text)
            |> result.map_error(fn(_) { "trace source entry JSON is corrupt" }),
          )
          use entry <- result.try(
            codec.decode_entry(value)
            |> result.map_error(fn(_) { "trace source entry is corrupt" }),
          )
          Ok(#([entry, ..entries], copied + descriptor.byte_length, notes))
        }
      }
    }),
  )
  let notes = case list.length(cut.recent) == window {
    True -> ["bounded recent source window reached", ..notes]
    False -> notes
  }
  Ok(#(list.reverse(entries), notes))
}

/// Joins a bounded inventory, useful for deterministic lifecycle tests.
/// The caller owns source visibility; input lists are bounded again here.
///
/// ## Examples
///
/// ```gleam
/// // trace.join(source, target, entries, ledger, bounds)
/// ```
pub fn join(
  source: session.Session,
  target: record.ModelScope,
  entries: List(entry.Entry),
  rows: List(entry.UsageRow),
  bounds: Bounds,
) -> Result(Brief, String) {
  use Nil <- result.try(validate(bounds))
  use identity <- result.try(
    session.id(source)
    |> result.map_error(fn(_) { "the source session identity is unreadable" }),
  )
  use identity <- result.try(case identity {
    Some(id) -> Ok(ids.session_id_to_string(id))
    None -> Error("the source session has no durable identity")
  })
  use #(excerpts, remaining) <- result.try(
    list.try_fold(
      list.take(entries, bounds.entries),
      #([], bounds.bytes),
      fn(acc, row) {
        let #(kept, remaining) = acc
        case list.length(kept) >= bounds.excerpts || remaining <= 0 {
          True -> Ok(acc)
          False ->
            join_row(
              source,
              identity,
              target,
              row,
              list.take(rows, bounds.usage_rows),
              bounds,
              kept,
              remaining,
            )
        }
      },
    ),
  )
  Ok(
    Brief(
      excerpts: list.reverse(excerpts),
      scrubber: scrub_version,
      bounds:,
      limitations: case
        list.length(excerpts) == bounds.excerpts || remaining <= 0
      {
        True -> ["excerpt output ceiling reached"]
        False -> []
      },
    ),
  )
}

fn join_row(
  source: session.Session,
  identity: String,
  target: record.ModelScope,
  row: entry.Entry,
  rows: List(entry.UsageRow),
  bounds: Bounds,
  kept: List(Excerpt),
  remaining: Int,
) -> Result(#(List(Excerpt), Int), String) {
  case row {
    entry.MessageEntry(
      id:,
      message: message.AssistantMessage(provider:, model:, api:, content:, ..),
      ..,
    )
      if provider == target.provider
      && model == target.model
      && api == target.api
    -> {
      use outcome <- result.try(read_outcome(source, id))
      let text =
        content
        |> list.map(block_text)
        |> string.join("\n")
        |> scrub_excerpt(bounds.graphemes)
      let bytes = bit_array.byte_size(bit_array.from_string(text))
      case bytes <= remaining {
        False -> Ok(#(kept, 0))
        True -> {
          let matching = list.filter(rows, fn(row) { row.entry_id == Some(id) })
          let usage = case matching {
            [] -> None
            rows ->
              Some(
                list.fold(rows, storage.empty_usage(), fn(total, row) {
                  storage.add_usage(total, row.usage)
                }),
              )
          }
          Ok(#(
            [
              Excerpt(
                session_id: identity,
                entry_id: id,
                target:,
                text:,
                usage:,
                outcome:,
              ),
              ..kept
            ],
            remaining - bytes,
          ))
        }
      }
    }
    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> Ok(#(kept, remaining))
  }
}

fn validate(bounds: Bounds) -> Result(Nil, String) {
  case
    bounds.entries > 0
    && bounds.entries <= 256
    && bounds.usage_rows > 0
    && bounds.usage_rows <= 1024
    && bounds.excerpts > 0
    && bounds.excerpts <= 64
    && bounds.graphemes > 0
    && bounds.graphemes <= 4096
    && bounds.bytes > 0
    && bounds.bytes <= 65_536
  {
    True -> Ok(Nil)
    False -> Error("invalid trace scan or excerpt bounds")
  }
}

fn block_text(block: message.AssistantBlock) -> String {
  case block {
    message.AssistantThinking(..) -> ""
    message.AssistantText(text:, ..) -> text
    message.AssistantToolCall(call) ->
      call.name <> " " <> json.to_string(scrub_json(call.arguments))
  }
}

fn scrub_json(value: json.JsonValue) -> json.JsonValue {
  case value {
    json.Object(fields) ->
      json.Object(
        list.map(fields, fn(pair) {
          #(pair.0, case field.secret_key(pair.0) {
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

/// Scrubs before clipping so a clipped credential cannot become an ordinary token.
/// Input is capped at 16 KiB graphemes; the last partial token is discarded first.
///
/// ## Examples
///
/// ```gleam
/// // trace.scrub_excerpt("key sk-secret-value", 128)
/// ```
pub fn scrub_excerpt(text: String, graphemes: Int) -> String {
  let prefix = string.slice(text, 0, 16_384)
  let prefix = case prefix == text {
    True -> prefix
    False ->
      prefix
      |> string.split(" ")
      |> list.reverse
      |> list.drop(1)
      |> list.reverse
      |> string.join(" ")
  }
  prefix |> field.scrub_text |> string.slice(0, graphemes)
}

/// Writes an outcome through a native reserved-fact capability.
/// Only an authenticated operator control path may call this function.
///
/// ## Examples
///
/// ```gleam
/// // trace.mark(runtime, source_entry, trace.Succeeded, principal)
/// ```
pub fn mark(
  runtime: api.Runtime,
  source: EntryId,
  outcome: Outcome,
  principal: String,
) -> Result(Nil, String) {
  case principal == "" || outcome == Unmarked {
    True -> Error("an outcome requires an authenticated operator and a verdict")
    False ->
      api.put_reserved_fact(
        runtime,
        outcome_key(source),
        json.Object([
          #("version", json.Int(1)),
          #("principal", json.String(principal)),
          #(
            "outcome",
            json.String(case outcome {
              Succeeded -> "succeeded"
              Failed -> "failed"
              Unmarked -> "unmarked"
            }),
          ),
        ]),
      )
      |> result.map_error(fn(_) {
        "the native task outcome could not be recorded"
      })
  }
}

fn outcome_key(id: EntryId) -> String {
  "prompt/evolution-outcome/" <> ids.entry_id_to_string(id)
}

fn read_outcome(
  source: session.Session,
  id: EntryId,
) -> Result(Outcome, String) {
  use cell <- result.try(
    storage.get_register(source.store, register.FactCustom, outcome_key(id))
    |> result.map_error(fn(_) { "the source outcome is unreadable" }),
  )
  case cell {
    None -> Ok(Unmarked)
    Some(storage.Register(value:, ..)) -> decode_outcome(value.payload)
  }
}

fn decode_outcome(value: json.JsonValue) -> Result(Outcome, String) {
  case value {
    json.Object(fields) -> {
      let version = list.key_find(fields, "version")
      let principal = list.key_find(fields, "principal")
      let outcome = list.key_find(fields, "outcome")
      case list.length(fields) == 3, version, principal, outcome {
        True,
          Ok(json.Int(1)),
          Ok(json.String(principal)),
          Ok(json.String("succeeded"))
          if principal != ""
        -> Ok(Succeeded)
        True,
          Ok(json.Int(1)),
          Ok(json.String(principal)),
          Ok(json.String("failed"))
          if principal != ""
        -> Ok(Failed)
        _, _, _, _ -> Error("the native task outcome is corrupt")
      }
    }
    _ -> Error("the native task outcome is corrupt")
  }
}
