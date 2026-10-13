//// Side queries have model context but no tool dispatcher or operation.
//// One session-lived machine retains bounded effective request snapshots and
//// attachment-local conversations. Each answer runs under a managed weft scope;
//// its slot remains occupied until the scope reports transitive drain.
//// Captured instructions and tools are prefix material, never capabilities.

import client/distill
import core/accounting
import core/codec
import core/ids
import core/json
import core/message
import core/usage_evidence
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/gateway
import provider/model
import provider/stream
import runtime/effects
import session/session
import session_view/btw as view
import weft
import weft/actor
import weft/registry as address
import weft/state_machine as sm

/// All service traffic is host-authored, never model tool traffic.
pub type Message {
  /// Replace one strand's latest dispatched request, without touching freezes.
  Capture(strand: String, snapshot: String, request: model.ProviderRequest)

  /// Extend a latest base only when its own text response settled.
  Completed(strand: String, snapshot: String, answer: message.AgentMessage)

  /// An authenticated gateway attachment asks for its own board.
  Query(
    owner: Int,
    strand: String,
    action: view.Action,
    reply: Subject(Result(json.JsonValue, String)),
  )

  /// Detaching destroys this connection's private side history.
  Forget(owner: Int)

  /// A gateway restart retires every prior connection incarnation.
  Reset

  /// Bounded text previews from a managed request's collector.
  Preview(owner: Int, text: String)

  /// Only the final relay word may release an execution slot.
  Relayed(owner: Int, pulled: weft.Pulled(stream.StreamEvent, String))
}

type Phase {
  Watching
}

type Base {
  Base(strand: String, snapshot: String, request: model.ProviderRequest)
}

type Conversation {
  Conversation(
    base: Base,
    exchanges: List(view.Exchange),
    status: String,
    notice: String,
  )
}

type Flight {
  Flight(
    cancel: weft.Cancel,
    reports: Subject(weft.Pulled(stream.StreamEvent, String)),
    landed: Option(Result(stream.StreamEvent, String)),
  )
}

type Data {
  Data(
    gateway: gateway.Gateway,
    session: session.Session,
    inbox: Subject(Message),
    latest: List(Base),
    conversations: Dict(Int, Conversation),
    flights: Dict(Int, Flight),
  )
}

// The collector selects real stream messages; its state timeout is absolute.
// It never accumulates reasoning, and enforces byte and event ceilings even
// when a subscription provider cannot honor max_output_tokens.
type CollectPhase {
  Parked

  Receiving(handle: stream.StreamHandle)
}

type CollectMessage {
  Begin

  Event(event: stream.StreamEvent)

  Expired
}

type Collection {
  Collection(
    gateway: gateway.Gateway,
    request: model.ProviderRequest,
    prefix: Int,
    ledger: weft.Ledger,
    reply: Subject(Result(stream.StreamEvent, String)),
    inbox: Subject(Message),
    owner: Int,
    text: String,
    events: Int,
    previewed: Int,
  )
}

/// Tees effective generation requests without retaining tool executors.
/// The callback runs in the existing provider observer, off the driver.
///
/// ## Examples
///
/// ```gleam
/// // btw.observer(name, session, request_builder)(spec, generation)
/// ```
pub fn observer(
  name: address.Address(Message),
  opened: session.Session,
  build: fn(effects.RequestSpec) -> model.ProviderRequest,
) -> fn(effects.RequestSpec, String) -> fn(stream.StreamEvent) -> Nil {
  fn(spec, _generation) {
    case spec {
      effects.GenerationRequest(operation:, response_entry:, ..) -> {
        let strand =
          session.op_meta(opened, operation)
          |> result.map(fn(cell) {
            option.map(cell, fn(cell) { cell.value.strand })
          })
          |> result.unwrap(None)
        case strand {
          None -> fn(_) { Nil }
          Some(strand) -> {
            let snapshot = ids.entry_id_to_string(response_entry)
            let _captured =
              address.send(name, Capture(strand, snapshot, build(spec)))
            fn(event) {
              case event {
                stream.Settled(message:, ..) -> {
                  let _ =
                    address.send(
                      name,
                      Completed(strand, snapshot, stream.message(message)),
                    )
                  Nil
                }
                stream.Delta(_) | stream.Failed(..) -> Nil
              }
            }
          }
        }
      }
      effects.PollRequest(..) | effects.SummaryRequest(..) -> fn(_) { Nil }
    }
  }
}

