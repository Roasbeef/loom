//// The operator board's shape, its size bound, the authority each principal
//// reaches it with, and the hint a committed mutation sends.
////
//// The bound is checked on the pure renderer with generated inputs, because a
//// catalogue cannot hold enough fat rows to reach 48 KiB without minutes of
//// setup. Everything that depends on a real catalogue (visibility, the audit
//// journal, the surface recorded) runs through the operator door against a
//// scratch database named uniquely per test.

import client/evolution/board
import client/evolution/control
import client/evolution/live
import client/evolution/queue
import client/evolution/record
import client/evolution/record_test
import client/evolution/store
import client/internal/ffi_os
import core/clock
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import qcheck
import storage/access

// --- the renderer -----------------------------------------------------------

fn candidate_named(index: Int, description_bytes: Int) -> record.Candidate {
  record.identified(
    record.Candidate(
      ..record_test.candidate(),
      name: "c" <> int.to_string(index),
      description: string.repeat("d", description_bytes),
    ),
  )
}

fn row(candidate: record.Candidate) -> store.Row {
  store.Row(candidate:, approval: None, evidence: [], selected: None)
}

fn selection_of(candidate: record.Candidate) -> record.Selection {
  record.Selection(
    candidate.id,
    record.evidence_placeholder(),
    candidate.scope,
    candidate.name,
    1,
  )
}

fn event(seq: Int, reason_bytes: Int) -> store.Event {
  store.Event(
    seq:,
    at_ms: seq,
    kind: "approved",
    scope: None,
    candidate_id: "",
    name: "c",
    generation: None,
    principal: "operator",
    via: "cli",
    reason: string.repeat("r", reason_bytes),
    request_id: "",
  )
}

fn input(
  rows: List(store.Row),
  selections: List(record.Selection),
  history: List(store.Event),
  history_omitted: Int,
) -> board.Input {
  board.Input(
    session_id: "session-a",
    identity: record_test.candidate().identity,
    board: store.Board(rows:, selections:, history:, history_omitted:),
    published: None,
    waiting: [],
  )
}

fn field(value: json.JsonValue, name: String) -> json.JsonValue {
  let assert json.Object(fields) = value as "the board is an object"
  let assert Ok(found) = list.key_find(fields, name)
    as "the expected board field exists"
  found
}

fn items(value: json.JsonValue, name: String) -> List(json.JsonValue) {
  let assert json.Array(found) = field(value, name)
    as "the board field is an array"
  found
}

fn omitted(value: json.JsonValue, name: String) -> Int {
  let assert json.Int(count) = field(field(value, "omitted"), name)
    as "the omitted count is an integer"
  count
}

fn names(value: json.JsonValue) -> List(String) {
  list.map(items(value, "candidates"), fn(candidate) {
    let assert json.String(name) = field(candidate, "name")
      as "a candidate row has a name"
    name
  })
}

pub fn an_empty_board_has_the_frozen_shape_test() {
  let value = board.value(input([], [], [], 0))
  let assert json.Object(fields) = value
  list.map(fields, fn(pair) { pair.0 })
  |> should.equal([
    "version", "session", "candidates", "selections", "published", "pending",
    "history", "omitted",
  ])
  field(value, "version") |> should.equal(json.Int(1))
  field(value, "session") |> should.equal(json.String("session-a"))
  field(value, "published") |> should.equal(json.Null)
  omitted(value, "candidates") |> should.equal(0)
  omitted(value, "history") |> should.equal(0)
}

pub fn a_candidate_row_carries_what_a_panel_draws_test() {
  let candidate = candidate_named(1, 4)
  let evidence =
    record.Evidence(
      id: record.evidence_placeholder(),
      candidate_id: candidate.id,
      identity: record.Identity("older-build", "x", "y"),
      at_ms: 42,
      purpose: record.AuthorTests,
      verdict: record.Inconclusive("timed out"),
      observation: "",
    )
  let selected = selection_of(candidate)
  let value =
    board.value(input(
      [
        store.Row(
          candidate:,
          approval: Some(store.Approval(
            evidence_id: record.evidence_placeholder(),
            principal: "alice",
            via: "web",
          )),
          evidence: [evidence],
          selected: Some(selected),
        ),
      ],
      [selected],
      [],
      0,
    ))
  let assert [one] = items(value, "candidates")
  field(one, "kind") |> should.equal(json.String("extension"))
  field(one, "scope")
  |> should.equal(
    json.Object([
      #("kind", json.String("session")),
      #("session", json.String("session-a")),
    ]),
  )
  field(one, "identity_current")
  |> should.equal(json.Bool(True))
  field(one, "parent") |> should.equal(json.Null)
  field(field(one, "approval"), "by") |> should.equal(json.String("alice"))
  field(field(one, "approval"), "via") |> should.equal(json.String("web"))
  field(field(one, "selected"), "generation") |> should.equal(json.Int(1))
  let assert [seen] = items(one, "evidence")
  field(seen, "verdict") |> should.equal(json.String("inconclusive"))
  field(seen, "reason") |> should.equal(json.String("timed out"))
  field(seen, "identity_current") |> should.equal(json.Bool(False))
  let assert [chosen] = items(value, "selections")
  field(chosen, "published") |> should.equal(json.Bool(False))
}

