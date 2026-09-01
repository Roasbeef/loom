//// The summarization pack: the words a provider is sent when the
//// harness asks it to compact a conversation, plus the serializer that
//// turns doomed messages into the text those words talk about.
////
//// ## Why this is a second pack rather than more sections in the first
////
//// `prompt/default` is the *system* prompt: rendered once, pinned, and
//// sent byte-identically behind a one-hour cache breakpoint on every
//// request of every strand. A section added there is paid for forever.
//// Summarization prose is the opposite shape — read once, by one
//// request, at the moment a strand's context overflows — so it lives in
//// its own pack file with its own version identity. Both are decoded by
//// the same total decoder (`pack.decode`) and both are swappable data:
//// mutate the pack, run the evaluation, keep the winner, never touch
//// Gleam. Keeping them separate is also what stops a summarization edit
//// from costing a session-wide cache rewrite.
////
//// ## The shape of a summary request
////
//// One user message and nothing else. `system(pack)` and
//// `instruction(pack, input)` are concatenated by the caller into that
//// single message, deliberately: a summary request carries **no system
//// prompt and no tool array**, because both of those render ahead of
//// the messages in a provider request and both carry the one-hour
//// breakpoints. A one-shot prompt that will never be read again must
//// not pay a cache write, which is pi's `cacheRetention: "none"`
//// expressed as a request shape rather than as a provider flag
//// (`docs/design-notes/compaction-and-memory.md`, Part 2).
////
//// ## The format the prompts demand
////
//// pi's structured template, ported section for section: Goal /
//// Constraints & Preferences / Progress (Done, In Progress, Blocked) /
//// Key Decisions / Next Steps / Critical Context, with an explicit
//// instruction to preserve exact paths, identifiers and error messages
//// verbatim. When a previous summary exists the *update* prompt merges
//// into it rather than restating it, which is what keeps a
//// twice-compacted session from losing its oldest constraints.
////
//// ## The conversation is data, never instructions
////
//// `serialize` role-tags the doomed messages and wraps them in
//// `<conversation>`; the prompts say in as many words that everything
//// inside the tag is transcript to be summarized. Tool results are
//// truncated at `tool_result_limit` characters because they dominate
//// context and are the least summary-relevant thing in it — Loom
//// already caps the worst of them at commit time, offloading anything
//// over 64 KiB to a content-addressed blob whose `sha256-<hex>` address
//// the prompt asks the model to carry forward. Splicing is `pack.fill`,
//// which never re-scans a substituted value, so a transcript containing
//// `{conversation}` cannot expand anything.

import core/json
import core/message.{type AgentMessage}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import prompt/pack.{type Pack}

/// How many characters of a single tool result reach the summarizer.
/// pi's 2,000: tool output is the bulk of a transcript and the least of
/// what a summary needs, and Loom already caps the worst of it at commit
/// time by offloading anything over 64 KiB to a blob ref.
pub const tool_result_limit = 2000

/// The sections a summary pack is expected to carry. A pack missing one
/// still renders — the missing body reads as empty — which is why
/// `problems` reports it rather than `instruction` failing.
pub const canonical_sections = ["system", "initial", "update", "branch"]

/// The fragments the inputs select between.
pub const required_fragments = [
  "_previous_summary", "_custom_instructions", "_file_operations",
]

/// Every placeholder name a summary pack may use.
pub const binding_names = [
  "conversation", "previous_summary_text", "custom_instructions_text",
  "files_read", "files_modified", "previous_summary", "custom_instructions",
  "file_operations",
]

/// What a summary request is being asked to summarize.
///
/// Constructor invariants: `conversation` is `serialize`d transcript
/// text, not raw messages; `files_read` and `files_modified` are sorted,
/// duplicate-free workspace paths (the preparation's `FileOperations`
/// normalizes them); `previous_summary` is the summary the last
/// compaction on this path published, when there was one.
pub type Input {
  /// A compaction summary: the older half of one strand's context.
  Compaction(
    conversation: String,
    previous_summary: Option(String),
    custom_instructions: Option(String),
    files_read: List(String),
    files_modified: List(String),
  )

  /// A branch summary: the work on a branch being navigated away from.
  Branch(conversation: String, custom_instructions: Option(String))
}

