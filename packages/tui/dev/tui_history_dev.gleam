//// Render-cost measurements over exported durable history.
////
//// The input is private JSONL from an operator-authorized session export.
//// Only measurements are printed; no conversation or reasoning leaves the
//// input file. Both revisions run this identical driver over identical data.

import core/codec
import core/json
import etui/backend
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/string
import simplifile
import tui
import tui/connection
import tui/protocol
import tui/workspace

type ClockUnit {
  Microsecond
}

@external(erlang, "erlang", "monotonic_time")
fn now(unit: ClockUnit) -> Int

@external(erlang, "erlang", "garbage_collect")
fn collect() -> Nil

/// Measures initial layout and separately painted keys over a saved history.
///
/// ## Examples
///
/// ```sh
/// gleam dev history /private/tmp/authorized-history.jsonl
/// ```
pub fn run(path: String) {
  let assert Ok(source) = simplifile.read(path) as "history export is readable"
  let records =
    source
    |> string.split("\n")
    |> list.filter(fn(line) { line != "" })
    |> list.map(fn(line) {
      let assert Ok(raw) = json.parse(line) as "export contains JSON"
      let assert Ok(value) = codec.decode_entry(raw)
        as "export contains durable entries"
      protocol.EntryRecord("main", value)
    })
    |> list.reverse
  let base =
    tui.new_model(
      connection.new_inbox(),
      workspace.Context("history benchmark", None),
    )
  let base =
    tui.Model(
      ..base,
      records: records,
      transcript: [],
      record_cache_valid: False,
    )
  let start = now(Microsecond)
  let model = tui.update(backend.Resize(160, 48), base)
  let layout = now(Microsecond) - start
  collect()

  // Resize forces each updated key to paint even when this tight loop has
  // not spent a real frame interval. It does not invalidate wrapped history
  // when dimensions are unchanged, matching a user's separately typed keys.
  let #(model, times) =
    list.fold(list.repeat(Nil, 64), #(model, []), fn(acc, _) {
      let #(model, samples) = acc
      let start = now(Microsecond)
      let changed =
        tui.update(backend.KeyPress("q"), model)
        |> fn(next) { tui.update(backend.Resize(160, 48), next) }
      #(changed, [now(Microsecond) - start, ..samples])
    })
  let ordered = list.sort(times, int.compare)
  let assert Ok(p95) = ordered |> list.drop(60) |> list.first
    as "64 key samples"
  let assert Ok(median) = ordered |> list.drop(32) |> list.first
    as "64 key samples"
  io.println(
    "history records="
    <> int.to_string(list.length(records))
    <> " rows="
    <> int.to_string(model.rendered_row_count)
    <> " initial_ms="
    <> milliseconds(layout)
    <> " key_median_ms="
    <> milliseconds(median)
    <> " key_p95_ms="
    <> milliseconds(p95),
  )
}

fn milliseconds(micros) {
  float.to_string(int.to_float(micros) /. 1000.0)
}
