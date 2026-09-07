//// Shared history over actual leased conversation stores and one owned index.
//// The mutable resolver models current catalogue authorization, not an index
//// locator. All test exchanges have finite deadlines and retire their owners.

import client/distill
import client/history
import core/clock
import core/codec
import core/entry
import core/ids
import core/message
import core/tx
import events/search
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import session/session
import simplifile
import sqlight
import storage/storage
import tools/history as tool
import weft/actor
import weft/poll

type Selection {
  Get(process.Subject(List(distill.Source)))
  Set(List(distill.Source), process.Subject(Nil))
  Arm(Int, fn() -> Nil, process.Subject(Nil))

  /// Parks the resolver on its `after`-th remaining answer and publishes the
  /// subject that resumes it. The owner blocks inside `authorized`, so a test
  /// can decide exactly which phase later calls arrive in.
  Gate(Int, process.Subject(process.Subject(Nil)), process.Subject(Nil))
  Stop
}

/// A parked owner can retire without creating or initializing the index.
pub fn shared_history_parked_retirement_test() {
  let root = directory("parked")
  let path = root <> "/search.db"
  let assert Ok(prepared) =
    history.prepare_shared(history.SharedConfig(path, fn() { Ok([]) }, 1000, 10))
    as "history custody must prepare without I/O"
  assert simplifile.is_file(path) == Ok(False)
  assert prepared.retire() == Ok(Nil)
  assert !process.is_alive(prepared.pid)
  assert simplifile.is_file(path) == Ok(False)
}

/// Two session seams share durable recall but fresh authorization removes both
/// snippets and exact reads, even while their indexed rows remain present.
pub fn shared_history_fresh_membership_and_retirement_test() {
  let root = directory("membership")
  let #(a, a_entry, a_retire) = conversation(root <> "/a.db", 1, "nebula alpha")
  let #(b, b_entry, b_retire) = conversation(root <> "/b.db", 2, "nebula beta")
  let selected = selection([a, b])
  let assert Ok(prepared) =
    history.prepare_shared(history.SharedConfig(
      root <> "/search.db",
      resolver(selected),
      1000,
      10,
    ))
    as "shared owner must prepare"
  let assert Ok(shared) = prepared.begin() as "published owner must initialize"
  let first = history.seam_for(shared, a.session)
  let second = history.seam_for(shared, b.session)
  let assert Ok(hits) = first.search("nebula", 10, tool.Repository)
    as "both live leased source databases must be readable"
  assert list.length(hits) == 2
  assert second.read(a.session, a_entry.id) == Ok(codec.encode_entry(a_entry))
  assert first.read(b.session, b_entry.id) == Ok(codec.encode_entry(b_entry))

  assert process.call(selected, waiting: 1000, sending: Set([a], _)) == Nil
  let assert Ok([only]) = first.search("nebula", 1, tool.Repository)
    as "removed source must be filtered before LIMIT"
  assert only.session == ids.session_id_to_string(a.session)
  let assert Error(tool.IndexRefused(_)) = first.read(b.session, b_entry.id)
    as "retained index rows cannot authorize an exact read"
  let assert Error(tool.IndexRefused(_)) =
    second.search("nebula", 1, tool.Repository)
    as "a seam's own session must still belong to the current domain"

  assert prepared.retire() == Ok(Nil)
  assert !process.is_alive(prepared.pid)
  let assert Error(tool.IndexUnavailable(_)) = first.read(a.session, a_entry.id)
    as "retired Shared must refuse without reusing a closed native handle"
  assert a_retire() == Ok(Nil)
  assert b_retire() == Ok(Nil)
  process.send(selected, Stop)
}

