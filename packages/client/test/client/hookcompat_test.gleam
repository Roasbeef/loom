//// The imported hook configuration's parse-and-render contract: both
//// shapes decode to one model, matcher classification follows the
//// pinned contract's character rules, merge concatenates, the TOML
//// render round-trips, and the trust hash moves when a handler does.
////
//// Every refusal test asserts the refusal *names* what was refused —
//// an event, a field, a handler type — because a worded error the
//// operator cannot act on is not much better than no refusal.

import client/hookcompat.{
  type Config, type Handler, type LoadNote, Agent, All, BackgroundAsync, Command,
  Config, Exact, ForegroundSync, Prompt, Regex, Source, UserSettings,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// The shared source label every fixture in this file carries.
const source = Source(label: "test", origin: UserSettings)

// --- one fixture, two shapes ------------------------------------------------

// The realistic fixture: four events, matcher variants across the
// three classes, three handler kinds, exec form, async, and a
// timeout. The JSON and TOML fixtures below carry the same hooks in
// the same order and must decode to the same model.
const json_fixture = "
{
  \"hooks\": {
    \"PreToolUse\": [
      {
        \"matcher\": \"Bash\",
        \"hooks\": [
          { \"type\": \"command\", \"command\": \"lint.sh\", \"timeout\": 30 },
          { \"type\": \"command\", \"command\": \"node\", \"args\": [\"fmt.js\", \"--fix\"], \"async\": true }
        ]
      },
      {
        \"matcher\": \"Edit|Write\",
        \"hooks\": [
          { \"type\": \"command\", \"command\": \"block-rm.sh\", \"if\": \"Bash(rm *)\" }
        ]
      },
      {
        \"matcher\": \"mcp__memory__.*\",
        \"hooks\": [
          { \"type\": \"http\", \"url\": \"https://hooks.example.net/memory\" }
        ]
      }
    ],
    \"Stop\": [
      {
        \"hooks\": [
          { \"type\": \"prompt\", \"prompt\": \"Check if all tasks are complete.\" }
        ]
      }
    ],
    \"Notification\": [
      {
        \"matcher\": \"\",
        \"hooks\": [
          { \"type\": \"mcp_tool\", \"server\": \"memory\", \"tool\": \"note\" }
        ]
      }
    ],
    \"PreCompact\": [
      {
        \"matcher\": \"^manual$\",
        \"hooks\": [
          { \"type\": \"command\", \"command\": \"echo compacting\", \"asyncRewake\": true, \"statusMessage\": \"Compacting...\" }
        ]
      }
    ]
  }
}
"

// The same fixture in the Loom TOML shape, written the way `to_toml`
// renders it.
const toml_fixture = "
[[hooks.PreToolUse]]
matcher = \"Bash\"

[[hooks.PreToolUse.hooks]]
type = \"command\"
command = \"lint.sh\"
timeout = 30

