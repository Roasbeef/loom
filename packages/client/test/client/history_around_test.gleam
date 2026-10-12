//// `history_search read around=N` over a real session file, through both
//// hosts of the recall seam: the per-session holder and the shared domain
//// owner. Each must answer the same window for the same request, so the
//// checks are written once, over a `read` closure, and run against both.
////
//// The same file holds the `memory.search_called` counter checks, since the
//// counter wraps both hosts' seams in one place.

import client/history
import client/internal/history_bridge
import client/internal/shared_history
import core/clock
import core/codec
import core/entry.{type Entry, MessageEntry}
import core/ids.{type EntryId, type SessionId}
import core/json.{type JsonValue}
import core/message.{UserMessage, UserText}
import core/tx
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session/session
import simplifile
import storage/storage
import support/addresses
import telemetry/field
import telemetry/level
import telemetry/log
import telemetry/record
import tools/history as tool

type Read =
  fn(SessionId, EntryId, Int) -> Result(List(JsonValue), tool.Refusal)

/// A session file with nine chained entries, the fifth of which is larger
/// than the 64 KiB the tool inlines.
type Fixture(handle) {
  Fixture(
    source: shared_history.Source,
    entries: List(Entry),
    store: storage.Storage(handle),
    retire: fn() -> Nil,
  )
}

const big_at = 4

// --- the per-session holder -------------------------------------------------

pub fn holder_reads_a_window_around_an_entry_test() {
  let root = directory("holder-window")
  let fixture = conversation(root <> "/a.db", 21)
  let #(stop, read) = holder_read(root, fixture)
  check_window(read, fixture)
  stop()
  retire(fixture)
}

pub fn holder_refuses_a_foreign_session_entry_test() {
  let root = directory("holder-foreign")
  let fixture = conversation(root <> "/a.db", 22)
  let other = conversation(root <> "/b.db", 23)
  let #(stop, read) = holder_read(root, fixture)
  check_foreign(read, fixture, other)
  stop()
  retire(fixture)
  retire(other)
}

// --- the shared domain owner ------------------------------------------------

pub fn shared_reads_a_window_around_an_entry_test() {
  let root = directory("shared-window")
  let fixture = conversation(root <> "/a.db", 31)
  let #(stop, read) = shared_read(root, [fixture], fixture)
  check_window(read, fixture)
  stop()
  retire(fixture)
}

pub fn shared_refuses_a_foreign_session_entry_test() {
  let root = directory("shared-foreign")
  let fixture = conversation(root <> "/a.db", 32)
  let other = conversation(root <> "/b.db", 33)
  let #(stop, read) = shared_read(root, [fixture, other], fixture)
  check_foreign(read, fixture, other)
  stop()
  retire(fixture)
  retire(other)
}

// A session outside the owner's current domain is refused for a window just
// as it is for a single entry, so `around` is no way to read past membership.
pub fn shared_refuses_a_window_outside_the_domain_test() {
  let root = directory("shared-outside")
  let fixture = conversation(root <> "/a.db", 34)
  let other = conversation(root <> "/b.db", 35)
  let #(stop, read) = shared_read(root, [fixture], fixture)
  let assert [first, ..] = other.entries
  let assert Error(tool.IndexRefused(_)) =
    read(other.source.session, first.id, 2)
    as "a session the domain no longer lists cannot be read around"
  stop()
  retire(fixture)
  retire(other)
}

// --- the shared checks ------------------------------------------------------

// The requested entry plus up to N neighbours each side, oldest first, the
// width clamped to 0..5, and `around` of zero the entry alone.
fn check_window(read: Read, fixture: Fixture(handle)) -> Nil {
  let session = fixture.source.session
  let encoded = list.map(fixture.entries, codec.encode_entry)

  let assert Ok(single) = read(session, id_at(fixture, 3), 0)
  assert single == [at(encoded, 3)]

  let assert Ok(window) = read(session, id_at(fixture, 3), 2)
  assert window == slice(encoded, 1, 5)

  // The first and last entries have no neighbours on one side, and the
  // window is simply shorter there.
  let assert Ok(head) = read(session, id_at(fixture, 0), 3)
  assert head == slice(encoded, 0, 3)
  let assert Ok(tail) = read(session, id_at(fixture, 8), 3)
  assert tail == slice(encoded, 5, 8)

  // Five is the most either side; more is clamped and a negative request
  // reads as none.
  let assert Ok(clamped) = read(session, id_at(fixture, 4), 99)
  assert clamped == slice(encoded, 0, 8)
  let assert Ok(negative) = read(session, id_at(fixture, 4), -3)
  assert negative == [at(encoded, 4)]

  // An entry larger than the tool inlines arrives whole as a neighbour, so
  // the tool's blob bound has the complete bytes to spill, and the centre
  // of a window can itself be the large one.
  let assert Ok(beside) = read(session, id_at(fixture, big_at - 1), 1)
  assert beside == slice(encoded, big_at - 2, big_at)
  assert string.byte_size(json.to_string(at(encoded, big_at))) > 65_536
  let assert Ok(centred) = read(session, id_at(fixture, big_at), 1)
  assert centred == slice(encoded, big_at - 1, big_at + 1)
  Nil
}

