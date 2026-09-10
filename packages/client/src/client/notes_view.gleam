//// A bounded, current blackboard view for the terminal. Reading notes is an
//// auxiliary request: an oversized board cannot prevent conversation capture,
//// steering, or cancellation. One storage cut supplies values and revisions.

import client/daemon/transfer
import core/json
import core/register
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import session/session.{type Session}
import storage/snapshot
import tools/agent

/// Reads one strand's notes without borrowing an old run-start digest.
/// The reader's ordinary byte and cell budgets apply before rendering, and
/// the display itself fits below a conversation response's 64 KiB limit.
///
/// ## Examples
///
/// ```gleam
/// // notes_view.read(session, "main")
/// ```
pub fn read(
  session: Session,
  strand: String,
) -> Result(json.JsonValue, snapshot.Error) {
  let prefix = agent.blackboard_prefix <> strand <> "/"
  use cut <- result.try(session.snapshot_reader.capture(
    snapshot.Plan(
      [
        snapshot.Selection(register.FactCustom, prefix, snapshot.All),
      ],
      [],
      0,
    ),
    5000,
  ))
  let ordered =
    list.sort(cut.cells, fn(left, right) {
      int.compare(right.register.seq, left.register.seq)
    })
  let rows = bounded_rows(ordered, prefix, [], 0)
  Ok(
    json.Object([
      #("strand", json.String(strand)),
      #("as_of", json.Int(cut.next_seq - 1)),
      #("total", json.Int(list.length(ordered))),
      #("notes", json.Array(rows)),
    ]),
  )
}

// Each row is charged by encoded bytes, including JSON escaping. The next
// omitted row terminates the prefix, so ordering remains newest first.
fn bounded_rows(
  cells: List(snapshot.Cell),
  prefix: String,
  reversed: List(json.JsonValue),
  used: Int,
) -> List(json.JsonValue) {
  case cells {
    [] -> list.reverse(reversed)
    [cell, ..rest] -> {
      let raw = case cell.register.value.payload {
        json.String(text) -> text
        value -> json.to_string(value)
      }
      let bytes = bit_array.from_string(raw)
      let excerpt =
        utf8_prefix(bytes, int.min(bit_array.byte_size(bytes), 4096), 4)
      let row =
        json.Object([
          #(
            "key",
            json.String(string.drop_start(cell.key, string.length(prefix))),
          ),
          #("seq", json.Int(cell.register.seq)),
          #("text", json.String(excerpt)),
          #(
            "extent",
            json.String(case string.byte_size(raw) > string.byte_size(excerpt) {
              True -> "excerpt"
              False -> "complete"
            }),
          ),
        ])
      case transfer.encoded_size(row, 48_000 - used) {
        Error(_) -> list.reverse(reversed)
        Ok(size) ->
          bounded_rows(rest, prefix, [row, ..reversed], used + size + 1)
      }
    }
  }
}

fn utf8_prefix(bytes: BitArray, size: Int, attempts: Int) -> String {
  case attempts {
    0 -> ""
    _ ->
      case bit_array.slice(bytes, 0, size) |> result.try(bit_array.to_string) {
        Ok(text) -> text
        Error(_) -> utf8_prefix(bytes, int.max(0, size - 1), attempts - 1)
      }
  }
}
