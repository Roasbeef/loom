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
import tui/goal_view
import tui/internal/ffi_terminal
import tui/notes_view
import tui/protocol
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import tui/workspace
import tui/worktree_view

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
      diff_view: tui.DiffVisible,
      worktree: fixture_worktree(),
      note_board: Some(fixture_notes()),
      note_selected: Some("plan"),
      goal: Some(fixture_goal()),
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
      fixture_update,
      fn(model) { model.quit },
      tui.terminal_poll_timeout,
    )
  Nil
}

fn fixture_goal() -> goal_view.Board {
  goal_view.Pinned(
    status: goal_view.Paused(by: goal_view.ByOperator),
    because: "you paused this illustrative goal before native review",
    objective: "Finish the native agent workspace, preserve every session draft, and verify compact layouts.",
    token_budget: 400_000,
    tokens_used: 51_200,
    cost_used: 0.42,
    continuations: 3,
    created_ms: 1_000_000,
    updated_ms: 1_060_000,
    reviewer_note: Some(
      "The focused goal card still needs review at 40 columns before the session is complete.",
    ),
    check: Some("bash scripts/test.sh tui --match goal"),
    last_check: Some(goal_view.CheckRun(
      command: "bash scripts/test.sh tui --match goal",
      status: Some(0),
      not_finished: None,
      output: "676 tests, 0 failures",
      ran_at_ms: 1_055_000,
    )),
    observed_at_ms: 1_120_000,
  )
}

// These boards are illustrative observations, not replies from a daemon.
// The production reducer still owns all navigation and recipient changes.
fn fixture_update(event: backend.InputEvent, model: tui.Model) -> tui.Model {
  let changed = tui.update(event, model)
  let target = case changed.overlay, changed.notes_open {
    tui.AgentInspector(agents.Inspector(detail: agents.Notes, selected:, ..)), _
    -> Some(selected)
    _, True -> Some(changed.active_strand)
    _, False -> None
  }
  case target {
    None -> changed
    Some(target) -> {
      let board = case target {
        "main" -> fixture_notes()
        _ ->
          notes_view.Board(target, 42, 2, [
            notes_view.Note(
              "findings",
              40,
              "{\"summary\":\"Recipient ownership stays explicit\",\"checks\":[\"Inspecting a worker keeps main as recipient\",\"Late replies retain their original note owner\"]}",
              notes_view.Complete,
            ),
            notes_view.Note(
              "next",
              42,
              "Report the remaining narrow-layout findings to main.\n\nThis is illustrative fixture data.",
              notes_view.Complete,
            ),
          ])
      }
      case changed.note_board == Some(board) {
        True -> changed
        False ->
          changed
          |> tui.apply_channel_update(
            session_channel.Auxiliary(protocol.NotesSnapshot(board)),
          )
          |> tui.update(backend.Tick, _)
      }
    }
  }
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

fn fixture_notes() -> notes_view.Board {
  notes_view.Board("main", 42, 2, [
    notes_view.Note(
      "plan",
      41,
      "{\"goal\":\"Preserve recipient ownership\",\"next\":[\"Review send receipts\",\"Check narrow layout\"]}",
      notes_view.Complete,
    ),
    notes_view.Note(
      "evidence",
      42,
      "{\"fixture\":\"provider-free\",\"coverage\":[\"started\",\"steered\",\"failed\"]}",
      notes_view.Complete,
    ),
  ])
}

fn fixture_worktree() -> worktree_view.State {
  worktree_view.State(
    "fixture",
    None,
    Some(worktree_view.Board(
      7,
      42,
      "fixture-head",
      [
        worktree_view.File(
          "docs/review/native-layout.md",
          "A",
          " ",
          "+native agent workspace findings\n",
          "text",
          "complete",
        ),
        worktree_view.File(
          "packages/tui/src/tui.gleam",
          " ",
          "D",
          "-legacy agent overlay path\n",
          "text",
          "complete",
        ),
      ],
      2,
      0,
      "complete",
      worktree_view.Committed("Fixture commit view", "", "complete"),
    )),
    0,
    worktree_view.Composer,
    worktree_view.Settled,
    "captured fixture worktree · 1 added · 1 deleted",
  )
}

fn send_calls(agent: String) -> List(message.AssistantBlock) {
  case agent {
    "main" -> [
      message.AssistantToolCall(message.ToolCall(
        "send-main-to-protocol",
        "agent_send",
        json.Object([
          #("to", json.String("sub:protocol-review")),
          #(
            "message",
            json.String(
              "Please verify the approval ownership path.\nRecord the exact request owner and the operation handle.\nReply with the observed delivery state.",
            ),
          ),
        ]),
        None,
        None,
      )),
    ]
    "sub:protocol-review" -> [
      message.AssistantToolCall(message.ToolCall(
        "send-protocol-to-main",
        "agent_send",
        json.Object([
          #("to", json.String("main")),
          #(
            "message",
            json.String(
              "Approval ownership is still exact.\nThe request belongs to sub:protocol-review.\nThe main strand may continue after the recorded decision.",
            ),
          ),
        ]),
        None,
        None,
      )),
    ]
    _ -> []
  }
}

fn send_results(agent: String, n: Int) -> List(snapshot.Item) {
  case agent {
    "main" -> [
      send_result(
        n,
        "send-main-to-protocol",
        "sub:protocol-review",
        "started",
        "Delivered to sub:protocol-review and started its active operation.",
      ),
    ]
    "sub:protocol-review" -> [
      send_result(
        n,
        "send-protocol-to-main",
        "main",
        "steered",
        "Delivered to main and steered its running turn.",
      ),
    ]
    _ -> []
  }
}

fn send_result(
  n: Int,
  call_id: String,
  target: String,
  delivery: String,
  text: String,
) -> snapshot.Item {
  snapshot.Loaded(
    entry.MessageEntry(
      entry_id(n + 3),
      Some(entry_id(n + 1)),
      n + 3,
      n + 3,
      message.ToolResultMessage(
        call_id,
        "agent_send",
        [message.ToolResultText(text <> "\nTarget: " <> target, None)],
        Some(json.Object([#("delivery", json.String(delivery))])),
        None,
        None,
        False,
        n + 3,
      ),
      False,
    ),
    0,
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
            Active(_) ->
              case agent.name {
                "main" | "sub:protocol-review" -> 3
                _ -> 1
              }
            Held -> 1
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
              json.to_string(
                json.Object([
                  #("path", json.String("docs/review/native-layout.md")),
                  #(
                    "content",
                    json.String(
                      "Native layout checks passed.\nApproval keeps the transcript visible.\n",
                    ),
                  ),
                ]),
              ),
            ),
          ),
          #("action", json.String("fixture-action")),
          #("origin", json.Null),
          #(
            "denial",
            json.Object([
              #(
                "wanted",
                json.Array([
                  json.Object([
                    #("grant", json.String("writable_root")),
                    #("path", json.String("docs/review/native-layout.md")),
                  ]),
                ]),
              ),
            ]),
          ),
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
    Active(tool) ->
      list.append(send_calls(agent.name), [
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
              json.Object([
                #("path", json.String("docs/review/native-layout.md")),
                #(
                  "content",
                  json.String(
                    "Native layout checks passed.\nApproval keeps the transcript visible.\n",
                  ),
                ),
              ])
            _ ->
              json.Object([#("path", json.String("packages/tui/src/tui.gleam"))])
          },
          None,
          None,
        )),
      ])
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
    Active(_) -> send_results(agent.name, n)
    Held -> []
  }
  list.append(
    [snapshot.Loaded(prompt, 0), snapshot.Loaded(response, 0)],
    results,
  )
}
