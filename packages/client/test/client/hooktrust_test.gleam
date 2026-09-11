//// The hook trust record's contract: one file per source, hash-pinned,
//// total decode, and a verdict that follows the hash alone. Every test
//// here is a pure file test under `build/`, so the suite runs without a
//// harness or a helper.

import client/hookcompat.{Source, UserSettings}
import client/hooktrust
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile

// The scratch directory every test writes under. Cleaned at the start
// of each test rather than the end, so a failed run leaves its state
// for inspection and a rerun starts fresh.
const root = "build/hooktrust-test"

// Two fixtures that differ in one handler's command, so their hashes
// differ and the trust verdict can be observed to flip.
const fixture_a = "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"lint.sh\"}]}]}}"

const fixture_b = "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"lint2.sh\"}]}]}}"

fn fresh_dir() {
  let _cleared = simplifile.delete_all([root])
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the test root must be creatable"
  Nil
}

fn config_a() {
  let assert Ok(config) = hookcompat.parse_claude(fixture_a, source())
    as "fixture a must parse"
  config
}

fn config_b() {
  let assert Ok(config) = hookcompat.parse_claude(fixture_b, source())
    as "fixture b must parse"
  config
}

fn source() {
  Source(label: "user settings", origin: UserSettings)
}

// --- round trip -------------------------------------------------------------

pub fn a_record_round_trips_through_save_and_load_test() {
  fresh_dir()
  let path = root <> "/user-settings.json"
  let record =
    hooktrust.Record(
      label: "user settings",
      origin: "user-settings",
      hash: "abc123",
      trusted_at_ms: 1_700_000_000_000,
    )

  let assert Ok(Nil) = hooktrust.save(path, record) as "the record must save"
  let assert Ok(read) = hooktrust.load(path) as "the record must load back"
  assert read == record
  let _removed = simplifile.delete_all([root])
  Nil
}

// --- the verdict ------------------------------------------------------------

pub fn check_is_trusted_after_trust_and_reviews_after_a_change_test() {
  fresh_dir()
  let path = root <> "/user-settings.json"
  let config = config_a()

  // No record yet: first sight is a review, not a trust.
  assert hooktrust.check(None, config) == hooktrust.NeedsReview

  let assert Ok(Nil) = hooktrust.trust(path, config, 1_700_000_000_000)
    as "trust must record the current hash"
  let assert Ok(record) = hooktrust.load(path)
    as "the trusted record must be on disk"
  assert hooktrust.check(Some(record), config) == hooktrust.Trusted

  // A changed definition re-enters review: the hash moved.
  let changed = config_b()
  assert hooktrust.check(Some(record), changed) == hooktrust.NeedsReview
  let _removed = simplifile.delete_all([root])
  Nil
}

// --- revoke -----------------------------------------------------------------

pub fn revoke_deletes_the_record_and_absent_revoke_succeeds_test() {
  fresh_dir()
  let path = root <> "/user-settings.json"
  let assert Ok(Nil) = hooktrust.trust(path, config_a(), 1_700_000_000_000)
    as "trust must record before revoke"

  let assert Ok(Nil) = hooktrust.revoke(path) as "revoke must delete the record"
  assert hooktrust.load(path) |> result_is_error()

  // Revoking an already-absent record is the state the operator asked
  // for, reached twice — success, not an error.
  let assert Ok(Nil) = hooktrust.revoke(path)
    as "revoking an absent record must succeed"
  let _removed = simplifile.delete_all([root])
  Nil
}

fn result_is_error(result: Result(a, String)) -> Bool {
  case result {
    Error(_) -> True
    Ok(_) -> False
  }
}

// --- scan -------------------------------------------------------------------

pub fn scan_lists_two_records_and_skips_a_malformed_one_test() {
  fresh_dir()
  let path_a = root <> "/user-settings.json"
  let path_b = root <> "/project-settings.json"
  let assert Ok(Nil) = hooktrust.trust(path_a, config_a(), 1_700_000_000_000)
    as "the first record must save"
  let assert Ok(Nil) = hooktrust.trust(path_b, config_b(), 1_700_000_000_000)
    as "the second record must save"

  // A corrupt file is data about a broken state, not a crash: scan
  // skips it and the well-formed records still come back.
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/broken.json", contents: "{not json")
    as "the corrupt fixture must write"

  let records = hooktrust.scan(root)
  assert list.length(records) == 2
  assert list.all(records, fn(record) { record.hash != "" })
  let _removed = simplifile.delete_all([root])
  Nil
}

// --- safe names -------------------------------------------------------------

pub fn a_label_with_slashes_sanitizes_to_one_filename_test() {
  assert hooktrust.safe_name("user settings") == "user-settings.json"
  assert hooktrust.safe_name("a/b/c") == "a-b-c.json"
  assert hooktrust.safe_name("plugin:memory") == "plugin-memory.json"
  assert hooktrust.safe_name("plain") == "plain.json"
  Nil
}

// --- the one-line summary ---------------------------------------------------

pub fn describes_renders_the_trusted_hash_prefix_and_time_test() {
  let record =
    hooktrust.Record(
      label: "user settings",
      origin: "user-settings",
      hash: "abcdef1234567890",
      trusted_at_ms: 1_700_000_000_000,
    )

  assert string.starts_with(
    hooktrust.describes(record),
    "user settings: trusted abcdef123456 at ",
  )
  Nil
}
