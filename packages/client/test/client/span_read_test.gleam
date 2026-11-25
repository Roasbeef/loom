//// The resident side of `sessions.span` (protocol-change/134): the lines of one
//// span of a real runtime's store, found by scanning down from the span's last
//// record, and the refusals for a record that is not the session's.

import client/internal/ffi_os
import client/span_read
import core/clock
import core/entry
import core/ids
import core/message
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import session/session
import session_view/span_lines
import simplifile
import storage/storage

const now = 1_790_000_000_000

fn open() -> api.Runtime {
  let directory =
    "build/span-read-test-" <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the scratch directory is made"
  let time = clock.fixed(at: now)
  let assert Ok(opened) =
    session.open_sqlite(
      directory <> "/session.db",
      "span-read-test",
      30_000,
      time,
    )
    as "the SQLite session must open"
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: [],
    )
  let assert Ok(runtime) =
    api.open(
      opened,
      effects.Effects(
        clock: time,
        entropy: ffi_os.unique_positive_integer,
        timers: effects.real_timers(),
        provider: effects.ProviderSurface(
          timeout_ms: 60_000,
          request: fn(_spec) {
            stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
          },
        ),
        tools: effects.ToolSurface(
          clear: fn(_query) {
            effects.ClearanceRefused(reason: "no tools in this harness")
          },
          run: fn(_run) { effects.ToolFailed(reason: "no tools") },
          replay_still_safe: fn(_name) { False },
          execution_mode: fn(_name) { effects.ExclusiveExecution },
          recover: None,
        ),
        hooks: effects.default_hooks(),
      ),
      api.default_options(configuration),
    )
    as "the runtime must open"
  runtime
}

fn newest(runtime: api.Runtime) -> entry.Entry {
  let assert Ok(Some(session.Cell(value: Some(leaf), ..))) =
    session.strand_leaf(runtime.session, "main")
    as "main has a leaf"
  let assert Ok([record, ..]) =
    storage.scan_branch(runtime.session.store, storage.branch_scan(leaf))
    as "the branch scans"

  record
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage([message.UserText(text, None)], now, None)
}

// A span is read back from the store by its last record and its sequences, in
// order, and a record that is not the session's is refused.
pub fn a_span_is_read_back_by_its_last_record_test() {
  let runtime = open()
  let assert Ok(_) = api.prompt(runtime, [user("fix the replay")])
    as "the prompt is accepted"
  let record = newest(runtime)
  let last = ids.entry_id_to_string(record.id)
  let assert Ok(feed) = span_read.build(runtime, last, record.seq, record.seq)
    as "the span reads"

  assert list.map(feed.lines, fn(line) { line.kind }) == [span_lines.Prompted]
  assert feed.omitted == 0

  let stranger = ids.mint_entry(ids.generator(clock.fixed(5), 99)).0

  assert span_read.build(runtime, "not-an-id", 0, 0) |> is_error
  assert span_read.build(runtime, ids.entry_id_to_string(stranger), 0, 5)
    |> is_error
  let assert Ok(Nil) = api.close(runtime)
}

// A span that starts after the record it ends at is empty, and the scan is
// bounded by the span's length and not the strand's.
pub fn the_scan_stops_at_the_spans_first_sequence_test() {
  let runtime = open()
  let assert Ok(_) = api.prompt(runtime, [user("one")]) as "accepted"
  let record = newest(runtime)
  let last = ids.entry_id_to_string(record.id)
  let assert Ok(feed) =
    span_read.build(runtime, last, record.seq + 1, record.seq + 1)
    as "reads"

  assert feed.lines == []
  let assert Ok(Nil) = api.close(runtime)
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}
