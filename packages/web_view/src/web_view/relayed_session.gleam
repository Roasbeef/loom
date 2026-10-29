//// The state and rules of the page of one session that runs on another
//// orchestrator (protocol-change/094, the placement revamp's slice S2b).
////
//// The page is the home component showing one relayed session in its centre
//// (`home.Relayed`), so the sidebar, the account panel and every ticket of the
//// home stay as they are. This module is what that centre holds: the row and the
//// transcript page the box last gave, whether the box is answering, whether a
//// reply, a stop, an archive or a decision is out, and the words of the last
//// refusal. It decides which presses may reach the daemon and says what the page
//// then owes, as `web_view/composer` does for a new session, and it performs
//// nothing itself.
////
//// ## What a press may do
////
//// A page may send a reply, stop the run, archive the session and decide the
//// requests the session's row lists. It may not delete, share, move, rename,
//// change the model, fork, or open another strand: the daemon offers none of them
//// for a relayed session and the page draws none. Each press is checked here
//// against the row the page last read, so a message for a request the page did
//// not draw, or for a question that has changed since, asks nothing. The daemon
//// checks the same things again from a fresh read of the box, and the box judges
//// them a third time against its own table.
////
//// ## One thing at a time
////
//// A reply is out until its answer arrives, and a second press asks nothing. So
//// is a stop or an archive, and a decision is out per request. A reply whose
//// answer was lost is left in the form where the person typed it, because the
//// form is only rebuilt after a reply landed (`State.sent` keys it): the person
//// looks at the transcript before sending it again, since it may have arrived.
////
//// ## When the box stops answering
////
//// The box keeps running a session whatever happens to the link. A read that
//// fails leaves the row and the transcript the page already has and marks them
//// stale (`Reach`), remembering when the failures began, so the page can say how
//// old what it shows is. The next read that succeeds replaces them.
////
//// ## Flow
////
//// `open` → `heard` → `update` → `replied` / `stopped` / `archived` / `decided`
////
//// 1. `open` is the state of a page that has read nothing.
//// 2. `heard` applies a read of the box.
//// 3. `update` applies one press and says what the page owes the daemon.
//// 4. The answer of each request is applied by the function named for it.
//// 5. `view/relayed_session` draws the state.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import web_view/composer
import web_view/relayed

/// The most bytes of a reply the page sends. A longer one is refused on the form,
/// in words, and nothing is sent, so a person never loses text to a bound they
/// could not see.
pub const reply_limit = composer.prompt_limit

/// Whether the session is in the box's list.
pub type Presence {
  /// No read has answered yet.
  Unread

  /// The box's list holds the session.
  Listed

  /// The box answered and its list does not hold the session. It was archived or
  /// deleted, or the box never made it for this daemon.
  Unlisted
}

/// Whether the box is answering.
pub type Reach {
  /// The latest read was answered, or none has failed.
  Answering

  /// The latest read failed. What the page shows is the last good read, and the
  /// box has been out of reach since `since_ms`.
  Silent(
    /// When the failures began, in Unix milliseconds on this daemon's clock.
    since_ms: Int,
    /// Why the latest read failed, in words for the person.
    why: String,
  )
}

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
  Busy
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
    /// The orchestrator's `[orchestrators.<name>]` key, which the router checked.
    orchestrator: String,
    /// The session's identity there, which the router checked.
    session: String,
    /// Whether the box's list holds the session.
    presence: Presence,
    /// The session's row in the last list that answered.
    row: Option(relayed.Row),
    /// The transcript page the box last gave.
    history: Option(relayed.History),
    /// When the last complete read was made, in Unix milliseconds.
    seen_ms: Option(Int),
    /// When the last read of any outcome finished, in Unix milliseconds, which
    /// is the instant the page counts the age of what it shows from.
    clock_ms: Int,
    /// Whether the box is answering.
    reach: Reach,
    /// Whether a reply is out.
    sending: Sending,
    /// Whether a stop or an archive is out or being confirmed.
    acting: Acting,
    /// The request whose decision is out, if one is.
    deciding: Option(String),
    /// The request whose decision the box accepted and whose card a later read
    /// may still list, so that "Your decision was sent." is said until a read no
    /// longer lists it.
    decided: Option(String),
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
/// let state = relayed_session.open("box", "0198c0de-0000-7000-8000-000000000001")
/// assert state.sending == relayed_session.Ready
/// assert state.presence == relayed_session.Unread
/// ```
pub fn open(orchestrator: String, session: String) -> State {
  State(
    orchestrator:,
    session:,
    presence: Unread,
    row: None,
    history: None,
    seen_ms: None,
    clock_ms: 0,
    reach: Answering,
    sending: Ready,
    acting: Calm,
    deciding: None,
    decided: None,
    notice: None,
    sent: 0,
  )
}

