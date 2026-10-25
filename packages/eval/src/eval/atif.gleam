//// Turns one finished session into an ATIF-v1.7 trajectory, the interchange
//// format Harbor's tooling reads.
////
//// A trial leaves its evidence in the session database: a tree of
//// conversation entries and an append-only usage ledger. Nothing outside
//// Loom can read that, and an evaluation that cannot be inspected by other
//// tools is an assertion rather than a measurement. ATIF is the narrow
//// format that fixes this: a flat, 1-based list of steps, each sourced from
//// the system, the user or the agent, where an agent step carries the tool
//// calls it made and the observations those calls returned.
////
//// ## Flow
////
//// `from_session_db` copies and reads a database, `from_entries` is the pure
//// walk over what it read, `with_system_prompt` lets the caller add the one
//// step the store does not hold, and `to_json` and `write` put the result on
//// disk. The walk happens in three moves, all inside `from_entries`.
////
//// 1. Every message entry becomes either a step (user text, an assistant
////    answer) or a tool result waiting for an owner. Compactions, branch
////    summaries and custom entries are not conversation and are skipped.
//// 2. A tool result is joined to the agent step that issued the call by the
////    provider's call id, and attached to that step's observation. Ids are
////    only unique within one assistant message, so the owner is the most
////    recent step that issued the id before the result arrived. A result
////    whose call was never seen has no step to belong to and is dropped.
//// 3. Usage rows tied to an assistant entry become that step's metrics; the
////    sum of every row, including adjustments and tool costs, becomes the
////    trajectory's final metrics.
////
//// `from_session_db` is the impure edge. It never opens the session's
//// own file: opening takes the writer lease, and a reader that stole or
//// held it would change what it is reading. It copies the database (and its
//// write-ahead log) to a sibling file, reads the copy, and deletes it.
////
//// ## What is deliberately not exported
////
//// Thinking blocks never leave the session. They are opaque, signed by the
//// provider for replay, and neither readable nor safe to publish, so an
//// exported trajectory contains the visible answer and nothing of the
//// reasoning behind it. Text that does reach the file passes through
//// `scrub`, which redacts vendor-prefixed credentials by their prefix, the
//// rule the replay lane uses, and not by the shape of a long alphanumeric
//// run: that rule would also mangle commit hashes and test names, which a
//// trajectory is full of.