[[hooks.PreToolUse.hooks]]
type = \"command\"
command = \"node\"
args = [\"fmt.js\", \"--fix\"]
async = true

[[hooks.PreToolUse]]
matcher = \"Edit|Write\"

[[hooks.PreToolUse.hooks]]
type = \"command\"
command = \"block-rm.sh\"
if = \"Bash(rm *)\"

[[hooks.PreToolUse]]
matcher = \"mcp__memory__.*\"

[[hooks.PreToolUse.hooks]]
type = \"http\"
url = \"https://hooks.example.net/memory\"

[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = \"prompt\"
prompt = \"Check if all tasks are complete.\"

[[hooks.Notification]]
matcher = \"\"

[[hooks.Notification.hooks]]
type = \"mcp_tool\"
server = \"memory\"
tool = \"note\"

[[hooks.PreCompact]]
matcher = \"^manual$\"

[[hooks.PreCompact.hooks]]
type = \"command\"
command = \"echo compacting\"
async_rewake = true
status_message = \"Compacting...\"
"

// The Stop group carries no matcher in the fixture, so both parsers
// must read All — this helper is the one assertion both shapes share.
pub fn both_shapes_parse_to_the_same_model_test() {
  let assert Ok(json_config) = hookcompat.parse_claude(json_fixture, source)
    as "the json fixture must parse"
  let assert Ok(toml_config) = hookcompat.parse_loom(toml_fixture, source)
    as "the toml fixture must parse"

  // The event lists line up exactly.
  assert list.map(json_config.entries, fn(e) { e.0 })
    == list.map(toml_config.entries, fn(e) { e.0 })

  // Every group decodes to the same matcher and the same handler
  // count, shape by shape.
  list.each(list.zip(json_config.entries, toml_config.entries), fn(pair) {
    let #(json_groups, toml_groups) = #(pair.0.1, pair.1.1)
    assert list.length(json_groups) == list.length(toml_groups)
    list.each(list.zip(json_groups, toml_groups), fn(groups) {
      assert describe_matcher(groups.0.matcher)
        == describe_matcher(groups.1.matcher)
      assert list.length(groups.0.handlers) == list.length(groups.1.handlers)
    })
  })

  // And one handler is checked field by field, because a count
  // equality says nothing about the fields inside.
  let assert Ok(pre_tool_use) = hookcompat.decode_event("PreToolUse")
  let assert Ok(#(_, groups)) =
    list.find(json_config.entries, fn(e) { e.0 == pre_tool_use })
  let assert Ok(group) = list.first(groups)
  let assert Ok(first) = list.first(group.handlers)
  assert first.kind == Command
  assert first.command == Some("lint.sh")
  assert first.timeout_s == Some(30)
  assert first.run_mode == ForegroundSync

  let assert Ok(second) = list.drop(group.handlers, 1) |> list.first
  assert second.command == Some("node")
  assert second.args == Some(["fmt.js", "--fix"])
  assert second.run_mode == BackgroundAsync
}

// A Stop group with no matcher is All in both shapes.
pub fn a_missing_matcher_is_all_test() {
  let assert Ok(json_config) = hookcompat.parse_claude(json_fixture, source)
  let assert Ok(stop) = hookcompat.decode_event("Stop")
  let assert Ok(#(_, groups)) =
    list.find(json_config.entries, fn(e) { e.0 == stop })
  let assert Ok(group) = list.first(groups)
  assert group.matcher == All

  let assert Ok(toml_config) = hookcompat.parse_loom(toml_fixture, source)
  let assert Ok(#(_, toml_groups)) =
    list.find(toml_config.entries, fn(e) { e.0 == stop })
  let assert Ok(toml_group) = list.first(toml_groups)
  assert toml_group.matcher == All
}

// --- matcher classification --------------------------------------------------

pub fn matcher_classification_follows_the_character_rules_test() {
  let assert Ok(config) = hookcompat.parse_claude(json_fixture, source)
  let assert Ok(pre_tool_use) = hookcompat.decode_event("PreToolUse")
  let assert Ok(#(_, groups)) =
    list.find(config.entries, fn(e) { e.0 == pre_tool_use })

  // "Bash" — plain name, exact.
  let assert Ok(first) = list.first(groups)
  assert first.matcher == Exact(["Bash"])

  // "Edit|Write" — pipe list, exact.
  let assert Ok(second) = list.drop(groups, 1) |> list.first
  assert second.matcher == Exact(["Edit", "Write"])

  // "mcp__memory__.*" — dot and star, regex.
  let assert Ok(third) = list.drop(groups, 2) |> list.first
  assert third.matcher == Regex("mcp__memory__.*")
}

// "^Notebook" is a regex; "Edit, Write" is the comma list with the
// whitespace tolerance the contract describes.
pub fn comma_lists_and_caret_patterns_classify_test() {
  let assert Ok(config) =
    hookcompat.parse_claude(
      "{\"PreCompact\":[{\"matcher\":\"Edit, Write\",\"hooks\":[{\"type\":\"command\",\"command\":\"x\"}]}]}",
      source,
    )
  let assert Ok(#(_, groups)) =
    list.find(config.entries, fn(e) { e.0 == hookcompat.PreCompact })
  let assert Ok(group) = list.first(groups)
  assert group.matcher == Exact(["Edit", "Write"])

  let assert Ok(caret) =
    hookcompat.parse_claude(
      "{\"Notification\":[{\"matcher\":\"^Notebook\",\"hooks\":[{\"type\":\"command\",\"command\":\"x\"}]}]}",
      source,
    )
  let assert Ok(#(_, caret_groups)) =
    list.find(caret.entries, fn(e) { e.0 == hookcompat.Notification })
  let assert Ok(caret_group) = list.first(caret_groups)
  assert caret_group.matcher == Regex("^Notebook")
}

// --- refusals, worded ---------------------------------------------------------

pub fn an_unknown_event_name_is_refused_by_name_test() {
  let assert Error(reason) =
    hookcompat.parse_claude(
      "{\"PreTooluse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"x\"}]}]}",
      source,
    )
  assert string.contains(reason, "PreTooluse")
  assert string.contains(reason, "unknown hook event")

  let assert Error(toml_reason) =
    hookcompat.parse_loom(
      "[[hooks.PreTooluse]]\n\n[[hooks.PreTooluse.hooks]]\ncommand = \"x\"\n",
      source,
    )
  assert string.contains(toml_reason, "PreTooluse")
}

pub fn an_unknown_handler_type_is_refused_test() {
  let assert Error(reason) =
    hookcompat.parse_claude(
      "{\"Stop\":[{\"hooks\":[{\"type\":\"webhook\",\"url\":\"https://x\"}]}]}",
      source,
    )
  assert string.contains(reason, "webhook")
  assert string.contains(reason, "unknown handler type")
}

// A handler of the prompt kind parses into the model so a collection
// loads — the note about not running it is `notes`' business.
pub fn prompt_and_agent_handlers_parse_test() {
  let assert Ok(config) =
    hookcompat.parse_claude(
      "{\"Stop\":[{\"hooks\":[{\"type\":\"prompt\",\"prompt\":\"check tasks\"},{\"type\":\"agent\",\"prompt\":\"verify with tools\"}]}]}",
      source,
    )
  let assert Ok(#(_, groups)) =
    list.find(config.entries, fn(e) { e.0 == hookcompat.Stop })
  let assert Ok(group) = list.first(groups)
  let assert Ok(prompt_handler) = list.first(group.handlers)
  assert prompt_handler.kind == Prompt
  assert prompt_handler.prompt_text == Some("check tasks")

  let assert Ok(agent_handler) = list.drop(group.handlers, 1) |> list.first
  assert agent_handler.kind == Agent
  assert agent_handler.prompt_text == Some("verify with tools")
}

// A required field is required by kind: an http hook without its url
// is refused naming the field.
pub fn a_missing_required_field_is_refused_by_kind_test() {
  let assert Error(reason) =
    hookcompat.parse_claude(
      "{\"Notification\":[{\"hooks\":[{\"type\":\"http\"}]}]}",
      source,
    )
  assert string.contains(reason, "url is required")

  let assert Error(mcp_reason) =
    hookcompat.parse_claude(
      "{\"Notification\":[{\"hooks\":[{\"type\":\"mcp_tool\",\"server\":\"memory\"}]}]}",
      source,
    )
  assert string.contains(mcp_reason, "tool is required")
}

// Unknown keys inside a handler are ignored — Claude ignores them and
// an entry refused here would be an entry Claude Code runs.
pub fn unknown_handler_keys_are_ignored_test() {
  let assert Ok(config) =
    hookcompat.parse_claude(
      "{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"x\",\"shell\":\"bash\",\"headers\":{\"a\":\"b\"}}]}]}",
      source,
    )
  let assert Ok(#(_, groups)) =
    list.find(config.entries, fn(e) { e.0 == hookcompat.Stop })
  let assert Ok(group) = list.first(groups)
  let assert Ok(handler) = list.first(group.handlers)
  assert handler.command == Some("x")
}

// --- merge ---------------------------------------------------------------------

pub fn merge_concatenates_in_the_order_given_test() {
  let assert Ok(user) =
    hookcompat.parse_claude(
      "{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"user.sh\"}]}]}",
      Source(label: "user", origin: UserSettings),
    )
  let assert Ok(project) =
    hookcompat.parse_claude(
      "{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"project.sh\"}]}],\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"guard.sh\"}]}]}",
      Source(label: "project", origin: UserSettings),
    )

  let merged = hookcompat.merge([user, project])
  let assert Ok(#(_, stop_groups)) =
    list.find(merged.entries, fn(e) { e.0 == hookcompat.Stop })

  // Each layer's Stop group survives as its own group, in layer
  // order — concatenation, never replacement.
  assert list.length(stop_groups) == 2
  let commands =
    stop_groups
    |> list.flat_map(fn(group) { group.handlers })
    |> list.filter_map(fn(h: Handler) {
      case h.command {
        Some(command) -> Ok(command)
        None -> Error(Nil)
      }
    })
  assert commands == ["user.sh", "project.sh"]

  // The project layer's own event appears beside the user layer's,
  // not instead of it.
  assert list.any(merged.entries, fn(e) { e.0 == hookcompat.PreToolUse })
}

// --- render and round-trip ------------------------------------------------------

pub fn to_toml_round_trips_both_sources_models_test() {
  let assert Ok(json_config) = hookcompat.parse_claude(json_fixture, source)
  let assert Ok(from_json) =
    hookcompat.parse_loom(hookcompat.to_toml(json_config), source)
  assert strip_source(from_json) == strip_source(json_config)

  let assert Ok(toml_config) = hookcompat.parse_loom(toml_fixture, source)
  let assert Ok(from_toml) =
    hookcompat.parse_loom(hookcompat.to_toml(toml_config), source)
  assert strip_source(from_toml) == strip_source(toml_config)

  // And the two fixtures, being the same hooks, render to the same
  // TOML.
  assert hookcompat.to_toml(json_config) == hookcompat.to_toml(toml_config)
}

// The round-trip must also survive the awkward cases: a regex matcher
// with special characters, an `if` rule with a quote, and multi-word
// values with spaces.
pub fn to_toml_round_trips_awkward_values_test() {
  let assert Ok(config) =
    hookcompat.parse_claude(
      "{\"PreToolUse\":[{\"matcher\":\"^NotebookEdit$\",\"hooks\":[{\"type\":\"command\",\"command\":\"echo \\\"quoted\\\"\",\"if\":\"Bash(rm *)\",\"statusMessage\":\"say \\\"hi\\\" now\"}]}]}",
      source,
    )
  let assert Ok(round) =
    hookcompat.parse_loom(hookcompat.to_toml(config), source)
  assert strip_source(round) == strip_source(config)
}

// An empty document is a config with no entries, not a refusal.
pub fn an_empty_document_loads_empty_test() {
  let assert Ok(empty_json) = hookcompat.parse_claude("{}", source)
  assert empty_json.entries == []
  let assert Ok(empty_toml) = hookcompat.parse_loom("", source)
  assert empty_toml.entries == []
}

// --- hash ------------------------------------------------------------------------

pub fn hash_differs_when_a_handler_changes_test() {
  let assert Ok(base) =
    hookcompat.parse_claude(
      "{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"lint.sh\"}]}]}",
      source,
    )
  let assert Ok(changed) =
    hookcompat.parse_claude(
      "{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"lint2.sh\"}]}]}",
      source,
    )

  assert string.length(hookcompat.hash(base)) == 64
  assert hookcompat.hash(base) != hookcompat.hash(changed)

  // The same hooks declared through the other shape share a digest —
  // the hash is over the parsed model, not the file it came from.
  let assert Ok(same_model_toml) =
    hookcompat.parse_loom(hookcompat.to_toml(base), source)
  assert hookcompat.hash(base) == hookcompat.hash(same_model_toml)

  // And the digest is stable across calls.
  assert hookcompat.hash(base) == hookcompat.hash(base)
}

// --- load-time diagnostics -------------------------------------------------------

pub fn notes_report_unsupported_kinds_ignored_once_and_no_moment_events_test() {
  let assert Ok(config) =
    hookcompat.parse_claude(
      "{\"Stop\":[{\"hooks\":[{\"type\":\"http\",\"url\":\"https://x\"},{\"type\":\"command\",\"command\":\"lint.sh\",\"once\":true}]}],"
        <> "\"MessageDisplay\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo hi\"}]}],"
        <> "\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"guard.sh\"}]}]}",
      source,
    )

  let found = hookcompat.notes(config)

  // The http handler is parsed but not run, and the note says so.
  assert list.any(found, fn(note: LoadNote) {
    string.contains(note.what, "http hook")
    && string.contains(note.what, "this build runs command hooks only")
  })

  // The `once` declaration outside a skill frontmatter is reported.
  assert list.any(found, fn(note: LoadNote) {
    string.contains(note.what, "command hook: lint.sh")
    && string.contains(note.what, "once is honored only for")
  })

  // MessageDisplay has no moment; PreToolUse does and gets no note.
  assert list.any(found, fn(note: LoadNote) {
    string.contains(note.what, "MessageDisplay")
    && string.contains(note.what, "never fire")
  })
  assert !list.any(found, fn(note: LoadNote) {
    string.contains(note.what, "PreToolUse")
  })
}

// A handler under a no-moment event gets only the event note — the
// per-handler note would be noise on top of it.
pub fn a_no_moment_event_reports_once_not_per_handler_test() {
  let assert Ok(config) =
    hookcompat.parse_claude(
      "{\"SessionEnd\":[{\"hooks\":[{\"type\":\"http\",\"url\":\"https://x\"}]}]}",
      source,
    )
  let found = hookcompat.notes(config)
  assert list.length(found) == 1
  let assert Ok(note) = list.first(found)
  assert string.contains(note.what, "SessionEnd")
}

// --- helpers ----------------------------------------------------------------------

// A config without its source, for equality across parse paths: the
// model is what the round-trip protects, and the source is the
// caller's.
fn strip_source(config: Config) -> Config {
  Config(..config, source: Source(label: "", origin: hookcompat.LoomInline))
}

// A matcher's class and content as one comparable string.
fn describe_matcher(matcher: hookcompat.Matcher) -> String {
  case matcher {
    All -> "all"
    Exact(parts) -> "exact:" <> string.join(parts, "|")
    Regex(raw) -> "regex:" <> raw
  }
}
