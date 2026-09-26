//// The block summarizer against a real session store and a scripted
//// summarizer: which committed blocks are asked about, what is stored and
//// pushed, what a failure leaves behind, and how a live stream's requests
//// coalesce.
////
//// The store is real because the machine reads committed entries and an
//// operation's strand straight off it. The summarizer, the cell write and
//// the bus publish are seams the tests fill with scripts that report to
//// the test process, so each assertion is about what the machine did and
//// not about a provider or a runtime.

import client/advisorslice
import client/blocksummary
import client/blocksummarybook
import client/catalog
import client/distill
import core/clock
import core/entry
import core/ids.{type EntryId, type OpId}
import core/json.{type JsonValue}
import core/message
import core/register
import core/tx.{InsertEntry, SetRegister, Tx}
import events/bus
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation
import machine/strand as machine_strand
import provider/gateway as provider_gateway
import provider/model
import provider/secret
import provider/stream
import runtime/effects
import runtime/writer
import session/session.{type Session}
import storage/storage
import support/addresses
import support/provider as provider_test
import telemetry/log
import weft/registry as address

// --- which blocks ----------------------------------------------------------------

// A reasoning block at or past the floor is a job, and one below it is not:
// a short block keeps the terminal's first-line digest and costs nothing.
pub fn the_floor_gates_reasoning_test() {
  let long = string.repeat("r", 512)
  let value =
    an_entry(1, assistant("acme", [thinking(long), thinking("short"), text()]))

  let assert [job] = blocksummary.jobs(value, provider: "acme", floor: 512)
    as "only the long block qualifies"
  assert job.block == 0
  assert job.source == blocksummarybook.Reasoning
  assert job.text == long
}

// Reasoning from another provider is never a job, whatever its length:
// reasoning is confidential to the provider that produced it, and the
// summarize route belongs to a different one here.
pub fn reasoning_from_another_provider_is_skipped_test() {
  let value =
    an_entry(1, assistant("other", [thinking(string.repeat("r", 4096))]))
  assert blocksummary.jobs(value, provider: "acme", floor: 512) == []
}

// A redacted block has no text behind its marker, so there is nothing to
// summarize.
pub fn a_redacted_block_is_skipped_test() {
  let redacted =
    message.AssistantThinking(
      thinking: string.repeat("r", 4096),
      thinking_signature: None,
      redacted: True,
    )
  let value = an_entry(1, assistant("acme", [redacted]))
  assert blocksummary.jobs(value, provider: "acme", floor: 512) == []
}

// A long advice message is a job over its body, whichever provider the
// session uses: it is harness-written text. A short one, a feed and an
// ordinary prompt are not.
pub fn delivered_advice_is_summarized_by_its_body_test() {
  let body = string.repeat("Re-run the failing test. ", 30)
  let advice = an_entry(2, advisorslice.advice_message(body, 0))

  let assert [job] = blocksummary.jobs(advice, provider: "anyone", floor: 512)
    as "a long advice body qualifies"
  assert job.block == 0
  assert job.source == blocksummarybook.AdvisorMessage
  assert job.text == body

  let short = an_entry(3, advisorslice.advice_message("Looks fine.", 0))
  assert blocksummary.jobs(short, provider: "anyone", floor: 512) == []

  let prompt = an_entry(4, user(string.repeat("please ", 200)))
  assert blocksummary.jobs(prompt, provider: "anyone", floor: 512) == []
}

// --- the request and the answer --------------------------------------------------

// The answer is cut down to one label: whitespace collapsed, a leading
// label and quotation marks removed, a long answer cut at a word with an
// ellipsis, and an empty one refused.
pub fn the_answer_is_bounded_to_one_label_test() {
  assert blocksummary.parse("Summary:  \"The agent reads\n the test.\"")
    == Ok("The agent reads the test.")
  assert blocksummary.parse(" \n ") == Error(Nil)

  let assert Ok(cut) = blocksummary.parse(string.repeat("word ", 200))
    as "a long answer is cut rather than refused"
  assert string.byte_size(cut) <= blocksummary.max_summary_bytes
  assert string.ends_with(cut, "word…")
}

