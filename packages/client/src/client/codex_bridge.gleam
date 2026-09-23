//// A VM-shared, profile-bound transport for Codex subscription requests.
////
//// The helper alone owns tokens and the fixed backend host. One Weft actor
//// per profile owns its port and correlates bounded frames to parked request
//// owners. Each request owner is the provider's drain witness: it can exit
//// normally only after the helper has sent `end` or `cancel_ack` for its ID.
//// Losing the helper or seeing malformed protocol faults that witness.

import client/install
import client/internal/ffi_codex_bridge as ffi
import client/internal/ffi_os
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/port.{type Port}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/gateway
import provider/http
import simplifile
import weft/actor

const max_frame = 4_194_304

/// A control operation addressed to a dedicated subscription profile.
pub type Command {
  /// Reports whether the profile is signed in, with its plan label.
  Status

  /// Starts browser OAuth and emits instructions before completion.
  LoginBrowser

  /// Starts device OAuth and emits instructions before completion.
  LoginDevice

  /// Removes the helper-owned credential for this profile.
  Logout

  /// Fetches the account's current entitled model catalogue.
  Models
}

/// A redacted control observation. None of these fields contains a token.
pub type ControlEvent {
  /// A URL and optional device code to present to the human operator.
  LoginInstructions(url: String, user_code: Option(String))

  /// Login completed and the helper accepted the bound account.
  LoginComplete(plan: String)

  /// Current signed-in status and plan label.
  LoginStatus(code: String, plan: String)

  /// Explicit logout finished.
  LogoutComplete

  /// A validated model list represented by its non-secret JSON document.
  ModelCatalogue(json: String)

  /// A bounded failure code with no helper diagnostic or credential text.
  ControlFailed(code: String)
}

/// The production provider transport. Its only caller-supplied selector is a
/// profile name; the helper path and backend host are fixed by the binary.
///
/// ## Examples
///
/// ```gleam
/// let bridge = codex_bridge.transport()
/// let gateway = gateway.with_codex_transport(gateway, bridge)
/// ```
pub fn transport() -> gateway.CodexTransport {
  gateway.CodexTransport(prepare_streaming: prepare_streaming)
}

/// Starts one control operation through the same long-lived profile helper.
/// The returned owner is monitorable and cancellable. `events` receives only
/// redacted control observations; login instructions may precede completion.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(running) = codex_bridge.command("default", Status, events)
/// // Monitor `http.owner(running)` before waiting for a terminal event.
/// ```
pub fn command(
  profile: String,
  action: Command,
  events: Subject(ControlEvent),
) -> Result(http.RunningRequest, String) {
  use manager <- result.try(ensure_manager(profile))
  let id = new_id()
  use #(owner, pid) <- result.try(start_owner(
    manager,
    profile,
    id,
    Control(events),
  ))
  process.send(owner, Begin(command_name(action), None))
  Ok(
    http.RunningRequest(owner: pid, cancel: fn() { process.send(owner, Cancel) }),
  )
}

fn prepare_streaming(
  profile: String,
  request: http.HttpRequest,
  events: Subject(http.HttpEvent),
) -> Result(http.PreparedRequest, String) {
  use Nil <- result.try(validate_request(request))
  use manager <- result.try(ensure_manager(profile))
  let id = new_id()
  use #(owner, pid) <- result.try(start_owner(
    manager,
    profile,
    id,
    Inference(events),
  ))
  let body =
    bit_array.from_string(request.body) |> bit_array.base64_encode(True)
  Ok(
    http.PreparedRequest(
      running: http.RunningRequest(owner: pid, cancel: fn() {
        process.send(owner, Cancel)
      }),
      begin: fn() { process.send(owner, Begin("request", Some(body))) },
    ),
  )
}

