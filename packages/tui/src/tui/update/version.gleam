//// Automatic latest-release selection cannot silently move a versioned
//// installation backwards. An explicit tag or commit is an operator-selected
//// destination and therefore does not apply automatic version ordering.

import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string

/// Checks an automatic update against the current stable package version.
///
/// Development identities are not ordered. Other unrecognised versions require
/// an explicit release selection, rather than guessing a prerelease ordering.
///
/// ## Examples
///
/// ```gleam
/// version.allow_latest("0.2.0", "0.3.0") // Ok(Nil)
/// version.allow_latest("0.3.0", "0.2.0") // Error(..)
/// ```
pub fn allow_latest(current: String, candidate: String) -> Result(Nil, String) {
  case current {
    "" | "dev" | "unknown" -> Ok(Nil)
    current -> {
      use previous <- result.try(parts(current))
      use next <- result.try(parts(candidate))
      case compare(next, previous) {
        order.Lt ->
          Error(
            "latest release is older than this client; select an explicit tag or commit to downgrade",
          )
        order.Eq | order.Gt -> Ok(Nil)
      }
    }
  }
}

fn parts(value) {
  use numbers <- result.try(
    list.try_map(string.split(value, "."), int.parse)
    |> result.replace_error(
      "cannot order this version automatically; select an explicit tag or commit",
    ),
  )
  case numbers {
    [major, minor, patch] if major >= 0 && minor >= 0 && patch >= 0 ->
      Ok(numbers)
    _ ->
      Error(
        "cannot order this version automatically; select an explicit tag or commit",
      )
  }
}

fn compare(left, right) {
  case left, right {
    [a, ..rest_a], [b, ..rest_b] ->
      case int.compare(a, b) {
        order.Eq -> compare(rest_a, rest_b)
        different -> different
      }
    _, _ -> order.Eq
  }
}
