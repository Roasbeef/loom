//// The advisor loop: the three hook slots, the verdict-to-acknowledgement
//// mapping, and the feed against a real session store.
////
//// The hook tests need no runtime at all — every slot decides what to do
//// from the operation's own `op.meta` cell — so they run against a bare
//// memory session with no actor registered, which is also the production
//// state while the service supervisor is restarting one. The feed tests
//// open a real runtime over an in-memory session, because what the feed
//// does is scan a branch, commit a durable message onto another strand
//// and write a cursor cell, and none of those can be faked without
//// testing the fake.

import client/advisor
import client/advisorguard
import client/agency
import client/goalstate
import core/clock
import core/entry.{type Entry}
import core/ids.{type EntryId, type OpId, type UsageId}
import core/json
import core/message
import core/register
import core/tx.{InsertUsage, SetRegister, Tx}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor as otp_actor
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import runtime/hooks
import runtime/lineage
import session/session.{type Session}
import storage/storage
import support/addresses
import telemetry/log
import tools/advise
import tools/agent
import weft/registry as address

// --- the run-start slot ----------------------------------------------------

// One `Effects` record serves every strand, so the nudges drain has to be
// keyed on the operation's own strand. A subagent's run start must cost
// exactly what it cost before advisors existed.
pub fn a_foreign_strand_run_start_is_left_alone_test() {
  let opened = a_session()
  let wiring = a_wiring(opened)
  let operation = an_operation(opened, "sub:main/reviewer-1", 3)
  let hooked =
    advisor.hooks(
      hooks.new()
        |> hooks.with_run_start(fn(_operation) { [user("a house rule")] })
        |> hooks.build,
      wiring,
    )

  let assert [only] = hooked.run_start(operation)
    as "a foreign strand must be handed the inner list unchanged"
  assert text_of(only) == "a house rule"
}

// The primary's run start with no actor registered: the drain degrades to
// no nudges rather than to a crashed driver. This is the state a restart
// of the service supervisor leaves behind.
pub fn an_absent_actor_yields_no_nudges_test() {
  let opened = a_session()
  let wiring = a_wiring(opened)
  let operation = an_operation(opened, advisor.primary, 5)
  let hooked = advisor.hooks(hooks.build(hooks.new()), wiring)

  assert hooked.run_start(operation) == []
}

// --- the context slot ------------------------------------------------------

// The advisor's standing instructions lead its own requests and appear in
// nobody else's.
pub fn the_advisor_is_handed_its_instructions_test() {
  let opened = a_session()
  let wiring = a_wiring(opened)
  let operation = an_operation(opened, advisor.strand, 7)
  let hooked = advisor.hooks(hooks.build(hooks.new()), wiring)

  let assert [first, second] = hooked.context(operation, [user("the feed")])
    as "the instructions must lead the projection"
  assert text_of(first) == advisor.brief
  assert text_of(second) == "the feed"
}

pub fn the_primary_is_not_handed_the_instructions_test() {
  let opened = a_session()
  let wiring = a_wiring(opened)
  let operation = an_operation(opened, advisor.primary, 9)
  let hooked = advisor.hooks(hooks.build(hooks.new()), wiring)

  let assert [only] = hooked.context(operation, [user("the prompt")])
    as "the primary's projection must be handed back unchanged"
  assert text_of(only) == "the prompt"
}

// --- the run-end slot ------------------------------------------------------

// The notification is a side effect beside the slot's contract, never
// instead of it: an earlier layer's follow-up must still be what the
// driver reads.
pub fn the_run_end_answer_is_passed_through_test() {
  let opened = a_session()
  let wiring = a_wiring(opened)
  let operation = an_operation(opened, advisor.primary, 11)
  let hooked =
    advisor.hooks(
      hooks.new()
        |> hooks.with_run_end(fn(_operation) { Some(user("carry on")) })
        |> hooks.build,
      wiring,
    )

  let assert Some(placed) = hooked.run_end(operation)
    as "the inner follow-up must survive the notification"
  assert text_of(placed) == "carry on"
}

// --- what the advisor is told ----------------------------------------------

// Only a `Deliver` sends anything. The other four decisions have already
// happened inside the guard, and a send evaluated to produce an argument
// they ignore would emit advice the guard just dropped.
pub fn only_a_delivery_sends_test() {
  let exploding = fn(_text) { panic as "no send is allowed on this arm" }

  assert advisor.outcome(advisorguard.Silent, exploding, advisor.Held)
    == #(Ok(advise.Acknowledged), None)
  assert advisor.outcome(
      advisorguard.Queued(text: "a nit"),
      exploding,
      advisor.Held,
    )
    == #(Ok(advise.Queued), None)
  assert advisor.outcome(
      advisorguard.Downgraded(text: "too soon", reason: "one run left"),
      exploding,
      advisor.Held,
    )
    == #(Ok(advise.Downgraded(reason: "one run left")), None)
  assert advisor.outcome(
      advisorguard.Dropped(reason: "said already"),
      exploding,
      advisor.Held,
    )
    == #(Ok(advise.Dropped(reason: "said already")), None)
}

// A queue that went out at once is its own acknowledgement, and a
// downgraded block keeps the variant that says it was downgraded: an
// advisor told `Delivered` would believe the primary had been stopped,
// which is the one thing a downgrade means did not happen.
pub fn a_woken_queue_is_told_apart_from_a_delivered_block_test() {
  let exploding = fn(_text) { panic as "no send is allowed on this arm" }
  let woken = advisor.Woken(how: "started a run on the idle primary")

  assert advisor.outcome(advisorguard.Queued(text: "a nit"), exploding, woken)
    == #(Ok(advise.Woke(how: "started a run on the idle primary")), None)

  let assert #(Ok(advise.Downgraded(reason:)), None) =
    advisor.outcome(
      advisorguard.Downgraded(text: "too soon", reason: "one review left"),
      exploding,
      woken,
    )
    as "a downgrade must stay a downgrade even when its queue went out"
  assert string.contains(reason, "one review left")
  assert string.contains(reason, "idle primary")
}

// A wake whose send was refused loses the nudges it drained, so the call
// is an error outcome rather than a quiet success.
pub fn a_refused_wake_is_an_error_outcome_test() {
  let exploding = fn(_text) { panic as "no send is allowed on this arm" }
  let refused = advisor.Refused(reason: "the primary would not take it")

  assert advisor.outcome(advisorguard.Queued(text: "a nit"), exploding, refused)
    == #(Error("the primary would not take it"), None)
}

// The advisor is told which door the message went through, because that
// is what it decides its next verdict from. The run a block opened
// travels back beside it, because the actor must not later read that run
// start as the operator arriving.
pub fn a_delivery_names_the_door_test() {
  let steered = fn(_text) { Ok(api.Steered(entry: an_entry_id())) }
  let assert #(Ok(advise.Delivered(how:)), None) =
    advisor.outcome(advisorguard.Deliver(text: "stop"), steered, advisor.Held)
    as "a steer must be reported as a delivery and open no run"
  assert string.contains(how, "open run")

  let opened = an_op_id(1)
  let started = fn(_text) { Ok(api.Started(operation: opened)) }
  let assert #(Ok(advise.Delivered(how: how_started)), Some(run)) =
    advisor.outcome(advisorguard.Deliver(text: "stop"), started, advisor.Held)
    as "a fresh run must be reported as a delivery and handed back"
  assert string.contains(how_started, "idle")
  assert run == opened
}

pub fn a_refused_delivery_is_an_error_outcome_test() {
  let refused = fn(_text) { Error("the primary would not take it") }

  assert advisor.outcome(
      advisorguard.Deliver(text: "stop"),
      refused,
      advisor.Held,
    )
    == #(Error("the primary would not take it"), None)
}

// --- the active tool list --------------------------------------------------

// A tool the operator named that this host does not build is dropped
// rather than refused, and `advise` is added whatever the table says.
pub fn the_advisor_gets_the_tools_this_host_built_test() {
  let settings = some_settings(["grep", "curl"])

  assert advisor.active_tools(settings, ["bash", "fs_read", "grep"])
    == ["advise", "grep"]
}

// An operator who names `advise` gets one of it, not two: the list is the
// provider's tool array, and a repeated name is a malformed request.
pub fn advise_is_granted_once_test() {
  let settings = some_settings(["advise"])

  assert advisor.active_tools(settings, ["advise", "bash"]) == ["advise"]
}

// A host that deactivated `advise` would otherwise get an advisor strand
// with a driver, a model and no way to say anything. It is refused by
// name at boot instead.
pub fn an_unregistered_advise_tool_refuses_the_strand_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Error(reason) =
    advisor.ensure_strand(rig.runtime, some_settings([]), ["bash", "grep"])
    as "a host with no `advise` tool must refuse the strand"
  assert string.contains(reason, "advise")
  stop(rig)
}

// --- the loop against a real store -----------------------------------------

