//// One ACP session: a Loom conversation lane, driven turn by turn.
////
//// An ACP session is a Loom session seen through the same credited lane
//// (`session_view/session_channel`) the terminal and `loom run -p` drive. This
//// module is that lane's owner for one session. It is a pure reducer: it never
//// writes to a socket or to standard output. Each entry point takes the new
//// event and the caller's monotonic clock reading and returns the next
//// `Session` with the `Action`s the server must perform, in order. The server
//// owns the processes and the transport; this module owns the *meaning* of
//// the exchange, which is where the races are.
////
//// Three facts shape it.
////
//// First, the lane admits one mutation at a time and answers it with an
//// acknowledgement, so commands wait in a queue here and leave one by one.
//// An abort therefore never overtakes the prompt it cancels, and an approval
//// never races the prompt that is still being acknowledged.
////
//// Second, a prompt has no reply of its own. The daemon acknowledges that the
//// run was *accepted*; the run ends later, as a durable `last_result` on the
//// `main` strand. The turn therefore remembers the operation id of whatever
//// result was there before the prompt, and ends on the first run result with a
//// different one. That is the same settling rule `loom run -p` uses, extended
//// to many turns on one session.
////
//// Third, output arrives twice: as live fragments pushed while the model
//// writes, and later as the durable message. `tui/acp/translate` reconciles the
//// two by content, and this module only threads its `Streamed` value through.
////
//// ## Flow
////
//// `start` → `receive` / `tick` → `absorb` → `on_cut` → `settle` → `finish`
////
//// 1. `start` queues the model-catalogue read and waits for the first cut.
//// 2. `receive` and `tick` feed the lane and `absorb` each update it makes.
//// 3. `on_cut` shows entries the client has not seen, forwards pending
////    escalations as permission requests, and calls `settle`.
//// 4. `settle` ends a turn when the run's terminal result appears; the turn
////    then reads the context size once so the reply can carry a usage update,
////    and `finish` answers the prompt request.
//// 5. `pump` sends the next queued command whenever the lane can take it.
////
//// ## Transitions
////
//// <!-- transitions: session.Phase -->
////
//// | state | prompt | cancel | first cut and catalogue | run result | lane failure |
//// | --- | --- | --- | --- | --- | --- |
//// | `Attaching` | refused | ignored | `Idle`, answering `session/new` or `session/load` | ignored | `Dead`, answering the attach with an error |
//// | `Idle` | `Turning` | ignored | ignored | ignored | `Dead` |
//// | `Turning` | refused | queues an abort, or answers `cancelled` if the prompt was never sent | ignored | `Idle`, answering the prompt | `Dead`, answering the prompt with an error |
//// | `Dead` | refused | ignored | ignored | ignored | ignored |

import core/entry as core_entry
import core/ids
import core/json.{type JsonValue}
import core/message
import core/register
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import machine/codec as machine_codec
import machine/operation
import session_view/approval
import session_view/connection_event
import session_view/context_view
import session_view/protocol
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import tui/acp/rpc
import tui/acp/schema
import tui/acp/translate
import tui/connection

/// The lane type this module drives.
pub type Lane =
  session_channel.Channel(connection.Connection, Nil)

/// Whether the attach answers `session/new` or `session/load`.
pub type Attach {
  /// A session this connection just created: history, if any, is not replayed.
  Created

  /// A saved session the client asked to resume: its transcript is replayed
  /// before the response, as ACP requires.
  Loaded
}

/// What the server must do after an entry point returns.
pub type Action {
  /// Send a notification to the client.
  Notify(method: String, params: JsonValue)

  /// Answer a client request.
  Respond(id: rpc.Id, outcome: Result(JsonValue, rpc.WireError))

  /// Send a `session/request_permission` request. The server picks the request
  /// id and routes the client's reply to `answer` under `review_id`.
  Ask(review_id: String, params: JsonValue)

  /// Perform one lane output: a frame to the daemon, or a socket close.
  Write(output: session_channel.Out(connection.Connection, Nil))

  /// The session can make no more progress and should be dropped.
  Ended(reason: String)
}

/// Whether a cancellation has been asked for the running turn.
type Cancellation {
  /// Nothing has asked the turn to stop.
  NotAsked

  /// The client sent `session/cancel`, so the turn ends `cancelled` however
  /// the run itself ends.
  Asked
}

/// Where a turn is between the prompt and its reply.
type Stage {
  /// The prompt is queued or awaiting the daemon's acknowledgement.
  Sending

  /// The daemon accepted the run.
  Running

  /// The run ended; the context size is being read for the usage update.
  Settling(outcome: translate.Outcome, until: Int)
}