// The prompt names the source's author in the third person and fences the
// text, so the label cannot be mistaken for the agent's own words.
pub fn the_request_asks_for_the_third_person_test() {
  let asked = blocksummary.request(blocksummarybook.Reasoning, "the text")
  assert string.contains(asked, "beginning with \"The agent\"")
  assert string.contains(asked, "<text>\nthe text\n</text>")

  let advised = blocksummary.request(blocksummarybook.AdvisorMessage, "x")
  assert string.contains(advised, "beginning with \"The advisor\"")
}

// Only the summarize role routes the summarizer. A catalogue with no such
// role gets no route rather than a fall back to the main model.
pub fn the_route_is_the_summarize_role_alone_test() {
  let assert Error(_reason) = blocksummary.route(routing([model.Main]))
    as "no summarize role, no route"
  let assert Ok(route) = blocksummary.route(routing([model.Summarize]))
    as "a summarize role routes"
  assert route.provider == "acme"
}

// A stored label reads back, and a cell of any other shape reads as none.
pub fn the_cell_codec_is_total_test() {
  assert blocksummary.decode(blocksummary.encode("x")) == Ok("x")
  assert blocksummary.decode(json.Object([#("text", json.String(""))]))
    == Error(Nil)
  assert blocksummary.decode(json.String("x")) == Error(Nil)
}

// --- committed blocks --------------------------------------------------------------

// One commit carrying a long reasoning block, a short one, another
// provider's long block and a long advice message: exactly the first long
// block and the advice are asked about, each label is stored under its
// block's key and then pushed, and nothing from the other provider reaches
// the summarizer.
pub fn a_commit_stores_and_pushes_labels_for_its_long_blocks_test() {
  let rig = a_rig(answering("Summary: The agent weighs two fixes."))
  let secret = string.repeat("other provider's reasoning ", 40)
  let reasoned =
    an_entry(
      10,
      assistant("acme", [
        text(),
        thinking(string.repeat("x", 600)),
        thinking("short"),
      ]),
    )
  let foreign = an_entry(11, assistant("other", [thinking(secret)]))
  let advised =
    an_entry(
      12,
      advisorslice.advice_message(string.repeat("Check it. ", 80), 0),
    )
  commit_entries(rig, [reasoned, foreign, advised])

  let written = receive_all(rig.written, 2)
  assert list.sort(list.map(written, fn(pair) { pair.0 }), string.compare)
    == list.sort(
      [blocksummary.key(reasoned.id, 1), blocksummary.key(advised.id, 0)],
      string.compare,
    )
  assert list.all(written, fn(pair) {
    pair.1 == blocksummary.encode("The agent weighs two fixes.")
  })

  let pushed = receive_all(rig.published, 2)
  assert list.contains(
    pushed,
    bus.BlockSummary(
      subject: bus.SettledBlock(entry: reasoned.id, block: 1),
      text: "The agent weighs two fixes.",
    ),
  )
  assert !list.any(requests(rig), string.contains(_, secret))
  stop(rig)
}

// A summarizer that refuses, or answers nothing usable, leaves no cell and
// pushes nothing: the terminal keeps its digest and sees no error row.
pub fn a_failed_summary_leaves_nothing_behind_test() {
  let refusing =
    a_rig(
      Answering(answer: fn(_request) {
        Error("the provider refused the request")
      }),
    )
  commit_entries(refusing, [
    an_entry(20, assistant("acme", [thinking(string.repeat("x", 600))])),
  ])
  let assert Ok(_asked) = process.receive(refusing.asked, 2000)
    as "the block must still be asked about"
  assert process.receive(refusing.written, 300) == Error(Nil)
  assert process.receive(refusing.published, 100) == Error(Nil)
  stop(refusing)

  let empty = a_rig(answering("   "))
  commit_entries(empty, [
    an_entry(21, assistant("acme", [thinking(string.repeat("x", 600))])),
  ])
  let assert Ok(_asked) = process.receive(empty.asked, 2000)
    as "the block must still be asked about"
  assert process.receive(empty.written, 300) == Error(Nil)
  stop(empty)
}

// A short block, committed, asks nothing at all.
pub fn a_short_block_asks_nothing_test() {
  let rig = a_rig(answering("The agent reads."))
  commit_entries(rig, [an_entry(30, assistant("acme", [thinking("brief")]))])
  assert process.receive(rig.asked, 300) == Error(Nil)
  stop(rig)
}

// The stored label is what a reattaching terminal reads back, by exact
// key, and a block with no label is simply absent from the board.
pub fn a_stored_label_reads_back_by_exact_key_test() {
  let rig = a_rig(answering("The agent weighs two fixes."))
  let reasoned =
    an_entry(40, assistant("acme", [thinking(string.repeat("x", 600))]))
  commit_entries(rig, [reasoned])
  let assert [#(cell, value)] = receive_all(rig.written, 1)
    as "the label must be written"
  let assert Ok(_committed) =
    storage.commit(
      rig.opened.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.FactCustom,
            key: cell,
            value: register.RegisterValue(payload: value),
          ),
        ],
        expected: [],
      ),
    )
    as "the fixture stores the written cell"

  let id = ids.entry_id_to_string(reasoned.id)
  let assert Ok(board) = blocksummary.read(rig.opened, [#(id, 0), #(id, 1)])
    as "the read must answer"
  assert board
    == json.Object([
      #(
        "summaries",
        json.Array([
          json.Object([
            #("entry", json.String(id)),
            #("block", json.Int(0)),
            #("text", json.String("The agent weighs two fixes.")),
          ]),
        ]),
      ),
    ])
  stop(rig)
}

// --- live streams ------------------------------------------------------------------

// While the first request for a stream is out, however much more reasoning
// arrives, no second request starts. When the first ends, its label is
// pushed and exactly one more request starts, carrying the newest text.
pub fn live_requests_coalesce_behind_the_one_out_test() {
  let rig = a_rig(held("The agent compares two fixes."))
  let operation = an_operation(rig.opened, "main", 5)
  let tap =
    blocksummary.observer(rig.name, single_provider())(
      a_request("acme", operation),
      "g-1",
    )

  tap(reasoning(string.repeat("a", 4096)))
  let assert Ok(#(first, release)) = process.receive(rig.held, 2000)
    as "the first 4 KiB must be asked about"
  assert string.byte_size(first) > 4096

  list.each(["<one>", "<two>", "<three>"], fn(marker) {
    tap(reasoning(string.repeat("b", 4096) <> marker))
  })
  assert process.receive(rig.held, 300) == Error(Nil)

  process.send(release, Nil)
  let assert Ok(bus.BlockSummary(
    subject: bus.LiveStream(generation:, ..),
    text:,
  )) = process.receive(rig.published, 2000)
    as "the first live label must be pushed"
  assert generation == "g-1"
  assert text == "The agent compares two fixes."

  let assert Ok(#(second, release)) = process.receive(rig.held, 2000)
    as "exactly one more request follows"
  assert string.contains(second, "<three>")
  process.send(release, Nil)
  assert process.receive(rig.held, 300) == Error(Nil)
  stop(rig)
}

// A generation request dispatched to another provider is not observed at
// all: its reasoning never reaches the machine, so nothing is asked.
pub fn another_providers_stream_is_not_observed_test() {
  let rig = a_rig(held("unused"))
  let operation = an_operation(rig.opened, "main", 6)
  let tap =
    blocksummary.observer(rig.name, single_provider())(
      a_request("other", operation),
      "g-2",
    )

  tap(reasoning(string.repeat("a", 8192)))
  assert process.receive(rig.held, 300) == Error(Nil)
  stop(rig)
}

// A strand configured with the summarize route's own provider can still be
// answered by another one when its role's chain falls back. With `main`
// heading `acme` and falling back to `other`, the stream names nothing that
// says which one answered, so it is not observed; settled blocks, checked
// against the provider the committed message names, are unaffected.
pub fn a_cross_provider_fallback_chain_is_not_observed_test() {
  let crossing =
    a_catalogue([#(model.Main, ["acme", "other"]), #(model.Summarize, ["acme"])])
  let admits = blocksummary.live_admission(crossing, "acme")
  assert !admits(identity("acme"))
  assert !admits(identity("other"))

  let rig = a_rig(held("unused"))
  let operation = an_operation(rig.opened, "main", 7)
  let tap =
    blocksummary.observer(rig.name, admits)(a_request("acme", operation), "g-3")
  tap(reasoning(string.repeat("a", 8192)))
  assert process.receive(rig.held, 300) == Error(Nil)
  stop(rig)
}

// A chain that stays on the summarize provider admits the strands it
// serves. A text-only identity can also be rerouted to the `vision` chain,
// so a `vision` chain on another provider turns its live text off, while a
// strand that reads images is never rerouted and stays admitted.
pub fn only_single_provider_routes_are_observed_test() {
  let staying =
    a_catalogue([#(model.Main, ["acme"]), #(model.Summarize, ["acme"])])
  assert blocksummary.live_admission(staying, "acme")(identity("acme"))

  let seeing =
    a_catalogue([
      #(model.Main, ["acme"]),
      #(model.Summarize, ["acme"]),
      #(model.Vision, ["other"]),
    ])
  assert blocksummary.live_admission(seeing, "acme")(identity("acme"))

  let blind =
    catalog.Catalog(
      ..seeing,
      models: list.map(seeing.models, fn(entry) {
        catalog.CatalogModel(..entry, vision: catalog.TextOnly)
      }),
    )
  assert !blocksummary.live_admission(blind, "acme")(identity("acme"))
}

// --- the rig -------------------------------------------------------------------

type Rig {
  Rig(
    opened: Session,
    name: address.Address(blocksummary.Message),
    commits: address.Address(writer.Event),
    asked: Subject(String),
    held: Subject(#(String, Subject(Nil))),
    written: Subject(#(String, JsonValue)),
    published: Subject(bus.Event),
  )
}

type Script {
  Answering(answer: fn(String) -> Result(String, String))

  Held(label: String)
}

fn answering(text: String) -> Script {
  Answering(answer: fn(_request) { Ok(text) })
}

fn held(label: String) -> Script {
  Held(label:)
}

fn a_rig(script: Script) -> Rig {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 1000))
    as "the memory session must open"
  let asked = process.new_subject()
  let held = process.new_subject()
  let written = process.new_subject()
  let published = process.new_subject()
  let name = addresses.new()
  let commits = addresses.new()

  let summarizer =
    distill.Distiller(ask: fn(request) {
      case script {
        Answering(answer:) -> {
          process.send(asked, request)
          answer(request)
          |> option_answer
        }

        // The request's own process waits for the test to release it, on a
        // subject it created, so the test decides when the request ends.
        Held(label:) -> {
          let release = process.new_subject()
          process.send(held, #(request, release))
          let _released = process.receive(release, 5000)
          Ok(distill.Answer(text: label, usage: effects.zero_usage()))
        }
      }
    })

  let assert Ok(_started) =
    blocksummary.start(blocksummary.Wiring(
      session: opened,
      route: blocksummary.Route(provider: "acme", summarizer:),
      write: fn(cell, value) {
        process.send(written, #(cell, value))
        Ok(Nil)
      },
      publish: fn(event) { process.send(published, event) },
      pace: blocksummarybook.Pace(
        ..blocksummarybook.default_pace,
        settled_concurrency: 4,
      ),
      logger: log.discard(),
      name:,
      commits:,
    ))
    as "the summarizer machine must start"
  Rig(opened:, name:, commits:, asked:, held:, written:, published:)
}

fn option_answer(
  answer: Result(String, String),
) -> Result(distill.Answer, String) {
  case answer {
    Ok(text) -> Ok(distill.Answer(text:, usage: effects.zero_usage()))
    Error(reason) -> Error(reason)
  }
}

// Commits the entries in one transaction and hands the machine the hint the
// writer would have sent for it.
fn commit_entries(rig: Rig, entries: List(entry.Entry)) -> Nil {
  let assert Ok(committed) =
    storage.commit(
      rig.opened.store,
      Tx(writes: list.map(entries, InsertEntry), expected: []),
    )
    as "the fixture entries must commit"
  let assert Ok(Nil) =
    address.send(
      rig.commits,
      writer.Committed(ordinal: 1, seqs: committed.seqs, ts: committed.ts),
    )
    as "the machine must be bound to its commit address"
  Nil
}

fn receive_all(inbox: Subject(a), count: Int) -> List(a) {
  case count {
    0 -> []
    _ ->
      case process.receive(inbox, 2000) {
        Ok(value) -> [value, ..receive_all(inbox, count - 1)]
        Error(Nil) -> []
      }
  }
}

fn requests(rig: Rig) -> List(String) {
  case process.receive(rig.asked, 0) {
    Ok(request) -> [request, ..requests(rig)]
    Error(Nil) -> []
  }
}

fn stop(rig: Rig) -> Nil {
  case addresses.owner(rig.name) {
    Ok(pid) -> {
      process.unlink(pid)
      process.kill(pid)
    }
    Error(Nil) -> Nil
  }
}

// --- fixtures ------------------------------------------------------------------

fn an_entry(seed: Int, value: message.AgentMessage) -> entry.Entry {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 1000), seed:))
  entry.MessageEntry(
    id:,
    parent: None,
    seq: 0,
    ts: 1000,
    message: value,
    terminate: False,
  )
}

fn an_entry_id(seed: Int) -> EntryId {
  let #(id, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: 2000), seed:))
  id
}

// Writes an `op.meta` cell, which is how the machine learns the strand a
// stream runs on.
fn an_operation(opened: Session, strand: String, seed: Int) -> OpId {
  let #(id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1000), seed:))
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

fn a_request(provider: String, operation: OpId) -> effects.RequestSpec {
  effects.GenerationRequest(
    operation:,
    step_id: "step-1",
    attempt: 1,
    response_entry: an_entry_id(9),
    configuration: machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider:, model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingHigh,
      active_tool_names: [],
    ),
    context: [],
    stream_options: json.Object([]),
  )
}

fn reasoning(text: String) -> stream.StreamEvent {
  stream.Delta(delta: stream.ThinkingDelta(index: 0, thinking: text))
}

fn assistant(
  provider: String,
  content: List(message.AssistantBlock),
) -> message.AgentMessage {
  message.AssistantMessage(
    content:,
    api: "test",
    provider:,
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: effects.zero_usage(),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: Some(True),
    timestamp: 0,
  )
}

fn thinking(text: String) -> message.AssistantBlock {
  message.AssistantThinking(
    thinking: text,
    thinking_signature: None,
    redacted: False,
  )
}

fn text() -> message.AssistantBlock {
  message.AssistantText(text: "Here is the plan.", text_signature: None)
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

fn routing(roles: List(model.Role)) -> provider_gateway.Gateway {
  let identity =
    model.ResolvedModel(
      provider: "acme",
      model_id: "loom-1",
      thinking: model.ThinkingHigh,
      context_window: 100_000,
      max_output_tokens: 4096,
    )
  let gateway =
    provider_gateway.new(
      transport: provider_test.silent(),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 0),
    )
    |> provider_gateway.add_provider(provider_gateway.AnthropicProvider(
      name: "acme",
      base_url: "https://acme.invalid",
      api_key_secret: "ACME_KEY",
    ))
  list.fold(roles, gateway, fn(gateway, role) {
    provider_gateway.route(gateway, role, [identity])
  })
}

// A catalogue of two entries, `acme` and `other`, both reading images,
// routed as given.
fn a_catalogue(roles: List(#(model.Role, List(String)))) -> catalog.Catalog {
  catalog.Catalog(
    models: list.map(["acme", "other"], an_entry_named),
    roles:,
    mcp_servers: [],
  )
}

fn an_entry_named(name: String) -> catalog.CatalogModel {
  catalog.CatalogModel(
    name:,
    dialect: catalog.Anthropic,
    base_url: "https://" <> name <> ".invalid",
    api_key_env: "KEY",
    model_id: "loom-1",
    context_window: 100_000,
    max_output_tokens: 4096,
    thinking: model.ThinkingHigh,
    pricing: None,
    vision: catalog.ReadsImages,
    max_images: 8,
  )
}

fn identity(provider: String) -> machine_strand.ModelIdentity {
  machine_strand.ModelIdentity(provider:, model_id: "loom-1")
}

fn single_provider() -> fn(machine_strand.ModelIdentity) -> Bool {
  blocksummary.live_admission(
    a_catalogue([#(model.Main, ["acme"]), #(model.Summarize, ["acme"])]),
    "acme",
  )
}
