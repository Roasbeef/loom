//// The words the inbox says about time, and the sentences it builds from a
//// stuck strand's reason code (protocol-change/120, the addendum on stuck
//// strands, and 124).
////
//// The daemon reports instants as Unix milliseconds and the server cannot know
//// the browser's zone, so a time of day is never formatted here. A sentence that
//// holds one is a `Phrase`: a list of fixed words and instants, and the view
//// draws each instant as a `<loom-time>` that the browser words in its own zone
//// (`view/phrase`). What this module does decide is how long ago something was
//// ("1h 22m"), when a wait is long enough to be marked, and which fixed words a
//// reason code gets. It performs no I/O and draws nothing.
////
//// ## Flow
////
//// `short_age` and `overdue` word a wait; `stuck_title` and `stuck_phrase` word
//// a stuck strand from its reason code, through `kind_of`.
////
//// 1. `short_age` words a wait as the row's right-hand age.
//// 2. `overdue` says whether the wait is one the row marks.
//// 3. `turn_words` words how long a turn has run.
//// 4. `kind_of` reads the closed table of reason codes, and `stuck_title` and
////    `stuck_phrase` word each entry of it.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import web_view/session_brief

/// A wait of this many milliseconds or more is marked on a row as long: an hour.
pub const overdue_after_ms = 3_600_000

/// One piece of a sentence that holds an instant.
pub type Part {
  /// Fixed words, or words the daemon bounded; drawn as a text node.
  Words(String)

  /// An instant in Unix milliseconds, drawn as the time of day in the browser's
  /// zone.
  Clock(Int)
}

/// A sentence as pieces, in order.
pub type Phrase =
  List(Part)

/// Which sort of failure a stuck strand's reason code names. The table is
/// closed: a code that is not listed is `Other`, so the page never words a
/// reason it was not told about.
pub type Failure {
  /// The provider refused the request for a rate limit.
  RateLimited

  /// The provider said it was overloaded.
  Overloaded

  /// The provider did not answer in time.
  TimedOut

  /// Any other code, or none.
  Other
}

/// How long a wait has gone on, as a row's age says it: "now" under a minute,
/// minutes alone under an hour, hours and minutes under a day, then days.
///
/// ## Examples
///
/// ```gleam
/// assert thread_words.short_age(4_920_000) == "1h 22m"
/// assert thread_words.short_age(2_400_000) == "40m"
/// ```
pub fn short_age(wait: Int) -> String {
  let minutes = wait / 60_000

  // Minutes alone below an hour, hours and minutes below a day, then days.
  case wait < 60_000, minutes < 60, wait < 86_400_000 {
    True, _, _ -> "now"
    False, True, _ -> int.to_string(minutes) <> "m"
    False, False, True ->
      int.to_string(minutes / 60)
      <> "h "
      <> string.pad_start(int.to_string(minutes % 60), 2, "0")
      <> "m"
    False, False, False -> int.to_string(wait / 86_400_000) <> "d"
  }
}

/// Whether a wait is long enough to be marked.
///
/// ## Examples
///
/// ```gleam
/// assert thread_words.overdue(3_600_000)
/// assert !thread_words.overdue(3_599_999)
/// ```
pub fn overdue(wait: Int) -> Bool {
  wait >= overdue_after_ms
}

/// How long the turn now running has gone on, as `working, 14 min into a turn`
/// says it. A turn that began less than a minute ago, or whose start is after
/// `now`, is "just started".
///
/// ## Examples
///
/// ```gleam
/// assert thread_words.turn_words(0, 840_000) == "14 min into a turn"
/// assert thread_words.turn_words(0, 10_000) == "a turn that has just started"
/// ```
pub fn turn_words(started: Int, now: Int) -> String {
  let wait = now - started

  // Minutes under an hour, then hours and a day count, as the pane's other ages.
  case wait < 60_000, wait < 3_600_000, wait < 86_400_000 {
    True, _, _ -> "a turn that has just started"
    False, True, _ -> int.to_string(wait / 60_000) <> " min into a turn"
    False, False, True -> int.to_string(wait / 3_600_000) <> " h into a turn"
    False, False, False -> int.to_string(wait / 86_400_000) <> " d into a turn"
  }
}

