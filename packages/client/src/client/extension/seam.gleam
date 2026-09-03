//// The extension seam's harness-side router: the one capability arm a
//// jailed extension has that a code-mode program does not.
////
//// An extension satellite is `codemode/workspace`'s seam plus
//// `net.request` — the one capability `cap/net` has always declared and
//// nothing has ever served — and the two memory arms an extension owns,
//// `ext.remember` and `ext.recall`. All three are
//// `satellite.ServedHere`: the harness answers them itself, no jail is
//// entered, and the node's network namespace stays empty, which is the
//// property ADR-007 turns on. Everything this router does not answer is
//// handed to the router beneath, exactly as `codemode/workspace.routing`
//// and `client/mcp.routing` do, so nothing about `fs.read` or `proc.run`
//// changes shape because an extension is what is running.
////
//// # The memory arms, and what they are not
////
//// `ext.remember` and `ext.recall` are the design note's mapping of pi's
//// `appendEntry`: durable, latest-wins cells under a reserved fact
//// prefix the extension owns. They are not `kv.*`, which the router
//// beneath already serves — that store is ephemeral scratch, evicted
//// between calls and gone with the session, and an extension that wants
//// something to survive a restart wants these two.
////
//// The key an extension sends is a **leaf**, and this module checks it:
//// non-empty, no `/`, and bounded. The subtree it lands in is composed
//// on the far side of the `Memory` closures from the installed record's
//// name (`client/extension/memory.key`), so no argument on the wire can
//// name another extension's cell — which is why the check here is about
//// the shape of a leaf and not about escaping a path. A key of `..`
//// means nothing to a cell name, and a key of `../x` is refused for the
//// slash rather than for the dots.
////
//// The arms are per *extension*, not per invocation kind. A `hook_call`
//// of kind `event` — a phase 3 hook — reaches the same satellite under
//// the same router, so a hook may remember and recall exactly as a tool
//// may. That is deliberate: the natural use is a hook that records what
//// it saw for a tool to read on the next call, and a seam that served
//// one kind and not the other would be a distinction with nothing
//// behind it.
////
//// There used to be a second arm. `ext.call` was how a phase 1 node
//// learned which tool its one execution was for, and phase 3 deleted it
//// along with the pull it belonged to: a satellite that lives for the
//// session is *told* what to answer over a `hook_call`
//// (`protocol-change/012`), so there is nothing left to ask.
////
//// # Why the seam speaks its own request type
////
//// `Ask` and `Answer` restate `cap/net`'s `Request` and `Response`
//// instead of naming `broker/egress`'s. That is deliberate: this module
//// is the *wire* — msgpack in, msgpack out, every field decoded totally —
//// and it holds no policy at all. Which hosts are reachable, which
//// methods are permitted, what a refusal's code should be and which
//// credential goes in which header are all decided in
//// `client/extension/policy` and closed over by the `perform` function
//// this router is handed. So a test drives the whole arm with a function
//// and no socket, and a reader looking for "what may this extension
//// reach" never finds half an answer here.
////
//// # Every boundary decodes totally
////
//// The satellite runs an operator-installed extension, which is code from
//// somebody else's repository, so every field of every inbound frame is
//// decoded rather than assumed. A wrong-shaped argument becomes a
//// `CapDenial` the extension reads and repairs; it is never a crash and
//// never a request made with a guessed value.
////
//// # The credential is not in this module, and could not be
////
//// A secret binding names an environment variable, a host and a header.
//// The value is read by `broker/egress` at request time, inside the
//// `perform` closure, and placed on the hop whose origin matches. It is
//// not an argument here, not a field of `Ask` or `Answer`, and not
//// something a `CapDenial` has room for — so no frame this router
//// composes can carry it, whatever an extension asks for.

import broker/framing.{type CapOutcome}
import client/extension/policy.{net_cap}
import codemode/satellite.{
  type CapDenial, type CapPlan, type CapRequest, type CapRouter, CapDenial,
  ServedHere,
}
import core/msgpack.{type MsgPackValue}
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The names this router answers. `extension/dispatch_test` walks it and
/// asserts each one routes, which is what keeps it the same list as the
/// `case` arms below — Gleam patterns cannot name a constant, so the two
/// could otherwise drift.
pub const serviced_caps = [net_cap, remember_cap, recall_cap]

