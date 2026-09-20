//// A native, provider-free review fixture for the agent workspace.
////
//// These illustrative tasks enter through the same snapshot decoder and
//// presentation reducer as an attached session. They are not provider runs.
//// Keeping the fixture executable lets a reviewer reproduce narrow layouts,
//// navigation, draft ownership, and palette behavior in a real terminal.

import core/clock
import core/codec as core_codec
import core/entry
import core/ids
import core/json
import core/message
import core/register
import etui/app
import etui/backend
import etui/backend/default
import gleam/list
import gleam/option.{None, Some}
import machine/codec
import machine/operation
import machine/strand
import tui
import tui/advisor_pending
import tui/agents
import tui/appearance
import tui/connection
import tui/internal/ffi_terminal
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import tui/workspace

type Work {
  Active(tool: String)
  Complete
  Failed
  Held
}

type Agent {
  Agent(name: String, task: String, update: String, work: Work)
}

/// Opens an illustrative captured workspace in the native etui event loop.
///
/// ## Examples
///
/// ```sh
/// gleam dev agents dark
/// gleam dev agents light
/// gleam dev agents ansi
/// gleam dev agents plain
/// ```
pub fn run(palette: String) -> Nil {
  ffi_terminal.silence_logger()
  let base =
    tui.new_model(
      connection.new_inbox(),
      workspace.Context("native UI fixture", None),
    )
  let fixture = [
    Agent(
      "main",
      "Integrate the agent workspace and preserve message targeting.",
      "Drafts now stay with their original session and strand. Checking the native layouts next.",
      Active("agent_wait"),
    ),
    Agent(
      "sub:viewport-review",
      "Review scroll anchors and per-strand reading positions.",
      "Returning to main restores the frozen transcript and its original reading position.",
      Complete,
    ),
    Agent(
      "sub:terminal-checks",
      "Exercise small terminals, Unicode names, and control sequences.",
      "One fixture exposed a clipped action label at 40 columns. The normal 80-column layout fits.",
      Failed,
    ),
    Agent(
      "sub:protocol-review",
      "Verify exact-request approval ownership across refreshes.",
      "Ready to write the review report. Waiting for permission to write the requested file.",
      Active("fs_write"),
    ),
    Agent(
      "sub:paused-review",
      "Review restart behavior without changing the running daemon.",
      "Stopped before touching the running daemon. The next message will resume this strand.",
      Held,
    ),
    Agent(
      "advisor",
      "Review the primary strand's implementation and validation claims.",
      "Keep queued advice visibly separate from advice that the primary already received.",
      Active("fs_read"),
    ),
  ]
  let cells =
    fixture
    |> list.index_map(fn(agent, index) { agent_cells(agent, index * 10 + 1) })
    |> list.flatten
  let items =
    fixture
    |> list.index_map(fn(agent, index) {
      agent_entries(agent, index * 10 + 1, base.usage)
    })
    |> list.flatten
  let metadata =
    json.Object([
      #("cells", json.Array(cells)),
      #("message_count", json.Int(list.length(items))),
      #("usage", core_codec.encode_usage(base.usage)),
      #(
        "host_run_settings",
        json.Object([
          #("queue_mode", json.String("one_at_a_time")),
          #("tool_execution", json.String("parallel")),
          #("origin", json.Null),
        ]),
      ),
      #("peers", json.Array([])),
      #("pending_inputs", json.Array([])),
    ])
  let captured =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected("native-fixture", "fixture", "fixture"),
        "review",
        message.Origin("reviewer", "Reviewer"),
        snapshot.Owner,
      ),
      100,
      metadata,
      snapshot.Window(list.reverse(items), 0, None),
      None,
    )
  let assert Ok(view) = snapshot_view.decode(captured)
    as "the native fixture must pass the shipped capture decoder"
  let initial =
    tui.Model(
      ..base,
      session: "native-fixture",
      strands: [],
      transcript: [],
      models: [],
      current_model: "fixture-model",
      palette: selected_palette(palette),
    )
    |> tui.apply_channel_update(session_channel.Captured(
      captured,
      view,
      session_channel.Requested,
    ))
  let initial =
    tui.Model(
      ..initial,
      overlay: tui.AgentInspector(agents.inspect("main")),
      notice: "illustrative fixture · no provider calls",
      diff_view: tui.DiffHidden,
      nudges: Some(advisor_pending.Board(
        "main",
        1,
        [
          "Keep exact approval ownership intact.\nThe selected preview is not permission to broaden the request.",
        ],
        1,
      )),
    )
  let _ =
    app.run_buffered_cursor_adaptive(
      default.new_with_options(backend.Options(mouse: True, paste: True)),
      initial,
      tui.view,
      tui.update,
      fn(model) { model.quit },
      tui.terminal_poll_timeout,
    )
  Nil
}

