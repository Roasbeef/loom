//// The imported hook configuration model: one in-memory shape both
//// accepted formats decode into, plus the merge, the render, the
//// trust hash, and the load-time diagnostics that sit on top of it.
////
//// # Why one model, and two parsers
////
//// The compatibility target of #350 is an operator's existing hook
//// collection — `~/.claude/settings.json`, a repo's
//// `.claude/settings.json`, a plugin's `hooks/hooks.json` — loading
//// into Loom without editing its entries or its scripts. The pinned
//// contract (`docs/design-notes/claude-hooks-contract.md`) fixes the
//// Claude shape; the design note fixes the goal, which is that both
//// shapes produce the same model so there is one bus, one runner
//// (`client/hookrunner`), and one trust story regardless of which
//// format a hook arrived in. Two parsers over one `Config` is that
//// sentence made structural: anything this module decides about
//// matcher semantics, handler kinds, or event names is decided once
//// and both formats inherit it.
////
//// Two consequences follow, and both are deliberate.
////
//// **The Claude parser is permissive where the catalogue is strict.**
//// Unknown keys inside a handler object are *ignored*, because Claude
//// ignores them and an entry this module refuses would be an entry
//// Claude Code runs — the parity direction of the whole issue. A
//// typoed event name and an unknown handler `type` are still
//// refusals, naming what was found: "loads but never fires" is
//// exactly the silent failure the load-time diagnostics exist to
//// prevent.
////
//// **The Loom TOML shape is what `to_toml` renders**, so `loom hooks
//// convert` is `parse_claude` then `to_toml`, and the round-trip
//// property `parse_loom(to_toml(c)) == c` is what makes the converter
//// lossless rather than lossy-with-apology.
////
//// # What this module does not do
////
//// It runs nothing and trusts nothing: execution is
//// `client/hookrunner`'s, and the hash here is the *input* to the
//// trust record, not the record. Match evaluation against a fired
//// event is the caller's problem — this module stores a parsed
//// `Matcher`, it does not test one against a tool name, and the
//// regular-expression path in particular stays behind whoever runs
//// the hook, so a catastrophic pattern is never *driven* by
//// configuration the loader read.

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import tom
import tools/blob

// --- the model --------------------------------------------------------------

/// One imported hook event, named exactly as the pinned contract names
/// it. The names are kept verbatim (`PreToolUse`, not a renamed
/// `tool_call`): the parity target is reuse, and renaming is the one
/// thing that guarantees a rewrite of an operator's configuration.
pub type Event {
  SessionStart
  UserPromptSubmit
  PreToolUse
  PostToolUse
  PreCompact
  Stop
  SubagentStop
  Notification
  PermissionRequest
  MessageDisplay
  TeammateIdle
  WorktreeCreate
  WorktreeRemove
  SessionEnd
  ConfigChange
  CwdChanged
  DirectoryAdded
  FileChanged
  InstructionsLoaded
  PostCompact
  PreModelSwitch
  PostModelSwitch
  SubagentStart
  TaskCreated
  TaskCompleted
  StopFailure
  Setup
  Elicitation
  ElicitationResult
  UserPromptExpansion
  PostToolUseFailure
  PostToolBatch
  PermissionDenied
}

/// The event's name, verbatim as the contract spells it — the key both
/// parsers look up and `to_toml` writes back.
///
/// ## Examples
///
/// ```gleam
/// assert event_name(PreToolUse) == "PreToolUse"
/// ```
pub fn event_name(event: Event) -> String {
  case event {
    SessionStart -> "SessionStart"
    UserPromptSubmit -> "UserPromptSubmit"
    PreToolUse -> "PreToolUse"
    PostToolUse -> "PostToolUse"
    PreCompact -> "PreCompact"
    Stop -> "Stop"
    SubagentStop -> "SubagentStop"
    Notification -> "Notification"
    PermissionRequest -> "PermissionRequest"
    MessageDisplay -> "MessageDisplay"
    TeammateIdle -> "TeammateIdle"
    WorktreeCreate -> "WorktreeCreate"
    WorktreeRemove -> "WorktreeRemove"
    SessionEnd -> "SessionEnd"
    ConfigChange -> "ConfigChange"
    CwdChanged -> "CwdChanged"
    DirectoryAdded -> "DirectoryAdded"
    FileChanged -> "FileChanged"
    InstructionsLoaded -> "InstructionsLoaded"
    PostCompact -> "PostCompact"
    PreModelSwitch -> "PreModelSwitch"
    PostModelSwitch -> "PostModelSwitch"
    SubagentStart -> "SubagentStart"
    TaskCreated -> "TaskCreated"
    TaskCompleted -> "TaskCompleted"
    StopFailure -> "StopFailure"
    Setup -> "Setup"
    Elicitation -> "Elicitation"
    ElicitationResult -> "ElicitationResult"
    UserPromptExpansion -> "UserPromptExpansion"
    PostToolUseFailure -> "PostToolUseFailure"
    PostToolBatch -> "PostToolBatch"
    PermissionDenied -> "PermissionDenied"
  }
}

