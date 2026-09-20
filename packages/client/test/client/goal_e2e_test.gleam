//// The session's goal, driven end to end by the harness alone.
////
//// This is the acceptance fixture the protocol review named as the one
//// that would prove its own findings wrong: a reviewer that answers
//// `continue` to every goal feed must not run the primary forever — the
//// loop stops on its own at the continuation cap — and an operator's
//// abort of a goal-woken run must leave the goal paused, not active and
//// dead. Both assertions are made against the durable cell and the
//// provider request bodies, the two places a claim about the loop must
//// land to count.
////
//// The assembly is the advisor e2e's: two catalogue entries on two base
//// URLs, a scripted transport that tells the strands apart by URL, and
//// assertions on request bodies rather than on the durable tree alone,
//// because a body is what was sent to a model. The goal is pinned and
//// read through the gateway's own command surface — `goal_set`,
//// `goal_get`, `goal_resume` — fed as protocol frames through the same
//// connection path the websocket listener feeds, so the codec, the
//// dispatch guards, the seam and the actor are all in the path the
//// operator's terminal will use.
////
//// ## Why the reviewer's lane is scripted by position
////
//// The same reasoning as the advisor fixture's, and for one more
//// reason: the loop's cadence is deliberately advisor-paced, so how
//// many reviews the host's scheduling produces is not fixed. The script
//// draws its verdicts in order — `continue` for every goal feed until
//// the operator says otherwise — and the assertions read the final
//// state of the goal cell rather than counting feeds.

import broker/exec
import client/advisor
import client/advisorslice
import client/catalog
import client/codemode
import client/distillpass
import client/gateway
import client/goal_pending
import client/goalloop
import client/goalstate
import client/internal/ffi_os
import client/jobs
import client/protocol
import client/retryconf
import client/schedule
import client/serve
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/clock
import core/ids
import core/json
import core/message
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/acceptance
import machine/operation
import machine/strand as machine_strand
import provider/adapter/anthropic
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/secret
import runtime/api
import session/session
import simplifile
import storage/access
import support/provider as provider_test
import telemetry/log
import tools/advise
import weft/actor
import weft/poll

/// The whole budget: one real instance, an operator turn, the loop's
/// continuations (each a primary run and a review), and the abort case's
/// pause, resume and completion.
const test_timeout_seconds = 300

/// gleeunit runs eunit with `ScaleTimeouts(10)`, so the number handed to
/// eunit is the number wanted divided by ten.
const gleeunit_timeout_scale = 10

/// How long any one wait for the loop to reach a state may take.
const await_ms = 60_000

/// The objective the operator pins. It must be findable inside the
/// untrusted block in every goal feed.
const objective = "land the fixture migration"

/// The reviewer's note on every continue.
const remaining = "the tests still fail"

/// The reviewer's note on the completion the abort fixture ends with.
const done_note = "the migration is merged"

/// The session id the fixture's instance is assembled under, and so the
/// name its hub answers `subscribe` for.
const fixture_session = "goal-e2e"

/// The host that answers for the primary's model.
const primary_host = "acme.test"

/// The host that answers for the advisor's model.
const advisor_host = "sage.test"

const primary_model = "loom-1"

const advisor_model = "sage-1"