// The whole feed path: the primary's branch is scanned from the root, the
// entries are rendered into one message the advisor receives, and the
// cursor advances to the newest entry the scan saw.
pub fn a_primary_run_end_feeds_the_advisor_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [
      user("write the migration"),
      user("and its down step"),
      user("then run the gate"),
    ])
    as "the primary must accept the fixture run"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  process.send(subject, advisor.PrimaryRunEnded(operation: an_op_id(2)))
  let _drained = settle(subject)

  let assert [fed] = advisor_texts(rig.opened)
    as "exactly one feed must reach the advisor"
  assert string.contains(fed, "write the migration")
  assert string.contains(fed, "and its down step")
  assert string.contains(fed, "then run the gate")
  assert cursor(rig.runtime) != None
  stop(rig)
}

// --- the step trigger ------------------------------------------------------

// The threshold is a floor, so the steps below it buy nothing. This is
// the half that keeps a step feed from costing one review per tool round
// trip against a primary that has not decided anything yet.
pub fn steps_below_the_threshold_do_not_feed_test() {
  let assert Ok(rig) = a_rig_with(stepping(3)) as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  step(subject, 2)

  assert advisor_texts(rig.opened) == []
  assert cursor(rig.runtime) == None
  stop(rig)
}

// And the step that reaches it does feed, without the primary's run
// having ended — which is the whole point of the trigger. The slice says
// the run is still open, because the advisor weighs a block against a
// half-finished task differently from a finished one.
pub fn the_step_threshold_feeds_a_mid_run_slice_test() {
  let assert Ok(rig) = a_rig_with(stepping(3)) as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  step(subject, 3)

  let assert [fed] = advisor_texts(rig.opened)
    as "the third step must feed the advisor exactly once"
  assert string.contains(fed, "write the migration")
  assert string.contains(fed, "the primary's run is still open")
  assert string.contains(fed, "3 steps since your last review")
  assert cursor(rig.runtime) != None
  stop(rig)
}

// The count restarts as the slice is offered, so a threshold of three is
// a feed every three steps rather than a feed on every step past the
// third.
pub fn the_step_count_restarts_at_each_feed_test() {
  let assert Ok(rig) = a_rig_with(stepping(3)) as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  step(subject, 3)
  let assert [_first] = advisor_texts(rig.opened)
    as "the third step must feed the advisor"

  // Two more steps is one short of the next threshold, and the primary
  // has appended nothing since, so neither the count nor the cursor has
  // anything to offer.
  step(subject, 2)
  let assert [_still_one] = advisor_texts(rig.opened)
    as "two further steps must not feed again"
  stop(rig)
}

// Zero is the operator asking for the run-end-only cadence the advisor
// shipped with. The steps are still counted — the arithmetic lives in one
// place — and never reach a threshold.
pub fn a_zero_step_interval_never_feeds_mid_run_test() {
  let assert Ok(rig) = a_rig_with(stepping(0)) as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  step(subject, 40)

  assert advisor_texts(rig.opened) == []

  // The run end still feeds, so the posture costs the reviewer nothing it
  // had before the trigger existed.
  process.send(subject, advisor.PrimaryRunEnded(operation: an_op_id(2)))
  let _drained = settle(subject)
  let assert [_fed] = advisor_texts(rig.opened)
    as "a run end must still feed an advisor with mid-run feeds off"
  stop(rig)
}

// The usage ledger is not strand-scoped, so the advisor's own requests
// reach the same slot. Counting those would let a long review trip the
// threshold it is itself the reason for, feeding the reviewer on the
// strength of its own token spend.
pub fn only_the_primarys_steps_are_counted_test() {
  let assert Ok(rig) = a_rig_with(stepping(2)) as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"

  let composed =
    advisor.hooks(effects.default_hooks(), a_wiring_named(rig.opened, rig.name))
  let mine = an_operation(rig.opened, advisor.strand, 71)
  let theirs = an_operation(rig.opened, "sub:main/helper", 72)

  // Four steps that are not the primary's, which is twice the threshold.
  composed.usage(mine, usage_row())
  composed.usage(mine, usage_row())
  composed.usage(theirs, usage_row())
  composed.usage(theirs, usage_row())

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let _drained = settle(subject)
  assert advisor_texts(rig.opened) == []

  // The primary's own two then reach the threshold through the same slot.
  let ours = an_operation(rig.opened, advisor.primary, 73)
  composed.usage(ours, usage_row())
  composed.usage(ours, usage_row())
  let _settled = settle(subject)

  let assert [_fed] = advisor_texts(rig.opened)
    as "the primary's own steps must reach the threshold"
  stop(rig)
}

// Coalescing is the whole backpressure story: an advisor with a run open
// is left alone, and the cursor stays where it was so the stretch it has
// not seen is still owed to it at the next run end.
pub fn a_busy_advisor_is_not_fed_again_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"

  // The advisor is reviewing something already. Nothing here is the
  // actor's doing, which is the point: the actor has to read the
  // advisor's durable state rather than remember what it last sent.
  let assert Ok(_busy) =
    api.send_to_strand(
      rig.runtime,
      to: advisor.strand,
      message: user("an earlier feed"),
    )
    as "the advisor must take the fixture feed"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  process.send(subject, advisor.PrimaryRunEnded(operation: an_op_id(2)))
  let _drained = settle(subject)

  let assert [only] = advisor_texts(rig.opened)
    as "the busy advisor must have been left alone"
  assert only == "an earlier feed"
  assert cursor(rig.runtime) == None
  stop(rig)
}

// The catch-up, which is why `AdvisorRunEnded` exists at all. The
// driver resolves `run_end` before the run closes, so the advisor still
// reads as busy at exactly the moment its review is finishing; a feed
// that yielded to that would never catch up on anything.
//
// The debt is what the catch-up answers, so the primary's run end has to
// be coalesced away first: that skipped feed is the thing being caught
// up on.
pub fn the_advisors_own_run_end_catches_up_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"
  let assert Ok(_busy) =
    api.send_to_strand(
      rig.runtime,
      to: advisor.strand,
      message: user("an earlier feed"),
    )
    as "the advisor must take the fixture feed"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  process.send(subject, advisor.PrimaryRunEnded(operation: an_op_id(2)))
  let _skipped = settle(subject)
  assert cursor(rig.runtime) == None

  process.send(subject, advisor.AdvisorRunEnded(operation: an_op_id(4)))
  let _drained = settle(subject)

  // The feed lands on the closing run as a steer, so it is off the
  // advisor's branch until that run consumes it. The cursor is the
  // observable that says it was sent: nothing else writes that cell, and
  // a send that failed leaves it alone.
  assert cursor(rig.runtime) != None
  stop(rig)
}

// The window between the advisor's review ending and its settlement
// clearing the store. The driver resolves `run_end` first, so a primary
// run end that lands in that gap reads a cell that still says busy. The
// actor has already seen that review end, so it must feed rather than
// coalesce: a debt recorded here would wait on a review end that has
// already happened, which on an idle session is forever.
pub fn a_primary_run_end_after_a_seen_review_end_is_fed_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"

  // The advisor holds a run that never settles: the fixture provider
  // hangs, so the store shows it busy for the rest of the test. That is
  // the stale cell the race exposes.
  let assert Ok(_busy) =
    api.send_to_strand(
      rig.runtime,
      to: advisor.strand,
      message: user("an earlier feed"),
    )
    as "the advisor must take the fixture feed"
  let assert Some(open) = strand_operation(rig.opened, advisor.strand)
    as "the advisor must be mid-run"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  process.send(subject, advisor.AdvisorRunEnded(operation: open))
  let _quiet = settle(subject)
  assert cursor(rig.runtime) == None

  process.send(subject, advisor.PrimaryRunEnded(operation: an_op_id(2)))
  let _fed = settle(subject)

  // The cursor moved: the primary's stretch was sent rather than owed to
  // a review end that will never come again.
  assert cursor(rig.runtime) != None
  stop(rig)
}

// A different run on the advisor is a live review, whatever run end the
// actor last saw. Only the one operation it has seen end is disbelieved.
pub fn a_later_advisor_run_still_reads_as_busy_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"
  let assert Ok(_busy) =
    api.send_to_strand(
      rig.runtime,
      to: advisor.strand,
      message: user("an earlier feed"),
    )
    as "the advisor must take the fixture feed"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  process.send(subject, advisor.AdvisorRunEnded(operation: an_op_id(9)))
  let _quiet = settle(subject)
  process.send(subject, advisor.PrimaryRunEnded(operation: an_op_id(2)))
  let _coalesced = settle(subject)

  assert cursor(rig.runtime) == None
  stop(rig)
}