/// One parser's entries in one stable order: by event name, the
/// same order both parsers share. A JSON document preserves its fields'
/// order and a TOML table does not, so the in-memory model cannot
/// promise "declaration order" across both shapes — and it should not:
/// within one source the event order carries no semantics, and the
/// merge order that does carry semantics is the caller's, over
/// sources, preserved by `merge`.
fn ordered(
  entries: List(#(Event, List(Group))),
) -> List(#(Event, List(Group))) {
  list.sort(entries, fn(a, b) {
    string.compare(event_name(a.0), event_name(b.0))
  })
}

/// Decodes a contract event name. The total counterpart to
/// `event_name`: an unknown name is a worded error, which is what
/// makes a typoed event a refusal rather than a silently dead entry.
///
/// ## Examples
///
/// ```gleam
/// assert decode_event("PreToolUse") == Ok(PreToolUse)
/// ```
///
/// ```gleam
/// assert decode_event("PreTooluse")
///   == Error("unknown hook event `PreTooluse`")
/// ```
pub fn decode_event(name: String) -> Result(Event, String) {
  case name {
    "SessionStart" -> Ok(SessionStart)
    "UserPromptSubmit" -> Ok(UserPromptSubmit)
    "PreToolUse" -> Ok(PreToolUse)
    "PostToolUse" -> Ok(PostToolUse)
    "PreCompact" -> Ok(PreCompact)
    "Stop" -> Ok(Stop)
    "SubagentStop" -> Ok(SubagentStop)
    "Notification" -> Ok(Notification)
    "PermissionRequest" -> Ok(PermissionRequest)
    "MessageDisplay" -> Ok(MessageDisplay)
    "TeammateIdle" -> Ok(TeammateIdle)
    "WorktreeCreate" -> Ok(WorktreeCreate)
    "WorktreeRemove" -> Ok(WorktreeRemove)
    "SessionEnd" -> Ok(SessionEnd)
    "ConfigChange" -> Ok(ConfigChange)
    "CwdChanged" -> Ok(CwdChanged)
    "DirectoryAdded" -> Ok(DirectoryAdded)
    "FileChanged" -> Ok(FileChanged)
    "InstructionsLoaded" -> Ok(InstructionsLoaded)
    "PostCompact" -> Ok(PostCompact)
    "PreModelSwitch" -> Ok(PreModelSwitch)
    "PostModelSwitch" -> Ok(PostModelSwitch)
    "SubagentStart" -> Ok(SubagentStart)
    "TaskCreated" -> Ok(TaskCreated)
    "TaskCompleted" -> Ok(TaskCompleted)
    "StopFailure" -> Ok(StopFailure)
    "Setup" -> Ok(Setup)
    "Elicitation" -> Ok(Elicitation)
    "ElicitationResult" -> Ok(ElicitationResult)
    "UserPromptExpansion" -> Ok(UserPromptExpansion)
    "PostToolUseFailure" -> Ok(PostToolUseFailure)
    "PostToolBatch" -> Ok(PostToolBatch)
    "PermissionDenied" -> Ok(PermissionDenied)

    // The refusal names the name it was handed, so an operator can see
    // the case difference or the typo that brought them here.
    unknown -> Error("unknown hook event `" <> unknown <> "`")
  }
}

/// When a matcher group's handlers run.
///
/// Claude evaluates a matcher as an **unanchored** regular expression
/// when it carries any character outside the exact set — `Edit.*`
/// matches both `Edit` and `NotebookEdit`, so the classification is a
/// decision about characters, not about intent, and it is recorded in
/// the parsed value rather than recomputed at fire time.
pub type Matcher {
  /// Matches every occurrence: a matcher of `*`, of `""`, or omitted.
  All

  /// Matches any of these exact strings: the parsed form of a matcher
  /// holding only letters, digits, `_`, `-`, spaces, `,` and `|`,
  /// split on `,` and `|` with surrounding whitespace tolerated
  /// (`Edit|Write` and `Edit, Write` both carry the two names).
  Exact(List(String))

  /// An unanchored regular expression, kept as the operator wrote it.
  /// Evaluation is the caller's; this module never compiles it.
  Regex(String)
}

/// Classifies a matcher string the way the contract's table says
/// Claude does. Total: every string classifies to one of the three
/// variants, so both parsers share one reading of the field.
///
/// ## Examples
///
/// ```gleam
/// assert hookcompat.All == hookcompat.classify_matcher("")
/// assert hookcompat.Exact(["Edit", "Write"])
///   == hookcompat.classify_matcher("Edit|Write")
/// assert hookcompat.Regex("mcp__.*") == hookcompat.classify_matcher("mcp__.*")
/// ```
///
pub fn classify_matcher(raw: String) -> Matcher {
  case raw {
    "" | "*" -> All
    _ ->
      case all_exact_chars(raw) {
        True -> Exact(split_exact(raw))
        False -> Regex(raw)
      }
  }
}

// The exact-match character set: letters, digits, `_`, `-`, space,
// `,`, `|`. Any other character sends the whole string to the regex
// path — the contract's table is a property of the whole value, not of
// the separators.
fn all_exact_chars(raw: String) -> Bool {
  raw
  |> string.to_graphemes
  |> list.all(fn(char) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-,| ",
      char,
    )
  })
}

// Splits an exact matcher on `,` and `|`, trimming the surrounding
// whitespace the contract tolerates. Empty alternatives are dropped
// rather than kept: the empty string would match everything and is
// never what a separator meant.
fn split_exact(raw: String) -> List(String) {
  raw
  |> string.replace(" ", ",")
  |> string.split(",")
  |> list.flat_map(fn(token) { string.split(token, "|") })
  |> list.map(string.trim)
  |> list.filter(fn(part) { part != "" })
}

/// Which of the contract's five handler types a handler is.
pub type HandlerKind {
  /// Shell form or exec form (`args` selects exec form).
  Command

  /// An HTTP POST of the event input to `url`. Parsed, not run: this
  /// build runs command hooks only, and `notes` says so at load time.
  Http

  /// A call of `tool` on the already-connected MCP server `server`.
  /// Parsed, not run, for the same reason as `Http`.
  McpTool

  /// A single-turn LLM evaluation carrying its prompt text. Parsed so
  /// a collection loads without edits; the runner side is a matrix
  /// row marked "parsed, not run".
  Prompt

  /// A subagent verifier with tool access. Parsed, not run, like
  /// `Prompt`.
  Agent
}

/// The wire spelling of each handler type: the `type` value both
/// parsers look up and `to_toml` writes back.
///
/// ## Examples
///
/// ```gleam
/// assert handler_type(McpTool) == "mcp_tool"
/// ```
pub fn handler_type(kind: HandlerKind) -> String {
  case kind {
    Command -> "command"
    Http -> "http"
    McpTool -> "mcp_tool"
    Prompt -> "prompt"
    Agent -> "agent"
  }
}

/// Whether a handler runs blocking in the foreground or is put in the
/// background. A raw `Bool` would name nothing at a construction site
/// and would carry its polarity in the reader's head everywhere else,
/// so the question is modelled — decoding a JSON `async: true` is
/// exactly the conversion into this shape.
pub type RunMode {
  /// The default: the event waits for the handler.
  ForegroundSync

  /// `async: true` (or `async_rewake: true` in the Loom shape) —
  /// background, with the rewake flag a separate field on `Handler`.
  BackgroundAsync
}