/// The summarization system prompt: what the model is, and the standing
/// refusal to continue the conversation it is reading.
///
/// The caller sends it as the head of the request's single user message
/// rather than in the `system` field — see the module doc.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(decoded) = pack.decode(default.summary_source)
/// assert summary.system(decoded) != ""
/// ```
///
pub fn system(pack: Pack) -> String {
  body(pack, "system")
}

/// The instruction half of a summary request: the transcript, the
/// format demand, and whatever context the input carries (a previous
/// summary to merge into, operator instructions, cumulative file
/// operations).
///
/// Total: a pack missing the section renders the empty string, and an
/// unknown placeholder renders empty, exactly as `pack.render` behaves.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(decoded) = pack.decode(default.summary_source)
/// let text =
///   summary.instruction(
///     decoded,
///     summary.Branch(conversation: "hi", custom_instructions: option.None),
///   )
/// assert string.contains(text, "hi")
/// ```
///
pub fn instruction(pack: Pack, input: Input) -> String {
  case input {
    Branch(conversation:, custom_instructions:) ->
      pack.fill(body(pack, "branch"), [
        #("conversation", conversation),
        #(
          "custom_instructions",
          selected(pack, "_custom_instructions", custom_instructions),
        ),
        #("previous_summary", ""),
        #("file_operations", ""),
      ])
    Compaction(
      conversation:,
      previous_summary:,
      custom_instructions:,
      files_read:,
      files_modified:,
    ) -> {
      let section = case previous_summary {
        Some(_) -> "update"
        None -> "initial"
      }
      pack.fill(body(pack, section), [
        #("conversation", conversation),
        #(
          "previous_summary",
          selected(pack, "_previous_summary", previous_summary),
        ),
        #(
          "custom_instructions",
          selected(pack, "_custom_instructions", custom_instructions),
        ),
        #("file_operations", file_operations(pack, files_read, files_modified)),
      ])
    }
  }
}

// A fragment filled with its own literal binding, or the empty string
// when the input does not select it (or the pack does not carry it).
fn selected(pack: Pack, fragment: String, value: Option(String)) -> String {
  case option.then(value, non_blank) {
    None -> ""
    Some(trimmed) ->
      pack.fill(body(pack, fragment), [
        #("previous_summary_text", trimmed),
        #("custom_instructions_text", trimmed),
      ])
  }
}

// `Some("")` and `Some("   ")` both mean "the input carried nothing worth
// selecting the fragment for".
fn non_blank(text: String) -> Option(String) {
  case string.trim(text) {
    "" -> None
    trimmed -> Some(trimmed)
  }
}

// The cumulative file-operation block, absent while both lists are
// empty. `FileOperations` on a preparation is empty today (filling it
// from the summarized span's tool calls is Stage C1); the fragment is
// here so that filling it is a preparation change and not a prompt one.
fn file_operations(
  pack: Pack,
  read: List(String),
  modified: List(String),
) -> String {
  case read, modified {
    [], [] -> ""
    _, _ ->
      pack.fill(body(pack, "_file_operations"), [
        #("files_read", string.join(read, "\n")),
        #("files_modified", string.join(modified, "\n")),
      ])
  }
}

fn body(pack: Pack, name: String) -> String {
  case pack.section(pack, name) {
    Ok(template) -> template
    Error(Nil) -> ""
  }
}

/// The problems a summary pack has: a canonical section or selectable
/// fragment it does not carry, or a placeholder no binding provides.
/// The same axis `pack.problems` reports on for the system pack, over
/// this pack's own vocabulary.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(decoded) = pack.decode(default.summary_source)
/// assert summary.problems(decoded) == []
/// ```
///
pub fn problems(pack: Pack) -> List(pack.Problem) {
  let present = list.map(pack.sections, fn(section) { section.name })
  let missing =
    list.append(canonical_sections, required_fragments)
    |> list.filter(fn(name) { !list.contains(present, name) })
    |> list.map(pack.MissingSection)
  let unknown =
    list.flat_map(pack.sections, fn(section) {
      pack.placeholders(section.template)
      |> list.filter(fn(name) { !list.contains(binding_names, name) })
      |> list.map(fn(name) {
        pack.UnknownPlaceholder(section: section.name, name:)
      })
    })
  list.append(missing, unknown)
}