// An advisor enabled on a session that already has history reviews what
// happens from now. The actor takes the primary's position at its start
// as the cursor when no cell exists, so the first run end after boot
// offers nothing older than boot.
pub fn an_advisor_started_over_history_reviews_from_now_test() {
  let assert Ok(#(rig, history)) = a_rig_over_history()
    as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  process.send(subject, advisor.PrimaryRunEnded(operation: history))
  let _quiet = settle(subject)
  assert advisor_texts(rig.opened) == []

  // The fixture provider never answers, so the history run is ended by
  // hand before the primary can take a second one.
  api.abort(rig.runtime)
  let assert Ok(_aborted) =
    api.await_result(rig.runtime, history, within_ms: 5000)
    as "the history run must settle once aborted"
  let assert Ok(second) =
    api.accept_quietly(rig.runtime, [user("now add the index")])
    as "the primary must accept the second run"
  process.send(subject, advisor.PrimaryRunEnded(operation: second))
  let _fed = settle(subject)

  let assert [feed] = advisor_texts(rig.opened)
    as "the second run end must feed exactly once"
  assert string.contains(feed, "now add the index")
  assert !string.contains(feed, "write the migration")
  stop(rig)
}

// A review that ended with nothing owed reviews nothing, even though the
// primary's branch has moved.
//
// Without the debt the catch-up would send any delta past the cursor,
// and the primary appends assistant turns and tool results throughout
// its own run — so every advisor run end would find something, send it,
// and be asked again when that review ended. The loop would sustain
// itself for as long as the primary kept working, at one inference per
// iteration against a primary that has not decided anything yet.
pub fn an_idle_review_end_does_not_poll_the_primary_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"

  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  process.send(subject, advisor.AdvisorRunEnded(operation: an_op_id(4)))
  let _quiet = settle(subject)

  assert advisor_texts(rig.opened) == []
  assert cursor(rig.runtime) == None
  stop(rig)
}

// A primary that has appended nothing has nothing to review. No message
// is sent and no cursor is written, so the next run end starts from the
// root rather than from a position nothing was ever read at.
pub fn an_empty_primary_branch_sends_nothing_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  process.send(subject, advisor.PrimaryRunEnded(operation: an_op_id(2)))
  let _drained = settle(subject)

  assert advisor_texts(rig.opened) == []
  assert cursor(rig.runtime) == None
  stop(rig)
}

// The verdict is judged against the caller's durable strand name, which
// the driver sets from its own coordinates. A strand that is not the
// advisor is refused whatever it asks for.
pub fn only_the_advisor_may_advise_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let refused =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.primary,
        verdict: advise.Block(text: "stop what you are doing"),
        reply:,
      )
    })

  assert refused == Error("only the advisor strand may advise")
  stop(rig)
}

// The goal words answer goal feeds only (protocol 044 §2). No goal feed
// is open in this rig — the goal loop is a later change — so both words
// are refused with the error that says so, which the advisor reads and
// can correct within the same run. The refusal is in-band rather than a
// crash for the same reason the caller check is: a model that answers
// the wrong feed still gets an answer it can act on.
pub fn goal_words_without_a_goal_feed_are_refused_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let refused = fn(verdict) {
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(strand: advisor.strand, verdict:, reply:)
    })
  }

  assert refused(advise.Continue(text: "the race remains"))
    == Error(
      "no goal feed is open; continue and complete answer the "
      <> "session's goal feeds only",
    )
  assert refused(advise.Complete(text: "the race passes"))
    == Error(
      "no goal feed is open; continue and complete answer the "
      <> "session's goal feeds only",
    )
  stop(rig)
}

// A block from the advisor reaches the primary, and the nudge that
// follows it inside the cooldown window is downgraded rather than
// delivered — the guard's decision, taken on the actor's own state and
// visible to the model in the acknowledgement it gets back.
pub fn a_block_reaches_the_primary_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(advise.Delivered(..)) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Block(text: "the migration has no down step"),
        reply:,
      )
    })
    as "the first block must be delivered"

  let assert Ok(advise.Downgraded(..)) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Block(text: "and the gate was never run"),
        reply:,
      )
    })
    as "a second block inside the window must be downgraded"

  let drained = settle(subject)
  assert drained == ["and the gate was never run"]
  stop(rig)
}

// A queued nudge is folded into the primary's next run start, after
// whatever the inner layers injected, and into nobody else's. This is the
// drain the run-start slot exists for, over a live actor rather than over
// an absent one.
//
// The primary has to be working for the nudge to queue at all: a verdict
// judged against one that has stopped is delivered there and then, which
// is the door `an_idle_primary_is_woken_with_the_drained_queue_test`
// covers.
pub fn a_queued_nudge_reaches_the_primarys_next_run_start_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  a_working_primary(rig)
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let assert Ok(advise.Queued) =
    judge(subject, advise.Nudge(text: "the helper is still unclosed"))
    as "the nudge must be queued against a working primary"

  let hooked =
    advisor.hooks(
      hooks.build(hooks.new()),
      a_wiring_named(rig.opened, rig.name),
    )
  let foreign = an_operation(rig.opened, "sub:main/reviewer-1", 21)
  assert hooked.run_start(foreign) == []

  let mine = an_operation(rig.opened, advisor.primary, 23)
  let assert [folded] = hooked.run_start(mine)
    as "the primary must be handed its queued nudge"
  assert string.contains(text_of(folded), "the helper is still unclosed")

  // Draining is what the slot does: the same run start twice must not
  // fold the same nudge in twice.
  assert hooked.run_start(mine) == []
  stop(rig)
}

// --- the nudge channel's two unsolicited doors ------------------------------

// The run-end door. A nudge queued while the primary worked is handed
// back as the run's follow-up, so the primary reads it before it stops
// rather than after the operator next types — which, on a primary that
// stopped to ask a question, is not a moment that arrives on its own.
pub fn a_queued_nudge_is_handed_back_at_the_primarys_run_end_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  a_working_primary(rig)
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let assert Ok(advise.Queued) =
    judge(subject, advise.Nudge(text: "rebase before you push"))
    as "the nudge must queue against a working primary"

  let hooked =
    advisor.hooks(
      hooks.build(hooks.new()),
      a_wiring_named(rig.opened, rig.name),
    )
  let mine = an_operation(rig.opened, advisor.primary, 51)

  let assert Some(placed) = hooked.run_end(mine)
    as "the run end must place the queued nudge as its follow-up"
  assert string.contains(text_of(placed), "rebase before you push")

  // Drained, not copied: the follow-up carries the queue away with it.
  assert settle(subject) == []
  stop(rig)
}

// And not when an earlier layer has already placed one. The slot carries
// a single message, so the two cannot both ride it; the continuation ends
// in a run end of its own, which asks again with the queue still in it.
pub fn an_inner_follow_up_keeps_the_queue_waiting_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  a_working_primary(rig)
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let assert Ok(advise.Queued) =
    judge(subject, advise.Nudge(text: "rebase before you push"))
    as "the nudge must queue against a working primary"

  let hooked =
    advisor.hooks(
      hooks.new()
        |> hooks.with_run_end(fn(_operation) { Some(user("carry on")) })
        |> hooks.build,
      a_wiring_named(rig.opened, rig.name),
    )
  let mine = an_operation(rig.opened, advisor.primary, 53)

  let assert Some(placed) = hooked.run_end(mine)
    as "the inner follow-up must survive the drain"
  assert text_of(placed) == "carry on"
  assert settle(subject) == ["rebase before you push"]
  stop(rig)
}

// The run-end door spends the same turn as the idle door, and that is
// what cuts the ring: a follow-up ends in a run end of its own, which
// feeds the advisor, whose next nudge would place another follow-up for
// as long as it kept finding something to say.
pub fn a_second_run_end_in_one_turn_drains_nothing_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  a_working_primary(rig)
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let hooked =
    advisor.hooks(
      hooks.build(hooks.new()),
      a_wiring_named(rig.opened, rig.name),
    )
  let mine = an_operation(rig.opened, advisor.primary, 55)

  let assert Ok(advise.Queued) = judge(subject, advise.Nudge(text: "the first"))
    as "the first nudge must queue"
  let assert Some(_placed) = hooked.run_end(mine)
    as "the first run end must spend the turn"

  let assert Ok(advise.Queued) =
    judge(subject, advise.Nudge(text: "the second"))
    as "the second nudge must queue against the same working primary"
  assert hooked.run_end(mine) == None
    as "a second run end inside one turn must place nothing"

  // Held rather than lost: the operator's next run start drains it.
  assert settle(subject) == ["the second"]
  stop(rig)
}

// A run-end drain that reaches the actor after its hook has given up.
// The wait on the driver is bounded, and an actor busy scanning a branch
// can answer past it; serving that request would clear the queue and
// spend the turn into a driver that has already returned `None` and
// ended the run, leaving an idle primary with neither the nudges nor a
// wake left to carry them. The deadline is what tells the two apart.
pub fn a_run_end_drain_past_its_deadline_refuses_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  a_working_primary(rig)
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let assert Some(working) = strand_operation(rig.opened, advisor.primary)
    as "the fixture run must be open on the primary"

  let assert Ok(advise.Queued) =
    judge(subject, advise.Nudge(text: "rebase before you push"))
    as "the nudge must queue against a working primary"

  // Zero is before every stamp this rig's fixed clock reads, so this is
  // a request whose asker stopped listening long ago.
  assert take_at_run_end(subject, 0) == []
    as "a drain served past its deadline must answer with nothing"

  // Neither the queue nor the turn moved. The idle door delivers what
  // the expired drain declined to take, and carries both nudges in the
  // one frame that proves the first was still pending.
  idle_again(rig, working)
  let assert Ok(advise.Woke(..)) =
    judge(subject, advise.Nudge(text: "and squash the fixups"))
    as "the unspent turn must still wake the idle primary"

  let assert [woken] =
    primary_texts(rig.opened)
    |> list.filter(string.contains(_, "and squash the fixups"))
    as "the wake must have reached the primary's branch as one frame"
  assert string.contains(woken, "rebase before you push")
    as "the refused drain must have left the first nudge queued"
  stop(rig)
}

