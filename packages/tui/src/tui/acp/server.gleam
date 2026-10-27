//// `loom acp`: Loom as an Agent Client Protocol agent over standard input and output.
////
//// An editor or an orchestrator that speaks ACP launches this command and
//// talks to it in JSON-RPC lines. The command is a *client* of the daemon, the
//// same kind of client the terminal and `loom run -p` are: it reaches the
//// daemon through the shared discovery ladder, authenticates with the owner
//// credential from the state root, creates or opens sessions, and drives each
//// through the credited session lane. It opens no listener and holds no model
//// credential. Durability, approvals, budgets and the sandbox stay where they
//// are, which is why ACP here changes nothing about the effect plane: a tool
//// call still goes through the broker into the jail, and an approval is still
//// a durable escalation the owner decides. ACP only changes who is asked.
////
//// One process runs the loop. It owns standard output, so frames are never
//// interleaved, and it reads one inbox into which three things arrive: lines
//// from a reader process that blocks on standard input, events from every
//// session socket (tagged with the session they belong to), and silence, which
//// is the cue to tick every lane. A reader process is the only way to wait on
//// a console and a socket at once; it holds no state and ends at end of input,
//// so there is nothing for weft to bound or reap.
////
//// The module is split from the per-session reducer (`tui/acp/session`) on
//// purpose. What a turn *means* is decided there, purely, from lane updates.
//// What this module does is custody: which sessions exist, which JSON-RPC ids
//// belong to which permission request, when the daemon is first reached, and
//// that every session this connection created is stopped when it ends.
////
//// ## Flow
////
//// `serve` → `loop` → `handle_line` → `dispatch` → `perform`
////
//// 1. `serve` fixes the workspace roots, starts the stdin reader and enters
////    the loop.
//// 2. `loop` waits on the inbox, bounded by the soonest lane deadline.
//// 3. `handle_line` decodes a line once, through `rpc.decode`, and routes
////    the frame by kind; `dispatch` decodes a request's params through
////    `schema.request` and runs it.
//// 4. `perform` carries out the actions a session returned, in order.
//// 5. At end of input `retire` closes sockets and stops created sessions.

import core/json.{type JsonValue}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as host_bootstrap
import session_view/connection_event
import session_view/session_channel
import tui/acp/rpc
import tui/acp/schema
import tui/acp/session
import tui/acp/workspace
import tui/bootstrap
import tui/connection
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection
import tui/internal/ffi_terminal
import tui/placement
import tui/run
import weft

/// What `loom acp` was asked to do.
pub type Config {
  Config(
    /// The daemon options shared with every local launch.
    options: bootstrap.Options,
    /// Directories a client's `cwd` may lie within, as named on the command
    /// line. When empty, the workspace option, or else the process directory,
    /// is the only root.
    roots: List(String),
    /// Registered workspace names a client may select with
    /// `_meta.loom.workspace`, as named on the command line. A registered
    /// workspace reaches a machine the operator configured, so none is
    /// admitted unless listed, just as no path is admitted outside a root.
    names: List(String),
    /// The Loom build, reported to the client as the agent's version.
    version: String,
  )
}

/// Where the protocol's lines come from and go to.
///
/// Standard input and output in production; two subjects in a test. Keeping
/// the transport a value is what lets the end-to-end test drive the real
/// server without a subprocess.
pub type Transport {
  Transport(
    /// Blocks for the next line, without its newline, or fails at end of input.
    read_line: fn() -> Result(String, Nil),
    /// Writes one frame and its newline.
    write_line: fn(String) -> Nil,
  )
}

/// Everything that can wake the loop.
type Event {
  /// A line from the client.
  Line(text: String)

  /// The client closed its output.
  EndOfInput

  /// Something happened on a session's socket.
  Socket(session: String, event: connection_event.Message)
}

/// Whether the client has completed `initialize`.
type Negotiation {
  /// Nothing but `initialize` is accepted.
  Fresh

  /// The version is agreed; sessions may be made.
  Negotiated
}

/// Whether this connection started the session, and so retires it.
type Origin {
  /// Created by `session/new`, or woken from disk by `session/load`; stopped
  /// at the end of the connection so nothing it started outlives it.
  Made

  /// Already resident when `session/load` found it; left as it was found.
  Opened
}

/// The daemon, once first needed.
type Daemon {
  Daemon(host: selection.Host)
}

