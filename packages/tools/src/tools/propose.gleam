//// The `propose` tool: the model's way of suggesting a standing rule
//// without being able to make one.
////
//// ## Flow
////
//// `tool` → `run` → `submission` → `refusal_outcome`
////
//// 1. `tool` builds the definition over the host's `Proposals` seam.
//// 2. `run` decodes the arguments and refuses what no host could accept:
////    a new rule over the byte cap, an empty rationale, an entry id that
////    does not parse, a control character other than newline and tab, and
////    text that names the prompt's `<instructions` fence (`closes_fence`).
//// 3. `submission` is the value the seam receives. It carries no path and no
////    kind, because the model has no say in either.
//// 4. The seam validates against the rules file, queues the proposal and
////    answers its id; `run` replies `queued as <id>` and nothing more.
//// 5. A seam `Refusal` becomes the in-band answer through `refusal_outcome`.
////
//// ## A suggestion, not a request
////
//// A rule that reaches a later session's system prompt is the strongest
//// influence a model can have over its successors, so this door only files a
//// suggestion. The call never blocks, never raises an approval or an
//// escalation, and never writes a file. It stores a pending proposal in the
//// domain's durable queue and returns. A human reads the proposal later and
//// decides, through the owner's session commands, and only that decision
//// writes anything (`docs/architecture/approvals.md`, "Proposals are not
//// approvals").
////
//// The model never names a target. The host owns one file, the rules file
//// beside the domain's memory store, and the argument schema has no field
//// that could carry a path. That is why there is nothing here to validate
//// about one.
////
//// ## A seam of closures, like `remember`
////
//// `tools` cannot reach a session, so the durable side is a closure the host
//// fills in (`client/proposals.seam`). Every bound that needs the store or
//// the file (the queue's depth, whether `old` matches the file once) is
//// enforced on that side. The bounds that depend on the arguments alone are
//// checked here, from constants the host imports, so the description and the
//// check cannot disagree.
////
//// `replay: Never`, because a replayed call would queue the same suggestion
//// twice, and `execution_mode: Exclusive`, because a submission takes the
//// memory store's writer lease, so two calls in one batch would contend for it
//// and one would be refused in band for no reason the model could act on.

import broker/policy.{type SandboxPolicy}
import core/ids
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import tools/tool.{type Tool, type ToolOutcome}

/// The tool's name, as a constant because the host gates registration on the
/// session having a store to queue into.
pub const tool_name = "propose"

/// The most bytes `new` may carry. Two KiB is a few short paragraphs: a rule
/// is a standing instruction, not a document.
pub const max_new_bytes = 2048

/// The most bytes `old` may carry. It only has to name a place in the rules
/// file, and the file itself is capped, so this is the same order of size as
/// `new`.
pub const max_old_bytes = 4096

/// The most bytes `rationale` may carry. It is the reviewer's evidence, not
/// the rule.
pub const max_rationale_bytes = 1024

/// How many proposals may wait for a decision at once. The host refuses the
/// next one in band with `QueueFull`, so a model that proposes in a loop
/// fills a bounded queue and then learns it is full.
pub const max_pending = 64

/// What the model asked to propose. The host fills in everything else: the
/// proposal's id, its kind, its target, the digest of the file it was judged
/// against, the session and the time.
///
/// Constructor invariants: `new` is non-empty after trimming and at most
/// `max_new_bytes`; `old` is at most `max_old_bytes` and empty means append;
/// `rationale` is non-empty after trimming and at most `max_rationale_bytes`;
/// `source_entry` is the canonical text of an entry id when present.
pub type Submission {
  Submission(
    old: String,
    new: String,
    rationale: String,
    source_entry: Option(String),
  )
}

/// Why the host did not queue a proposal.
pub type Refusal {
  /// The proposal cannot apply to the rules file as it stands: `old` is not
  /// there, matches more than once, or the edit would overfill the file.
  Invalid(reason: String)

  /// `max_pending` proposals already wait for a decision.
  QueueFull(limit: Int)

  /// Another writer holds the domain's memory store: a `remember` call or a
  /// decision in another session. Nothing is lost by proposing again.
  Busy(reason: String)

  /// The store could not be read or written.
  Unavailable(reason: String)
}

