//// Bounded snapshot reader contracts shared by memory and real SQLite.
//// These prove storage cuts and byte transfer, not WebSocket peer convergence.

import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/register
import core/tx
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import sqlight
import storage/internal/snapshot_call
import storage/memory
import storage/session_schema
import storage/snapshot
import storage/sql
import storage/sqlite
import storage/storage
import support/fixtures

// How long an outcome test waits for the reader's answer. These tests assert
// what a read returns (a cut, a page, a typed refusal), never how fast, so the
// wait is set to what only a hung reader would exceed. A wait near the read's
// real cost turned a budget refusal into `ReadTimedOut` on a loaded machine:
// `reference_expansion_spends_the_same_metadata_budget_test` writes and expands
// 1024 references and once ran past a one-second wait. Timing itself is pinned
// by `timed_out_reads_remain_queued_and_late_replies_are_isolated_test`, which
// suspends the reader rather than racing it, and keeps its own short waits.
const answer_wait_ms = 60_000

type Backend {
  Memory
  Sqlite
}

type Fixture {
  Fixture(
    reader: snapshot.Reader,
    commit: fn(tx.Tx) -> Result(tx.CommitResult, tx.CommitError),
    close: fn() -> Result(Nil, storage.StorageError),
    pid: process.Pid,
  )
}

fn open(backend: Backend, name: String) -> Fixture {
  case backend {
    Memory -> {
      let assert Ok(store) = memory.open(clock.fixed(1000)) as "memory opens"
      wrap(store, memory.snapshot_reader(store.handle))
    }
    Sqlite -> {
      let assert Ok(store) =
        sqlite.open(
          sqlite.config(path(name), "snapshot-writer"),
          clock.fixed(1000),
        )
        as "SQLite opens"
      wrap(store, sqlite.snapshot_reader(store.handle))
    }
  }
}

fn wrap(
  store: storage.Storage(process.Subject(message)),
  reader: snapshot.Reader,
) -> Fixture {
  let assert Ok(pid) = process.subject_owner(store.handle)
    as "the concrete backend subject has a live owner"
  Fixture(
    reader,
    fn(transaction) { storage.commit(store, transaction) },
    fn() { storage.close(store) },
    pid,
  )
}

pub fn timed_out_reads_remain_queued_and_late_replies_are_isolated_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "timeout")
    let plan = snapshot.Plan([], [], 0)
    let #(entry, _) = fixtures.message_entry(fixtures.new_ctx(), None, "entry")
    let descriptor = snapshot.Descriptor(entry.id, 1, 1)
    let assert Ok(_) = fixture.reader.capture(plan, 1000)
      as "startup traffic settles before the actor is suspended"
    let original_monitors = monitor_count()
    let original_replies = mailbox_length(process.self())
    let assert True = suspend_process(fixture.pid) as "pause the original actor"
    let original_queue = mailbox_length(fixture.pid)

    // Expired budgets enqueue nothing. Finite waits leave exactly one request
    // each, because timing out is not removal from the backend's mailbox.
    let expired_capture = fixture.reader.capture(plan, 0)
    let expired_page = fixture.reader.page(0, 2, 1, -1)
    let expired_fragment = fixture.reader.fragment(descriptor, 0, 0)
    let expired_queue = mailbox_length(fixture.pid)
    let capture = fixture.reader.capture(plan, 20)
    let page = fixture.reader.page(0, 2, 1, 20)
    let fragment = fixture.reader.fragment(descriptor, 0, 20)
    let queued = mailbox_length(fixture.pid)
    let monitors = monitor_count()
    let assert True = resume_process(fixture.pid)
      as "release the original actor"

    // Reading again demonstrates that timeout did not cancel actor work, and
    // that it did not make the reader unusable. This page's reply differs
    // from the queued capture and missing fragment, so a late reply cannot
    // silently satisfy the new exchange. A caller that does not want the late
    // replies in its own mailbox asks from a process that exits first.
    let later = fixture.reader.page(0, 2, 1, 1000)
    let late_replies = mailbox_length(process.self())
    let closed = fixture.close()
    assert expired_capture == Error(snapshot.InvalidRequest)
    assert expired_page == Error(snapshot.InvalidRequest)
    assert expired_fragment == Error(snapshot.InvalidRequest)
    assert expired_queue == original_queue
    assert capture == Error(snapshot.ReadTimedOut)
    assert page == Error(snapshot.ReadTimedOut)
    assert fragment == Error(snapshot.ReadTimedOut)
    assert queued == original_queue + 3
    assert monitors == original_monitors
    assert later == Ok([])
    assert late_replies == original_replies + 3
    assert closed == Ok(Nil)
  })
}

pub fn dead_reader_returns_total_unavailable_for_every_operation_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "dead-reader")
    let assert Ok(Nil) = fixture.close()
      as "close the connection before killing"
    let monitor = process.monitor(fixture.pid)
    let departed =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(_down) { Nil })
    process.unlink(fixture.pid)
    process.kill(fixture.pid)
    let assert Ok(Nil) = process.selector_receive(departed, 1000)
      as "the original backend must exit"
    let #(entry, _) = fixtures.message_entry(fixtures.new_ctx(), None, "entry")
    assert fixture.reader.capture(snapshot.Plan([], [], 0), answer_wait_ms)
      == Error(snapshot.ReaderUnavailable)
    assert fixture.reader.page(0, 2, 1, answer_wait_ms)
      == Error(snapshot.ReaderUnavailable)
    assert fixture.reader.lineage(entry.id, 2, 1, answer_wait_ms)
      == Error(snapshot.ReaderUnavailable)
    assert fixture.reader.fragment(
        snapshot.Descriptor(entry.id, 1, 1),
        0,
        answer_wait_ms,
      )
      == Error(snapshot.ReaderUnavailable)
  })
}