/// One attached session.
type Live {
  Live(session: session.Session, socket: connection.Connection, origin: Origin)
}

/// A permission request awaiting the client's reply.
type Asked {
  Asked(session: String, review: String)
}

/// The loop's state.
type State {
  State(
    config: Config,
    transport: Transport,
    inbox: Subject(Event),
    roots: List(String),
    negotiation: Negotiation,
    daemon: Option(Daemon),
    sessions: Dict(String, Live),
    asked: Dict(Int, Asked),
    abandoned: List(String),
    next_request: Int,
    created: Int,
  )
}

/// How long retirement may take in all, in milliseconds.
const retire_deadline_ms = 15_000

/// The longest the loop sleeps, so lane deadlines are re-read promptly.
const longest_wait_ms = 250

/// The exit status for a refused command line or an unusable root.
pub const exit_bad_arguments = 2

/// The usage text `loom acp --help` prints.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(server.usage(), "loom acp")
/// ```
pub fn usage() -> String {
  "usage: loom acp [--workspace-root <dir>]... [--workspace-name <name>]...\n"
  <> "                [--workspace <dir>]\n"
  <> "                [--config <loom.toml>] [--model-profile <name>]\n"
  <> "                [--server <path>] [--state-dir <path>]\n\n"
  <> "Speaks the Agent Client Protocol (JSON-RPC 2.0, one frame per line) on\n"
  <> "standard input and output, so an editor or orchestrator can drive Loom\n"
  <> "sessions. It is a client of the daemon, which it starts if needed; it\n"
  <> "opens no listener. A session's cwd must lie within a --workspace-root\n"
  <> "(repeatable); with none given, the --workspace directory, or else the\n"
  <> "current directory, is the only root. A client may name a workspace\n"
  <> "registered on an executor only if it is listed with --workspace-name\n"
  <> "(repeatable). Sessions it creates are stopped\n"
  <> "when the client closes standard input. Diagnostics go to standard error;\n"
  <> "standard output carries only protocol frames.\n"
}

/// Parses the words after `loom acp`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(config) = server.parse(["--workspace-root", "/work"], "0.3")
/// assert config.roots == ["/work"]
/// ```
///
/// ```gleam
/// let assert Error(_) = server.parse(["--wat"], "0.3")
/// ```
pub fn parse(
  arguments: List(String),
  version: String,
) -> Result(Config, String) {
  let start =
    Config(
      options: bootstrap.Options("", "", "", "", "", "", placement.OnThisHost),
      roots: [],
      names: [],
      version:,
    )
  parse_words(arguments, start)
}

/// Folds the words into a config, one flag and its value at a time.
fn parse_words(
  arguments: List(String),
  config: Config,
) -> Result(Config, String) {
  // Words come in pairs: a flag and its value, until none are left.
  case arguments {
    [] -> Ok(config)
    [flag] -> Error("missing value for " <> flag)
    [flag, value, ..rest] -> {
      use config <- result.try(apply_flag(config, flag, value))
      parse_words(rest, config)
    }
  }
}

/// Lands one flag's value in the config, or refuses a flag this verb lacks.
fn apply_flag(
  config: Config,
  flag: String,
  value: String,
) -> Result(Config, String) {
  let options = config.options

  // Which flag this is decides where its value lands.
  case flag {
    "--workspace-root" ->
      Ok(Config(..config, roots: list.append(config.roots, [value])))
    "--workspace-name" ->
      Ok(Config(..config, names: list.append(config.names, [value])))
    "--workspace" ->
      Ok(
        Config(
          ..config,
          options: bootstrap.Options(..options, workspace: value),
        ),
      )
    "--server" ->
      Ok(Config(..config, options: bootstrap.Options(..options, server: value)))
    "--state-dir" ->
      Ok(
        Config(
          ..config,
          options: bootstrap.Options(..options, state_directory: value),
        ),
      )
    "--config" ->
      Ok(Config(..config, options: bootstrap.Options(..options, config: value)))
    "--model-profile" ->
      Ok(
        Config(..config, options: bootstrap.Options(..options, profile: value)),
      )
    _ -> Error("unknown acp option " <> flag)
  }
}

/// The transport over this process's standard input and output.
///
/// ## Examples
///
/// ```gleam
/// // server.serve(config, server.stdio())
/// ```
pub fn stdio() -> Transport {
  Transport(
    read_line: fn() {
      ffi_terminal.read_protocol_line()
      |> result.map(strip_newline)
      |> result.replace_error(Nil)
    },
    write_line: io.println,
  )
}

