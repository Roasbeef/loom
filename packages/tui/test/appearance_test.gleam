//// Palette adaptation changes only color. Terminal content, links and wide
//// cells retain the identity used by selection and diff rendering.

import etui/buffer
import etui/geometry
import etui/style
import gleam/list
import gleam/option.{None, Some}
import tui/appearance
import tui/frame
import tui/theme

pub fn terminal_capabilities_select_readable_fallbacks_test() {
  assert appearance.detect("truecolor", "xterm-256color", "0;15", None)
    == appearance.Light
  assert appearance.detect("24bit", "xterm", "15;0", None) == appearance.Dark
  assert appearance.detect("", "xterm-256color", "", None)
    == appearance.Terminal
  assert appearance.detect("", "dumb", "", None) == appearance.Plain
  assert appearance.detect("truecolor", "xterm", "", Some("1"))
    == appearance.Plain
  assert appearance.detect("truecolor", "xterm", "", Some(""))
    == appearance.Dark
}

pub fn palette_conversion_preserves_wide_cells_links_and_focus_weight_test() {
  let screen = geometry.rect_new(0, 0, 12, 2)
  let original =
    buffer.buffer_new(screen)
    |> buffer.set_string_linked(
      geometry.Position(0, 0),
      "界 agent",
      style.new(theme.signal, theme.raised, style.bold()),
      "https://example.test/agent",
    )
    |> buffer.set_string(
      geometry.Position(0, 1),
      "Needs input",
      theme.overlay_quiet(),
    )
  list.each(
    [appearance.Dark, appearance.Light, appearance.Terminal, appearance.Plain],
    fn(palette) {
      let mapped = appearance.apply(original, palette)
      assert frame.buffer_to_text(mapped) == frame.buffer_to_text(original)
      list.each(
        list.index_map(list.repeat(Nil, 24), fn(_, index) { index }),
        fn(index) {
          let position = geometry.Position(index % 12, index / 12)
          let before = buffer.get_cell(original, position)
          let after = buffer.get_cell(mapped, position)
          assert after.content == before.content
          assert after.link == before.link
          assert after.style.modifier == before.style.modifier
          case palette {
            appearance.Plain -> {
              assert after.style.fg == style.Default
              assert after.style.bg == style.Default
            }
            appearance.Terminal -> {
              assert after.style.bg == style.Default
              let assert False = case after.style.fg {
                style.Rgb(..) -> True
                style.Default | style.Indexed(_) -> False
              }
                as "a reduced-color terminal never receives RGB foregrounds"
              Nil
            }
            appearance.Dark | appearance.Light -> Nil
          }
        },
      )
    },
  )
}
