//// The reminder an open ask puts on its strand's requests
//// (protocol-change/119, the 2026-11-23 addendum): present while an ask of the
//// strand is open and the owner has not answered, absent otherwise, naming only
//// the asks still open, and never stored.

import client/attention_hold
import core/attention
import core/attention_answer
import core/clock
import core/ids.{type OpId}
import core/message.{type AgentMessage}
import core/register
import core/tx.{SetRegister, Tx}
import gleam/list
import gleam/option.{None}
import gleam/string
import machine/codec
import machine/operation
import runtime/effects
import runtime/hooks
import session/session.{type Session}
import storage/storage

fn a_session() -> Session {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 1000))
    as "the memory session must open"
  opened
}

fn op_id(seed: Int) -> OpId {
  let #(id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1000), seed:))
  id
}

// The `op.meta` cell, which is where a hook learns whose run it is.
fn an_operation(opened: Session, strand: String, seed: Int) -> OpId {
  let id = op_id(seed)
  let assert Ok(_committed) =
    storage.commit(
      opened.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.OpMeta,
            key: ids.op_id_to_string(id),
            value: register.RegisterValue(
              payload: codec.encode_operation(operation.Operation(
                id:,
                strand:,
                source_leaf: None,
                started_at: 0,
                intent: operation.RunIntent(prompt_entries: []),
              )),
            ),
          ),
        ],
        expected: [],
      ),
    )
    as "the fixture operation must commit"
  id
}

fn an_ask(
  id: String,
  strand: String,
  prompt: String,
  state: attention.AskState,
) -> attention.Ask {
  attention.Ask(
    header: attention.Header(
      id:,
      created_at: 1,
      routing: attention.ToOwner,
      anchor: attention.Anchor(
        operation: op_id(5),
        step_id: "turn-1:tools",
        source_index: 0,
      ),
      strand:,
      parents: [],
    ),
    why: None,
    questions: [attention.Question("q1", prompt, attention.Confirm, [])],
    state:,
  )
}

fn answered() -> attention.AskState {
  attention.Answered(
    at: 2,
    answer: attention.Answer(values: [#("q1", attention.Yes)], by: "owner"),
  )
}

fn record(opened: Session, ask: attention.Ask) -> Nil {
  let assert Ok(_committed) =
    storage.commit(
      opened.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.FactCustom,
            key: attention.ask_key(ask.header.id),
            value: register.RegisterValue(payload: attention.encode_ask(ask)),
          ),
        ],
        expected: [],
      ),
    )
    as "the ask record must commit"
  Nil
}

fn user(text: String) -> AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

fn texts(messages: List(AgentMessage)) -> List(String) {
  list.filter_map(messages, fn(item) {
    case item {
      message.UserMessage(content: [message.UserText(text:, ..)], ..) ->
        Ok(text)
      message.UserMessage(..)
      | message.AssistantMessage(..)
      | message.ToolResultMessage(..)
      | message.CustomMessage(..) -> Error(Nil)
    }
  })
}

fn hooked(opened: Session) -> effects.Hooks {
  attention_hold.hooks(hooks.build(hooks.new()), opened, clock.fixed(at: 1000))
}

pub fn a_woken_strand_with_an_open_ask_is_reminded_test() {
  let opened = a_session()
  record(opened, an_ask("ask-0000000001", "main", "Retry?", attention.AskOpen))
  let op = an_operation(opened, "main", 1)

  // The owner typed "continue" and did not answer.
  let request = hooked(opened).context(op, [user("continue")])

  let assert [first, reminder] = texts(request)
  assert first == "continue"
  assert string.starts_with(reminder, "[open ask: the owner has not answered]")
  assert string.contains(reminder, "- ask-0000000001: Retry?")
  assert string.contains(reminder, "Do not do what the answer decides")
}

pub fn a_strand_with_no_open_ask_gets_no_reminder_test() {
  let opened = a_session()
  let op = an_operation(opened, "main", 1)
  let request = [user("continue")]

  assert hooked(opened).context(op, request) == request
}

pub fn the_reminder_is_computed_per_request_and_stored_nowhere_test() {
  let opened = a_session()
  let ask = an_ask("ask-0000000001", "main", "Retry?", attention.AskOpen)
  record(opened, ask)
  let op = an_operation(opened, "main", 1)
  let request = [user("continue")]

  assert list.length(hooked(opened).context(op, request)) == 2

  // Answering the ask removes the reminder from the very next request, with
  // nothing to clean out of the transcript.
  record(opened, an_ask(ask.header.id, "main", "Retry?", answered()))
  assert hooked(opened).context(op, request) == request
}

