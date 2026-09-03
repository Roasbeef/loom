//// The session's extension satellites, held open and handed out.
////
//// `client/extension/dispatch` turns an install record into `tools.Tool`
//// values; this module owns the *nodes* those tools run on. One actor per
//// session keeps at most one `codemode/satellite.Host` per installed
//// extension, starts it lazily on that extension's first use, and stops
//// every one of them when the session ends.
////
//// # Why a node per session rather than a node per call
////
//// Phase 2 launched a jailed `erl` for every tool call and destroyed it on
//// the way out. That was ADR-007's accepted cost and it is what
//// `protocol-change/012` removes: an extension's artifact is compiled once
//// at install, so a call was paying a node boot for nothing, and an
//// extension could keep no state at all between calls — no client, no
//// cache, no actor. A host launched once and asked many times fixes both.
////
//// # What a session-lived node is *not* allowed to do
////
//// Nothing about holding a node open widens it. The satellite host mints a
//// token per invocation and revokes it on the answer, so an extension may
//// compute between invocations and may not act; that rule lives in
//// `codemode/satellite` and this module neither relaxes nor restates it.
//// What this module owns is the two facts above that rule:
////
//// - **when a node is launched.** On first use, under the coordinates of
////   the call that happened to be first. A host's environment, workspace
////   and base policy are therefore that call's, which is sound because
////   every extension call in a session runs under one workspace and one
////   session base; a host is not re-launched to pick up a later call's.
//// - **when a node is gone for good.** A host the satellite lost — a
////   deadline it ignored, a frame that correlated to nothing — is
////   `Departed` for the rest of the session, reported once, and every
////   later call on that extension is `Gone`. Restarting one silently would
////   hand the extension a fresh set of the actors it just lost without
////   telling anybody it had lost them.
////
//// # Serialisation
////
//// The protocol allows one outstanding `hook_call` per satellite, so
//// invocations of one extension have to queue somewhere. They queue here:
//// the actor performs the invocation itself, so its mailbox *is* the
//// queue and a second caller waits rather than reading `Busy`.
////
//// That makes the actor a session-wide serialiser rather than a
//// per-extension one, which is a deliberate simplification and worth
//// naming. An extension tool is `tool.Exclusive`, so the model cannot have
//// two running at once on a strand, and hook events fire on a serialised
//// timeline; the case the simplification costs is two *different*
//// extensions invoked from two strands at the same moment, where the
//// second waits for the first. A per-extension lease would fix it and is
//// the shape to reach for when that case is measured rather than
//// imagined.

import broker/exec.{type EnforcementDemand}
import broker/framing
import broker/policy.{type SandboxPolicy}
import client/extension/hooks
import codemode/enforcement
import codemode/satellite
import core/ids.{type OpId}
import core/msgpack.{type MsgPackValue}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import runtime/internal/ffi_sup

/// How long the actor is given to stop every host it holds.
pub const default_stop_timeout_ms = 30_000

/// Why an invocation produced no value.
///
/// The vocabulary a hook bus reads, and deliberately smaller than
/// `satellite.InvokeError`: what a caller does about a failure depends on
/// whether the extension answered (`Unhandled`, `Refused`), died mid-answer
/// (`Crashed`), ran out of time (`Deadline`), or is not there any more
/// (`Gone`) — and not on which of the host's internal endings produced the
/// last of those.
pub type HookFailure {
  /// The extension registered no handler for this event. An ordinary
  /// answer: an extension is offered every moment and cares about few.
  Unhandled

  /// The extension refused, in band, with this message.
  Refused(message: String)

  /// The extension's handler died mid-answer, with this reason. The
  /// satellite survives; the invocation does not.
  Crashed(reason: String)

  /// The invocation passed its deadline. The satellite has been destroyed
  /// and every later call on this extension is `Gone`.
  Deadline

  /// The extension has no satellite for the rest of this session.
  Gone(reason: String)
}