/// One prompt turn.
type Turn {
  Turn(
    /// The `session/prompt` request being answered.
    reply: rpc.Id,
    /// The operation id of the `main` result present before the prompt, so an
    /// earlier turn's result cannot end this one.
    baseline: Option(String),
    /// The session's cumulative usage when the prompt was accepted.
    usage_before: message.Usage,
    /// Whether the client asked to stop.
    cancellation: Cancellation,
    /// How far the turn has got.
    stage: Stage,
  )
}

/// The session's lifecycle.
type Phase {
  /// Waiting for the first cut and the model catalogue.
  Attaching(intent: Attach, reply: rpc.Id)

  /// Ready for a prompt.
  Idle

  /// A prompt is in flight.
  Turning(turn: Turn)

  /// The lane failed or closed.
  Dead
}

/// A command for the lane.
type Command {
  PromptTurn(content: List(message.UserBlock))
  AbortTurn
  Decide(review: approval.Review, decision: translate.Decision)
  SwitchModel(name: String, answer: schema.ModelAnswer)
  ReadModels
  ReadContext
}

/// A command with the request, if any, its acknowledgement answers.
type Queued {
  Queued(command: Command, reply: Option(rpc.Id))
}

/// The most tool-call ids remembered as announced.
const max_announced = 512

/// How long the context read may take before the reply goes out without it, in
/// milliseconds.
const settle_wait_ms = 3000

/// One ACP session over one Loom lane.
pub opaque type Session {
  Session(
    id: String,
    lane: Lane,
    phase: Phase,
    cut: Option(#(snapshot.Captured, snapshot_view.View)),
    shown_seq: Int,
    streamed: translate.Streamed,
    announced: List(String),
    asked: List(String),
    catalogue: Option(List(protocol.ModelInfo)),
    requested_model: Option(String),
    queue: List(Queued),
    in_flight: Option(Queued),
  )
}

/// A reducer result: the next session and what to do.
type Step =
  #(Session, List(Action))

/// Begins a session over a freshly opened socket.
///
/// The lane starts its subscription immediately; the catalogue read is queued
/// behind it and goes out when the first cut has arrived. `reply` is the
/// `session/new` or `session/load` request that is answered once both are in.
///
/// ## Examples
///
/// ```gleam
/// // session.start(id, socket, expected, session.Created, rpc.NumberId(1), None, now)
/// ```
pub fn start(
  id: String,
  socket: connection.Connection,
  expected: snapshot.Expected,
  intent: Attach,
  reply: rpc.Id,
  model: Option(String),
  now: Int,
) -> Step {
  // A model requested at creation is switched to before the catalogue is
  // read, so the catalogue the client sees already names it current.
  let switch = case model {
    Some(name) -> [Queued(SwitchModel(name, schema.LegacyAnswer), None)]
    None -> []
  }

  Session(
    id:,
    lane: session_channel.start(socket, expected, now:),
    phase: Attaching(intent, reply),
    cut: None,
    shown_seq: -1,
    streamed: translate.nothing_streamed,
    announced: [],
    asked: [],
    catalogue: None,
    requested_model: model,
    queue: list.append(switch, [Queued(ReadModels, None)]),
    in_flight: None,
  )
  |> settle_io(now, [])
}

/// The session's Loom id, which is also its ACP session id.
///
/// ## Examples
///
/// ```gleam
/// // session.id(session) == "01J..."
/// ```
pub fn id(session: Session) -> String {
  session.id
}

/// Whether the session has failed or closed and should be dropped.
///
/// ## Examples
///
/// ```gleam
/// // session.is_dead(session)
/// ```
pub fn is_dead(session: Session) -> Bool {
  session.phase == Dead
}

/// The instant the session next needs a tick, or `None` when it can wait.
///
/// ## Examples
///
/// ```gleam
/// // session.next_due(session) == Some(1250)
/// ```
pub fn next_due(session: Session) -> Option(Int) {
  // Only a turn that is reading its final context figure has a deadline of
  // its own; every other wake-up belongs to the lane.
  let settling = case session.phase {
    Turning(Turn(stage: Settling(until:, ..), ..)) -> Some(until)
    Attaching(..) | Idle | Turning(..) | Dead -> None
  }

  // The session needs waking at the earlier of the two.
  case session_channel.next_due(session.lane), settling {
    Some(lane), Some(until) -> Some(int.min(lane, until))
    Some(lane), None -> Some(lane)
    None, until -> until
  }
}

/// Feeds one socket event through the lane.
///
/// ## Examples
///
/// ```gleam
/// // session.receive(session, connection_event.Incoming(text), now)
/// ```
pub fn receive(
  session: Session,
  event: connection_event.Message,
  now: Int,
) -> Step {
  let #(lane, updates) = session_channel.receive(session.lane, event, now:)
  Session(..session, lane:)
  |> absorb_all(updates, now)
}

/// Lets the lane's timers and the settling deadline act.
///
/// ## Examples
///
/// ```gleam
/// // session.tick(session, now)
/// ```
pub fn tick(session: Session, now: Int) -> Step {
  let #(lane, updates) = session_channel.tick(session.lane, now:)
  let #(session, actions) = absorb_all(Session(..session, lane:), updates, now)

  // A context read that has not come back by its deadline is given up on, so
  // the prompt is answered rather than held for a figure that is only a nicety.
  case session.phase {
    Turning(Turn(stage: Settling(until:, ..), ..) as turn) if now >= until -> {
      let #(session, more) = finish(session, turn, None)
      #(session, list.append(actions, more))
    }
    Attaching(..) | Idle | Turning(..) | Dead -> #(session, actions)
  }
}

/// Starts a prompt turn, or refuses one that cannot start.
///
/// ## Examples
///
/// ```gleam
/// // session.prompt(session, rpc.NumberId(3), blocks, now)
/// ```
pub fn prompt(
  session: Session,
  reply: rpc.Id,
  content: List(message.UserBlock),
  now: Int,
) -> Step {
  // A turn starts only from idle with a held cut, because the baseline that
  // tells this turn's result from an older one is read from that cut.
  case session.phase, session.cut {
    Idle, Some(#(_, view)) -> {
      let turn =
        Turn(
          reply:,
          baseline: option.map(last_result(view), fn(found) { found.0 }),
          usage_before: view.usage,
          cancellation: NotAsked,
          stage: Sending,
        )
      Session(
        ..session,
        phase: Turning(turn),
        streamed: translate.nothing_streamed,
      )
      |> enqueue(Queued(PromptTurn(content), None))
      |> settle_io(now, [])
    }
    Idle, None | Attaching(..), _ | Turning(..), _ | Dead, _ ->
      refuse(session, reply, "a prompt cannot start now for this session")
  }
}

/// Stops the running turn.
///
/// A prompt the daemon has not been sent is withdrawn and answered
/// `cancelled` at once. One already sent gets an abort queued behind its
/// acknowledgement, and the turn ends `cancelled` when the run's result lands.
///
/// ## Examples
///
/// ```gleam
/// // session.cancel(session, now)
/// ```
pub fn cancel(session: Session, now: Int) -> Step {
  // What cancelling means depends on how far the turn has got.
  case session.phase {
    Turning(Turn(stage: Sending, ..) as turn) ->
      cancel_sending(session, turn, now)

    Turning(Turn(stage: Running, ..) as turn) -> ask_abort(session, turn, now)

    Turning(Turn(stage: Settling(..), ..)) | Attaching(..) | Idle | Dead -> #(
      session,
      [],
    )
  }
}