pub fn recipient_death_during_exchange_returns_unavailable_test() {
  let handoff = process.new_subject()
  let _recipient =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      process.send(handoff, subject)
      let assert Ok(Nil) = process.receive(subject, 1000)
        as "the request must arrive before the recipient exits without replying"
    })
  let assert Ok(subject) = process.receive(handoff, 1000)
    as "the recipient publishes its live mailbox"
  let original_monitors = monitor_count()
  let answer: Result(Nil, snapshot.Error) =
    snapshot_call.read(subject, waiting: 1000, sending: fn(_reply) { Nil })
  assert answer == Error(snapshot.ReaderUnavailable)
  assert monitor_count() == original_monitors
}

fn mailbox_length(pid: process.Pid) -> Int {
  let assert Ok(size) =
    decode.run(
      process_info(pid, atom.create("message_queue_len")),
      decode.at([1], decode.int),
    )
    as "the live process reports its queue length"
  size
}

fn monitor_count() -> Int {
  let assert Ok(monitors) =
    decode.run(
      process_info(process.self(), atom.create("monitors")),
      decode.at([1], decode.list(decode.dynamic)),
    )
    as "the calling process reports its monitors"
  list.length(monitors)
}

@external(erlang, "erlang", "process_info")
fn process_info(pid: process.Pid, item: atom.Atom) -> Dynamic

@external(erlang, "erlang", "suspend_process")
fn suspend_process(pid: process.Pid) -> Bool

@external(erlang, "erlang", "resume_process")
fn resume_process(pid: process.Pid) -> Bool

fn path(name: String) -> String {
  let assert Ok(Nil) = simplifile.create_directory_all("build/test_db")
    as "test directory exists"
  let path = "build/test_db/snapshot-" <> name <> ".db"
  let _removed = simplifile.delete(path)
  let _removed_wal = simplifile.delete(path <> "-wal")
  let _removed_shm = simplifile.delete(path <> "-shm")
  path
}

fn all(namespace: register.RegisterNs) -> snapshot.Selection {
  snapshot.Selection(namespace, "", snapshot.All)
}

fn write(fixture: Fixture, writes: List(tx.Write)) -> tx.CommitResult {
  let assert Ok(committed) = fixture.commit(tx.Tx(writes, []))
    as "fixture commit succeeds"
  committed
}

pub fn exact_key_capture_excludes_prefix_neighbors_and_omits_missing_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "exact-keys")
    let _committed =
      write(fixture, [
        tx.SetRegister(
          register.FactCustom,
          "escalation/id",
          register.value(json.String("resolved")),
        ),
        tx.SetRegister(
          register.FactCustom,
          "escalation/id-neighbor",
          register.value(json.String("pending")),
        ),
        tx.SetRegister(
          register.FactName,
          "escalation/id",
          register.value(json.String("other namespace")),
        ),
      ])
    let exact = snapshot.ExactKey(register.FactCustom, "escalation/id")
    let plan =
      snapshot.Plan(
        [
          exact,
          exact,
          snapshot.ExactKey(register.FactCustom, "escalation/missing"),
        ],
        [],
        0,
      )
    let assert Ok(cut) = fixture.reader.capture(plan, answer_wait_ms)
      as "exact keys use the same coherent bounded cut"
    let assert [cell] = cut.cells
      as "duplicate selections union and missing keys are omitted"
    assert cell.namespace == register.FactCustom
    assert cell.key == "escalation/id"
    assert cell.register.value.payload == json.String("resolved")
    assert cut.recent == []
    assert fixture.close() == Ok(Nil)
  })
}

// Keys chosen around the boundaries a key range gets wrong when its upper bound
// is computed carelessly: the prefix itself, the prefix with a following byte
// below and above the separator, the code point just under the UTF-16 surrogate
// block, and the maximum code point, which has no successor at all.
const boundary_keys = [
  "client", "client.", "client/", "client/\u{0}", "client/a", "client/z",
  "client0", "clients", "runtime/a", "\u{D7FF}", "\u{D7FF}z", "\u{E000}",
  "\u{10FFFF}", "\u{10FFFF}a",
]

pub fn prefix_selection_is_a_key_range_over_the_same_members_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "prefix-range")
    let _committed =
      write(
        fixture,
        list.map(boundary_keys, fn(key) {
          tx.SetRegister(
            register.FactCustom,
            key,
            register.value(json.String(key)),
          )
        }),
      )

    // The SQLite backend answers a prefix with an index range, the memory
    // backend with a literal starts_with. Both must select exactly the keys
    // carrying the prefix, including for the two prefixes with no successor:
    // the empty one and the one made of the maximum code point.
    list.each(["client/", "clientz", "\u{D7FF}", "\u{10FFFF}", ""], fn(prefix) {
      let selection =
        snapshot.Selection(register.FactCustom, prefix, snapshot.All)
      let assert Ok(cut) =
        fixture.reader.capture(
          snapshot.Plan([selection], [], 0),
          answer_wait_ms,
        )
        as "a bounded prefix selection is readable"
      let selected =
        cut.cells
        |> list.map(fn(cell) { cell.key })
        |> list.sort(string.compare)
      let carrying =
        boundary_keys
        |> list.filter(string.starts_with(_, prefix))
        |> list.sort(string.compare)
      assert selected == carrying
    })
    assert fixture.close() == Ok(Nil)
  })
}

pub fn prefix_header_plan_is_an_index_range_not_a_namespace_scan_test() {
  let assert Ok(conn) = sqlight.open(path("prefix-plan"))
    as "plan fixture opens"
  assert sqlight.exec(session_schema.schema, on: conn) == Ok(Nil)
  let #(statement, _params, _decoder) =
    sql.snapshot_register_headers("", "", "", "", "")
  let assert Ok(plan) =
    sqlight.query(
      "EXPLAIN QUERY PLAN " <> statement,
      on: conn,
      with: list.repeat(sqlight.text(""), 5),
      expecting: decode.at([3], decode.string),
    )
    as "SQLite explains the generated header query"

  // The bounds are what keeps a client attach off a namespace-wide scan, and
  // with them the per-row JSON predicate only runs inside the prefix window.
  // A plan without the upper bound still returns the right rows, so only this
  // assertion notices if the range decays back into a filter.
  assert list.any(plan, string.contains(_, "SEARCH registers"))
  assert list.any(plan, string.contains(_, "key>? AND key<?"))
  assert sqlight.close(conn) == Ok(Nil)
}

