//// Context inspection reads one captured configuration and immutable branch.
//// It neither calls a model nor reruns context hooks. Provider-backed totals
//// and independently estimated components remain separate, so static prompt
//// bytes cannot be charged twice. An unreadable or incomplete branch refuses
//// the observation instead of presenting an empty context.

import client/daemon/transfer
import core/json
import core/message
import core/register
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/codec as machine_codec
import machine/operation
import machine/strand
import runtime/hooks
import session/session
import storage/snapshot
import storage/storage
import tools/tool

/// One independently estimated component; names never contain prompt content.
pub type Item {
  Item(
    /// The request component that contains these bytes.
    category: String,
    /// A bounded source label, such as an advertised tool name.
    name: String,
    /// Approximate tokens, using the runtime's character-based estimate.
    tokens: Int,
  )
}

/// Captures a complete bounded context without borrowing the terminal's history.
/// The caller runs this read under the gateway's managed observation deadline.
///
/// ## Examples
///
/// ```gleam
/// // context_view.read(session, "main", system, registry, window_for, settings)
/// ```
pub fn read(
  session: session.Session,
  name: String,
  system: String,
  registry: tool.Registry,
  window_for: fn(strand.ModelIdentity) -> Int,
  settings: operation.CompactionSettings,
) -> Result(json.JsonValue, String) {
  use cut <- result.try(
    session.snapshot_reader.capture(
      snapshot.Plan(
        [
          snapshot.ExactKey(register.StrandConfig, name),
          snapshot.ExactKey(register.StrandLeaf, name),
        ],
        [],
        0,
      ),
      5000,
    )
    |> result.replace_error("context metadata could not be read"),
  )
  use config_cell <- result.try(cell(cut.cells, register.StrandConfig))
  use leaf_cell <- result.try(cell(cut.cells, register.StrandLeaf))
  use config <- result.try(
    machine_codec.decode_configuration(config_cell.register.value.payload)
    |> result.replace_error("context configuration is unreadable"),
  )
  use leaf <- result.try(
    register.read_leaf(leaf_cell.register.value)
    |> result.replace_error("context leaf is unreadable"),
  )
  use entries <- result.try(case leaf {
    None -> Ok([])
    Some(id) ->
      storage.scan_branch(
        session.store,
        storage.branch_scan(id)
          |> storage.branch_stop_at_kind(storage.Compaction)
          |> storage.branch_limit(4097),
      )
      |> result.replace_error("context branch could not be read")
  })
  use <- bool.guard(
    list.drop(entries, 4096) != [],
    Error("context exceeds the 4096-entry inspection limit"),
  )
  let projected = hooks.project_from_scan(entries)
  let items =
    inventory(system, registry, config.active_tool_names, projected.messages)
  board(
    name,
    cut.next_seq - 1,
    config.model,
    window_for(config.model),
    settings,
    projected,
    items,
  )
}

fn cell(cells: List(snapshot.Cell), namespace: register.RegisterNs) {
  list.find(cells, fn(cell) { cell.namespace == namespace })
  |> result.replace_error("context strand is unavailable")
}

/// Estimates the pinned prompt, active definitions, and current messages once.
/// Loaded skill documents and injected memory remain part of their messages;
/// availability alone never adds their full content to this inventory.
///
/// ## Examples
///
/// ```gleam
/// // context_view.inventory(system, registry, active_names, messages)
/// ```
@internal
pub fn inventory(
  system: String,
  registry: tool.Registry,
  active: List(String),
  messages: List(message.AgentMessage),
) -> List(Item) {
  let tools =
    active
    |> list.sort(string.compare)
    |> list.unique
    |> list.filter_map(fn(name) {
      use definition <- result.map(tool.lookup(registry, name))
      let encoded =
        json.to_string(
          json.Object([
            #("name", json.String(definition.name)),
            #("description", json.String(definition.description)),
            #("input_schema", definition.schema),
          ]),
        )
      Item("Tools", string.slice(name, 0, 256), string.length(encoded) / 4)
    })
  let messages =
    list.index_map(messages, fn(value, index) {
      let label = case value {
        message.UserMessage(..) -> "User / injected context"
        message.AssistantMessage(..) -> "Assistant"
        message.ToolResultMessage(tool_name:, ..) ->
          "Tool result: " <> tool_name
        message.CustomMessage(schema:, ..) -> "Custom: " <> schema
      }
      Item(
        "Messages",
        int.to_string(index + 1) <> ". " <> string.slice(label, 0, 256),
        hooks.estimate_message(value),
      )
    })
  [
    Item(
      "System prompt",
      "Pinned prompt (includes embedded instructions)",
      string.length(system) / 4,
    ),
    ..list.append(tools, messages)
  ]
}

