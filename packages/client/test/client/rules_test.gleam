//// The rule store: what `[[rule]]` accepts, what it refuses in words,
//// and the two derived things a fire depends on — the literal match and
//// the fenced text.
////
//// The refusal rows carry most of the weight here. A rule store is
//// operator configuration that ends up inside a model's context, so
//// every way a typo could turn into a rule that silently never fires,
//// or into a durable key that collides with another rule's, is a row
//// below.

import client/rules
import core/entry
import core/ids
import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile

// --- what parses -----------------------------------------------------------

pub fn a_document_with_no_rule_tables_has_no_rules_test() {
  assert rules.parse("") == Ok([])
  assert rules.parse("[models.x]\nmodel_id = \"m\"") == Ok([])
}

pub fn one_rule_parses_with_its_three_fields_test() {
  let assert Ok([rule]) =
    rules.parse(
      "[[rule]]
name = \"schema-gate\"
triggers = [\"migrations/\", \"ALTER TABLE\"]
body = \"Run make check-storage first.\"
",
    )
    as "a well-formed rule must parse"
  assert rule.name == "schema-gate"
  assert rule.triggers == ["migrations/", "ALTER TABLE"]
  assert rule.body == "Run make check-storage first."
}

// File order, not sorted order: an array of tables is ordered in TOML
// itself, and the order decides which rule is offered a run first when
// two fire on the same entry.
pub fn rules_keep_the_order_the_file_gave_them_test() {
  let assert Ok(parsed) =
    rules.parse(
      "[[rule]]
name = \"zulu\"
triggers = [\"z\"]
body = \"z\"

[[rule]]
name = \"alpha\"
triggers = [\"a\"]
body = \"a\"
",
    )
    as "two rules must parse"
  assert list.map(parsed, fn(rule) { rule.name }) == ["zulu", "alpha"]
}

// The catalogue and the rules read the same document, and neither may
// refuse the other's tables.
pub fn a_rule_table_sits_beside_the_catalogue_tables_test() {
  let assert Ok([rule]) =
    rules.parse(
      "[models.acme]
dialect = \"anthropic\"

[roles]
main = [\"acme\"]

[[rule]]
name = \"r\"
triggers = [\"t\"]
body = \"b\"
",
    )
    as "a rule beside a catalogue must parse"
  assert rule.name == "r"
}

// --- what is refused, and in what words ------------------------------------

pub fn a_rule_that_is_not_a_table_array_is_refused_test() {
  let assert Error(reason) = rules.parse("rule = 3")
    as "a scalar `rule` must be refused"
  assert string.contains(reason, "array of [[rule]] tables")
}

pub fn an_unknown_key_inside_a_rule_is_refused_test() {
  let assert Error(reason) =
    rules.parse(
      "[[rule]]
name = \"r\"
triggers = [\"t\"]
body = \"b\"
trigger = \"typo\"
",
    )
    as "a typoed key must be refused, not ignored"
  assert string.contains(reason, "unknown key `trigger`")
}

pub fn a_missing_field_is_named_test() {
  let assert Error(reason) = rules.parse("[[rule]]\nname = \"r\"\nbody = \"b\"")
    as "a rule with no triggers must be refused"
  assert reason == "rule 1 (r).triggers is required"
}

pub fn an_empty_name_is_refused_test() {
  let assert Error(reason) =
    rules.parse("[[rule]]\nname = \"\"\ntriggers = [\"t\"]\nbody = \"b\"")
    as "an empty name must be refused"
  assert reason == "rule 1.name must be non-empty"
}

// An empty trigger occurs in every string, so it would fire the rule on
// the first assistant message of the session — a rule with no trigger
// wearing a trigger's clothes.
pub fn an_empty_trigger_is_refused_test() {
  let assert Error(reason) =
    rules.parse("[[rule]]\nname = \"r\"\ntriggers = [\"\"]\nbody = \"b\"")
    as "an empty trigger must be refused"
  assert string.contains(reason, "empty trigger matches every message")
}

pub fn an_empty_trigger_list_is_refused_test() {
  let assert Error(reason) =
    rules.parse("[[rule]]\nname = \"r\"\ntriggers = []\nbody = \"b\"")
    as "a rule with no triggers at all must be refused"
  assert string.contains(reason, "must name at least one trigger")
}

pub fn a_non_string_trigger_is_refused_test() {
  let assert Error(reason) =
    rules.parse("[[rule]]\nname = \"r\"\ntriggers = [7]\nbody = \"b\"")
    as "a numeric trigger must be refused"
  assert string.contains(reason, "array of literal strings")
}

// Two rules under one name would share one fired-mark, so the first to
// fire would silence the second for the rest of the session.
pub fn a_duplicate_rule_name_is_refused_test() {
  let assert Error(reason) =
    rules.parse(
      "[[rule]]
name = \"r\"
triggers = [\"a\"]
body = \"a\"

[[rule]]
name = \"r\"
triggers = [\"b\"]
body = \"b\"
",
    )
    as "a duplicate rule name must be refused"
  assert string.contains(reason, "two rules are named r")
}

// The newline shares the quote's refusal: both would break the fence.
// TOML's `\n` escape in a basic string decodes to a real newline, which
// is how one reaches a parsed name at all.
pub fn a_newline_in_a_rule_name_is_refused_test() {
  let assert Error(reason) =
    rules.parse("[[rule]]\nname = \"a\\nb\"\ntriggers = [\"t\"]\nbody = \"b\"")
    as "a newline in a rule name must be refused"
  assert string.contains(reason, "quote or a newline")
}

// The name is a segment of `rule/fired/<strand>/<name>`, so a slash in
// it would make the strand segment unreadable.
pub fn a_slash_in_a_rule_name_is_refused_test() {
  let assert Error(reason) =
    rules.parse("[[rule]]\nname = \"a/b\"\ntriggers = [\"t\"]\nbody = \"b\"")
    as "a slash in a rule name must be refused"
  assert string.contains(reason, "must not contain `/`")
}

// The name is quoted inside the injected fence.
pub fn a_quote_in_a_rule_name_is_refused_test() {
  let assert Error(reason) =
    rules.parse("[[rule]]\nname = \"a\\\"b\"\ntriggers = [\"t\"]\nbody = \"b\"")
    as "a quote in a rule name must be refused"
  assert string.contains(reason, "quote or a newline")
}

pub fn an_oversized_body_is_refused_test() {
  let body = string.repeat("x", rules.max_body_length + 1)
  let assert Error(reason) =
    rules.parse(
      "[[rule]]\nname = \"r\"\ntriggers = [\"t\"]\nbody = \"" <> body <> "\"",
    )
    as "an oversized body must be refused"
  assert string.contains(reason, "at most 8192 characters")
}

pub fn a_body_exactly_at_the_bound_is_accepted_test() {
  let body = string.repeat("x", rules.max_body_length)
  let assert Ok([rule]) =
    rules.parse(
      "[[rule]]\nname = \"r\"\ntriggers = [\"t\"]\nbody = \"" <> body <> "\"",
    )
    as "a body exactly at the bound must be accepted"
  assert rule.body == body
}

pub fn an_oversized_name_is_refused_test() {
  let name = string.repeat("n", rules.max_name_length + 1)
  let assert Error(reason) =
    rules.parse(
      "[[rule]]\nname = \"" <> name <> "\"\ntriggers = [\"t\"]\nbody = \"b\"",
    )
    as "an oversized name must be refused"
  assert string.contains(reason, "at most 64 characters")
}

pub fn too_many_rules_are_refused_test() {
  let document =
    string.repeat(
      "[[rule]]\nname = \"r\"\ntriggers = [\"t\"]\nbody = \"b\"\n",
      rules.max_rules + 1,
    )
  let assert Error(reason) = rules.parse(document)
    as "more rules than the bound must be refused"
  assert string.contains(reason, "more than the 64")
}

pub fn too_many_triggers_are_refused_test() {
  // Distinct trigger strings, one more than the bound allows.
  let triggers =
    string.repeat("x", rules.max_triggers + 1)
    |> string.to_graphemes
    |> list.index_map(fn(_char, index) {
      "\"t" <> string.inspect(index) <> "\""
    })
    |> string.join(", ")
  let assert Error(reason) =
    rules.parse(
      "[[rule]]\nname = \"r\"\ntriggers = [" <> triggers <> "]\nbody = \"b\"",
    )
    as "more triggers than the bound must be refused"
  assert string.contains(reason, "more than the 32")
}

pub fn malformed_toml_is_refused_in_words_test() {
  let assert Error(reason) = rules.parse("[[rule]\nname = ")
    as "malformed toml must be refused"
  assert string.contains(reason, "not valid toml")
}

// --- matching --------------------------------------------------------------

fn rule(triggers: List(String)) -> rules.Rule {
  rules.Rule(name: "r", triggers:, body: "the body")
}

pub fn a_trigger_matches_as_a_literal_substring_test() {
  assert rules.fires_on(rule(["ALTER TABLE"]), "then I will ALTER TABLE users")
}

pub fn a_trigger_is_case_sensitive_test() {
  assert !rules.fires_on(rule(["ALTER TABLE"]), "then i will alter table users")
}

pub fn any_one_trigger_fires_the_rule_test() {
  assert rules.fires_on(rule(["nope", "yes"]), "the answer is yes")
}

// A trigger is a literal, not a pattern: the regex metacharacters mean
// themselves, which is exactly the property that keeps an operator's
// config from being an unbounded computation over model output.
pub fn a_trigger_is_not_a_pattern_test() {
  assert !rules.fires_on(rule([".*"]), "anything at all")
  assert rules.fires_on(rule([".*"]), "a literal .* in the text")
}

// --- what is scannable -----------------------------------------------------

fn entry_id() -> ids.EntryId {
  let assert Ok(id) = ids.parse_entry_id("01890000-0000-7000-8000-000000000001")
    as "the fixture entry id must parse"
  id
}

fn assistant(text: String, stop: message.StopReason) -> entry.Entry {
  entry.MessageEntry(
    id: entry_id(),
    parent: None,
    seq: 1,
    ts: 0,
    terminate: False,
    message: message.AssistantMessage(
      content: [
        message.AssistantThinking(
          thinking: "a hidden thought",
          thinking_signature: None,
          redacted: False,
        ),
        message.AssistantText(text:, text_signature: None),
      ],
      api: "anthropic",
      provider: "acme",
      model: "loom-1",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: no_usage(),
      stop_reason: stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: 0,
    ),
  )
}

fn no_usage() -> message.Usage {
  message.Usage(
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 0,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

pub fn a_settled_assistant_entry_offers_its_visible_text_test() {
  assert rules.scannable_text(assistant("said out loud", message.Stop))
    == Some("said out loud")
}

// Thinking is not visible text, so it is not scannable — the same line
// `events/search` draws, drawn by the same function.
pub fn thinking_is_not_scannable_test() {
  let assert Some(text) =
    rules.scannable_text(assistant("visible", message.Stop))
    as "a settled assistant entry must be scannable"
  assert !string.contains(text, "a hidden thought")
}

// The projection drops these three, so a rule that fired on one would
// fire on text the model will never see again — and an `error` response
// carries the harness's own failure prose, not model output.
pub fn a_dropped_assistant_response_is_not_scannable_test() {
  assert rules.scannable_text(assistant("x", message.Errored)) == None
  assert rules.scannable_text(assistant("x", message.Aborted)) == None
  assert rules.scannable_text(assistant("x", message.Deferred)) == None
}

pub fn a_user_entry_is_not_scannable_test() {
  let user =
    entry.MessageEntry(
      id: entry_id(),
      parent: None,
      seq: 1,
      ts: 0,
      terminate: False,
      message: message.UserMessage(
        content: [message.UserText(text: "ALTER TABLE", text_signature: None)],
        timestamp: 0,
      ),
    )
  assert rules.scannable_text(user) == None
}

// --- the durable half ------------------------------------------------------

pub fn the_fired_key_is_reserved_and_addressable_test() {
  let key = rules.fired_key(strand: "main", rule: "schema-gate")
  assert key == "rule/fired/main/schema-gate"
  assert string.starts_with(key, "rule/")
}

pub fn the_cursor_key_is_reserved_test() {
  assert rules.cursor_key(strand: "sub:1") == "rule/cursor/sub:1"
}

// A cursor that cannot be read starts the scanner from the beginning,
// which costs a bounded re-scan and injects nothing twice. Refusing to
// start would stop every rule in the session over one bad cell.
pub fn an_unreadable_cursor_reads_as_the_beginning_test() {
  assert rules.cursor_seq(Some(json.Int(42))) == 42
  assert rules.cursor_seq(Some(json.String("nonsense"))) == 0
  assert rules.cursor_seq(None) == 0
}

// --- the injected text -----------------------------------------------------

pub fn the_injection_names_itself_and_fences_the_body_test() {
  let text = rules.injection(rules.Rule("schema-gate", ["t"], "the body"))
  assert string.contains(text, "triggered project rule \"schema-gate\"")
  assert string.contains(text, "not a turn from the user")
  assert string.contains(text, "--- begin project rule \"schema-gate\" ---")
  assert string.contains(text, "the body")
  assert string.contains(text, "--- end project rule \"schema-gate\" ---")
}

// --- the committed example ------------------------------------------------

// The worked `loom.toml` in `docs/examples` carries both halves of the
// file, and both parsers must accept the whole of it: a documented
// example that would refuse the boot is worse than none.
pub fn the_committed_example_config_parses_its_rules_test() {
  let assert Ok(text) = simplifile.read("../../docs/examples/loom.toml")
    as "the committed example config must be readable"
  let assert Ok(parsed) = rules.parse(text)
    as "the committed example config's rules must parse"
  assert list.map(parsed, fn(rule) { rule.name })
    == ["schema-gate", "no-force-push"]
}
