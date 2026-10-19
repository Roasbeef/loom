//// A deployment as the daemon states it, for the tests of the Admin page's
//// machines: the document `deployment.status` returns for the whole deployment
//// and for one node, built as values so a test can change one member and read it
//// back through the page's own decoder.
////
//// The deployment is the one the design's example draws: the asking daemon
//// `alpha`, an executor `box` that is degraded with a scope stuck closing, an
//// executor `exec2` that is down, and an orchestrator `bravo`. The ledger lists
//// `alpha`, `box` and `laptop`, so `laptop` is a member this daemon is not linked
//// to, and `exec2` and `bravo` are configured here and not in the ledger.

import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import web_view/machines

/// The hex SHA-256 of box's certificate.
pub const box_pin =
  "9d2f0c7a1b3e4d5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7"

/// The hex SHA-256 of alpha's certificate.
pub const alpha_pin =
  "1c7e00112233445566778899aabbccddeeff00112233445566778899aabbccdd"

/// The node of the executor the tests choose.
pub const box_node = "box@10.0.0.2"

/// The session stuck on box.
pub const stuck_session = "0198c1aa-0000-7000-8000-0000000000aa"

fn text(value: String) -> JsonValue {
  json.String(value)
}

fn strings(values: List(String)) -> JsonValue {
  json.Array(list.map(values, json.String))
}

/// The whole deployment, with the executor `box` named `box_name`.
pub fn document(box_name: String) -> JsonValue {
  json.Object([
    #("as_of_ms", json.Int(1_760_190_131_000)),
    #("self", text("alpha@10.0.0.1")),
    #("state", text("degraded")),
    #(
      "reasons",
      json.Array([
        json.Object([
          #("node", text("exec2@10.0.0.9")),
          #("reason", text("timeout")),
        ]),
      ]),
    ),
    #(
      "nodes",
      json.Array([
        json.Object([
          #("node", text("alpha@10.0.0.1")),
          #("name", text("alpha")),
          #("roles", strings(["orchestrator", "member"])),
          #("state", text("ok")),
          #("self", json.Bool(True)),
          #("build_version", text("0.2.0")),
          #("build_commit", text("b4eeb50c")),
          #("uptime_ms", json.Int(86_400_000)),
          #(
            "orchestrator",
            json.Object([
              #("capacity", json.Int(8)),
              #("occupied", json.Int(2)),
              #("resident", json.Int(2)),
              #("imports", text("receiving")),
              #("moves_in_flight", json.Int(1)),
            ]),
          ),
        ]),
        box(box_name),
        json.Object([
          #("node", text("exec2@10.0.0.9")),
          #("name", text("exec2")),
          #("roles", strings(["executor"])),
          #("state", text("down")),
          #("reason", text("timeout")),
        ]),
        json.Object([
          #("node", text("bravo@10.0.0.4")),
          #("name", text("bravo")),
          #("roles", strings(["orchestrator"])),
          #("state", text("ok")),
          #("build_version", text("0.2.0")),
          #("build_commit", text("b4eeb50c")),
          #("uptime_ms", json.Int(3_600_000)),
          #(
            "orchestrator",
            json.Object([
              #("capacity", json.Int(4)),
              #("occupied", json.Int(0)),
              #("resident", json.Int(0)),
              #("imports", text("not_receiving")),
              #("moves_in_flight", json.Int(0)),
            ]),
          ),
        ]),
      ]),
    ),
    #(
      "edges",
      json.Array([
        json.Object([
          #("from", text("alpha@10.0.0.1")),
          #("to", text(box_node)),
          #("kind", text("serves")),
          #("sessions", json.Int(3)),
          #("link", text("connected")),
        ]),
        json.Object([
          #("from", text("alpha@10.0.0.1")),
          #("to", text("bravo@10.0.0.4")),
          #("kind", text("peer")),
          #("link", text("connected")),
        ]),
        json.Object([
          #("from", text("alpha@10.0.0.1")),
          #("to", text("exec2@10.0.0.9")),
          #("kind", text("serves")),
          #("sessions", json.Int(0)),
          #("link", text("none")),
        ]),
      ]),
    ),
    #(
      "placements",
      json.Object([
        #("executors", json.Array([])),
        #(
          "pools",
          json.Array([
            json.Object([
              #("name", text("linux")),
              #("executors", strings([box_name, "exec2"])),
              #("eligible", strings([box_name])),
            ]),
          ]),
        ),
      ]),
    ),
    #("distribution", text("configured")),
    #(
      "directory",
      json.Object([
        #("members", strings(["alpha@10.0.0.1"])),
        #("copy", text("unconfirmed")),
      ]),
    ),
    #("ledger", ledger()),
    #(
      "moves",
      json.Array([
        json.Object([
          #("session_id", text("0198c1aa-0000-7000-8000-0000000000bb")),
          #("op", text("op-1")),
          #("to", text("bravo")),
          #("phase", text("waiting")),
          #("stalled_ms", json.Int(120_000)),
          #("reason", text("the destination is busy")),
        ]),
      ]),
    ),
  ])
}