/// Removes the line terminator, whether `\n` or `\r\n`.
fn strip_newline(line: String) -> String {
  line |> string.drop_end(count_terminator(line))
}

/// How many trailing terminator characters a line carries.
fn count_terminator(line: String) -> Int {
  case string.ends_with(line, "\r\n") {
    True -> 2
    False ->
      case string.ends_with(line, "\n") {
        True -> 1
        False -> 0
      }
  }
}

/// Runs the server until the client closes its output, then answers an exit status.
///
/// The status is `0` after an orderly end of input and `2` when a workspace
/// root could not be resolved, which is reported on standard error before any
/// frame is read so a misconfigured launch fails at once.
///
/// ## Examples
///
/// ```gleam
/// // let status = server.serve(config, server.stdio())
/// ```
pub fn serve(config: Config, transport: Transport) -> Int {
  // A root that cannot be resolved fails the launch before any frame is read,
  // so a misconfiguration is seen at once and not on the first session.
  case resolve_roots(config) {
    Error(reason) -> {
      io.println_error("loom acp: " <> reason)
      exit_bad_arguments
    }
    Ok(roots) -> {
      let inbox = process.new_subject()
      let _reader = process.spawn_unlinked(fn() { read_loop(transport, inbox) })
      let state =
        State(
          config:,
          transport:,
          inbox:,
          roots:,
          negotiation: Fresh,
          daemon: None,
          sessions: dict.new(),
          asked: dict.new(),
          abandoned: [],
          next_request: 1,
          created: 0,
        )
      loop(state)
    }
  }
}

/// Canonicalises the roots once, so every later comparison is between canonical paths.
fn resolve_roots(config: Config) -> Result(List(String), String) {
  list.try_map(named_roots(config), fn(root) {
    host_bootstrap.canonical_directory(root)
    |> result.map_error(fn(reason) {
      "workspace root " <> root <> ": " <> reason
    })
  })
}

/// The roots the operator named, or the one default root when none were named.
fn named_roots(config: Config) -> List(String) {
  case config.roots, config.options.workspace {
    [], "" -> ["."]
    [], path -> [path]
    roots, _ -> roots
  }
}

/// Posts each line of the transport to the inbox, then the end of input.
///
/// The read blocks, so it lives in a process of its own; it keeps nothing and
/// returns at end of input, after which the loop retires the sessions.
fn read_loop(transport: Transport, inbox: Subject(Event)) -> Nil {
  // A line is filed and the next awaited; a failed read is the end of input.
  case transport.read_line() {
    Ok(text) -> {
      process.send(inbox, Line(text))
      read_loop(transport, inbox)
    }
    Error(Nil) -> process.send(inbox, EndOfInput)
  }
}

// --- the loop ----------------------------------------------------------------

/// One turn of the loop: wait, handle what arrived, repeat until end of input.
fn loop(state: State) -> Int {
  let now = host_bootstrap.monotonic_time_ms()

  // An event is handled; a quiet interval ticks every lane instead.
  case process.receive(state.inbox, wait_for(state, now)) {
    Ok(EndOfInput) -> {
      retire(state)
      0
    }
    Ok(Line(text)) -> loop(handle_line(state, text, now))
    Ok(Socket(session:, event:)) -> loop(route(state, session, event, now))
    Error(Nil) -> loop(tick_all(state, now))
  }
}

/// How long to wait: until the soonest session deadline, never longer than a quarter second.
fn wait_for(state: State, now: Int) -> Int {
  dict.values(state.sessions)
  |> list.filter_map(fn(live) {
    session.next_due(live.session) |> option.to_result(Nil)
  })
  |> list.fold(longest_wait_ms, fn(shortest, due) {
    int.min(shortest, int.max(1, due - now))
  })
}

/// Ticks every session's lane.
fn tick_all(state: State, now: Int) -> State {
  dict.keys(state.sessions)
  |> list.fold(state, fn(state, id) {
    with_session(state, id, fn(live) { session.tick(live.session, now) })
  })
}

/// Delivers a socket event to the session it belongs to.
fn route(
  state: State,
  id: String,
  event: connection_event.Message,
  now: Int,
) -> State {
  with_session(state, id, fn(live) { session.receive(live.session, event, now) })
}