// --- serialization ---------------------------------------------------------

/// Renders messages as the role-tagged transcript a summary request
/// carries, oldest first, wrapped in a `<conversation>` element.
///
/// pi's serialization, with pi's reasoning: the summarizer is *not*
/// sent the live conversation as messages. It is sent one user message
/// containing text, so nothing in a transcript can be mistaken for a
/// turn addressed to the model, no tool call in it can be answered, and
/// the request needs no tool array. Tool results are truncated at
/// `tool_result_limit`; a cut is announced rather than silent.
///
/// ## Examples
///
/// ```gleam
/// // summary.serialize([summary_test_user])
/// // -> "<conversation>\n[User]: hello\n</conversation>"
/// ```
///
pub fn serialize(messages: List(AgentMessage)) -> String {
  let body =
    messages
    |> list.map(serialize_message)
    |> list.filter(fn(line) { line != "" })
    |> string.join("\n\n")
  "<conversation>\n" <> body <> "\n</conversation>"
}

fn serialize_message(message: AgentMessage) -> String {
  case message {
    message.UserMessage(content:, ..) ->
      tagged("[User]", string.join(list.map(content, user_block), "\n"))
    message.AssistantMessage(content:, stop_reason:, ..) ->
      tagged(
        "[Assistant]",
        string.join(
          list.append(
            list.map(content, assistant_block),
            stop_note(stop_reason),
          ),
          "\n",
        ),
      )
    message.ToolResultMessage(tool_name:, content:, is_error:, ..) -> {
      let label = case is_error {
        True -> "[Tool error: " <> tool_name <> "]"
        False -> "[Tool result: " <> tool_name <> "]"
      }
      tagged(
        label,
        truncate(string.join(list.map(content, tool_result_block), "\n")),
      )
    }
    message.CustomMessage(schema:, payload:) ->
      tagged("[Custom: " <> schema <> "]", json.to_string(payload))
  }
}

// A truncated turn is one whose output limit was hit: the summarizer
// should know the thought was cut off rather than concluded.
fn stop_note(stop_reason: message.StopReason) -> List(String) {
  case stop_reason {
    message.Length -> ["(cut off at the output limit)"]
    _ -> []
  }
}

fn tagged(label: String, text: String) -> String {
  case string.trim(text) {
    "" -> ""
    trimmed -> label <> ": " <> trimmed
  }
}

fn user_block(block: message.UserBlock) -> String {
  case block {
    message.UserText(text:, ..) -> text
    message.UserImage(mime_type:, ..) -> "(image: " <> mime_type <> ")"
  }
}

fn assistant_block(block: message.AssistantBlock) -> String {
  case block {
    message.AssistantText(text:, ..) -> text

    // Thinking is not carried: it is the least durable part of a turn
    // (providers redact it, signatures are opaque) and the decisions
    // worth keeping are the ones that reached the text or the calls.
    message.AssistantThinking(..) -> ""
    message.AssistantToolCall(call:) ->
      "(calls "
      <> call.name
      <> " with "
      <> truncate(json.to_string(call.arguments))
      <> ")"
  }
}

fn tool_result_block(block: message.ToolResultBlock) -> String {
  case block {
    message.ToolResultText(text:, ..) -> text
    message.ToolResultImage(mime_type:, ..) -> "(image: " <> mime_type <> ")"
  }
}

fn truncate(text: String) -> String {
  case string.length(text) > tool_result_limit {
    False -> text
    True ->
      string.slice(text, at_index: 0, length: tool_result_limit)
      <> "\n… (truncated for summarization; the full output is in the "
      <> "conversation tree)"
  }
}
