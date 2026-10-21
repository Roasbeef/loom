//// The state and rules of the page of one session that runs on another
//// orchestrator (protocol-change/094, the placement revamp's slice S2b).
////
//// The page is the home component showing one relayed session in its centre
//// (`home.Visiting`), so the sidebar, the account panel and every ticket of the
//// home stay as they are. This module is what that centre holds: the transcript
//// page the box last gave, whether a reply, a stop, an archive or a decision is
//// out, and the words of the last refusal. It decides which presses may reach the
//// daemon and says what the page then owes, as `web_view/composer` does for a new
//// session, and it performs nothing itself.
////
//// ## What a press may do
////
//// A page may send a reply, stop the run, archive the session and decide the
//// requests the session's row lists. It may not delete, share, move, rename,
//// change the model, fork, or open another strand: the daemon offers none of them
//// for a relayed session and the page draws none. Each press is checked here
//// against the row the page last read (`relayed.find_row`), so a message for a
//// session or a request the page did not draw, or for a question that has changed
//// since, asks nothing. The daemon checks the same things again from what it
//// handed the page, and the box judges them a third time against its own table.
////
//// ## One thing at a time
////
//// A reply is out until its answer arrives, and a second press asks nothing. So
//// is a stop or an archive, and a decision is out per request. A reply whose
//// answer was lost is left in the box where the person typed it, because the form
//// is only rebuilt after a reply landed (`State.sent` keys it): the person looks
//// at the transcript before sending it again, since it may have arrived.
////
//// ## Flow
////
//// `update` → `replied` / `stopped` / `archived` / `decided` / `read`
////
//// 1. `update` applies one press and says what the page owes the daemon.
//// 2. The answer of each request is applied by the function named for it.
//// 3. `view/relayed_session` draws the state with the row the page last read.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import web_view/composer
import web_view/relayed

/// The most bytes of a reply the page sends. A longer one is refused on the form,
/// in words, and nothing is sent, so a person never loses text to a bound they
/// could not see.
pub const reply_limit = composer.prompt_limit

/// Whether a reply is out.
pub type Sending {
  /// Nothing is out, and a press may send a reply.
  Ready

  /// A reply is with the daemon, and a second press asks nothing.
  Out
}

/// Whether a stop or an archive is out or being confirmed.
pub type Acting {
  /// Neither is in progress.
  Calm

  /// The Archive button was pressed once, and the page asks again before it sends
  /// anything, as the sidebar's archive control does.
  Confirming

  /// A stop or an archive is with the daemon.
  Working
}

/// What the page last said about a press, drawn above the reply form.
pub type Notice {
  /// The press succeeded, or says what the page did.
  Said(
    /// The words.
    words: String,
  )

  /// The press was refused or its outcome is unknown.
  Failed(
    /// The words.
    words: String,
  )
}

/// The page's state for one relayed session.
pub type State {
  State(
    /// The orchestrator's key, a row the page drew.
    orchestrator: String,
    /// The session's identity there.
    session: String,
    /// The transcript page the box last gave, or `None` while the first read is
    /// out.
    history: Option(relayed.History),
    /// Whether a reply is out.
    sending: Sending,
    /// Whether a stop or an archive is out or being confirmed.
    acting: Acting,
    /// The request whose decision is out, if one is.
    deciding: Option(String),
    /// What the page last said about a press.
    notice: Option(Notice),
    /// How many replies have landed, which keys the reply form so that it is
    /// rebuilt empty after one lands and left as typed after any other outcome.
    sent: Int,
  )
}

/// Every press the page's centre offers. None carries text the page did not draw
/// except `Replied`, whose text is the person's own.
pub type Msg {
  /// The reply form was submitted with this text.
  Replied(text: String)

  /// The Stop button was pressed.
  Stopped

  /// The Archive button was pressed.
  ArchiveAsked

  /// The archive question was confirmed.
  ArchiveConfirmed

  /// The archive question was cancelled.
  ArchiveCancelled

  /// A request card's button was pressed. The request and the question's revision
  /// are the ones the card was drawn with.
  Decided(
    /// The box's identity for the request.
    escalation: String,
    /// The revision the person was shown.
    seq: Int,
    /// What was pressed.
    choice: relayed.Choice,
  )
}

/// What the page owes the daemon after a press.
pub type Intent {
  /// Nothing.
  Stay

  /// Send this reply to the session's main strand.
  SendReply(
    /// The text, trimmed.
    text: String,
  )

  /// Stop the session's current run.
  StopRun

  /// Archive the session.
  ArchiveSession

  /// Decide a request.
  Decide(
    /// The box's identity for the request.
    escalation: String,
    /// The revision the person was shown.
    seq: Int,
    /// What the person chose.
    choice: relayed.Choice,
  )
}

/// The state of a page that has just opened a session, before it has read
/// anything.
///
/// ## Examples
///
/// ```gleam
/// assert relayed_session.open("box", "0198c0de-0000-7000-8000-000000000001").sending
///   == relayed_session.Ready
/// ```
pub fn open(orchestrator: String, session: String) -> State {
  State(
    orchestrator:,
    session:,
    history: None,
    sending: Ready,
    acting: Calm,
    deciding: None,
    notice: None,
    sent: 0,
  )
}

