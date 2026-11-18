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

  let stuck = index_of(html, "Stuck · sub:main/audit")
  let ask = index_of(html, "Ask · main")
  assert stuck > 0 && stuck < ask
  assert string.contains(html, "stuck since at least 10 min ago")
  assert string.contains(html, "waiting 5 min")
  assert string.contains(html, "Finds<span class=\"inbox-count\">1</span>")
  assert string.contains(html, "noticed 6 min ago")
  assert string.contains(
    html,
    "2 need you · 1 find · 2 running sessions read live, 0 saved from the catalogue",
  )
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
  assert !string.contains(html, "<b>")
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

  assert string.contains(html, "Ask · main")
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
  assert string.contains(
    html,
    "2 need you · 2 finds · 0 running sessions read live, 1 saved from the catalogue",
  )
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
