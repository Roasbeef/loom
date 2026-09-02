//// The extension seam's harness-side router: the two capability arms a
//// jailed extension has that a code-mode program does not.
////
//// An extension satellite is `codemode/workspace`'s seam plus two names.
//// `ext.call` is how the node learns which tool this execution is for,
//// and `net.request` is how it reaches the network — the one capability
//// `cap/net` has always declared and nothing has ever served. Both are
//// `satellite.ServedHere`: the harness answers them itself, no jail is
//// entered, and the node's network namespace stays empty, which is the
//// property ADR-007 turns on. Everything this router does not answer is
//// handed to the router beneath, exactly as `codemode/workspace.routing`
//// and `client/mcp.routing` do, so nothing about `fs.read` or `proc.run`
//// changes shape because an extension is what is running.
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
import client/extension/policy.{call_cap, net_cap}
import codemode/satellite.{
  type CapDenial, type CapPlan, type CapRequest, type CapRouter, CapDenial,
  ServedHere,
}
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/result

/// The two names this router answers. `extension/dispatch_test` walks it and
/// asserts each one routes, which is what keeps it the same list as the
/// `case` arms below — Gleam patterns cannot name a constant, so the two
/// could otherwise drift.
pub const serviced_caps = [call_cap, net_cap]

/// The code a structurally invalid argument travels under.
///
/// Outside `cap/net.map_error`'s denial set on purpose: an extension that
/// sent a malformed `net.request` has a bug rather than a policy problem,
/// and `NetFailed("invalid_argument", …)` says which. `cap/ext` has no
/// code vocabulary at all, so the same constant serves both arms.
pub const invalid_argument_code = "invalid_argument"

/// The call one execution was launched to serve, in the shape `cap/ext`
/// decodes.
///
/// Constructor invariants: `args` is JSON *text*, never a msgpack value —
/// `cap/ext`'s module doc pins that and gives the reason, which is that
/// `gleam_json`'s parser is the only route from bytes to a `Dynamic` the
/// extension seam's allowlist admits. `deadline_ms` is what is left of
/// the call's wall budget at the moment the call is handed over, not an
/// absolute time, because the node has no clock the harness trusts.
pub type Call {
  Call(tool: String, args: String, strand: String, deadline_ms: Int)
}

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

/// The harness-side closures one extension execution's router calls.
pub type Extension {
  Extension(
    /// The call this execution serves, answered once (the `ext.call`
    /// admission ceiling in `client/extension/policy` is what makes
    /// "once" true rather than a convention).
    ///
    /// A thunk rather than a value because `Call.deadline_ms` is how much
    /// of the budget is *left*, and how much is left is not known until
    /// the node has booted and asked. Computing it when the router is
    /// built would hand every extension the whole timeout however long
    /// the launch took, which is the one number a tool uses to decide
    /// whether to refuse rather than run past its own deadline.
    call: fn() -> Call,
    /// How outbound requests are answered.
    egress: Egress,
  )
}

/// The extension seam's router, in front of `inner`.
///
/// Composed rather than total: an extension satellite reaches `fs.*`,
/// `kv.*`, `report.emit` and `proc.run` through the routers beneath, so
/// this one answers its two names and hands everything else down.
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
      "ext.call" -> call_plan(extension.call)
      "net.request" -> net_plan(extension.egress, request)
      _other -> inner(request)
    }
  }
}

/// The `ext.call` answer for one call, as the value `cap/ext.decode`
/// reads.
///
/// Public so a test can compare it against `cap/ext`'s own decoder
/// without standing up a router: the two are halves of one wire shape,
/// and the only way to keep them in agreement is to run one against the
/// other.
///
/// ## Examples
///
/// ```gleam
/// // seam.call_value(seam.Call("hello", "{}", "main", 1000))
/// ```
///
pub fn call_value(call: Call) -> MsgPackValue {
  fields([
    #("tool", msgpack.StringValue(call.tool)),
    #("args", msgpack.StringValue(call.args)),
    #("strand", msgpack.StringValue(call.strand)),
    #("deadline_ms", msgpack.IntValue(call.deadline_ms)),
  ])
}

/// One response as the value `cap/net.decode_response` reads.
///
/// Public for the same reason `call_value` is: this and `cap/net`'s
/// decoder are two halves of one shape.
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

// --- ext.call --------------------------------------------------------------

// The call is decided before the node is launched, so this arm reads no
// arguments and can never refuse. `cap/ext` sends the empty map and the
// harness answers what it already knew; the whole point of asking over
// the channel rather than through the environment is that the answer is
// typed, unbounded and unreadable by every other process in the jail.
fn call_plan(call: fn() -> Call) -> Result(CapPlan, CapDenial) {
  Ok(ServedHere(fn() { framing.CapOk(value: call_value(call())) }))
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
