//// The state of the inbox's open review thread: the review that was read, the
//// revisions of its finds, what is staged, and where a Send stands (the
//// attention inbox, `docs/design-notes/attention-inbox/README.md` section 2.1).
////
//// Nothing here reaches the agent. Every transition is a pure function of the
//// state and one event, so a test states the whole life of a review without
//// drawing a page or calling the daemon, as `web_view/item_pane` does for an
//// ask. `web_view/home` holds the state in its model and performs the effect
//// each step asks for.
////
//// ## How Send runs
////
//// One Send applies the find closes at the revisions the page read, one at a
//// time, and then delivers one prompt (`web_view/review_outbox_rule`) to the
//// session's strand. The prompt is composed, and refused when it is past the
//// composer's bound, before the first close is applied, so an oversized review
//// has no side effect. A close the daemon refuses halts the Send: the prompt
//// says what was closed and would otherwise be wrong, so it is not delivered,
//// and the receipt says so. The closes already applied stay applied and are
//// not applied again by the next Send. A prompt the gateway refuses leaves the
//// staging as it was, so Send can be pressed again.
////
//// The words of a close's outcome and of a refusal are the daemon's fixed
//// words, never text a person typed or a session wrote.
////
//// ## Flow
////
//// `opened` → `loaded` / `revision_read` → staging → `send` → `closed` →
//// `prompted`
////
//// 1. `opened` starts a thread for a session, and `loaded` takes the review the
////    daemon read.
//// 2. `revision_read` takes the revision of each find the pane shows.
//// 3. `verdict`, `comment` and `find_action` stage, and `cleared` takes it all
////    back.
//// 4. `send` begins a Send and says what to do first, `closed` takes the
////    daemon's word on a close and says what is next, and `prompted` takes its
////    word on the prompt.

import core/attention.{type Closure}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/operator
import web_view/review_feed.{type Review}
import web_view/review_outbox_rule
import web_view/review_stage_rule.{type Staging, type Verdict}
import web_view/thread_send

/// What the page has of the open session's review.
pub type Loaded {
  /// The read is out.
  Reading

  /// The daemon's review of the worktree.
  Read(review: Review)

  /// The read was refused or failed. The words are the daemon's fixed ones.
  Unavailable(words: String)
}

/// What the page knows of one find's revision, which a close names.
pub type Revision {
  /// The record's read is out.
  Asking

  /// The record was read at this revision.
  Revision(number: Int)

  /// The record could not be read, so the find cannot be closed from here.
  Unread(words: String)
}

/// What the daemon said of one find close.
pub type Outcome {
  /// The find was closed. The words are the daemon's.
  Done(words: String)

  /// It was not. The words are the daemon's.
  Refused(words: String)
}

/// One find close of a Send, and how it went.
pub type CloseResult {
  CloseResult(find: String, closure: Closure, outcome: Outcome)
}

/// What became of the prompt.
pub type PromptResult {
  /// No prompt was sent, and the words say why.
  NotSent(words: String)

  /// The gateway answered the prompt.
  Answered(answer: thread_send.Answer)
}

/// What a Send did: each close in the order it was applied, and the prompt.
pub type Receipt {
  Receipt(closes: List(CloseResult), prompt: PromptResult)
}

/// Where a Send stands.
pub type Progress {
  /// No send is out and no receipt is held.
  Resting

  /// A send is out. `done` are the closes already answered, and `prompt` is the
  /// text that was composed, and checked against the composer's bound, before
  /// the first close was asked. Staging is refused while a send is out, so the
  /// text is the one that was checked.
  Sending(done: List(CloseResult), prompt: String)

  /// The send ended, and this is what it did.
  Settled(receipt: Receipt)
}

/// What to ask of the daemon next.
pub type Step {
  /// Close a find at the revision the page read.
  CloseStep(find: String, revision: Int, closure: Closure)

  /// Deliver the composed prompt to the session's strand.
  PromptStep(text: String)

  /// Nothing more is asked: the send ended, and `progress` says how.
  Halted
}

/// The open review thread.
pub type State {
  State(
    /// The session whose review is open, or nothing when none is.
    session: Option(String),
    /// The last message the session said when the review was opened. A session
    /// that says something new has a review that may be out of date.
    read_for: Option(String),
    /// What was read.
    loaded: Loaded,
    /// The revisions of the session's finds, by identifier.
    revisions: Dict(String, Revision),
    /// What is staged.
    staging: Staging,
    /// Why the last stage was refused, in fixed words.
    problem: Option(String),
    /// Where the send stands.
    progress: Progress,
  )
}

/// A state with no review open.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.closed().session == None
/// ```
pub fn closed() -> State {
  State(
    session: None,
    read_for: None,
    loaded: Reading,
    revisions: dict.new(),
    staging: review_stage_rule.empty(),
    problem: None,
    progress: Resting,
  )
}