pub fn exact_key_preflight_refuses_before_fetch_and_never_scans_prefix_test() {
  let fetched = process.new_subject()
  let source =
    snapshot.Source(
      headers: fn(_, _, _) {
        process.send(fetched, "prefix")
        Error(snapshot.InvalidRequest)
      },
      page_headers: fn(_, _, _, _) {
        process.send(fetched, "page")
        Error(snapshot.InvalidRequest)
      },
      header: fn(namespace, key) {
        process.send(fetched, "header")
        Ok(snapshot.Header(namespace, key, 1, snapshot.metadata_bytes_limit + 1))
      },
      cell: fn(_) {
        process.send(fetched, "payload")
        Error(snapshot.InvalidRequest)
      },
    )
  let plan = snapshot.Plan([snapshot.ExactKey(register.FactCustom, "x")], [], 0)
  assert snapshot.collect(plan, source, 0) == Error(snapshot.MetadataTooLarge)
  assert process.receive(fetched, 0) == Ok("header")
  assert process.receive(fetched, 0) == Error(Nil)

  // An oversized key is caller-owned metadata too. Reject it before asking
  // either backend to bind a query or allocate an encoded payload.
  let huge =
    snapshot.Plan(
      [
        snapshot.ExactKey(
          register.FactCustom,
          string.repeat("x", snapshot.metadata_bytes_limit),
        ),
      ],
      [],
      0,
    )
  assert snapshot.collect(huge, source, 0) == Error(snapshot.MetadataTooLarge)
  assert process.receive(fetched, 0) == Error(Nil)
}

pub fn sqlite_exact_key_oversize_refuses_before_json_decode_test() {
  let fixture = open(Sqlite, "exact-oversized")
  let _committed =
    write(fixture, [
      tx.SetRegister(register.FactCustom, "exact", register.value(json.Null)),
    ])
  let assert Ok(conn) =
    sqlight.open("build/test_db/snapshot-exact-oversized.db")
    as "independent test corruption connection"
  assert sqlight.exec("UPDATE registers SET value=zeroblob(1048577)", on: conn)
    == Ok(Nil)
  assert fixture.reader.capture(
      snapshot.Plan([snapshot.ExactKey(register.FactCustom, "exact")], [], 0),
      answer_wait_ms,
    )
    == Error(snapshot.MetadataTooLarge)
  assert sqlight.close(conn) == Ok(Nil)
  assert fixture.close() == Ok(Nil)
}

pub fn recent_window_and_sparse_continuation_are_immutable_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "recent")
    let #(_, entries) =
      list.map_fold(range(1, 205), fixtures.new_ctx(), fn(ctx, n) {
        let #(entry, ctx) = fixtures.message_entry(ctx, None, int.to_string(n))
        #(ctx, entry)
      })
    let _committed =
      write(
        fixture,
        list.flat_map(entries, fn(entry) {
          [
            tx.InsertEntry(entry),
            tx.SetRegister(
              register.StrandLeaf,
              "main",
              register.leaf_value(Some(entry.id)),
            ),
          ]
        }),
      )
    let plan = snapshot.Plan([all(register.StrandLeaf)], [], 50)
    let assert Ok(cut) = fixture.reader.capture(plan, answer_wait_ms)
      as "coherent initial window"
    assert cut.next_seq == 411
    assert cut.stats.message_count == 205
    assert list.length(cut.recent) == 50
    assert list.map(cut.recent, fn(item) { item.seq })
      == list.map(range(156, 205), fn(n) { 2 * n - 1 })

    // A later entry and mutable leaf cannot change the captured inventory.
    let #(later, _) = fixtures.message_entry(fixtures.new_ctx(), None, "later")
    let assert entry.MessageEntry(..) = later as "fixture is a message entry"
    let #(new_id, _) = ids.mint_entry(ids.generator(clock.fixed(9000), 52))
    let later = entry.MessageEntry(..later, id: new_id)
    let _committed =
      write(fixture, [
        tx.InsertEntry(later),
        tx.SetRegister(
          register.StrandLeaf,
          "main",
          register.leaf_value(Some(later.id)),
        ),
      ])
    let pages = inventory(fixture.reader, 0, cut.next_seq, [])
    assert list.length(pages) == 205
    assert !list.any(pages, fn(item) { item.id == later.id })
    assert fixture.reader.page(409, cut.next_seq, 7, answer_wait_ms) == Ok([])
    assert fixture.close() == Ok(Nil)
  })
}

fn inventory(
  reader: snapshot.Reader,
  after: Int,
  before: Int,
  reversed: List(snapshot.Descriptor),
) -> List(snapshot.Descriptor) {
  let assert Ok(page) = reader.page(after, before, 7, answer_wait_ms)
    as "bounded next page"
  assert list.length(page) <= 7
  case page {
    [] -> list.reverse(reversed)
    [_, ..] -> {
      let assert Ok(last) = list.last(page) as "nonempty page has a last item"
      inventory(
        reader,
        last.seq,
        before,
        list.append(list.reverse(page), reversed),
      )
    }
  }
}

