//// How a strand's minted identity reads to a person.
////
//// A sub-agent is minted as `sub:{parent}/{slug}-{digest}`. The parent and
//// the digest keep two children of one task apart for the machine, and the
//// slug is the only part its parent chose for a reader. The agent strip, the
//// reviewer band and the strand list all want that slug, so the rule lives
//// here once and none of them writes a second copy that drifts.
////
//// The module is pure and portable: it reads one string and does no I/O.

import gleam/list
import gleam/result
import gleam/string

/// Shortens a minted child identity to the words its parent chose.
///
/// Anything not in the `sub:{parent}/{slug}-{digest}` shape is returned
/// whole, so `main` and `advisor` read as they are.
///
/// ## Examples
///
/// ```gleam
/// assert strand_name.short("sub:main/audit-panics-1a2b3c") == "audit-panics"
/// assert strand_name.short("main") == "main"
/// ```
pub fn short(name: String) -> String {
  case string.starts_with(name, "sub:") {
    False -> name
    True -> {
      let leaf =
        string.split(name, "/")
        |> list.last
        |> result.unwrap(name)
      case string.split(leaf, "-") |> list.reverse {
        [digest, first, ..rest] ->
          case is_digest(digest) {
            True -> [first, ..rest] |> list.reverse |> string.join("-")
            False -> leaf
          }
        [_] | [] -> leaf
      }
    }
  }
}

// A trailing run of hex digits long enough to be a minted digest and not a
// word the parent chose, such as `fix`.
fn is_digest(value: String) -> Bool {
  string.drop_start(value, 3) != ""
  && string.to_graphemes(value)
  |> list.all(fn(char) { string.contains("0123456789abcdef", char) })
}