/// Runs a session reducer step and performs the actions it returns.
///
/// A session that has died is closed and forgotten here, after its last
/// actions have been performed, so an error answer is never lost to the drop.
fn with_session(
  state: State,
  id: String,
  step: fn(Live) -> #(session.Session, List(session.Action)),
) -> State {
  // Only a session this connection still holds can take a step.
  case dict.get(state.sessions, id) {
    Error(Nil) -> state
    Ok(live) -> {
      let #(next, actions) = step(live)
      let state =
        State(
          ..state,
          sessions: dict.insert(state.sessions, id, Live(..live, session: next)),
        )
      let state = perform(state, id, actions)
      drop_if_dead(state, id)
    }
  }
}

/// Closes and forgets a session whose reducer reports it dead.
fn drop_if_dead(state: State, id: String) -> State {
  case dict.get(state.sessions, id) {
    Ok(live) ->
      case session.is_dead(live.session) {
        True -> {
          connection.close(live.socket)
          let state = forget_asks(state, id)

          // A dead session this connection started is still the daemon's to
          // hold, so its id is kept to be stopped when the connection ends.
          State(
            ..state,
            sessions: dict.delete(state.sessions, id),
            abandoned: case live.origin {
              Made -> [id, ..state.abandoned]
              Opened -> state.abandoned
            },
          )
        }
        False -> state
      }
    Error(Nil) -> state
  }
}

// --- performing actions ------------------------------------------------------

/// Forgets the permission requests a session left open.
///
/// Once a turn is answered (or its session is gone) the escalation it was
/// parked on cannot be decided from here, so a late reply must find nothing
/// to act on rather than a stale entry that still names the session.
fn forget_asks(state: State, id: String) -> State {
  State(
    ..state,
    asked: dict.filter(state.asked, fn(_, owner) { owner.session != id }),
  )
}

/// Carries out a session's actions, in the order the reducer decided them.
fn perform(state: State, id: String, actions: List(session.Action)) -> State {
  list.fold(actions, state, fn(state, action) {
    // Each action is a frame for the client, a lane output for the daemon, or
    // the end of the session.
    case action {
      session.Notify(method:, params:) ->
        write(state, rpc.encode_notification(method, params))

      session.Respond(id: reply, outcome:) -> respond(state, reply, outcome)

      session.Ask(review_id:, params:) -> ask(state, id, review_id, params)

      session.Write(output) -> {
        perform_output(output)
        state
      }

      session.TurnEnded -> forget_asks(state, id)

      session.Ended(reason:) -> {
        io.println_error("loom acp: session " <> id <> " ended: " <> reason)
        state
      }
    }
  })
}

/// Performs one lane output; recording notes are ignored because ACP keeps no recording.
fn perform_output(
  output: session_channel.Out(connection.Connection, Nil),
) -> Nil {
  case output {
    session_channel.Transmit(socket, frame) -> connection.send(socket, frame)
    session_channel.Shut(socket) -> connection.close(socket)
    session_channel.Note(..) -> Nil
  }
}

/// Writes one frame to the client.
fn write(state: State, frame: String) -> State {
  state.transport.write_line(frame)
  state
}

/// Answers a client request with a result or an error object.
fn respond(
  state: State,
  id: rpc.Id,
  outcome: Result(JsonValue, rpc.WireError),
) -> State {
  case outcome {
    Ok(value) -> write(state, rpc.encode_result(id, value))
    Error(error) -> write(state, rpc.encode_error(Some(id), error))
  }
}

/// Sends a permission request under a fresh id and remembers whose it is.
///
/// The id is ours, drawn from a counter, so a reply is matched to exactly the
/// escalation it answers and a stale or forged id matches nothing.
fn ask(state: State, id: String, review: String, params: JsonValue) -> State {
  let number = state.next_request
  let state =
    State(
      ..state,
      next_request: number + 1,
      asked: dict.insert(state.asked, number, Asked(id, review)),
    )
  write(
    state,
    rpc.encode_request(
      rpc.NumberId(number),
      "session/request_permission",
      params,
    ),
  )
}

// --- decoding what the client sent -------------------------------------------

/// Decodes one line and routes the frame by kind.
fn handle_line(state: State, text: String, now: Int) -> State {
  case string.trim(text) {
    "" -> state
    line ->
      case rpc.decode(line) {
        Error(rpc.Refusal(id:, error:)) ->
          write(state, rpc.encode_error(id, error))
        Ok(rpc.Call(id:, method:, params:)) ->
          call(state, id, method, params, now)
        Ok(rpc.Notification(method:, params:)) ->
          notification(state, method, params, now)
        Ok(rpc.Reply(id:, outcome:)) -> reply(state, id, outcome, now)
      }
  }
}