/// Applies a read of the box. A complete read replaces the row and transcript,
/// and a session the list does not hold clears both. A failed list or transcript
/// keeps the last complete page and remembers when the failures began; the
/// failures that follow keep that time, so the age shown is the age of the data.
/// `now_ms` is this daemon's clock.
///
/// ## Examples
///
/// ```gleam
/// let state = relayed_session.open("box", id)
/// let state = relayed_session.heard(state, relayed.Unreached("down"), 50)
/// assert state.reach == relayed_session.Silent(since_ms: 50, why: "down")
/// ```
pub fn heard(state: State, read: relayed.Read, now_ms: Int) -> State {
  let state = State(..state, clock_ms: now_ms)

  // Update presence, history, and answering status depending on read outcome.
  case read {
    // A transcript failure cannot make an older complete page fresh. On the
    // first partial read the row and its error are still useful to show.
    relayed.Heard(
      row: Some(_) as row,
      history: relayed.Unreadable(why:) as history,
    ) ->
      case state.history {
        Some(relayed.Shown(_)) ->
          State(..state, reach: silent(state.reach, why, now_ms))
        Some(relayed.Unreadable(_)) | None ->
          State(
            ..state,
            presence: Listed,
            row:,
            history: Some(history),
            reach: silent(state.reach, why, now_ms),
          )
      }

    relayed.Heard(row: Some(_) as row, history:) ->
      State(
        ..state,
        presence: Listed,
        row:,
        history: Some(history),
        seen_ms: Some(now_ms),
        reach: Answering,
      )
      |> settled_decision

    // A session the list does not hold has nothing to act on, so nothing that
    // was pending on it stays on the page either.
    relayed.Heard(row: None, ..) ->
      State(
        ..state,
        presence: Unlisted,
        row: None,
        history: None,
        seen_ms: Some(now_ms),
        reach: Answering,
        deciding: None,
      )
      |> settled_decision

    relayed.Unreached(why:) ->
      State(..state, reach: silent(state.reach, why, now_ms))
  }
}

/// Once a read no longer lists the request whose decision was sent, the decision
/// has taken effect and the line saying it was sent has nothing left to say. Any
/// other notice stays until the next press replaces it.
fn settled_decision(state: State) -> State {
  // Check if there is an in-flight decision to settle.
  case state.decided {
    None -> state
    Some(escalation) -> {
      // Verify whether the escalated request still appears in needs list.
      let listed = case state.row {
        Some(row) ->
          list.any(row.needs, fn(need) { need.escalation == escalation })
        None -> False
      }

      // Clear decision and notice if the need is no longer listed.
      case listed, state.notice {
        True, _ -> state
        False, Some(Said(_)) -> State(..state, decided: None, notice: None)
        False, _ -> State(..state, decided: None)
      }
    }
  }
}

// A failure that follows a failure keeps the time the first one began.
fn silent(reach: Reach, why: String, now_ms: Int) -> Reach {
  case reach {
    Silent(since_ms:, ..) -> Silent(since_ms:, why:)
    Answering -> Silent(since_ms: now_ms, why:)
  }
}