// --- the acceptance case: the harness, not the reviewer, ends the loop ----
// A reviewer that answers `continue` to every goal feed is the adversarial
// reviewer the design's bounds exist for: nothing about the work will ever
// satisfy it, so the only thing that can stop the loop is a harness bound.
// The budget is set far beyond anything the scripted usage can spend, so
// what the assertion reads tripping is one of the two bounds that count
// the loop's own behaviour rather than its spend.
//
// It is the zero-progress bound, and which one it is was a finding. This
// fixture was first written against the continuation cap, and it expired:
// the scripted primary answers every continuation with a plain text turn,
// so no woken stretch commits a tool result or an operator turn, and a
// stretch that commits neither is zero-progress by definition. Two of them
// pause the goal, which happens six continuations before the cap could.
// That is the bound working — it could not fire at all in the first
// implementation, because the continuation frame is itself a user message
// and the predicate counted any user message as progress. The cap is
// reached by the fixture below, whose primary makes a call on every woken
// run and so never stalls.
pub fn an_always_continue_reviewer_stops_itself_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    let root = fixture_root("stalled")
    let script = script(SaysNothing)
    let assert Ok(instance) =
      serve.open_instance(settings(root, script), log.discard())
      as "the goal fixture must open a real instance"
    let assert Ok(helper) = exec.checkout(instance.pool, waiting: 5000)
      as "the instance must have a real, handshaken helper"
    exec.checkin(instance.pool, helper)
    // Pin the goal through the instance's goal seam — the same five
    // calls the gateway's commands forward to, held by the instance so
    // the fixture drives the operator's door without booting the
    // listener.
    let assert Some(goal_commands) = instance.goal
      as "an instance with a routed advisor must expose the goal seam"
    let assert Ok(Nil) = goal_commands.set(objective, 100_000_000, None)
      as "the goal must pin through the operator's own command door"
    // The operator's one turn ends; the goal feed replaces the ordinary
    // review, and the loop begins. Every subsequent primary run is the
    // loop's own continuation.
    complete(instance, "work on the migration")
    // The reviewer says continue, forever. The loop's continuations each
    // end with a goal feed, so the loop is entirely self-driving here.
    let assert poll.Answered(goal) = poll_goal(instance, "paused")
      as "a harness bound must stop the loop and flip the goal"

    // The reason names which bound stopped it. A bare `paused` would not
    // distinguish this from the operator pausing the goal or from an
    // abort, which is why the cell carries a cause at all.
    assert goal.reason == Some("zero_progress")

    // The loop ran itself a few times and then stopped itself, and the
    // count is the bound's own evidence: at least as many continuations as
    // the zero-progress limit needs, and well short of the cap. It is not
    // pinned to an exact number because the first woken stretch still
    // carries the operator's own turn — which is work — so the
    // zero-progress count starts again there, and how many stretches the
    // host's scheduling coalesces into one is the thing this fixture is
    // written not to depend on.
    assert goal.continuations >= goalloop.zero_progress_limit
      as "the loop wakes the primary at least as often as the bound needs"
    assert goal.continuations < goalloop.continuation_cap
      as "the zero-progress bound stops the loop before the cap could"

    // A pause sends no wrap-up. The wrap-up is the one-shot steer a
    // *limited* status carries, and a goal the harness paused for
    // producing nothing has nothing to tell the primary to wrap up.
    assert !list.any(seen(script).primary, fn(body) {
      string.contains(body, "wrap up the current step")
    })
    // The continuations each reached the primary as the frame that woke
    // it, and the goal feed carried the objective inside the untrusted
    // block with the goal question in its footer.
    assert list.any(seen(script).primary, fn(body) {
      string.contains(body, advisorslice.continuation_header)
    })
    let assert Ok(feed) =
      list.first(
        list.filter(seen(script).advisor, fn(body) {
          string.contains(body, advisorslice.goal_feed_header)
        }),
      )
      as "the advisor must have been fed the goal question"
    // The objective rides inside the untrusted block with the goal
    // question in its footer. The block's delimiters and the objective's
    // own text are checked separately: one escaped-body contains check
    // for the whole block is brittle against the adapter's rendering of
    // the newline the block's own builder writes.
    assert string.contains(feed, "<untrusted_objective>")
    assert string.contains(feed, objective)
    assert string.contains(feed, "</untrusted_objective>")
    assert string.contains(feed, advisorslice.goal_feed_footer)
    // The goal reads back through the same observation the panel will
    // read through: the exact-key read, never the actor.
    let assert Ok(board) = goal_pending.read(instance.runtime.session, 0)
    let assert json.Object(board_fields) = board
    assert list.key_find(board_fields, "status") == Ok(json.String("paused"))
    // The status word alone names four different pauses, so the board
    // carries the cause and the sentence the panel shows beside it.
    assert list.key_find(board_fields, "reason")
      == Ok(json.String("zero_progress"))
    assert list.key_find(board_fields, "because")
      == Ok(
        json.String(
          goalloop.stopped_because(goalstate.Paused(
            by: goalstate.ByZeroProgress,
          )),
        ),
      )
    serve.close_instance(instance)
  })
}

// --- the acceptance case: the cap stops a working loop ----------------------
// The fixture above stops on the zero-progress bound because its primary
// produces nothing, which leaves the continuation cap — the bound the
// protocol review named as the one that must hold against an adversarial
// reviewer — proved only where the primary is a number rather than a
// session. This one reaches it: the primary makes a call on every woken
// run, so every stretch is work, the zero-progress bound never fires, and
// the only thing left that can stop an always-`continue` reviewer is the
// cap.
//
// The budget is far beyond anything the scripted usage can spend, so the
// bound that trips is not the token budget either.
pub fn an_always_continue_reviewer_stops_at_the_cap_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    let root = fixture_root("cap")
    let script = script(CallsATool)
    let assert Ok(instance) =
      serve.open_instance(settings(root, script), log.discard())
      as "the goal fixture must open a real instance"
    let assert Ok(helper) = exec.checkout(instance.pool, waiting: 5000)
      as "the instance must have a real, handshaken helper"
    exec.checkin(instance.pool, helper)
    let assert Some(goal_commands) = instance.goal
      as "an instance with a routed advisor must expose the goal seam"
    let assert Ok(Nil) = goal_commands.set(objective, 100_000_000, None)
      as "the goal must pin through the operator's own command door"
    complete(instance, "work on the migration")

    // The loop runs itself until a harness bound stops it, and the status
    // it stops in is the limited one rather than a pause: a cap reached is
    // the harness spending its allowance, not the harness giving up on a
    // primary that produces nothing.
    let assert poll.Answered(goal) = poll_goal(instance, "budget_limited")
      as "the continuation cap must stop the loop and limit the goal"
    assert goal.reason == Some("continuation_cap")
      as "the cap is the bound that tripped, not the token budget"

    // The cap is a count, so the count is the evidence: the loop took
    // exactly the consecutive turns the harness allows and then stopped.
    assert goal.continuations == goalloop.continuation_cap

    // The primary was told, once, in the cap's own words. An earlier draft
    // told it the token budget was exhausted whichever bound had tripped,
    // which is a false statement half the time.
    // The wording is the harness's own rather than a copy of it here, so
    // the assertion cannot drift away from what the primary is sent.
    //
    // It is awaited rather than read at once, because the cell is written
    // before the wrap-up is sent: the evaluation stores the `Limited` goal
    // and only then performs the action, so the status this fixture polled
    // for is always visible a moment before the send that follows it. An
    // immediate read here raced that send and passed on the host's
    // scheduling rather than on the behaviour.
    let capped = goalloop.wrap_up_text(goalstate.ByContinuationCap)
    let _wrapped = await_primary(script, capped)
    assert !list.any(seen(script).primary, fn(body) {
      string.contains(body, goalloop.wrap_up_text(goalstate.ByTokenBudget))
    })
      as "the budget's wrap-up must not be sent for a cap"

    // Every woken stretch did work, which is what kept the zero-progress
    // bound out of the way: the count the other fixture trips on is zero
    // here.
    assert goal.zero_progress == 0
      as "a stretch that commits a tool result is work, so nothing stalled"
    serve.close_instance(instance)
  })
}

