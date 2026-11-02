//// The vocabulary of project mode: identifiers, triggers, mandates, reports
//// and routing decisions, as plain data.
////
//// A project turns outside events into units of authorized work. Everything
//// the engine decides is a function of the values defined here, so the types
//// carry the design's rulings where the compiler can enforce them. A
//// `Mandate` has no field a model could fill, a `Report` has no `Ready`
//// variant, and a `Routing` carries no free text for a worker. Strength
//// (`Explicit` or `Inferred`) is never a field of a routing event: it is set
//// by `project/gate` from the trigger's own inputs and stored in the
//// `Mandate` the engine builds.
////
//// Nothing in this module performs I/O, reads a clock or holds state. Times
//// are system-time milliseconds that the caller passes in, never read from
//// the monotonic clock, so a ledger written on one boot replays on the next.
////
//// What a catalogue row calls a session's standing (`Router`, `Worker`) is
//// not here. It belongs to the catalogue layer, and this package never
//// imports it.

import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string

// --- identifiers -------------------------------------------------------------

/// The identity of one trigger, assigned by its source.
pub type TriggerId {
  TriggerId(
    /// The source's own identifier for the event.
    value: String,
  )
}

/// The identity of one ticket, derived from the trigger that created it.
pub type TicketId {
  TicketId(
    /// A path-safe string, see `ticket_for`.
    value: String,
  )
}

/// A stream of events with its own read position and bot identity.
pub type SourceId {
  SourceId(
    /// The source's name, such as `github` or `composer`.
    value: String,
  )
}

/// A thread of triggers in the order the source defines.
pub type ThreadId {
  ThreadId(
    /// The source's identifier for the thread.
    value: String,
  )
}

/// A person or bot, as the source names them.
pub type ActorId {
  ActorId(
    /// The source's name for the actor.
    value: String,
  )
}

/// The identity of an admission rule in a source's configuration.
pub type RuleId {
  RuleId(
    /// The rule's name in the project configuration.
    value: String,
  )
}

/// A git commit id.
pub type CommitId {
  CommitId(
    /// The commit's hash text.
    value: String,
  )
}

/// The digest of the check command that ran against a commit.
pub type CommandDigest {
  CommandDigest(
    /// The digest text.
    value: String,
  )
}

/// A ledger entry id, which ties a fact to the record that proves it.
pub type EntryId {
  EntryId(
    /// The entry's identifier in the session log or ledger.
    value: String,
  )
}

/// The identity of a worker session, minted by the catalogue and recorded by
/// a `SessionBound` event.
pub type SessionId {
  SessionId(
    /// The catalogue's session id.
    value: String,
  )
}

/// The identity of a project.
pub type ProjectId {
  ProjectId(
    /// The project's id in the catalogue.
    value: String,
  )
}

/// A person who issued a command through the host, never a model.
pub type PrincipalId {
  PrincipalId(
    /// The principal's name as the host authenticated it.
    value: String,
  )
}

/// A pull request the host opened.
pub type PullRequestRef {
  PullRequestRef(
    /// The pull request's URL.
    url: String,
  )
}

/// The most code points of the host's own words that a review reason keeps.
pub const max_reason_chars: Int = 200

/// Why a ticket waits for a person although its work may be done. The host
/// writes every one of these; none is a worker's or a router's text.
pub type ReviewReason {
  /// The project names no check, so nothing could vouch for the work.
  NoCheckConfigured

  /// The check was started and gave no verdict, more than once: it ran out of
  /// time or the sandbox would not run it. That says nothing about the work,
  /// so a person decides whether to publish it.
  CheckUnfinished(
    /// What stopped the check, in the host's words, capped.
    why: String,
  )

  /// The project keeps `publish` off, so nothing goes outward on its own.
  PublishingOff

  /// The host could not push the branch or open the pull request. The words
  /// are the host's description of the step that failed, capped.
  PublishUnavailable(
    /// What failed.
    why: String,
  )

  /// The host repository would not take the worker's commit in: Git refused
  /// an object, or what the host repository holds is not the commit the
  /// worker's clone named. Nothing about the commit was checked or can be
  /// published. The words are the host's description, capped.
  IntakeRefused(
    /// What was refused.
    why: String,
  )
}

