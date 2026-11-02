//// The project tools: the router's `route`, `project_read` and `reply`, and a
//// worker's `project_report` and `project_handback`
//// (`docs/design-notes/project-mode.md`, sections 4 and 6).
////
//// This module owns the schemas and the wording the model reads, and nothing
//// else. Every effect belongs to the host, which hands in a `Projects` seam of
//// closures in the manner of `tools/schedule`: `tools` may not depend on
//// `client`, and the project actor lives there. `client/projectseam` fills
//// the seam.
////
//// ## Why the arguments are typed here
////
//// A routing decision carries references and no text a worker will read. The
//// decoder therefore builds `project/model` values directly: a trigger id, a
//// ticket id, a capped title. Free text appears in three places only, a
//// ticket title (capped by `model.title`), a reply (capped in words), and a
//// worker's report question (capped in characters). Strength never appears,
//// because the gate sets it, and no argument names a branch or a destination,
//// because the host derives both.
////
//// ## What each call refuses
////
//// `route` takes one to twenty items and refuses the whole call only when its
//// shape is wrong. A well-formed item the engine declines comes back as that
//// item's own refusal, so one bad item does not cost the rest of the batch.
//// `project_read` serves a fixed set of resources, each a ledger record or a
//// card, and takes no path. `reply` records an outbox row and names a trigger
//// as its subject; the host resolves where it goes.

import broker/policy.{type SandboxPolicy}
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/model
import tools/tool.{type Ctx, type Tool, type ToolOutcome}

/// The router's decision tool.
pub const route_tool_name = "route"

/// The router's read tool.
pub const read_tool_name = "project_read"

/// The router's outbox tool.
pub const reply_tool_name = "reply"

/// A worker's status tool.
pub const report_tool_name = "project_report"

/// A worker's hand-back tool.
pub const handback_tool_name = "project_handback"

/// The most items one `route` call takes.
pub const max_route_items = 20

/// The most words a reply holds.
pub const max_reply_words = 100

/// The most characters a worker's question or hand-back reason holds.
pub const max_note_chars = 500

/// The router's tools, in the order the prompt lists them. This list is the
/// router's tool ceiling: nothing outside it may be activated on a router
/// session.
///
/// ## Examples
///
/// ```gleam
/// assert project.router_tool_names == ["route", "project_read", "reply"]
/// ```
pub const router_tool_names = [route_tool_name, read_tool_name, reply_tool_name]

/// A worker's project tools.
///
/// ## Examples
///
/// ```gleam
/// assert project.worker_tool_names
///   == ["project_report", "project_handback"]
/// ```
pub const worker_tool_names = [report_tool_name, handback_tool_name]

/// What one routing item asks for.
pub type Action {
  /// Open a ticket with a capped title.
  Accept(
    /// The title, capped by `model.title`.
    title: model.TicketTitle,
  )

  /// Add the trigger to an open ticket.
  Attach(
    /// The open ticket.
    ticket: model.TicketId,
  )

  /// Reopen an ended ticket with the trigger.
  Resume(
    /// The ended ticket.
    ticket: model.TicketId,
  )

  /// Stop a ticket on a person's explicit message.
  Stop(
    /// The ticket to stop.
    ticket: model.TicketId,
  )

  /// Decline the candidate.
  Ignore
}

