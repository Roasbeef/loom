//// Request construction preserves routing, image placeholders and ordinary
//// message metadata. The fixture also supplies the complete public request
//// boundary to the matched before/after allocation benchmark.

import core/clock
import core/ids
import core/json
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import harness/model_facts.{type ImageReading, Known, ReadsImages, TextOnly}
import harness/provider
import harness/routing
import harness/vision
import provider/gateway
import provider/model
import runtime/effects
import session/session
import support/fixtures
import support/scripted
import tools/tool

/// Builds a disposable provider and complete generation request for measurement.
pub fn request_fixture(count: Int, reading: ImageReading) {
  let context = list.repeat(text_message(), count)
  fixture(context, reading)
}

fn text_message() {
  message.UserMessage(
    [message.UserText("ordinary signed text", Some("signature"))],
    12,
    Some(message.Origin("owner", "Owner")),
  )
}

fn tool_message() {
  message.ToolResultMessage(
    tool_call_id: "read-1",
    tool_name: "fs_read",
    content: [message.ToolResultText("ordinary result", Some("signature"))],
    details: Some(json.String("metadata")),
    usage: None,
    added_tool_names: Some(["helper"]),
    is_error: False,
    timestamp: 13,
  )
}

fn image_message() {
  message.UserMessage(
    [message.UserImage("cGljdHVyZQ==", "image/png")],
    14,
    Some(message.Origin("owner", "Owner")),
  )
}

fn fixture(context: List(message.AgentMessage), reading: ImageReading) {
  let assert Ok(opened) = session.open_memory(clock.fixed(1))
    as "the disposable request session opens"
  let transport =
    scripted.transport(process.new_subject(), fn(_body) { scripted.Say("") })
  let routing =
    routing.Routing(
      gateway: fixtures.routed_gateway(transport),
      role: model.Main,
      lookup: fn(_identity) {
        Ok(Known(fixtures.routed_model(), "fixture", reading))
      },
      fallback: fixtures.fallback(),
    )
  let built = provider.new(routing, opened, Some("system"), tool.registry([]))
  let request =
    effects.GenerationRequest(
      operation: ids.mint_op(ids.generator(clock.fixed(1), 1)).0,
      step_id: "step-1",
      attempt: 1,
      response_entry: ids.mint_entry(ids.generator(clock.fixed(1), 2)).0,
      configuration: fixtures.strand_on_route([]),
      context:,
      stream_options: json.Object([]),
    )
  #(built, request, fn() {
    let assert Ok(Nil) = session.close(opened)
      as "the disposable request session closes"
    Nil
  })
}

pub fn imageless_classification_makes_placeholder_projection_identity_test() {
  let context = [text_message(), tool_message()]
  assert vision.image_bearing(context) == False
  assert vision.placeholdered(context) == context
  list.each([TextOnly, ReadsImages], fn(reading) {
    let #(built, spec, retire) = fixture(context, reading)
    let request = provider.request(built, spec)
    assert request.messages == context
    assert request.system == Some("system")
    assert request.target == model.ForRole(model.Main, Some(model.ThinkingOff))
    retire()
  })
}

pub fn text_only_missing_vision_route_keeps_image_placeholders_test() {
  let context = [text_message(), image_message(), tool_message()]
  let #(built, spec, retire) = fixture(context, TextOnly)
  let request = provider.request(built, spec)
  assert request.messages == vision.placeholdered(context)
  assert vision.image_bearing(request.messages) == False
  assert request.target == model.ForRole(model.Main, Some(model.ThinkingOff))
  retire()
}

pub fn image_capable_and_vision_routes_preserve_original_images_test() {
  let context = [text_message(), image_message(), tool_message()]
  let #(built, spec, retire) = fixture(context, ReadsImages)
  assert provider.request(built, spec).messages == context
  retire()
  let #(built, spec, retire) = fixture(context, TextOnly)
  let routes = built.routing
  let built =
    provider.Provider(
      ..built,
      routing: routing.Routing(
        ..routes,
        gateway: gateway.route(routes.gateway, model.Vision, [
          fixtures.routed_model(),
        ]),
      ),
    )
  let request = provider.request(built, spec)
  assert request.messages == context
  assert request.target == model.ForRole(model.Vision, Some(model.ThinkingOff))
  retire()
}