pub fn the_oldest_history_goes_before_any_candidate_test() {
  let rows = [row(candidate_named(1, 8)), row(candidate_named(2, 8))]
  let history =
    list.map(list.reverse(list.map(counting(64), int.add(_, 1))), fn(seq) {
      event(seq, 2000)
    })
  let value = board.value(input(rows, [], history, 5))
  assert string.byte_size(json.to_string(value)) <= board.max_bytes
  names(value) |> should.equal(["c1", "c2"])
  omitted(value, "candidates") |> should.equal(0)

  // The shown entries are the newest, in the order they arrived, and the
  // count adds what this module dropped to what the store already left out.
  let kept = items(value, "history")
  assert kept != []
  assert list.length(kept) < 64
  let assert Ok(first) = list.first(kept)
  field(first, "seq") |> should.equal(json.Int(64))
  omitted(value, "history") |> should.equal(5 + 64 - list.length(kept))
}

pub fn candidates_go_oldest_first_and_take_their_selections_test() {
  let candidates = list.map(counting(40), candidate_named(_, 2000))
  let assert [newest, ..] = candidates
  let assert Ok(oldest) = list.last(candidates)
  let value =
    board.value(input(
      list.map(candidates, row),
      [selection_of(newest), selection_of(oldest)],
      [],
      0,
    ))
  assert string.byte_size(json.to_string(value)) <= board.max_bytes
  let shown = names(value)
  assert list.length(shown) < 40
  assert shown != []

  // Rows arrive newest first, so what stays is a prefix of them.
  shown
  |> should.equal(
    list.map(counting(list.length(shown)), fn(index) {
      "c" <> int.to_string(index)
    }),
  )
  omitted(value, "candidates") |> should.equal(40 - list.length(shown))

  // The oldest row's selection left with it; the newest row's stayed.
  let chosen =
    list.map(items(value, "selections"), fn(selection) {
      field(selection, "name")
    })
  chosen |> should.equal([json.String("c0")])
}

pub fn the_bound_holds_for_any_catalogue_size_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(60)
    |> qcheck.with_seed(qcheck.seed(2_026_102_301))
  let generator =
    qcheck.return({
      use rows <- qcheck.parameter
      use description <- qcheck.parameter
      use events <- qcheck.parameter
      use reason <- qcheck.parameter
      use older <- qcheck.parameter
      #(rows, description, events, reason, older)
    })
    |> qcheck.apply(qcheck.bounded_int(from: 0, to: 80))
    |> qcheck.apply(qcheck.bounded_int(from: 0, to: 3000))
    |> qcheck.apply(qcheck.bounded_int(from: 0, to: 64))
    |> qcheck.apply(qcheck.bounded_int(from: 0, to: 1500))
    |> qcheck.apply(qcheck.bounded_int(from: 0, to: 4000))

  qcheck.run(config, generator, fn(drawn) {
    let #(row_count, description, event_count, reason, older) = drawn
    let candidates =
      list.map(counting(row_count), candidate_named(_, description))
    let history =
      list.map(counting(event_count), fn(index) {
        event(event_count - index, reason)
      })

    // Every candidate is currently selected, so each row carries a selection
    // that the bound has to pay for.
    let value =
      board.value(input(
        list.map(candidates, row),
        list.map(candidates, selection_of),
        history,
        older,
      ))
    assert string.byte_size(json.to_string(value)) <= board.max_bytes
    assert list.length(items(value, "candidates"))
      + omitted(value, "candidates")
      == row_count
    assert list.length(items(value, "history")) + omitted(value, "history")
      == event_count + older
    assert list.length(items(value, "selections"))
      == list.length(items(value, "candidates"))
  })
}

// The integers from zero up to, and not including, `count`.
fn counting(count: Int) -> List(Int) {
  case count > 0 {
    True -> list.append(counting(count - 1), [count - 1])
    False -> []
  }
}