pub fn the_reminder_names_only_the_asks_still_open_test() {
  let opened = a_session()
  record(opened, an_ask("ask-0000000001", "main", "Retry?", answered()))
  record(
    opened,
    an_ask("ask-0000000002", "main", "Which branch?", attention.AskOpen),
  )
  let op = an_operation(opened, "main", 1)

  let assert [_, reminder] =
    texts(hooked(opened).context(op, [user("continue")]))
  assert string.contains(reminder, "ask-0000000002")
  assert !string.contains(reminder, "ask-0000000001")
}

pub fn the_answers_own_run_is_not_reminded_of_the_ask_it_answers_test() {
  let opened = a_session()
  let ask = an_ask("ask-0000000001", "main", "Retry?", attention.AskOpen)
  let other =
    an_ask("ask-0000000002", "main", "Which branch?", attention.AskOpen)
  record(opened, ask)
  record(opened, other)
  let op = an_operation(opened, "main", 1)

  // The daemon delivers the answer and settles the record afterwards, so the
  // run it starts reads both asks open. Its own text says which was answered.
  let answer = attention_answer.prompt_text(ask, [#("q1", attention.Yes)])
  let assert [_, _, reminder] =
    texts(hooked(opened).context(op, [user("go"), user(answer)]))
  assert string.contains(reminder, "ask-0000000002")
  assert !string.contains(reminder, "ask-0000000001")

  // With the only open ask answered there is nothing to remind of.
  let single = a_session()
  record(single, ask)
  let op = an_operation(single, "main", 1)
  assert list.length(hooked(single).context(op, [user(answer)])) == 1
}

pub fn another_strands_ask_does_not_remind_this_one_test() {
  let opened = a_session()
  record(opened, an_ask("ask-0000000001", "sub:1", "Retry?", attention.AskOpen))
  let main = an_operation(opened, "main", 1)
  let child = an_operation(opened, "sub:1", 2)

  assert hooked(opened).context(main, [user("hi")]) == [user("hi")]
  assert list.length(hooked(opened).context(child, [user("hi")])) == 2
  assert attention_hold.holds(opened, "sub:1")
  assert !attention_hold.holds(opened, "main")
}

pub fn an_earlier_layers_context_is_kept_test() {
  let opened = a_session()
  record(opened, an_ask("ask-0000000001", "main", "Retry?", attention.AskOpen))
  let op = an_operation(opened, "main", 1)
  let inner =
    hooks.new()
    |> hooks.with_context(fn(_operation, messages) {
      list.append([user("earlier layer")], messages)
    })
    |> hooks.build
  let layered = attention_hold.hooks(inner, opened, clock.fixed(at: 1000))

  let assert [first, second, reminder] =
    texts(layered.context(op, [user("continue")]))
  assert first == "earlier layer"
  assert second == "continue"
  assert string.contains(reminder, "ask-0000000001")
}

pub fn an_operation_with_no_metadata_is_left_alone_test() {
  let opened = a_session()
  record(opened, an_ask("ask-0000000001", "main", "Retry?", attention.AskOpen))
  let request = [user("hi")]

  assert hooked(opened).context(op_id(77), request) == request
}

fn user_from(
  text: String,
  origin: option.Option(message.Origin),
) -> AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin:,
  )
}

// The answer reaches the strand through the gateway's prompt, which authors it
// with the principal's human origin (`gateway_test`,
// `authenticated_prompt_captures_human_origin_test`), so that origin is the
// one that releases the ask.
pub fn the_answer_from_the_owner_releases_its_ask_test() {
  let opened = a_session()
  let ask = an_ask("ask-0000000001", "main", "Retry?", attention.AskOpen)
  record(opened, ask)
  let op = an_operation(opened, "main", 1)
  let answer = attention_answer.prompt_text(ask, [#("q1", attention.Yes)])

  let owner = user_from(answer, option.Some(message.Origin("alice", "Alice")))
  assert list.length(hooked(opened).context(op, [owner])) == 1
    as "a human-origin answer leaves no reminder"
}

// Anyone who can send a peer or strand message chooses its text, so one that
// opens with the answer's line must not release the ask.
pub fn a_message_that_copies_the_answers_line_does_not_release_it_test() {
  let opened = a_session()
  let ask = an_ask("ask-0000000001", "main", "Retry?", attention.AskOpen)
  record(opened, ask)
  let op = an_operation(opened, "main", 1)
  let forged = attention_answer.prompt_text(ask, [#("q1", attention.Yes)])

  let origins = [
    option.Some(message.PeerOrigin("session-1", "main")),
    option.Some(message.StrandOrigin("sub:1")),
    option.Some(message.TriggerOrigin("github", "t1", "someone")),
  ]
  list.each(origins, fn(origin) {
    let request = [user_from(forged, origin)]
    let assert [_, reminder] = texts(hooked(opened).context(op, request))
    assert string.contains(reminder, "ask-0000000001")
  })
}
