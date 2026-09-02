//// The extension hook bus: one `weft/event_manager` per session, one
//// handler per installed extension that declares a `[[hook]]`.
////
//// Phase 1 gave an extension tools. A tool is something the *model*
//// asked for, and the harness answers it by launching a satellite. A
//// hook is the other direction: it fires on the harness's own timeline
//// — a run was accepted, a call was planned, a reply settled — and the
//// extension has to be told. `protocol-change/012` adds the frame that
//// carries the telling; this module is the harness side of it, and it
//// is deliberately the *only* place that knows an extension can be
//// asked anything.
////
//// ## Why a `weft/event_manager` and not a fan-out written here
////
//// The shape the design note names is gen_event's exactly: an ordered
//// list of subscribers, each holding private state (its name, the
//// events it declared, its invoker, how many times it has declined),
//// receiving every event in load order, with a broken one dropped and
//// logged while its siblings carry on. `weft/event_manager` is the
//// typed binding of that, and the state each handler keeps is sealed in
//// its own closure, so two extensions with unrelated state still share
//// one list. Writing the fan-out here would be a hand-rolled copy of a
//// weft primitive, which is a review finding rather than a shortcut.
////
//// The manager's own limit is the intended semantics: a handler stalls
//// the bus for as long as its round trip takes, and the per-call
//// deadline is what bounds that.
////
//// ## Five events fan out; two transforms do not
////
//// `session_start`, `before_agent_start`, `tool_call`, `agent_end` and
//// `agent_settled` are bus events. The notifications go through
//// `notify`. The two that need an answer — `before_agent_start`, whose
//// answer is an injection, and `tool_call`, whose answer is a verdict —
//// go through `sync_notify` carrying a reply subject, and the caller
//// drains the subject after the fan-out has returned. `sync_notify`
//// replies only once every handler has finished, so a drain with a zero
//// timeout is exact rather than a race.
////
//// `context` and `tool_result` are **not** bus events, because each
//// extension must see its predecessor's output. They are folds —
//// `fold_context` and `fold_tool_result` — over the same ordered list,
//// run on the caller's process, which is the strand driver. There is no
//// worker between the driver and the invoker there, so the fold's
//// liveness *is* the invoker's: an `Invoker` must return inside
//// `deadline_ms` and must never raise, and its own documentation is
//// where that contract is written down.
////
//// A fold that fails an extension cannot remove that extension's
//// handler from the manager (the list lives in another process), so it
//// discards that one transform and logs; the next bus event the
//// extension mishandles drops it for good. Two planes, one ordering,
//// and the divergence is written down here rather than discovered.
////
//// The standing cost of that is one `Gone` per request, per dropped
//// extension, for the rest of the session: the chain is not mutated, so
//// a fold keeps asking a satellite that is not there. It is an
//// immediate answer rather than a round trip — the host knows its
//// satellite is gone without asking it — so it costs a function call
//// and a log line, not a deadline. `Gone` is therefore logged at debug
//// in the folds while `Crashed`, `Deadline` and a refusal stay at warn:
//// the first is a fact the bus already reported once, and the others
//// are news.
////
//// ## `agent_settled` has no producer in this wave
////
//// The event exists on the bus and an extension may declare it, but
//// nothing in the harness notifies it yet: "the run and every follow-up
//// it queued are done" has no signal in `runtime` — `api.await_strand_result`
//// answers for one run, and the follow-up queue is the planner's own
//// state with no terminal edge to hang this on. Faking it from
//// `agent_end` would be a lie an extension author could not detect, so
//// registration logs `extension.hook.inert` for a declaration of it and
//// the divergence is recorded in the design note's table.
////
//// ## The wire, once, here
////
//// Every payload crosses as **a msgpack string holding JSON**, the way
//// `cap/ext` carries a tool call's arguments and for the same reason:
//// the extension seam admits `gleam/json` and no msgpack decoder, so
//// text is the only shape both ends can read. `args` is what the
//// harness sends in a `hook_call`; `value` is what comes back in the
//// `hook_result`.
////
//// ```
//// session_start        args {}
////                      value ignored
//// before_agent_start   args {"op_id": str, "strand": str}
////                      value {"inject": str | null}
//// context              args {"op_id": str, "messages": [message, …]}
////                      value {"messages": [message, …]}
//// tool_call            args {"op_id": str, "tool": str,
////                            "arguments": json, "source_index": int}
////                      value {"verdict": "allow"}
////                          | {"verdict": "block", "reason": str}
//// tool_result          args {"message": message}
////                      value {"message": message}
//// agent_end            args {"op_id": str}
////                      value ignored
//// agent_settled        args {"op_id": str}
////                      value ignored
//// ```
////
//// A `message` is `core/codec.encode_message`'s JSON, the durable
//// conversation format, decoded back through `core/codec.decode_message`.
//// Reusing it rather than inventing a hook-only shape means an
//// extension reads the same document the store holds, and a transform
//// that does not decode is discarded by a total decoder rather than
//// half-applied.
////
//// ## What a hook may not do
////
//// The `context` transform's only bound is the token allowance, and that
//// is the whole of what the ruling gives it. A context hook may drop
//// messages, reorder them or add its own, and the harness does not
//// second-guess any of it — a hook installed to remove a section of the
//// transcript is doing exactly what a context hook is for, and a floor
//// or an attribution rule here would be policy this design has not
//// made. What bounds it is the install: a context hook is an operator's
//// approval of an extension's whole authority over a request, recorded
//// in the install record.
////
//// A `tool_call` hook may block a call and may not rewrite its
//// arguments: a hook that edited arguments after clearance is the one
//// thing vetting cannot see. A `tool_result` hook may transform the
//// reply's *content* and nothing else, and that is obtained by
//// construction: what is committed is the original reply with the
//// hook's content substituted, so `is_error`, the usage, the timestamp
//// and the call's coordinates are the harness's whatever the hook
//// answered with. An answer that is not a tool reply at all is
//// discarded whole.

