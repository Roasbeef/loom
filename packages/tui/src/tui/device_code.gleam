//// The QR code `loom ui --device` prints beside its link (protocol-change/052,
//// the addendum), so a phone's camera can open the link without the person
//// typing a ticket.
////
//// The encoding is `qrkit`'s, a pure Gleam encoder; this module only chooses
//// how the code is drawn on a terminal. It uses Unicode half blocks, two
//// module rows per text line, so a link of about a hundred characters fits
//// in some thirty lines. A terminal's own colours vary, and a camera reads a
//// code only when its dark modules are darker than its light ones, so each
//// line is drawn black on white with explicit ANSI colours rather than in
//// whatever foreground and background the terminal has. The quiet zone of
//// four light modules around the code is part of the drawing, because the
//// standard needs it for a reliable scan.

import gleam/list
import gleam/result
import gleam/string
import qrkit
import qrkit/render/ascii

/// The ANSI sequence that draws what follows black on white.
const black_on_white = "\u{1b}[30;47m"

/// The ANSI sequence that restores the terminal's own colours.
const restore = "\u{1b}[0m"

/// The QR code of `link`, as lines for a terminal, or `Error(Nil)` when the
/// encoder refuses it, which for a link a daemon minted means it is longer
/// than any QR code holds. The caller prints the link itself either way, so
/// a refusal costs only the picture.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(code) = device_code.render("https://box.example:8443/ui/home")
/// assert string.contains(code, "\u{1b}[30;47m")
/// ```
pub fn render(link: String) -> Result(String, Nil) {
  use code <- result.map(qrkit.encode(link) |> result.replace_error(Nil))
  ascii.to_string_compact(code)
  |> string.split("\n")
  |> list.map(fn(line) { black_on_white <> line <> restore })
  |> string.join("\n")
}

/// The module rows of `link`'s QR code, dark modules `True`, for a test that
/// decodes the code back to the link it was drawn from.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(rows) = device_code.rows("https://box.example")
/// assert rows != []
/// ```
@internal
pub fn rows(link: String) -> Result(List(List(Bool)), Nil) {
  qrkit.encode(link)
  |> result.map(qrkit.rows)
  |> result.replace_error(Nil)
}
