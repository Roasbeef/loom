//// Native owner-only asynchronous control for reviewed harness components.
////
//// Admission returns a queued receipt, so the session gateway remains able to
//// serve ordinary requests while acquisition or one component migration runs.
//// One operation per session is active, and at most 64 immutable request records
//// are retained. Exact replay is idempotent; reuse with another payload refuses.
//// Tasks use managed custodians, making normal drain include resumed service.

import client/evolution/control as evolution
import client/scratch
import client/upgrade/controller
import client/upgrade/source
import client/upgrade/state as abi
import core/json
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision
import gleam/result
import gleam/string
import storage/access
import weft
import weft/actor
import weft/registry

/// The restartable native control owner's private message ABI.
pub opaque type Message {
  Submit(controller.Request, String, Subject(Result(json.JsonValue, String)))
  Status(Option(String), Subject(Result(json.JsonValue, String)))
  Report(weft.Pulled(controller.Receipt, String))
}

type Entry {
  Entry(request: controller.Request, principal: String, receipt: json.JsonValue)
}

type State {
  State(
    scratch: registry.Address(scratch.Message),
    entries: Dict(String, Entry),
    active: Option(String),
    reports: Subject(weft.Pulled(controller.Receipt, String)),
  )
}

/// Starts one session's nonblocking native control owner.
/// ## Examples
/// `start(control_address, scratch_address)` exposes no model-facing authority.
pub fn start(
  name: registry.Address(Message),
  scratch_name: registry.Address(scratch.Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(inbox) {
    let reports = process.new_subject()
    Ok(
      actor.initialised(State(scratch_name, dict.new(), None, reports))
      |> actor.selecting(
        process.new_selector()
        |> process.select(inbox)
        |> process.select_map(reports, Report),
      )
      |> actor.returning(inbox),
    )
  })
  |> actor.on_message(handle)
  |> actor.addressed(name)
  |> actor.start
}

/// Restartable sibling of scratch; managed tasks retain cleanup custody.
/// ## Examples
/// `supervised(control_address, scratch_address)` fits the existing service tree.
pub fn supervised(
  name: registry.Address(Message),
  scratch_name: registry.Address(scratch.Message),
) -> supervision.ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(name, scratch_name) })
}

/// Session-bound owner-only native door, composed with ordinary evolution.
/// ## Examples
/// `seam(name).command(access.Owner, principal, "core_status", args)` is native-only.
pub fn seam(name: registry.Address(Message)) -> evolution.Seam {
  evolution.Seam(command: fn(authority, principal, action, args) {
    use _ <- result.try(case authority {
      access.Owner -> Ok(Nil)
      access.Participant(_) ->
        Error("Forbidden: reviewed harness upgrades require the native owner")
    })
    case action {
      "core_status" -> {
        use request_id <- result.try(status_args(args))
        ask(name, Status(request_id, _)) |> result.flatten
      }
      "core_upgrade" | "core_downgrade" -> {
        use request <- result.try(parse(args))
        ask(name, Submit(request, principal, _)) |> result.flatten
      }
      _ -> Error("Unknown: unsupported reviewed harness action")
    }
  })
}

fn ask(
  name: registry.Address(Message),
  request: fn(Subject(answer)) -> Message,
) -> Result(answer, String) {
  use subject <- result.try(
    registry.lookup(name)
    |> result.replace_error("native harness control is unavailable"),
  )
  use pid <- result.try(
    process.subject_owner(subject)
    |> result.replace_error("native harness control is unavailable"),
  )
  let reply = process.new_subject()
  let monitor = process.monitor(pid)
  process.send(subject, request(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) {
      Error("native harness control exited")
    })
    |> process.selector_receive(1500)
  process.demonitor_process(monitor)
  result.unwrap(answer, Error("native harness control did not answer"))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Submit(request, principal, reply) ->
      submit(state, request, principal, reply)
    Status(request_id, reply) -> {
      let answer = status(state, request_id)
      process.send(reply, answer)
      actor.continue(state)
    }
    Report(weft.PulledOutcome(outcome)) ->
      actor.continue(record_outcome(state, outcome))
    Report(weft.NotYet) -> actor.continue(state)
    Report(weft.AllDelivered) -> actor.continue(State(..state, active: None))
    Report(weft.RunLost(_)) ->
      actor.continue(record_failed(
        state,
        "managed harness operation cleanup was lost",
      ))
  }
}