pub fn capture_metadata_stats_and_high_water_share_one_commit_cut_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "concurrent-cut")
    let done = process.new_subject()
    let _writer =
      process.spawn(fn() {
        let _ctx =
          list.fold(range(1, 100), fixtures.new_ctx(), fn(ctx, n) {
            let #(entry, ctx) = fixtures.message_entry(ctx, None, "entry")
            let _committed =
              write(fixture, [
                tx.InsertEntry(entry),
                tx.SetRegister(
                  register.FactName,
                  "count",
                  register.value(json.Int(n)),
                ),
              ])
            ctx
          })
        process.send(done, Nil)
      })
    list.each(range(1, 100), fn(_) {
      let assert Ok(cut) =
        fixture.reader.capture(
          snapshot.Plan([all(register.FactName)], [], 0),
          answer_wait_ms,
        )
        as "capture while writer runs"
      assert cut.next_seq == cut.stats.message_count * 2 + 1
      case cut.cells {
        [] -> {
          assert cut.stats.message_count == 0
        }
        [cell] -> {
          assert cell.register.value.payload
            == json.Int(cut.stats.message_count)
          assert cell.register.seq == cut.next_seq - 1
        }
        [_, _, ..] -> panic as "only the count cell is selected"
      }
    })
    assert process.receive(done, 5000) == Ok(Nil)
    assert fixture.close() == Ok(Nil)
  })
}

pub fn selected_pending_cells_and_live_references_exclude_history_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "references")
    let historical =
      list.map(range(1, 1100), fn(n) {
        tx.SetRegister(
          register.FactCustom,
          "escalation/old-" <> int.to_string(n),
          register.value(json.Object([#("status", json.String("consumed"))])),
        )
      })
    let _committed =
      write(fixture, [
        tx.SetRegister(
          register.StrandState,
          "main",
          register.value(
            json.Object([#("currentOperationId", json.String("live"))]),
          ),
        ),
        tx.SetRegister(
          register.OpState,
          "live",
          register.value(json.String("active")),
        ),
        tx.SetRegister(
          register.OpState,
          "old",
          register.value(json.String("historical")),
        ),
        tx.SetRegister(
          register.FactCustom,
          "escalation/current",
          register.value(json.Object([#("status", json.String("pending"))])),
        ),
        ..historical
      ])
    let plan =
      snapshot.Plan(
        [
          all(register.StrandState),
          snapshot.Selection(
            register.FactCustom,
            "escalation/",
            snapshot.StringFieldEquals("status", "pending"),
          ),
        ],
        [
          snapshot.FromField(
            register.StrandState,
            "currentOperationId",
            register.OpState,
          ),
        ],
        0,
      )
    let assert Ok(cut) = fixture.reader.capture(plan, answer_wait_ms)
      as "only selected current metadata is copied"
    assert list.length(cut.cells) == 3
    assert list.any(cut.cells, fn(cell) {
      cell.namespace == register.OpState && cell.key == "live"
    })
    assert !list.any(cut.cells, fn(cell) { cell.key == "old" })
    assert fixture.close() == Ok(Nil)
  })
}

pub fn byte_fragments_round_trip_across_unicode_boundaries_test() {
  let text = string.repeat("aλ😀漢\n", 25_000)
  let outputs =
    list.map([Memory, Sqlite], fn(backend) {
      let fixture = open(backend, "unicode")
      let #(entry, _) = fixtures.message_entry(fixtures.new_ctx(), None, text)
      let _committed = write(fixture, [tx.InsertEntry(entry)])
      let assert Ok(cut) =
        fixture.reader.capture(snapshot.Plan([], [], 1), answer_wait_ms)
        as "one descriptor"
      let assert [descriptor] = cut.recent as "one recent entry"
      let bytes = fragments(fixture.reader, descriptor, 0, <<>>)
      assert bit_array.byte_size(bytes) == descriptor.byte_length
      assert fixture.reader.fragment(
          descriptor,
          descriptor.byte_length,
          answer_wait_ms,
        )
        == Ok(<<>>)
      assert fixture.reader.fragment(descriptor, -1, answer_wait_ms)
        == Error(snapshot.InvalidRequest)
      assert fixture.reader.fragment(
          descriptor,
          descriptor.byte_length + 1,
          answer_wait_ms,
        )
        == Error(snapshot.InvalidRequest)
      list.each(range(0, 24), fn(offset) {
        let assert Ok(expected) =
          bit_array.slice(bytes, offset, snapshot.fragment_bytes_limit)
          as "expected byte slice"
        assert fixture.reader.fragment(descriptor, offset, answer_wait_ms)
          == Ok(expected)
      })
      let assert Ok(encoded) = bit_array.to_string(bytes)
        as "complete bytes form UTF-8"
      let assert Ok(value) = json.parse(encoded) as "complete record is JSON"
      let assert Ok(decoded) = codec.decode_entry(value)
        as "complete record passes core codec"
      assert decoded == storage.stamp(entry, 1, 1000)
      assert fixture.close() == Ok(Nil)
      bytes
    })
  let assert [memory_bytes, sqlite_bytes] = outputs as "both backends ran"
  assert memory_bytes == sqlite_bytes
}

fn fragments(
  reader: snapshot.Reader,
  descriptor: snapshot.Descriptor,
  offset: Int,
  bytes: BitArray,
) -> BitArray {
  let assert Ok(part) = reader.fragment(descriptor, offset, answer_wait_ms)
    as "next byte fragment"
  assert bit_array.byte_size(part) <= snapshot.fragment_bytes_limit
  case bit_array.byte_size(part) {
    0 -> bytes
    size ->
      fragments(
        reader,
        descriptor,
        offset + size,
        bit_array.append(bytes, part),
      )
  }
}

pub fn metadata_count_limit_refuses_instead_of_truncating_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "metadata-count")
    let _committed =
      write(
        fixture,
        list.map(range(1, 1025), fn(n) {
          tx.SetRegister(
            register.FactName,
            int.to_string(n),
            register.value(json.Null),
          )
        }),
      )
    assert fixture.reader.capture(
        snapshot.Plan([all(register.FactName)], [], 0),
        answer_wait_ms,
      )
      == Error(snapshot.MetadataTooLarge)
    assert fixture.close() == Ok(Nil)
  })
}

pub fn sqlite_oversized_payloads_are_refused_before_json_decode_test() {
  let fixture = open(Sqlite, "oversized")
  let #(entry, _) = fixtures.message_entry(fixtures.new_ctx(), None, "small")
  let _committed =
    write(fixture, [
      tx.InsertEntry(entry),
      tx.SetRegister(register.FactName, "huge", register.value(json.Null)),
    ])
  let assert Ok(conn) = sqlight.open("build/test_db/snapshot-oversized.db")
    as "test corruption connection"

  // Invalid JSON bytes would fail decoding if payload fetch happened first.
  assert sqlight.exec("UPDATE registers SET value=zeroblob(1048577)", on: conn)
    == Ok(Nil)
  assert fixture.reader.capture(
      snapshot.Plan([all(register.FactName)], [], 0),
      answer_wait_ms,
    )
    == Error(snapshot.MetadataTooLarge)
  assert sqlight.exec("UPDATE entries SET payload=zeroblob(33554433)", on: conn)
    == Ok(Nil)
  assert fixture.reader.page(0, 3, 1, answer_wait_ms)
    == Error(snapshot.RecordTooLarge(entry.id, 33_554_433))
  assert fixture.reader.fragment(
      snapshot.Descriptor(entry.id, 1, 33_554_433),
      0,
      answer_wait_ms,
    )
    == Error(snapshot.RecordTooLarge(entry.id, 33_554_433))

  // A forged small descriptor cannot circumvent the preflighted row length.
  assert fixture.reader.fragment(
      snapshot.Descriptor(entry.id, 1, 10),
      0,
      answer_wait_ms,
    )
    == Error(snapshot.MissingRecord)
  assert sqlight.close(conn) == Ok(Nil)
  assert fixture.close() == Ok(Nil)
}

pub fn capture_is_read_only_and_does_not_pin_a_transaction_test() {
  let fixture = open(Sqlite, "read-txn")
  let assert Ok(conn) = sqlight.open("build/test_db/snapshot-read-txn.db")
    as "second connection"
  assert sqlight.exec("BEGIN IMMEDIATE", on: conn) == Ok(Nil)
  let assert Ok(cut) =
    fixture.reader.capture(snapshot.Plan([], [], 0), answer_wait_ms)
    as "reader coexists with reserved writer"
  assert cut.next_seq == 1
  assert sqlight.exec("ROLLBACK", on: conn) == Ok(Nil)
  let _committed =
    write(fixture, [
      tx.SetRegister(register.FactName, "after", register.value(json.Int(1))),
    ])
  let assert Ok(next) =
    fixture.reader.capture(
      snapshot.Plan([all(register.FactName)], [], 0),
      answer_wait_ms,
    )
    as "prior read transaction ended"
  assert next.next_seq == 2
  assert sqlight.close(conn) == Ok(Nil)
  assert fixture.close() == Ok(Nil)
}

pub fn sealed_handles_and_invalid_ranges_return_typed_errors_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "closed")
    assert fixture.reader.page(0, 10, 101, answer_wait_ms)
      == Error(snapshot.InvalidRequest)
    assert fixture.reader.page(10, 10, 1, answer_wait_ms)
      == Error(snapshot.InvalidRequest)
    assert fixture.reader.capture(snapshot.Plan([], [], 101), answer_wait_ms)
      == Error(snapshot.InvalidRequest)
    assert fixture.close() == Ok(Nil)
    assert fixture.reader.capture(snapshot.Plan([], [], 0), answer_wait_ms)
      == Error(snapshot.StorageFailure(storage.HandleClosed))
    assert fixture.reader.page(0, 1, 1, answer_wait_ms)
      == Error(snapshot.StorageFailure(storage.HandleClosed))
    let #(id, _) = fixtures.mint(fixtures.new_ctx())
    assert fixture.reader.fragment(
        snapshot.Descriptor(id, 1, 1),
        0,
        answer_wait_ms,
      )
      == Error(snapshot.StorageFailure(storage.HandleClosed))
  })
}