/// Where an invocation sits: the coordinates its effects clear under and
/// the workspace its node lives in.
///
/// One record rather than seven parameters because the two callers fill it
/// from different places — a tool dispatch from `tool.Ctx`, a hook from
/// the strand the event fired on — and a positional signature they both
/// have to get right is one either can get wrong silently.
pub type Coordinates {
  Coordinates(
    /// The operation this invocation's clearances run under.
    op_id: OpId,
    /// The step within it.
    step_id: String,
    /// The strand, for attribution.
    strand: String,
    /// The workspace the node's jail is rooted at.
    workspace: String,
    /// The session base policy this invocation's effects compose onto.
    base_policy: SandboxPolicy,
    /// Enforcement strictness for this invocation's jailed effects.
    demand: EnforcementDemand,
    /// The allowlist-constructed child environment.
    env: List(#(String, String)),
  )
}

/// One installed extension as this actor knows how to run it: the artifact
/// to boot and the two functions that turn a call's coordinates into a
/// launch and into the terms one invocation is judged under.
///
/// Functions rather than values because both depend on the call: a host is
/// launched under the coordinates of whichever call was first, and an
/// invocation is judged under its own. `client/serve` builds these from
/// the same install record and the same `client/codemode` configuration
/// that `dispatch` builds a tool from, so a host and a tool cannot end up
/// describing different extensions.
pub type Extension {
  Extension(
    /// The manifest's extension name — the key every caller names.
    name: String,
    /// Launches this extension's satellite under these coordinates, or
    /// says why it cannot be launched at all.
    ///
    /// One function rather than an artifact, a configuration and a
    /// launcher, because all three depend on the call that happened to be
    /// first — the workspace its node is rooted at, the environment it is
    /// given, the enforcement demanded of it — and a caller holding them
    /// apart could compose a node from one call's policy and another's
    /// jail.
    start: fn(Coordinates) -> Result(satellite.Host, String),
    /// What one invocation under these coordinates is judged under.
    invoking: fn(Coordinates) -> satellite.Invoking,
  )
}

/// The seam a caller reaches the session's hosts through: one function,
/// closed over the actor's registered name.
///
/// Closed over the *name* rather than a subject for the reason
/// `client/scratch.seam` is: the seam is built while the registry is
/// assembled and the actor starts later, under a supervisor, so a captured
/// subject would go stale the first time it restarted.
pub type Hosts {
  Hosts(
    invoke: fn(String, satellite.Invocation, MsgPackValue, Coordinates, Int) ->
      Result(MsgPackValue, HookFailure),
  )
}

/// What the actor is asked. Opaque: a caller reaches it through `seam`,
/// never by building a message, so there is one place that decides what a
/// wedged or absent host actor answers.
pub opaque type Message {
  Invoke(
    extension: String,
    invocation: satellite.Invocation,
    args: MsgPackValue,
    at: Coordinates,
    deadline_ms: Int,
    reply_with: Subject(Result(MsgPackValue, HookFailure)),
  )

  /// Stop every host, reporting what each node's teardown found. The
  /// session's end, and the only thing that reaps a healthy node.
  StopAll(reply_with: Subject(List(#(String, enforcement.Report))))
}

/// Whether this extension has a satellite, and if not, why not.
type Held {
  /// A live host, launched under the coordinates of the call that was
  /// first to need it.
  Live(host: satellite.Host)

  /// The satellite is gone, with the reason and what the kernel enforced
  /// on the node before it went. Recorded rather than forgotten so the
  /// reason is told the same way every time, and so the node's report
  /// survives to be handed out at session end like a live host's.
  Departed(reason: String, report: enforcement.Report)
}

type State {
  State(known: List(Extension), held: Dict(String, Held))
}

/// Starts the session's host registry under `name`.
///
/// Starts no satellite: every host is launched on its extension's first
/// use, because a host launched at boot would pay for extensions the
/// session never calls.
///
/// ## Examples
///
/// ```gleam
/// // hosts.start(name, extensions)
/// ```
///
pub fn start(
  name: Name(Message),
  extensions: List(Extension),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new(State(known: extensions, held: dict.new()))
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

/// The registry as a supervisable child, which is how a session wires it.
///
/// A restart loses every host, and that is within the contract rather than
/// a gap in it: a lost host is `Gone` to its next caller, which is the same
/// answer a satellite that died would have produced, and the extension's
/// tools go on being registered and go on refusing in band.
pub fn supervised(
  name: Name(Message),
  extensions: List(Extension),
) -> supervision.ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(name, extensions) })
}

/// Stops every host the registry holds, reaping their nodes and handing
/// back what the kernel enforced on each.
///
/// The deliberate teardown, for a host that wants the reports. It is
/// **not** what `client/serve`'s shutdown does: the service supervisor
/// stops this actor, the satellite host machines die with it by link,
/// and the launcher's janitor reaps each node — so the nodes go either
/// way and only their enforcement reports are lost on that path. Wiring
/// this into the shutdown would buy those reports, and it is left undone
/// rather than half-done, because a shutdown that first waited out an
/// invocation in flight is a different decision from the one the grace
/// currently makes.
///
/// A registry that is not running, or does not answer, leaves the nodes
/// to that same janitor.
pub fn stop(name: Name(Message), timeout_ms timeout_ms: Int) -> Nil {
  case process.named(name) {
    Error(Nil) -> Nil
    Ok(pid) -> {
      let reply = process.new_subject()
      ffi_sup.send_to_pid(pid, #(name, StopAll(reply_with: reply)))
      let _reports = process.receive(reply, timeout_ms)
      Nil
    }
  }
}

/// The invocation seam over the registry named `name`.
///
/// ## Examples
///
/// ```gleam
/// // hosts.seam(name, timeout_ms: 5000).invoke("web_search", ...)
/// ```
///
pub fn seam(name: Name(Message), margin_ms margin_ms: Int) -> Hosts {
  Hosts(invoke: fn(extension, invocation, args, at, deadline_ms) {
    ask(name, margin_ms + deadline_ms, fn(reply) {
      Invoke(
        extension:,
        invocation:,
        args:,
        at:,
        deadline_ms:,
        reply_with: reply,
      )
    })
  })
}

/// The seam a session with no extension registry hands out: every
/// invocation refuses in band, naming the reason.
pub fn none() -> Hosts {
  Hosts(invoke: fn(_extension, _invocation, _args, _at, _deadline) {
    Error(Gone("this session runs no extension host registry"))
  })
}

/// Invokes one extension tool or event, by name.
///
/// ## Examples
///
/// ```gleam
/// // hosts.invoke(hosts, "web_search", satellite.Tool("search"), args, at, 30_000)
/// ```
///
pub fn invoke(
  hosts: Hosts,
  extension extension: String,
  invocation invocation: satellite.Invocation,
  args args: MsgPackValue,
  at at: Coordinates,
  within deadline_ms: Int,
) -> Result(MsgPackValue, HookFailure) {
  hosts.invoke(extension, invocation, args, at, deadline_ms)
}

/// The bus's `Invoker` over this registry: extension, event, arguments,
/// deadline in — the extension's answer or a `hooks.HookFailure` out.
///
/// The bus's type carries no coordinates, which is right: a hook fires on
/// the harness's own timeline rather than inside a model-made tool call,
/// so there is no run whose `{op_id, step_id}` it could borrow. `at` is
/// therefore the session's, closed over here — one operation for every
/// hook this session fires, which is the operation a hook's capability
/// token is bound to and the ledger its effects clear against.
///
/// # The contract this satisfies, by construction
///
/// `hooks.Invoker` requires two things of every implementation, because
/// the bus's manager is linked to the host and the `context` and
/// `tool_result` folds call it directly on the strand driver with nothing
/// between.
///
/// **It returns inside `deadline_ms`.** The satellite host arms the
/// invocation's deadline as the state timeout of the `Answering` state it
/// belongs to, so a satellite that does not answer is cut off by weft
/// rather than waited on; `ask` here adds its own bounded wait over that,
/// against a registry that is wedged rather than merely slow. And a
/// satellite destroyed by a deadline is `Departed` for the session, so
/// every later call on it answers `Gone` from memory without a round trip
/// at all.
///
/// **It never raises.** Every step is a `Result`: `ask` degrades an
/// absent, dead or silent registry to `Gone` rather than exiting its
/// caller — `process.call` would exit, which is exactly the failure mode
/// the strand driver must not meet — and `settle` maps every
/// `satellite.InvokeError` and every in-band code onto one of the bus's
/// five variants.
///
/// ## Examples
///
/// ```gleam
/// // hooks.Extension(name:, events:, invoke: hosts.invoker(hosts, at: at))
/// ```
///
pub fn invoker(hosts: Hosts, at at: Coordinates) -> hooks.Invoker {
  fn(extension, event, args, deadline_ms) {
    invoke_event(hosts, extension:, event:, args:, at:, within: deadline_ms)
    |> result.map_error(bus_failure)
  }
}

// This registry's vocabulary in the bus's five variants.
//
// The bus's `Gone` carries no reason and this one does, which is the
// right way round: a model reading a tool reply needs to know *why* an
// extension is unavailable, and the bus logs its own reason from
// `hooks.describe` beside the extension's name.
fn bus_failure(failure: HookFailure) -> hooks.HookFailure {
  case failure {
    Unhandled -> hooks.Unhandled
    Refused(message:) -> hooks.Refused(reason: message)
    Crashed(reason:) -> hooks.Crashed(reason:)
    Deadline -> hooks.Deadline
    Gone(..) -> hooks.Gone
  }
}

/// Fires one hook event at one extension. The function `invoker` wraps.
///
/// `Unhandled` is the ordinary answer for an extension that registers no
/// handler for this event, and is not a failure to report: the bus asks
/// every installed extension and most of them care about none of the
/// moments on offer.
///
/// ## Examples
///
/// ```gleam
/// // hosts.invoke_event(hosts, extension: "web_search",
/// //   event: "session_start", args: payload, at: at, within: 5000)
/// ```
///
pub fn invoke_event(
  hosts: Hosts,
  extension extension: String,
  event event: String,
  args args: MsgPackValue,
  at at: Coordinates,
  within deadline_ms: Int,
) -> Result(MsgPackValue, HookFailure) {
  invoke(
    hosts,
    extension:,
    invocation: satellite.Event(name: event),
    args:,
    at:,
    within: deadline_ms,
  )
}

// --- the actor ------------------------------------------------------------

fn handle(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Invoke(extension:, invocation:, args:, at:, deadline_ms:, reply_with:) ->
      serve_invoke(
        state,
        extension,
        invocation,
        args,
        at,
        deadline_ms,
        reply_with,
      )

    StopAll(reply_with:) -> {
      process.send(reply_with, reap(state))
      actor.continue(State(..state, held: dict.new()))
    }
  }
}

// One invocation, performed on the actor's own timeline.
//
// Blocking here is the design rather than an oversight: the actor's
// mailbox is the queue the protocol's one-slot rule needs, so a second
// caller waits instead of reading `Busy`. See the module doc for what that
// costs.
fn serve_invoke(
  state: State,
  extension: String,
  invocation: satellite.Invocation,
  args: MsgPackValue,
  at: Coordinates,
  deadline_ms: Int,
  reply: Subject(Result(MsgPackValue, HookFailure)),
) -> actor.Next(State, Message) {
  case ready(state, extension, at) {
    Error(#(state, failure)) -> {
      process.send(reply, Error(failure))
      actor.continue(state)
    }
    Ok(#(state, entry, host)) -> {
      let answer =
        satellite.invoke(
          host,
          invocation,
          args,
          entry.invoking(at),
          deadline_ms,
        )
      process.send(reply, settle(answer))
      actor.continue(depart_if_lost(state, extension, host, answer))
    }
  }
}

// The host for `extension`, starting one if this is its first use. The
// entry travels back with it because the caller needs its `invoking` and
// looking it up twice would be two chances to find two different rows.
fn ready(
  state: State,
  extension: String,
  at: Coordinates,
) -> Result(#(State, Extension, satellite.Host), #(State, HookFailure)) {
  case known(state, extension), dict.get(state.held, extension) {
    Error(Nil), _ ->
      Error(#(
        state,
        Gone("no extension named " <> extension <> " is installed here"),
      ))
    Ok(entry), Ok(Live(host:)) -> Ok(#(state, entry, host))
    Ok(_entry), Ok(Departed(reason:, ..)) -> Error(#(state, Gone(reason)))
    Ok(entry), Error(Nil) -> launch(state, entry, at)
  }
}

fn launch(
  state: State,
  entry: Extension,
  at: Coordinates,
) -> Result(#(State, Extension, satellite.Host), #(State, HookFailure)) {
  case entry.start(at) {
    // A launch that failed left no node, so there is no report to keep.
    Error(reason) ->
      Error(#(
        depart(
          state,
          entry.name,
          reason,
          enforcement.Unreported("no node was launched"),
        ),
        Gone(reason),
      ))
    Ok(host) ->
      Ok(#(
        State(..state, held: dict.insert(state.held, entry.name, Live(host:))),
        entry,
        host,
      ))
  }
}

fn known(state: State, extension: String) -> Result(Extension, Nil) {
  list.find(state.known, fn(entry) { entry.name == extension })
}

// A host the satellite lost is gone for the session, and the reason is
// kept so it is told the same way every time rather than re-derived.
//
// `satellite.stop` is called on the way out even though the host has
// already destroyed its own node. It is idempotent — the machine hands
// back the report it kept from that teardown — and it is what stops the
// machine process, so a session that lost three extensions does not
// carry three `Destroyed` machines to the end of it. The report it
// returns is the node's own account of what confined it, and it goes in
// the ledger rather than into the garbage.
fn depart_if_lost(
  state: State,
  extension: String,
  host: satellite.Host,
  answer: Result(framing.CapOutcome, satellite.InvokeError),
) -> State {
  case answer {
    Error(satellite.InvocationDeadline) ->
      reaped(
        state,
        extension,
        host,
        "an invocation passed its deadline, so the satellite was destroyed; "
          <> "this extension is unavailable for the rest of this session",
      )
    Error(satellite.HostGone(reason:)) -> reaped(state, extension, host, reason)
    Error(satellite.HostFaulted(reason:)) ->
      reaped(
        state,
        extension,
        host,
        "the capability channel faulted: " <> reason,
      )

    // `Busy` cannot reach here — this actor is the queue — and an answered
    // invocation leaves the host exactly as it found it.
    Error(satellite.Busy) | Ok(_) -> state
  }
}

fn reaped(
  state: State,
  extension: String,
  host: satellite.Host,
  reason: String,
) -> State {
  depart(state, extension, reason, satellite.stop(host))
}

fn depart(
  state: State,
  extension: String,
  reason: String,
  report: enforcement.Report,
) -> State {
  State(
    ..state,
    held: dict.insert(state.held, extension, Departed(reason:, report:)),
  )
}

// What the satellite answered, in the vocabulary a hook bus reads.
//
// The codes are `ext/runtime`'s and `cap/runtime`'s, which is the other
// half of this contract: a code neither of them mints reaches a caller as
// `Refused`, which is the safe reading — something went wrong and the
// extension said what.
fn settle(
  answer: Result(framing.CapOutcome, satellite.InvokeError),
) -> Result(MsgPackValue, HookFailure) {
  case answer {
    Ok(framing.CapOk(value:)) -> Ok(value)
    Ok(framing.CapErr(code: "unhandled", message: _)) -> Error(Unhandled)
    Ok(framing.CapErr(code: "crashed", message:)) -> Error(Crashed(message))
    Ok(framing.CapErr(code: _, message:)) -> Error(Refused(message))
    Error(satellite.InvocationDeadline) -> Error(Deadline)
    Error(satellite.Busy) ->
      Error(Refused(
        "the satellite was already answering an invocation; this host "
        <> "serialises, so that is a bug rather than contention",
      ))
    Error(satellite.HostGone(reason:)) -> Error(Gone(reason))
    Error(satellite.HostFaulted(reason:)) ->
      Error(Gone("the capability channel faulted: " <> reason))
  }
}

// Every node this session stood up, and what the kernel enforced on it:
// the live ones stopped here, the departed ones from the report kept when
// they went. A departed extension is in the ledger too, because "we ran a
// node for it and here is its jail" is the same fact whether the node
// outlived the session or not.
fn reap(state: State) -> List(#(String, enforcement.Report)) {
  dict.to_list(state.held)
  |> list.map(fn(entry) {
    case entry.1 {
      Live(host:) -> #(entry.0, satellite.stop(host))
      Departed(report:, ..) -> #(entry.0, report)
    }
  })
}

// One question to the registry, degrading an absent or wedged actor to an
// in-band refusal rather than to the caller's death. `process.call` exits
// its caller on a timeout or a dead callee, and this runs on a strand's
// own process inside a live run, so the failure mode that must not happen
// is exactly the one `call` has.
fn ask(
  name: Name(Message),
  timeout_ms: Int,
  build: fn(Subject(Result(MsgPackValue, HookFailure))) -> Message,
) -> Result(MsgPackValue, HookFailure) {
  case process.named(name) {
    Error(Nil) -> Error(Gone("the extension host registry is not running"))
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      let selector =
        process.new_selector()
        |> process.select_map(reply, Answered)
        |> process.select_specific_monitor(monitor, RegistryDied)
      ffi_sup.send_to_pid(pid, #(name, build(reply)))
      let answer = case process.selector_receive(selector, timeout_ms) {
        Ok(Answered(answer:)) -> answer
        Ok(RegistryDied(..)) ->
          Error(Gone("the extension host registry died mid-invocation"))
        // Not a departed satellite: the registry serialises, so this is
        // most likely a caller queued behind an invocation that is still
        // running. The reason says so rather than telling the model an
        // extension is out for the session when it is not.
        Error(Nil) ->
          Error(Gone(
            "the extension host registry did not answer in time; another "
            <> "invocation is still holding it",
          ))
      }
      process.demonitor_process(monitor)
      answer
    }
  }
}

// What a caller of `ask` selects on.
type Asked {
  Answered(answer: Result(MsgPackValue, HookFailure))
  RegistryDied(down: process.Down)
}