/// Starts the disposable side service; restart loses only ephemeral state.
///
/// ## Examples
///
/// ```gleam
/// // btw.start(name, gateway, session)
/// ```
pub fn start(
  name: address.Address(Message),
  gateway: gateway.Gateway,
  session: session.Session,
) -> actor.StartResult(Subject(Message)) {
  sm.new_with_initialiser(1000, fn(inbox) {
    Ok(
      sm.initialised(
        Watching,
        Data(gateway, session, inbox, [], dict.new(), dict.new()),
      )
      |> sm.returning(inbox),
    )
  })
  |> sm.addressed(name)
  |> sm.on_event(handle)
  |> sm.start
}

/// A bounded, non-panicking gateway seam; no inference runs in this call.
///
/// ## Examples
///
/// ```gleam
/// // btw.query(name, connection, "main", view.Read)
/// ```
pub fn query(
  name: address.Address(Message),
  owner: Int,
  strand: String,
  action: view.Action,
) -> Result(json.JsonValue, String) {
  let reply = process.new_subject()
  use Nil <- result.try(
    address.send(name, Query(owner, strand, action, reply))
    |> result.replace_error("side service is unavailable"),
  )
  process.receive(reply, within: 1000)
  |> result.replace_error("side service did not answer")
  |> result.flatten
}

fn handle(
  _phase: Phase,
  data: Data,
  event: Message,
) -> sm.Next(Phase, Data, Message) {
  case event {
    Capture(strand, snapshot, request) -> {
      let base = Base(strand, snapshot, request)
      let others = list.filter(data.latest, fn(old) { old.strand != strand })
      let latest = case request_size(request) <= 8_388_608 {
        True -> [base, ..others] |> list.take(4)
        False -> others
      }
      settle(Data(..data, latest:))
    }
    Completed(strand, snapshot, answer) -> {
      let latest =
        list.filter_map(data.latest, fn(base) {
          case base.strand == strand && base.snapshot == snapshot {
            False -> Ok(base)
            True -> {
              use resolved <- result.try(settled_identity(
                data.gateway,
                base.request.target,
                answer,
              ))
              let messages = case text_only(answer) {
                True -> list.append(base.request.messages, [answer])
                False -> base.request.messages
              }
              let request =
                model.ProviderRequest(
                  ..base.request,
                  target: model.ForResolved(resolved),
                  messages:,
                )
              use <- bool.guard(request_size(request) > 8_388_608, Error(Nil))
              Ok(Base(..base, request:))
            }
          }
        })
      settle(Data(..data, latest:))
    }
    Query(owner, strand, action, reply) -> {
      let #(data, answer) = asked(data, owner, strand, action)
      process.send(reply, result.map(answer, board))
      settle(data)
    }
    Reset -> {
      dict.each(data.flights, fn(_, flight) { weft.cancel(flight.cancel) })
      settle(Data(..data, conversations: dict.new()))
    }
    Forget(owner) -> {
      cancel(data, owner)
      settle(
        Data(..data, conversations: dict.delete(data.conversations, owner)),
      )
    }
    Preview(owner, text) -> {
      let conversations =
        update_conversation(data.conversations, owner, fn(found) {
          result.map(found, fn(conversation) {
            Conversation(
              ..conversation,
              exchanges: update_answer(conversation.exchanges, text),
            )
          })
        })
      settle(Data(..data, conversations:))
    }
    Relayed(owner, pulled) -> relayed(data, owner, pulled)
  }
}

fn settle(data: Data) -> sm.Next(Phase, Data, Message) {
  let selector =
    dict.fold(
      data.flights,
      process.new_selector() |> process.select(data.inbox),
      fn(selector, owner, flight) {
        process.select_map(selector, flight.reports, fn(pulled) {
          Relayed(owner, pulled)
        })
      },
    )
  sm.keep(data) |> sm.with_selector(selector)
}