import client/internal/ffi_os
import core/clock
import core/entry.{type Entry, type UsageRow, MessageEntry}
import core/ids.{type EntryId}
import core/json.{type JsonValue}
import core/message.{
  type AgentMessage, type AssistantBlock, type ToolCall, type ToolResultBlock,
  type Usage, type UserBlock, AssistantMessage, AssistantText, AssistantThinking,
  AssistantToolCall, ToolResultImage, ToolResultMessage, ToolResultText,
  UserImage, UserMessage, UserText,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import storage/sqlite
import storage/storage

/// The ATIF revision this module writes.
pub const schema_version = "ATIF-v1.7"

/// The agent name every exported trajectory carries.
pub const agent_name = "loom"

/// The agent version every exported trajectory carries. The session database
/// does not record which build wrote it, so this names the exporter's own
/// vocabulary rather than guessing a release.
pub const agent_version = "0.1.0"

/// The most entries `from_session_db` reads, the bound the trial runner uses.
pub const max_entries = 8192

/// Whose words a step records.
pub type Source {
  /// The system prompt.
  SystemSource

  /// A user turn.
  UserSource

  /// The model's answer, with any tool calls and their observations.
  AgentSource
}

/// A tool invocation the agent requested.
pub type Call {
  Call(
    /// The provider's call id, which an observation names in `source_call_id`.
    id: String,
    /// The tool's name.
    function_name: String,
    /// The arguments as the model sent them, credentials scrubbed.
    arguments: JsonValue,
  )
}

/// What one tool call returned.
pub type Observed {
  Observed(
    /// The id of the call this answers.
    source_call_id: String,
    /// The result text, with an image shown as a placeholder naming its type.
    content: String,
  )
}

/// Token counts and cost for one step or for the whole run.
pub type Metrics {
  Metrics(
    /// Input tokens: uncached, cache reads and cache writes together.
    prompt_tokens: Int,
    /// Generated tokens.
    completion_tokens: Int,
    /// The part of the prompt served from the provider's cache.
    cached_tokens: Int,
    /// Dollar cost as the provider's pricing model reported it.
    cost_usd: Float,
  )
}

/// One entry of the trajectory.
pub type Step {
  Step(
    /// Position, 1-based and contiguous across the whole trajectory.
    id: Int,
    /// Whose words these are.
    source: Source,
    /// The visible text of the step.
    message: String,
    /// The calls an agent step made, in emission order.
    tool_calls: List(Call),
    /// The results of those calls, in the order they arrived.
    observation: List(Observed),
    /// The cost of producing the step, when the ledger tied a row to it.
    metrics: Option(Metrics),
  )
}

/// A whole exported session.
pub type Trajectory {
  Trajectory(
    /// The model that answered, from the first assistant message.
    model_name: String,
    /// The steps in conversation order.
    steps: List(Step),
    /// The ledger's totals, which can exceed the sum of step metrics because
    /// tool costs and adjustments belong to no step.
    final_metrics: Metrics,
  )
}

/// Walks a session's entries, oldest first, into a trajectory.
///
/// `usage` is the whole ledger: rows tied to an assistant entry become that
/// step's metrics and every row, tied or not, is summed into the totals.
/// `model` names the agent when the entries cannot (an empty session).
///
/// ## Examples
///
/// ```gleam
/// let trajectory = atif.from_entries(entries, usage_rows, "provider/model")
/// assert list.map(trajectory.steps, fn(step) { step.id }) == [1, 2, 3]
/// ```
///
pub fn from_entries(
  entries: List(Entry),
  usage: List(UsageRow),
  model: String,
) -> Trajectory {
  let costs = step_metrics(usage)
  let walked =
    list.fold(entries, Walk([], dict.new(), dict.new(), 1), fn(walk, each) {
      case each {
        MessageEntry(id:, message:, ..) -> consume(walk, id, message, costs)
        entry.CompactionEntry(..)
        | entry.BranchSummaryEntry(..)
        | entry.CustomEntry(..) -> walk
      }
    })

  // Steps were consed newest-first; observations were consed in arrival order, so both are reversed once here.
  let steps =
    walked.steps
    |> list.reverse
    |> list.map(fn(step) {
      let seen = result.unwrap(dict.get(walked.observed, step.id), [])
      Step(..step, observation: list.reverse(seen))
    })

  Trajectory(
    model_name: model,
    steps:,
    final_metrics: total_metrics(list.map(usage, fn(row) { row.usage })),
  )
}

/// Puts a system step in front of a trajectory and renumbers, so ids stay
/// contiguous from 1. The session store does not hold the system prompt (it
/// is built per request), so the caller that has it supplies it here.
///
/// ## Examples
///
/// ```gleam
/// let with_prompt = atif.with_system_prompt(trajectory, "You are an agent.")
/// assert list.first(with_prompt.steps) |> result.map(fn(s) { s.id }) == Ok(1)
/// ```
///
pub fn with_system_prompt(
  trajectory: Trajectory,
  prompt: String,
) -> Trajectory {
  let system =
    Step(
      id: 0,
      source: SystemSource,
      message: scrub(prompt),
      tool_calls: [],
      observation: [],
      metrics: None,
    )

  Trajectory(
    ..trajectory,
    steps: [system, ..trajectory.steps]
      |> list.index_map(fn(step, index) { Step(..step, id: index + 1) }),
  )
}

/// Encodes a trajectory as ATIF-v1.7 JSON. Total: every trajectory encodes.
/// A step with no calls, no observations or no metrics omits those keys, as
/// the format requires for steps that are not agent steps.
///
/// ## Examples
///
/// ```gleam
/// let text = json.to_string(atif.to_json(trajectory))
/// assert string.contains(text, "\"schema_version\":\"ATIF-v1.7\"")
/// ```
///
pub fn to_json(trajectory: Trajectory) -> JsonValue {
  json.Object([
    #("schema_version", json.String(schema_version)),
    #(
      "agent",
      json.Object([
        #("name", json.String(agent_name)),
        #("version", json.String(agent_version)),
        #("model_name", json.String(trajectory.model_name)),
      ]),
    ),
    #("steps", json.Array(list.map(trajectory.steps, step_json))),
    #("final_metrics", final_json(trajectory)),
  ])
}

