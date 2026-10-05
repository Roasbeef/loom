//// Evolution's v2 door admits a closed action vocabulary and object arguments.
//// These tests exercise malformed boundaries and exact receipt correlation;
//// storage and live-generation suites establish what an admitted action does.

import client/protocol
import core/json
import gleam/list
import gleam/option.{None, Some}

pub fn evolution_known_actions_and_receipts_round_trip_test() {
  list.each(
    [
      "catalogue",
      "inspect",
      "evidence",
      "status",
      "approve",
      "revoke",
      "select",
      "rollback",
      "admit_tasks",
      "mark_outcome",
    ],
    fn(action) {
      let command =
        protocol.CommandEnvelope(
          17,
          protocol.Evolution(
            action,
            json.Object([#("candidate_id", json.String("exact"))]),
          ),
        )
      assert protocol.decode_command(protocol.encode_command(command))
        == Ok(command)
    },
  )
  let event =
    protocol.EventEnvelope(
      Some(17),
      None,
      protocol.SnapshotEvent(
        protocol.EvolutionSnapshot(
          json.Object([
            #("candidate_id", json.String("exact")),
            #("generation", json.Int(2)),
          ]),
        ),
      ),
    )
  assert protocol.decode_event(protocol.encode_event(event)) == Ok(event)
}

pub fn evolution_unknown_actions_and_nonobjects_are_refused_test() {
  list.each(
    [
      "{\"action\":\"execute_as_owner\",\"arguments\":{}}",
      "{\"action\":\"approve\",\"arguments\":[]}",
      "{\"action\":\"approve\",\"arguments\":null}",
      "{\"action\":\"approve\"}",
      "{\"arguments\":{}}",
    ],
    fn(body) {
      let assert Error(protocol.BadBody(id: 17, cmd: "evolution", ..)) =
        protocol.decode_command(
          "{\"v\":2,\"id\":17,\"cmd\":\"evolution\",\"body\":" <> body <> "}",
        )
        as "a malformed operator action is refused before authority dispatch"
    },
  )
}