fn asked(
  data: Data,
  owner: Int,
  strand: String,
  action: view.Action,
) -> #(Data, Result(Conversation, String)) {
  case action {
    view.Read -> #(data, selected(data, owner, strand))
    view.Cancel -> {
      cancel(data, owner)
      let found =
        selected(data, owner, strand)
        |> result.map(fn(c) {
          Conversation(..c, notice: "Cancelling side request")
        })
      case dict.has_key(data.conversations, owner) {
        True -> store(data, owner, found)
        False -> #(data, found)
      }
    }
    view.Clear -> {
      cancel(data, owner)
      #(
        Data(..data, conversations: dict.delete(data.conversations, owner)),
        Ok(empty(strand)),
      )
    }
    view.Refresh -> {
      case
        dict.has_key(data.flights, owner)
        || !dict.has_key(data.conversations, owner)
        && dict.size(data.conversations) >= 8
      {
        True -> #(data, Error("cancel the side request before refreshing"))
        False -> store(data, owner, fresh(data, strand))
      }
    }
    view.Ask(text) -> ask(data, owner, strand, text)
  }
}

fn selected(
  data: Data,
  owner: Int,
  strand: String,
) -> Result(Conversation, String) {
  case dict.get(data.conversations, owner) {
    Ok(conversation) if conversation.base.strand == strand -> Ok(conversation)
    Ok(_) ->
      Error(
        "refresh or clear the side conversation before querying another strand",
      )
    Error(Nil) -> Ok(empty(strand))
  }
}

fn empty(strand: String) -> Conversation {
  Conversation(
    Base(
      strand,
      "",
      model.ProviderRequest(model.ForRole(model.Main, None), None, [], [], None),
    ),
    [],
    "idle",
    "Ask with /btw <question>. Context freezes on the first question.",
  )
}

fn fresh(data: Data, strand: String) -> Result(Conversation, String) {
  use base <- result.try(
    list.find(data.latest, fn(base) { base.strand == strand })
    |> result.replace_error(
      "no dispatched context is available yet; send a main-session message first",
    ),
  )
  use resolved <- result.try(pin(data.gateway, base.request.target))
  let request =
    model.ProviderRequest(..base.request, target: model.ForResolved(resolved))
  use <- bool.guard(
    request_size(request) > 8_388_608,
    Error("side snapshot exceeds 8 MiB"),
  )
  Ok(Conversation(
    Base(..base, request:),
    [],
    "ready",
    "Frozen context. /btw refresh captures newer work.",
  ))
}

fn pin(
  gateway: gateway.Gateway,
  target: model.RequestTarget,
) -> Result(model.ResolvedModel, String) {
  case target {
    model.ForResolved(resolved) -> Ok(resolved)
    model.ForRole(role, thinking) -> {
      use resolved <- result.map(
        gateway.resolve(gateway, role)
        |> result.replace_error("side model is unavailable"),
      )
      model.ResolvedModel(
        ..resolved,
        thinking: option.unwrap(thinking, resolved.thinking),
      )
    }
  }
}

// A fallback can settle on a different service. Keep its actual identity
// before replaying provider-confidential reasoning from that response.
fn settled_identity(
  gateway: gateway.Gateway,
  target: model.RequestTarget,
  answer: message.AgentMessage,
) -> Result(model.ResolvedModel, Nil) {
  use original <- result.try(pin(gateway, target) |> result.replace_error(Nil))
  case answer {
    message.AssistantMessage(provider:, model: produced, ..) -> {
      let selected = case
        original.provider == provider && original.model_id == produced
      {
        True -> Ok(original)
        False -> gateway.resolve_identity(gateway, provider, produced)
      }
      use resolved <- result.map(selected)
      case target {
        model.ForRole(_, Some(thinking)) ->
          model.ResolvedModel(..resolved, thinking:)
        model.ForRole(_, None) | model.ForResolved(_) -> resolved
      }
    }
    message.UserMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> Error(Nil)
  }
}