/// Opens a review for a session that said `message`. What was staged belonged
/// to the review before and is dropped.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.opened("a", "done").session == Some("a")
/// ```
pub fn opened(session: String, message: String) -> State {
  State(..closed(), session: Some(session), read_for: Some(message))
}

/// Takes the daemon's review of a session. A read for another session, which a
/// quick second press overtook, is dropped.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.loaded(review_pane.closed(), "a", Error("gone")) == review_pane.closed()
/// ```
pub fn loaded(
  state: State,
  session: String,
  read: Result(Review, String),
) -> State {
  case state.session == Some(session) {
    False -> state
    True ->
      State(..state, loaded: case read {
        Ok(review) -> Read(review)
        Error(words) -> Unavailable(words)
      })
  }
}

/// Takes the read of one find's record, so a close can name its revision.
///
/// ## Examples
///
/// ```gleam
/// assert dict.size(review_pane.revision_read(review_pane.closed(), "f", Ok(3)).revisions) == 1
/// ```
pub fn revision_read(
  state: State,
  find: String,
  read: Result(Int, String),
) -> State {
  State(
    ..state,
    revisions: dict.insert(state.revisions, find, case read {
      Ok(number) -> Revision(number)
      Error(words) -> Unread(words)
    }),
  )
}

/// Marks the finds whose record has not been asked for as asked, and returns
/// them, so the page asks for each once. A find whose read is out, answered or
/// failed is not asked again.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.ask_revisions(review_pane.closed(), []).1 == []
/// ```
pub fn ask_revisions(
  state: State,
  finds: List(String),
) -> #(State, List(String)) {
  let fresh =
    finds
    |> list.unique
    |> list.filter(fn(find) { !dict.has_key(state.revisions, find) })

  #(
    State(
      ..state,
      revisions: list.fold(fresh, state.revisions, fn(held, find) {
        dict.insert(held, find, Asking)
      }),
    ),
    fresh,
  )
}

/// The paths of the open review in the order it draws them, or none before it
/// was read.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.files(review_pane.closed()) == []
/// ```
pub fn files(state: State) -> List(String) {
  case state.loaded {
    Read(review:) -> list.map(review.files, fn(file) { file.path })
    Reading | Unavailable(_) -> []
  }
}

/// Stages a verdict.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.verdict(review_pane.closed(), review_stage_rule.Approve).staging.verdict
///   == Some(review_stage_rule.Approve)
/// ```
pub fn verdict(state: State, chosen: Verdict) -> State {
  // A send that is out has checked what it carries, so nothing changes it.
  case state.progress {
    Sending(..) -> state
    Resting | Settled(_) ->
      State(
        ..state,
        staging: review_stage_rule.verdict(state.staging, chosen),
        problem: None,
        progress: Resting,
      )
  }
}

/// Stages a file's comment, or records why it was refused.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.comment(review_pane.closed(), "x", "t").problem != None
/// ```
pub fn comment(state: State, path: String, text: String) -> State {
  // A send that is out has checked what it carries, so nothing changes it.
  case state.progress {
    Sending(..) -> state
    Resting | Settled(_) ->
      case review_stage_rule.comment(state.staging, files(state), path, text) {
        Ok(staging) ->
          State(..state, staging:, problem: None, progress: Resting)
        Error(problem) ->
          State(
            ..state,
            problem: Some(review_stage_rule.problem_words(problem)),
          )
      }
  }
}

/// Stages how a find is closed. The find's revision must have been read, since
/// the close names it.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.find_action(review_pane.closed(), "f", attention.Fixed, "").problem != None
/// ```
pub fn find_action(
  state: State,
  find: String,
  closure: Closure,
  note: String,
) -> State {
  // A send that is out has checked what it carries, so nothing changes it.
  case state.progress {
    Sending(..) -> state
    Resting | Settled(_) -> staged_find(state, find, closure, note)
  }
}

/// Stages the close of a find whose revision was read, or says why not.
fn staged_find(
  state: State,
  find: String,
  closure: Closure,
  note: String,
) -> State {
  // The close names the revision the page read, so a find not yet read waits.
  case dict.get(state.revisions, find) {
    Ok(Revision(number:)) ->
      case
        review_stage_rule.find_action(
          state.staging,
          find,
          number,
          closure,
          note,
        )
      {
        Ok(staging) ->
          State(..state, staging:, problem: None, progress: Resting)
        Error(problem) ->
          State(
            ..state,
            problem: Some(review_stage_rule.problem_words(problem)),
          )
      }
    Ok(Unread(_)) | Ok(Asking) | Error(Nil) ->
      State(
        ..state,
        problem: Some(
          "That find has not been read yet, so it cannot be closed.",
        ),
      )
  }
}

/// Takes back everything staged.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.cleared(review_pane.closed()) == review_pane.closed()
/// ```
pub fn cleared(state: State) -> State {
  // A send that is out has checked what it carries, so nothing changes it.
  case state.progress {
    Sending(..) -> state
    Resting | Settled(_) ->
      State(
        ..state,
        staging: review_stage_rule.empty(),
        problem: None,
        progress: Resting,
      )
  }
}

