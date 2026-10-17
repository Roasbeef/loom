//// Forks (pi §2.7): branch and tree scopes, fresh strand state, ledger
//// zeroed, semantic-fact copying, refusal cases, and the generated property
//// that a branch fork's projected context equals the source's projection
//// at the fork point.

import core/clock
import core/ids
import core/json
import core/message
import core/register
import core/tx.{SetRegister, Tx}
import gleam/list
import gleam/option.{None, Some}
import machine/strand.{
  ModelIdentity, StrandConfiguration, StrandState, ThinkingOff,
}
import qcheck
import session/repo
import session/session
import simplifile
import storage/sqlite
import storage/storage
import support/drive
import support/messages

// Every fork mints the destination's canonical id, so every fork call
// needs a generator. Tests that assert something about the minted id
// build their own; the rest take this one.
fn fork_generator() -> ids.Generator {
  ids.generator(clock.stepping(from: 5000, by: 7), seed: 99)
}

fn configuration() -> strand.StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: ThinkingOff,
    active_tool_names: [],
  )
}

fn fresh_path(name: String) -> String {
  let _ = simplifile.create_directory_all("build/test_db")
  let path = "build/test_db/" <> name <> ".db"
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  path
}

// --- branch scope ----------------------------------------------------------

pub fn branch_fork_copies_the_ancestor_chain_test() {
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  let ctx = drive.new_ctx(source, 1)
  let #(ctx, _) = drive.append_message(ctx, messages.user_msg(1))
  let #(ctx, at) =
    drive.append_message(ctx, messages.assistant_msg(2, message.Stop, []))
  // A descendant past the fork point must not be copied.
  let #(ctx, _) = drive.append_message(ctx, messages.user_msg(3))
  let ctx = drive.append_usage(ctx, ctx.leaf, messages.some_usage(50))
  let assert Ok(forked) =
    repo.fork(
      source: ctx.session,
      scope: repo.ForkBranch(strand: "main", at:),
      into: repo.ForkIntoMemory,
      clock: clock.fixed(at: 2000),
      generator: fork_generator(),
    )

  // The forked main strand: leaf at the fork point, fresh state, copied
  // configuration.
  let assert Ok(Some(session.Cell(value: leaf, ..))) =
    session.strand_leaf(forked, "main")
  assert leaf == Some(at)
  let assert Ok(Some(session.Cell(value: state, ..))) =
    session.strand_state(forked, "main")
  assert state == StrandState(current_operation: None, pending_next_run: [])
  let assert Ok(Some(session.Cell(value: config, ..))) =
    session.strand_configuration(forked, "main")
  assert config == configuration()

  // Only the chain: two entries, and the ledger starts at zero.
  let assert Ok(entries) =
    storage.scan_entries(forked.store, storage.entry_scan())
  assert list.length(entries) == 2
  let assert Ok([]) = storage.scan_usage(forked.store, storage.usage_scan())
  let assert Ok(stats) = storage.stats(forked.store)
  assert stats.usage == storage.empty_usage()

  // Projections agree at the fork point.
  let assert Ok(source_context) = session.project_context(source, Some(at))
  let assert Ok(forked_context) = session.project_context(forked, Some(at))
  assert forked_context == source_context
}

pub fn branch_fork_of_unconfigured_strand_copies_no_configuration_test() {
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(source, 2)
  let #(_ctx, at) = drive.append_message(ctx, messages.user_msg(1))
  let assert Ok(forked) =
    repo.fork(
      source:,
      scope: repo.ForkBranch(strand: "main", at:),
      into: repo.ForkIntoMemory,
      clock: clock.fixed(at: 2000),
      generator: fork_generator(),
    )
  let assert Ok(None) = session.strand_configuration(forked, "main")
  let assert Ok(Some(session.Cell(value: leaf, ..))) =
    session.strand_leaf(forked, "main")
  assert leaf == Some(at)
}