fn ask(
  data: Data,
  owner: Int,
  strand: String,
  text: String,
) -> #(Data, Result(Conversation, String)) {
  let attempt = fn() {
    use _ <- result.try(view.action("ask", text))
    use <- bool.guard(
      dict.has_key(data.flights, owner) || dict.size(data.flights) >= 2,
      Error("a side request is already running; wait or cancel it"),
    )
    use <- bool.guard(
      !dict.has_key(data.conversations, owner)
        && dict.size(data.conversations) >= 8,
      Error("too many side conversations are retained"),
    )
    use previous <- result.try(selected(data, owner, strand))
    use conversation <- result.try(case previous.base.snapshot {
      "" -> fresh(data, strand)
      _ -> Ok(previous)
    })
    use <- bool.guard(
      conversation.status == "failed",
      Error(
        "refresh or clear the failed side conversation before another question",
      ),
    )
    use <- bool.guard(
      list.length(conversation.exchanges) >= 8,
      Error("side conversation has eight exchanges; refresh or clear it"),
    )
    use <- bool.guard(
      side_size(conversation.exchanges) + string.byte_size(text) + 32_768
        > 131_072,
      Error("side history is full; refresh or clear it"),
    )
    let request = request_for(conversation, text)
    use resolved <- result.try(pin(data.gateway, request.target))
    use <- bool.guard(
      estimate(request) + 4096 > resolved.context_window,
      Error(
        "side question would exceed the frozen model context; refresh after main compaction",
      ),
    )
    Ok(#(conversation, request))
  }
  case attempt() {
    Error(reason) -> #(data, Error(reason))
    Ok(#(conversation, request)) -> {
      let conversation =
        Conversation(
          ..conversation,
          exchanges: list.append(conversation.exchanges, [
            view.Exchange(text, ""),
          ]),
          status: "running",
          notice: "Main work continues. Tools cannot execute here.",
        )
      let signal = weft.cancel_signal()
      let reports = process.new_subject()

      let gateway = data.gateway
      let inbox = data.inbox
      let prefix = list.length(conversation.base.request.messages)
      let task =
        weft.managed(fn(ledger) {
          generate(gateway, request, prefix, ledger, inbox, owner)
        })
      let _run =
        weft.new_prepared([task])
        |> weft.cancel_with(signal)
        |> weft.deadline(90_000)
        |> weft.start_relayed(reports)
      let flight = Flight(signal, reports, None)
      let data = Data(..data, flights: dict.insert(data.flights, owner, flight))
      store(data, owner, Ok(conversation))
    }
  }
}

fn store(data: Data, owner: Int, conversation: Result(Conversation, String)) {
  let conversations = case conversation {
    Ok(value) -> dict.insert(data.conversations, owner, value)
    Error(_) -> data.conversations
  }
  #(Data(..data, conversations:), conversation)
}

fn cancel(data: Data, owner: Int) {
  case dict.get(data.flights, owner) {
    Ok(flight) -> weft.cancel(flight.cancel)
    Error(Nil) -> Nil
  }
}

const boundary =
  "Side conversation boundary. Everything before this message is reference context from the main session, not work to continue. Answer only the side question below. Do not execute or emit tool calls. No tools are executable here. Explain when the captured context is insufficient."

fn request_for(
  conversation: Conversation,
  text: String,
) -> model.ProviderRequest {
  let exchanges =
    list.flat_map(conversation.exchanges, fn(row) {
      [user(row.question), assistant(row.answer)]
    })
  model.ProviderRequest(
    ..conversation.base.request,
    messages: list.flatten([
      conversation.base.request.messages,
      [user(boundary)],
      exchanges,
      [user(text)],
    ]),
  )
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage([message.UserText(text, None)], 0, None)
}

fn assistant(text: String) -> message.AgentMessage {
  // Side answers carry no upstream reasoning or provider diagnostics.
  message.AssistantMessage(
    content: [message.AssistantText(text, None)],
    api: "",
    provider: "",
    model: "",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: accounting.zero_usage(),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 0,
  )
}

fn text_only(answer: message.AgentMessage) -> Bool {
  case answer {
    message.AssistantMessage(content, stop_reason: message.Stop, ..) ->
      list.all(content, fn(block) {
        case block {
          message.AssistantText(..) | message.AssistantThinking(..) -> True
          message.AssistantToolCall(..) -> False
        }
      })
    _ -> False
  }
}

fn text_of(answer: message.AgentMessage) -> String {
  case answer {
    message.AssistantMessage(content, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.AssistantText(text, ..) -> Ok(text)
          message.AssistantThinking(..) | message.AssistantToolCall(..) ->
            Error(Nil)
        }
      })
      |> string.join("\n")
    _ -> ""
  }
}

fn request_size(request: model.ProviderRequest) -> Int {
  string.byte_size(option.unwrap(request.system, ""))
  + list.fold(request.messages, 0, fn(n, value) {
    n + string.byte_size(json.to_string(codec.encode_message(value)))
  })
  + list.fold(request.tools, 0, fn(n, tool) {
    n
    + string.byte_size(tool.name)
    + string.byte_size(tool.description)
    + string.byte_size(json.to_string(tool.input_schema))
  })
}

fn estimate(request: model.ProviderRequest) -> Int {
  request_size(request) / 3
}

fn side_size(rows: List(view.Exchange)) -> Int {
  list.fold(rows, 0, fn(n, row) {
    n + string.byte_size(row.question) + string.byte_size(row.answer)
  })
}