// The idle door. A primary that has stopped is not left holding advice
// until somebody types: the whole queue is drained and delivered as a run
// of its own.
pub fn an_idle_primary_is_woken_with_the_drained_queue_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(advise.Woke(how:)) =
    judge(subject, advise.Nudge(text: "rebase before you push"))
    as "an idle primary must be woken rather than left the queue"
  assert string.contains(how, "idle primary")
  assert string.contains(how, "1 nudge")

  let assert [woken] = primary_texts(rig.opened)
    as "the nudges must have reached the primary's own branch"
  assert string.contains(woken, "rebase before you push")

  // The queue went with it, so the next run start folds in nothing.
  assert settle(subject) == []
  stop(rig)
}

// One wake per operator turn. The second nudge is judged against a
// primary that is idle again, so what holds it back is the spent turn and
// nothing else.
pub fn a_second_nudge_in_one_turn_is_held_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let assert Ok(advise.Woke(..)) =
    judge(subject, advise.Nudge(text: "rebase before you push"))
    as "the first nudge must wake the idle primary"

  let assert Some(woken) = strand_operation(rig.opened, advisor.primary)
    as "the wake must have opened a run on the primary"
  idle_again(rig, woken)

  // A working primary would queue the second nudge too, so the test
  // would pass for the wrong reason without this: the primary really is
  // idle, and the spent turn is the only thing holding the nudge back.
  assert strand_operation(rig.opened, advisor.primary) == None
    as "the primary must have no open operation when the second is judged"

  let assert Ok(advise.Queued) =
    judge(subject, advise.Nudge(text: "and squash the fixups"))
    as "the second nudge of one turn must be held"
  assert list.length(primary_texts(rig.opened)) == 1
    as "the held nudge must not have reached the primary"
  stop(rig)
}

// The turn comes back at a run start this actor did not open, and not at
// one it did. Without that distinction the woken run's own start would
// pay for the next wake, and the loop would sustain itself.
pub fn the_turn_renews_only_on_a_run_the_advisor_did_not_open_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let assert Ok(advise.Woke(..)) =
    judge(subject, advise.Nudge(text: "rebase before you push"))
    as "the first nudge must wake the idle primary"

  let assert Some(woken) = strand_operation(rig.opened, advisor.primary)
    as "the wake must have opened a run on the primary"
  idle_again(rig, woken)

  // The woken run's own start. It is this actor's wake coming back
  // around, not somebody asking the primary for something.
  assert take_pending(subject, woken) == []
  let assert Ok(advise.Queued) =
    judge(subject, advise.Nudge(text: "and squash the fixups"))
    as "the advisor's own run start must not renew the turn"

  // A run start the actor did not open is the operator arriving, and it
  // drains what was waiting on the way in.
  assert take_pending(subject, an_op_id(61)) == ["and squash the fixups"]
  let assert Ok(advise.Woke(..)) =
    judge(subject, advise.Nudge(text: "and rerun the gate"))
    as "a renewed turn must wake the idle primary again"
  stop(rig)
}

// The turn's delivery and the block cooldown are separate counters. A
// nudge that woke the primary spends the turn and nothing else, so the
// block that follows it is judged against the cooldown alone.
pub fn a_block_after_a_wake_is_governed_by_the_cooldown_alone_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let assert Ok(advise.Woke(..)) =
    judge(subject, advise.Nudge(text: "rebase before you push"))
    as "the first nudge must wake the idle primary"

  let assert Ok(advise.Delivered(..)) =
    judge(subject, advise.Block(text: "the migration has no down step"))
    as "a spent turn must not silence the block channel"

  // And the cooldown still rations the next one, which is the counter
  // that was supposed to be doing this all along.
  let assert Ok(advise.Downgraded(..)) =
    judge(subject, advise.Block(text: "and the gate was never run"))
    as "the second block inside the window must still be downgraded"
  stop(rig)
}

// The hook and the actor, joined: the primary's run end is what drives
// the whole loop in production, and nothing else casts that message. A
// run end on another strand drives nothing at all.
pub fn the_primarys_run_end_drives_the_feed_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"
  let hooked =
    advisor.hooks(
      hooks.build(hooks.new()),
      a_wiring_named(rig.opened, rig.name),
    )

  let foreign = an_operation(rig.opened, "sub:main/reviewer-1", 31)
  assert hooked.run_end(foreign) == None
  let _quiet = settle(subject)
  assert advisor_texts(rig.opened) == []

  let mine = an_operation(rig.opened, advisor.primary, 33)
  assert hooked.run_end(mine) == None
  let _drained = settle(subject)

  let assert [fed] = advisor_texts(rig.opened)
    as "the primary's run end must have fed the advisor"
  assert string.contains(fed, "write the migration")
  stop(rig)
}

// --- the isolation the design rests on -------------------------------------

// The advisor is made with `create_idle_strand` and never through the
// Agency, so it has no lineage cell. That absence is what the whole
// design rests on: the ledger is the only thing `agent_send` consults
// before one strand may address another, and it is what `strand.roster`
// lists, so a primary cannot argue its reviewer out of a verdict and is
// never prompted to reason about a strand it has no business managing.
pub fn the_advisor_is_outside_the_lineage_ledger_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"

  let assert Ok(cells) =
    api.reserved_facts(rig.runtime, prefix: lineage.key_prefix)
    as "the lineage ledger must be readable"
  assert !list.any(cells, fn(cell) {
    cell.0 == lineage.register_key(advisor.strand)
  })

  // And the seam that reads that ledger refuses the name, which is the
  // property the absent cell is there to produce.
  let name = addresses.new()
  let config = agency.default_config(name, clock.fixed(at: 1000))
  let assert Ok(_holder) = agency.start(config, rig.runtime)
    as "the agency holder must start"
  let seam = agency.seam(config)

  assert seam.send(
      a_caller(advisor.primary),
      advisor.strand,
      "reconsider",
      None,
    )
    == Error(agent.NotAddressable(strand: advisor.strand))
  stop(rig)
}

fn a_caller(strand: String) -> agent.Caller {
  agent.Caller(
    strand:,
    operation: an_op_id(41),
    step_id: "turn-1:tools",
    source_index: 0,
    minter: agent.ToolCall,
  )
}

// --- the rig ---------------------------------------------------------------

type Rig {
  Rig(
    opened: Session,
    runtime: api.Runtime,
    name: address.Address(advisor.Message),
  )
}

fn a_rig() -> Result(Rig, String) {
  a_rig_with(some_settings([]))
}

// The rig with the advisor's settings chosen by the caller, which is how
// the step-trigger tests vary `feed_every_steps` without every other test
// having to name it.
fn a_rig_with(settings: advisor.Settings) -> Result(Rig, String) {
  use opened <- result.try(
    session.open_memory(clock.fixed(at: 1_756_000_000_000))
    |> result.replace_error("the memory session did not open"),
  )
  use entropy <- result.try(start_entropy())
  use runtime <- result.try(
    api.open(
      opened,
      effects.Effects(
        clock: clock.fixed(at: 1_756_000_000_000),
        entropy:,
        timers: effects.real_timers(),
        provider: hanging_provider(),
        tools: refusing_tools(),
        hooks: effects.default_hooks(),
      ),
      api.default_options(a_configuration()),
    )
    |> result.map_error(string.inspect),
  )
  use Nil <- result.try(advisor.ensure_strand(runtime, settings, [advise.name]))

  let name = addresses.new()
  let wiring =
    advisor.Wiring(
      session: opened,
      runtime: fn() { Ok(runtime) },
      settings:,
      clock: clock.fixed(at: 1_756_000_000_000),
      logger: log.discard(),
      name:,
    )
  use _started <- result.try(
    advisor.start(wiring)
    |> result.replace_error("the advisor actor did not start"),
  )
  Ok(Rig(opened:, runtime:, name:))
}

// A strand's open operation as the store shows it, which is what
// `reviewing` reads of the advisor and what the nudge door reads of the
// primary.
fn strand_operation(opened: Session, name: String) -> Option(OpId) {
  case session.strand_state(opened, name) {
    Ok(Some(session.Cell(value: current, ..))) -> current.current_operation
    Ok(None) | Error(_) -> None
  }
}

