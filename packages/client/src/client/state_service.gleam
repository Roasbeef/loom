//// The one process that owns a node's state store (protocol-change/107).
////
//// `client/state_store` has no lock. It is correct when one process owns its
//// directory and serializes its calls, as the other stores under the state root
//// are owned by one actor each. A node can be asked for pieces from two places,
//// the orchestrator port when it is the parent's or the target's node and the
//// executor host when it holds the repository, and a retry after a silence can
//// overlap the call it retries, so neither carrier may touch the store itself.
//// This actor is the owner. Both carriers get the `Endpoint` it builds
//// (`client/state_transfer`), each call is a message answered in the owner's own
//// turn, and a daemon that is orchestrator and executor at once starts one
//// service and gives it to both.
////
//// The carriers call the endpoint from runs of their own, so a piece that makes
//// a state, which reads and hashes the whole bundle, never delays the port's
//// answer about ownership or the host's admission of a tool call. It delays only
//// the next question about states. A caller waits a bounded time for the owner,
//// and a wait that runs out is a `Failed` verdict, not silence, because the
//// carrier is alive and the sender should ask again.
////
//// ## Flow
////
//// `start` → `endpoint` → `handle`
////
//// 1. `start` registers nothing and links the actor to the caller, which is the
////    daemon's process for starting services.
//// 2. `endpoint` turns the actor into the three functions the carriers call.
////    Each sends a request carrying a reply subject and waits for it.
//// 3. `handle` answers one request from the store it owns and waits for the
////    next.

import client/state_store.{type Store}
import client/state_transfer.{
  type Endpoint, type Fetched, type Piece, type Stage, type Verdict,
}
import gleam/erlang/process.{type Subject}
import gleam/result
import gleam/string
import weft/actor

/// How long a caller waits for the owner, in milliseconds. The last piece of a
/// 256 MiB state is read, hashed and renamed in one turn, so the bound is generous;
/// a store that has not answered after it is not coming back soon.
pub const answer_wait_ms = 120_000

/// What the owner is asked.
type Request {
  /// Takes one piece into the store.
  Take(piece: Piece, reply: Subject(Verdict))

  /// How far a state has got.
  Stat(hash: String, reply: Subject(Result(Stage, String)))

  /// Cuts one piece out of a held state.
  Serve(hash: String, offset: Int, reply: Subject(Fetched))
}

/// A running owner of a state store.
pub opaque type Service {
  Service(inbox: Subject(Request))
}

/// Starts the owner of `store`, linked to the caller. `now_s` is the clock the
/// store's sweep reads, in Unix seconds.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(service) = state_service.start(store, fn() { bootstrap.system_time_ms() / 1000 })
/// ```
pub fn start(store: Store, now_s: fn() -> Int) -> Result(Service, String) {
  actor.new(Nil)
  |> actor.on_message(fn(state, request) {
    handle(store, now_s, state, request)
  })
  |> actor.start
  |> result.map(fn(started) { Service(inbox: started.data) })
  |> result.map_error(fn(error) {
    "the state service did not start: " <> string.inspect(error)
  })
}

/// The three answers a carrier gives for a node, over the service. Each call
/// sends one request and waits at most `answer_wait_ms` for the owner's reply.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.start_with_states(.., state_service.endpoint(service))
/// ```
pub fn endpoint(service: Service) -> Endpoint {
  state_transfer.Endpoint(
    take: fn(piece) {
      ask(service, fn(reply) { Take(piece:, reply:) })
      |> result.unwrap(state_transfer.Failed(unanswered))
    },
    stage: fn(hash) {
      ask(service, fn(reply) { Stat(hash:, reply:) })
      |> result.unwrap(Error(unanswered))
    },
    serve: fn(hash, offset) {
      ask(service, fn(reply) { Serve(hash:, offset:, reply:) })
      |> result.unwrap(state_transfer.FetchFailed(unanswered))
    },
  )
}

/// What a caller reports when the owner did not answer in time.
const unanswered = "the state store did not answer in time"

/// One request and its reply, or `Error(Nil)` when the owner is silent.
fn ask(
  service: Service,
  request: fn(Subject(answer)) -> Request,
) -> Result(answer, Nil) {
  let reply = process.new_subject()
  process.send(service.inbox, request(reply))
  process.receive(reply, answer_wait_ms)
}

/// Answers one request from the store the owner holds.
fn handle(
  store: Store,
  now_s: fn() -> Int,
  state: Nil,
  request: Request,
) -> actor.Next(Nil, Request) {
  // Each request is answered from the store in this turn, so no two of them
  // touch the directory at once. The service never crashes on a store fault:
  // the store reports one as a verdict, and the carrier passes it on.
  case request {
    Take(piece:, reply:) ->
      process.send(reply, state_transfer.take(store, piece, now_s()))
    Stat(hash:, reply:) ->
      process.send(reply, state_transfer.stage(store, hash))
    Serve(hash:, offset:, reply:) ->
      process.send(reply, state_transfer.serve(store, hash, offset))
  }

  actor.continue(state)
}
