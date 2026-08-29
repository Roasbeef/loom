//// Memory stage M1's exit criterion, end to end: **a fresh session
//// finds, by search, a decision made in a previous session's
//// compacted-away history.**
////
//// Everything load-bearing here is the real thing. Two SQLite session
//// files, each opened through `runtime/api` over `client/wiring`'s
//// production effects and compaction hooks. One search index file,
//// shared, owned by a real `client/history` holder per session. Sync is
//// driven the way `client/serve` drives it — a second writer subscriber
//// poking the holder after every commit — and never by this test
//// calling `synchronize`, because a test that synced by hand would pass
//// with the subscriber removed. The tool is the registered
//// `history_search`, dispatched through a real registry.
////
//// What is scripted is the provider, and only the provider: it answers
//// turns and summaries so a compaction happens without a network. The
//// compaction it produces is the machine's own.

import broker/broker
import broker/exec
import broker/policy
import broker/token
import client/escalate
import client/history
import client/serve
import client/summaries
import client/system_prompt
import client/wiring
import core/clock
import core/entry
import core/ids
import core/json
import core/message.{type AgentMessage}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/gateway as provider_gateway
import provider/model
import provider/secret
import provider/stream
import runtime/api
import runtime/effects
import runtime/hooks
import session/session
import simplifile
import storage/storage
import support/provider as provider_test
import tools/history as history_tool
import tools/tool

// The decision session A takes, and the word session B goes looking for.
// Short, so compaction's keep-recent budget evicts it rather than
// retaining it in the tail.
const decision = "we settled on msgpack for the durable envelope"

// A decision of session B's own, for the within-session scope row.
const local_decision = "the reviewer strand owns the changelog"

const window = 10_000

const reserve = 2000

const keep_recent = 500

const scripted_summary = "[from the provider] earlier work, summarized"

// A message of roughly 400 estimated tokens, so the keep-recent budget
// is a budget rather than a formality.
fn bulky(label: String) -> String {
  label <> ": " <> string.repeat("context ", 200)
}

// --- the exit criterion ----------------------------------------------------

pub fn a_fresh_session_finds_a_compacted_away_decision_test() {
  let root = fresh_root("recall")
  let index = root <> "/loom-search.db"

  // --- session A: take the decision, let it be compacted away ---
  let assert Ok(first) = open_session(root <> "/a.db", index, 21)
    as "session A must open"
  let assert Ok(taken) = api.prompt(first.runtime, [user(decision)])
  let assert Ok(_settled) =
    api.await_result(first.runtime, taken, within_ms: 5000)
  let assert Ok(more) = api.prompt(first.runtime, [user(bulky("keep going"))])
  let assert Ok(_settled) =
    api.await_result(first.runtime, more, within_ms: 5000)

  // The decision really is out of the live context: a compaction landed
  // and the projection no longer carries it.
  let assert [entry.CompactionEntry(..)] = compactions(first.session)
    as "the second turn's usage must have crossed the threshold"
  assert projected_text(first.session) |> string.contains(decision) == False

  // And it really is in the index, put there by the commit hints alone.
  // Nothing in this test calls `synchronize`: with the subscriber
  // disconnected, this wait expires and the test fails.
  assert await_indexed(first.holder, "msgpack", 5000)
  let first_id = api.session_id(first.runtime)
  close_session(first)

  // --- session B: a fresh session file over the same index ---
  let assert Ok(second) = open_session(root <> "/b.db", index, 33)
    as "session B must open"
  let assert Ok(local) = api.prompt(second.runtime, [user(local_decision)])
  let assert Ok(_settled) =
    api.await_result(second.runtime, local, within_ms: 5000)
  assert await_indexed(second.holder, "changelog", 5000)

  // The exit criterion. Through the registered tool, over the real seam.
  let found = search(second, "msgpack", None)
  assert found.is_error == False
  let rendered = text_of(found)
  assert string.contains(rendered, "[msgpack]")
  // Named by session A's canonical id, which is how a hit says where it
  // came from.
  assert string.contains(rendered, ids.session_id_to_string(first_id))

  // --- the within-session scope row ---
  // Session B's own scope sees its own decision and not session A's.
  let scoped = search(second, "msgpack", Some("session"))
  assert scoped.is_error == False
  assert string.contains(text_of(scoped), "no matches")
  let own = search(second, "changelog", Some("session"))
  assert own.is_error == False
  assert string.contains(text_of(own), "[changelog]")
  assert string.contains(
    text_of(own),
    ids.session_id_to_string(api.session_id(second.runtime)),
  )
  close_session(second)
}

