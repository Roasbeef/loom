import core/json
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import tui/command
import tui/daemon/protocol

const hello = "{\"v\":2,\"event\":\"hello\",\"body\":{\"protocol\":2,\"epoch\":\"epoch-one\",\"principal\":\"owner\",\"limits\":{\"control_bytes\":65536}}}"

pub fn rename_command_preserves_spaces_and_requires_argument_test() {
  assert command.parse("/rename review auth") == command.Rename("review auth")
  assert command.parse("/rename   ") == command.MissingArgument("rename")
  assert protocol.mutates(protocol.RenameSession("invalid", "name"))
  let assert Error(_) =
    protocol.encode(
      1,
      protocol.RenameSession("invalid", "name"),
      protocol.Epoch("epoch"),
    )
    as "rename retains canonical session identity validation"
}

pub fn every_truncated_hello_is_rejected_test() {
  assert protocol.decode(hello)
    == Ok(
      protocol.Greeting(protocol.Hello(
        protocol.Epoch("epoch-one"),
        "owner",
        65_536,
        None,
      )),
    )
  list.each(
    list.index_map(string.to_graphemes(hello), fn(_, i) { i }),
    fn(size) {
      let assert Error(_) = protocol.decode(string.slice(hello, 0, size))
        as "every incomplete envelope must be refused"
    },
  )
}

// Issue #392. A daemon that names its build gives a client two comparison
// strings; a daemon that predates the fields gives `None`, which is
// reported as an unknown build rather than refused.
pub fn a_hello_carries_the_daemons_build_when_it_names_one_test() {
  assert protocol.decode(
      "{\"v\":2,\"event\":\"hello\",\"body\":{\"protocol\":2,\"epoch\":\"e\",\"principal\":\"owner\",\"build_version\":\"0.1.0\",\"build_commit\":\"4c266dde\",\"limits\":{\"control_bytes\":65536}}}",
    )
    == Ok(
      protocol.Greeting(protocol.Hello(
        protocol.Epoch("e"),
        "owner",
        65_536,
        Some(protocol.Build("0.1.0", "4c266dde")),
      )),
    )

  // A hello with only one of the two fields is an unknown build, not a
  // half-read one: `build_at` yields `None` when either field is absent.
  assert protocol.decode(
      "{\"v\":2,\"event\":\"hello\",\"body\":{\"protocol\":2,\"epoch\":\"e\",\"principal\":\"owner\",\"build_version\":\"0.1.0\",\"limits\":{\"control_bytes\":65536}}}",
    )
    == Ok(
      protocol.Greeting(protocol.Hello(
        protocol.Epoch("e"),
        "owner",
        65_536,
        None,
      )),
    )
}

pub fn duplicate_keys_versions_and_complete_frame_bound_test() {
  list.each(
    [
      "{\"v\":1,\"event\":\"hello\",\"body\":{}}",
      "{\"v\":2,\"v\":2,\"event\":\"hello\",\"body\":{}}",
      "{\"v\":2,\"reply_to\":0,\"event\":\"daemon.shutdown\",\"body\":{\"state\":\"draining\"}}",
      "{\"v\":2,\"event\":\"error\",\"reply_to\":null,\"body\":{\"code\":\"bad\",\"message\":\"bad\"}}",
      string.repeat(" ", protocol.max_bytes + 1),
    ],
    fn(text) {
      let assert Error(_) = protocol.decode(text)
        as "invalid envelopes cannot reach control state"
    },
  )
}

pub fn empty_page_and_refusal_are_distinct_test() {
  assert protocol.decode(
      "{\"v\":2,\"reply_to\":7,\"event\":\"sessions.list\",\"body\":{\"revision\":9,\"sessions\":[],\"after\":null}}",
    )
    == Ok(protocol.Answer(
      7,
      "sessions.list",
      protocol.SessionsReply(protocol.Page(9, [], None)),
    ))
  assert protocol.decode(
      "{\"v\":2,\"reply_to\":7,\"event\":\"error\",\"body\":{\"code\":\"revision_changed\",\"message\":\"request refused\"}}",
    )
    == Ok(protocol.Refused(Some(7), "revision_changed", "request refused"))
}

pub fn request_scalar_limits_and_stale_operation_epoch_test() {
  let epoch = protocol.Epoch("current")
  assert protocol.encode(0, protocol.Status, epoch)
    == Error("invalid request id")
  let assert Error(_) =
    protocol.encode(1, protocol.ListSessions("not-an-id", None), epoch)
    as "session cursors are canonical identities"
  let assert Error(_) =
    protocol.encode(
      1,
      protocol.CreateSession("key", "/work", string.repeat("x", 257), "/config"),
      epoch,
    )
    as "names are bounded before serialization"
  assert protocol.encode(
      1,
      protocol.GetOperation("ignored", "op", protocol.Epoch("old")),
      epoch,
    )
    == Error("stale epoch")
  assert protocol.encode(1, protocol.Shutdown, epoch)
    == Ok(
      "{\"v\":2,\"id\":1,\"cmd\":\"daemon.shutdown\",\"body\":{\"epoch\":\"current\"}}",
    )
}