pub fn missing_reference_and_malformed_predicate_fail_closed_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "malformed")
    let _committed =
      write(fixture, [
        tx.SetRegister(
          register.StrandState,
          "main",
          register.value(
            json.Object([#("currentOperationId", json.String("missing"))]),
          ),
        ),
      ])
    assert fixture.reader.capture(
        snapshot.Plan(
          [all(register.StrandState)],
          [
            snapshot.FromField(
              register.StrandState,
              "currentOperationId",
              register.OpState,
            ),
          ],
          0,
        ),
        answer_wait_ms,
      )
      == Error(snapshot.MissingRecord)
    let _committed =
      write(fixture, [
        tx.SetRegister(
          register.FactCustom,
          "escalation/bad",
          register.value(json.Object([#("status", json.Int(1))])),
        ),
      ])
    let assert Error(snapshot.StorageFailure(storage.CorruptRow(_))) =
      fixture.reader.capture(
        snapshot.Plan(
          [
            snapshot.Selection(
              register.FactCustom,
              "escalation/",
              snapshot.StringFieldEquals("status", "pending"),
            ),
          ],
          [],
          0,
        ),
        answer_wait_ms,
      )
      as "invalid status is not silently omitted"
    assert fixture.close() == Ok(Nil)
  })
}

pub fn conversation_schema_and_generated_queries_match_sources_test() {
  let assert Ok(schema) = simplifile.read("sql/session.sql")
    as "conversation DDL source"
  assert session_schema.schema == schema
  let assert Ok(source) = simplifile.read("src/storage/sql/snapshot.sql")
    as "named snapshot SQL"
  let generated = [
    sql.snapshot_session().0,
    sql.snapshot_usage_value().0,
    sql.snapshot_register_headers("", "", "", "", "").0,
    sql.snapshot_register_budget("", "", "", "", "").0,
    sql.snapshot_register_value("", "", 0).0,
    sql.snapshot_register_page_budget("", "", "", "", 1).0,
    sql.snapshot_register_page_headers("", "", "", "", 1).0,
    sql.snapshot_register_header("", "").0,
    sql.snapshot_entry_page(Some(0), Some(1), 1).0,
    sql.snapshot_recent_entries(Some(1), 1).0,
    sql.snapshot_entry_fragment(0, 1, "", Some(1), 1).0,
    sql.snapshot_entry_head("", Some(1)).0,
  ]
  assert normalized_sql(source) == normalized_sql(string.join(generated, "\n"))
}

pub fn corrupt_identifiers_and_metadata_are_never_successful_cuts_test() {
  let fixture = open(Sqlite, "corrupt-cut")
  let #(entry, _) = fixtures.message_entry(fixtures.new_ctx(), None, "small")
  let _committed =
    write(fixture, [
      tx.InsertEntry(entry),
      tx.SetRegister(register.FactName, "bad", register.value(json.Null)),
    ])
  let assert Ok(conn) = sqlight.open("build/test_db/snapshot-corrupt-cut.db")
    as "test corruption connection"
  assert sqlight.exec("UPDATE registers SET value=x'ff'", on: conn) == Ok(Nil)
  let assert Error(snapshot.StorageFailure(storage.CorruptRow(_))) =
    fixture.reader.capture(
      snapshot.Plan([all(register.FactName)], [], 0),
      answer_wait_ms,
    )
    as "invalid UTF-8 is stored corruption"
  assert sqlight.exec("UPDATE session SET next_seq=-1", on: conn) == Ok(Nil)
  let assert Error(snapshot.StorageFailure(storage.CorruptRow(_))) =
    fixture.reader.capture(snapshot.Plan([], [], 0), answer_wait_ms)
    as "negative high-water is stored corruption"
  assert sqlight.exec(
      "UPDATE entries SET id=CAST(zeroblob(1048576) AS TEXT)",
      on: conn,
    )
    == Ok(Nil)
  let assert Error(snapshot.StorageFailure(storage.CorruptRow(_))) =
    fixture.reader.page(0, 3, 1, answer_wait_ms)
    as "noncanonical ID is refused before transferring its bytes"
  assert sqlight.close(conn) == Ok(Nil)
  assert fixture.close() == Ok(Nil)
}

fn normalized_sql(source: String) -> String {
  let text =
    list.fold(
      [
        "namespace",
        // Longer names first: replacing "@prefix" would otherwise eat the head
        // of "@prefix_upper" and leave the tail behind.
        "prefix_upper",
        "prefix",
        "field",
        "expected",
        "after_key",
        "key",
        "seq",
        "after_seq",
        "before_seq",
        "page_size",
        "offset",
        "fragment_size",
        "entry_id",
        "id",
        "payload_bytes",
      ],
      source,
      fn(text, name) { string.replace(text, "@" <> name, "?") },
    )
  let text =
    list.fold(range(1, 5), text, fn(text, n) {
      string.replace(text, "?" <> int.to_string(n), "?")
    })
  text
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" && !string.starts_with(line, "--") })
  |> list.map(fn(line) { string.trim_end(string.replace(line, ";", "")) })
  |> string.join("\n")
}

fn range(first: Int, last: Int) -> List(Int) {
  int.range(first, last + 1, [], fn(acc, n) { [n, ..acc] }) |> list.reverse
}

pub fn key_pages_survive_history_beyond_capture_budget_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "key-pages")
    let prefix = "mail%_/"
    let body = register.value(json.String(string.repeat("x", 2048)))
    let writes =
      list.map(range(1, 1100), fn(n) {
        tx.SetRegister(
          register.FactCustom,
          prefix <> int.to_string(10_000 + n),
          body,
        )
      })
    let _committed =
      write(fixture, [
        tx.SetRegister(register.FactCustom, "mail%X/00000", body),
        tx.SetRegister(register.FactName, prefix <> "10001", body),
        tx.SetRegister(
          register.FactCustom,
          prefix <> "zz",
          register.value(
            json.String(string.repeat("y", snapshot.metadata_bytes_limit)),
          ),
        ),
        ..writes
      ])

    // Complete capture must refuse this history. A key page still admits only
    // its window, preserving literal prefixes, ordering and the namespace.
    assert fixture.reader.capture(
        snapshot.Plan(
          [snapshot.Selection(register.FactCustom, prefix, snapshot.All)],
          [],
          0,
        ),
        answer_wait_ms,
      )
      == Error(snapshot.MetadataTooLarge)
    let first =
      snapshot.Plan(
        [snapshot.KeyPage(register.FactCustom, prefix, "", 7)],
        [],
        0,
      )
    let assert Ok(cut) = fixture.reader.capture(first, answer_wait_ms)
      as "a small page ignores the history's total size"
    assert cut.metadata_bytes < 20_000
    assert cell_keys(cut)
      == list.map(range(10_001, 10_007), fn(n) { prefix <> int.to_string(n) })

    // A removed cursor remains an exclusive key boundary, rather than an
    // offset into the mutable list. A larger neighbor is still not fetched.
    let _deleted =
      write(fixture, [tx.DeleteRegister(register.FactCustom, prefix <> "10007")])
    let second =
      snapshot.Plan(
        [snapshot.KeyPage(register.FactCustom, prefix, prefix <> "10007", 3)],
        [],
        0,
      )
    let assert Ok(cut) = fixture.reader.capture(second, answer_wait_ms)
      as "deleting the cursor never skips the next keys"
    assert cell_keys(cut)
      == [prefix <> "10008", prefix <> "10009", prefix <> "10010"]

    // Oversize is still an explicit refusal when that cell enters the page.
    let oversized =
      snapshot.Plan(
        [snapshot.KeyPage(register.FactCustom, prefix, prefix <> "11100", 1)],
        [],
        0,
      )
    assert fixture.reader.capture(oversized, answer_wait_ms)
      == Error(snapshot.MetadataTooLarge)
    assert fixture.close() == Ok(Nil)
  })
}

