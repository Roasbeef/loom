//// When to poll, what to poll with, and what a poll's answer means for the
//// engine: the project actor's side of a source, as plain functions.
////
//// The actor owns the ledger and the engine's state, and it must stay quick,
//// so it never calls GitHub itself. It asks this module whether a poll is due,
//// builds the poll's request from the engine's state, runs `client/project_poller`
//// in a task, and takes the answer back as a message. Everything that can be
//// decided without the ledger is decided here, so it can be tested without a
//// process:
////
//// - **Schedule.** A poll is due when its time has come and none is running.
////   A poll that never answers (its task was killed at the deadline) stops
////   counting as running after `stall_ms`, so one lost answer cannot end
////   polling for good. After a pass the next one waits `interval_s`, or until
////   the time a rate limit named, or, after failures, the interval doubled for
////   each one up to an hour.
//// - **Request.** The pull requests to read and the generation of a trigger on
////   each of them come from the engine's tickets, so what the project opened is
////   known to the source without the source keeping a table of its own.
//// - **Answer.** Of the triggers a pass returns, only those the engine has not
////   seen are new. A re-read of the same page therefore changes nothing.

import client/project_github.{type Arrival}
import client/project_poller.{
  type Conclusion, type Polled, type Request, type Watched, Broken, Healthy,
  Limited,
}
import client/project_sources.{type Github}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/model
import project/state.{type State}

/// How long a poll may run before it is given up on and the next may begin,
/// in milliseconds. It exceeds the task's own deadline.
pub const stall_ms = 420_000

/// The longest a run of failures defers the next pass, in milliseconds.
pub const longest_backoff_ms = 3_600_000

/// Whether a poll is in flight.
pub type Phase {
  /// None is.
  Idle

  /// One began at this system time.
  Running(
    /// When it began.
    since_ms: Int,
  )
}

/// The poller's bookkeeping. It is rebuilt empty at every start, so the first
/// poll after a restart is due at once; the read positions that matter are in
/// the ledger.
pub type Watcher {
  Watcher(
    /// Whether a poll is in flight.
    phase: Phase,
    /// The earliest system time of the next poll.
    due_ms: Int,
    /// Passes in a row that read nothing.
    failures: Int,
    /// The agent's login once GitHub has said it.
    account: Option(String),
    /// The last note the actor recorded, so an unchanged one is not written
    /// again.
    note: String,
    /// When the last pass finished, or 0.
    last_ms: Int,
  )
}

/// A watcher that polls at once.
///
/// ## Examples
///
/// ```gleam
/// assert project_watcher.is_due(project_watcher.new(), 0)
/// ```
pub fn new() -> Watcher {
  Watcher(
    phase: Idle,
    due_ms: 0,
    failures: 0,
    account: None,
    note: "",
    last_ms: 0,
  )
}

/// Whether a poll should begin now.
///
/// ## Examples
///
/// ```gleam
/// let running = project_watcher.begun(project_watcher.new(), 10)
/// assert !project_watcher.is_due(running, 11)
/// ```
pub fn is_due(watcher: Watcher, now_ms: Int) -> Bool {
  case watcher.phase {
    Idle -> now_ms >= watcher.due_ms
    Running(since_ms:) -> now_ms - since_ms > stall_ms
  }
}

/// A poll began.
pub fn begun(watcher: Watcher, now_ms: Int) -> Watcher {
  Watcher(..watcher, phase: Running(now_ms))
}

/// A pass finished, and the time the next may begin follows from how it ended.
///
/// ## Examples
///
/// ```gleam
/// let polled = project_poller.Polled([], [], [], "bot", [], project_poller.Limited(9000))
/// let next = project_watcher.settled(project_watcher.new(), polled, 100, 60)
/// assert next.due_ms == 9000
/// ```
pub fn settled(
  watcher: Watcher,
  polled: Polled,
  now_ms: Int,
  interval_s: Int,
) -> Watcher {
  let interval_ms = interval_s * 1000
  let account = case polled.account {
    "" -> watcher.account
    found -> Some(found)
  }
  let #(failures, due_ms) = case polled.health {
    Healthy -> #(0, now_ms + interval_ms)
    Limited(until_ms) -> #(0, int.max(until_ms, now_ms + 1000))
    Broken(_) -> #(
      watcher.failures + 1,
      now_ms + backoff_ms(interval_ms, watcher.failures),
    )
  }
  Watcher(..watcher, phase: Idle, due_ms:, failures:, account:, last_ms: now_ms)
}

/// The wait after `failures` failed passes already: the interval doubled for
/// each, up to `longest_backoff_ms`.
///
/// ## Examples
///
/// ```gleam
/// assert project_watcher.backoff_ms(60_000, 0) == 60_000
/// assert project_watcher.backoff_ms(60_000, 2) == 240_000
/// assert project_watcher.backoff_ms(60_000, 20) == 3_600_000
/// ```
pub fn backoff_ms(interval_ms: Int, failures: Int) -> Int {
  let doublings = int.min(failures, 10)
  int.min(
    interval_ms * int.bitwise_shift_left(1, doublings),
    longest_backoff_ms,
  )
}