/// Handles a request, enforcing that `initialize` comes first.
fn call(
  state: State,
  id: rpc.Id,
  method: String,
  params: JsonValue,
  now: Int,
) -> State {
  case schema.request(method, params), state.negotiation {
    Error(error), _ -> respond(state, id, Error(error))

    Ok(schema.Initialize(version)), _ -> initialize(state, id, version)

    Ok(_), Fresh ->
      respond(
        state,
        id,
        Error(rpc.error(rpc.invalid_request, "initialize must come first")),
      )

    Ok(request), Negotiated -> dispatch(state, id, request, now)
  }
}

/// Answers `initialize`: version negotiation and the capability advertisement.
///
/// ACP's rule is that the agent answers with the version it speaks when it
/// cannot speak the client's, and the client then decides whether to go on. The
/// one version below which no agreement is possible is zero, which is refused.
fn initialize(state: State, id: rpc.Id, version: Int) -> State {
  case version >= schema.protocol_version {
    True ->
      respond(
        State(..state, negotiation: Negotiated),
        id,
        Ok(schema.initialize_result(state.config.version)),
      )
    False ->
      respond(
        state,
        id,
        Error(rpc.error(rpc.invalid_params, "protocol version 1 is required")),
      )
  }
}

/// Runs one negotiated request.
fn dispatch(
  state: State,
  id: rpc.Id,
  request: schema.Request,
  now: Int,
) -> State {
  case request {
    schema.Initialize(..) -> state

    schema.Authenticate(..) ->
      respond(
        state,
        id,
        Error(rpc.error(rpc.invalid_params, "no authentication is offered")),
      )

    schema.NewSession(cwd:, mcp_servers:, meta:) ->
      new_session(state, id, cwd, mcp_servers, meta, now)

    schema.LoadSession(session_id:, cwd:, mcp_servers:, meta:) ->
      load_session(state, id, session_id, cwd, mcp_servers, meta, now)

    schema.Prompt(session_id:, content:) ->
      existing(state, id, session_id, fn(live) {
        session.prompt(live.session, id, content, now)
      })

    schema.SetModel(session_id:, model_id:) ->
      existing(state, id, session_id, fn(live) {
        session.set_model(live.session, id, model_id, schema.LegacyAnswer, now)
      })

    schema.SetConfigOption(session_id:, config_id: "model", value:) ->
      set_model_option(state, id, session_id, value, now)

    schema.SetConfigOption(config_id:, ..) ->
      respond(
        state,
        id,
        Error(rpc.error(rpc.invalid_params, "no such option: " <> config_id)),
      )
  }
}

/// Applies the `model` option; its only values are catalogue names, which are text.
fn set_model_option(
  state: State,
  id: rpc.Id,
  session_id: String,
  value: schema.ConfigValue,
  now: Int,
) -> State {
  case value {
    schema.Choice(name) ->
      existing(state, id, session_id, fn(live) {
        session.set_model(live.session, id, name, schema.ConfigAnswer, now)
      })
    schema.Switch ->
      respond(
        state,
        id,
        Error(rpc.error(rpc.invalid_params, "the model option is a select")),
      )
  }
}

/// Runs a step on a known session, or answers that the session does not exist.
fn existing(
  state: State,
  id: rpc.Id,
  session_id: String,
  step: fn(Live) -> #(session.Session, List(session.Action)),
) -> State {
  case dict.has_key(state.sessions, session_id) {
    True -> with_session(state, session_id, step)
    False ->
      respond(
        state,
        id,
        Error(rpc.error(
          rpc.resource_not_found,
          "unknown session " <> session_id,
        )),
      )
  }
}

/// Handles a notification; only `session/cancel` is defined, and nothing may be answered.
fn notification(
  state: State,
  method: String,
  params: JsonValue,
  now: Int,
) -> State {
  case schema.notification(method, params) {
    Ok(schema.Cancel(session_id:)) ->
      with_session(state, session_id, fn(live) {
        session.cancel(live.session, now)
      })
    Error(_) -> state
  }
}