/// Checks the non-secret, relative subscription request boundary.
/// Credentials, account routing headers, and absolute URLs are refused before
/// the helper sees a frame.
///
/// ## Examples
///
/// ```gleam
/// // validate_request(http.HttpRequest("POST", "/responses", [#("content-type", "application/json"), #("accept", "text/event-stream")], "{}")) == Ok(Nil)
/// ```
pub fn validate_request(request: http.HttpRequest) -> Result(Nil, String) {
  case request.method, request.url, request.headers {
    "POST",
      "/responses",
      [#("content-type", "application/json"), #("accept", "text/event-stream")]
    -> Ok(Nil)
    _, _, _ ->
      Error("subscription request contains a forbidden method, URL, or header")
  }
}

fn new_id() -> String {
  "loom-" <> int.to_string(ffi_os.unique_positive_integer())
}

fn command_name(command: Command) -> String {
  case command {
    Status -> "status"
    LoginBrowser -> "login_browser"
    LoginDevice -> "login_device"
    Logout -> "logout"
    Models -> "models"
  }
}

type Destination {
  Inference(Subject(http.HttpEvent))
  Control(Subject(ControlEvent))
}

type OwnerMessage {
  Begin(command: String, body: Option(String))
  Cancel
  Frame(WireEvent)
  ManagerLost
  CreatorLost
}

type OwnerState {
  OwnerState(
    inbox: Subject(OwnerMessage),
    manager: Subject(ManagerMessage),
    profile: String,
    id: String,
    destination: Destination,
    phase: OwnerPhase,
    ending: ResponseEnding,
  )
}

type OwnerPhase {
  Parked
  Active
  Cancelling
}

type ResponseEnding {
  ResponseOpen
  FailureReported
}

fn start_owner(
  manager: Subject(ManagerMessage),
  profile: String,
  id: String,
  destination: Destination,
) -> Result(#(Subject(OwnerMessage), Pid), String) {
  use manager_pid <- result.try(
    process.subject_owner(manager)
    |> result.replace_error("subscription helper owner unavailable"),
  )
  let creator = process.self()
  actor.new_with_initialiser(1000, fn(subject) {
    let creator_watch = process.monitor(creator)
    let manager_watch = process.monitor(manager_pid)
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_specific_monitor(creator_watch, fn(_) { CreatorLost })
      |> process.select_specific_monitor(manager_watch, fn(_) { ManagerLost })
    let state =
      OwnerState(
        inbox: subject,
        manager:,
        profile:,
        id:,
        destination:,
        phase: Parked,
        ending: ResponseOpen,
      )
    Ok(
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(subject),
    )
  })
  |> actor.unlinked
  |> actor.on_message(handle_owner)
  |> actor.start
  |> result.map(fn(started) { #(started.data, started.pid) })
  |> result.map_error(fn(_) { "subscription request owner could not start" })
}

fn handle_owner(
  state: OwnerState,
  message: OwnerMessage,
) -> actor.Next(OwnerState, OwnerMessage) {
  case message, state.phase {
    Begin(command, body), Parked -> {
      process.send(
        state.manager,
        Start(state.id, command, body, state.profile, state.inbox),
      )
      actor.continue(OwnerState(..state, phase: Active))
    }
    Begin(_, _), _ -> actor.continue(state)

    Cancel, Parked -> actor.stop()
    Cancel, Active -> {
      process.send(state.manager, Stop(state.id))
      actor.continue(OwnerState(..state, phase: Cancelling))
    }
    Cancel, Cancelling -> actor.continue(state)

    CreatorLost, Parked -> actor.stop()
    CreatorLost, _ -> {
      process.send(state.manager, Stop(state.id))
      actor.continue(OwnerState(..state, phase: Cancelling))
    }
    ManagerLost, Parked -> actor.stop()
    ManagerLost, _ ->
      actor.stop_abnormal("subscription helper drain proof lost")

    Frame(_event), Parked ->
      actor.stop_abnormal("unsolicited subscription frame")
    Frame(event), _ -> deliver_frame(state, event)
  }
}

fn deliver_frame(
  state: OwnerState,
  event: WireEvent,
) -> actor.Next(OwnerState, OwnerMessage) {
  case state.destination, event.event {
    Inference(events), "http_status" -> {
      process.send(events, http.ResponseStatus(event.status, []))
      actor.continue(state)
    }
    Inference(events), "chunk" -> {
      case bit_array.base64_decode(event.data_b64) {
        Ok(bytes) -> {
          process.send(events, http.ResponseChunk(bytes))
          actor.continue(state)
        }
        Error(_) -> actor.stop_abnormal("invalid subscription response chunk")
      }
    }
    Inference(events), "end" -> {
      case state.ending {
        FailureReported -> Nil
        ResponseOpen -> process.send(events, http.ResponseEnd)
      }
      actor.stop()
    }
    Inference(_), "cancel_ack" -> actor.stop()
    Inference(events), "error" -> {
      case event.code {
        "not_logged_in" -> terminal_status(state, events, 401, event.code)
        "credential_unavailable" ->
          terminal_status(state, events, 401, event.code)
        "refresh_failed" -> terminal_status(state, events, 401, event.code)
        "account_mismatch" -> terminal_status(state, events, 403, event.code)
        "model_unavailable" -> terminal_status(state, events, 403, event.code)
        _ -> {
          process.send(
            events,
            http.RequestFailed("subscription helper request failed"),
          )
          actor.continue(OwnerState(..state, ending: FailureReported))
        }
      }
    }
    Control(events), "login_instructions" -> {
      process.send(events, LoginInstructions(event.url, event.user_code))
      actor.continue(state)
    }
    Control(events), "login_complete" -> {
      process.send(events, LoginComplete(event.plan))
      actor.continue(state)
    }
    Control(events), "status" -> {
      process.send(events, LoginStatus(event.code, event.plan))
      actor.continue(state)
    }
    Control(events), "logout_complete" -> {
      process.send(events, LogoutComplete)
      actor.continue(state)
    }
    Control(events), "models" -> {
      process.send(events, ModelCatalogue(encode_models(event.models)))
      actor.continue(state)
    }
    Control(events), "error" -> {
      process.send(events, ControlFailed(event.code))
      actor.continue(state)
    }
    Control(_), "end" -> actor.stop()
    Control(_), "cancel_ack" -> actor.stop()
    _, _ -> actor.stop_abnormal("unrecognized subscription helper event")
  }
}

fn terminal_status(
  state: OwnerState,
  events: Subject(http.HttpEvent),
  status: Int,
  code: String,
) -> actor.Next(OwnerState, OwnerMessage) {
  process.send(events, http.ResponseStatus(status, []))
  process.send(events, http.ResponseChunk(bit_array.from_string(code)))
  actor.continue(state)
}

type ManagerMessage {
  Start(
    id: String,
    command: String,
    body: Option(String),
    profile: String,
    owner: Subject(OwnerMessage),
  )
  Stop(id: String)
  Native(ffi.PortEvent)
}

type ManagerState {
  ManagerState(
    profile: String,
    port: Port,
    pending: Dict(String, Subject(OwnerMessage)),
    buffer: BitArray,
  )
}

fn ensure_manager(profile: String) -> Result(Subject(ManagerMessage), String) {
  case valid_profile(profile) {
    Error(reason) -> Error(reason)
    Ok(Nil) ->
      case ffi.lookup(profile) {
        Ok(existing) -> Ok(existing)
        Error("subscription profile is not active") -> start_manager(profile)
        Error(reason) -> Error(reason)
      }
  }
}

fn valid_profile(profile: String) -> Result(Nil, String) {
  let chars = string.to_graphemes(profile)
  let allowed =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
  let initial = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  let valid = case chars {
    [first, ..rest] ->
      string.contains(initial, first)
      && list.all(rest, fn(char) { string.contains(allowed, char) })
      && string.byte_size(profile) <= 64
    [] -> False
  }
  case valid {
    True -> Ok(Nil)
    False -> Error("subscription profile is unavailable")
  }
}

fn helper_path() -> Result(String, String) {
  let bundled = install.root() <> "/bin/codex-bridge"
  case simplifile.is_file(bundled) {
    Ok(True) -> Ok(bundled)
    _ ->
      Error(
        "subscription helper is not bundled beside the running Loom release",
      )
  }
}

fn start_manager(profile: String) -> Result(Subject(ManagerMessage), String) {
  use executable <- result.try(helper_path())
  let started =
    actor.new_with_initialiser(2000, fn(subject) {
      use Nil <- result.try(ffi.claim(profile, subject))
      use port <- result.try(ffi.open_stdio(executable, profile))
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_record(
          tag: port,
          fields: 1,
          mapping: fn(raw: Dynamic) { Native(ffi.port_event(raw)) },
        )
      let state =
        ManagerState(profile:, port:, pending: dict.new(), buffer: <<>>)
      Ok(
        actor.initialised(state)
        |> actor.selecting(selector)
        |> actor.returning(subject),
      )
    })
    |> actor.unlinked
    |> actor.on_message(handle_manager)
    |> actor.start
  case started {
    Ok(started) -> Ok(started.data)
    Error(_) -> ffi.lookup(profile)
  }
}

fn handle_manager(
  state: ManagerState,
  message: ManagerMessage,
) -> actor.Next(ManagerState, ManagerMessage) {
  case message {
    Start(id, command, body, profile, owner) -> {
      case profile == state.profile, dict.has_key(state.pending, id) {
        True, False -> {
          let frame = encode_command(id, command, body, profile)
          case ffi.port_send(state.port, frame) {
            Ok(Nil) ->
              actor.continue(
                ManagerState(
                  ..state,
                  pending: dict.insert(state.pending, id, owner),
                ),
              )
            Error(Nil) -> {
              process.send(owner, ManagerLost)
              actor.stop_abnormal("subscription helper command write failed")
            }
          }
        }
        _, _ -> {
          process.send(owner, ManagerLost)
          actor.continue(state)
        }
      }
    }
    Stop(id) -> {
      let _ =
        ffi.port_send(
          state.port,
          encode_command(id, "cancel", None, state.profile),
        )
      actor.continue(state)
    }
    Native(ffi.PortBytes(bytes)) ->
      case bounded_append(state.buffer, bytes) {
        Error(Nil) ->
          actor.stop_abnormal("subscription helper frame buffer exceeded")
        Ok(buffer) ->
          case consume(state, buffer) {
            Ok(next) -> actor.continue(next)
            Error(_) ->
              actor.stop_abnormal("subscription helper protocol invalid")
          }
      }
    Native(ffi.PortClosed(_)) ->
      actor.stop_abnormal("subscription helper exited")
    Native(ffi.PortInvalid) ->
      actor.stop_abnormal("subscription helper port message invalid")
  }
}

fn encode_command(
  id: String,
  command: String,
  body: Option(String),
  profile: String,
) -> String {
  let fields = [
    #("v", json.int(1)),
    #("id", json.string(id)),
    #("cmd", json.string(command)),
    #("profile", json.string(profile)),
  ]
  let fields = case body {
    Some(encoded) -> [#("body_b64", json.string(encoded)), ..fields]
    None -> fields
  }
  json.object(fields) |> json.to_string
}

/// The exact request frame before the native four-byte prefix is attached.
/// This test seam verifies that neither a URL nor a credential field is sent.
@internal
pub fn request_command_json(
  id: String,
  profile: String,
  body: String,
) -> String {
  encode_command(id, "request", Some(body), profile)
}

type WireEvent {
  WireEvent(
    id: String,
    event: String,
    status: Int,
    data_b64: String,
    code: String,
    url: String,
    user_code: Option(String),
    plan: String,
    models: List(ModelInfo),
  )
}

type ModelInfo {
  ModelInfo(id: String, context_window: Int, reasoning_levels: List(String))
}

fn model_decoder() -> decode.Decoder(ModelInfo) {
  use id <- decode.field("id", decode.string)
  use context_window <- decode.optional_field("context_window", 0, decode.int)
  use reasoning_levels <- decode.optional_field(
    "reasoning_levels",
    [],
    decode.list(decode.string),
  )
  decode.success(ModelInfo(id:, context_window:, reasoning_levels:))
}

fn encode_models(models: List(ModelInfo)) -> String {
  json.array(models, fn(model) {
    json.object([
      #("id", json.string(model.id)),
      #("context_window", json.int(model.context_window)),
      #("reasoning_levels", json.array(model.reasoning_levels, json.string)),
    ])
  })
  |> json.to_string
}

fn consume(state: ManagerState, buffer: BitArray) -> Result(ManagerState, Nil) {
  use next <- result.try(split_frame(buffer))
  case next {
    None -> Ok(ManagerState(..state, buffer:))
    Some(#(frame, tail)) -> {
      use event <- result.try(decode_event(frame))
      use state <- result.try(route_event(state, event))
      consume(state, tail)
    }
  }
}

fn bounded_append(held: BitArray, incoming: BitArray) -> Result(BitArray, Nil) {
  case
    bit_array.byte_size(held) + bit_array.byte_size(incoming)
    <= max_frame * 2 + 8
  {
    True -> Ok(bit_array.append(held, incoming))
    False -> Error(Nil)
  }
}

/// Splits one complete helper frame from an arbitrary byte fragment.
/// Partial frames wait, while zero and oversized declared lengths fail.
@internal
pub fn split_frame(
  buffer: BitArray,
) -> Result(Option(#(BitArray, BitArray)), Nil) {
  case buffer {
    <<size:int-size(32), rest:bits>> if size > 0 && size <= max_frame ->
      case bit_array.byte_size(rest) >= size {
        False -> Ok(None)
        True -> {
          use frame <- result.try(bit_array.slice(rest, 0, size))
          use tail <- result.try(bit_array.slice(
            rest,
            size,
            bit_array.byte_size(rest) - size,
          ))
          Ok(Some(#(frame, tail)))
        }
      }
    <<_size:int-size(32), _rest:bits>> -> Error(Nil)
    _ -> Ok(None)
  }
}

/// Validates the versioned JSON shape before a frame is routed to any owner.
@internal
pub fn event_name(frame: BitArray) -> Result(String, Nil) {
  decode_event(frame) |> result.map(fn(event) { event.event })
}

fn decode_event(frame: BitArray) -> Result(WireEvent, Nil) {
  use event <- result.try(
    json.parse_bits(frame, event_decoder()) |> result.replace_error(Nil),
  )
  case valid_wire_event(event) {
    True -> Ok(event)
    False -> Error(Nil)
  }
}

fn valid_wire_event(event: WireEvent) -> Bool {
  let code_chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
  let model_chars = code_chars <> ".:/"
  let uri_chars = model_chars <> "?&=%+~#@!$'()*,;"
  let id_ok =
    string.starts_with(event.id, "loom-")
    && safe_chars(event.id, 128, code_chars)
  let code_ok = event.code == "" || safe_chars(event.code, 64, code_chars)
  let plan_ok = event.plan == "" || safe_chars(event.plan, 64, code_chars)
  let url_ok =
    event.url == ""
    || {
      string.starts_with(event.url, "https://auth.openai.com/")
      && safe_chars(event.url, 4096, uri_chars)
    }
  let user_code_ok = case event.user_code {
    None -> True
    Some(value) -> safe_chars(value, 64, code_chars)
  }
  let models_ok =
    list.length(event.models) <= 512
    && list.all(event.models, fn(model) {
      safe_chars(model.id, 128, model_chars)
      && model.context_window >= 0
      && list.length(model.reasoning_levels) <= 16
      && list.all(model.reasoning_levels, fn(level) {
        safe_chars(level, 32, code_chars)
      })
    })
  id_ok && code_ok && plan_ok && url_ok && user_code_ok && models_ok
}

fn safe_chars(value: String, max_bytes: Int, allowed: String) -> Bool {
  value != ""
  && string.byte_size(value) <= max_bytes
  && list.all(string.to_graphemes(value), fn(char) {
    string.byte_size(char) == 1 && string.contains(allowed, char)
  })
}

fn event_decoder() -> decode.Decoder(WireEvent) {
  use version <- decode.field("v", decode.int)
  use id <- decode.field("id", decode.string)
  use event <- decode.field("event", decode.string)
  use status <- decode.optional_field("status", 0, decode.int)
  use data_b64 <- decode.optional_field("data_b64", "", decode.string)
  use code <- decode.optional_field("code", "", decode.string)
  use url <- decode.optional_field("url", "", decode.string)
  use user_code <- decode.optional_field(
    "user_code",
    None,
    decode.optional(decode.string),
  )
  use plan <- decode.optional_field("plan", "", decode.string)
  use models <- decode.optional_field(
    "models",
    [],
    decode.list(model_decoder()),
  )
  case version {
    1 ->
      decode.success(WireEvent(
        id:,
        event:,
        status:,
        data_b64:,
        code:,
        url:,
        user_code:,
        plan:,
        models:,
      ))
    _ ->
      decode.failure(
        WireEvent(
          id:,
          event:,
          status:,
          data_b64:,
          code:,
          url:,
          user_code:,
          plan:,
          models:,
        ),
        expected: "version 1",
      )
  }
}

fn route_event(
  state: ManagerState,
  event: WireEvent,
) -> Result(ManagerState, Nil) {
  use owner <- result.try(dict.get(state.pending, event.id))
  process.send(owner, Frame(event))
  case event.event {
    "end" | "cancel_ack" ->
      Ok(ManagerState(..state, pending: dict.delete(state.pending, event.id)))
    "http_status"
    | "chunk"
    | "login_instructions"
    | "error"
    | "login_complete"
    | "models"
    | "status"
    | "logout_complete" -> Ok(state)
    _ -> Error(Nil)
  }
}
