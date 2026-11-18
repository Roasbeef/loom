//// The inbox's review pane as a page draws and drives it
//// (`web_view/view/review_thread`, wired in `web_view/home`): the "To review"
//// group, the hunks with a find pinned at its line, the staged verdict, file
//// comments and find actions, the one Send and its receipt, and the observer
//// who is shown no review at all (protocol-change/123, the review addendum to
//// protocol-change/051).

import core/attention
import core/clock
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element
import session_view/diff_view
import web_view/approval_evidence
import web_view/attention_feed.{Find, Row, Section}
import web_view/home
import web_view/item_pane
import web_view/review_feed
import web_view/review_scan_rule as scan
import web_view/review_stage_rule
import web_view/sessions.{type Entry, Entry, Live, Report}
import web_view/signins
import web_view/thread_send
import web_view/view/review_thread

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: element.Element(message)) -> List(String)

const now = 7_400_000

const find_id = "find-0123456789"

const hostile = "src/\"><script>x</script>.gleam"

pub type Acted {
  Closed(
    session: String,
    find: String,
    revision: Int,
    closure: attention.Closure,
  )
  Messaged(session: String, strand: String, text: String)
}

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

fn reports() -> List(#(String, sessions.Report)) {
  [
    #("A", Report(sessions.Idle, Some("Done <b>it</b>."), [])),
    #("B", Report(sessions.Idle, Some("Nothing changed."), [])),
  ]
}

fn feed_rows() -> List(#(String, attention_feed.Row)) {
  [
    #(
      "A",
      Row(
        waiting_since: None,
        asks: Section(count: 0, items: []),
        finds: Section(count: 3, items: [
          Find(
            id: find_id,
            strand: "main",
            kind: attention.Bug,
            created_at: 7_000_000,
            head: "No backoff in <i>retry</i>.",
            path: Some("src/retry.gleam"),
            line: Some(41),
          ),
          Find(
            id: "find-aaaaaaaaaa",
            strand: "main",
            kind: attention.Risk,
            created_at: 7_000_000,
            head: "Loose in its file.",
            path: Some("src/retry.gleam"),
            line: Some(900),
          ),
          Find(
            id: "find-bbbbbbbbbb",
            strand: "main",
            kind: attention.Idea,
            created_at: 7_000_000,
            head: "Names no shown file.",
            path: Some("elsewhere.gleam"),
            line: None,
          ),
        ]),
        stuck: Section(count: 0, items: []),
      ),
    ),
  ]
}

fn line(
  kind: diff_view.Kind,
  new: Option(Int),
  text: String,
) -> diff_view.Line {
  diff_view.Line(kind:, old: None, new:, text:)
}

fn review() -> review_feed.Review {
  review_feed.Review(
    observed_at_ms: now,
    repository: review_feed.Head,
    stat: review_feed.Stat(files: 5, added: 41, removed: 9),
    files: [
      review_feed.File(
        path: "src/retry.gleam",
        change: review_feed.Modified,
        section: review_feed.Source,
        content: review_feed.Text,
        added: 30,
        removed: 9,
        hunks: [
          review_feed.Hunk(
            header: "@@ -40,2 +40,3 @@ pub fn retry(",
            lines: [
              line(diff_view.Context, Some(40), "let wait = base"),
              line(diff_view.Removed, None, "loop(base)"),
              line(diff_view.Added, Some(41), "loop(base * 2)"),
            ],
            omitted: 12,
            shortened: 2,
          ),
        ],
        hunks_omitted: 3,
        extent: review_feed.Cut,
      ),
      review_feed.File(
        path: hostile,
        change: review_feed.Added,
        section: review_feed.Tests,
        content: review_feed.Binary,
        added: 0,
        removed: 0,
        hunks: [],
        hunks_omitted: 0,
        extent: review_feed.Whole,
      ),
    ],
    omitted: 3,
    extent: review_feed.Cut,
  )
}

