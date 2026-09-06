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

    // Reading again is deliberately test-only: it demonstrates that timeout
    // did not cancel actor work. Production must retire this gateway instead.
    // This page's reply differs from the queued capture and missing fragment,
    // so a late reply cannot silently satisfy the new exchange.
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
    assert fixture.reader.capture(snapshot.Plan([], [], 0), 1000)
      == Error(snapshot.ReaderUnavailable)
    assert fixture.reader.page(0, 2, 1, 1000)
      == Error(snapshot.ReaderUnavailable)
    assert fixture.reader.fragment(snapshot.Descriptor(entry.id, 1, 1), 0, 1000)
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
    let assert Ok(cut) = fixture.reader.capture(plan, 1000)
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

pub fn exact_key_preflight_refuses_before_fetch_and_never_scans_prefix_test() {
  let fetched = process.new_subject()
  let source =
    snapshot.Source(
      headers: fn(_, _, _) {
        process.send(fetched, "prefix")
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
      1000,
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
    let assert Ok(cut) = fixture.reader.capture(plan, 1000)
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
    assert fixture.reader.page(409, cut.next_seq, 7, 1000) == Ok([])
    assert fixture.close() == Ok(Nil)
  })
}

fn inventory(
  reader: snapshot.Reader,
  after: Int,
  before: Int,
  reversed: List(snapshot.Descriptor),
) -> List(snapshot.Descriptor) {
  let assert Ok(page) = reader.page(after, before, 7, 1000)
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
          1000,
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
    let assert Ok(cut) = fixture.reader.capture(plan, 1000)
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
        fixture.reader.capture(snapshot.Plan([], [], 1), 1000)
        as "one descriptor"
      let assert [descriptor] = cut.recent as "one recent entry"
      let bytes = fragments(fixture.reader, descriptor, 0, <<>>)
      assert bit_array.byte_size(bytes) == descriptor.byte_length
      assert fixture.reader.fragment(descriptor, descriptor.byte_length, 1000)
        == Ok(<<>>)
      assert fixture.reader.fragment(descriptor, -1, 1000)
        == Error(snapshot.InvalidRequest)
      assert fixture.reader.fragment(
          descriptor,
          descriptor.byte_length + 1,
          1000,
        )
        == Error(snapshot.InvalidRequest)
      list.each(range(0, 24), fn(offset) {
        let assert Ok(expected) =
          bit_array.slice(bytes, offset, snapshot.fragment_bytes_limit)
          as "expected byte slice"
        assert fixture.reader.fragment(descriptor, offset, 1000) == Ok(expected)
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
  let assert Ok(part) = reader.fragment(descriptor, offset, 1000)
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
        1000,
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
      1000,
    )
    == Error(snapshot.MetadataTooLarge)
  assert sqlight.exec("UPDATE entries SET payload=zeroblob(33554433)", on: conn)
    == Ok(Nil)
  assert fixture.reader.page(0, 3, 1, 1000)
    == Error(snapshot.RecordTooLarge(entry.id, 33_554_433))
  assert fixture.reader.fragment(
      snapshot.Descriptor(entry.id, 1, 33_554_433),
      0,
      1000,
    )
    == Error(snapshot.RecordTooLarge(entry.id, 33_554_433))

  // A forged small descriptor cannot circumvent the preflighted row length.
  assert fixture.reader.fragment(snapshot.Descriptor(entry.id, 1, 10), 0, 1000)
    == Error(snapshot.MissingRecord)
  assert sqlight.close(conn) == Ok(Nil)
  assert fixture.close() == Ok(Nil)
}

pub fn capture_is_read_only_and_does_not_pin_a_transaction_test() {
  let fixture = open(Sqlite, "read-txn")
  let assert Ok(conn) = sqlight.open("build/test_db/snapshot-read-txn.db")
    as "second connection"
  assert sqlight.exec("BEGIN IMMEDIATE", on: conn) == Ok(Nil)
  let assert Ok(cut) = fixture.reader.capture(snapshot.Plan([], [], 0), 1000)
    as "reader coexists with reserved writer"
  assert cut.next_seq == 1
  assert sqlight.exec("ROLLBACK", on: conn) == Ok(Nil)
  let _committed =
    write(fixture, [
      tx.SetRegister(register.FactName, "after", register.value(json.Int(1))),
    ])
  let assert Ok(next) =
    fixture.reader.capture(snapshot.Plan([all(register.FactName)], [], 0), 1000)
    as "prior read transaction ended"
  assert next.next_seq == 2
  assert sqlight.close(conn) == Ok(Nil)
  assert fixture.close() == Ok(Nil)
}

pub fn sealed_handles_and_invalid_ranges_return_typed_errors_test() {
  list.each([Memory, Sqlite], fn(backend) {
    let fixture = open(backend, "closed")
    assert fixture.reader.page(0, 10, 101, 1000)
      == Error(snapshot.InvalidRequest)
    assert fixture.reader.page(10, 10, 1, 1000)
      == Error(snapshot.InvalidRequest)
    assert fixture.reader.capture(snapshot.Plan([], [], 101), 1000)
      == Error(snapshot.InvalidRequest)
    assert fixture.close() == Ok(Nil)
    assert fixture.reader.capture(snapshot.Plan([], [], 0), 1000)
      == Error(snapshot.StorageFailure(storage.HandleClosed))
    assert fixture.reader.page(0, 1, 1, 1000)
      == Error(snapshot.StorageFailure(storage.HandleClosed))
    let #(id, _) = fixtures.mint(fixtures.new_ctx())
    assert fixture.reader.fragment(snapshot.Descriptor(id, 1, 1), 0, 1000)
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
        1000,
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
        1000,
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
    sql.snapshot_register_headers("", "", "", "").0,
    sql.snapshot_register_budget("", "", "", "").0,
    sql.snapshot_register_value("", "", 0).0,
    sql.snapshot_register_header("", "").0,
    sql.snapshot_entry_page(Some(0), Some(1), 1).0,
    sql.snapshot_recent_entries(Some(1), 1).0,
    sql.snapshot_entry_fragment(0, 1, "", Some(1), 1).0,
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
    fixture.reader.capture(snapshot.Plan([all(register.FactName)], [], 0), 1000)
    as "invalid UTF-8 is stored corruption"
  assert sqlight.exec("UPDATE session SET next_seq=-1", on: conn) == Ok(Nil)
  let assert Error(snapshot.StorageFailure(storage.CorruptRow(_))) =
    fixture.reader.capture(snapshot.Plan([], [], 0), 1000)
    as "negative high-water is stored corruption"
  assert sqlight.exec(
      "UPDATE entries SET id=CAST(zeroblob(1048576) AS TEXT)",
      on: conn,
    )
    == Ok(Nil)
  let assert Error(snapshot.StorageFailure(storage.CorruptRow(_))) =
    fixture.reader.page(0, 3, 1, 1000)
    as "noncanonical ID is refused before transferring its bytes"
  assert sqlight.close(conn) == Ok(Nil)
  assert fixture.close() == Ok(Nil)
}

fn normalized_sql(source: String) -> String {
  let text =
    list.fold(
      [
        "namespace",
        "prefix",
        "field",
        "expected",
        "key",
        "seq",
        "after_seq",
        "before_seq",
        "page_size",
        "offset",
        "fragment_size",
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
    assert fixture.reader.capture(plan, 1000)
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
    assert fixture.reader.capture(plan, 1000)
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
        1000,
      )
      == Error(snapshot.MetadataTooLarge)
    assert fixture.close() == Ok(Nil)
  })
}