/// Begins a Send and says what to ask first. A send already out, an unread
/// review and an empty outbox begin nothing. A prompt that cannot be composed,
/// because it is past the composer's bound, is refused here, before any close.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.send(review_pane.closed()).1 == review_pane.Halted
/// ```
pub fn send(state: State) -> #(State, Step) {
  case state.progress, state.loaded {
    Sending(..), _ -> #(state, Halted)
    Resting, Read(_) | Settled(_), Read(_) ->
      case review_outbox_rule.compose(files(state), state.staging) {
        Ok(text) ->
          step(
            State(
              ..state,
              progress: Sending(done: [], prompt: text),
              problem: None,
            ),
          )
        Error(refusal) -> #(
          State(
            ..state,
            progress: Settled(Receipt(
              closes: [],
              prompt: NotSent(review_outbox_rule.refusal_words(refusal)),
            )),
          ),
          Halted,
        )
      }
    Resting, Reading
    | Resting, Unavailable(_)
    | Settled(_), Reading
    | Settled(_), Unavailable(_)
    -> #(state, Halted)
  }
}

/// Takes the daemon's word on the close that was asked, and says what is next.
/// A close that was done marks its action applied. One that was refused halts
/// the send, with the prompt unsent.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.closed_with(review_pane.closed(), "f", attention.Fixed, review_pane.Done("ok")).1 == review_pane.Halted
/// ```
pub fn closed_with(
  state: State,
  find: String,
  closure: Closure,
  outcome: Outcome,
) -> #(State, Step) {
  // A close answers only while a Send is out.
  case state.progress {
    Sending(done:, prompt:) -> {
      let result = CloseResult(find:, closure:, outcome:)

      // A close that was done is applied and the Send goes on, and one refused halts it.
      case outcome {
        Done(_) ->
          step(
            State(
              ..state,
              staging: review_stage_rule.applied(state.staging, find),
              progress: Sending(done: list.append(done, [result]), prompt:),
            ),
          )
        // A refused close is dropped with the revision it named, so the next
        // pass over the feed reads the find afresh and the owner stages it
        // again against what is there now. The receipt keeps the refusal.
        Refused(_) -> #(
          State(
            ..state,
            staging: review_stage_rule.dropped(state.staging, find),
            revisions: dict.delete(state.revisions, find),
            progress: Settled(Receipt(
              closes: list.append(done, [result]),
              prompt: NotSent("Nothing was sent to the agent."),
            )),
          ),
          Halted,
        )
      }
    }
    Resting | Settled(_) -> #(state, Halted)
  }
}

/// Takes the gateway's word on the prompt. A delivery empties the staging, and
/// a refusal leaves it, so Send can be pressed again.
///
/// ## Examples
///
/// ```gleam
/// // review_pane.prompted(state, thread_send.Delivered(thread_send.Admitted))
/// ```
pub fn prompted(state: State, answer: thread_send.Answer) -> State {
  case state.progress {
    Sending(done:, ..) ->
      State(
        ..state,
        staging: case answer {
          thread_send.Delivered(_) -> review_stage_rule.empty()
          thread_send.Refused(_) -> state.staging
        },
        progress: Settled(Receipt(closes: done, prompt: Answered(answer))),
      )
    Resting | Settled(_) -> state
  }
}

/// The lines a receipt says, one for each close and one for the prompt, in the
/// daemon's fixed words.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.receipt_lines(review_pane.Receipt([], review_pane.NotSent("no"))) == ["no"]
/// ```
pub fn receipt_lines(receipt: Receipt) -> List(String) {
  list.append(
    list.map(receipt.closes, fn(each) {
      each.find
      <> " ("
      <> review_outbox_rule.closure_words(each.closure)
      <> "): "
      <> case each.outcome {
        Done(words:) | Refused(words:) -> words
      }
    }),
    [
      case receipt.prompt {
        NotSent(words:) -> words
        Answered(answer:) ->
          thread_send.answer_words(answer, operator.Prompt, "the session")
      },
    ],
  )
}

/// Whether anything is staged, for a Send that has something to carry.
///
/// ## Examples
///
/// ```gleam
/// assert review_pane.has_staged(review_pane.closed()) == False
/// ```
pub fn has_staged(state: State) -> Bool {
  !review_stage_rule.is_empty(state.staging)
}

/// What a send asks next: the first close not yet applied, else the prompt that
/// was composed when the send began.
fn step(state: State) -> #(State, Step) {
  case review_stage_rule.pending_close(state.staging), state.progress {
    Some(action), _ -> #(
      state,
      CloseStep(
        find: action.id,
        revision: action.revision,
        closure: action.closure,
      ),
    )
    None, Sending(prompt:, ..) -> #(state, PromptStep(prompt))
    None, Resting | None, Settled(_) -> #(state, Halted)
  }
}
