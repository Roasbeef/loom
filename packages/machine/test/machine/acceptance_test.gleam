//// Acceptance rows and pre-acceptance rejections (pi §3.6).

import core/clock
import core/ids
import core/register
import core/tx
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import machine/acceptance.{
  AcceptCompaction, AcceptCtx, AcceptNavigation, AcceptRun, AcceptancePlan,
  InvalidMessage, InvalidNavigation, NothingToCompact, StrandBusy, UnknownTarget,
}
import machine/operation.{
  Inbox, PendingMessage, RunIntent, RunState, Running, Starting,
}
import machine/queue
import machine/strand.{StrandState}
import support/fixture
import support/scenario
import support/store

fn generator() -> ids.Generator {
  ids.generator(clock.fixed(at: 5000), seed: 11)
}

fn idle_ctx() -> acceptance.AcceptCtx {
  AcceptCtx(
    strand: "main",
    now: 5000,
    generator: generator(),
    strand_state: StrandState(current_operation: None, pending_next_run: []),
    strand_state_seq: 3,
    leaf: None,
    leaf_seq: Some(2),
    settings: scenario.settings(),
    pending: dict.new(),
  )
}

pub fn busy_strand_rejects_test() {
  let #(op_id, _generator) = ids.mint_op(generator())
  let busy =
    AcceptCtx(
      ..idle_ctx(),
      strand_state: StrandState(
        current_operation: Some(op_id),
        pending_next_run: [],
      ),
    )
  assert acceptance.accept_prompt(
      AcceptRun(prompts: [fixture.user("hi")]),
      busy,
    )
    == Error(StrandBusy)
}

pub fn empty_run_rejects_test() {
  assert acceptance.accept_prompt(AcceptRun(prompts: []), idle_ctx())
    == Error(InvalidMessage(reason: "acceptance would append zero entries"))
}

pub fn run_accepts_in_payload_free_starting_test() {
  let assert Ok(AcceptancePlan(operation:, state:, tx: _)) =
    acceptance.accept_prompt(
      AcceptRun(prompts: [fixture.user("hello")]),
      idle_ctx(),
    )
  let assert RunIntent(prompt_entries: [_prompt]) = operation.intent
  let assert RunState(
    control: Running,
    phase: Starting,
    inbox: Inbox(steer: [], follow_up: [], writes: []),
    latest_assistant: None,
    ..,
  ) = state
}

pub fn run_captures_next_run_items_test() {
  // Enqueue a next-run item on the idle strand, then accept with no
  // prompts: the captured item alone makes acceptance valid, and its id
  // is not part of the run's prompt intent.
  let strand_state = StrandState(current_operation: None, pending_next_run: [])
  let #(entry, next_strand, _tx) =
    queue.enqueue_next_run(
      "main",
      strand_state,
      1,
      generator(),
      PendingMessage(message: fixture.user("queued idea")),
    )
  let ctx =
    AcceptCtx(
      ..idle_ctx(),
      strand_state: next_strand,
      pending: dict.from_list([
        #(
          ids.entry_id_to_string(entry),
          PendingMessage(message: fixture.user("queued idea")),
        ),
      ]),
    )
  let assert Ok(AcceptancePlan(operation:, state: _, tx: plan_tx)) =
    acceptance.accept_prompt(AcceptRun(prompts: []), ctx)
  let assert RunIntent(prompt_entries: []) = operation.intent
  // The acceptance transaction places the captured entry, deletes its
  // pending register, and clears pending_next_run.
  assert scenario.write_names(plan_tx)
    == [
      "insert:message", "del:pending.entry", "set:strand.leaf", "set:op.meta",
      "set:op.state", "set:strand.state",
    ]
}

pub fn compaction_without_preparation_rejects_test() {
  assert acceptance.accept_prompt(
      AcceptCompaction(custom_instructions: None, preparation: None),
      idle_ctx(),
    )
    == Error(NothingToCompact)
}

