//// Projection semantics: catch-up equals rebuild, hints are lossy but
//// convergence is pull-based, checkpoints resume without refolding.

import core/entry as core_entry
import core/message
import events/bus
import events/projection.{EntryAppended, UsageAppended}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import storage/storage
import support/fixtures
import telemetry/log

/// Commits `n` single-entry transactions plus a usage row on every
/// second one; returns the store and the threaded id context (minting
/// from a fresh context against the same store would re-mint the same
/// deterministic ids and corrupt the id namespace).
fn seeded_store(n: Int) {
  let store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let ctx =
    int.range(from: 1, to: n + 1, with: ctx, run: fn(ctx, i) {
      let #(entry, ctx) =
        fixtures.message_entry(ctx, None, "turn " <> int.to_string(i))
      case i % 2 {
        0 -> {
          let #(row, ctx) = fixtures.usage_row(ctx, i * 10)
          fixtures.commit_entry_and_usage(store, entry, row)
          ctx
        }
        _ -> {
          fixtures.commit_entries(store, [entry])
          ctx
        }
      }
    })
  #(store, ctx)
}

pub fn stats_rebuild_equals_maintained_stats_test() {
  let #(store, _ctx) = seeded_store(8)
  let assert Ok(#(rebuilt, high_water)) =
    projection.rebuild(store, projection.stats_projection())
  let assert Ok(maintained) = storage.stats(store)
  assert rebuilt == maintained
  assert high_water > 0
}

pub fn incremental_catch_up_equals_rebuild_test() {
  let store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let stats = projection.stats_projection()
  // Fold incrementally after every commit...
  let #(_ctx, incremental, high_water) =
    int.range(from: 1, to: 7, with: #(ctx, stats.initial, 0), run: fn(acc, i) {
      let #(ctx, state, high_water) = acc
      let #(entry, ctx) =
        fixtures.message_entry(ctx, None, "step " <> int.to_string(i))
      let #(row, ctx) = fixtures.usage_row(ctx, i)
      fixtures.commit_entry_and_usage(store, entry, row)
      let assert Ok(#(state, high_water)) =
        projection.catch_up(store, stats, state, after: high_water)
      #(ctx, state, high_water)
    })
  // ...and it must equal one rebuild from zero.
  let assert Ok(#(rebuilt, rebuilt_high_water)) =
    projection.rebuild(store, stats)
  assert incremental == rebuilt
  assert high_water == rebuilt_high_water
}

pub fn catch_up_is_idempotent_at_the_high_water_test() {
  let #(store, _ctx) = seeded_store(4)
  let stats = projection.stats_projection()
  let assert Ok(#(state, high_water)) = projection.rebuild(store, stats)
  let assert Ok(#(again, again_high_water)) =
    projection.catch_up(store, stats, state, after: high_water)
  assert again == state
  assert again_high_water == high_water
}

pub fn change_seq_orders_the_merged_stream_test() {
  let #(store, _ctx) = seeded_store(6)
  let assert Ok(#(_state, _hw)) =
    projection.rebuild(store, projection.stats_projection())
  // The merge order is observable through a recording projection.
  let recorder =
    projection.Projection(initial: [], apply: fn(seqs, change) {
      [projection.change_seq(change), ..seqs]
    })
  let assert Ok(#(seqs, _hw)) = projection.rebuild(store, recorder)
  let ascending = list.reverse(seqs)
  assert ascending == list.sort(ascending, int.compare)
  // Both kinds of change are present in the stream.
  let count =
    projection.Projection(initial: #(0, 0), apply: fn(acc, change) {
      let #(entries, usage) = acc
      case change {
        EntryAppended(..) -> #(entries + 1, usage)
        UsageAppended(..) -> #(entries, usage + 1)
      }
    })
  let assert Ok(#(#(entries, usage), _hw)) = projection.rebuild(store, count)
  assert entries == 6
  assert usage == 3
}

// --- the driver ------------------------------------------------------------

/// The WP-K lost-event exit criterion: drop every Nth event and the
/// projection still converges via catch-up, equalling a rebuild from
/// zero. Here the driver receives a hint for only every third commit —
/// two thirds of all events are lost — and converges anyway, because a
/// hint only prompts a pull and every pull reads everything owed.
pub fn lost_events_converge_via_catch_up_test() {
  let bus = bus.start()
  let session = "projection-lossy"
  let store = fixtures.open_store()
  let assert Ok(started) =
    projection.start(projection.Options(
      store: fn() { store },
      generation: fn() { 0 },
      projection: projection.stats_projection(),
      checkpoint: projection.ephemeral(),
      hints: projection.FromBus(bus:, session:),
      logger: log.discard(),
    ))
  let driver = started.data
  let ctx = fixtures.new_ctx()
  let _ctx =
    int.range(from: 1, to: 10, with: ctx, run: fn(ctx, i) {
      let #(entry, ctx) =
        fixtures.message_entry(ctx, None, "lossy " <> int.to_string(i))
      let #(row, ctx) = fixtures.usage_row(ctx, i)
      fixtures.commit_entry_and_usage(store, entry, row)
      // Drop every event except each third: loss is legal.
      case i % 3 {
        0 -> bus.publish(bus, session:, event: bus.Committed(seqs: [], ts: i))
        _ -> Nil
      }
      ctx
    })
  // `sync` queues behind the delivered hints, forces a final pull, and
  // returns the converged state.
  let assert Ok(converged) = projection.sync(driver)
  let assert Ok(#(rebuilt, _hw)) =
    projection.rebuild(store, projection.stats_projection())
  let assert Ok(maintained) = storage.stats(store)
  assert converged == rebuilt
  assert converged == maintained
}

/// Total loss: no events are ever published, and the driver still
/// converges on an explicit sync — pulls are truth.
pub fn total_event_loss_still_converges_test() {
  let #(store, _ctx) = seeded_store(5)
  let assert Ok(started) =
    projection.start(projection.Options(
      store: fn() { store },
      generation: fn() { 0 },
      projection: projection.stats_projection(),
      checkpoint: projection.ephemeral(),
      hints: projection.NoHints,
      logger: log.discard(),
    ))
  let assert Ok(converged) = projection.sync(started.data)
  let assert Ok(maintained) = storage.stats(store)
  assert converged == maintained
}

pub fn hint_triggers_catch_up_test() {
  let bus = bus.start()
  let session = "projection-hinted"
  let store = fixtures.open_store()
  let assert Ok(started) =
    projection.start(projection.Options(
      store: fn() { store },
      generation: fn() { 0 },
      projection: projection.stats_projection(),
      checkpoint: projection.ephemeral(),
      hints: projection.FromBus(bus:, session:),
      logger: log.discard(),
    ))
  let driver = started.data
  let ctx = fixtures.new_ctx()
  let #(entry, _ctx) = fixtures.message_entry(ctx, None, "hinted turn")
  fixtures.commit_entries(store, [entry])
  bus.publish(bus, session:, event: bus.Committed(seqs: [1], ts: 1))
  // `read` never pulls, so observing the count means the *hint* drove
  // the catch-up. The hint is asynchronous; poll briefly.
  assert wait_for_count(driver, 1, attempts: 50)
}

fn wait_for_count(
  driver: process.Subject(projection.Message(storage.SessionStats)),
  expected: Int,
  attempts attempts: Int,
) -> Bool {
  case projection.read(driver).message_count == expected, attempts {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(10)
      wait_for_count(driver, expected, attempts: attempts - 1)
    }
  }
}

pub fn read_lags_until_poked_test() {
  let store = fixtures.open_store()
  let assert Ok(started) =
    projection.start(projection.Options(
      store: fn() { store },
      generation: fn() { 0 },
      projection: projection.stats_projection(),
      checkpoint: projection.ephemeral(),
      hints: projection.NoHints,
      logger: log.discard(),
    ))
  let driver = started.data
  assert projection.read(driver).message_count == 0
  let ctx = fixtures.new_ctx()
  let #(entry, _ctx) = fixtures.message_entry(ctx, None, "lagging turn")
  fixtures.commit_entries(store, [entry])
  // Still stale: reads are local-speed and never pull.
  assert projection.read(driver).message_count == 0
  projection.poke(driver)
  assert wait_for_count(driver, 1, attempts: 50)
}

/// A driver started from a checkpoint resumes from its high-water
/// instead of refolding: the marker state survives because nothing past
/// the checkpointed seq exists to fold.
pub fn checkpoint_resumes_without_refolding_test() {
  let #(store, ctx) = seeded_store(4)
  let stats = projection.stats_projection()
  let assert Ok(#(state, high_water)) = projection.rebuild(store, stats)
  // Poison the checkpointed state with an impossible count; if the
  // driver refolded from zero the marker would vanish.
  let marker = storage.SessionStats(..state, message_count: 100)
  let saves = process.new_subject()
  let checkpoint =
    projection.Checkpoint(
      load: fn() { option.Some(#(marker, high_water, 0)) },
      save: fn(saved_state, saved_high_water, saved_generation) {
        process.send(saves, #(saved_state, saved_high_water, saved_generation))
      },
    )
  let assert Ok(started) =
    projection.start(projection.Options(
      store: fn() { store },
      generation: fn() { 0 },
      projection: stats,
      checkpoint:,
      hints: projection.NoHints,
      logger: log.discard(),
    ))
  let driver = started.data
  assert projection.read(driver).message_count == 100
  // The start-time convergence pull found nothing new but still saved.
  let assert Ok(#(saved, saved_high_water, saved_generation)) =
    process.receive(saves, 500)
  assert saved == marker
  assert saved_high_water == high_water
  assert saved_generation == 0
  // New commits fold on top of the resumed state (the threaded ctx
  // keeps minted ids disjoint from the seeded ones).
  let #(entry, _ctx) = fixtures.message_entry(ctx, None, "after checkpoint")
  fixtures.commit_entries(store, [entry])
  let assert Ok(after) = projection.sync(driver)
  assert after.message_count == 101
}

// --- rewrite invalidation ---------------------------------------------------

/// A projection that folds each message entry's text into a list — the
/// stats projection only counts, so it cannot show *content* surviving
/// a rewrite; this one can.
fn text_projection() -> projection.Projection(List(String)) {
  projection.Projection(initial: [], apply: fn(seen, change) {
    case change {
      EntryAppended(entry:) -> [entry_user_text(entry), ..seen]
      UsageAppended(..) -> seen
    }
  })
}

fn entry_user_text(entry: core_entry.Entry) -> String {
  case entry {
    core_entry.MessageEntry(message: message.UserMessage(content:, ..), ..) ->
      case content {
        [message.UserText(text:, ..), ..] -> text
        _ -> ""
      }
    _ -> ""
  }
}

/// A single mutable cell, actor-backed — the test double for "wherever
/// the driver's `store`/`generation` thunks actually read from" (a
/// session registry in production). Its whole point is that `cell_get`
/// after a `cell_set` returns the *new* value, unlike a plain closure
/// over a `let`-bound variable.
type CellMessage(value) {
  CellGet(reply: Subject(value))
  CellSet(value: value)
}

fn start_cell(initial: value) -> Subject(CellMessage(value)) {
  let assert Ok(started) =
    actor.new(initial)
    |> actor.on_message(fn(state, message) {
      case message {
        CellGet(reply:) -> {
          process.send(reply, state)
          actor.continue(state)
        }
        CellSet(value:) -> actor.continue(value)
      }
    })
    |> actor.start
    as "cell actor must start"
  started.data
}

fn cell_get(cell: Subject(CellMessage(value))) -> value {
  process.call(cell, waiting: 1000, sending: CellGet)
}

fn cell_set(cell: Subject(CellMessage(value)), value: value) -> Nil {
  process.send(cell, CellSet(value))
}

/// EV-proj-rewrite: a precise rewrite preserves seq numbering while
/// replacing payloads, so the frontier rule alone cannot see it — a
/// projection checkpointed over the store before the rewrite must
/// notice the generation moved and rebuild from zero instead of
/// serving the pre-rewrite state forever.
///
/// The rewrite is simulated exactly as `events/search`'s own
/// `generation_bump_invalidates_and_reindexes_test` simulates it: a
/// fresh store under the same session, at a bumped generation — which
/// is precisely what a real `storage/sqlite.rewrite_into` swap looks
/// like from a reader's side (same seq numbering could apply; here a
/// fresh store is simplest and keeps the test backend-agnostic, since
/// the driver's contract is the generation counter, not the swap
/// mechanism). `store`/`generation` are cell-backed rather than plain
/// closures over a `let`-bound store, so the test can swap them the way
/// a real session would after a rewrite — and so this test would still
/// catch a driver that only re-reads `generation` but keeps its store
/// handle from `start`.
pub fn rewrite_invalidates_checkpointed_projection_test() {
  let before_store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(secret, _ctx) =
    fixtures.message_entry(ctx, None, "the doomed passphrase")
  fixtures.commit_entries(before_store, [secret])

  let store_cell = start_cell(before_store)
  let generation_cell = start_cell(0)

  let assert Ok(started) =
    projection.start(projection.Options(
      store: fn() { cell_get(store_cell) },
      generation: fn() { cell_get(generation_cell) },
      projection: text_projection(),
      checkpoint: projection.ephemeral(),
      hints: projection.NoHints,
      logger: log.discard(),
    ))
  let driver = started.data
  let assert Ok(before) = projection.sync(driver)
  assert list.contains(before, "the doomed passphrase")

  // The rewrite: a fresh store (fresh seq numbering, no trace of the
  // erased entry) under a bumped generation — swapped in through the
  // cells, exactly as a session would after a real rewrite.
  let after_store = fixtures.open_store()
  let ctx = fixtures.new_ctx()
  let #(kept, _ctx) = fixtures.message_entry(ctx, None, "the surviving remark")
  fixtures.commit_entries(after_store, [kept])
  cell_set(store_cell, after_store)
  cell_set(generation_cell, 1)

  let assert Ok(after) = projection.sync(driver)
  assert !list.contains(after, "the doomed passphrase")
  assert list.contains(after, "the surviving remark")
}
