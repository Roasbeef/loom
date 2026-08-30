//// Provider transport helpers shared by client tests.
////
//// These transports perform only in-memory scripted work. Each call gets a
//// monitorable owner process, and cancellation kills that owner, matching the
//// production transport contract without pretending to cancel external I/O.

import gleam/erlang/process.{type Subject}
import provider/http

pub fn transport(
  replay: fn(http.HttpRequest, Subject(http.HttpEvent)) -> Nil,
) -> http.Transport {
  http.Transport(prepare_streaming: fn(request, events) {
    let ready = process.new_subject()
    let owner =
      process.spawn_unlinked(fn() {
        let begin = process.new_subject()
        process.send(ready, begin)
        let _permit = process.receive_forever(begin)
        replay(request, events)
      })
    let begin = process.receive_forever(ready)
    Ok(
      http.PreparedRequest(
        running: http.RunningRequest(owner:, cancel: fn() {
          process.kill(owner)
        }),
        begin: fn() { process.send(begin, Nil) },
      ),
    )
  })
}

pub fn silent() -> http.Transport {
  transport(fn(_request, _events) { Nil })
}
