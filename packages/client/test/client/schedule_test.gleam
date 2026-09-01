//// The schedule store: what `[[schedule]]` accepts, what it refuses in
//// words, and the two derived things a fire depends on — the durable
//// key shapes and the fenced text.
////
//// Mirrors `test/client/rules_test.gleam`'s style: one test per
//// refusal, named for the thing it proves, so a failing test names the
//// bound that broke rather than leaving that to a diff.

import client/schedule
import gleam/list
import gleam/string
import simplifile

// --- what parses -----------------------------------------------------------

pub fn a_document_with_no_schedule_tables_has_no_schedules_test() {
  assert schedule.parse("") == Ok([])
  assert schedule.parse("[models.x]\nmodel_id = \"m\"") == Ok([])
}

pub fn an_interval_schedule_parses_with_its_fields_test() {
  let assert Ok([sched]) =
    schedule.parse(
      "[[schedule]]
name = \"heartbeat\"
every = \"300s\"
body = \"Check on things.\"
",
    )
    as "a well-formed interval schedule must parse"
  assert sched.name == "heartbeat"
  assert sched.target == "main"
  assert sched.wake == False
  assert sched.body == "Check on things."
  assert sched.timing
    == schedule.Interval(
      seconds: 300,
      expiry: schedule.Expiry(
        max_fires: schedule.default_max_fires,
        expires_after_s: schedule.default_expires_after_s,
      ),
    )
}

pub fn a_one_shot_schedule_parses_with_its_fields_test() {
  let assert Ok([sched]) =
    schedule.parse(
      "[[schedule]]
name = \"reminder\"
at = \"2026-09-01T09:00:00Z\"
body = \"The window opens today.\"
",
    )
    as "a well-formed one-shot schedule must parse"
  assert sched.name == "reminder"
  assert sched.timing == schedule.OneShot(at: 1_788_253_200)
}

pub fn a_schedule_may_set_target_wake_and_expiry_explicitly_test() {
  let assert Ok([sched]) =
    schedule.parse(
      "[[schedule]]
name = \"watch\"
target = \"sub:main/reviewer-abc\"
every = \"120s\"
max_fires = 5
expires_after_s = 3600
wake = true
body = \"Watch the subagent.\"
",
    )
    as "a fully specified interval schedule must parse"
  assert sched.target == "sub:main/reviewer-abc"
  assert sched.wake == True
  assert sched.timing
    == schedule.Interval(
      seconds: 120,
      expiry: schedule.Expiry(max_fires: 5, expires_after_s: 3600),
    )
}

pub fn schedules_keep_the_order_the_file_gave_them_test() {
  let assert Ok(parsed) =
    schedule.parse(
      "[[schedule]]
name = \"zulu\"
every = \"60s\"
body = \"z\"

[[schedule]]
name = \"alpha\"
every = \"60s\"
body = \"a\"
",
    )
    as "two schedules must parse"
  assert list.map(parsed, fn(sched) { sched.name }) == ["zulu", "alpha"]
}

pub fn a_schedule_table_sits_beside_the_catalogue_tables_test() {
  let assert Ok([sched]) =
    schedule.parse(
      "[models.acme]
dialect = \"anthropic\"

[roles]
main = [\"acme\"]

[[schedule]]
name = \"s\"
every = \"60s\"
body = \"b\"
",
    )
    as "a schedule beside a catalogue must parse"
  assert sched.name == "s"
}

// --- what is refused, and in what words -------------------------------------

pub fn a_schedule_that_is_not_a_table_array_is_refused_test() {
  let assert Error(reason) = schedule.parse("schedule = 3")
    as "a scalar `schedule` must be refused"
  assert string.contains(reason, "array of [[schedule]] tables")
}

pub fn an_unknown_key_inside_a_schedule_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]
name = \"s\"
every = \"60s\"
body = \"b\"
frequency = \"typo\"
",
    )
    as "a typoed key must be refused, not ignored"
  assert string.contains(reason, "unknown key `frequency`")
}

