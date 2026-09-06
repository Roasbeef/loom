//// Projection follows captured leaves and pairs configuration with its author.

import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/message
import core/register
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import machine/codec as machine_codec
import machine/strand
import tui/snapshot
import tui/snapshot_view

fn author(name) {
  json.Object([
    #("principal", json.String("principal-" <> name)),
    #("name", json.String(name)),
  ])
}

fn cell(namespace, key, value) {
  json.Object([
    #("namespace", json.String(register.ns_to_string(namespace))),
    #("key", json.String(key)),
    #("seq", json.Int(1)),
    #("value", value),
  ])
}

fn settings(name, queue) {
  json.Object([
    #("queue_mode", json.String(queue)),
    #("tool_execution", json.String("parallel")),
    #("origin", author(name)),
  ])
}

fn metadata(cells) {
  json.Object([
    #("cells", json.Array(cells)),
    #("message_count", json.Int(0)),
    #(
      "usage",
      codec.encode_usage(message.Usage(
        0,
        0,
        0,
        0,
        None,
        None,
        0,
        message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
      )),
    ),
    #("host_run_settings", settings("Host", "one_at_a_time")),
    #(
      "peers",
      json.Array([
        json.Object([
          #("connection_id", json.String("alice-tab")),
          #("origin", author("Alice")),
          #("role", json.String("operator")),
        ]),
      ]),
    ),
  ])
}

fn cut(metadata, window) {
  snapshot.Captured(
    snapshot.Attachment(
      snapshot.Expected("session", "epoch", "incarnation"),
      "alice-tab",
      message.Origin("principal-Alice", "Alice"),
      snapshot.Operator,
    ),
    10,
    metadata,
    window,
    None,
  )
}

pub fn snapshot_view_lookup_requires_exact_complete_requested_keys_test() {
  let present = cell(register.FactCustom, "escalation/esc", json.Object([]))
  let lookup = fn(cells, missing) {
    cut(
      json.Object([
        #("cells", json.Array(cells)),
        #("missing", json.Array(list.map(missing, json.String))),
      ]),
      snapshot.empty(),
    )
  }
  let assert Ok(#(found, missing)) =
    snapshot_view.lookup(lookup([present], ["absent"]), ["esc", "absent"])
    as "requested present and absent identities are distinct explicit answers"
  assert list.length(found) == 1
  assert missing == ["absent"]
  list.each(
    [
      lookup([present], ["esc"]),
      lookup([present], []),
      lookup(
        [cell(register.FactCustom, "escalation/esc-neighbor", json.Object([]))],
        ["absent"],
      ),
      lookup([cell(register.StrandConfig, "escalation/esc", json.Object([]))], [
        "absent",
      ]),
    ],
    fn(captured) {
      let assert Error(_) = snapshot_view.lookup(captured, ["esc", "absent"])
        as "duplicate, omitted, prefix-neighbor and wrong-namespace answers fail closed"
    },
  )
}

fn config_cells(leaf, name, model) {
  [
    cell(
      register.StrandConfig,
      "main",
      machine_codec.encode_configuration(
        strand.StrandConfiguration(
          strand.ModelIdentity("provider", model),
          strand.ThinkingOff,
          [],
        ),
      ),
    ),
    cell(register.StrandLeaf, "main", leaf),
    cell(
      register.StrandState,
      "main",
      machine_codec.encode_strand_state(strand.StrandState(None, [])),
    ),
    cell(
      register.FactCustom,
      "client/config_origin/main",
      json.Object([#("origin", author(name))]),
    ),
    cell(
      register.FactCustom,
      "client/run_settings",
      settings(name, "consume_all"),
    ),
  ]
}

pub fn snapshot_view_metadata_only_cut_replaces_configuration_and_author_together_test() {
  let first =
    cut(metadata(config_cells(json.Null, "Alice", "first")), snapshot.empty())
  let second =
    cut(metadata(config_cells(json.Null, "Bob", "second")), snapshot.empty())
  let assert Ok(a) = snapshot_view.decode(first)
    as "first coherent metadata decodes"
  let assert Ok(b) = snapshot_view.decode(second)
    as "metadata can change without a new entry cursor"
  let assert Ok(config) = dict.get(b.configurations, "main")
    as "captured configuration is present"
  assert config.configuration.model.model_id == "second"
  assert config.origin == Some(message.Origin("principal-Bob", "Bob"))
  assert a.settings.origin != b.settings.origin
  assert b.settings.queue_mode == "consume_all"
    as "durable run settings override host defaults"
  assert first.next_seq == second.next_seq
  assert b.peers
    == [
      snapshot_view.Peer(
        "alice-tab",
        message.Origin("principal-Alice", "Alice"),
        snapshot.Operator,
      ),
    ]
}

pub fn snapshot_view_projects_only_real_ancestry_and_marks_missing_parent_test() {
  let #(missing, generator) =
    ids.mint_entry(ids.generator(clock.fixed(1000), 1))
  let #(leaf, generator) = ids.mint_entry(generator)
  let #(unrelated, _) = ids.mint_entry(generator)
  let row =
    entry.MessageEntry(
      leaf,
      Some(missing),
      2,
      1000,
      message.UserMessage([message.UserText("selected", None)], 1000, None),
      False,
    )
  let other =
    entry.MessageEntry(
      unrelated,
      None,
      3,
      1000,
      message.UserMessage([message.UserText("unrelated", None)], 1000, None),
      False,
    )
  let window =
    snapshot.Window(
      [snapshot.Loaded(other, 100), snapshot.Loaded(row, 100)],
      200,
      None,
    )
  let captured =
    cut(
      metadata(config_cells(
        json.String(ids.entry_id_to_string(leaf)),
        "Alice",
        "first",
      )),
      window,
    )
  let assert Ok(view) = snapshot_view.decode(captured)
    as "captured leaf and strand state agree"
  let branch = snapshot_view.branch(view, window, "main")
  assert list.map(branch.records, fn(record) { record.entry.id }) == [leaf]
  assert branch.unloaded == Some(ids.entry_id_to_string(missing))
}

pub fn snapshot_view_rejects_duplicate_cells_and_registers_outside_cut_test() {
  let value =
    cell(register.FactCustom, "client/run_settings", settings("Alice", "all"))
  let assert Error(_) =
    snapshot_view.decode(cut(metadata([value, value]), snapshot.empty()))
    as "duplicate mutable identities cannot silently overwrite one another"
  let captured = cut(metadata([value]), snapshot.empty())
  let assert Error(_) =
    snapshot_view.decode(snapshot.Captured(..captured, next_seq: 1))
    as "a register sequence cannot be at or after the capture cursor"
  Nil
}
