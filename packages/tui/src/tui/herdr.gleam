//// Best-effort agent-state reporting to a Herdr multiplexer, when the
//// terminal was launched inside one of its panes.
////
//// Herdr keeps a closed registry of agent integrations; a pane running an
//// integrated agent inherits three environment variables
//// (`HERDR_ENV=1`, `HERDR_SOCKET_PATH`, `HERDR_PANE_ID`), and the agent
//// reports its lifecycle as newline-delimited JSON requests over that
//// unix socket: `pane.report_agent_session` when the session identity is
//// known, then `pane.report_agent` as the agent moves between working,
//// blocked and idle. `herdr session` resume keys off the reported session
//// id, which Loom already has as a first-class value — the attached
//// session id itself.
////
//// This terminal is a self-contained binary with no hook directory for
//// Herdr's installer to drop a script into, so the adapter is compiled in
//// and gated at runtime by the same three variables. Every other
//// integration's adapter is fire-and-forget, and this one keeps the rule:
//// the reporter is a dedicated process, each exchange carries a deadline,
//// a failed delivery is retried once and then dropped, and nothing here
//// can stall or fail the terminal's own connection to the daemon.
////
//// The module is split so the loop-facing half is pure: `state_for` maps the
//// model onto the pane state and `encode_*` build the wire bytes, which
//// the tests pin, while the reporter process and the socket exchange are
//// the only effects.

import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import host/bootstrap
import tui/approval
import tui/internal/ffi_herdr
import tui/protocol.{type Strand}
import weft/actor

/// The wire tag Herdr's resume planner matches this integration on.
const source = "herdr:loom"

/// The agent label reported beside it.
const agent = "loom"

/// A failed delivery is retried once with a longer deadline, the pattern
/// every scriptable-host adapter uses.
const attempt_timeout_ms = 500

const retry_timeout_ms = 1500

/// One report in flight is enough: state reports supersede each other, so
/// a queued change waits for the current exchange rather than stacking.
pub opaque type Reporter {
  Reporter(config: Config, inner: actor.Started(Subject(Message)))
}

/// The pane a reporter serves. The three values are exactly the three
/// environment variables, held as one record so the gate is "was there a
/// config", never three separate presence checks.
pub type Config {
  Config(
    /// Herdr's own pane identifier, echoed back on every report.
    pane_id: String,
    /// The unix socket the pane's client daemon listens on.
    socket_path: String,
    /// Process start time in milliseconds, the seed of the monotonic
    /// report sequence Herdr uses to drop reordered reports.
    started_ms: Int,
  )
}

/// The state one pane report carries. The set is Herdr's; `Working` is
/// any live strand, `Blocked` is a pending approval, and `Done` is the
/// settled transition Herdr's registry understands that `Idle` does not.
pub type PaneState {
  Idle
  Working
  Blocked
  Done
}

/// The last report sent, so the loop publishes only on a change. The
/// session id rides along because a session switch at the same state is
/// still a new report: resume must follow the new session.
pub type Publication {
  Publication(state: PaneState, session: String)
}

/// What the reporter is asked to do.
pub type Message {
  /// Report a state transition. Superseded by a later `Report`; `Shutdown`
  /// beats everything, because the pane is going away.
  Report(state: PaneState, session: String, message: String)

  /// Report the session identity without a state claim. Sent when the
  /// terminal first attaches and on every switch, so a pane opened onto an
  /// idle session still resumes correctly.
  Announce(session: String)

  /// Stop reporting. The process exits; the socket was already closed by
  /// Stop reporting. The process exits; the socket was already closed by
  /// the exchange that completed or timed out.
  Shutdown
}

/// The reporter's own state: the config it was born with and the sequence
/// number of the last report it attempted.
type ReporterState {
  ReporterState(config: Config, seq: Int)
}

/// Reads the launch environment and answers the pane config when this
/// terminal is running under Herdr.
///
/// The gate is the same one every adapter applies: `HERDR_ENV` is exactly
/// "1" and both the socket path and the pane id are present. Anything
/// less — a partial export, a different value — is not a Herdr pane, and
/// the reporter never starts.
///
/// ## Examples
///
/// ```gleam
/// // Outside a Herdr pane there is nothing to configure.
/// // herdr.configure(1_700_000_000_000) == None
/// ```
pub fn configure(started_ms: Int) -> Option(Config) {
  case bootstrap.getenv("HERDR_ENV") {
    Ok("1") ->
      case
        bootstrap.getenv("HERDR_SOCKET_PATH"),
        bootstrap.getenv("HERDR_PANE_ID")
      {
        Ok(socket_path), Ok(pane_id) ->
          case socket_path != "" && pane_id != "" {
            True -> Some(Config(pane_id:, socket_path:, started_ms:))
            False -> None
          }
        _, _ -> None
      }
    _ -> None
  }
}

/// Maps the terminal's own lifecycle signals onto Herdr's pane state.
///
/// The three inputs are the same three the frame renders from, so the
/// pane cannot disagree with the operator's own screen: a pending approval
/// is blocked, a strand with a live phase is working, and an operation
/// that just settled is done. Approval wins over liveness because the
/// strand is waiting on the operator, whatever the last phase said.
///
/// ## Examples
///
/// ```gleam
/// herdr.state_for(
///   [protocol.Strand(id: "main", name: None, live_phase: Some("tool"))],
///   [],
///   False,
/// )
/// // -> Working
/// ```
pub fn state_for(
  strands: List(Strand),
  approvals: List(approval.Review),
  settled: Bool,
) -> PaneState {
  let pending =
    list.any(approvals, fn(review) { review.status == approval.Pending })
  let live = list.any(strands, fn(strand) { strand.live_phase != None })
  case pending, live, settled {
    True, _, _ -> Blocked
    False, True, _ -> Working
    False, False, True -> Done
    False, False, False -> Idle
  }
}