/// Routes the client's answer to a permission request to its session.
fn reply(
  state: State,
  id: rpc.Id,
  outcome: Result(JsonValue, rpc.WireError),
  now: Int,
) -> State {
  case id {
    rpc.NumberId(number) ->
      case dict.get(state.asked, number) {
        Error(Nil) -> state
        Ok(Asked(session: owner, review:)) -> {
          let state = State(..state, asked: dict.delete(state.asked, number))

          // An error, or an answer that does not decode, is a refusal: an
          // unreadable reply must never widen authority.
          let choice =
            outcome
            |> result.try(schema.permission_choice)
            |> result.unwrap(schema.Dismissed)
          with_session(state, owner, fn(live) {
            session.answer(live.session, review, choice, now)
          })
        }
      }
    rpc.TextId(_) -> state
  }
}

// --- making sessions ---------------------------------------------------------

/// A refusal that carries the state its steps had already changed.
///
/// A step can reach the daemon before a later one fails, and what it reached
/// (a cached control connection, a session it woke) must survive the failure
/// so it is neither leaked nor lost.
type Refused {
  Refused(state: State, error: rpc.WireError)
}

/// Handles `session/new`.
fn new_session(
  state: State,
  id: rpc.Id,
  cwd: String,
  mcp_servers: List(String),
  meta: schema.Meta,
  now: Int,
) -> State {
  let made = {
    use _ <- result.try(
      refuse_unsupported(mcp_servers, meta)
      |> result.map_error(Refused(state, _)),
    )
    use choice <- result.try(
      workspace.choose(
        meta,
        cwd,
        state.roots,
        state.config.names,
        host_bootstrap.canonical_directory,
      )
      |> result.map_error(fn(reason) { Refused(state, invalid(reason)) }),
    )
    use #(state, host) <- result.try(
      ensure_daemon(state) |> result.map_error(Refused(state, _)),
    )
    use target <- result.try(
      create(state, host, choice, meta) |> result.map_error(Refused(state, _)),
    )
    start_attached(state, target, session.Created, id, meta.model, Made, now)
  }
  settle_attach(id, made)
}

/// Handles `session/load`.
fn load_session(
  state: State,
  id: rpc.Id,
  session_id: String,
  cwd: String,
  mcp_servers: List(String),
  meta: schema.Meta,
  now: Int,
) -> State {
  let opened = {
    use _ <- result.try(
      refuse_unsupported(mcp_servers, meta)
      |> result.map_error(Refused(state, _)),
    )
    use _ <- result.try(
      refuse_duplicate(state, session_id) |> result.map_error(Refused(state, _)),
    )
    use #(state, host) <- result.try(
      ensure_daemon(state) |> result.map_error(Refused(state, _)),
    )

    // Everything that can refuse a load is checked against the registration
    // *before* the session is opened, because opening a parked session makes
    // it resident, and a session woken and then refused would be left running
    // with nothing tracking it.
    use row <- result.try(
      registration(host, session_id) |> result.map_error(Refused(state, _)),
    )
    use _ <- result.try(
      require_inside_roots(state.roots, row.workspace)
      |> result.map_error(Refused(state, _)),
    )
    use _ <- result.try(
      require_matching_cwd(cwd, row.workspace)
      |> result.map_error(Refused(state, _)),
    )

    // A session found saved is made resident by this open, so it is this
    // connection's to stop again; one found resident belongs to someone else.
    let origin = case row.status {
      protocol.Saved -> Made
      _ -> Opened
    }

    use target <- result.try(
      selection.open(host, session_id)
      |> result.map_error(fn(reason) {
        Refused(
          abandon(state, session_id, origin),
          rpc.error(rpc.resource_not_found, reason),
        )
      }),
    )
    start_attached(state, target, session.Loaded, id, None, origin, now)
  }
  settle_attach(id, opened)
}

/// Refuses to attach a session this connection already holds.
///
/// A second attach would replace the first without closing its socket or
/// forgetting its permission requests, and the second open would find the
/// session resident and so lose track of who is to stop it.
fn refuse_duplicate(
  state: State,
  session_id: String,
) -> Result(Nil, rpc.WireError) {
  case dict.has_key(state.sessions, session_id) {
    True -> Error(invalid("session " <> session_id <> " is already loaded"))
    False -> Ok(Nil)
  }
}

/// Reads the daemon's registration for a session.
fn registration(
  host: selection.Host,
  session_id: String,
) -> Result(protocol.Session, rpc.WireError) {
  case
    daemon.request(
      selection.control(host),
      protocol.GetSession(session_id),
      5000,
    )
  {
    Ok(protocol.SessionReply(row)) -> Ok(row)
    _ ->
      Error(rpc.error(rpc.resource_not_found, "unknown session " <> session_id))
  }
}