fn cell_keys(cut: snapshot.Cut) -> List(String) {
  list.map(cut.cells, fn(cell) { cell.key }) |> list.sort(string.compare)
}

pub fn key_page_validation_and_budget_precede_payload_fetch_test() {
  let fetched = process.new_subject()
  let source =
    snapshot.Source(
      headers: fn(_, _, _) { Error(snapshot.InvalidRequest) },
      page_headers: fn(namespace, _, _, _) {
        process.send(fetched, "headers")
        Ok([
          snapshot.Header(
            namespace,
            "large",
            1,
            snapshot.metadata_bytes_limit + 1,
          ),
        ])
      },
      header: fn(_, _) { Error(snapshot.InvalidRequest) },
      cell: fn(_) {
        process.send(fetched, "payload")
        Error(snapshot.InvalidRequest)
      },
    )
  let plan =
    snapshot.Plan([snapshot.KeyPage(register.FactCustom, "", "", 1)], [], 0)
  assert snapshot.collect(plan, source, 0) == Error(snapshot.MetadataTooLarge)
  assert process.receive(fetched, 0) == Ok("headers")
  assert process.receive(fetched, 0) == Error(Nil)

  list.each([0, -1, 101], fn(limit) {
    let invalid =
      snapshot.Plan(
        [snapshot.KeyPage(register.FactCustom, "", "", limit)],
        [],
        0,
      )
    assert snapshot.collect(invalid, source, 0)
      == Error(snapshot.InvalidRequest)
    assert process.receive(fetched, 0) == Error(Nil)
  })
}