// An entry that belongs to another session is not reachable by naming this
// one, and a window around it is refused like the entry itself.
fn check_foreign(
  read: Read,
  fixture: Fixture(handle),
  other: Fixture(other_handle),
) -> Nil {
  let assert [stranger, ..] = other.entries
  let assert Error(tool.IndexRefused(_)) =
    read(fixture.source.session, stranger.id, 0)
    as "a foreign entry must be refused alone"
  let assert Error(tool.IndexRefused(_)) =
    read(fixture.source.session, stranger.id, 2)
    as "a foreign entry must be refused with its window"
  Nil
}

fn id_at(fixture: Fixture(handle), index: Int) -> EntryId {
  let assert Ok(found) = list.drop(fixture.entries, index) |> list.first
  found.id
}

fn at(values: List(JsonValue), index: Int) -> JsonValue {
  let assert Ok(found) = list.drop(values, index) |> list.first
  found
}

// Positions `from` through `to`, inclusive.
fn slice(values: List(JsonValue), from: Int, to: Int) -> List(JsonValue) {
  values |> list.drop(from) |> list.take(to - from + 1)
}

// --- the search counter -----------------------------------------------------

// The line names the scope and the counts and never the words searched for.
pub fn the_counter_logs_scope_and_counts_but_not_the_query_test() {
  let root = directory("counter")
  let fixture = conversation(root <> "/a.db", 41)
  let records = process.new_subject()
  let logger = log.new(sink: log.to_subject(records), threshold: level.Info)
  let prepared = prepare(root, [fixture])
  let assert Ok(shared) = prepared.begin()
  let seam =
    history.seam_for_with_logger(shared, fixture.source.session, logger)

  let assert Ok(hits) =
    seam.search(tool.query("secretword", 10, tool.ThisSession))
  assert list.length(hits) == 8
  let assert Ok(seen) = process.receive(records, 1000)
  assert seen.event == "memory.search_called"
  assert seen.level == level.Info
  assert seen.fields
    == [
      field.text(key: "scope", value: "this_session"),
      field.count(key: "hits", value: 8),
      field.count(key: "note_hits", value: 0),
    ]
  assert !string.contains(record.render(seen), "secretword")

  let assert Ok(_) = seam.search(tool.query("secretword", 10, tool.Repository))
  let assert Ok(again) = process.receive(records, 1000)
  assert list.contains(
    again.fields,
    field.text(key: "scope", value: "repository"),
  )

  // A browse is a recall call too, and it is always this session's.
  let assert Ok(_) = seam.recent(5)
  let assert Ok(browse) = process.receive(records, 1000)
  assert list.contains(
    browse.fields,
    field.text(key: "scope", value: "this_session"),
  )

  assert prepared.retire() == Ok(Nil)
  retire(fixture)
}

// Notes are indexed by another slice, so the count is shown here over a seam
// that already returns them. A refused call has no result count and writes
// nothing.
pub fn the_counter_counts_note_hits_and_skips_refusals_test() {
  let records = process.new_subject()
  let logger = log.new(sink: log.to_subject(records), threshold: level.Info)
  let note = tool.Hit("s", "e", "note", 0, "a [note]")
  let user = tool.Hit("s", "f", "user", 0, "a [user]")
  let stub =
    tool.History(
      search: fn(query) {
        case query.text {
          "refused" -> Error(tool.IndexRefused("no"))
          _ -> Ok([note, user, note])
        }
      },
      recent: fn(_) { Ok([]) },
      read: fn(_, _, _) { Ok([]) },
    )
  let seam = history_bridge.counted(stub, logger)

  let assert Error(_) = seam.search(tool.query("refused", 10, tool.Repository))
  let assert Ok(_) = seam.search(tool.query("found", 10, tool.Repository))
  let assert Ok(seen) = process.receive(records, 1000)
  assert seen.fields
    == [
      field.text(key: "scope", value: "repository"),
      field.count(key: "hits", value: 3),
      field.count(key: "note_hits", value: 2),
    ]
  let assert Error(Nil) = process.receive(records, 50)
}

