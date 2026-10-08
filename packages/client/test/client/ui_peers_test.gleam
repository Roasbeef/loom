//// An owner's page changing peer links, run against two real runtimes
//// (protocol-change/077).
////
//// The daemon runs a page's request with the same functions the control
//// commands run, so these tests drive `ui_peers.run` over a directory of two
//// resident sessions and read what each session recorded through the same
//// endpoint commands `loomd peer inspect` reads.

import client/daemon/ui_peers
import client/gateway_test
import client/peer_mail
import client/peers
import core/clock
import core/ids
import core/json
import gleam/list
import gleam/option.{Some}
import web_view/peer_links.{
  type Board, BothWays, BusyOnly, Complete, Default, Granted, Incoming, MayWake,
  OneWay, Outgoing,
}

type Pair {
  Pair(first: String, second: String, directory: peers.Directory)
}

// Two resident sessions, each answering through its own `handle_with`, and a
// directory that resolves only the sessions in `resident`.
fn resident_pair(
  defaults: peer_mail.Defaults,
  resident: fn(String, String) -> List(String),
) -> Pair {
  let first_id = session_id(801)
  let second_id = session_id(802)
  let first = ids.session_id_to_string(first_id)
  let second = ids.session_id_to_string(second_id)
  let first_runtime = gateway_test.reserved_fixture(first_id).runtime
  let second_runtime = gateway_test.reserved_fixture(second_id).runtime
  let endpoint = fn(id, runtime) {
    peer_mail.Endpoint(id, fn(command) {
      peer_mail.handle_with(runtime, clock.fixed(0), defaults, command)
      |> peer_mail.refused
    })
  }
  let first_endpoint = endpoint(first, first_runtime)
  let second_endpoint = endpoint(second, second_runtime)
  let open = resident(first, second)
  Pair(
    first:,
    second:,
    directory: peers.Directory(
      resolve: fn(id) {
        case list.contains(open, id), id == first {
          False, _ -> Error(peer_mail.Refused("session is saved, not open"))
          True, True -> Ok(first_endpoint)
          True, False -> Ok(second_endpoint)
        }
      },
      describe: fn(id) { Ok(json.Object([#("name", json.String("n-" <> id))])) },
    ),
  )
}

fn session_id(seed: Int) -> ids.SessionId {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.stepping(1_756_000_000_000, 1), seed))
  id
}

fn both(first: String, second: String) -> List(String) {
  [first, second]
}

fn only_first(first: String, _second: String) -> List(String) {
  [first]
}

fn listed(pair: Pair, session: String) -> Board {
  let assert peer_links.Listed(board) =
    ui_peers.run(pair.directory, session, peer_links.Read("main"))
    as "the read answers"
  board
}

pub fn a_link_to_a_resident_session_is_listed_with_its_name_and_wake_test() {
  let pair = resident_pair(peer_mail.no_defaults, both)
  assert ui_peers.run(
      pair.directory,
      pair.first,
      peer_links.Link("main", pair.second, "main", MayWake, OneWay),
    )
    == peer_links.Changed(Complete)
  let board = listed(pair, pair.first)
  assert board.rows
    == [
      peer_links.Row(
        Outgoing,
        pair.second,
        "n-" <> pair.second,
        "main",
        Some(MayWake),
        Granted,
      ),
    ]

  // The other session sees the same link as an incoming one.
  let board = listed(pair, pair.second)
  assert list.map(board.rows, fn(row) {
      #(row.direction, row.session, row.wake)
    })
    == [#(Incoming, pair.first, Some(MayWake))]
}

pub fn both_directions_grants_two_links_in_one_request_test() {
  let pair = resident_pair(peer_mail.no_defaults, both)
  assert ui_peers.run(
      pair.directory,
      pair.first,
      peer_links.Link("main", pair.second, "main", BusyOnly, BothWays),
    )
    == peer_links.Changed(Complete)
  let from_first = listed(pair, pair.first)
  assert list.map(from_first.rows, fn(row) { row.direction })
    == [Outgoing, Incoming]
  let from_second = listed(pair, pair.second)
  assert list.map(from_second.rows, fn(row) { row.direction })
    == [Outgoing, Incoming]

  // A one-way request grants one.
  let one_way = resident_pair(peer_mail.no_defaults, both)
  let assert peer_links.Changed(Complete) =
    ui_peers.run(
      one_way.directory,
      one_way.first,
      peer_links.Link("main", one_way.second, "main", BusyOnly, OneWay),
    )
  assert list.length(listed(one_way, one_way.second).rows) == 1
}

pub fn unlinking_removes_one_direction_or_both_test() {
  let pair = resident_pair(peer_mail.no_defaults, both)
  let assert peer_links.Changed(Complete) =
    ui_peers.run(
      pair.directory,
      pair.first,
      peer_links.Link("main", pair.second, "main", BusyOnly, BothWays),
    )
  let outgoing = peer_links.Edge(Outgoing, pair.second, "main")
  let incoming = peer_links.Edge(Incoming, pair.second, "main")

  // Removing the outgoing link leaves the incoming one.
  assert ui_peers.run(
      pair.directory,
      pair.first,
      peer_links.Unlink("main", [outgoing]),
    )
    == peer_links.Changed(Complete)
  assert list.map(listed(pair, pair.first).rows, fn(row) { row.direction })
    == [Incoming]

  // Removing the incoming link removes what the other session granted.
  assert ui_peers.run(
      pair.directory,
      pair.first,
      peer_links.Unlink("main", [incoming]),
    )
    == peer_links.Changed(Complete)
  assert listed(pair, pair.first).rows == []
  assert listed(pair, pair.second).rows == []

  // Both at once.
  let assert peer_links.Changed(Complete) =
    ui_peers.run(
      pair.directory,
      pair.first,
      peer_links.Link("main", pair.second, "main", BusyOnly, BothWays),
    )
  assert ui_peers.run(
      pair.directory,
      pair.first,
      peer_links.Unlink("main", [outgoing, incoming]),
    )
    == peer_links.Changed(Complete)
  assert listed(pair, pair.first).rows == []
}

pub fn a_saved_session_is_refused_and_never_opened_test() {
  let pair = resident_pair(peer_mail.no_defaults, only_first)
  assert ui_peers.run(
      pair.directory,
      pair.first,
      peer_links.Link("main", pair.second, "main", BusyOnly, OneWay),
    )
    == peer_links.Declined(peer_links.NotRunning)

  // Removing an incoming link needs its sender running.
  assert ui_peers.run(
      pair.directory,
      pair.first,
      peer_links.Unlink("main", [peer_links.Edge(Incoming, pair.second, "main")]),
    )
    == peer_links.Declined(peer_links.NotRunning)
}

pub fn a_strand_the_other_session_lacks_is_refused_in_fixed_words_test() {
  let pair = resident_pair(peer_mail.no_defaults, both)
  assert ui_peers.run(
      pair.directory,
      pair.first,
      peer_links.Link("main", pair.second, "nowhere", BusyOnly, OneWay),
    )
    == peer_links.Declined(peer_links.MissingStrand)
  assert listed(pair, pair.first).rows == []
}

pub fn default_links_are_listed_marked_and_can_be_unlinked_test() {
  let defaults = fn(first: String, second: String) {
    peer_mail.Defaults(
      peer_mail.Policy(peer_mail.SameOwner, peer_mail.BusyOnly),
      fn() { [first, second] },
    )
  }
  let first_id = ids.session_id_to_string(session_id(801))
  let second_id = ids.session_id_to_string(session_id(802))
  let pair = resident_pair(defaults(first_id, second_id), both)
  let board = listed(pair, pair.first)
  assert list.map(board.rows, fn(row) { #(row.direction, row.basis) })
    == [#(Outgoing, Default), #(Incoming, Default)]

  // Unlinking a row that is only a default records the owner's decision.
  assert ui_peers.run(
      pair.directory,
      pair.first,
      peer_links.Unlink("main", [peer_links.Edge(Outgoing, pair.second, "main")]),
    )
    == peer_links.Changed(Complete)
  assert list.map(listed(pair, pair.first).rows, fn(row) { row.direction })
    == [Incoming]
}

pub fn a_read_of_a_strand_that_does_not_exist_is_refused_test() {
  let pair = resident_pair(peer_mail.no_defaults, both)
  assert ui_peers.run(pair.directory, pair.first, peer_links.Read("ghost"))
    == peer_links.Declined(peer_links.MissingStrand)
}

pub fn a_malformed_inspection_is_an_error_and_never_a_partial_list_test() {
  let inspected =
    json.Object([
      #("outgoing", json.Array([json.Object([#("session", json.Int(1))])])),
      #("incoming", json.Array([])),
      #("next", json.Null),
    ])
  let assert Error(_) = ui_peers.board_of("main", inspected)
}

pub fn a_bounded_board_counts_the_rows_it_left_out_test() {
  let row =
    json.Object([
      #("session", json.String("s")),
      #("target_strand", json.String("t")),
      #("wake", json.Null),
    ])
  let inspected =
    json.Object([
      #("outgoing", json.Array(list.repeat(row, 45))),
      #("incoming", json.Array([])),
      #("next", json.Null),
    ])
  let assert Ok(board) = ui_peers.board_of("main", inspected)
  assert list.length(board.rows) == peer_links.row_limit
  assert board.omitted == peer_links.Cut(5)
}

pub fn a_next_cursor_says_more_without_a_count_test() {
  let row =
    json.Object([
      #("session", json.String("s")),
      #("target_strand", json.String("sub:main/reviewer")),
      #("wake", json.Null),
    ])
  let inspected =
    json.Object([
      #("outgoing", json.Array([row])),
      #("incoming", json.Array([])),
      #("next", json.String("cursor")),
    ])
  let assert Ok(board) = ui_peers.board_of("main", inspected)
  assert board.omitted == peer_links.Unread
  assert list.length(board.rows) == 1

  // A listed strand with a control character refuses the whole read.
  let bad =
    json.Object([
      #(
        "outgoing",
        json.Array([
          json.Object([
            #("session", json.String("s")),
            #("target_strand", json.String("a\u{0}b")),
          ]),
        ]),
      ),
      #("incoming", json.Array([])),
      #("next", json.Null),
    ])
  let assert Error(_) = ui_peers.board_of("main", bad)
}