fn selected_palette(value: String) -> appearance.Palette {
  case value {
    "light" -> appearance.Light
    "ansi" -> appearance.Terminal
    "plain" -> appearance.Plain
    _ -> appearance.Dark
  }
}

fn op_id(n) {
  ids.mint_op(ids.generator(clock.fixed(n), n)).0
}

fn entry_id(n) {
  ids.mint_entry(ids.generator(clock.fixed(n), n)).0
}

fn configuration() {
  strand.StrandConfiguration(
    strand.ModelIdentity("fixture", "fixture-model"),
    strand.ThinkingHigh,
    ["fs_read"],
  )
}

fn cell(namespace, key, seq, value) {
  json.Object([
    #("namespace", json.String(register.ns_to_string(namespace))),
    #("key", json.String(key)),
    #("seq", json.Int(seq)),
    #("value", value),
  ])
}

fn agent_cells(agent: Agent, n: Int) -> List(json.JsonValue) {
  let current = case agent.work {
    Active(_) -> Some(op_id(n))
    Complete | Failed | Held -> None
  }
  let common = [
    cell(
      register.StrandConfig,
      agent.name,
      n,
      codec.encode_configuration(configuration()),
    ),
    cell(
      register.StrandLeaf,
      agent.name,
      n + 1,
      json.String(
        ids.entry_id_to_string(entry_id(
          n
          + case agent.work {
            Complete | Failed -> 2
            Active(_) | Held -> 1
          },
        )),
      ),
    ),
    cell(
      register.StrandState,
      agent.name,
      n + 1,
      codec.encode_strand_state(strand.StrandState(current, [])),
    ),
    cell(
      register.OpMeta,
      ids.op_id_to_string(op_id(n)),
      n,
      codec.encode_operation(operation.Operation(
        op_id(n),
        agent.name,
        None,
        n,
        operation.RunIntent([entry_id(n)]),
      )),
    ),
  ]
  let lifecycle = case agent.work {
    Active(_) ->
      cell(
        register.OpState,
        ids.op_id_to_string(op_id(n)),
        n + 1,
        codec.encode_state(operation.RunState(
          operation.Running,
          operation.RunSettings(
            operation.CompactionSettings(False, 0, 0),
            operation.ConsumeAll,
            operation.ConsumeAll,
            operation.Parallel,
          ),
          operation.Tools(
            operation.ToolBatch(
              entry_id(n + 1),
              configuration(),
              "fixture-step",
              [
                operation.CallEffectPending(
                  1,
                  entry_id(n + 2),
                  operation.ReplaySafe,
                ),
              ],
            ),
          ),
          operation.Inbox([], [], []),
          Some(entry_id(n + 1)),
        )),
      )
    Complete | Failed | Held ->
      cell(
        register.StrandLastResult,
        agent.name,
        n + 2,
        codec.encode_last_result(operation.RunLastResult(
          op_id(n),
          Some(entry_id(n + 1)),
          outcome(agent.work),
          Some(entry_id(n + 1)),
        )),
      )
  }
  let pending = case agent.work {
    Active("fs_write") -> [
      cell(
        register.FactCustom,
        "escalation/fixture-permission",
        n + 2,
        json.Object([
          #("id", json.String("fixture-permission")),
          #("status", json.String("pending")),
          #("tool", json.String("fs_write")),
          #(
            "preview",
            json.String(
              "Write docs/review/native-layout.md with the native layout findings.\nNo other files are included in this request.",
            ),
          ),
          #("action", json.String("fixture-action")),
          #("origin", json.Null),
          #("denial", json.Object([#("wanted", json.Array([]))])),
          #(
            "scope",
            json.Object([
              #("strand", json.String(agent.name)),
              #("operation", json.String(ids.op_id_to_string(op_id(n)))),
            ]),
          ),
        ]),
      ),
    ]
    _ -> []
  }
  list.append([lifecycle, ..common], pending)
}