fn submit(
  state: State,
  request: controller.Request,
  principal: String,
  reply: Subject(Result(json.JsonValue, String)),
) -> actor.Next(State, Message) {
  case dict.get(state.entries, request.request_id) {
    Ok(entry) -> {
      let answer = case
        entry.request == request && entry.principal == principal
      {
        True -> Ok(entry.receipt)
        False ->
          Error(
            "Conflict: request identity was already used for another payload or principal",
          )
      }
      process.send(reply, answer)
      actor.continue(state)
    }
    Error(Nil) -> admit(state, request, principal, reply)
  }
}

fn admit(
  state: State,
  request: controller.Request,
  principal: String,
  reply: Subject(Result(json.JsonValue, String)),
) -> actor.Next(State, Message) {
  let admitted = case state.active, dict.size(state.entries) < 64 {
    None, True -> Ok(Nil)
    Some(_), _ -> Error("Busy: another reviewed harness operation is active")
    None, False ->
      Error("native harness receipt capacity is full for this session")
  }
  case admitted {
    Error(reason) -> {
      process.send(reply, Error(reason))
      actor.continue(state)
    }
    Ok(Nil) -> {
      let receipt =
        json.Object([
          #("request_id", json.String(request.request_id)),
          #("status", json.String("queued")),
        ])
      let run =
        weft.new_prepared([
          controller.prepared(state.scratch, request, process.self()),
        ])
        |> weft.deadline(130_000)
        |> weft.cancel_grace(3000)
      let _relay = weft.start_relayed(run, to: state.reports)
      process.send(reply, Ok(receipt))
      actor.continue(
        State(
          ..state,
          active: Some(request.request_id),
          entries: dict.insert(
            state.entries,
            request.request_id,
            Entry(request, principal, receipt),
          ),
        ),
      )
    }
  }
}

fn record_outcome(
  state: State,
  outcome: weft.Outcome(controller.Receipt, String),
) -> State {
  case outcome {
    weft.Completed(value:, ..) -> record(state, receipt_json(value))
    weft.Failed(error:, ..) -> record_failed(state, error)
    weft.Crashed(..) -> record_failed(state, "harness operation crashed")
    weft.Abandoned(..) | weft.NeverStarted(..) ->
      record_failed(state, "harness operation cancelled or expired")
    weft.DrainProofLost(..) | weft.CancellationUnconfirmed(..) ->
      record_failed(state, "harness operation cleanup remains unconfirmed")
  }
}

fn record_failed(state: State, reason: String) -> State {
  record(
    state,
    json.Object([
      #("status", json.String("refused")),
      #("error", json.String(reason)),
    ]),
  )
}

fn record(state: State, receipt: json.JsonValue) -> State {
  case state.active {
    None -> state
    Some(request_id) ->
      case dict.get(state.entries, request_id) {
        Error(Nil) -> state
        Ok(entry) ->
          State(
            ..state,
            entries: dict.insert(
              state.entries,
              request_id,
              Entry(..entry, receipt:),
            ),
          )
      }
  }
}

fn status(
  state: State,
  request_id: Option(String),
) -> Result(json.JsonValue, String) {
  case request_id {
    Some(request_id) ->
      dict.get(state.entries, request_id)
      |> result.map(fn(entry) {
        json.Object([
          #("request_id", json.String(request_id)),
          #("receipt", entry.receipt),
        ])
      })
      |> result.replace_error("unknown reviewed harness request identity")
    None -> {
      use subject <- result.try(
        registry.lookup(state.scratch)
        |> result.replace_error("scratch component is unavailable"),
      )
      use pid <- result.try(
        process.subject_owner(subject)
        |> result.replace_error("scratch recipient is unavailable"),
      )
      use observed <- result.try(scratch.observe_subject(subject, 100))
      Ok(
        json.Object([
          #("pid", json.String(string.inspect(pid))),
          ..observation_fields(observed)
        ]),
      )
    }
  }
}

