//// Slash-command parsing for the terminal client.
////
//// Commands stay separate from protocol encoding: this module decides what
//// the operator meant, while the connection layer later decides which frozen
//// ClientGateway envelope carries it.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// One action entered at the prompt.
pub type Command {
  /// Show the command reference.
  Help

  /// Show the model catalogue.
  Models

  /// Switch the active strand to one catalogue model by name.
  Model(
    /// The stable catalogue name selected by the operator.
    name: String,
  )

  /// Show the strand list.
  Strands

  /// List every schedule the session holds — the operator's own tables
  /// and the ones its strands created.
  Schedules

  /// Retire one schedule a strand created.
  Unschedule(
    /// The schedule's name, as the listing prints it.
    name: String,
    /// The strand it fires onto; `None` means the active strand, which
    /// is the row an operator is usually looking at.
    target: Option(String),
  )

  /// Inspect the session's agents and sub-agents.
  Agents

  /// Choose another locally managed session.
  Sessions

  /// Browse the active strand's injected agent-note digest.
  Notes

  /// Toggle expanded reasoning and tool detail.
  Details

  /// Switch the active strand by name.
  Strand(
    /// The stable strand name to make active.
    name: String,
  )

  /// Fork the active strand.
  Fork(
    /// The operator-facing name for the new branch strand.
    name: String,
  )

  /// Set the active strand's reasoning level for its next turns.
  Effort(
    /// The level word the server accepts: `off`, `minimal`, `low`,
    /// `medium`, `high`, `xhigh` or `max`. Validated server-side, so an
    /// unknown word comes back as a worded error rather than a guess.
    level: String,
  )

  /// Compact the active strand.
  Compact

  /// Abort the active strand's live operation.
  Abort

  /// Inject text into the active strand's live operation.
  Steer(
    /// The instruction that must affect the in-flight turn.
    text: String,
  )

  /// Queue text to run after the active strand's live operation.
  Queue(
    /// The instruction that must wait for the in-flight turn to settle.
    text: String,
  )

  /// Clear only this client's rendered transcript.
  Clear

  /// Leave the client.
  Quit

  /// Send ordinary text as a prompt.
  Prompt(
    /// The user-authored prompt text.
    text: String,
  )

  /// A slash command the client does not know.
  Unknown(
    /// The first slash-prefixed word that was not recognized.
    name: String,
  )

  /// A known command whose required argument is absent.
  MissingArgument(
    /// The command name whose argument is missing.
    name: String,
  )

  /// Ignore an empty submission.
  Empty
}

/// One slash-command row shown while the operator is composing.
pub type Suggestion {
  Suggestion(
    /// The slash-prefixed command inserted into the editor.
    command: String,
    /// A short operator-facing description.
    description: String,
    /// Whether choosing the row should leave room for an argument.
    takes_argument: Bool,
  )
}

/// Returns prefix-matched slash commands for an incomplete command word.
pub fn suggestions(input: String) -> List(Suggestion) {
  let input = string.trim_start(input)
  case input {
    // A command with a closed argument vocabulary keeps the palette open
    // past the space and offers the words themselves, so the operator
    // never has to remember them; Tab completes one and Enter submits.
    "/effort " <> partial -> level_suggestions(string.trim(partial))
    _ -> word_suggestions(string.trim(input))
  }
}

fn word_suggestions(input: String) -> List(Suggestion) {
  case string.starts_with(input, "/"), string.contains(input, " ") {
    True, False ->
      all_suggestions()
      |> list.filter(fn(suggestion) {
        string.starts_with(suggestion.command, input)
      })
    _, _ -> []
  }
}

/// The reasoning levels `/effort` completes, with what each one means.
/// The vocabulary is the server's (`set_config` validates it); the
/// adapters fold its seven steps onto whatever their dialect offers.
pub const effort_levels = [
  #("off", "no reasoning requested"),
  #("minimal", "the smallest budget the model offers"),
  #("low", "a small reasoning budget"),
  #("medium", "a medium reasoning budget"),
  #("high", "a large reasoning budget"),
  #("xhigh", "beyond high where the model offers it"),
  #("max", "the largest budget the model offers"),
]

fn level_suggestions(partial: String) -> List(Suggestion) {
  effort_levels
  |> list.filter(fn(level) { string.starts_with(level.0, partial) })
  |> list.map(fn(level) { Suggestion("/effort " <> level.0, level.1, False) })
}

/// Moves a slash palette selection and wraps at either edge.
pub fn move_selection(selected: Int, count: Int, down: Bool) -> Int {
  case count <= 0, down, selected {
    True, _, _ -> 0
    False, True, selected if selected >= count - 1 -> 0
    False, True, selected -> selected + 1
    False, False, selected if selected <= 0 -> count - 1
    False, False, selected -> selected - 1
  }
}

/// Returns the command text selected in a filtered palette.
pub fn selected(
  suggestions: List(Suggestion),
  selected: Int,
) -> Option(String) {
  suggestions
  |> list.drop(selected)
  |> list.first
  |> option_from_result
  |> option_map(fn(suggestion) {
    case suggestion.takes_argument {
      True -> suggestion.command <> " "
      False -> suggestion.command
    }
  })
}