pub fn a_missing_body_is_named_test() {
  let assert Error(reason) =
    schedule.parse("[[schedule]]\nname = \"s\"\nevery = \"60s\"")
    as "a schedule with no body must be refused"
  assert reason == "schedule 1 (s).body is required"
}

pub fn an_empty_name_is_refused_test() {
  let assert Error(reason) =
    schedule.parse("[[schedule]]\nname = \"\"\nevery = \"60s\"\nbody = \"b\"")
    as "an empty name must be refused"
  assert reason == "schedule 1.name must be non-empty"
}

pub fn a_slash_in_a_schedule_name_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"a/b\"\nevery = \"60s\"\nbody = \"b\"",
    )
    as "a slash in a schedule name must be refused"
  assert string.contains(reason, "must not contain `/`")
}

pub fn a_quote_in_a_schedule_name_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"a\\\"b\"\nevery = \"60s\"\nbody = \"b\"",
    )
    as "a quote in a schedule name must be refused"
  assert string.contains(reason, "quote or a newline")
}

pub fn a_newline_in_a_schedule_name_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"a\\nb\"\nevery = \"60s\"\nbody = \"b\"",
    )
    as "a newline in a schedule name must be refused"
  assert string.contains(reason, "quote or a newline")
}

pub fn an_oversized_name_is_refused_test() {
  let name = string.repeat("n", schedule.max_name_length + 1)
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"" <> name <> "\"\nevery = \"60s\"\nbody = \"b\"",
    )
    as "an oversized name must be refused"
  assert string.contains(reason, "at most 64 characters")
}

pub fn an_oversized_body_is_refused_test() {
  let body = string.repeat("x", schedule.max_body_length + 1)
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\nevery = \"60s\"\nbody = \"" <> body <> "\"",
    )
    as "an oversized body must be refused"
  assert string.contains(reason, "at most 8192 characters")
}

pub fn a_body_exactly_at_the_bound_is_accepted_test() {
  let body = string.repeat("x", schedule.max_body_length)
  let assert Ok([sched]) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\nevery = \"60s\"\nbody = \"" <> body <> "\"",
    )
    as "a body exactly at the bound must be accepted"
  assert sched.body == body
}

pub fn an_empty_target_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\ntarget = \"\"\nevery = \"60s\"\nbody = \"b\"",
    )
    as "an empty target must be refused"
  assert string.contains(reason, "target must be non-empty")
}

pub fn an_oversized_target_is_refused_test() {
  let target = string.repeat("t", schedule.max_target_length + 1)
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\ntarget = \""
      <> target
      <> "\"\nevery = \"60s\"\nbody = \"b\"",
    )
    as "an oversized target must be refused"
  assert string.contains(reason, "target must be at most 64 characters")
}

pub fn a_target_may_itself_contain_a_slash_test() {
  let assert Ok([sched]) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\ntarget = \"sub:main/child-1\"\n"
      <> "every = \"60s\"\nbody = \"b\"",
    )
    as "a slash in a target must be accepted: strand names may carry one"
  assert sched.target == "sub:main/child-1"
}

pub fn too_many_schedules_are_refused_test() {
  let document =
    string.repeat(
      "[[schedule]]\nname = \"s\"\nevery = \"60s\"\nbody = \"b\"\n",
      schedule.max_schedules + 1,
    )
  let assert Error(reason) = schedule.parse(document)
    as "more schedules than the bound must be refused"
  assert string.contains(reason, "more than the 16")
}

pub fn a_duplicate_schedule_name_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]
name = \"s\"
every = \"60s\"
body = \"a\"

[[schedule]]
name = \"s\"
every = \"90s\"
body = \"b\"
",
    )
    as "a duplicate schedule name must be refused"
  assert string.contains(reason, "two schedules are named s")
}

