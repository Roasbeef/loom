//// The precise rewrite (pi §2.9): text erasure through `repo.erase_text`,
//// the memory rebuild, the SQLite VACUUM-INTO copy + swap, and the audit
//// contract — after erasing X, the string X appears nowhere in the new
//// file's raw bytes, retained-tail copies inside compaction entries
//// included.

import core/clock
import core/codec as core_codec
import core/entry
import core/ids
import core/json
import core/message
import core/register
import core/tx.{InsertUsage, SetRegister, Tx}
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/strand.{ModelIdentity, StrandConfiguration, ThinkingOff}
import session/repo
import session/session
import simplifile
import storage/sqlite
import storage/storage
import support/drive
import support/generate

const needle = "XYZZY_SECRET_7"

const replacement = "[erased]"

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

fn mint_id(seed: Int) -> ids.EntryId {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 0), seed:))
  id
}

fn mint_usage_id(seed: Int) -> ids.UsageId {
  let #(id, _generator) =
    ids.mint_usage(ids.generator(clock.fixed(at: 0), seed:))
  id
}

// Plants the needle in every non-entry store the audit contract covers:
// the registers a live operation writes (queued pending payloads, tool
// arguments, compaction preparation, a terminal result, custom and named
// facts) and a usage-ledger row's opaque details blob.
fn seed_register_secrets(sess: session.Session) -> Nil {
  let assert Ok(_) =
    storage.commit(
      sess.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.PendingEntry,
            key: "main/1",
            value: register.value(json.String("queued " <> needle)),
          ),
          SetRegister(
            ns: register.OpToolArgs,
            key: "op-1/1",
            value: register.value(
              json.Object([#("query", json.String("find " <> needle))]),
            ),
          ),
          SetRegister(
            ns: register.OpPreparation,
            key: "op-1",
            value: register.value(json.String("summarizing " <> needle)),
          ),
          SetRegister(
            ns: register.StrandLastResult,
            key: "main",
            value: register.value(json.String("result " <> needle)),
          ),
          SetRegister(
            ns: register.FactCustom,
            key: "note",
            value: register.value(json.String("custom " <> needle)),
          ),
          SetRegister(
            ns: register.FactName,
            key: "session",
            value: register.value(json.String("named " <> needle)),
          ),
          InsertUsage(row: entry.UsageRow(
            id: mint_usage_id(31),
            seq: 0,
            entry_id: None,
            adjustment: False,
            usage: generate.some_usage(10),
            details: Some(
              json.Object([#("echo", json.String("details " <> needle))]),
            ),
          )),
        ],
        expected: [],
      ),
    )
  Nil
}

// Seeds a session with the needle in every place an entry can carry text:
// message blocks, tool-call arguments, a compaction summary and its
// retained tail, and a custom payload. Returns the driver.
fn seed_secrets(sess: session.Session) -> drive.Ctx {
  let ctx = drive.new_ctx(sess, 42)
  let #(ctx, _) =
    drive.append_message(ctx, generate.user_text("please handle " <> needle))
  let call =
    generate.tool_call(
      1,
      json.Object([#("query", json.String("find " <> needle))]),
    )
  let #(ctx, _) =
    drive.append_message(
      ctx,
      generate.assistant_msg(2, message.ToolUse, [call]),
    )
  let #(ctx, _) = drive.append_message(ctx, generate.tool_result(call, 3))
  let #(ctx, _) =
    drive.append_compaction(ctx, "earlier we discussed " <> needle, [
      // The retained tail carries its own copy of the secret — the audit
      // must reach inside it.
      generate.user_text("tail copy of " <> needle),
    ])
  let #(ctx, _) =
    drive.append_custom(ctx, "note", Some(json.String("noted " <> needle)))
  let #(ctx, _) =
    drive.append_message(ctx, generate.assistant_msg(4, message.Stop, []))
  ctx
}

// --- erase_text ------------------------------------------------------------

pub fn erase_text_keeps_clean_entries_test() {
  let erase = repo.erase_text(needle:, replacement:)
  let clean =
    entry.MessageEntry(
      id: mint_id(1),
      parent: None,
      seq: 1,
      ts: 1,
      message: generate.user_text("nothing to hide"),
      terminate: False,
    )
  assert erase(clean) == Ok(None)
}

pub fn erase_text_rewrites_retained_tail_test() {
  let erase = repo.erase_text(needle:, replacement:)
  let compaction =
    entry.CompactionEntry(
      id: mint_id(2),
      parent: None,
      seq: 1,
      ts: 1,
      summary: "summary with " <> needle,
      retained_tail: [generate.user_text("tail with " <> needle)],
      tokens_before: 10,
      from_hook: False,
      usage: None,
    )
  let assert Ok(Some(rewritten)) = erase(compaction)
  let encoded = json.to_string(core_codec.encode_entry(rewritten))
  assert !string.contains(does: encoded, contain: needle)
  assert string.contains(does: encoded, contain: replacement)
}

pub fn erase_text_leaves_object_keys_alone_test() {
  // Keys are structural: a needle inside a custom payload's key survives
  // (documented limitation), and the entry counts as unchanged.
  let erase = repo.erase_text(needle:, replacement:)
  let custom =
    entry.CustomEntry(
      id: mint_id(3),
      parent: None,
      seq: 1,
      ts: 1,
      custom_type: "note",
      data: Some(json.Object([#("key-" <> needle, json.Int(1))])),
    )
  assert erase(custom) == Ok(None)
}

// --- memory rebuild --------------------------------------------------------

pub fn rewrite_memory_erases_and_retains_everything_else_test() {
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  let ctx = seed_secrets(source)
  let ctx = drive.append_usage(ctx, ctx.leaf, generate.some_usage(90))
  seed_register_secrets(ctx.session)
  let assert Ok(repo.MemoryRewrite(session: rebuilt, entries_rewritten:)) =
    repo.rewrite_memory(
      source: ctx.session,
      rewrite: repo.erase_text(needle:, replacement:),
      rewrite_value: repo.erase_value(needle:, replacement:),
      clock: clock.fixed(at: 3000),
    )
  // Five of the seven entries carried the needle (user, assistant call
  // arguments, tool result echoes nothing — only the call text — so:
  // user, assistant, compaction, custom, and the tool-call query).
  assert entries_rewritten == 4

  // No stored payload carries the needle any more.
  let assert Ok(entries) =
    storage.scan_entries(rebuilt.store, storage.entry_scan())
  list.each(entries, fn(rebuilt_entry) {
    let encoded = json.to_string(core_codec.encode_entry(rebuilt_entry))
    assert !string.contains(does: encoded, contain: needle)
  })

  // Unlike a fork, the rewrite retains history: the ledger and registers
  // survive — erased where the needle reached them, verbatim elsewhere.
  let assert Ok(rows) = storage.scan_usage(rebuilt.store, storage.usage_scan())
  let assert [clean_row, details_row] = rows
  assert clean_row.usage == generate.some_usage(90)
  let flattened_details = string.inspect(details_row.details)
  assert !string.contains(does: flattened_details, contain: needle)
  assert string.contains(does: flattened_details, contain: replacement)
  let assert Ok(Some(storage.Register(value: named, ..))) =
    storage.get_register(rebuilt.store, register.FactName, "session")
  let named_text = json.to_string(core_codec.encode_register_value(named))
  assert !string.contains(does: named_text, contain: needle)
  assert string.contains(does: named_text, contain: replacement)
  let assert Ok(Some(storage.Register(value: pending, ..))) =
    storage.get_register(rebuilt.store, register.PendingEntry, "main/1")
  let pending_text = json.to_string(core_codec.encode_register_value(pending))
  assert !string.contains(does: pending_text, contain: needle)
  let assert Ok(Some(session.Cell(value: config, ..))) =
    session.strand_configuration(rebuilt, "main")
  assert config == configuration()

  // The projection at the same leaf shows the replacement text.
  let assert Ok(projected) = session.project_context(rebuilt, ctx.leaf)
  let flattened = string.inspect(projected)
  assert !string.contains(does: flattened, contain: needle)
  assert string.contains(does: flattened, contain: replacement)
}

pub fn rewrite_memory_refuses_placement_changes_test() {
  let assert Ok(source) = session.open_memory(clock.fixed(at: 1000))
  let ctx = drive.new_ctx(source, 7)
  let #(ctx, _) = drive.append_message(ctx, generate.user_msg(1))
  let hijack = fn(rewritten: entry.Entry) {
    // Return a different id: the driver must refuse to move entries.
    let moved = case rewritten {
      entry.MessageEntry(..) as message_entry ->
        entry.MessageEntry(..message_entry, id: mint_id(99))
      other -> other
    }
    Ok(Some(moved))
  }
  let assert Error(repo.RewriteEntryFailed(..)) =
    repo.rewrite_memory(
      source: ctx.session,
      rewrite: hijack,
      rewrite_value: fn(_) { Ok(None) },
      clock: clock.fixed(at: 3000),
    )
}

// --- the SQLite copy + swap and the erase audit ----------------------------

pub fn sqlite_rewrite_erase_audit_test() {
  let path = fresh_path("rewrite_audit")
  let assert Ok(source) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 5000,
      clock: clock.stepping(from: 10_000, by: 1),
    )
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  let ctx = seed_secrets(source)
  let leaf = ctx.leaf
  let assert Ok(Nil) = session.close(source)

  // Fresh files are generation 0; the needle is on disk before — in the
  // main file or its WAL sibling, wherever the last checkpoint left it.
  assert sqlite.generation(path:) == Ok(0)
  let assert Ok(before) = simplifile.read_bits(path)
  let before_wal = case simplifile.read_bits(path <> "-wal") {
    Ok(bits) -> bits
    Error(_) -> <<>>
  }
  assert contains_bytes(before, bit_array.from_string(needle))
    || contains_bytes(before_wal, bit_array.from_string(needle))

  let assert Ok(sqlite.Rewrite(generation: 1, entries_rewritten: 4)) =
    repo.rewrite_sqlite(
      path:,
      clock: clock.fixed(at: 100_000),
      rewrite: repo.erase_text(needle:, replacement:),
      rewrite_value: repo.erase_value(needle:, replacement:),
    )

  // The audit: the erased string appears NOWHERE in the new file's raw
  // bytes — free pages and retained-tail copies included — and no
  // sibling WAL/SHM files survive to carry it either.
  let assert Ok(after) = simplifile.read_bits(path)
  assert !contains_bytes(after, bit_array.from_string(needle))
  assert contains_bytes(after, bit_array.from_string(replacement))
  assert simplifile.is_file(path <> "-wal") == Ok(False)
  assert simplifile.is_file(path <> "-shm") == Ok(False)
  assert sqlite.generation(path:) == Ok(1)

  // The rewritten file reopens as an ordinary session and projects the
  // replacement text at the same leaf.
  let assert Ok(reopened) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 5000,
      clock: clock.stepping(from: 200_000, by: 1),
    )
  let assert Ok(projected) = session.project_context(reopened, leaf)
  let flattened = string.inspect(projected)
  assert !string.contains(does: flattened, contain: needle)
  assert string.contains(does: flattened, contain: replacement)
  let assert Ok(Nil) = session.close(reopened)

  // A second rewrite bumps the generation again.
  let assert Ok(sqlite.Rewrite(generation: 2, entries_rewritten: 0)) =
    repo.rewrite_sqlite(
      path:,
      clock: clock.fixed(at: 300_000),
      rewrite: repo.erase_text(needle:, replacement:),
      rewrite_value: repo.erase_value(needle:, replacement:),
    )
}

pub fn sqlite_rewrite_erases_registers_and_usage_details_test() {
  let path = fresh_path("rewrite_register_audit")
  let assert Ok(source) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 5000,
      clock: clock.stepping(from: 10_000, by: 1),
    )
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  // One clean entry, so the audit isolates the non-entry stores: every
  // needle below lives in a register payload or a usage-details blob.
  let ctx = drive.new_ctx(source, 42)
  let #(ctx, _) =
    drive.append_message(ctx, generate.user_text("nothing to hide"))
  seed_register_secrets(ctx.session)
  let assert Ok(Nil) = session.close(source)

  let assert Ok(before) = simplifile.read_bits(path)
  let before_wal = case simplifile.read_bits(path <> "-wal") {
    Ok(bits) -> bits
    Error(_) -> <<>>
  }
  assert contains_bytes(before, bit_array.from_string(needle))
    || contains_bytes(before_wal, bit_array.from_string(needle))

  // No entry carried the needle, so the count stays 0 — the registers
  // and the ledger details are rewritten without inflating it.
  let assert Ok(sqlite.Rewrite(generation: 1, entries_rewritten: 0)) =
    repo.rewrite_sqlite(
      path:,
      clock: clock.fixed(at: 100_000),
      rewrite: repo.erase_text(needle:, replacement:),
      rewrite_value: repo.erase_value(needle:, replacement:),
    )

  // The audit holds across every store: the raw bytes of the new file
  // carry no needle even though it was planted only outside entries.
  let assert Ok(after) = simplifile.read_bits(path)
  assert !contains_bytes(after, bit_array.from_string(needle))
  assert contains_bytes(after, bit_array.from_string(replacement))

  // And the rewritten cells decode as ordinary registers on reopen.
  let assert Ok(reopened) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 5000,
      clock: clock.fixed(at: 200_000),
    )
  let assert Ok(Some(storage.Register(value: pending, ..))) =
    storage.get_register(reopened.store, register.PendingEntry, "main/1")
  let pending_text = json.to_string(core_codec.encode_register_value(pending))
  assert !string.contains(does: pending_text, contain: needle)
  assert string.contains(does: pending_text, contain: replacement)
  let assert Ok([row]) =
    storage.scan_usage(reopened.store, storage.usage_scan())
  let details_text = string.inspect(row.details)
  assert !string.contains(does: details_text, contain: needle)
  assert string.contains(does: details_text, contain: replacement)
  let assert Ok(Nil) = session.close(reopened)
}

pub fn sqlite_rewrite_retires_the_source_wal_before_the_copy_test() {
  let path = fresh_path("rewrite_wal_retired")
  let assert Ok(source) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 5000,
      clock: clock.stepping(from: 10_000, by: 1),
    )
  let assert Ok(Nil) = session.ensure_strand(source, "main", configuration())
  let _ctx = seed_secrets(source)
  let assert Ok(Nil) = session.close(source)

  // A clean close leaves the `-wal` sibling on disk with the committed
  // frames still in it (the actor's close releases the lease but does
  // not checkpoint), and SQLite would replay any WAL whose checksums and
  // page size match the file at its path — which the old WAL does,
  // against the swapped-in copy, by construction. The rewrite must
  // therefore retire those frames *before* the copy is sworn in, not
  // unlink the file afterwards and hope.
  assert wal_bytes(path) > 0

  let seen = process.new_subject()
  let erase = repo.erase_text(needle:, replacement:)
  let assert Ok(sqlite.Rewrite(generation: 1, ..)) =
    repo.rewrite_sqlite(
      path:,
      clock: clock.fixed(at: 100_000),
      rewrite: fn(candidate) {
        // Observed from inside the copy pass: by the time any entry is
        // transformed, nothing that can resurrect the original's bytes
        // may remain beside it — the WAL is checkpointed and truncated
        // to zero (the rewrite's own lease claim included).
        process.send(seen, wal_bytes(path))
        erase(candidate)
      },
      rewrite_value: repo.erase_value(needle:, replacement:),
    )
  let assert Ok(0) = process.receive(seen, 1000)

  // End to end: reopening recovers nothing — the secret stays gone in
  // the raw bytes even after WAL recovery had its chance to run.
  let assert Ok(reopened) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 5000,
      clock: clock.fixed(at: 200_000),
    )
  let assert Ok(Nil) = session.close(reopened)
  let assert Ok(after) = simplifile.read_bits(path)
  assert !contains_bytes(after, bit_array.from_string(needle))
}