fn board(c: Conversation) -> json.JsonValue {
  let model = case c.base.request.target {
    model.ForResolved(resolved) -> resolved.provider <> "/" <> resolved.model_id
    model.ForRole(..) -> ""
  }
  view.encode(view.Board(
    c.base.strand,
    c.base.snapshot,
    model,
    c.status,
    c.exchanges,
    c.notice,
  ))
}

fn update_answer(
  rows: List(view.Exchange),
  answer: String,
) -> List(view.Exchange) {
  case list.reverse(rows) {
    [] -> []
    [row, ..rest] -> list.reverse([view.Exchange(..row, answer:), ..rest])
  }
}

fn relayed(
  data: Data,
  owner: Int,
  pulled: weft.Pulled(stream.StreamEvent, String),
) -> sm.Next(Phase, Data, Message) {
  case dict.get(data.flights, owner) {
    Error(Nil) -> settle(data)
    Ok(flight) ->
      case pulled {
        weft.PulledOutcome(outcome) -> {
          let landed = case outcome {
            weft.Completed(value:, ..) -> Ok(value)
            weft.Failed(error:, ..) -> Error(error)
            weft.Crashed(..) -> Error("side request crashed")
            weft.Abandoned(..) -> Error("side request cancelled or timed out")
            weft.NeverStarted(..) -> Error("side request never started")
            weft.DrainProofLost(..) ->
              Error("side request drain proof was lost")
            weft.CancellationUnconfirmed(..) ->
              Error("side request cancellation was not confirmed")
          }
          settle(
            Data(
              ..data,
              flights: dict.insert(
                data.flights,
                owner,
                Flight(..flight, landed: Some(landed)),
              ),
            ),
          )
        }
        weft.NotYet -> settle(data)
        weft.AllDelivered ->
          finished(
            data,
            owner,
            option.unwrap(
              flight.landed,
              Error("side request ended without an outcome"),
            ),
          )
        weft.RunLost(_) ->
          finished(data, owner, Error("side request owner was lost"))
      }
  }
}

fn finished(
  data: Data,
  owner: Int,
  terminal: Result(stream.StreamEvent, String),
) -> sm.Next(Phase, Data, Message) {
  let report = case terminal {
    Ok(event) -> stream.terminal_accounting(event)
    Error(_) -> unknown_accounting()
  }
  let answer = case terminal {
    Ok(stream.Settled(settled, _)) -> Ok(stream.message(settled))
    Ok(stream.Failed(error, _)) -> Error(stream.describe_error(error))
    Ok(stream.Delta(_)) -> Error("side stream ended without a terminal")
    Error(reason) -> Error(reason)
  }
  let answer = case distill.record_request(data.session, report, "btw") {
    Ok(Nil) -> answer
    Error(reason) -> Error(reason)
  }
  let conversations =
    update_conversation(data.conversations, owner, fn(found) {
      result.map(found, fn(c) {
        case answer {
          Ok(value) ->
            Conversation(
              ..c,
              status: "ready",
              exchanges: update_answer(c.exchanges, text_of(value)),
              notice: "Answer uses frozen context. Nothing was sent to the main session.",
            )
          Error(reason) -> Conversation(..c, status: "failed", notice: reason)
        }
      })
    })
  settle(
    Data(..data, conversations:, flights: dict.delete(data.flights, owner)),
  )
}

fn generate(
  gateway: gateway.Gateway,
  request: model.ProviderRequest,
  prefix: Int,
  ledger: weft.Ledger,
  inbox: Subject(Message),
  owner: Int,
) -> Result(stream.StreamEvent, String) {
  let reply = process.new_subject()
  let collector =
    sm.new(
      Parked,
      Collection(
        gateway,
        request,
        prefix,
        ledger,
        reply,
        inbox,
        owner,
        "",
        0,
        0,
      ),
    )
    |> sm.on_event(collect)
    |> sm.start
  use started <- result.try(
    collector
    |> result.map_error(fn(_) { "side stream collector could not start" }),
  )
  use Nil <- result.try(
    case
      weft.adopt_leaf(ledger, started.pid, fn() { process.kill(started.pid) })
    {
      weft.Adopted -> Ok(Nil)
      weft.Refused -> Error("side request was cancelled")
    },
  )
  process.send(started.data, Begin)
  process.receive(reply, within: 75_000)
  |> result.replace_error("side stream collector did not answer")
  |> result.flatten
}

