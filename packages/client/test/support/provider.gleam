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
  http.Transport(start_streaming: fn(request, events) {
    let owner = process.spawn_unlinked(fn() { replay(request, events) })
    Ok(http.RunningRequest(owner:, cancel: fn() { process.kill(owner) }))
  })
}

pub fn silent() -> http.Transport {
  transport(fn(_request, _events) { Nil })
}
