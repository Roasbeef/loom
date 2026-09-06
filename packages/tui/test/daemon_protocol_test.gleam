import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui/daemon/protocol

const hello = "{\"v\":2,\"event\":\"hello\",\"body\":{\"protocol\":2,\"epoch\":\"epoch-one\",\"principal\":\"owner\",\"limits\":{\"control_bytes\":65536}}}"

pub fn every_truncated_hello_is_rejected_test() {
  assert protocol.decode(hello)
    == Ok(
      protocol.Greeting(protocol.Hello(
        protocol.Epoch("epoch-one"),
        "owner",
        65_536,
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