// --- the catalogue through the operator door --------------------------------

type Fixture {
  Fixture(
    catalogue: store.Store,
    door: control.Seam,
    // Held so the live owner and the queue outlive the test body.
    owner: live.Live,
    front: queue.Queue,
  )
}

fn fixture() -> Fixture {
  let identity = record_test.candidate().identity
  let at = clock.fixed(at: 1_700_000_000_000)
  let assert Ok(catalogue) =
    store.open(
      "build/test_db/evolution-board-"
        <> int.to_string(ffi_os.system_time_ms())
        <> "-"
        <> int.to_string(ffi_os.unique_positive_integer()),
      store.Owner,
      identity,
      at,
    )
    as "the catalogue opens under an owner capability"
  let assert Ok(owner) =
    live.start(
      live.Config(
        clock: clock.fixed(0),
        stage: fn(_) { Error(store.Unavailable("the board never stages")) },
        adopt: fn(_) { Ok(Nil) },
        recover: fn() { Ok(None) },
      ),
    )
    as "the live owner starts"
  let assert Ok(front) = queue.start(owner, clock.fixed(0))
    as "the queue starts"
  let door =
    control.new(
      "session-a",
      "/workspace",
      fn(authority) {
        store.open(store.root(catalogue), authority, identity, at)
      },
      owner,
      front,
      clock.fixed(0),
    )
  Fixture(catalogue:, door:, owner:, front:)
}

fn session_extension() -> record.Candidate {
  record_test.candidate()
}

