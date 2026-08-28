//// The workspace seam's harness-side capability router: `fs.read`,
//// `fs.list`, `kv.*` and `report.emit`, answered inside the harness
//// rather than inside a jail.
////
//// # What this is, and what it deliberately is not
////
//// `satellite.default_router` services one capability — `proc.run` —
//// because that is the one that maps onto a jailed `broker.clear_call`.
//// Everything else a workspace program can import is either composed out
//// of `proc.run` inside the satellite (`cap/git`, which needs no routing
//// at all and never did), still gated on something outside this package
//// (`net.request` on the egress proxy, `lsp.*` on the long-lived stdio
//// client), or a request the harness answers *itself*. This module is
//// that last group.
////
//// Its plans are therefore `satellite.ServedHere` and never
//// `satellite.ClearedCall`, for the same reason the orchestration seam's
//// are (`codemode/orchestration`). Reading a file the harness can
//// already read, writing a byte-capped entry into a process-local dict,
//// and hashing bytes into the session's blob store are not effects on
//// the world outside the harness: no process is spawned, no socket is
//// opened, nothing crosses a namespace. Composing a `SandboxPolicy` for
//// one would build a policy **whose enforcer is not there** — the
//// enforcer is the jail, and there is no jail on this path — and it
//// would add six `broker.CallSpec` construction sites to the most
//// security-sensitive dispatch in the tree, each carrying `{op_id,
//// step_id, budget}` a router writes by hand. A router that returns only
//// `ServedHere` cannot state coordinates at all. That is the whole
//// argument for the shape, and it is issue #16's ruling.
////
//// # Nothing about the authorization model is re-derived
////
//// The seam record below is a record of *injected closures*, and the
//// production ones are built out of `tools/fs`'s own functions
//// (`client/codemode`). `resolve_real` is the harness's sole filesystem
//// boundary — it walks a path component by component through `read_link`
//// and requires the resolved result to land under the equally-resolved
//// workspace root, so neither `..` nor a symlink planted inside the
//// workspace escapes — and `read_text_file` is the same large-file guard
//// and the same UTF-8 rule `fs_read` applies. A second path resolution
//// written here would be a second boundary to keep correct, and the one
//// that got it wrong would be the one nobody was reading. This module
//// therefore holds no path logic whatever: it decodes a frame, calls a
//// closure, and names the refusal that comes back.
////
//// # What is not here yet, and why
////
//// `fs.write` and `fs.edit` are refused as `unsupported_cap`, and the
//// seam record has no slot for them — an absent field is a decision a
//// reader can see, where a field wired to a refusal is one they have to
//// go looking for.
////
//// `fs.write` waited on the protected-path check (#105): until the
//// harness-side write path enforced the base policy's never-writable
//// list, bridging it would have handed a vetted program **strictly more
//// filesystem authority than its own jailed `proc.run`**, whose bwrap
//// masks honour that list. `fs.edit` is a live design question rather
//// than plumbing: the satellite side is `Replacement(find, replace_with)`
//// with no anchors and no digest, while the harness `fs_edit` is
//// anchor-and-digest-bound, and a satellite cannot construct a
//// harness-shaped hunk because `cap/fs.read` hands back plain string
//// contents. Bridging it would mean the bridge *synthesising* the
//// anchors and the digest on the program's behalf — inventing a safety
//// property rather than checking one the caller committed to.
////
//// # Every boundary decodes totally
////
//// The satellite is untrusted, so every field of every inbound frame is
//// decoded rather than assumed: a wrong-shaped argument is a `CapDenial`
//// the program reads as `cap/fs.InvalidArgument` (or `cap/kv.KvDenied`)
//// and can repair, never a crash and never a call made with a guessed
//// value.