pub fn peer_control_commands_bind_epoch_exact_coordinates_and_wake_test() {
  let epoch = protocol.Epoch("current")
  let source = "00000000-0000-7000-8000-000000000001"
  let target = "00000000-0000-7000-8000-000000000002"
  assert protocol.mutates(protocol.InspectPeers(source, "main", None)) == False
  assert protocol.mutates(protocol.LinkPeers(
    source,
    "main",
    target,
    "reviewer",
    protocol.BusyOnly,
  ))
  assert protocol.encode(1, protocol.InspectPeers(source, "main", None), epoch)
    == Ok(
      "{\"v\":2,\"id\":1,\"cmd\":\"peers.inspect\",\"body\":{\"epoch\":\"current\",\"source_session\":\"00000000-0000-7000-8000-000000000001\",\"source_strand\":\"main\"}}",
    )
  assert protocol.encode(
      4,
      protocol.InspectPeers(source, "main", Some("cursor-2")),
      epoch,
    )
    == Ok(
      "{\"v\":2,\"id\":4,\"cmd\":\"peers.inspect\",\"body\":{\"epoch\":\"current\",\"source_session\":\"00000000-0000-7000-8000-000000000001\",\"source_strand\":\"main\",\"after\":\"cursor-2\"}}",
    )
  assert protocol.encode(
      2,
      protocol.LinkPeers(source, "main", target, "reviewer", protocol.MayWake),
      epoch,
    )
    == Ok(
      "{\"v\":2,\"id\":2,\"cmd\":\"peers.link\",\"body\":{\"epoch\":\"current\",\"source_session\":\"00000000-0000-7000-8000-000000000001\",\"source_strand\":\"main\",\"target_session\":\"00000000-0000-7000-8000-000000000002\",\"target_strand\":\"reviewer\",\"wake\":\"may_wake\"}}",
    )
  assert protocol.encode(
      3,
      protocol.UnlinkPeers(source, "main", target, "reviewer"),
      epoch,
    )
    |> result.is_ok
}

pub fn peer_inspection_reply_preserves_server_document_test() {
  assert protocol.decode(
      "{\"v\":2,\"reply_to\":9,\"event\":\"peers.inspect\",\"body\":{\"incoming\":[],\"outgoing\":[]}}",
    )
    == Ok(protocol.Answer(
      9,
      "peers.inspect",
      protocol.PeersInspectionReply(
        json.Object([
          #("incoming", json.Array([])),
          #("outgoing", json.Array([])),
        ]),
      ),
    ))
}

pub fn session_activity_request_names_distinct_bounded_sessions_test() {
  let epoch = protocol.Epoch("current")
  let first = "00000000-0000-7000-8000-000000000001"
  let second = "00000000-0000-7000-8000-000000000002"
  assert protocol.mutates(protocol.SessionActivity([first])) == False
  assert protocol.encode(1, protocol.SessionActivity([first, second]), epoch)
    == Ok(
      "{\"v\":2,\"id\":1,\"cmd\":\"sessions.activity\",\"body\":{\"sessions\":[\"00000000-0000-7000-8000-000000000001\",\"00000000-0000-7000-8000-000000000002\"],\"epoch\":\"current\"}}",
    )

  // Each of these is a request the daemon refuses whole.
  // Distinct identities, so the count bound is tested apart from the
  // duplicate rule.
  let too_many =
    list.repeat(Nil, protocol.activity_limit + 1)
    |> list.index_map(fn(_, index) {
      "00000000-0000-7000-8000-0000000001" <> pad(index)
    })
  list.each([[], [first, first], ["not-a-session"], too_many], fn(sessions) {
    let assert Error(_) =
      protocol.encode(1, protocol.SessionActivity(sessions), epoch)
      as "an invalid identity list is refused before sending"
  })
}

pub fn session_activity_reply_decodes_every_field_test() {
  let frame =
    "{\"v\":2,\"reply_to\":3,\"event\":\"sessions.activity\",\"body\":{\"activity\":[{\"session_id\":\"00000000-0000-7000-8000-000000000001\",\"state\":\"needs_you\",\"strands\":3,\"working\":1,\"approvals\":2,\"last_outcome\":\"failed\",\"last_message\":\"Tests fail on main.\",\"model\":\"glm-5.2\",\"glances\":[{\"strand\":\"sub:main/audit\",\"title\":\"Audit\",\"summary\":\"\"}]}]}}"
  assert protocol.decode(frame)
    == Ok(protocol.Answer(
      3,
      "sessions.activity",
      protocol.ActivityReply([
        protocol.Activity(
          session_id: "00000000-0000-7000-8000-000000000001",
          state: protocol.NeedsYou,
          strands: 3,
          working: 1,
          approvals: 2,
          last_outcome: Some(protocol.LastFailed),
          last_message: Some("Tests fail on main."),
          model: Some("glm-5.2"),
          glances: [protocol.GlanceLine("sub:main/audit", "Audit", "")],
        ),
      ]),
    ))
}

