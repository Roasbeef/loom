//// Round trips for `cap/history`: the exact arguments each stub puts on
//// the wire, the decoding of each result shape, the limit clamp, and the
//// mapping of every refusal code.
////
//// The channel is faked rather than driven, as in `cap/search_test`, so
//// what is under test is only this module's marshalling. The argument
//// assertions are whole-map comparisons on purpose: a key renamed on one
//// side of the wire is the failure this suite exists to catch, and a
//// per-field check would let an extra key through.

import cap/history
import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack
import gleam/erlang/process
import gleam/list
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// --- helpers ------------------------------------------------------------

fn install_fake(
  with call: fn(String, msgpack.MsgPackValue, Int) ->
    Result(msgpack.MsgPackValue, channel.CallError),
) -> Nil {
  dispatch.install(channel.Channel(call:))
}

fn map(entries: List(#(String, msgpack.MsgPackValue))) -> msgpack.MsgPackValue {
  wire.args(entries)
}

fn text(value: String) -> msgpack.MsgPackValue {
  msgpack.StringValue(value)
}

fn number(value: Int) -> msgpack.MsgPackValue {
  msgpack.IntValue(value)
}

// A fake that answers every call with `reply`, handing back a reader for
// the capability name and the arguments it was given. The fake runs on
// the calling process, so a subject carries both out of the closure.
fn answering(
  reply: msgpack.MsgPackValue,
) -> fn() -> Result(#(String, msgpack.MsgPackValue), Nil) {
  let sent = process.new_subject()
  install_fake(with: fn(cap, args, _deadline) {
    process.send(sent, #(cap, args))
    Ok(reply)
  })
  fn() { process.receive(sent, 100) }
}

fn one_hit() -> msgpack.MsgPackValue {
  map([
    #("hits", msgpack.ArrayValue([hit("s-1", "e-1", "a [timeout] here")])),
    #("limit", number(5)),
  ])
}

fn hit(
  session: String,
  entry: String,
  snippet: String,
) -> msgpack.MsgPackValue {
  map([
    #("session", text(session)),
    #("entry", text(entry)),
    #("snippet", text(snippet)),
  ])
}

// --- history.search -----------------------------------------------------

/// A search puts the query, the clamped limit and the scope name on the
/// wire, and the reply decodes into hits plus the limit that ran.
pub fn search_round_trip_test() {
  let take = answering(one_hit())

  assert history.search(
      for: "timeout retry",
      limit: 5,
      scope: history.Repository,
    )
    == Ok(history.Found(
      hits: [
        history.Hit(session: "s-1", entry: "e-1", snippet: "a [timeout] here"),
      ],
      limit: 5,
    ))

  assert take()
    == Ok(#(
      "history.search",
      map([
        #("query", text("timeout retry")),
        #("limit", number(5)),
        #("scope", text("repository")),
      ]),
    ))
}

/// `ThisSession` is the other scope name, and it is the only other one.
pub fn search_session_scope_test() {
  let take = answering(one_hit())
  let _found = history.search(for: "x", limit: 1, scope: history.ThisSession)
  let assert Ok(#(_cap, args)) = take() as "the search arm must be reached"
  assert wire.string_field(args, "scope") == Ok("session")
}

/// `search_for` is the whole-repository shape with the default limit.
pub fn search_for_uses_the_defaults_test() {
  let take = answering(one_hit())
  let _found = history.search_for("hashline replay")
  assert take()
    == Ok(#(
      "history.search",
      map([
        #("query", text("hashline replay")),
        #("limit", number(history.default_limit)),
        #("scope", text("repository")),
      ]),
    ))
}

/// The limit is clamped before it is marshalled, in both directions. A
/// non-positive one is the dangerous direction — SQLite reads a negative
/// `LIMIT` as unbounded — so it clamps up rather than down to nothing.
pub fn search_clamps_the_limit_on_the_wire_test() {
  let rows = [
    #(0, history.min_limit),
    #(-1, history.min_limit),
    #(1, 1),
    #(10_000, history.max_limit),
  ]
  list.each(rows, fn(row) {
    let take = answering(one_hit())
    let _found =
      history.search(for: "x", limit: row.0, scope: history.Repository)
    let assert Ok(#(_cap, args)) = take() as "the search arm must be reached"
    assert wire.int_field(args, "limit") == Ok(row.1)
  })
}

/// `clamp_limit` is the same function the harness applies, so a caller
/// can predict what its query will run with.
pub fn clamp_limit_test() {
  assert history.clamp_limit(0) == history.min_limit
  assert history.clamp_limit(10_000) == history.max_limit
  assert history.clamp_limit(7) == 7
}

/// No matches is an empty list and never an error, so a program that
/// found nothing takes the same branch as one that found something.
pub fn search_with_no_hits_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(map([#("hits", msgpack.ArrayValue([])), #("limit", number(10))]))
  })

  assert history.search_for("nothing at all")
    == Ok(history.Found(hits: [], limit: 10))
}

/// The limit the harness ran with is read back rather than assumed: a
/// clamp applied on the far side is visible to the caller.
pub fn search_reports_the_limit_that_ran_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(map([#("hits", msgpack.ArrayValue([])), #("limit", number(50))]))
  })

  let assert Ok(found) = history.search_for("x")
    as "a search must decode its answer"
  assert found.limit == 50
}

/// A hit missing a field is a typed error, never a crash and never a
/// hit with an invented empty field.
pub fn search_with_a_malformed_hit_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #(
          "hits",
          msgpack.ArrayValue([
            map([#("session", text("s-1")), #("entry", text("e-1"))]),
          ]),
        ),
        #("limit", number(10)),
      ]),
    )
  })

  assert history.search_for("x")
    == Error(history.HistoryUnavailable(
      "bad history.search result: missing field snippet",
    ))
}