/// Applies one press and says what the page owes. Every press is judged against
/// `row`, the session's row in what the page last read: with none, the session is
/// not one the page holds and nothing is asked. A reply is asked only while none
/// is out and only with some text within `reply_limit`; a stop only while nothing
/// else is in progress; an archive only after its question was asked; a decision
/// only for a request the row lists at the revision the card showed, which the
/// box's ceiling lets the page decide, and only while no decision for it is out.
///
/// ## Examples
///
/// ```gleam
/// let #(state, intent) = relayed_session.update(relayed_session.open("box", id), relayed_session.Stopped, Error(Nil))
/// assert intent == relayed_session.Stay
/// ```
pub fn update(
  state: State,
  message: Msg,
  row: Result(relayed.Row, Nil),
) -> #(State, Intent) {
  case row {
    Error(Nil) -> #(state, Stay)
    Ok(held) ->
      case message {
        Replied(text:) -> replying(state, text)
        Stopped -> stopping(state)
        ArchiveAsked ->
          case state.acting {
            Calm -> #(State(..state, acting: Confirming, notice: None), Stay)
            Confirming | Working -> #(state, Stay)
          }
        ArchiveConfirmed ->
          case state.acting {
            Confirming -> #(
              State(..state, acting: Working, notice: None),
              ArchiveSession,
            )
            Calm | Working -> #(state, Stay)
          }
        ArchiveCancelled ->
          case state.acting {
            Confirming -> #(State(..state, acting: Calm), Stay)
            Calm | Working -> #(state, Stay)
          }
        Decided(escalation:, seq:, choice:) ->
          deciding(state, held, escalation, seq, choice)
      }
  }
}

// A reply, when none is out and the text has something in it within the bound.
fn replying(state: State, text: String) -> #(State, Intent) {
  let trimmed = string.trim(text)

  case state.sending, trimmed {
    Out, _ -> #(state, Stay)
    Ready, "" -> #(state, Stay)
    Ready, _ ->
      case string.byte_size(trimmed) > reply_limit {
        True -> #(
          State(
            ..state,
            notice: Some(Failed(
              "That reply is too long to send. Shorten it, or send the rest in another message.",
            )),
          ),
          Stay,
        )
        False -> #(
          State(..state, sending: Out, notice: None),
          SendReply(trimmed),
        )
      }
  }
}

// A stop, while nothing else is in progress. A stop is not undone by asking
// twice, and a run that already ended is not stopped again by the box, so it asks
// at once.
fn stopping(state: State) -> #(State, Intent) {
  case state.acting {
    Calm -> #(State(..state, acting: Working, notice: None), StopRun)
    Confirming | Working -> #(state, Stay)
  }
}

// A decision for a request the row lists, at the revision the card showed.
fn deciding(
  state: State,
  row: relayed.Row,
  escalation: String,
  seq: Int,
  choice: relayed.Choice,
) -> #(State, Intent) {
  let found =
    list.find(row.needs, fn(need) {
      need.escalation == escalation && need.seq == seq
    })

  case found, state.deciding {
    Ok(relayed.Need(ability: relayed.Decidable, ..)), None -> #(
      State(..state, deciding: Some(escalation), notice: None),
      Decide(escalation:, seq:, choice:),
    )
    Ok(relayed.Need(ability: relayed.ViewOnly, ..)), _
    | Ok(_), Some(_)
    | Error(Nil), _
    -> #(state, Stay)
  }
}

/// The state after a reply's answer. A reply that landed rebuilds the form empty
/// and says nothing; a refusal or an unknown outcome leaves the form as typed and
/// says why.
///
/// ## Examples
///
/// ```gleam
/// assert relayed_session.replied(relayed_session.open("box", id), relayed.Done).sent == 1
/// ```
pub fn replied(state: State, outcome: relayed.Outcome) -> State {
  case outcome {
    relayed.Done ->
      State(..state, sending: Ready, notice: None, sent: state.sent + 1)
    relayed.Refusal(why:) | relayed.Unknown(why:) ->
      State(..state, sending: Ready, notice: Some(Failed(why)))
  }
}

/// The state after a stop's answer.
///
/// ## Examples
///
/// ```gleam
/// assert relayed_session.stopped(relayed_session.open("box", id), relayed.Done).acting == relayed_session.Calm
/// ```
pub fn stopped(state: State, outcome: relayed.Outcome) -> State {
  case outcome {
    relayed.Done ->
      State(..state, acting: Calm, notice: Some(Said("The run was stopped.")))
    relayed.Refusal(why:) | relayed.Unknown(why:) ->
      State(..state, acting: Calm, notice: Some(Failed(why)))
  }
}

/// The state after an archive's answer.
///
/// ## Examples
///
/// ```gleam
/// assert relayed_session.archived(relayed_session.open("box", id), relayed.Done).acting == relayed_session.Calm
/// ```
pub fn archived(state: State, outcome: relayed.Outcome) -> State {
  case outcome {
    relayed.Done ->
      State(
        ..state,
        acting: Calm,
        notice: Some(Said(
          "The session was archived. Delete it on its own machine's page if you want it gone.",
        )),
      )
    relayed.Refusal(why:) | relayed.Unknown(why:) ->
      State(..state, acting: Calm, notice: Some(Failed(why)))
  }
}

/// The state after a decision's answer. The request leaves the card when the next
/// read lists the session without it, so a decision that was done changes only
/// what the page says.
///
/// ## Examples
///
/// ```gleam
/// assert relayed_session.decided(relayed_session.open("box", id), relayed.Done).deciding == None
/// ```
pub fn decided(state: State, outcome: relayed.Outcome) -> State {
  case outcome {
    relayed.Done ->
      State(..state, deciding: None, notice: Some(Said("Your decision was sent.")))
    relayed.Refusal(why:) | relayed.Unknown(why:) ->
      State(..state, deciding: None, notice: Some(Failed(why)))
  }
}

/// The state after a read of the transcript. A page that arrived replaces the one
/// before it whole.
///
/// ## Examples
///
/// ```gleam
/// assert relayed_session.read(relayed_session.open("box", id), relayed.Unreadable("slow")).history
///   == Some(relayed.Unreadable("slow"))
/// ```
pub fn read(state: State, history: relayed.History) -> State {
  State(..state, history: Some(history))
}