import broker/framing.{type CapOutcome}
import codemode/artifact.{type Emit}
import codemode/satellite.{
  type CapCeiling, type CapDenial, type CapPlan, type CapRequest, type CapRouter,
  CapDenial, ServedHere,
}
import core/msgpack.{type MsgPackValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tools/fs
import tools/tool

// --- the capability names --------------------------------------------------

/// The capability a program reads a workspace file with.
pub const read_cap = "fs.read"

/// The capability a program lists a workspace directory with.
pub const list_cap = "fs.list"

/// The capability a program reads a scratch key with.
pub const kv_get_cap = "kv.get"

/// The capability a program writes a scratch key with.
pub const kv_set_cap = "kv.set"

/// The capability a program removes a scratch key with.
pub const kv_delete_cap = "kv.delete"

/// The capability a program mints a durable artifact with. Serviced on
/// **both** seams, by one mechanism (`codemode/artifact`).
pub const emit_cap = artifact.emit_cap

/// The two `cap/fs` capabilities this seam does not service yet, refused
/// by name rather than by falling through to a router that would say
/// only "not routed". See the module doc for what each is waiting on.
pub const unserviced_caps = ["fs.write", "fs.edit"]

/// Every capability this router services, in the order a program meets
/// them. Published so the tool description a model reads states the real
/// set rather than a copy that can drift.
pub const serviced_caps = [
  read_cap, list_cap, kv_get_cap, kv_set_cap, kv_delete_cap, emit_cap,
]

/// The most entries one `fs.list` may answer with.
///
/// A refusal rather than a truncation, because `cap/fs.DirEntry` has no
/// field for "and more" — a silently short listing is a program looping
/// over a directory it believes it has seen. Four thousand is past every
/// source directory in this tree and well under what would make one
/// answer a multi-megabyte frame.
///
/// The bound is published here and applied where the listing is built,
/// which is the injected closure: enumerating a hundred thousand entries
/// and then refusing would have paid for the whole walk.
pub const max_list_entries = 4096

// --- refusal codes ----------------------------------------------------------
//
// Half of a contract whose other half is `cap/fs.map_error` and
// `cap/kv.map_error`. The two packages share no dependency — they are the
// two ends of one wire, not peers — so each side states its own half and
// a test on each side pins it. A code the far side has not learned
// arrives as its catch-all (`FsFailed`, `KvDenied`) carrying the code
// verbatim, which is a worse answer than a named variant and a much
// better one than a lie.

/// A structurally invalid argument. `cap/fs` decodes it to
/// `InvalidArgument`.
pub const invalid_argument_code = "invalid_argument"

/// A path the workspace does not contain, or one the base policy
/// protects. `cap/fs` decodes it to `PermissionDenied`.
pub const permission_denied_code = "permission_denied"

/// No such path. `cap/fs` decodes it to `NotFound`.
pub const not_found_code = "not_found"

/// An operation/kind mismatch — today, a text read of bytes that are not
/// text. `cap/fs` decodes it to `WrongKind`.
pub const wrong_kind_code = "wrong_kind"

/// A read or a listing that is too big to answer. Carried verbatim into
/// `cap/fs.FsFailed`, so the message is what a program reads.
pub const too_large_code = "too_large"

/// A path that could not be resolved at all: an unreadable component, or
/// a symlink chain past the resolution budget.
pub const unresolvable_code = "unresolvable"

/// Any other filesystem failure, with the backend's own description.
pub const fs_failure_code = "fs_failure"

/// The scratch store could not answer. `cap/kv` decodes every code to
/// `KvDenied`, so the message is what a program reads.
pub const kv_unavailable_code = "kv_unavailable"

/// A capability name this seam does not service.
pub const unsupported_cap_code = "unsupported_cap"

// --- the seam ---------------------------------------------------------------

/// One directory entry, as `cap/fs.DirEntry` reads it back.
///
/// Constructor invariants: `name` is the entry's own name and never a
/// path — a program joins it onto the directory it listed. `is_directory`
/// is answered with **lstat semantics**: a symlink is reported as not a
/// directory whatever it points at, which is both the safe direction (the
/// answer says nothing about a target that may be outside the workspace)
/// and the honest one (`fs.read` through that link would be refused by
/// `resolve_real` anyway).
pub type DirEntry {
  DirEntry(name: String, is_directory: Bool)
}

/// Why a filesystem call could not be answered.
///
/// Every variant wraps a decision made by `tools/fs` rather than by this
/// module — a `PathError` from `resolve_real`, a `ReadError` from
/// `read_text_file` — except the two that are properties of *listing*, an
/// operation the harness's own tool set does not have.
pub type FsRefusal {
  /// `resolve_real` refused the path.
  PathRefused(error: fs.PathError)
  /// The path resolved and the read did not produce text.
  ReadRefused(error: fs.ReadError)
  /// The directory could not be enumerated, with the backend's reason.
  ListRefused(error: tool.FsError)
  /// The directory holds more than `max_list_entries` entries.
  TooManyEntries(count: Int, limit: Int)
}

/// Why a scratch-store call could not be answered.
///
/// A *missing* key is not here: `cap/kv.get` answers `Ok(None)` for an
/// absent or evicted key, which is the case every caller must handle, so
/// the closure returns `Option` and this type is for infrastructure
/// alone.
pub type KvRefusal {
  /// The value is larger than one entry may be.
  EntryTooLarge(bytes: Int, limit: Int)
  /// The store is not running, or did not answer.
  StoreUnavailable(reason: String)
}

/// What the router needs beyond the request: one closure per serviced
/// capability, and the ceiling on artifact emissions.
///
/// Closures rather than a configuration record, for the reason
/// `codemode/orchestration` takes an `Agency`: this package must not
/// learn what a workspace root is, where a session keeps its blobs, or
/// how the scratch store is supervised. It decodes a frame, calls a
/// closure, and carries the answer — or the refusal, under a name
/// `packages/cap` decodes — back.
///
/// There is deliberately **no slot for `fs.write` or `fs.edit`**. See the
/// module doc: an absent field is a decision a reader can see.
pub type Workspace {
  Workspace(
    /// Reads a workspace-relative path as text.
    fs_read: fn(String) -> Result(String, FsRefusal),
    /// Lists a workspace-relative directory, bounded by
    /// `max_list_entries`.
    fs_list: fn(String) -> Result(List(DirEntry), FsRefusal),
    /// Reads a scratch key, or `None` when it is absent or was evicted.
    kv_get: fn(String) -> Result(Option(BitArray), KvRefusal),
    /// Writes a scratch key, replacing any prior value.
    kv_set: fn(String, BitArray) -> Result(Nil, KvRefusal),
    /// Removes a scratch key. Removing an absent key succeeds.
    kv_delete: fn(String) -> Result(Nil, KvRefusal),
    /// Writes one artifact and answers its content address.
    emit: Emit,
    /// How many artifacts one execution may mint.
    emit_ceiling: Int,
  )
}

/// The lifetime admission ceilings a workspace execution runs under.
///
/// Exactly one, and its solitude is the decision. `satellite.CapCeiling`
/// states the test: a capability earns a ceiling when a call **mints
/// something that outlives the execution**. `report.emit` meets it — a
/// content-addressed file in a store that outlives the session — and
/// none of the others comes close. `fs.read` and `fs.list` are reads,
/// bounded by the per-read size guard and by the pooled
/// outstanding-effect cap and wall deadline every admitted call already
/// runs under. `kv.*` writes into a process-local store that dies with
/// the session, and it is bounded **store-side**, by a total byte cap
/// with eviction, which is a different instrument from an admission
/// ceiling and the right one: what a scratch store must not do is grow,
/// not answer often.
///
/// ## Examples
///
/// ```gleam
/// // workspace.ceilings(seam) |> list.length == 1
/// ```
///
pub fn ceilings(seam: Workspace) -> List(CapCeiling) {
  [artifact.ceiling(seam.emit_ceiling)]
}

/// The workspace seam's harness-side router, in front of `inner`.
///
/// Composed rather than total, because the workspace seam is served by
/// more than one arm: `proc.run` is `satellite.default_router`'s jailed
/// clearance and `mcp.<server>` is `client/mcp`'s. This one answers the
/// six names it services, refuses the two `cap/fs` names nobody services
/// yet, and hands everything else down untouched — the same shape
/// `client/mcp.routing` has, and for the same reason.
///
/// ## Examples
///
/// ```gleam
/// // workspace.routing(seam, over: satellite.default_router)
/// ```
///
pub fn routing(seam: Workspace, over inner: CapRouter) -> CapRouter {
  fn(request: CapRequest) {
    // Gleam patterns cannot name a constant, so the arms below are string
    // literals while `serviced_caps` holds the constants — two lists that
    // could drift. `workspace_test` walks `serviced_caps` and asserts each
    // one routes, which is what keeps them the same list.
    case request.cap {
      "fs.read" -> read_plan(seam, request)
      "fs.list" -> list_plan(seam, request)
      "kv.get" -> kv_get_plan(seam, request)
      "kv.set" -> kv_set_plan(seam, request)
      "kv.delete" -> kv_delete_plan(seam, request)
      "report.emit" -> artifact.plan(seam.emit, request)
      "fs.write" -> Error(unserviced("fs.write", write_reason))
      "fs.edit" -> Error(unserviced("fs.edit", edit_reason))
      _other -> inner(request)
    }
  }
}

// Why each unserviced `cap/fs` name is refused, in one sentence a model
// can act on: what is missing, and what to do instead. A program that
// reads "not routed" learns nothing; one that reads this reaches for
// `proc.run` and gets on with it.
const write_reason = "writing through the capability bridge is not serviced "
  <> "yet; write the file with proc.run instead"

const edit_reason = "editing through the capability bridge is not serviced "
  <> "yet — the harness's own editor is anchor-and-digest bound and this "
  <> "wire carries neither; read the file, and write it whole with proc.run"

fn unserviced(cap: String, reason: String) -> CapDenial {
  CapDenial(code: unsupported_cap_code, message: cap <> ": " <> reason)
}

// --- fs ---------------------------------------------------------------------

fn read_plan(
  seam: Workspace,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use path <- result.try(string_arg(request.args, "path"))
  Ok(
    ServedHere(fn() {
      case seam.fs_read(path) {
        Error(refusal) -> fs_refused(refusal)
        Ok(contents) -> answered([#("contents", msgpack.StringValue(contents))])
      }
    }),
  )
}

fn list_plan(
  seam: Workspace,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use path <- result.try(string_arg(request.args, "path"))
  Ok(
    ServedHere(fn() {
      case seam.fs_list(path) {
        Error(refusal) -> fs_refused(refusal)
        Ok(entries) ->
          answered([
            #("entries", msgpack.ArrayValue(list.map(entries, entry_value))),
          ])
      }
    }),
  )
}

fn entry_value(entry: DirEntry) -> MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("name"), msgpack.StringValue(entry.name)),
    #(msgpack.StringValue("is_dir"), msgpack.BoolValue(entry.is_directory)),
  ])
}

