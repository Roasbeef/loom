//// The state of the inbox's item thread: the ask, find or stuck strand whose
//// pane is open, what was read of its record, and what the owner has staged to
//// send (protocol-change/120, the attention inbox's phase 1).
////
//// The pane's one outbox holds at most one staged answer and one staged note.
//// Nothing reaches the session until Send, and Send names the revision the
//// page read the record at, so a record that moved since is refused by the
//// daemon and never delivered. Every transition here is a pure function of the
//// state and one event, so a test states the whole life of a thread without
//// drawing a page or calling the daemon. `web_view/home` holds the state in its
//// model and performs the effects each transition asks for.
////
//// The words of a daemon refusal are the daemon's fixed words
//// (`attention_door.Refusal.words`), and never text the person typed or a
//// session wrote, so the page may draw them as they are.
////
//// ## Flow
////
//// `pick` → `loaded` → `staged_answer` / `staged_note` → `sending` → `settled`
////
//// 1. `pick` opens a thread and says whether its record must be read.
//// 2. `loaded` takes the read, or the words for why there is none.
//// 3. The owner stages an answer and a note, each replacing the last.
//// 4. `sending` marks the outbox out, and `settled` takes the daemon's word.

import core/attention.{type Ask, type Find}
import gleam/option.{type Option, None, Some}
import gleam/string
import web_view/answer_rule.{type Problem, type Staged}
import web_view/attention_rule.{type Key}

/// A record read in full, with the revision it was read at.
pub type Record {
  /// An ask, whose questions the pane draws as components.
  AskRecord(ask: Ask, revision: Int)

  /// A find, whose full text and place the pane shows.
  FindRecord(find: Find, revision: Int)
}

/// What the page has of the open thread's record.
pub type Loaded {
  /// The thread has no record to read: a stuck strand.
  NoRecord

  /// A read is out.
  Loading

  /// The record was read.
  Loaded(record: Record)

  /// The record could not be read. The words are the daemon's fixed ones.
  Unavailable(words: String)
}

/// What is staged to send. Both parts are optional, and Send needs one.
pub type Outbox {
  Outbox(
    /// The checked answer to the open ask.
    answer: Option(Staged),
    /// A message for the thread's strand, which Send delivers after the answer.
    note: Option(String),
  )
}

/// Where the outbox stands.
pub type Progress {
  /// Nothing is out.
  Resting

  /// A send is with the daemon.
  Sending

  /// The daemon answered. The words say what, and whether anything was
  /// delivered. They are fixed words.
  Settled(words: String)
}

/// The open thread. `key` is nothing when the pane shows a session thread.
pub type State {
  State(
    /// The thread that is open.
    key: Option(Key),
    /// Its record.
    loaded: Loaded,
    /// What is staged.
    outbox: Outbox,
    /// Why the last stage was refused, in the daemon's rule's fixed words.
    problem: Option(Problem),
    /// Where the send stands.
    progress: Progress,
  )
}

/// What a send asks of the daemon, in the order it asks.
pub type Step {
  /// Answer the staged ask.
  AnswerStep(answer: Staged)

  /// Message a strand of a session with the staged text.
  NoteStep(session: String, strand: String, text: String)

  /// Nothing is staged.
  NothingStaged
}

/// A state with no thread open.
///
/// ## Examples
///
/// ```gleam
/// assert item_pane.closed().key == None
/// ```
pub fn closed() -> State {
  State(
    key: None,
    loaded: NoRecord,
    outbox: Outbox(answer: None, note: None),
    problem: None,
    progress: Resting,
  )
}

/// Opens a thread. The outbox is emptied, because what was staged belongs to
/// the thread it was staged in, and a stuck strand has no record to read. The
/// second value is whether the page must read the record.
///
/// ## Examples
///
/// ```gleam
/// let #(state, read) = item_pane.pick(item_pane.closed(), key)
/// assert read == item_pane.ReadRecord
/// ```
pub fn pick(_state: State, key: Key) -> #(State, Reading) {
  // An ask and a find have a record to read, and a stuck strand has none.
  let #(loaded, reading) = case key.sort {
    attention_rule.AskSort | attention_rule.FindSort -> #(Loading, ReadRecord)
    attention_rule.StuckSort -> #(NoRecord, SkipRead)
  }

  #(State(..closed(), key: Some(key), loaded:), reading)
}

/// Whether opening a thread needs its record read.
pub type Reading {
  /// Read it.
  ReadRecord

  /// There is none to read.
  SkipRead
}