/// The proposal seam: everything the tool may ask of the host.
///
/// Constructor invariants: `submit` is total, returning a `Refusal` rather
/// than crashing. On success it has durably stored a pending proposal and
/// returns its id, and it has written nothing else. It never blocks on a
/// person.
pub type Proposals {
  Proposals(submit: fn(Submission) -> Result(String, Refusal))
}

/// The `propose` tool over one seam.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry([bash.tool(), propose.tool(seam)])
/// ```
///
pub fn tool(proposals: Proposals) -> Tool {
  tool.Tool(
    name: tool_name,
    description: "Suggest a standing rule for this repository's later "
      <> "sessions. The suggestion is queued and returns immediately; you "
      <> "are never asked to wait. A person reads it later and approves or "
      <> "rejects it, and only an approval writes anything. An approved rule "
      <> "reaches new sessions in the system prompt, after the operator's "
      <> "own instructions. Use it for a lesson that should bind future "
      <> "work, not for a note: `remember` is for notes. `old` is text "
      <> "already in the rules to replace, which must match exactly once; "
      <> "leave `old` out to append `new` as a new rule. `new` is capped at "
      <> int.to_string(max_new_bytes)
      <> " bytes and the queue holds "
      <> int.to_string(max_pending)
      <> " pending suggestions.",
    prompt_snippet: Some(
      "`propose` queues a suggested standing rule for a person to approve; "
      <> "it never changes anything itself.",
    ),
    schema: tool.object_schema(
      [
        #(
          "old",
          tool.string_property(
            "existing rule text to replace, matching exactly once; leave it "
            <> "out to append a new rule",
          ),
        ),
        #(
          "new",
          tool.string_property(
            "the rule text, at most "
            <> int.to_string(max_new_bytes)
            <> " bytes",
          ),
        ),
        #(
          "rationale",
          tool.string_property(
            "why this should bind future sessions, for the reviewer",
          ),
        ),
        #(
          "source_entry",
          tool.string_property(
            "optional id of the conversation entry that prompted this, so "
            <> "the reviewer can see the words",
          ),
        ),
      ],
      ["new", "rationale"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(_ctx, args) { run(proposals, args) },
  )
}