/// Reads a finished session's database and answers its trajectory.
///
/// The file is copied beside the original (never under `/tmp`, which the
/// jail replaces), together with its write-ahead log when one exists, and the
/// copy is opened, scanned and closed before it is deleted. The copy's clock
/// is set past every possible lease expiry, so a lease row that was copied
/// from a live writer reads as expired and is claimed in the copy alone; the
/// original is neither opened nor written.
///
/// ## Examples
///
/// ```gleam
/// // atif.from_session_db("run/session.db") -> Ok(Trajectory(..))
/// ```
///
pub fn from_session_db(path: String) -> Result(Trajectory, String) {
  let copy = path <> ".atif-" <> int.to_string(ffi_os.unique_positive_integer())

  use _ <- result.try(
    simplifile.copy_file(path, copy)
    |> result.map_error(fn(error) {
      "cannot copy " <> path <> ": " <> simplifile.describe_error(error)
    }),
  )

  // The log holds commits the main file has not absorbed yet, so a copy without it would silently lose the newest turns.
  let _copied = simplifile.copy_file(path <> "-wal", copy <> "-wal")
  let read = read_copy(copy)

  remove_copy(copy)
  read
}

/// Writes a trajectory to `path` as ATIF JSON, replacing any file there.
///
/// ## Examples
///
/// ```gleam
/// // atif.write(trajectory, "run/trajectory.json") == Ok(Nil)
/// ```
///
pub fn write(trajectory: Trajectory, path: String) -> Result(Nil, String) {
  simplifile.write(path, json.to_string(to_json(trajectory)) <> "\n")
  |> result.map_error(fn(error) {
    "cannot write " <> path <> ": " <> simplifile.describe_error(error)
  })
}

/// Redacts vendor-prefixed credentials and `Bearer` tokens in text.
///
/// This is the replay lane's rule: a token is redacted when it begins at a
/// standalone occurrence of a known prefix (`sk-`, `xai-`, `ghp_`, `gho_`,
/// `ghs_`, `ghu_`, `github_pat_`, `Bearer `). A prefix inside a longer word
/// is prose, and an ordinary hash has no prefix, so commit ids and test names
/// pass through byte for byte.
///
/// ## Examples
///
/// ```gleam
/// assert atif.scrub("key sk-abc123") == "key <redacted>"
/// assert atif.scrub("commit 3f9a1c2b") == "commit 3f9a1c2b"
/// ```
///
pub fn scrub(text: String) -> String {
  let keyed =
    list.fold(key_prefixes, text, fn(so_far, prefix) {
      redact_after(so_far, prefix, "")
    })

  redact_after(keyed, "Bearer ", "Bearer ")
}

// What the walk has gathered so far.
type Walk {
  Walk(
    // Steps, newest first.
    steps: List(Step),
    // Which step most recently issued each call id.
    owners: Dict(String, Int),
    // Observations per step id, newest first.
    observed: Dict(Int, List(Observed)),
    // The id the next step will take.
    next: Int,
  )
}

