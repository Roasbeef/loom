//// Native control is owner-only, asynchronous and exact-request idempotent.

import client/scratch
import client/upgrade/control
import core/json
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit/should
import storage/access
import support/addresses
import weft/poll

fn args(id: String) -> json.JsonValue {
  json.Object([
    #("request_id", json.String(id)),
    #("component", json.String("scratch")),
    #("expected_version", json.String("builtin")),
    #("expected_digest", json.String("builtin")),
    #("target_release", json.String("builtin")),
    #("manifest_digest", json.String("builtin")),
    #("pause_ms", json.Int(1000)),
  ])
}

pub fn owner_control_queues_and_preserves_exact_replay_test() -> Nil {
  let scratch_name = addresses.new()
  let control_name = addresses.new()
  let assert Ok(store) = scratch.start(scratch_name, scratch.default_bounds())
    as "the production store starts"
  let assert Ok(owner) = control.start(control_name, scratch_name)
    as "the production nonblocking control owner starts"
  let door = control.seam(control_name)
  let assert Ok(json.Object(current)) =
    door.command(access.Owner, "owner", "core_status", json.Object([]))
    as "native status reports the actual recipient"
  list.key_find(current, "pid")
  |> should.equal(Ok(json.String(string.inspect(store.pid))))
  let asked = args("same-request")
  door.command(
    access.Participant(access.Operator),
    "participant",
    "core_upgrade",
    asked,
  )
  |> should.be_error
  door.command(
    access.Participant(access.Observer),
    "observer",
    "core_status",
    json.Object([]),
  )
  |> should.be_error
  let assert Ok(queued) =
    door.command(access.Owner, "owner", "core_downgrade", asked)
    as "native owner receives a queued acknowledgement"
  status(queued) |> should.equal("queued")
  door.command(access.Owner, "another-owner", "core_downgrade", asked)
  |> should.be_error
  let changed = case asked {
    json.Object(fields) ->
      json.Object(
        list.map(fields, fn(field) {
          case field.0 {
            "pause_ms" -> #(field.0, json.Int(900))
            _ -> field
          }
        }),
      )
    _ -> asked
  }
  door.command(access.Owner, "owner", "core_downgrade", changed)
  |> should.be_error
  let completed =
    poll.until(2000, 5, fn() {
      let answer =
        door.command(
          access.Owner,
          "owner",
          "core_status",
          json.Object([#("request_id", json.String("same-request"))]),
        )
      case answer {
        Ok(json.Object(fields)) ->
          case list.key_find(fields, "receipt") {
            Ok(receipt) ->
              case status(receipt) {
                "installed" -> poll.Done(receipt)
                "queued" -> poll.Retry
                _ -> poll.Fail(receipt)
              }
            Error(_) -> poll.Retry
          }
        _ -> poll.Retry
      }
    })
  let assert poll.Answered(receipt) = completed
    as "the queued managed operation completes"
  door.command(access.Owner, "owner", "core_downgrade", asked)
  |> should.equal(Ok(receipt))
  scratch.stat(scratch_name, timeout_ms: 1000) |> should.equal(#(0, 0))
  process.unlink(owner.pid)
  process.kill(owner.pid)
  let watcher = process.monitor(store.pid)
  scratch.stop(scratch_name)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(watcher, fn(_) { Nil })
  process.selector_receive(selector, 1000) |> should.equal(Ok(Nil))
}

fn status(value: json.JsonValue) -> String {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, "status") {
        Ok(json.String(status)) -> status
        _ -> "unknown"
      }
    _ -> "unknown"
  }
}