// Provider events are process-bound subjects. Preparation belongs to the
// collector that receives them, and its begin permit follows managed adoption.
fn begin_collection(
  data: Collection,
) -> sm.Next(CollectPhase, Collection, CollectMessage) {
  let prepared =
    gateway.prepare(
      gateway.with_cache_prefix(data.gateway, data.prefix),
      data.request,
    )
  let handle = prepared.handle
  let adopted = case handle.owner {
    None -> weft.Adopted
    Some(pid) -> weft.adopt(data.ledger, pid, fn() { stream.cancel(handle) })
  }
  case adopted {
    weft.Refused -> {
      process.send(
        data.reply,
        Error("side request was cancelled before dispatch"),
      )
      sm.stop()
    }
    weft.Adopted -> {
      prepared.begin()
      sm.transition(Receiving(handle), data)
      |> sm.with_state_timeout(after: 60_000, sending: Expired)
      |> sm.with_selector(
        process.new_selector() |> process.select_map(handle.events, Event),
      )
    }
  }
}

fn collect(
  phase: CollectPhase,
  data: Collection,
  event: CollectMessage,
) -> sm.Next(CollectPhase, Collection, CollectMessage) {
  case phase, event {
    Parked, Begin -> begin_collection(data)
    Parked, Event(_) | Parked, Expired | Receiving(_), Begin -> sm.keep(data)
    Receiving(handle), Expired ->
      end_collection(
        handle,
        data,
        Error("side answer exceeded its 60-second deadline"),
        unknown_accounting(),
      )
    Receiving(handle), Event(stream.Delta(delta)) -> {
      let text = case delta {
        stream.TextDelta(_, text) -> data.text <> text
        stream.ThinkingDelta(..) | stream.ToolCallDelta(..) -> data.text
      }
      case string.byte_size(text) > 32_768 || data.events >= 8192 {
        True ->
          end_collection(
            handle,
            data,
            Error("side answer exceeded its output limit"),
            unknown_accounting(),
          )
        False -> {
          let count = string.byte_size(text)
          let previewed = case count >= data.previewed + 1024 {
            True -> {
              process.send(data.inbox, Preview(data.owner, text))
              count
            }
            False -> data.previewed
          }
          sm.keep(
            Collection(..data, text:, events: data.events + 1, previewed:),
          )
        }
      }
    }
    Receiving(handle), Event(stream.Failed(error, report)) ->
      finish_collection(handle, data, stream.Failed(error, report))
    Receiving(handle), Event(stream.Settled(settled, report)) -> {
      let answer = stream.message(settled)
      let text = text_of(answer)
      let result = case
        text_only(answer)
        && string.byte_size(text) <= 32_768
        && string.trim(text) != ""
      {
        True -> Ok(answer)
        False ->
          Error(
            "side answer was empty, too large, or requested tools; nothing was executed",
          )
      }
      case result {
        Ok(_) ->
          finish_collection(handle, data, stream.Settled(settled, report))
        Error(reason) -> end_collection(handle, data, Error(reason), report)
      }
    }
  }
}

fn end_collection(
  handle: stream.StreamHandle,
  data: Collection,
  answer: Result(message.AgentMessage, String),
  report: accounting.RequestAccounting,
) -> sm.Next(CollectPhase, Collection, CollectMessage) {
  let reason = case answer {
    Error(reason) -> reason
    Ok(_) -> "side stream stopped"
  }
  finish_collection(
    handle,
    data,
    stream.Failed(stream.StreamError("btw", reason), report),
  )
}

fn finish_collection(
  handle: stream.StreamHandle,
  data: Collection,
  terminal: stream.StreamEvent,
) -> sm.Next(CollectPhase, Collection, CollectMessage) {
  stream.cancel(handle)
  process.send(data.reply, Ok(terminal))
  sm.stop()
}

fn unknown_accounting() -> accounting.RequestAccounting {
  accounting.from_usage(accounting.unknown_usage(usage_evidence.Other))
}

fn update_conversation(
  conversations: Dict(Int, Conversation),
  owner: Int,
  update: fn(Result(Conversation, Nil)) -> Result(Conversation, Nil),
) -> Dict(Int, Conversation) {
  case update(dict.get(conversations, owner)) {
    Ok(conversation) -> dict.insert(conversations, owner, conversation)
    Error(Nil) -> conversations
  }
}