import client/extension/manifest
import client/notes
import core/clock.{type Clock}
import core/codec
import core/ids.{type OpId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import runtime/effects.{type Effects}
import runtime/hooks as runtime_hooks
import session/session.{type Session}
import telemetry/field
import telemetry/log.{type Logger}
import weft
import weft/actor
import weft/event_manager.{type Handler}

/// How long a hook invocation may take before the harness stops waiting.
///
/// The manifest has no per-hook timeout to read: `[[hook]]` carries an
/// event and an entry and nothing else, and adding a key would be a
/// change to a ruled surface for a number no author has yet wanted to
/// set. Five seconds is the bound a hook is written against, and it is
/// the same order as a tool's default: long enough for a satellite round
/// trip and a decode, short enough that a stalled extension does not
/// read to an operator as a hung session.
pub const deadline_ms = 5000

/// How many tokens a `context` transform may add to the projection it
/// was given.
///
/// A cap of zero would refuse the only thing a context hook is for. An
/// unbounded one would let an extension spend the session's whole
/// window on the harness's behalf, silently, on every request. The
/// allowance is counted with `runtime/hooks.estimate_message`, the same
/// estimate the compaction threshold is decided with, so a hook and the
/// threshold cannot disagree about what a message costs.
pub const context_growth_tokens = 2000

// --- what wave A hands us -------------------------------------------------

/// Why an extension did not answer a hook.
///
/// The three at the bottom are fatal to the extension: a satellite that
/// is gone, one that crashed inside the answer, and one that slept past
/// its deadline are all satellites the harness has stopped being able to
/// trust with a session's worth of state. The two at the top are not:
/// an event the extension never declared, and one it declined, are
/// ordinary answers.
pub type HookFailure {
  /// The extension does not handle this event. Never reaches the wire —
  /// the bus checks the declared list before it calls.
  Unhandled

  /// The extension declined to answer, in band, with a reason.
  Refused(reason: String)

  /// The extension's body raised while answering.
  Crashed(reason: String)

  /// The deadline passed with no `hook_result`. The satellite is
  /// destroyed by its host; the handler is dropped here.
  Deadline

  /// There is no satellite to ask any more.
  Gone
}

/// The seam onto the persistent satellite host: extension name, event
/// name, arguments, deadline, in — the extension's answer or a failure,
/// out.
///
/// A function rather than a direct call into the host so that this
/// module is testable without a satellite, and so that the host's own
/// module (`client/extension/hosts`, phase 3 wave A) can be swapped in
/// at one place. The four positional arguments are the `hook_call`
/// frame's own fields, in the frame's order.
///
/// **An invoker must return inside `deadline_ms`, and must never
/// raise.** Both halves are load-bearing and neither is checked here,
/// because neither can be. A handler runs *in the manager's process*,
/// which is linked to the process that started the bus and has no
/// rescue — Gleam has no exception handling, so `weft/event_manager`
/// isolates a handler that says it is `Failed` and cannot isolate one
/// that raises. And `fold_context`/`fold_tool_result` call an invoker
/// directly on the strand driver, with no worker between them, so an
/// invoker that blocks forever blocks that strand. The failure
/// vocabulary exists so that neither has to happen: a satellite that is
/// gone, has crashed or has overslept is a `Gone`/`Crashed`/`Deadline`
/// *value*, and the host is the thing that turns a dead process and an
/// expired timer into one. `client/extension/hosts.invoke_event` is
/// held to this contract.
pub type Invoker =
  fn(String, String, MsgPackValue, Int) -> Result(MsgPackValue, HookFailure)

/// The invoker a server has before the persistent satellite host is
/// wired: every call fails with `Gone`.
///
/// Phase 3 is built in two halves. This half — the bus, the runtime
/// slots, the manifest and the record — knows how to ask an extension a
/// question; the other half owns the satellite that answers. Until the
/// two are joined, an honest server says the satellite is not there
/// rather than pretending an extension declined, so the first event
/// drops the handler with a reason an operator can read. Joining them is
/// replacing this one call with `client/extension/hosts.invoke_event`.
///
/// ## Examples
///
/// ```gleam
/// assert hooks.unwired()("web_search", "tool_call", msgpack.NilValue, 0)
///   == Error(hooks.Gone)
/// ```
///
pub fn unwired() -> Invoker {
  fn(_extension, _event, _args, _deadline_ms) { Error(Gone) }
}

/// One installed extension as the bus sees it: the name refusals are
/// attributed to, the events its manifest declared, and the way to reach
/// it.
pub type Extension {
  Extension(
    /// The manifest name. Appears in every refusal an extension causes,
    /// because a blocked tool call with no author named is a dead end
    /// for whoever has to fix it.
    name: String,
    /// The `[[hook]].event` names this extension declared. An event
    /// outside this list is skipped before any call is made, so an
    /// extension is never woken for something it did not ask for.
    events: List(String),
    /// The seam onto its satellite.
    invoke: Invoker,
  )
}

// --- the bus --------------------------------------------------------------

/// What a `tool_call` hook decided.
pub type Verdict {
  /// Nothing to say; the call proceeds.
  Allow

  /// Refuse the call. The reason reaches the model as the in-band error
  /// the driver stages, and the name is carried alongside it because a
  /// refusal nobody is attributed for is one nobody can act on. The name
  /// is stamped here, from the handler's own state, so an extension
  /// cannot claim to be another.
  Block(extension: String, reason: String)
}

/// Text one extension asked to have injected at run start, and whose it
/// is. Only an extension that returned something sends one, so a drained
/// empty subject means every extension had nothing to add.
pub type Injection {
  Injection(extension: String, text: String)
}

/// What the manager fans out.
///
/// The two events carrying a `reply` subject are delivered with
/// `sync_notify`; the caller drains the subject once it returns, when
/// every handler that was going to answer has answered.
pub type Event {
  /// The session's extension hosts are wired. Fires once, at boot.
  SessionStart

  /// A run was accepted, before planning.
  BeforeAgentStart(op_id: OpId, strand: String, reply: Subject(Injection))

  /// A tool call was planned, before dispatch. Arguments are read-only.
  ToolCall(
    op_id: OpId,
    tool: String,
    arguments: JsonValue,
    source_index: Int,
    reply: Subject(Verdict),
  )

  /// A run reached a terminal state.
  ///
  /// Carries the operation and nothing else. pi's event names an
  /// outcome; the slot this rides on (`effects.Hooks.run_end`) is handed
  /// an `OpId` and is asked *before* the terminal transaction commits,
  /// so the harness does not yet know how the run ended. A word invented
  /// here would be one an extension author could not tell from a real
  /// one, so the field is absent rather than fabricated.
  AgentEnd(op_id: OpId)

  /// The run and every follow-up it queued are done. No producer in this
  /// wave; see the module doc.
  AgentSettled(op_id: OpId)
}

/// A running hook bus.
///
/// Holds two views of the same ordered extension list: the manager, for
/// the five fan-out events, and the list itself, for the two chained
/// transforms that are folds rather than a fan-out.
pub opaque type Bus {
  Bus(
    manager: Subject(event_manager.Message(Event)),
    chain: List(Extension),
    logger: Logger,
  )
}

/// Starts a bus over `extensions`, in load order.
///
/// One handler per extension, whatever events it declared: the declared
/// list is checked inside the handler rather than by registering an
/// extension several times, so an extension is one subscriber with one
/// failure story rather than several that can disagree about whether it
/// is still alive.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(bus) = hooks.start([extension], log.discard())
/// ```
///
pub fn start(
  extensions: List(Extension),
  logger: Logger,
) -> Result(Bus, actor.StartError) {
  let described =
    list.fold(extensions, event_manager.new(), fn(builder, extension) {
      event_manager.add(builder, handler_for(extension, logger))
    })
  use started <- result.try(event_manager.start(described))
  Ok(Bus(manager: started.data, chain: extensions, logger:))
}

/// The extensions this bus fans out to, in load order. What a caller
/// asserts on, and what the folds walk.
///
/// ## Examples
///
/// ```gleam
/// // list.map(hooks.extensions(bus), fn(e) { e.name }) == ["web_search"]
/// ```
///
pub fn extensions(bus: Bus) -> List(Extension) {
  bus.chain
}

/// How many handlers the manager still holds. Falls as broken
/// extensions are dropped, which is the observable side of a `Gone`.
///
/// ## Examples
///
/// ```gleam
/// // hooks.subscribers(bus) == 1
/// ```
///
pub fn subscribers(bus: Bus) -> Int {
  event_manager.count_handlers(bus.manager, waiting: deadline_ms)
}

// --- the five fan-out events ----------------------------------------------

/// Notifies `session_start`. Called once, when the session's extension
/// hosts are wired.
///
/// ## Examples
///
/// ```gleam
/// // hooks.session_start(bus)
/// ```
///
pub fn session_start(bus: Bus) -> Nil {
  event_manager.notify(bus.manager, SessionStart)
}

/// Fires `before_agent_start` and renders every returned injection as a
/// run-start message, fenced and attributed to the extension that asked
/// for it.
///
/// The wait is `sync_notify`, so the drain that follows sees every
/// answer and no partial fan-out.
///
/// ## Examples
///
/// ```gleam
/// // hooks.run_start_injections(bus, operation, "main")
/// ```
///
pub fn run_start_injections(
  bus: Bus,
  operation: OpId,
  strand: String,
  now: Int,
) -> List(AgentMessage) {
  fan_out(bus, "before_agent_start", fn(reply) {
    BeforeAgentStart(op_id: operation, strand:, reply:)
  })
  |> list.map(fn(injection) { injected(injection, now) })
}

/// Asks every extension's `tool_call` hook about one planned call.
///
/// Any `Block` wins, and the first one in load order is the reason
/// reported: a call refused by two extensions is refused, and naming
/// both would tell the model nothing it can act on.
///
/// ## Examples
///
/// ```gleam
/// // hooks.gate(bus, operation, "bash", arguments, 0) == hooks.Allow
/// ```
///
pub fn gate(
  bus: Bus,
  operation: OpId,
  tool: String,
  arguments: JsonValue,
  source_index: Int,
) -> Verdict {
  fan_out(bus, "tool_call", fn(reply) {
    ToolCall(op_id: operation, tool:, arguments:, source_index:, reply:)
  })
  |> first_block
}

/// Notifies `agent_end`. A notification only: the follow-up an extension
/// might want is not a thing this event can return, and the existing
/// `run_end` semantics are untouched by it.
///
/// ## Examples
///
/// ```gleam
/// // hooks.agent_end(bus, operation)
/// ```
///
pub fn agent_end(bus: Bus, operation: OpId) -> Nil {
  event_manager.notify(bus.manager, AgentEnd(op_id: operation))
}

/// Notifies `agent_settled`. Nothing in the harness calls this yet; see
/// the module doc on why it is not faked from `agent_end`.
///
/// ## Examples
///
/// ```gleam
/// // hooks.agent_settled(bus, operation)
/// ```
///
pub fn agent_settled(bus: Bus, operation: OpId) -> Nil {
  event_manager.notify(bus.manager, AgentSettled(op_id: operation))
}

// --- the two chained transforms -------------------------------------------

/// Folds every extension's `context` hook over one generation attempt's
/// projected messages, in load order, each seeing its predecessor's
/// output.
///
/// A transform is discarded, and the previous list kept, when the
/// extension fails, when the answer does not decode as a message list,
/// or when it grew the context by more than `context_growth_tokens`.
/// Discarding rather than refusing the request is the right direction:
/// the harness owns the provider call, and an extension that cannot
/// transform a context has no business stopping one.
///
/// ## Examples
///
/// ```gleam
/// // hooks.fold_context(bus, operation, messages) == messages
/// ```
///
pub fn fold_context(
  bus: Bus,
  operation: OpId,
  messages: List(AgentMessage),
) -> List(AgentMessage) {
  use carried, extension <- list.fold(bus.chain, messages)
  let asked =
    ask(extension, manifest.context_event, context_args(operation, carried))
    |> result.try(fn(value) {
      decode_messages(value)
      |> result.map_error(fn(reason) { Crashed(reason) })
    })
    |> result.try(fn(produced) { within_cap(carried, produced) })
  keep(bus, extension, manifest.context_event, carried, asked)
}

/// Folds every extension's `tool_result` hook over a settled reply,
/// before it is committed.
///
/// The reply travels as a whole `ToolResultMessage` rather than as its
/// content alone, because that is the document the store holds and the
/// one `core/codec` can decode totally. What comes back is *narrowed*
/// rather than checked: the committed reply is the original with the
/// hook's content substituted, so a hook may rewrite what the model
/// reads and cannot rewrite whether the call failed, what it cost, or
/// which call it settles.
///
/// ## Examples
///
/// ```gleam
/// // hooks.fold_tool_result(bus, reply) == reply
/// ```
///
pub fn fold_tool_result(bus: Bus, reply: AgentMessage) -> AgentMessage {
  use carried, extension <- list.fold(bus.chain, reply)
  let asked =
    ask(extension, manifest.tool_result_event, tool_result_args(carried))
    |> result.try(fn(value) {
      decode_message(value)
      |> result.map_error(fn(reason) { Crashed(reason) })
    })
    |> result.try(fn(produced) { retexted(carried, produced) })
  keep(bus, extension, manifest.tool_result_event, carried, asked)
}

// Either the transform an extension produced, or the value carried in
// with the reason the transform was dropped logged against the
// extension's name. Shared by both folds because the failure story is
// the same one: a fold cannot remove a handler from the manager's list
// (that list lives in another process), so the extension keeps its place
// here and loses it at the next bus event it mishandles.
fn keep(
  bus: Bus,
  extension: Extension,
  event: String,
  carried: value,
  asked: Result(value, HookFailure),
) -> value {
  case asked {
    Ok(produced) -> produced

    Error(Unhandled) -> carried

    // A satellite that is already gone answers `Gone` to every later
    // request, because a fold does not mutate the chain. The bus warned
    // once when it dropped the handler; repeating that warning on every
    // provider request would bury the line that mattered, so this one is
    // a debug note.
    Error(Gone) -> {
      log.debug(bus.logger, "extension.hook.absent", [
        field.ident(key: "extension", value: extension.name),
        field.ident(key: "event", value: event),
        field.text(key: "reason", value: describe(Gone)),
      ])
      carried
    }

    Error(failure) -> {
      log.warn(bus.logger, "extension.hook.discarded", [
        field.ident(key: "extension", value: extension.name),
        field.ident(key: "event", value: event),
        field.text(key: "reason", value: describe(failure)),
      ])
      carried
    }
  }
}

// A transform that grew the context past its allowance is not applied.
// The estimate is `runtime/hooks.estimate_message`, the same one the
// compaction threshold reads, so a hook cannot buy itself room the
// threshold does not know it spent.
fn within_cap(
  before: List(AgentMessage),
  after: List(AgentMessage),
) -> Result(List(AgentMessage), HookFailure) {
  let allowance = tokens(before) + context_growth_tokens
  let spent = tokens(after)
  case spent <= allowance {
    True -> Ok(after)
    False ->
      Error(Refused(
        "the transform is "
        <> int.to_string(spent)
        <> " tokens against an allowance of "
        <> int.to_string(allowance),
      ))
  }
}

fn tokens(messages: List(AgentMessage)) -> Int {
  list.fold(messages, 0, fn(total, message) {
    total + runtime_hooks.estimate_message(message)
  })
}

// What a `tool_result` transform is allowed to have changed, obtained by
// construction rather than by checking: the reply that is committed is
// the *original* with the hook's content substituted, so every other
// field is the harness's whatever the hook answered with.
//
// Checking a field list was the first shape of this and it was wrong in
// a way worth writing down. `is_error` was checked; `usage` was not, and
// a `ToolResultMessage` carrying a usage becomes a durable row in the
// session's ledger (`machine/planner`). A hook that may rewrite what the
// model reads must not be able to write the session's accounting, and a
// rebuild says that once instead of a check saying it per field and
// missing the next one.
fn retexted(
  before: AgentMessage,
  after: AgentMessage,
) -> Result(AgentMessage, HookFailure) {
  case before, after {
    message.ToolResultMessage(..), message.ToolResultMessage(content:, ..) ->
      Ok(message.ToolResultMessage(..before, content:))

    _before, _after ->
      Error(Refused(
        "a tool_result transform answers with the reply it was given, "
        <> "its content changed; this one answered with something else",
      ))
  }
}

// --- handlers -------------------------------------------------------------

// One extension's subscription. The state is the extension plus a count
// of the answers it declined: a decline is an ordinary answer and must
// not drop anybody, but an extension that declines everything is worth
// being able to see, and the count is what a later `RemoveSelf` policy
// would be built from.
type Subscription {
  Subscription(extension: Extension, declined: Int)
}

fn handler_for(extension: Extension, logger: Logger) -> Handler(Event) {
  use state, event <- event_manager.handler(Subscription(
    extension:,
    declined: 0,
  ))
  handle(state, event, logger)
}

fn handle(
  state: Subscription,
  event: Event,
  logger: Logger,
) -> Result(Subscription, String) {
  case event {
    SessionStart ->
      settle(state, manifest.session_start_event, session_start_args(), logger)

    BeforeAgentStart(op_id:, strand:, reply:) ->
      answer(
        state,
        manifest.before_agent_start_event,
        run_start_args(op_id, strand),
        logger,
        fn(value) { forward_injection(state.extension.name, value, reply) },
      )

    ToolCall(op_id:, tool:, arguments:, source_index:, reply:) ->
      answer(
        state,
        manifest.tool_call_event,
        tool_call_args(op_id, tool, arguments, source_index),
        logger,
        fn(value) { forward_verdict(state.extension.name, value, reply) },
      )

    AgentEnd(op_id:) ->
      settle(state, manifest.agent_end_event, settled_args(op_id), logger)

    AgentSettled(op_id:) ->
      settle(state, manifest.agent_settled_event, settled_args(op_id), logger)
  }
}

// A notification: the round trip still happens, because the extension is
// entitled to know, but nothing is read back from it.
fn settle(
  state: Subscription,
  event: String,
  args: JsonValue,
  logger: Logger,
) -> Result(Subscription, String) {
  answer(state, event, args, logger, fn(_value) { Nil })
}

// The shape both kinds of delivery share. An event the extension never
// declared is skipped *before* the call, which is the property that
// keeps a hook bus from waking every satellite on every event.
fn answer(
  state: Subscription,
  event: String,
  args: JsonValue,
  logger: Logger,
  forward: fn(JsonValue) -> Nil,
) -> Result(Subscription, String) {
  case ask(state.extension, event, args) {
    Ok(value) -> {
      forward(value)
      Ok(state)
    }

    // Not declared, or declined in band. Neither is a broken extension,
    // so neither costs it its place in the list.
    Error(Unhandled) -> Ok(state)

    Error(Refused(reason:)) -> {
      log.info(logger, "extension.hook.declined", [
        field.ident(key: "extension", value: state.extension.name),
        field.ident(key: "event", value: event),
        field.text(key: "reason", value: reason),
      ])
      Ok(Subscription(..state, declined: state.declined + 1))
    }

    // Gone, crashed, or past its deadline. The manager drops the handler
    // and logs the reason; the run carries on without this extension for
    // the rest of the session.
    Error(failure) ->
      Error(state.extension.name <> " " <> event <> ": " <> describe(failure))
  }
}

fn forward_injection(
  name: String,
  value: JsonValue,
  reply: Subject(Injection),
) -> Nil {
  case injection_of(value) {
    Ok(Some(text)) -> process.send(reply, Injection(extension: name, text:))

    // Nothing to inject, or an answer that did not decode. A malformed
    // answer to an optional injection is worth no more than a silent
    // one: there is nothing to attribute and nothing to insert.
    Ok(None) | Error(_reason) -> Nil
  }
}

fn forward_verdict(
  name: String,
  value: JsonValue,
  reply: Subject(Verdict),
) -> Nil {
  case verdict_of(name, value) {
    Ok(verdict) -> process.send(reply, verdict)

    // An undecodable verdict is not a block. A gate that fails open is
    // the deliberate direction: the built-in clearance has already run,
    // and an extension whose answers do not parse is a broken extension
    // rather than a policy.
    Error(_reason) -> process.send(reply, Allow)
  }
}

// --- calling an extension -------------------------------------------------

// The one place a `hook_call` is made. The declared-event check sits
// here, above the invoker, so that `Unhandled` means "we did not ask"
// everywhere in this module rather than sometimes meaning "the satellite
// did not recognise it".
fn ask(
  extension: Extension,
  event: String,
  args: JsonValue,
) -> Result(JsonValue, HookFailure) {
  use Nil <- result.try(case list.contains(extension.events, event) {
    True -> Ok(Nil)
    False -> Error(Unhandled)
  })
  let sent = msgpack.StringValue(json.to_string(args))
  use returned <- result.try(extension.invoke(
    extension.name,
    event,
    sent,
    deadline_ms,
  ))
  read(returned)
}

// The answer, as JSON. A `hook_result` that is not a msgpack string, or
// is a string that is not JSON, is the satellite runtime disagreeing
// with this module about the wire — which is a broken extension, not a
// refusal, so it costs the handler its place.
fn read(value: MsgPackValue) -> Result(JsonValue, HookFailure) {
  case value {
    msgpack.StringValue(value: text) ->
      json.parse(text)
      |> result.replace_error(Crashed("the answer was not JSON"))

    _other -> Error(Crashed("the answer was not a msgpack string"))
  }
}

/// A one-line account of a failure, for a log line or a refusal.
///
/// ## Examples
///
/// ```gleam
/// assert hooks.describe(hooks.Deadline) == "it did not answer in time"
/// ```
///
pub fn describe(failure: HookFailure) -> String {
  case failure {
    Unhandled -> "it does not handle this event"
    Refused(reason:) -> "it declined: " <> reason
    Crashed(reason:) -> "it crashed: " <> reason
    Deadline -> "it did not answer in time"
    Gone -> "its satellite is gone"
  }
}

// --- payloads -------------------------------------------------------------

fn session_start_args() -> JsonValue {
  json.Object([])
}

fn run_start_args(operation: OpId, strand: String) -> JsonValue {
  json.Object([
    #("op_id", json.String(ids.op_id_to_string(operation))),
    #("strand", json.String(strand)),
  ])
}

fn tool_call_args(
  operation: OpId,
  tool: String,
  arguments: JsonValue,
  source_index: Int,
) -> JsonValue {
  json.Object([
    #("op_id", json.String(ids.op_id_to_string(operation))),
    #("tool", json.String(tool)),
    #("arguments", arguments),
    #("source_index", json.Int(source_index)),
  ])
}

fn settled_args(operation: OpId) -> JsonValue {
  json.Object([#("op_id", json.String(ids.op_id_to_string(operation)))])
}

fn context_args(operation: OpId, messages: List(AgentMessage)) -> JsonValue {
  json.Object([
    #("op_id", json.String(ids.op_id_to_string(operation))),
    #("messages", json.Array(list.map(messages, codec.encode_message))),
  ])
}

fn tool_result_args(reply: AgentMessage) -> JsonValue {
  json.Object([#("message", codec.encode_message(reply))])
}

// --- reading an answer ----------------------------------------------------

fn injection_of(value: JsonValue) -> Result(Option(String), String) {
  case field(value, "inject") {
    Ok(json.String(value: text)) if text != "" -> Ok(Some(text))
    Ok(json.Null) | Error(_absent) -> Ok(None)
    Ok(_other) -> Error("inject is neither a non-empty string nor null")
  }
}

fn verdict_of(name: String, value: JsonValue) -> Result(Verdict, String) {
  case field(value, "verdict") {
    Ok(json.String(value: "allow")) -> Ok(Allow)
    Ok(json.String(value: "block")) -> blocked(name, value)
    Ok(_other) | Error(_absent) -> Error("verdict is neither allow nor block")
  }
}

// A block with no readable reason is still a block. Treating it as
// undecodable would fail the gate *open*, which turns an author's empty
// string into a silently disabled hook; the model gets a sentence saying
// the extension said nothing more, which at least names who to ask.
fn blocked(name: String, value: JsonValue) -> Result(Verdict, String) {
  case field(value, "reason") {
    Ok(json.String(value: reason)) if reason != "" ->
      Ok(Block(extension: name, reason:))
    Ok(_other) | Error(_absent) ->
      Ok(Block(extension: name, reason: "it gave no reason"))
  }
}

fn decode_messages(value: JsonValue) -> Result(List(AgentMessage), String) {
  use messages <- result.try(field(value, "messages"))
  case messages {
    json.Array(items:) ->
      list.try_map(items, fn(item) {
        codec.decode_message(item)
        |> result.replace_error("a transformed message did not decode")
      })
    _other -> Error("messages is not an array")
  }
}

fn decode_message(value: JsonValue) -> Result(AgentMessage, String) {
  use encoded <- result.try(field(value, "message"))
  codec.decode_message(encoded)
  |> result.replace_error("the transformed reply did not decode")
}

fn field(value: JsonValue, name: String) -> Result(JsonValue, String) {
  case value {
    json.Object(fields:) ->
      list.key_find(fields, name)
      |> result.map_error(fn(_nil) { "the answer has no " <> name })
    _other -> Error("the answer is not an object")
  }
}

// --- rendering an injection -----------------------------------------------

/// The run-start message one extension's injection becomes: the `[loom]`
/// first line the client already collapses, the prose that says whose
/// text this is and that no reply is expected, and the extension's own
/// text inside a fence naming it.
///
/// The fence is written here rather than by the extension for the reason
/// `system_prompt.render_file` gives about instruction files: only this
/// side knows which extension it read, so only this side can attribute
/// it unforgeably. The framing prose travels with the message rather
/// than in the system prompt, the way `client/rules.injection` and
/// `client/schedule.injection` do, because a session with no extensions
/// should pay nothing for the vocabulary.
///
/// ## Examples
///
/// ```gleam
/// // hooks.injection("web_search", "quota: 3 left")
/// // |> string.contains("<extension name=web_search>")
/// ```
///
pub fn injection(name: String, text: String) -> String {
  "[loom] note from the extension \""
  <> name
  <> "\"\n\n"
  <> "This is text an installed extension asked to have placed at the "
  <> "start of this run. It is not a turn from the user and no reply to "
  <> "it is expected; it is the extension's own words, not your "
  <> "operator's, and it carries no more authority than any other "
  <> "attributed note.\n\n"
  <> "<extension name="
  <> name
  <> ">\n"
  <> text
  <> "\n</extension>"
}

fn injected(one: Injection, now: Int) -> AgentMessage {
  message.UserMessage(
    content: [
      message.UserText(
        text: injection(one.extension, one.text),
        text_signature: None,
      ),
    ],
    timestamp: now,
  )
}

// --- draining a reply subject ---------------------------------------------

// Everything the fan-out sent, in the order it was sent. `sync_notify`
// has already returned, so every handler that was going to send has
// sent, and a zero timeout is exact rather than a guess.
fn drain(reply: Subject(answer), collected: List(answer)) -> List(answer) {
  case process.receive(reply, within: 0) {
    Ok(answer) -> drain(reply, [answer, ..collected])
    Error(Nil) -> list.reverse(collected)
  }
}

fn first_block(verdicts: List(Verdict)) -> Verdict {
  case list.find(verdicts, fn(verdict) { verdict != Allow }) {
    Ok(blocked) -> blocked
    Error(Nil) -> Allow
  }
}

// Every answer one fan-out produced, gathered on a worker process rather
// than on the caller's.
//
// The worker is the whole point, and it is not defensive scaffolding.
// `sync_notify` is a `call`, and a `call` whose callee does not answer in
// time **panics the caller**. The callers here are strand drivers, and
// one `Effects` record serves every strand of a session, so the manager
// is shared: the wait is whatever is queued ahead of this event plus this
// event's own fan-out, and the second term is the only one a chain length
// can bound. A stalled extension has to cost a hook and never a strand,
// so the wait happens inside a weft run whose deadline reaps it and whose
// every unhappy outcome is "nobody answered".
//
// Answering with nothing is the right direction for both callers: no
// injection, and no block on a call the built-in clearance already
// cleared.
fn fan_out(
  bus: Bus,
  event: String,
  build: fn(Subject(answer)) -> Event,
) -> List(answer) {
  let collect = fn() {
    let reply = process.new_subject()
    event_manager.sync_notify(
      bus.manager,
      build(reply),
      waiting: fan_out_ms(bus),
    )
    Ok(drain(reply, []))
  }
  let ran =
    weft.new([collect])
    |> weft.deadline(fan_out_ms(bus) + deadline_ms)
    |> weft.start
  gathered(bus, event, ran)
}

// A one-task run yields exactly one outcome; the impossible shapes are
// answered rather than asserted away, because a wrong account from the
// engine should cost a fan-out and not the driver behind it. Only a
// managed task can lose a drain proof, and this run carries none, so
// those two arms are exhaustiveness rather than cases.
fn gathered(
  bus: Bus,
  event: String,
  outcomes: List(weft.Outcome(List(answer), String)),
) -> List(answer) {
  case outcomes {
    [weft.Completed(value:, ..)] -> value

    [weft.Failed(..)]
    | [weft.Crashed(..)]
    | [weft.Abandoned(..)]
    | [weft.NeverStarted(..)]
    | [weft.DrainProofLost(..)]
    | [weft.CancellationUnconfirmed(..)]
    | []
    | [_, _, ..] -> {
      log.warn(bus.logger, "extension.hook.unanswered", [
        field.ident(key: "event", value: event),
        field.text(
          key: "reason",
          value: "the hook bus did not answer inside its deadline; the "
            <> "event is treated as though every extension had nothing to say",
        ),
      ])
      []
    }
  }
}

// The budget the fan-out itself is given. Every handler may spend the
// per-call deadline, so the manager's own call has to allow all of them
// to, plus one deadline's margin for the decoding between them. It is
// deliberately not the bound the *caller* relies on: queueing behind
// another strand's notification can outlast it, which is exactly why the
// call happens on a worker whose death nobody feels.
fn fan_out_ms(bus: Bus) -> Int {
  { list.length(bus.chain) + 1 } * deadline_ms
}

// --- wiring the bus into a session's effects ------------------------------

/// Composes a bus into a built `Effects` record: the four runtime slots
/// a hook event lands in, wrapped rather than replaced.
///
/// Wrapping is the house pattern for hook composition
/// (`client/notes.digest_hooks`, `client/agency.reaping_hooks`), and it
/// is what lets extensions be added to a session whose hooks are
/// otherwise the production ones. Four slots move:
///
/// - `run_start` gains every extension's `before_agent_start` injection,
///   appended after whatever the harness itself injects;
/// - `run_end` notifies `agent_end` and returns the follow-up the
///   wrapped slot produced, unchanged;
/// - `context` becomes the fold, so the transform is the last thing to
///   touch a request's message list;
/// - `tools.clear` consults the gate *after* the built-in clearance, so
///   an extension is never asked about a call the harness already
///   refused;
/// - `tools.run` folds `tool_result` over the settled reply before the
///   driver commits it.
///
/// ## Examples
///
/// ```gleam
/// // let effects = hooks.wire(wiring.build_effects(config), bus, clock)
/// ```
///
pub fn wire(
  effects: Effects,
  bus: Bus,
  session: Session,
  clock: Clock,
) -> Effects {
  let built = effects.hooks
  let tools = effects.tools
  effects.Effects(
    ..effects,
    hooks: effects.Hooks(
      ..built,
      run_start: fn(operation) {
        list.append(
          built.run_start(operation),
          started(bus, session, clock, operation),
        )
      },
      context: fn(operation, messages) {
        fold_context(bus, operation, built.context(operation, messages))
      },
      run_end: fn(operation) {
        // A notification beside the existing slot, never instead of it:
        // whatever follow-up the harness's own `run_end` was going to
        // place is placed unchanged, and the extensions are merely told.
        let follow_up = built.run_end(operation)
        agent_end(bus, operation)
        follow_up
      },
    ),
    tools: effects.ToolSurface(
      ..tools,
      clear: fn(query: effects.ClearanceQuery) {
        cleared(bus, tools.clear(query), query)
      },
      run: fn(run) { ran(bus, tools.run(run)) },
    ),
  )
}

// The gate, applied to a clearance the harness already granted. A call
// the built-in clearance refused never reaches an extension: asking
// about a call that is not going to run wakes a satellite for nothing
// and invites a second, contradictory reason.
fn cleared(
  bus: Bus,
  clearance: effects.Clearance,
  query: effects.ClearanceQuery,
) -> effects.Clearance {
  case clearance {
    effects.ClearanceRefused(..) -> clearance

    effects.Cleared(..) -> {
      let verdict =
        gate(
          bus,
          query.operation,
          query.call.name,
          query.call.arguments,
          query.source_index,
        )
      refusal(clearance, query.call.name, verdict)
    }
  }
}

// A verdict as the driver's clearance. The driver turns a
// `ClearanceRefused` into the in-band error result the model reads, so
// this sentence is written for the model: which extension, which tool,
// and why.
fn refusal(
  clearance: effects.Clearance,
  tool: String,
  verdict: Verdict,
) -> effects.Clearance {
  case verdict {
    Allow -> clearance
    Block(extension:, reason:) ->
      effects.ClearanceRefused(
        reason: extension <> " blocked " <> tool <> ": " <> reason,
      )
  }
}

// The injections for whichever strand owns this operation. One
// `Effects` record serves every strand of a session, so `run_start` is
// handed an `OpId` and the strand is resolved through the durable
// `op.meta` cell — `client/notes` established the pattern and owns the
// read. An operation whose metadata will not read injects nothing: a run
// is never held up because an extension could not be attributed.
fn started(
  bus: Bus,
  session: Session,
  clock: Clock,
  operation: OpId,
) -> List(AgentMessage) {
  case notes.strand_of(session, operation) {
    Error(Nil) -> []
    Ok(strand) -> {
      let #(now, _clock) = clock.read(clock)
      run_start_injections(bus, operation, strand, now)
    }
  }
}

fn ran(bus: Bus, outcome: effects.ToolOutcome) -> effects.ToolOutcome {
  case outcome {
    effects.ToolCompleted(result:, terminate:) ->
      effects.ToolCompleted(result: fold_tool_result(bus, result), terminate:)

    effects.ToolFailed(..) -> outcome
  }
}