/// Cancels a turn whose prompt has not been acknowledged.
///
/// A prompt still in the queue never reached the daemon, so it is withdrawn
/// and the turn answered `cancelled` at once. One already handed to the lane
/// may be running by the time an abort lands, so the abort queues behind its
/// acknowledgement instead.
fn cancel_sending(session: Session, turn: Turn, now: Int) -> Step {
  // Whether the prompt is still ours decides between withdrawing and aborting.
  case list.any(session.queue, is_prompt) {
    True -> {
      let queue = list.filter(session.queue, fn(q) { !is_prompt(q) })
      let reply = prompt_reply(turn, schema.Cancelled, None)
      #(Session(..session, queue:, phase: Idle), [reply])
    }
    False -> ask_abort(session, turn, now)
  }
}

/// Queues the abort and marks the turn so it ends `cancelled`.
fn ask_abort(session: Session, turn: Turn, now: Int) -> Step {
  Session(..session, phase: Turning(Turn(..turn, cancellation: Asked)))
  |> enqueue(Queued(AbortTurn, None))
  |> settle_io(now, [])
}

/// Queues the decision for a permission request the client has answered.
///
/// The record is read from the latest cut, not from when it was asked, so the
/// compare-and-swap sequence the daemon checks is the freshest one. A request
/// that is no longer pending (decided from another attachment, or by the turn
/// ending) is dropped silently.
///
/// ## Examples
///
/// ```gleam
/// // session.answer(session, escalation_id, schema.Selected("allow"), now)
/// ```
pub fn answer(
  session: Session,
  review_id: String,
  choice: schema.PermissionChoice,
  now: Int,
) -> Step {
  case pending_review(session, review_id) {
    Some(review) ->
      session
      |> enqueue(Queued(Decide(review, translate.decision(choice)), None))
      |> settle_io(now, [])
    None -> #(session, [])
  }
}

