//// The attention inbox's threads as a page draws and drives them
//// (`web_view/view/attention_thread`, wired in `web_view/home`): asks as
//// threads with a fixed component for each answer kind, finds with a close,
//// the stuck strand with Retry, the counts of saved sessions, and the observer
//// who sees all of it and can send none of it (protocol-change/120).

import core/attention
import core/clock
import core/ids
import core/json.{type JsonValue}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element
import session_view/operator
import web_view/approval_evidence
import web_view/attention_feed.{Ask, Find, Row, Section, Stuck}
import web_view/attention_rule
import web_view/home
import web_view/item_pane
import web_view/saved_attention
import web_view/sessions.{type Entry, Entry, Live, Report}
import web_view/signins
import web_view/thread_send

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: element.Element(message)) -> List(String)

const now = 7_400_000

const ask_id = "ask-0123456789"

const find_id = "find-0123456789"

const strand = "sub:main/audit"

fn entry(id: String, name: String, residency: sessions.Residency) -> Entry {
  Entry(
    id:,
    name:,
    workspace: "/src/loom",
    created_at: 100_000,
    residency:,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

fn reports() -> List(#(String, sessions.Report)) {
  [
    #("A", Report(sessions.Idle, Some("Done."), [])),
    #("B", Report(sessions.Idle, None, [])),
  ]
}

fn feed_rows() -> List(#(String, attention_feed.Row)) {
  [
    #(
      "A",
      Row(
        waiting_since: Some(7_100_000),
        asks: Section(count: 1, items: [
          Ask(
            id: ask_id,
            strand: "main",
            created_at: 7_100_000,
            head: "<b>Which</b> branch?",
            questions: 2,
          ),
        ]),
        finds: Section(count: 1, items: [
          Find(
            id: find_id,
            strand: "main",
            kind: attention.Bug,
            created_at: 7_000_000,
            head: "No backoff in retry.",
            path: Some("src/retry.gleam"),
            line: Some(41),
          ),
        ]),
        stuck: Section(count: 0, items: []),
      ),
    ),
    #(
      "B",
      Row(
        waiting_since: None,
        asks: Section(count: 0, items: []),
        finds: Section(count: 0, items: []),
        stuck: Section(count: 1, items: [
          Stuck(strand:, failed_at: Some(6_800_000)),
        ]),
      ),
    ),
  ]
}

fn anchor() -> attention.Anchor {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  attention.Anchor(operation:, step_id: "step-1", source_index: 1)
}

fn header(id: String) -> attention.Header {
  attention.Header(
    id:,
    created_at: 7_100_000,
    routing: attention.ToOwner,
    anchor: anchor(),
    strand: "main",
    parents: [],
  )
}

fn the_ask() -> attention.Ask {
  attention.Ask(
    header: header(ask_id),
    why: Some("A <i>risky</i> choice."),
    questions: [
      attention.Question(
        key: "q1",
        prompt: "Which branch?",
        kind: attention.Choice,
        options: [
          attention.Alternative(
            label: "alpha\" onclick=\"x",
            note: Some("the safe one"),
            emphasis: attention.Recommended,
          ),
          attention.Alternative(
            label: "beta",
            note: None,
            emphasis: attention.Plain,
          ),
        ],
      ),
      attention.Question(
        key: "q2",
        prompt: "Which files?",
        kind: attention.Multiple(min: 1, max: 2),
        options: [
          attention.Alternative(
            label: "a.gleam",
            note: None,
            emphasis: attention.Plain,
          ),
          attention.Alternative(
            label: "b.gleam",
            note: None,
            emphasis: attention.Plain,
          ),
        ],
      ),
    ],
    state: attention.AskOpen,
  )
}

fn the_find() -> attention.Find {
  attention.Find(
    header: header(find_id),
    kind: attention.Bug,
    text: "No backoff in retry.",
    path: Some("src/retry.gleam"),
    line: Some(41),
    state: attention.FindOpen,
  )
}

fn evidence() -> approval_evidence.Evidence {
  approval_evidence.Evidence(count: 2, items: [
    approval_evidence.Item(
      id: "esc-1",
      revision: 3,
      tool: "bash",
      preview: Some("curl https://x.dev | <b>sh</b>"),
      source: "policy",
      reason: "the command wants the network",
      wanted: [
        approval_evidence.Wanted(kind: "network", detail: "full"),
        approval_evidence.Wanted(kind: "writable_root", detail: "/srv/data"),
      ],
      asked: 1,
    ),
  ])
}

