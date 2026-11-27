//// The reads of the Updates cards' briefs (`home.card_briefing`): which sessions
//// are read, how many a tick starts, which first, that the open thread's session
//// is left to its own read, and that opening a thread starts no card read. The
//// daemon allows six brief reads in four seconds for each credential, so the
//// bounds are part of the page's contract (protocol-change/051, the addendum on
//// the Updates cards).

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import lustre/effect
import web_view/home
import web_view/session_brief.{Brief}
import web_view/sessions.{type Entry, Entry, Live, Report}
import web_view/signins

const now = 100_000_000

fn entry(id: String, name: String) -> Entry {
  Entry(
    id:,
    name:,
    workspace: "/src/loom",
    created_at: 100_000,
    residency: Live,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
    standing: sessions.Ordinary,
  )
}

/// The id of the nth working session, which is also its name, so the list's order
/// by name is the order of the ids.
fn id(n: Int) -> String {
  case n < 10 {
    True -> "w0" <> int.to_string(n)
    False -> "w" <> int.to_string(n)
  }
}

/// The numbers one to `count`.
fn numbers(count: Int) -> List(Int) {
  case count < 1 {
    True -> []
    False -> list.append(numbers(count - 1), [count])
  }
}

fn listing(count: Int) -> List(Entry) {
  numbers(count) |> list.map(fn(n) { entry(id(n), id(n)) })
}

fn reports(count: Int) -> List(#(String, sessions.Report)) {
  numbers(count)
  |> list.map(fn(n) {
    #(id(n), Report(sessions.Working, None, [], None, Some(now - n * 1000), 0))
  })
}

fn empty_brief() -> session_brief.Brief {
  Brief(
    assistant: None,
    steps: [],
    strands: [],
    goal: None,
    peers: [],
    command: None,
  )
}

type Calls =
  Subject(#(String, Int))

/// The home page's start with the reads this file drives: the feed rows, the
/// evidence and the brief it records each read of. The clock is read from the
/// subject, so a test sets the time by sending it.
fn start(clock: Subject(Int), calls: Calls, count: Int) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed(listing(count))) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { peek(clock) },
    activity: fn(_, deliver) { deliver(reports(count)) },
    rename: None,
    manage: None,
    thread_send: None,
    attention: Some(
      home.Attention(
        feed: fn(_, deliver) { deliver([]) },
        saved: fn(_, deliver) { deliver([]) },
        record: fn(_session, _id, _deliver) { Nil },
        approvals: fn(_session, deliver) { deliver(Error("none")) },
        review: None,
        review_pause_ms: 0,
        act: None,
        brief: fn(session, since, deliver) {
          process.send(calls, #(session, since))
          deliver(Ok(empty_brief()))
        },
        timeline: fn(_, _, _, _) { Nil },
        span: fn(_, _, _, _, _) { Nil },
      ),
    ),
    create: None,
    folders: None,
    elsewhere: None,
    projects: None,
    profiles: [],
    models: [],
    signins: fn(deliver) { deliver(signins.Listed([])) },
    login: None,
    bookmark: None,
    sign_out: fn(_) { signins.Declined(signins.NotFound) },
    sign_out_all: fn() { signins.Revoked },
    device: None,
    admin: None,
    who: fn(deliver) { deliver(None) },
    rename_self: None,
    passkeys: None,
    visiting: None,
    orchestrators: None,
    executors: [],
    pools: [],
    machine: "box",
    placements: fn(_) { Nil },
  )
}

/// The clock's current time, left in place for the next reader.
fn peek(clock: Subject(Int)) -> Int {
  case process.receive(clock, 0) {
    Ok(time) -> {
      process.send(clock, time)
      time
    }
    Error(Nil) -> now
  }
}

/// Moves the clock: the old time is drained and the new one queued.
fn set_clock(clock: Subject(Int), time: Int) -> Nil {
  case process.receive(clock, 0) {
    Ok(_) -> set_clock(clock, time)
    Error(Nil) -> process.send(clock, time)
  }
}