/// The sort of failure a reason code names.
///
/// ## Examples
///
/// ```gleam
/// assert thread_words.kind_of(Some("rate_limited")) == thread_words.RateLimited
/// assert thread_words.kind_of(Some("provider_error")) == thread_words.Other
/// assert thread_words.kind_of(None) == thread_words.Other
/// ```
pub fn kind_of(reason: Option(String)) -> Failure {
  case reason {
    Some("rate_limited") -> RateLimited
    Some("overloaded") -> Overloaded
    Some("timeout") -> TimedOut
    Some(_) | None -> Other
  }
}

/// The pane's title for a stuck strand.
///
/// ## Examples
///
/// ```gleam
/// assert thread_words.stuck_title(thread_words.RateLimited)
///   == "The last turn failed on a provider rate limit, and nothing has retried."
/// ```
pub fn stuck_title(failure: Failure) -> String {
  case failure {
    RateLimited ->
      "The last turn failed on a provider rate limit, and nothing has retried."
    Overloaded ->
      "The last turn failed because the provider was overloaded, and nothing has retried."
    TimedOut ->
      "The last turn failed because the provider did not answer in time, and nothing has retried."
    Other -> "The last turn failed, and nothing has retried."
  }
}

/// The row's one line for a stuck strand: what stopped it, without a time,
/// since a row's age already says how long ago.
///
/// ## Examples
///
/// ```gleam
/// assert thread_words.stuck_head(thread_words.RateLimited) == "Rate-limited, has not retried"
/// ```
pub fn stuck_head(failure: Failure) -> String {
  case failure {
    RateLimited -> "Rate-limited, has not retried"
    Overloaded -> "Provider overloaded, has not retried"
    TimedOut -> "Provider timed out, has not retried"
    Other -> "Stopped on a failed run"
  }
}

/// The sentence that says what happened and when, then what the provider said
/// about a retry. `failed_at` is the failed response's time and `retry_after_ms`
/// the wait the provider asked for. A time that is not known is left out of the
/// sentence, and a wait that is not known says the provider gave none, which is
/// a statement about the reply and not a guess.
///
/// ## Examples
///
/// ```gleam
/// assert thread_words.stuck_phrase(thread_words.RateLimited, Some(1000), None)
///   == [
///     thread_words.Words("Rate-limited at "),
///     thread_words.Clock(1000),
///     thread_words.Words("; nothing has retried."),
///     thread_words.Words(" The provider gave no reset time."),
///   ]
/// ```
pub fn stuck_phrase(
  failure: Failure,
  failed_at: Option(Int),
  retry_after_ms: Option(Int),
) -> Phrase {
  // The lead words say what failed, by the closed table of reasons.
  let #(lead, place) = case failure {
    RateLimited -> #("Rate-limited", " at ")
    Overloaded -> #("The provider was overloaded", " at ")
    TimedOut -> #("The provider did not answer in time", " at ")
    Other -> #("The last turn failed", " at ")
  }

  list.flatten([
    case failed_at {
      Some(at) -> [Words(lead <> place), Clock(at)]
      None -> [Words(lead)]
    },
    [Words("; nothing has retried.")],
    retry_phrase(failure, failed_at, retry_after_ms),
  ])
}