/// One decoded routing item.
pub type Item {
  Item(
    /// The candidate being routed.
    trigger: model.TriggerId,
    /// What to do with it.
    action: Action,
    /// Triggers the worker should hold the work for.
    holds: List(model.TriggerId),
    /// Other tickets this one relates to.
    related: List(#(model.TicketId, model.Relation)),
    /// An earlier trigger that handed the work back.
    prior_hand_back: Option(model.TriggerId),
  )
}

/// What the host did with one item.
pub type ItemOutcome {
  /// The engine applied the item.
  Applied

  /// The engine or the host declined the item, with a reason worded for the
  /// model.
  Declined(
    /// Why.
    reason: String,
  )
}

/// A resource `project_read` can serve. Each is a ledger record or a card;
/// none is a transcript or a file.
pub type Resource {
  /// The candidates offered to the router now.
  Candidates

  /// One page of tickets, newest first.
  Board(
    /// The zero-based page.
    page: Int,
  )

  /// One ticket's card.
  TicketCard(
    /// The ticket.
    ticket: model.TicketId,
  )

  /// One trigger's record.
  TriggerCard(
    /// The trigger.
    trigger: model.TriggerId,
  )

  /// One thread's entries.
  ThreadCard(
    /// The thread.
    thread: model.ThreadId,
  )
}

/// What a reply is for. The purpose sets the host's cap and wording.
pub type Purpose {
  /// Tell the sender their request was taken.
  Acknowledge

  /// Ask the sender a question.
  Clarify

  /// Tell the sender why nothing will happen.
  Decline
}

/// One decoded reply.
pub type Reply {
  Reply(
    /// The trigger whose thread the reply belongs to.
    subject: model.TriggerId,
    /// What it is for.
    purpose: Purpose,
    /// The text, at most `max_reply_words` words.
    text: String,
  )
}

/// A worker's status report as the tool decoded it.
pub type WorkerReport {
  WorkerReport(
    /// The closed-set status.
    status: Status,
    /// A question for a person, when the status is `Waiting`.
    question: Option(String),
  )
}

/// The statuses a worker can report. There is no ready: the host's check
/// decides readiness.
pub type Status {
  /// The worker is working.
  Progress

  /// The worker is idle and may have a question.
  Waiting

  /// The worker cannot continue without help.
  Blocked

  /// The worker's attempt failed.
  Failed

  /// The worker found the ticket unworkable.
  Dropped
}

/// A worker's hand-back of an input that does not belong to its ticket.
pub type Handback {
  Handback(
    /// The input being handed back.
    trigger: model.TriggerId,
    /// Why, capped.
    reason: String,
  )
}

/// Why the host declined a whole call.
pub type Refusal {
  /// The caller is not the session this tool serves.
  NotPermitted(reason: String)

  /// The named record does not exist.
  NotFound(reason: String)

  /// The project could not be reached or its ledger failed.
  Unavailable(reason: String)
}

/// The host's half of the project tools. Every function is total and returns a
/// `Refusal`; none crashes. The seam owns the project, the session's standing
/// and the ledger, and these tools know none of them.
pub type Projects {
  Projects(
    /// Applies a batch of routing items and reports each one's outcome in
    /// order.
    route: fn(Ctx, List(Item)) -> Result(List(ItemOutcome), Refusal),
    /// Serves a resource as one JSON document.
    read: fn(Ctx, Resource) -> Result(JsonValue, Refusal),
    /// Records an outbox row for a reply.
    reply: fn(Ctx, Reply) -> Result(Nil, Refusal),
    /// Records a worker's report.
    report: fn(Ctx, WorkerReport) -> Result(Nil, Refusal),
    /// Records a worker's hand-back.
    handback: fn(Ctx, Handback) -> Result(Nil, Refusal),
  )
}

/// The router's three tools over one seam.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry(list.append(base, project.router_tools(seam)))
/// ```
pub fn router_tools(seam: Projects) -> List(Tool) {
  [route_tool(seam.route), read_tool(seam.read), reply_tool(seam.reply)]
}

/// A worker's two tools over one seam.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry(list.append(base, project.worker_tools(seam)))
/// ```
pub fn worker_tools(seam: Projects) -> List(Tool) {
  [report_tool(seam.report), handback_tool(seam.handback)]
}

// --- route -------------------------------------------------------------------

/// The router's `route` tool. It runs `Exclusive` and is never replayed,
/// because applying a routing decision changes the ledger.
fn route_tool(
  route: fn(Ctx, List(Item)) -> Result(List(ItemOutcome), Refusal),
) -> Tool {
  tool.Tool(
    name: route_tool_name,
    description: "Route the candidates you were shown. Give one to "
      <> int.to_string(max_route_items)
      <> " items in a single call, each naming a candidate `trigger` and one "
      <> "`action`: `accept` opens a ticket (give a short `title`), `attach` "
      <> "adds the candidate to an open `ticket`, `resume` reopens an ended "
      <> "`ticket` with it, `stop` stops a `ticket` on a person's explicit "
      <> "message, and `ignore` declines it. Each item is judged alone, so a "
      <> "refused item does not undo the others, and the result says which "
      <> "were applied. You write no instructions for the worker: it reads "
      <> "the original request itself. To say that work should wait for "
      <> "another message, name it in `holds`; to relate the work to other "
      <> "tickets, use `related`. Whether work is authorized is not your "
      <> "decision, and the host refuses what the gate did not admit.",
    prompt_snippet: Some(
      "`route` decides what each candidate becomes: accept, attach, resume, "
      <> "stop or ignore.",
    ),
    schema: tool.object_schema(
      [
        #(
          "items",
          json.Object([
            #("type", json.String("array")),
            #(
              "description",
              json.String(
                "one to "
                <> int.to_string(max_route_items)
                <> " routing decisions",
              ),
            ),
            #("minItems", json.Int(1)),
            #("maxItems", json.Int(max_route_items)),
            #("items", item_schema()),
          ]),
        ),
      ],
      ["items"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_route(route, ctx, args) },
  )
}