pub fn sqlite_rewrite_holds_the_lease_for_its_whole_duration_test() {
  let path = fresh_path("rewrite_lease_window")
  let assert Ok(source) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 5000,
      clock: clock.stepping(from: 10_000, by: 1),
    )
  let ctx = drive.new_ctx(source, 42)
  let #(_ctx, _) =
    drive.append_message(ctx, generate.user_text("please handle " <> needle))
  let assert Ok(Nil) = session.close(source)

  // M3-02's interleaving, made deterministic by using the transform as
  // the rewrite's elapsed time: a writer that opens mid-rewrite must be
  // refused by the held lease — before the fix it opened, committed
  // durably, and the swap silently discarded its commit.
  let outcomes = process.new_subject()
  let erase = repo.erase_text(needle:, replacement:)
  let assert Ok(sqlite.Rewrite(generation: 1, entries_rewritten: 1)) =
    repo.rewrite_sqlite(
      path:,
      clock: clock.fixed(at: 100_000),
      rewrite: fn(candidate) {
        let opened =
          session.open_sqlite(
            path:,
            owner: "intruder",
            lease_ttl_ms: 5000,
            clock: clock.fixed(at: 100_001),
          )
        let outcome = case opened {
          Ok(intruder) -> {
            // The pre-fix hole: the open was granted, so commit an entry
            // the swap would silently discard, and report the breach.
            let intruder_ctx = drive.new_ctx(intruder, 77)
            let #(_, _) =
              drive.append_message(
                intruder_ctx,
                generate.user_text("about to be lost"),
              )
            let _ = session.close(intruder)
            Error("a concurrent writer was granted the lease")
          }
          Error(session.SqliteOpenFailed(error: sqlite.LeaseHeld(owner:, ..))) ->
            Ok(owner)
          Error(other) -> Error(string.inspect(other))
        }
        process.send(outcomes, outcome)
        erase(candidate)
      },
      rewrite_value: repo.erase_value(needle:, replacement:),
    )
  let assert Ok(Ok("rewrite")) = process.receive(outcomes, 1000)

  // Nothing was lost and nothing leaked in: exactly the one seeded entry
  // survives, erased.
  let assert Ok(reopened) =
    session.open_sqlite(
      path:,
      owner: "writer-2",
      lease_ttl_ms: 5000,
      clock: clock.fixed(at: 200_000),
    )
  let assert Ok([only]) =
    storage.scan_entries(reopened.store, storage.entry_scan())
  let encoded = json.to_string(core_codec.encode_entry(only))
  assert string.contains(does: encoded, contain: replacement)
  let assert Ok(Nil) = session.close(reopened)
}