// --- the acceptance case: the abort pauses the goal --------------------------
// An operator's abort of a goal-woken run is a "not now", not a "never":
// the goal must read back paused — and the loop held, since a paused
// goal occasions no further goal feeds — rather than active with nothing
// running, which is the stall the design review warned the naive abort
// path would leave behind.
pub fn an_aborted_continuation_pauses_the_goal_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    let root = fixture_root("abort")
    let script = script(HoldsTheContinuation)
    let assert Ok(instance) =
      serve.open_instance(settings(root, script), log.discard())
      as "the goal fixture must open a real instance"
    let assert Ok(helper) = exec.checkout(instance.pool, waiting: 5000)
      as "the instance must have a real, handshaken helper"
    exec.checkin(instance.pool, helper)
    let assert Some(goal_commands) = instance.goal
      as "an instance with a routed advisor must expose the goal seam"
    let assert Ok(Nil) = goal_commands.set(objective, 100_000_000, None)
      as "the goal must pin through the operator's own command door"
    complete(instance, "work on the migration")
    // The first continuation wakes the primary; wait for its frame in a
    // request body — the body is what was sent, so the run is live — and
    // then abort the way the terminal's abort command does.
    let _carrying = await_primary(script, advisorslice.continuation_header)

    // The abort, through the two steps the gateway's abort handler
    // performs for the TUI's command: the runtime's abort on the open
    // run, then the advisor's notice. The handler's third step — the
    // effect-plane sweep — has no effect here, because the scripted
    // provider runs no live effects.
    let assert Some(notice) = instance.goal_abort
      as "an instance with a routed advisor must expose the abort notice"
    let open = case
      session.strand_state(instance.runtime.session, advisor.primary)
    {
      Ok(Some(session.Cell(value: current, ..))) -> current.current_operation
      Ok(None) | Error(_) -> option.None
    }
    api.abort(instance.runtime)
    case open {
      Some(op) -> {
        notice(op)

        // Release the held reply and await the run's settlement, so the
        // primary reads idle by the time the fixture asserts the pause
        // and the resume that follows it.
        actor.call(script, waiting: 5000, sending: fn(reply) {
          ReleaseHeld(reply)
        })
        let assert Ok(operation.RunLastResult(outcome: outcome, ..)) =
          api.await_result(instance.runtime, op, within_ms: 60_000)
          as "the aborted continuation must settle through the real machine"
        assert outcome == operation.RunAborted
      }
      option.None -> Nil
    }
    api.abort(instance.runtime)
    let assert poll.Answered(goal) = poll_goal(instance, "paused")
      as "the aborted continuation must pause the goal"
    assert goal.continuations == 1
      as "exactly one continuation ran before the operator stopped it"
    // The cause is the abort's, not the operator's own pause command: the
    // two read back differently, which is what the panel shows.
    assert goal.reason == Some("aborted")
      as "an aborted continuation pauses the goal for the abort's own cause"
    // A paused goal occasions no further goal feeds: the loop is held,
    // not dead, and the resume is the operator's call.
    let held: poll.Outcome(Nil, Nil) =
      poll.until(within: 2000, every: 100, attempt: fn() {
        case goal_feeds_seen(script) > 1 {
          True -> poll.Done(Nil)
          False -> poll.Retry
        }
      })
    assert held == poll.Expired
      as "a paused goal must occasion no further goal feeds"
    // Resume continues the loop, and a reviewer that now says complete
    // ends it cleanly — the two commands the operator actually has.
    // The completion is armed before the resume: the resume offers the
    // goal feed on the idle primary itself, so a completion armed after
    // would race the feed the resume is already sending.
    actor.call(script, waiting: 5000, sending: fn(reply) {
      AnswerComplete(reply)
    })
    let assert Ok(Nil) = goal_commands.resume()
      as "the resumed goal must commit through the operator's door"
    let assert poll.Answered(done) = poll_goal(instance, "complete")
      as "the resumed loop must accept the completion"
    assert done.reviewer_note == Some(done_note)
    serve.close_instance(instance)
  })
}