// The registration gate, on the real boot path's own function: a host
// with an index registers `history_search`, one without does not.
pub fn the_tool_is_registered_only_when_the_index_opened_test() {
  let name = process.new_name(prefix: "loom_recall_registry")
  let with_index =
    serve.registry(None, None, Some(history.seam(name, timeout_ms: 1000)), None)
  assert list.contains(tool.names(with_index), history_tool.tool_name)
  let without = serve.registry(None, None, None, None)
  assert list.contains(tool.names(without), history_tool.tool_name) == False
}

// --- the rig ---------------------------------------------------------------

type Live {
  Live(
    runtime: api.Runtime,
    session: session.Session,
    holder: Name(history.Message),
    registry: tool.Registry,
  )
}

// One session, opened the way `client/serve` opens one: production
// wiring, production compaction hooks, an index holder under a name, and
// a second writer subscriber poking it after every commit.
fn open_session(
  session_path: String,
  index: String,
  seed: Int,
) -> Result(Live, String) {
  use opened <- result.try(
    session.open_sqlite(
      path: session_path,
      owner: "memory-recall-test",
      lease_ttl_ms: 60_000,
      clock: a_clock(),
    )
    |> result.map_error(fn(error) {
      "the session did not open: " <> string.inspect(error)
    }),
  )
  use entropy <- result.try(start_entropy(seed))
  use sink <- result.try(
    summaries.start()
    |> result.map_error(fn(_error) { "the summary sink did not start" }),
  )
  let holder = process.new_name(prefix: "loom_recall_holder")
  let pulls = process.new_name(prefix: "loom_recall_pulls")
  use config <- result.try(wiring_config(opened, sink, index, holder))
  use turns <- result.try(start_turns())
  use summaries_seen <- result.try(start_turns())
  let effects_record =
    effects.Effects(
      clock: a_clock(),
      entropy:,
      timers: effects.real_timers(),
      provider: wiring.recording_summaries(
        scripted_provider(turns, summaries_seen),
        into: sink,
      ),
      tools: refusing_tools(),
      hooks: wiring.compaction_hooks(config),
    )
  let options =
    api.default_options(
      machine_strand.StrandConfiguration(
        model: machine_strand.ModelIdentity(
          provider: "acme",
          model_id: "loom-1",
        ),
        thinking_level: machine_strand.ThinkingOff,
        active_tool_names: [],
      ),
    )
  use runtime <- result.try(api.open(
    opened,
    effects_record,
    api.Options(
      ..options,
      poll_interval_ms: 20,
      settings: operation.RunSettings(
        ..options.settings,
        compaction: compaction_settings(),
      ),
      // The whole sync path, in one line: the writer publishes, the
      // subscriber pokes, the holder pulls.
      subscribers: [process.named_subject(pulls)],
    ),
  ))
  use _holder <- result.try(
    history.start(history.over_session(
      name: holder,
      path: index,
      session: api.session_id(runtime),
      store: opened.store,
      generation: history.sqlite_generation(session_path),
      timeout_ms: history.default_timeout_ms,
    ))
    |> result.map_error(fn(_error) { "the index holder did not start" }),
  )
  use _pulls <- result.try(
    history.commit_pull(to: holder, as_name: pulls)
    |> result.map_error(fn(_error) { "the commit subscriber did not start" }),
  )
  Ok(Live(runtime:, session: opened, holder:, registry: config.registry))
}

fn close_session(live: Live) -> Nil {
  history.stop(live.holder)
  let _closed = api.close(live.runtime)
  Nil
}

