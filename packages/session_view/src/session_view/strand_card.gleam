//// The words on a strand's card in a host's strand panel: one status line
//// under the name, and the count of strands that are waiting for a person.
////
//// A card answers "what is this strand doing" in one line, so a host that
//// draws cards (the web view's Strands tab, and the terminal when its strip
//// is revised) says the same words. The line is derived from the roster's
//// `Line`, which already joins the captured status with the operation's
//// activity or the strand's own summary, so nothing here reads the session
//// again. A strand that needs a decision says only so: its line is the same
//// fixed words whatever the request was, because the request is the approval
//// card's to show, in the place the person can answer it.
////
//// The activity text of a working strand is session text (a model wrote the
//// summary, or the captured tool name is shown), and hosts draw it as text.
//// The fixed words carry the state; the text after the separator only adds
//// to it. The roster's text is the engine's, and some of it is the engine's
//// vocabulary rather than a person's: the phase `assistant`, a state word it
//// already said (`Waiting · Waiting for x`), or a tool's whole command line.
//// `status_line` words those for a card, and `status_title` keeps the whole
//// text for a host's tooltip, so a long command is one hover away and not on
//// the card.
////
//// The module is portable: it holds no `@external`, performs no I/O and
//// reads no clock.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/agent_roster
import session_view/agent_view
import session_view/text_hygiene

/// The card's one status line for `line`.
///
/// A strand that needs a decision reads `Needs approval`. A working or
/// waiting strand reads its state word, and what it is doing after ` · ` when
/// that adds something: the engine's phase `assistant` reads `thinking`, a
/// tool's activity names the tool and drops its command, and an activity that
/// already starts with the state word (`Waiting for x` under `Waiting`) is the
/// line by itself. A finished strand adds how long its last operation ran,
/// when the roster knows. The other states are their state words.
///
/// ## Examples
///
/// ```gleam
/// // strand_card.status_line(line) == "Working · code_mode"
/// ```
pub fn status_line(line: agent_roster.Line) -> String {
  case line.status {
    agent_view.NeedsInput -> "Needs approval"
    agent_view.Working | agent_view.Waiting -> {
      let word = agent_view.label(line.status)
      case
        string.starts_with(string.lowercase(line.text), string.lowercase(word))
      {
        True -> line.text
        False ->
          case doing(line.text) {
            "" -> word
            text -> word <> " · " <> text
          }
      }
    }
    agent_view.Finished ->
      case line.elapsed_s {
        Some(seconds) ->
          agent_view.label(line.status) <> " " <> agent_roster.duration(seconds)
        None -> agent_view.label(line.status)
      }
    agent_view.Failed
    | agent_view.Halted
    | agent_view.Idle
    | agent_view.Unavailable -> agent_view.label(line.status)
  }
}

/// Everything the roster knows about what the strand is doing, for a host's
/// tooltip on the card: the status line, and after it the whole activity text
/// when the line shortened it, such as the command of a tool. It is session
/// text, so a host draws it as an escaped attribute or a text node, never
/// as markup, and it is cut to `title_limit` characters.
///
/// ## Examples
///
/// ```gleam
/// // strand_card.status_title(line) == "Working · bash · make check"
/// ```
pub fn status_title(line: agent_roster.Line) -> String {
  case line.status, line.text {
    _, "" -> status_line(line)
    agent_view.Working, text | agent_view.Waiting, text -> {
      let word = agent_view.label(line.status)
      let whole = case
        string.starts_with(string.lowercase(text), string.lowercase(word))
      {
        True -> text
        False -> word <> " · " <> text
      }

      string.slice(whole, 0, title_limit)
    }
    _, _ -> status_line(line)
  }
}

/// The most characters `status_title` keeps.
pub const title_limit = 240

