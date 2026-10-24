//// The governed-evolution board's decoder, its words and its offers
//// (protocol-change/099).
////
//// The decoder's contract is the one the proposals board keeps: a row of a
//// kind, scope, purpose, verdict, phase or event the client does not know is
//// kept and shown as written, and a row that cannot be read never closes the
//// lane. The example tests pin the shape the daemon sends and the words a host
//// draws. The property tests sweep it: every generated well-formed board
//// decodes whole and keeps its unfamiliar rows, a corrupted row is counted and
//// leaves its neighbours alone, and `read` returns for arbitrary JSON under
//// every action. The generators draw from the board's own vocabulary, so the
//// sweep reaches the decoder's interior and not only its first guard. Every
//// seed is a constant, so the gate is deterministic.

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import qcheck
import session_view/evolution

// --- the shape the daemon sends ----------------------------------------------

fn text(value: String) -> json.JsonValue {
  json.String(value)
}

fn evidence(id: String, verdict: String) -> json.JsonValue {
  json.Object([
    #("evidence_id", text(id)),
    #("purpose", text("author_tests")),
    #("verdict", text(verdict)),
    #("reason", text("")),
    #("at_ms", json.Int(1000)),
    #("identity_current", json.Bool(True)),
  ])
}

fn session_scope(id: String) -> json.JsonValue {
  json.Object([#("kind", text("session")), #("session", text(id))])
}

fn candidate(
  id: String,
  name: String,
  approval: json.JsonValue,
  evidence_rows: List(json.JsonValue),
  selected: json.JsonValue,
) -> json.JsonValue {
  json.Object([
    #("candidate_id", text(id)),
    #("name", text(name)),
    #("kind", text("extension")),
    #("scope", session_scope("0198c0de-0000")),
    #("description", text("Runs the formatter.")),
    #("parent", json.Null),
    #(
      "origin",
      json.Object([
        #("session", text("0198c0de-0000")),
        #("strand", text("main")),
      ]),
    ),
    #("identity_current", json.Bool(True)),
    #("approval", approval),
    #("evidence", json.Array(evidence_rows)),
    #("selected", selected),
  ])
}

fn approval(evidence_id: String) -> json.JsonValue {
  json.Object([
    #("evidence_id", text(evidence_id)),
    #("by", text("owner")),
    #("via", text("web")),
  ])
}

fn chosen(generation: Int, evidence_id: String) -> json.JsonValue {
  json.Object([
    #("generation", json.Int(generation)),
    #("evidence_id", text(evidence_id)),
  ])
}

fn event(
  seq: Int,
  decision: String,
  id: String,
  name: String,
) -> json.JsonValue {
  json.Object([
    #("seq", json.Int(seq)),
    #("at_ms", json.Int(2000 + seq)),
    #("event", text(decision)),
    #("candidate_id", text(id)),
    #("name", text(name)),
    #("generation", case decision {
      "selected" -> json.Int(seq)
      _ -> json.Null
    }),
    #("principal", text("owner")),
    #("via", text("terminal")),
    #("reason", text("looked fine")),
    #("request_id", text("")),
  ])
}

fn board(
  candidates: List(json.JsonValue),
  history: List(json.JsonValue),
) -> json.JsonValue {
  json.Object([
    #("version", json.Int(1)),
    #("session", text("0198c0de-0000")),
    #("candidates", json.Array(candidates)),
    #(
      "selections",
      json.Array([
        json.Object([
          #("scope", session_scope("0198c0de-0000")),
          #("name", text("fmt_check")),
          #("candidate_id", text("aaaa1111")),
          #("evidence_id", text("e1")),
          #("generation", json.Int(3)),
          #("published", json.Bool(True)),
        ]),
      ]),
    ),
    #(
      "published",
      json.Object([
        #("candidate_id", text("aaaa1111")),
        #("name", text("fmt_check")),
        #("generation", json.Int(3)),
        #("inventory", json.Object([#("helpers", json.Int(2))])),
      ]),
    ),
    #(
      "pending",
      json.Array([
        json.Object([
          #("request_id", text("ui-0198c0de-5000-bbbb2222-1")),
          #("state", text("queued")),
          #("candidate_id", text("bbbb2222")),
          #("expires_at_ms", json.Int(99_000)),
        ]),
      ]),
    ),
    #("history", json.Array(history)),
    #(
      "omitted",
      json.Object([#("candidates", json.Int(4)), #("history", json.Int(12))]),
    ),
  ])
}