// --- the request --------------------------------------------------------------

/// What a pass needs from the engine and the ledger.
pub fn request(
  run: project_poller.Runner,
  repository: project_poller.Repository,
  github: Github,
  rules: List(project_sources.Rule),
  engine: State,
  cursors: Dict(String, String),
  watcher: Watcher,
  now_ms: Int,
) -> Request {
  project_poller.Request(
    run:,
    repository:,
    account: option.or(github.account, watcher.account),
    allow: github.allow,
    bots: github.bots,
    rules:,
    generations: generations(engine),
    cursors:,
    watched: watched(engine),
    now_ms:,
  )
}

/// The ledger keys of every cursor a pass reads, for the actor to look up.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(project_watcher.cursor_keys(state), "github:issues")
/// ```
pub fn cursor_keys(engine: State) -> List(String) {
  project_poller.cursor_keys(watched(engine))
}

/// The open tickets with a pull request, which the pass reads.
///
/// ## Examples
///
/// ```gleam
/// assert project_watcher.watched(state.start(config)) == []
/// ```
pub fn watched(engine: State) -> List(Watched) {
  state.tickets_oldest_first(engine)
  |> list.filter_map(fn(ticket) {
    case ticket.outcome, ticket.pull_request {
      None, Some(reference) ->
        pull_number(reference)
        |> result.map(fn(number) {
          project_poller.Watched(ticket.id.value, number)
        })
      Some(_), _ | None, None -> Error(Nil)
    }
  })
}

/// The number of a pull request the host opened, from its URL.
fn pull_number(reference: model.PullRequestRef) -> Result(Int, Nil) {
  case model.pull_request_thread(reference) {
    Some(model.ThreadId(thread)) -> int.parse(string.drop_start(thread, 3))
    None -> Error(Nil)
  }
}

/// For each thread a ticket's pull request opened, the generation a trigger
/// on it carries: one more than the trigger that began the ticket. A failure
/// on the project's own pull request is therefore a hop further from the
/// person who started the chain, and the gate stops inferring work past a
/// small number of hops. An ended ticket's pull request counts too, because a
/// comment on a merged pull request still descends from the project's output.
///
/// ## Examples
///
/// ```gleam
/// assert project_watcher.generations(state.start(config)) == dict.new()
/// ```
pub fn generations(engine: State) -> Dict(String, Int) {
  state.tickets_oldest_first(engine)
  |> list.filter_map(fn(ticket) {
    use reference <- result.try(option.to_result(ticket.pull_request, Nil))
    use model.ThreadId(thread) <- result.try(option.to_result(
      model.pull_request_thread(reference),
      Nil,
    ))
    let origin = dict.get(engine.triggers, ticket.origin)
    let base = case origin {
      Ok(stored) -> stored.trigger.generation
      Error(Nil) -> 0
    }
    Ok(#(thread, base + 1))
  })
  |> dict.from_list
}

// --- the answer ---------------------------------------------------------------

/// The pass's triggers the engine has not seen. Reading a page twice, across a
/// restart or after a lost cursor write, therefore changes nothing.
///
/// ## Examples
///
/// ```gleam
/// assert project_watcher.fresh(state.start(config), []) == []
/// ```
pub fn fresh(engine: State, arrivals: List(Arrival)) -> List(Arrival) {
  list.filter(arrivals, fn(arrival) {
    !dict.has_key(engine.triggers, arrival.trigger.id)
  })
}

/// The pass's conclusions for tickets that are still open. A ticket the
/// engine has already ended, or never knew, is left out.
///
/// ## Examples
///
/// ```gleam
/// assert project_watcher.open_conclusions(state.start(config), []) == []
/// ```
pub fn open_conclusions(
  engine: State,
  conclusions: List(Conclusion),
) -> List(Conclusion) {
  list.filter(conclusions, fn(each) {
    case state.ticket(engine, model.TicketId(each.ticket)) {
      Ok(found) -> found.outcome == None
      Error(_) -> False
    }
  })
}

/// What a pass leaves for a person to read, or an empty string when it ran
/// clean. A rate limit says when polling resumes. The text is capped, because
/// it carries GitHub's words.
///
/// ## Examples
///
/// ```gleam
/// let clean = project_poller.Polled([], [], [], "bot", [], project_poller.Healthy)
/// assert project_watcher.note_text(clean) == ""
/// ```
pub fn note_text(polled: Polled) -> String {
  let health = case polled.health {
    Healthy -> []
    Limited(until_ms) -> [
      "rate limited until " <> project_poller.iso_from_ms(until_ms),
    ]
    Broken(reason) -> [reason]
  }
  let all = list.append(health, polled.notes)
  string.join(list.unique(all), "; ")
  |> string.to_utf_codepoints
  |> list.take(400)
  |> string.from_utf_codepoints
}
