//// What one terminal keeps while a long answer streams into it.
////
//// Pushed delivery turned every provider token into its own `stream_delta`
//// frame at every attached terminal. After a few hours of interactive use two
//// `loom` terminals were resident at 32 GB and 26 GB while the daemons behind
//// them sat at 3.5 GB and 1.6 GB, which places the growth in the client and
//// not in the session it was watching. This fixture is the measurement that
//// says which part of the client, and it is kept afterwards as the bound.
////
//// ## Why it is shaped like this
////
//// The model is held by its own process and fed real wire text, because both
//// of the things under measurement are invisible to a fixture that skips
//// either. A decoded `protocol.StreamDelta` built in the test would carry a
//// freshly allocated string and could never show sub-binary retention: on the
//// real path the delta's `text` is a slice of the whole received frame, so
//// keeping the slice pins the frame. And a model folded over in the test
//// process has no mailbox, so a client falling behind the token rate would
//// look exactly like one keeping up.
////
//// The holder renders on a fixed cadence rather than per frame, which is what
//// the shipped loop does: `update_tick` drains up to sixty-four socket
//// messages and then paints once. A resize is the cheapest event that is a
//// flush point and touches no lane, so it is what the holder paints with.
////
//// ## What is asserted
////
//// Three bounds, each naming the growth it rules out. The bytes the live
//// stream retains stay under the cap whatever the token count, so a single
//// answer cannot grow without limit. Process memory between the quarter mark
//// and the end grows by less than a tenth, so nothing accumulates per token.
//// The mailbox stays short, so the terminal keeps up with the token rate.
////
//// The default token count runs in a second or so. `LOOM_TUI_STREAM_DELTAS`
//// raises it for a hunt.

import etui/backend
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import tui
import tui/connection
import tui_test/pushed
import weft/actor

/// The runtime's own account of one process, and of the node around it.
pub type Probe {
  Probe(
    memory: Int,
    message_queue_len: Int,
    heap_size: Int,
    binary_bytes: Int,
    binary_count: Int,
  )
}

/// Node totals, read beside the per-process series.
pub type NodeMemory {
  NodeMemory(total: Int, binary: Int)
}

@external(erlang, "tui_probe_ffi", "probe")
fn probe(pid: Pid) -> Probe

@external(erlang, "tui_probe_ffi", "collected")
fn collect(pid: Pid) -> Nil

@external(erlang, "tui_probe_ffi", "node_memory")
fn node_memory() -> NodeMemory

// Tokens streamed by default. Enough that a per-token cost is unmistakable
// against the model's fixed size, and small enough to stay well inside a
// package's test budget.
const default_deltas = 20_000

// Bytes of answer text per delta, about what a provider token weighs.
const delta_bytes = 16

// Frames drained between paints, matching `update_tick`'s socket budget.
const render_every = 64

// Deltas per second the terminal must sustain at the end of a long answer.
const min_drain_rate = 2000

// The refc bytes the whole holder is allowed to reference once collected. The
// live region itself is held to `tui.live_stream_limit` doubled — the exact
// bound the second fixture asserts on the model — and this coarser number has
// room above it for the wrapped rows a paint leaves cached beside it. What it
// rules out is the shape the leak had: bytes rising with the token count.
const retained_ceiling = 131_072

/// One command to the process holding the model.
type Command {
  /// A frame off the wire, applied through the shipped reducer.
  Frame(message: connection.Message)

  /// A barrier: the reply lands after every frame sent before it.
  Drained(reply: Subject(Nil))
}

type Holder {
  Holder(model: tui.Model, seen: Int)
}