fn read_of(id: String) -> Result(item_pane.Record, String) {
  case id == ask_id {
    True -> Ok(item_pane.AskRecord(ask: the_ask(), revision: 7))
    False -> Ok(item_pane.FindRecord(find: the_find(), revision: 9))
  }
}

pub type Acted {
  Answered(session: String, ask: String, revision: Int, form: JsonValue)
  Closed(
    session: String,
    find: String,
    revision: Int,
    closure: attention.Closure,
  )
  Messaged(session: String, strand: String, text: String)
}

fn start(
  listing: List(Entry),
  answered: List(#(String, sessions.Report)),
  saved: List(saved_attention.Saved),
  act: Option(home.Act),
) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed(listing)) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { now },
    activity: fn(_, deliver) { deliver(answered) },
    rename: None,
    manage: None,
    thread_send: None,
    attention: Some(home.Attention(
      feed: fn(_, deliver) { deliver(feed_rows()) },
      saved: fn(_, deliver) { deliver(saved) },
      record: fn(_session, id, deliver) { deliver(read_of(id)) },
      approvals: fn(_session, deliver) { deliver(Ok(evidence())) },
      review: None,
      review_pause_ms: 0,
      act:,
    )),
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

fn listing() -> List(Entry) {
  [entry("A", "web ui", Live), entry("B", "lint", Live)]
}

