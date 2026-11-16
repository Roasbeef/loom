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
//// `delegate:<spawner>:<parent session>:<child>` names one child's. The child of
//// the pair's own session is the empty string, so the two shapes cannot collide:
//// a child's key has a fourth field and the pair's has three. A spawner's name is a
//// word of the operator's table and a session identity and a child's name are
//// minted by this daemon, none holds a `:`, and
//// `seed_landing_model_test` states that two keys are equal only for equal parts.

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

  // The pair's own session has no child, and a child's key follows the pair's.
  case parts.child {
    "" -> base
    named -> base <> ":" <> named
  }
}