/// Builds bounded presentation data while preserving totals over omitted rows.
/// A provider total already includes the static prompt and tool definitions.
///
/// ## Examples
///
/// ```gleam
/// // context_view.board("main", seq, model, window, settings, projected, items)
/// ```
@internal
pub fn board(
  name: String,
  as_of: Int,
  model: strand.ModelIdentity,
  window: Int,
  settings: operation.CompactionSettings,
  projected: hooks.Projected,
  items: List(Item),
) -> Result(json.JsonValue, String) {
  use <- bool.guard(window <= 0, Error("context window is unavailable"))
  let compaction_used = hooks.context_tokens(projected, hooks.estimate_message)
  let reported = hooks.has_reported_usage(projected)
  let used = case reported {
    True -> compaction_used
    False -> list.fold(items, 0, fn(total, item) { total + item.tokens })
  }
  let categories =
    list.map(["System prompt", "Tools", "Messages"], fn(category) {
      let matching = list.filter(items, fn(item) { item.category == category })
      json.Object([
        #("name", json.String(category)),
        #(
          "tokens",
          json.Int(
            list.fold(matching, 0, fn(total, item) { total + item.tokens }),
          ),
        ),
      ])
    })
  let shown = fit(items, [], 0)
  let payload =
    json.Object([
      #("strand", json.String(name)),
      #("as_of", json.Int(as_of)),
      #("model", json.String(model.provider <> "/" <> model.model_id)),
      #("context_window", json.Int(window)),
      #("used_tokens", json.Int(used)),
      #(
        "basis",
        json.String(case reported {
          True -> "reported_plus_estimate"
          False -> "estimated"
        }),
      ),
      #("compaction_used_tokens", json.Int(compaction_used)),
      #("checkpoint_at", case settings.enabled {
        True -> json.Int(int.max(0, window - settings.reserve_tokens))
        False -> json.Null
      }),
      #(
        "reserve_tokens",
        json.Int(case settings.enabled {
          True -> int.max(0, settings.reserve_tokens)
          False -> 0
        }),
      ),
      #("categories", json.Array(categories)),
      #("items", json.Array(shown)),
      #("items_total", json.Int(list.length(items))),
      #("items_omitted", json.Int(list.length(items) - list.length(shown))),
    ])

  // Reserve room for the gateway's status and request identity too. Oversized
  // metadata must fail here rather than produce a board the terminal rejects.
  use _ <- result.try(
    transfer.encoded_size(payload, 47_000)
    |> result.replace_error("context metadata exceeds its byte limit"),
  )
  Ok(payload)
}

// Fit encoded rows, not unescaped names. The fixed metadata retains room for
// bounded identifiers; the gateway independently checks the complete envelope.
fn fit(items: List(Item), reversed, used) {
  case items {
    [] -> list.reverse(reversed)
    [item, ..rest] -> {
      let row =
        json.Object([
          #("category", json.String(item.category)),
          #("name", json.String(item.name)),
          #("tokens", json.Int(item.tokens)),
        ])
      case transfer.encoded_size(row, 40_000 - used) {
        Error(_) -> list.reverse(reversed)
        Ok(size) -> fit(rest, [row, ..reversed], used + size + 1)
      }
    }
  }
}