/// A review reason for a failed publish, with the host's words capped at
/// `max_reason_chars` code points.
///
/// ## Examples
///
/// ```gleam
/// assert model.publish_unavailable("no remote named origin")
///   == model.PublishUnavailable("no remote named origin")
/// ```
pub fn publish_unavailable(why: String) -> ReviewReason {
  PublishUnavailable(capped(why))
}

/// A review reason for a commit the host repository refused, with the host's
/// words capped at `max_reason_chars` code points.
///
/// ## Examples
///
/// ```gleam
/// assert model.intake_refused("fsck: badTimezone")
///   == model.IntakeRefused("fsck: badTimezone")
/// ```
pub fn intake_refused(why: String) -> ReviewReason {
  IntakeRefused(capped(why))
}

/// A review reason for a check that gave no verdict, with the host's words
/// capped at `max_reason_chars` code points.
///
/// ## Examples
///
/// ```gleam
/// assert model.check_unfinished("the check ran out of time")
///   == model.CheckUnfinished("the check ran out of time")
/// ```
pub fn check_unfinished(why: String) -> ReviewReason {
  CheckUnfinished(capped(why))
}

fn capped(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.take(max_reason_chars)
  |> string.from_utf_codepoints
}

// --- derived identity --------------------------------------------------------

/// The ticket that accepting `trigger` creates. The id is a function of the
/// trigger alone, so accepting the same trigger twice names one ticket.
///
/// ## Examples
///
/// ```gleam
/// assert model.ticket_for(model.TriggerId("c1")) == model.TicketId("t-c1")
/// ```
pub fn ticket_for(trigger: TriggerId) -> TicketId {
  TicketId("t-" <> slug(trigger.value))
}

/// The key under which the host creates or recovers the session for
/// assignment `seq` of `ticket`. The catalogue mints session ids itself, so
/// the key is what makes creation idempotent: a host that crashed between
/// creating a session and recording it looks the key up again and binds the
/// session it finds (`SessionBound`).
///
/// ## Examples
///
/// ```gleam
/// let key = model.request_key(model.ProjectId("p1"), model.TicketId("t-c1"), 2)
/// assert key == "project:p1:t-c1:2"
/// ```
pub fn request_key(project: ProjectId, ticket: TicketId, seq: Int) -> String {
  "project:"
  <> slug(project.value)
  <> ":"
  <> slug(ticket.value)
  <> ":"
  <> int.to_string(seq)
}

/// The id under which a person's answer to a ticket's question travels to its
/// worker. It is a function of the ticket and the question's number, so a
/// delivery repeated after a crash names the same message. The `~` is not in
/// the alphabet a composer request id may use, so no request can take it.
///
/// ## Examples
///
/// ```gleam
/// assert model.answer_id(model.TicketId("t-c1"), 7) == model.TriggerId("a~t-c1~7")
/// ```
pub fn answer_id(ticket: TicketId, question: Int) -> TriggerId {
  TriggerId("a~" <> ticket.value <> "~" <> int.to_string(question))
}

/// The remote branch the host pushes for `ticket`. No model output reaches
/// it, so a router cannot choose what gets pushed.
///
/// ## Examples
///
/// ```gleam
/// assert model.branch_name(model.TicketId("t-c1")) == "project/t-c1"
/// ```
pub fn branch_name(ticket: TicketId) -> String {
  "project/" <> slug(ticket.value)
}

/// The thread of a GitHub issue or pull request. GitHub numbers issues and
/// pull requests from one sequence, so the number names the conversation
/// whichever of the two it is. The `gh-` prefix keeps the name apart from a
/// composer request id, which is a thread of its own.
///
/// ## Examples
///
/// ```gleam
/// assert model.github_thread(12) == model.ThreadId("gh-12")
/// ```
pub fn github_thread(number: Int) -> ThreadId {
  ThreadId("gh-" <> int.to_string(number))
}

