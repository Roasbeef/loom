//// The data the final inbox mockup draws, as the home page draws it from the
//// reads it holds: an approval's age, its policy rows and the peer messages
//// that reached it, an update's latest message and steps, an ask's coordinator
//// card, a stuck strand's failure, and the reads of a session's brief, which are
//// made for the open thread only (protocol-change/120, 124 and 125).

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element
import web_view/approval_evidence
import web_view/attention_feed.{Ask, Row, Section, Stuck}
import web_view/attention_rule
import web_view/home
import web_view/session_brief.{Brief}
import web_view/sessions.{type Entry, Entry, Live, Report}
import web_view/signins
import web_view/view/brief_view

const now = 100_000_000

const raised = 95_080_000

const ask_id = "ask-0123456789"

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
  )
}

fn listing() -> List(Entry) {
  [
    entry("A", "storage/repair"),
    entry("W", "wp-j/lint"),
    entry("B", "coord/web-inbox"),
    entry("S", "sub:mockup-b"),
  ]
}

fn reports() -> List(#(String, sessions.Report)) {
  [
    #("A", Report(sessions.NeedsYou, None, [], None, None)),
    #("W", Report(sessions.Working, None, [], None, Some(now - 840_000))),
    #(
      "B",
      Report(sessions.Idle, Some("Waiting."), [], Some(now - 60_000), None),
    ),
    #("S", Report(sessions.Idle, Some("Stopped."), [], None, None)),
  ]
}

fn feed_rows(reason: Option(String)) -> List(#(String, attention_feed.Row)) {
  [
    #(
      "B",
      Row(
        waiting_since: Some(now - 2_400_000),
        asks: Section(count: 1, items: [
          Ask(
            id: ask_id,
            strand: "main",
            created_at: now - 2_400_000,
            head: "Fold closed items?",
            questions: 1,
          ),
        ]),
        finds: Section(count: 0, items: []),
        stuck: Section(count: 0, items: []),
      ),
    ),
    #(
      "S",
      Row(
        waiting_since: None,
        asks: Section(count: 0, items: []),
        finds: Section(count: 0, items: []),
        stuck: Section(count: 1, items: [
          Stuck(
            strand: "sub:mockup-b",
            failed_at: Some(now - 1_680_000),
            reason:,
            retry_after_ms: None,
            parent: Some("coord/web-inbox"),
          ),
        ]),
      ),
    ),
  ]
}

fn item(
  raised_at: Option(Int),
  network: Option(approval_evidence.Network),
  policy: Option(approval_evidence.Policy),
) -> approval_evidence.Evidence {
  approval_evidence.Evidence(count: 1, items: [
    approval_evidence.Item(
      id: "esc-1",
      revision: 3,
      tool: "code_mode",
      preview: Some("sqlite3 store.db 'PRAGMA integrity_check'"),
      source: "policy",
      reason: "the program wants a write grant",
      wanted: [
        approval_evidence.Wanted(kind: "writable_root", detail: "~/.loom"),
      ],
      asked: 1,
      raised_at:,
      network:,
      policy:,
    ),
  ])
}

fn full_evidence() -> approval_evidence.Evidence {
  item(
    Some(raised),
    Some(approval_evidence.NetworkOff),
    Some(approval_evidence.Policy(sandbox: "workspace-write", network: "off")),
  )
}

fn the_brief() -> session_brief.Brief {
  Brief(
    assistant: Some(session_brief.Assistant(
      text: session_brief.untrusted("List renders; <i>fold</i> test waits."),
      at: now - 300_000,
    )),
    steps: [
      session_brief.Step(
        at: now - 700_000,
        tool: session_brief.untrusted("fs_edit"),
        words: session_brief.untrusted("inbox.gleam +84"),
        outcome: session_brief.Succeeded,
      ),
      session_brief.Step(
        at: now - 600_000,
        tool: session_brief.untrusted("bash"),
        words: session_brief.untrusted("make check exit 2"),
        outcome: session_brief.Failed,
      ),
    ],
    strands: [
      session_brief.Strand(
        "sub:fact-sheet",
        session_brief.Idle,
        Some(now - 9_000_000),
      ),
      session_brief.Strand(
        "sub:mockup-a",
        session_brief.Working,
        Some(now - 840_000),
      ),
      session_brief.Strand(
        "sub:mockup-b",
        session_brief.Stopped,
        Some(now - 1_680_000),
      ),
    ],
    goal: Some(session_brief.Goal(
      objective: "Ship the attention inbox",
      status: "active",
      tokens_used: 412_000,
      token_budget: 1_200_000,
    )),
    peers: [
      session_brief.Peer(
        session: "B",
        strand: "main",
        at: now - 4_000_000,
        text: session_brief.untrusted("Does the check need <b>the grant</b>?"),
      ),
    ],
    command: None,
  )
}

