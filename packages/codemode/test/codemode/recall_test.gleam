//// The recall router: what a `history.*` or `memory.remember` frame
//// becomes, what the injected seam is asked, what shape the answer comes
//// back in, what code a refusal keeps, and what an absent plane does.
////
//// These drive `recall.routing` directly against scripted closures,
//// because everything worth proving *here* is carriage. That the index
//// and the memory session are the tools' own is a fact about the types
//// rather than a thing to assert: the closures below fill
//// `tools/history.History` and `tools/remember.Memory`, so a router that
//// took anything else would not compile.
////
//// The wire keys are asserted by name rather than by round-tripping
//// through `cap/history`, because the two packages share no dependency —
//// they are the two ends of one wire, not peers. Each side pins its own
//// half, and a key renamed here without being renamed there is a decode
//// failure a program reads as `HistoryUnavailable`.

import broker/budget
import broker/exec
import broker/framing.{type CapOutcome}
import broker/policy
import codemode/identity.{type PhaseIdentity}
import codemode/recall
import codemode/satellite
import core/clock
import core/ids
import core/json
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tools/history
import tools/remember
import tools/tool

const t = 1_700_000_000_000

// --- the scripted seam ---------------------------------------------------------

// What the scripted closures were asked, in the terms the arm decoded
// rather than the terms the wire carried: a test that recorded the raw
// map would pass while the decoding dropped a field on the floor.
type Seen {
  SearchAsked(query: String, limit: Int, scope: history.Scope)
  ReadAsked(session: ids.SessionId, entry: ids.EntryId)
  RememberAsked(note: String)
}

fn recorder() -> Subject(Seen) {
  process.new_subject()
}

fn drain(seen: Subject(Seen)) -> List(Seen) {
  case process.receive(seen, within: 0) {
    Error(Nil) -> []
    Ok(one) -> [one, ..drain(seen)]
  }
}

fn a_hit() -> history.Hit {
  history.Hit(session: "s-1", entry: "e-1", snippet: "a [timeout] here")
}