fn wiring_config(
  opened: session.Session,
  sink: summaries.Summaries,
  index: String,
  holder: Name(history.Message),
) -> Result(wiring.Config, String) {
  use loaded <- result.try(system_prompt.summary_pack(None))
  use broker_actor <- result.try(
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 0),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    |> result.map_error(fn(_error) { "the broker did not start" }),
  )
  let workspace = "/nonexistent/loom-memory-recall"
  let base = serve.protecting_index(policy.workspace_default(workspace), index)
  Ok(
    wiring.Config(
      gateway: routed_gateway(),
      role: model.Main,
      facts: fn(_identity) { Error(Nil) },
      system: Some("you are an agent"),
      api: "acme-api",
      fallback_context_window: window,
      fallback_max_output_tokens: 1024,
      provider_timeout_ms: 2000,
      summary_role: model.Summarize,
      summary_pack: loaded.0,
      summaries: sink,
      session: opened,
      compaction: compaction_settings(),
      broker: broker_actor,
      broker_timeout_ms: 1000,
      registry: serve.registry(
        None,
        None,
        Some(history.seam(holder, timeout_ms: history.default_timeout_ms)),
        None,
      ),
      workspace:,
      blob_root: workspace <> "/.blobs",
      base_policy: base,
      escalations: escalate.none(),
      demand: exec.BestEffort,
      env: [],
      clock: clock.fixed(at: 0),
      entropy: fn() { 11 },
    ),
  )
}

fn compaction_settings() -> operation.CompactionSettings {
  operation.CompactionSettings(
    enabled: True,
    reserve_tokens: reserve,
    keep_recent_tokens: keep_recent,
  )
}

// --- asking the index ------------------------------------------------------

// One `history_search` call, dispatched through the registry the wiring
// was built with — the same table the effect plane dispatches through.
fn search(
  live: Live,
  query: String,
  scope: Option(String),
) -> tool.ToolOutcome {
  let arguments = case scope {
    None -> [#("query", json.String(query))]
    Some(named) -> [
      #("query", json.String(query)),
      #("scope", json.String(named)),
    ]
  }
  tool.dispatch(
    live.registry,
    a_ctx(),
    history_tool.tool_name,
    json.Object(arguments),
  )
}

// Waits for the commit-driven sync to land a term in the index. The wait
// is the assertion: nothing here forces a sync, so a hint that never
// arrives is a term that never appears.
fn await_indexed(
  holder: Name(history.Message),
  term: String,
  left_ms: Int,
) -> Bool {
  let seam = history.seam(holder, timeout_ms: 2000)
  case seam.search(term, 5, history_tool.Repository) {
    Ok([_hit, ..]) -> True
    Ok([]) | Error(_refused) ->
      case left_ms <= 0 {
        True -> False
        False -> {
          process.sleep(25)
          await_indexed(holder, term, left_ms - 25)
        }
      }
  }
}

// --- reading the tree ------------------------------------------------------

fn compactions(opened: session.Session) -> List(entry.Entry) {
  case storage.scan_entries(opened.store, storage.entry_scan()) {
    Ok(entries) ->
      list.filter(entries, fn(item) {
        case item {
          entry.CompactionEntry(..) -> True
          _other -> False
        }
      })
    Error(_unreadable) -> []
  }
}

// What the strand would actually send: the projection the compaction
// hooks build, which is where a compacted-away message is *gone*.
fn projected_text(opened: session.Session) -> String {
  hooks.project(opened, "main").messages
  |> list.map(rendered)
  |> string.join("\n")
}

fn rendered(injected: AgentMessage) -> String {
  case injected {
    message.UserMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.UserText(text:, ..) -> Ok(text)
          message.UserImage(..) -> Error(Nil)
        }
      })
      |> string.join(" ")
    message.AssistantMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.AssistantText(text:, ..) -> Ok(text)
          message.AssistantThinking(..) | message.AssistantToolCall(..) ->
            Error(Nil)
        }
      })
      |> string.join(" ")
    message.ToolResultMessage(..) | message.CustomMessage(..) -> ""
  }
}

fn text_of(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      message.ToolResultImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

// --- the scripted provider -------------------------------------------------

fn scripted_provider(
  turns: Subject(Subject(Int)),
  summaries_seen: Subject(Subject(Int)),
) -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 2000, request: fn(spec) {
    let events = process.new_subject()
    case spec {
      effects.SummaryRequest(..) -> {
        let _attempt = next_turn(summaries_seen)
        settle(events, answer(scripted_summary, 40))
      }
      effects.PollRequest(..) -> settle(events, answer("polled", 1))
      effects.GenerationRequest(..) ->
        case next_turn(turns) {
          // Turn one settles under the threshold; turn two reports usage
          // above it, so the checkpoint after it compacts.
          2 -> settle(events, answer(bulky("continuing"), window))
          _other -> settle(events, answer(bulky("answer"), 100))
        }
    }
    stream.StreamHandle(events:, cancel: fn() { Nil })
  })
}

