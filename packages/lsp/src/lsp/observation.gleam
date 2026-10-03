//// A finite language-server observation, distinct from the interactive door.
////
//// The collector records exactly the requested outlines and reference seeds.
//// SQL consumers may join these facts inside the satellite, but must not infer
//// workspace coverage or reference coverage for an unrequested outline symbol.
//// A refusal publishes no partial batch. Server-withheld locations contribute
//// a count and never become document reads.

import gleam/option.{type Option}
import lsp/query

/// The maximum explicitly requested outline files.
pub const max_outline_files = 16

/// The maximum explicitly requested reference targets.
pub const max_targets = 32

/// The maximum document, symbol, target and reference facts together.
pub const max_facts = 10_000

/// The maximum retained UTF-8 fact payload.
pub const max_fact_bytes = 4_194_304

/// The maximum semantic protocol requests, including target resolution.
pub const max_requests = 128

/// The maximum observation interval, additionally clamped by the invocation.
pub const max_duration_ms = 75_000

/// An explicitly bounded scope under one configured server and project root.
pub type Request {
  Request(
    /// The configured server name.
    server: String,
    /// The project root, resolved and checked by the collector.
    root: String,
    /// Only these files receive outline queries.
    outlines: List(String),
    /// Only these symbols receive reference queries; every seed needs a path.
    targets: List(query.SymbolQuery),
  )
}

/// The invocation's absolute deadline and its monotonic clock.
///
/// Cancellation belongs to the managed caller. Its death withdraws the
/// outstanding protocol request; a collector never starts detached fanout.
pub type Control {
  Control(
    /// The invocation's absolute deadline in the clock's milliseconds.
    deadline_ms: Int,
    /// The same clock used to admit the invocation.
    now: fn() -> Int,
  )
}

/// The file text on which a fact was converted.
pub type Document {
  Document(
    /// A canonical admitted absolute path.
    path: String,
    /// The SHA256 content address, including its algorithm prefix.
    digest: String,
    /// The actor's internal document version, absent for an unopened result file.
    version: Option(Int),
  )
}

/// One flat outline symbol. Parent identities stay inside this batch.
pub type Symbol {
  Symbol(
    /// The unique batch-local identity.
    id: Int,
    /// The parent outline symbol, if the server nested this symbol.
    parent_id: Option(Int),
    /// The server's symbol spelling.
    name: String,
    /// The decoded symbol kind.
    kind: String,
    /// The server's optional description.
    detail: Option(String),
    /// Its admitted canonical path and one-based codepoint position.
    site: query.Site,
  )
}

/// One requested reference seed, separate from outlined symbols.
pub type Target {
  Target(
    /// The seed's zero-based index in Request.targets.
    id: Int,
    /// The original question, retained to state the scope actually answered.
    asked: query.SymbolQuery,
    /// The exact admitted position sent in the reference request.
    site: query.Site,
  )
}

/// One admitted raw reference, with no implicit container-outline requests.
pub type Reference {
  Reference(
    /// The requested seed this reference answers.
    target_id: Int,
    /// The admitted canonical path and one-based codepoint position.
    site: query.Site,
  )
}

/// Counts which make bounded collection and withheld results explicit.
pub type Counts {
  Counts(
    /// All semantic requests, including resolver documentSymbol calls.
    requests: Int,
    /// Locations withheld by admission, which were never read or opened.
    withheld: Int,
    /// All retained document, symbol, target and reference rows.
    facts: Int,
    /// The retained UTF-8 strings plus conservative row overhead.
    fact_bytes: Int,
  )
}

/// A complete observation of the explicit request during one checked interval.
pub type Batch {
  Batch(
    /// The complete request this observation answered.
    requested: Request,
    /// The canonical server project root.
    root: String,
    /// An opaque content address identifying this client incarnation.
    generation: String,
    /// Observation start in Control.now's milliseconds.
    started_ms: Int,
    /// Observation finish in the same clock's milliseconds.
    finished_ms: Int,
    /// Exactly the admitted files whose outlines were answered.
    outlined: List(String),
    /// Every admitted file used to convert a returned fact.
    documents: List(Document),
    /// Flat outline rows, covering only Batch.outlined.
    symbols: List(Symbol),
    /// Exactly one row for every requested reference seed.
    targets: List(Target),
    /// Raw admitted references for Batch.targets only.
    references: List(Reference),
    /// Counts for requests, retained facts and withheld locations.
    counts: Counts,
  )
}

/// Why the requested complete observation could not be published.
pub type Error {
  /// The scope is invalid or exceeds a fixed admission bound.
  InvalidScope(reason: String)

  /// The server refused or failed one required query.
  QueryFailed(error: query.QueryError)

  /// The shared server or an observed document changed during collection.
  Changed(reason: String)

  /// A complete result exceeded a fixed fact or request bound.
  LimitExceeded(reason: String)

  /// The invocation or fixed observation deadline expired.
  DeadlineExceeded
}

/// A separate read-only collection seam; query.Door remains unchanged.
pub type Door {
  Door(
    /// Collects a complete finite batch under the invocation's custody.
    collect: fn(Request, Control) -> Result(Batch, Error),
  )
}