pub fn branch_fork_copies_labels_only_for_copied_entries_test() {
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(source, 3)
  let #(ctx, at) = drive.append_message(ctx, messages.user_msg(1))
  let #(ctx, behind) = drive.append_message(ctx, messages.user_msg(2))
  let assert Ok(_) =
    storage.commit(
      ctx.session.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.FactName,
            key: "session",
            value: register.value(json.String("the session name")),
          ),
          SetRegister(
            ns: register.FactLabel,
            key: ids.entry_id_to_string(at),
            value: register.value(json.String("kept label")),
          ),
          SetRegister(
            ns: register.FactLabel,
            key: ids.entry_id_to_string(behind),
            value: register.value(json.String("left behind")),
          ),
          SetRegister(
            ns: register.FactCustom,
            key: "app",
            value: register.value(json.String("application state")),
          ),
        ],
        expected: [],
      ),
    )
  let assert Ok(forked) =
    repo.fork(
      source:,
      scope: repo.ForkBranch(strand: "main", at:),
      into: repo.ForkIntoMemory,
      clock: clock.fixed(at: 2000),
      generator: fork_generator(),
    )
  // The session name copies; the label of the uncopied entry does not;
  // application-defined facts never copy without an explicit policy.
  let assert Ok(Some(_)) =
    storage.get_register(forked.store, register.FactName, "session")
  let assert Ok(Some(_)) =
    storage.get_register(
      forked.store,
      register.FactLabel,
      ids.entry_id_to_string(at),
    )
  let assert Ok(None) =
    storage.get_register(
      forked.store,
      register.FactLabel,
      ids.entry_id_to_string(behind),
    )
  let assert Ok(None) =
    storage.get_register(forked.store, register.FactCustom, "app")
}

pub fn fork_point_must_exist_test() {
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let #(ghost, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 0), seed: 9))
  let assert Error(repo.ForkPointUnknown(id:)) =
    repo.fork(
      source:,
      scope: repo.ForkBranch(strand: "main", at: ghost),
      into: repo.ForkIntoMemory,
      clock: clock.fixed(at: 2000),
      generator: fork_generator(),
    )
  assert id == ghost
}

// --- orphan-call healing at the fork boundary ------------------------------

pub fn fork_at_assistant_with_calls_heals_at_projection_test() {
  let call_a = messages.tool_call(1, json.Object([]))
  let call_b = messages.tool_call(2, json.Object([]))
  let assistant = messages.assistant_msg(3, message.ToolUse, [call_a, call_b])
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(source, 4)
  let #(ctx, _) = drive.append_message(ctx, messages.user_msg(1))
  let #(ctx, at) = drive.append_message(ctx, assistant)
  let #(ctx, _) = drive.append_message(ctx, messages.tool_result(call_a, 4))
  let #(ctx, _) = drive.append_message(ctx, messages.tool_result(call_b, 5))
  let assert Ok(forked) =
    repo.fork(
      source: ctx.session,
      scope: repo.ForkBranch(strand: "main", at:),
      into: repo.ForkIntoMemory,
      clock: clock.fixed(at: 2000),
      generator: fork_generator(),
    )
  // The fork left both results behind; request construction heals both
  // calls, in source order, directly after the assistant message.
  let assert Ok(Some(session.Cell(value: leaf, ..))) =
    session.strand_leaf(forked, "main")
  let assert Ok(projected) = session.project_context(forked, leaf)
  let assert [projected_user, projected_assistant, healed_a, healed_b] =
    projected
  assert projected_user == messages.user_msg(1)
  assert projected_assistant == assistant
  let assert message.ToolResultMessage(
    tool_call_id: "call-1",
    is_error: True,
    ..,
  ) = healed_a
  let assert message.ToolResultMessage(
    tool_call_id: "call-2",
    is_error: True,
    ..,
  ) = healed_b
  // The source still projects the real results — the fork never touched
  // it.
  let assert Ok(source_projected) = session.project_context(source, ctx.leaf)
  assert list.length(source_projected) == 4
  let assert [_, _, real_a, _] = source_projected
  assert real_a == messages.tool_result(call_a, 4)
}

// --- tree scope ------------------------------------------------------------