/// The JSON schema of one routing item. It has no field for text addressed to
/// a worker: the only free text is the capped title, which stays on the board.
fn item_schema() -> JsonValue {
  tool.object_schema(
    [
      #("trigger", tool.string_property("the candidate's id")),
      #(
        "action",
        tool.enum_property(
          ["accept", "attach", "resume", "stop", "ignore"],
          "what to do with the candidate",
        ),
      ),
      #(
        "title",
        tool.string_property(
          "for `accept` only: a short title for the board, at most "
          <> int.to_string(model.max_title_codepoints)
          <> " characters. The worker never sees it",
        ),
      ),
      #(
        "ticket",
        tool.string_property(
          "for `attach`, `resume` and `stop`: the ticket's id",
        ),
      ),
      #(
        "holds",
        tool.string_array_property(
          "ids of messages the work should wait for before it starts",
        ),
      ),
      #(
        "related",
        json.Object([
          #("type", json.String("array")),
          #("description", json.String("other tickets this one is related to")),
          #(
            "items",
            tool.object_schema(
              [
                #("ticket", tool.string_property("the related ticket")),
                #(
                  "relation",
                  tool.enum_property(
                    ["duplicate", "blocks", "follows"],
                    "how this work relates to that ticket",
                  ),
                ),
              ],
              ["ticket", "relation"],
            ),
          ),
        ]),
      ),
      #(
        "prior_hand_back",
        tool.string_property(
          "the id of an earlier message that handed this work back",
        ),
      ),
    ],
    ["trigger", "action"],
  )
}

/// Decodes the items, hands them to the seam and answers one line per item.
/// The structured details carry the same outcomes for a client to read.
fn run_route(
  route: fn(Ctx, List(Item)) -> Result(List(ItemOutcome), Refusal),
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  use items <- tool.with_arg(decode_items(args))
  use outcomes <- tool.or_outcome(route(ctx, items), refusal_outcome)
  let lines =
    list.zip(items, outcomes)
    |> list.map(fn(pair) {
      let #(item, outcome) = pair
      item.trigger.value <> ": " <> outcome_text(outcome)
    })

  tool.success(string.join(lines, "\n"))
  |> tool.with_details(
    json.Object([
      #(
        "items",
        json.Array(
          list.zip(items, outcomes)
          |> list.map(fn(pair) { outcome_json(pair.0, pair.1) }),
        ),
      ),
    ]),
  )
}

fn outcome_text(outcome: ItemOutcome) -> String {
  case outcome {
    Applied -> "applied"
    Declined(reason:) -> "declined, " <> reason
  }
}