/// Whether a background handler wakes the session on exit code 2.
///
/// The contract's `asyncRewake` is a boolean in both wire shapes, so
/// the question is modelled rather than carried — the same conversion
/// `RunMode` makes for `async`.
pub type Rewake {
  /// The default: the handler's exit is noticed, not acted on.
  Quiet

  /// `asyncRewake: true`: exit code 2 wakes the session and the
  /// stderr becomes a reminder the model reads.
  WakesSession
}

/// Whether a handler runs once or repeats.
///
/// Claude honours `once` only for hooks declared in skill frontmatter
/// and ignores it elsewhere; the parsed value keeps what was declared
/// and `notes` reports where the declaration will be ignored, so an
/// operator who wrote `once = true` in a settings file can see it.
pub type Lifetime {
  /// The default: the handler runs on every matching event.
  Repeats

  /// `once: true` — removed after its first successful run.
  Once
}

/// One handler of a matcher group, with every contract field the two
/// parsers read. Fields that belong to one kind alone are `None` for
/// every other kind; the required ones are enforced at parse time by
/// kind, not by the type.
pub type Handler {
  Handler(
    /// Which of the five handler types this is.
    kind: HandlerKind,
    /// The command for `Command` handlers: the shell string in shell
    /// form, the executable in exec form.
    command: Option(String),
    /// The exec-form argument vector; `Some` selects exec form with no
    /// shell involved.
    args: Option(List(String)),
    /// Foreground or background.
    run_mode: RunMode,
    /// `asyncRewake: true` / `async_rewake = true`: background, and
    /// wakes the session on exit code 2.
    rewake: Rewake,
    /// The per-handler `timeout` in seconds; `None` means the
    /// contract's per-event default, which the caller supplies.
    timeout_s: Option(Int),
    /// The POST target of an `Http` handler.
    url: Option(String),
    /// The MCP server of an `McpTool` handler.
    server: Option(String),
    /// The tool called on `server`.
    tool: Option(String),
    /// The prompt text of a `Prompt` or `Agent` handler.
    prompt_text: Option(String),
    /// The `if` permission-rule filter. Kept as the operator wrote it
    /// — evaluation is the caller's, exactly as for `Matcher`.
    if_rule: Option(String),
    /// The custom spinner message.
    status_message: Option(String),
    /// `once: true`, decoded into the named question.
    lifetime: Lifetime,
  )
}

/// A one-line human summary of a handler, for load-time diagnostics
/// and CLI listings. The kind names the head; the kind's own address
/// (command, url, server, tool) names the body, and a prompt or agent
/// handler is summarized by its prompt's first line.
///
/// ## Examples
///
/// ```gleam
/// assert describes_handler(lint_command) == "command hook: lint.sh"
/// ```
pub fn describes_handler(handler: Handler) -> String {
  let head = case handler.kind {
    Command -> "command hook: "
    Http -> "http hook: "
    McpTool -> "mcp_tool hook: "
    Prompt -> "prompt hook: "
    Agent -> "agent hook: "
  }

  head <> handler_address(handler)
}

// The part of the summary that identifies *which* handler this is, by
// kind. Every kind has exactly one identifying field the parsers
// require, so the case is total over what a parsed handler can carry.
fn handler_address(handler: Handler) -> String {
  case
    handler.command,
    handler.url,
    handler.server,
    handler.tool,
    handler.prompt_text
  {
    Some(command), _, _, _, _ -> command
    _, Some(url), _, _, _ -> url
    _, _, _, Some(tool), _ -> tool
    _, _, Some(server), _, _ -> server
    _, _, _, _, Some(prompt) -> string.slice(prompt, 0, 40)
    _, _, _, _, _ -> "(unspecified)"
  }
}

/// One matcher group: the filter and the handlers that run when it
/// matches. Handlers within a group run in the declared order, and all
/// matching groups run for the event — Claude's own merge semantics.
pub type Group {
  Group(matcher: Matcher, handlers: List(Handler))
}

/// Where a configuration came from. The label is the human-readable
/// name diagnostics and the trust record carry; the origin is the
/// precedence class the caller sorts by.
pub type Origin {
  /// The operator's own user-level settings.
  UserSettings

  /// The project's committed settings.
  ProjectSettings

  /// The project's gitignored local settings.
  LocalSettings

  /// A plugin's bundled hooks, named for the plugin.
  Plugin(name: String)

  /// Hooks declared inline in Loom's own configuration.
  LoomInline
}

/// One configuration source: a parsed document plus where it came
/// from.
pub type Source {
  Source(label: String, origin: Origin)
}