// `a_rig`, with one primary run already on the branch before the advisor
// strand and actor exist: the enable-on-a-live-session shape.
fn a_rig_over_history() -> Result(#(Rig, OpId), String) {
  use opened <- result.try(
    session.open_memory(clock.fixed(at: 1_756_000_000_000))
    |> result.replace_error("the memory session did not open"),
  )
  use entropy <- result.try(start_entropy())
  use runtime <- result.try(
    api.open(
      opened,
      effects.Effects(
        clock: clock.fixed(at: 1_756_000_000_000),
        entropy:,
        timers: effects.real_timers(),
        provider: hanging_provider(),
        tools: refusing_tools(),
        hooks: effects.default_hooks(),
      ),
      api.default_options(a_configuration()),
    )
    |> result.map_error(string.inspect),
  )
  use history <- result.try(
    api.accept_quietly(runtime, [user("write the migration")])
    |> result.replace_error("the primary did not accept its history"),
  )
  let settings = some_settings([])
  use Nil <- result.try(advisor.ensure_strand(runtime, settings, [advise.name]))

  let name = addresses.new()
  let wiring =
    advisor.Wiring(
      session: opened,
      runtime: fn() { Ok(runtime) },
      settings:,
      clock: clock.fixed(at: 1_756_000_000_000),
      logger: log.discard(),
      name:,
    )
  use _started <- result.try(
    advisor.start(wiring)
    |> result.replace_error("the advisor actor did not start"),
  )
  Ok(#(Rig(opened:, runtime:, name:), history))
}

// The actor first, then the tree it reads through.
//
// The actor is not part of the session tree — it is linked to the test
// process — so killing the tree alone left it alive with a dead writer
// behind it, and any message still in flight (the tail of an abort drain,
// say) then crashed it inside `write_cell`. Because it is linked to the
// eunit process, that crash cancelled the rest of the module: a flake that
// reported as "one or more tests were cancelled" several tests later.
fn stop(rig: Rig) -> Nil {
  case address.lookup(rig.name) {
    Ok(subject) ->
      case process.subject_owner(subject) {
        // Unlinked first: the actor is linked to this process, so killing
        // it while linked would take the test down with it.
        Ok(pid) -> {
          process.unlink(pid)
          process.kill(pid)
        }
        Error(Nil) -> Nil
      }
    Error(Nil) -> Nil
  }
  process.kill(rig.runtime.tree.supervisor)
}

// A call after a cast, to the same actor and from the same process, is
// answered only once the cast has been handled: the mailbox is FIFO per
// sender. That is what makes this a barrier rather than a sleep.
//
// It is a run-start drain, so it renews the operator turn as well as
// draining. Every test that cares about the turn's one unsolicited
// delivery uses `take_pending` with an operation it chose instead, and
// every test that cares about the *goal's* counters uses `barrier`, which
// touches nothing.
fn settle(subject: process.Subject(advisor.Message)) -> List(String) {
  take_pending(subject, an_op_id(97))
}

// A barrier that changes nothing.
//
// `settle` is a run-start drain, and a run-start drain is not inert: it
// renews the operator turn, and the operation it names is one the actor
// never opened, so the goal evaluation it triggers is a *foreign*
// `PrimaryStarted` that clears the continuation and zero-progress counts. A
// goal test that used it could pass on its own barrier. This is the run-end
// drain served past its deadline, which is the one call this actor answers
// by touching neither queue, turn nor goal.
fn barrier(subject: process.Subject(advisor.Message)) -> Nil {
  let _nothing = take_at_run_end(subject, 0)
  Nil
}

// The primary's run-start drain, with the operation the run is opening.
// That operation is what decides whether the turn's unsolicited delivery
// comes back, so a test that means to renew names a run the advisor
// cannot have opened.
fn take_pending(
  subject: process.Subject(advisor.Message),
  operation: OpId,
) -> List(String) {
  process.call(subject, waiting: 5000, sending: fn(reply) {
    advisor.TakePending(operation:, reply:)
  })
}

// The primary's run-end drain, with the deadline the asking hook would
// have computed from its own timeout. A test that means to arrive late
// passes an instant this rig's fixed clock has already gone past.
fn take_at_run_end(
  subject: process.Subject(advisor.Message),
  deadline: Int,
) -> List(String) {
  process.call(subject, waiting: 5000, sending: fn(reply) {
    advisor.TakeAtRunEnd(deadline:, reply:)
  })
}

// One verdict from the advisor strand, judged the way the seam judges
// one.
fn judge(
  subject: process.Subject(advisor.Message),
  verdict: advise.Verdict,
) -> Result(advise.Ack, String) {
  process.call(subject, waiting: 5000, sending: fn(reply) {
    advisor.Judge(strand: advisor.strand, verdict:, reply:)
  })
}

// A primary with a run open, which is the state every test needs before
// it can queue a nudge rather than have one delivered: the fixture
// provider never answers, so the run stays open for the rest of the
// test.
fn a_working_primary(rig: Rig) -> Nil {
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"
  Nil
}

// Ends whatever run the primary has open, so the next verdict is judged
// against an idle one. The fixture provider hangs, so a run is only
// finishable by abort.
fn idle_again(rig: Rig, operation: OpId) -> Nil {
  api.abort(rig.runtime)
  let assert Ok(_aborted) =
    api.await_result(rig.runtime, operation, within_ms: 5000)
    as "the aborted run must settle"
  Nil
}

fn cursor(runtime: api.Runtime) -> Option(json.JsonValue) {
  api.fact(runtime, advisor.cursor_key) |> result.unwrap(None)
}

// The shipped settings with the step threshold moved, so a test reaches
// it in three casts rather than in twenty.
fn stepping(every: Int) -> advisor.Settings {
  advisor.Settings(..some_settings([]), feed_every_steps: every)
}

// `count` steps on the primary, cast the way the `usage` slot casts them.
// A call after the last one is the barrier: the mailbox is FIFO per
// sender, so an answer to it means every cast before it was handled.
fn step(subject: process.Subject(advisor.Message), count: Int) -> Nil {
  list.each(list.repeat(Nil, count), fn(_each) {
    process.send(subject, advisor.PrimaryStepped(operation: an_op_id(9)))
  })
  let _drained = settle(subject)
  Nil
}

fn usage_row() -> entry.UsageRow {
  let generator = ids.generator(clock.fixed(at: 0), seed: 11)
  let #(id, _generator) = ids.mint_usage(generator)
  entry.UsageRow(
    id:,
    seq: 77,
    entry_id: None,
    adjustment: False,
    usage: message.Usage(
      input: 11,
      output: 22,
      cache_read: 3,
      cache_write: 4,
      cache_write_1h: None,
      reasoning: Some(5),
      total_tokens: 40,
      cost: message.UsageCost(
        input: 0.1,
        output: 0.2,
        cache_read: 0.0,
        cache_write: 0.0,
        total: 0.3,
      ),
    ),
    details: None,
  )
}

fn some_settings(tools: List(String)) -> advisor.Settings {
  advisor.Settings(
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking: machine_strand.ThinkingOff,
    tools:,
    feed_every_steps: 20,
    block_cooldown_reviews: 2,
  )
}

fn a_configuration() -> machine_strand.StrandConfiguration {
  machine_strand.StrandConfiguration(
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: machine_strand.ThinkingOff,
    active_tool_names: [],
  )
}

// --- reading the advisor's branch ------------------------------------------

// The text of every user message on the advisor's branch, oldest first:
// what the advisor was actually handed, read back out of the store rather
// than out of anything this test built.
fn advisor_texts(opened: Session) -> List(String) {
  strand_texts(opened, advisor.strand)
}

// The same read against the primary, which is where a delivered block
// and a woken nudge queue land.
fn primary_texts(opened: Session) -> List(String) {
  strand_texts(opened, advisor.primary)
}

fn strand_texts(opened: Session, name: String) -> List(String) {
  case strand_leaf(opened, name) {
    None -> []

    Some(leaf) ->
      storage.branch_scan(from: leaf)
      |> storage.branch_order(storage.OldestFirst)
      |> storage.scan_branch(opened.store, _)
      |> result.unwrap([])
      |> list.filter_map(entry_text)
  }
}

fn strand_leaf(opened: Session, name: String) -> Option(EntryId) {
  let assert Ok(Some(session.Cell(value: leaf, ..))) =
    session.strand_leaf(opened, name)
    as "the strand must be seeded"
  leaf
}

fn entry_text(each: Entry) -> Result(String, Nil) {
  case each {
    entry.MessageEntry(message: message.UserMessage(content:, ..), ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.UserText(text:, ..) -> Ok(text)
          message.UserImage(..) -> Error(Nil)
        }
      })
      |> string.join("\n")
      |> Ok

    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> Error(Nil)
  }
}

// --- fixtures --------------------------------------------------------------

fn a_session() -> Session {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 1000))
    as "the memory session must open"
  opened
}

// A wiring whose runtime never answers and whose actor is not registered:
// the state every hook slot has to tolerate, since the slots run on the
// strand driver and a run is never held up for a review.
//
// Its clock reads the same instant `a_rig` gives the actor, because in a
// running session the hook slots and the actor share one `Wiring`. The
// run-end drain compares a deadline the hook computed against the
// actor's own reading, so two fixtures on different stamps would make
// every drain look arbitrarily late.
fn a_wiring(opened: Session) -> advisor.Wiring {
  advisor.Wiring(
    session: opened,
    runtime: fn() { Error(Nil) },
    settings: some_settings([]),
    clock: clock.fixed(at: 1_756_000_000_000),
    logger: log.discard(),
    name: addresses.new(),
  )
}