// --- the acceptance case: the reviewer is shown a check it did not run ------
// The check is the first evidence in the loop the reviewer can weigh that the
// primary did not write, so what this fixture proves is that it reaches the
// reviewer's own request body — the place a claim about what a model was shown
// has to land — and that it reaches it having actually run in the session's
// jail rather than having been rendered from the cell alone.
//
// It runs the check twice, failing and then passing, because the pair is the
// claim: a reviewer that sees `exit status 1` is being given evidence against
// `complete`, and one that sees `exit status 0` is being given evidence for
// it. The commands are shell builtins under the same `bash` invocation the
// tool plane uses, so what is under test is the harness's plumbing rather than
// whatever the host happens to have on its PATH.
//
// The primary calls a tool on every woken run, so every stretch is work and
// the zero-progress bound cannot end the fixture before the second round.
pub fn a_scripted_reviewer_is_shown_the_checks_result_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    let root = fixture_root("check")
    let script = script(CallsATool)
    let assert Ok(instance) =
      serve.open_instance(settings(root, script), log.discard())
      as "the goal fixture must open a real instance"
    let assert Ok(helper) = exec.checkout(instance.pool, waiting: 5000)
      as "the instance must have a real, handshaken helper"
    exec.checkin(instance.pool, helper)
    let assert Some(goal_commands) = instance.goal
      as "an instance with a routed advisor must expose the goal seam"

    // The goal and its check pin in one command, which is the form an
    // operator uses when they know both up front.
    let assert Ok(Nil) =
      goal_commands.set(objective, 100_000_000, Some("exit 1"))
      as "the goal and its failing check must pin through the operator's door"
    complete(instance, "work on the migration")

    // The failing check reaches the reviewer's request body, labelled as the
    // harness's own evidence rather than as part of the transcript.
    let failing = await_advisor(script, "exit status 1")
    assert string.contains(failing, advisorslice.check_label)
    assert string.contains(failing, "command: exit 1")
    assert string.contains(failing, "(the check failed)")
      as "the reviewer is told what a non-zero status means"
    assert string.contains(failing, advisorslice.goal_feed_footer)
      as "the check rides inside the goal feed frame"

    // The reviewer answered `continue` to that, which is the default this
    // script gives until told otherwise, and the loop woke the primary.
    let _carrying = await_primary(script, advisorslice.continuation_header)

    // Now the check passes. The completion is armed first, because setting the
    // check returns the phase to idle and the evaluation that follows sends
    // the next feed at once — a completion armed after would race it.
    actor.call(script, waiting: 5000, sending: fn(reply) {
      AnswerComplete(reply)
    })
    let assert Ok(Nil) = goal_commands.set_check(Some("exit 0"))
      as "the operator must be able to change the check without a refresh"

    let passing = await_advisor(script, "exit status 0")
    assert string.contains(passing, "command: exit 0")
    assert string.contains(passing, "(the check passed)")

    let assert poll.Answered(done) = poll_goal(instance, "complete")
      as "a reviewer shown a passing check must be able to complete the goal"
    assert done.reviewer_note == Some(done_note)

    // And the operator reads the same evidence the reviewer was shown, from
    // the same cell: one recorded run, not two renderings of one fact.
    let assert Ok(board) = goal_pending.read(instance.runtime.session, 0)
    let assert json.Object(board_fields) = board
    assert list.key_find(board_fields, "check") == Ok(json.String("exit 0"))
    let assert Ok(json.Object(run)) = list.key_find(board_fields, "last_check")
      as "the board carries the run the reviewer was shown"
    assert list.key_find(run, "command") == Ok(json.String("exit 0"))
    assert list.key_find(run, "status") == Ok(json.Int(0))
    assert list.key_find(run, "not_finished") == Ok(json.Null)

    serve.close_instance(instance)
  })
}

// --- the scripted session ----------------------------------------------------
// The goal cell, polled until its status is the one the fixture waits
// on. The poll reads the durable cell directly — the same read the
// goal_get board projects — because the loop's transitions are
// asynchronous to the fixture's own steps.
fn poll_goal(
  instance: serve.Instance,
  status: String,
) -> poll.Outcome(GoalCell, Nil) {
  poll.until(within: await_ms, every: 100, attempt: fn() {
    case api.fact(instance.runtime, advisor.goal_key) {
      Ok(Some(payload)) ->
        case cell_of(payload) {
          Ok(goal) ->
            case goal.status == status {
              True -> poll.Done(goal)
              False -> poll.Retry
            }
          Error(Nil) -> poll.Retry
        }
      _other -> poll.Retry
    }
  })
}

type GoalCell {
  GoalCell(
    status: String,
    reason: option.Option(String),
    continuations: Int,
    zero_progress: Int,
    reviewer_note: option.Option(String),
  )
}

// The four fields the fixtures read, out of the cell the goal codec
// writes. The status is a wire word so the poll waits on the exact
// string the board would show, and the reason beside it is the cause the
// word cannot carry on its own.
fn cell_of(payload: json.JsonValue) -> Result(GoalCell, Nil) {
  case payload {
    json.Object(fields) ->
      case list.key_find(fields, "status") {
        Ok(json.String(status)) -> {
          let continuations = case list.key_find(fields, "continuations") {
            Ok(json.Int(n)) -> n
            _absent_or_older -> 0
          }
          let zero_progress = case list.key_find(fields, "zero_progress") {
            Ok(json.Int(n)) -> n
            _absent_or_older -> 0
          }
          let note = case list.key_find(fields, "reviewer_note") {
            Ok(json.String(text)) -> Some(text)
            _absent -> None
          }
          let reason = case list.key_find(fields, "reason") {
            Ok(json.String(word)) -> Some(word)
            _absent_or_null -> None
          }
          Ok(GoalCell(
            status:,
            reason:,
            continuations:,
            zero_progress:,
            reviewer_note: note,
          ))
        }

        _missing_or_mistyped -> Error(Nil)
      }

    _not_an_object -> Error(Nil)
  }
}

// Distinct goal feeds, not advisor bodies: every later advisor request
// replays its whole branch, so one body carries every earlier feed's
// header too. The count is the occurrences in the newest body, which is
// the whole branch at its newest — exactly how many feeds were ever
// sent, one header each.
fn goal_feeds_seen(script: Subject(ScriptMessage)) -> Int {
  case seen(script).advisor {
    [] -> 0

    bodies -> {
      let assert Ok(newest) = list.last(bodies)
      occurrences(newest, advisorslice.goal_feed_header)
    }
  }
}

