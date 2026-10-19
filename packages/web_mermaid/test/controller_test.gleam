//// Regression tests for the pure isolated-frame controller.

import gleam/int
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit/should
import web_mermaid/controller

/// Rejects malformed, excessive, and policy-bearing source at the boundary.
///
/// ## Examples
/// ```gleam
/// assert controller.input("null") == controller.Ignored
/// ```
pub fn input_boundary_test() {
  controller.input("null") |> should.equal(controller.Ignored)
  controller.input(request_json(1, "dark", repeated("x", 32_001)))
  |> should.equal(controller.Ignored)
  controller.input(request_json(1, "dark", "%%{init: x}"))
  |> should.equal(controller.Forbidden(1))
  controller.input(request_json(1, "dark", "  ---\nsource"))
  |> should.equal(controller.Forbidden(1))
  controller.input(request_json(1, "dark", "click A https://invalid"))
  |> should.equal(controller.Forbidden(1))
  controller.input(request_json(1, "dark", "  click\tA https://invalid"))
  |> should.equal(controller.Forbidden(1))
  controller.input(request_json(1, "dark", "click\tA action"))
  |> should.equal(controller.Forbidden(1))
  controller.input(request_json(1, "default", "ok"))
  |> should.equal(
    controller.Accepted(controller.Request("ok", controller.Light, 1)),
  )
}

/// Serializes work and retains only the newest waiting request.
///
/// ## Examples
/// ```gleam
/// assert controller.new().latest == 0
/// ```
pub fn serialized_queue_test() {
  let first = controller.Request("first", controller.Dark, 1)
  let old = controller.Request("old", controller.Dark, 2)
  let newest = controller.Request("newest", controller.Dark, 3)
  let #(model, _) =
    controller.update(controller.new(), controller.Requested(first))
  let #(model, _) = controller.update(model, controller.Requested(old))
  let #(model, _) = controller.update(model, controller.Requested(newest))
  let #(model, effects) =
    controller.update(model, controller.Rendered(1, Ok("<svg/>")))
  effects |> should.equal([controller.Begin(newest)])
  let #(model, _) = controller.update(model, controller.Published(1, Ok(300.0)))
  model.phase
  |> should.equal(controller.Busy(controller.Drawing, newest, None))
}

/// Prevents stale replies and clears queued work after a refusal.
///
/// ## Examples
/// ```gleam
/// assert controller.max_height == 2000
/// ```
pub fn stale_refusal_test() {
  let request = controller.Request("active", controller.Dark, 1)
  let #(model, _) =
    controller.update(controller.new(), controller.Requested(request))
  let #(model, effects) = controller.update(model, controller.Refused(2))
  effects
  |> should.equal([
    controller.Clear,
    controller.ReplyToParent(controller.FailedReply(2)),
  ])
  let #(model, effects) =
    controller.update(model, controller.Rendered(1, Ok("secret")))
  effects |> should.equal([])
  model.latest |> should.equal(2)
}

/// Checks SVG element and href restrictions over every node.
///
/// ## Examples
/// ```gleam
/// assert controller.safe_svg([controller.Node("svg", [])])
/// ```
pub fn svg_safety_test() {
  controller.safe_svg([
    controller.Node("svg", []),
    controller.Node("path", [controller.Attribute("href", "#local")]),
  ])
  |> should.be_true
  controller.safe_svg([controller.Node("svg", []), controller.Node("image", [])])
  |> should.be_false
  controller.safe_svg([
    controller.Node("svg", []),
    controller.Node("use", [
      controller.Attribute("xlink:href", "https://invalid"),
    ]),
  ])
  |> should.be_false
  controller.safe_svg([controller.Node("html", [])]) |> should.be_false
}

/// Checks UTF-16 limits, serialized settings, and fixed reply encoding.
///
/// ## Examples
/// ```gleam
/// assert controller.min_height == 120
/// ```
pub fn limits_and_configuration_test() {
  case controller.input(request_json(1, "dark", repeated("a", 32_000))) {
    controller.Accepted(_) -> should.be_true(True)
    _ -> should.be_true(False)
  }
  case controller.input(request_json(1, "dark", repeated("💜", 16_000))) {
    controller.Accepted(_) -> should.be_true(True)
    _ -> should.be_true(False)
  }
  controller.input(request_json(1, "dark", repeated("💜", 16_001)))
  |> should.equal(controller.Ignored)
  controller.configuration(controller.Light)
  |> string.contains("\"theme\":\"default\"")
  |> should.be_true
  controller.reply_json(controller.RenderedReply(4, 300))
  |> string.contains("\"height\":300")
  |> should.be_true
}

fn request_json(revision: Int, theme: String, source: String) -> String {
  "{\"source\":"
  <> json.to_string(json.string(source))
  <> ",\"theme\":\""
  <> theme
  <> "\",\"revision\":"
  <> int.to_string(revision)
  <> "}"
}

fn repeated(source: String, count: Int) -> String {
  string.repeat(source, count)
}

/// Ignores wrong-stage completions and stale inspection results.
///
/// ## Examples
/// ```gleam
/// assert controller.new().latest == 0
/// ```
pub fn wrong_stage_and_stale_completion_test() {
  let request = controller.Request("drawing", controller.Dark, 1)
  let #(model, effects) =
    controller.update(controller.new(), controller.Published(1, Ok(300.0)))
  effects |> should.equal([])
  let #(model, _) = controller.update(model, controller.Requested(request))
  let #(model, effects) =
    controller.update(model, controller.Rendered(1, Ok("<svg/>")))
  effects |> should.equal([controller.Inspect(1, "<svg/>")])
  let #(model, _) =
    controller.update(
      model,
      controller.Requested(controller.Request("new", controller.Dark, 2)),
    )
  let #(model, effects) =
    controller.update(model, controller.Published(1, Ok(300.0)))
  effects
  |> should.equal([
    controller.Begin(controller.Request("new", controller.Dark, 2)),
  ])
  model.phase
  |> should.equal(controller.Busy(
    controller.Drawing,
    controller.Request("new", controller.Dark, 2),
    None,
  ))
}

/// Clamps and rounds height replies and avoids duplicate resize measurements.
///
/// ## Examples
/// ```gleam
/// assert controller.max_height == 2000
/// ```
pub fn height_and_resize_test() {
  let request = controller.Request("diagram", controller.Dark, 1)
  let #(model, _) =
    controller.update(controller.new(), controller.Requested(request))
  let #(model, _) =
    controller.update(model, controller.Rendered(1, Ok("<svg/>")))
  let #(model, effects) =
    controller.update(model, controller.Published(1, Ok(119.1)))
  effects
  |> should.equal([controller.ReplyToParent(controller.RenderedReply(1, 120))])
  let #(model, effects) = controller.update(model, controller.Resized(600.0))
  effects |> should.equal([controller.Measure(1)])
  let #(_, effects) = controller.update(model, controller.Measured(1, 2000.1))
  effects
  |> should.equal([controller.ReplyToParent(controller.RenderedReply(1, 2000))])
}