/// Switches the model of the session's main strand.
///
/// ## Examples
///
/// ```gleam
/// // session.set_model(session, rpc.NumberId(4), "fixture", schema.LegacyAnswer, now)
/// ```
pub fn set_model(
  session: Session,
  reply: rpc.Id,
  name: String,
  answer: schema.ModelAnswer,
  now: Int,
) -> Step {
  case session.phase {
    Idle ->
      session
      |> enqueue(Queued(SwitchModel(name, answer), Some(reply)))
      |> settle_io(now, [])
    Attaching(..) | Turning(..) | Dead ->
      refuse(session, reply, "the model cannot change during a turn")
  }
}

// --- the lane's updates ------------------------------------------------------

/// Folds every update the lane made into the session, then sends what is queued.
fn absorb_all(
  session: Session,
  updates: List(session_channel.Update),
  now: Int,
) -> Step {
  let #(session, actions) =
    list.fold(updates, #(session, []), fn(state, update) {
      let #(session, actions) = state
      let #(session, more) = absorb(session, update, now)
      #(session, list.append(actions, more))
    })
  settle_io(session, now, actions)
}

/// Reduces one lane update.
fn absorb(session: Session, update: session_channel.Update, now: Int) -> Step {
  // Each update kind is either session state, a correlated outcome, or noise.
  case update {
    session_channel.Captured(cut:, view:, ..) -> on_cut(session, cut, view, now)

    session_channel.Acknowledged(..) -> on_acknowledged(session, now)

    session_channel.Auxiliary(event:) -> on_auxiliary(session, event)

    session_channel.Streamed(strand: "main", kind:, text:, ..) ->
      on_fragment(session, kind, text)

    session_channel.ToolStreamed(strand: "main", call_id:, text:, ..) ->
      on_tool_tail(session, call_id, text)

    session_channel.RequestRefused(command:, code:, ..) ->
      on_refused(session, command, code)

    session_channel.UnknownOutcome(command:, ..) ->
      on_refused(session, command, "reply_lost")

    session_channel.Submission(session_channel.DefinitelyNotSent(reason:)) ->
      on_refused(session, "", reason)

    session_channel.Failed(reason:) -> die(session, reason)

    session_channel.Streamed(..)
    | session_channel.ToolStreamed(..)
    | session_channel.Submission(session_channel.Waiting(..))
    | session_channel.Submission(session_channel.Sent(..))
    | session_channel.HistoryPage(..)
    | session_channel.LineagePage(..)
    | session_channel.LookedUp(..)
    | session_channel.Noticed(..) -> #(session, [])
  }
}

/// Takes a completed cut: shows new entries, asks for approvals, and settles.
fn on_cut(
  session: Session,
  cut: snapshot.Captured,
  view: snapshot_view.View,
  now: Int,
) -> Step {
  let first = session.cut == None
  let session = Session(..session, cut: Some(#(cut, view)))

  // How a cut is used depends on whether the client is attached yet.
  case session.phase {
    Dead -> #(session, [])

    Attaching(Loaded, _) if first -> show_entries(session, translate.Replay)

    Attaching(Created, _) if first -> #(
      Session(..session, shown_seq: newest_seq(cut)),
      [],
    )

    Attaching(..) -> #(session, [])

    Idle | Turning(..) -> {
      let #(session, shown) = show_entries(session, translate.Live)
      let #(session, asks) = ask_permissions(session)
      let #(session, ended) = settle(session, now)
      #(session, list.flatten([shown, asks, ended]))
    }
  }
}

/// Handles the daemon accepting the command that was in flight.
fn on_acknowledged(session: Session, now: Int) -> Step {
  let acknowledged = session.in_flight
  let session = Session(..session, in_flight: None)

  // The acknowledgement means different things to different commands.
  case acknowledged {
    Some(Queued(PromptTurn(..), _)) -> #(advance_to_running(session), [])

    // The switch is now the session's choice, so the reply names it current.
    Some(Queued(SwitchModel(name, answer), Some(reply))) -> {
      let session = Session(..session, requested_model: Some(name))
      let body = schema.model_answer(answer, model_state(session))
      #(session, [Respond(reply, Ok(body))])
    }

    Some(Queued(..)) | None -> {
      // An acknowledgement for a read-free command needs nothing more, but a
      // result that raced it may already be in the cut.
      settle(session, now)
    }
  }
}

/// Marks a sending turn as accepted.
fn advance_to_running(session: Session) -> Session {
  case session.phase {
    Turning(Turn(stage: Sending, ..) as turn) ->
      Session(..session, phase: Turning(Turn(..turn, stage: Running)))
    Turning(..) | Attaching(..) | Idle | Dead -> session
  }
}

/// Handles a correlated read result.
fn on_auxiliary(session: Session, event: protocol.Event) -> Step {
  case event, session.phase {
    protocol.ModelsSnapshot(models:), Attaching(..) ->
      complete_attach(Session(..session, catalogue: Some(models)))

    protocol.ContextSnapshot(observation: context_view.Ready(board:)),
      Turning(Turn(stage: Settling(..), ..) as turn)
    -> finish(session, turn, Some(board))

    protocol.ContextSnapshot(observation: context_view.Failed(..)),
      Turning(Turn(stage: Settling(..), ..) as turn)
    -> finish(session, turn, None)

    _, _ -> #(session, [])
  }
}

/// Shows a live fragment at once and remembers it for reconciliation.
fn on_fragment(session: Session, kind: String, text: String) -> Step {
  // A fragment is shown only to an attached client; before the attach answer
  // there is nothing to attach it to.
  case session.phase {
    Idle | Turning(..) -> {
      let #(update, streamed) = translate.fragment(kind, text, session.streamed)
      let shown = option.map(update, list.wrap) |> option.unwrap([])
      #(Session(..session, streamed:), updates_of(session.id, shown))
    }
    Attaching(..) | Dead -> #(session, [])
  }
}

/// Shows the tail of a running tool call, once the call has been announced.
fn on_tool_tail(session: Session, call_id: String, text: String) -> Step {
  // A tail that outruns the entry that names its call would arrive before the
  // `tool_call` it updates, which clients reject; the final result carries the
  // whole output, so the preview is dropped rather than reordered.
  case list.contains(session.announced, call_id) {
    True -> #(
      session,
      updates_of(session.id, [translate.tool_tail(call_id, text)]),
    )
    False -> #(session, [])
  }
}