fn workspace_program() -> record.Candidate {
  record.identified(
    record.Candidate(
      ..record_test.candidate(),
      name: "gleam_fix",
      kind: record.Program,
      scope: record.Workspace("/workspace"),
      files: [#("program.gleam", "pub fn run() { 1 }")],
    ),
  )
}

fn foreign_extension() -> record.Candidate {
  record.identified(
    record.Candidate(
      ..record_test.candidate(),
      name: "elsewhere",
      scope: record.Session("session-b"),
      origin: record.Origin("session-b", "main", "/workspace", None),
    ),
  )
}

// Proposes a candidate and records passing author evidence, and approves it
// as the owner does from a terminal.
fn proposed(fixture: Fixture, candidate: record.Candidate) -> record.Evidence {
  store.propose(fixture.catalogue, candidate) |> should.equal(Ok(candidate))
  let assert Ok(evidence) =
    store.record_evidence(
      fixture.catalogue,
      candidate.id,
      record.AuthorTests,
      record.Passed,
      "{}",
    )
    as "the evaluator's observation is retained"
  evidence
}

fn approved(fixture: Fixture, candidate: record.Candidate) -> record.Evidence {
  let evidence = proposed(fixture, candidate)
  store.approve(
    fixture.catalogue,
    candidate.id,
    evidence.id,
    candidate.scope,
    "operator",
  )
  |> should.equal(Ok(Nil))
  evidence
}

fn arguments(
  candidate: record.Candidate,
  evidence: record.Evidence,
) -> json.JsonValue {
  json.Object([
    #("candidate_id", json.String(record.id_string(candidate.id))),
    #("evidence_id", json.String(record.evidence_string(evidence.id))),
  ])
}

fn read_board(fixture: Fixture, authority: access.Authority) -> json.JsonValue {
  let assert Ok(value) =
    fixture.door.command(
      authority,
      "reader",
      store.Cli,
      "board",
      json.Object([]),
    )
    as "the board answers"
  value
}

fn text(value: json.JsonValue, name: String) -> String {
  let assert json.String(found) = field(value, name) as "the field is a string"
  found
}

pub fn the_owner_reads_every_candidate_and_the_journal_newest_first_test() {
  let fixture = fixture()
  let extension = session_extension()
  let program = workspace_program()
  let foreign = foreign_extension()
  let _ = approved(fixture, extension)
  let _ = approved(fixture, program)
  let _ = approved(fixture, foreign)
  let value = read_board(fixture, access.Owner)
  list.sort(names(value), string.compare)
  |> should.equal(["elsewhere", "example", "gleam_fix"])
  let rows = items(value, "candidates")
  assert list.all(rows, fn(one) { field(one, "approval") != json.Null })

  // Retentions are journalled too and are not history. Each of the three
  // approvals is, newest first.
  let history = items(value, "history")
  list.map(history, fn(one) { text(one, "event") })
  |> should.equal(["approved", "approved", "approved"])
  list.map(history, fn(one) { text(one, "name") })
  |> should.equal(["elsewhere", "gleam_fix", "example"])
  list.map(history, fn(one) { text(one, "principal") })
  |> should.equal(["operator", "operator", "operator"])
  list.map(history, fn(one) { text(one, "via") })
  |> should.equal(["cli", "cli", "cli"])
  omitted(value, "history") |> should.equal(0)
  field(value, "pending") |> should.equal(json.Array([]))
}

pub fn an_observer_reads_only_what_it_may_see_test() {
  let fixture = fixture()
  let _ = approved(fixture, session_extension())
  let _ = approved(fixture, foreign_extension())
  let value = read_board(fixture, access.Participant(access.Observer))

  // The foreign session's candidate and the approval entry that names it are
  // absent, and the count of older entries does not hint that either exists.
  names(value) |> should.equal(["example"])
  let history = items(value, "history")
  list.map(history, fn(one) { text(one, "name") })
  |> should.equal(["example"])
  omitted(value, "history") |> should.equal(0)
}

pub fn an_observer_is_refused_every_mutation_test() {
  let fixture = fixture()
  let extension = session_extension()
  let evidence = proposed(fixture, extension)
  fixture.door.command(
    access.Participant(access.Observer),
    "reader",
    store.Cli,
    "approve",
    arguments(extension, evidence),
  )
  |> should.equal(Error(
    "authority: approval and selection require native operator authority",
  ))
}

pub fn a_member_operator_approves_session_rows_and_is_refused_global_ones_test() {
  let fixture = fixture()
  let extension = session_extension()
  let program = workspace_program()
  let session_evidence = proposed(fixture, extension)
  let program_evidence = proposed(fixture, program)

  // `for_principal` leaves a member exactly as the role cap made it.
  let member =
    control.for_principal(
      access.Participant(access.Operator),
      access.MemberPrincipal,
      "approve",
    )
  fixture.door.command(
    member,
    "alice",
    store.Web,
    "approve",
    arguments(extension, session_evidence),
  )
  |> should.be_ok
  let assert Error(refusal) =
    fixture.door.command(
      member,
      "alice",
      store.Web,
      "approve",
      arguments(program, program_evidence),
    )
  assert string.contains(refusal, "daemon owner")

  // The owner's own page arrives with the same role, and the principal's kind
  // is what lets it through.
  let page =
    control.for_principal(
      access.Participant(access.Operator),
      access.OwnerPrincipal,
      "approve",
    )
  fixture.door.command(
    page,
    "owner",
    store.Web,
    "approve",
    arguments(program, program_evidence),
  )
  |> should.be_ok
}

pub fn the_surface_and_the_principal_reach_the_journal_test() {
  let fixture = fixture()
  let program = workspace_program()
  let evidence = proposed(fixture, program)
  fixture.door.command(
    access.Owner,
    "owner",
    store.Web,
    "approve",
    arguments(program, evidence),
  )
  |> should.be_ok
  let selecting =
    json.Object([
      #("candidate_id", json.String(record.id_string(program.id))),
      #("evidence_id", json.String(record.evidence_string(evidence.id))),
      #("expected_generation", json.Int(0)),
      #("reason", json.String("ship it: it passed")),
      #("request_id", json.String("request-1")),
    ])
  fixture.door.command(
    access.Owner,
    "owner",
    store.Terminal,
    "select",
    selecting,
  )
  |> should.be_ok
  let value = read_board(fixture, access.Owner)
  let assert [chosen, approval] = items(value, "history")
  text(chosen, "event") |> should.equal("selected")
  text(chosen, "name") |> should.equal("gleam_fix")
  text(chosen, "principal") |> should.equal("owner")
  text(chosen, "via") |> should.equal("terminal")
  text(chosen, "reason") |> should.equal("ship it: it passed")
  text(chosen, "request_id") |> should.equal("request-1")
  field(chosen, "generation") |> should.equal(json.Int(1))
  text(approval, "event") |> should.equal("approved")
  text(approval, "via") |> should.equal("web")

  // The row and the selection list agree with the journal, and nothing runs in
  // this session, so the selection is committed and not published.
  let assert [row] = items(value, "candidates")
  field(field(row, "selected"), "generation") |> should.equal(json.Int(1))
  field(field(row, "approval"), "via") |> should.equal(json.String("web"))
  let assert [selection] = items(value, "selections")
  field(selection, "published") |> should.equal(json.Bool(False))
}

// --- the audit journal's reader ---------------------------------------------

pub fn an_old_selection_entry_still_reads_with_a_colon_in_its_reason_test() {
  let candidate = session_extension()
  let selection =
    "{\"candidate\":\""
    <> record.id_string(candidate.id)
    <> "\",\"evidence\":\""
    <> record.evidence_string(record.evidence_placeholder())
    <> "\",\"scope\":{\"kind\":\"session\",\"session\":\"session-a\"},"
    <> "\"name\":\"example\",\"generation\":4}"
  let assert Ok(event) =
    store.event_from(
      "evolution/selected",
      9,
      1000,
      "because: it is better, really: " <> selection,
      [candidate],
    )
  event.reason |> should.equal("because: it is better, really")
  event.generation |> should.equal(Some(4))
  event.name |> should.equal("example")
  event.principal |> should.equal("")
  event.via |> should.equal("")
  event.scope |> should.equal(Some(record.Session("session-a")))
}

pub fn an_unreadable_entry_keeps_its_place_and_names_no_scope_test() {
  let assert Ok(event) =
    store.event_from("evolution/revoked", 12, 2000, "not json", [])
  event.seq |> should.equal(12)
  event.at_ms |> should.equal(2000)
  event.kind |> should.equal("revoked")
  event.scope |> should.equal(None)
  event.candidate_id |> should.equal("")

  // A retention is journalled and is not history.
  store.event_from("evolution/retained", 13, 0, "candidate/abc", [])
  |> should.equal(Error(Nil))
}

// --- the authority each principal reaches the door with ---------------------

pub fn the_owners_page_is_raised_for_everything_but_a_core_change_test() {
  let operator = access.Participant(access.Operator)
  list.each(
    [
      "catalogue",
      "board",
      "approve",
      "revoke",
      "select",
      "rollback",
      "core_status",
    ],
    fn(action) {
      control.for_principal(operator, access.OwnerPrincipal, action)
      |> should.equal(access.Owner)
    },
  )
  list.each(["core_upgrade", "core_downgrade"], fn(action) {
    control.for_principal(operator, access.OwnerPrincipal, action)
    |> should.equal(operator)
  })
}

pub fn a_member_and_an_observer_keep_the_authority_they_hold_test() {
  let operator = access.Participant(access.Operator)
  let observer = access.Participant(access.Observer)
  list.each(
    ["board", "approve", "select", "core_status", "core_upgrade"],
    fn(action) {
      control.for_principal(operator, access.MemberPrincipal, action)
      |> should.equal(operator)
      control.for_principal(observer, access.MemberPrincipal, action)
      |> should.equal(observer)

      // An observer is a cap the owner may have chosen, and a principal's kind
      // does not lift it.
      control.for_principal(observer, access.OwnerPrincipal, action)
      |> should.equal(observer)
      control.for_principal(access.Owner, access.OwnerPrincipal, action)
      |> should.equal(access.Owner)
    },
  )
}

// --- the hint a committed mutation sends ------------------------------------

pub fn a_hint_follows_a_durable_mutation_and_only_a_mutation_test() {
  let fixture = fixture()
  let extension = session_extension()
  let evidence = proposed(fixture, extension)
  let heard = process.new_subject()

  // The hint reads the catalogue, so what it sees is what a woken subscriber
  // would see. An approval absent here would mean the hint overtook the commit.
  let announce = fn() {
    let assert Ok(read) = store.read_board(fixture.catalogue)
    process.send(heard, list.count(read.rows, fn(row) { row.approval != None }))
  }
  let door = control.announcing(fixture.door, announce)
  let ask = fn(authority, action, args) {
    door.command(authority, "operator", store.Cli, action, args)
  }
  ask(access.Owner, "board", json.Object([])) |> should.be_ok
  ask(access.Owner, "catalogue", json.Object([])) |> should.be_ok
  process.receive(heard, 0) |> should.equal(Error(Nil))

  ask(
    access.Participant(access.Observer),
    "approve",
    arguments(extension, evidence),
  )
  |> should.be_error
  process.receive(heard, 0) |> should.equal(Error(Nil))

  ask(access.Owner, "approve", arguments(extension, evidence)) |> should.be_ok
  process.receive(heard, 1000) |> should.equal(Ok(1))
  process.receive(heard, 0) |> should.equal(Error(Nil))

  ask(
    access.Owner,
    "revoke",
    json.Object([
      #("candidate_id", json.String(record.id_string(extension.id))),
      #("reason", json.String("changed my mind")),
    ]),
  )
  |> should.be_ok
  process.receive(heard, 1000) |> should.equal(Ok(0))
}