/// Small entry batches expose incomplete progress explicitly, then resume from
/// their durable cursor without duplicate rows or requiring a writer lease.
pub fn shared_history_bounded_refresh_and_identity_refusal_test() {
  let root = directory("bounded")
  let #(a, item, retire) = conversation(root <> "/a.db", 3, "orbit marker")
  let selected = selection([a])
  let assert Ok(prepared) =
    history.prepare_shared(history.SharedConfig(
      root <> "/search.db",
      resolver(selected),
      1000,
      1,
    ))
    as "shared owner must prepare"
  let assert Ok(shared) = prepared.begin() as "shared owner must initialize"
  let seam = history.seam_for(shared, a.session)
  let assert Error(tool.IndexRefused(_)) =
    seam.search("orbit", 10, tool.Repository)
    as "a full bounded page cannot claim the history is complete"
  let assert Ok([hit]) = seam.search("orbit", 10, tool.Repository)
    as "the next request must continue after committed progress"
  assert hit.entry == ids.entry_id_to_string(item.id)
  let #(wrong, _) = ids.mint_session(ids.generator(clock.fixed(0), 99))
  let alias = distill.Source(session: wrong, path: a.path)
  assert process.call(selected, waiting: 1000, sending: Set([alias], _)) == Nil
  let rejected = history.seam_for(shared, wrong)
  let assert Error(tool.IndexRefused(_)) = rejected.read(wrong, item.id)
    as "catalogue identity mismatch must refuse the actual opened database"
  assert prepared.retire() == Ok(Nil)
  assert retire() == Ok(Nil)
  process.send(selected, Stop)
}

