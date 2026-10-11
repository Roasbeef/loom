//// Context accounting distinguishes a current provider baseline from component
//// estimates and from usage copied across a compaction boundary. The production
//// read uses a real session so an empty or missing strand cannot fake success.

import broker/policy
import client/context_view
import core/accounting
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import core/tx
import core/usage_evidence
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation
import machine/strand
import runtime/hooks
import session/session
import session_view/context_view as terminal
import storage/storage
import support/internal/ffi_memory
import support/tool_registry
import tools/tool

fn user(text) {
  message.UserMessage([message.UserText(text, None)], 0, None)
}

fn answer(tokens) {
  message.AssistantMessage(
    content: [message.AssistantText("done", None)],
    api: "test",
    provider: "test",
    model: "test",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: message.Usage(
      ..accounting.unknown_usage(usage_evidence.Other),
      input: tokens - 1,
      output: 1,
      total_tokens: tokens,
    ),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 1,
  )
}

fn field(value, name) {
  let assert json.Object(fields) = value as "the observation is an object"
  let assert Ok(value) = list.key_find(fields, name) as "the named field exists"
  value
}

fn board(projected, items) {
  context_view.board(
    "main",
    12,
    strand.ModelIdentity("test", "large"),
    10_000,
    operation.CompactionSettings(True, 2000, 1000),
    projected,
    items,
  )
}