/// A whole loaded configuration: per-event matcher groups in the order
/// each source declared them, tagged with its source. Merging is
/// concatenation over the caller's precedence order — this module
/// never reorders.
pub type Config {
  Config(entries: List(#(Event, List(Group))), source: Source)
}

// --- parse: the Claude JSON shape ------------------------------------------

/// Parses the `hooks` object of a Claude settings file — or a plugin's
/// `hooks/hooks.json`, which is the same shape. Total: every failure
/// is a worded `Error` naming the event or field it came from.
///
/// Keys are event names; each value is an array of matcher groups,
/// each group an object with an optional `matcher` and a required
/// `hooks` array of handler objects. Unknown keys inside a handler are
/// ignored — Claude ignores them, and refusing an entry Claude Code
/// runs would break the parity the issue is about.
///
/// The whole settings file is also accepted: when a top-level `hooks`
/// object is present it is descended into, so a caller can hand this
/// the file it read rather than extracting the field first.
///
/// ## Examples
///
/// ```gleam
/// parse_claude(
///   "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",
///     \"hooks\":[{\"type\":\"command\",\"command\":\"lint.sh\"}]}]}}",
///   source,
/// )
/// // -> Ok(config) with one PreToolUse group matching Bash
/// ```
pub fn parse_claude(text: String, source: Source) -> Result(Config, String) {
  use value <- result.try(
    json.parse(text)
    |> result.map_error(describe_json_error),
  )
  use fields <- result.try(object_fields(value, "the hooks configuration"))

  // Accept either the bare `hooks` object or a whole settings file
  // with `hooks` as one of its top-level keys. The bare object has no
  // `hooks` key (an event is not named that), so the two are
  // distinguishable by exactly the field the contract nests under.
  let hooks = case list.key_find(fields, "hooks") {
    Ok(nested) -> nested
    Error(Nil) -> value
  }
  use event_fields <- result.try(object_fields(hooks, "the hooks object"))
  use entries <- result.try(
    event_fields
    |> list.map(parse_event)
    |> result.all,
  )
  Ok(Config(entries: ordered(entries), source:))
}

// Decodes one `event name: [groups]` pair, naming the event in every
// refusal it produces.
fn parse_event(
  field: #(String, JsonValue),
) -> Result(#(Event, List(Group)), String) {
  let #(name, value) = field
  use event <- result.try(decode_event(name))
  use groups <- result.try(case value {
    json.Array(items) ->
      items
      |> list.index_map(fn(item, at) { parse_group(event, at, item) })
      |> result.all
    _ -> Error("the " <> name <> " hooks must be an array of matcher groups")
  })
  Ok(#(event, groups))
}

// Decodes one matcher group from the JSON shape, naming the event and
// the group's matcher in every refusal.
fn parse_group(
  event: Event,
  at: Int,
  value: JsonValue,
) -> Result(Group, String) {
  let place = event_name(event) <> " group " <> string.inspect(at + 1)
  use group_fields <- result.try(object_fields(value, place))

  // Once the group's matcher is known, say it: a refusal about "group
  // 3" costs the operator a count; one naming the matcher reads
  // itself.
  use raw_matcher <- result.try(optional_string(group_fields, place, "matcher"))
  let place = case raw_matcher {
    Some(raw) -> place <> " (`" <> raw <> "`)"
    None -> place
  }
  let matcher = case raw_matcher {
    Some(raw) -> classify_matcher(raw)
    None -> All
  }
  use handlers <- result.try(case list.key_find(group_fields, "hooks") {
    Ok(json.Array(items)) ->
      items
      |> list.index_map(fn(item, at) { parse_json_handler(place, at, item) })
      |> result.all
    Ok(_) -> Error(place <> ": hooks must be an array of handler objects")
    Error(Nil) -> Error(place <> ": hooks is required")
  })
  Ok(Group(matcher:, handlers:))
}

// --- parse: the Loom TOML shape ---------------------------------------------

/// Parses the Loom TOML shape — `[[hooks.<Event>]]` matcher tables
/// with nested `[[hooks.<Event>.hooks]]` handler tables, as rendered
/// by `to_toml`. Total, with refusals worded like the catalogue's.
///
/// Handler table fields: `type` (default `"command"`), `command`,
/// `args`, `async`, `async_rewake`, `timeout`, `url`, `server`,
/// `tool`, `prompt`, `if`, `status_message`, `once`. Unknown handler
/// keys are ignored for compat with Claude extras; an event name that
/// is not a known event is refused, naming it.
///
/// ## Examples
///
/// ```gleam
/// parse_loom(
///   "[[hooks.PreToolUse]]\nmatcher = \"Bash\"\n
///    [[hooks.PreToolUse.hooks]]\ncommand = \"lint.sh\"",
///   source,
/// )
/// // -> Ok(config), the same model the equivalent JSON produces
/// ```
pub fn parse_loom(text: String, source: Source) -> Result(Config, String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(describe_toml_error),
  )
  case dict.get(document, "hooks") {
    Ok(tom.Table(fields)) | Ok(tom.InlineTable(fields)) ->
      loom_events(fields, source)
    Ok(tom.ArrayOfTables(tables)) -> loom_bare_groups(tables, source)
    Ok(_) ->
      Error("the hooks section must be a table or an array of event tables")
    Error(Nil) -> Ok(Config(entries: [], source:))
  }
}

// The `[hooks]` nesting: keys under it are event names.
fn loom_events(
  fields: Dict(String, tom.Toml),
  source: Source,
) -> Result(Config, String) {
  use entries <- result.try(
    fields
    |> dict.to_list
    |> list.map(parse_loom_event)
    |> result.all,
  )
  Ok(Config(entries: ordered(entries), source:))
}

// The bare `[[hooks.<Event>]]` nesting, where each element of the
// array under `hooks` is one group of one event.
fn loom_bare_groups(
  tables: List(Dict(String, tom.Toml)),
  source: Source,
) -> Result(Config, String) {
  // The bare nesting renders each group as an anonymous table; without
  // the event name in the fields, the group cannot be decoded at all.
  // That shape is therefore refused by naming the fix — the nested
  // `[[hooks.<Event>]]` spelling `to_toml` writes and the contract's
  // convert story produces — rather than guessed at.
  case tables {
    [] -> Ok(Config(entries: [], source:))
    _ ->
      Error(
        "the hooks section must hold one table per event, as in "
        <> "[[hooks.PreToolUse]] with its hooks nested under it",
      )
  }
}

// Decodes one `event = [groups]` table under the Loom shape, naming
// the event in every refusal.
fn parse_loom_event(
  field: #(String, tom.Toml),
) -> Result(#(Event, List(Group)), String) {
  let #(name, value) = field
  use event <- result.try(decode_event(name))
  use groups <- result.try(case value {
    tom.ArrayOfTables(tables) ->
      tables
      |> list.index_map(fn(fields, at) { parse_loom_group(event, at, fields) })
      |> result.all
    _ ->
      Error(
        "the "
        <> name
        <> " hooks must be [[hooks."
        <> name
        <> "]] tables, one per matcher group",
      )
  })
  Ok(#(event, groups))
}

// Decodes one matcher group from the Loom TOML shape, with the same
// matcher-naming refusals as the JSON path so both formats speak the
// operator's own vocabulary back at them.
fn parse_loom_group(
  event: Event,
  at: Int,
  fields: Dict(String, tom.Toml),
) -> Result(Group, String) {
  let place = event_name(event) <> " group " <> string.inspect(at + 1)
  use raw_matcher <- result.try(optional_toml_string(fields, place, "matcher"))
  let place = case raw_matcher {
    Some(raw) -> place <> " (`" <> raw <> "`)"
    None -> place
  }
  let matcher = case raw_matcher {
    Some(raw) -> classify_matcher(raw)
    None -> All
  }
  use handler_tables <- result.try(case dict.get(fields, "hooks") {
    Ok(tom.ArrayOfTables(tables)) -> Ok(tables)
    Ok(_) ->
      Error(
        place
        <> ": hooks must be [[hooks."
        <> event_name(event)
        <> ".hooks]] tables",
      )
    Error(Nil) -> Error(place <> ": hooks is required")
  })
  use handlers <- result.try(
    handler_tables
    |> list.index_map(fn(fields, at) { parse_loom_handler(place, at, fields) })
    |> result.all,
  )
  Ok(Group(matcher:, handlers:))
}

// --- shared handler decoding ------------------------------------------------

// Decodes one handler object from the JSON shape. The kind decides
// which fields are required; everything the kind does not need is
// still read, so a config round-trips through the model rather than
// being narrowed to what this build runs.
fn parse_json_handler(
  place: String,
  at: Int,
  value: JsonValue,
) -> Result(Handler, String) {
  use fields <- result.try(object_fields(
    value,
    place <> " handler " <> string.inspect(at + 1),
  ))

  // The kind first, because every later refusal names it: "PreToolUse
  // group 1 (`Bash`) http hook: url is required" reads itself.
  use kind <- result.try(case list.key_find(fields, "type") {
    Ok(json.String("command")) -> Ok(Command)
    Ok(json.String("http")) -> Ok(Http)
    Ok(json.String("mcp_tool")) -> Ok(McpTool)
    Ok(json.String("prompt")) -> Ok(Prompt)
    Ok(json.String("agent")) -> Ok(Agent)
    Ok(json.String(other)) ->
      Error("unknown handler type `" <> other <> "` in " <> place)
    Ok(_) -> Error(place <> ": type must be a string naming a handler type")
    Error(Nil) -> Error(place <> ": type is required")
  })

  handler_from_common(kind, place, json_getters(fields))
}

// The Loom-shape twin of `parse_json_handler`: same kind-first order,
// same refusals, TOML accessors and Loom field spellings.
fn parse_loom_handler(
  place: String,
  at: Int,
  fields: Dict(String, tom.Toml),
) -> Result(Handler, String) {
  let place = place <> " handler " <> string.inspect(at + 1)
  use kind <- result.try(case dict.get(fields, "type") {
    Error(Nil) -> Ok(Command)
    Ok(tom.String("command")) -> Ok(Command)
    Ok(tom.String("http")) -> Ok(Http)
    Ok(tom.String("mcp_tool")) -> Ok(McpTool)
    Ok(tom.String("prompt")) -> Ok(Prompt)
    Ok(tom.String("agent")) -> Ok(Agent)
    Ok(tom.String(other)) ->
      Error("unknown handler type `" <> other <> "` in " <> place)
    Ok(_) -> Error(place <> ": type must be a string naming a handler type")
  })

  handler_from_common(kind, place, toml_getters(fields))
}

// The per-kind required fields, worded the way the contract's tables
// state them. `Prompt` and `Agent` handlers parse into the model — a
// collection must load without edits — so their `prompt` is required
// here even though nothing runs it yet.
fn check_required(
  kind: HandlerKind,
  h: Handler,
  place: String,
) -> Result(Nil, String) {
  let command_check = case kind, h.command {
    Command, None -> Error(place <> ": command is required")
    _, _ -> Ok(Nil)
  }
  let http_check = case kind, h.url {
    Http, None -> Error(place <> ": url is required")
    _, _ -> Ok(Nil)
  }
  let mcp_check = case kind, h.server, h.tool {
    McpTool, None, _ -> Error(place <> ": server is required")
    McpTool, _, None -> Error(place <> ": tool is required")
    _, _, _ -> Ok(Nil)
  }
  let prompt_check = case kind, h.prompt_text {
    Prompt, None -> Error(place <> ": prompt is required")
    Agent, None -> Error(place <> ": prompt is required")
    _, _ -> Ok(Nil)
  }

  command_check
  |> result.try(fn(_) { http_check })
  |> result.try(fn(_) { mcp_check })
  |> result.try(fn(_) { prompt_check })
}

// The field accessors one wire format offers the shared handler
// decoder. Two constructors, one consumer: the kind-first order and
// the per-kind requirement checks live in exactly one place.
type Getters {
  JsonGetters(fields: List(#(String, JsonValue)))

  TomlGetters(fields: Dict(String, tom.Toml))
}

fn json_getters(fields: List(#(String, JsonValue))) -> Getters {
  JsonGetters(fields)
}

fn toml_getters(fields: Dict(String, tom.Toml)) -> Getters {
  TomlGetters(fields)
}

// Reads one optional string field through either accessor.
fn get_string(
  get: Getters,
  place: String,
  key: String,
) -> Result(Option(String), String) {
  case get {
    JsonGetters(fields) -> optional_string(fields, place, key)
    TomlGetters(fields) -> optional_toml_string(fields, place, key)
  }
}

// Reads one optional integer field through either accessor.
fn get_int_field(
  get: Getters,
  place: String,
  key: String,
) -> Result(Option(Int), String) {
  case get {
    JsonGetters(fields) -> optional_json_int(fields, place, key)
    TomlGetters(fields) -> optional_toml_int(fields, place, key)
  }
}

// Reads the exec-form argument vector through either accessor.
fn get_args(
  get: Getters,
  place: String,
  key: String,
) -> Result(Option(List(String)), String) {
  case get {
    JsonGetters(fields) -> optional_json_args(fields, place, key)
    TomlGetters(fields) -> optional_toml_args(fields, place, key)
  }
}

// Reads one three-state boolean (`true` / `false` / absent) through
// either accessor, into its named question. `once` and `async` and
// `async_rewake` are the three the model carries.
fn get_bool(
  get: Getters,
  _place: String,
  key: String,
) -> Result(Option(Bool), String) {
  case get {
    JsonGetters(fields) ->
      case list.key_find(fields, key) {
        Ok(json.Bool(value)) -> Ok(Some(value))
        Ok(_) -> Error(key <> " must be a boolean")
        Error(Nil) -> Ok(None)
      }
    TomlGetters(fields) ->
      case dict.get(fields, key) {
        Ok(tom.Bool(value)) -> Ok(Some(value))
        Ok(_) -> Error(key <> " must be a boolean")
        Error(Nil) -> Ok(None)
      }
  }
}

// Assembles a `Handler` from the common field set, in the order the
// contract's tables list them, then enforces the kind's requirements.
// Both parsers land here, which is why the per-kind checks exist in
// exactly one place.
fn handler_from_common(
  kind: HandlerKind,
  place: String,
  get: Getters,
) -> Result(Handler, String) {
  let place = place <> " " <> handler_type(kind) <> " hook"
  use command <- result.try(get_string(get, place, "command"))
  use args <- result.try(get_args(get, place, "args"))
  use async_flag <- result.try(get_bool(get, place, async_key(get)))
  use async_rewake <- result.try(get_bool(get, place, async_rewake_key(get)))
  use timeout_s <- result.try(get_int_field(get, place, "timeout"))
  use url <- result.try(get_string(get, place, "url"))
  use server <- result.try(get_string(get, place, "server"))
  use tool <- result.try(get_string(get, place, "tool"))
  use prompt_text <- result.try(get_string(get, place, "prompt"))
  use if_rule <- result.try(get_string(get, place, "if"))
  use status_message <- result.try(get_string(get, place, status_key(get)))
  use once <- result.try(get_bool(get, place, "once"))
  use Nil <- result.try(check_required(
    kind,
    Handler(
      kind:,
      command:,
      args:,
      run_mode: run_mode_of(async_flag),
      rewake: rewake_of(async_rewake),
      timeout_s:,
      url:,
      server:,
      tool:,
      prompt_text:,
      if_rule:,
      status_message:,
      lifetime: lifetime_of(once),
    ),
    place,
  ))

  Ok(Handler(
    kind:,
    command:,
    args:,
    run_mode: run_mode_of(async_flag),
    rewake: rewake_of(async_rewake),
    timeout_s:,
    url:,
    server:,
    tool:,
    prompt_text:,
    if_rule:,
    status_message:,
    lifetime: lifetime_of(once),
  ))
}

// The run mode from the raw three-state flag: present-and-true means
// background, everything else is the foreground default.
fn run_mode_of(async_flag: Option(Bool)) -> RunMode {
  case async_flag {
    Some(True) -> BackgroundAsync
    _ -> ForegroundSync
  }
}

// The wire flag is a three-state boolean the parsers read raw
// (`Some(True)`, `Some(False)`, `None`); these three conversions are
// where it turns into the modelled question, and the `Bool` never
// crosses any other signature.

// The lifetime from the raw three-state flag.
fn lifetime_of(once: Option(Bool)) -> Lifetime {
  case once {
    Some(True) -> Once
    _ -> Repeats
  }
}

// The rewake question from the raw three-state flag.
fn rewake_of(async_rewake: Option(Bool)) -> Rewake {
  case async_rewake {
    Some(True) -> WakesSession
    _ -> Quiet
  }
}

// The async key differs by shape: `async` in both, `asyncRewake` in
// JSON versus `async_rewake` in TOML, `statusMessage` versus
// `status_message`. Three tiny lookups rather than one clever one.
fn async_key(_get: Getters) -> String {
  "async"
}

fn async_rewake_key(get: Getters) -> String {
  case get {
    JsonGetters(_) -> "asyncRewake"
    TomlGetters(_) -> "async_rewake"
  }
}

fn status_key(get: Getters) -> String {
  case get {
    JsonGetters(_) -> "statusMessage"
    TomlGetters(_) -> "status_message"
  }
}

// --- merge, render, hash -----------------------------------------------------

/// Merges several parsed configurations by concatenating their entries
/// in the order given — which is the caller's precedence order, since
/// source precedence (managed > user > project > local > plugin) is a
/// policy question this module has no authority over. Entries are
/// appended, never replaced: Claude's own semantics, and what makes a
/// higher layer's hooks coexist with a lower layer's rather than
/// silencing them. The merged config's source is the last one's, as
/// the label diagnostics will carry.
///
/// ## Examples
///
/// ```gleam
/// merge([user_config, project_config])
/// // -> project entries appended after user entries
/// ```
pub fn merge(configs: List(Config)) -> Config {
  let flattened =
    configs
    |> list.map(fn(config) { config.entries })
    |> list.flatten

  // Two passes, each simple: the first collects every group per event
  // in first-occurrence order of the events, the second rebuilds the
  // entry list from that map. A fold that tried to do both at once is
  // the shape that produced duplicate entries — append-in-place over a
  // list being built is two problems wearing one accumulator.
  let #(order, grouped) =
    list.fold(flattened, #([], dict.new()), fn(state, entry) {
      let #(order, grouped) = state
      let #(event, groups) = entry
      case dict.get(grouped, event) {
        Ok(existing) -> #(
          order,
          dict.insert(grouped, event, list.append(existing, groups)),
        )
        Error(Nil) -> #(
          list.append(order, [event]),
          dict.insert(grouped, event, groups),
        )
      }
    })
  let entries =
    order
    |> list.filter_map(fn(event) {
      dict.get(grouped, event)
      |> result.map(fn(groups) { #(event, groups) })
    })
  let source = case list.last(configs) {
    Ok(config) -> config.source
    Error(Nil) -> Source(label: "none", origin: LoomInline)
  }
  Config(entries:, source:)
}

/// Renders the Loom TOML shape for `loom hooks convert`. The
/// round-trip property `parse_loom(to_toml(config)) == config` is what
/// makes the converter lossless; the render writes every field the
/// model carries, in the contract's field order.
///
/// ## Examples
///
/// ```gleam
/// // parse_loom(to_toml(config), source) == Ok(config)
/// ```
pub fn to_toml(config: Config) -> String {
  config.entries
  |> list.flat_map(render_event)
  |> string_tree.from_strings
  |> string_tree.to_string
}

// Renders one event's groups as `[[hooks.<event>]]` tables.
fn render_event(entry: #(Event, List(Group))) -> List(String) {
  let #(event, groups) = entry
  list.map(groups, fn(group) { render_group(event_name(event), group) })
}

// Renders one matcher group: the header and matcher line, then its
// handler tables nested under it. The regex matcher is written as the
// operator wrote it, unquoted beyond TOML's own escaping.
fn render_group(name: String, group: Group) -> String {
  let header = case group.matcher {
    All -> "[[hooks." <> name <> "]]\n"
    Exact(parts) ->
      "[[hooks."
      <> name
      <> "]]\nmatcher = "
      <> quote_toml(string.join(parts, "|"))
      <> "\n"
    Regex(raw) ->
      "[[hooks." <> name <> "]]\nmatcher = " <> quote_toml(raw) <> "\n"
  }
  header <> render_handlers(name, group.handlers)
}

// Renders a group's handler tables, each `[[hooks.<event>.hooks]]`.
fn render_handlers(name: String, handlers: List(Handler)) -> String {
  handlers
  |> list.map(fn(handler) { render_handler(name, handler) })
  |> string_tree.from_strings
  |> string_tree.to_string
}

// Renders one handler table, in the contract's field order. Fields the
// model carries but this handler does not are simply not written;
// `parse_loom` treats an absent field and a default-valued one alike.
fn render_handler(name: String, handler: Handler) -> String {
  let prefix = "[[hooks." <> name <> ".hooks]]\n"
  let kind_line = "type = " <> quote_toml(handler_type(handler.kind)) <> "\n"
  let command_line = case handler.command {
    Some(command) -> "command = " <> quote_toml(command) <> "\n"
    None -> ""
  }

  prefix
  <> kind_line
  <> command_line
  <> render_args(handler.args)
  <> render_run_mode(handler.run_mode)
  <> render_async_rewake(handler.rewake)
  <> render_timeout(handler.timeout_s)
  <> render_url(handler)
  <> render_server_tool(handler)
  <> render_prompt(handler)
  <> render_if_rule(handler)
  <> render_status_message(handler)
  <> render_lifetime(handler.lifetime)
}

fn render_args(args: Option(List(String))) -> String {
  case args {
    Some(parts) ->
      "args = [" <> string.join(list.map(parts, quote_toml), ", ") <> "]\n"
    None -> ""
  }
}

fn render_run_mode(mode: RunMode) -> String {
  case mode {
    ForegroundSync -> ""
    BackgroundAsync -> "async = true\n"
  }
}

fn render_async_rewake(rewake: Rewake) -> String {
  case rewake {
    Quiet -> ""
    WakesSession -> "async_rewake = true\n"
  }
}

fn render_timeout(timeout_s: Option(Int)) -> String {
  case timeout_s {
    Some(seconds) -> "timeout = " <> int.to_string(seconds) <> "\n"
    None -> ""
  }
}

fn render_url(handler: Handler) -> String {
  case handler.url {
    Some(url) -> "url = " <> quote_toml(url) <> "\n"
    None -> ""
  }
}

fn render_server_tool(handler: Handler) -> String {
  let server = case handler.server {
    Some(server) -> "server = " <> quote_toml(server) <> "\n"
    None -> ""
  }
  let tool = case handler.tool {
    Some(tool) -> "tool = " <> quote_toml(tool) <> "\n"
    None -> ""
  }
  server <> tool
}

fn render_prompt(handler: Handler) -> String {
  case handler.prompt_text {
    Some(text) -> "prompt = " <> quote_toml(text) <> "\n"
    None -> ""
  }
}

fn render_if_rule(handler: Handler) -> String {
  case handler.if_rule {
    Some(rule) -> "if = " <> quote_toml(rule) <> "\n"
    None -> ""
  }
}

fn render_status_message(handler: Handler) -> String {
  case handler.status_message {
    Some(message) -> "status_message = " <> quote_toml(message) <> "\n"
    None -> ""
  }
}

fn render_lifetime(lifetime: Lifetime) -> String {
  case lifetime {
    Repeats -> ""
    Once -> "once = true\n"
  }
}

// Quotes a string as a TOML basic string, escaping what TOML reads
// specially so a value with a quote or a backslash round-trips.
fn quote_toml(text: String) -> String {
  "\""
  <> text
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\t", "\\t")
  <> "\""
}

/// The digest of the parsed model, for the trust record: lowercase hex
/// SHA-256 over a canonical encoding, re-derived on every load so a
/// changed hook definition re-enters review.
///
/// The encoding is the domain tag, then the length-prefixed canonical
/// TOML render of the model. `to_toml`'s round-trip property is what
/// makes the render canonical — two configs that decode equal render
/// equal, so two sources declaring the same hooks share a digest, and
/// a one-character edit anywhere in a handler changes it.
///
/// ## Examples
///
/// ```gleam
/// // string.length(hash(config)) == 64
/// ```
pub fn hash(config: Config) -> String {
  let rendered = to_toml(config)
  let bytes = bit_array.from_string(rendered)

  // The tag plus a 64-bit length prefix, the same shape the archive
  // digest uses: no rendering can be crafted to look like a boundary,
  // and configs from different sources cannot collide on framing.
  let canonical =
    bit_array.concat([
      <<digest_tag:utf8>>,
      <<bit_array.byte_size(bytes):size(64)>>,
      bytes,
    ])

  blob.ref_for(canonical) |> string.drop_start(string.length("sha256-"))
}

// --- load-time diagnostics ---------------------------------------------------

/// One visibility finding at load time: what was parsed and why this
/// build will not do with it what Claude would. The issue's
/// requirement — missing permissions, unavailable payload fields, and
/// unsupported declarations visible at load time where possible —
/// lands here for the parse-time-visible half; the runner-side
/// refusals carry the rest.
pub type LoadNote {
  LoadNote(source_label: String, what: String)
}

// Events with no harness moment in this build: their entries load —
// the design note's declared-and-skipped posture, so a collection
// loads without edits — but never fire. This set is the matrix's skip
// list and **shrinks as moments land**, one row at a time; an event
// moving to a wired moment leaves this const and its note goes away
// with it. `Stop` and `SubagentStop` are wired at `finish_boundary`,
// `PreToolUse` at clearance, and so on per the design note's table.
const no_moment_events = [
  MessageDisplay,
  TeammateIdle,
  WorktreeCreate,
  WorktreeRemove,
  ConfigChange,
  CwdChanged,
  DirectoryAdded,
  FileChanged,
  InstructionsLoaded,
  PostCompact,
  PreModelSwitch,
  PostModelSwitch,
  SubagentStart,
  TaskCreated,
  TaskCompleted,
  StopFailure,
  Setup,
  Elicitation,
  ElicitationResult,
  UserPromptExpansion,
  PostToolUseFailure,
  PostToolBatch,
  PermissionDenied,
  SessionEnd,
]

/// The load-time findings for one configuration: per-handler notes for
/// kinds this build does not run and per-`once` notes where the
/// declaration will be ignored, then one note per event that has no
/// moment to fire on. Order follows the config's own order.
pub fn notes(config: Config) -> List(LoadNote) {
  let label = config.source.label

  // Per-handler notes, in the config's own order.
  let handler_notes =
    config.entries
    |> list.flat_map(fn(entry) {
      let #(event, groups) = entry
      list.flat_map(groups, fn(group) {
        list.flat_map(group.handlers, fn(handler) {
          handler_notes(event, handler, label)
        })
      })
    })

  // Per-event notes for the declared-and-skipped set, deduplicated so
  // a file declaring ten `MessageDisplay` groups reports the gap once.
  let event_notes =
    config.entries
    |> list.filter_map(fn(entry) {
      let #(event, _) = entry
      case list.contains(no_moment_events, event) {
        True ->
          Ok(LoadNote(
            source_label: label,
            what: event_name(event)
              <> " has no moment in this build; entries load but never fire",
          ))
        False -> Error(Nil)
      }
    })
    |> list.unique

  list.append(handler_notes, event_notes)
}

// One handler's findings. Each note says what the operator wrote and
// what this build does with it — the honest middle between faking a
// fire and refusing the collection.
fn handler_notes(
  event: Event,
  handler: Handler,
  label: String,
) -> List(LoadNote) {
  // The event carries no moment, so the handler would never run
  // anyway and the per-handler note would be noise on top of the
  // event note.
  case list.contains(no_moment_events, event) {
    True -> []

    False -> {
      let kind_note = case handler.kind {
        Command -> []
        _ -> [
          LoadNote(
            source_label: label,
            what: describes_handler(handler)
              <> " parsed; this build runs command hooks only",
          ),
        ]
      }
      let once_note = case handler.lifetime {
        Repeats -> []
        Once -> [
          LoadNote(
            source_label: label,
            what: describes_handler(handler)
              <> " declares once: true; once is honored only for "
              <> "skill-declared hooks",
          ),
        ]
      }
      list.append(kind_note, once_note)
    }
  }
}

// --- shared field accessors --------------------------------------------------

// The TOML spelling of a refusal the catalogue's voice would write.
fn describe_toml_error(error: tom.ParseError) -> String {
  case error {
    tom.Unexpected(got:, expected:) ->
      "not valid toml: expected " <> expected <> ", got `" <> got <> "`"
    tom.KeyAlreadyInUse(key:) ->
      "not valid toml: the key " <> string.join(key, ".") <> " appears twice"
  }
}

// The JSON spelling of the same refusal, through the corruption
// report's own description.
fn describe_json_error(report: CorruptionReport) -> String {
  "not valid json: "
  <> "expected "
  <> report.expected
  <> " at "
  <> report.subject
  <> ", got: "
  <> report.context
}

// The JSON object's fields, refusing non-objects with the place named.
fn object_fields(
  value: JsonValue,
  place: String,
) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(place <> " must be a json object")
  }
}

// An optional JSON string field, refusing a present non-string.
fn optional_string(
  fields: List(#(String, JsonValue)),
  place: String,
  key: String,
) -> Result(Option(String), String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Ok(Some(text))
    Ok(_) -> Error(place <> ": " <> key <> " must be a string")
    Error(Nil) -> Ok(None)
  }
}

// An optional TOML string field, refusing a present non-string.
fn optional_toml_string(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(Option(String), String) {
  case dict.get(fields, key) {
    Ok(tom.String(text)) -> Ok(Some(text))
    Ok(_) -> Error(place <> ": " <> key <> " must be a string")
    Error(Nil) -> Ok(None)
  }
}

// An optional JSON integer field.
fn optional_json_int(
  fields: List(#(String, JsonValue)),
  place: String,
  key: String,
) -> Result(Option(Int), String) {
  case list.key_find(fields, key) {
    Ok(json.Int(value)) -> Ok(Some(value))
    Ok(_) -> Error(place <> ": " <> key <> " must be an integer")
    Error(Nil) -> Ok(None)
  }
}

// An optional TOML integer field.
fn optional_toml_int(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(Option(Int), String) {
  case dict.get(fields, key) {
    Ok(tom.Int(value)) -> Ok(Some(value))
    Ok(_) -> Error(place <> ": " <> key <> " must be an integer")
    Error(Nil) -> Ok(None)
  }
}

// The exec-form argument vector from JSON: an array of strings, or
// absent.
fn optional_json_args(
  fields: List(#(String, JsonValue)),
  place: String,
  key: String,
) -> Result(Option(List(String)), String) {
  case list.key_find(fields, key) {
    Ok(json.Array(items)) ->
      items
      |> list.try_map(fn(item) {
        case item {
          json.String(part) -> Ok(part)
          _ -> Error(place <> ": " <> key <> " must be an array of strings")
        }
      })
      |> result.map(Some)
    Ok(_) -> Error(place <> ": " <> key <> " must be an array of strings")
    Error(Nil) -> Ok(None)
  }
}

// The same argument vector from TOML.
fn optional_toml_args(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(Option(List(String)), String) {
  case dict.get(fields, key) {
    Ok(tom.Array(items)) ->
      items
      |> list.try_map(fn(item) {
        case item {
          tom.String(part) -> Ok(part)
          _ -> Error(place <> ": " <> key <> " must be an array of strings")
        }
      })
      |> result.map(Some)
    Ok(_) -> Error(place <> ": " <> key <> " must be an array of strings")
    Error(Nil) -> Ok(None)
  }
}

// The domain tag of the hash encoding, versioned so an encoding change
// is a different digest rather than a silent reinterpretation.
const digest_tag = "loom-hooks-config-v1"