fn clean() -> review_feed.Review {
  review_feed.Review(
    observed_at_ms: now,
    repository: review_feed.Head,
    stat: review_feed.Stat(files: 0, added: 0, removed: 0),
    files: [],
    omitted: 0,
    extent: review_feed.Whole,
  )
}

fn anchor() -> attention.Anchor {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  attention.Anchor(operation:, step_id: "step-1", source_index: 1)
}

fn the_find() -> attention.Find {
  attention.Find(
    header: attention.Header(
      id: find_id,
      created_at: 7_000_000,
      routing: attention.ToOwner,
      anchor: anchor(),
      strand: "main",
      parents: [],
    ),
    kind: attention.Bug,
    text: "No backoff in retry.",
    path: Some("src/retry.gleam"),
    line: Some(41),
    state: attention.FindOpen,
  )
}

fn start(
  review: Option(
    fn(String, fn(Result(review_feed.Review, String)) -> Nil) -> Nil,
  ),
  act: Option(home.Act),
) -> home.Start {
  start_for([entry("A", "web ui"), entry("B", "lint")], reports(), review, act)
}

fn start_for(
  listed: List(Entry),
  answered: List(#(String, sessions.Report)),
  review: Option(
    fn(String, fn(Result(review_feed.Review, String)) -> Nil) -> Nil,
  ),
  act: Option(home.Act),
) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed(listed)) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { now },
    activity: fn(_, deliver) { deliver(answered) },
    rename: None,
    manage: None,
    thread_send: None,
    attention: Some(home.Attention(
      feed: fn(_, deliver) { deliver(feed_rows()) },
      saved: fn(_, deliver) { deliver([]) },
      record: fn(_session, _id, deliver) {
        deliver(Ok(item_pane.FindRecord(find: the_find(), revision: 9)))
      },
      approvals: fn(_session, deliver) {
        deliver(Ok(approval_evidence.Evidence(count: 0, items: [])))
      },
      review:,
      review_pause_ms: 5,
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

// A reader that answers a review for A and a clean tree for B, and records the
// sessions it was asked about.
fn reader(
  asked: Subject(String),
) -> fn(String, fn(Result(review_feed.Review, String)) -> Nil) -> Nil {
  fn(session, deliver) {
    process.send(asked, session)
    case session {
      "A" -> deliver(Ok(review()))
      _ -> deliver(Ok(clean()))
    }
  }
}

fn acting(
  acted: Subject(Acted),
  close: home.ActOutcome,
  prompt: thread_send.Answer,
) -> home.Act {
  home.Act(
    answer: fn(_, _, _, _, deliver) { deliver(home.Failed("unused")) },
    close: fn(session, find, revision, closure, deliver) {
      process.send(acted, Closed(session, find, revision, closure))
      deliver(close)
    },
    strand: fn(session, strand, text, _delivery, deliver) {
      process.send(acted, Messaged(session, strand, text))
      deliver(prompt)
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

fn received(acted: Subject(Acted)) -> List(Acted) {
  case process.receive(acted, 0) {
    Ok(each) -> [each, ..received(acted)]
    Error(Nil) -> []
  }
}

// An operator's page, with the owner's controls: the inbox is opened on the
// session that is "To review".
fn owner(acted: Subject(Acted), close: home.ActOutcome) -> home.Model {
  let asked = process.new_subject()
  let model =
    opened(start(
      Some(reader(asked)),
      Some(acting(acted, close, thread_send.Delivered(thread_send.Queued))),
    ))

  // The scan reads one session for each list read, so a few more reads settle
  // both idle sessions.
  run(model, home.InboxOpened("A"))
}

fn scanned(model: home.Model) -> home.Model {
  model
  |> run(home.Answered(
    1,
    home.Listed([entry("A", "web ui"), entry("B", "lint")]),
  ))
  |> run(home.InboxOpened("A"))
}

fn settled_owner(acted: Subject(Acted), close: home.ActOutcome) -> home.Model {
  scanned(scanned(owner(acted, close)))
}

fn index_of(html: String, needle: String) -> Int {
  case string.split_once(html, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(Nil) -> -1
  }
}

// The open pane's own read is a fresh scan: a tree the owner made clean leaves
// "To review", and a read that failed leaves the classification alone.
pub fn the_open_panes_read_settles_the_classification_test() {
  let model = settled_owner(process.new_subject(), home.Succeeded("ok"))
  assert string.contains(
    drawn(model),
    "To review<span class=\"inbox-count\">1</span>",
  )

  let failed = run(model, home.ReviewRead("A", Error("boom")))
  assert string.contains(
    drawn(failed),
    "To review<span class=\"inbox-count\">1</span>",
  )

  let cleaned = run(model, home.ReviewRead("A", Ok(clean())))
  assert !string.contains(drawn(cleaned), "To review<span")
}

// A finished session whose tree changed is "To review", and a clean one waits.
pub fn a_changed_idle_session_is_under_to_review_test() {
  let html = drawn(settled_owner(process.new_subject(), home.Succeeded("ok")))

  assert string.contains(html, "To review<span class=\"inbox-count\">1</span>")
  assert string.contains(html, "Waiting<span class=\"inbox-count\">1</span>")
  let review_at = index_of(html, "Review · web ui")
  assert review_at > 0
  assert string.contains(html, "Waiting · lint")
}

// The pane says the message is untrusted, counts and cuts plainly, and draws
// session text only as text.
pub fn the_pane_says_what_it_cut_and_draws_text_only_test() {
  let html = drawn(settled_owner(process.new_subject(), home.Succeeded("ok")))

  assert string.contains(
      html,
      "The agent&#39;s last finished turn, untrusted text",
    )
    || string.contains(html, "The agent's last finished turn, untrusted text")
  assert string.contains(html, "Done &lt;b&gt;it&lt;/b&gt;.")
  assert string.contains(html, "5 files · +41 −9")
  assert string.contains(html, "3 files not shown")
  assert string.contains(html, "12 more lines not shown")
  assert string.contains(html, "2 lines shortened to 400 bytes")
  assert string.contains(html, "3 more hunks not shown")
  assert string.contains(html, "Binary file")

  // The repository's words are escaped text, in no attribute.
  assert string.contains(
    html,
    "src/&quot;&gt;&lt;script&gt;x&lt;/script&gt;.gleam",
  )
  assert !string.contains(html, "<script>")
  assert !string.contains(html, "\"><script")
  assert !string.contains(html, "<b>it</b>")
  assert !string.contains(html, "<i>retry</i>")
}

// The find at line 41 is drawn under that line, one past its range at the top
// of its file, and one naming no shown file at the top of the pane.
pub fn finds_are_pinned_at_their_lines_or_listed_at_the_top_test() {
  // The finds' own rows in the list also carry their text, so only the pane counts.
  let page = drawn(settled_owner(process.new_subject(), home.Succeeded("ok")))
  let assert Ok(#(_, html)) = string.split_once(page, "Changes to review")

  let added = index_of(html, "loop(base * 2)")
  let pinned = index_of(html, "No backoff in &lt;i&gt;retry&lt;/i&gt;.")
  let hunk = index_of(html, "@@ -40,2 +40,3 @@ pub fn retry(")
  assert hunk > 0 && hunk < added && added < pinned

  // The loose find precedes the hunks of its file, and the unplaced one the files.
  let loose = index_of(html, "Loose in its file.")
  let unplaced = index_of(html, "Names no shown file.")
  let files = index_of(html, "review-files")
  assert unplaced > 0 && unplaced < files
  assert loose > files && loose < hunk
}

// Every control is one beneath the table, and each form is keyed apart from any
// path: a hostile path is in no key, label or placeholder.
pub fn every_review_handler_is_beneath_the_table_test() {
  let model = settled_owner(process.new_subject(), home.Succeeded("ok"))
  let keys =
    handlers(home.view(model))
    |> list.filter(string.starts_with(_, home.table_path <> "\t"))

  assert keys != []
  assert list.all(keys, fn(key) {
    string.ends_with(key, "\nclick") || string.ends_with(key, "\nsubmit")
  })
  let html = drawn(model)
  assert !string.contains(html, "aria-label=\"Comment on src")
  assert !string.contains(html, "placeholder=\"Comment on src")
}

// Staging sends nothing. One Send closes the find at its revision first and
// then delivers the one prompt, and the receipt says what each did.
pub fn staging_sends_nothing_until_one_send_carries_it_all_test() {
  let acted = process.new_subject()
  let model = settled_owner(acted, home.Succeeded("Closed as fixed."))
  let model =
    model
    |> run(home.ReviewVerdictChosen(review_stage_verdict()))
    |> run(home.ReviewCommented("src/retry.gleam", "Cap the wait."))
    |> run(home.ReviewFindStaged(find_id, attention.Fixed, "Thanks."))

  let html = drawn(model)
  assert string.contains(html, "Verdict: changes requested")
  assert string.contains(html, "Comment on src/retry.gleam: Cap the wait.")
  assert string.contains(html, "Close " <> find_id <> " as fixed: Thanks.")
  assert received(acted) == []

  let sent = run(model, home.ReviewSent)
  assert received(acted)
    == [
      Closed("A", find_id, 9, attention.Fixed),
      Messaged(
        "A",
        "main",
        "I reviewed your changes. Verdict: changes requested.\n\nFile comments:\n\nsrc/retry.gleam:\nCap the wait.\n\nFinds I closed:\n\n"
          <> find_id
          <> ": fixed. Thanks.",
      ),
    ]

  let html = drawn(sent)
  assert string.contains(html, find_id <> " (fixed): Closed as fixed.")
  assert string.contains(html, "Delivered to the session · queued")
  assert string.contains(html, "Nothing is staged.")
}

// A close the daemon refuses halts the Send, and no prompt reaches the agent.
pub fn a_refused_close_sends_no_prompt_test() {
  let acted = process.new_subject()
  let model = settled_owner(acted, home.Failed("That find changed."))
  let model =
    model
    |> run(home.ReviewVerdictChosen(review_stage_verdict()))
    |> run(home.ReviewFindStaged(find_id, attention.Dismissed, ""))
    |> run(home.ReviewSent)

  assert received(acted) == [Closed("A", find_id, 9, attention.Dismissed)]
  let html = drawn(model)
  assert string.contains(html, find_id <> " (dismissed): That find changed.")
  assert string.contains(html, "Nothing was sent to the agent.")

  // The refused find's revision was dropped and read again at once, so the
  // find offers its form and is not left waiting for the next refresh.
  assert !string.contains(html, "Reading the find…")
}

// An oversized review is refused on the page, with nothing sent or closed.
pub fn an_oversized_review_is_refused_before_send_test() {
  let acted = process.new_subject()
  let model = settled_owner(acted, home.Succeeded("ok"))
  let big = string.repeat("é", 2000)
  let model =
    model
    |> run(home.ReviewCommented("src/retry.gleam", big))
    |> run(home.ReviewCommented(hostile, big))
    |> run(home.ReviewFindStaged(find_id, attention.Fixed, big))
    |> run(home.ReviewFindStaged("find-aaaaaaaaaa", attention.Filed, big))
    |> run(home.ReviewFindStaged("find-bbbbbbbbbb", attention.Filed, big))
    |> run(home.ReviewSent)

  assert received(acted) == []
  assert string.contains(
    drawn(model),
    "byte limit. Shorten a comment or a note.",
  )
}

// A comment on a file the review does not hold is refused and not kept.
pub fn a_comment_on_a_file_not_in_the_review_is_refused_test() {
  let model =
    settled_owner(process.new_subject(), home.Succeeded("ok"))
    |> run(home.ReviewCommented("other.gleam", "x"))
  let html = drawn(model)
  assert string.contains(html, "That file is not in this review.")
  assert string.contains(html, "Nothing is staged.")
}

// A page that may only read draws the files and the finds, and no control.
pub fn a_page_that_may_not_act_draws_no_controls_test() {
  let asked = process.new_subject()
  let model = opened(start(Some(reader(asked)), None))
  let model = scanned(scanned(model))
  let html = drawn(model)

  assert string.contains(html, "Review · web ui")
  assert string.contains(html, "5 files · +41 −9")
  assert string.contains(
      html,
      "Only the owner&#39;s operating page can send a review.",
    )
    || string.contains(
      html,
      "Only the owner's operating page can send a review.",
    )
  assert !string.contains(html, "Stage the comment")
  assert !string.contains(html, "Request changes")
  assert !string.contains(html, "Close as Fixed")

  // A staging message from such a page changes nothing.
  let model = run(model, home.ReviewCommented("src/retry.gleam", "x"))
  assert !string.contains(drawn(model), "Comment on src/retry.gleam: x")
}

// A session that has not been read yet is already under To review, with a quiet
// line in place of a count of changes, so it does not jump there when its turn
// comes. A refused read leaves it where it is.
pub fn an_unread_session_is_under_to_review_and_says_it_is_being_checked_test() {
  let silent = fn(_session, _deliver) { Nil }
  let model = opened(start(Some(silent), None))
  let html = drawn(model)

  assert string.contains(html, "To review<span class=\"inbox-count\">2</span>")
  assert string.contains(html, "Checking for changes…")
  assert !string.contains(html, "Waiting<span")

  let refusing = fn(_session, deliver) { deliver(Error(scan.busy_words)) }
  let refused = opened(start(Some(refusing), None))
  assert string.contains(
    drawn(refused),
    "To review<span class=\"inbox-count\">2</span>",
  )
}

// An observer's page is given no review: nothing is read, the session waits
// with its last message, and no review pane is drawn.
pub fn an_observer_sees_no_review_test() {
  let model = opened(start(None, None))
  let model = scanned(scanned(model))
  let html = drawn(model)

  assert !string.contains(html, "To review")
  assert !string.contains(html, "Changes to review")
  assert string.contains(html, "Waiting<span class=\"inbox-count\">2</span>")
  assert string.contains(html, "Done &lt;b&gt;it&lt;/b&gt;.")
}

// The find form's fields are exactly a note and one of the three words.
pub fn the_find_form_reads_back_only_its_own_fields_test() {
  assert review_thread.closing([#("note", "ok"), #("closure", "filed")])
    == Ok(#("ok", attention.Filed))
  assert review_thread.closing([#("closure", "fixed"), #("note", "")])
    == Error(Nil)
  assert review_thread.closing([#("note", ""), #("closure", "gone")])
    == Error(Nil)
  assert review_thread.closing([
      #("note", ""),
      #("closure", "fixed"),
      #("extra", "x"),
    ])
    == Error(Nil)
}

fn review_stage_verdict() -> review_stage_rule.Verdict {
  review_stage_rule.RequestChanges
}

// The count a comment box's key carries, from a drawn page.
fn comment_key_count(html: String) -> String {
  let assert Ok(#(_, after)) = string.split_once(html, "key=\"review-A-")
    as "the page draws a comment box"
  let assert Ok(#(count, _)) = string.split_once(after, "-comment-0\"")
    as "the key names the comment box"
  count
}

// A delivered Send empties the staging, and the comment boxes must drop what
// was typed: their keys carry the open count, which a delivery raises, so the
// browser builds new boxes. A refused Send keeps the staging and the keys.
pub fn a_delivered_send_rekeys_the_forms_so_typed_text_goes_test() {
  let model = settled_owner(process.new_subject(), home.Succeeded("ok"))
  let staged =
    run(model, home.ReviewCommented("src/retry.gleam", "Cap the wait."))
  let before = comment_key_count(drawn(staged))

  let delivered = run(staged, home.ReviewSent)
  assert comment_key_count(drawn(delivered)) != before

  let refused =
    run(
      staged,
      home.ReviewPrompted(thread_send.Refused(thread_send.NotResident)),
    )
  assert comment_key_count(drawn(refused)) == before
}

// A page that is staged says what opening another review discards, with the
// session's name as text.
pub fn the_outbox_says_what_opening_another_thread_discards_test() {
  let model = settled_owner(process.new_subject(), home.Succeeded("ok"))
  assert !string.contains(drawn(model), "are discarded if you open")

  let staged = run(model, home.ReviewVerdictChosen(review_stage_verdict()))
  assert string.contains(
    drawn(staged),
    "Staged items for web ui are discarded if you open another review.",
  )
}

// The receipt of a delivered Send stays while the session works on the prompt,
// whose last message is still what it was, and goes when the agent next speaks.
pub fn the_receipt_goes_when_the_agent_next_speaks_test() {
  let acted = process.new_subject()
  let model = settled_owner(acted, home.Succeeded("Closed as fixed."))
  let sent =
    model
    |> run(home.ReviewVerdictChosen(review_stage_verdict()))
    |> run(home.ReviewSent)
  assert string.contains(drawn(sent), "Delivered to the session · queued")

  // A later activity read finds the session working on the prompt, and its last
  // finished message is the one the review was read for.
  let working =
    run(
      sent,
      home.Observed([
        #("A", Report(sessions.Working, Some("Done <b>it</b>."), [])),
        #("B", Report(sessions.Idle, Some("Nothing changed."), [])),
      ]),
    )
  let html = drawn(working)
  assert !string.contains(html, "To review<span")
  assert string.contains(html, "Changes to review")
  assert string.contains(html, "Delivered to the session · queued")

  // The turn ends with a new message: the hunks and the receipt were for what
  // it said before, and they go.
  let spoke =
    run(
      working,
      home.Observed([
        #("A", Report(sessions.Idle, Some("Capped the wait."), [])),
        #("B", Report(sessions.Idle, Some("Nothing changed."), [])),
      ]),
    )
  assert !string.contains(drawn(spoke), "Delivered to the session · queued")
}

// A refusal for the allowance sets the scan's timer once, however many refusals
// follow before it fires, and the scan goes on when it does.
pub fn a_refusal_schedules_exactly_one_rearm_test() {
  let allowance = gate()

  // Nothing is granted until the test refills the allowance.
  let refused = fn(_session, deliver) {
    case process.call(allowance, 1000, Take) {
      Granted -> deliver(Ok(review()))
      Denied -> deliver(Error(scan.busy_words))
    }
  }
  let timer = process.new_subject()
  let listed = [entry("S1", "n1"), entry("S2", "n2")]
  let answered = list.take(five(), 2)

  // The allowance is spent before the page asks, so the first read is refused.
  process.send(allowance, Drain)
  let model =
    run(
      home.new(start_for(listed, answered, Some(refused), None)),
      home.ReviewTimerReady(timer),
    )
  let model = run(model, home.TimerReady(process.new_subject()))

  // A second refusal before the timer fires sets no second timer.
  let model = run(model, home.Observed(answered))
  assert process.receive(timer, 200) == Ok(Nil)
  assert process.receive(timer, 100) == Error(Nil)

  // The timer fires with the allowance refilled, and both sessions are read.
  process.send(allowance, Refill)
  let model = run(model, home.ReviewTicked)
  process.send(allowance, Refill)
  let model = run(model, home.Observed(answered))
  assert string.contains(
    drawn(model),
    "To review<span class=\"inbox-count\">2</span>",
  )
}

// No attribute value, anywhere on the page, holds a path, a line of the diff,
// the agent's words, a find's text or anything the owner typed.
pub fn no_attribute_value_holds_session_text_test() {
  let model =
    settled_owner(process.new_subject(), home.Succeeded("ok"))
    |> run(home.ReviewCommented("src/retry.gleam", "Cap the wait."))
    |> run(home.ReviewFindStaged(find_id, attention.Fixed, "Thanks."))
    |> run(home.ReviewVerdictChosen(review_stage_verdict()))
  let values = attribute_values(drawn(model))

  assert list.length(values) > 10

  // The offending values, if any, are the failure.
  let offenders =
    list.filter(values, fn(value) {
      list.any(
        [
          "src/retry", "src/&quot;", "script", "retry", "backoff", "Backoff",
          "Cap the wait", "Thanks", "loop(", "Done", "Loose in", "Names no",
        ],
        string.contains(value, _),
      )
    })
  assert offenders == []
}

fn attribute_values(html: String) -> List(String) {
  case string.split(html, "=\"") {
    [] -> []
    [_, ..rest] ->
      list.filter_map(rest, fn(piece) {
        case string.split_once(piece, "\"") {
          Ok(#(value, _)) -> Ok(value)
          Error(Nil) -> Error(Nil)
        }
      })
  }
}

pub type Gate {
  Take(reply: Subject(Grant))
  Refill
  Drain
  Count(reply: Subject(Int))
}

pub type Grant {
  Granted
  Denied
}

// A stand-in for the daemon's allowance: two reads, then refusals until it is
// refilled, counting every ask.
fn gate() -> Subject(Gate) {
  let parent = process.new_subject()
  let _ =
    process.spawn(fn() {
      let inbox = process.new_subject()
      process.send(parent, inbox)
      gate_loop(inbox, 2, 0)
    })
  let assert Ok(inbox) = process.receive(parent, 1000)
  inbox
}

fn gate_loop(inbox: Subject(Gate), left: Int, asked: Int) -> Nil {
  case process.receive_forever(inbox) {
    Take(reply:) ->
      case left {
        0 -> {
          process.send(reply, Denied)
          gate_loop(inbox, 0, asked + 1)
        }
        _ -> {
          process.send(reply, Granted)
          gate_loop(inbox, left - 1, asked + 1)
        }
      }
    Refill -> gate_loop(inbox, 2, asked)
    Drain -> gate_loop(inbox, 0, asked)
    Count(reply:) -> {
      process.send(reply, asked)
      gate_loop(inbox, left, asked)
    }
  }
}

fn five() -> List(#(String, sessions.Report)) {
  list.map(["S1", "S2", "S3", "S4", "S5"], fn(id) {
    #(id, Report(sessions.Idle, Some("Done " <> id), []))
  })
}

// The daemon refuses the third read in four seconds. A refusal does not start
// the next read, does not count as one of a session's three tries, and the
// reads that follow the allowance's refill reach every session.
pub fn a_refusing_reader_still_reaches_every_session_test() {
  let allowance = gate()
  let reader = fn(_session, deliver) {
    case process.call(allowance, 1000, Take) {
      Granted -> deliver(Ok(review()))
      Denied -> deliver(Error(scan.busy_words))
    }
  }
  let listed =
    list.map(["S1", "S2", "S3", "S4", "S5"], fn(id) { entry(id, "n" <> id) })
  let model = opened(start_for(listed, five(), Some(reader), None))

  // Every idle session is under To review from the start, unread. The open
  // thread's own read took the first grant, and the scan waits beside it.
  assert process.call(allowance, 1000, Count) == 1
  assert string.contains(
    drawn(model),
    "To review<span class=\"inbox-count\">5</span>",
  )

  // Each later read of the page's activity finds the allowance refilled.
  let rounds =
    list.fold([1, 2, 3, 4], model, fn(held, _) {
      process.send(allowance, Refill)
      run(held, home.Observed(five()))
    })
  assert string.contains(
    drawn(rounds),
    "To review<span class=\"inbox-count\">5</span>",
  )

  // One open read, which also answers for its session, four scans for the other
  // four, and the one refusal that stopped a run, and no other ask: a refusal
  // never starts the next read.
  assert process.call(allowance, 1000, Count) == 6
}