fn holder() -> actor.StartResult(Subject(Command)) {
  actor.new(Holder(pushed.attached(), 0))
  |> actor.on_message(fn(holder, command) {
    case command {
      Drained(reply) -> {
        process.send(reply, Nil)
        actor.continue(holder)
      }
      Frame(message) -> {
        let model = tui.accept_connection_message(holder.model, message)
        let seen = holder.seen + 1

        // The paint the shipped loop would have done after this batch. A
        // resize is a flush point which touches neither lane nor socket, so
        // what it costs is exactly the transcript and stream projection:
        // `update` invalidates the frame and `refresh_frame_cache` renders it
        // before returning, so `stream_lines` and the markdown wrap are inside
        // the measured loop rather than deferred to a `view` nobody calls.
        let model = case seen % render_every {
          0 -> tui.update(backend.Resize(model.width, model.height), model)
          _ -> model
        }
        actor.continue(Holder(model:, seen:))
      }
    }
  })
  |> actor.start
}

// Answer text of a fixed weight, distinct per token so nothing downstream can
// share one binary between fragments and flatter the measurement. Words and
// line breaks are part of the shape rather than decoration: a stream of one
// unbroken run of characters would be a single enormous logical line, and
// what that measures is the wrapper's behaviour on input no provider sends.
fn token(index: Int) -> String {
  let seed = int.to_string(index)
  let word =
    string.repeat("x", int.max(1, delta_bytes - 1 - string.length(seed)))
    <> seed
  case index % 12 {
    11 -> word <> "\n"
    _ -> word <> " "
  }
}

fn deltas_wanted() -> Int {
  case bootstrap.getenv("LOOM_TUI_STREAM_DELTAS") {
    Ok(text) ->
      case int.parse(string.trim(text)) {
        Ok(count) if count > 0 -> count
        Ok(_) | Error(Nil) -> default_deltas
      }
    Error(Nil) -> default_deltas
  }
}

// Blocks until the holder has applied every frame sent so far, then collects,
// so a sample describes what the model retains rather than a queue in motion
// or the garbage a burst of paints left behind.
fn settled(commands: Subject(Command), pid: Pid) -> Probe {
  actor.call(commands, 120_000, Drained)
  collect(pid)
  probe(pid)
}

fn report(label: String, probe: Probe) -> Nil {
  io.println_error(
    "stream-bounds "
    <> label
    <> ": memory="
    <> int.to_string(probe.memory)
    <> " queue="
    <> int.to_string(probe.message_queue_len)
    <> " heap="
    <> int.to_string(probe.heap_size)
    <> " binary_bytes="
    <> int.to_string(probe.binary_bytes)
    <> " binary_count="
    <> int.to_string(probe.binary_count),
  )
}

// The deepest the mailbox got while the run was in flight. Sampling from the
// coordinator is the only way to see it: by the time the holder answers a
// barrier the queue it fell behind on is already gone.
fn feed(
  commands: Subject(Command),
  pid: Pid,
  from: Int,
  to: Int,
  deepest: Int,
) -> Int {
  case from >= to {
    True -> deepest
    False -> {
      process.send(commands, Frame(pushed.delta("main", "op-1", token(from))))

      // Reading the queue on every frame would cost more than the frame does.
      let deepest = case from % 256 {
        0 -> int.max(deepest, probe(pid).message_queue_len)
        _ -> deepest
      }
      feed(commands, pid, from + 1, to, deepest)
    }
  }
}