/// The thread of the pull request a host opened, read from the last path
/// segment of its URL (`.../pull/7`). A URL that does not end in a number
/// names no thread, and the ticket then follows nothing new.
///
/// ## Examples
///
/// ```gleam
/// assert model.pull_request_thread(model.PullRequestRef("https://github.com/o/r/pull/7"))
///   == option.Some(model.ThreadId("gh-7"))
/// ```
///
/// ```gleam
/// assert model.pull_request_thread(model.PullRequestRef("https://example.test/x"))
///   == option.None
/// ```
pub fn pull_request_thread(reference: PullRequestRef) -> Option(ThreadId) {
  let segments = string.split(reference.url, "/")

  // Only a `pull/<number>` ending names a thread.
  case list.reverse(segments) {
    [last, "pull", ..] ->
      case int.parse(last) {
        Ok(number) if number > 0 -> option.Some(github_thread(number))
        Ok(_) | Error(Nil) -> option.None
      }
    _ -> option.None
  }
}

/// Rewrite `text` so that it is safe in a git ref and in a session id. ASCII
/// letters, digits and `-` stay; every other code point becomes `_`, its hex
/// value and `_`. The mapping is injective, so two ids never share a name.
fn slug(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.map(fn(point) {
    let code = string.utf_codepoint_to_int(point)

    // Safe code points pass through and every other one becomes its escaped
    // hex form.
    case safe_code(code) {
      True -> string.from_utf_codepoints([point])
      False -> "_" <> string.lowercase(int.to_base16(code)) <> "_"
    }
  })
  |> string.concat
}

// Digits, upper and lower case ASCII letters, and the hyphen.
fn safe_code(code: Int) -> Bool {
  { code >= 48 && code <= 57 }
  || { code >= 65 && code <= 90 }
  || { code >= 97 && code <= 122 }
  || code == 45
}

// --- titles ------------------------------------------------------------------

/// The most code points a ticket title keeps.
pub const max_title_codepoints: Int = 80

/// A ticket title, capped. It appears on the board and never in a worker's
/// context, so the router's one piece of free text cannot steer a worker.
pub opaque type TicketTitle {
  TicketTitle(text: String)
}

/// Cap `text` at `max_title_codepoints` code points. An empty result becomes
/// `untitled`, so a title is never empty. The cut walks code points, never
/// graphemes, which the two compile targets count differently.
///
/// ## Examples
///
/// ```gleam
/// assert model.title_text(model.title("Fix the flaky test"))
///   == "Fix the flaky test"
/// ```
///
/// ```gleam
/// assert model.title_text(model.title("")) == "untitled"
/// ```
pub fn title(text: String) -> TicketTitle {
  let kept =
    text
    |> string.to_utf_codepoints
    |> list.take(max_title_codepoints)
    |> string.from_utf_codepoints

  // A title that is cut down to nothing falls back to a fixed word.
  case kept {
    "" -> TicketTitle("untitled")
    _ -> TicketTitle(kept)
  }
}

/// The text of a title.
///
/// ## Examples
///
/// ```gleam
/// assert model.title_text(model.title("a")) == "a"
/// ```
pub fn title_text(title: TicketTitle) -> String {
  title.text
}

// --- triggers and the gate's inputs ------------------------------------------

/// How much authority a request carries.
pub type Strength {
  /// A person asked, and the request works in every mode.
  Explicit

  /// The system inferred the work; it needs `Auto`, a rule and a verdict.
  Inferred
}

/// Who sent a trigger, as the source classified them from its literal
/// allowlists.
pub type Sender {
  /// The owner, through the composer.
  Owner

  /// A person on the source's allowlist.
  Person

  /// A bot on the source's allowlist.
  ListedBot

  /// A CI failure report.
  CiFailure

  /// Anyone not listed.
  Unlisted
}

/// Whether the message addressed the agent.
pub type Addressing {
  /// The message addressed the agent.
  Addressed

  /// The message did not address the agent.
  Unaddressed
}

