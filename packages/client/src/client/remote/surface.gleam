//// The orchestrator's side of a remote tool call: the `run` and `recover`
//// functions of a `ToolSurface` whose tools execute on another machine
//// (protocol-change/078, "`ToolSurface.recover`").
////
//// The runtime already makes a call's intent durable before it runs, and it
//// calls `run` on an effect process it can kill. This module turns that call
//// into a `Run` message to the executor's host and waits for the answer. What
//// it adds over a local call is a story for every way the network can fail
//// between the send and the answer.
////
//// ## Attach first, every runtime incarnation
////
//// `attach` mints a fresh random token and sends it with the incarnation. The
//// host makes that token the scope's only valid one. A runtime that restarts
//// without its VM restarting leaves behind effect processes whose `Run`
//// messages may still be in flight, and Erlang orders messages only per sender
//// pair, so a new runtime cannot assume its own messages arrive after the dead
//// one's. The token is what makes order irrelevant: the host compares it by
//// value when it admits a call, so a dead runtime's late `Run` is refused
//// whatever the network did. Recovery follows attach, never the reverse.
////
//// ## Lost connections are repaired by sending again
////
//// A `Run` is idempotent by call key, so re-sending it is the reconciliation
//// step. The surface monitors the executor while it waits. If the connection
//// drops, the surface reconnects with a growing pause between attempts and
//// sends the same `Run` again:
////
//// | The host finds | And so replies |
//// | --- | --- |
//// | the call running | the sender joins its waiters; nothing starts twice |
//// | the call finished | the stored outcome |
//// | the call lost | that the outcome is unknown |
//// | no row | it admits the call, because the first send never arrived |
////
//// Messages lost with a dropped connection are never delivered later, so the
//// last arm cannot double-run a call. There is no timer here: the call's
//// deadline lives on the executor, and the surface keeps reconnecting until the
//// executor answers or the effect process is killed. An abort that happens
//// while the surface is waiting is the death of this process, and the host's
//// monitor turns that into a cancellation.
////
//// `recover` is the same repair for a call whose effect process is gone, after
//// a runtime restart: it asks the ledger what became of the call and re-sends
//// `Run` only when the answer is that the call is still running.
////
//// ## A missing row is not yet an answer
////
//// A dead runtime's effect process may have sent its `Run` just before it was
//// killed, and Erlang orders messages only per sender, so recovery's question
//// can overtake that `Run`. The attach token refuses the stale `Run` if the new
//// runtime attached first, but nothing orders that attach against the `Run`
//// at the host. So a call that must not run twice is recovered with
//// `QueryOrFence`: the host stores "did not start" for a key with no row in the
//// same transaction that found it missing. If the stale `Run` arrived first,
//// the row is `admitted` and recovery waits for it. If the fence arrived
//// first, the stale `Run` finds the key taken and never starts. A call that is
//// safe to run again needs no fence, because the planner replays it under the
//// same key and admission deduplicates the replay against any stale `Run`.

import broker/internal/ffi_crypto
import client/remote/address.{type Address}
import client/remote/owner_port.{type Port}
import client/remote/protocol.{
  type Attached, type HostMessage, type Refusal, type RunAnswer,
}
import client/wiring.{type Authority}
import gleam/erlang/process.{type Subject}
import gleam/list
import machine/operation
import runtime/effects.{type Recovery, type ToolOutcome, type ToolRun}
import weft/poll

/// How an orchestrator reaches one session's scope on an executor.
pub type Config(census) {
  Config(
    /// The executor's host.
    address: Address(census),
    /// The orchestrator session.
    session: String,
    /// The workspace, as the executor names it.
    workspace: String,
    /// The incarnation this runtime attaches under.
    incarnation: Int,
    /// The session's owner port, which the executor calls back and which
    /// reconciles acknowledgements.
    port: Port,
    /// Reads a call's stored authority from the orchestrator's own store.
    read_authority: fn(ToolRun) -> Result(Authority, String),
    /// Makes the connection to the executor again. It is called after a drop,
    /// before each re-send.
    reconnect: fn() -> Result(Nil, String),
    /// The tool names that run on the executor. A call to any other name is
    /// refused instead of being sent.
    remote_tools: List(String),
    /// How long `attach` keeps trying to reach the executor.
    attach_within_ms: Int,
    /// Mints an attach token: thirty-two bytes from a strong source in
    /// production (`strong_token`), a fixed value in a test.
    mint_token: fn() -> BitArray,
  )
}