fn occurrences(text: String, marker: String) -> Int {
  list.length(string.split(text, marker)) - 1
}

fn complete(instance: serve.Instance, text: String) -> Nil {
  let admitted: poll.Outcome(ids.OpId, Nil) =
    poll.until(within: await_ms, every: 100, attempt: fn() {
      case api.prompt(instance.runtime, [user(text)]) {
        Ok(op) -> poll.Done(op)
        Error(api.AcceptRejected(reason: acceptance.StrandBusy)) -> poll.Retry
        Error(other) -> panic as string.inspect(other)
      }
    })
  let assert poll.Answered(value: op) = admitted
    as "the instance must admit the operator's turn through its own writer"
  let assert Ok(operation.RunLastResult(outcome: completion, ..)) =
    api.await_result(instance.runtime, op, within_ms: 60_000)
    as "the operator's turn must settle through the real machine"
  assert completion == operation.RunCompleted(operation.CompletedByAssistant)
  Nil
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

// --- the two scripted models ---------------------------------------------------
/// How the scripted primary answers the runs the loop wakes it with.
///
/// The style decides which of the harness's bounds the fixture can
/// reach, so it is the one knob the three goal fixtures differ by. A
/// `Bool` could not carry that: the question is not whether something is
/// on but which of three transcripts the primary writes.
type PrimaryStyle {
  /// Plain text on every woken run. A stretch that commits no tool
  /// result and no operator turn is zero-progress by definition, so two
  /// of them pause the goal long before the continuation cap could.
  SaysNothing

  /// One tool call per woken run. The call is refused — the name is not
  /// a registered tool — and a refusal is still a committed tool result,
  /// which is work by the loop's own predicate. So the zero-progress
  /// bound never fires and the continuation cap is the bound left to
  /// stop the loop.
  CallsATool

  /// The first continuation's run is left unanswered, so it stays live
  /// on the real machine until the fixture aborts it. A mid-flight abort
  /// needs a run in flight, and the scripted provider otherwise answers
  /// in microseconds.
  HoldsTheContinuation
}

type Seen {
  Seen(
    primary: List(String),
    advisor: List(String),
    /// Whether the fixture has released the completion: every goal feed
    /// after it is answered `complete` rather than `continue`.
    completing: Bool,
    /// How this fixture's primary answers its continuations.
    style: PrimaryStyle,
    /// The primary request the continuation's run is waiting on, held
    /// under `HoldsTheContinuation`.
    held: option.Option(Subject(String)),
  )
}

type ScriptMessage {
  Dispatched(url: String, body: String, reply: Subject(String))
  Snapshot(reply: Subject(Seen))
  AnswerComplete(reply: Subject(Nil))
  ReleaseHeld(reply: Subject(Nil))
}

fn script(style: PrimaryStyle) -> Subject(ScriptMessage) {
  let assert Ok(started) =
    actor.new(Seen(
      primary: [],
      advisor: [],
      completing: False,
      style:,
      held: option.None,
    ))
    |> actor.on_message(dispatch)
    |> actor.start
    as "the two-model script must start"
  started.data
}

fn dispatch(
  seen: Seen,
  message: ScriptMessage,
) -> actor.Next(Seen, ScriptMessage) {
  case message {
    // The completion the abort fixture releases after its resume: the
    // next goal feed is answered with `complete` rather than `continue`.
    AnswerComplete(reply:) -> {
      process.send(reply, Nil)
      actor.continue(Seen(..seen, completing: True))
    }

    // Releases the held primary reply after the fixture aborted the run
    // it belonged to. The abort settles the run synthetically; releasing
    // the reply lets the in-flight transport call finish rather than
    // dangle against a run that no longer wants it.
    ReleaseHeld(reply:) -> {
      case seen.held {
        Some(waiting) -> {
          process.send(
            waiting,
            text_turn("primary-held", primary_model, "aborted mid-flight"),
          )
          process.send(reply, Nil)
          actor.continue(Seen(..seen, held: option.None))
        }

        option.None -> {
          process.send(reply, Nil)
          actor.continue(seen)
        }
      }
    }
    Snapshot(reply:) -> {
      process.send(
        reply,
        Seen(
          primary: list.reverse(seen.primary),
          advisor: list.reverse(seen.advisor),
          completing: seen.completing,
          style: seen.style,
          held: seen.held,
        ),
      )
      actor.continue(seen)
    }
    Dispatched(url:, body:, reply:) ->
      case string.contains(url, advisor_host) {
        True -> {
          process.send(reply, advisor_answer(body, seen.completing))
          actor.continue(Seen(..seen, advisor: [body, ..seen.advisor]))
        }
        False -> {
          // The operator's own turn is answered the same way in every
          // fixture; the style decides only what the loop's own
          // continuations are answered with.
          case list.length(seen.primary) {
            0 -> {
              process.send(
                reply,
                text_turn("primary-1", primary_model, "still working"),
              )
              actor.continue(Seen(..seen, primary: [body, ..seen.primary]))
            }

            _continuation -> continuing(seen, body, reply)
          }
        }
      }
  }
}

// The primary's answer inside a run the loop woke, which is the whole of
// what the three fixtures differ by.
fn continuing(
  seen: Seen,
  body: String,
  reply: Subject(String),
) -> actor.Next(Seen, ScriptMessage) {
  let recorded = Seen(..seen, primary: [body, ..seen.primary])

  case seen.style {
    HoldsTheContinuation -> actor.continue(Seen(..recorded, held: Some(reply)))

    SaysNothing -> {
      process.send(
        reply,
        text_turn("primary-n", primary_model, "still working"),
      )
      actor.continue(recorded)
    }

    // One call per woken run, and the run ends on the request that
    // carries its result. Without the second arm the primary would call
    // the tool again on every request of the same run and the run would
    // never end.
    CallsATool ->
      case probed_since_the_wake(body) {
        True -> {
          process.send(
            reply,
            text_turn("primary-done", primary_model, "that is as far as I got"),
          )
          actor.continue(recorded)
        }

        False -> {
          process.send(
            reply,
            tool_turn(
              "primary-probe",
              primary_model,
              probe_tool,
              json.Object([#("why", json.String("checking the migration"))]),
            ),
          )
          actor.continue(recorded)
        }
      }
  }
}

/// The tool the cap fixture's primary calls. The name is deliberately not
/// a registered tool: clearance refuses it and stages a synthetic error
/// result, which is a committed tool result on the primary's branch and
/// therefore work by `goalloop.progress_of`. What the fixture needs is a
/// stretch that is not zero-progress, and a refusal is the cheapest one
/// there is — no jail, no approval, no workspace state.
const probe_tool = "no_such_tool"

// Whether the primary already made its call inside the run it is
// answering now. The stretch after the newest continuation frame is that
// run's own, so a probe in it is this run's rather than an earlier one's
// replayed — the branch replays every request, so a test of the whole
// body would answer `True` from the second continuation onward and the
// primary would never call the tool again.
fn probed_since_the_wake(body: String) -> Bool {
  case list.last(string.split(body, advisorslice.continuation_header)) {
    Ok(tail) -> string.contains(tail, probe_tool)
    Error(Nil) -> False
  }
}

// The advisor's answer. A goal feed is answered with `continue` — the
// adversarial reviewer the bounds exist for — and with `complete` once
// the fixture has released the completion. Ordinary feeds, which the
// loop never sends while the goal is active, answer quiet.
// The advisor's answer, by the shape of the request: a request that
// ends with an unanswered goal feed is answered with the verdict the
// fixture's phase draws; a request whose newest goal feed already
// carries its tool result is the review's tail, and ends the run with
// plain text — the same `answered` reading the advisor e2e makes,
// because an advisor scripted to call `advise` forever would never end
// its run and the loop's reviews would never finish.
fn advisor_answer(body: String, completing: Bool) -> String {
  let goal_feed = string.contains(body, advisorslice.goal_feed_header)
  let answered = answered_goal_feed(body)

  case goal_feed, answered, completing {
    _, True, _ -> text_turn("advisor-said", advisor_model, "noted")

    True, False, False -> advise_call("advise-continue", "continue", remaining)
    True, False, True -> advise_call("advise-complete", "complete", done_note)

    // An ordinary feed — which the loop never sends while the goal is
    // live, but the coalescing machinery can — answers quiet.
    False, False, _ -> advise_call("advise-quiet", "quiet", "")
  }
}

// Whether the newest goal feed in `body` has already been answered: the
// request that ends a review carries the tool result after the feed it
// answered, and the request that opens one ends with the feed itself.
fn answered_goal_feed(body: String) -> Bool {
  case list.last(string.split(body, advisorslice.goal_feed_header)) {
    Ok(tail) -> string.contains(tail, "\"tool_result\"")
    Error(Nil) -> False
  }
}

fn advise_call(id: String, verdict: String, text: String) -> String {
  let arguments = case text {
    "" -> json.Object([#("verdict", json.String(verdict))])
    said ->
      json.Object([
        #("verdict", json.String(verdict)),
        #("text", json.String(said)),
      ])
  }
  tool_turn(id, advisor_model, advise.name, arguments)
}

fn seen(script: Subject(ScriptMessage)) -> Seen {
  actor.call(script, waiting: 5000, sending: fn(reply) { Snapshot(reply) })
}

fn scripted_transport(script: Subject(ScriptMessage)) -> http.Transport {
  provider_test.transport(fn(request: http.HttpRequest, events) {
    let response =
      actor.call(
        script,
        waiting: test_timeout_seconds * 1000,
        sending: fn(reply) { Dispatched(request.url, request.body, reply) },
      )
    process.send(
      events,
      http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
    )
    process.send(events, http.ResponseChunk(bit_array.from_string(response)))
    process.send(events, http.ResponseEnd)
  })
}

// --- the wire shapes ------------------------------------------------------------
fn text_turn(id: String, model_id: String, text: String) -> String {
  started(id, model_id) <> text_block(0, text) <> stopped("end_turn")
}

fn text_block(index: Int, text: String) -> String {
  let at = int.to_string(index)
  sse(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":"
      <> at
      <> ",\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> sse(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":"
      <> at
      <> ",\"delta\":{\"type\":\"text_delta\",\"text\":"
      <> json.to_string(json.String(text))
      <> "}}",
  )
  <> sse(
    "content_block_stop",
    "{\"type\":\"content_block_stop\",\"index\":" <> at <> "}",
  )
}

fn tool_turn(
  id: String,
  model_id: String,
  name: String,
  arguments: json.JsonValue,
) -> String {
  started(id, model_id)
  <> sse(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,"
      <> "\"content_block\":{\"type\":\"tool_use\",\"id\":\""
      <> id
      <> "\",\"name\":\""
      <> name
      <> "\",\"input\":{}}}",
  )
  <> sse(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,"
      <> "\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":"
      <> json.to_string(json.String(json.to_string(arguments)))
      <> "}}",
  )
  <> sse("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}")
  <> stopped("tool_use")
}

fn started(id: String, model_id: String) -> String {
  sse(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\""
      <> id
      <> "\",\"model\":\""
      <> model_id
      <> "\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}",
  )
}

fn stopped(reason: String) -> String {
  sse(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\""
      <> reason
      <> "\"},\"usage\":{\"output_tokens\":1}}",
  )
  <> sse("message_stop", "{\"type\":\"message_stop\"}")
}

fn sse(event: String, data: String) -> String {
  "event: " <> event <> "\ndata: " <> data <> "\n\n"
}

// --- waiting on the loop ------------------------------------------------------
// The same wait against the reviewer's own requests, which is where a claim
// about what the reviewer was shown has to land: a body is what was sent.
fn await_advisor(script: Subject(ScriptMessage), marker: String) -> String {
  let found: poll.Outcome(String, Nil) =
    poll.until(within: await_ms, every: 100, attempt: fn() {
      case latest_with(seen(script).advisor, marker) {
        Ok(body) -> poll.Done(body)
        Error(Nil) -> poll.Retry
      }
    })
  let assert poll.Answered(value: body) = found
    as "the marker must reach an advisor request inside the wait"
  body
}

fn await_primary(script: Subject(ScriptMessage), marker: String) -> String {
  let found: poll.Outcome(String, Nil) =
    poll.until(within: await_ms, every: 100, attempt: fn() {
      case latest_with(seen(script).primary, marker) {
        Ok(body) -> poll.Done(body)
        Error(Nil) -> poll.Retry
      }
    })
  let assert poll.Answered(value: body) = found
    as "the marker must reach a primary request inside the wait"
  body
}

fn latest_with(bodies: List(String), marker: String) -> Result(String, Nil) {
  bodies
  |> list.filter(string.contains(_, marker))
  |> list.last
}

// --- the catalogue and the instance ---------------------------------------------
fn scripted_catalog() -> catalog.Catalog {
  catalog.Catalog(
    models: [
      entry("acme", "https://" <> primary_host, primary_model, "ACME_KEY"),
      entry("sage", "https://" <> advisor_host, advisor_model, "SAGE_KEY"),
    ],
    roles: [#(model.Main, ["acme"]), #(catalog.advisor_role, ["sage"])],
    mcp_servers: [],
  )
}

fn entry(
  name: String,
  base_url: String,
  model_id: String,
  api_key_env: String,
) -> catalog.CatalogModel {
  catalog.CatalogModel(
    name:,
    dialect: catalog.Anthropic,
    base_url:,
    api_key_env:,
    model_id:,
    context_window: 100_000,
    max_output_tokens: 4096,
    thinking: model.ThinkingOff,
    vision: catalog.TextOnly,
    max_images: 8,
    pricing: None,
  )
}

fn gateway_of(script: Subject(ScriptMessage)) -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: scripted_transport(script),
    secrets: secret.from_list([
      #("ACME_KEY", "goal-e2e-primary-key"),
      #("SAGE_KEY", "goal-e2e-advisor-key"),
    ]),
    clock: clock.fixed(at: 0),
  )
}

fn fixture_root(label: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test process must know where it is"
  let root =
    here
    <> "/build/goal-e2e-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.delete_all([root])
    as "a previous run's fixture tree must be removable"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "the fixture workspace must be creatable"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/home")
    as "the fixture home must be creatable"
  root
}

fn settings(root: String, script: Subject(ScriptMessage)) -> serve.Settings {
  let assert Ok(here) = simplifile.current_directory()
    as "the test process must know where it is"
  serve.Settings(
    secrets: secret.env(),
    secret_failures: [],
    session_path: root <> "/session.db",
    domain_paths: None,
    bind_host: "not an interface",
    bind_port: -1,
    token_path: root <> "/transport-only/daemon.token",
    workspace: root <> "/work",
    base_policy: serve.base_policy(root <> "/work"),
    helper_path: here <> "/../sandbox/loom-exec",
    helper_pool_size: 2,
    session_id: fixture_session,
    demand: exec.BestEffort,
    gateway: gateway_of(script),
    catalog: scripted_catalog(),
    system: None,
    home: Some(root <> "/home"),
    model: machine_strand.ModelIdentity(
      provider: "acme",
      model_id: primary_model,
    ),
    context_window: 100_000,
    max_output_tokens: 4096,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000,
    ),
    codemode_seed: root <> "/no-such-seed",
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    retry_policy: retryconf.default_policy,
    deactivated_tools: [],
    memory: distillpass.no_pass(),
    tools: catalog.default_tools(),
    advisor: Some(advisor.Settings(
      model: machine_strand.ModelIdentity(
        provider: "sage",
        model_id: advisor_model,
      ),
      thinking: machine_strand.ThinkingOff,
      tools: ["fs_read", "grep"],
      // Run-end-only: the loop's reviews are the fixture's reviews, and a
      // step trigger would add goal feeds whose count depends on host
      // timing — the scheduling this fixture is written not to depend on.
      feed_every_steps: 0,
      block_cooldown_reviews: 2,
    )),
  )
}

// --- the acceptance case: the operator's own door ---------------------------
// Every fixture above drives `instance.goal` directly, which is the seam the
// gateway forwards to — and that is exactly why none of them noticed that the
// gateway was never given it. `hub.with_goal_control` had one caller, a unit
// test that injected the seam by hand, so on a real server every goal
// mutation answered `code_unsupported`: a session with a routed advisor
// telling its operator it had no reviewer.
//
// This fixture issues the six commands as frames over the instance's own
// hub, which is the production assembly, and reads the boards back.
pub fn the_six_goal_commands_work_over_the_real_gateway_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    let root = fixture_root("gateway")
    let script = script(SaysNothing)
    let assert Ok(instance) =
      serve.open_instance(settings(root, script), log.discard())
      as "the goal fixture must open a real instance"
    let assert Ok(helper) = exec.checkout(instance.pool, waiting: 5000)
      as "the instance must have a real, handshaken helper"
    exec.checkin(instance.pool, helper)

    // A real, authenticated attachment. The instance's hub is a *network*
    // hub, which disconnects a client that sends frames on the unauthenticated
    // door, so the fixture goes through the same admission the websocket
    // listener uses.
    let inbox = process.new_subject()
    let handle = authenticated(instance, inbox)

    // One frame in, one answer out. A network hub answers a command through
    // the request's own reply capability and reserves the pushed-frame sink
    // for frames it raised itself, so this is the door the websocket
    // listener uses and the only one that answers.
    let command = fn(id: Int, cmd: protocol.Command) -> String {
      let assert Ok(answer) =
        gateway.connection_request(
          handle,
          protocol.encode_command(protocol.CommandEnvelope(id:, command: cmd)),
        )
        as "the hub must answer the operator's command"
      answer
    }

    // Commands are answered only for a subscribed connection, so the
    // subscription is part of the operator's door rather than a detail. An
    // authenticated connection subscribes with the session its own binding
    // names, which is the canonical id.
    let subscribed =
      command(
        700,
        protocol.Subscribe(
          ids.session_id_to_string(api.session_id(instance.runtime)),
          None,
        ),
      )
    assert string.contains(subscribed, "snapshot")
      as "the fixture connection must be subscribed before it commands"

    // `goal_set` commits and answers with the fresh board, which is the
    // reply protocol 044 §7 fixes. An unrouted seam would answer
    // `code_unsupported` here, which is the whole of the regression.
    let pinned =
      command(
        701,
        protocol.GoalSet(objective:, token_budget: 400_000, check: None),
      )
    assert string.contains(pinned, "\"mode\":\"goal\"")
      as "goal_set must answer with the fresh board, not a refusal"
    assert string.contains(pinned, "\"status\":\"active\"")
    assert string.contains(pinned, objective)

    // The read is the same board, observed without touching the goal.
    let read = command(702, protocol.GoalGet)
    assert string.contains(read, "\"status\":\"active\"")
    assert string.contains(read, "\"token_budget\":400000")

    // The pause carries its cause, because the status word alone names four
    // different pauses.
    let held = command(703, protocol.GoalPause)
    assert string.contains(held, "\"status\":\"paused\"")
    assert string.contains(held, "\"reason\":\"operator\"")

    let resumed = command(704, protocol.GoalResume)
    assert string.contains(resumed, "\"status\":\"active\"")

    // The sixth command sets the check without touching the objective, and
    // answers with the same board every other goal mutation answers with.
    let checked = command(706, protocol.GoalCheck(command: Some("make check")))
    assert string.contains(checked, "\"check\":\"make check\"")
      as "goal_check must answer with the fresh board carrying the command"
    assert string.contains(checked, objective)
      as "setting the check leaves the objective where it was"

    // And a body with no command clears it, which is the one spelling the
    // wire has for that.
    let unchecked = command(707, protocol.GoalCheck(command: None))
    assert string.contains(unchecked, "\"check\":null")

    // And the clear retires the cell, so the board is the positive empty one
    // rather than a refusal.
    let cleared = command(708, protocol.GoalClear)
    assert string.contains(cleared, "\"status\":\"none\"")

    // The objective's bound is the server's, refused in words with both
    // counts rather than written to a cell no client can draw.
    let oversized =
      command(
        709,
        protocol.GoalSet(
          objective: string.repeat("a", protocol.objective_limit + 1),
          token_budget: 400_000,
          check: None,
        ),
      )
    assert string.contains(oversized, "\"event\":\"error\"")
    assert string.contains(oversized, "\"reply_to\":709")
      as "a refused body is answered against the request that carried it"
    assert string.contains(oversized, int.to_string(protocol.objective_limit))
      as "the operator is told the bound, not just that something was wrong"

    serve.close_instance(instance)
  })
}

// One authenticated attachment on the instance's own hub, with the owner's
// authority. The credential digest and the principal are the fixture's; what
// matters is that the frames travel the authenticated door, because that is
// the only door a network hub serves.
fn authenticated(
  instance: serve.Instance,
  inbox: Subject(String),
) -> gateway.ConnectionHandle {
  let assert Ok(digest) = access.credential_digest(string.repeat("a", 64))
    as "the fixture credential digest must be well formed"
  let principal =
    access.Principal("operator", "Operator", access.MemberPrincipal)
  let role = access.Owner
  let assert Ok(handle) =
    gateway.attach_authenticated(
      instance.gateway,
      gateway.Binding(
        // The *canonical* session id, which is what the hub admits a
        // binding against; the display name the hub was started under is a
        // different key space (protocol-change/008) and is what `subscribe`
        // asks for.
        ids.session_id_to_string(api.session_id(instance.runtime)),
        "epoch",
        "incarnation",
        "connection-operator",
        principal,
        role,
        digest,
      ),
      fn() { Ok(#(principal, role)) },
      fn(frame) { process.send(inbox, frame) },
      fn() { Nil },
      fn() { Nil },
      process.self(),
    )
    as "the fixture client must attach to the instance's own hub"
  handle
}