fn decoded(value: json.JsonValue) -> evolution.Board {
  let assert Ok(board) = evolution.decode_board(value)
  board
}

fn the_example() -> evolution.Board {
  decoded(
    board(
      [
        candidate(
          "aaaa1111",
          "fmt_check",
          approval("e1"),
          [evidence("e1", "passed")],
          chosen(3, "e1"),
        ),
        candidate(
          "bbbb2222",
          "fmt_check",
          json.Null,
          [evidence("e2", "passed")],
          json.Null,
        ),
      ],
      [
        event(41, "selected", "aaaa1111", "fmt_check"),
        event(40, "approved", "aaaa1111", "fmt_check"),
      ],
    ),
  )
}

pub fn the_board_the_daemon_sends_decodes_in_full_test() {
  let read = the_example()
  assert read.version == 1
  assert read.session == "0198c0de-0000"
  assert read.omitted_candidates == 4
  assert read.omitted_history == 12
  assert read.unread == 0
  let assert [live, proposed] = read.candidates
  assert live.candidate_id == "aaaa1111"
  assert live.kind == evolution.Extension
  assert live.scope == evolution.SessionScope("0198c0de-0000")
  assert live.identity == evolution.Current
  assert live.approval == Some(evolution.Approval("e1", "owner", evolution.Web))
  assert live.selected == Some(evolution.Chosen(3, "e1"))
  assert proposed.approval == None
  let assert [row] = proposed.evidence
  assert row.verdict == evolution.Passed
  assert row.purpose == evolution.AuthorTests
  let assert [selection] = read.selections
  assert selection.liveness == evolution.Live
  assert selection.generation == 3
  let assert Some(generation) = read.published
  assert generation.name == "fmt_check"
  assert generation.inventory == json.Object([#("helpers", json.Int(2))])
  let assert [waiting] = read.pending
  assert waiting.phase == evolution.Queued
  assert waiting.expires_at_ms == 99_000
  let assert [selected, approved] = read.history
  assert selected.decision == evolution.Selected
  assert selected.generation == Some(41)
  assert selected.via == evolution.Terminal
  assert approved.decision == evolution.Approved
  assert approved.generation == None
}

pub fn a_body_that_is_not_an_object_is_the_only_refusal_test() {
  assert evolution.decode_board(json.Null) |> result.is_error
  assert evolution.decode_board(json.Array([])) |> result.is_error
  let assert Ok(empty) = evolution.decode_board(json.Object([]))
  assert empty.candidates == []
  assert empty.published == None
  assert empty.unread == 0
}

// --- rows the client does not know --------------------------------------------

pub fn rows_of_unfamiliar_kinds_are_kept_as_written_test() {
  let odd =
    json.Object([
      #("candidate_id", text("cccc3333")),
      #("name", text("odd")),
      #("kind", text("skill")),
      #("scope", json.Object([#("kind", text("galaxy"))])),
      #("identity_current", json.Bool(False)),
      #(
        "evidence",
        json.Array([
          json.Object([
            #("evidence_id", text("e9")),
            #("purpose", text("vibes")),
            #("verdict", text("maybe")),
            #("identity_current", json.Bool(True)),
          ]),
        ]),
      ),
    ])
  let read =
    decoded(
      json.Object([
        #("candidates", json.Array([odd])),
        #(
          "pending",
          json.Array([
            json.Object([
              #("request_id", text("r")),
              #("state", text("paused")),
              #("candidate_id", text("cccc3333")),
            ]),
          ]),
        ),
        #("history", json.Array([event(1, "frobbed", "cccc3333", "odd")])),
      ]),
    )
  let assert [row] = read.candidates
  assert row.kind == evolution.UnknownKind("skill")
  assert row.scope == evolution.UnknownScope("galaxy")
  assert row.identity == evolution.Outdated
  let assert [observed] = row.evidence
  assert observed.purpose == evolution.UnknownPurpose("vibes")
  assert observed.verdict == evolution.UnknownVerdict("maybe")
  let assert [waiting] = read.pending
  assert waiting.phase == evolution.UnknownPhase("paused")
  let assert [entry] = read.history
  assert entry.decision == evolution.UnknownDecision("frobbed")
  assert read.unread == 0
}