fn all_suggestions() -> List(Suggestion) {
  [
    Suggestion("/help", "show the command reference", False),
    Suggestion("/model", "choose a model", False),
    Suggestion("/agents", "inspect agents and sub-agents", False),
    Suggestion("/sessions", "switch local sessions", False),
    Suggestion("/notes", "browse agent notes", False),
    Suggestion("/details", "toggle reasoning and tool detail", False),
    Suggestion("/effort", "set the active strand's reasoning level", True),
    Suggestion("/strands", "list session strands", False),
    Suggestion("/strand", "switch the active strand", True),
    Suggestion("/schedules", "list session schedules", False),
    Suggestion("/unschedule", "retire one schedule", True),
    Suggestion("/fork", "fork the active strand", True),
    Suggestion("/compact", "compact the active strand", False),
    Suggestion("/abort", "abort the live operation", False),
    Suggestion("/steer", "inject into the live operation", True),
    Suggestion("/queue", "run after the live operation", True),
    Suggestion("/clear", "clear this local transcript", False),
    Suggestion("/quit", "leave the client", False),
  ]
}

fn option_from_result(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

fn option_map(value: Option(a), map: fn(a) -> b) -> Option(b) {
  case value {
    Some(value) -> Some(map(value))
    None -> None
  }
}

/// Parses prompt text into a slash command or ordinary prompt.
///
/// The command name is case-sensitive and the first run of whitespace
/// separates it from its argument. The argument keeps its internal spaces.
///
/// ## Examples
///
/// ```gleam
/// assert command.parse("/models") == command.Models
/// ```
///
/// ```gleam
/// assert command.parse("hello") == command.Prompt("hello")
/// ```
///
pub fn parse(input: String) -> Command {
  let input = string.trim(input)
  case input {
    "" -> Empty
    "/help" -> Help
    "/models" -> Models
    "/model" -> Models
    "/strands" -> Strands
    "/schedules" -> Schedules
    "/unschedule" -> MissingArgument("unschedule")
    "/agents" -> Agents
    "/sessions" -> Sessions
    "/notes" -> Notes
    "/details" -> Details
    "/effort" -> MissingArgument("effort")
    "/compact" -> Compact
    "/abort" -> Abort
    "/steer" -> MissingArgument("steer")
    "/queue" -> MissingArgument("queue")
    "/clear" -> Clear
    "/quit" -> Quit
    "/strand" -> MissingArgument("strand")
    "/fork" -> MissingArgument("fork")
    "/model " <> rest -> required_argument("model", rest, Model)
    "/strand " <> rest -> required_argument("strand", rest, Strand)
    "/fork " <> rest -> required_argument("fork", rest, Fork)
    "/effort " <> rest -> required_argument("effort", rest, Effort)
    "/steer " <> rest -> required_argument("steer", rest, Steer)
    "/queue " <> rest -> required_argument("queue", rest, Queue)
    "/unschedule " <> rest -> unschedule(rest)
    "/" <> rest -> Unknown(command_name(rest))
    text -> Prompt(text)
  }
}

// `/unschedule <name> [target]`. The target is optional because the
// common case is a schedule on the strand the operator is already
// watching; a second word names another one, which is how a heartbeat a
// parent set onto a subagent is reached.
fn unschedule(raw: String) -> Command {
  case words(raw) {
    [] -> MissingArgument("unschedule")
    [name] -> Unschedule(name:, target: None)
    [name, target, ..] -> Unschedule(name:, target: Some(target))
  }
}

fn words(raw: String) -> List(String) {
  raw
  |> string.trim
  |> string.split(" ")
  |> list.filter(fn(word) { word != "" })
}

fn required_argument(
  name: String,
  raw: String,
  build: fn(String) -> Command,
) -> Command {
  case string.trim(raw) {
    "" -> MissingArgument(name)
    value -> build(value)
  }
}

fn command_name(raw: String) -> String {
  raw
  |> string.split(" ")
  |> list.first
  |> result_or(raw)
}

fn result_or(value: Result(a, Nil), fallback: a) -> a {
  case value {
    Ok(found) -> found
    Error(Nil) -> fallback
  }
}

/// The command reference rendered by `/help`.
///
/// ## Examples
///
/// ```gleam
/// assert command.help_text() |> string.contains("/model")
/// ```
pub fn help_text() -> String {
  "/help             show this command reference\n"
  <> "/model            open the model selector\n"
  <> "/model <name>     switch the active strand model\n"
  <> "/agents           inspect agents and sub-agents\n"
  <> "/sessions         switch locally managed sessions\n"
  <> "/notes            browse the active strand's agent notes\n"
  <> "/details          toggle reasoning and tool detail\n"
  <> "/effort <level>   set reasoning: off, minimal, low, medium, high, xhigh, max\n"
  <> "/strands          list session strands\n"
  <> "/schedules        list session schedules\n"
  <> "/unschedule <name> [target]  retire one schedule\n"
  <> "/strand <name>    switch the active strand\n"
  <> "/fork <name>      fork the active strand\n"
  <> "/compact          compact the active strand\n"
  <> "/abort            abort the live operation\n"
  <> "/steer <text>     inject into the live operation\n"
  <> "/queue <text>     run after the live operation\n"
  <> "/clear            clear this local transcript\n"
  <> "/quit             leave the client"
}