fn box(name: String) -> JsonValue {
  json.Object([
    #("node", text(box_node)),
    #("name", text(name)),
    #("roles", strings(["executor"])),
    #("state", text("degraded")),
    #("reasons", strings(["unclean_scope"])),
    #("build_version", text("0.2.0")),
    #("build_commit", text("b4eeb50c")),
    #("protocol", json.Int(3)),
    #("uptime_ms", json.Int(3_600_000)),
    #(
      "executor",
      json.Object([
        #(
          "scopes",
          json.Object([
            #("open", json.Int(3)),
            #("closing", json.Int(1)),
            #("closed_clean", json.Int(9)),
            #("closed_unknown", json.Int(1)),
          ]),
        ),
        #("scope_limit", json.Int(16)),
        #("platform", text("linux/x86_64")),
        #("enforcement", text("enforced")),
        #("toolchains", strings(["go", "gleam"])),
        #("contradiction", json.Null),
      ]),
    ),
  ])
}

fn ledger() -> JsonValue {
  json.Object([
    #("deployment", text("3f9c0000000000000000000000000000")),
    #("state", text("ok")),
    #(
      "head",
      json.Object([
        #("seq", json.Int(9)),
        #("id", text(alpha_pin)),
      ]),
    ),
    #(
      "self",
      json.Object([#("name", text("alpha")), #("enrolled", json.Bool(True))]),
    ),
    #(
      "members",
      json.Array([
        json.Object([
          #("name", text("alpha")),
          #("node", text("alpha@10.0.0.1")),
          #("role", text("orchestrator")),
          #("directory", text("voter")),
          #("links", strings([])),
          #("pin", text(alpha_pin)),
          #("reported_seq", json.Int(9)),
          #("ms_since_report", json.Int(0)),
        ]),
        json.Object([
          #("name", text("box")),
          #("node", text(box_node)),
          #("role", text("executor")),
          #("directory", text("none")),
          #("links", strings(["alpha"])),
          #("pin", text(box_pin)),
          #("reported_seq", json.Int(8)),
          #("ms_since_report", json.Int(412_000)),
        ]),
        json.Object([
          #("name", text("laptop")),
          #("node", text("laptop@10.0.0.7")),
          #("role", text("executor")),
          #("directory", text("none")),
          #("links", strings(["bravo"])),
          #("pin", text("not a pin")),
        ]),
      ]),
    ),
    #("last_refusal", json.Null),
  ])
}

