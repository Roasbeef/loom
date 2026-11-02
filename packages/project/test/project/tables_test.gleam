//// The pure tables: the gate's authority rows, the stage function row by row,
//// the policy derivation, readiness transitions and derived names.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/gate
import project/host
import project/model.{
  Abandoned, Addressed, Asking, Closed, CommitId, Explicit, Inferred, Merged,
  NoQuestion, PersonHeard, Satisfied, Silent, StoppedByPerson, Unaddressed,
  Waiting, Wanting,
}
import project/policy
import project/readiness
import project/stage.{type Facts, Facts}
import qcheck
import support/gen
import support/world

// --- the gate ---------------------------------------------------------------------

fn classify(
  sender: model.Sender,
  addressing: model.Addressing,
  relation: gate.ThreadRelation,
  matched: option.Option(model.RuleMatch),
  generation: Int,
) -> gate.Admission {
  gate.classify(
    world.trigger("t", "th", "pat", sender, addressing, matched, generation),
    relation,
  )
}

pub fn the_owner_is_explicit_in_every_case_test() {
  let admitted =
    gate.Admitted(Explicit, model.FromComposer, model.ApprovalsNotGranted)
  assert classify(model.Owner, Addressed, gate.UnrelatedThread, None, 0)
    == admitted
  assert classify(model.Owner, Unaddressed, gate.OwnTicketThread, None, 9)
    == admitted
}

pub fn an_allowed_person_is_explicit_when_addressing_or_following_up_test() {
  assert classify(model.Person, Addressed, gate.UnrelatedThread, None, 0)
    == gate.Admitted(Explicit, model.FromAddressed, model.ApprovalsNotGranted)
  assert classify(model.Person, Unaddressed, gate.OwnTicketThread, None, 0)
    == gate.Admitted(Explicit, model.FromFollowUp, model.ApprovalsNotGranted)
}

pub fn an_allowed_person_not_addressing_the_agent_is_inferred_test() {
  assert classify(model.Person, Unaddressed, gate.UnrelatedThread, None, 0)
    == gate.Admitted(Inferred, model.FromOverheard, model.ApprovalsNotGranted)
}

pub fn a_listed_bot_or_a_ci_failure_is_inferred_test() {
  let automated =
    gate.Admitted(Inferred, model.FromAutomation, model.ApprovalsNotGranted)
  assert classify(model.ListedBot, Addressed, gate.UnrelatedThread, None, 0)
    == automated
  assert classify(model.CiFailure, Unaddressed, gate.OwnTicketThread, None, 0)
    == automated
}

pub fn an_unlisted_sender_is_ignored_unless_a_rule_admits_them_test() {
  assert classify(model.Unlisted, Addressed, gate.UnrelatedThread, None, 0)
    == gate.NotAdmitted(gate.SenderUnlisted)
  assert classify(
      model.Unlisted,
      Addressed,
      gate.UnrelatedThread,
      world.matched(),
      0,
    )
    == gate.Admitted(
      Inferred,
      model.FromRule(world.rule),
      model.ApprovalsNotGranted,
    )
}

pub fn inference_stops_past_the_generation_limit_but_explicit_work_does_not_test() {
  let past = gate.max_generation + 1
  assert classify(model.ListedBot, Addressed, gate.UnrelatedThread, None, past)
    == gate.NotAdmitted(gate.PastGenerationLimit)
  assert classify(
      model.ListedBot,
      Addressed,
      gate.UnrelatedThread,
      None,
      gate.max_generation,
    )
    != gate.NotAdmitted(gate.PastGenerationLimit)
  assert classify(model.Owner, Addressed, gate.UnrelatedThread, None, past)
    == gate.Admitted(Explicit, model.FromComposer, model.ApprovalsNotGranted)
}

pub fn acceptance_follows_mode_rule_and_verdict_test() {
  let rule = Some(world.rule)
  let pair = fn(mode, verdict) { gate.Pair(rule, mode, verdict) }
  assert gate.acceptance(
      Inferred,
      gate.Pair(None, model.Auto, gate.VerdictCurrent),
    )
    == gate.Refuse(gate.NoMatchingRule)
  assert gate.acceptance(Inferred, pair(model.Off, gate.VerdictCurrent))
    == gate.Refuse(gate.ModeIsOff)
  assert gate.acceptance(Inferred, pair(model.Observe, gate.VerdictMissing))
    == gate.RecordOnly
  assert gate.acceptance(Inferred, pair(model.Auto, gate.VerdictMissing))
    == gate.Refuse(gate.NoCurrentVerdict)
  assert gate.acceptance(Inferred, pair(model.Auto, gate.VerdictCurrent))
    == gate.Proceed
}