/// Handles a refusal or a lost reply for the command the lane was running.
fn on_refused(session: Session, command: String, code: String) -> Step {
  let refused = session.in_flight
  let session = Session(..session, in_flight: None)

  // A read has no queue entry in flight, so it is told apart by its name.
  case command, refused, session.phase {
    "models", _, Attaching(..) -> complete_attach(session)

    "context", _, Turning(Turn(stage: Settling(..), ..) as turn) ->
      finish(session, turn, None)

    _, Some(Queued(PromptTurn(..), _)), Turning(turn) ->
      end_with_error(session, turn, "prompt refused: " <> code)

    _, Some(Queued(SwitchModel(..), None)), Attaching(reply:, ..) ->
      die_with(session, reply, "the requested model was refused: " <> code)

    _, Some(Queued(SwitchModel(..), Some(reply))), _ -> #(session, [
      Respond(reply, Error(rpc.error(rpc.invalid_params, "refused: " <> code))),
    ])

    _, _, _ -> #(session, [])
  }
}

/// Ends the session after the lane failed, answering whatever was waiting.
fn die(session: Session, reason: String) -> Step {
  // The attach or the prompt that was waiting learns why it will not finish.
  let waiting = case session.phase {
    Attaching(reply:, ..) -> [Respond(reply, Error(failure(reason)))]
    Turning(turn) -> [Respond(turn.reply, Error(failure(reason)))]
    Idle | Dead -> []
  }

  // So does a request whose acknowledgement was still owed.
  let held = case session.in_flight {
    Some(Queued(_, Some(reply))) -> [Respond(reply, Error(failure(reason)))]
    Some(_) | None -> []
  }

  #(
    Session(..session, phase: Dead, queue: [], in_flight: None),
    list.flatten([waiting, held, [Ended(reason)]]),
  )
}

/// Fails an attach whose model request was refused, so no session is left half made.
fn die_with(session: Session, reply: rpc.Id, reason: String) -> Step {
  #(Session(..session, phase: Dead, queue: []), [
    Respond(reply, Error(rpc.error(rpc.invalid_params, reason))),
    Ended(reason),
  ])
}

/// The error object for a failed lane.
fn failure(reason: String) -> rpc.WireError {
  rpc.error(rpc.internal_error, "the session connection failed: " <> reason)
}

// --- attaching ---------------------------------------------------------------

/// Answers `session/new` or `session/load` once the catalogue is known.
fn complete_attach(session: Session) -> Step {
  // The answer goes out once, to the request that started the attach; the
  // permission requests of an already-pending escalation follow it.
  case session.phase {
    Attaching(reply:, intent:) -> {
      let #(session, asks) = ask_permissions(Session(..session, phase: Idle))
      let result = attach_result(session, intent)
      #(session, [Respond(reply, Ok(result)), ..asks])
    }
    Idle | Turning(..) | Dead -> #(session, [])
  }
}