// What a working strand is doing, in a person's words, or empty when the
// engine's text adds nothing to the state word. The phases are the engine's:
// `assistant` and `streaming` are the model generating, and `tool`,
// `running tools` and `running` say only that something runs. A tool's
// activity is `name · command`; the name is one word and the command is
// everything after it, so a first part that is one word is the tool.
fn doing(text: String) -> String {
  case text {
    "" | "tool" | "running tools" | "running" -> ""
    "assistant" | "streaming" -> "thinking"
    _ ->
      case string.split_once(text, " · ") {
        Ok(#(name, _)) ->
          case string.contains(name, " ") {
            True -> text
            False -> name
          }
        Error(Nil) -> text
      }
  }
}

/// The glyph before a status line: `●` for work in progress, `◌` for a wait,
/// `!` for a decision, `✓` for a finished strand and so on. It is the
/// state's mark and carries no session text, so a host may draw it in the
/// state's colour and pulse the working one.
///
/// ## Examples
///
/// ```gleam
/// assert strand_card.glyph(agent_view.Finished) == "✓"
/// ```
pub fn glyph(status: agent_view.Status) -> String {
  case status {
    agent_view.Working -> "●"
    agent_view.Waiting -> "◌"
    agent_view.NeedsInput -> "!"
    agent_view.Finished -> "✓"
    agent_view.Failed -> "×"
    agent_view.Halted -> "■"
    agent_view.Idle -> "○"
    agent_view.Unavailable -> "–"
  }
}

/// The task a strand's own view shows, or `None` when the roster holds no task
/// worth a row. `agent_view` words a task it cannot read as `Task unavailable`
/// or `Task brief outside loaded history`, which tell a reader nothing about
/// the strand. The advisor's roster title is the prompt of its feed
/// (`[advisor feed: ...]` and the primary's recent turn), which is a
/// placeholder and not a task: the advisor's task is fixed, and its card's
/// status already says so. A view leaves each of those rows out as it leaves
/// out any figure it does not know.
///
/// A sub-agent's brief is the model's whole first message, so it is cut to
/// its first sentence and `task_limit` characters, ending in an ellipsis when
/// it was cut, which keeps a row to the length a figure should have.
///
/// ## Examples
///
/// ```gleam
/// assert strand_card.task_words("Fix the parser") == Some("Fix the parser")
/// assert strand_card.task_words("Task unavailable") == None
/// assert strand_card.task_words("[advisor feed: what changed] user: Add it")
///   == None
/// assert strand_card.task_words("Fix the parser. Then add tests.")
///   == Some("Fix the parser.")
/// ```
pub fn task_words(title: String) -> Option(String) {
  let placeholder = fn(known: String) {
    string.lowercase(title) == string.lowercase(known)
  }

  case
    title == ""
    || placeholder(agent_view.task_unavailable)
    || placeholder(agent_view.task_outside_history)
    || string.starts_with(title, advisor_feed_prefix)
  {
    True -> None
    False -> Some(first_sentence(title))
  }
}

/// The most characters `task_words` keeps of a brief.
pub const task_limit = 120

// How the advisor's roster title opens: the feed's own header, which the
// engine writes for the model and is no task.
const advisor_feed_prefix = "[advisor feed"

// The brief's first sentence, cut at `task_limit` characters. A sentence ends
// at a full stop followed by a space, so `calc.py` and `v1.2` do not end one.
fn first_sentence(text: String) -> String {
  let one_line = text_hygiene.single_line(text)
  let sentence = case string.split_once(one_line, ". ") {
    Ok(#(first, _rest)) -> first <> "."
    Error(Nil) -> one_line
  }

  case string.length(sentence) > task_limit {
    True -> string.slice(sentence, 0, task_limit - 1) <> "…"
    False -> sentence
  }
}

/// A model's name as a strand's own view shows it: the last path segment of
/// its identifier, so `zai-org/GLM-5.3` reads `GLM-5.3`. A host keeps the
/// whole identifier for a tooltip.
///
/// ## Examples
///
/// ```gleam
/// assert strand_card.model_name("zai-org/GLM-5.3") == "GLM-5.3"
/// assert strand_card.model_name("kimi-k3") == "kimi-k3"
/// ```
pub fn model_name(model: String) -> String {
  case list.last(string.split(model, "/")) {
    Ok("") | Error(Nil) -> model
    Ok(name) -> name
  }
}

/// How many of `lines` are waiting for a decision: the number the Strands
/// tab's badge shows. A strand with a pending approval is exactly one whose
/// status is `NeedsInput`, which `agent_view` derives from the record of the
/// escalation and no other evidence.
///
/// ## Examples
///
/// ```gleam
/// assert strand_card.needing([]) == 0
/// ```
pub fn needing(lines: List(agent_roster.Line)) -> Int {
  list.count(lines, fn(line) { line.status == agent_view.NeedsInput })
}

/// The words for a strand's context size on its own view, or `None` when the
/// roster knows no size: the count in the strip's own short form followed by
/// `tokens`.
///
/// ## Examples
///
/// ```gleam
/// assert strand_card.context_words(Some(1500)) == Some("1.5k tokens")
/// assert strand_card.context_words(None) == None
/// ```
pub fn context_words(tokens: Option(Int)) -> Option(String) {
  case tokens {
    Some(count) -> Some(agent_roster.count_label(count) <> " tokens")
    None -> None
  }
}