/// An attached surface: the configuration plus the token this runtime attached
/// with.
pub opaque type Surface(census) {
  Surface(config: Config(census), token: BitArray)
}

/// What a successful attach returns.
pub type Attachment(census) {
  Attachment(
    /// The surface to run and recover through.
    surface: Surface(census),
    /// The census and unacknowledged calls the host reported.
    attached: Attached(census),
  )
}

/// The functions a `ToolSurface` composes for its remote tools.
pub type Functions {
  Functions(
    /// `ToolSurface.run` for a remote tool.
    run: fn(ToolRun) -> ToolOutcome,
    /// `ToolSurface.recover` for a remote tool.
    recover: fn(ToolRun) -> Recovery,
  )
}

// How long an exchange may go on without an answer.
type Patience {
  Forever
  Within(ms: Int)
}

// What the host's side of one exchange did.
type Heard(reply) {
  Replied(reply: reply)
  HostDown
}

// Whether the next attempt can send at once or must repair the connection
// first. The first attempt assumes the connection is up.
type Link {
  Assumed
  Repair
}

// The pause between repair attempts doubles from this to a cap, so a long
// outage costs a few connection attempts and not a few thousand.
const first_pause_ms = 50

const longest_pause_ms = 2000

// How long a `Forever` wait runs one pass of the repair loop before starting
// the next. It is a unit of bookkeeping, not a deadline.
const pass_ms = 60_000

// How long a reconciliation listing may take.
const listing_ms = 10_000

/// Thirty-two bytes from the operating system's strong random source, for an
/// attach token.
///
/// ## Examples
///
/// ```gleam
/// // surface.Config(.., mint_token: surface.strong_token)
/// ```
pub fn strong_token() -> BitArray {
  ffi_crypto.strong_random_bytes(32)
}

/// Attaches this runtime incarnation to its scope on the executor.
///
/// A fresh token replaces whatever the scope held, which fences every request a
/// previous runtime of this session may still have in flight. On success the
/// owner port is told which host it is reconciling against and which calls the
/// executor reported unacknowledged.
///
/// An executor that cannot be reached within `attach_within_ms` is
/// `Unreachable`; the caller decides whether to try again.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(surface.Attachment(surface:, attached:)) = surface.attach(config)
/// ```
pub fn attach(config: Config(census)) -> Result(Attachment(census), Refusal) {
  let token = config.mint_token()
  let owner = owner_port.inbox(config.port)
  let sent =
    exchange(config, Within(config.attach_within_ms), fn(reply) {
      protocol.Attach(
        version: protocol.version,
        session: config.session,
        workspace: config.workspace,
        incarnation: config.incarnation,
        token:,
        owner_port: owner,
        reply:,
      )
    })
  case sent {
    Ok(Ok(attached)) -> {
      let surface = Surface(config:, token:)
      owner_port.bind(config.port, host_link(surface), attached.unacked)
      Ok(Attachment(surface:, attached:))
    }
    Ok(Error(refusal)) -> Error(refusal)
    Error(Nil) ->
      Error(protocol.Unreachable(
        "no answer to the attach within "
        <> "the allowed time; the executor may be down or partitioned",
      ))
  }
}

/// The `run` and `recover` functions to compose into a `ToolSurface`.
///
/// ## Examples
///
/// ```gleam
/// // let surface.Functions(run:, recover:) = surface.functions(attached_surface)
/// ```
pub fn functions(surface: Surface(census)) -> Functions {
  Functions(run: fn(tool_run) { run(surface, tool_run) }, recover: fn(tool_run) {
    recover(surface, tool_run)
  })
}

