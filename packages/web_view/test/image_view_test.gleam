//// The images the lane draws (protocol-change/051, the addendum on images):
//// each row that carries one shows a thumbnail whose `src` is the page's own
//// address, on both pages, and the page answers the daemon's request for an
//// image only where it drew one. The stylesheet's `img-src 'self'` admits
//// exactly these requests, so no `data:` or `blob:` address may appear.

import gleam/erlang/process
import gleam/list
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/transcript_image.{Image}
import session_view/turns
import web_view/component
import web_view/operator_page

fn page() {
  component.new(page_fixture.start())
  |> component.apply([lane_fixture.pictured()])
  |> lane_fixture.opened
}

fn observer() -> String {
  element.to_string(component.view(page()))
}

fn operator() -> String {
  element.to_string(operator_page.view(page()))
}

// The `src` of every image the page draws.
fn sources(html: String) -> List(String) {
  case string.split(html, "<img ") {
    [] -> []
    [_, ..images] ->
      list.filter_map(images, fn(image) {
        case string.split(image, "src=\"") {
          [_, rest, ..] ->
            case string.split_once(rest, "\"") {
              Ok(#(source, _)) -> Ok(source)
              Error(Nil) -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
  }
}

// The lane's second pictured row: the read call's step.
fn step_ref() -> String {
  let assert [_, #(ref, _)] = turns.pictured(component.pieces(page()))
    as "the prompt and the read step carry images"
  ref
}

pub fn a_prompt_draws_a_thumbnail_for_each_raster_image_test() {
  let drawn = observer()
  assert string.contains(
    drawn,
    "<details class=\"picture\"><summary class=\"picture-summary\"><img",
  )
  assert list.contains(sources(drawn), "A/image/1.0/0")
}

pub fn an_image_that_is_not_raster_keeps_only_its_text_row_test() {
  let drawn = observer()

  // The SVG is the second image and the mislabelled one the third; neither
  // has a picture, and each still has its `[image <type>]` row, escaped.
  assert !list.contains(sources(drawn), "A/image/1.0/1")
  assert !list.contains(sources(drawn), "A/image/1.0/2")
  assert string.contains(drawn, "[image image/svg+xml]")
  assert string.contains(drawn, "[image image/x-&lt;b&gt;evil&lt;/b&gt;]")
  assert !string.contains(drawn, "<b>evil")
}

pub fn a_tool_result_draws_its_image_with_the_call_test() {
  let ref = step_ref()
  assert string.contains(ref, "-")
  assert list.contains(sources(observer()), "A/image/" <> ref <> "/0")
}

pub fn every_src_is_the_pages_own_address_test() {
  let all = list.append(sources(observer()), sources(operator()))
  assert list.length(all) == 4
  assert list.all(all, fn(source) {
    string.starts_with(source, "A/image/") && !string.contains(source, ":")
  })
}

pub fn no_page_carries_a_data_or_blob_address_test() {
  assert !string.contains(observer(), "data:")
  assert !string.contains(observer(), "blob:")
  assert !string.contains(operator(), "data:")
  assert !string.contains(operator(), "blob:")
}

pub fn the_alternative_text_is_fixed_test() {
  assert string.contains(observer(), "alt=\"Attached image\"")
  assert !string.contains(observer(), "alt=\"look")
}

pub fn the_operators_page_draws_the_same_pictures_test() {
  assert sources(operator()) == sources(observer())
}

pub fn a_page_with_no_images_draws_no_pictures_test() {
  let plain =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.answered(["hello"])])
  let drawn = element.to_string(component.view(plain))
  assert !string.contains(drawn, "<details class=\"picture\">")
  assert sources(drawn) == []
}

// The daemon's request for an image, answered by the page.
fn asked(ref: String, position: Int) -> Result(transcript_image.Image, Nil) {
  let reply = process.new_subject()
  let _ =
    page_fixture.run(page(), component.update, [
      component.ImageRequested(ref, position, reply),
    ])
  let assert Ok(answer) = process.receive(reply, 1000)
    as "the page answers a request for an image"
  answer
}

pub fn the_page_answers_for_an_image_it_drew_test() {
  assert asked("1.0", 0) == Ok(Image("image/png", lane_fixture.png))
  assert asked("1.0", 1) == Ok(Image("image/svg+xml", lane_fixture.svg))
  assert asked(step_ref(), 0) != Error(Nil)
}

pub fn the_page_answers_for_no_other_image_test() {
  assert asked("9.0", 0) == Error(Nil)
  assert asked("1.0", 3) == Error(Nil)
  assert asked("1.0", -1) == Error(Nil)
  assert asked("", 0) == Error(Nil)
}

pub fn the_operators_page_answers_through_the_observers_message_test() {
  let reply = process.new_subject()
  let _ =
    page_fixture.run(page(), operator_page.update, [
      operator_page.Observed(component.ImageRequested("1.0", 0, reply)),
    ])
  assert process.receive(reply, 1000)
    == Ok(Ok(Image("image/png", lane_fixture.png)))
}