pub fn sqlite_key_pages_use_an_indexed_bounded_window_test() {
  let assert Ok(conn) = sqlight.open(path("key-page-plan"))
    as "query-plan fixture opens"
  assert sqlight.exec(session_schema.schema, on: conn) == Ok(Nil)
  let statements = [
    sql.snapshot_register_page_budget("", "", "", "", 1).0,
    sql.snapshot_register_page_headers("", "", "", "", 1).0,
  ]
  list.each(statements, fn(statement) {
    let assert Ok(plan) =
      sqlight.query(
        "EXPLAIN QUERY PLAN " <> statement,
        on: conn,
        with: [
          sqlight.text("fact.custom"),
          sqlight.text("mail/"),
          sqlight.text("mail/01"),
          sqlight.text("mail0"),
          sqlight.int(1),
        ],
        expecting: decode.at([3], decode.string),
      )
      as "SQLite explains the bounded header window"
    assert list.any(plan, string.contains(_, "SEARCH registers"))
    assert list.any(plan, string.contains(_, "key>? AND key<?"))
    assert !list.any(plan, string.contains(_, "TEMP B-TREE FOR ORDER BY"))
  })
  assert sqlight.close(conn) == Ok(Nil)
}

// A capture reads its statistics from the maintained session row and its
// recent window from one index search, so its cost does not grow with the
// length of the history. Measured on a real 28 MB session of 4,727 messages
// and 35,840 sequence numbers it took 1.5 to 11 ms, which means a capture that
// exceeds its five-second wait was queued behind other work in the actor, not
// slow in itself. These plans are what keeps that true.
pub fn capture_cost_does_not_grow_with_history_test() {
  let assert Ok(conn) = sqlight.open(path("capture-plan"))
    as "query-plan fixture opens"
  assert sqlight.exec(session_schema.schema, on: conn) == Ok(Nil)
  let explain = fn(statement: String, params) {
    let assert Ok(plan) =
      sqlight.query(
        "EXPLAIN QUERY PLAN " <> statement,
        on: conn,
        with: params,
        expecting: decode.at([3], decode.string),
      )
      as "SQLite explains the capture query"
    plan
  }

  // The statistics are one stored row. Nothing in them aggregates entries.
  let summary = explain(sql.snapshot_session().0, [])
  assert list.any(summary, string.contains(_, "SCAN session"))
  assert !list.any(summary, string.contains(_, "entries"))
  assert !list.any(summary, string.contains(_, "usage_ledger"))

  // The recent window is a descending range over the sequence index, with no
  // sort and no scan of the entry table.
  let recent =
    explain(sql.snapshot_recent_entries(Some(1), 1).0, [
      sqlight.int(1),
      sqlight.int(1),
    ])
  assert list.any(recent, string.contains(_, "SEARCH entries"))
  assert list.any(recent, string.contains(_, "ix_entry_seq"))
  assert !list.any(recent, string.contains(_, "SCAN entries"))
  assert !list.any(recent, string.contains(_, "TEMP B-TREE"))
  assert sqlight.close(conn) == Ok(Nil)
}

pub fn reference_expansion_spends_the_same_metadata_budget_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "reference-budget")
    let sources =
      list.map(range(1, 1024), fn(n) {
        tx.SetRegister(
          register.StrandState,
          int.to_string(n),
          register.value(
            json.Object([#("currentOperationId", json.String("shared"))]),
          ),
        )
      })
    let _committed =
      write(fixture, [
        tx.SetRegister(register.OpState, "shared", register.value(json.Null)),
        ..sources
      ])
    let plan =
      snapshot.Plan(
        [all(register.StrandState)],
        [
          snapshot.FromField(
            register.StrandState,
            "currentOperationId",
            register.OpState,
          ),
        ],
        0,
      )
    assert fixture.reader.capture(plan, answer_wait_ms)
      == Error(snapshot.MetadataTooLarge)
    assert fixture.close() == Ok(Nil)
  })
}

pub fn metadata_byte_limit_includes_keys_and_reference_payloads_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "metadata-bytes")
    let _committed =
      write(fixture, [
        tx.SetRegister(
          register.StrandState,
          "main",
          register.value(
            json.Object([#("currentOperationId", json.String("large"))]),
          ),
        ),
        tx.SetRegister(
          register.OpState,
          "large",
          register.value(
            json.String(string.repeat("x", snapshot.metadata_bytes_limit)),
          ),
        ),
      ])
    let plan =
      snapshot.Plan(
        [all(register.StrandState)],
        [
          snapshot.FromField(
            register.StrandState,
            "currentOperationId",
            register.OpState,
          ),
        ],
        0,
      )
    assert fixture.reader.capture(plan, answer_wait_ms)
      == Error(snapshot.MetadataTooLarge)
    let _committed =
      write(fixture, [
        tx.SetRegister(
          register.FactName,
          string.repeat("k", snapshot.metadata_bytes_limit),
          register.value(json.Null),
        ),
      ])
    assert fixture.reader.capture(
        snapshot.Plan([all(register.FactName)], [], 0),
        answer_wait_ms,
      )
      == Error(snapshot.MetadataTooLarge)
    assert fixture.close() == Ok(Nil)
  })
}

