//// The peer CLI accepts exact coordinates and leaves retry identity with the caller.

import client/daemon/peer_cli
import core/clock
import core/ids
import gleam/result

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