/// Folds one conversation message into the walk: a user turn or an answer opens a step, a tool result joins the step that issued its call.
fn consume(
  walk: Walk,
  id: EntryId,
  message: AgentMessage,
  costs: Dict(EntryId, Metrics),
) -> Walk {
  case message {
    UserMessage(content:, ..) ->
      open(walk, UserSource, user_text(content), [], None)

    AssistantMessage(content:, ..) ->
      open(
        walk,
        AgentSource,
        assistant_text(content),
        assistant_calls(content),
        option.from_result(dict.get(costs, id)),
      )

    ToolResultMessage(tool_call_id:, content:, ..) ->
      attach(walk, tool_call_id, result_text(content))

    // A custom message is application data with no ATIF source.
    message.CustomMessage(..) -> walk
  }
}

/// Starts the next step, numbering it and recording which call ids it now owns, so a later result can find its issuer.
fn open(
  walk: Walk,
  source: Source,
  text: String,
  calls: List(Call),
  metrics: Option(Metrics),
) -> Walk {
  let step =
    Step(
      id: walk.next,
      source:,
      message: scrub(text),
      tool_calls: calls,
      observation: [],
      metrics:,
    )
  let owners =
    list.fold(calls, walk.owners, fn(held, call) {
      dict.insert(held, call.id, step.id)
    })

  Walk(..walk, steps: [step, ..walk.steps], owners:, next: walk.next + 1)
}

/// Joins a result to the step that issued its call. A result whose call was never seen belongs to no step and is dropped.
fn attach(walk: Walk, call_id: String, content: String) -> Walk {
  // The most recent issuer of the id owns the result; an id nobody issued has no step to join.
  case dict.get(walk.owners, call_id) {
    Ok(owner) -> {
      let held = result.unwrap(dict.get(walk.observed, owner), [])
      let observed =
        dict.insert(walk.observed, owner, [
          Observed(source_call_id: call_id, content: scrub(content)),
          ..held
        ])

      Walk(..walk, observed:)
    }

    Error(Nil) -> walk
  }
}

/// The text of a user turn; an image is named by its media type and never embedded.
fn user_text(blocks: List(UserBlock)) -> String {
  blocks
  |> list.map(fn(block) {
    case block {
      UserText(text:, ..) -> text
      UserImage(mime_type:, ..) -> "[image: " <> mime_type <> "]"
    }
  })
  |> string.join("\n")
}