/// The result of the request that started the attach.
///
/// A new session names itself; a loaded one was named by the request, so its
/// result carries only what the client has not been told.
fn attach_result(session: Session, intent: Attach) -> JsonValue {
  case intent {
    Created -> schema.session_result(session.id, model_state(session))
    Loaded -> schema.load_result(model_state(session))
  }
}

/// The model choices to advertise, or none when the catalogue is empty.
///
/// The current model is the catalogue entry whose provider model id matches the
/// main strand's configuration; failing that, the entry routed to `main`, and
/// failing that the first entry.
fn model_state(session: Session) -> Option(schema.ModelState) {
  // Without a catalogue or a cut there is nothing true to advertise.
  case session.catalogue, session.cut {
    Some([first, ..] as models), Some(#(_, view)) -> {
      let configured =
        dict.get(view.configurations, "main")
        |> result.map(fn(found) { found.configuration.model.model_id })
      let requested = option.to_result(session.requested_model, Nil)
      let current =
        list.find(models, fn(model) { Ok(model.name) == requested })
        |> result.lazy_or(fn() {
          list.find(models, fn(model) { Ok(model.model_id) == configured })
        })
        |> result.lazy_or(fn() {
          list.find(models, fn(model) { list.contains(model.active, "main") })
        })
        |> result.unwrap(first)
      Some(schema.ModelState(
        current: current.name,
        available: list.map(models, fn(model) {
          schema.ModelChoice(model.name, model.model_id)
        }),
      ))
    }
    Some([]), _ | None, _ | Some(_), None -> None
  }
}

// --- showing the conversation ------------------------------------------------

/// Sends the `main` branch entries newer than the last one shown.
fn show_entries(session: Session, mode: translate.Mode) -> Step {
  // Entries are read from the held cut; before the first cut there are none.
  case session.cut {
    None -> #(session, [])
    Some(#(cut, view)) -> {
      let fresh =
        snapshot_view.branch(view, cut.window, "main").records
        |> list.reverse
        |> list.filter(fn(record) {
          entry_seq(record.entry) > session.shown_seq
        })

      let #(session, actions) =
        list.fold(fresh, #(session, []), fn(state, record) {
          let #(session, actions) = state
          let #(updates, streamed) =
            translate.entry_updates(record.entry, mode, session.streamed)
          let session =
            Session(
              ..session,
              streamed:,
              shown_seq: entry_seq(record.entry),
              announced: announce(session.announced, updates),
            )
          #(session, list.append(actions, updates_of(session.id, updates)))
        })
      #(session, actions)
    }
  }
}

/// Remembers the tool calls an update list announced, newest last.
fn announce(
  announced: List(String),
  updates: List(schema.Update),
) -> List(String) {
  let started =
    list.filter_map(updates, fn(update) {
      case update {
        schema.ToolStarted(call) -> Ok(call.id)
        _ -> Error(Nil)
      }
    })
  list.append(announced, started)
  |> list.reverse
  |> list.take(max_announced)
  |> list.reverse
}

/// Wraps updates as `session/update` notifications.
fn updates_of(
  session_id: String,
  updates: List(schema.Update),
) -> List(Action) {
  list.map(updates, fn(update) {
    Notify("session/update", schema.update_params(session_id, update))
  })
}

/// The newest entry sequence anywhere in the cut, or -1 when it holds none.
fn newest_seq(cut: snapshot.Captured) -> Int {
  list.fold(cut.window.items, -1, fn(newest, item) {
    case item {
      snapshot.Loaded(entry, _) -> int.max(newest, entry_seq(entry))
      snapshot.Unloaded(seq:, ..) -> int.max(newest, seq)
    }
  })
}

/// The commit sequence of any entry kind.
fn entry_seq(entry: core_entry.Entry) -> Int {
  case entry {
    core_entry.MessageEntry(seq:, ..)
    | core_entry.CompactionEntry(seq:, ..)
    | core_entry.BranchSummaryEntry(seq:, ..)
    | core_entry.CustomEntry(seq:, ..) -> seq
  }
}

// --- approvals ---------------------------------------------------------------

/// Forwards every pending escalation not yet asked as a permission request.
fn ask_permissions(session: Session) -> Step {
  // Escalations are read from the held cut's registers, once each.
  case session.cut {
    None -> #(session, [])
    Some(#(_, view)) -> {
      let fresh =
        approval.records(view.cells)
        |> result.unwrap([])
        |> list.filter(fn(review) {
          review.status == approval.Pending
          && !list.contains(session.asked, review.id)
        })
      let asks =
        list.map(fresh, fn(review) {
          let #(call, options) = translate.permission(review)
          Ask(review.id, schema.permission_params(session.id, call, options))
        })
      let asked = list.append(session.asked, list.map(fresh, fn(r) { r.id }))
      #(Session(..session, asked:), asks)
    }
  }
}

