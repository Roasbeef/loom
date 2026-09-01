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
  /// Inspect the session's agents and sub-agents.
  Agents
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
  let input = string.trim(input)
  case string.starts_with(input, "/"), string.contains(input, " ") {
    True, False ->
      all_suggestions()
      |> list.filter(fn(suggestion) {
        string.starts_with(suggestion.command, input)
      })
    _, _ -> []
  }
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
    Suggestion("/notes", "browse agent notes", False),
    Suggestion("/details", "toggle reasoning and tool detail", False),
    Suggestion("/strands", "list session strands", False),
    Suggestion("/strand", "switch the active strand", True),
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
    "/agents" -> Agents
    "/notes" -> Notes
    "/details" -> Details
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
    "/steer " <> rest -> required_argument("steer", rest, Steer)
    "/queue " <> rest -> required_argument("queue", rest, Queue)
    "/" <> rest -> Unknown(command_name(rest))
    text -> Prompt(text)
  }
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
  <> "/notes            browse the active strand's agent notes\n"
  <> "/details          toggle reasoning and tool detail\n"
  <> "/strands          list session strands\n"
  <> "/strand <name>    switch the active strand\n"
  <> "/fork <name>      fork the active strand\n"
  <> "/compact          compact the active strand\n"
  <> "/abort            abort the live operation\n"
  <> "/steer <text>     inject into the live operation\n"
  <> "/queue <text>     run after the live operation\n"
  <> "/clear            clear this local transcript\n"
  <> "/quit             leave the client"
}