/// Commit hints alone index bounded pages; foreground search is not required to
/// make another session's durable text searchable.
pub fn shared_history_commit_hint_indexes_without_query_test() {
  let root = directory("hint")
  let #(a, item, retire) = conversation(root <> "/a.db", 4, "hintonly marker")
  let assert Ok(prepared) =
    history.prepare_shared(history.SharedConfig(
      root <> "/search.db",
      fn() { Ok([a]) },
      1000,
      1,
    ))
    as "shared owner must prepare"
  let assert Ok(shared) = prepared.begin() as "shared owner must initialize"
  let assert Ok(observation) = search.open(root <> "/search.db")
    as "independent projection observer must open"
  history.notify(shared, a.session)
  let expected = ids.entry_id_to_string(item.id)
  let assert poll.Answered(Nil) =
    poll.until(within: 1000, every: 5, attempt: fn() {
      case search.query(observation, "hintonly", 10) {
        Ok([hit]) if hit.entry == expected -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "a commit hint must index without a foreground refresh"
  assert prepared.retire() == Ok(Nil)
  assert search.close(observation) == Ok(Nil)
  assert retire() == Ok(Nil)
}

/// A rewrite at the fresh authorization boundary cannot publish an empty old
/// cut and erase the existing index under the wrong generation.
pub fn shared_history_empty_cut_rechecks_generation_test() {
  let root = directory("rewrite")
  let #(a, _, retire) = conversation(root <> "/a.db", 5, "retained marker")
  let selected = selection([a])
  let assert Ok(prepared) =
    history.prepare_shared(history.SharedConfig(
      root <> "/search.db",
      resolver(selected),
      1000,
      10,
    ))
    as "shared owner must prepare"
  let assert Ok(shared) = prepared.begin() as "shared owner must initialize"
  let seam = history.seam_for(shared, a.session)
  let assert Ok([_]) = seam.search("retained", 10, tool.Repository)
    as "the original indexed row must exist before the rewrite"
  let assert Ok(writer) = sqlight.open(a.path)
    as "test rewrite connection opens"
  assert sqlight.exec("DELETE FROM entries", writer) == Ok(Nil)
  assert sqlight.exec(
      "UPDATE session SET next_seq=1, metadata=CAST(json_set(CAST(metadata AS TEXT),'$.generation',1) AS BLOB)",
      writer,
    )
    == Ok(Nil)
  let mutate = fn() {
    assert sqlight.exec(
        "UPDATE session SET metadata=CAST(json_set(CAST(metadata AS TEXT),'$.generation',2) AS BLOB)",
        writer,
      )
      == Ok(Nil)
  }
  assert process.call(selected, waiting: 1000, sending: Arm(2, mutate, _))
    == Nil
  assert seam.search("retained", 10, tool.Repository)
    == Error(tool.IndexRefused(
      "history source changed generation or was truncated",
    ))
  assert prepared.retire() == Ok(Nil)
  let assert Ok(index) = search.open(root <> "/search.db")
    as "the closed projection must reopen for independent observation"
  let assert Ok([_]) = search.query(index, "retained", 10)
    as "refused stale invalidation must not clear the previously indexed row"
  assert search.close(index) == Ok(Nil)
  assert sqlight.close(writer) == Ok(Nil)
  assert retire() == Ok(Nil)
  process.send(selected, Stop)
}

/// A search arriving while the owner is indexing a commit hint of its own is
/// held until that refresh finishes, and then answered with hits. The owner
/// used to refuse it as a bad request, and two such refusals in the first
/// seconds of a session are what taught the model to stop calling the tool.
pub fn shared_history_holds_a_search_during_a_refresh_test() {
  let root = directory("holding")
  let #(a, _, retire) = conversation(root <> "/a.db", 6, "holding marker")
  let selected = selection([a])
  let assert Ok(prepared) =
    history.prepare_shared(history.SharedConfig(
      root <> "/search.db",
      resolver(selected),
      1000,
      10,
    ))
    as "shared owner must prepare"
  let assert Ok(shared) = prepared.begin() as "shared owner must initialize"
  let seam = history.seam_for(shared, a.session)

  // The refresh resolves the catalogue once to choose its source and once
  // more to validate it before publishing, so the second answer parks the
  // owner inside a job whose request is its own.
  let announced = process.new_subject()
  assert process.call(selected, waiting: 1000, sending: Gate(2, announced, _))
    == Nil
  history.notify(shared, a.session)
  let assert Ok(release) = process.receive(announced, 5000)
    as "the refresh must park inside its own job"

  let answers = process.new_subject()
  process.spawn(fn() {
    process.send(answers, seam.search("holding", 10, tool.Repository))
  })

  // Any answer arriving here is the immediate refusal this change removes.
  let assert poll.Expired =
    poll.until(within: 300, every: 25, attempt: fn() {
      case process.receive(answers, 0) {
        Ok(early) -> poll.Fail(early)
        Error(Nil) -> poll.Retry
      }
    })
    as "a held search must not be answered while the refresh runs"

  process.send(release, Nil)
  let assert Ok(Ok([hit])) = process.receive(answers, 5000)
    as "the held search must be answered once the refresh finishes"
  assert hit.session == ids.session_id_to_string(a.session)
  assert prepared.retire() == Ok(Nil)
  assert retire() == Ok(Nil)
  process.send(selected, Stop)
}

/// A second caller arriving while the owner is serving somebody else's search
/// is refused at once, and told the request was fine and to send it again.
pub fn shared_history_refuses_a_second_caller_as_busy_test() {
  let root = directory("busy")
  let #(a, _, retire) = conversation(root <> "/a.db", 7, "busy marker")
  let selected = selection([a])
  let assert Ok(prepared) =
    history.prepare_shared(history.SharedConfig(
      root <> "/search.db",
      resolver(selected),
      1000,
      10,
    ))
    as "shared owner must prepare"
  let assert Ok(shared) = prepared.begin() as "shared owner must initialize"
  let seam = history.seam_for(shared, a.session)

  // Admission resolves the catalogue once and publication validates it a
  // second time, so the gate parks the owner with a foreground job running.
  let announced = process.new_subject()
  assert process.call(selected, waiting: 1000, sending: Gate(2, announced, _))
    == Nil
  let first = process.new_subject()
  process.spawn(fn() {
    process.send(first, seam.search("busy", 10, tool.Repository))
  })
  let assert Ok(release) = process.receive(announced, 5000)
    as "the first search must park inside its own job"

  let second = process.new_subject()
  process.spawn(fn() {
    process.send(second, seam.search("busy", 10, tool.Repository))
  })
  let assert poll.Expired =
    poll.until(within: 300, every: 25, attempt: fn() {
      case process.receive(second, 0) {
        Ok(early) -> poll.Fail(early)
        Error(Nil) -> poll.Retry
      }
    })
    as "the parked owner answers nobody"

  // The second call is at the head of the mailbox when the owner resumes,
  // and the first caller's job still owns the owner at that moment.
  process.send(release, Nil)
  let assert Ok(Error(tool.IndexBusy(reason))) = process.receive(second, 5000)
    as "a second caller must be refused as busy, not as a bad request"
  assert reason == "another recall request is in flight"
  let assert Ok(Ok([_])) = process.receive(first, 5000)
    as "the first caller's own search must still be answered"
  assert prepared.retire() == Ok(Nil)
  assert retire() == Ok(Nil)
  process.send(selected, Stop)
}

// A gated answer parks the owner for as long as the test needs, so the wait
// here outlasts the owner's own five-second ceiling rather than crashing it.
fn resolver(selected) {
  fn() { Ok(process.call(selected, waiting: 20_000, sending: Get)) }
}

fn selection(sources) {
  let assert Ok(started) =
    actor.new(#(sources, None, None))
    |> actor.on_message(fn(state, request) {
      let #(sources, hook, gate) = state
      case request {
        Get(reply) -> {
          let next = case hook {
            Some(#(1, action)) -> {
              action()
              None
            }
            Some(#(remaining, action)) -> Some(#(remaining - 1, action))
            None -> None
          }

          // The gate is one-shot: it publishes a release subject, waits on
          // it, and every later answer is immediate again.
          let opened = case gate {
            Some(#(1, announce)) -> {
              let release = process.new_subject()
              process.send(announce, release)
              let _ = process.receive(release, 20_000)
              None
            }
            Some(#(remaining, announce)) -> Some(#(remaining - 1, announce))
            None -> None
          }
          process.send(reply, sources)
          actor.continue(#(sources, next, opened))
        }
        Set(next, reply) -> {
          process.send(reply, Nil)
          actor.continue(#(next, hook, gate))
        }
        Arm(after, action, reply) -> {
          process.send(reply, Nil)
          actor.continue(#(sources, Some(#(after, action)), gate))
        }
        Gate(after, announce, reply) -> {
          process.send(reply, Nil)
          actor.continue(#(sources, hook, Some(#(after, announce))))
        }
        Stop -> actor.stop()
      }
    })
    |> actor.start
    as "bounded resolver fixture must start"
  started.data
}

fn conversation(path, seed, text) {
  let clock = clock.fixed(1000)
  let assert Ok(#(opened, retire)) =
    session.open_sqlite_owned(
      path:,
      owner: "shared-history-test",
      lease_ttl_ms: 60_000,
      clock:,
    )
    as "actual leased conversation must open"
  let assert Ok(#(id, generator)) =
    session.ensure_id(opened, ids.generator(clock, seed))
    as "conversation must publish its canonical ID"
  let #(entry_id, _) = ids.mint_entry(generator)
  let item =
    entry.MessageEntry(
      entry_id,
      None,
      0,
      0,
      message.UserMessage([message.UserText(text, None)], 0, None),
      False,
    )
  let assert Ok(_) =
    storage.commit(opened.store, tx.Tx([tx.InsertEntry(item)], []))
    as "conversation entry must commit"
  let assert Ok([stored]) =
    storage.scan_entries(opened.store, storage.entry_scan())
    as "fixture must read the stamped durable entry"
  #(distill.Source(id, path), stored, retire)
}

fn directory(lane) {
  let assert Ok(here) = simplifile.current_directory() as "cwd must resolve"
  let path = here <> "/build/test_db/shared-history-" <> lane
  let _ = simplifile.delete(path)
  assert simplifile.create_directory_all(path) == Ok(Nil)
  path
}