// --- rigs -------------------------------------------------------------------

// A holder over the fixture's real session file, registered as the exact-read
// source the way `client/serve` registers it.
fn holder_read(root: String, fixture: Fixture(handle)) -> #(fn() -> Nil, Read) {
  let name = addresses.new()
  let path = fixture.source.path
  let assert Ok(_started) =
    history.start(
      history.over_session(
        name:,
        path: root <> "/search.db",
        session: fixture.source.session,
        store: fixture.store,
        generation: history.sqlite_generation(path),
        timeout_ms: 5000,
      )
      |> history.with_source(path),
    )
    as "the holder must start"
  let assert Ok(Nil) = history.synchronize(name, timeout_ms: 5000)
    as "the holder must register the session file"
  let seam = history.seam(name, timeout_ms: 5000)
  #(fn() { history.stop(name) }, seam.read)
}

fn prepare(root: String, sources: List(Fixture(handle))) {
  let listed = list.map(sources, fn(fixture) { fixture.source })
  let assert Ok(prepared) =
    history.prepare_shared(history.SharedConfig(
      root <> "/search.db",
      fn() { Ok(listed) },
      1000,
      10,
    ))
    as "the shared owner must prepare"
  prepared
}

fn shared_read(
  root: String,
  sources: List(Fixture(handle)),
  current: Fixture(handle),
) -> #(fn() -> Nil, Read) {
  let prepared = prepare(root, sources)
  let assert Ok(shared) = prepared.begin() as "the shared owner must begin"
  let seam = history.seam_for(shared, current.source.session)
  #(
    fn() {
      let assert Ok(Nil) = prepared.retire() as "the shared owner must retire"
      Nil
    },
    seam.read,
  )
}

// --- fixtures ---------------------------------------------------------------

fn retire(fixture: Fixture(handle)) -> Nil {
  fixture.retire()
}

fn conversation(path: String, seed: Int) {
  let clock = clock.fixed(1000)
  let assert Ok(#(opened, retire)) =
    session.open_sqlite_owned(
      path:,
      owner: "history-around-test",
      lease_ttl_ms: 60_000,
      clock:,
    )
    as "the conversation must open"
  let assert Ok(#(id, generator)) =
    session.ensure_id(opened, ids.generator(clock, seed))
    as "the conversation must publish its identity"
  let _ = chain(opened.store, generator, None, 0)
  let assert Ok(stored) =
    storage.scan_entries(opened.store, storage.entry_scan())
    as "the fixture must read its stamped entries"
  Fixture(shared_history.Source(id, path), stored, opened.store, fn() {
    let assert Ok(Nil) = retire() as "the session file must close"
    Nil
  })
}

// Nine chained user messages; the one at `big_at` is far larger than the
// tool's inline limit, and the rest carry the word the counter test searches.
fn chain(
  store: storage.Storage(handle),
  generator: ids.Generator,
  parent: Option(EntryId),
  index: Int,
) -> Nil {
  case index {
    9 -> Nil
    _ -> {
      let #(id, generator) = ids.mint_entry(generator)
      let text = case index == big_at {
        True -> "bulky " <> string.repeat("x", 70_000)
        False -> "entry " <> string.inspect(index) <> " secretword"
      }
      let item =
        MessageEntry(
          id:,
          parent:,
          seq: 0,
          ts: 0,
          message: UserMessage([UserText(text, None)], 0, None),
          terminate: False,
        )
      let assert Ok(_) =
        storage.commit(store, tx.Tx([tx.InsertEntry(item)], []))
        as "the fixture entry must commit"
      chain(store, generator, Some(id), index + 1)
    }
  }
}

fn directory(lane: String) -> String {
  let assert Ok(here) = simplifile.current_directory() as "cwd must resolve"
  let path = here <> "/build/test_db/history-around-" <> lane
  let _ = simplifile.delete(path)
  assert simplifile.create_directory_all(path) == Ok(Nil)
  path
}