pub fn an_unfamiliar_row_is_drawn_as_written_and_offered_nothing_test() {
  let odd =
    evolution.Candidate(
      ..the_candidate(),
      kind: evolution.UnknownKind("skill"),
      approval: None,
    )
  assert evolution.kind_words(odd.kind) == "unknown (skill)"
  assert evolution.approval_target(odd) == Error(Nil)
  assert evolution.selection_target(the_example(), odd) == Error(Nil)
  assert evolution.scope_words(evolution.UnknownScope("galaxy"), "s")
    == "unknown scope (galaxy)"
  assert evolution.verdict_words(evolution.UnknownVerdict("maybe"), "")
    == "unknown (maybe)"
  assert evolution.purpose_words(evolution.UnknownPurpose("vibes"))
    == "unknown (vibes)"
  assert evolution.decision_words(evolution.UnknownDecision("x"))
    == "unknown (x)"
}

fn the_candidate() -> evolution.Candidate {
  let assert [first, ..] = the_example().candidates
  first
}

// --- rows the client cannot read ----------------------------------------------

pub fn an_unreadable_row_is_counted_and_its_neighbours_survive_test() {
  let good = candidate("aaaa1111", "a", json.Null, [], json.Null)
  let read =
    decoded(
      json.Object([
        #(
          "candidates",
          json.Array([json.Null, good, json.Object([]), json.Int(3)]),
        ),
        #("history", json.Array([json.String("x")])),
        #("published", json.Int(1)),
      ]),
    )
  assert list.length(read.candidates) == 1
  assert read.history == []
  assert read.published == None
  assert read.unread == 5
}

