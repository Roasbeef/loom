//// What a request is accounted against: the window, the output ceiling, the
//// adapter api and the image reading of one model identity.
////
//// The facts come from the identity's *own* catalogue entry, so a strand
//// switched off the configured route is admitted, compacted and captured
//// against what it will actually be dispatched to. An identity the host does
//// not know falls back to figures the host declared up front, which is what
//// keeps a session with a moved route running rather than admitting requests
//// against numbers nobody stands behind.
////
//// The seam is a function (`Lookup`) rather than a table because the daemon
//// builds it over a catalogue it does not own the shape of, and an embedder
//// may build it over nothing at all (`no_facts`).
////
//// ## Flow
////
//// `of_identity` answers for an identity; `of_strand` reads the strand's
//// captured identity first and falls back when it cannot; `strand_window` is
//// the window alone, for hosts which need it before their configuration
//// exists. `no_facts` is the lookup of a host with a single model.

import gleam/option.{None, Some}
import harness/session_read
import machine/strand.{type ModelIdentity}
import provider/model.{type ResolvedModel}
import session/session.{type Session}

/// Whether a model can read an image in its input.
pub type ImageReading {
  /// The model accepts image blocks. The answer for an identity nobody
  /// declared anything about, because routing consults only the blind
  /// declarations a host actually made.
  ReadsImages

  /// The model reads text only. A request carrying an image either routes
  /// through the vision chain or has the image replaced by a placeholder.
  TextOnly
}

/// One identity's own facts, as its catalogue entry declares them.
pub type Known {
  Known(
    /// The resolved model: its window, ceiling and thinking default.
    resolved: ResolvedModel,
    /// The adapter api its dialect speaks. Captured durably into every
    /// generation intent, where deferred-handle validity compares against it,
    /// so it must name the api actually dispatched to.
    api: String,
    /// Whether the model can read images.
    reading: ImageReading,
  )
}

/// The lookup seam: an identity's own facts, or `Error(Nil)` for one the host
/// does not know.
pub type Lookup =
  fn(ModelIdentity) -> Result(Known, Nil)

/// The figures used for an identity the lookup does not know.
///
/// Constructor invariants: `context_window` and `max_output_tokens` are
/// positive token counts. `harness.new` checks them; the daemon's `Config`
/// has always documented them as positive and does not.
pub type Fallback {
  Fallback(
    /// The adapter api to capture for an unknown identity.
    api: String,
    /// The context window to account an unknown identity against.
    context_window: Int,
    /// The output ceiling to account an unknown identity against.
    max_output_tokens: Int,
  )
}

/// The facts one request is accounted against, after the fallback is applied.
pub type ModelFacts {
  ModelFacts(
    /// The adapter api the request will be dispatched through.
    api: String,
    /// The window the request is measured against.
    context_window: Int,
    /// The output ceiling the request is admitted with.
    max_output_tokens: Int,
    /// Whether the model reads images.
    reading: ImageReading,
  )
}

/// A lookup which knows no identity, so every request is accounted against
/// the fallback. The default for an embedder with a single configured model.
///
/// ## Examples
///
/// ```gleam
/// // model_facts.no_facts()(identity) == Error(Nil)
/// ```
///
pub fn no_facts() -> Lookup {
  fn(_identity) { Error(Nil) }
}

/// The facts for one identity: its own entry when the lookup knows it, the
/// fallback figures (and an image-reading default) otherwise.
///
/// ## Examples
///
/// ```gleam
/// // model_facts.of_identity(lookup, fallback, identity).context_window
/// ```
///
pub fn of_identity(
  lookup: Lookup,
  fallback: Fallback,
  identity: ModelIdentity,
) -> ModelFacts {
  case lookup(identity) {
    Ok(Known(resolved:, api:, reading:)) ->
      ModelFacts(
        api:,
        context_window: resolved.context_window,
        max_output_tokens: resolved.max_output_tokens,
        reading:,
      )
    Error(Nil) -> unknown(fallback)
  }
}

/// One strand's facts, read from its durable configuration.
///
/// A strand whose configuration is unreadable is accounted against the
/// fallback figures: a token count that cannot be taken must not halt a
/// strand.
///
/// ## Examples
///
/// ```gleam
/// // model_facts.of_strand(session, lookup, fallback, "main")
/// ```
///
pub fn of_strand(
  opened: Session,
  lookup: Lookup,
  fallback: Fallback,
  strand: String,
) -> ModelFacts {
  case session_read.strand_identity(opened, strand) {
    Some(identity) -> of_identity(lookup, fallback, identity)
    None -> unknown(fallback)
  }
}

/// The context window a strand is measured against: its captured identity's
/// own entry when the lookup knows it, `fallback` otherwise.
///
/// ## Examples
///
/// ```gleam
/// // model_facts.strand_window(session, lookup, "main", fallback: 200_000)
/// ```
///
pub fn strand_window(
  opened: Session,
  lookup: Lookup,
  strand: String,
  fallback fallback: Int,
) -> Int {
  session_read.strand_identity(opened, strand)
  |> option.then(fn(identity) { option.from_result(lookup(identity)) })
  |> option.map(fn(known) { known.resolved.context_window })
  |> option.unwrap(fallback)
}

/// Constructs default model facts using the host fallback parameters.
fn unknown(fallback: Fallback) -> ModelFacts {
  ModelFacts(
    api: fallback.api,
    context_window: fallback.context_window,
    max_output_tokens: fallback.max_output_tokens,
    reading: ReadsImages,
  )
}
