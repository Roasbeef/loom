//// Drawn images: the box in the frame, and what the terminal is told.
////
//// An image a tool returned is a placeholder row on every terminal
//// (`image_rows_test`). On a terminal whose probe answered for kitty,
//// Ghostty or iTerm2 it becomes a labelled box. These tests render whole
//// frames for the probed-yes and probed-no cases, and drive `tui.step` to
//// read the image commands as values, because the order is the behaviour:
//// nothing is sent before the alternate screen is open, a kitty image is
//// uploaded when it enters view and deleted when it leaves, and an iTerm2
//// picture is drawn only after the frame that laid its box out, and again
//// after a resize. The error paths are here too: a probe that times out, an
//// image that will not decode, and an image over the budget.

import core/json
import etui/backend
import etui/buffer
import etui/geometry
import etui/graphics
import etui/graphics/kitty
import etui/style
import frame_scene
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as host_bootstrap
import image_fixture
import session_view/image_header
import session_view/model as _
import session_view/shared_set
import simplifile
import tui/appearance
import tui/demo_image
import tui/effect.{type Effect}
import tui/frame
import tui/image_box
import tui/image_shown
import tui/image_support
import tui/layout
import tui/model.{type Model, Model, View} as tui_model
import tui/queue_editor
import tui/render
import tui/submit
import tui/view_set
import tui_test/stepping

fn kitty_support() -> image_support.Support {
  image_support.KittyPlaceholders(graphics.CellSize(width: 10, height: 20))
}

fn iterm_support() -> image_support.Support {
  image_support.Iterm2Inline(graphics.CellSize(width: 10, height: 20))
}

fn with_support(base: Model, support: image_support.Support) -> Model {
  Model(..base, view: View(..base.view, image_support: support))
}

