//// The key that names a delegate session
//// (protocol-change/107, slice 4b).
////
//// A spawner keeps one delegate session for each pair of a parent session and,
//// for a seeded child on an executor, one for each child of the pair. The
//// registry creates a session under a request key, and a creation retried after a
//// crash lands on the registration that key reserved. The key is therefore what
//// makes it true that at most one session exists for a (spawner, parent, child).
////
//// ## Shape
////
//// `delegate:<spawner>:<parent session>` names the pair's own session, and
//// `delegate:<spawner>:<parent session>:<child>` names one child's. No part may be
//// empty or contain `:`. The child of the pair's own session is the empty string
//// in `key`, so the two shapes cannot collide: a child's key has a fourth field
//// and the pair's has three. `parse` is the total inverse, and it refuses any
//// text that `key` could not have made, such as a child that is empty after a
//// trailing colon.

import gleam/list
import gleam/string

/// The parts of a delegate key.
pub type Key {
  Key(
    /// The spawner's name in the operator's table.
    spawner: String,
    /// The parent's session identity.
    parent: String,
    /// The child's name, or the empty string for the pair's own session.
    child: String,
  )
}

/// Why text is not a delegate key.
pub type Damage {
  /// The text does not begin with `delegate:`.
  NotDelegate

  /// The text has too few or too many fields.
  WrongFields

  /// A field that must be named is empty, including a child after a trailing
  /// colon.
  EmptyField
}

/// Whether a part can be put in a key: it is not empty and holds no `:`.
///
/// ## Examples
///
/// ```gleam
/// assert delegate_key.is_part("seed-0123456789abcdef")
/// assert !delegate_key.is_part("a:b")
/// ```
pub fn is_part(text: String) -> Bool {
  text != "" && !string.contains(text, ":")
}

/// The request key of the session of a (spawner, parent, child). The empty child
/// is the pair's own session.
///
/// ## Examples
///
/// ```gleam
/// assert delegate_key.key(delegate_key.Key("laptop", "0198", "")) == "delegate:laptop:0198"
/// assert delegate_key.key(delegate_key.Key("laptop", "0198", "seed-1")) == "delegate:laptop:0198:seed-1"
/// ```
pub fn key(parts: Key) -> String {
  let base = "delegate:" <> parts.spawner <> ":" <> parts.parent
  case parts.child {
    "" -> base
    named -> base <> ":" <> named
  }
}

/// Reads a key back into its parts, or says how it is damaged.
///
/// ## Examples
///
/// ```gleam
/// assert delegate_key.parse("delegate:laptop:0198:") == Error(delegate_key.EmptyField)
/// ```
pub fn parse(text: String) -> Result(Key, Damage) {
  case string.split(text, ":") {
    ["delegate", ..fields] -> fields_of(fields)
    _other -> Error(NotDelegate)
  }
}

// Builds the key from the fields after the prefix, refusing empty ones.
fn fields_of(fields: List(String)) -> Result(Key, Damage) {
  case list.all(fields, is_part) {
    False ->
      case fields {
        [_, _] | [_, _, _] -> Error(EmptyField)
        _other -> Error(WrongFields)
      }
    True ->
      case fields {
        [spawner, parent] -> Ok(Key(spawner:, parent:, child: ""))
        [spawner, parent, child] -> Ok(Key(spawner:, parent:, child:))
        _other -> Error(WrongFields)
      }
  }
}