pub fn malformed_toml_is_refused_in_words_test() {
  let assert Error(reason) = schedule.parse("[[schedule]\nname = ")
    as "malformed toml must be refused"
  assert string.contains(reason, "not valid toml")
}

// --- every/at, and their mutual exclusivity ---------------------------------

pub fn neither_every_nor_at_is_refused_test() {
  let assert Error(reason) =
    schedule.parse("[[schedule]]\nname = \"s\"\nbody = \"b\"")
    as "a schedule with no timing must be refused"
  assert string.contains(reason, "must set exactly one of .every or .at")
}

pub fn both_every_and_at_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\nevery = \"60s\"\n"
      <> "at = \"2026-01-01T00:00:00Z\"\nbody = \"b\"",
    )
    as "a schedule naming both every and at must be refused"
  assert string.contains(reason, "mutually exclusive")
}

pub fn an_every_with_a_non_numeric_unit_is_refused_test() {
  let assert Error(reason) =
    schedule.parse("[[schedule]]\nname = \"s\"\nevery = \"5m\"\nbody = \"b\"")
    as "a non-second unit must be refused"
  assert string.contains(reason, "no other unit is understood")
}

pub fn an_every_with_no_unit_is_refused_test() {
  let assert Error(reason) =
    schedule.parse("[[schedule]]\nname = \"s\"\nevery = \"300\"\nbody = \"b\"")
    as "every with no unit suffix must be refused"
  assert string.contains(reason, "no other unit is understood")
}

pub fn a_negative_every_is_refused_test() {
  let assert Error(reason) =
    schedule.parse("[[schedule]]\nname = \"s\"\nevery = \"-60s\"\nbody = \"b\"")
    as "a negative every must be refused"
  assert string.contains(reason, "positive whole number")
}

pub fn a_zero_every_is_refused_test() {
  let assert Error(reason) =
    schedule.parse("[[schedule]]\nname = \"s\"\nevery = \"0s\"\nbody = \"b\"")
    as "a zero every must be refused"
  assert string.contains(reason, "must be a positive number of seconds")
}

pub fn an_every_below_the_minimum_is_refused_test() {
  let assert Error(reason) =
    schedule.parse("[[schedule]]\nname = \"s\"\nevery = \"59s\"\nbody = \"b\"")
    as "an every below the minimum must be refused"
  assert string.contains(reason, "below the 60s minimum")
}

pub fn an_every_at_the_minimum_is_accepted_test() {
  let assert Ok([sched]) =
    schedule.parse("[[schedule]]\nname = \"s\"\nevery = \"60s\"\nbody = \"b\"")
    as "every at the minimum must be accepted"
  assert sched.timing
    == schedule.Interval(
      seconds: 60,
      expiry: schedule.Expiry(
        max_fires: schedule.default_max_fires,
        expires_after_s: schedule.default_expires_after_s,
      ),
    )
}

pub fn an_at_that_is_not_rfc3339_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\nat = \"not a timestamp\"\nbody = \"b\"",
    )
    as "a malformed at must be refused"
  assert string.contains(reason, "RFC3339")
}

pub fn an_at_missing_its_offset_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\nat = \"2026-01-01T00:00:00\"\nbody = \"b\"",
    )
    as "an at with no offset must be refused"
  assert string.contains(reason, "RFC3339")
}

// --- max_fires / expires_after_s --------------------------------------------

pub fn max_fires_alongside_at_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\nat = \"2026-01-01T00:00:00Z\"\n"
      <> "max_fires = 5\nbody = \"b\"",
    )
    as "max_fires beside at must be refused"
  assert string.contains(reason, "max_fires is only valid alongside .every")
}

pub fn expires_after_s_alongside_at_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\nat = \"2026-01-01T00:00:00Z\"\n"
      <> "expires_after_s = 60\nbody = \"b\"",
    )
    as "expires_after_s beside at must be refused"
  assert string.contains(
    reason,
    "expires_after_s is only valid alongside .every",
  )
}