pub fn tree_fork_copies_every_strand_and_all_labels_test() {
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  let assert Ok(Nil) = session.ensure_strand(source, "side", configuration())
  let ctx = drive.new_ctx(source, 5)
  let #(ctx, main_leaf) = drive.append_message(ctx, messages.user_msg(1))
  // A second root chain: the side strand's history.
  let #(ctx, side_leaf) =
    drive.append_message_under(ctx, None, messages.user_msg(2))
  let ctx = drive.append_usage(ctx, Some(main_leaf), messages.some_usage(70))
  let assert Ok(_) =
    storage.commit(
      ctx.session.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.StrandLeaf,
            key: "main",
            value: register.leaf_value(Some(main_leaf)),
          ),
          SetRegister(
            ns: register.StrandLeaf,
            key: "side",
            value: register.leaf_value(Some(side_leaf)),
          ),
          SetRegister(
            ns: register.FactLabel,
            key: ids.entry_id_to_string(side_leaf),
            value: register.value(json.String("side label")),
          ),
          SetRegister(
            ns: register.OpMeta,
            key: "op-1",
            value: register.value(json.Object([])),
          ),
          SetRegister(
            ns: register.StrandLastResult,
            key: "main",
            value: register.value(json.Object([])),
          ),
        ],
        expected: [],
      ),
    )
  let assert Ok(forked) =
    repo.fork(
      source:,
      scope: repo.ForkTree,
      into: repo.ForkIntoMemory,
      clock: clock.fixed(at: 2000),
      generator: fork_generator(),
    )

  // Every entry, every strand's configuration and leaf; fresh states.
  let assert Ok(source_entries) =
    storage.scan_entries(source.store, storage.entry_scan())
  let assert Ok(forked_entries) =
    storage.scan_entries(forked.store, storage.entry_scan())
  assert list.length(forked_entries) == list.length(source_entries)
  let assert Ok(Some(session.Cell(value: main_cell, ..))) =
    session.strand_leaf(forked, "main")
  assert main_cell == Some(main_leaf)
  let assert Ok(Some(session.Cell(value: side_cell, ..))) =
    session.strand_leaf(forked, "side")
  assert side_cell == Some(side_leaf)
  let assert Ok(Some(session.Cell(value: side_state, ..))) =
    session.strand_state(forked, "side")
  assert side_state
    == StrandState(current_operation: None, pending_next_run: [])

  // Labels all copy under tree scope; operation state and terminal
  // results never do; the ledger starts at zero.
  let assert Ok(Some(_)) =
    storage.get_register(
      forked.store,
      register.FactLabel,
      ids.entry_id_to_string(side_leaf),
    )
  let assert Ok(None) =
    storage.get_register(forked.store, register.OpMeta, "op-1")
  let assert Ok(None) = session.last_result(forked, "main")
  let assert Ok([]) = storage.scan_usage(forked.store, storage.usage_scan())
}

// --- destinations ----------------------------------------------------------

pub fn fork_into_sqlite_and_back_test() {
  let path = fresh_path("fork_destination")
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  let ctx = drive.new_ctx(source, 6)
  let #(ctx, _) = drive.append_message(ctx, messages.user_msg(1))
  let #(ctx, at) =
    drive.append_message(ctx, messages.assistant_msg(2, message.Stop, []))
  let assert Ok(forked) =
    repo.fork(
      source: ctx.session,
      scope: repo.ForkBranch(strand: "main", at:),
      into: repo.ForkIntoSqlite(path:, owner: "fork-writer", lease_ttl_ms: 5000),
      clock: clock.stepping(from: 10_000, by: 1),
      generator: fork_generator(),
    )
  let assert Ok(forked_context) = session.project_context(forked, Some(at))
  let assert Ok(source_context) = session.project_context(source, Some(at))
  assert forked_context == source_context
  let assert Ok(Nil) = session.close(forked)

  // Forking into a session that already holds entries is refused.
  let assert Error(repo.ForkDestinationNotEmpty) =
    repo.fork(
      source:,
      scope: repo.ForkBranch(strand: "main", at:),
      into: repo.ForkIntoSqlite(path:, owner: "fork-writer", lease_ttl_ms: 5000),
      clock: clock.stepping(from: 20_000, by: 1),
      generator: fork_generator(),
    )
}

// --- session identity across a fork (protocol-change/008) ------------------