pub fn explicit_work_proceeds_in_every_mode_test() {
  let modes = [model.Off, model.Observe, model.Auto]
  let verdicts = [gate.VerdictCurrent, gate.VerdictMissing]
  list.each(modes, fn(mode) {
    list.each(verdicts, fn(verdict) {
      assert gate.acceptance(Explicit, gate.Pair(None, mode, verdict))
        == gate.Proceed
    })
  })
}

// --- stage, row by row -------------------------------------------------------------------

fn base() -> Facts {
  Facts(
    outcome: None,
    delivery: stage.DeliveryClear,
    question: NoQuestion,
    review: stage.NotInReview,
    latest: None,
    heard: Silent,
    assignment: stage.LatestLive,
    demand: Satisfied,
  )
}

pub fn row_one_an_ended_ticket_hides_everything_else_test() {
  let facts =
    Facts(
      ..base(),
      outcome: Some(Merged),
      delivery: stage.DeliveryFailed,
      question: Asking(1),
      review: stage.InReview,
    )
  assert stage.of(facts) == stage.StageEnded(Merged)
}

pub fn row_two_a_failed_input_comes_before_a_question_test() {
  let facts =
    Facts(
      ..base(),
      delivery: stage.DeliveryFailed,
      question: Asking(1),
      review: stage.InReview,
    )
  assert stage.of(facts) == stage.PersonDelivery
}

pub fn row_three_an_open_question_comes_before_review_test() {
  let facts = Facts(..base(), question: Asking(2), review: stage.InReview)
  assert stage.of(facts) == stage.PersonAnswer
}

pub fn row_four_review_covers_awaiting_review_and_an_open_pull_request_test() {
  assert stage.of(Facts(..base(), review: stage.InReview)) == stage.PersonReview
  assert stage.of(Facts(..base(), review: stage.PullRequestOpen))
    == stage.PersonReview
  assert stage.of(
      Facts(..base(), review: stage.InReview, latest: Some(model.Blocked)),
    )
    == stage.PersonReview
}

pub fn row_five_distress_stands_until_a_person_speaks_test() {
  assert stage.of(Facts(..base(), latest: Some(model.Blocked)))
    == stage.PersonBlocked
  assert stage.of(Facts(..base(), latest: Some(model.Failed)))
    == stage.PersonFailed
  assert stage.of(
      Facts(..base(), latest: Some(model.Blocked), heard: PersonHeard),
    )
    == stage.Working
}

pub fn row_six_queued_covers_never_assigned_pending_and_wanting_test() {
  assert stage.of(Facts(..base(), assignment: stage.NeverAssigned))
    == stage.Queued
  assert stage.of(Facts(..base(), assignment: stage.LatestPending))
    == stage.Queued
  assert stage.of(
      Facts(
        ..base(),
        assignment: stage.LatestEnded,
        demand: Wanting(model.ByRouting),
      ),
    )
    == stage.Queued
}

pub fn row_seven_idle_is_a_waiting_report_or_an_ended_assignment_test() {
  assert stage.of(Facts(..base(), latest: Some(Waiting(NoQuestion))))
    == stage.Idle
  assert stage.of(Facts(..base(), assignment: stage.LatestEnded)) == stage.Idle
}

pub fn row_eight_working_is_everything_else_test() {
  assert stage.of(base()) == stage.Working
  assert stage.of(Facts(..base(), latest: Some(model.Progress)))
    == stage.Working
}

pub fn the_wire_spelling_round_trips_for_every_stage_test() {
  let stages = [
    stage.PersonDelivery,
    stage.PersonAnswer,
    stage.PersonReview,
    stage.PersonBlocked,
    stage.PersonFailed,
    stage.Queued,
    stage.Idle,
    stage.Working,
    stage.StageEnded(Merged),
    stage.StageEnded(Closed),
    stage.StageEnded(Abandoned),
    stage.StageEnded(StoppedByPerson),
  ]
  list.each(stages, fn(found) {
    assert stage.parse(stage.to_string(found)) == Ok(found)
  })
  assert stage.to_string(stage.StageEnded(StoppedByPerson)) == "ended/stopped"
  assert stage.parse("ended/") == Error(Nil)
  assert stage.parse("ended/nonsense") == Error(Nil)
  assert stage.parse("") == Error(Nil)
}

// --- policy ------------------------------------------------------------------------------

const seed = 20_261_101

fn config() -> qcheck.Config {
  qcheck.default_config() |> qcheck.with_seed(qcheck.seed(seed))
}

pub fn policy_never_holds_a_credential_test() {
  use mandate <- qcheck.run(config(), gen.mandate())
  assert policy.for_mandate(mandate).credentials == policy.NoCredentials
}

pub fn mandates_differing_only_in_non_authority_fields_derive_equal_policy_test() {
  use #(mandate, other) <- qcheck.run(
    config(),
    qcheck.tuple2(gen.mandate(), gen.mandate()),
  )
  // Keep the authority fields of the first and take everything else from
  // the second.
  let varied =
    model.Mandate(
      strength: mandate.strength,
      basis: other.basis,
      actor: other.actor,
      source: other.source,
      scope: model.Scope(other.scope.workspace, mandate.scope.approvals),
      policy_version: other.policy_version,
    )
  assert policy.for_mandate(varied) == policy.for_mandate(mandate)
}

