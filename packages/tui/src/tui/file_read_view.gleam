//// Human-readable projection of successful file reads.
//// Edit digests and line anchors stay in the recorded model result. Only the
//// terminal projection removes them, retaining line numbers and source text.

import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Hides recognized edit metadata without changing source text or diagnostics.
///
/// ## Examples
///
/// ```gleam
/// assert file_read_view.render("12:abcdef01|  value") == "12 │   value"
/// ```
pub fn render(text: String) -> String {
  let lines = string.split(text, "\n")
  let lines = case lines {
    [first, ..rest] -> {
      let digest = string.drop_start(first, 8)
      case string.starts_with(first, "digest: ") && valid_digest(digest) {
        True -> rest
        False -> lines
      }
    }
    [] -> []
  }
  lines
  |> list.map(fn(line) { result.unwrap(source_line(line), line) })
  |> string.join("\n")
}

// Split only the framing delimiters. Colons, pipes and whitespace after the
// anchor belong to the file and must survive exactly as recorded.
fn source_line(line: String) -> Result(String, Nil) {
  use #(number, rest) <- result.try(string.split_once(line, ":"))
  use #(anchor, source) <- result.try(string.split_once(rest, "|"))
  use index <- result.try(int.parse(number))
  use <- bool.guard(index <= 0 || !hex(anchor, 8), Error(Nil))
  Ok(number <> " │ " <> source)
}

fn valid_digest(value: String) -> Bool {
  let parsed = {
    use #(hash, bytes) <- result.try(string.split_once(value, "-"))
    use size <- result.try(int.parse(bytes))
    Ok(hex(hash, 16) && size >= 0)
  }
  result.unwrap(parsed, False)
}

fn hex(value: String, width: Int) -> Bool {
  string.length(value) == width
  && list.all(string.to_graphemes(value), fn(char) {
    string.contains("0123456789abcdef", char)
  })
}
