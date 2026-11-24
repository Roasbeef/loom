//// When the page reads a session's brief and which of the brief it may show
//// (protocol-change/125).
////
//// The daemon allows six brief reads in four seconds for each credential, and
//// every read costs the session a bounded walk of its recent entries, so the
//// page reads a brief only for the thread that is open: once when the thread is
//// opened, and again when the page's own refresh finds the thread still open and
//// the last read fifteen seconds old or older. A thread that is not open is
//// never read. `due` decides that from the time of the last read, and nothing
//// else, so it is a function of two numbers and a trigger.
////
//// The brief's peer messages are those that arrived after a time the read
//// named. That time is the raise time of an approval, and the label over the
//// messages says "since it asked", so they are shown only for an approval
//// thread whose brief was read with that very time. A brief read before the
//// approval's time was known, or for any other thread, carries messages that
//// the label would misdescribe, so `shown` drops them. It performs no I/O and
//// draws nothing.
////
//// `due` says whether a read is worth starting now, and `shown` turns what the
//// page holds into the brief a thread draws.

import gleam/option.{type Option, None, Some}
import web_view/session_brief.{type Brief}

/// How old the last read of an open thread's brief must be before the page's
/// refresh reads it again, in milliseconds.
pub const refresh_ms = 15_000

/// How soon after a read a thread's opening reads again, in milliseconds: a
/// person pressing the same row twice reads once.
pub const debounce_ms = 1000

/// What asks for a read.
pub type Trigger {
  /// The person opened the thread, or the thread's own evidence arrived.
  Opened

  /// The page's refresh found the thread still open.
  Refreshed
}

/// The last read the page started of one session's brief.
pub type Read {
  Read(
    /// When it was started, in Unix milliseconds.
    started: Int,
    /// The time it asked peer messages after, or zero.
    since: Int,
  )
}

/// Whether a read is worth starting at `now`, given the last read of the same
/// session and the time the next would ask peer messages after. A session never
/// read is always due, and so is one whose last read asked after another time,
/// since its peer messages would not be the ones the thread labels.
///
/// ## Examples
///
/// ```gleam
/// assert brief_rule.due(None, 0, 0, brief_rule.Refreshed)
/// assert !brief_rule.due(Some(brief_rule.Read(0, 0)), 14_999, 0, brief_rule.Refreshed)
/// assert brief_rule.due(Some(brief_rule.Read(0, 0)), 15_000, 0, brief_rule.Refreshed)
/// assert brief_rule.due(Some(brief_rule.Read(0, 0)), 1, 7, brief_rule.Refreshed)
/// assert !brief_rule.due(Some(brief_rule.Read(0, 0)), 999, 0, brief_rule.Opened)
/// ```
pub fn due(last: Option(Read), now: Int, since: Int, trigger: Trigger) -> Bool {
  case last, trigger {
    None, _ -> True
    Some(Read(since: asked, ..)), _ if asked != since -> True
    Some(Read(started:, ..)), Opened -> now - started >= debounce_ms
    Some(Read(started:, ..)), Refreshed -> now - started >= refresh_ms
  }
}

/// The brief a thread draws from what the page holds: the answer, the time the
/// read that produced it named, and the raise time of the thread's oldest
/// pending approval, when the thread is an approval. The peer messages are kept
/// only when both times are known and equal; every other section is the answer's
/// own. A refused read shows nothing.
///
/// ## Examples
///
/// ```gleam
/// assert brief_rule.shown(None, None, None) == None
/// ```
pub fn shown(
  held: Option(session_brief.Seen),
  read_since: Option(Int),
  raised: Option(Int),
) -> Option(Brief) {
  case held {
    Some(session_brief.Seen(brief:)) ->
      case read_since, raised {
        Some(asked), Some(at) if asked == at -> Some(brief)
        _, _ -> Some(session_brief.Brief(..brief, peers: []))
      }
    Some(session_brief.Unseen(_)) | None -> None
  }
}

/// Whether a held brief's latest message is at least as new as the last
/// finished message the overview reports, so a brief read during an earlier turn
/// is not drawn as what the agent last said after a later turn ended. A brief
/// with no message is not current, and an overview with no time has nothing
/// newer to contradict it.
///
/// ## Examples
///
/// ```gleam
/// assert brief_rule.current(brief, None) == True
/// ```
pub fn current(read: Brief, finished_at: Option(Int)) -> Bool {
  case read.assistant, finished_at {
    Some(assistant), Some(finished) -> assistant.at >= finished
    Some(_), None -> True
    None, Some(_) | None, None -> False
  }
}