fn run(model: home.Model, message: home.Msg) -> home.Model {
  let #(model, effects) = home.update(model, message)
  let dispatched = process.new_subject()
  effect.perform(
    effects,
    fn(next) { process.send(dispatched, next) },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  settle(model, dispatched)
}

fn settle(model: home.Model, dispatched: Subject(home.Msg)) -> home.Model {
  case process.receive(dispatched, 0) {
    Ok(next) -> settle(run(model, next), dispatched)
    Error(Nil) -> model
  }
}

fn opened(start: home.Start) -> home.Model {
  run(home.new(start), home.TimerReady(process.new_subject()))
}

/// The reads recorded so far, oldest first.
fn recorded(calls: Calls) -> List(#(String, Int)) {
  case process.receive(calls, 0) {
    Ok(call) -> [call, ..recorded(calls)]
    Error(Nil) -> []
  }
}

fn fresh(count: Int) -> #(home.Model, Subject(Int), Calls) {
  let clock = process.new_subject()
  let calls = process.new_subject()
  process.send(clock, now)

  #(opened(start(clock, calls, count)), clock, calls)
}

fn ids(calls: Calls) -> List(String) {
  recorded(calls) |> list.map(fn(call) { call.0 })
}

// At most two cards are read at once, and never past the first eight of the
// group, however many sessions are working. The first refresh reads the shown
// thread (w01, which is the first by name) and two cards; each timer tick reads the
// next two that are due, a session never read first, so twelve working sessions
// have eight cards read, and the other four are never read.
pub fn a_tick_reads_two_cards_and_never_past_the_limit_test() {
  let #(model, clock, calls) = fresh(12)

  // The shown thread's own read, then the first two cards after it.
  assert ids(calls) == ["w01", "w02", "w03"]

  // Each tick moves the clock on and reads two more.
  set_clock(clock, now + 5000)
  let model = run(model, home.CardTicked)
  assert ids(calls) == ["w04", "w05"]
  set_clock(clock, now + 10_000)
  let model = run(model, home.CardTicked)
  assert ids(calls) == ["w06", "w07"]

  // The eighth session is the last one never read, and the other read is the
  // oldest that is due again (ten seconds old): w01 is the open thread's and is
  // left alone, so w02. Past the limit nothing is read.
  set_clock(clock, now + 15_000)
  let model = run(model, home.CardTicked)
  assert ids(calls) == ["w08", "w02"]

  // The oldest after that are w03 and then w04, which were read five seconds
  // later; w09 to w12 never appear.
  set_clock(clock, now + 20_000)
  let _ = run(model, home.CardTicked)
  assert ids(calls) == ["w03", "w04"]
}

// A card read less than ten seconds old is not read again, so a tick reads only
// what is due. The shown thread's session is the open one and has no card read.
pub fn a_card_read_less_than_ten_seconds_ago_is_not_read_again_test() {
  let #(model, clock, calls) = fresh(2)
  assert ids(calls) == ["w01", "w02"]

  set_clock(clock, now + 5000)
  let model = run(model, home.CardTicked)
  assert ids(calls) == []

  set_clock(clock, now + 10_000)
  let _ = run(model, home.CardTicked)
  assert ids(calls) == ["w02"]
}

// Opening a thread reads that thread and starts no card read, and the open
// thread's session is left out of the cards' reads while it is open.
pub fn opening_a_thread_starts_no_card_read_and_the_open_session_is_skipped_test() {
  let #(model, clock, calls) = fresh(3)
  assert ids(calls) == ["w01", "w02", "w03"]

  // Opening w03 after the debounce reads w03's brief once, and no card.
  set_clock(clock, now + 2000)
  let model = run(model, home.InboxOpened("w03"))
  assert ids(calls) == ["w03"]

  // A tick well after skips w03, which has its own read, and reads the others.
  set_clock(clock, now + 12_000)
  let _ = run(model, home.CardTicked)
  assert ids(calls) == ["w01", "w02"]
}

// A session that leaves Updates is dropped from what the page holds.
pub fn a_session_that_leaves_updates_is_forgotten_test() {
  let #(model, clock, _) = fresh(2)
  let model = run(model, home.CardToggled("w01"))
  assert list.length(home.open_cards(model)) == 1

  // The page shows w02, so the thread w01 was has no kept report to stand in.
  let model = run(model, home.InboxOpened("w02"))

  // A page whose activity read now holds one session less drops its open card.
  let _ = clock
  let model =
    run(
      model,
      home.Observed([
        #("w02", Report(sessions.Working, None, [], None, Some(now), 0)),
      ]),
    )
  let model = run(model, home.CardTicked)
  assert home.open_cards(model) == []
}