pub fn provider_total_includes_static_context_exactly_once_test() {
  let projected =
    hooks.uncompacted([
      user("old input"),
      answer(7000),
      user("abcdefghijklmnop"),
    ])
  let items =
    context_view.inventory(
      string.repeat("s", 8000),
      tool.registry([]),
      [],
      projected.messages,
    )
  let assert Ok(result) = board(projected, items)
    as "a valid window can be observed"
  assert field(result, "used_tokens") == json.Int(7004)
  assert field(result, "compaction_used_tokens") == json.Int(7004)
  assert field(result, "basis") == json.String("reported_plus_estimate")
  assert field(result, "checkpoint_at") == json.Int(8000)
  assert field(result, "categories")
    == json.Array([
      json.Object([
        #("name", json.String("System prompt")),
        #("tokens", json.Int(2000)),
      ]),
      json.Object([#("name", json.String("Tools")), #("tokens", json.Int(0))]),
      json.Object([#("name", json.String("Messages")), #("tokens", json.Int(7))]),
    ])
}

pub fn carried_usage_cannot_price_the_context_after_compaction_test() {
  let projected =
    hooks.Projected(
      [user("summary!"), answer(9000), user("new!")],
      2,
      Some("summary!"),
      list.repeat(None, 3),
      None,
      None,
    )
  let items =
    context_view.inventory(
      "system!!",
      tool.registry([]),
      [],
      projected.messages,
    )
  let assert Ok(result) = board(projected, items)
    as "the compacted context is observable"
  assert field(result, "basis") == json.String("estimated")
  assert field(result, "used_tokens") == json.Int(6)
  assert field(result, "compaction_used_tokens") == json.Int(4)
}

pub fn only_active_unique_tool_definitions_are_priced_test() {
  let registry = tool_registry.built_in(None, None, None, None, None)
  let items =
    context_view.inventory("instructions", registry, ["grep", "bash", "grep"], [
      user("loaded skill text"),
    ])
  assert list.map(items, fn(item) { item.name })
    == [
      "Pinned prompt (includes embedded instructions)", "bash", "grep",
      "1. User / injected context",
    ]
  assert list.all(items, fn(item) { item.tokens > 0 })
}

pub fn omitted_detail_preserves_totals_and_escaped_byte_bound_test() {
  let items =
    list.repeat(
      context_view.Item("Tools", string.repeat("\"\\\u{1f600}", 100), 20),
      2000,
    )
  let assert Ok(result) = board(hooks.uncompacted([]), items)
    as "detail can be truncated"
  assert field(result, "used_tokens") == json.Int(40_000)
  let assert json.Int(omitted) = field(result, "items_omitted")
    as "omission is explicit"
  assert omitted > 0
  let assert json.Object(fields) = result
    as "the gateway adds its request identity"
  let ready =
    json.Object([
      #("status", json.String("ready")),
      #("request_id", json.Int(8)),
      ..fields
    ])
  assert string.byte_size(json.to_string(ready)) < 48_000
  let assert Ok(terminal.Ready(decoded)) = terminal.decode(ready)
    as "the production terminal accepts the bounded board"
  assert decoded.omitted == omitted
  assert decoded.used == 40_000
}

pub fn invalid_window_never_manufactures_a_percentage_test() {
  assert context_view.board(
      "main",
      1,
      strand.ModelIdentity("test", "missing"),
      0,
      operation.CompactionSettings(False, 0, 0),
      hooks.uncompacted([]),
      [],
    )
    == Error("context window is unavailable")
}

pub fn server_reads_the_active_branch_and_refuses_an_unknown_strand_test() {
  let assert Ok(opened) =
    session.open_memory(clock.stepping(1_756_000_000_000, 1))
    as "the test owns a real session"
  let assert Ok(Nil) =
    session.ensure_strand(
      opened,
      "main",
      strand.StrandConfiguration(
        strand.ModelIdentity("test", "large"),
        strand.ThinkingOff,
        [],
      ),
    )
    as "the strand is initialized through production boot bookkeeping"
  let read =
    context_view.reader(
      opened,
      "pinned prompt",
      tool.registry([]),
      fn(_) { 20_000 },
      operation.CompactionSettings(False, 0, 0),
    )
  let assert Ok(empty) = read("main")
    as "an initialized empty strand has a real static context"
  assert field(empty, "used_tokens") == json.Int(3)
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1), 93))
  let assert Ok(_) =
    storage.commit(
      opened.store,
      tx.Tx(
        [
          tx.InsertEntry(entry.MessageEntry(
            id,
            None,
            0,
            0,
            user("context branch marker"),
            False,
          )),
          tx.SetRegister(
            register.StrandLeaf,
            "main",
            register.leaf_value(Some(id)),
          ),
        ],
        [],
      ),
    )
    as "the durable branch and leaf publish together"
  let assert Ok(observed) = read("main")
    as "the complete durable branch is observed"
  assert field(observed, "items_total") == json.Int(2)
  assert field(observed, "used_tokens") == json.Int(8)
  assert field(observed, "model") == json.String("test/large")
  assert read("missing") == Error("context strand is unavailable")
  let _ = session.close(opened)
}

// Dynamic executor data must remain observable through execution so the
// capture premise measures real heap terms rather than shared literals.
fn context_tool(name: String, words: Int) -> tool.Tool {
  let payload = list.repeat(#(name, name), words)
  tool.Tool(
    name:,
    description: "metadata retained independently of its executor",
    prompt_snippet: None,
    schema: tool.object_schema([], []),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: policy.workspace_default,
    run: fn(_ctx, _arguments) {
      tool.ToolOutcome(
        content: [message.ToolResultText(string.inspect(payload), None)],
        details: None,
        is_error: False,
        terminate: tool.ContinueRun,
      )
    },
  )
}

fn context_registry(words: Int) -> tool.Registry {
  tool.registry([context_tool("alpha", words), context_tool("zeta", words)])
}

/// The retained reader scales with descriptions, not executable payloads.
pub fn context_reader_does_not_copy_tool_executors_test() {
  let assert Ok(opened) = session.open_memory(clock.fixed(1))
    as "the capture fixture owns its session"
  let light = context_registry(1)
  let heavy = context_registry(4096)
  let small =
    context_view.reader(
      opened,
      "system",
      light,
      fn(_) { 1000 },
      operation.CompactionSettings(False, 0, 0),
    )
  let large =
    context_view.reader(
      opened,
      "system",
      heavy,
      fn(_) { 1000 },
      operation.CompactionSettings(False, 0, 0),
    )

  // The same number of tools and identical metadata isolate executor growth.
  assert ffi_memory.flat_words(heavy) > ffi_memory.flat_words(light) + 8192
  assert ffi_memory.flat_words(large) == ffi_memory.flat_words(small)
  assert large("missing") == Error("context strand is unavailable")
  let _ = session.close(opened)
}

/// A retained reader follows durable active names and the registry's last entry.
pub fn context_reader_preserves_definitions_and_current_selection_test() {
  let assert Ok(opened) = session.open_memory(clock.fixed(1))
    as "the projection fixture owns its session"
  let configuration =
    strand.StrandConfiguration(
      strand.ModelIdentity("test", "large"),
      strand.ThinkingOff,
      ["zeta", "missing", "alpha", "zeta"],
    )
  let assert Ok(Nil) = session.ensure_strand(opened, "main", configuration)
    as "the selected tools belong to a real strand"
  let old = context_tool("alpha", 1)
  let newer =
    tool.Tool(
      ..old,
      description: "the replacement description",
      schema: tool.object_schema(
        [#("value", json.Object([#("type", json.String("string"))]))],
        ["value"],
      ),
    )
  let registry = tool.registry([old, context_tool("zeta", 1), newer])
  let window = fn(_) { 20_000 }
  let settings = operation.CompactionSettings(False, 0, 0)
  let read = context_view.reader(opened, "system", registry, window, settings)
  assert read("main")
    == context_view.read(opened, "main", "system", registry, window, settings)
  let items =
    context_view.inventory(
      "system",
      registry,
      configuration.active_tool_names,
      [],
    )
  assert list.map(items, fn(item) { item.name })
    == ["Pinned prompt (includes embedded instructions)", "alpha", "zeta"]
  assert context_view.inventory("system", registry, ["alpha"], [])
    == context_view.inventory("system", tool.registry([newer]), ["alpha"], [])

  // Independent fixture JSON lengths are 184 for the replacement alpha and
  // 171 for zeta. Dividing each by four preserves both description and schema;
  // comparing projection paths alone would let both lose the same metadata.
  assert items
    == [
      context_view.Item(
        "System prompt",
        "Pinned prompt (includes embedded instructions)",
        1,
      ),
      context_view.Item("Tools", "alpha", 46),
      context_view.Item("Tools", "zeta", 42),
    ]
  let assert Ok(initial) = read("main")
    as "the reader exposes the independently accounted tool metadata"
  assert field(initial, "items_total") == json.Int(3)
  assert field(initial, "used_tokens") == json.Int(89)
  assert field(initial, "categories")
    == json.Array([
      json.Object([
        #("name", json.String("System prompt")),
        #("tokens", json.Int(1)),
      ]),
      json.Object([
        #("name", json.String("Tools")),
        #("tokens", json.Int(88)),
      ]),
      json.Object([
        #("name", json.String("Messages")),
        #("tokens", json.Int(0)),
      ]),
    ])

  // Reusing the callback must not reuse the earlier active-tool selection.
  let assert Ok(_) =
    storage.commit(
      opened.store,
      tx.Tx(
        [
          tx.SetRegister(
            register.StrandConfig,
            "main",
            register.value(codec.encode_configuration(
              strand.StrandConfiguration(..configuration, active_tool_names: [
                "zeta",
              ]),
            )),
          ),
        ],
        [],
      ),
    )
    as "the next observation reads a changed durable configuration"
  assert read("main")
    == context_view.read(opened, "main", "system", registry, window, settings)
  let assert Ok(observed) = read("main") as "the changed selection is readable"
  assert field(observed, "items_total") == json.Int(2)
  let _ = session.close(opened)
}