// The same wiring the hook tests use, pointed at a running actor.
fn a_wiring_named(
  opened: Session,
  name: address.Address(advisor.Message),
) -> advisor.Wiring {
  advisor.Wiring(..a_wiring(opened), name:)
}

// Writes an `op.meta` cell, which is where every hook slot learns whose
// run this is.
fn an_operation(opened: Session, strand: String, seed: Int) -> OpId {
  let id = an_op_id(seed)
  let assert Ok(_committed) =
    storage.commit(
      opened.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.OpMeta,
            key: ids.op_id_to_string(id),
            value: register.RegisterValue(
              payload: codec.encode_operation(operation.Operation(
                id:,
                strand:,
                source_leaf: None,
                started_at: 0,
                intent: operation.RunIntent(prompt_entries: []),
              )),
            ),
          ),
        ],
        expected: [],
      ),
    )
    as "the fixture operation must commit"
  id
}

fn an_op_id(seed: Int) -> OpId {
  let #(id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1000), seed:))
  id
}

fn an_entry_id() -> EntryId {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 1000), seed: 13))
  id
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

fn text_of(injected: message.AgentMessage) -> String {
  case injected {
    message.UserMessage(content: [message.UserText(text:, ..)], ..) -> text
    _other -> ""
  }
}

fn hanging_provider() -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 30_000, request: fn(_spec) {
    stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
  })
}

fn refusing_tools() -> effects.ToolSurface {
  effects.ToolSurface(
    clear: fn(_query) {
      effects.ClearanceRefused(reason: "no tools in this harness")
    },
    run: fn(_run) { effects.ToolFailed(reason: "no tools in this harness") },
    replay_still_safe: fn(_name) { False },
    execution_mode: fn(_name) { effects.ExclusiveExecution },
  )
}

fn start_entropy() -> Result(fn() -> Int, String) {
  otp_actor.new(1)
  |> otp_actor.on_message(fn(next, reply) {
    process.send(reply, next)
    otp_actor.continue(next + 1)
  })
  |> otp_actor.start
  |> result.map(fn(counter) {
    fn() { process.call(counter.data, waiting: 1000, sending: fn(r) { r }) }
  })
  |> result.replace_error("the entropy counter did not start")
}

// --- the goal loop ---------------------------------------------------------

// A goal is pinned through the same call the operator's gateway command
// will ride: the actor is the cell's only writer, and the call's `Ok` is
// what a `goal_set` replies on.
pub fn a_goal_can_be_pinned_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let pinned =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.SetGoal(
        objective: "make the failing storage race test pass",
        token_budget: 400_000,
        reply:,
      )
    })
  assert pinned == Ok(Nil)

  let assert Ok(Some(cell)) = api.fact(rig.runtime, advisor.goal_key)
  let assert Ok(goal) = goalstate.decode(cell)
  assert goalstate.status_of(goal) == goalstate.Active
  assert goal.tokens_used == 0
  stop(rig)
}

// A non-positive budget is refused worded, because v1 has no unbounded
// goals and a zero budget is a typo rather than a wish.
pub fn a_non_positive_budget_is_refused_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let refused =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.SetGoal(objective: "x", token_budget: 0, reply:)
    })
  assert refused == Error("token_budget must be a positive number of tokens")
  assert api.fact(rig.runtime, advisor.goal_key) == Ok(None)
  stop(rig)
}

// A primary run end with an active goal and an idle primary sends the
// advisor a goal feed, not an ordinary one: the frame names the
// objective and the budget, and the footer asks for the goal words.
pub fn a_primary_run_end_with_a_goal_feeds_the_goal_question_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(_pinned) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.SetGoal(
        objective: "land the migration",
        token_budget: 400_000,
        reply:,
      )
    })

  let assert Ok(run) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
  process.send(subject, advisor.PrimaryRunEnded(operation: run))
  let _drained = settle(subject)
  idle_again(rig, run)

  assert list.any(advisor_texts(rig.opened), fn(text) {
    string.contains(
      text,
      "[advisor goal feed: the primary stopped with the session's goal still open]",
    )
    && string.contains(
      text,
      "<untrusted_objective>\nland the migration\n</untrusted_objective>",
    )
  })
  stop(rig)
}

// A continue wakes the idle primary with the continuation frame, spends
// no operator-turn budget, and counts the continuation in the cell.
pub fn a_continue_wakes_the_idle_primary_with_a_continuation_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(_pinned) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.SetGoal(
        objective: "land the migration",
        token_budget: 400_000,
        reply:,
      )
    })

  let assert Ok(run) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
  process.send(subject, advisor.PrimaryRunEnded(operation: run))
  let _drained = settle(subject)
  idle_again(rig, run)

  let assert Ok(advise.Delivered(_how)) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Continue(text: "the tests still fail"),
        reply:,
      )
    })
    as "the continuation must be delivered"

  assert list.any(primary_texts(rig.opened), fn(text) {
    string.contains(text, "[goal continuation]")
    && string.contains(
      text,
      "The reviewer's note on what remains:\nthe tests still fail",
    )
  })

  // The continuation was counted: the cell's continuations moved.
  let assert Ok(Some(cell)) = api.fact(rig.runtime, advisor.goal_key)
  let assert Ok(goal) = goalstate.decode(cell)
  assert goal.continuations == 1
  stop(rig)
}

// A complete flips the status, records the reviewer's note, and stops the
// loop: no continuation lands on the primary.
pub fn a_complete_flips_the_status_and_stops_the_loop_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(_pinned) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.SetGoal(
        objective: "land the migration",
        token_budget: 400_000,
        reply:,
      )
    })

  let assert Ok(run) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
  process.send(subject, advisor.PrimaryRunEnded(operation: run))
  let _drained = settle(subject)
  idle_again(rig, run)

  let assert Ok(advise.Acknowledged) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Complete(text: "the migration is merged"),
        reply:,
      )
    })

  let assert Ok(Some(cell)) = api.fact(rig.runtime, advisor.goal_key)
  let assert Ok(goal) = goalstate.decode(cell)
  assert goalstate.status_of(goal) == goalstate.Complete
  assert goalstate.reviewer_note_of(goal) == Some("the migration is merged")

  // No continuation reached the primary: completion is the loop's end,
  // not a message the worker reads. The fixture's own prompt is the only
  // thing on the primary's branch.
  assert !list.any(primary_texts(rig.opened), fn(text) {
    string.contains(text, "[goal continuation]")
  })
  stop(rig)
}

// The ordinary words cannot answer a goal feed: the in-band error names
// the two goal words, because an idle primary has no next occasion and
// a misread answer would stall the loop silently.
pub fn ordinary_words_cannot_answer_a_goal_feed_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(_pinned) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.SetGoal(
        objective: "land the migration",
        token_budget: 400_000,
        reply:,
      )
    })

  let assert Ok(run) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
  process.send(subject, advisor.PrimaryRunEnded(operation: run))
  let _drained = settle(subject)
  idle_again(rig, run)

  let refused =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(strand: advisor.strand, verdict: advise.Quiet, reply:)
    })
  assert refused
    == Error(
      "this feed asks for continue or complete; quiet, nudge and block answer an ordinary feed",
    )
  stop(rig)
}

// The goal verdicts answered with no goal feed open are refused with the
// error that says so — the same arm the pre-loop actor had, now the
// refusal a stale or stray goal word meets.
pub fn goal_words_with_no_open_goal_feed_are_refused_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let refused =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Continue(text: "the race remains"),
        reply:,
      )
    })
  assert refused
    == Error(
      "no goal feed is open; continue and complete answer the session's goal feeds only",
    )
  stop(rig)
}

// A reviewer run that ends without a verdict does not strand the goal.
// That is the failure the level-triggered rework exists to remove: the
// earlier draft closed the feed on the run end and then waited for an
// occasion that could not occur — an idle primary has no next one. Now
// the abandoned feed is counted and offered again, and the count is what
// bounds the retry so a provider that never answers pauses the goal
// rather than being paid to refuse it forever.
pub fn an_unanswered_review_is_counted_and_offered_again_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  pin_goal(subject, 400_000)

  let assert Ok(run) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
  process.send(subject, advisor.PrimaryRunEnded(operation: run))
  let _drained = settle(subject)
  idle_again(rig, run)

  // The run that actually owed the verdict is the one the feed opened,
  // read from the store rather than invented: an end on any other
  // advisor run is somebody else's review and leaves the feed open.
  let assert Some(feed) = strand_operation(rig.opened, advisor.strand)
    as "the goal feed must have opened a run on the advisor"

  // The advisor's own run ends without a verdict — the provider's
  // failure shape.
  process.send(subject, advisor.AdvisorRunEnded(operation: feed))
  let _drained = settle(subject)

  let goal = goal_cell(rig)
  assert goal.unanswered_feeds == 1
  assert goalstate.status_of(goal) == goalstate.Active

  // Offered again rather than abandoned, and the phase is the durable
  // evidence: the level read found the idle phase, sent a feed, and
  // recorded a verdict owed again. The second frame is not a second
  // committed entry here because this rig's advisor never settles — the
  // store still shows its run open, so the send steers that run rather
  // than starting one, and a steered message sits on the run's queue. The
  // earlier draft left this state with no verdict owed and nothing
  // scheduled, which is exactly what this assertion refutes.
  assert goal.phase == goalstate.AwaitingVerdict(feed:)
  stop(rig)
}