/// Whether an admission rule's grant includes approvals.
pub type ApprovalGrant {
  /// The rule lets this work have approvals routed to a person.
  ApprovalsGranted

  /// Approvals are refused.
  ApprovalsNotGranted
}

/// A rule of the source's configuration that matched a trigger.
pub type RuleMatch {
  RuleMatch(
    /// The rule that matched.
    rule: RuleId,
    /// What the rule grants beyond admission.
    approvals: ApprovalGrant,
  )
}

/// What the gate reads to decide a trigger's strength. All of it comes from
/// the source and none from a model.
pub type Inputs {
  Inputs(
    /// Who sent it.
    sender: Sender,
    /// Whether it addressed the agent.
    addressing: Addressing,
    /// The rule that matched it, if any.
    rule: Option(RuleMatch),
  )
}

/// One immutable event from a source.
pub type Trigger {
  Trigger(
    /// The source's id; accepting a trigger twice makes one ticket.
    id: TriggerId,
    /// The source it came from.
    source: SourceId,
    /// The thread it belongs to.
    thread: ThreadId,
    /// Who sent it.
    actor: ActorId,
    /// The inputs the gate decides strength from.
    inputs: Inputs,
    /// How many hops of the project's own output precede it.
    generation: Int,
    /// System time in milliseconds when the source observed it.
    at_ms: Int,
  )
}

/// Why a trigger was admitted, in the words of the authority table.
pub type Basis {
  /// The owner typed it in the composer.
  FromComposer

  /// An allowed person addressed the agent.
  FromAddressed

  /// An allowed person followed up on their own ticket's thread.
  FromFollowUp

  /// An allowed person spoke without addressing the agent.
  FromOverheard

  /// A listed bot or a CI failure.
  FromAutomation

  /// An unlisted sender whom a rule admitted.
  FromRule(
    /// The admitting rule.
    rule: RuleId,
  )
}

/// What an accept grants. Immutable, written by the host, and typed so that
/// no model output can reach it.
pub type Mandate {
  Mandate(
    /// Explicit or inferred, as the gate decided.
    strength: Strength,
    /// Why the trigger was admitted.
    basis: Basis,
    /// Whose request it was.
    actor: ActorId,
    /// The source that carried it.
    source: SourceId,
    /// How far the grant reaches.
    scope: Scope,
    /// The policy version in force when the mandate was written.
    policy_version: String,
  )
}

/// The reach of a mandate beyond its strength.
pub type Scope {
  Scope(
    /// The workspace the ticket's worktree is cut from.
    workspace: String,
    /// Whether approvals may be routed to a person for this work.
    approvals: ApprovalGrant,
  )
}

// --- threads -----------------------------------------------------------------

/// Whether the gate let a trigger through, as the thread records it.
pub type Reception {
  /// The gate admitted the trigger.
  Received

  /// The gate did not admit it. It is recorded and never delivered.
  Recorded
}

/// One trigger on a thread.
pub type ThreadEntry {
  ThreadEntry(
    /// The trigger.
    trigger: TriggerId,
    /// Whether it was admitted.
    reception: Reception,
  )
}

/// Triggers in the order they arrived.
pub type Thread {
  Thread(
    /// The thread's id.
    id: ThreadId,
    /// Entries, newest first.
    entries: List(ThreadEntry),
  )
}

/// A link between a ticket and a thread. It delivers admitted triggers and
/// grants nothing.
pub type Subscription {
  Subscription(
    /// The subscribed ticket.
    ticket: TicketId,
    /// The thread it follows.
    thread: ThreadId,
  )
}

// --- reports and work --------------------------------------------------------

/// Whether a worker has an unanswered question for a person.
pub type Question {
  /// Nothing is pending.
  NoQuestion

  /// A question awaits an answer that echoes `seq`.
  Asking(
    /// The question's sequence number.
    seq: Int,
  )
}