fn run(proposals: Proposals, args: JsonValue) -> ToolOutcome {
  use submitted <- tool.with_arg(submission(args))
  use id <- tool.or_outcome(proposals.submit(submitted), refusal_outcome)
  tool.success("queued as " <> id)
  |> tool.with_details(json.Object([#("id", json.String(id))]))
}

/// Decodes and bounds the arguments, with the reason a bad one is refused.
///
/// ## Examples
///
/// ```gleam
/// assert propose.submission(args_with_empty_new) == Error("`new` is empty")
/// ```
///
pub fn submission(args: JsonValue) -> Result(Submission, String) {
  use old <- result.try(
    tool.optional_string(args, "old") |> result.map(option.unwrap(_, "")),
  )
  use new <- result.try(tool.required_string(args, "new"))
  use rationale <- result.try(tool.required_string(args, "rationale"))
  use source <- result.try(tool.optional_string(args, "source_entry"))
  use <- bool.guard(string.trim(new) == "", Error("`new` is empty"))
  use <- bool.guard(string.trim(rationale) == "", Error("`rationale` is empty"))
  use <- bool.guard(
    bytes(new) > max_new_bytes,
    Error(too_long("new", max_new_bytes)),
  )
  use <- bool.guard(
    bytes(old) > max_old_bytes,
    Error(too_long("old", max_old_bytes)),
  )
  use <- bool.guard(
    bytes(rationale) > max_rationale_bytes,
    Error(too_long("rationale", max_rationale_bytes)),
  )
  use Nil <- result.try(clean("new", new))
  use Nil <- result.try(clean("old", old))
  use Nil <- result.try(clean("rationale", rationale))
  use source_entry <- result.try(case source {
    option.None -> Ok(option.None)
    Some(text) ->
      ids.parse_entry_id(text)
      |> result.map(fn(_id) { Some(text) })
      |> result.replace_error("`source_entry` is not an entry id")
  })
  Ok(Submission(old:, new:, rationale:, source_entry:))
}

// A field is clean when it holds no control character a rule could not need
// and does not name the prompt's fence. Control characters serve no purpose
// in a rule, and each inflates to six bytes when a cell is JSON-escaped, which
// is how a bounded field becomes an oversized stored row.
fn clean(field: String, text: String) -> Result(Nil, String) {
  case first_control(text), closes_fence(text) {
    Some(code), _ ->
      Error(
        "`"
        <> field
        <> "` contains a control character (code "
        <> int.to_string(code)
        <> "); remove it. Only newline and tab are allowed",
      )
    option.None, True ->
      Error(
        "`"
        <> field
        <> "` contains the text `<instructions` or `</instructions`; remove "
        <> "it, because that text delimits the system prompt's rule files",
      )
    option.None, False -> Ok(Nil)
  }
}

fn first_control(text: String) -> Option(Int) {
  string.to_utf_codepoints(text)
  |> list.map(string.utf_codepoint_to_int)
  |> list.find(is_forbidden_control)
  |> option.from_result
}

fn is_forbidden_control(code: Int) -> Bool {
  { code < 32 && code != 10 && code != 9 } || code == 127
}

/// Whether `text` could open or close the prompt's `<instructions` fence.
///
/// The system prompt wraps each guidance file in `<instructions ...>` and
/// `</instructions>`, and an approved rule is carried inside one. Text that
/// names either tag could end its own fence and speak outside it, so a
/// proposal naming one is refused when it is filed, and again when it would
/// be applied. The comparison lowercases the text and keeps only the
/// characters that can spell a tag, the letters `a` to `z`, `<` and `/`, so
/// every separator is ignored whatever it is: a space, a newline, a zero-width
/// space, a byte order mark, a soft hyphen. Ordinary prose that mentions
/// "instructions" is not refused, because the kept string must hold a `<`
/// directly before the word.
///
/// ## Examples
///
/// ```gleam
/// assert propose.closes_fence("end </Instructions> now")
/// assert propose.closes_fence("< / instructions")
/// assert propose.closes_fence("</\u{200B}instructions>")
/// assert !propose.closes_fence("follow the instructions")
/// ```
///
pub fn closes_fence(text: String) -> Bool {
  let spelled =
    text
    |> string.lowercase
    |> string.to_utf_codepoints
    |> list.filter(fn(point) {
      can_spell_tag(string.utf_codepoint_to_int(point))
    })
    |> string.from_utf_codepoints
  string.contains(spelled, "<instructions")
  || string.contains(spelled, "</instructions")
}

// The codepoints that can appear in `<instructions` or `</instructions`:
// the lowercase ASCII letters, `<` and `/`. Everything else is a separator as
// far as the fence is concerned.
fn can_spell_tag(code: Int) -> Bool {
  { code >= 97 && code <= 122 } || code == 60 || code == 47
}

fn bytes(text: String) -> Int {
  bit_array.byte_size(<<text:utf8>>)
}

fn too_long(field: String, limit: Int) -> String {
  "`" <> field <> "` is longer than " <> int.to_string(limit) <> " bytes"
}

/// Renders a seam refusal as the in-band failure the model reads.
///
/// ## Examples
///
/// ```gleam
/// // propose.refusal_outcome(propose.QueueFull(limit: 64)).is_error
/// ```
///
pub fn refusal_outcome(refusal: Refusal) -> ToolOutcome {
  tool.failure(describe(refusal))
  |> tool.with_details(
    json.Object([
      #("error", json.String(code(refusal))),
      #("reason", json.String(describe(refusal))),
    ]),
  )
}

fn code(refusal: Refusal) -> String {
  case refusal {
    Invalid(..) -> "proposal_invalid"
    QueueFull(..) -> "proposal_queue_full"
    Busy(..) -> "proposal_busy"
    Unavailable(..) -> "proposal_unavailable"
  }
}

fn describe(refusal: Refusal) -> String {
  case refusal {
    Invalid(reason:) -> "that proposal cannot apply: " <> reason
    QueueFull(limit:) ->
      "the proposal queue already holds "
      <> int.to_string(limit)
      <> " suggestions waiting for a decision. Carry on; a person will "
      <> "clear some"
    Busy(reason:) ->
      "the proposal queue is in use right now ("
      <> reason
      <> "). Nothing is lost; propose it again later, or carry on without it"
    Unavailable(reason:) ->
      "the proposal could not be queued: " <> reason <> ". Carry on without it"
  }
}

// The tool asks the broker for nothing: it touches no path and starts no
// process, and the host reads the rules file itself.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}