/// Applies one press and says what the page owes. Every press is judged against
/// the row the page last read: with none, the session is not one the page holds
/// and nothing is asked. A reply is asked only while none is out and only with
/// some text within `reply_limit`; a stop only while nothing else is in progress;
/// an archive only after its question was asked; a decision only for a request
/// the row lists at the revision the card showed, which the box's ceiling lets the
/// page decide, and only while no decision is out.
///
/// ## Examples
///
/// ```gleam
/// let #(state, intent) = relayed_session.update(relayed_session.open("box", id), relayed_session.Stopped)
/// assert intent == relayed_session.Stay
/// ```
pub fn update(state: State, message: Msg) -> #(State, Intent) {
  case state.row {
    None -> #(state, Stay)
    Some(held) ->
      case message {
        Replied(text:) -> replying(state, text)
        Stopped -> stopping(state)
        ArchiveAsked -> asking_archive(state)
        ArchiveConfirmed -> confirming_archive(state)
        ArchiveCancelled -> cancelling_archive(state)
        Decided(escalation:, seq:, choice:) ->
          deciding(state, held, escalation, seq, choice)
      }
  }
}

/// A reply, when none is out and the text has something in it within the bound.
fn replying(state: State, text: String) -> #(State, Intent) {
  let trimmed = string.trim(text)

  // Validate that no reply is currently sending and that message is non-empty.
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

// A stop, while nothing else is in progress. Stopping is not undone by asking
// twice, and the box does not stop a run that already ended, so it asks at once.
fn stopping(state: State) -> #(State, Intent) {
  case state.acting {
    Calm -> #(State(..state, acting: Busy, notice: None), StopRun)
    Confirming | Busy -> #(state, Stay)
  }
}

// The first press of Archive only opens the question.
fn asking_archive(state: State) -> #(State, Intent) {
  case state.acting {
    Calm -> #(State(..state, acting: Confirming, notice: None), Stay)
    Confirming | Busy -> #(state, Stay)
  }
}

// The second press sends, and only for a question that is open.
fn confirming_archive(state: State) -> #(State, Intent) {
  case state.acting {
    Confirming -> #(State(..state, acting: Busy, notice: None), ArchiveSession)
    Calm | Busy -> #(state, Stay)
  }
}

// Cancel closes an open question and nothing else.
fn cancelling_archive(state: State) -> #(State, Intent) {
  case state.acting {
    Confirming -> #(State(..state, acting: Calm), Stay)
    Calm | Busy -> #(state, Stay)
  }
}

/// A decision for a request the row lists, at the revision the card showed, and
/// one the ceiling lets the page decide. Allowing for the session is asked only
/// for a request whose grants may be remembered.
fn deciding(
  state: State,
  row: relayed.Row,
  escalation: String,
  seq: Int,
  choice: relayed.Choice,
) -> #(State, Intent) {
  let found = relayed.find_need(row.needs, escalation, seq)

  // Verify the escalation need is actionable and within permissible decision scope.
  case found, state.deciding, choice {
    Ok(relayed.Need(ability: relayed.ViewOnly, ..)), _, _
    | Error(Nil), _, _
    | Ok(_), Some(_), _
    | Ok(relayed.Need(remember: relayed.OnceOnly, ..)),
      None,
      relayed.AllowForSession
    -> #(state, Stay)
    Ok(_), None, _ -> #(
      State(..state, deciding: Some(escalation), notice: None),
      Decide(escalation:, seq:, choice:),
    )
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
      State(..state, acting: Calm, notice: Some(Said("Stop requested.")))
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
      State(
        ..state,
        deciding: None,
        decided: state.deciding,
        notice: Some(Said("Your decision was sent.")),
      )
    relayed.Refusal(why:) | relayed.Unknown(why:) ->
      State(..state, deciding: None, notice: Some(Failed(why)))
  }
}