/// Takes the read of the open thread's record. A read of another thread, which
/// a quick second press overtook, is dropped.
///
/// ## Examples
///
/// ```gleam
/// assert item_pane.loaded(item_pane.closed(), key, Error("gone")) == item_pane.closed()
/// ```
pub fn loaded(state: State, key: Key, read: Result(Record, String)) -> State {
  case state.key == Some(key) {
    False -> state
    True ->
      State(..state, loaded: case read {
        Ok(record) -> Loaded(record)
        Error(words) -> Unavailable(words)
      })
  }
}

/// Stages an answer, replacing the one before it and clearing the last
/// refusal.
///
/// ## Examples
///
/// ```gleam
/// assert item_pane.staged_answer(item_pane.closed(), staged).outbox.answer == Some(staged)
/// ```
pub fn staged_answer(state: State, staged: Staged) -> State {
  State(
    ..state,
    outbox: Outbox(..state.outbox, answer: Some(staged)),
    problem: None,
    progress: Resting,
  )
}

/// Records why a form was not staged. What was staged before stands.
///
/// ## Examples
///
/// ```gleam
/// assert item_pane.refused(item_pane.closed(), problem).problem == Some(problem)
/// ```
pub fn refused(state: State, problem: Problem) -> State {
  State(..state, problem: Some(problem))
}

/// Stages a note for the thread's strand, or takes it back when the text has
/// nothing in it.
///
/// ## Examples
///
/// ```gleam
/// assert item_pane.staged_note(item_pane.closed(), "  ").outbox.note == None
/// ```
pub fn staged_note(state: State, text: String) -> State {
  // A note with nothing but whitespace is no note.
  let note = case string.trim(text) {
    "" -> None
    _ -> Some(text)
  }

  State(
    ..state,
    outbox: Outbox(..state.outbox, note:),
    problem: None,
    progress: Resting,
  )
}

/// Takes back everything staged.
///
/// ## Examples
///
/// ```gleam
/// assert item_pane.unstaged(item_pane.closed()) == item_pane.closed()
/// ```
pub fn unstaged(state: State) -> State {
  State(
    ..state,
    outbox: Outbox(answer: None, note: None),
    problem: None,
    progress: Resting,
  )
}

/// The first thing Send must do for the open thread, and nothing when the
/// outbox is empty. The answer goes first: a note that accompanies it should
/// reach the strand after the answer that it comments on.
///
/// ## Examples
///
/// ```gleam
/// assert item_pane.first_step(item_pane.closed(), "main") == item_pane.NothingStaged
/// ```
pub fn first_step(state: State, strand: String) -> Step {
  case state.outbox.answer, state.outbox.note, state.key {
    Some(answer), _, _ -> AnswerStep(answer)
    None, Some(text), Some(key) -> NoteStep(key.session, strand, text)
    None, Some(_), None | None, None, _ -> NothingStaged
  }
}

/// The step after the answer was delivered: the note, when there is one.
///
/// ## Examples
///
/// ```gleam
/// assert item_pane.after_answer(item_pane.closed(), "main") == item_pane.NothingStaged
/// ```
pub fn after_answer(state: State, strand: String) -> Step {
  case state.outbox.note, state.key {
    Some(text), Some(key) -> NoteStep(key.session, strand, text)
    Some(_), None | None, _ -> NothingStaged
  }
}

/// Marks a send as out.
///
/// ## Examples
///
/// ```gleam
/// assert item_pane.sending(item_pane.closed()).progress == item_pane.Sending
/// ```
pub fn sending(state: State) -> State {
  State(..state, progress: Sending, problem: None)
}

/// Takes the daemon's word. A delivery empties what it delivered; a refusal
/// leaves the outbox as it was, so the owner can fix the cause and send again.
///
/// ## Examples
///
/// ```gleam
/// assert item_pane.settled(item_pane.closed(), "Sent", Everything).progress == item_pane.Settled("Sent")
/// ```
pub fn settled(state: State, words: String, spent: Spent) -> State {
  // A delivery spends what it delivered, and a refusal spends nothing.
  let outbox = case spent {
    Everything -> Outbox(answer: None, note: None)
    TheAnswer -> Outbox(..state.outbox, answer: None)
    Nothing -> state.outbox
  }

  State(..state, outbox:, progress: Settled(words))
}

/// What a daemon word used up of the outbox.
pub type Spent {
  /// The answer and the note both went, or the one that was staged did.
  Everything

  /// The answer went and the note, if any, did not.
  TheAnswer

  /// Nothing went.
  Nothing
}

/// Whether anything is staged.
///
/// ## Examples
///
/// ```gleam
/// assert item_pane.has_staged(item_pane.closed()) == False
/// ```
pub fn has_staged(state: State) -> Bool {
  case state.outbox.answer, state.outbox.note {
    None, None -> False
    Some(_), _ | None, Some(_) -> True
  }
}