pub fn session_activity_reply_tolerates_unknown_and_missing_fields_test() {
  // An unanswered session carries only its identity, and a later daemon may
  // send a state or outcome this terminal has never heard of.
  let frame =
    "{\"v\":2,\"reply_to\":4,\"event\":\"sessions.activity\",\"body\":{\"activity\":[{\"session_id\":\"00000000-0000-7000-8000-000000000001\",\"state\":\"unknown\"},{\"session_id\":\"00000000-0000-7000-8000-000000000002\",\"state\":\"hibernating\",\"last_outcome\":\"paused\",\"glances\":[{\"strand\":\"\"},7],\"extra\":true}]}}"
  let empty = fn(id) {
    protocol.Activity(
      session_id: id,
      state: protocol.Unknown,
      strands: 0,
      working: 0,
      approvals: 0,
      last_outcome: None,
      last_message: None,
      model: None,
      glances: [],
    )
  }
  assert protocol.decode(frame)
    == Ok(protocol.Answer(
      4,
      "sessions.activity",
      protocol.ActivityReply([
        empty("00000000-0000-7000-8000-000000000001"),
        empty("00000000-0000-7000-8000-000000000002"),
      ]),
    ))

  // A row the terminal cannot attribute to a session refuses the reply.
  let assert Error(_) =
    protocol.decode(
      "{\"v\":2,\"reply_to\":5,\"event\":\"sessions.activity\",\"body\":{\"activity\":[{\"state\":\"idle\"}]}}",
    )
    as "a row without an identity is a daemon fault"
}

pub fn creation_allows_empty_configuration_but_bounds_explicit_paths_test() {
  let epoch = protocol.Epoch("current")
  let assert Ok(encoded) =
    protocol.encode(
      1,
      protocol.CreateSession("key", "/work", "New session", ""),
      epoch,
    )
    as "omitted config can reach the daemon's inherited defaults"
  assert string.contains(encoded, "\"configuration\":\"\"")
  let assert Error(_) =
    protocol.encode(
      1,
      protocol.CreateSession(
        "key",
        "/work",
        "New session",
        string.repeat("x", 4097),
      ),
      epoch,
    )
    as "allowing absence does not relax the explicit path ceiling"
}

pub fn domain_status_counts_are_separate_required_observations_test() {
  let frame =
    "{\"v\":2,\"reply_to\":1,\"event\":\"status\",\"body\":{\"epoch\":\"current\",\"ready\":true,\"capacity\":4,\"occupied\":2,\"opening\":0,\"resident\":1,\"stopping\":1,\"blocked\":0,\"domain_capacity\":8,\"domain_occupied\":3,\"domain_blocked\":1}}"
  let assert Ok(protocol.Answer(_, _, protocol.StatusReply(summary))) =
    protocol.decode(frame)
    as "domain counts do not replace the independent runtime counts"
  assert summary.occupied == 2
  assert summary.domain_capacity == 8
  assert summary.domain_occupied == 3
  assert summary.domain_blocked == 1
  list.each(["domain_capacity", "domain_occupied", "domain_blocked"], fn(key) {
    let wrong_type = string.replace(frame, "\"" <> key <> "\":", "\"unknown\":")
    let assert Error(_) = protocol.decode(wrong_type)
      as "a missing domain observation is not silently reported as zero"
  })
}

// The owner actions retain the epoch fence while archive listing stays read-only.
pub fn archive_controls_encode_with_their_authority_fields_test() {
  let id = "00000000-0000-7000-8000-000000000001"
  let epoch = protocol.Epoch("current")
  list.each(
    [
      #(protocol.ArchiveSession(id), "sessions.archive"),
      #(protocol.RestoreSession(id), "sessions.restore"),
    ],
    fn(pair) {
      assert protocol.mutates(pair.0)
      assert protocol.encode(7, pair.0, epoch)
        == Ok(
          "{\"v\":2,\"id\":7,\"cmd\":\""
          <> pair.1
          <> "\",\"body\":{\"epoch\":\"current\",\"session_id\":\""
          <> id
          <> "\"}}",
        )
    },
  )
  assert !protocol.mutates(protocol.ListArchivedSessions("", None))
  assert protocol.encode(7, protocol.ListArchivedSessions("", None), epoch)
    == Ok(
      "{\"v\":2,\"id\":7,\"cmd\":\"sessions.archived\",\"body\":{\"after\":\"\"}}",
    )
}

fn pad(index: Int) -> String {
  case index < 10 {
    True -> "0" <> int.to_string(index)
    False -> int.to_string(index)
  }
}
