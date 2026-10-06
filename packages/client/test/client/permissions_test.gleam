//// Who approved a remembered permission, as the reserved fact records it
//// (protocol-change/073): the provenance round-trips, anything that is not a
//// complete record reads as unknown, and a fact written before provenance
//// existed still reads, honouring every permission it held.

import broker/policy
import client/grants
import client/permissions
import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}

fn approved() -> permissions.Provenance {
  permissions.Approved(
    by: Some(message.Origin("alice", "Alice")),
    via: permissions.Login("9c1e0f2ab3d4e5f6"),
    at_ms: 1_790_000_000_000,
  )
}

pub fn a_provenance_round_trips_through_the_fact_test() {
  list.each(
    [
      approved(),
      permissions.Approved(
        by: Some(message.Origin("alice", "Alice")),
        via: permissions.Device("0123456789abcdef"),
        at_ms: 0,
      ),
      permissions.Approved(by: None, via: permissions.Uncredentialed, at_ms: 5),
      permissions.Unknown,
    ],
    fn(provenance) {
      assert permissions.decode_provenance(permissions.encode_provenance(
          provenance,
        ))
        == provenance
    },
  )
}

// The record is advisory, so a damaged one reads as unknown rather than as an
// error that would hide the permission it describes.
pub fn a_damaged_provenance_reads_as_unknown_test() {
  list.each(
    [
      json.String("approved"),
      json.Object([]),
      json.Object([
        #("by", json.Null),
        #("via", json.Object([#("kind", json.String("telepathy"))])),
        #("at_ms", json.Int(1)),
      ]),
      json.Object([
        #("by", json.Null),
        #(
          "via",
          json.Object([
            #("kind", json.String("login")),
            #("fingerprint", json.String("9c1e0f2ab3d4e5f6")),
          ]),
        ),
        #("at_ms", json.Int(-1)),
      ]),
    ],
    fn(damaged) {
      assert permissions.decode_provenance(damaged) == permissions.Unknown
    },
  )
}

// What dispatch reads is the `grants` array and nothing else, so a fact with
// no provenance rows, a row for something it does not hold, or a row that does
// not parse permits exactly what it permitted before.
pub fn only_the_grants_array_is_authority_test() {
  let network = policy.GrantNetwork(policy.NetworkFull)
  let fact =
    json.Object([
      #("version", json.Int(2)),
      #("grants", json.Array([grants.encode(network)])),
      #(
        "remembered",
        json.Array([
          json.Object([
            #("grant", grants.encode(policy.GrantReadableRoot("/etc"))),
            #("provenance", permissions.encode_provenance(approved())),
          ]),
          json.String("not a row"),
        ]),
      ),
    ])
  assert permissions.decode(fact) == Ok([network])
}