// --- kv ---------------------------------------------------------------------

fn kv_get_plan(
  seam: Workspace,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use key <- result.try(string_arg(request.args, "key"))
  Ok(
    ServedHere(fn() {
      case seam.kv_get(key) {
        Error(refusal) -> kv_refused(refusal)
        // `found` and `value` as two fields rather than a nullable one:
        // `cap/kv.get` reads the flag first and only then the bytes, so a
        // stored empty `BitArray` is distinguishable from an absent key.
        Ok(None) -> answered([#("found", msgpack.BoolValue(False))])
        Ok(Some(value)) ->
          answered([
            #("found", msgpack.BoolValue(True)),
            #("value", msgpack.BinaryValue(value)),
          ])
      }
    }),
  )
}

fn kv_set_plan(
  seam: Workspace,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use key <- result.try(string_arg(request.args, "key"))
  use value <- result.try(binary_arg(request.args, "value"))
  Ok(
    ServedHere(fn() {
      case seam.kv_set(key, value) {
        Error(refusal) -> kv_refused(refusal)
        Ok(Nil) -> answered([])
      }
    }),
  )
}

fn kv_delete_plan(
  seam: Workspace,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use key <- result.try(string_arg(request.args, "key"))
  Ok(
    ServedHere(fn() {
      case seam.kv_delete(key) {
        Error(refusal) -> kv_refused(refusal)
        Ok(Nil) -> answered([])
      }
    }),
  )
}

// --- answers and refusals ----------------------------------------------------

fn answered(fields: List(#(String, MsgPackValue))) -> CapOutcome {
  framing.CapOk(
    value: msgpack.MapValue(
      list.map(fields, fn(entry) { #(msgpack.StringValue(entry.0), entry.1) }),
    ),
  )
}

fn fs_refused(refusal: FsRefusal) -> CapOutcome {
  let CapDenial(code:, message:) = fs_denial(refusal)
  framing.CapErr(code:, message:)
}

/// The in-band code and message one filesystem refusal travels under.
///
/// Public because it is half of a contract: `cap/fs.map_error` turns each
/// code back into the variant of the same name, and the sentence is what
/// a program reads when there is no named variant. Every message here is
/// `tools/fs`'s own words where `tools/fs` has words for it, so a program
/// and a model reading `fs_read`'s failure read the same sentence.
///
/// ## Examples
///
/// ```gleam
/// // workspace.fs_denial(PathRefused(fs.EmptyPath)).code == "invalid_argument"
/// ```
///
pub fn fs_denial(refusal: FsRefusal) -> CapDenial {
  case refusal {
    PathRefused(error:) -> path_denial(error)
    ReadRefused(error:) -> read_denial(error)
    ListRefused(error:) ->
      CapDenial(code: fs_error_code(error), message: fs_error_text(error))
    TooManyEntries(count:, limit:) ->
      CapDenial(
        code: too_large_code,
        message: "the directory holds "
          <> int.to_string(count)
          <> " entries, more than the "
          <> int.to_string(limit)
          <> " one fs.list may answer with; list a subdirectory, or walk it "
          <> "with proc.run",
      )
  }
}

fn path_denial(error: fs.PathError) -> CapDenial {
  case error {
    fs.EmptyPath ->
      CapDenial(
        code: invalid_argument_code,
        message: "`path` must not be empty",
      )
    fs.EscapesWorkspace(path:) ->
      CapDenial(
        code: permission_denied_code,
        message: "path `" <> path <> "` resolves outside the workspace root",
      )
    // Reads are not refused by the protected list — the harness's own
    // `fs_read` does not consult it either, and an unreadable `.git` would
    // make most of what a program is asked to do impossible. This arm is
    // here because the variant exists and an exhaustive match is how the
    // compiler will find this spot the day a read *is* protected.
    fs.ProtectedPath(path:, protected:) ->
      CapDenial(
        code: permission_denied_code,
        message: "path `"
          <> path
          <> "` is under the protected entry `"
          <> protected
          <> "`",
      )
    fs.Unresolvable(path:, reason:) ->
      CapDenial(
        code: unresolvable_code,
        message: "path `" <> path <> "` could not be resolved: " <> reason,
      )
  }
}

fn read_denial(error: fs.ReadError) -> CapDenial {
  case error {
    fs.ReadFailed(error:) ->
      CapDenial(code: fs_error_code(error), message: fs_error_text(error))
    fs.TooLarge(size:, limit:) ->
      CapDenial(
        code: too_large_code,
        message: "the file is "
          <> int.to_string(size)
          <> " bytes, larger than the "
          <> int.to_string(limit)
          <> " bytes fs.read may answer with; read it in pieces with proc.run",
      )
    fs.NotText ->
      CapDenial(
        code: wrong_kind_code,
        message: "the file is not valid UTF-8 text, and fs.read answers text; "
          <> "read binary content with proc.run",
      )
  }
}

fn fs_error_code(error: tool.FsError) -> String {
  case error {
    tool.FsNotFound(..) -> not_found_code
    tool.FsPermissionDenied(..) -> permission_denied_code
    tool.FsFailure(..) -> fs_failure_code
  }
}

fn fs_error_text(error: tool.FsError) -> String {
  case error {
    tool.FsNotFound(path:) -> "file not found: " <> path
    tool.FsPermissionDenied(path:) -> "permission denied: " <> path
    tool.FsFailure(path:, reason:) ->
      "filesystem error on " <> path <> ": " <> reason
  }
}

fn kv_refused(refusal: KvRefusal) -> CapOutcome {
  let CapDenial(code:, message:) = kv_denial(refusal)
  framing.CapErr(code:, message:)
}

/// The in-band code and message one scratch-store refusal travels under.
///
/// ## Examples
///
/// ```gleam
/// // workspace.kv_denial(EntryTooLarge(1, 0)).code == "too_large"
/// ```
///
pub fn kv_denial(refusal: KvRefusal) -> CapDenial {
  case refusal {
    EntryTooLarge(bytes:, limit:) ->
      CapDenial(
        code: too_large_code,
        message: "a value of "
          <> int.to_string(bytes)
          <> " bytes is larger than the "
          <> int.to_string(limit)
          <> " bytes one scratch entry may hold; the scratch store is a "
          <> "cache, and anything larger belongs in a report.emit artifact",
      )
    StoreUnavailable(reason:) ->
      CapDenial(code: kv_unavailable_code, message: reason)
  }
}

// --- argument decoding -------------------------------------------------------
//
// Total over anything a satellite can send, and shaped exactly like
// `codemode/orchestration`'s: each answers a `CapDenial` naming the
// field, so a program repairs the call rather than guessing.

fn msgpack_field(
  value: MsgPackValue,
  key: String,
) -> Result(MsgPackValue, CapDenial) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
      |> result.map_error(fn(_nil) { invalid("`" <> key <> "` is missing") })
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..) -> Error(invalid("arguments must be a map"))
  }
}

fn string_arg(value: MsgPackValue, key: String) -> Result(String, CapDenial) {
  use found <- result.try(msgpack_field(value, key))
  case found {
    msgpack.StringValue(text) -> Ok(text)
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) -> Error(invalid("`" <> key <> "` must be text"))
  }
}

// A scratch value. `cap/kv.set` marshals a `BitArray` with `wire.binary`,
// so binary is the shape to expect; text is taken as its own bytes for
// the same reason `codemode/artifact` takes it — the store has no such
// distinction, and refusing would cost a round trip to learn one that
// does not exist.
fn binary_arg(value: MsgPackValue, key: String) -> Result(BitArray, CapDenial) {
  use found <- result.try(msgpack_field(value, key))
  case found {
    msgpack.BinaryValue(bytes:) -> Ok(bytes)
    msgpack.StringValue(text) -> Ok(<<text:utf8>>)
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) ->
      Error(invalid("`" <> key <> "` must be bytes or text"))
  }
}

fn invalid(reason: String) -> CapDenial {
  CapDenial(code: invalid_argument_code, message: reason)
}
