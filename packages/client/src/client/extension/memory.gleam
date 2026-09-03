//// The host side of an installed extension's durable memory: the two
//// closures `client/extension/seam` calls for `ext.remember` and
//// `ext.recall`, and the one place the key an extension touches is
//// composed.
////
//// The design note's mapping of pi's `appendEntry` is a reserved fact
//// prefix the extension owns (`docs/design-notes/extension-architecture.md`,
//// "The rest of pi's surface, mapped"): durable, latest-wins cells under
//// `ext/<name>/<key>`, written through the same door
//// `schedule/config/…` cells go through. This module is that door, and
//// it is the same split `client/scheduleseam` fills for
//// `tools/schedule` — the seam owns the wire and the vocabulary, and the
//// host owns everything durable.
////
//// # The subtree is composed here and named nowhere else
////
//// A `Cell` carries the extension's name and the leaf key, and `key`
//// is the only function in the tree that turns the two into a fact
//// key. The name comes from the install record
//// (`client/extension/dispatch` closes over it), never from the
//// capability frame, so an extension cannot describe a cell outside its
//// own subtree: there is no argument in which it could. The leaf is
//// checked for the one character that would let it climb —
//// `client/extension/seam` refuses a `/` before this module is reached —
//// so `ext/a/…` and `ext/b/…` are disjoint by construction rather than
//// by a check somebody has to remember to make.
////
//// The model reaches neither. `runtime/api.ext_fact_prefix` is
//// reserved, so `put_fact` refuses these keys and `facts` hides them,
//// which is what makes an extension's memory something the extension
//// alone decides to show — through a `before_agent_start` injection, if
//// it wants to show it at all.
////
//// # Latest-wins, and no ceiling
////
//// A write is `api.put_reserved_fact`: a blind overwrite of one cell,
//// exactly as a `schedule/config/…` cell is written and for the same
//// reason — the extension is the only writer of its own subtree, and
//// writing the same value twice is indistinguishable from writing it
//// once. Nothing here is compare-and-set, so two concurrent
//// `ext.remember` calls on one key leave the later one's value and the
//// earlier one's write is simply gone. An extension that needs a
//// counter should keep it in one cell it writes from one place.
////
//// There is no admission ceiling on either arm, on the reading
//// `codemode/workspace.ceilings` states: the durable thing a remember
//// mints is bounded per cell by `seam.max_value_bytes` and per key by
//// the fact that a key is overwritten rather than appended. What is
//// *not* bounded is how many distinct keys an extension may write, and
//// that is deliberate — an extension is operator-installed code that
//// already holds `fs.write` inside the workspace, so a key-count
//// ceiling would bound the smaller of the two ways it can fill a disk
//// while making the honest use awkward.

import client/agency
import core/corruption
import core/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api.{type Runtime}

/// Why a memory call could not be answered.
///
/// A *missing* key is not here: `recall` answers `Ok(None)` for a cell
/// that was never written, which is the case every extension has to
/// handle on its first call.
pub type Refusal {
  /// The value the extension sent is not a JSON document. Refused
  /// rather than stored as text, because a cell an operator or a hook
  /// reads is worth keeping as the structure it claims to be.
  NotJson(reason: String)

  /// The session store could not be reached, or refused the write.
  Unavailable(reason: String)
}

/// One cell, addressed the only way a cell can be addressed here: the
/// installed extension's name, and the leaf key it asked for.
///
/// A record rather than two positional strings because both are text
/// and a caller that swapped them would type-check while writing into
/// another extension's subtree.
pub type Cell {
  Cell(
    /// The installed extension's name, from its record.
    extension: String,
    /// The leaf key, checked by `client/extension/seam` before it
    /// arrives.
    key: String,
  )
}

/// The two closures one session's extensions reach their memory through.
///
/// Closures rather than a runtime, for the reason `scheduleseam.Door`
/// is: the runtime does not exist until `api.open` has returned, and the
/// seam is built before that.
pub type Door {
  Door(
    /// Writes one cell, overwriting whatever it held. `value` is the
    /// JSON document the extension sent, as text.
    remember: fn(Cell, String) -> Result(Nil, Refusal),
    /// Reads one cell, or `None` when it was never written. The answer
    /// is the stored document rendered back to text.
    recall: fn(Cell) -> Result(Option(String), Refusal),
  )
}