/// The capability an extension writes one durable cell with.
pub const remember_cap = "ext.remember"

/// The capability an extension reads one durable cell with.
pub const recall_cap = "ext.recall"

/// The code a memory call travels under when the session's own store
/// could not answer it.
///
/// Outside `invalid_argument_code` on purpose: a malformed key is the
/// extension's bug and a store that will not answer is the host's, and an
/// author who cannot tell them apart cannot decide whether to retry.
pub const memory_unavailable_code = "memory_unavailable"

/// The longest leaf key an extension may name, in graphemes.
///
/// A bound rather than no bound because the key becomes part of a
/// durable register key, and a store whose key size is whatever an
/// extension felt like is a store with no shape. Generous enough that no
/// honest name reaches it: this is a name an author types, not a digest.
pub const max_key_length = 128

/// The largest value one cell may hold, in bytes of JSON text.
///
/// The per-cell half of the bound on what an extension's memory can grow
/// to; the other half is that a key is overwritten rather than appended
/// (`client/extension/memory`). An extension with more than this to keep
/// has a file, and `fs.write` to put it in.
pub const max_value_bytes = 65_536

/// The code a structurally invalid argument travels under.
///
/// Outside `cap/net.map_error`'s denial set on purpose: an extension that
/// sent a malformed `net.request` has a bug rather than a policy problem,
/// and `NetFailed("invalid_argument", …)` says which.
pub const invalid_argument_code = "invalid_argument"

