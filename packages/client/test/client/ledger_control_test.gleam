//// The `ledger.*` owner commands (protocol-change/086), without a socket: the
//// replies a daemon builds from its ledger process and the decoders an
//// operator's tool reads them with. The ledger is the fixture scheme's, over a
//// real file, so every rule of the acceptance procedure is the production one.

import client/distribution_plan
import client/ledger_control.{type Handle, Handle}
import client/ledger_holdings
import client/ledger_service
import client/membership_entry.{Upsert}
import client/membership_ledger
import client/remote/orchestrator_port
import core/json
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/ledger_rig as rig
import support/membership_fixture as fixture
import support/membership_log as log

const local = "loom@hub.example.net"

fn text(line: BitArray) -> String {
  let assert Ok(line) = bit_array.to_string(line)
  line
}

// A node `hub` holding genesis and itself, and the lines of the entries that
// would come next: `laptop` enrolled, then revoked.
fn started() -> #(rig.Rig, Handle, List(String)) {
  let history = log.genesis() |> log.enroll("hub", [])
  let started = rig.start("control", log.lines(history), rig.patient, [])
  let next = history |> log.enroll("laptop", ["hub"]) |> log.revoke("laptop")
  let assert [_, _, laptop, gone] = log.lines(next)
  #(
    started,
    Handle(
      service: started.service,
      local:,
      name: "hub",
      asker: ledger_holdings.silent,
    ),
    [
      text(laptop),
      text(gone),
    ],
  )
}

pub fn an_append_reports_what_it_applied_and_the_new_head_test() {
  let #(_, handle, lines) = started()
  let assert [laptop, gone] = lines
  let assert Ok(reply) = ledger_control.append(handle, [laptop, gone])
  let assert Ok(applied) = ledger_control.decode_applied(reply)
  assert applied.applied == 2
  assert applied.head.seq == 3

  // The same lines again are held already, which is not a failure and counts
  // for nothing.
  let assert Ok(reply) = ledger_control.append(handle, [laptop])
  let assert Ok(again) = ledger_control.decode_applied(reply)
  assert again.applied == 0
  assert again.head == applied.head
}

pub fn an_append_names_the_step_that_refused_a_line_test() {
  let #(_, handle, lines) = started()
  let assert [laptop, gone] = lines

  // A line signed by another key is refused before its body is read.
  let assert Ok(head) = ledger_service.head(handle.service, 1000)
  let assert Ok(forged) =
    membership_entry.seal(
      fixture.entry(2, head.id, Upsert(fixture.member("x", []))),
      fixture.stranger_signer(),
    )
  assert ledger_control.append(handle, [text(membership_entry.line(forged))])
    == Error(ledger_control.Invalid("bad_signature"))

  // Garbage is malformed, a line from the future is a gap, and lines before
  // the failing one stay applied.
  assert ledger_control.append(handle, ["not a line"])
    == Error(ledger_control.Invalid("malformed"))
  assert ledger_control.append(handle, [gone])
    == Error(ledger_control.Invalid("gap"))
  let assert Ok(_) = ledger_control.append(handle, [laptop])
  assert ledger_control.append(handle, [gone, "not a line"])
    == Error(ledger_control.Invalid("malformed"))
  let assert Ok(reply) = ledger_control.entries(handle, 0, 64)
  let assert Ok(page) = ledger_control.decode_entries(reply)
  assert page.head_seq == 3
}

pub fn entries_are_the_lines_after_a_sequence_number_test() {
  let #(_, handle, lines) = started()
  let assert Ok(_) = ledger_control.append(handle, lines)
  let assert Ok(reply) = ledger_control.entries(handle, 1, 64)
  let assert Ok(page) = ledger_control.decode_entries(reply)
  assert page.head_seq == 3
  assert page.lines == lines

  // A page may be shorter than the limit asks.
  let assert Ok(reply) = ledger_control.entries(handle, 0, 1)
  let assert Ok(page) = ledger_control.decode_entries(reply)
  assert list.length(page.lines) == 1

  // Past the head there is nothing, and the head says so.
  let assert Ok(reply) = ledger_control.entries(handle, 3, 64)
  let assert Ok(page) = ledger_control.decode_entries(reply)
  assert page.lines == []
  assert page.head_seq == 3
}

pub fn the_status_names_the_standing_the_members_and_the_last_refusal_test() {
  let #(_, handle, lines) = started()
  let assert Ok(reply) = ledger_control.status(handle)
  let assert Ok(status) = ledger_control.decode_status(reply)
  assert status.deployment == fixture.deployment
  assert status.standing == ledger_ok()
  assert status.self_name == "hub"
  assert status.head.seq == 1
  assert status.last_refusal == None

  // The node reports itself at its own head, and a member that has not
  // reported has no sequence number.
  let assert Ok(_) = ledger_control.append(handle, [list_first(lines)])
  let assert Ok(reply) = ledger_control.status(handle)
  let assert Ok(status) = ledger_control.decode_status(reply)
  let assert [hub, laptop] = status.members
  assert hub.name == "hub"
  assert hub.reported_seq == Some(2)
  assert hub.ms_since_report == Some(0)
  assert laptop.name == "laptop"
  assert laptop.reported_seq == None
  assert laptop.directory == "none"

  // A refused line is the last refusal until the next one replaces it.
  assert result_is_error(ledger_control.append(handle, ["not a line"]))
  let assert Ok(reply) = ledger_control.status(handle)
  let assert Ok(status) = ledger_control.decode_status(reply)
  let assert Some(refusal) = status.last_refusal
  assert refusal.step == "malformed"
}

