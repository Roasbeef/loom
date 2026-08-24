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
import core/tx.{SetRegister, Tx}
import gleam/bit_array
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
  let assert Ok(_) =
    storage.commit(
      ctx.session.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.FactName,
            key: "session",
            value: register.value(json.String("clean name")),
          ),
        ],
        expected: [],
      ),
    )
  let assert Ok(repo.MemoryRewrite(session: rebuilt, entries_rewritten:)) =
    repo.rewrite_memory(
      source: ctx.session,
      rewrite: repo.erase_text(needle:, replacement:),
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
  // survive.
  let assert Ok([row]) = storage.scan_usage(rebuilt.store, storage.usage_scan())
  assert row.usage == generate.some_usage(90)
  let assert Ok(Some(_)) =
    storage.get_register(rebuilt.store, register.FactName, "session")
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
    )
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
    )
  // Refusal must not conjure an empty database at the path.
  assert simplifile.is_file(path) == Ok(False)
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