pub fn a_zero_max_fires_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\nevery = \"60s\"\nmax_fires = 0\nbody = \"b\"",
    )
    as "a zero max_fires must be refused"
  assert string.contains(reason, "max_fires must be between 1 and 1000")
}

pub fn a_max_fires_above_the_ceiling_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\nevery = \"60s\"\nmax_fires = 1001\n"
      <> "body = \"b\"",
    )
    as "a max_fires above the ceiling must be refused"
  assert string.contains(reason, "max_fires must be between 1 and 1000")
}

pub fn a_max_fires_at_the_ceiling_is_accepted_test() {
  let assert Ok([sched]) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\nevery = \"60s\"\nmax_fires = 1000\n"
      <> "body = \"b\"",
    )
    as "a max_fires at the ceiling must be accepted"
  let assert schedule.Interval(expiry:, ..) = sched.timing
    as "an interval schedule must carry an expiry"
  assert expiry.max_fires == 1000
}

pub fn an_expires_after_s_above_the_ceiling_is_refused_test() {
  let assert Error(reason) =
    schedule.parse(
      "[[schedule]]\nname = \"s\"\nevery = \"60s\"\n"
      <> "expires_after_s = 604801\nbody = \"b\"",
    )
    as "an expires_after_s above the ceiling must be refused"
  assert string.contains(reason, "expires_after_s must be between 1 and 604800")
}

// --- fired_key / fired_key_prefix --------------------------------------------

pub fn the_fired_key_is_reserved_and_addressable_test() {
  let key =
    schedule.fired_key(strand: "main", name: "heartbeat", occurrence: 300)
  assert key == "schedule/fired/main/heartbeat/300"
  assert string.starts_with(key, "schedule/")
}

pub fn the_fired_key_prefix_is_a_clean_prefix_of_the_fired_key_test() {
  let prefix = schedule.fired_key_prefix(strand: "main", name: "heartbeat")
  let key =
    schedule.fired_key(strand: "main", name: "heartbeat", occurrence: 600)
  assert prefix == "schedule/fired/main/heartbeat/"
  assert string.starts_with(key, prefix)
}

pub fn distinct_targets_produce_distinct_key_prefixes_test() {
  let one = schedule.fired_key_prefix(strand: "main", name: "heartbeat")
  let other =
    schedule.fired_key_prefix(strand: "sub:main/child", name: "heartbeat")
  assert one != other
}

// --- interval occurrence arithmetic ------------------------------------
//
// Direct, deterministic tests of the pure functions `client/schedulescan`
// drives its timer off — the arithmetic an actor-and-timer test can only
// exercise indirectly, and where a fencepost error is easy to write and
// easy to miss when it hides behind a full harness.

pub fn interval_occurrence_floors_to_the_slot_boundary_test() {
  assert schedule.interval_occurrence(seconds: 60, now_s: 125) == 120
  assert schedule.interval_occurrence(seconds: 60, now_s: 120) == 120
  assert schedule.interval_occurrence(seconds: 60, now_s: 0) == 0
}

pub fn the_very_first_occurrence_is_never_late_test() {
  assert !schedule.interval_late(occurrences: [], seconds: 60, occurrence: 0)
}

// The case the bug lived in: a naive "is `now_s` past this occurrence's
// own boundary" check is always false, because the occurrence is derived
// *from* `now_s` in the first place (`interval_occurrence`). Lateness has
// to come from whether the immediately preceding slot actually fired.
pub fn an_on_time_fire_whose_previous_slot_fired_is_not_late_test() {
  assert !schedule.interval_late(occurrences: [0], seconds: 60, occurrence: 60)
  assert !schedule.interval_late(
    occurrences: [0, 60],
    seconds: 60,
    occurrence: 120,
  )
}

pub fn a_fire_after_a_skipped_window_is_late_test() {
  // Only slot 0 ever fired; the current occurrence is four windows later,
  // so the immediately preceding slot (180) was never fired.
  assert schedule.interval_late(occurrences: [0], seconds: 60, occurrence: 240)
}