pub fn a_revoked_node_still_reports_that_it_was_revoked_test() {
  let #(_, handle, _) = started()
  let history = log.genesis() |> log.enroll("hub", []) |> log.revoke("hub")
  let assert [_, _, gone] = log.lines(history)
  let assert Ok(_) = ledger_control.append(handle, [text(gone)])
  let assert Ok(reply) = ledger_control.status(handle)
  let assert Ok(status) = ledger_control.decode_status(reply)
  assert status.standing == ledger_control.Revoked
  assert status.members == []
}

pub fn a_page_of_entries_is_cut_to_the_frame_test() {
  // Lines of 20 KB each cannot be three to a frame. The first is always sent,
  // so a caller makes progress.
  let big = string.repeat("a", 20_000)
  assert ledger_control.pages([big, big, big]) == [[big, big], [big]]
  assert ledger_control.pages([]) == []
  assert ledger_control.fit_page([big, big, big]) == [big, big]
  let huge = string.repeat("a", 50_000)
  assert ledger_control.fit_page([huge, big]) == [huge]
  let many = list.repeat("a", 130)
  let pages = ledger_control.pages(many)
  assert list.map(pages, list.length) == [64, 64, 2]
}

pub fn the_decoders_refuse_a_reply_that_is_not_what_was_asked_for_test() {
  assert result_is_error(ledger_control.decode_status(json.Object([])))
  assert result_is_error(ledger_control.decode_entries(json.Null))
  assert result_is_error(
    ledger_control.decode_applied(
      json.Object([
        #("applied", json.String("1")),
        #("head", json.Object([#("seq", json.Int(1))])),
      ]),
    ),
  )

  // An identity must be 64 lowercase hex characters.
  let bad_head =
    json.Object([
      #("seq", json.Int(1)),
      #("id", json.String(string.uppercase(string.repeat("ab", 32)))),
    ])
  assert result_is_error(
    ledger_control.decode_applied(
      json.Object([#("applied", json.Int(1)), #("head", bad_head)]),
    ),
  )
}

// --- holdings --------------------------------------------------------------

fn orchestrating() -> #(rig.Rig, Handle) {
  let history =
    log.genesis()
    |> log.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("hub", []),
        role: distribution_plan.Orchestrator,
      ),
    ))
    |> log.must_push(Upsert(
      membership_entry.Member(
        ..fixture.member("laptop", ["hub"]),
        role: distribution_plan.Orchestrator,
      ),
    ))
  let started = rig.start("holdings", log.lines(history), rig.patient, [])
  #(
    started,
    Handle(
      service: started.service,
      local:,
      name: "hub",
      asker: ledger_holdings.silent,
    ),
  )
}

pub fn holdings_report_each_answer_and_leave_silence_without_a_count_test() {
  let #(_, handle) = orchestrating()
  let asked =
    ledger_control.asking(handle, fn(node) {
      case node {
        "loom@hub.example.net" ->
          Ok(
            orchestrator_port.Held(sessions: 3, placed: [
              orchestrator_port.Placed(
                executor_node: "loom@box.example.net",
                sessions: 2,
              ),
            ]),
          )
        _ -> Error(Nil)
      }
    })
  let assert Ok(reply) = ledger_control.holdings(asked)
  let assert Ok(answers) = ledger_control.decode_holdings(reply)
  assert answers
    == [
      ledger_control.AnswerView(
        name: "hub",
        node: local,
        held: Some(
          ledger_control.HeldView(sessions: 3, placed: [
            ledger_control.PlacedView(node: "loom@box.example.net", sessions: 2),
          ]),
        ),
      ),
      ledger_control.AnswerView(
        name: "laptop",
        node: "loom@laptop.example.net",
        held: None,
      ),
    ]

  // A handle that was given no way to ask reports every orchestrator silent.
  let assert Ok(reply) = ledger_control.holdings(handle)
  let assert Ok(silent) = ledger_control.decode_holdings(reply)
  assert list.all(silent, fn(answer) { answer.held == None })
}

pub fn the_holdings_decoder_refuses_what_it_was_not_asked_for_test() {
  let entry = fn(fields) { json.Object(fields) }
  let named = [
    #("name", json.String("hub")),
    #("node", json.String("loom@hub.example.net")),
  ]
  let reply = fn(entries) {
    json.Object([#("orchestrators", json.Array(entries))])
  }

  // A count below zero, a placement without a node, a reply that is not a list
  // and one with more entries than a ledger holds.
  assert result_is_error(
    ledger_control.decode_holdings(
      reply([
        entry(
          list.append(named, [
            #("sessions", json.Int(-1)),
            #("placed", json.Array([])),
          ]),
        ),
      ]),
    ),
  )
  assert result_is_error(
    ledger_control.decode_holdings(
      reply([
        entry(
          list.append(named, [
            #("sessions", json.Int(1)),
            #("placed", json.Array([json.Object([#("sessions", json.Int(1))])])),
          ]),
        ),
      ]),
    ),
  )
  assert result_is_error(
    ledger_control.decode_holdings(json.Object([#("orchestrators", json.Null)])),
  )
  assert result_is_error(
    ledger_control.decode_holdings(
      reply(list.repeat(entry(named), membership_ledger.max_active + 1)),
    ),
  )

  // A sessions count with no placements is a reply that lost a field.
  assert result_is_error(
    ledger_control.decode_holdings(
      reply([entry(list.append(named, [#("sessions", json.Int(1))]))]),
    ),
  )
}

// Small helpers, kept at the end so the tests above read as a sequence.

fn list_first(lines: List(String)) -> String {
  let assert [first, ..] = lines
  first
}

fn ledger_ok() -> ledger_control.Standing {
  ledger_control.Enrolled
}

fn result_is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}
