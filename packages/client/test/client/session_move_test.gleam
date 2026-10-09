//// The vocabulary of a session move is names, paths and one projection, and
//// every one of them is a contract between two orchestrators that may be
//// running different builds, so each is pinned here.

import client/session_move
import gleam/list
import gleam/option.{None, Some}
import storage/catalogue

pub fn each_step_is_named_and_the_name_reads_back_test() {
  let steps = [
    session_move.Intent,
    session_move.Close,
    session_move.Cut,
    session_move.Send,
    session_move.Activate,
    session_move.Retire,
  ]
  assert list.map(steps, session_move.step_name)
    == ["intent", "close", "cut", "send", "activate", "retire"]
  assert list.map(steps, fn(step) {
      session_move.parse_step(session_move.step_name(step))
    })
    == list.map(steps, Ok)
  assert session_move.parse_step("") == Error(Nil)
  assert session_move.parse_step("Cut") == Error(Nil)
  assert session_move.parse_step("seven") == Error(Nil)
}

pub fn the_source_and_receiver_files_have_fixed_names_test() {
  assert session_move.lease_owner("op1") == "move:op1"
  assert session_move.reader_owner("op1") == "move-read:op1"
  assert session_move.copy_path("/s/a.db", "op1") == "/s/a.db.move.op1"
  assert session_move.moved_path("/s/a.db") == "/s/a.db.moved"
  assert session_move.incoming_directory("/state") == "/state/incoming"
  assert session_move.incoming_path("/state", "s1", "op1")
    == "/state/incoming/s1.op1"
  assert session_move.part_path("/state", "s1", "op1")
    == "/state/incoming/s1.op1.part"
  assert session_move.check_path("/state", "s1", "op1")
    == "/state/incoming/s1.op1.check"
}

pub fn the_manifest_carries_what_the_receiver_registers_and_no_path_test() {
  let record =
    catalogue.Registration(
      id: "0198c0de-0000-7000-8000-000000000001",
      path: "/source/sessions/0198c0de.db",
      workspace: "repo",
      name: "a name",
      configuration: "/source/loom.toml",
      profile: Some("fast"),
      model: None,
      executor: "box",
      pool: "fleet",
      created_at: 1_700_000_000_000,
      request_key: "key",
      state: catalogue.Saved,
      subtitle: Some("first words"),
    )
  assert session_move.manifest_of(record)
    == session_move.Manifest(
      workspace: "repo",
      name: "a name",
      profile: Some("fast"),
      executor: "box",
      pool: "fleet",
      subtitle: Some("first words"),
      created_at: 1_700_000_000_000,
    )
  let plain =
    catalogue.Registration(..record, profile: None, subtitle: None, pool: "")
  assert session_move.manifest_of(plain).profile == None
}

pub fn every_refusal_has_words_that_name_what_the_receiver_found_test() {
  assert session_move.describe(session_move.DigestMismatch)
    == "the received copy does not match the digest"
  assert session_move.describe(session_move.NoExecutor("box"))
    == "this orchestrator has no executor named box"
  assert session_move.describe(session_move.OutOfOrder(7))
    == "a piece did not start at offset 7"
  assert session_move.describe(session_move.UnknownSource("a@b"))
    == "this orchestrator does not list the node a@b as an orchestrator"
}

pub fn a_move_carries_a_bounded_file_in_bounded_pieces_test() {
  assert session_move.chunk_bytes == 262_144
  assert session_move.size_limit == 268_435_456
  assert session_move.size_limit % session_move.chunk_bytes == 0
}
