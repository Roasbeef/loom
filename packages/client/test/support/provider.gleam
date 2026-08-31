//// Provider transport helpers shared by client tests.
////
//// These transports perform only in-memory scripted work. Each call gets a
//// monitorable owner process, and cancellation kills that owner, matching the
//// production transport contract without pretending to cancel external I/O.

import gleam/erlang/process.{type Subject}
import provider/http

type ScriptControl {
  BeginScript
  CancelScript
  CreatorExited
}

pub fn transport(
  replay: fn(http.HttpRequest, Subject(http.HttpEvent)) -> Nil,
) -> http.Transport {
  http.Transport(prepare_streaming: fn(request, events) {
    let creator = process.self()
    let ready = process.new_subject()
    let owner =
      process.spawn_unlinked(fn() {
        let control = process.new_subject()
        let creator_monitor = process.monitor(creator)
        process.send(ready, control)
        let command =
          process.new_selector()
          |> process.select_map(control, fn(command) { command })
          |> process.select_specific_monitor(creator_monitor, fn(_down) {
            CreatorExited
          })
          |> process.selector_receive_forever()
        process.demonitor_process(creator_monitor)
        case command {
          BeginScript -> replay(request, events)
          CancelScript | CreatorExited -> Nil
        }
      })
    let control = process.receive_forever(ready)
    Ok(
      http.PreparedRequest(
        running: http.RunningRequest(owner:, cancel: fn() {
          process.send(control, CancelScript)
        }),
        begin: fn() { process.send(control, BeginScript) },
      ),
    )
  })
}

pub fn silent() -> http.Transport {
  transport(fn(_request, _events) { Nil })
}