pub fn a_long_live_stream_is_bounded_in_what_the_terminal_keeps_test() {
  let wanted = deltas_wanted()
  let quarter = wanted / 4
  let assert Ok(started) = holder() as "the model holder starts"
  let commands = started.data
  let pid = started.pid

  let before = node_memory()
  let baseline = settled(commands, pid)
  report("baseline", baseline)

  let first_depth = feed(commands, pid, 0, quarter, 0)
  let at_quarter = settled(commands, pid)
  report("quarter", at_quarter)

  let started_ms = bootstrap.monotonic_time_ms()
  let rest_depth = feed(commands, pid, quarter, wanted, first_depth)
  let at_end = settled(commands, pid)
  let elapsed_ms = int.max(1, bootstrap.monotonic_time_ms() - started_ms)
  let rate = { wanted - quarter } * 1000 / elapsed_ms
  report("full", at_end)
  io.println_error(
    "stream-bounds drain: "
    <> int.to_string(wanted - quarter)
    <> " deltas in "
    <> int.to_string(elapsed_ms)
    <> " ms = "
    <> int.to_string(rate)
    <> "/s",
  )

  let after = node_memory()
  io.println_error(
    "stream-bounds node: total "
    <> int.to_string(before.total)
    <> " -> "
    <> int.to_string(after.total)
    <> ", binary "
    <> int.to_string(before.binary)
    <> " -> "
    <> int.to_string(after.binary)
    <> "; deepest queue "
    <> int.to_string(rest_depth),
  )

  // What the answer on screen is allowed to weigh. Without a cap this is the
  // whole answer plus one frame slice per token, which is what the resident
  // terminals were made of.
  assert retained_bytes(at_end) <= retained_ceiling
    as "a live stream retains a bounded number of bytes however long the answer"

  // The leak's signature: the model grew in proportion to tokens. Three
  // quarters of the run adds less than a tenth once the streams are bounded.
  assert at_end.memory <= at_quarter.memory * 110 / 100
    as "process memory is flat between the quarter mark and the end"

  // The mailbox is bounded in the field only if the terminal drains faster
  // than a provider fills it, so the rate is the property and the queue depth
  // this fixture reaches is not: the coordinator sends as fast as it can build
  // frames, which no provider does. Before the region was bounded the rate
  // fell as the answer grew, which is how a terminal on a long turn stopped
  // draining its socket at all. `min_drain_rate` is an order of magnitude
  // above the fastest provider stream measured against this client.
  assert rate >= min_drain_rate
    as "the terminal drains deltas far faster than a provider can produce them"

  process.send_exit(pid)
}

// A bounded ascending index list; the standard library has no range.
fn fragment_indices(from: Int, to: Int, built: List(Int)) -> List(Int) {
  case from >= to {
    True -> list.reverse(built)
    False -> fragment_indices(from + 1, to, [from, ..built])
  }
}

// Bytes the live stream region is holding: the text itself, and the refc
// binaries the fragments pin whether or not the text needs them.
fn retained_bytes(probe: Probe) -> Int {
  probe.binary_bytes
}

pub fn a_later_operation_drops_the_stream_it_replaces_test() {
  let model =
    list.fold(
      list.map(fragment_indices(0, 8000, []), fn(i) {
        pushed.delta("main", "op-1", token(i))
      }),
      pushed.attached(),
      tui.accept_connection_message,
    )
  let assert [tui.Stream(bytes:, fragments:, ..)] = model.streams
    as "the live answer is on screen as one stream"

  // The exact invariant, on the model rather than on the process: the region
  // is collapsed back to `live_stream_limit` whenever it would pass twice it,
  // so no answer length can make it grow.
  assert bytes <= tui.live_stream_limit * 2
    as "a live stream never retains more than twice the preview bound"
  assert list.length(fragments) <= 2 * tui.live_stream_limit / delta_bytes
    as "collapsing keeps the fragment list bounded too"

  // The next operation is a different answer, so the previous one's fragments
  // are not kept beside it. This is the rollover, not the commit: a strand
  // reaching `done` and an entry landing both clear the region too, but the
  // lane drops a pushed `op_transition` and a pushed `entry_added` rather
  // than forwarding them, so neither path is reachable from a frame here.
  let next =
    tui.accept_connection_message(model, pushed.delta("main", "op-2", "New"))
  assert next.streams == [tui.Stream("main", "op-2", "text", ["New"], 3)]
    as "the previous operation's fragments are dropped, not carried forward"
  let assert Some(_) = next.channel as "the lane survives the whole answer"
  assert next.notices == 0 as "no notice was pushed in this fixture"
  assert None == next.submitting as "nothing was submitted here"
}
