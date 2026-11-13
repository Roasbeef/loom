//// What a live session feed does with each frame the laptop's lane sends
//// (protocol-change/108, "What the box admits from the page").
////
//// The box's gateway judges every frame it receives as an Operator attachment of
//// the box's owner, so a frame forwarded unchanged would be judged with the
//// owner's whole authority. The feed host therefore decodes the `cmd` of each
//// frame with the gateway's own decoder first and applies a closed table: a
//// command is forwarded as the lane wrote it, answered `forbidden` without the
//// gateway seeing it, or turned into a decision for the hub's relayed door. The
//// table is data and decides nothing by itself. The feed host acts on the
//// verdict, and the gateway and the hub keep every judgement of their own.
////
//// ## The table
////
//// | Commands | Verdict |
//// |---|---|
//// | the reads the page needs, `subscribe`, `snapshot_next` and `catch_up` | `Forward` |
//// | `prompt`, `prompt_content`, `steer`, `follow_up`, `abort` and the queued-input edits | `Forward`, to any strand |
//// | `approve`, `approve_for_session`, `deny` | `Decide`, judged by the relayed door |
//// | `permission_forget` of one grant | `Forget`, judged by the relayed door |
//// | `permission_forget` of an action consent or of everything | `Refuse` |
//// | every other command, and a command name this build does not know | `Forbid` |
////
//// A frame that does not decode is `Forward`: the gateway answers it as it
//// answers any malformed frame, and no frame that fails the gateway's own
//// decoder can name a command in the table.
////
//// ## Flow
////
//// `judge` → `of_command` → `approval`
////
//// 1. `judge` decodes a frame with the gateway's decoder.
//// 2. `of_command` is the table, one arm per command.
//// 3. `approval` makes the decision of an approval for one run or for the session.

import broker/policy.{type Grant}
import client/protocol.{type Command}
import client/remote_escalation.{type Decision}
import gleam/option

/// The words a refused command is answered with.
pub const forbidden_words = "not offered to a page on another orchestrator"

/// The words a forget the relayed door cannot express is answered with.
pub const forget_words =
  "forget it on the page of the orchestrator that runs this session"

/// What the feed host does with one frame.
pub type Verdict {
  /// Hand the frame to the gateway exactly as the lane wrote it.
  Forward

  /// Answer the lane's request `id` with `forbidden` and tell the gateway
  /// nothing.
  Forbid(
    /// The lane's request id.
    id: Int,
  )

  /// Judge a decision through the hub's relayed door and answer request `id`
  /// with what it says.
  Decide(
    /// The lane's request id.
    id: Int,
    /// The escalation record's identity.
    escalation: String,
    /// What the person decided.
    decision: Decision,
    /// The seq the person was shown.
    expected_seq: Int,
  )

  /// Withdraw one remembered grant through the relayed door, then answer
  /// request `id` with the permissions board read afterwards.
  Withdraw(
    /// The lane's request id.
    id: Int,
    /// What the person decided, always a `Forget`.
    decision: Decision,
    /// The seq the listing carried, or zero when it carried none.
    expected_seq: Int,
  )

  /// Answer request `id` with `bad_request` and these words.
  Refuse(
    /// The lane's request id.
    id: Int,
    /// What the person is told.
    words: String,
  )
}

/// Decides what to do with one frame the lane wrote.
///
/// ## Examples
///
/// ```gleam
/// assert feed_filter.judge("{\"v\":1,\"id\":3,\"cmd\":\"fork\",\"body\":{\"strand\":\"main\",\"scope\":\"branch\"}}")
///   == feed_filter.Forbid(3)
/// ```
pub fn judge(frame: String) -> Verdict {
  case protocol.decode_command(frame) {
    Ok(protocol.CommandEnvelope(id:, command:)) -> of_command(id, command)
    Error(_) -> Forward
  }
}

/// The table: one arm per command, with no catch-all, so a command added to the
/// protocol must be placed here before the build passes.
fn of_command(id: Int, command: Command) -> Verdict {
  case command {
    protocol.Subscribe(..)
    | protocol.SnapshotNext(..)
    | protocol.CatchUp(..)
    | protocol.History(..)
    | protocol.HistoryLineage(..)
    | protocol.EscalationsGet(..)
    | protocol.EscalationsDecided
    | protocol.ChildHistoryGet(..)
    | protocol.ContextGet(..)
    | protocol.LiveJobsGet(..)
    | protocol.NotesGet(..)
    | protocol.QueuedInputGet(..)
    | protocol.GoalGet
    | protocol.BlockSummariesGet(..)
    | protocol.AdvisorPendingGet
    | protocol.ListSkills(..)
    | protocol.ListModels
    | protocol.PermissionsGet -> Forward

    protocol.Prompt(..)
    | protocol.PromptContent(..)
    | protocol.Steer(..)
    | protocol.FollowUp(..)
    | protocol.Abort(..)
    | protocol.EditQueuedInput(..)
    | protocol.RemoveQueuedInput(..) -> Forward

    protocol.Approve(escalation_id:, grants:, action:, expected_seq:) ->
      approval(
        id,
        escalation_id,
        grants,
        action,
        expected_seq,
        remote_escalation.Once,
      )
    protocol.ApproveForSession(escalation_id:, grants:, action:, expected_seq:) ->
      approval(
        id,
        escalation_id,
        grants,
        action,
        expected_seq,
        remote_escalation.Session,
      )
    protocol.Deny(escalation_id:, expected_seq:) ->
      Decide(
        id:,
        escalation: escalation_id,
        decision: remote_escalation.Deny,
        expected_seq:,
      )

    // The relayed door can withdraw a grant this spawner approved and nothing
    // else, so the two wider targets are refused with a pointer to where they
    // can be done.
    protocol.PermissionForget(
      target: protocol.ForgetGrant(grant:),
      expected_seq:,
    ) ->
      Withdraw(
        id:,
        decision: remote_escalation.Forget(grant),
        expected_seq: option.unwrap(expected_seq, 0),
      )
    protocol.PermissionForget(target: protocol.ForgetAction(..), ..)
    | protocol.PermissionForget(target: protocol.ForgetAll, ..) ->
      Refuse(id:, words: forget_words)

    protocol.Fork(..)
    | protocol.Navigate(..)
    | protocol.Compact(..)
    | protocol.CreateStrand(..)
    | protocol.SetConfig(..)
    | protocol.ProfileGet
    | protocol.ProfileSet(..)
    | protocol.ListSchedules
    | protocol.CancelSchedule(..)
    | protocol.GoalSet(..)
    | protocol.GoalCheck(..)
    | protocol.GoalClear
    | protocol.GoalPause
    | protocol.GoalResume
    | protocol.Btw(..)
    | protocol.ProposalsGet
    | protocol.ProposalDecide(..)
    | protocol.MemoryGet
    | protocol.Evolution(..)
    | protocol.WorktreeDiffGet
    | protocol.UnknownCommand(..) -> Forbid(id)
  }
}

/// An approval for one execution or for the session, as the decision the hub's
/// relayed door judges. The grants and the action are the page's echo, and the hub
/// checks them against the record before it commits anything.
fn approval(
  id: Int,
  escalation: String,
  grants: List(Grant),
  action: String,
  expected_seq: Int,
  scope: remote_escalation.Scope,
) -> Verdict {
  Decide(
    id:,
    escalation:,
    decision: remote_escalation.Approve(grants:, action:, scope:),
    expected_seq:,
  )
}
