//// Triggered project rules: the operator-authored store, the literal
//// trigger match, the durable key shapes, and the fenced text a fire
//// actually injects.
////
//// A project rule is a paragraph of standing instruction that only
//// matters some of the time — "when you touch the migration files, run
//// the schema gate first". Carrying it in the system prompt costs its
//// tokens on every request of every run forever. Design §8's answer is
//// to keep it out of the context entirely until model output says it
//// has become relevant, and then inject it once. This module is the
//// store half of that; `client/rulescan` is the scanner that watches.
////
//// ## Rules are operator configuration, never model-writable
////
//// A rule is text the harness injects into a model's own context, which
//// makes a model-writable rule store durable prompt injection with a
//// delivery mechanism attached: one run writes the rule, a later run
//// (or a later session) is handed it as if the operator had said it.
//// So rules live in `loom.toml` beside the model catalogue, an operator
//// edits them with an editor, and restarting the server *is* the trust
//// decision — the same posture `client/catalog` takes for MCP server
//// argv, and for the same reason.
////
//// ```toml
//// [[rule]]
//// name = "schema-gate"
//// triggers = ["migrations/", "ALTER TABLE"]
//// body = """
//// Before proposing a migration, run `make check-storage` and paste the
//// failing rows. The schema gate is not optional.
//// """
//// ```
////
//// ## What a trigger is, and what it deliberately is not
////
//// A trigger is a **literal, case-sensitive substring**. Any one of a
//// rule's triggers firing fires the rule. There is no regular
//// expression syntax, and adding one is not a small feature: an
//// operator-supplied pattern is an unbounded computation reached from
//// model output, which is the one place a catastrophic backtrack would
//// be *driven* by the thing being matched. Literals are also what the
//// feature is actually for — a path fragment, a command name, a phrase
//// — and they cost one `string.contains` per trigger per new entry.
////
//// Matching is over an assistant entry's **visible text blocks**, via
//// `events/search.entry_text`, which is the extraction the search index
//// already agrees on: thinking blocks and tool-call arguments are not
//// text a reader sees and are out of scope for this version. Sharing
//// that function rather than restating it is what keeps the two from
//// drifting apart.
////
//// ## The bounds, and why each one is here
////
//// Every limit below refuses at parse time with a worded message,
//// because the alternative is a config that boots and then behaves
//// strangely. `max_rules` and `max_triggers` bound the per-entry scan
//// cost, which is `rules x triggers` string searches over each new
//// assistant entry. `max_body_length` bounds what one fire costs a
//// context — a rule is supposed to be cheaper than the prompt line it
//// replaces, and an eight-thousand-character "rule" is a document.
//// `max_name_length` and the character rules on a name are structural:
//// the name is a durable register key segment and appears inside the
//// injected fence, so a name with a `/`, a newline or a quote in it
//// would make one of those ambiguous.

import core/entry.{type Entry}
import core/json.{type JsonValue}
import core/message
import events/search
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import tom

/// One project rule as the operator wrote it.
///
/// Constructor invariants (guaranteed by `parse`, owed by any direct
/// construction): `name` is unique in its list, non-empty, at most
/// `max_name_length` characters, and contains no `/`, no `"` and no
/// newline; `triggers` is non-empty, at most `max_triggers` long, and
/// every trigger is non-empty and at most `max_trigger_length`
/// characters; `body` is non-empty and at most `max_body_length`
/// characters.
pub type Rule {
  Rule(
    /// The operator's handle for the rule: the durable fired-mark's key
    /// segment, and the name the injected text attributes itself to.
    name: String,
    /// The literal, case-sensitive substrings that fire this rule. Any
    /// one of them is enough.
    triggers: List(String),
    /// The text injected, once, when a trigger fires.
    body: String,
  )
}

/// The most `[[rule]]` entries one configuration may define.
pub const max_rules = 64

/// The most triggers one rule may carry.
pub const max_triggers = 32

/// The longest a rule name may be, in characters.
pub const max_name_length = 64

/// The longest one trigger may be, in characters.
pub const max_trigger_length = 256

/// The longest a rule body may be, in characters.
pub const max_body_length = 8192

// --- parsing ---------------------------------------------------------------