// A run end on the advisor that is not the run owing the verdict is
// somebody else's review ending, and leaves the open feed alone: the
// phase names the run, which is what makes the difference readable
// rather than guessed.
pub fn a_foreign_advisor_run_end_leaves_the_feed_open_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  pin_goal(subject, 400_000)

  let assert Ok(run) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
  process.send(subject, advisor.PrimaryRunEnded(operation: run))
  let _drained = settle(subject)
  idle_again(rig, run)

  process.send(subject, advisor.AdvisorRunEnded(operation: an_op_id(4)))
  let _drained = settle(subject)

  let goal = goal_cell(rig)
  assert goal.unanswered_feeds == 0
  assert goal_feeds_on(rig.opened) == 1

  // The feed is still open, so the verdict it was waiting for lands.
  let assert Ok(advise.Delivered(_how)) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Continue(text: "the race remains"),
        reply:,
      )
    })
    as "the verdict the open feed asked for must be accepted"
  stop(rig)
}

// How many goal feeds are on the advisor's branch, counted off the
// durable tree: a feed that was never committed cannot be counted here,
// which is why this rather than a log line is the evidence.
fn goal_feeds_on(opened: Session) -> Int {
  advisor_texts(opened)
  |> list.filter(fn(text) {
    string.contains(
      text,
      "[advisor goal feed: the primary stopped with the session's goal still open]",
    )
  })
  |> list.length
}

// --- accounting -------------------------------------------------------------
//
// The four fixtures below share one shape, and the shape is the point of
// the rework. `PrimarySpent` carries nothing: it is a trigger, and the
// total is computed by scanning the session's own usage ledger past the
// goal's cursor and counting the rows whose entry is on the primary's
// branch. So every fixture commits real rows into the real ledger — a
// synthetic row cast at the actor would now account nothing, which is
// exactly the property that makes the ledger the single adder.

// Accounting: one committed primary row adds its non-cached input and
// output to the goal's spend, and the cursor advances past it.
pub fn a_primary_row_accounts_against_the_goal_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  pin_goal(subject, 400_000)

  let worked = a_primary_entry(rig)
  let spent = commit_usage(rig, worked, 101)

  process.send(subject, advisor.PrimarySpent)
  let _drained = settle(subject)

  let goal = goal_cell(rig)
  // Non-cached input 11 - 3 - 4 = 4, plus output 22: 26. Reasoning is
  // inside output and not added again.
  assert goal.tokens_used == 26
  assert goal.accounted_through_seq == spent
  stop(rig)
}

// The row no trigger ever announced is still counted. Two rows are
// committed and exactly one trigger fires afterwards, so the older row is
// the cast that was lost. The accounting this replaced moved the cursor
// to the announcing row's own seq, which skipped the older row forever —
// the permanent undercount the design says cannot happen.
pub fn a_lost_row_is_recovered_by_the_next_scan_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  pin_goal(subject, 400_000)

  let worked = a_primary_entry(rig)
  let older = commit_usage(rig, worked, 101)
  let newer = commit_usage(rig, worked, 105)
  assert older < newer as "the ledger stamps the second row above the first"

  // One trigger for two rows: the cast that would have announced the
  // older row is the one this fixture never sends.
  process.send(subject, advisor.PrimarySpent)
  let _drained = settle(subject)

  let goal = goal_cell(rig)
  assert goal.tokens_used == 52
  assert goal.accounted_through_seq == newer
  stop(rig)
}

// The accounting counts only the primary's spend, read from the ledger
// side. The reviewer's rows land before and after the primary's on every
// cycle, so a foreign row is committed in both positions, and neither
// adds: the filter is `set.contains` against the primary's own branch,
// not a size check that answers yes to everything.
pub fn the_accounting_counts_only_the_primary_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  pin_goal(subject, 400_000)

  // The run end sends the goal feed, which commits a real entry on the
  // advisor's branch: the foreign entry these rows name is the reviewer's
  // own turn, not an id invented by the fixture.
  let assert Ok(run) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
  process.send(subject, advisor.PrimaryRunEnded(operation: run))
  let _drained = settle(subject)
  idle_again(rig, run)

  let assert Some(reviewed) = strand_leaf(rig.opened, advisor.strand)
    as "the goal feed must leave a leaf on the advisor's branch"
  let assert Some(worked) = strand_leaf(rig.opened, advisor.primary)
    as "the operator's turn must leave a leaf on the primary's branch"

  let _before = commit_usage(rig, reviewed, 201)
  let _own = commit_usage(rig, worked, 202)
  let trailing = commit_usage(rig, reviewed, 203)

  process.send(subject, advisor.PrimarySpent)
  let _drained = settle(subject)

  let goal = goal_cell(rig)
  // One row of the three counted, and the cursor past all three: a row
  // the sum refuses is a row it must never re-examine.
  assert goal.tokens_used == 26
  assert goal.accounted_through_seq == trailing
  stop(rig)
}

// A counted row does not count twice: the seq cursor is the guard, so a
// second trigger over the same ledger is inert.
pub fn a_replayed_row_does_not_count_twice_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  pin_goal(subject, 400_000)

  let worked = a_primary_entry(rig)
  let _spent = commit_usage(rig, worked, 101)

  process.send(subject, advisor.PrimarySpent)
  process.send(subject, advisor.PrimarySpent)
  let _drained = settle(subject)

  let goal = goal_cell(rig)
  assert goal.tokens_used == 26
  stop(rig)
}

// The accounting that crosses the budget is the one that trips the bound:
// the status flips to the token-budget limit, told apart from the
// continuation cap by its cause.
pub fn an_exhausted_budget_trips_the_bound_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  pin_goal(subject, 10)

  let worked = a_primary_entry(rig)
  let _spent = commit_usage(rig, worked, 101)

  process.send(subject, advisor.PrimarySpent)
  let _drained = settle(subject)

  let goal = goal_cell(rig)
  assert goalstate.status_of(goal)
    == goalstate.Limited(by: goalstate.ByTokenBudget)
  stop(rig)
}

// Nothing in the ledger is nothing accounted. The trigger carries no
// payload, so a trigger with no row behind it must leave the goal exactly
// where it was — which is also what a cast for a row another strand wrote
// now costs.
pub fn a_trigger_with_an_empty_ledger_accounts_nothing_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  pin_goal(subject, 400_000)

  process.send(subject, advisor.PrimarySpent)
  let _drained = settle(subject)

  let goal = goal_cell(rig)
  assert goal.tokens_used == 0
  assert goal.accounted_through_seq == 0
  stop(rig)
}

// --- the accounting fixtures' own rig ---------------------------------------

// Pins the goal through the operator's own call, which every accounting
// fixture starts with.
fn pin_goal(
  subject: process.Subject(advisor.Message),
  token_budget: Int,
) -> Nil {
  let assert Ok(_pinned) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.SetGoal(objective: "land the migration", token_budget:, reply:)
    })
    as "the goal must pin through the actor's own call"
  Nil
}

// One real entry on the primary's branch, which is what a usage row has
// to name to be the primary's spend. Accepted through the runtime's own
// writer, because branch membership is tested against the chain the store
// actually holds.
fn a_primary_entry(rig: Rig) -> EntryId {
  let assert Ok(_accepted) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture turn"
  let assert Some(leaf) = strand_leaf(rig.opened, advisor.primary)
    as "the accepted turn must leave a leaf on the primary's branch"
  leaf
}

// Commits one usage row against a named entry and answers the seq the
// ledger stamped it with. The store assigns the seq from the session's
// own counter, so a fixture never claims a number: it claims which rows
// exist, which entry each names, and the order they were written in.
fn commit_usage(rig: Rig, entry_id: EntryId, seed: Int) -> Int {
  let row =
    entry.UsageRow(
      ..usage_row(),
      id: a_usage_id(seed),
      entry_id: Some(entry_id),
    )
  let assert Ok(committed) =
    storage.commit(
      rig.opened.store,
      Tx(writes: [InsertUsage(row:)], expected: []),
    )
    as "the fixture usage row must commit"
  committed.first_seq
}

// A fresh usage id per row: the store refuses a row whose id it has
// already seen, so the seed is what tells two otherwise identical rows
// apart.
fn a_usage_id(seed: Int) -> UsageId {
  let #(id, _generator) =
    ids.mint_usage(ids.generator(clock.fixed(at: 0), seed:))
  id
}

fn goal_cell(rig: Rig) -> goalstate.Goal {
  let assert Ok(Some(cell)) = api.fact(rig.runtime, advisor.goal_key)
    as "the goal cell must be readable"
  let assert Ok(goal) = goalstate.decode(cell) as "the goal cell must decode"
  goal
}