/// What the door needs from the host.
pub type Wiring {
  Wiring(
    /// Borrows the live runtime, exactly as `scheduleseam.Wiring` does
    /// and for the same reason: this door is built while `api.open` is
    /// still assembling the registry it will be reached through, so a
    /// captured runtime would be a value cycle. `Error(Nil)` — the
    /// holder not up, or gone — becomes an in-band `Unavailable`.
    runtime: fn() -> Result(Runtime, Nil),
  )
}

/// The memory door over one live session.
///
/// ## Examples
///
/// ```gleam
/// // memory.door(memory.Wiring(runtime: fn() { Ok(runtime) }))
/// //   .remember(memory.Cell("web-search", "last"), "{\"q\":\"loom\"}")
/// ```
///
pub fn door(wiring: Wiring) -> Door {
  Door(
    remember: fn(cell, value) {
      use runtime <- with_runtime(wiring)
      remember(runtime, cell, value)
    },
    recall: fn(cell) {
      use runtime <- with_runtime(wiring)
      recall(runtime, cell)
    },
  )
}

/// A door onto no session at all: every call refuses with `reason`.
///
/// What a host with no runtime to borrow hands the dispatch, so the
/// field is a `Door` rather than an `Option(Door)` — an extension then
/// reads one sentence saying its memory is unavailable, instead of
/// `ext.remember` being an unrouted name whose refusal says nothing
/// about why.
///
/// ## Examples
///
/// ```gleam
/// // memory.shut("this host has no session").recall(cell)
/// //   == Error(memory.Unavailable("this host has no session"))
/// ```
///
pub fn shut(reason: String) -> Door {
  Door(
    remember: fn(_cell, _value) { Error(Unavailable(reason:)) },
    recall: fn(_cell) { Error(Unavailable(reason:)) },
  )
}

/// The fact key one cell lives under. The single composition of
/// `ext/<extension>/<key>`, so the confinement is one line a reader can
/// check rather than a convention spread over the arms that write it.
///
/// ## Examples
///
/// ```gleam
/// assert memory.key(memory.Cell("web-search", "last"))
///   == "ext/web-search/last"
/// ```
///
pub fn key(cell: Cell) -> String {
  api.ext_fact_prefix <> cell.extension <> "/" <> cell.key
}

/// The door over the session `agency.borrow_runtime` holds, which is
/// what `client/serve` wires.
///
/// ## Examples
///
/// ```gleam
/// // memory.for_session(agency_config).remember(cell, "{}")
/// ```
///
pub fn for_session(config: agency.Config) -> Door {
  door(Wiring(runtime: fn() { agency.borrow_runtime(config) }))
}

// --- the two arms ----------------------------------------------------------

// A remember is a parse and a write. The parse is what keeps a cell
// honest: `ext.remember` takes a JSON document as text on the wire
// because that is what crosses a msgpack channel cheaply, and storing an
// unparsed string would put a quoted document where every other reader
// of the blackboard expects a value.
fn remember(
  runtime: Runtime,
  cell: Cell,
  value: String,
) -> Result(Nil, Refusal) {
  use parsed <- result.try(
    json.parse(value)
    |> result.map_error(fn(report) {
      NotJson(
        reason: "the value is not a JSON document: "
        <> corruption.describe(report),
      )
    }),
  )
  api.put_reserved_fact(runtime, key(cell), parsed)
  |> result.map_error(unavailable)
}

// A recall reads the cell and renders it back. `api.fact` is the read
// that never consulted the reservation, which is what makes it the right
// one here: this key *is* reserved, and the harness-side listing door
// would answer a subtree where one cell was asked for.
fn recall(runtime: Runtime, cell: Cell) -> Result(Option(String), Refusal) {
  use found <- result.try(
    api.fact(runtime, key(cell)) |> result.map_error(unavailable),
  )
  case found {
    None -> Ok(None)
    Some(value) -> Ok(Some(json.to_string(value)))
  }
}

// Every call borrows the runtime first, and a holder that is not up
// refuses in band rather than crashing the effect process.
fn with_runtime(
  wiring: Wiring,
  then: fn(Runtime) -> Result(a, Refusal),
) -> Result(a, Refusal) {
  case wiring.runtime() {
    Ok(runtime) -> then(runtime)
    Error(Nil) ->
      Error(Unavailable(
        reason: "this session's store is not available to read or write",
      ))
  }
}

fn unavailable(error: api.ApiError) -> Refusal {
  Unavailable(reason: string.inspect(error))
}