fn receipt_json(receipt: controller.Receipt) -> json.JsonValue {
  json.Object([
    #("request_id", json.String(receipt.request_id)),
    #("status", json.String(receipt.status)),
    #("pid", json.String(string.inspect(receipt.pid))),
    #("pause_ms", json.Int(receipt.pause_ms)),
    #("component", observation_json(receipt.observation)),
    #("error", case receipt.error {
      None -> json.Null
      Some(reason) -> json.String(reason)
    }),
  ])
}

fn observation_json(observed: abi.Observation) -> json.JsonValue {
  json.Object(observation_fields(observed))
}

fn observation_fields(
  observed: abi.Observation,
) -> List(#(String, json.JsonValue)) {
  [
    #("component", json.String("scratch")),
    #("version", json.String(observed.identity.version)),
    #("digest", json.String(observed.identity.digest)),
    #("state_version", json.String(observed.identity.state_version)),
    #("boundary", json.String(observed.identity.boundary)),
    #("reported_version", json.String(observed.reported_version)),
    #("entries", json.Int(observed.entries)),
    #("bytes", json.Int(observed.bytes)),
  ]
}

fn parse(args: json.JsonValue) -> Result(controller.Request, String) {
  use fields <- result.try(object(args))
  use <- bool.guard(
    list.any(fields, fn(field) {
      !list.contains(
        [
          "request_id",
          "component",
          "expected_version",
          "expected_digest",
          "target_release",
          "manifest_digest",
          "pause_ms",
        ],
        field.0,
      )
    }),
    Error("unknown reviewed harness argument"),
  )
  use request_id <- result.try(text(fields, "request_id"))
  use component <- result.try(text(fields, "component"))
  use expected_version <- result.try(text(fields, "expected_version"))
  use expected_digest <- result.try(text(fields, "expected_digest"))
  use target_release <- result.try(text(fields, "target_release"))
  use manifest_digest <- result.try(text(fields, "manifest_digest"))
  use pause_ms <- result.try(number(fields, "pause_ms"))
  use <- bool.guard(
    !source.basename(request_id)
      || !source.basename(expected_version)
      || {
      expected_digest != "builtin" && !source.hexadecimal(expected_digest, 64)
    }
      || component != "scratch"
      || pause_ms < 400
      || pause_ms > 1000,
    Error("invalid request identity, component or bounded pause"),
  )
  use <- bool.guard(
    target_release != "builtin"
      && {
      !source.basename(target_release)
      || !source.hexadecimal(manifest_digest, 64)
    },
    Error("an official release tag and exact manifest digest are required"),
  )
  Ok(controller.Request(
    request_id,
    component,
    expected_version,
    expected_digest,
    target_release,
    manifest_digest,
    pause_ms,
  ))
}

fn status_args(args) {
  use fields <- result.try(object(args))
  case fields {
    [] -> Ok(None)
    [#("request_id", json.String(value))] -> Ok(Some(value))
    _ -> Error("core_status accepts only an optional request_id")
  }
}

fn object(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("native harness arguments must be an object")
  }
}

fn field(fields, key) {
  list.key_find(fields, key)
  |> result.map_error(fn(_) { "native harness arguments lack " <> key })
}

fn text(fields, key) {
  use value <- result.try(field(fields, key))
  case value {
    json.String(value) -> Ok(value)
    _ -> Error("native harness argument must be text: " <> key)
  }
}

fn number(fields, key) {
  use value <- result.try(field(fields, key))
  case value {
    json.Int(value) -> Ok(value)
    _ -> Error("native harness argument must be an integer: " <> key)
  }
}