/// Whether the named tool runs on the executor.
///
/// ## Examples
///
/// ```gleam
/// // surface.places(attached_surface, "bash")
/// ```
pub fn places(surface: Surface(census), tool: String) -> Bool {
  list.contains(surface.config.remote_tools, tool)
}

/// Runs one tool call on the executor and waits for its outcome.
///
/// The call is refused, without being sent, when its tool does not run on the
/// executor or its stored authority cannot be read. After that the wait ends
/// only with an answer from the executor or with the death of the calling
/// process; see the module doc for how lost connections are repaired.
///
/// ## Examples
///
/// ```gleam
/// // surface.run(attached_surface, tool_run)
/// ```
pub fn run(surface: Surface(census), run: ToolRun) -> ToolOutcome {
  let config = surface.config
  case places(surface, run.call.name), config.read_authority(run) {
    False, _ ->
      effects.ToolFailed(
        reason: "the tool `"
        <> run.call.name
        <> "` does not run on this session's executor",
      )
    True, Error(reason) -> effects.ToolFailed(reason:)
    True, Ok(authority) ->
      case sent_run(surface, run, authority) {
        Ok(protocol.RunFinished(outcome:)) -> outcome
        Ok(protocol.RunLost) ->
          effects.ToolFailed(reason: protocol.unknown_outcome_text)
        Ok(protocol.RunRefused(refusal:)) ->
          effects.ToolFailed(reason: protocol.describe(refusal))
        Error(Nil) ->
          effects.ToolFailed(reason: "the executor could not be reached")
      }
  }
}

/// Asks the executor what became of a call whose effect process is gone.
///
/// It assumes `attach` already ran for this runtime incarnation. A call that is
/// safe to replay is looked up, and a missing row means the planner may run it
/// again under the same key. Any other call is looked up with a fence, which
/// is what makes a missing row mean the call never reached the executor and now
/// never can. A call that is still running is waited for by re-sending its
/// `Run`.
///
/// ## Examples
///
/// ```gleam
/// // surface.recover(attached_surface, tool_run)
/// ```
pub fn recover(surface: Surface(census), run: ToolRun) -> Recovery {
  let config = surface.config
  let key = protocol.key_of(config.session, run)
  let asked = case run.replay {
    operation.ReplaySafe -> exchange(config, Forever, protocol.Query(key, _))
    operation.ReplayNever ->
      exchange(config, Forever, protocol.QueryOrFence(
        key,
        config.incarnation,
        _,
      ))
  }
  case asked {
    Ok(Ok(protocol.Missing)) | Ok(Ok(protocol.Fenced)) -> effects.NotStarted
    Ok(Ok(protocol.Terminal(outcome:))) -> effects.Recovered(outcome:)
    Ok(Ok(protocol.Unknown)) -> effects.OutcomeUnknown
    Ok(Ok(protocol.Admitted)) -> await_live(surface, run)
    Ok(Error(_refusal)) | Error(Nil) -> effects.OutcomeUnknown
  }
}

/// Tells the executor a call's result is durably staged, so its row may go. A
/// lost acknowledgement is found again by the owner port's reconciler.
///
/// ## Examples
///
/// ```gleam
/// // surface.ack(attached_surface, tool_run)
/// ```
pub fn ack(surface: Surface(census), run: ToolRun) -> Nil {
  let key = protocol.key_of(surface.config.session, run)
  address.deliver(surface.config.address, protocol.Ack(key))
}

// The call the executor still reports running: join it and take its answer.
fn await_live(surface: Surface(census), run: ToolRun) -> Recovery {
  case surface.config.read_authority(run) {
    Error(_reason) -> effects.OutcomeUnknown
    Ok(authority) ->
      case sent_run(surface, run, authority) {
        Ok(protocol.RunFinished(outcome:)) -> effects.Recovered(outcome:)
        Ok(protocol.RunLost) | Ok(protocol.RunRefused(..)) | Error(Nil) ->
          effects.OutcomeUnknown
      }
  }
}

