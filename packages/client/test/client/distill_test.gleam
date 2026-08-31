//// The distillation pipeline, against real session files: the walk and
//// its lease-driven skip, the cursors, the two model turns, the write
//// order that makes a kill survivable, and the anti-feedback exclusion
//// asserted both on the pure input selector and end to end on the rows
//// the run produced.
////
//// Everything durable here is real — real SQLite session files, a real
//// memory session, a real digest sidecar on disk. What is scripted is
//// the provider, through the `Distiller` seam, and only the provider.

import client/distill
import client/memory
import client/rules
import core/clock
import core/entry.{type Entry}
import core/ids.{type EntryId}
import core/json
import core/message.{type AgentMessage}
import core/tx.{InsertEntry, Tx}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/secret
import session/repo
import session/session
import simplifile
import storage/storage
import tools/remember

// What the scripted consolidation turn answers with. The exit criterion
// downstream looks for this text, so it is stated once.
const consolidated = "preference: the user prefers tabs over spaces\n"
  <> "fact: the gate in this repository is make check"

const extracted = "fact: the release smoke boots with no erl on PATH"

// --- the whole pass ---------------------------------------------------------

/// One pass over a directory with one quiet source: walk, extract,
/// consolidate, append, CAS, render.
pub fn a_pass_distills_a_source_into_a_head_and_a_digest_test() {
  let root = fresh_root("pass")
  let named = write_source(root <> "/a.db", 11, [assistant("we chose msgpack")])
  let prompts = start_recorder()

  let assert Ok(report) = distill.run(config(root, prompts))
    as "the pass must run"
  assert report.sources == 1
  assert report.skipped == 0
  assert report.rows == 2

  // The head names the rows the consolidation turn produced, under the
  // pipeline's own types.
  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let assert Ok(rows) = memory.head_rows(opened) as "the head must read"
  let kinds = list.map(rows, fn(row) { row.kind })
  assert list.contains(kinds, memory.preference_type)
  assert list.contains(kinds, memory.fact_type)
  assert list.any(rows, fn(row) { string.contains(row.text, "tabs over") })

  // Provenance rides every row, naming the source session and the
  // entries it was distilled from.
  let assert Ok(stored) = raw_rows(opened) as "the raw rows must read"
  assert list.all(stored, fn(row) { string.contains(row, named) })

  // The cursor advanced under this source's own id, and the usage rows
  // for both turns landed in memory's own ledger.
  let assert Ok(Some(#(json.Object(_fields), _seq))) =
    memory.cell(opened, memory.cursor_key(named))
    as "the source's cursor must be written"
  assert usage_rows(opened) == 2
  memory.close(opened)

  // And the sidecar is the head, rendered.
  let assert Some(body) = memory.read_digest(root <> "/loom-memory.digest")
    as "the sidecar must exist after a pass"
  assert string.contains(body, "tabs over")
  assert string.contains(body, "(preference)")
  // The body carries no fence and no attribution: those are built at
  // injection time so the file cannot forge them.
  assert string.contains(body, memory.fence) == False
  assert string.contains(body, "heuristic context") == False

  // A second pass over an unchanged directory finds nothing new and
  // leaves the head where it is — the cursor is doing its job.
  let assert Ok(second) = distill.run(config(root, prompts))
    as "the second pass must run"
  assert second.sources == 0
}

/// A live session holds its own writer lease, so the pipeline's open
/// fails and that file is skipped. That is the entire "do not read a
/// session somebody is using" rule.
pub fn a_leased_source_is_skipped_test() {
  let root = fresh_root("leased")
  let _named = write_source(root <> "/live.db", 13, [assistant("in progress")])
  let prompts = start_recorder()

  // A live server: the lease is held for the length of the run.
  let assert Ok(live) =
    session.open_sqlite(
      path: root <> "/live.db",
      owner: "loom-server",
      lease_ttl_ms: 60_000,
      clock: a_clock(),
    )
    as "the live session must open"

  let assert Ok(report) = distill.run(config(root, prompts))
    as "the pass must run"
  assert report.sources == 0
  assert report.skipped == 1
  // Nothing was asked of the model, because nothing was harvested.
  assert recorded(prompts) == []

  let _closed = session.close(live)

  // Released, the same file is read on the next pass.
  let assert Ok(after) = distill.run(config(root, prompts))
    as "the second pass must run"
  assert after.sources == 1
  assert after.skipped == 0
}

// --- R10a: the kill point ---------------------------------------------------

/// **A run killed between the row append and the head CAS leaves the
/// previous head and the previous sidecar standing.**
///
/// Driven by phase, which is what `client/memory` splits
/// `append_distillates` from `advance_head` for: the rows land, and then
/// nothing else happens — exactly the state a `kill -9` between the two
/// commits leaves. The orphaned rows are asserted present *and* absent
/// from the head, because "inert" is the property, not "absent".
///
/// The mutation this is here to catch: move the head CAS into the row
/// append, or ahead of it. Then the head has already moved when the kill
/// lands, and the first assertion below fails.
pub fn a_kill_between_the_rows_and_the_head_leaves_both_standing_test() {
  let root = fresh_root("kill")
  let _named =
    write_source(root <> "/a.db", 11, [assistant("we chose msgpack")])
  let prompts = start_recorder()
  let assert Ok(_report) = distill.run(config(root, prompts))
    as "the first pass must run"

  let assert Ok(before) = open_memory(root) as "the memory session must open"
  let assert Ok(#(settled_head, _seq)) = memory.head(before)
    as "the head must read"
  memory.close(before)
  let assert Some(settled_digest) =
    memory.read_digest(root <> "/loom-memory.digest")
    as "the sidecar must exist"

  // The crash point: rows committed, and then the process is gone.
  let assert Ok(dying) = open_memory(root) as "the memory session must reopen"
  let assert Ok(#(orphans, _generator)) =
    memory.append_distillates(
      dying,
      [#(memory.fact_type, "a row from the run that died")],
      memory.Provenance(sources: [], derived_from: []),
      a_clock(),
    )
    as "the orphan rows must commit"
  memory.close(dying)

  // The old head still stands, and so does the old sidecar.
  let assert Ok(after) = open_memory(root) as "the memory session must reopen"
  let assert Ok(#(head_now, _seq)) = memory.head(after)
    as "the head must read back"
  assert head_now == settled_head
  assert memory.read_digest(root <> "/loom-memory.digest")
    == Some(settled_digest)

  // The orphans are durable and inert: present in the store, named by no
  // head, and therefore invisible to every reader.
  let assert [orphan] = orphans as "exactly one orphan row was written"
  let orphan_text = ids.entry_id_to_string(orphan)
  assert list.contains(head_now, orphan_text) == False
  let assert Ok(rows) = memory.head_rows(after) as "the head's rows must read"
  assert list.any(rows, fn(row) { string.contains(row.text, "run that died") })
    == False
  memory.close(after)
}

// --- R10c: the anti-feedback exclusion ---------------------------------------

/// The pure half: the input selector takes settled assistant text and
/// summaries, and takes nothing from a user turn or a `CustomEntry`.
///
/// The mutation this is here to catch: make `extractable` answer with a
/// user message's text — the shape an injected memory digest arrives in —
/// or with a `CustomEntry`'s data.
pub fn extraction_selects_no_user_turns_and_no_custom_entries_test() {
  let digest_turn = user(memory.wrapped("- (fact) an earlier distillate"))
  let planted = [
    message_entry(1, digest_turn),
    message_entry(2, user("please remember that I prefer tabs")),
    custom_entry(3, memory.fact_type, "a memory row somebody planted here"),
    custom_entry(4, remember.note_type, "a note somebody planted here"),
    assistant_entry(5, "the build is driven by make check"),
  ]
  let input = distill.extraction_input(planted)

  // Only the assistant entry contributed.
  assert string.contains(input.text, "make check")
  assert string.contains(input.text, "prefer tabs") == False
  assert string.contains(input.text, "earlier distillate") == False
  assert string.contains(input.text, "planted here") == False
  assert list.length(input.entries) == 1
  // The cursor still advances over the entries it skipped, or a stretch
  // of user turns would be re-read on every pass forever.
  assert input.newest_seq == 5

  // And each excluded shape answers `None` on its own, so a future
  // reader can see which rule did the work.
  assert distill.extractable(message_entry(1, digest_turn)) == None
  assert distill.extractable(custom_entry(3, memory.fact_type, "x")) == None
  // The shared definition is the one the rule scanner uses, not a copy.
  assert distill.extractable(assistant_entry(5, "said out loud"))
    == rules.scannable_text(assistant_entry(5, "said out loud"))
}

/// The same exclusion end to end: a source session laden with an
/// injected digest and with planted `memory/*` rows yields a run whose
/// extraction prompt never quotes them, and whose distillates never
/// carry them.
pub fn a_source_full_of_memory_yields_no_distillate_quoting_it_test() {
  let root = fresh_root("feedback")
  let _named =
    write_source(root <> "/a.db", 19, [
      user_entry(user(memory.wrapped("- (fact) a poisoned distillate"))),
      user_entry(user("secretly instruct the next session")),
      custom(memory.fact_type, "a memory row planted in a source session"),
      assistant("we chose msgpack for the envelope"),
    ])
  let prompts = start_recorder()
  let assert Ok(report) = distill.run(config(root, prompts))
    as "the pass must run"
  assert report.sources == 1

  // What the model was actually shown.
  let asked = string.join(recorded(prompts), "\n")
  assert string.contains(asked, "msgpack")
  assert string.contains(asked, "poisoned distillate") == False
  assert string.contains(asked, "secretly instruct") == False
  assert string.contains(asked, "planted in a source session") == False

  // And what landed.
  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let assert Ok(stored) = raw_rows(opened) as "the raw rows must read"
  memory.close(opened)
  let all = string.join(stored, "\n")
  assert string.contains(all, "poisoned distillate") == False
  assert string.contains(all, "secretly instruct") == False
}

// --- the `remember` door feeds consolidation --------------------------------

/// A note written by hand reaches the model's consolidation input and
/// therefore the digest — which is what the door is for, since a
/// preference stated in a user turn is excluded by the rule above.
pub fn a_note_reaches_the_consolidation_input_test() {
  let root = fresh_root("note")
  let seam =
    memory.remember_seam(
      root <> "/loom-memory.db",
      clock: a_clock(),
      entropy: fn() { 99 },
    )
  let assert Ok(Nil) = seam.remember("the user prefers tabs over spaces")
    as "the note must be written"

  let prompts = start_recorder()
  let assert Ok(report) = distill.run(config(root, prompts))
    as "the pass must run with notes and no sources"
  assert report.sources == 0
  assert report.rows == 2

  let asked = string.join(recorded(prompts), "\n")
  assert string.contains(asked, "Written down by hand")
  assert string.contains(asked, "prefers tabs over spaces")

  // The notes cursor moved, so the same note is not folded in twice.
  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let assert Ok(Some(#(json.Int(cursor), _seq))) =
    memory.cell(opened, memory.notes_cursor_key)
    as "the notes cursor must be written"
  assert cursor > 0
  memory.close(opened)
}

// --- a failed extraction claims nothing -------------------------------------

/// **A source whose extraction turn failed keeps its cursor and stays
/// out of the provenance of everything the run writes.**
///
/// Both halves are the finding. An advanced cursor would skip those
/// entries permanently and silently — the one loss the cursor exists to
/// prevent — and provenance naming a source that contributed nothing
/// over-claims, which is what issue #115's cascade would later act on by
/// over-deleting.
pub fn a_failed_extraction_advances_no_cursor_and_claims_no_provenance_test() {
  let root = fresh_root("halfread")
  let good =
    write_source(root <> "/good.db", 23, [assistant("we chose msgpack")])
  let bad = write_source(root <> "/bad.db", 29, [assistant("and cbor lost")])

  // The extraction turn for one source fails; the other, and the
  // consolidation, succeed.
  let assert Ok(report) =
    distill.run(
      distill.config_for(
        root,
        distill.Distiller(ask: fn(prompt) {
          case
            string.contains(prompt, "consolidating the durable memory"),
            string.contains(prompt, "cbor")
          {
            True, _ -> Ok(distill.Answer(text: consolidated, usage: usage(4)))
            False, True -> Error("the model refused this one")
            False, False -> Ok(distill.Answer(text: extracted, usage: usage(4)))
          }
        }),
        clock: a_clock(),
        entropy: fn() { 31 },
      ),
    )
    as "the pass must run"
  assert report.sources == 1
  assert report.skipped == 1

  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  // The source that answered advanced; the one that failed did not.
  let assert Ok(Some(#(_cursor, _seq))) =
    memory.cell(opened, memory.cursor_key(good))
    as "the source that answered must have a cursor"
  let assert Ok(None) = memory.cell(opened, memory.cursor_key(bad))
    as "the source whose extraction failed must have no cursor"

  // And no row claims the failed source.
  let assert Ok(stored) = raw_rows(opened) as "the raw rows must read"
  let all = string.join(stored, "\n")
  assert string.contains(all, good)
  assert string.contains(all, bad) == False
  memory.close(opened)

  // The proof that "no cursor" means "read again": a second run over the
  // same directory offers the failed source's entries once more.
  let prompts = start_recorder()
  let assert Ok(second) = distill.run(config(root, prompts))
    as "the second pass must run"
  assert second.sources == 1
  assert string.contains(string.join(recorded(prompts), "\n"), "cbor")
}

// --- a run with nothing to consolidate --------------------------------------

/// A repository whose sources are all read and all honestly answer
/// `nothing` records that it read them, dispatches no consolidation, and
/// leaves the head alone.
///
/// Without the cursors-only commit this run would reach the (correct)
/// empty-answer refusal, write nothing, and re-pay the same extraction
/// turn over the same entries on every run from then on.
pub fn a_run_that_extracts_nothing_still_advances_its_cursors_test() {
  let root = fresh_root("quiet")
  let named = write_source(root <> "/a.db", 37, [assistant("small talk")])
  let asked = start_recorder()
  let nothing =
    distill.Distiller(ask: fn(prompt) {
      record(asked, prompt)
      Ok(distill.Answer(text: "nothing", usage: usage(2)))
    })
  let assert Ok(report) =
    distill.run(
      distill.config_for(root, nothing, clock: a_clock(), entropy: fn() { 41 }),
    )
    as "the quiet pass must run"
  assert report.sources == 1
  assert report.candidates == 0

  // One turn only: the extraction. No consolidation was dispatched.
  let turns = recorded(asked)
  assert list.length(turns) == 1
  assert string.contains(
      string.join(turns, "\n"),
      "consolidating the durable memory",
    )
    == False

  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  // The cursor moved…
  let assert Ok(Some(#(_cursor, _seq))) =
    memory.cell(opened, memory.cursor_key(named))
    as "a read source's cursor must advance even when it yielded nothing"
  // …and the head did not.
  let assert Ok(#([], None)) = memory.head(opened)
    as "a quiet run must not write a head"
  memory.close(opened)

  // The second run finds nothing left to read, and asks nothing at all.
  let again = start_recorder()
  let assert Ok(second) =
    distill.run(
      distill.config_for(
        root,
        distill.Distiller(ask: fn(prompt) {
          record(again, prompt)
          Ok(distill.Answer(text: "nothing", usage: usage(2)))
        }),
        clock: a_clock(),
        entropy: fn() { 43 },
      ),
    )
    as "the second quiet pass must run"
  assert second.sources == 0
  assert recorded(again) == []
}

// --- the sidecar is reconciled, not only written ----------------------------

/// A sidecar that went missing after a successful run is restored by the
/// next run, even one with nothing to consolidate.
///
/// The gap this closes: the head CAS commits and the process dies before
/// the file is written. Nothing else would notice — every later run
/// reads the head, not the file — so a repository that then went quiet
/// would serve a stale digest to every session from then on.
pub fn a_missing_sidecar_is_restored_by_the_next_quiet_run_test() {
  let root = fresh_root("reconcile")
  let _named =
    write_source(root <> "/a.db", 47, [assistant("we chose msgpack")])
  let prompts = start_recorder()
  let assert Ok(_first) = distill.run(config(root, prompts))
    as "the first pass must run"
  let assert Some(settled) = memory.read_digest(root <> "/loom-memory.digest")
    as "the first pass must leave a digest"

  // The crash's residue: the head stands, the sidecar is gone.
  let assert Ok(Nil) = simplifile.delete(root <> "/loom-memory.digest")
    as "the sidecar must be removable"
  assert memory.read_digest(root <> "/loom-memory.digest") == None

  // A run with nothing whatever to do still puts it back.
  let assert Ok(report) = distill.run(config(root, prompts))
    as "the reconciling pass must run"
  assert report.sources == 0
  let assert Some(restored) = report.digest
    as "the run must rewrite the sidecar"
  assert restored > 0
  assert memory.read_digest(root <> "/loom-memory.digest") == Some(settled)

  // And a run over an already-correct sidecar rewrites nothing.
  let assert Ok(third) = distill.run(config(root, prompts))
    as "the third pass must run"
  assert third.digest == None
}

// --- the run's lease covers the run -----------------------------------------

// When a run begins, on the fixed clock the lease arithmetic is done
// against.
const run_began_at = 1_756_000_000_000

// How far into the run the interloper arrives: past the short per-call
// TTL, well inside the run-scale one.
const interloper_arrives_after = 60_000

/// **A distillation run's lease is not stolen while it waits on the
/// model.**
///
/// Nothing renews a lease but a commit through it, and a run's commits
/// are separated by provider turns. Under the short TTL the lease
/// expires during the first turn and the next opener to arrive — a
/// `remember` call, a second run — steals it with a bumped fence; the
/// run then loses its next commit to `LeaseLost` and throws away every
/// turn it has paid for.
///
/// Driven from inside the model turn itself, which is exactly the window
/// that matters, and on a fixed clock so the arithmetic is decided
/// rather than raced: the interloper carries a clock a minute ahead of
/// the run's own.
pub fn a_runs_lease_is_not_stolen_while_it_waits_on_the_model_test() {
  let root = fresh_root("lease")
  let _named =
    write_source(root <> "/a.db", 59, [assistant("we chose msgpack")])
  let arrivals = process.new_subject()
  let inside_the_turn =
    distill.Distiller(ask: fn(prompt) {
      // The opener that arrives while the run is thinking.
      process.send(arrivals, interloper(root))
      case string.contains(prompt, "consolidating the durable memory") {
        True -> Ok(distill.Answer(text: consolidated, usage: usage(3)))
        False -> Ok(distill.Answer(text: extracted, usage: usage(3)))
      }
    })
  let assert Ok(report) =
    distill.run(
      distill.Config(
        ..distill.config_for(
          root,
          inside_the_turn,
          clock: clock.fixed(at: run_began_at),
          entropy: fn() { 61 },
        ),
        clock: clock.fixed(at: run_began_at),
      ),
    )
    as "the run must survive an opener arriving mid-turn"
  assert report.rows == 2

  // Both turns had an interloper, and neither of them got in.
  let assert Ok(first) = process.receive(arrivals, within: 1000)
    as "the extraction turn's interloper must have reported"
  let assert Ok(second) = process.receive(arrivals, within: 1000)
    as "the consolidation turn's interloper must have reported"
  assert first == Refused
  assert second == Refused
}

/// What an opener arriving mid-run found.
type Arrival {
  /// `LeaseHeld`: the run still owns its file, which is the whole point.
  Refused
  /// The lease had expired and this opener took it — the run's next
  /// commit is now doomed.
  Stole
  /// Something else went wrong; never expected, and not silently a pass.
  Confused(reason: String)
}

fn interloper(root: String) -> Arrival {
  case
    memory.open(
      path: root <> "/loom-memory.db",
      owner: "interloper",
      lease_ttl_ms: memory.lease_ttl_ms,
      clock: clock.fixed(at: run_began_at + interloper_arrives_after),
      generator: ids.generator(a_clock(), seed: 67),
    )
  {
    Error(memory.MemoryHeld(..)) -> Refused
    Error(memory.MemoryFailed(reason:)) -> Confused(reason:)
    Ok(opened) -> {
      memory.close(opened)
      Stole
    }
  }
}

// --- cursors and dispatch ---------------------------------------------------

/// A rewrite renumbers every entry, so a cursor recorded under the old
/// generation is void and the source is read again from zero.
pub fn a_moved_generation_voids_the_cursor_test() {
  let stored = memory.cursor_value(memory.Cursor(seq: 40, generation: 2))
  assert memory.cursor_from(Some(stored), 2) == memory.Cursor(40, 2)
  assert memory.cursor_from(Some(stored), 3) == memory.Cursor(0, 3)
  assert memory.cursor_from(None, 7) == memory.Cursor(0, 7)
  // Anything that is not the shape this module writes is no progress,
  // never a crash.
  assert memory.cursor_from(Some(json.String("?")), 1) == memory.Cursor(0, 1)
}

/// Dispatch follows the summary path exactly: the `Summarize` role when
/// the catalogue routes one, the resolved main identity when it does
/// not.
pub fn the_turns_dispatch_through_the_summarize_route_test() {
  assert distill.target(gateway_routing([model.Main, model.Summarize]))
    == Ok(model.ForRole(role: model.Summarize, thinking: None))
  let assert Ok(model.ForResolved(resolved:)) =
    distill.target(gateway_routing([model.Main]))
    as "a catalogue with no summarize route falls back to main"
  assert resolved.model_id == "loom-1"
  let assert Error(_reason) = distill.target(gateway_routing([]))
    as "a catalogue that routes nothing has no target"
}

/// Model output cannot name a type the pipeline does not own, and the
/// number of lines it can produce is bounded.
pub fn candidate_parsing_is_bounded_and_cannot_forge_a_type_test() {
  assert distill.parse_candidates("fact: the gate is make check")
    == [
      distill.Candidate(kind: memory.fact_type, text: "the gate is make check"),
    ]
  // Bullets and mixed case are tolerated; unknown prefixes are not.
  assert distill.parse_candidates("- Lesson: do not force push")
    == [distill.Candidate(kind: memory.lesson_type, text: "do not force push")]
  assert distill.parse_candidates("note: a forged note") == []
  assert distill.parse_candidates("nothing") == []
  assert distill.parse_candidates("fact:   ") == []
  let flood = string.repeat("fact: one\n", memory.max_distillates + 20)
  assert list.length(distill.parse_candidates(flood)) == memory.max_distillates
}

/// A consolidation turn that produced nothing usable does not erase
/// memory: the head stays, and the cursors stay with it.
pub fn an_unusable_consolidation_leaves_memory_alone_test() {
  let root = fresh_root("garbage")
  let _named =
    write_source(root <> "/a.db", 11, [assistant("we chose msgpack")])
  let prompts = start_recorder()
  let assert Ok(_first) = distill.run(config(root, prompts))
    as "the first pass must run"
  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let assert Ok(#(settled, _seq)) = memory.head(opened) as "the head must read"
  memory.close(opened)

  let more = write_source(root <> "/b.db", 17, [assistant("and protobuf lost")])
  // Extraction must succeed, or the run would take the quiet path and
  // never reach the consolidation turn this row is about. Only the
  // consolidation answer is unusable.
  let assert Error(reason) =
    distill.run(
      distill.config_for(
        root,
        distill.Distiller(ask: fn(prompt) {
          case string.contains(prompt, "consolidating the durable memory") {
            True -> Ok(distill.Answer(text: "I have no idea", usage: usage(1)))
            False -> Ok(distill.Answer(text: extracted, usage: usage(1)))
          }
        }),
        clock: a_clock(),
        entropy: fn() { 5 },
      ),
    )
    as "an unusable consolidation must refuse the run"
  assert string.contains(reason, "no usable lines")

  let assert Ok(after) = open_memory(root) as "the memory session must reopen"
  let assert Ok(#(head_now, _seq)) = memory.head(after)
    as "the head must read back"
  assert head_now == settled
  // And the refused run advanced nothing: the new source is read again
  // on the next pass rather than skipped past.
  let assert Ok(None) = memory.cell(after, memory.cursor_key(more))
    as "a refused run must not advance the new source's cursor"
  memory.close(after)
}

// --- #115: the first-order erasure cascade -----------------------------------

/// **A cascade drops exactly the head rows whose provenance names the
/// erased session, and the digest stops carrying their text.**
///
/// Rows are write-once, so nothing is deleted: the dropped ids are still
/// readable in the store afterwards, and are inert only because the head
/// no longer names them — the same class of orphan a crashed
/// consolidation leaves, which is what `docs/spec-gaps.md` records.
///
/// The mutation this is here to catch: invert or remove the provenance
/// match in `memory.names_source`. Inverted, beta's row is dropped and
/// alpha's survive; removed, nothing is dropped at all.
pub fn a_cascade_drops_exactly_the_rows_naming_the_erased_session_test() {
  let root = fresh_root("cascade-drop")
  let #(alpha, beta) = mixed_head(root)
  let assert Some(before) = memory.read_digest(root <> "/loom-memory.digest")
    as "the mixed head must have rendered"
  assert string.contains(before, "make check")
  assert string.contains(before, "prefers tabs")

  let assert Ok(report) =
    distill.cascade(cascade_config(root), session: "alpha")
    as "the cascade must run"
  assert report.session == "alpha"
  assert report.dropped == 2
  assert report.kept == 1
  let assert Some(bytes) = report.digest
    as "the cascade must rewrite the sidecar"
  assert bytes > 0

  // The head is exactly beta's rows, in the order it held them.
  let assert Ok(opened) = open_memory(root) as "the memory session must reopen"
  let assert Ok(#(now, _seq)) = memory.head(opened) as "the head must read back"
  assert now == beta

  // The digest went with it.
  let assert Some(after) = memory.read_digest(root <> "/loom-memory.digest")
    as "the sidecar must survive a cascade"
  assert string.contains(after, "prefers tabs")
  assert string.contains(after, "make check") == False
  assert string.contains(after, "force push") == False

  // Nothing was deleted: the dropped rows are still in the store, still
  // carrying the provenance that got them dropped. A cascade edits a
  // pointer, and the store stays append-only.
  let assert Ok(orphans) = memory.provenance_by_id(opened, alpha)
    as "the dropped rows must still be readable by id"
  assert list.length(orphans) == 2
  assert list.all(orphans, fn(pair) { memory.names_source(pair.1, "alpha") })
  memory.close(opened)
}

/// A cascade over a session nothing names is a **true** no-op: the head
/// cell is not written at all, and the sidecar is byte-identical.
///
/// "Not written" is the property, which is why the cell's seq is asserted
/// rather than its value. CASing the identical id list back would still
/// bump that seq — a visible write, and one that would lose a concurrent
/// run's expectation for no reason whatever.
pub fn a_cascade_over_a_session_nothing_names_moves_nothing_test() {
  let root = fresh_root("cascade-noop")
  let named = write_source(root <> "/a.db", 11, [assistant("we chose msgpack")])
  let prompts = start_recorder()
  let assert Ok(_first) = distill.run(config(root, prompts))
    as "the pass must run"

  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let assert Ok(#(settled, Some(seq))) = memory.head(opened)
    as "the head must read"
  // The head does carry provenance, naming the real source — so the no-op
  // below is a match that failed, not an absence of anything to match.
  let assert Ok(pairs) = memory.provenance_by_id(opened, settled)
    as "the head's provenance must read"
  assert list.all(pairs, fn(pair) { memory.names_source(pair.1, named) })
  memory.close(opened)
  let assert Some(digest) = memory.read_digest(root <> "/loom-memory.digest")
    as "the pass must leave a digest"

  let assert Ok(report) =
    distill.cascade(cascade_config(root), session: "a-session-nothing-names")
    as "the cascade must run"
  assert report.dropped == 0
  assert report.kept == 2
  assert report.digest == None

  let assert Ok(after) = open_memory(root) as "the memory session must reopen"
  let assert Ok(#(now, Some(still))) = memory.head(after)
    as "the head must read back"
  assert now == settled
  assert still == seq
  memory.close(after)
  assert memory.read_digest(root <> "/loom-memory.digest") == Some(digest)
}

/// **The erase → cascade → re-distill loop.** After the source is
/// rewritten and the cascade has dropped what named it, the next run
/// re-extracts that source from zero — and does so because the *rewrite
/// generation* moved, not because the cascade reset anything.
///
/// Both halves are asserted, because the claim is about which mechanism
/// does the work: the cursor cell is unchanged after the cascade, and the
/// source is nonetheless read again from the beginning.
pub fn an_erase_then_cascade_re_extracts_the_source_on_the_next_run_test() {
  let root = fresh_root("cascade-erase")
  let named =
    write_source(root <> "/a.db", 11, [assistant("we chose msgpack here")])
  let prompts = start_recorder()
  let assert Ok(first) = distill.run(config(root, prompts))
    as "the first pass must run"
  assert first.rows == 2

  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let assert Ok(Some(#(recorded_cursor, _seq))) =
    memory.cell(opened, memory.cursor_key(named))
    as "the first pass must record a cursor"
  memory.close(opened)

  // The erase itself: the admin surface above the harness, rewriting the
  // source in place and bumping its rewrite generation.
  let assert Ok(rewritten) =
    repo.rewrite_sqlite(
      path: root <> "/a.db",
      clock: a_clock(),
      rewrite: repo.erase_text(needle: "msgpack", replacement: "[erased]"),
      rewrite_value: repo.erase_value(
        needle: "msgpack",
        replacement: "[erased]",
      ),
    )
    as "the source must be erasable"
  assert rewritten.generation > 0

  let assert Ok(report) = distill.cascade(cascade_config(root), session: named)
    as "the cascade must run"
  assert report.dropped == 2
  assert report.kept == 0

  let assert Ok(after) = open_memory(root) as "the memory session must reopen"
  let assert Ok(#([], Some(_seq))) = memory.head(after)
    as "every row named the erased source, so the head is empty"
  // The cascade moved no cursor: the cell is exactly what the run left.
  let assert Ok(Some(#(still, _cell))) =
    memory.cell(after, memory.cursor_key(named))
    as "the cursor must still be there"
  assert still == recorded_cursor
  memory.close(after)
  // An empty head renders an empty digest, so the sidecar reads as absent.
  assert memory.read_digest(root <> "/loom-memory.digest") == None

  // And the source is read again from zero, carrying the erased text.
  //
  // A fresh entropy seed, because this second run consolidates rather
  // than going quiet: the rig's clock and seed are fixed, so two
  // row-writing runs under one seed would mint one id twice and the
  // second would be refused as already written.
  let again = start_recorder()
  let assert Ok(second) =
    distill.run(distill.Config(..config(root, again), entropy: fn() { 4243 }))
    as "the second pass must run"
  assert second.sources == 1
  let asked = string.join(recorded(again), "\n")
  assert string.contains(asked, "[erased]")
  assert string.contains(asked, "msgpack") == False
}

/// **A cascade killed between the head CAS and the sidecar is reconciled
/// by the next run**, exactly as a consolidation killed there is.
///
/// A cascade writes no rows, so its whole write order is "CAS the head,
/// then render" — and the sidecar is again the one artifact that can be
/// left behind its head. Driven by phase: the head is replaced and then
/// nothing else happens, which is the state a `kill -9` in that window
/// leaves.
pub fn a_cascade_killed_before_the_sidecar_is_reconciled_by_the_next_run_test() {
  let root = fresh_root("cascade-kill")
  let #(_alpha, beta) = mixed_head(root)

  // The crash point: the head moves, and the process is gone.
  let assert Ok(dying) = open_memory(root) as "the memory session must reopen"
  let assert Ok(#(_named, seq)) = memory.head(dying) as "the head must read"
  let assert Ok(Nil) = memory.replace_head(dying, named: beta, expected: seq)
    as "the cascade's head CAS must land"
  memory.close(dying)

  // The sidecar is now behind its head, and nothing but a run would ever
  // notice: every reader goes through the head.
  let assert Some(stale) = memory.read_digest(root <> "/loom-memory.digest")
    as "the stale sidecar must still be there"
  assert string.contains(stale, "make check")

  // A run with nothing whatever to do puts it right.
  let prompts = start_recorder()
  let assert Ok(report) = distill.run(config(root, prompts))
    as "the reconciling pass must run"
  assert report.sources == 0
  let assert Some(rewritten) = report.digest
    as "the reconciling run must rewrite the sidecar"
  assert rewritten > 0
  assert recorded(prompts) == []
  let assert Some(now) = memory.read_digest(root <> "/loom-memory.digest")
    as "the sidecar must be restored"
  assert string.contains(now, "prefers tabs")
  assert string.contains(now, "make check") == False
}

/// **What an emptying cascade costs, pinned.** The head is uniform in
/// provenance, so a cascade naming any contributing source wipes it — and
/// the surviving sources are *not* re-read, because only the erased one's
/// cursor was voided. Their contribution, and every hand-written note
/// already folded in, is unrecoverable by the pipeline.
///
/// This records a defect, not an intention: issue #124 carries the
/// mechanism (a cursor rewind on drop, a `--rebuild` companion, or a
/// `--dry-run` preview). When one of those lands this test is the thing
/// that should fail, and its failure is the signal to rewrite it.
pub fn an_emptying_cascade_loses_the_surviving_sources_test() {
  let root = fresh_root("cascade-loss")
  let alpha =
    write_source(root <> "/a.db", 11, [assistant("alpha chose msgpack")])
  let beta = write_source(root <> "/b.db", 13, [assistant("beta chose cbor")])
  let seam =
    memory.remember_seam(
      root <> "/loom-memory.db",
      clock: a_clock(),
      entropy: fn() { 99 },
    )
  let assert Ok(Nil) = seam.remember("the user prefers tabs over spaces")
    as "the note must be written"

  let prompts = start_recorder()
  let assert Ok(first) = distill.run(config(root, prompts))
    as "the first pass must run"
  assert first.sources == 2
  // One head, one batch, one provenance value naming both sources.
  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let assert Ok(#(named, _seq)) = memory.head(opened) as "the head must read"
  let assert Ok(pairs) = memory.provenance_by_id(opened, named)
    as "the head's provenance must read"
  assert list.all(pairs, fn(pair) { memory.names_source(pair.1, alpha) })
  assert list.all(pairs, fn(pair) { memory.names_source(pair.1, beta) })
  memory.close(opened)

  // Erase beta, then cascade over it. Naming *either* source wipes the
  // whole head, because every row names both.
  let assert Ok(_rewritten) =
    repo.rewrite_sqlite(
      path: root <> "/b.db",
      clock: a_clock(),
      rewrite: repo.erase_text(needle: "cbor", replacement: "[erased]"),
      rewrite_value: repo.erase_value(needle: "cbor", replacement: "[erased]"),
    )
    as "beta must be erasable"
  let assert Ok(report) = distill.cascade(cascade_config(root), session: beta)
    as "the cascade must run"
  assert report.dropped == 2
  assert report.kept == 0

  // The next run re-reads beta and **only** beta.
  let again = start_recorder()
  let assert Ok(second) =
    distill.run(distill.Config(..config(root, again), entropy: fn() { 4243 }))
    as "the second pass must run"
  assert second.sources == 1
  let asked = string.join(recorded(again), "\n")
  assert string.contains(asked, "[erased]")
  // Alpha's transcript is never offered again: its cursor still sits at
  // the high-water seq the first run left, under an unmoved generation.
  assert string.contains(asked, "msgpack") == False
  // And the consolidation turn is shown an empty memory and no notes, so
  // neither alpha's contribution nor the note can come back through it.
  assert string.contains(
    asked,
    "What memory says now:\n\n```transcript\n(nothing)",
  )
  assert string.contains(
    asked,
    "Written down by hand with the remember tool:\n\n```transcript\n(nothing)",
  )
}

/// **A re-run cascade reports the sidecar it actually rewrote.** The
/// crash story routes through exactly this: the head CAS lands, the
/// process dies before the sidecar, and the operator runs the cascade
/// again. The second run drops nothing — the head is already correct —
/// but it still rewrites the digest, and reporting that as "unchanged"
/// would tell the operator the erased text was still on disk.
///
/// The mutation this is here to catch: collapse `reconcile_digest`'s
/// `Option(Int)` back to a byte count. `None` and `Some(0)` then read
/// alike and the first assertion below fails.
pub fn a_rerun_cascade_reports_the_sidecar_it_rewrote_test() {
  let root = fresh_root("cascade-rerun")
  let #(_alpha, beta) = mixed_head(root)

  // The crash: the head moves, the sidecar does not.
  let assert Ok(dying) = open_memory(root) as "the memory session must reopen"
  let assert Ok(#(_named, seq)) = memory.head(dying) as "the head must read"
  let assert Ok(Nil) = memory.replace_head(dying, named: beta, expected: seq)
    as "the cascade's head CAS must land"
  memory.close(dying)

  // The operator re-runs it. Nothing left to drop, but the sidecar is
  // still carrying alpha's text and this run is what removes it.
  let assert Ok(report) =
    distill.cascade(cascade_config(root), session: "alpha")
    as "the re-run cascade must run"
  assert report.dropped == 0
  let assert Some(bytes) = report.digest
    as "a cascade that rewrote the sidecar must say so, not report `None`"
  assert bytes > 0
  let assert Some(now) = memory.read_digest(root <> "/loom-memory.digest")
    as "the sidecar must be there"
  assert string.contains(now, "make check") == False
}

/// A cascade that empties the digest reports `Some(0)` — written, and
/// written to nothing — which is a different fact from `None`, the
/// sidecar it never touched.
pub fn an_emptying_cascade_reports_a_written_empty_digest_test() {
  let root = fresh_root("cascade-emptied")
  let #(alpha, _beta) = mixed_head(root)
  // Drop beta's row too, by hand, so only alpha's remain and a cascade
  // over alpha empties the head outright.
  let assert Ok(opened) = open_memory(root) as "the memory session must reopen"
  let assert Ok(#(_named, seq)) = memory.head(opened) as "the head must read"
  let assert Ok(Nil) = memory.replace_head(opened, named: alpha, expected: seq)
    as "the narrowed head must land"
  memory.close(opened)

  let assert Ok(report) =
    distill.cascade(cascade_config(root), session: "alpha")
    as "the cascade must run"
  assert report.kept == 0
  // Written, and written empty — not "unchanged".
  assert report.digest == Some(0)
  assert memory.read_digest(root <> "/loom-memory.digest") == None
}

/// A row whose provenance will not decode is **kept**, and the report
/// says so separately — that is the one place a cascade under-deletes,
/// and it is permanent, since no later cascade can reach the row either.
pub fn a_row_with_unreadable_provenance_is_kept_and_counted_test() {
  let root = fresh_root("cascade-unreadable")
  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let assert Ok(#(named_rows, generator)) =
    memory.append_distillates(
      opened,
      [#(memory.fact_type, "alpha said the gate is make check")],
      from_session("alpha"),
      a_clock(),
    )
    as "the named row must append"
  // A row this module did not write: the right entry type, a payload
  // `provenance_of` cannot read.
  let #(id, _generator) = ids.mint_entry(generator)
  let assert Ok(_committed) =
    storage.commit(
      opened.session.store,
      Tx(
        writes: [
          InsertEntry(entry.CustomEntry(
            id:,
            parent: None,
            seq: 0,
            ts: 0,
            custom_type: memory.fact_type,
            data: Some(
              json.Object([
                #("text", json.String("a row from somewhere else")),
                #("sources", json.String("not an array")),
              ]),
            ),
          )),
        ],
        expected: [],
      ),
    )
    as "the opaque row must commit"
  let assert Ok(#(head_now, head_seq)) = memory.head(opened)
    as "the head must read"
  assert head_now == []
  let assert Ok(Nil) =
    memory.replace_head(
      opened,
      named: list.append(list.map(named_rows, ids.entry_id_to_string), [
        ids.entry_id_to_string(id),
      ]),
      expected: head_seq,
    )
    as "the head over both rows must land"
  memory.close(opened)

  let assert Ok(report) =
    distill.cascade(cascade_config(root), session: "alpha")
    as "the cascade must run"
  assert report.dropped == 1
  assert report.kept == 1
  // The survivor is not an ordinary keep: it escaped the match because
  // its provenance would not decode, and the operator is told.
  assert report.unreadable == 1
}

// --- the rig ----------------------------------------------------------------

// A memory head built by hand from two batches with different
// provenance, its sidecar rendered, answering alpha's ids and beta's.
//
// A real consolidation never writes such a head: it replaces the head
// wholesale with the single batch it just appended, so every row in a
// live head shares one provenance value — which is also why a transitive
// pass over `derived_from` *within* the head is vacuous rather than
// merely deferred, since a batch's `derived_from` names the previous
// head's rows and none of those are in the new one. A cascade rewrites a
// pointer, though, and has to be right over any head the store can hold,
// so the mixed case is the one worth driving.
fn mixed_head(root: String) -> #(List(String), List(String)) {
  let assert Ok(opened) = open_memory(root) as "the memory session must open"
  let assert Ok(#(alpha, generator)) =
    memory.append_distillates(
      opened,
      [
        #(memory.fact_type, "alpha said the gate is make check"),
        #(memory.lesson_type, "alpha said do not force push"),
      ],
      from_session("alpha"),
      a_clock(),
    )
    as "alpha's rows must append"
  let assert Ok(#(beta, _generator)) =
    memory.append_distillates(
      memory.Opened(..opened, generator:),
      [#(memory.preference_type, "beta said the user prefers tabs")],
      from_session("beta"),
      a_clock(),
    )
    as "beta's rows must append"
  let assert Ok(Nil) =
    memory.advance_head(
      opened,
      ids: list.append(alpha, beta),
      expected: None,
      cursors: [],
    )
    as "the mixed head must land"
  let assert Ok(Some(_bytes)) =
    memory.reconcile_digest(opened, root <> "/loom-memory.digest")
    as "the sidecar must render the mixed head"
  memory.close(opened)
  #(
    list.map(alpha, ids.entry_id_to_string),
    list.map(beta, ids.entry_id_to_string),
  )
}

fn from_session(named: String) -> memory.Provenance {
  memory.Provenance(
    sources: [memory.SourceRef(session: named, entries: ["e1"])],
    derived_from: [],
  )
}

// A cascade dispatches no model turn, so it runs under the refusing
// distiller and no catalogue is involved anywhere.
fn cascade_config(root: String) -> distill.Config {
  distill.config_for(
    root,
    distill.no_distiller(),
    clock: a_clock(),
    entropy: fn() { 7 },
  )
}

fn config(root: String, prompts: Subject(Recorder)) -> distill.Config {
  distill.config_for(root, scripted(prompts), clock: a_clock(), entropy: fn() {
    4242
  })
}

// The scripted provider: it tells the two turns apart by the prompt the
// pipeline built, and records every prompt so a test can assert on what
// the model was shown rather than only on what came back.
fn scripted(prompts: Subject(Recorder)) -> distill.Distiller {
  distill.Distiller(ask: fn(prompt) {
    record(prompts, prompt)
    case string.contains(prompt, "consolidating the durable memory") {
      True -> Ok(distill.Answer(text: consolidated, usage: usage(11)))
      False -> Ok(distill.Answer(text: extracted, usage: usage(7)))
    }
  })
}

fn open_memory(root: String) -> Result(memory.Opened, memory.MemoryFault) {
  memory.open(
    path: root <> "/loom-memory.db",
    owner: "distill-test",
    lease_ttl_ms: memory.lease_ttl_ms,
    clock: a_clock(),
    generator: ids.generator(a_clock(), seed: 21),
  )
}

// Every `memory/*` row's stored JSON, as text — which is where
// provenance lives and where a leaked source string would show up.
fn raw_rows(opened: memory.Opened) -> Result(List(String), Nil) {
  case
    storage.scan_entries(
      opened.session.store,
      storage.entry_scan() |> storage.entry_kind(storage.Custom),
    )
  {
    Error(_unreadable) -> Error(Nil)
    Ok(found) ->
      Ok(
        list.filter_map(found, fn(item) {
          case item {
            entry.CustomEntry(data: Some(payload), ..) ->
              Ok(json.to_string(payload))
            _other -> Error(Nil)
          }
        }),
      )
  }
}

fn usage_rows(opened: memory.Opened) -> Int {
  case storage.scan_usage(opened.session.store, storage.usage_scan()) {
    Error(_unreadable) -> 0
    Ok(rows) -> list.length(rows)
  }
}

// One source session file with its own canonical id and the given
// entries, committed and closed. Returns the id, which is what a cursor
// is keyed by and what provenance names.
fn write_source(path: String, seed: Int, entries: List(Entry)) -> String {
  let assert Ok(opened) =
    session.open_sqlite(
      path:,
      owner: "distill-test-source",
      lease_ttl_ms: 60_000,
      clock: a_clock(),
    )
    as "the source session must open"
  let assert Ok(#(named, generator)) =
    session.ensure_id(opened, ids.generator(a_clock(), seed:))
    as "the source session must have an id"
  // Ids are minted here rather than by the builders, so two entries
  // built the same way in one file are still two rows.
  let #(stamped, _generator) =
    list.fold(entries, #([], generator), fn(carried, item) {
      let #(built, generator) = carried
      let #(id, generator) = ids.mint_entry(generator)
      #([with_id(item, id), ..built], generator)
    })
  let assert Ok(_committed) =
    storage.commit(
      opened.store,
      Tx(writes: list.map(list.reverse(stamped), InsertEntry), expected: []),
    )
    as "the source entries must commit"
  let _closed = session.close(opened)
  ids.session_id_to_string(named)
}

fn with_id(item: Entry, id: EntryId) -> Entry {
  case item {
    entry.MessageEntry(..) as row -> entry.MessageEntry(..row, id:)
    entry.CustomEntry(..) as row -> entry.CustomEntry(..row, id:)
    entry.CompactionEntry(..) as row -> entry.CompactionEntry(..row, id:)
    entry.BranchSummaryEntry(..) as row -> entry.BranchSummaryEntry(..row, id:)
  }
}

// --- entries ----------------------------------------------------------------

fn assistant(text: String) -> Entry {
  assistant_entry(0, text)
}

fn custom(kind: String, text: String) -> Entry {
  custom_entry(0, kind, text)
}

fn user_entry(said: AgentMessage) -> Entry {
  message_entry(0, said)
}

fn assistant_entry(seq: Int, text: String) -> Entry {
  message_entry(
    seq,
    message.AssistantMessage(
      content: [message.AssistantText(text:, text_signature: None)],
      api: "acme-api",
      provider: "acme",
      model: "loom-1",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: usage(1),
      stop_reason: message.Stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: Some(True),
      timestamp: 0,
    ),
  )
}

fn message_entry(seq: Int, said: AgentMessage) -> Entry {
  entry.MessageEntry(
    id: an_id(seq),
    parent: None,
    seq:,
    ts: 0,
    message: said,
    terminate: False,
  )
}

fn custom_entry(seq: Int, kind: String, text: String) -> Entry {
  entry.CustomEntry(
    id: an_id(seq + 1000),
    parent: None,
    seq:,
    ts: 0,
    custom_type: kind,
    data: Some(json.Object([#("text", json.String(text))])),
  )
}

fn an_id(seed: Int) -> ids.EntryId {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 1000 + seed), seed: seed + 1))
  id
}

fn user(text: String) -> AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

fn usage(tokens: Int) -> message.Usage {
  message.Usage(
    input: tokens,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: tokens,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

// --- the prompt recorder ----------------------------------------------------

/// What the scripted provider was asked, kept where the test process can
/// read it after the run — the assertion the anti-feedback row needs is
/// about the prompt, not about the answer.
type Recorder {
  Asked(prompt: String)
  Seen(reply_with: Subject(List(String)))
}

fn start_recorder() -> Subject(Recorder) {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(seen: List(String), message: Recorder) {
      case message {
        Asked(prompt:) -> actor.continue([prompt, ..seen])
        Seen(reply_with:) -> {
          process.send(reply_with, list.reverse(seen))
          actor.continue(seen)
        }
      }
    })
    |> actor.start
    as "the prompt recorder must start"
  started.data
}

fn record(prompts: Subject(Recorder), prompt: String) -> Nil {
  process.send(prompts, Asked(prompt:))
}

fn recorded(prompts: Subject(Recorder)) -> List(String) {
  process.call(prompts, waiting: 1000, sending: Seen)
}

// --- provider targets -------------------------------------------------------

fn gateway_routing(roles: List(model.Role)) -> provider_gateway.Gateway {
  let identity =
    model.ResolvedModel(
      provider: "acme",
      model_id: "loom-1",
      thinking: model.ThinkingOff,
      context_window: 100_000,
      max_output_tokens: 4096,
    )
  list.fold(
    roles,
    provider_gateway.new(
      transport: http.Transport(send_streaming: fn(_request, _subject) { Nil }),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 0),
    )
      |> provider_gateway.add_provider(provider_gateway.AnthropicProvider(
        name: "acme",
        base_url: "https://acme.invalid",
        api_key_secret: "ACME_KEY",
      )),
    fn(gateway, role) { provider_gateway.route(gateway, role, [identity]) },
  )
}

// --- small helpers ----------------------------------------------------------

fn a_clock() -> clock.Clock {
  clock.stepping(from: 1_756_000_000_000, by: 3)
}

fn fresh_root(lane: String) -> String {
  let root = "build/test_db/distill-" <> lane
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the test root must be creatable"
  let assert Ok(False) = simplifile.is_file(root <> "/loom-memory.db")
    as "the memory store must not survive from the last run"
  root
}