/// The visible text of an answer. Thinking is dropped here, at the only place answer text is read, so no later change can export it by accident.
fn assistant_text(blocks: List(AssistantBlock)) -> String {
  blocks
  |> list.filter_map(fn(block) {
    case block {
      AssistantText(text:, ..) -> Ok(text)
      AssistantThinking(..) | AssistantToolCall(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

/// The tool calls an answer made, in emission order.
fn assistant_calls(blocks: List(AssistantBlock)) -> List(Call) {
  list.filter_map(blocks, fn(block) {
    case block {
      AssistantToolCall(call:) -> Ok(exported_call(call))
      AssistantText(..) | AssistantThinking(..) -> Error(Nil)
    }
  })
}

/// A tool call as ATIF records it, with credentials scrubbed from its arguments.
fn exported_call(call: ToolCall) -> Call {
  Call(
    id: call.id,
    function_name: call.name,
    arguments: scrub_json(call.arguments),
  )
}

/// A tool result's text; an image is named by its media type and never embedded.
fn result_text(blocks: List(ToolResultBlock)) -> String {
  blocks
  |> list.map(fn(block) {
    case block {
      ToolResultText(text:, ..) -> text
      ToolResultImage(mime_type:, ..) -> "[image: " <> mime_type <> "]"
    }
  })
  |> string.join("\n")
}

/// Scrubs every string value in a JSON document and leaves its shape alone.
fn scrub_json(value: JsonValue) -> JsonValue {
  case value {
    json.String(text) -> json.String(scrub(text))
    json.Array(items) -> json.Array(list.map(items, scrub_json))
    json.Object(fields) ->
      json.Object(
        list.map(fields, fn(field) { #(field.0, scrub_json(field.1)) }),
      )
    json.Int(..) | json.Float(..) | json.Bool(..) | json.Null -> value
  }
}

/// The ledger rows tied to an entry, summed per entry. An adjustment reconciles the run and is not the cost of a step, so it is left out.
fn step_metrics(rows: List(UsageRow)) -> Dict(EntryId, Metrics) {
  list.fold(rows, dict.new(), fn(seen, row) {
    // Only a non-adjustment row tied to an entry is a step cost; every other row counts in the totals alone.
    case row.entry_id, row.adjustment {
      Some(id), False -> {
        let one = metrics_of(row.usage)
        let sum =
          dict.get(seen, id)
          |> result.map(add(_, one))
          |> result.unwrap(one)

        dict.insert(seen, id, sum)
      }

      _, _ -> seen
    }
  })
}

fn total_metrics(usages: List(Usage)) -> Metrics {
  list.fold(usages, zero(), fn(total, usage) { add(total, metrics_of(usage)) })
}

/// One usage observation as ATIF metrics: the prompt side counts uncached input and both cache buckets.
fn metrics_of(usage: Usage) -> Metrics {
  Metrics(
    prompt_tokens: usage.input + usage.cache_read + usage.cache_write,
    completion_tokens: usage.output,
    cached_tokens: usage.cache_read,
    cost_usd: usage.cost.total,
  )
}

fn zero() -> Metrics {
  Metrics(0, 0, 0, 0.0)
}

/// Adds two metrics field by field.
fn add(left: Metrics, right: Metrics) -> Metrics {
  Metrics(
    prompt_tokens: left.prompt_tokens + right.prompt_tokens,
    completion_tokens: left.completion_tokens + right.completion_tokens,
    cached_tokens: left.cached_tokens + right.cached_tokens,
    cost_usd: left.cost_usd +. right.cost_usd,
  )
}

/// Encodes one step, omitting the keys a step has nothing to put in.
fn step_json(step: Step) -> JsonValue {
  // ATIF spells the three sources in lowercase.
  let source = case step.source {
    SystemSource -> "system"
    UserSource -> "user"
    AgentSource -> "agent"
  }

  json.Object(
    list.flatten([
      [
        #("step_id", json.Int(step.id)),
        #("source", json.String(source)),
        #("message", json.String(step.message)),
      ],
      calls_json(step.tool_calls),
      observation_json(step.observation),
      metrics_json(step.metrics),
    ]),
  )
}

/// The `tool_calls` key of a step, or nothing when it made none.
fn calls_json(calls: List(Call)) -> List(#(String, JsonValue)) {
  case calls {
    [] -> []
    _some -> [
      #(
        "tool_calls",
        json.Array(
          list.map(calls, fn(call) {
            json.Object([
              #("tool_call_id", json.String(call.id)),
              #("function_name", json.String(call.function_name)),
              #("arguments", call.arguments),
            ])
          }),
        ),
      ),
    ]
  }
}

/// The `observation` key of a step, or nothing when no result joined it.
fn observation_json(seen: List(Observed)) -> List(#(String, JsonValue)) {
  case seen {
    [] -> []
    _some -> [
      #(
        "observation",
        json.Object([
          #(
            "results",
            json.Array(
              list.map(seen, fn(each) {
                json.Object([
                  #("source_call_id", json.String(each.source_call_id)),
                  #("content", json.String(each.content)),
                ])
              }),
            ),
          ),
        ]),
      ),
    ]
  }
}

/// The `metrics` key of a step, or nothing when the ledger tied no row to it.
fn metrics_json(metrics: Option(Metrics)) -> List(#(String, JsonValue)) {
  case metrics {
    None -> []
    Some(each) -> [
      #(
        "metrics",
        json.Object([
          #("prompt_tokens", json.Int(each.prompt_tokens)),
          #("completion_tokens", json.Int(each.completion_tokens)),
          #("cached_tokens", json.Int(each.cached_tokens)),
          #("cost_usd", json.Float(each.cost_usd)),
        ]),
      ),
    ]
  }
}

/// The trajectory's totals, with the step count taken from the steps themselves.
fn final_json(trajectory: Trajectory) -> JsonValue {
  let total = trajectory.final_metrics

  json.Object([
    #("total_prompt_tokens", json.Int(total.prompt_tokens)),
    #("total_completion_tokens", json.Int(total.completion_tokens)),
    #("total_cached_tokens", json.Int(total.cached_tokens)),
    #("total_cost_usd", json.Float(total.cost_usd)),
    #("total_steps", json.Int(list.length(trajectory.steps))),
  ])
}

/// Opens the copy, reads entries and ledger, and closes it again. The clock sits past any lease a live writer could have taken, so the copy opens.
fn read_copy(copy: String) -> Result(Trajectory, String) {
  let beyond_any_lease = clock.fixed(at: 4_000_000_000_000_000)

  use store <- result.try(
    sqlite.open(sqlite.config(path: copy, owner: "eval-atif"), beyond_any_lease)
    |> result.map_error(fn(_) { "the session database could not be opened" }),
  )
  let scanned = scan(store)
  let _closed = storage.close(store)

  use #(entries, usage) <- result.map(scanned)

  from_entries(entries, usage, first_model(entries))
}

/// Reads every entry and every ledger row of an open store.
fn scan(store) -> Result(#(List(Entry), List(UsageRow)), String) {
  use entries <- result.try(
    storage.scan_entries(
      store,
      storage.entry_scan() |> storage.entry_limit(max_entries),
    )
    |> result.replace_error("the session's entries could not be read"),
  )
  use usage <- result.map(
    storage.scan_usage(store, storage.usage_scan())
    |> result.replace_error("the session's usage ledger could not be read"),
  )

  #(entries, usage)
}

/// The model named by the first assistant answer, or empty for a session that has none.
fn first_model(entries: List(Entry)) -> String {
  entries
  |> list.find_map(fn(each) {
    case each {
      MessageEntry(message: AssistantMessage(model:, ..), ..) -> Ok(model)
      _ -> Error(Nil)
    }
  })
  |> result.unwrap("")
}

// Deletes the copy and its siblings. A leftover is only disk, never evidence.
fn remove_copy(copy: String) -> Nil {
  list.each([copy, copy <> "-wal", copy <> "-shm"], fn(path) {
    let _ = simplifile.delete(path)
    Nil
  })
}

const redacted_marker = "<redacted>"

const key_prefixes = [
  "sk-", "xai-", "ghp_", "gho_", "ghs_", "ghu_", "github_pat_",
]

/// Redacts the token that begins at each standalone occurrence of `prefix`, writing `keep` before the marker. An occurrence inside a longer word, or followed by nothing, is prose and stays.
fn redact_after(text: String, prefix: String, keep: String) -> String {
  case string.split(text, prefix) {
    [] -> text
    [first, ..rest] ->
      list.fold(rest, first, fn(kept, part) {
        let #(token, remainder) = split_token(part, "")

        // A prefix glued to the end of a longer word, or with no token after it, is prose and stays as written.
        case token_character(string.slice(kept, -1, 1)) || token == "" {
          True -> kept <> prefix <> part
          False -> kept <> keep <> redacted_marker <> remainder
        }
      })
  }
}

/// Splits the longest run of credential characters off the front of `text`.
fn split_token(text: String, token: String) -> #(String, String) {
  case string.pop_grapheme(text) {
    Ok(#(char, rest)) ->
      case token_character(char) {
        True -> split_token(rest, token <> char)
        False -> #(token, text)
      }

    Error(Nil) -> #(token, "")
  }
}

/// Whether a grapheme can be part of a credential token: a letter, a digit, `-`, `_` or `.`.
fn token_character(char: String) -> Bool {
  char != ""
  && {
    string.lowercase(char) != string.uppercase(char)
    || string.contains("0123456789-_.", char)
  }
}