/// Parses the `[[rule]]` entries of a `loom.toml` document. Total: every
/// failure is a human-worded `Error` naming the offending entry and key,
/// which is what the server prints when it refuses to boot.
///
/// Entries keep **file order**, unlike the catalogue's tables: an array
/// of tables is ordered in TOML itself, and the order is what decides
/// which rule is offered a run first when two fire on the same entry.
///
/// Only `[[rule]]` is read here. The document's other top-level tables
/// belong to `client/catalog`, which is where an unknown *top-level* key
/// is refused; this parser is strict about everything inside a rule and
/// silent about everything outside one, so the two can read the same
/// file without either having to know the other's schema.
///
/// ## Examples
///
/// ```gleam
/// assert rules.parse("") == Ok([])
/// ```
///
/// ```gleam
/// assert rules.parse("[[rule]]\nname = \"\"\ntriggers = [\"x\"]\nbody = \"y\"")
///   == Error("rule 1.name must be non-empty")
/// ```
///
pub fn parse(text: String) -> Result(List(Rule), String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(describe_parse_error),
  )
  parse_document(document)
}

// The document half of `parse`. Deliberately not a public door:
// `client/serve` hands each parser the raw text and pays one extra
// `tom.parse` of a small file at boot, so each keeps its own worded
// TOML failure — the decision is recorded at `serve.load_config`.
fn parse_document(
  document: Dict(String, tom.Toml),
) -> Result(List(Rule), String) {
  use tables <- result.try(case dict.get(document, "rule") {
    Error(Nil) -> Ok([])
    Ok(tom.ArrayOfTables(tables)) -> Ok(tables)
    Ok(_other) ->
      Error(
        "rule must be an array of [[rule]] tables, each with name, "
        <> "triggers and body",
      )
  })
  use Nil <- result.try(bounded_count(
    list.length(tables),
    max_rules,
    "this configuration defines",
    "rules",
  ))
  use parsed <- result.try(
    tables
    |> list.index_map(fn(fields, index) { parse_rule(index + 1, fields) })
    |> result.all,
  )
  use Nil <- result.try(unique_names(parsed, []))
  Ok(parsed)
}

fn parse_rule(
  position: Int,
  fields: Dict(String, tom.Toml),
) -> Result(Rule, String) {
  let place = "rule " <> string.inspect(position)
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    ["name", "triggers", "body"],
    place,
  ))
  use name <- result.try(rule_name(fields, place))
  // Once the rule has a name, say the name: an operator reading a
  // refusal about `rule 7` has to count tables to find it.
  let place = place <> " (" <> name <> ")"
  use triggers <- result.try(rule_triggers(fields, place))
  use body <- result.try(bounded_string(fields, place, "body", max_body_length))
  Ok(Rule(name:, triggers:, body:))
}