// An act that records what it was asked to do and answers at once with the
// words it is given.
fn acting(
  asked: Subject(Acted),
  outcome: home.ActOutcome,
  messaged: thread_send.Answer,
) -> home.Act {
  home.Act(
    answer: fn(session, ask, revision, form, deliver) {
      process.send(asked, Answered(session, ask, revision, form))
      deliver(outcome)
    },
    close: fn(session, find, revision, closure, deliver) {
      process.send(asked, Closed(session, find, revision, closure))
      deliver(outcome)
    },
    strand: fn(session, strand, text, _delivery, deliver) {
      process.send(asked, Messaged(session, strand, text))
      deliver(messaged)
    },
  )
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

fn ask_key() -> attention_rule.Key {
  attention_rule.Key(attention_rule.AskSort, "A", ask_id)
}

fn find_key() -> attention_rule.Key {
  attention_rule.Key(attention_rule.FindSort, "A", find_id)
}

fn stuck_key() -> attention_rule.Key {
  attention_rule.Key(attention_rule.StuckSort, "B", strand)
}

fn received(asked: Subject(Acted)) -> List(Acted) {
  case process.receive(asked, 0) {
    Ok(acted) -> [acted, ..received(asked)]
    Error(Nil) -> []
  }
}

fn owner() -> home.Model {
  let asked = process.new_subject()
  opened(start(
    listing(),
    reports(),
    [],
    Some(acting(
      asked,
      home.Succeeded("Answered."),
      thread_send.Delivered(thread_send.Admitted),
    )),
  ))
}

// Threads rank by wait: the stuck strand has waited longest (a bound, worded
// as such), then the ask. The find has its own group, and the headline counts
// what it read.
pub fn needs_you_ranks_by_wait_and_finds_have_their_own_group_test() {
  let html = drawn(owner())

  let stuck = index_of(html, ">Stuck</span>")
  let ask = index_of(html, ">Ask</span>")
  assert stuck > 0 && stuck < ask
  assert string.contains(html, "10m</span>")
  assert string.contains(html, "5m</span>")
  assert string.contains(html, "Finds<span class=\"inbox-count\"> · 1</span>")
  assert string.contains(html, "6m</span>")
  assert string.contains(html, "2 need you</span>")
}

// The ask's pane draws one fixed control for each question's kind. Everything
// the model wrote is a text node: no attribute carries a label, a note or a
// prompt, and a label that tries to break out of an attribute is only text.
pub fn an_asks_questions_are_fixed_controls_and_model_text_is_text_test() {
  let html = drawn(run(owner(), home.ItemPicked(ask_key())))

  // The components, named by key and valued by position.
  assert string.contains(html, "name=\"q1\"")
  assert string.contains(html, "type=\"radio\"")
  assert string.contains(html, "name=\"q2\"")
  assert string.contains(html, "type=\"checkbox\"")
  assert string.contains(html, "name=\"q1-other\"")
  assert string.contains(html, "value=\"0\"")
  assert string.contains(html, "Pick 1 to 2")
  assert string.contains(html, "recommended")
  assert string.contains(html, "the safe one")

  // The model's words are escaped text and never a tag or an attribute.
  assert string.contains(html, "&lt;b&gt;Which&lt;/b&gt; branch?")
  assert string.contains(html, "A &lt;i&gt;risky&lt;/i&gt; choice.")
  assert !string.contains(html, "<b>Which")
  assert !string.contains(html, "<i>")
  assert !string.contains(html, "value=\"alpha")
  assert !string.contains(html, "\" onclick=\"")
}

// Submitting stages the answer into the outbox and sends nothing. Send then
// names the revision the ask was read at, and the daemon's word is shown.
pub fn staging_an_answer_sends_nothing_until_send_test() {
  let asked = process.new_subject()
  let model =
    opened(start(
      listing(),
      reports(),
      [],
      Some(acting(
        asked,
        home.Succeeded("Answered. Delivered to the strand · admitted"),
        thread_send.Delivered(thread_send.Admitted),
      )),
    ))
  let picked = run(model, home.ItemPicked(ask_key()))
  let staged =
    run(picked, home.ItemStaged([#("q1", "1"), #("q2", "0"), #("q2", "1")]))

  // The outbox lists the checked answer, and nothing has been asked of the daemon.
  let html = drawn(staged)
  assert string.contains(html, "Which branch? — beta")
  assert string.contains(html, "Which files? — a.gleam, b.gleam")
  assert received(asked) == []

  // Send answers at the revision that was read, with the wire object.
  let sent = run(staged, home.ItemSent)
  let assert [Answered(session: "A", ask: _, revision: 7, form:)] =
    received(asked)
  let assert json.Object([#("answers", json.Object(answers)), ..]) = form
  assert list.key_find(answers, "q1") == Ok(json.String("beta"))
  assert string.contains(
    drawn(sent),
    "Answered. Delivered to the strand · admitted",
  )
}

// A form the daemon's own rule would refuse is not staged, and the page words
// the refusal beside the ask.
pub fn an_invalid_form_is_refused_in_the_rules_words_test() {
  let picked = run(owner(), home.ItemPicked(ask_key()))
  let html =
    drawn(run(
      picked,
      home.ItemStaged([#("q1", "0"), #("q2", "0"), #("q2", "1"), #("q2", "1")]),
    ))
  assert string.contains(html, "Question 2: a label is chosen twice")

  let none_picked = drawn(run(picked, home.ItemStaged([#("q1", "0")])))
  assert string.contains(none_picked, "Question 2: too few choices")
}

// A refusal of the daemon is shown in its words, the outbox keeps what was
// staged, and a second Send is possible.
pub fn a_refusal_keeps_the_outbox_and_shows_its_words_test() {
  let asked = process.new_subject()
  let model =
    opened(start(
      listing(),
      reports(),
      [],
      Some(acting(
        asked,
        home.Failed("Not sent: that ask was already answered"),
        thread_send.Delivered(thread_send.Admitted),
      )),
    ))
  let staged =
    run(
      run(model, home.ItemPicked(ask_key())),
      home.ItemStaged([#("q1", "1"), #("q2", "0")]),
    )
  let html = drawn(run(staged, home.ItemSent))

  assert string.contains(html, "Not sent: that ask was already answered")
  assert string.contains(html, "Which branch? — beta")
}

// One Send carries an answer and a note: the answer first, then the note to
// the asking strand.
pub fn send_carries_the_answer_then_the_note_test() {
  let asked = process.new_subject()
  let model =
    opened(start(
      listing(),
      reports(),
      [],
      Some(acting(
        asked,
        home.Succeeded("Answered."),
        thread_send.Delivered(thread_send.Admitted),
      )),
    ))
  let staged =
    model
    |> run(home.ItemPicked(ask_key()))
    |> run(home.ItemStaged([#("q1", "0"), #("q2", "1")]))
    |> run(home.ItemNoted("Mind the lockfile."))
  let _ = run(staged, home.ItemSent)

  let assert [
    Answered(session: "A", revision: 7, ..),
    Messaged(session: "A", strand: "main", text: "Mind the lockfile."),
  ] = received(asked)
}

// A message to a strand the session no longer has says so, in the fixed words.
pub fn an_unknown_strand_is_worded_test() {
  let asked = process.new_subject()
  let model =
    opened(start(
      listing(),
      reports(),
      [],
      Some(acting(
        asked,
        home.Succeeded("Answered."),
        thread_send.Refused(thread_send.UnknownStrand),
      )),
    ))
  let html =
    model
    |> run(home.ItemPicked(stuck_key()))
    |> run(home.ItemNoted("hello"))
    |> run(home.ItemSent)
    |> drawn

  assert string.contains(html, "Not sent: that strand no longer exists")
  assert received(asked) == [Messaged(session: "B", strand:, text: "hello")]
}

// A find shows its kind, text and place, and closes at the revision it was
// read at.
pub fn a_find_closes_at_its_revision_test() {
  let asked = process.new_subject()
  let model =
    opened(start(
      listing(),
      reports(),
      [],
      Some(acting(
        asked,
        home.Succeeded("Closed."),
        thread_send.Delivered(thread_send.Admitted),
      )),
    ))
  let picked = run(model, home.ItemPicked(find_key()))
  let html = drawn(picked)
  assert string.contains(html, "The agent noticed (bug), untrusted text")
  assert string.contains(html, "src/retry.gleam:41")

  let _ = run(picked, home.ItemClosed(attention.Filed))
  assert received(asked)
    == [
      Closed(session: "A", find: find_id, revision: 9, closure: attention.Filed),
    ]
}

// Retry prompts the stuck strand itself.
pub fn retry_prompts_the_stuck_strand_test() {
  let asked = process.new_subject()
  let model =
    opened(start(
      listing(),
      reports(),
      [],
      Some(acting(
        asked,
        home.Succeeded("Answered."),
        thread_send.Delivered(thread_send.Admitted),
      )),
    ))
  let retried = run(run(model, home.ItemPicked(stuck_key())), home.ItemRetried)

  let assert [Messaged(session: "B", strand: "sub:main/audit", ..)] =
    received(asked)
  assert string.contains(drawn(retried), "Delivered to the strand · admitted")
}

// An observer's page reads the same threads and the same record and has no
// form, no staging, no outbox and no Send, and its messages are ignored.
pub fn an_observer_reads_and_cannot_stage_or_send_test() {
  let model = opened(start(listing(), reports(), [], None))
  let picked = run(model, home.ItemPicked(ask_key()))
  let html = drawn(picked)

  assert string.contains(html, ">Ask</span>")
  assert string.contains(html, "Which branch?")
  assert string.contains(
    html,
    "Only the owner&#39;s operating page can answer.",
  )
  assert !string.contains(html, "<form")
  assert !string.contains(html, "type=\"radio\"")
  assert !string.contains(html, "Outbox")
  assert !string.contains(html, ">Send<")

  // Messages a forged frame could not have sent are ignored by the model.
  let forced =
    picked
    |> run(home.ItemStaged([#("q1", "0"), #("q2", "0")]))
    |> run(home.ItemNoted("hi"))
    |> run(home.ItemSent)
  assert drawn(forced) == html

  let stuck = drawn(run(model, home.ItemPicked(stuck_key())))
  assert !string.contains(stuck, ">Retry<")
  let found = drawn(run(model, home.ItemPicked(find_key())))
  assert !string.contains(found, ">Fixed<")
}

// After a restart every session is saved, and the catalogue's summary is the
// only source. An approval and an ask still count, the page lands on the
// inbox, and the headline says where the count came from.
pub fn a_restart_with_an_approval_pending_is_counted_test() {
  let saved = [
    saved_attention.Saved(
      session_id: "D",
      pending_approvals: 1,
      open_asks: 1,
      open_finds: 2,
      oldest_open_at: Some(5),
      updated_at: 9,
    ),
  ]
  let html =
    drawn(
      opened(start(
        [
          entry("D", "hex release", sessions.Saved),
          entry("E", "moving", sessions.Moving("other")),
        ],
        [],
        saved,
        None,
      )),
    )

  assert string.contains(html, "<h1>Inbox</h1>")
  assert string.contains(html, "1 need you</span>")
}

// A count the headline states is a row the person can act on: each saved
// session whose summary holds an approval or an ask is a thread under Needs you,
// and one with finds is a thread under Finds, each named as text with its
// counts, its oldest age and one action. The empty-inbox sentence never shows
// beside them, and a saved session with nothing open has no row.
pub fn a_saved_summary_is_a_thread_the_headline_counts_test() {
  let saved = [
    saved_attention.Saved(
      session_id: "D",
      pending_approvals: 1,
      open_asks: 1,
      open_finds: 2,
      oldest_open_at: Some(now - 300_000),
      updated_at: 9,
    ),
    saved_attention.Saved(
      session_id: "F",
      pending_approvals: 0,
      open_asks: 0,
      open_finds: 0,
      oldest_open_at: None,
      updated_at: 9,
    ),
  ]
  let html =
    drawn(
      opened(start(
        [
          entry("D", "hex <b>release</b>", sessions.Saved),
          entry("F", "all clear", sessions.Saved),
        ],
        [],
        saved,
        None,
      )),
    )

  assert string.contains(
    html,
    "Needs you<span class=\"inbox-count\"> · 1</span>",
  )
  assert string.contains(html, "Finds<span class=\"inbox-count\"> · 1</span>")
  assert string.contains(
    html,
    "<span class=\"inbox-name\">hex &lt;b&gt;release&lt;/b&gt;</span>",
  )
  assert string.contains(html, ">Saved</span>")
  assert string.contains(html, "1 approval, 1 ask pending")
  assert string.contains(html, "2 finds open")
  assert string.contains(html, "oldest open 5 min ago")
  assert string.contains(html, "Resume and open ›")
  assert !string.contains(html, "Saved · all clear")
  assert !string.contains(html, "Nothing waits on you")
}

fn saved_summary() -> saved_attention.Saved {
  saved_attention.Saved(
    session_id: "D",
    pending_approvals: 1,
    open_asks: 0,
    open_finds: 0,
    oldest_open_at: None,
    updated_at: 9,
  )
}

// A saved session is not running, so the row's one action resumes it, as the
// sessions table does: the page's open would be refused for it. The press is
// shown as out, a refusal is a line on the row, and an observer has no button.
pub fn a_saved_row_resumes_and_says_what_happened_test() {
  let resumed = process.new_subject()
  let operator =
    home.Start(
      ..start([entry("D", "hex", sessions.Saved)], [], [saved_summary()], None),
      resume: fn(session, _deliver) { process.send(resumed, session) },
    )
  let model = opened(operator)
  assert string.contains(drawn(model), "Resume and open ›")
  assert !string.contains(drawn(model), "Open the session&#39;s page")

  // The press goes to the daemon's resume and shows as out.
  let pressed = run(model, home.Resuming("D"))
  assert process.receive(resumed, 0) == Ok("D")
  assert string.contains(drawn(pressed), "Resuming…")
  assert !string.contains(drawn(pressed), "Resume and open ›")

  // A refusal is drawn on the row in the inbox, and the button is back.
  let refused =
    run(pressed, home.Linked(sessions.Declined(sessions.NotRunning)))
  assert string.contains(
    drawn(refused),
    "That session is not running. Resume it from a terminal",
  )
  assert string.contains(drawn(refused), "Resume and open ›")

  // An observer may not resume, so its row draws no button.
  let observer =
    opened(
      home.Start(
        ..start(
          [entry("D", "hex", sessions.Saved)],
          [],
          [saved_summary()],
          None,
        ),
        ceiling: home.ObserverCeiling,
      ),
    )
  assert string.contains(drawn(observer), "1 approval pending")
  assert !string.contains(drawn(observer), "Resume and open")
}

// Every handler an item thread registers is a click or a submit beneath the
// table's region, which the socket admits already.
pub fn every_handler_is_beneath_the_table_test() {
  let model = run(owner(), home.ItemPicked(ask_key()))
  let keys =
    handlers(home.view(model))
    |> list.filter(string.starts_with(_, home.table_path <> "\t"))

  assert keys != []
  assert list.all(keys, fn(key) {
    string.ends_with(key, "\nclick") || string.ends_with(key, "\nsubmit")
  })
}

fn index_of(html: String, needle: String) -> Int {
  case string.split_once(html, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(Nil) -> -1
  }
}

pub fn unused_directions_stay_pinned_test() {
  assert thread_send.answer_words(
      thread_send.Refused(thread_send.UnknownStrand),
      operator.Prompt,
      "x",
    )
    == "Not sent: that strand no longer exists"
}

// An approval's thread lists the evidence the daemon read: the tool, the action,
// what held it, the network and the other grants, and one line for the
// approvals the reply did not carry. Every word is a text node, no age is
// shown, and the one control still leads to the session's page.
pub fn an_approval_thread_lists_its_evidence_and_still_only_points_away_test() {
  let model =
    opened(start(
      listing(),
      [#("A", Report(sessions.NeedsYou, None, []))],
      [],
      None,
    ))
  let html = drawn(run(model, home.InboxOpened("A")))

  assert string.contains(html, "What it asks for")
  assert string.contains(html, "bash")
  assert string.contains(html, "curl https://x.dev | &lt;b&gt;sh&lt;/b&gt;")
  assert !string.contains(html, "<b>sh</b>")
  assert string.contains(html, "policy: the command wants the network")
  assert string.contains(html, "Network")
  assert string.contains(html, "writable_root /srv/data")
  assert string.contains(html, "1 more pending, decided on the page.")
  assert string.contains(
    html,
    "The record carries no time, so no age is shown.",
  )
  assert string.contains(html, "Decide on the session&#39;s page ›")

  // Nothing here decides: no form, no input and no deciding word.
  assert !string.contains(html, "<form")
  assert !string.contains(html, "Allow")
  assert !string.contains(html, "Deny")
}

// A strand's name is text a session chose. It is drawn in the eyebrow as text
// and appears in no attribute: not the note field's placeholder, not a class or
// a key.
pub fn a_hostile_strand_name_is_in_no_attribute_test() {
  let hostile = "sub:HOSTILE\"><b>x"
  let rows = [
    #(
      "A",
      Row(
        waiting_since: Some(7_100_000),
        asks: Section(count: 1, items: [
          Ask(
            id: ask_id,
            strand: hostile,
            created_at: 7_100_000,
            head: "Which?",
            questions: 1,
          ),
        ]),
        finds: Section(count: 0, items: []),
        stuck: Section(count: 1, items: [
          Stuck(strand: hostile, failed_at: Some(6_800_000)),
        ]),
      ),
    ),
  ]
  let asked = process.new_subject()
  let base =
    start(
      listing(),
      reports(),
      [],
      Some(acting(
        asked,
        home.Succeeded("Answered."),
        thread_send.Delivered(thread_send.Admitted),
      )),
    )
  let model =
    opened(
      home.Start(
        ..base,
        attention: Some(
          home.Attention(
            feed: fn(_, deliver) { deliver(rows) },
            saved: fn(_, deliver) { deliver([]) },
            record: fn(_session, id, deliver) { deliver(read_of(id)) },
            approvals: fn(_session, deliver) { deliver(Ok(evidence())) },
            review: None,
            review_pause_ms: 0,
            act: case base.attention {
              Some(reads) -> reads.act
              None -> None
            },
          ),
        ),
      ),
    )

  list.each(
    [
      attention_rule.Key(attention_rule.StuckSort, "A", hostile),
      attention_rule.Key(attention_rule.AskSort, "A", ask_id),
    ],
    fn(key) {
      let html = drawn(run(model, home.ItemPicked(key)))
      assert string.contains(html, "Message this strand")
      assert occurrences(html, "HOSTILE") > 0
      assert inside_tags(html, "HOSTILE") == 0
    },
  )
}

// How many times a marker appears inside a tag, that is, in an attribute.
fn inside_tags(html: String, marker: String) -> Int {
  let parts = string.split(html, marker)
  let before = list.take(parts, list.length(parts) - 1)

  list.count(before, fn(part) {
    case list.last(string.split(part, ">")) {
      Ok(tail) -> string.contains(tail, "<")
      Error(Nil) -> False
    }
  })
}

fn occurrences(html: String, marker: String) -> Int {
  list.length(string.split(html, marker)) - 1
}

// A note that fails after its answer settled stays staged, and stays in view
// when the answered ask has left the list, so it can be sent again.
pub fn a_note_that_failed_after_a_settled_answer_stays_in_view_test() {
  let asked = process.new_subject()
  let model =
    opened(start(
      listing(),
      reports(),
      [],
      Some(acting(
        asked,
        home.Succeeded("Answered."),
        thread_send.Refused(thread_send.UnknownStrand),
      )),
    ))
  let sent =
    model
    |> run(home.ItemPicked(ask_key()))
    |> run(home.ItemStaged([#("q1", "1"), #("q2", "0")]))
    |> run(home.ItemNoted("Mind the lockfile."))
    |> run(home.ItemSent)

  // The ask has been answered and the next read no longer holds it.
  let html = drawn(run(sent, home.FeedRead([])))
  assert string.contains(html, "Message: Mind the lockfile.")
  assert string.contains(html, "Not sent: that strand no longer exists")
  assert string.contains(html, ">Send<")
}

fn none_waiting() -> saved_attention.Saved {
  saved_attention.Saved(
    session_id: "D",
    pending_approvals: 0,
    open_asks: 0,
    open_finds: 0,
    oldest_open_at: None,
    updated_at: 9,
  )
}

fn approval_waiting() -> saved_attention.Saved {
  saved_attention.Saved(..none_waiting(), pending_approvals: 1, open_asks: 1)
}

// A page that can start a session, so the composer is its centre unless the
// inbox is. The feed answers with nothing open, and `saved` and `activity` are
// what the catalogue's read and the activity read do when they are asked, so a
// test can hold either back and deliver it as a message.
fn composing(
  listing: List(Entry),
  activity: fn(fn(List(#(String, sessions.Report))) -> Nil) -> Nil,
  saved: fn(fn(List(saved_attention.Saved)) -> Nil) -> Nil,
) -> home.Start {
  let base = start(listing, [], [], None)

  home.Start(
    ..base,
    create: Some(fn(_, _, _, _, _, _, _) { Nil }),
    activity: fn(_, deliver) { activity(deliver) },
    attention: Some(home.Attention(
      feed: fn(_, deliver) { deliver([]) },
      saved: fn(_, deliver) { saved(deliver) },
      record: fn(_session, id, deliver) { deliver(read_of(id)) },
      approvals: fn(_session, deliver) { deliver(Ok(evidence())) },
      review: None,
      review_pause_ms: 0,
      act: None,
    )),
  )
}

// A running session that is quiet beside a saved one.
fn quiet_and_saved() -> List(Entry) {
  [
    entry("A", "web ui", Live),
    entry("D", "hex release", sessions.Saved),
  ]
}

fn quiet_report() -> List(#(String, sessions.Report)) {
  [#("A", Report(sessions.Idle, None, []))]
}

// A saved session with nothing pending lands the composer once its summary has
// answered, and a later summary that counts something does not cover it. The
// "Inbox" control is how the person gets to what arrived.
pub fn a_summary_that_counts_nothing_lands_the_composer_test() {
  let model =
    opened(
      composing(
        [entry("D", "hex release", sessions.Saved)],
        fn(_) { Nil },
        fn(deliver) { deliver([none_waiting()]) },
      ),
    )
  let html = drawn(model)
  assert string.contains(html, "<h1>New session</h1>")
  assert !string.contains(html, "<h1>Inbox</h1>")
  assert !string.contains(html, "Back to the inbox")

  let later = drawn(run(model, home.SavedRead([approval_waiting()])))
  assert string.contains(later, "<h1>New session</h1>")
  assert !string.contains(later, "<h1>Inbox</h1>")
  assert string.contains(later, "Back to the inbox")
}

// The activity read answers first and says the one running session is quiet,
// which on its own lands the composer. The saved session's summary has not come,
// so the round is still open, and the summary that does come counts an approval
// pending: the page lands on the inbox, as it does when the summary is first.
pub fn a_quiet_activity_read_does_not_land_the_composer_over_a_summary_test() {
  let model =
    opened(
      composing(
        quiet_and_saved(),
        fn(deliver) { deliver(quiet_report()) },
        fn(_) { Nil },
      ),
    )

  // The round is waiting for the summary: nothing is decided yet.
  assert !string.contains(drawn(model), "<h1>Inbox</h1>")

  let landed = drawn(run(model, home.SavedRead([approval_waiting()])))
  assert string.contains(landed, "<h1>Inbox</h1>")
  assert !string.contains(landed, "<h1>New session</h1>")
}

// The same page with the reads the other way round: the summary counts an
// approval first, and the activity read that follows says quiet. Either order
// lands the inbox.
pub fn the_summary_before_the_activity_read_lands_the_inbox_test() {
  let model =
    opened(
      composing(quiet_and_saved(), fn(_) { Nil }, fn(deliver) {
        deliver([approval_waiting()])
      }),
    )
  assert !string.contains(drawn(model), "<h1>Inbox</h1>")

  let landed = drawn(run(model, home.Observed(quiet_report())))
  assert string.contains(landed, "<h1>Inbox</h1>")
}

// When nothing waits across the reads the round was owed, the composer is
// decided, and no read that comes afterwards covers it: not an ask, a find, an
// approval in a summary, or a session that now works.
pub fn a_decided_composer_is_never_covered_by_a_later_read_test() {
  let model =
    opened(
      composing(
        quiet_and_saved(),
        fn(deliver) { deliver(quiet_report()) },
        fn(deliver) { deliver([none_waiting()]) },
      ),
    )
  assert string.contains(drawn(model), "<h1>New session</h1>")

  let later =
    model
    |> run(home.FeedRead(feed_rows()))
    |> run(home.SavedRead([approval_waiting()]))
    |> run(home.Observed([#("A", Report(sessions.Working, None, []))]))
  let html = drawn(later)

  assert string.contains(html, "<h1>New session</h1>")
  assert !string.contains(html, "<h1>Inbox</h1>")
}

// A composer decided on a page that held nothing waiting still offers the
// inbox as soon as its only content is a saved summary that counts something.
pub fn the_inbox_control_shows_on_a_decided_composer_with_a_summary_test() {
  let model =
    opened(
      composing(
        [entry("D", "hex release", sessions.Saved)],
        fn(_) { Nil },
        fn(deliver) { deliver([none_waiting()]) },
      ),
    )
  let calm = drawn(model)
  assert string.contains(calm, "<h1>New session</h1>")
  assert !string.contains(calm, "Back to the inbox")

  let html = drawn(run(model, home.SavedRead([approval_waiting()])))
  assert string.contains(html, "<h1>New session</h1>")
  assert string.contains(html, "Back to the inbox")
}

// With no saved session in the list no summary is coming, so nothing decides the
// composer but the person: a session saved later, with something pending, does
// not take the page to the inbox over it. The first list is empty and a later
// one holds the saved session, as when another process saves one.
pub fn a_composer_with_no_saved_session_listed_stays_the_persons_test() {
  let later =
    saved_attention.Saved(
      session_id: "D",
      pending_approvals: 1,
      open_asks: 1,
      open_finds: 0,
      oldest_open_at: None,
      updated_at: 9,
    )
  let lists = process.new_subject()
  process.send(lists, [])
  process.send(lists, [entry("D", "hex release", sessions.Saved)])
  let base = start([], [], [later], None)
  let model =
    opened(
      home.Start(..base, sessions: fn(deliver) {
        case process.receive(lists, 0) {
          Ok(entries) -> deliver(home.Listed(entries))
          Error(Nil) ->
            deliver(home.Listed([entry("D", "hex release", sessions.Saved)]))
        }
      }),
    )
  assert !string.contains(drawn(model), "<h1>Inbox</h1>")

  // The next list holds the saved session, its summary is read, and the person's
  // composer is still the person's.
  let refreshed = run(model, home.Ticked)
  assert !string.contains(drawn(refreshed), "<h1>Inbox</h1>")
}

// An activity read whose task crashed delivers nothing, so the round would wait
// on it for ever. The next readable list no longer holds the running session, so
// it releases the read and the round decides, on the composer. A read that comes
// much later must not cover the composer in use: not a summary that now counts
// something, and not an activity read that finally answers.
pub fn a_crashed_read_is_released_by_the_next_list_test() {
  let lists = process.new_subject()
  process.send(lists, quiet_and_saved())
  let base =
    composing(quiet_and_saved(), fn(_) { Nil }, fn(deliver) {
      deliver([none_waiting()])
    })
  let model =
    opened(
      home.Start(..base, sessions: fn(deliver) {
        case process.receive(lists, 0) {
          Ok(entries) -> deliver(home.Listed(entries))
          Error(Nil) ->
            deliver(home.Listed([entry("D", "hex release", sessions.Saved)]))
        }
      }),
    )

  // The crashed read leaves the round open; the next list releases it.
  let ticked = run(model, home.Ticked)
  assert string.contains(drawn(ticked), "<h1>New session</h1>")

  let later =
    ticked
    |> run(home.SavedRead([approval_waiting()]))
    |> run(home.Observed(quiet_report()))
  let html = drawn(later)

  assert string.contains(html, "<h1>New session</h1>")
  assert !string.contains(html, "<h1>Inbox</h1>")
  assert string.contains(html, "Back to the inbox")
}