/// What the provider said about a retry: the instant it asked to wait until
/// when both are known, the wait alone when the time of failure is not, and
/// that it gave no time otherwise. A reason that is not about the provider
/// says nothing about one.
fn retry_phrase(
  failure: Failure,
  failed_at: Option(Int),
  retry_after_ms: Option(Int),
) -> Phrase {
  case failure, retry_after_ms, failed_at {
    Other, _, _ -> []
    TimedOut, _, _ -> []
    _, None, _ -> [Words(" The provider gave no reset time.")]
    _, Some(wait), Some(at) -> [
      Words(
        " The provider asked for a wait of " <> wait_words(wait) <> ", until ",
      ),
      Clock(at + wait),
      Words("."),
    ]
    _, Some(wait), None -> [
      Words(" The provider asked for a wait of " <> wait_words(wait) <> "."),
    ]
  }
}

/// A wait the provider asked for, in the largest whole unit that is not zero.
fn wait_words(wait: Int) -> String {
  case wait < 60_000, wait < 3_600_000 {
    True, _ -> int.to_string(int.max(1, wait / 1000)) <> " s"
    False, True -> int.to_string(wait / 60_000) <> " min"
    False, False -> int.to_string(wait / 3_600_000) <> " h"
  }
}

/// A token count as the coordinator's card says it: the number itself below a
/// thousand, then thousands as `412k`, then millions with one decimal as `1.2M`,
/// the decimal left out when it is zero.
///
/// ## Examples
///
/// ```gleam
/// assert thread_words.tokens(412_000) == "412k"
/// assert thread_words.tokens(1_200_000) == "1.2M"
/// assert thread_words.tokens(2_000_000) == "2M"
/// ```
pub fn tokens(count: Int) -> String {
  // Below a thousand the number, below a million thousands, then millions.
  case count < 1000, count < 1_000_000 {
    True, _ -> int.to_string(int.max(count, 0))
    False, True -> int.to_string(count / 1000) <> "k"
    False, False -> {
      let tenths = count / 100_000

      // The decimal is left out when it is zero.
      case tenths % 10 {
        0 -> int.to_string(tenths / 10) <> "M"
        tenth ->
          int.to_string(tenths / 10) <> "." <> int.to_string(tenth) <> "M"
      }
    }
  }
}

/// The words for a goal's status, or nothing for a word the page does not know.
///
/// ## Examples
///
/// ```gleam
/// assert thread_words.goal_status("limited") == Some("stopped at its budget")
/// assert thread_words.goal_status("x") == None
/// ```
pub fn goal_status(status: String) -> Option(String) {
  case status {
    "active" -> Some("active")
    "paused" -> Some("paused")
    "limited" -> Some("stopped at its budget")
    "complete" -> Some("complete")
    _ -> None
  }
}

/// What a strand is doing and since when, as one sentence: `working since 14:06`,
/// `idle since 13:40`, `stopped since 13:52`. A strand whose time is not known
/// has the state alone.
///
/// ## Examples
///
/// ```gleam
/// assert thread_words.strand_phrase(session_brief.Idle, None) == [Words("idle")]
/// ```
pub fn strand_phrase(state: session_brief.State, since: Option(Int)) -> Phrase {
  // The state's word is the card's own, one for each state a strand can be in.
  let word = case state {
    session_brief.Working -> "working"
    session_brief.Idle -> "idle"
    session_brief.Stopped -> "stopped"
  }

  // A strand with no time has the state alone.
  case since {
    Some(at) -> [Words(word <> " since "), Clock(at)]
    None -> [Words(word)]
  }
}

/// How many strands are in each state, as the card's one line: `1 working, 1
/// stopped, 2 idle`. A state no strand is in is left out, and no strands say
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// assert thread_words.delegates([]) == ""
/// ```
pub fn delegates(strands: List(session_brief.Strand)) -> String {
  let count = fn(state) {
    list.count(strands, fn(strand) { strand.state == state })
  }

  [
    #(count(session_brief.Working), "working"),
    #(count(session_brief.Stopped), "stopped"),
    #(count(session_brief.Idle), "idle"),
  ]
  |> list.filter(fn(entry) { entry.0 > 0 })
  |> list.map(fn(entry) { int.to_string(entry.0) <> " " <> entry.1 })
  |> string.join(", ")
}