// A user turn, a call that returned `images`, and an answer. The support is
// set before the entries are attached, because the rows of an image are
// built when its entry is projected.
fn scene(support: image_support.Support, images: List(#(String, String))) {
  frame_scene.attach(
    with_support(frame_scene.model(), support),
    "fix readme badge",
    [
      frame_scene.user(1, "Look at plots/latency.png."),
      frame_scene.assistant(2, "", [
        frame_scene.call("r1", "fs_read", [
          #("path", json.String("plots/latency.png")),
        ]),
      ]),
      frame_scene.result_images(3, "r1", "fs_read", images),
      frame_scene.assistant(4, "The jump lines up with the deploy.", []),
    ],
  )
}

// The frame the model would draw, built without performing any effect.
fn lines_of(model: Model) -> List(String) {
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  render.render_frame(model, screen).0 |> frame.buffer_to_lines
}

fn frame_of(model: Model) -> buffer.Buffer {
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  render.render_frame(model, screen).0
}

// The numbers from one to `last`.
fn numbers(last: Int) -> List(Int) {
  int.range(from: 1, to: last + 1, with: [], run: fn(all, n) { [n, ..all] })
  |> list.reverse
}

// How many kitty placeholder characters a row holds. `string.contains` is
// no help: it matches whole graphemes, and a placeholder is the base of a
// grapheme with its three combining marks, so it never matches the
// placeholder character alone.
fn placeholders(text: String) -> Int {
  text
  |> string.to_utf_codepoints
  |> list.count(fn(codepoint) {
    string.utf_codepoint_to_int(codepoint) == 0x10EEEE
  })
}

fn shows_placeholders(row: String) -> Bool {
  placeholders(row) > 0
}

fn image_commands(effects: List(Effect)) -> List(image_shown.Command) {
  list.flat_map(effects, fn(requested) {
    case requested {
      effect.DrawImages(commands) -> commands
      _ -> []
    }
  })
}

fn woke(effects: List(Effect)) -> Bool {
  list.contains(effects, effect.WakeLoop)
}

fn id_of(data: String) -> kitty.ImageId {
  let assert Ok(id) =
    kitty.image_id(image_box.id_of(image_header.fingerprint(data)))
    as "a fingerprint's id is in the protocol's range"
  id
}

// ------------------------------------------------------------ the frame

pub fn a_kitty_terminal_draws_a_labelled_box_of_placeholders_test() {
  let data = image_fixture.png(1200, 700)
  let #(model, _) =
    stepping.step(
      backend.Resize(120, 40),
      scene(kitty_support(), [#("image/png", data)]),
    )
  let lines = lines_of(model)
  let assert Ok(top) =
    list.find(lines, string.contains(_, "╭─ image 1 · image/png · 1200×700"))
    as "the box carries the image's words"
  assert string.contains(top, "╮")
  assert !list.any(lines, string.contains(_, "▣ image 1"))
    as "the placeholder row is replaced by the box"
  assert list.any(lines, string.contains(_, "╰─ o opens externally"))
  let cells = list.filter(lines, shows_placeholders)

  // 1200 by 700 pixels in cells of 10 by 20 fits 42 columns by 12 rows.
  assert list.length(cells) == 12
  list.each(cells, fn(row) {
    assert placeholders(row) == 42
  })
}

// A 40-column pane has a 38-column transcript. The indent and the frame take
// 7, leaving 31 columns, and a 1200 by 700 image fitted there is 31 columns
// by 10 rows.
pub fn the_box_narrows_to_the_pane_test() {
  let #(model, _) =
    stepping.step(
      backend.Resize(40, 50),
      scene(kitty_support(), [#("image/png", image_fixture.png(1200, 700))]),
    )
  let cells = lines_of(model) |> list.filter(shows_placeholders)
  assert list.length(cells) == 10
  list.each(cells, fn(row) {
    assert placeholders(row) == 31
  })
}

pub fn an_iterm2_terminal_draws_a_box_of_blank_cells_test() {
  let #(model, _) =
    stepping.step(
      backend.Resize(120, 40),
      scene(iterm_support(), [#("image/png", image_fixture.png(1200, 700))]),
    )
  let lines = lines_of(model)
  assert list.any(lines, string.contains(_, "╭─ image 1 · image/png"))
  assert !list.any(lines, shows_placeholders)
    as "iTerm2 cannot draw placeholder cells, so none are written"
  let blanks = list.filter(lines, string.contains(_, image_box.blank))
  assert list.length(blanks) == 12
}

pub fn a_terminal_that_did_not_answer_keeps_the_placeholder_row_test() {
  list.each(
    [
      image_support.NotProbed,
      image_support.PlainPalette,
      image_support.InsideHerdr,
      image_support.ColourDisabled,
      image_support.NotAnswered,
    ],
    fn(why) {
      let #(model, effects) =
        stepping.step(
          backend.Resize(120, 40),
          scene(image_support.TextOnly(why), [
            #("image/png", image_fixture.png(1200, 700)),
          ]),
        )
      let lines = lines_of(model)
      assert list.any(lines, string.contains(
        _,
        "▣ image 1 · image/png · 1200×700",
      ))
      assert !list.any(lines, string.contains(_, "╭─ image 1"))
      assert image_commands(effects) == []
        as "a terminal that draws nothing is told nothing"
    },
  )
}

pub fn a_png_only_terminal_says_so_about_a_jpeg_test() {
  let #(model, effects) =
    stepping.step(
      backend.Resize(120, 40),
      scene(kitty_support(), [#("image/jpeg", image_fixture.jpeg(640, 480))]),
    )
  let lines = lines_of(model)
  assert list.any(lines, string.contains(_, "▣ image 1 · image/jpeg · 640×480"))
  assert list.any(lines, string.contains(
    _,
    "this terminal draws PNG images only",
  ))
  assert image_commands(effects) == []

  // iTerm2 decodes a JPEG itself, so the same image earns a box there.
  let #(model, _) =
    stepping.step(
      backend.Resize(120, 40),
      scene(iterm_support(), [#("image/jpeg", image_fixture.jpeg(640, 480))]),
    )
  assert list.any(lines_of(model), string.contains(_, "╭─ image 1 · image/jpeg"))
}

pub fn an_image_over_the_budget_keeps_its_row_and_says_why_test() {
  let heavy = image_fixture.heavy(1200, 700, image_box.max_bytes + 4096)
  let #(model, effects) =
    stepping.step(
      backend.Resize(120, 40),
      scene(kitty_support(), [#("image/png", heavy)]),
    )
  let lines = lines_of(model)
  assert list.any(lines, string.contains(_, "▣ image 1 · image/png · 1200×700"))
  assert list.any(lines, string.contains(_, "too large to draw in the terminal"))
  assert list.any(lines, string.contains(_, "limit 4.0 MB"))
  assert image_commands(effects) == []
    as "an image over the budget is never sent"
}

// ----------------------------------------------------------- recolouring

// A cell coloured like a theme role is remapped by the light palette, and a
// placeholder cell coloured the same is not: its colour is its address.
pub fn the_light_palette_leaves_placeholder_cells_alone_test() {
  let assert Ok(id) = kitty.image_id(0x203B3C)
  let theme_like =
    style.new(style.Rgb(0x20, 0x3B, 0x3C), style.Default, style.none())
  let area = geometry.rect_new(0, 0, 4, 1)
  let source =
    buffer.buffer_new(area)
    |> buffer.set_string(geometry.Position(0, 0), "ab", theme_like)
    |> buffer.set_string(
      geometry.Position(2, 0),
      kitty.cell_symbol(id, 0, 0),
      kitty.id_style(id),
    )
  let painted = appearance.apply(source, appearance.Light)
  assert buffer.get_cell(painted, geometry.Position(2, 0))
    == buffer.get_cell(source, geometry.Position(2, 0))
    as "a placeholder keeps its exact colour"

  // The same palette does remap an ordinary cell of a theme colour.
  let ordinary =
    buffer.buffer_new(area)
    |> buffer.set_string(
      geometry.Position(0, 0),
      "a",
      style.new(style.Rgb(231, 237, 245), style.Default, style.none()),
    )
  assert buffer.get_cell(
      appearance.apply(ordinary, appearance.Light),
      geometry.Position(0, 0),
    ).style.fg
    == style.Rgb(32, 43, 60)
}

pub fn a_frame_in_a_light_palette_keeps_every_placeholder_colour_test() {
  let data = image_fixture.png(1200, 700)
  let #(model, _) =
    stepping.step(
      backend.Resize(120, 40),
      Model(
        ..scene(kitty_support(), [#("image/png", data)]),
        view: View(
          ..scene(kitty_support(), [#("image/png", data)]).view,
          palette: appearance.Light,
        ),
      ),
    )
  let painted = frame_of(model)
  let id = id_of(data)
  let area = buffer.area(painted)
  let marked =
    int.range(from: 0, to: area.size.height, with: [], run: fn(rows, y) {
      int.range(from: 0, to: area.size.width, with: rows, run: fn(cells, x) {
        [buffer.get_cell(painted, geometry.Position(x, y)), ..cells]
      })
    })
    |> list.filter(fn(cell) {
      case cell.content {
        buffer.Content(symbol:, ..) ->
          string.starts_with(symbol, kitty.placeholder)
        buffer.Continuation -> False
      }
    })
  assert list.length(marked) == 42 * 12
  list.each(marked, fn(cell) {
    assert cell.style.fg == kitty.id_style(id).fg
      as "every placeholder keeps the id as its colour"
  })
}

// -------------------------------------------------------- kitty commands

fn chat_with_scrollback() -> Model {
  let lines =
    numbers(80)
    |> list.map(fn(n) { "A line of the answer number " <> int.to_string(n) })
    |> string.join("\n\n")
  frame_scene.attach(
    with_support(frame_scene.model(), kitty_support()),
    "fix readme badge",
    [
      frame_scene.user(1, "Look at the chart."),
      frame_scene.assistant(2, "", [
        frame_scene.call("r1", "fs_read", [
          #("path", json.String("plots/latency.png")),
        ]),
      ]),
      frame_scene.result_images(3, "r1", "fs_read", [
        #("image/png", image_fixture.chart()),
      ]),
      frame_scene.assistant(4, lines, []),
    ],
  )
}

pub fn nothing_is_sent_before_the_alternate_screen_is_open_test() {
  let model = scene(kitty_support(), [#("image/png", image_fixture.chart())])

  // Every event before the first resize leaves the terminal alone, however
  // much of an image the rows hold.
  let #(ticked, effects) = stepping.step(backend.Tick, model)
  assert image_commands(effects) == []
  assert ticked.view.images.screen == image_shown.BeforeScreen
  let #(typed, effects) = stepping.step(backend.KeyPress("x"), ticked)
  assert image_commands(effects) == []
  assert typed.view.images.screen == image_shown.BeforeScreen

  // The resize is what the backend sends once it has entered the alternate
  // screen, and the first image command follows it, not precedes it.
  let #(opened, effects) = stepping.step(backend.Resize(120, 50), typed)
  assert opened.view.images.screen == image_shown.OnScreen
  let assert [image_shown.Upload(id, png, box)] = image_commands(effects)
  assert id == id_of(image_fixture.chart())
  assert box == graphics.Box(columns: 42, rows: 12)
  assert case png {
    <<0x89, 0x50, 0x4E, 0x47, _:bits>> -> True
    _ -> False
  }
    as "the terminal is sent the PNG file"
}

pub fn a_kitty_image_is_uploaded_once_and_deleted_when_it_leaves_view_test() {
  let model = chat_with_scrollback()
  let #(tail, effects) = stepping.step(backend.Resize(120, 40), model)
  assert image_commands(effects) == []
    as "an image that is out of view is not sent"

  // Scrolling back brings it into view: one upload, and nothing more while
  // it stays there.
  let #(seen, uploaded) = scroll(tail, True, fn(commands) { commands != [] })
  let assert [image_shown.Upload(id, ..)] = uploaded
  assert id == id_of(image_fixture.chart())
  let #(still, effects) = stepping.step(backend.Tick, seen)
  assert image_commands(effects) == []
  assert still.view.images.uploaded != []

  // Scrolling forward again takes it out of view: it is deleted.
  let #(_, removed) = scroll(still, False, fn(commands) { commands != [] })
  assert removed == [image_shown.Remove(id)]
}

pub fn a_resize_that_changes_the_box_places_the_image_again_test() {
  let model = scene(kitty_support(), [#("image/png", image_fixture.chart())])
  let #(wide, effects) = stepping.step(backend.Resize(120, 50), model)
  let assert [image_shown.Upload(id, _, wide_box)] = image_commands(effects)
  let #(narrow, effects) = stepping.step(backend.Resize(40, 50), wide)
  assert image_commands(effects)
    == [image_shown.Place(id, graphics.Box(columns: 31, rows: 10))]
    as "the image is placed again at the new size, not sent again"
  assert wide_box != graphics.Box(columns: 31, rows: 10)
  let #(_, effects) = stepping.step(backend.Tick, narrow)
  assert image_commands(effects) == []
}

// Scrolls one notch at a time until the image commands match, and gives
// back the model and the commands of the step that matched.
fn scroll(
  model: Model,
  up: Bool,
  matches: fn(List(image_shown.Command)) -> Bool,
) -> #(Model, List(image_shown.Command)) {
  scroll_from(model, up, matches, 200)
}

fn scroll_from(
  model: Model,
  up: Bool,
  matches: fn(List(image_shown.Command)) -> Bool,
  budget: Int,
) -> #(Model, List(image_shown.Command)) {
  let #(next, effects) = stepping.step(backend.MouseScroll(5, 5, up), model)
  case matches(image_commands(effects)), budget {
    True, _ -> #(next, image_commands(effects))
    False, 0 -> #(next, image_commands(effects))
    False, _ -> scroll_from(next, up, matches, budget - 1)
  }
}

// --------------------------------------------------------- iTerm2 commands

// The position the frame has the first blank cell of the box at.
fn first_blank(model: Model) -> Option(geometry.Position) {
  let painted = frame_of(model)
  let area = buffer.area(painted)
  int.range(from: 0, to: area.size.height, with: [], run: fn(rows, y) {
    int.range(from: 0, to: area.size.width, with: rows, run: fn(cells, x) {
      [geometry.Position(x, y), ..cells]
    })
  })
  |> list.reverse
  |> list.find(fn(at) {
    case buffer.get_cell(painted, at).content {
      buffer.Content(symbol:, ..) -> symbol == image_box.blank
      buffer.Continuation -> False
    }
  })
  |> option.from_result
}

pub fn an_iterm2_picture_is_owed_until_the_frame_has_been_drawn_test() {
  let model = scene(iterm_support(), [#("image/png", image_fixture.chart())])

  // The step that lays the box out only owes the picture, and asks to be
  // woken: its commands are written before this step's frame is drawn, and
  // anything written before the frame is overwritten by it.
  let #(laid, effects) = stepping.step(backend.Resize(120, 50), model)
  assert image_commands(effects) == []
    as "nothing is drawn before the frame that lays the box out"
  assert woke(effects)
  assert laid.view.images.owed != []

  // The next step runs after that frame, and draws, at the frame's own
  // first blank cell.
  let #(drawn, effects) = stepping.step(backend.Tick, laid)
  let assert [image_shown.Draw(at, bytes, box)] = image_commands(effects)
  assert Some(at) == first_blank(drawn)
    as "the picture lands where the frame put the box"
  assert box == graphics.Box(columns: 42, rows: 12)
  assert bytes != <<>>
  assert !woke(effects)

  // Then it stays: no further commands while the box stands still.
  let #(_, effects) = stepping.step(backend.Tick, drawn)
  assert image_commands(effects) == []
  assert !woke(effects)
}

pub fn an_iterm2_picture_is_drawn_again_after_a_resize_test() {
  let model = scene(iterm_support(), [#("image/png", image_fixture.chart())])
  let #(laid, _) = stepping.step(backend.Resize(120, 50), model)
  let #(drawn, _) = stepping.step(backend.Tick, laid)
  assert drawn.view.images.drawn != []

  // The resize repaints every cell, which erases the picture, so nothing is
  // erased by hand and the picture is owed again.
  let #(resized, effects) = stepping.step(backend.Resize(100, 40), drawn)
  assert image_commands(effects) == []
  assert woke(effects)
  assert resized.view.images.drawn == []
  let #(_, effects) = stepping.step(backend.Tick, resized)
  let assert [image_shown.Draw(..)] = image_commands(effects)
}

pub fn an_iterm2_picture_is_erased_when_its_box_moves_away_test() {
  let lines =
    numbers(80)
    |> list.map(fn(n) { "A line of the answer number " <> int.to_string(n) })
    |> string.join("\n\n")
  let model =
    frame_scene.attach(
      with_support(frame_scene.model(), iterm_support()),
      "fix readme badge",
      [
        frame_scene.user(1, "Look at the chart."),
        frame_scene.assistant(2, "", [
          frame_scene.call("r1", "fs_read", [
            #("path", json.String("plots/latency.png")),
          ]),
        ]),
        frame_scene.result_images(3, "r1", "fs_read", [
          #("image/png", image_fixture.chart()),
        ]),
        frame_scene.assistant(4, lines, []),
      ],
    )
  let #(tail, _) = stepping.step(backend.Resize(120, 40), model)

  // Bring the whole box into view and let it be drawn.
  let #(seen, _) = scroll_until_owed(tail, 400)
  let #(drawn, effects) = stepping.step(backend.Tick, seen)
  let assert [image_shown.Draw(at, _, box)] = image_commands(effects)

  // One notch more moves the box, so the old place is blanked at once and
  // the new one is owed for after the frame.
  let #(_, effects) = stepping.step(backend.MouseScroll(5, 5, True), drawn)
  let commands = image_commands(effects)
  assert list.contains(commands, image_shown.Erase(at, box))
  assert !list.any(commands, fn(command) {
    case command {
      image_shown.Draw(..) -> True
      _ -> False
    }
  })
}

// One notch at a time, with the tick the loop would interleave, until a box
// is owed. A scroll gesture can leave the frame to the next tick, and a
// picture is only owed for a frame that has been built.
fn scroll_until_owed(model: Model, budget: Int) -> #(Model, Int) {
  let #(scrolled, _) = stepping.step(backend.MouseScroll(5, 5, True), model)
  let #(next, _) = stepping.step(backend.Tick, scrolled)
  case next.view.images.owed, budget {
    [_, ..], _ -> #(next, budget)
    [], 0 -> #(next, 0)
    [], _ -> scroll_until_owed(next, budget - 1)
  }
}

// ------------------------------------------------------------ the error paths

pub fn an_image_that_will_not_decode_is_reported_once_test() {
  let model =
    scene(kitty_support(), [#("image/png", image_fixture.corrupt(640, 480))])
  let #(model, effects) = stepping.step(backend.Resize(120, 40), model)
  assert image_commands(effects) == []
  assert string.contains(
    model.shared.notice,
    "could not draw an image: its data is not valid base64",
  )

  // It is not tried again on the next tick or the next frame.
  let quiet = Model(..model, shared: shared_set.notice(model.shared, ""))
  let #(after, effects) = stepping.step(backend.Tick, quiet)
  assert image_commands(effects) == []
  assert after.shared.notice == ""
}

pub fn bytes_that_are_not_a_png_are_refused_before_they_are_sent_test() {
  // A header that reads, and whole base64, but a body that makes the file
  // something other than what it claims: here its signature is wrong.
  let wrong = "/9j/4AAQSkZJRgABAQEASABIAAD/wAARCAHgAoADASIAAhEBAxEB"
  let outcome =
    image_shown.reconcile(
      image_shown.opened(image_shown.new()),
      image_shown.Facts(
        support: kitty_support(),
        width: 120,
        height: 40,
        wants: [
          image_shown.Want(
            id: id_of(wrong),
            at: geometry.Position(0, 0),
            extent: image_box.Whole,
          ),
        ],
        picture: fn(_) { Ok(png_picture()) },
        bytes: fn(_) { image_shown.decode(wrong) },
        showing: fn(_, _) { image_shown.Intact },
      ),
    )
  assert outcome.commands == []
  assert list.map(outcome.failures, fn(failure) { failure.1 })
    == [image_shown.NotPng]
}

fn png_picture() -> image_header.Picture {
  let assert Some(picture) =
    image_header.picture("image/png", image_fixture.png(480, 280))
  picture
}

// -------------------------------------------------------- the pure pieces

pub fn a_probe_timeout_is_text_only_test() {
  let support =
    image_support.detect(appearance.Dark, fn(_) { Error(Nil) }, fn(_) {
      graphics.none()
    })
  assert support == image_support.TextOnly(image_support.NotAnswered)
}

pub fn a_plain_palette_or_herdr_is_not_probed_test() {
  let refuse = fn(_) { panic as "the probe must not be sent" }
  let none = fn(_) { Error(Nil) }
  assert image_support.detect(appearance.Plain, none, refuse)
    == image_support.TextOnly(image_support.PlainPalette)
  assert image_support.detect(
      appearance.Dark,
      fn(name) {
        case name {
          "HERDR_ENV" -> Ok("1")
          _ -> Error(Nil)
        }
      },
      refuse,
    )
    == image_support.TextOnly(image_support.InsideHerdr)
  assert image_support.detect(
      appearance.Dark,
      fn(name) {
        case name {
          "NO_COLOR" -> Ok("1")
          _ -> Error(Nil)
        }
      },
      refuse,
    )
    == image_support.TextOnly(image_support.ColourDisabled)
}

pub fn the_probe_is_asked_for_its_deadline_and_believed_when_positive_test() {
  let asked = fn(timeout) {
    assert timeout == image_support.probe_timeout_ms
    graphics.Capabilities(
      kitty: graphics.Supported,
      iterm2: graphics.Unsupported,
      cell_size: Some(graphics.CellSize(9, 18)),
      terminal: Some("ghostty 1.2"),
    )
  }
  assert image_support.detect(appearance.Dark, fn(_) { Error(Nil) }, asked)
    == image_support.KittyPlaceholders(graphics.CellSize(9, 18))
  assert image_support.from_capabilities(graphics.Capabilities(
      kitty: graphics.Unsupported,
      iterm2: graphics.Supported,
      cell_size: None,
      terminal: Some("iTerm2 3.5"),
    ))
    == image_support.Iterm2Inline(image_support.guessed_cell)
}

pub fn an_id_is_stable_in_range_and_spread_test() {
  let first = image_box.id_of("1024:a:b:c")
  assert first == image_box.id_of("1024:a:b:c")
  let ids =
    numbers(200)
    |> list.map(fn(n) { image_box.id_of(int.to_string(n) <> ":x:y:z") })
  list.each(ids, fn(id) {
    assert id >= 1 && id <= 0xFFFFFF
  })
  assert list.length(list.unique(ids)) == 200
    as "two hundred different fingerprints are two hundred different ids"
}

pub fn found_tells_a_whole_box_from_a_clipped_one_test() {
  let data = image_fixture.png(1200, 700)
  let #(model, _) =
    stepping.step(
      backend.Resize(120, 50),
      scene(kitty_support(), [#("image/png", data)]),
    )
  let area = render.transcript_area(model, geometry.rect_new(0, 0, 120, 50))
  let window = render.transcript_window(model, area)
  let assert [whole] = image_box.found(window)
  assert whole.id == id_of(data)
  assert whole.cells == image_box.Placeholders
  assert whole.rows == 12
  assert whole.extent == image_box.Whole

  // Cut the window through the box and it is clipped, with fewer rows.
  let cut = list.drop(window, whole.row + 3)
  let assert [clipped] = image_box.found(cut)
  assert clipped.extent == image_box.Clipped
  assert clipped.rows == 9
}

pub fn commands_become_the_protocols_bytes_test() {
  let id = id_of(image_fixture.chart())
  let box = graphics.Box(columns: 42, rows: 12)
  let upload = image_shown.sequence([image_shown.Upload(id, <<1, 2, 3>>, box)])
  assert string.starts_with(upload, "\u{001B}_Ga=t,f=100,t=d,i=")
  assert string.contains(upload, "a=p")
  assert image_shown.sequence([image_shown.Remove(id)]) == kitty.delete(id)
  let at = geometry.Position(3, 4)
  assert string.contains(
    image_shown.sequence([image_shown.Draw(at, <<1, 2, 3>>, box)]),
    "]1337;File=inline=1",
  )
  assert string.contains(
    image_shown.sequence([image_shown.Erase(at, box)]),
    "[0m",
  )
  assert image_shown.sequence([]) == ""
}

// ------------------------------------------------------------ a review file

// Writes the raw bytes a terminal that draws images reads for one frame: the
// image uploaded, then the frame with its placeholder cells. `cat` the file
// in Ghostty or kitty to see the picture. It is written only when the
// variable names a path, so the suite leaves nothing behind.
pub fn the_inline_frame_can_be_written_for_a_terminal_test() {
  let data = image_fixture.chart()
  let #(model, effects) =
    stepping.step(
      backend.Resize(110, 36),
      scene(kitty_support(), [#("image/png", data)]),
    )
  let ansi = inline_frame_ansi(model, image_commands(effects))
  assert string.contains(ansi, "\u{001B}_Ga=t,f=100")
  assert string.contains(ansi, "\u{001B}_G")
  assert string.contains(ansi, "image 1 · image/png · 480×280")
  case host_bootstrap.getenv("LOOM_IMAGE_ANSI") {
    Ok(path) -> {
      let assert Ok(Nil) = simplifile.write(path, ansi)
        as "the review file is written"
      Nil
    }
    Error(Nil) -> Nil
  }
}

// The bytes of a frame as a terminal receives them: the screen cleared, the
// image commands, then each row of the frame at its own position.
fn inline_frame_ansi(
  model: Model,
  commands: List(image_shown.Command),
) -> String {
  let rows = buffer.to_ansi_lines(frame_of(model))
  "\u{001B}[2J\u{001B}[H"
  <> image_shown.sequence(commands)
  <> string.join(rows, "\r\n")
  <> "\u{001B}[0m\r\n"
}

// ------------------------------------------------- review findings

// A pasted line indented with no-break spaces is text, not a box. With no
// image anywhere in the transcript, nothing is drawn, owed or reported, at
// any pane width.
pub fn indented_text_is_not_mistaken_for_a_box_test() {
  let model =
    frame_scene.attach(
      with_support(frame_scene.model(), iterm_support()),
      "fix readme badge",
      [
        frame_scene.user(
          1,
          "\u{00A0}\u{00A0}\u{00A0}\u{00A0}indented by no-break spaces\n\u{00A0}\u{00A0}\u{00A0}\u{00A0}and again",
        ),
        frame_scene.assistant(2, "Noted.", []),
      ],
    )
  list.each([120, 100, 80, 60], fn(width) {
    let #(laid, effects) = stepping.step(backend.Resize(width, 40), model)
    assert image_commands(effects) == []
    assert !woke(effects)
    assert laid.view.images.owed == []
    assert !string.contains(laid.shared.notice, "could not draw")
      as "there is no image to fail to draw"
    let #(next, effects) = stepping.step(backend.Tick, laid)
    assert image_commands(effects) == []
    assert !string.contains(next.shared.notice, "could not draw")
  })
}

// On a short pane the picture takes about half the transcript, so the text
// around it is still on screen: 80 by 24 leaves 19 transcript rows, and the
// picture gets 9 of them.
pub fn a_short_pane_gives_the_picture_half_its_rows_test() {
  let #(model, _) =
    stepping.step(
      backend.Resize(80, 24),
      scene(kitty_support(), [#("image/png", image_fixture.png(1200, 700))]),
    )
  assert layout.transcript_viewport_height(model) == 19
  assert image_box.picture_rows(24) == 9
  let cells = lines_of(model) |> list.filter(shows_placeholders)
  assert list.length(cells) == 9

  // A taller pane gets the full twelve, and the cache follows the height.
  let #(tall, _) = stepping.step(backend.Resize(80, 50), model)
  assert list.length(lines_of(tall) |> list.filter(shows_placeholders)) == 12
  let #(short, _) = stepping.step(backend.Resize(80, 24), tall)
  assert list.length(lines_of(short) |> list.filter(shows_placeholders)) == 9
}

// A small or tall picture is centred in its frame rather than seated at the
// left: a 64 by 64 image is 8 columns wide in a frame as wide as its label.
pub fn a_small_picture_is_centred_in_its_frame_test() {
  let #(model, _) =
    stepping.step(
      backend.Resize(120, 40),
      scene(kitty_support(), [#("image/png", image_fixture.png(64, 64))]),
    )
  let screen = geometry.rect_new(0, 0, 120, 40)
  let window =
    render.transcript_window(model, render.transcript_area(model, screen))
  let assert [found] = image_box.found(window)
  let frame_left = 3

  // The frame is as wide as its label, 38 columns here, and the picture is 8
  // of the 34 inside it: 13 columns of padding on each side.
  let lines = lines_of(model)
  let assert Ok(top) = list.find(lines, string.contains(_, "╭─ image 1"))
  let frame_width = string.length(string.trim_start(top))
  assert found.column - { frame_left + 2 } == { frame_width - 4 - 8 } / 2
}

// Two images in one result are two boxes with their own ids, both sent, and
// one blank row between them.
pub fn two_images_in_one_result_are_two_boxes_test() {
  let first = image_fixture.png_seeded(480, 280, "first")
  let second = image_fixture.png_seeded(480, 280, "second")
  let #(model, effects) =
    stepping.step(
      backend.Resize(120, 60),
      scene(kitty_support(), [#("image/png", first), #("image/png", second)]),
    )
  let assert [image_shown.Upload(a, ..), image_shown.Upload(b, ..)] =
    image_commands(effects)
  assert a != b
  assert [a, b] == [id_of(first), id_of(second)]
    || [a, b] == [id_of(second), id_of(first)]
  let lines = lines_of(model)
  let assert Ok(foot) =
    list.index_map(lines, fn(row, at) { #(at, row) })
    |> list.find(fn(entry) { string.contains(entry.1, "╰─ o opens externally") })
  let below = list.drop(lines, foot.0 + 1)
  assert list.first(below) == Ok("") as "a blank row follows the first box"
  assert string.contains(
    list.drop(below, 1) |> list.first |> result.unwrap(""),
    "╭─ image 2",
  )
    as "and the second box follows it"
}

// A surface drawn over the transcript keeps an iTerm2 picture off it: a
// picture that is owed is dropped, and one that was drawn is erased.
pub fn a_surface_over_the_box_keeps_the_picture_off_it_test() {
  let model = scene(iterm_support(), [#("image/png", image_fixture.chart())])
  let #(laid, _) = stepping.step(backend.Resize(120, 50), model)
  let covered = fn(shown: Model) {
    tui_model.invalidate_frame(
      Model(
        ..shown,
        view: view_set.summary_surface(shown.view, queue_editor.Inspector),
      ),
    )
  }

  // Owed, then covered: the late draw never happens.
  let #(after, effects) = stepping.step(backend.Tick, covered(laid))
  assert image_commands(effects) == []
  assert after.view.images.owed == []
  assert after.view.images.drawn == []

  // Drawn, then covered: the picture is erased where it was.
  let #(drawn, effects) = stepping.step(backend.Tick, laid)
  let assert [image_shown.Draw(at, _, box)] = image_commands(effects)
  let #(_, effects) = stepping.step(backend.Tick, covered(drawn))
  assert image_commands(effects) == [image_shown.Erase(at, box)]
}

// Switching strands replaces the rows, and the images of the strand left
// are deleted from the terminal.
pub fn a_strand_switch_removes_the_uploads_test() {
  let model = scene(kitty_support(), [#("image/png", image_fixture.chart())])
  let #(shown, effects) = stepping.step(backend.Resize(120, 50), model)
  let assert [image_shown.Upload(id, ..)] = image_commands(effects)
  // The switch is the reducer's own, so the next step sees the strand change
  // and rebuilds the rows.
  let elsewhere = submit.switch_active_strand(shown, "sub:docs")
  assert elsewhere.shared.active_strand == "sub:docs"
  let #(_, effects) = stepping.step(backend.Tick, elsewhere)
  assert image_commands(effects) == [image_shown.Remove(id)]
}

// The step that sets quit deletes every image the terminal holds, while the
// alternate screen is still open.
pub fn quitting_deletes_the_uploaded_images_test() {
  let model = scene(kitty_support(), [#("image/png", image_fixture.chart())])
  let #(shown, effects) = stepping.step(backend.Resize(120, 50), model)
  let assert [image_shown.Upload(id, ..)] = image_commands(effects)
  let leaving = Model(..shown, shared: shared_set.quit(shown.shared, True))
  let #(left, effects) = stepping.step(backend.Tick, leaving)
  assert image_commands(effects) == [image_shown.Remove(id)]
  assert left.view.images.uploaded == []
  let #(_, effects) = stepping.step(backend.Tick, left)
  assert image_commands(effects) == []
}

// The `--demo` scene carries one image, so the box can be seen end to end.
pub fn the_demo_scene_shows_a_box_test() {
  let model =
    demo_image.seed(with_support(frame_scene.model(), kitty_support()))
  let #(model, effects) = stepping.step(backend.Resize(120, 40), model)
  let lines = lines_of(model)
  assert list.any(lines, string.contains(_, "╭─ image 1 · image/png · 480×280"))
  assert list.any(lines, string.contains(_, "fs_read"))
  let assert [image_shown.Upload(..)] = image_commands(effects)
}

// Typing a prompt long enough to wrap makes the composer taller and the
// transcript shorter, but the picture's size follows the terminal's height,
// so the row cache stays and no image is placed again.
pub fn typing_a_wrapping_prompt_leaves_the_picture_alone_test() {
  let #(start, effects) =
    stepping.step(
      backend.Resize(80, 24),
      scene(kitty_support(), [#("image/png", image_fixture.chart())]),
    )
  let assert [image_shown.Upload(..)] = image_commands(effects)
  let before = layout.transcript_viewport_height(start)
  let rows = start.view.caches.record_rows
  let typed =
    string.repeat("a wrapping word ", 12)
    |> string.to_graphemes
    |> list.fold(start, fn(model, character) {
      let #(next, effects) = stepping.step(backend.KeyPress(character), model)
      assert image_commands(effects) == []
        as "no key places or sends an image again"
      next
    })
  assert layout.transcript_viewport_height(typed) < before
    as "the composer wrapped and took rows from the transcript"
  assert typed.view.caches.record_rows == rows
    as "the record rows were kept, not rebuilt"
  assert list.length(lines_of(typed) |> list.filter(shows_placeholders)) == 9
}