/// A loaded session's own workspace must be the `cwd` the client named.
///
/// The session is already bound to a workspace; a client that believes it is
/// somewhere else is about to act on the wrong tree, so the mismatch is
/// reported instead of ignored. A registered name is not a path and is not
/// compared.
fn require_matching_cwd(
  cwd: String,
  workspace: String,
) -> Result(Nil, rpc.WireError) {
  case string.starts_with(workspace, "/") {
    False -> Ok(Nil)
    True ->
      case host_bootstrap.canonical_directory(cwd) {
        Ok(resolved) if resolved == workspace -> Ok(Nil)
        _ ->
          Error(invalid(
            "cwd is not the workspace this session is bound to: " <> workspace,
          ))
      }
  }
}

/// Records that this connection started a session it no longer tracks, so it is still stopped.
fn abandon(state: State, session_id: String, origin: Origin) -> State {
  case origin {
    Made -> State(..state, abandoned: [session_id, ..state.abandoned])
    Opened -> state
  }
}

/// Attaches a session, and on failure keeps the session in the abandoned list.
fn start_attached(
  state: State,
  target: selection.Target,
  intent: session.Attach,
  reply: rpc.Id,
  model: Option(String),
  origin: Origin,
  now: Int,
) -> Result(State, Refused) {
  case attach(state, target, intent, reply, model, origin, now) {
    Ok(state) -> Ok(state)
    Error(error) ->
      Error(Refused(abandon(state, target.expected.session, origin), error))
  }
}

/// Turns an attach that failed into the error response, or keeps the new state.
fn settle_attach(id: rpc.Id, attached: Result(State, Refused)) -> State {
  case attached {
    Ok(state) -> state
    Error(Refused(state:, error:)) -> respond(state, id, Error(error))
  }
}

/// A loaded session's local workspace must lie inside an operator root.
///
/// A registered-name workspace (an executor's) is not a path and is the
/// operator's own configuration, so only an absolute path is held to the roots.
fn require_inside_roots(
  roots: List(String),
  path: String,
) -> Result(Nil, rpc.WireError) {
  case
    string.starts_with(path, "/"),
    list.any(roots, workspace.within(_, path))
  {
    True, False ->
      Error(invalid("the session's workspace is outside the workspace roots"))
    True, True | False, _ -> Ok(Nil)
  }
}

/// Refuses the two session options this server cannot yet honour for one session.
///
/// Both exist to isolate a session (its own tools, no repository guidance).
/// Accepting them and then doing nothing would hand the client a guarantee
/// that is not there, so each is named in a refusal instead.
fn refuse_unsupported(
  mcp_servers: List(String),
  meta: schema.Meta,
) -> Result(Nil, rpc.WireError) {
  case mcp_servers, meta.guidance {
    [], schema.GuidanceLoaded -> Ok(Nil)
    [_, ..], _ ->
      Error(invalid(
        "per-session MCP servers are not supported yet: "
        <> string.join(mcp_servers, ", "),
      ))
    [], schema.GuidanceOmitted ->
      Error(invalid(
        "_meta.loom.project_instructions=false is not supported yet",
      ))
  }
}