/// The pending record for an escalation id in the latest cut.
fn pending_review(
  session: Session,
  review_id: String,
) -> Option(approval.Review) {
  case session.cut {
    None -> None
    Some(#(_, view)) ->
      approval.records(view.cells)
      |> result.unwrap([])
      |> list.find(fn(review) {
        review.id == review_id && review.status == approval.Pending
      })
      |> option.from_result
  }
}

// --- settling a turn ---------------------------------------------------------

/// Ends the turn when the run's terminal result has appeared in the cut.
fn settle(session: Session, now: Int) -> Step {
  case session.phase, session.cut {
    Turning(Turn(stage: Settling(..), ..)), _ -> #(session, [])

    Turning(turn), Some(#(_, view)) ->
      case last_result(view) {
        Some(#(operation_id, result)) if Some(operation_id) != turn.baseline ->
          case translate.outcome(result) {
            Some(outcome) -> conclude(session, turn, outcome, now)
            None -> #(session, [])
          }
        Some(_) | None -> #(session, [])
      }

    Turning(..), None | Attaching(..), _ | Idle, _ | Dead, _ -> #(session, [])
  }
}

/// Applies the cancellation rule to a run result and starts the final read.
fn conclude(
  session: Session,
  turn: Turn,
  outcome: translate.Outcome,
  now: Int,
) -> Step {
  // A client that asked to stop is told the turn was cancelled even when the
  // run finished before the abort landed: ACP defines the reply to a
  // cancelled prompt, not a race between the two.
  let outcome = case outcome, turn.cancellation {
    translate.Stopped(schema.EndTurn), Asked ->
      translate.Stopped(schema.Cancelled)
    translate.Stopped(_), _ | translate.Errored(_), _ -> outcome
  }

  // A failed run is answered at once; a stopped one reads the context size so
  // the reply can be preceded by a usage update.
  case outcome {
    translate.Errored(reason:) -> end_with_error(session, turn, reason)
    translate.Stopped(..) -> {
      let settling =
        Turn(..turn, stage: Settling(outcome, until: now + settle_wait_ms))
      Session(..session, phase: Turning(settling))
      |> enqueue(Queued(ReadContext, None))
      |> settle_io(now, [])
    }
  }
}

/// Answers the prompt with the stop reason, after a usage update when known.
fn finish(
  session: Session,
  turn: Turn,
  board: Option(context_view.Board),
) -> Step {
  let reply = prompt_reply(turn, stop_reason(turn), turn_tokens(session, turn))
  let queue = without_turn_commands(session.queue)

  #(
    Session(
      ..session,
      phase: Idle,
      queue:,
      streamed: translate.nothing_streamed,
    ),
    list.append(usage_report(session, board), [reply]),
  )
}

/// The stop reason a settling turn was waiting to deliver.
fn stop_reason(turn: Turn) -> schema.StopReason {
  case turn.stage {
    Settling(translate.Stopped(reason:), ..) -> reason
    Settling(translate.Errored(..), ..) | Sending | Running -> schema.EndTurn
  }
}

/// The tokens this turn spent, from the cut that ended it.
fn turn_tokens(session: Session, turn: Turn) -> Option(schema.TurnUsage) {
  case session.cut {
    Some(#(_, view)) ->
      Some(translate.turn_usage(turn.usage_before, view.usage))
    None -> None
  }
}

/// The usage update that precedes the reply, when the context read answered.
///
/// ACP's `usage_update` carries the context in use and the window, which only
/// the daemon's context read knows; the cumulative cost comes from the cut.
fn usage_report(
  session: Session,
  board: Option(context_view.Board),
) -> List(Action) {
  case board, session.cut {
    Some(board), Some(#(_, view)) ->
      updates_of(session.id, [
        schema.Usage(
          used: board.used,
          size: board.window,
          cost: Some(view.usage.cost.total),
        ),
      ])
    Some(_), None | None, _ -> []
  }
}

/// Drops the commands that belong to a turn that has ended.
///
/// An abort queued for a turn must not outlive it: sent later it would abort
/// the next turn, and a context read has no one left to answer.
fn without_turn_commands(queue: List(Queued)) -> List(Queued) {
  list.filter(queue, fn(queued) {
    case queued.command {
      AbortTurn | ReadContext -> False
      PromptTurn(..) | Decide(..) | SwitchModel(..) | ReadModels -> True
    }
  })
}

/// Answers a prompt with a failure.
fn end_with_error(session: Session, turn: Turn, reason: String) -> Step {
  let ended =
    Session(
      ..session,
      phase: Idle,
      queue: without_turn_commands(session.queue),
      streamed: translate.nothing_streamed,
    )
  #(ended, [Respond(turn.reply, Error(rpc.error(rpc.internal_error, reason)))])
}

/// The `session/prompt` response.
fn prompt_reply(
  turn: Turn,
  reason: schema.StopReason,
  usage: Option(schema.TurnUsage),
) -> Action {
  Respond(turn.reply, Ok(schema.prompt_result(reason, usage)))
}

/// The terminal result on the main strand: its operation id and decoded value.
fn last_result(
  view: snapshot_view.View,
) -> Option(#(String, operation.LastResult)) {
  view.cells
  |> list.find(fn(cell) {
    cell.namespace == register.StrandLastResult && cell.key == "main"
  })
  |> result.try(fn(cell) {
    machine_codec.decode_last_result(cell.value) |> result.replace_error(Nil)
  })
  |> result.map(fn(found) { #(result_operation(found), found) })
  |> option.from_result
}

/// The operation a last result belongs to.
fn result_operation(result: operation.LastResult) -> String {
  case result {
    operation.RunLastResult(operation:, ..)
    | operation.CompactionLastResult(operation:, ..)
    | operation.NavigationLastResult(operation:, ..) ->
      ids.op_id_to_string(operation)
  }
}

// --- the command queue -------------------------------------------------------

/// Appends a command to the queue.
fn enqueue(session: Session, queued: Queued) -> Session {
  Session(..session, queue: list.append(session.queue, [queued]))
}

/// Whether a queued command is the prompt.
fn is_prompt(queued: Queued) -> Bool {
  case queued.command {
    PromptTurn(..) -> True
    AbortTurn | Decide(..) | SwitchModel(..) | ReadModels | ReadContext -> False
  }
}

/// Sends the queue's head if the lane can take it, then collects the lane's outputs.
fn settle_io(session: Session, now: Int, actions: List(Action)) -> Step {
  let session = pump(session, now)
  let #(lane, outputs) = session_channel.take_outputs(session.lane)
  #(Session(..session, lane:), list.append(actions, list.map(outputs, Write)))
}

/// Hands the head of the queue to the lane when the lane is ready for it.
fn pump(session: Session, now: Int) -> Session {
  case session.queue, session.in_flight {
    [], _ -> session
    [Queued(command, _) as head, ..rest], None ->
      case readiness(session, command) {
        False -> session
        True -> send(Session(..session, queue: rest), head, now)
      }
    [_, ..], Some(_) -> session
  }
}

/// Whether the lane can take this command now: reads and mutations differ.
fn readiness(session: Session, command: Command) -> Bool {
  case is_read(command) {
    True -> session_channel.ready_for_read(session.lane)
    False ->
      session_channel.synchronized(session.lane)
      && session_channel.mutation_available(session.lane)
  }
}

/// Whether a command is a read, which the daemon answers with a snapshot.
fn is_read(command: Command) -> Bool {
  case command {
    ReadModels | ReadContext -> True
    PromptTurn(..) | AbortTurn | Decide(..) | SwitchModel(..) -> False
  }
}

/// Encodes and submits one command.
fn send(session: Session, queued: Queued, now: Int) -> Session {
  // A command whose frame cannot be encoded is dropped, which is a decision
  // the daemon would have refused anyway.
  case frame(queued.command) {
    Error(Nil) -> session
    Ok(text) -> {
      let #(lane, disposition) =
        session_channel.submit(session.lane, text, now:)
      let session = Session(..session, lane:)

      // A mutation is tracked until acknowledged; a read answers by event.
      case disposition, is_read(queued.command) {
        session_channel.DefinitelyNotSent(..), _ -> session
        _, True -> session
        _, False -> Session(..session, in_flight: Some(queued))
      }
    }
  }
}

/// The wire frame for a command; a decision the record cannot encode is dropped.
fn frame(command: Command) -> Result(String, Nil) {
  case command {
    PromptTurn(content) -> Ok(protocol.prompt_content(0, "main", content))
    AbortTurn -> Ok(protocol.abort(0, "main"))
    SwitchModel(name, _) -> Ok(protocol.set_model(0, "main", name))
    ReadModels -> Ok(protocol.models(0))
    ReadContext -> Ok(protocol.context(0, "main"))
    Decide(review, decision) ->
      case decision {
        translate.Approve -> approval.approve(0, review)
        translate.ApproveForSession -> approval.approve_for_session(0, review)
        translate.Deny -> approval.deny(0, review)
      }
      |> result.replace_error(Nil)
  }
}

/// Answers a request with an invalid-params refusal.
fn refuse(session: Session, reply: rpc.Id, reason: String) -> Step {
  #(session, [Respond(reply, Error(rpc.error(rpc.invalid_params, reason)))])
}