pub fn a_fork_mints_its_own_id_and_records_its_parent_test() {
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  let assert Ok(#(source_id, _)) =
    session.ensure_id(source, ids.generator(clock.fixed(at: 900), seed: 1))
  let ctx = drive.new_ctx(source, 21)
  let #(ctx, at) =
    drive.append_message(ctx, messages.assistant_msg(1, message.Stop, []))
  let assert Ok(forked) =
    repo.fork(
      source: ctx.session,
      scope: repo.ForkBranch(strand: "main", at:),
      into: repo.ForkIntoMemory,
      clock: clock.fixed(at: 2000),
      generator: fork_generator(),
    )
  let assert Ok(Some(forked_id)) = session.id(forked)
  assert forked_id != source_id
  assert session.parent_id(forked) == Ok(Some(source_id))
  // The source is untouched: same id, still no parent of its own.
  assert session.id(source) == Ok(Some(source_id))
  assert session.parent_id(source) == Ok(None)
  // And the id the fork minted is the one a later `ensure_id` reads back.
  let assert Ok(#(kept, _)) =
    session.ensure_id(forked, ids.generator(clock.fixed(at: 3000), seed: 77))
  assert kept == forked_id
}

pub fn a_fork_of_an_unidentified_source_records_no_parent_test() {
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  let ctx = drive.new_ctx(source, 22)
  let #(ctx, at) =
    drive.append_message(ctx, messages.assistant_msg(1, message.Stop, []))
  let assert Ok(forked) =
    repo.fork(
      source: ctx.session,
      scope: repo.ForkBranch(strand: "main", at:),
      into: repo.ForkIntoMemory,
      clock: clock.fixed(at: 2000),
      generator: fork_generator(),
    )
  // Minting one into the source would be a mutation the fork forbids.
  let assert Ok(Some(_)) = session.id(forked)
  assert session.parent_id(forked) == Ok(None)
  assert session.id(source) == Ok(None)
}

pub fn a_sqlite_fork_writes_parent_session_id_test() {
  let path = fresh_path("fork_parent_column")
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  let assert Ok(#(source_id, _)) =
    session.ensure_id(source, ids.generator(clock.fixed(at: 900), seed: 2))
  let ctx = drive.new_ctx(source, 23)
  let #(ctx, at) =
    drive.append_message(ctx, messages.assistant_msg(1, message.Stop, []))
  let assert Ok(forked) =
    repo.fork(
      source: ctx.session,
      scope: repo.ForkBranch(strand: "main", at:),
      into: repo.ForkIntoSqlite(path:, owner: "fork-writer", lease_ttl_ms: 5000),
      clock: clock.stepping(from: 10_000, by: 1),
      generator: fork_generator(),
    )
  let assert Ok(Some(forked_id)) = session.id(forked)
  let assert Ok(Nil) = session.close(forked)
  // The lease-free read an outside lister would use.
  assert sqlite.identity(path:)
    == Ok(#(
      Some(ids.session_id_to_string(forked_id)),
      Some(ids.session_id_to_string(source_id)),
    ))
}

pub fn a_fork_into_an_already_identified_destination_is_refused_test() {
  let path = fresh_path("fork_identified_destination")
  // A destination an earlier open already named, but never wrote an entry
  // into: `require_empty` sees nothing to object to, so only the copy
  // transaction's expectation stands between this and a session file
  // whose id silently changed under it.
  let assert Ok(destination) =
    session.open_sqlite(
      path:,
      owner: "prior-writer",
      lease_ttl_ms: 5000,
      clock: clock.stepping(from: 10_000, by: 1),
    )
    as "the destination file opens"
  let assert Ok(#(already, _)) =
    session.ensure_id(destination, ids.generator(clock.fixed(at: 900), seed: 4))
  let assert Ok(Nil) = session.close(destination)

  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  let ctx = drive.new_ctx(source, 24)
  let #(ctx, at) =
    drive.append_message(ctx, messages.assistant_msg(1, message.Stop, []))
  let assert Error(repo.ForkCopyFailed(error: tx.StaleExpectation(..))) =
    repo.fork(
      source: ctx.session,
      scope: repo.ForkBranch(strand: "main", at:),
      into: repo.ForkIntoSqlite(path:, owner: "fork-writer", lease_ttl_ms: 5000),
      clock: clock.stepping(from: 20_000, by: 1),
      generator: fork_generator(),
    )

  // The destination is exactly as it was: same id, still no entries.
  let assert Ok(reopened) =
    session.open_sqlite(
      path:,
      owner: "after-the-refusal",
      lease_ttl_ms: 5000,
      clock: clock.stepping(from: 30_000, by: 1),
    )
    as "the destination file reopens"
  assert session.id(reopened) == Ok(Some(already))
  let assert Ok([]) = storage.scan_entries(reopened.store, storage.entry_scan())
  let assert Ok(Nil) = session.close(reopened)
}

// --- projection equivalence (generated property) ---------------------------

/// How many generated trees the fork property is checked over (the
/// hand-seeded sweep it replaced drew 20), and the qcheck seed they are
/// drawn from. The seed is fixed so the gate is deterministic.
const fork_tree_count = 100

const fork_tree_seed = 61

/// Whether a grown entry also gets a usage row. A named pair rather than a
/// `Bool` field, so a generated step reads as a domain choice.
type Billing {
  Billed
  Unbilled
}

/// One growth step of a generated tree. `parent_pick` indexes the entries
/// grown so far, newest first, wrapping at the count, so the step stays
/// valid whatever the tree looks like when it is replayed.
type Growth {
  Growth(parent_pick: Int, kind: Int, billing: Billing)
}

/// A tree of one to twelve growth steps and a pick for the fork point.
/// Every number shrinks toward zero: a failing tree is reported with fewer
/// steps, each hanging off the newest entry (a plain chain), each a user
/// message with no usage row, forked at the newest entry.
fn tree_generator() -> qcheck.Generator(#(List(Growth), Int)) {
  let growth =
    qcheck.map3(
      qcheck.bounded_int(from: 0, to: 1000),
      qcheck.bounded_int(from: 0, to: 3),
      qcheck.bounded_int(from: 0, to: 1),
      fn(parent_pick, kind, billed) {
        let billing = case billed {
          0 -> Unbilled
          _ -> Billed
        }
        Growth(parent_pick:, kind:, billing:)
      },
    )
  let steps =
    qcheck.generic_list(
      elements_from: growth,
      length_from: qcheck.bounded_int(from: 1, to: 12),
    )
  qcheck.tuple2(steps, qcheck.bounded_int(from: 0, to: 1000))
}

pub fn branch_fork_projection_equals_source_property_test() {
  qcheck.default_config()
  |> qcheck.with_test_count(fork_tree_count)
  |> qcheck.with_seed(qcheck.seed(fork_tree_seed))
  |> qcheck.run(tree_generator(), fn(tree) {
    let #(steps, at_pick) = tree
    run_fork_scenario(steps, at_pick)
  })
}

// Builds a generated branching tree with interleaved usage rows, forks at
// a picked entry, and asserts the fork's projected context at its leaf is
// exactly the source's at the fork point — and that the fork carries no
// cost history.
fn run_fork_scenario(steps: List(Growth), at_pick: Int) -> Nil {
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  let ctx = drive.new_ctx(source, 777)
  let #(ctx, all_ids) =
    list.fold(over: steps, from: #(ctx, []), with: fn(grown, step) {
      let #(ctx, all_ids) = grown
      grow_tree(ctx, all_ids, step)
    })
  let assert Ok(at) = pick(all_ids, at_pick)
  let assert Ok(forked) =
    repo.fork(
      source: ctx.session,
      scope: repo.ForkBranch(strand: "main", at:),
      into: repo.ForkIntoMemory,
      clock: clock.fixed(at: 2000),
      generator: fork_generator(),
    )
  let assert Ok(Some(session.Cell(value: forked_leaf, ..))) =
    session.strand_leaf(forked, "main")
  assert forked_leaf == Some(at)
  let assert Ok(source_context) = session.project_context(source, Some(at))
  let assert Ok(forked_context) = session.project_context(forked, Some(at))
  assert forked_context == source_context
  let assert Ok([]) = storage.scan_usage(forked.store, storage.usage_scan())
  let assert Ok(stats) = storage.stats(forked.store)
  assert stats.usage == storage.empty_usage()
  Nil
}

fn grow_tree(
  ctx: drive.Ctx,
  all_ids: List(ids.EntryId),
  step: Growth,
) -> #(drive.Ctx, List(ids.EntryId)) {
  let parent = option.from_result(pick(all_ids, step.parent_pick))
  let #(ctx, n) = drive.tick(ctx)
  let #(ctx, id) = case step.kind {
    0 -> drive.append_message_under(ctx, parent, messages.user_msg(n))
    1 ->
      drive.append_message_under(
        ctx,
        parent,
        messages.assistant_msg(n, message.Stop, []),
      )
    2 ->
      drive.append_message_under(
        ctx,
        parent,
        messages.assistant_msg(n, message.Errored, []),
      )
    _ -> {
      let call = messages.tool_call(n, json.Object([]))
      let #(ctx, _) =
        drive.append_message_under(
          ctx,
          parent,
          messages.assistant_msg(n, message.ToolUse, [call]),
        )
      drive.append_message(ctx, messages.tool_result(call, n))
    }
  }
  let ctx = case step.billing {
    Billed -> drive.append_usage(ctx, Some(id), messages.some_usage(n))
    Unbilled -> ctx
  }
  #(ctx, [id, ..all_ids])
}

// The entry a generated pick names: an index into the newest-first list,
// wrapping at its length. An empty list names nothing, which is how the
// first step gets no parent.
fn pick(all_ids: List(ids.EntryId), index: Int) -> Result(ids.EntryId, Nil) {
  case list.length(all_ids) {
    0 -> Error(Nil)
    count ->
      all_ids
      |> list.drop(index % count)
      |> list.first
  }
}