fn settle(events: Subject(stream.StreamEvent), reply: AgentMessage) -> Nil {
  case stream.settle(reply) {
    Ok(settled) ->
      process.send(
        events,
        stream.Settled(message: settled, usage: usage_of(reply)),
      )
    Error(Nil) ->
      process.send(
        events,
        stream.Failed(error: stream.TransportFailed(
          reason: "the scripted settlement was not settleable",
        )),
      )
  }
}

fn usage_of(reply: AgentMessage) -> message.Usage {
  case reply {
    message.AssistantMessage(usage:, ..) -> usage
    _other -> effects.zero_usage()
  }
}

fn answer(text: String, tokens: Int) -> AgentMessage {
  message.AssistantMessage(
    content: [message.AssistantText(text:, text_signature: None)],
    api: "acme-api",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: usage(tokens),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: Some(True),
    timestamp: 0,
  )
}

fn usage(tokens: Int) -> message.Usage {
  message.Usage(
    input: tokens,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: tokens,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

fn routed_gateway() -> provider_gateway.Gateway {
  let identity =
    model.ResolvedModel(
      provider: "acme",
      model_id: "loom-1",
      thinking: model.ThinkingOff,
      context_window: window,
      max_output_tokens: 1024,
    )
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
  |> provider_gateway.route(model.Main, [identity])
  |> provider_gateway.route(model.Summarize, [identity])
}

fn refusing_tools() -> effects.ToolSurface {
  effects.ToolSurface(
    clear: fn(_query) {
      effects.ClearanceRefused(reason: "no jailed tools in this harness")
    },
    run: fn(_run) {
      effects.ToolFailed(reason: "no jailed tools in this harness")
    },
    replay_still_safe: fn(_name) { False },
    execution_mode: fn(_name) { effects.ExclusiveExecution },
  )
}

// --- small helpers ---------------------------------------------------------

fn a_clock() -> clock.Clock {
  clock.stepping(from: 1_756_000_000_000, by: 3)
}

fn user(text: String) -> AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

// A `Ctx` the history tool can be dispatched with. It reads none of it —
// the index is served harness-side through the seam — but a real
// dispatch takes a real one.
fn a_ctx() -> tool.Ctx {
  let workspace = "/nonexistent/loom-memory-recall"
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 3))
  tool.Ctx(
    workspace:,
    strand: "main",
    op_id:,
    step_id: "step-1",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.BestEffort,
    env: [],
    clock: clock.fixed(at: 0),
    filesystem: dead_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
  )
}

fn dead_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
    rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
  )
}

// A directory nothing survives into: both session files and the index
// start empty on every run, which is what makes "a fresh session" mean
// what it says.
fn fresh_root(lane: String) -> String {
  let root = "build/test_db/memory-recall-" <> lane
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the test root must be creatable"
  // Checked rather than assumed. Ids here are deterministic — a seeded
  // generator over a fixed clock — so an index left behind by the last
  // run holds rows indistinguishable from this run's, and a stale one
  // would let this test pass with the sync path removed entirely. That
  // is not a hypothetical: it happened once while the mutation evidence
  // for this file was being taken.
  let assert Ok(False) = simplifile.is_file(root <> "/loom-search.db")
    as "the search index must not survive from the last run"
  root
}

fn start_turns() -> Result(Subject(Subject(Int)), String) {
  case
    actor.new(0)
    |> actor.on_message(fn(count, reply: Subject(Int)) {
      process.send(reply, count + 1)
      actor.continue(count + 1)
    })
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(_error) -> Error("the turn counter did not start")
  }
}

fn next_turn(turns: Subject(Subject(Int))) -> Int {
  process.call(turns, waiting: 1000, sending: fn(reply) { reply })
}

fn start_entropy(seed: Int) -> Result(fn() -> Int, String) {
  case
    actor.new(seed)
    |> actor.on_message(fn(next, reply: Subject(Int)) {
      process.send(reply, next)
      actor.continue(next + 1)
    })
    |> actor.start
  {
    Ok(counter) ->
      Ok(fn() {
        2_000_000
        + process.call(counter.data, waiting: 1000, sending: fn(reply) { reply })
        * 15_485_863
      })
    Error(_error) -> Error("the entropy counter did not start")
  }
}