pub fn policy_is_monotone_in_strength_test() {
  use mandate <- qcheck.run(config(), gen.mandate())
  let explicit =
    policy.for_mandate(model.Mandate(..mandate, strength: Explicit))
  let inferred =
    policy.for_mandate(model.Mandate(..mandate, strength: Inferred))
  assert policy.network_rank(explicit.network)
    >= policy.network_rank(inferred.network)
  assert policy.approval_rank(explicit.approvals)
    >= policy.approval_rank(inferred.approvals)
}

pub fn inferred_approvals_need_a_rule_that_grants_them_test() {
  use mandate <- qcheck.run(config(), gen.mandate())
  let inferred = model.Mandate(..mandate, strength: Inferred)
  let granted =
    model.Mandate(
      ..inferred,
      scope: model.Scope(inferred.scope.workspace, model.ApprovalsGranted),
    )
  let withheld =
    model.Mandate(
      ..inferred,
      scope: model.Scope(inferred.scope.workspace, model.ApprovalsNotGranted),
    )
  assert policy.for_mandate(granted).approvals == policy.ApprovalsToPerson
  assert policy.for_mandate(withheld).approvals == policy.ApprovalsRefused
  assert policy.for_mandate(withheld).network == policy.RegistriesOnly
}

// --- readiness ---------------------------------------------------------------------------

fn proof(commit: String) -> host.CheckPassed {
  host.passed(CommitId(commit), model.CommandDigest("d"), model.EntryId("e"))
}

pub fn only_a_ticket_in_progress_accepts_a_passing_check_test() {
  assert readiness.check_passed(readiness.InProgress, proof("a"))
    == Ok(readiness.Ready(proof("a")))
  assert readiness.check_passed(readiness.AwaitingReview, proof("a"))
    == Error(Nil)
  assert readiness.check_passed(readiness.Ready(proof("a")), proof("a"))
    == Error(Nil)
  let published = readiness.Published(model.PrincipalId("p"), CommitId("a"))
  assert readiness.check_passed(published, proof("a")) == Error(Nil)
}

pub fn a_new_commit_invalidates_every_readiness_test() {
  let published = readiness.Published(model.PrincipalId("p"), CommitId("a"))
  let all = [
    readiness.InProgress,
    readiness.AwaitingReview,
    readiness.Ready(proof("a")),
    published,
  ]
  list.each(all, fn(found) {
    assert readiness.new_commit(found) == readiness.InProgress
  })
}

pub fn protected_paths_send_work_to_review_only_from_progress_test() {
  assert readiness.protected_touched(readiness.InProgress)
    == readiness.AwaitingReview
  let ready = readiness.Ready(proof("a"))
  assert readiness.protected_touched(ready) == ready
}

pub fn a_person_may_publish_from_any_state_test() {
  let by = model.PrincipalId("p")
  let published = readiness.Published(by, CommitId("a"))
  list.each(
    [
      readiness.InProgress,
      readiness.AwaitingReview,
      readiness.Ready(proof("a")),
      published,
    ],
    fn(found) {
      assert readiness.person_publishes(found, by, CommitId("a")) == published
    },
  )
}

// --- derived names -----------------------------------------------------------------------

pub fn a_ticket_id_is_a_function_of_its_trigger_test() {
  assert model.ticket_for(model.TriggerId("c1")) == model.TicketId("t-c1")
}

pub fn a_branch_name_is_ref_safe_and_injective_test() {
  use #(left, right) <- qcheck.run(
    config(),
    qcheck.tuple2(gen.ticket_id(), gen.ticket_id()),
  )
  let branch = model.branch_name(left)
  assert string.starts_with(branch, "project/")
  assert !string.contains(branch, " ")
  assert !string.contains(branch, "..")
  assert !string.contains(branch, "~")
  assert { left == right } == { branch == model.branch_name(right) }
}

pub fn a_request_key_names_project_ticket_and_sequence_test() {
  let key = model.request_key(model.ProjectId("p1"), model.TicketId("t-c1"), 3)
  assert key == "project:p1:t-c1:3"
  let other =
    model.request_key(model.ProjectId("p1"), model.TicketId("t-c1"), 4)
  assert key != other
}

pub fn a_title_is_capped_and_never_empty_test() {
  let long = string.repeat("é", 200)
  let capped = model.title_text(model.title(long))
  assert string.length(capped) == model.max_title_codepoints
  assert model.title_text(model.title("")) == "untitled"
  use text <- qcheck.run(config(), gen.text())
  let once = model.title_text(model.title(text))
  assert model.title_text(model.title(once)) == once
}