// A candidate whose approval cannot be read is not drawn as unapproved. The
// difference is the one a person acts on, so the whole row is left out.
pub fn a_nested_row_that_fails_fails_the_candidate_test() {
  let broken_approval =
    candidate(
      "aaaa1111",
      "a",
      json.Object([#("by", text("owner"))]),
      [],
      json.Null,
    )
  let broken_evidence =
    candidate(
      "bbbb2222",
      "b",
      json.Null,
      [json.Object([#("evidence_id", text("e"))])],
      json.Null,
    )
  let read =
    decoded(
      json.Object([
        #("candidates", json.Array([broken_approval, broken_evidence])),
      ]),
    )
  assert read.candidates == []
  assert read.unread == 2
}

pub fn rows_over_the_clients_own_bound_are_counted_test() {
  let many =
    list.repeat(candidate("aaaa1111", "a", json.Null, [], json.Null), 300)
  let read = decoded(json.Object([#("candidates", json.Array(many))]))
  assert list.length(read.candidates) == evolution.candidate_limit
  assert read.unread == 300 - evolution.candidate_limit
}

pub fn displayed_text_cannot_carry_a_control_sequence_test() {
  let sneaky =
    candidate("aaaa1111", "fmt\nreset\u{1b}[2J", json.Null, [], json.Null)
  let read = decoded(json.Object([#("candidates", json.Array([sneaky]))]))
  let assert [row] = read.candidates
  assert !string.contains(row.name, "\n")
  assert !string.contains(row.name, "\u{1b}")
}

// --- words ---------------------------------------------------------------------

pub fn the_words_are_the_ones_both_hosts_share_test() {
  assert evolution.kind_words(evolution.Extension) == "extension"
  assert evolution.kind_words(evolution.Prompt) == "prompt"
  assert evolution.scope_words(
      evolution.SessionScope("0198c0de-0000"),
      "0198c0de-0000",
    )
    == "this session"
  assert evolution.scope_words(evolution.SessionScope("0198c0de-0000"), "other")
    == "session 0198c0de"
  assert evolution.scope_words(
      evolution.WorkspaceScope("executor:gilgamesh/loom"),
      "s",
    )
    == "executor:gilgamesh/loom"
  assert evolution.scope_words(
      evolution.ModelScope("anthropic", "opus", "x"),
      "s",
    )
    == "anthropic/opus (x)"
  assert evolution.verdict_words(evolution.Inconclusive, "timed out")
    == "inconclusive: timed out"
  assert evolution.verdict_words(evolution.Passed, "") == "passed"
  assert evolution.purpose_words(evolution.IndependentRollout)
    == "independent rollout"
  assert evolution.surface_words(evolution.Web) == "web"
  assert evolution.surface_words(evolution.Unrecorded) == ""
  assert evolution.decision_words(evolution.Revoked) == "revoked"
  assert evolution.generation_words(3, evolution.Live) == "generation 3, live"
  assert evolution.generation_words(4, evolution.NotLive) == "generation 4"
  assert evolution.short_id("3f9a0c2e1b7d") == "3f9a0c2e"
}

pub fn refusals_are_worded_from_the_code_test() {
  assert string.starts_with(
    evolution.refusal_words("bad_request", "selection changed"),
    "The selection changed",
  )
  assert string.contains(
    evolution.refusal_words("bad_request", "authority: foreign session"),
    "Not allowed: foreign session.",
  )
  assert evolution.refusal_words(
      "bad_request",
      "runtime evolution is unavailable for this session",
    )
    == "Evolution is not available for this session."
  assert evolution.refusal_words("bad_request", "odd\nline")
    == "Evolution refused: odd line"
  assert string.contains(evolution.refusal_words("forbidden", ""), "may not")
}

// --- what a person may be offered ----------------------------------------------

pub fn an_approval_rests_on_passing_current_evidence_test() {
  let read = the_example()
  let assert [approved, proposed] = read.candidates
  assert evolution.approval_target(approved) == Error(Nil)
  assert evolution.approval_target(proposed) == Ok("e2")
  let failing =
    evolution.Candidate(..proposed, evidence: [
      evolution.Evidence(
        "e3",
        evolution.AuthorTests,
        evolution.Failed,
        "",
        1,
        evolution.Current,
      ),
    ])
  assert evolution.approval_target(failing) == Error(Nil)
  let stale = evolution.Candidate(..proposed, identity: evolution.Outdated)
  assert evolution.approval_target(stale) == Error(Nil)
}

// The store approves a prompt only on an independent rollout and refuses its
// author's tests, so the lane offers an approval on that evidence alone.
pub fn a_prompt_is_approved_on_an_independent_rollout_only_test() {
  let read = the_example()
  let assert [_, proposed] = read.candidates
  let on = fn(purpose) {
    evolution.Candidate(..proposed, kind: evolution.Prompt, evidence: [
      evolution.Evidence(
        "e9",
        purpose,
        evolution.Passed,
        "",
        1,
        evolution.Current,
      ),
    ])
  }
  assert evolution.approval_target(on(evolution.AuthorTests)) == Error(Nil)
  assert evolution.approval_target(on(evolution.IndependentRollout)) == Ok("e9")
  let program =
    evolution.Candidate(..on(evolution.AuthorTests), kind: evolution.Program)
  assert evolution.approval_target(program) == Ok("e9")
}

// An owner's principal is a long digest. Both hosts draw it cut, so a history
// row stays short, and a short one is left whole.
pub fn a_long_principal_is_cut_for_a_row_test() {
  assert evolution.principal_words("member-noa") == "member-noa"
  assert evolution.principal_words(
      "owner-2d927c35c48e817d2424885de1166ca9e4f01871137ed1795fa7378d8783d036",
    )
    == "owner-2d927c35…"
}

pub fn a_selection_echoes_the_generation_the_board_shows_test() {
  let read = the_example()
  let assert [selected, proposed] = read.candidates

  // Not approved yet, so nothing to select.
  assert evolution.selection_target(read, proposed) == Error(Nil)

  // The candidate that is selected already offers no second selection.
  assert evolution.selection_target(read, selected) == Error(Nil)
  let approved = evolution.Candidate(..proposed, approval: selected.approval)
  assert evolution.selection_target(read, approved)
    == Ok(evolution.SelectTarget("e1", 3))
  let elsewhere =
    evolution.Candidate(..approved, scope: evolution.WorkspaceScope("/work"))
  assert evolution.selection_target(read, elsewhere)
    == Ok(evolution.SelectTarget("e1", 0))
}

pub fn a_rollback_lists_earlier_approved_candidates_test() {
  let first = candidate("aaaa1111", "fmt_check", approval("e1"), [], json.Null)
  let second =
    candidate("bbbb2222", "fmt_check", approval("e2"), [], chosen(2, "e2"))
  let unapproved = candidate("cccc3333", "fmt_check", json.Null, [], json.Null)
  let other = candidate("dddd4444", "other", approval("e4"), [], json.Null)
  let read =
    decoded(
      board([first, second, unapproved, other], [
        event(4, "selected", "bbbb2222", "fmt_check"),
        event(3, "selected", "cccc3333", "fmt_check"),
        event(2, "selected", "dddd4444", "other"),
        event(1, "selected", "aaaa1111", "fmt_check"),
        event(0, "selected", "aaaa1111", "fmt_check"),
      ]),
    )
  let assert Ok(live) = evolution.find(read, "bbbb2222")
  let assert [earlier] = evolution.rollback_choices(read, live)
  assert earlier.candidate_id == "aaaa1111"
}

pub fn the_badge_counts_what_waits_for_a_person_test() {
  assert evolution.awaiting_approval(the_example()) == 2
  assert evolution.awaiting_approval(decoded(json.Object([]))) == 0
}

// --- requests and replies --------------------------------------------------------

pub fn every_request_encodes_to_its_arguments_test() {
  let args = fn(request) {
    evolution.arguments(request, evolution.Unclaimed, "ui-1", 60_000)
  }
  assert args(evolution.Approve("c", "e"))
    == json.Object([
      #("candidate_id", text("c")),
      #("evidence_id", text("e")),
    ])
  assert args(evolution.Revoke("c", "flaky"))
    == json.Object([
      #("candidate_id", text("c")),
      #("reason", text("flaky")),
    ])
  assert args(evolution.Select("c", "fmt", "e", 3, "go"))
    == json.Object([
      #("candidate_id", text("c")),
      #("evidence_id", text("e")),
      #("expected_generation", json.Int(3)),
      #("reason", text("go")),
      #("request_id", text("ui-1")),
      #("deadline_ms", json.Int(60_000)),
    ])
  assert args(evolution.Rollback("c", "fmt", "e", 3, "go"))
    == args(evolution.Select("c", "fmt", "e", 3, "go"))
  assert args(evolution.Inspect("c"))
    == json.Object([#("candidate_id", text("c"))])
  assert args(evolution.ReadEvidence("e"))
    == json.Object([#("evidence_id", text("e"))])
  assert args(evolution.CoreStatus) == json.Object([])
}

pub fn a_terminal_names_itself_and_a_page_does_not_test() {
  let claimed =
    evolution.arguments(
      evolution.Approve("c", "e"),
      evolution.ClaimsTerminal,
      "",
      0,
    )
  let assert json.Object(fields) = claimed
  assert list.key_find(fields, "via") == Ok(text("terminal"))
}

// Only the four changes record `via` in an audit entry, and `core_status`
// accepts only an optional `request_id`: the live daemon refused one that
// carried the claim. So the claim goes only with a change.
pub fn a_terminals_claim_goes_only_with_a_change_test() {
  let claimed = fn(request) {
    let assert json.Object(fields) =
      evolution.arguments(request, evolution.ClaimsTerminal, "ui-1", 60_000)
    list.key_find(fields, "via")
  }
  assert claimed(evolution.Approve("c", "e")) == Ok(text("terminal"))
  assert claimed(evolution.Revoke("c", "r")) == Ok(text("terminal"))
  assert claimed(evolution.Select("c", "n", "e", 0, "r"))
    == Ok(text("terminal"))
  assert claimed(evolution.Rollback("c", "n", "e", 0, "r"))
    == Ok(text("terminal"))
  assert claimed(evolution.Inspect("c")) == Error(Nil)
  assert claimed(evolution.ReadEvidence("e")) == Error(Nil)
  assert claimed(evolution.CoreStatus) == Error(Nil)
}

pub fn each_request_is_sent_as_its_action_test() {
  assert evolution.action_word(evolution.Approve("c", "e")) == "approve"
  assert evolution.action_word(evolution.Revoke("c", "r")) == "revoke"
  assert evolution.action_word(evolution.Select("c", "n", "e", 0, "r"))
    == "select"
  assert evolution.action_word(evolution.Rollback("c", "n", "e", 0, "r"))
    == "rollback"
  assert evolution.action_word(evolution.Inspect("c")) == "inspect"
  assert evolution.action_word(evolution.ReadEvidence("e")) == "evidence"
  assert evolution.action_word(evolution.CoreStatus) == "core_status"
}

pub fn the_lane_issues_nine_actions_and_three_of_them_change_nothing_test() {
  let actions = [
    "board", "status", "inspect", "evidence", "core_status", "approve", "revoke",
    "select", "rollback",
  ]
  assert list.all(actions, evolution.is_action)
  assert list.filter(actions, evolution.is_read_action)
    == ["board", "status", "inspect", "evidence", "core_status"]
  assert !evolution.is_action("core_upgrade")
  assert !evolution.is_action("admit_tasks")
}

fn state(word: String) -> json.JsonValue {
  json.Object([#("state", text(word)), #("request_id", text("r"))])
}

pub fn the_three_selection_actions_share_one_vocabulary_test() {
  let report = fn(body) { evolution.read("status", body) }
  assert report(state("queued"))
    == evolution.ProgressReply(evolution.InFlight(evolution.Queued))
  assert report(state("running"))
    == evolution.ProgressReply(evolution.InFlight(evolution.Running))
  assert report(state("paused"))
    == evolution.ProgressReply(
      evolution.InFlight(evolution.UnknownPhase("paused")),
    )
  assert report(state("unknown"))
    == evolution.ProgressReply(evolution.Forgotten)
  assert report(
      json.Object([#("state", text("failed")), #("reason", text("busy"))]),
    )
    == evolution.ProgressReply(evolution.Rejected("busy"))
  let committed =
    json.Object([
      #("state", text("completed")),
      #("committed", json.Object([#("generation", json.Int(4))])),
    ])
  assert evolution.read("select", committed)
    == evolution.ProgressReply(evolution.Done(Some(4)))
  assert evolution.read(
      "rollback",
      json.Object([
        #("state", text("committed")),
        #("committed", json.Object([#("generation", json.Int(4))])),
        #("published", json.Null),
      ]),
    )
    == evolution.ProgressReply(evolution.DurableOnly(Some(4)))
}

// A global candidate commits at once and answers with the bare selection.
pub fn a_bare_committed_selection_is_done_test() {
  assert evolution.read(
      "select",
      json.Object([
        #("candidate_id", text("c")),
        #("generation", json.Int(2)),
        #("name", text("n")),
        #("evidence_id", text("e")),
      ]),
    )
    == evolution.ProgressReply(evolution.Done(Some(2)))
  assert evolution.read("status", json.Object([#("x", json.Int(1))]))
    |> is_unreadable
}

pub fn approvals_revocations_and_pages_read_by_action_test() {
  assert evolution.read("approve", json.Object([#("approved", text("c"))]))
    == evolution.ApprovalReply("c")
  assert evolution.read("revoke", json.Object([#("revoked", text("c"))]))
    == evolution.RevocationReply("c")
  assert evolution.read("approve", json.Object([#("revoked", text("c"))]))
    |> is_unreadable
  let envelope = json.Object([#("name", text("fmt"))])
  assert evolution.read("inspect", envelope)
    == evolution.PageReply(evolution.Whole(envelope))
  let fragment =
    json.Object([
      #("fragment_base64", text("AAAA")),
      #("total_bytes", json.Int(99_999)),
    ])
  assert evolution.read("evidence", fragment)
    == evolution.PageReply(evolution.Large(99_999))
  assert evolution.read("core_status", json.Null)
    == evolution.PageReply(evolution.Whole(json.Null))
  assert evolution.read("board", json.Null) |> is_unreadable
}

fn is_unreadable(reply: evolution.Reply) -> Bool {
  case reply {
    evolution.Unreadable(..) -> True
    _ -> False
  }
}

// --- the properties --------------------------------------------------------------

const sweep_seed = 99

const kinds = ["extension", "program", "prompt", "skill", "agent"]

const verdicts = ["passed", "failed", "inconclusive", "maybe", "weird"]

fn scope_json(index: Int) -> json.JsonValue {
  case index {
    0 -> session_scope("0198c0de-0000")
    1 -> json.Object([#("kind", text("workspace")), #("workspace", text("/w"))])
    2 ->
      json.Object([
        #("kind", text("model")),
        #("provider", text("p")),
        #("model", text("m")),
        #("api", text("a")),
      ])
    3 -> json.Object([#("kind", text("galaxy"))])
    _ -> json.Object([#("kind", text("cluster")), #("size", json.Int(3))])
  }
}

fn pick(choices: List(String), index: Int) -> String {
  case list.drop(choices, index) {
    [chosen, ..] -> chosen
    [] -> ""
  }
}

// One well-formed row from five small draws: a kind, a scope and a verdict,
// each from a set that includes words the client does not know, whether the
// row is approved, and how many observations it holds.
type Draw =
  #(Int, Int, Int, Int, Int)

fn draws() -> qcheck.Generator(List(Draw)) {
  let index = qcheck.bounded_int(from: 0, to: 4)
  qcheck.generic_list(
    elements_from: qcheck.tuple5(
      index,
      index,
      index,
      qcheck.bounded_int(from: 0, to: 1),
      qcheck.bounded_int(from: 0, to: 3),
    ),
    length_from: qcheck.bounded_int(from: 0, to: 8),
  )
}

fn row_of(position: Int, draw: Draw) -> json.JsonValue {
  let #(kind, scope, verdict, approved, observations) = draw
  let id = "cand" <> string.inspect(position)
  json.Object([
    #("candidate_id", text(id)),
    #("name", text("name" <> string.inspect(position))),
    #("kind", text(pick(kinds, kind))),
    #("scope", scope_json(scope)),
    #("identity_current", json.Bool(True)),
    #("approval", case approved {
      1 -> approval("e0")
      _ -> json.Null
    }),
    #(
      "evidence",
      json.Array(list.repeat(
        evidence("e0", pick(verdicts, verdict)),
        observations,
      )),
    ),
  ])
}

fn rows_of(drawn: List(Draw)) -> List(json.JsonValue) {
  list.index_map(drawn, fn(draw, position) { row_of(position, draw) })
}

fn run(generator: qcheck.Generator(a), property: fn(a) -> Nil) -> Nil {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(500)
    |> qcheck.with_seed(qcheck.seed(sweep_seed))
  qcheck.run(config, generator, property)
}

pub fn every_generated_board_decodes_whole_and_keeps_unfamiliar_rows_test() {
  run(draws(), fn(drawn) {
    let assert Ok(read) =
      evolution.decode_board(
        json.Object([#("candidates", json.Array(rows_of(drawn)))]),
      )
    assert read.unread == 0
    assert list.length(read.candidates) == list.length(drawn)
    list.zip(drawn, read.candidates)
    |> list.each(fn(pair) {
      let #(#(kind, scope, verdict, approved, observations), row) = pair
      assert row.kind
        == case kind {
          0 -> evolution.Extension
          1 -> evolution.Program
          2 -> evolution.Prompt
          _ -> evolution.UnknownKind(pick(kinds, kind))
        }
      assert case scope, row.scope {
        0, evolution.SessionScope(..)
        | 1, evolution.WorkspaceScope(..)
        | 2, evolution.ModelScope(..)
        | 3, evolution.UnknownScope("galaxy")
        | 4, evolution.UnknownScope("cluster")
        -> True
        _, _ -> False
      }
      assert list.length(row.evidence) == observations
      assert { row.approval != None } == { approved == 1 }
      list.each(row.evidence, fn(observed) {
        assert observed.verdict
          == case verdict {
            0 -> evolution.Passed
            1 -> evolution.Failed
            2 -> evolution.Inconclusive
            _ -> evolution.UnknownVerdict(pick(verdicts, verdict))
          }
      })
    })
  })
}

// Corrupt some rows of a well-formed board with values no daemon sends. The
// board still decodes, the corrupted rows are the ones counted, and the rows
// around them are exactly what they were.
pub fn a_corrupted_row_never_closes_the_lane_test() {
  let breakage = [
    json.Null,
    json.Int(7),
    json.String("row"),
    json.Array([]),
    json.Object([]),
    json.Object([#("candidate_id", json.Int(1))]),
  ]
  let generator =
    qcheck.tuple2(
      draws(),
      qcheck.generic_list(
        elements_from: qcheck.bounded_int(from: 0, to: 5),
        length_from: qcheck.bounded_int(from: 0, to: 8),
      ),
    )
  run(generator, fn(case_) {
    let #(drawn, breaks) = case_
    let rows = rows_of(drawn)

    // Each break replaces the row at its position modulo the length, so a
    // row hit twice is corrupted once.
    let broken =
      list.fold(breaks, #(rows, []), fn(state, which) {
        let #(rows, hit) = state
        case list.length(rows) {
          0 -> state
          size -> {
            let position = which % size
            let replacement = pick_json(breakage, which)
            #(
              list.index_map(rows, fn(row, at) {
                case at == position {
                  True -> replacement
                  False -> row
                }
              }),
              [position, ..hit],
            )
          }
        }
      })
    let #(rows, hit) = broken
    let corrupted = list.unique(hit)
    let assert Ok(read) =
      evolution.decode_board(json.Object([#("candidates", json.Array(rows))]))
    assert read.unread == list.length(corrupted)
    let survivors =
      list.index_map(drawn, fn(_, position) {
        case list.contains(corrupted, position) {
          True -> []
          False -> ["cand" <> string.inspect(position)]
        }
      })
      |> list.flatten
    assert list.map(read.candidates, fn(row) { row.candidate_id }) == survivors
  })
}

fn pick_json(choices: List(json.JsonValue), index: Int) -> json.JsonValue {
  case list.drop(choices, index) {
    [chosen, ..] -> chosen
    [] -> json.Null
  }
}

// The daemon writes an empty candidate for an audit entry whose text did not
// parse, so the row is drawn and not counted as unread.
pub fn an_audit_row_with_no_candidate_is_kept_test() {
  let row = event(7, "approved", "", "")
  let read = decoded(json.Object([#("history", json.Array([row]))]))
  let assert [kept] = read.history
  assert kept.candidate_id == ""
  assert read.unread == 0
}

pub fn a_busy_refusal_and_a_multiline_description_read_as_written_test() {
  assert evolution.refusal_words(
      "bad_request",
      "Busy: one live transition is already pending",
    )
    == "Another selection is still staging; wait for it."
  let assert json.Object(fields) =
    candidate("aaaa1111", "a", json.Null, [], json.Null)
  let with_lines =
    json.Object([
      #("description", text("first\nsecond")),
      ..list.filter(fields, fn(field) { field.0 != "description" })
    ])
  let read = decoded(json.Object([#("candidates", json.Array([with_lines]))]))
  let assert [row] = read.candidates
  assert row.description == "first\nsecond"
}

// --- arbitrary JSON----------------------------------------------------------------

const keys = [
  "candidates", "selections", "published", "pending", "history", "omitted",
  "candidate_id", "name", "kind", "scope", "identity_current", "approval",
  "evidence", "selected", "state", "committed", "generation", "evidence_id",
  "verdict", "purpose", "event", "seq", "fragment_base64", "total_bytes",
]

const words = ["session", "workspace", "model", "passed", "queued", "", "x"]

fn arbitrary(depth: Int) -> qcheck.Generator(json.JsonValue) {
  let leaves = [
    qcheck.return(json.Null),
    qcheck.map(qcheck.bool(), json.Bool),
    qcheck.map(qcheck.bounded_int(from: -3, to: 5), json.Int),
    qcheck.return(json.Float(1.5)),
    qcheck.map(
      qcheck.bounded_int(from: 0, to: list.length(words) - 1),
      fn(index) { json.String(pick(words, index)) },
    ),
  ]
  case depth <= 0 {
    True -> qcheck.from_generators(qcheck.return(json.Null), leaves)
    False -> {
      let inner = arbitrary(depth - 1)
      let array =
        qcheck.generic_list(
          elements_from: inner,
          length_from: qcheck.bounded_int(from: 0, to: 3),
        )
        |> qcheck.map(json.Array)
      let object =
        qcheck.generic_list(
          elements_from: qcheck.tuple2(
            qcheck.map(
              qcheck.bounded_int(from: 0, to: list.length(keys) - 1),
              pick(keys, _),
            ),
            inner,
          ),
          length_from: qcheck.bounded_int(from: 0, to: 8),
        )
        |> qcheck.map(json.Object)
      qcheck.from_generators(qcheck.return(json.Null), [array, object, ..leaves])
    }
  }
}

// The assertion is that reading returns, never what it returns: the cases
// above pin what a shape decodes to. A failure would be a panic inside a
// decoder, and qcheck then shrinks the value toward a plainer tree.
pub fn reading_is_total_over_arbitrary_json_under_every_action_test() {
  let actions = [
    "board", "status", "select", "rollback", "approve", "revoke", "inspect",
    "evidence", "catalogue", "core_status", "something_new",
  ]
  run(arbitrary(3), fn(value) {
    list.each(actions, fn(action) {
      let _ = evolution.read(action, value)
      Nil
    })
    let _ = evolution.decode_board(value)
    Nil
  })
}