fn outcome(work: Work) -> operation.RunOutcome {
  case work {
    Complete -> operation.RunCompleted(operation.CompletedByAssistant)
    Failed ->
      operation.RunFailed(operation.OperationError(
        "fixture-check",
        "Narrow action-label check failed",
        None,
      ))
    Held -> operation.RunAborted
    Active(_) -> operation.RunCompleted(operation.CompletedByAssistant)
  }
}

fn agent_entries(
  agent: Agent,
  n: Int,
  usage: message.Usage,
) -> List(snapshot.Item) {
  let prompt =
    entry.MessageEntry(
      entry_id(n),
      None,
      n,
      n,
      message.UserMessage([message.UserText(agent.task, None)], n, None),
      False,
    )
  let tools = case agent.work {
    Active(tool) -> [
      message.AssistantToolCall(message.ToolCall(
        "fixture-call",
        tool,
        case tool {
          "agent_wait" ->
            json.Object([
              #(
                "handles",
                json.Array([
                  json.String(
                    "sub:terminal-checks#" <> ids.op_id_to_string(op_id(21)),
                  ),
                ]),
              ),
            ])
          "fs_write" ->
            json.Object([#("path", json.String("docs/review/native-layout.md"))])
          _ ->
            json.Object([#("path", json.String("packages/tui/src/tui.gleam"))])
        },
        None,
        None,
      )),
    ]
    Complete | Failed -> [
      message.AssistantToolCall(message.ToolCall(
        "fixture-call",
        "bash",
        json.Object([#("command", json.String("make check-tui"))]),
        None,
        None,
      )),
    ]
    Held -> []
  }
  let response =
    entry.MessageEntry(
      entry_id(n + 1),
      Some(entry_id(n)),
      n + 1,
      n + 1,
      message.AssistantMessage(
        [message.AssistantText(agent.update, None), ..tools],
        "fixture",
        "fixture",
        "fixture-model",
        None,
        None,
        None,
        usage,
        message.Stop,
        None,
        None,
        None,
        None,
        n + 1,
      ),
      False,
    )
  let results = case agent.work {
    Complete | Failed -> [
      snapshot.Loaded(
        entry.MessageEntry(
          entry_id(n + 2),
          Some(entry_id(n + 1)),
          n + 2,
          n + 2,
          message.ToolResultMessage(
            "fixture-call",
            "bash",
            [
              message.ToolResultText(
                case agent.work {
                  Failed ->
                    "Layout assertion failed at 40 columns.\nThe approval action label was clipped."
                  _ -> "The viewport and reading-position checks passed."
                },
                None,
              ),
            ],
            None,
            None,
            None,
            agent.work == Failed,
            n + 2,
          ),
          False,
        ),
        0,
      ),
    ]
    Active(_) | Held -> []
  }
  list.append(
    [snapshot.Loaded(prompt, 0), snapshot.Loaded(response, 0)],
    results,
  )
}