/// One outbound request a jailed extension asked the harness to make.
///
/// `method` is text rather than a closed set because that is what came
/// off the wire; turning it into one is a policy decision and belongs
/// with the policy.
pub type Ask {
  Ask(
    method: String,
    url: String,
    headers: List(#(String, String)),
    body: BitArray,
  )
}

/// One response the harness made on the extension's behalf.
pub type Answer {
  Answer(status: Int, headers: List(#(String, String)), body: BitArray)
}

/// How `net.request` is answered for this execution.
///
/// Two variants and no third, mirroring `policy.Egress`: an extension
/// either declared a `[net]` table an operator approved, in which case
/// requests go to a function with that policy closed over, or it did not,
/// in which case every request meets one standing refusal.
pub type Egress {
  /// Requests are performed by this function, which holds the policy, the
  /// credential lookup and the refusal mapping.
  Reaches(perform: fn(Ask) -> Result(Answer, CapDenial))

  /// Every request is refused with this denial, by the router rather
  /// than by a served closure — so nothing is decoded, no ordinal is
  /// claimed and no admission is spent. The refusal is a value rather
  /// than a computation so that a reader can see it is the same one
  /// every time.
  ReachesNothing(refusal: CapDenial)
}

/// How this extension's durable cells are read and written.
///
/// Two closures rather than a store, for the reason `Egress` is a
/// closure: this module is the wire and holds no durability at all. The
/// key each takes is the *leaf* an extension named and this router
/// checked; the subtree it lands in is bound on the far side, by
/// `client/extension/dispatch`, from the installed record's name.
pub type Memory {
  Memory(
    /// Writes one cell, overwriting whatever it held. The value is the
    /// JSON document the extension sent, as text.
    remember: fn(String, String) -> Result(Nil, CapDenial),
    /// Reads one cell, or `None` when nothing was ever written under it.
    recall: fn(String) -> Result(Option(String), CapDenial),
  )
}

/// The harness-side closures one extension invocation's router calls.
pub type Extension {
  Extension(
    /// How outbound requests are answered.
    egress: Egress,
    /// How durable cells are read and written.
    memory: Memory,
  )
}

/// The extension seam's router, in front of `inner`.
///
/// Composed rather than total: an extension satellite reaches `fs.*`,
/// `kv.*`, `report.emit` and `proc.run` through the routers beneath, so
/// this one answers the three names in `serviced_caps` and hands
/// everything else down.
///
/// ## Examples
///
/// ```gleam
/// // seam.routing(extension, over: workspace.routing(ws, over: inner))
/// ```
///
pub fn routing(extension: Extension, over inner: CapRouter) -> CapRouter {
  fn(request: CapRequest) {
    case request.cap {
      "net.request" -> net_plan(extension.egress, request)
      "ext.remember" -> remember_plan(extension.memory, request)
      "ext.recall" -> recall_plan(extension.memory, request)
      _other -> inner(request)
    }
  }
}

/// One response as the value `cap/net.decode_response` reads.
///
/// Public so a test can compare it against `cap/net`'s own decoder
/// without standing up a router: this and that decoder are two halves of
/// one wire shape, and the only way to keep them in agreement is to run
/// one against the other.
///
/// ## Examples
///
/// ```gleam
/// // seam.answer_value(seam.Answer(200, [], <<>>))
/// ```
///
pub fn answer_value(answer: Answer) -> MsgPackValue {
  fields([
    #("status", msgpack.IntValue(answer.status)),
    #(
      "headers",
      msgpack.MapValue(
        list.map(answer.headers, fn(pair) {
          #(msgpack.StringValue(pair.0), msgpack.StringValue(pair.1))
        }),
      ),
    ),
    #("body", msgpack.BinaryValue(answer.body)),
  ])
}

// --- net.request -----------------------------------------------------------

// Refusals are returned by the *plan* rather than from inside a served
// closure, and both of them for the same reason: the host admits a call
// only once the router has answered `Ok`, so a plan that refuses costs no
// ordinal and no admission against the ceiling — the rule
// `satellite.CapRequest`'s `ordinal` doc states.
//
// That ordering is also what makes `network_off` reachable at all. An
// extension with no `[net]` has a `net.request` ceiling of zero
// admissions, so a `ServedHere` plan here would be overtaken by the
// ceiling's own refusal and the author would read "lifetime cap of 0"
// where they should read "this extension declares no [net] table".
fn net_plan(egress: Egress, request: CapRequest) -> Result(CapPlan, CapDenial) {
  case egress {
    ReachesNothing(refusal:) -> Error(refusal)
    Reaches(perform:) -> {
      use ask <- result.try(decode_ask(request.args))
      Ok(
        ServedHere(fn() {
          case perform(ask) {
            Ok(answer) -> framing.CapOk(value: answer_value(answer))
            Error(denial) -> refused(denial)
          }
        }),
      )
    }
  }
}

fn decode_ask(args: MsgPackValue) -> Result(Ask, CapDenial) {
  use method <- result.try(string_field(args, "method"))
  use url <- result.try(string_field(args, "url"))
  use headers <- result.try(header_field(args, "headers"))
  use body <- result.try(binary_field(args, "body"))
  Ok(Ask(method:, url:, headers:, body:))
}

// --- ext.remember and ext.recall -------------------------------------------

// Both arms check the key before they claim a plan, for the reason the
// egress refusals are returned by the plan: a refused plan costs no
// ordinal and no admission, so an extension that sent a malformed key
// pays nothing for the mistake it is about to be told to fix.

fn remember_plan(
  memory: Memory,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use key <- result.try(leaf_key(request.args))
  use value <- result.try(remembered_value(request.args))
  Ok(
    ServedHere(fn() {
      case memory.remember(key, value) {
        Ok(Nil) -> framing.CapOk(value: fields([]))
        Error(denial) -> refused(denial)
      }
    }),
  )
}

fn recall_plan(
  memory: Memory,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use key <- result.try(leaf_key(request.args))
  Ok(
    ServedHere(fn() {
      case memory.recall(key) {
        Error(denial) -> refused(denial)

        // `found` and `value` as two fields rather than one nullable
        // field, the shape `kv.get` set and for the same reason: the
        // reader takes the flag first, so a cell holding the document
        // `null` is distinguishable from a cell that was never written.
        Ok(None) ->
          framing.CapOk(value: fields([#("found", msgpack.BoolValue(False))]))
        Ok(Some(value)) ->
          framing.CapOk(
            value: fields([
              #("found", msgpack.BoolValue(True)),
              #("value", msgpack.StringValue(value)),
            ]),
          )
      }
    }),
  )
}

/// One leaf key, checked.
///
/// Public because the check *is* the confinement's near half — the far
/// half being that the subtree is composed from the install record — and
/// a property this narrow deserves a test that does not have to stand up
/// a router to ask it.
///
/// ## Examples
///
/// ```gleam
/// // seam.checked_key("last") == Ok("last")
/// ```
///
/// ```gleam
/// // seam.checked_key("../x") is an `invalid_argument` denial
/// ```
///
pub fn checked_key(key: String) -> Result(String, CapDenial) {
  use <- bool.lazy_guard(when: key == "", return: fn() {
    Error(invalid("`key` must not be empty"))
  })
  use <- bool.lazy_guard(when: string.contains(key, "/"), return: fn() {
    Error(invalid(
      "`key` names one cell in this extension's own memory, so it may not "
      <> "contain `/`",
    ))
  })

  // Asked with `drop_start`, which stops at the bound, rather than with
  // `string.length`, which walks the whole key to answer a question
  // settled long before its end — and the key is whatever came off the
  // channel.
  use <- bool.lazy_guard(
    when: string.drop_start(key, max_key_length) != "",
    return: fn() {
      Error(invalid(
        "`key` is longer than the "
        <> int.to_string(max_key_length)
        <> " characters a cell name may have",
      ))
    },
  )
  Ok(key)
}

fn leaf_key(args: MsgPackValue) -> Result(String, CapDenial) {
  use key <- result.try(string_field(args, "key"))
  checked_key(key)
}

fn remembered_value(args: MsgPackValue) -> Result(String, CapDenial) {
  use value <- result.try(string_field(args, "value"))
  case string.byte_size(value) > max_value_bytes {
    True ->
      Error(invalid(
        "`value` is larger than the "
        <> int.to_string(max_value_bytes)
        <> " bytes one cell may hold",
      ))
    False -> Ok(value)
  }
}

// --- total field extraction ------------------------------------------------
//
// `codemode/internal/args` does this for the routers inside that package
// and is internal to it, so these four are the same discipline restated
// at the package boundary rather than a second opinion about it: every
// failure names the offending field, none is a crash, and the code is the
// one `invalid_argument_code` declares.

fn field(value: MsgPackValue, key: String) -> Result(MsgPackValue, CapDenial) {
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

fn string_field(value: MsgPackValue, key: String) -> Result(String, CapDenial) {
  use found <- result.try(field(value, key))
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

// Bytes or text, the same latitude `codemode/internal/args.binary` gives
// and for the same reason: `cap/net` marshals the body with
// `wire.binary`, but an extension that built its body by string
// concatenation and sent it as text meant exactly those bytes.
fn binary_field(
  value: MsgPackValue,
  key: String,
) -> Result(BitArray, CapDenial) {
  use found <- result.try(field(value, key))
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

// Headers are a map of text to text and every entry has to survive: a
// filter here would drop a header the extension believes it sent, and a
// request that quietly lost its `Accept` is worse to debug than one that
// was refused.
fn header_field(
  value: MsgPackValue,
  key: String,
) -> Result(List(#(String, String)), CapDenial) {
  use found <- result.try(field(value, key))
  case found {
    msgpack.MapValue(entries:) -> list.try_map(entries, header_entry)

    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..) ->
      Error(invalid("`" <> key <> "` must be a map of header names to values"))
  }
}

fn header_entry(
  entry: #(MsgPackValue, MsgPackValue),
) -> Result(#(String, String), CapDenial) {
  case entry {
    #(msgpack.StringValue(name), msgpack.StringValue(text)) -> Ok(#(name, text))
    _other -> Error(invalid("every header name and value must be text"))
  }
}

fn invalid(reason: String) -> CapDenial {
  CapDenial(code: invalid_argument_code, message: reason)
}

fn refused(denial: CapDenial) -> CapOutcome {
  let CapDenial(code:, message:) = denial
  framing.CapErr(code:, message:)
}

fn fields(entries: List(#(String, MsgPackValue))) -> MsgPackValue {
  msgpack.MapValue(
    list.map(entries, fn(entry) { #(msgpack.StringValue(entry.0), entry.1) }),
  )
}