/// Reaches the daemon the first time a session needs it.
fn ensure_daemon(
  state: State,
) -> Result(#(State, selection.Host), rpc.WireError) {
  case state.daemon {
    Some(Daemon(host)) -> Ok(#(state, host))
    None ->
      case run.reach_daemon(state.config.options) {
        Ok(#(host, _root)) ->
          Ok(#(State(..state, daemon: Some(Daemon(host))), host))
        Error(reason) ->
          Error(rpc.error(rpc.internal_error, "no daemon: " <> reason))
      }
  }
}

/// Creates the session under a key that is never reused.
fn create(
  state: State,
  host: selection.Host,
  choice: workspace.Choice,
  meta: schema.Meta,
) -> Result(selection.Target, rpc.WireError) {
  let options = state.config.options
  let key =
    "loom-acp-"
    <> int.to_string(host_bootstrap.current_process_id())
    <> "-"
    <> int.to_string(state.created)
    <> "-"
    <> int.to_string(host_bootstrap.system_time_ms())
  let profile = option.unwrap(meta.profile, options.profile)

  use configuration <- result.try(
    bootstrap.session_configuration(options)
    |> result.map_error(fn(reason) { rpc.error(rpc.internal_error, reason) }),
  )

  // A local workspace is named by its directory; a registered one by its name
  // together with the executor or pool that serves it.
  let created = case choice {
    workspace.Local(path) ->
      selection.create_named(
        host,
        key,
        path,
        bootstrap.workspace_name(path),
        configuration,
        profile,
        "",
        "",
      )
    workspace.Registered(name, executor, pool) ->
      selection.create_named(
        host,
        key,
        name,
        name,
        configuration,
        profile,
        executor,
        pool,
      )
  }

  result.map_error(created, fn(reason) { rpc.error(rpc.internal_error, reason) })
}

/// Opens the session's socket, starts its reducer and files it.
fn attach(
  state: State,
  target: selection.Target,
  intent: session.Attach,
  reply: rpc.Id,
  model: Option(String),
  origin: Origin,
  now: Int,
) -> Result(State, rpc.WireError) {
  let id = target.expected.session

  // The socket's events are tagged with the session, so the loop's single
  // inbox can tell which lane an event belongs to.
  use socket <- result.try(
    connection.connect_tagged(target.address, target.token, state.inbox, Socket(
      id,
      _,
    ))
    |> result.map_error(fn(reason) { rpc.error(rpc.internal_error, reason) }),
  )
  let #(started, actions) =
    session.start(id, socket, target.expected, intent, reply, model, now)
  let state =
    State(
      ..state,
      created: state.created + 1,
      sessions: dict.insert(state.sessions, id, Live(started, socket, origin)),
    )
  Ok(perform(state, id, actions))
}

/// An `invalid_params` error.
fn invalid(reason: String) -> rpc.WireError {
  rpc.error(rpc.invalid_params, reason)
}

// --- ending ------------------------------------------------------------------

/// Closes every socket and stops the sessions this connection created.
///
/// A created session left running would outlive the client that asked for it,
/// holding a resident slot and any provider work, so each is stopped and the
/// daemon's own report that it saved is waited for. A session this connection
/// only opened is detached and left as it was found.
fn retire(state: State) -> Nil {
  dict.each(state.sessions, fn(_, live) { connection.close(live.socket) })

  // Every session to stop is stopped at once under one deadline. A client's
  // runtime closes our standard input and then terminates us after a short
  // grace, so stopping them one after another would let the last wait out a
  // deadline the first already spent. The shared deadline bounds the whole
  // retirement; a session still stopping when it passes stays the daemon's.
  let ids =
    list.append(
      state.abandoned,
      dict.to_list(state.sessions)
        |> list.filter_map(fn(entry) {
          case entry.1.origin {
            Made -> Ok(entry.0)
            Opened -> Error(Nil)
          }
        }),
    )
  stop_together(state, ids)

  // The control connection closes last, once nothing needs it to stop a session.
  case state.daemon {
    Some(Daemon(host)) -> daemon.close(selection.control(host))
    None -> Nil
  }
}

/// Stops the named sessions concurrently within `retire_deadline_ms`.
fn stop_together(state: State, ids: List(String)) -> Nil {
  case state.daemon {
    None -> Nil
    Some(Daemon(host)) ->
      ids
      |> list.map(fn(id) { fn() { stop_on_own_control(host, id) } })
      |> weft.new
      |> weft.limit(8)
      |> weft.deadline(retire_deadline_ms)
      |> weft.start
      |> list.each(report_stop)
  }
}

/// Stops one session over a control connection of its own.
///
/// The daemon's control connection answers one request at a time and refuses
/// a second as busy, so concurrent stops cannot share the connection the
/// loop used. Each worker mints its own, which it owns and closes.
fn stop_on_own_control(
  host: selection.Host,
  id: String,
) -> Result(Nil, String) {
  use own <- result.try(selection.reconnect(host, process.self()))
  let stopped = run.stop(own, id)
  daemon.close(selection.control(own))
  stopped
}

/// Says on standard error when a session was not stopped; success is silent.
fn report_stop(outcome: weft.Outcome(Nil, String)) -> Nil {
  case outcome {
    weft.Completed(..) -> Nil
    weft.Failed(error: reason, ..) ->
      io.println_error("loom acp: a session was not stopped: " <> reason)
    _ ->
      io.println_error("loom acp: a session was still stopping at the deadline")
  }
}