/// One item's outcome as structured details. A declined item carries the
/// reason the host gave.
fn outcome_json(item: Item, outcome: ItemOutcome) -> JsonValue {
  let base = [#("trigger", json.String(item.trigger.value))]

  // Both results name the trigger. Only a declined one adds a reason.
  case outcome {
    Applied ->
      json.Object(list.append(base, [#("result", json.String("applied"))]))
    Declined(reason:) ->
      json.Object(
        list.append(base, [
          #("result", json.String("declined")),
          #("reason", json.String(reason)),
        ]),
      )
  }
}

/// Decodes the `items` array into typed routing items. A malformed item
/// refuses the call, because a call the decoder cannot read has no items to
/// judge alone.
fn decode_items(args: JsonValue) -> Result(List(Item), String) {
  use raw <- result.try(tool.optional_value(args, "items"))

  // Anything but an array is refused, whether it is another type or missing.
  case raw {
    Some(json.Array(items)) -> decode_item_list(items)
    Some(_) | None -> Error("`items` must be an array")
  }
}

/// Checks the item count against the one to twenty the tool allows before
/// decoding any item.
fn decode_item_list(items: List(JsonValue)) -> Result(List(Item), String) {
  case list.length(items) {
    0 -> Error("give at least one item")
    count if count > max_route_items ->
      Error(
        "give at most " <> int.to_string(max_route_items) <> " items per call",
      )
    _ -> list.try_map(items, decode_item)
  }
}

/// Decodes one routing item. Its ids are wrapped in their id types here, so
/// nothing past this point handles them as plain strings.
fn decode_item(raw: JsonValue) -> Result(Item, String) {
  use trigger <- result.try(tool.required_string(raw, "trigger"))
  use action_word <- result.try(tool.required_string(raw, "action"))
  use title <- result.try(tool.optional_string(raw, "title"))
  use ticket <- result.try(tool.optional_string(raw, "ticket"))
  use holds <- result.try(tool.optional_string_list(raw, "holds"))
  use hand_back <- result.try(tool.optional_string(raw, "prior_hand_back"))
  use related <- result.try(decode_related(raw))
  use action <- result.try(decode_action(action_word, title, ticket))

  Ok(Item(
    trigger: model.TriggerId(trigger),
    action:,
    holds: list.map(option.unwrap(holds, []), model.TriggerId),
    related:,
    prior_hand_back: option.map(hand_back, model.TriggerId),
  ))
}

/// Matches the action word against the title and ticket the item carries. Each
/// action takes exactly the arguments that mean something for it: an accept
/// has a title and no ticket, the others have a ticket and no title, and an
/// ignore has neither.
fn decode_action(
  word: String,
  title: Option(String),
  ticket: Option(String),
) -> Result(Action, String) {
  case word, title, ticket {
    "accept", Some(text), None -> Ok(Accept(model.title(text)))
    "accept", None, _ -> Error("`accept` needs a `title`")
    "accept", Some(_), Some(_) -> Error("`accept` takes no `ticket`")
    "attach", None, Some(id) -> Ok(Attach(model.TicketId(id)))
    "resume", None, Some(id) -> Ok(Resume(model.TicketId(id)))
    "stop", None, Some(id) -> Ok(Stop(model.TicketId(id)))
    "attach", _, None | "resume", _, None | "stop", _, None ->
      Error("`" <> word <> "` needs a `ticket`")
    "attach", Some(_), Some(_)
    | "resume", Some(_), Some(_)
    | "stop", Some(_), Some(_)
    -> Error("`" <> word <> "` takes no `title`")
    "ignore", None, None -> Ok(Ignore)
    "ignore", _, _ -> Error("`ignore` takes no `title` or `ticket`")
    other, _, _ -> Error("unknown action `" <> other <> "`")
  }
}

/// Decodes the optional `related` list of an item.
fn decode_related(
  raw: JsonValue,
) -> Result(List(#(model.TicketId, model.Relation)), String) {
  use found <- result.try(tool.optional_value(raw, "related"))

  // An absent list and a null both mean no relations.
  case found {
    None | Some(json.Null) -> Ok([])
    Some(json.Array(entries)) -> list.try_map(entries, decode_relation)
    Some(_) -> Error("`related` must be an array")
  }
}

/// Decodes one entry of `related`: a ticket and how the work relates to it.
fn decode_relation(
  entry: JsonValue,
) -> Result(#(model.TicketId, model.Relation), String) {
  use ticket <- result.try(tool.required_string(entry, "ticket"))
  use word <- result.try(tool.required_string(entry, "relation"))

  // The relations are a closed set. An unknown word names itself in the
  // refusal so the model can correct it.
  case word {
    "duplicate" -> Ok(#(model.TicketId(ticket), model.Duplicate))
    "blocks" -> Ok(#(model.TicketId(ticket), model.Blocks))
    "follows" -> Ok(#(model.TicketId(ticket), model.Follows))
    other -> Error("unknown relation `" <> other <> "`")
  }
}

// --- project_read ------------------------------------------------------------

/// The router's `project_read` tool. Reading changes nothing, so it is safe to
/// replay and may run beside other reads.
fn read_tool(read: fn(Ctx, Resource) -> Result(JsonValue, Refusal)) -> Tool {
  tool.Tool(
    name: read_tool_name,
    description: "Read one record of the project. `resource` is one of "
      <> "`candidates` (what you were shown), `board` or `board:N` (a page "
      <> "of tickets), `ticket:ID`, `trigger:ID` or `thread:ID`. Every id a "
      <> "page shows can be read the same way, so you expand one step at a "
      <> "time. This serves the project's own records and cards. It does "
      <> "not serve conversations or files, and there is nothing else to "
      <> "read.",
    prompt_snippet: Some(
      "`project_read` reads one ticket, trigger, thread or page of the board.",
    ),
    schema: tool.object_schema(
      [#("resource", tool.string_property("which record to read"))],
      ["resource"],
    ),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_read(read, ctx, args) },
  )
}

/// Parses the resource word and returns the card the seam reads for it, both as
/// text and as structured details.
fn run_read(
  read: fn(Ctx, Resource) -> Result(JsonValue, Refusal),
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  use text <- tool.with_arg(tool.required_string(args, "resource"))
  use resource <- tool.with_arg(parse_resource(text))
  use document <- tool.or_outcome(read(ctx, resource), refusal_outcome)
  tool.success(json.to_string(document))
  |> tool.with_details(document)
}

/// Parses a resource word. The grammar is closed: a word outside it is a
/// refusal of the call, so no argument reaches a path or a query.
///
/// ## Examples
///
/// ```gleam
/// assert project.parse_resource("board:2") == Ok(project.Board(2))
/// ```
///
/// ```gleam
/// assert project.parse_resource("/etc/passwd") != Ok(project.Candidates)
/// ```
pub fn parse_resource(text: String) -> Result(Resource, String) {
  case text, string.split_once(text, ":") {
    "candidates", _ -> Ok(Candidates)
    "board", _ -> Ok(Board(0))
    _, Ok(#("board", page)) ->
      case int.parse(page) {
        Ok(number) if number >= 0 -> Ok(Board(number))
        Ok(_) | Error(Nil) -> Error("a board page is a number of zero or more")
      }
    _, Ok(#("ticket", id)) ->
      named(id, fn(value) { TicketCard(model.TicketId(value)) })
    _, Ok(#("trigger", id)) ->
      named(id, fn(value) { TriggerCard(model.TriggerId(value)) })
    _, Ok(#("thread", id)) ->
      named(id, fn(value) { ThreadCard(model.ThreadId(value)) })
    _, _ ->
      Error(
        "unknown resource; use candidates, board, ticket:ID, trigger:ID or thread:ID",
      )
  }
}

/// Builds a resource from the id after the colon, refusing an empty one.
fn named(
  id: String,
  build: fn(String) -> Resource,
) -> Result(Resource, String) {
  case string.trim(id) {
    "" -> Error("the resource names no id")
    value -> Ok(build(value))
  }
}

// --- reply -------------------------------------------------------------------

/// The router's `reply` tool. The subject names a message and the host works
/// out the destination, so the model chooses words and never an address.
fn reply_tool(reply: fn(Ctx, Reply) -> Result(Nil, Refusal)) -> Tool {
  tool.Tool(
    name: reply_tool_name,
    description: "Answer the sender of a message. `subject` is the id of the "
      <> "message you are answering, and the host works out where the reply "
      <> "goes: you cannot choose a destination. `purpose` is `acknowledge`, "
      <> "`clarify` or `decline`. Keep it to at most "
      <> int.to_string(max_reply_words)
      <> " words. The reply is queued for delivery and is not sent at once.",
    prompt_snippet: Some(
      "`reply` queues a short answer to the sender of a message.",
    ),
    schema: tool.object_schema(
      [
        #("subject", tool.string_property("the id of the message answered")),
        #(
          "purpose",
          tool.enum_property(
            ["acknowledge", "clarify", "decline"],
            "what the reply is for",
          ),
        ),
        #("text", tool.string_property("the reply text")),
      ],
      ["subject", "purpose", "text"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_reply(reply, ctx, args) },
  )
}

/// Decodes the subject, purpose and text, enforces the word limit and queues
/// the reply through the seam.
fn run_reply(
  reply: fn(Ctx, Reply) -> Result(Nil, Refusal),
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  use subject <- tool.with_arg(tool.required_string(args, "subject"))
  use purpose <- tool.with_arg(decode_purpose(args))
  use text <- tool.with_arg(tool.required_string(args, "text"))
  use text <- tool.with_arg(within_words(text))
  let request = Reply(subject: model.TriggerId(subject), purpose:, text:)
  use Nil <- tool.or_outcome(reply(ctx, request), refusal_outcome)
  tool.success("queued the reply to " <> subject <> ".")
}

/// Decodes the purpose of a reply.
fn decode_purpose(args: JsonValue) -> Result(Purpose, String) {
  use word <- result.try(tool.required_string(args, "purpose"))

  // The purposes are a closed set, and the word cap that goes with them is
  // checked separately.
  case word {
    "acknowledge" -> Ok(Acknowledge)
    "clarify" -> Ok(Clarify)
    "decline" -> Ok(Decline)
    other -> Error("unknown purpose `" <> other <> "`")
  }
}

/// Refuses a reply over the word cap. Words are counted between spaces, which
/// is coarse, and the cap exists to bound the router's output channel rather
/// than to measure prose.
fn within_words(text: String) -> Result(String, String) {
  let words = string.split(text, " ") |> list.filter(fn(word) { word != "" })

  // The refusal tells the model to shorten the reply and try again.
  case list.length(words) <= max_reply_words {
    True -> Ok(text)
    False ->
      Error(
        "a reply holds at most "
        <> int.to_string(max_reply_words)
        <> " words; shorten it",
      )
  }
}

// --- project_report and project_handback ------------------------------------

/// A worker's `project_report` tool. Its status set has no ready word, because
/// only the host's check can say that work is done.
fn report_tool(report: fn(Ctx, WorkerReport) -> Result(Nil, Refusal)) -> Tool {
  tool.Tool(
    name: report_tool_name,
    description: "Tell the project where your work stands. `status` is "
      <> "`progress` while you work, `waiting` when you have stopped and "
      <> "want a person to look (give a `question` if you need an answer), "
      <> "`blocked` when you cannot continue without help, `failed` when "
      <> "your attempt did not work, and `dropped` when the task cannot be "
      <> "done. There is no ready status: finishing is `waiting`, and the "
      <> "host decides whether the work passes its check. Read the original "
      <> "request, do the work in your worktree, and report; you have no "
      <> "access to GitHub.",
    prompt_snippet: Some(
      "`project_report` tells the project your status: progress, waiting, "
      <> "blocked, failed or dropped.",
    ),
    schema: tool.object_schema(
      [
        #(
          "status",
          tool.enum_property(
            ["progress", "waiting", "blocked", "failed", "dropped"],
            "where your work stands",
          ),
        ),
        #(
          "question",
          tool.string_property(
            "beside `waiting` only: a question for a person, at most "
            <> int.to_string(max_note_chars)
            <> " characters",
          ),
        ),
      ],
      ["status"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_report(report, ctx, args) },
  )
}

/// Decodes the report and hands it to the seam, which knows the calling
/// session and so which assignment the report is for.
fn run_report(
  report: fn(Ctx, WorkerReport) -> Result(Nil, Refusal),
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  use decoded <- tool.with_arg(decode_report(args))
  use Nil <- tool.or_outcome(report(ctx, decoded), refusal_outcome)
  tool.success("recorded.")
}

/// Decodes a report and checks that a question appears only beside `waiting`.
/// The project scanner reads it back from the arguments of a committed
/// `project_report` call, so a call is judged the same way when it is replayed
/// as when it was made.
///
/// ## Examples
///
/// ```gleam
/// assert project.decode_report(json.Object([#("status", json.String("progress"))]))
///   == Ok(project.WorkerReport(project.Progress, None))
/// ```
pub fn decode_report(args: JsonValue) -> Result(WorkerReport, String) {
  use word <- result.try(tool.required_string(args, "status"))
  use question <- result.try(tool.optional_string(args, "question"))
  use status <- result.try(decode_status(word))
  use question <- result.try(capped(question))

  // A question beside any other status would never be shown to a person, so
  // it is refused instead of silently dropped.
  case status, question {
    Waiting, _ | _, None -> Ok(WorkerReport(status:, question:))
    _, Some(_) -> Error("a `question` goes only beside `waiting`")
  }
}

/// Decodes a status word from the closed set of five.
fn decode_status(word: String) -> Result(Status, String) {
  case word {
    "progress" -> Ok(Progress)
    "waiting" -> Ok(Waiting)
    "blocked" -> Ok(Blocked)
    "failed" -> Ok(Failed)
    "dropped" -> Ok(Dropped)
    other -> Error("unknown status `" <> other <> "`")
  }
}

/// Refuses model text over the note cap. A report is relayed to people, so its
/// length is bounded when it is written.
fn capped(text: Option(String)) -> Result(Option(String), String) {
  case text {
    Some(value) ->
      case string.length(value) <= max_note_chars {
        True -> Ok(text)
        False ->
          Error(
            "keep it to at most "
            <> int.to_string(max_note_chars)
            <> " characters",
          )
      }
    None -> Ok(None)
  }
}

/// A worker's `project_handback` tool, for a message that belongs to another
/// task. The worker keeps working, and the project decides what the message
/// becomes.
fn handback_tool(handback: fn(Ctx, Handback) -> Result(Nil, Refusal)) -> Tool {
  tool.Tool(
    name: handback_tool_name,
    description: "Hand back a message that does not belong to your task. "
      <> "`trigger` is the id of the message and `reason` says why in a "
      <> "sentence. The project decides what happens to it; you keep "
      <> "working on your own task.",
    prompt_snippet: None,
    schema: tool.object_schema(
      [
        #("trigger", tool.string_property("the id of the message")),
        #("reason", tool.string_property("why it is not yours")),
      ],
      ["trigger", "reason"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_handback(handback, ctx, args) },
  )
}

/// Decodes the trigger and the capped reason and hands them to the seam.
fn run_handback(
  handback: fn(Ctx, Handback) -> Result(Nil, Refusal),
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  use trigger <- tool.with_arg(tool.required_string(args, "trigger"))
  use reason <- tool.with_arg(tool.required_string(args, "reason"))
  use reason <- tool.with_arg(capped(Some(reason)))
  let request =
    Handback(
      trigger: model.TriggerId(trigger),
      reason: option.unwrap(reason, ""),
    )
  use Nil <- tool.or_outcome(handback(ctx, request), refusal_outcome)
  tool.success("handed back " <> trigger <> ".")
}

// --- refusals ----------------------------------------------------------------

/// The model's answer to a refused call. The reason is worded by the seam.
fn refusal_outcome(refusal: Refusal) -> ToolOutcome {
  // Each refusal has a stable code beside its reason, so a client can tell a
  // refusal of the call from an unavailable project without parsing text.
  let #(code, reason) = case refusal {
    NotPermitted(reason:) -> #("not_permitted", reason)
    NotFound(reason:) -> #("not_found", reason)
    Unavailable(reason:) -> #("project_unavailable", reason)
  }

  tool.failure(reason)
  |> tool.with_details(
    json.Object([
      #("error", json.String(code)),
      #("reason", json.String(reason)),
    ]),
  )
}

// These tools read the host's ledger and write nothing on the filesystem, so
// they ask the sandbox for nothing, as `tools/schedule` does.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}