pub fn navigation_validations_test() {
  let #(leaf, _generator) = ids.mint_entry(generator())
  let ctx = AcceptCtx(..idle_ctx(), leaf: Some(leaf))
  // Target is the current leaf.
  let assert Error(InvalidNavigation(reason: _)) =
    acceptance.accept_prompt(
      AcceptNavigation(
        target: Some(leaf),
        summarize: False,
        label: None,
        custom_instructions: None,
        preparation: None,
        target_known: True,
      ),
      ctx,
    )
  // Label on the root target.
  let assert Error(InvalidNavigation(reason: _)) =
    acceptance.accept_prompt(
      AcceptNavigation(
        target: None,
        summarize: False,
        label: Some("x"),
        custom_instructions: None,
        preparation: None,
        target_known: True,
      ),
      ctx,
    )
  // Summarize with a null target.
  let assert Error(InvalidNavigation(reason: _)) =
    acceptance.accept_prompt(
      AcceptNavigation(
        target: None,
        summarize: True,
        label: None,
        custom_instructions: None,
        preparation: None,
        target_known: True,
      ),
      ctx,
    )
  // Summarize from the root.
  let #(target, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 6000), seed: 99))
  let assert Error(InvalidNavigation(reason: _)) =
    acceptance.accept_prompt(
      AcceptNavigation(
        target: Some(target),
        summarize: True,
        label: None,
        custom_instructions: None,
        preparation: None,
        target_known: True,
      ),
      idle_ctx(),
    )
  // Unknown non-null target.
  let assert Error(UnknownTarget) =
    acceptance.accept_prompt(
      AcceptNavigation(
        target: Some(target),
        summarize: False,
        label: None,
        custom_instructions: None,
        preparation: None,
        target_known: False,
      ),
      ctx,
    )
}

pub fn acceptance_expects_the_leaf_seq_test() {
  // ORCH-L6: the acceptance transaction carries a strand.leaf seq
  // expectation, so a concurrent idle tree-write moving the leaf between
  // the read and the commit refuses the acceptance instead of
  // mis-parenting its prompt entries.
  let assert Ok(AcceptancePlan(tx: plan_tx, ..)) =
    acceptance.accept_prompt(
      AcceptRun(prompts: [fixture.user("hello")]),
      idle_ctx(),
    )
  assert list.contains(
    plan_tx.expected,
    tx.Expect(ns: register.StrandLeaf, key: "main", seq: Some(2)),
  )
}

pub fn stale_leaf_refuses_acceptance_test() {
  // Behavioral half of ORCH-L6: compute an acceptance against the seeded
  // leaf, move the leaf as an idle tree-write would, then try to commit
  // the stale plan — the leaf CAS must refuse it even though the
  // strand-state seq still matches.
  let world = scenario.fresh()
  let assert Ok(#(strand_state_seq, _value)) =
    store.get_register(world.store, register.StrandState, "main")
  let assert Ok(#(leaf_seq, _value)) =
    store.get_register(world.store, register.StrandLeaf, "main")
  let assert Ok(AcceptancePlan(tx: stale_tx, ..)) =
    acceptance.accept_prompt(
      AcceptRun(prompts: [fixture.user("parent me on the old leaf")]),
      AcceptCtx(
        ..idle_ctx(),
        strand_state_seq: strand_state_seq,
        leaf_seq: Some(leaf_seq),
      ),
    )
  // The concurrent idle tree-write: a fresh entry becomes the leaf,
  // touching neither strand.state nor any op register.
  let #(moved_to, _generator) = ids.mint_entry(generator())
  let assert Ok(moved) =
    store.apply(
      world.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            ns: register.StrandLeaf,
            key: "main",
            value: register.leaf_value(Some(moved_to)),
          ),
        ],
        expected: [],
      ),
    )
  let assert Error(_message) = store.apply(moved, stale_tx)
}

pub fn acceptance_rejections_write_nothing_test() {
  // A rejected acceptance leaves the store untouched by construction:
  // the reject carries no transaction. Assert the CAS discipline instead:
  // the acceptance transaction expects the strand-state seq it read, so
  // a concurrent acceptance loses with a stale expectation.
  let world = scenario.fresh()
  let assert Ok(#(world, _tx)) =
    scenario.accept(world, AcceptRun(prompts: [fixture.user("first")]))
  // Replaying the same acceptance transaction (stale strand-state seq)
  // must be refused by the store.
  let assert Ok(AcceptancePlan(tx: stale_tx, ..)) =
    acceptance.accept_prompt(
      AcceptRun(prompts: [fixture.user("second")]),
      AcceptCtx(
        ..idle_ctx(),
        // The seq read before the first acceptance committed.
        strand_state_seq: 3,
      ),
    )
  let assert Error(_message) = store.apply(world.store, stale_tx)
}