pub fn sqlite_rewrite_refuses_live_writer_test() {
  let path = fresh_path("rewrite_leased")
  let assert Ok(source) =
    session.open_sqlite(
      path:,
      owner: "writer-1",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 10_000),
    )
  let assert Error(sqlite.RewriteLeaseHeld(owner: "writer-1", ..)) =
    repo.rewrite_sqlite(
      path:,
      clock: clock.fixed(at: 10_001),
      rewrite: repo.erase_text(needle:, replacement:),
      rewrite_value: repo.erase_value(needle:, replacement:),
    )
  let assert Ok(Nil) = session.close(source)
}

pub fn sqlite_rewrite_requires_an_existing_file_test() {
  let path = fresh_path("rewrite_absent")
  let assert Error(sqlite.RewriteFailed(..)) =
    repo.rewrite_sqlite(
      path:,
      clock: clock.fixed(at: 10_000),
      rewrite: repo.erase_text(needle:, replacement:),
      rewrite_value: repo.erase_value(needle:, replacement:),
    )
  // Refusal must not conjure an empty database at the path.
  assert simplifile.is_file(path) == Ok(False)
}

// The size of the session's `-wal` sibling, with "absent" as zero — what
// matters to the audit is whether any replayable frame exists.
fn wal_bytes(path: String) -> Int {
  case simplifile.read_bits(path <> "-wal") {
    Ok(bits) -> bit_array.byte_size(bits)
    Error(_) -> 0
  }
}

// Byte-level substring search; the audit greps raw bytes, not decoded
// text, so free-page remnants cannot hide.
fn contains_bytes(haystack: BitArray, sub: BitArray) -> Bool {
  let hay_size = bit_array.byte_size(haystack)
  let sub_size = bit_array.byte_size(sub)
  contains_bytes_loop(haystack, sub, 0, hay_size - sub_size, sub_size)
}

fn contains_bytes_loop(
  haystack: BitArray,
  sub: BitArray,
  at: Int,
  last: Int,
  sub_size: Int,
) -> Bool {
  case at > last {
    True -> False
    False ->
      case bit_array.slice(from: haystack, at:, take: sub_size) {
        Ok(window) if window == sub -> True
        Ok(_) | Error(Nil) ->
          contains_bytes_loop(haystack, sub, at + 1, last, sub_size)
      }
  }
}