// Two strands write alternately, so neither one's records are adjacent in the
// sequence. Each record names the one before it on its own strand.
fn interleaved(count: Int) -> #(List(entry.Entry), List(entry.Entry)) {
  let #(_, _, left, right) =
    list.fold(
      range(1, count),
      #(fixtures.new_ctx(), #(None, None), [], []),
      fn(acc, n) {
        let #(ctx, #(left_leaf, right_leaf), left, right) = acc
        let #(a, ctx) =
          fixtures.message_entry(ctx, left_leaf, "left " <> int.to_string(n))
        let #(b, ctx) =
          fixtures.message_entry(ctx, right_leaf, "right " <> int.to_string(n))
        #(ctx, #(Some(a.id), Some(b.id)), [a, ..left], [b, ..right])
      },
    )
  #(list.reverse(left), list.reverse(right))
}

pub fn a_lineage_read_returns_one_strands_records_only_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "lineage")
    let #(left, right) = interleaved(150)
    let _committed =
      write(
        fixture,
        list.flat_map(list.zip(left, right), fn(pair) {
          [tx.InsertEntry(pair.0), tx.InsertEntry(pair.1)]
        }),
      )
    let assert Ok(cut) =
      fixture.reader.capture(snapshot.Plan([], [], 0), answer_wait_ms)
    assert cut.next_seq == 301
    let assert Ok(leaf) = list.last(left)

    // The newest page is the newest hundred of the strand, oldest first, and
    // none of the other strand's records, though they sit between them.
    let assert Ok(page) =
      fixture.reader.lineage(leaf.id, cut.next_seq, 100, answer_wait_ms)
    assert list.length(page) == 100
    let left_ids = list.map(left, fn(held) { held.id })
    assert list.all(page, fn(item) { list.contains(left_ids, item.id) })
    assert list.map(page, fn(item) { item.seq })
      == list.map(range(51, 150), fn(n) { 2 * n - 1 })

    // The next page starts at the parent of the oldest record held, and the
    // two pages are the strand's whole ancestry with no record twice.
    let assert Ok(oldest) = list.first(page)
    let assert Ok(held) = list.find(left, fn(held) { held.id == oldest.id })
    let assert entry.MessageEntry(parent: Some(next), ..) = held
    let assert Ok(rest) =
      fixture.reader.lineage(next, cut.next_seq, 100, answer_wait_ms)
    assert list.map(rest, fn(item) { item.seq })
      == list.map(range(1, 50), fn(n) { 2 * n - 1 })

    // The high-water bounds a page: an entry at or above it is not read, and a
    // walk from one below it stops at the same place.
    assert fixture.reader.lineage(leaf.id, 299, 100, answer_wait_ms) == Ok([])
    let assert Ok(inside) =
      fixture.reader.lineage(leaf.id, 300, 3, answer_wait_ms)
    assert list.map(inside, fn(item) { item.seq }) == [295, 297, 299]

    // An entry the store does not hold is the end of a walk, not a fault, and
    // a request outside the bounds is refused before any read.
    let #(unknown, _) = ids.mint_entry(ids.generator(clock.fixed(9000), 52))
    assert fixture.reader.lineage(unknown, cut.next_seq, 100, answer_wait_ms)
      == Ok([])
    assert fixture.reader.lineage(leaf.id, cut.next_seq, 0, answer_wait_ms)
      == Error(snapshot.InvalidRequest)
    assert fixture.reader.lineage(leaf.id, cut.next_seq, 101, answer_wait_ms)
      == Error(snapshot.InvalidRequest)
    assert fixture.reader.lineage(leaf.id, 0, 10, answer_wait_ms)
      == Error(snapshot.InvalidRequest)
    assert fixture.close() == Ok(Nil)
  })
}

pub fn a_lineage_page_stops_before_the_record_that_would_pass_its_bytes_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "lineage-bytes")
    let big = string.repeat("x", 900_000)
    let #(chain, _) =
      list.fold(range(1, 3), #([], fixtures.new_ctx()), fn(acc, _) {
        let #(held, ctx): #(List(entry.Entry), _) = acc
        let parent = case held {
          [newest, ..] -> Some(newest.id)
          [] -> None
        }
        let #(next, ctx) = fixtures.message_entry(ctx, parent, big)
        #([next, ..held], ctx)
      })
    let _committed =
      write(
        fixture,
        list.map(list.reverse(chain), fn(held) { tx.InsertEntry(held) }),
      )
    let assert [newest, ..] = chain
    let assert Ok(page) =
      fixture.reader.lineage(newest.id, 4, 100, answer_wait_ms)

    // Three records of nine hundred kilobytes are past the page's two
    // megabytes, so the oldest is left for the next read and the newest two
    // are returned.
    assert list.map(page, fn(item) { item.seq }) == [2, 3]
    assert fixture.close() == Ok(Nil)
  })
}

pub fn the_lineage_step_is_a_primary_key_probe_test() {
  let assert Ok(conn) = sqlight.open(path("lineage-plan"))
    as "query-plan fixture opens"
  assert sqlight.exec(session_schema.schema, on: conn) == Ok(Nil)
  let assert Ok(plan) =
    sqlight.query(
      "EXPLAIN QUERY PLAN " <> sql.snapshot_entry_head("", Some(1)).0,
      on: conn,
      with: [sqlight.text("id"), sqlight.int(10)],
      expecting: decode.at([3], decode.string),
    )
    as "SQLite explains one step of a lineage walk"
  assert list.any(plan, string.contains(_, "SEARCH entries"))
  assert list.any(plan, string.contains(_, "PRIMARY KEY"))
  assert !list.any(plan, string.contains(_, "SCAN"))
  assert sqlight.close(conn) == Ok(Nil)
}
