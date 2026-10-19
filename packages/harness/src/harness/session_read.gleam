//// Two reads of a session's durable registers which request routing needs
//// and which depend on nothing else: the strand an operation belongs to, and
//// the model identity a strand captured.
////
//// Both are deliberately forgiving. A hook decides from durable state, and a
//// store which will not answer must not halt a conversation, so every failure
//// to read collapses into "unknown" and the caller falls back to the figures
//// it was configured with. `client/notes.strand_of` delegates here, so the
//// daemon and an embedder resolve a strand the same way.

import core/ids.{type OpId}
import gleam/option.{type Option, None, Some}
import machine/strand.{type ModelIdentity}
import session/session.{type Session}

/// The strand an operation belongs to, from its durable `op.meta` cell.
///
/// `Error(Nil)` is both "no metadata yet" and "the store would not answer": a
/// run is never held up for a digest or an admission over a read it cannot
/// make.
///
/// ## Examples
///
/// ```gleam
/// // session_read.strand_of(session, operation) == Ok("main")
/// ```
///
pub fn strand_of(session: Session, operation: OpId) -> Result(String, Nil) {
  case session.op_meta(session, operation) {
    Ok(Some(session.Cell(value: meta, ..))) -> Ok(meta.strand)

    // No metadata, or a store that would not answer.
    Ok(None) -> Error(Nil)
    Error(_unreadable) -> Error(Nil)
  }
}

/// The identity a strand's durable configuration captured, or `None` when the
/// cell is absent or the store would not answer.
///
/// ## Examples
///
/// ```gleam
/// // session_read.strand_identity(session, "main")
/// //   == option.Some(ModelIdentity(provider: "acme", model_id: "loom-1"))
/// ```
///
pub fn strand_identity(
  session: Session,
  strand: String,
) -> Option(ModelIdentity) {
  case session.strand_configuration(session, strand) {
    Ok(Some(session.Cell(value: configuration, ..))) ->
      Some(configuration.model)
    Ok(None) -> None
    Error(_unreadable) -> None
  }
}