/// The reply to a read of the node `key` names: that node with its long lists.
pub fn detail_document() -> JsonValue {
  json.Object([
    #("self", text("alpha@10.0.0.1")),
    #("state", text("degraded")),
    #("reasons", json.Array([])),
    #(
      "nodes",
      json.Array([
        json.Object([
          #("node", text(box_node)),
          #("name", text("box")),
          #("roles", strings(["executor"])),
          #("state", text("degraded")),
          #(
            "executor",
            json.Object([
              #(
                "scopes",
                json.Object([
                  #("open", json.Int(3)),
                  #("closing", json.Int(1)),
                  #("closed_clean", json.Int(9)),
                  #("closed_unknown", json.Int(1)),
                ]),
              ),
              #("scope_limit", json.Int(16)),
              #("workspaces", strings(["app", "docs"])),
              #(
                "unclean",
                json.Array([
                  json.Object([
                    #("session", text(stuck_session)),
                    #("state", text("closing")),
                  ]),
                  json.Object([
                    #("session", text("0198c1aa-0000-7000-8000-0000000000ab")),
                    #("state", text("unknown_cleanup")),
                    #("count", json.Int(2)),
                  ]),
                ]),
              ),
            ]),
          ),
        ]),
      ]),
    ),
  ])
}

/// The node name a daemon without distribution is given by the BEAM's profile
/// boot, which means nothing to a person and is never drawn.
pub const standalone_node =
  "loom_daemon_profile_50242_5e12ebec8c7ed73e5501f7c6bf984aeb@127.0.0.1"

/// A daemon with no `[distribution]` table: itself, an orchestrator that
/// answered with its build and uptime and no orchestrator facts, since such a
/// daemon has no orchestrator port to read them from, and nothing else.
pub fn standalone_document() -> JsonValue {
  json.Object([
    #("as_of_ms", json.Int(1_760_190_131_000)),
    #("self", text(standalone_node)),
    #("state", text("ok")),
    #("reasons", json.Array([])),
    #(
      "nodes",
      json.Array([
        json.Object([
          #("node", text(standalone_node)),
          #("name", text(standalone_node)),
          #("roles", strings(["orchestrator"])),
          #("state", text("ok")),
          #("self", json.Bool(True)),
          #("build_version", text("0.3.0")),
          #("build_commit", text("ca9a21f02bc67201de0dbed2bc6debe308377fac")),
          #("uptime_ms", json.Int(7_500_000)),
        ]),
      ]),
    ),
    #(
      "placements",
      json.Object([#("executors", json.Array([])), #("pools", json.Array([]))]),
    ),
    #("orchestrators", json.Array([])),
    #("distribution", text("none")),
  ])
}

/// The standalone daemon's document with the `host` member a daemon that read
/// its host name adds.
pub fn hosted_document(host: String) -> JsonValue {
  let assert json.Object(fields) = standalone_document()
    as "the fixture is an object"
  json.Object(list.append(fields, [#("host", text(host))]))
}

/// The standalone daemon's reading when it states its host name.
pub fn hosted(host: String) -> machines.Snapshot {
  let assert Ok(snapshot) = machines.decode_overview(hosted_document(host))
    as "the fixture decodes"
  snapshot
}

/// The standalone daemon's reading.
pub fn standalone() -> machines.Snapshot {
  let assert Ok(snapshot) = machines.decode_overview(standalone_document())
    as "the fixture decodes"
  snapshot
}

/// The page's reading of the whole deployment with the executor named
/// `box_name`.
pub fn overview(box_name: String) -> machines.Snapshot {
  let assert Ok(snapshot) = machines.decode_overview(document(box_name))
    as "the fixture decodes"
  snapshot
}

/// What the daemon's read answers: the whole deployment for no key, the long
/// lists of `box` for its key, and nothing for any other.
pub fn reading(node: Option(String)) -> machines.Reading {
  case node {
    None -> machines.Heard(overview("box"))
    Some("box") -> {
      let assert Ok(detail) = machines.decode_detail(detail_document())
        as "the fixture decodes"
      machines.HeardOne(detail)
    }
    Some(_) -> machines.Unread
  }
}