fn sent_run(
  surface: Surface(census),
  run: ToolRun,
  authority: Authority,
) -> Result(RunAnswer, Nil) {
  let config = surface.config
  let key = protocol.key_of(config.session, run)
  exchange(config, Forever, fn(reply) {
    protocol.Run(
      key:,
      incarnation: config.incarnation,
      token: surface.token,
      run:,
      authority:,
      reply:,
    )
  })
}

// The reconciler's way to the same host: list what it holds, and acknowledge.
fn host_link(surface: Surface(census)) -> owner_port.HostLink {
  let config = surface.config
  let host = config.address
  let session = config.session
  owner_port.HostLink(
    list: fn() {
      case
        exchange(config, Within(listing_ms), protocol.ListUnacked(session, _))
      {
        Ok(Ok(unacked)) -> Ok(unacked)
        Ok(Error(refusal)) -> Error(protocol.describe(refusal))
        Error(Nil) -> Error("the executor could not be reached")
      }
    },
    ack: fn(key) { address.deliver(host, protocol.Ack(key)) },
  )
}

// --- one exchange, repaired --------------------------------------------------------

// Sends a request and returns its reply, repairing the connection and sending
// again whenever the host goes away first. `Error(Nil)` is only possible for a
// bounded patience that ran out.
fn exchange(
  config: Config(census),
  patience: Patience,
  make: fn(Subject(reply)) -> HostMessage(census),
) -> Result(reply, Nil) {
  case patience {
    Within(ms:) -> attempts(config, ms, make)
    Forever -> forever(config, make)
  }
}

// A pass of the repair loop that ends unanswered is followed by another.
fn forever(
  config: Config(census),
  make: fn(Subject(reply)) -> HostMessage(census),
) -> Result(reply, Nil) {
  case attempts(config, pass_ms, make) {
    Ok(reply) -> Ok(reply)
    Error(Nil) -> forever(config, make)
  }
}

fn attempts(
  config: Config(census),
  within: Int,
  make: fn(Subject(reply)) -> HostMessage(census),
) -> Result(reply, Nil) {
  let verdict =
    poll.fold_until(
      clock: poll.monotonic(),
      within:,
      every: poll.Doubling(from: first_pause_ms, to: longest_pause_ms),
      from: Assumed,
      attempt: fn(link) { attempt(config, link, make) },
    )
  case verdict {
    poll.Answer(value:) -> Ok(value)
    poll.Failure(error: Nil) | poll.RanOut(state: _) -> Error(Nil)
  }
}

// One send and one wait. The first attempt trusts the connection; every later
// one repairs it first, and an attempt whose repair fails waits and tries again.
fn attempt(
  config: Config(census),
  link: Link,
  make: fn(Subject(reply)) -> HostMessage(census),
) -> poll.Pass(reply, Nil, Link) {
  case link {
    Assumed -> send_and_wait(config, make)
    Repair ->
      case config.reconnect() {
        Ok(Nil) -> send_and_wait(config, make)
        Error(_unreachable) -> poll.Pending(Repair)
      }
  }
}

// The reply subject is owned by the calling process, which is the process the
// host watches. Monitoring the host before sending means a host that is
// already gone answers with its `DOWN` instead of with silence. Whichever of
// the reply and the `DOWN` comes first ends the wait.
fn send_and_wait(
  config: Config(census),
  make: fn(Subject(reply)) -> HostMessage(census),
) -> poll.Pass(reply, Nil, Link) {
  let reply = process.new_subject()
  let watch = address.watch(config.address)
  address.deliver(config.address, make(reply))
  let heard =
    process.new_selector()
    |> process.select_map(reply, Replied)
    |> process.select_specific_monitor(watch, fn(_down) { HostDown })
    |> process.selector_receive_forever

  // Demonitoring flushes a `DOWN` that arrived beside the reply.
  process.demonitor_process(watch)
  case heard {
    Replied(reply:) -> poll.Settled(reply)
    HostDown -> poll.Pending(Repair)
  }
}