// An operator abort of a goal-woken run pauses the goal; an abort of a
// run the actor did not wake leaves it alone. The `woke` gate is what
// makes "a goal-woken run" precise.
pub fn an_abort_of_a_goal_woken_run_pauses_the_goal_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(_pinned) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.SetGoal(
        objective: "land the migration",
        token_budget: 400_000,
        reply:,
      )
    })

  let assert Ok(run) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
  process.send(subject, advisor.PrimaryRunEnded(operation: run))
  let _drained = settle(subject)
  idle_again(rig, run)

  // The continuation opens a run on the primary, which the actor records
  // in `woke`.
  let assert Ok(advise.Delivered(_how)) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Continue(text: "the tests still fail"),
        reply:,
      )
    })

  // The abort of the woken run pauses the goal. The operation is the
  // one the continuation opened — read from the store, the same place
  // the gateway's abort handler reads it from.
  let assert Some(woken) = strand_operation(rig.opened, advisor.primary)
    as "the continuation must have opened a run on the primary"
  process.send(subject, advisor.PrimaryAborted(operation: woken))
  let _drained = settle(subject)

  let assert Ok(Some(cell)) = api.fact(rig.runtime, advisor.goal_key)
  let assert Ok(goal) = goalstate.decode(cell)
  // The cause is the abort's own, not the operator's pause command: a
  // Ctrl-C on the loop's run is "not now", and the panel says which.
  assert goalstate.status_of(goal) == goalstate.Paused(by: goalstate.ByAbort)
  stop(rig)
}

// A resume offers the goal feed where it stands, rather than waiting for
// an occasion the session will not produce.
//
// This is the operator's own door onto the stall the rework exists to
// remove. A resume writes `Active` into the cell, and an idle primary has
// no next run end, so a resume that only wrote the cell left the goal
// active with nothing running and nothing scheduled until the repair tick
// — two minutes in which the panel says the goal is working and nothing
// is. The evidence is the durable phase: a verdict is owed, by the run the
// resume's own feed opened.
//
// The goal is pinned while the primary is working, so the pin's own
// evaluation rests and neither strand has a run open by the time the
// resume asks. That isolates the resume as the only occasion in the
// fixture that could have sent anything.
pub fn a_resume_offers_the_goal_feed_at_once_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(run) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
    as "the primary must accept the fixture run"
  pin_goal(subject, 400_000)
  let _drained = settle(subject)

  // The pin found the primary working, so it rested: nothing has been
  // offered to the reviewer yet.
  assert goal_feeds_on(rig.opened) == 0

  let assert Ok(Nil) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.PauseGoal(reply:)
    })
    as "the operator's pause must commit"
  let _drained = settle(subject)
  assert goalstate.status_of(goal_cell(rig))
    == goalstate.Paused(by: goalstate.ByOperator)

  // Both strands go idle while the goal is held, which is the state a
  // resume finds after an abort or an operator pause.
  idle_again(rig, run)
  assert strand_operation(rig.opened, advisor.primary) == None
    as "the settled abort must leave the primary idle in the store"

  let assert Ok(Nil) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.ResumeGoal(reply:)
    })
    as "the operator's resume must commit"

  // The command answers before its own evaluation, so that a terminal
  // waiting on the reply does not wait on a provider. The barrier is a call
  // sent after it: an answer means the command's work is finished, because
  // the mailbox is FIFO per sender.
  //
  // It is the *inert* barrier, and that matters here more than anywhere. A
  // run-start drain evaluates the goal itself, so a `settle` would have sent
  // the feed this test is asserting the resume sent — the fixture would have
  // passed against a resume that evaluated nothing.
  barrier(subject)

  // The resume sent the feed itself. The phase names the advisor run the
  // feed opened, which is what a verdict is matched against and what a
  // replacement actor would read to know one is owed.
  let resumed = goal_cell(rig)
  assert goalstate.status_of(resumed) == goalstate.Active
  assert goal_feeds_on(rig.opened) == 1
    as "the resume itself must offer the goal to the reviewer"
  let assert Some(feed) = strand_operation(rig.opened, advisor.strand)
    as "the resumed goal's feed must have opened a run on the advisor"
  assert resumed.phase == goalstate.AwaitingVerdict(feed:)
  stop(rig)
}

// Pause and resume, as the operator asks. Resuming a complete goal
// refuses: completion is the reviewer's verdict, not a status to undo.
pub fn resume_refuses_a_complete_goal_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(_pinned) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.SetGoal(
        objective: "land the migration",
        token_budget: 400_000,
        reply:,
      )
    })

  let assert Ok(run) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
  process.send(subject, advisor.PrimaryRunEnded(operation: run))
  let _drained = settle(subject)
  idle_again(rig, run)

  let assert Ok(advise.Acknowledged) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Complete(text: "merged"),
        reply:,
      )
    })

  let refused =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.ResumeGoal(reply:)
    })
  assert refused == Error("a complete goal cannot be resumed; set a new one")
  stop(rig)
}

// Clearing the goal retires the cell: absence is the one durable
// representation of no goal, and a late verdict against the cleared goal
// says the goal is gone.
pub fn a_cleared_goal_is_gone_and_a_late_verdict_says_so_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(_pinned) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.SetGoal(
        objective: "land the migration",
        token_budget: 400_000,
        reply:,
      )
    })

  let assert Ok(run) =
    api.accept_quietly(rig.runtime, [user("write the migration")])
  process.send(subject, advisor.PrimaryRunEnded(operation: run))
  let _drained = settle(subject)
  idle_again(rig, run)

  let assert Ok(Nil) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.ClearGoal(reply:)
    })
  assert api.fact(rig.runtime, advisor.goal_key) == Ok(None)

  // A goal verdict that raced the clear is refused: the goal it would
  // have continued is gone.
  let refused =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.Judge(
        strand: advisor.strand,
        verdict: advise.Continue(text: "the race remains"),
        reply:,
      )
    })
  assert refused
    == Error(
      "no goal feed is open; continue and complete answer the session's goal feeds only",
    )
  stop(rig)
}

// The gate's other half: an abort of a run the actor did not wake is the
// operator changing their own mind about their own work, and the goal
// is none the wiser. The `woke` check is what makes a goal-woken run
// precise rather than inferred.
pub fn an_abort_of_a_foreign_run_leaves_the_goal_active_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  let assert Ok(_pinned) =
    process.call(subject, waiting: 5000, sending: fn(reply) {
      advisor.SetGoal(
        objective: "land the migration",
        token_budget: 400_000,
        reply:,
      )
    })

  // An abort the actor has no woken run for: nobody's continuation is
  // involved, so the goal keeps running.
  process.send(subject, advisor.PrimaryAborted(operation: an_op_id(5)))
  let _drained = settle(subject)

  let assert Ok(Some(cell)) = api.fact(rig.runtime, advisor.goal_key)
  let assert Ok(goal) = goalstate.decode(cell)
  assert goalstate.status_of(goal) == goalstate.Active
  stop(rig)
}

// --- the accounting starts where the ledger stands -------------------------

// One primary entry, with the run that carried it closed again, so the next
// acceptance is not refused as `strand_busy` and the wrap-up door finds an
// idle primary to wake.
fn a_settled_primary_entry(rig: Rig) -> EntryId {
  let leaf = a_primary_entry(rig)
  case strand_operation(rig.opened, advisor.primary) {
    Some(open) -> idle_again(rig, open)
    None -> Nil
  }
  leaf
}

// A fresh goal's accounting starts at the ledger's newest seq, so spend the
// session had already made is not charged to a budget the operator has only
// just set.
//
// The cursor used to start at zero, which meant the first evaluation summed
// every usage row the session had ever committed: on a session that had spent
// two million tokens, `/goal --budget 400000` was `budget_limited` before the
// loop ran once, and the operator's only evidence was a panel saying their
// brand-new goal had exhausted its budget.
pub fn spend_before_the_pin_is_not_charged_to_the_goal_test() {
  let assert Ok(rig) = a_rig() as "the advisor rig must open"
  let assert Ok(subject) = address.lookup(rig.name)
    as "the advisor actor must be registered"

  // The session's history: one primary entry with one usage row against it,
  // committed before anybody pinned anything.
  let worked = a_settled_primary_entry(rig)
  let before = commit_usage(rig, worked, 201)

  pin_goal(subject, 400_000)

  process.send(subject, advisor.PrimarySpent)
  barrier(subject)

  let pinned = goal_cell(rig)
  assert pinned.tokens_used == 0
    as "spend the session made before the pin is not the goal's"
  assert pinned.accounted_through_seq >= before
    as "the cursor starts at the ledger's newest row, not at zero"

  // Spend after the pin is the goal's, which is what says the cursor was
  // seeded rather than parked past everything. The row names an entry
  // committed after the pin, which is the shape every real row has: the
  // ledger writes a row in the same transaction as the entry it names.
  let fresh = a_settled_primary_entry(rig)
  let _after = commit_usage(rig, fresh, 202)
  process.send(subject, advisor.PrimarySpent)
  barrier(subject)

  assert goal_cell(rig).tokens_used == 26
    as "spend after the pin is charged to the goal"
  stop(rig)
}