/// Whether a derived state differs from the last one published.
///
/// ## Examples
///
/// ```gleam
/// herdr.changed(
///   Some(herdr.Publication(herdr.Idle, "a")),
///   herdr.Publication(herdr.Idle, "b"),
/// )
/// // -> True
/// ```
pub fn changed(last: Option(Publication), next: Publication) -> Bool {
  case last {
    Some(previous) ->
      previous.state != next.state || previous.session != next.session
    None -> True
  }
}

/// Starts the reporter for one pane. Unlinked: a failed socket must never
/// take the terminal down, and the terminal exiting normally leaves the
/// reporter to drain its queue on its own short deadlines.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(config) = option.to_result(herdr.configure(now), "no pane")
/// let assert Ok(reporter) = herdr.start(config)
/// ```
pub fn start(config: Config) -> Result(Reporter, actor.StartError) {
  case
    actor.new(ReporterState(config:, seq: config.started_ms))
    |> actor.on_message(handle)
    |> actor.unlinked
    |> actor.start
  {
    Ok(started) -> Ok(Reporter(config:, inner: started))
    Error(reason) -> Error(reason)
  }
}

/// Queues a state report. Silent when there is no reporter, which is what
/// the whole codebase outside a Herdr pane gets.
pub fn report(
  reporter: Option(Reporter),
  state: PaneState,
  session: String,
  message: String,
) -> Nil {
  case reporter {
    None -> Nil
    Some(reporter) ->
      process.send(reporter.inner.data, Report(state:, session:, message:))
  }
}

/// Queues a session announcement without a state claim.
pub fn announce(reporter: Option(Reporter), session: String) -> Nil {
  case reporter {
    None -> Nil
    Some(reporter) -> process.send(reporter.inner.data, Announce(session:))
  }
}

/// Stops the reporter. Called from the terminal's shutdown path only.
pub fn shutdown(reporter: Option(Reporter)) -> Nil {
  case reporter {
    None -> Nil
    Some(reporter) -> process.send(reporter.inner.data, Shutdown)
  }
}

fn handle(
  state: ReporterState,
  message: Message,
) -> actor.Next(ReporterState, Message) {
  case message {
    Shutdown -> actor.stop()

    // The sequence advances on the attempt, not the delivery: a dropped
    // report leaves a gap, and Herdr's reordering guard reads the gap as
    // "something was lost", which is the truth.
    Report(state: pane_state, session:, message: note) -> {
      let seq = state.seq + 1
      deliver(
        state.config,
        encode_report(state.config, seq, pane_state, session, note),
      )
      actor.continue(ReporterState(..state, seq:))
    }

    Announce(session:) -> {
      let seq = state.seq + 1
      deliver(state.config, encode_announce(state.config, seq, session))
      actor.continue(ReporterState(..state, seq:))
    }
  }
}

// One exchange, one retry, then the report is gone. The retry exists
// because a pane report racing its own daemon's startup is common enough
// to be worth one second and no more; anything beyond that is the
// terminal's own session, which always wins.
fn deliver(config: Config, payload: String) -> Nil {
  case ffi_herdr.exchange(config.socket_path, payload, attempt_timeout_ms) {
    Ok(_) -> Nil
    Error(_) -> {
      let _ = ffi_herdr.exchange(config.socket_path, payload, retry_timeout_ms)
      Nil
    }
  }
}

/// Encodes one `pane.report_agent` request as one line of JSON.
///
/// ## Examples
///
/// ```gleam
/// herdr.encode_report(config, 7, herdr.Working, "sess-1", "")
/// ```
pub fn encode_report(
  config: Config,
  seq: Int,
  state: PaneState,
  session: String,
  message: String,
) -> String {
  encode(config, seq, "pane.report_agent", [
    #("state", json.String(state_name(state))),
    #("agent_session_id", json.String(session)),
    #("message", case message {
      "" -> json.Null
      text -> json.String(text)
    }),
  ])
}

/// Encodes one `pane.report_agent_session` request as one line of JSON.
pub fn encode_announce(config: Config, seq: Int, session: String) -> String {
  encode(config, seq, "pane.report_agent_session", [
    #("agent_session_id", json.String(session)),
  ])
}

// The envelope both methods share: a monotonically sequenced request with
// the pane identity and this integration's tags, newline-terminated the
// way the daemon frames it.
fn encode(
  config: Config,
  seq: Int,
  method: String,
  extra: List(#(String, json.JsonValue)),
) -> String {
  json.to_string(
    json.Object([
      #("id", json.String(source <> ":" <> int.to_string(seq))),
      #("method", json.String(method)),
      #(
        "params",
        json.Object([
          #("pane_id", json.String(config.pane_id)),
          #("source", json.String(source)),
          #("agent", json.String(agent)),
          #("seq", json.Int(seq)),
          ..extra
        ]),
      ),
    ]),
  )
  <> "\n"
}

fn state_name(state: PaneState) -> String {
  case state {
    Idle -> "idle"
    Working -> "working"
    Blocked -> "blocked"
    Done -> "done"
  }
}
