//// Projection semantics: catch-up equals rebuild, hints are lossy but
//// convergence is pull-based, checkpoints resume without refolding.

import events/bus
import events/projection.{EntryAppended, UsageAppended}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import storage/storage
import support/fixtures

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
      store:,
      projection: projection.stats_projection(),
      checkpoint: projection.ephemeral(),
      hints: projection.FromBus(bus:, session:),
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
      store:,
      projection: projection.stats_projection(),
      checkpoint: projection.ephemeral(),
      hints: projection.NoHints,
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
      store:,
      projection: projection.stats_projection(),
      checkpoint: projection.ephemeral(),
      hints: projection.FromBus(bus:, session:),
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
      store:,
      projection: projection.stats_projection(),
      checkpoint: projection.ephemeral(),
      hints: projection.NoHints,
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
      load: fn() { option.Some(#(marker, high_water)) },
      save: fn(saved_state, saved_high_water) {
        process.send(saves, #(saved_state, saved_high_water))
      },
    )
  let assert Ok(started) =
    projection.start(projection.Options(
      store:,
      projection: stats,
      checkpoint:,
      hints: projection.NoHints,
    ))
  let driver = started.data
  assert projection.read(driver).message_count == 100
  // The start-time convergence pull found nothing new but still saved.
  let assert Ok(#(saved, saved_high_water)) = process.receive(saves, 500)
  assert saved == marker
  assert saved_high_water == high_water
  // New commits fold on top of the resumed state (the threaded ctx
  // keeps minted ids disjoint from the seeded ones).
  let #(entry, _ctx) = fixtures.message_entry(ctx, None, "after checkpoint")
  fixtures.commit_entries(store, [entry])
  let assert Ok(after) = projection.sync(driver)
  assert after.message_count == 101
}
