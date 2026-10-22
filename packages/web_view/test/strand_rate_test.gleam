//// The real web header selects the viewed strand's own measured throughput.
//// Focus and joining a generation already observed in the background must
//// preserve the clock and settled reading rather than borrow the parent's.

import core/accounting
import core/json
import core/message
import core/usage_evidence
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/dev/query
import lustre/element
import page_fixture
import session_view/protocol
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import web_view/component

fn usage(output: Int) -> message.Usage {
  message.Usage(
    ..accounting.zero_usage(),
    output: output,
    total_tokens: output,
    evidence: usage_evidence.reported(usage_evidence.Api),
  )
}

fn page(clock) {
  component.update(
    component.new(page_fixture.start_with(clock)),
    component.Opened(process.new_subject()),
  ).0
  |> component.apply([phase_cut(10, None)])
}

fn at(model, clock, ms) {
  page_fixture.set(clock, ms)
  component.update(model, component.Ticked).0
}

fn header(model) -> String {
  let assert Ok(header) =
    query.find(component.view(model), query.element(query.tag("header")))
    as "the web header exists"
  element.to_string(header)
}

fn settled(model, strand, output) {
  component.apply(model, [
    session_channel.Auxiliary(protocol.UsageChanged(
      strand,
      None,
      None,
      usage(output),
      Some(usage(output)),
    )),
  ])
}

fn phase_cut(seq, phase) {
  let assert session_channel.Captured(cut, view, trigger) =
    lane_fixture.captured(seq, Some(lane_fixture.main_op()))
    as "a real capture fixture"
  let strands =
    list.map(view.strands, fn(strand) {
      case strand.id == lane_fixture.child {
        True -> protocol.Strand(..strand, live_phase: phase)
        False -> strand
      }
    })
  session_channel.Captured(
    snapshot.Captured(..cut, metadata: json.String(int.to_string(seq))),
    snapshot_view.View(..view, strands:),
    trigger,
  )
}

pub fn switching_restores_each_strands_rate_and_never_borrows_parent_tps_test() {
  let clock = page_fixture.clock()
  let model =
    page(clock)
    |> at(clock, 1000)
    |> component.apply([
      session_channel.Auxiliary(protocol.OperationChanged("main", "tools")),
      session_channel.Auxiliary(protocol.OperationChanged("main", "assistant")),
      session_channel.Auxiliary(protocol.OperationChanged(
        lane_fixture.child,
        "assistant",
      )),
    ])
  let model = at(model, clock, 3000) |> settled("main", 200)
  assert string.contains(header(model), ">100</span> tok/s")

  // An unmeasured child has no rate, rather than the parent's last reading.
  let child = component.focus(model, lane_fixture.child).0
  assert string.contains(header(child), "<span class=\"num\">—</span> tok/s")
  assert !string.contains(header(child), ">100</span> tok/s")
  let model =
    component.focus(child, "main").0 |> settled(lane_fixture.child, 900)
  assert string.contains(header(model), ">100</span> tok/s")
  let child = component.focus(model, lane_fixture.child).0
  assert string.contains(header(child), ">450</span> tok/s")
  let parent = component.focus(child, "main").0
  assert string.contains(header(parent), ">100</span> tok/s")
}

pub fn joining_a_captured_background_generation_keeps_its_original_clock_test() {
  let clock = page_fixture.clock()
  let model =
    page(clock)
    |> at(clock, 1000)
    |> component.apply([phase_cut(11, Some("assistant"))])
    |> at(clock, 4000)
  let child =
    component.focus(model, lane_fixture.child).0
    |> component.apply([
      session_channel.Auxiliary(protocol.StreamDelta(
        lane_fixture.child,
        "",
        "request",
        "text",
        "later fragment",
      )),
    ])
    |> at(clock, 5000)
    |> settled(lane_fixture.child, 800)
  assert string.contains(header(child), ">200</span> tok/s")
  assert !string.contains(header(child), ">800</span> tok/s")
}

pub fn attaching_after_a_generation_started_does_not_invent_its_tps_test() {
  let clock = page_fixture.clock()
  let model =
    component.update(
      component.new(page_fixture.start_with(clock)),
      component.Opened(process.new_subject()),
    ).0
    |> at(clock, 4000)
    |> component.apply([phase_cut(10, Some("assistant"))])
  let child =
    component.focus(model, lane_fixture.child).0
    |> at(clock, 5000)
    |> settled(lane_fixture.child, 800)
  assert string.contains(header(child), "<span class=\"num\">—</span> tok/s")
  assert !string.contains(header(child), ">100</span> tok/s")
}

fn answered_phase(phase) {
  let assert session_channel.Captured(cut, view, trigger) =
    lane_fixture.answered(["settled answer"])
    as "the exact streamed response is now durable"
  let strands =
    list.map(view.strands, fn(strand) {
      case strand.id == "main" {
        True -> protocol.Strand(..strand, live_phase: Some(phase))
        False -> strand
      }
    })
  session_channel.Captured(
    snapshot.Captured(..cut, metadata: json.String(phase)),
    snapshot_view.View(..view, strands:),
    trigger,
  )
}

pub fn a_stream_retiring_cut_keeps_the_next_generation_measurable_test() {
  let clock = page_fixture.clock()
  let model =
    page(clock)
    |> at(clock, 1000)
    |> component.apply([
      session_channel.Auxiliary(protocol.OperationChanged("main", "tools")),
      session_channel.Auxiliary(protocol.OperationChanged("main", "assistant")),
      lane_fixture.fragment(
        lane_fixture.generation(2),
        "text",
        "settled answer",
      ),
      lane_fixture.fragment(lane_fixture.generation(2), "end", ""),
    ])
    |> at(clock, 2000)
    |> settled("main", 100)
  assert string.contains(header(model), ">100</span> tok/s")

  // The tools cut retires the exact response stream. Its phase must be read
  // after retirement, so the following assistant cut starts a complete window.
  let model =
    model
    |> at(clock, 3000)
    |> component.apply([answered_phase("tools")])
    |> at(clock, 4000)
    |> component.apply([answered_phase("assistant")])
    |> at(clock, 6000)
    |> settled("main", 800)
  assert string.contains(header(model), ">400</span> tok/s")
}

pub fn a_lagging_capture_never_upgrades_a_background_partial_window_test() {
  let clock = page_fixture.clock()
  let model =
    page(clock)
    |> at(clock, 1000)
    |> component.apply([
      session_channel.Auxiliary(protocol.StreamDelta(
        lane_fixture.child,
        "",
        "already-running",
        "text",
        "first observed fragment",
      )),
    ])
    |> at(clock, 2000)
    |> component.apply([phase_cut(11, None)])
    |> at(clock, 4000)
    |> component.apply([phase_cut(12, Some("assistant"))])
  let child =
    component.focus(model, lane_fixture.child).0
    |> at(clock, 5000)
    |> settled(lane_fixture.child, 800)
  assert string.contains(header(child), "<span class=\"num\">—</span> tok/s")
  assert !string.contains(header(child), ">100</span> tok/s")
}
