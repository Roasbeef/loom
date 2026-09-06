//// All provider adapters add attribution once without changing stored blocks.

import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/adapter/anthropic
import provider/adapter/gemini
import provider/adapter/openai
import provider/fixture
import provider/model

pub fn every_adapter_attributes_image_first_user_content_once_test() {
  let resolved =
    fixture.resolved(provider: "fixture", model_id: "fixture-model")
  let content = [
    message.UserImage("image-data", "image/png"),
    message.UserText("actual human content", None),
  ]
  let original =
    message.UserMessage(
      content,
      1,
      Some(message.Origin("alice", "Alice \"quoted\"")),
    )
  let request =
    model.ProviderRequest(
      model.ForResolved(resolved),
      None,
      [original],
      [],
      None,
    )
  let builders = [
    anthropic.build_request,
    openai.build_request,
    gemini.build_request,
  ]
  list.each(builders, fn(build) {
    let projected =
      build("https://fixture.invalid", "fixture-key", resolved, request)
    assert list.length(string.split(projected.body, "Human author")) == 2
    assert string.contains(projected.body, "Alice")
    assert string.contains(projected.body, "actual human content")
    assert string.contains(projected.body, "image-data")
    assert string.contains(projected.body, "\"role\":\"user\"")
    assert !string.contains(projected.body, "\"role\":\"system\"")
    assert !string.contains(projected.body, "\"role\":\"developer\"")
    assert request.messages == [original]
  })
}

pub fn anonymous_turns_do_not_gain_fictional_authors_test() {
  let resolved =
    fixture.resolved(provider: "fixture", model_id: "fixture-model")
  let request =
    model.ProviderRequest(
      model.ForResolved(resolved),
      None,
      [message.UserMessage([message.UserText("host turn", None)], 1, None)],
      [],
      None,
    )
  list.each(
    [anthropic.build_request, openai.build_request, gemini.build_request],
    fn(build) {
      let projected =
        build("https://fixture.invalid", "fixture-key", resolved, request)
      assert !string.contains(projected.body, "Human author")
    },
  )
}
