//// Slash-command parsing for the terminal client.
////
//// Commands stay separate from protocol encoding: this module decides what
//// the operator meant, while the connection layer later decides which frozen
//// ClientGateway envelope carries it.

import gleam/list
import gleam/string

/// One action entered at the prompt.
pub type Command {
  /// Show the command reference.
  Help
  /// Show the model catalogue.
  Models
  /// Switch the active strand to one catalogue model by name.
  Model(name: String)
  /// Show the strand list.
  Strands
  /// Inspect the session's agents and sub-agents.
  Agents
  /// Toggle expanded reasoning and tool detail.
  Details
  /// Switch the active strand by name.
  Strand(name: String)
  /// Fork the active strand.
  Fork(name: String)
  /// Compact the active strand.
  Compact
  /// Abort the active strand's live operation.
  Abort
  /// Clear only this client's rendered transcript.
  Clear
  /// Leave the client.
  Quit
  /// Send ordinary text as a prompt.
  Prompt(text: String)
  /// A slash command the client does not know.
  Unknown(name: String)
  /// A known command whose required argument is absent.
  MissingArgument(name: String)
  /// Ignore an empty submission.
  Empty
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
    "/details" -> Details
    "/compact" -> Compact
    "/abort" -> Abort
    "/clear" -> Clear
    "/quit" -> Quit
    "/strand" -> MissingArgument("strand")
    "/fork" -> MissingArgument("fork")
    "/model " <> rest -> required_argument("model", rest, Model)
    "/strand " <> rest -> required_argument("strand", rest, Strand)
    "/fork " <> rest -> required_argument("fork", rest, Fork)
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
pub fn help_text() -> String {
  "/help             show this command reference\n"
  <> "/model            open the model selector\n"
  <> "/model <name>     switch the active strand model\n"
  <> "/agents           inspect agents and sub-agents\n"
  <> "/details          toggle reasoning and tool detail\n"
  <> "/strands          list session strands\n"
  <> "/strand <name>    switch the active strand\n"
  <> "/fork <name>      fork the active strand\n"
  <> "/compact          compact the active strand\n"
  <> "/abort            abort the live operation\n"
  <> "/clear            clear this local transcript\n"
  <> "/quit             leave the client"
}