pub fn lateness_only_looks_at_the_immediately_preceding_slot_test() {
  // The previous slot (60) is missing even though an *older* one (0) is
  // present — this must still read as late, not as "some history exists
  // so it's fine."
  assert schedule.interval_late(occurrences: [0], seconds: 60, occurrence: 120)
}

pub fn expiry_is_reached_by_fire_count_alone_test() {
  assert schedule.interval_expired(
    occurrences: [0, 60],
    expiry: schedule.Expiry(max_fires: 2, expires_after_s: 604_800),
    now_s: 120,
  )
}

pub fn expiry_is_reached_by_age_alone_test() {
  assert schedule.interval_expired(
    occurrences: [0],
    expiry: schedule.Expiry(max_fires: 1000, expires_after_s: 100),
    now_s: 101,
  )
}

pub fn expiry_is_not_reached_below_either_bound_test() {
  assert !schedule.interval_expired(
    occurrences: [0],
    expiry: schedule.Expiry(max_fires: 1000, expires_after_s: 604_800),
    now_s: 120,
  )
}

pub fn a_schedule_that_has_never_fired_is_never_expired_by_age_test() {
  assert !schedule.interval_expired(
    occurrences: [],
    expiry: schedule.Expiry(max_fires: 1000, expires_after_s: 1),
    now_s: 1_000_000,
  )
}

// --- the injected text -----------------------------------------------------

fn sched() -> schedule.Schedule {
  schedule.Schedule(
    name: "heartbeat",
    target: "main",
    timing: schedule.Interval(
      seconds: 300,
      expiry: schedule.Expiry(max_fires: 10, expires_after_s: 3600),
    ),
    wake: False,
    body: "the body",
  )
}

pub fn the_injection_names_itself_and_fences_the_body_test() {
  let text = schedule.injection(sched(), False)
  assert string.contains(text, "scheduled heartbeat \"heartbeat\"")
  assert string.contains(text, "not a turn from the user")
  assert string.contains(
    text,
    "--- begin scheduled heartbeat \"heartbeat\" ---",
  )
  assert string.contains(text, "the body")
  assert string.contains(text, "--- end scheduled heartbeat \"heartbeat\" ---")
}

pub fn a_prompt_fire_carries_no_late_annotation_test() {
  let text = schedule.injection(sched(), False)
  assert !string.contains(text, "This fire is late")
}

pub fn a_late_fire_says_so_test() {
  let text = schedule.injection(sched(), True)
  assert string.contains(text, "This fire is late")
}

// --- the committed example ------------------------------------------------

// The worked `loom.toml` in `docs/examples` is the operator's only
// discovery surface for a feature no model can reach for, so a documented
// example that would refuse the boot is worse than none — the same
// argument `rules_test` makes for its own half of the file, and the one
// this feature already failed once by shipping a `[[schedule]]` no
// `catalog.parse` would admit.
pub fn the_committed_example_config_parses_its_schedules_test() {
  let assert Ok(text) = simplifile.read("../../docs/examples/loom.toml")
    as "the committed example config must be readable"
  let assert Ok(parsed) = schedule.parse(text)
    as "the committed example config's schedules must parse"
  assert list.map(parsed, fn(sched: schedule.Schedule) { sched.name })
    == ["watch-reviewer", "migration-window"]
}

// The example shows both timings, because an operator reading one shape
// only would have to infer the other from prose.
pub fn the_committed_example_shows_both_timings_test() {
  let assert Ok(text) = simplifile.read("../../docs/examples/loom.toml")
    as "the committed example config must be readable"
  let assert Ok(parsed) = schedule.parse(text)
    as "the committed example config's schedules must parse"
  let timings =
    list.map(parsed, fn(sched: schedule.Schedule) {
      case sched.timing {
        schedule.Interval(..) -> "interval"
        schedule.OneShot(..) -> "one-shot"
      }
    })
  assert timings == ["interval", "one-shot"]
}