/// A worker's closed-set status. There is no `Ready`: readiness comes only
/// from a host-built `CheckPassed`.
pub type Report {
  /// The worker is making progress.
  Progress

  /// The worker is idle, possibly with a question for a person.
  Waiting(
    /// The open question, if any.
    question: Question,
  )

  /// The worker cannot continue without help.
  Blocked

  /// The worker's attempt failed.
  Failed

  /// The worker found the ticket unworkable and let it go.
  Dropped
}

/// Whether a diff touches the project's protected paths. The host computes
/// it, so it is a two-variant type and not a flag a worker could set.
pub type PathScope {
  /// The diff touches the Makefile, CI configuration or the check itself.
  ProtectedPathsTouched

  /// It does not.
  ProtectedPathsUntouched
}

/// The state of the worker's branch when it reported.
pub type Head {
  /// The report carries no commit.
  NoHead

  /// The host snapshotted the worker's head.
  Head(
    /// The snapshot commit.
    commit: CommitId,
    /// Whether its diff touches protected paths.
    paths: PathScope,
  )
}

/// How a worker session ended.
pub type SessionEnd {
  /// The session finished normally.
  SessionExited

  /// The session crashed or was lost.
  SessionCrashed

  /// The assignment was ended by the engine because its worker came to rest:
  /// its work is waiting for a person and the worker is idle. Only the engine
  /// ends an assignment this way, and the session and its clone stay. The next
  /// assignment of the ticket may take the same session over, see
  /// `work.rest`.
  SessionRested
}

/// How a ticket ended, in the words the board shows after `ended/`.
pub type Outcome {
  /// Its pull request merged.
  Merged

  /// Its pull request closed unmerged.
  Closed

  /// The worker reported the ticket unworkable.
  Abandoned

  /// A person stopped it. Such a ticket never resumes.
  StoppedByPerson
}

/// Which kind of demand put a ticket in line for a session.
pub type Wanted {
  /// A person's message wants it; this alone may use the reserved slot.
  ByPerson

  /// The router or a retry wants it.
  ByRouting
}

/// Whether a ticket is waiting for a session.
pub type Demand {
  /// Nothing is waiting.
  Satisfied

  /// A session is wanted.
  Wanting(
    /// What wants it.
    by: Wanted,
  )
}

/// Whether a person has spoken to the worker since its latest report.
pub type Heard {
  /// No person has.
  Silent

  /// A person has.
  PersonHeard
}

// --- routing -----------------------------------------------------------------

/// How a trigger relates to another ticket.
pub type Relation {
  /// It repeats that ticket.
  Duplicate

  /// It blocks that ticket.
  Blocks

  /// It follows that ticket.
  Follows
}

/// What the router does with a candidate.
pub type RouteKind {
  /// Open a new ticket.
  Accept(
    /// The capped title.
    title: TicketTitle,
  )

  /// Add the trigger to an open ticket.
  Attach(
    /// The open ticket.
    ticket: TicketId,
  )

  /// Reopen an ended ticket with the trigger.
  Resume(
    /// The ended ticket.
    ticket: TicketId,
  )
}

/// A routing decision. It carries references and no text for the worker.
pub type Routing {
  Routing(
    /// The candidate being routed.
    trigger: TriggerId,
    /// What to do with it.
    kind: RouteKind,
    /// Triggers the worker should hold the work for, by reference.
    holds: List(TriggerId),
    /// Other tickets this one relates to.
    related: List(#(TicketId, Relation)),
    /// A trigger that handed the work back earlier.
    prior_hand_back: Option(TriggerId),
  )
}

// --- project controls --------------------------------------------------------

/// How a source and rule pair is allowed to act.
pub type Mode {
  /// Inferred work from the pair is ignored.
  Off

  /// The whole path runs and records what would have happened.
  Observe

  /// Inferred work from the pair may be accepted. Needs a current verdict.
  Auto
}

/// What a recorded verdict found.
pub type VerdictOutcome {
  /// The pair passed its evaluation.
  VerdictPassed

  /// It did not.
  VerdictFailed
}

/// Whether the project's token ceiling has been reached.
pub type Ceiling {
  /// New assignments may start.
  CeilingClear

  /// New assignments for inferred work are refused.
  CeilingReached
}