/// A reply with no `limit` is a typed error too: the bound is part of
/// the answer, so a missing one must not read as zero.
pub fn search_without_a_limit_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(map([#("hits", msgpack.ArrayValue([]))]))
  })

  assert history.search_for("x")
    == Error(history.HistoryUnavailable(
      "bad history.search result: missing field limit",
    ))
}

// --- history.read -------------------------------------------------------

/// `read` sends the two canonical ids and decodes the entry's JSON text.
pub fn read_round_trip_test() {
  let take = answering(map([#("entry", text("{\"type\":\"user\"}"))]))

  assert history.read(session: "s-1", entry: "e-1") == Ok("{\"type\":\"user\"}")

  assert take()
    == Ok(#(
      "history.read",
      map([#("session", text("s-1")), #("entry", text("e-1"))]),
    ))
}

/// A reply of the wrong shape is a typed error.
pub fn read_with_a_malformed_reply_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(map([#("entry", number(7))]))
  })

  assert history.read(session: "s-1", entry: "e-1")
    == Error(history.HistoryUnavailable(
      "bad history.read result: field entry is not a string",
    ))
}

// --- error mapping ------------------------------------------------------

/// Every refusal code the harness mints maps to the variant of the same
/// name, and an unknown code survives verbatim — including the
/// `unsupported_cap` a host with no index answers with.
pub fn error_mapping_test() {
  assert refused("history_unavailable", "no holder")
    == history.IndexUnavailable(reason: "no holder")
  assert refused("history_refused", "bad fts5")
    == history.IndexRefused(reason: "bad fts5")
  assert refused("history_not_ready", "opening")
    == history.IndexNotReady(reason: "opening")
  assert refused("history_busy", "serving another")
    == history.IndexBusy(reason: "serving another")
  assert refused("invalid_argument", "`query` is empty")
    == history.InvalidQuery(message: "`query` is empty")
  assert refused("unsupported_cap", "not routed")
    == history.HistoryFailed(code: "unsupported_cap", message: "not routed")
}

// Drive one refusal through `search`, which is the arm every code can
// reach.
fn refused(code: String, message: String) -> history.HistoryError {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Denied(code, message))
  })
  let assert Error(error) = history.search_for("x")
    as "a denied call must answer an error"
  error
}

/// A dead channel fails both calls the same way.
pub fn channel_down_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Unreachable("broker exited"))
  })

  assert history.search_for("x")
    == Error(history.HistoryUnavailable("broker exited"))
  assert history.read(session: "s", entry: "e")
    == Error(history.HistoryUnavailable("broker exited"))
}
