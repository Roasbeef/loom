//// The peer CLI accepts exact coordinates and leaves retry identity with the caller.

import broker/token
import client/daemon/peer_cli
import client/daemon/protocol
import client/peer_mail
import client/peers
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/endpoint
import simplifile

fn session(seed) {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), seed))
  ids.session_id_to_string(id)
}

pub fn peer_cli_requires_explicit_wake_and_retry_identity_test() {
  let source = session(100)
  let target = session(101)
  assert result.is_error(
    peer_cli.parse(["link", source, "main", target, "reviewer"]),
  )
  assert result.is_error(
    peer_cli.parse([
      "link", source, "main", target, "reviewer", "--wake", "default",
    ]),
  )
  assert result.is_error(
    peer_cli.parse([
      "send", source, "main", target, "reviewer", "--text", "finding",
    ]),
  )
  assert result.is_error(
    peer_cli.parse([
      "send", source, "main", target, "reviewer", "--message-id", "", "--text",
      "finding",
    ]),
  )
  assert result.is_error(
    peer_cli.parse([
      "send", source, "main", target, "reviewer", "--message-id", "one",
      "--text", "",
    ]),
  )
  assert result.is_error(peer_cli.parse(["inspect", "other", "main"]))
}

pub fn malformed_local_endpoint_is_not_a_daemon_refusal_test() {
  let path =
    "build/test_db/peer-cli-malformed-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(paths) = endpoint.paths(path)
  let assert Ok(Nil) = simplifile.write(paths.record, "not a daemon endpoint")
  let assert Ok(command) =
    peer_cli.parse([
      "--state-dir",
      paths.root,
      "inspect",
      session(102),
      "main",
    ])
  let assert Error(reason) = peer_cli.run(command)
  assert string.starts_with(reason, "request not sent:")
  assert peer_cli.unknown_outcome(reason)
}

pub fn peer_inspection_pages_both_directions_with_bounded_frames_test() {
  let source = session(200)
  let target = session(201)
  let links =
    list.index_map(list.repeat(Nil, 64), fn(_, offset) {
      let index = offset + 1
      json.Object([
        #("session", json.String(target)),
        #("strand", json.String("reviewer-" <> int.to_string(index))),
      ])
    })
  let grants =
    list.index_map(list.repeat(Nil, 800), fn(_, offset) {
      let index = offset + 1
      json.Object([
        #("source_session", json.String("source-" <> int.to_string(index))),
        #("source_strand", json.String("main")),
        #("target_strand", json.String("main")),
        #("wake", json.String("busy_only")),
      ])
    })
  let endpoint =
    peer_mail.Endpoint(source, fn(command) {
      case command {
        peer_mail.Activity(_) -> Ok(json.Object([]))
        peer_mail.Links(_) -> Ok(json.Array(links))
        peer_mail.Grants(_) -> Ok(json.Array(grants))
        _ -> Error("unexpected test command")
      }
    })
  let directory =
    peers.Directory(
      resolve: fn(_) {
        Ok(
          peer_mail.Endpoint(target, fn(command) {
            case command {
              peer_mail.Roster(_, _) ->
                Ok(
                  json.Array(
                    list.map(links, fn(link) {
                      json.Object([
                        #("strand", test_field(link, "strand")),
                        #("wake", json.String("may_wake")),
                      ])
                    }),
                  ),
                )
              _ -> Error("unexpected test command")
            }
          }),
        )
      },
      describe: fn(_) {
        Ok(json.Object([#("label", json.String(string.repeat("x", 96)))]))
      },
    )
  let wiring = peers.Wiring(endpoint, json.Object([]), Some(directory))
  let assert Ok(empty_frame) =
    protocol.event(Some(1), "peers.inspect", json.Null)
  let budget = 60_000 - string.byte_size(empty_frame) + 4
  inspect_all_pages(wiring, None, budget, [], [], 0)
}

fn inspect_all_pages(wiring, after, budget, outgoing, incoming, pages) {
  let assert Ok(body) = peers.inspect(wiring, "main", after, budget)
  let assert Ok(frame) = protocol.event(Some(1), "peers.inspect", body)
  assert string.byte_size(frame) <= 60_000
  let assert json.Array(next_outgoing) = test_field(body, "outgoing")
  let assert json.Array(next_incoming) = test_field(body, "incoming")
  let outgoing = list.append(outgoing, next_outgoing)
  let incoming = list.append(incoming, next_incoming)
  case test_field(body, "next") {
    json.String(cursor) -> {
      assert pages < 20
      inspect_all_pages(
        wiring,
        Some(cursor),
        budget,
        outgoing,
        incoming,
        pages + 1,
      )
    }
    json.Null -> {
      assert pages > 0
      assert list.length(outgoing) == 64
      assert list.length(incoming) == 800
      assert list.length(
          list.unique(
            list.map(outgoing, fn(row) { test_field(row, "target_strand") }),
          ),
        )
        == 64
      assert list.length(
          list.unique(
            list.map(incoming, fn(row) { test_field(row, "source_session") }),
          ),
        )
        == 800
      assert list.all(outgoing, fn(row) {
        test_field(row, "wake") == json.String("may_wake")
        && test_field(row, "exported_strands") == json.Null
      })
    }
    _ -> panic as "invalid test cursor"
  }
}

pub fn peer_inspection_refuses_an_oversized_single_row_test() {
  let source = session(203)
  let target = session(204)
  let endpoint =
    peer_mail.Endpoint(source, fn(command) {
      case command {
        peer_mail.Activity(_) -> Ok(json.Object([]))
        peer_mail.Links(_) ->
          Ok(
            json.Array([
              json.Object([
                #("session", json.String(target)),
                #("strand", json.String("reviewer")),
              ]),
            ]),
          )
        peer_mail.Grants(_) -> Ok(json.Array([]))
        _ -> Error("unexpected test command")
      }
    })
  let directory =
    peers.Directory(resolve: fn(_) { Error("unavailable") }, describe: fn(_) {
      Ok(json.Object([#("label", json.String(string.repeat("x", 60_000)))]))
    })
  let wiring = peers.Wiring(endpoint, json.Object([]), Some(directory))
  assert peers.inspect(wiring, "main", None, 59_000)
    == Error("metadata_too_large")
}

fn test_field(value, key) {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key) |> result.unwrap(json.Null)
    _ -> json.Null
  }
}