fn an_entry() -> json.JsonValue {
  json.Object([#("type", json.String("user"))])
}

// A seam whose every closure succeeds, recording what it was asked.
fn answering(seen: Subject(Seen)) -> recall.Recall {
  recall.Recall(
    index: Some(
      history.History(
        search: fn(query, limit, scope) {
          process.send(seen, SearchAsked(query:, limit:, scope:))
          Ok([a_hit()])
        },
        read: fn(session, entry) {
          process.send(seen, ReadAsked(session:, entry:))
          Ok(an_entry())
        },
      ),
    ),
    store: Some(
      remember.Memory(remember: fn(note) {
        process.send(seen, RememberAsked(note:))
        Ok(Nil)
      }),
    ),
  )
}

// A seam whose closures all refuse, so one refusal can be driven through
// whichever arm reaches it.
fn refusing(index: history.Refusal, store: remember.Refusal) -> recall.Recall {
  recall.Recall(
    index: Some(
      history.History(
        search: fn(_query, _limit, _scope) { Error(index) },
        read: fn(_session, _entry) { Error(index) },
      ),
    ),
    store: Some(remember.Memory(remember: fn(_note) { Error(store) })),
  )
}

// The router under test, over an inner arm that records nothing and
// answers a distinctive refusal, so "handed down untouched" is provable
// rather than indistinguishable from "refused here".
const passed_through = "reached_the_inner_router"

fn routed(seam: recall.Recall) -> satellite.CapRouter {
  recall.routing(seam, over: fn(request: satellite.CapRequest) {
    Error(satellite.CapDenial(code: passed_through, message: request.cap))
  })
}

// Routes one call and runs the plan it produced, which is what the host's
// worker process does.
fn serviced(
  seam: recall.Recall,
  cap: String,
  args: MsgPackValue,
) -> CapOutcome {
  let assert Ok(satellite.ServedHere(serve:)) = routed(seam)(request(cap, args))
    as { "the recall router must service " <> cap }
  serve()
}

fn refused(
  seam: recall.Recall,
  cap: String,
  args: MsgPackValue,
) -> satellite.CapDenial {
  let assert Error(denial) = routed(seam)(request(cap, args))
    as { "the recall router must refuse " <> cap }
  denial
}

fn request(cap: String, args: MsgPackValue) -> satellite.CapRequest {
  satellite.CapRequest(
    cap:,
    args:,
    identity: phase(),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    ordinal: 0,
  )
}

fn phase() -> PhaseIdentity {
  let generator = ids.generator(clock.fixed(at: t), seed: 23)
  let #(op, generator) = ids.mint_op(generator)
  let #(entry, _generator) = ids.mint_entry(generator)
  identity.run_phase(identity.for_execution(
    op_id: op,
    step_id: ids.entry_id_to_string(entry),
    budget: budget.Budget(max_outstanding: 8, deadline_ms: t + 60_000),
  ))
}

fn map(fields: List(#(String, MsgPackValue))) -> MsgPackValue {
  msgpack.MapValue(
    list.map(fields, fn(field) { #(msgpack.StringValue(field.0), field.1) }),
  )
}

fn text(value: String) -> MsgPackValue {
  msgpack.StringValue(value)
}

fn int(value: Int) -> MsgPackValue {
  msgpack.IntValue(value)
}

fn field(value: MsgPackValue, key: String) -> Result(MsgPackValue, Nil) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _other -> Error(Nil)
  }
}

fn ok_value(outcome: CapOutcome) -> MsgPackValue {
  let assert framing.CapOk(value:) = outcome
    as "the call must have been serviced"
  value
}

// A canonical pair, minted rather than spelled, because `read`'s arm
// parses both and a hand-written id would be testing the spelling.
fn canonical_ids() -> #(String, String) {
  let generator = ids.generator(clock.fixed(at: t), seed: 7)
  let #(session, generator) = ids.mint_session(generator)
  let #(entry, _generator) = ids.mint_entry(generator)
  #(ids.session_id_to_string(session), ids.entry_id_to_string(entry))
}

fn search_args(query: String, limit: Int, scope: String) -> MsgPackValue {
  map([
    #("query", text(query)),
    #("limit", int(limit)),
    #("scope", text(scope)),
  ])
}

// --- every serviced capability routes -------------------------------------------

/// `serviced_caps` and the router's `case` arms are two lists that could
/// drift, since a Gleam pattern cannot name a constant. Walking the
/// published list is what keeps them one list.
pub fn every_serviced_cap_routes_test() {
  let seen = recorder()
  let seam = answering(seen)
  list.each(recall.serviced_caps, fn(cap) {
    // Routed, not passed down: a missing argument is this router's own
    // refusal, and the inner arm would have answered `passed_through`.
    assert refused(seam, cap, map([])).code == recall.invalid_argument_code
  })
  assert drain(seen) == []
}

/// A capability this router does not answer reaches the inner one.
pub fn an_unknown_cap_falls_through_test() {
  let seen = recorder()
  let denial = refused(answering(seen), "proc.run", map([]))
  assert denial.code == passed_through
  assert denial.message == "proc.run"
}

// --- what the arms carry in ------------------------------------------------------

pub fn a_search_routes_with_every_argument_decoded_test() {
  let seen = recorder()
  let _answer =
    serviced(
      answering(seen),
      "history.search",
      search_args("retry", 5, "repository"),
    )
  assert drain(seen)
    == [SearchAsked(query: "retry", limit: 5, scope: history.Repository)]
}

pub fn a_search_carries_the_session_scope_test() {
  let seen = recorder()
  let _answer =
    serviced(
      answering(seen),
      "history.search",
      search_args("retry", 5, "session"),
    )
  let assert [SearchAsked(scope:, ..)] = drain(seen)
    as "the search arm must reach its closure"
  assert scope == history.ThisSession
}

/// The limit is clamped by `tools/history.clamp_limit` — the tool's own
/// function, so the two doors cannot come to hold different numbers —
/// and the clamp runs here because this side of the wire is the trusted
/// one. A satellite can put any integer on the wire it likes.
pub fn a_search_limit_is_clamped_before_the_index_sees_it_test() {
  let rows = [
    #(0, history.min_limit),
    #(-1, history.min_limit),
    #(10_000, history.max_limit),
    #(7, 7),
  ]
  list.each(rows, fn(row) {
    let seen = recorder()
    let _answer =
      serviced(
        answering(seen),
        "history.search",
        search_args("retry", row.0, "repository"),
      )
    let assert [SearchAsked(limit:, ..)] = drain(seen)
      as "the search arm must reach its closure"
    assert limit == row.1
  })
}

/// The query reaches the index already trimmed, which is what
/// `tools/history.History`'s constructor contract asks for.
pub fn a_search_query_is_trimmed_test() {
  let seen = recorder()
  let _answer =
    serviced(
      answering(seen),
      "history.search",
      search_args("  retry  ", 5, "repository"),
    )
  let assert [SearchAsked(query:, ..)] = drain(seen)
    as "the search arm must reach its closure"
  assert query == "retry"
}

pub fn a_read_routes_with_both_ids_parsed_test() {
  let seen = recorder()
  let #(session_text, entry_text) = canonical_ids()
  let _answer =
    serviced(
      answering(seen),
      "history.read",
      map([#("session", text(session_text)), #("entry", text(entry_text))]),
    )
  let assert [ReadAsked(session:, entry:)] = drain(seen)
    as "the read arm must reach its closure"
  assert ids.session_id_to_string(session) == session_text
  assert ids.entry_id_to_string(entry) == entry_text
}

/// The note is handed over untrimmed: redaction happens on the far side
/// of the seam and measures the text it was given, so trimming here
/// would be a second place deciding what the stored bytes are.
pub fn a_remember_routes_with_the_note_untouched_test() {
  let seen = recorder()
  let _answer =
    serviced(
      answering(seen),
      "memory.remember",
      map([#("note", text("  a lesson  "))]),
    )
  assert drain(seen) == [RememberAsked(note: "  a lesson  ")]
}

// --- what the arms carry out -----------------------------------------------------

pub fn a_search_answers_hits_and_the_limit_that_ran_test() {
  // `cap/history.decode_found` reads exactly `hits` and `limit` and
  // refuses anything else as `bad history.search result`, so the two
  // field names are the contract.
  let seen = recorder()
  let value =
    ok_value(serviced(
      answering(seen),
      "history.search",
      search_args("retry", 5, "repository"),
    ))
  assert field(value, "limit") == Ok(int(5))
  let assert Ok(msgpack.ArrayValue(items: [first])) = field(value, "hits")
    as "a search must answer an array of hits"
  assert field(first, "session") == Ok(text("s-1"))
  assert field(first, "entry") == Ok(text("e-1"))
  assert field(first, "snippet") == Ok(text("a [timeout] here"))
}

/// The `limit` on the wire is the clamped one, not the one asked for:
/// that is the whole point of reporting it.
pub fn a_search_answers_the_clamped_limit_test() {
  let seen = recorder()
  let value =
    ok_value(serviced(
      answering(seen),
      "history.search",
      search_args("retry", 10_000, "repository"),
    ))
  assert field(value, "limit") == Ok(int(history.max_limit))
}

pub fn a_read_answers_the_entry_as_json_text_test() {
  let seen = recorder()
  let #(session_text, entry_text) = canonical_ids()
  let value =
    ok_value(serviced(
      answering(seen),
      "history.read",
      map([#("session", text(session_text)), #("entry", text(entry_text))]),
    ))
  assert field(value, "entry") == Ok(text(json.to_string(an_entry())))
}

pub fn a_remember_answers_nothing_at_all_test() {
  let seen = recorder()
  let value =
    ok_value(serviced(
      answering(seen),
      "memory.remember",
      map([#("note", text("a lesson"))]),
    ))
  assert value == msgpack.MapValue([])
}

// --- what the arms refuse --------------------------------------------------------

pub fn a_missing_argument_is_invalid_in_band_test() {
  // Refused at *plan* time, before any closure runs: a call that cannot
  // be decoded has nothing to ask anybody.
  let seen = recorder()
  let seam = answering(seen)
  list.each(
    [
      #("history.search", map([#("query", text("x"))])),
      #("history.read", map([#("session", text("s"))])),
      #("memory.remember", map([])),
    ],
    fn(row) {
      let denial = refused(seam, row.0, row.1)
      assert denial.code == recall.invalid_argument_code
      assert string.contains(denial.message, "is missing")
    },
  )
  assert drain(seen) == []
}

pub fn an_empty_query_is_refused_before_the_index_test() {
  // The index answers an empty query with a fault about full-text
  // syntax, which a program cannot act on. Refused here instead, in the
  // words of the thing it should do next.
  let seen = recorder()
  let denial =
    refused(
      answering(seen),
      "history.search",
      search_args("   \n ", 5, "repository"),
    )
  assert denial.code == recall.invalid_argument_code
  assert string.contains(denial.message, "`query` is empty")
  assert drain(seen) == []
}

pub fn an_unknown_scope_is_refused_rather_than_defaulted_test() {
  let seen = recorder()
  let denial =
    refused(answering(seen), "history.search", search_args("x", 5, "repo"))
  assert denial.code == recall.invalid_argument_code
  assert string.contains(denial.message, "`repo`")
  assert drain(seen) == []
}

pub fn a_non_canonical_id_is_refused_before_the_index_test() {
  let seen = recorder()
  let #(session_text, entry_text) = canonical_ids()
  let rows = [
    #(
      map([#("session", text("not-an-id")), #("entry", text(entry_text))]),
      "`session`",
    ),
    #(
      map([#("session", text(session_text)), #("entry", text("nope"))]),
      "`entry`",
    ),
  ]
  list.each(rows, fn(row) {
    let denial = refused(answering(seen), "history.read", row.0)
    assert denial.code == recall.invalid_argument_code
    assert string.contains(denial.message, row.1)
  })
  assert drain(seen) == []
}

/// Every index refusal keeps the harness's own sentence under the code
/// `cap/history` turns back into the variant of the same name.
pub fn every_index_refusal_has_its_own_code_test() {
  let rows = [
    #(
      history.IndexUnavailable(reason: "no holder"),
      recall.history_unavailable_code,
    ),
    #(history.IndexRefused(reason: "bad fts5"), recall.history_refused_code),
    #(history.IndexNotReady(reason: "opening"), recall.history_not_ready_code),
    #(history.IndexBusy(reason: "elsewhere"), recall.history_busy_code),
  ]
  list.each(rows, fn(row) {
    let seam = refusing(row.0, remember.NothingToRemember)
    let outcome =
      serviced(seam, "history.search", search_args("x", 5, "repository"))
    assert outcome == framing.CapErr(code: row.1, message: reason_of(row.0))
    // And the same refusal reaches a `read` under the same code, since
    // both arms share one rendering.
    let #(session_text, entry_text) = canonical_ids()
    let read =
      serviced(
        seam,
        "history.read",
        map([#("session", text(session_text)), #("entry", text(entry_text))]),
      )
    assert read == framing.CapErr(code: row.1, message: reason_of(row.0))
  })
}

fn reason_of(refusal: history.Refusal) -> String {
  case refusal {
    history.IndexUnavailable(reason:) -> reason

    history.IndexRefused(reason:) -> reason

    history.IndexNotReady(reason:) -> reason

    history.IndexBusy(reason:) -> reason
  }
}

/// Every memory refusal keeps its own code, and the two arithmetic ones
/// render their numbers into the sentence.
pub fn every_memory_refusal_has_its_own_code_test() {
  let rows = [
    #(remember.MemoryBusy(reason: "a run holds it"), recall.memory_busy_code),
    #(
      remember.MemoryUnavailable(reason: "could not open"),
      recall.memory_unavailable_code,
    ),
    #(
      remember.NoteTooLong(chars: 2400, limit: remember.max_note_chars),
      recall.note_too_long_code,
    ),
    #(
      remember.CeilingReached(limit: remember.max_notes),
      recall.memory_full_code,
    ),
    #(remember.NothingToRemember, recall.note_empty_code),
  ]
  list.each(rows, fn(row) {
    let seam = refusing(history.IndexBusy(reason: "unused"), row.0)
    let outcome =
      serviced(seam, "memory.remember", map([#("note", text("a lesson"))]))
    let assert framing.CapErr(code:, message:) = outcome
      as "a refused note must answer in band"
    assert code == row.1
    assert message != ""
  })
}

pub fn an_over_long_note_names_both_numbers_test() {
  let seam =
    refusing(
      history.IndexBusy(reason: "unused"),
      remember.NoteTooLong(chars: 2400, limit: remember.max_note_chars),
    )
  let assert framing.CapErr(code: _code, message:) =
    serviced(seam, "memory.remember", map([#("note", text("a lesson"))]))
    as "a refused note must answer in band"
  assert string.contains(message, "2400")
  assert string.contains(message, "2000")
}

// --- the codes are the tools' own ------------------------------------------------

/// The codes this router mints are the strings the two tools already put
/// in their own failure details, restated here because the tools keep
/// theirs private. Asserted against the tools' rendering rather than
/// against a second literal, so the two halves cannot drift in silence.
pub fn the_wire_codes_match_the_tool_details_test() {
  let index_rows = [
    #(history.IndexUnavailable(reason: "r"), recall.history_unavailable_code),
    #(history.IndexRefused(reason: "r"), recall.history_refused_code),
    #(history.IndexNotReady(reason: "r"), recall.history_not_ready_code),
    #(history.IndexBusy(reason: "r"), recall.history_busy_code),
  ]
  list.each(index_rows, fn(row) {
    assert detail_error(history.refusal_outcome(row.0)) == Ok(row.1)
    assert recall.history_denial(row.0).code == row.1
  })

  let memory_rows = [
    #(remember.MemoryBusy(reason: "r"), recall.memory_busy_code),
    #(remember.MemoryUnavailable(reason: "r"), recall.memory_unavailable_code),
    #(remember.NoteTooLong(chars: 1, limit: 2), recall.note_too_long_code),
    #(remember.CeilingReached(limit: 2), recall.memory_full_code),
    #(remember.NothingToRemember, recall.note_empty_code),
  ]
  list.each(memory_rows, fn(row) {
    assert detail_error(remember.refusal_outcome(row.0)) == Ok(row.1)
    assert recall.memory_denial(row.0).code == row.1
  })
}

// The `error` field of a tool failure's structured details, which is
// where each tool spells its own refusal code.
fn detail_error(outcome: tool.ToolOutcome) -> Result(String, Nil) {
  case outcome.details {
    option.Some(json.Object(fields)) ->
      list.find_map(fields, fn(field) {
        case field.0, field.1 {
          "error", json.String(code) -> Ok(code)
          _key, _value -> Error(Nil)
        }
      })

    _other -> Error(Nil)
  }
}

// --- an absent plane -------------------------------------------------------------

/// A host whose index would not open leaves the two `history.*`
/// capabilities **unrouted**, so a call meets the inner router's
/// unknown-capability denial rather than a door that always refuses.
/// That is `cap/schedule`'s posture: recall is a convenience over a
/// rebuildable projection, and a door that could only ever refuse is
/// worse than no door.
pub fn an_absent_index_leaves_its_capabilities_unrouted_test() {
  let seen = recorder()
  let seam = recall.Recall(..answering(seen), index: None)
  assert refused(seam, "history.search", search_args("x", 5, "repository")).code
    == passed_through
  let #(session_text, entry_text) = canonical_ids()
  assert refused(
      seam,
      "history.read",
      map([#("session", text(session_text)), #("entry", text(entry_text))]),
    ).code
    == passed_through
  // The memory half is untouched by the index's absence.
  let value =
    ok_value(serviced(seam, "memory.remember", map([#("note", text("x"))])))
  assert value == msgpack.MapValue([])
  assert drain(seen) == [RememberAsked(note: "x")]
}

/// And the same in the other direction.
pub fn an_absent_store_leaves_its_capability_unrouted_test() {
  let seen = recorder()
  let seam = recall.Recall(..answering(seen), store: None)
  assert refused(seam, "memory.remember", map([#("note", text("x"))])).code
    == passed_through
  let _answer =
    serviced(seam, "history.search", search_args("x", 5, "repository"))
  assert drain(seen)
    == [SearchAsked(query: "x", limit: 5, scope: history.Repository)]
}

/// `none()` routes nothing at all, which is what a host that opened
/// neither plane serves.
pub fn a_host_with_neither_plane_routes_nothing_test() {
  list.each(recall.serviced_caps, fn(cap) {
    assert refused(recall.none(), cap, map([])).code == passed_through
  })
  assert recall.serviced_caps_on(recall.none()) == []
}

/// What is advertised is what is routed, half by half — the sentence a
/// model is charged for on every request must not claim a door this host
/// did not open.
pub fn the_advertised_capabilities_are_the_routed_ones_test() {
  let seen = recorder()
  let seam = answering(seen)
  assert recall.serviced_caps_on(seam) == recall.serviced_caps
  assert recall.serviced_caps_on(recall.Recall(..seam, index: None))
    == [recall.remember_cap]
  assert recall.serviced_caps_on(recall.Recall(..seam, store: None))
    == [recall.search_cap, recall.read_cap]
}