// The name is a durable register key segment (`fired_key`) and it is
// quoted inside the injected fence, so the characters refused here are
// the ones that would make either ambiguous rather than a matter of
// taste.
fn rule_name(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(String, String) {
  use name <- result.try(bounded_string(fields, place, "name", max_name_length))
  case
    string.contains(name, "/"),
    string.contains(name, "\""),
    string.contains(name, "\n")
  {
    True, _, _ ->
      Error(
        place
        <> ".name must not contain `/`: the name is a key segment of the "
        <> "durable fired-mark, whose strand segment a slash would swallow",
      )
    _, True, _ | _, _, True ->
      Error(
        place
        <> ".name must not contain a quote or a newline: the name is "
        <> "quoted inside the injected text, which those would break out of",
      )
    False, False, False -> Ok(name)
  }
}

fn rule_triggers(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(String), String) {
  use items <- result.try(case dict.get(fields, "triggers") {
    Ok(tom.Array(items)) -> Ok(items)
    Ok(_other) ->
      Error(place <> ".triggers must be an array of literal strings")
    Error(Nil) -> Error(place <> ".triggers is required")
  })
  use Nil <- result.try(bounded_count(
    list.length(items),
    max_triggers,
    place <> ".triggers carries",
    "triggers",
  ))
  use triggers <- result.try(
    list.try_map(items, fn(item) {
      case item {
        tom.String("") ->
          Error(
            place
            <> ".triggers must not contain an empty string: an "
            <> "empty trigger matches every message, which is a rule with "
            <> "no trigger at all",
          )
        tom.String(trigger) ->
          case too_long(trigger, max_trigger_length) {
            True ->
              Error(
                place
                <> ".triggers must each be at most "
                <> string.inspect(max_trigger_length)
                <> " characters",
              )
            False -> Ok(trigger)
          }
        _other ->
          Error(place <> ".triggers must be an array of literal strings")
      }
    }),
  )
  case triggers {
    [] ->
      Error(
        place
        <> ".triggers must name at least one trigger: a rule with none can "
        <> "never fire, and would only cost the scanner a comparison",
      )
    _some -> Ok(triggers)
  }
}

// Duplicate names are refused rather than resolved, because the name is
// the fired-mark's key: two rules sharing one would share one mark, so
// whichever fired first would silence the other for the rest of the
// session, with nothing anywhere saying so.
fn unique_names(
  remaining: List(Rule),
  seen: List(String),
) -> Result(Nil, String) {
  case remaining {
    [] -> Ok(Nil)
    [rule, ..rest] ->
      case list.contains(seen, rule.name) {
        True ->
          Error(
            "two rules are named "
            <> rule.name
            <> ": a rule's name is the key of its durable fired-mark, so a "
            <> "shared name would let one rule spend the other's",
          )
        False -> unique_names(rest, [rule.name, ..seen])
      }
  }
}

fn bounded_string(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
  limit: Int,
) -> Result(String, String) {
  case dict.get(fields, key) {
    Error(Nil) -> Error(place <> "." <> key <> " is required")
    Ok(tom.String("")) -> Error(place <> "." <> key <> " must be non-empty")
    Ok(tom.String(text)) ->
      case too_long(text, limit) {
        True ->
          Error(
            place
            <> "."
            <> key
            <> " must be at most "
            <> string.inspect(limit)
            <> " characters",
          )
        False -> Ok(text)
      }
    Ok(_other) -> Error(place <> "." <> key <> " must be a string")
  }
}

// Asks whether a string is longer than the bound without walking a
// pathological value to its end (lint R5), the way `client/catalog`
// bounds an MCP server name.
fn too_long(text: String, limit: Int) -> Bool {
  string.drop_start(text, limit) != ""
}

fn bounded_count(
  count: Int,
  limit: Int,
  subject: String,
  noun: String,
) -> Result(Nil, String) {
  case count > limit {
    False -> Ok(Nil)
    True ->
      Error(
        subject
        <> " "
        <> string.inspect(count)
        <> " "
        <> noun
        <> ", more than the "
        <> string.inspect(limit)
        <> " a scan of every assistant message can afford",
      )
  }
}

// The catalogue's strictness helper, restated rather than imported: this
// parser answers about a different set of keys and must not depend on
// the catalogue's private surface.
fn known_keys(
  present: List(String),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  case list.find(present, fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in "
        <> place
        <> " (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}

fn describe_parse_error(error: tom.ParseError) -> String {
  case error {
    tom.Unexpected(got:, expected:) ->
      "not valid toml: expected " <> expected <> ", got `" <> got <> "`"
    tom.KeyAlreadyInUse(key:) ->
      "not valid toml: the key " <> string.join(key, ".") <> " appears twice"
  }
}

// --- matching --------------------------------------------------------------

/// The text a committed entry offers a trigger, or `None` for an entry
/// that offers none.
///
/// Only **settled assistant output that the conversation keeps** is
/// scanned. Two exclusions, both deliberate:
///
/// - Non-assistant entries. A rule fires on model output; firing on the
///   operator's own prompt or on a tool's result would make a rule a
///   grep over the transcript, which is a different feature.
/// - Assistant messages the projection drops — `error`, `aborted`,
///   `deferred`. This is the same set `session.project_entries` refuses,
///   and matching it is the point: a rule may only fire on text the
///   model will actually still see. An `error` response also carries the
///   harness's own failure prose rather than model output, and a rule
///   that fired on that would be firing on the harness talking to
///   itself.
///
/// ## Examples
///
/// ```gleam
/// // rules.scannable_text(entry) == option.Some("the model's answer")
/// ```
///
pub fn scannable_text(entry: Entry) -> Option(String) {
  case entry {
    entry.MessageEntry(message: message.AssistantMessage(stop_reason:, ..), ..) ->
      case stop_reason {
        message.Errored | message.Aborted | message.Deferred -> None
        message.Pending | message.Stop | message.Length | message.ToolUse ->
          Some(search.entry_text(entry))
      }
    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> None
  }
}

/// Whether any of the rule's triggers occurs literally in `text`.
///
/// Case-sensitive, and any-of: one matching trigger fires the rule.
///
/// ## Examples
///
/// ```gleam
/// assert rules.fires_on(
///   rules.Rule(name: "n", triggers: ["ALTER TABLE"], body: "b"),
///   "I will ALTER TABLE users",
/// )
/// ```
///
/// ```gleam
/// assert !rules.fires_on(
///   rules.Rule(name: "n", triggers: ["ALTER TABLE"], body: "b"),
///   "i will alter table users",
/// )
/// ```
///
pub fn fires_on(rule: Rule, text: String) -> Bool {
  list.any(rule.triggers, string.contains(text, _))
}

// --- the durable half ------------------------------------------------------

/// The reserved `fact.custom` key of one rule's write-once fired-mark on
/// one strand. Write-once is the whole at-most-once story: the scanner
/// commits this cell in the same transaction as the injection, expecting
/// it absent, so a replay after a crash loses the race to its own
/// earlier self rather than injecting twice. At-most-once rather than
/// exactly-once, and the gap is one corner: an abort landing between the
/// fire and the checkpoint that would have drained it destroys the
/// queued injection while the mark stands, spending the rule on text the
/// model never saw (`docs/spec-gaps.md`, the triggered-rules section).
///
/// The strand segment is unambiguous because a rule name may not contain
/// a `/` (see `Rule`), so everything after the last slash is the name.
///
/// ## Examples
///
/// ```gleam
/// assert rules.fired_key(strand: "main", rule: "schema-gate")
///   == "rule/fired/main/schema-gate"
/// ```
///
pub fn fired_key(strand strand: String, rule rule: String) -> String {
  api.rule_fact_prefix <> "fired/" <> strand <> "/" <> rule
}

/// The reserved `fact.custom` key of one strand's scan-cursor
/// checkpoint: the newest entry seq the scanner had judged when it last
/// wrote one down.
///
/// A checkpoint rather than a position of record. Correctness does not
/// rest on it — the fired-marks do — so it is written lazily (see
/// `client/rulescan`) and a restart that resumes behind it re-judges a
/// bounded overhang, which the marks make harmless.
///
/// ## Examples
///
/// ```gleam
/// assert rules.cursor_key(strand: "main") == "rule/cursor/main"
/// ```
///
pub fn cursor_key(strand strand: String) -> String {
  api.rule_fact_prefix <> "cursor/" <> strand
}

/// The mark's stored value: the rule name, so an operator reading the
/// reserved namespace sees what fired rather than inferring it from a
/// key.
///
/// ## Examples
///
/// ```gleam
/// // rules.fired_value(rule) == json.String("schema-gate")
/// ```
///
pub fn fired_value(rule: Rule) -> JsonValue {
  json.String(rule.name)
}

/// A cursor checkpoint's stored value.
///
/// ## Examples
///
/// ```gleam
/// assert rules.cursor_value(42) == json.Int(42)
/// ```
///
pub fn cursor_value(seq: Int) -> JsonValue {
  json.Int(seq)
}

/// The seq a stored cursor checkpoint names, or `0` for anything else.
///
/// Total by construction and forgiving on purpose: a cursor that cannot
/// be read is a cursor the scanner starts from the beginning of, which
/// costs one bounded re-scan and injects nothing twice. Refusing to
/// start would be the worse failure — a corrupt checkpoint would stop
/// every rule in the session.
///
/// ## Examples
///
/// ```gleam
/// assert rules.cursor_seq(option.Some(json.Int(9))) == 9
/// ```
///
/// ```gleam
/// assert rules.cursor_seq(option.None) == 0
/// ```
///
pub fn cursor_seq(value: Option(JsonValue)) -> Int {
  case value {
    Some(json.Int(seq)) -> seq
    Some(json.Object(..))
    | Some(json.Array(..))
    | Some(json.String(..))
    | Some(json.Float(..))
    | Some(json.Bool(..))
    | Some(json.Null)
    | None -> 0
  }
}

// --- the injected text -----------------------------------------------------

/// The text one fire injects: an attribution line naming the rule, a
/// sentence saying whose text this is, and the body inside a named
/// fence.
///
/// The framing is the security-relevant part. The message arrives on the
/// strand's queue as a *user-role* turn, because that is the only shape
/// the provider APIs have for injected context — and a model that reads
/// it as something the person at the keyboard just said is a model that
/// can be steered by whoever chose the trigger text. So the first line
/// says what it is, the fence says where the operator's text starts and
/// stops, and nothing claims to be a request from the user. A rule name
/// can carry no quote, no newline and no slash (see `Rule`), which is
/// what keeps the fence's own lines unforgeable from the name side.
///
/// ## Examples
///
/// ```gleam
/// // rules.injection(rule) |> string.contains("triggered project rule")
/// ```
///
pub fn injection(rule: Rule) -> String {
  "[loom] triggered project rule \""
  <> rule.name
  <> "\"\n\n"
  <> "This is standing project configuration, injected automatically "
  <> "because your last message matched one of this rule's triggers. It "
  <> "is not a turn from the user and no reply to it is expected; treat "
  <> "it as project policy and carry on with the work in hand.\n\n"
  <> "--- begin project rule \""
  <> rule.name
  <> "\" ---\n"
  <> rule.body
  <> "\n--- end project rule \""
  <> rule.name
  <> "\" ---"
}