type Calls =
  Subject(#(String, Int))

/// The home page's start with the reads this file drives: the feed rows, the
/// evidence and the brief it records each read of. The clock is read from the
/// subject, so a test sets the time by sending it.
fn start(
  clock: Subject(Int),
  calls: Calls,
  evidence: approval_evidence.Evidence,
  reason: Option(String),
) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed(listing())) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { peek(clock) },
    activity: fn(_, deliver) { deliver(reports()) },
    rename: None,
    manage: None,
    thread_send: None,
    attention: Some(
      home.Attention(
        feed: fn(_, deliver) { deliver(feed_rows(reason)) },
        saved: fn(_, deliver) { deliver([]) },
        record: fn(_session, _id, _deliver) { Nil },
        approvals: fn(_session, deliver) { deliver(Ok(evidence)) },
        review: None,
        review_pause_ms: 0,
        act: None,
        brief: fn(session, since, deliver) {
          process.send(calls, #(session, since))
          deliver(Ok(the_brief()))
        },
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

fn drawn(model: home.Model) -> String {
  element.to_string(home.view(model))
}

/// The reads recorded so far, oldest first.
fn recorded(calls: Calls) -> List(#(String, Int)) {
  case process.receive(calls, 0) {
    Ok(call) -> [call, ..recorded(calls)]
    Error(Nil) -> []
  }
}

fn fresh(
  evidence: approval_evidence.Evidence,
  reason: Option(String),
) -> #(home.Model, Subject(Int), Calls) {
  let clock = process.new_subject()
  let calls = process.new_subject()
  process.send(clock, now)

  #(opened(start(clock, calls, evidence, reason)), clock, calls)
}

pub fn an_approval_is_dated_by_its_raise_time_test() {
  let #(model, _, _) = fresh(full_evidence(), None)
  let html = drawn(run(model, home.InboxOpened("A")))

  // The row's age is the short form and marked as a long wait, and the
  // eyebrow dates the wait with a clock the browser words in its own zone.
  assert string.contains(html, "1h 22m")
  assert string.contains(html, "inbox-age-overdue")
  assert string.contains(html, "waiting since ")
  assert string.contains(html, "<loom-time at=\"95080000\"")
  assert !string.contains(html, "The record carries no time")
}

pub fn an_approval_without_a_time_draws_no_age_and_says_so_test() {
  let #(model, _, _) = fresh(item(None, None, None), None)
  let html = drawn(run(model, home.InboxOpened("A")))

  assert !string.contains(html, "waiting since")
  assert !string.contains(html, "inbox-age-overdue")
  assert string.contains(
    html,
    "The record carries no time, so no age is shown.",
  )
}

pub fn an_approvals_policy_rows_are_the_daemons_words_test() {
  let #(model, _, _) = fresh(full_evidence(), None)
  let html = drawn(run(model, home.InboxOpened("A")))

  assert string.contains(html, "Policy today")
  assert string.contains(html, "workspace-write · network off")
  assert string.contains(html, ">Network<")
  assert string.contains(html, ">off<")
}

pub fn a_word_the_daemon_left_out_is_not_drawn_test() {
  let #(model, _, _) = fresh(item(Some(raised), None, None), None)
  let html = drawn(run(model, home.InboxOpened("A")))

  // No network word and no policy: neither row, and the page words none.
  assert !string.contains(html, "Policy today")
  assert !string.contains(html, ">Network<")
  assert !string.contains(html, ">off<")
}

pub fn peer_messages_since_the_ask_are_untrusted_text_test() {
  let #(model, _, calls) = fresh(full_evidence(), None)
  let html = drawn(run(model, home.InboxOpened("A")))

  assert string.contains(html, "In this session since it asked")
  assert string.contains(html, "Peer message")
  assert string.contains(html, "untrusted text")
  assert string.contains(
    html,
    "Does the check need &lt;b&gt;the grant&lt;/b&gt;?",
  )
  assert !string.contains(html, "<b>the grant</b>")

  // The read asked for the messages after the approval was raised.
  assert list.contains(recorded(calls), #("A", raised))
}

pub fn an_update_draws_the_latest_message_and_the_last_steps_test() {
  let #(model, _, _) = fresh(full_evidence(), None)
  let html = drawn(run(model, home.InboxOpened("W")))

  assert string.contains(html, "working, 14 min into a turn")
  assert string.contains(html, "The agent&#39;s latest message, untrusted text")
  assert string.contains(
    html,
    "List renders; &lt;i&gt;fold&lt;/i&gt; test waits.",
  )
  assert string.contains(html, "Last few steps")
  assert string.contains(html, "brief-ok")
  assert string.contains(html, "brief-bad")
  assert string.contains(html, "make check exit 2")
  assert string.contains(html, "Watch it live ›")
  assert !string.contains(html, "What its strands are doing")
}

pub fn an_ask_draws_the_coordinator_and_where_it_stopped_test() {
  let #(model, _, _) = fresh(full_evidence(), None)
  let key = attention_rule.Key(attention_rule.AskSort, "B", ask_id)
  let html = drawn(run(model, home.ItemPicked(key)))

  assert string.contains(html, "The coordinator")
  assert string.contains(html, "Ship the attention inbox")
  assert string.contains(html, "412k of 1.2M")
  assert string.contains(html, "1 working, 1 stopped, 1 idle")
  assert string.contains(html, "sub:mockup-a")
  assert string.contains(html, "Where it stopped")
  assert !string.contains(html, "phase")
}

pub fn a_session_with_only_its_own_strand_has_no_coordinator_test() {
  let lone =
    Brief(..the_brief(), goal: None, strands: [
      session_brief.Strand("main", session_brief.Working, Some(now)),
    ])

  // No goal and no delegate: nothing to draw.
  assert element.to_string(brief_view.coordinator(lone)) == ""

  // A goal alone is a card of the goal and the tokens, with no delegate lines.
  let with_goal = Brief(..lone, goal: the_brief().goal)
  let html = element.to_string(brief_view.coordinator(with_goal))
  assert string.contains(html, "Ship the attention inbox")
  assert !string.contains(html, "brief-strands")
}

pub fn a_stuck_strand_is_worded_by_its_reason_code_test() {
  let #(model, _, _) = fresh(full_evidence(), Some("rate_limited"))
  let key = attention_rule.Key(attention_rule.StuckSort, "S", "sub:mockup-b")
  let html = drawn(run(model, home.ItemPicked(key)))

  assert string.contains(html, "The last turn failed on a provider rate limit")
  assert string.contains(html, "Rate-limited at ")
  assert string.contains(html, "The provider gave no reset time.")
  assert string.contains(html, "<loom-time at=\"98320000\"")
  assert string.contains(html, "coord/web-inbox")

  // The row says what stopped without a time, since its age says how long ago.
  assert string.contains(html, "Rate-limited, has not retried")
}

pub fn a_code_that_is_not_in_the_table_gets_the_generic_words_test() {
  let #(model, _, _) = fresh(full_evidence(), Some("provider_error"))
  let key = attention_rule.Key(attention_rule.StuckSort, "S", "sub:mockup-b")
  let html = drawn(run(model, home.ItemPicked(key)))

  assert string.contains(html, "The last turn failed, and nothing has retried.")
  assert !string.contains(html, "rate limit")
}

pub fn only_the_open_thread_is_read_and_a_refresh_waits_fifteen_seconds_test() {
  let #(model, clock, calls) = fresh(full_evidence(), None)
  let _ = recorded(calls)
  let model = run(model, home.InboxOpened("W"))

  // Opening the working thread reads its brief once, and no other session's.
  assert recorded(calls) == [#("W", 0)]

  // A refresh a few seconds later does not read it again.
  set_clock(clock, now + 5000)
  let model = run(model, home.Ticked)
  assert recorded(calls) == []

  // One after fifteen seconds does.
  set_clock(clock, now + 16_000)
  let _ = run(model, home.Ticked)
  assert recorded(calls) == [#("W", 0)]
}

pub fn pressing_the_open_row_again_reads_once_test() {
  let #(model, _, calls) = fresh(full_evidence(), None)
  let _ = recorded(calls)
  let model = run(model, home.InboxOpened("W"))
  let _ = run(model, home.InboxOpened("W"))

  assert recorded(calls) == [#("W", 0)]
}

pub fn an_asks_session_is_read_when_the_ask_is_open_test() {
  let #(model, _, calls) = fresh(full_evidence(), None)
  let _ = recorded(calls)
  let key = attention_rule.Key(attention_rule.AskSort, "B", ask_id)
  let _ = run(model, home.ItemPicked(key))

  assert list.contains(recorded(calls), #("B", 0))
}

pub fn a_stuck_strand_reads_no_brief_test() {
  let #(model, _, calls) = fresh(full_evidence(), Some("rate_limited"))
  let _ = recorded(calls)
  let key = attention_rule.Key(attention_rule.StuckSort, "S", "sub:mockup-b")
  let _ = run(model, home.ItemPicked(key))

  assert !list.any(recorded(calls), fn(call) { call.0 == "S" })
}

pub fn the_default_thread_of_an_approval_waits_for_its_evidence_test() {
  let clock = process.new_subject()
  let calls = process.new_subject()
  process.send(clock, now)

  // The first thread is the approval's, and its brief is read after the
  // evidence, with the raise time the evidence gave.
  let _ = opened(start(clock, calls, full_evidence(), None))
  let made = recorded(calls)

  assert list.contains(made, #("A", raised))
  assert !list.contains(made, #("A", 0))
}
