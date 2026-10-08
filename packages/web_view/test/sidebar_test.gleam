//// The session sidebar: how the principal's sessions are grouped and
//// ordered, when a page reads the list, and what the sidebar draws.
////
//// These tests pin that the sidebar draws every name as escaped text, marks
//// the session on screen, adds no handler but the session buttons beneath
//// `component.sidebar_path` (`session_switch_test` reads what pressing one
//// does), and leaves the paths the observer's socket admits where they were.

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lane_fixture
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import web_view/component
import web_view/operator_page
import web_view/sessions.{type Entry, Entry, Live, Saved}
import web_view/view/archiving
import web_view/view/resume
import web_view/view/sidebar

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn entry(
  id: String,
  name: String,
  workspace: String,
  created_at: Int,
  residency: sessions.Residency,
) -> Entry {
  Entry(
    id:,
    name:,
    workspace:,
    created_at:,
    residency:,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

// Three workspaces. `A`, the session on screen, is in `/src/loom` with a
// newer sibling; `/src/weft` holds the newest session of the three.
fn listing() -> List(Entry) {
  [
    entry("B", "vetting lint", "/src/loom", 300, Live),
    entry("A", "web ui", "/src/loom", 100, Live),
    entry("C", "hex release", "/src/weft", 900, Saved),
    entry("D", "", "/src/notes", 500, Saved),
    entry("E", "older weft", "/src/weft", 50, Saved),
  ]
}

fn names(group: sessions.Group) -> List(String) {
  list.map(group.entries, fn(entry) { entry.id })
}

// The groups are alphabetical by the project's directory name, though
// `/src/weft` holds the newest session of the three. Within a workspace the
// newest session is first.
pub fn the_groups_are_alphabetical_and_the_newest_session_leads_test() {
  let groups = sessions.grouped(listing())
  assert list.map(groups, fn(group) { group.workspace })
    == ["/src/loom", "/src/notes", "/src/weft"]
  let assert [loom, notes, weft] = groups
  assert names(loom) == ["B", "A"]
  assert names(notes) == ["D"]
  assert names(weft) == ["C", "E"]
}

// Which session is on screen never reorders the groups: the page's list is
// the same whichever row is selected, and a case difference in a name does not
// change the place.
pub fn selecting_a_session_does_not_reorder_the_groups_test() {
  let workspaces = fn(model) {
    list.map(component.session_groups(model), fn(group) { group.workspace })
  }
  let rows = [
    entry("W", "w", "/src/Zed", 900, Live),
    entry("A", "a", "/src/alpha", 100, Live),
    entry("M", "m", "/src/mid", 500, Live),
  ]
  let on = fn(id) {
    let start = page_fixture.start()
    let model =
      component.new(component.Start(..start, session_id: id))
      |> component.apply([lane_fixture.captured(10, None)])
    let #(model, _) = component.update(model, component.SessionsListed(rows))
    model
  }
  assert workspaces(on("W")) == ["/src/alpha", "/src/mid", "/src/Zed"]
  assert workspaces(on("A")) == workspaces(on("W"))
  assert workspaces(on("M")) == workspaces(on("W"))
}

// Two sessions created in the same millisecond are ordered by identity, and
// two workspaces with one name are ordered by path, so the order never
// depends on the order the daemon listed them in.
pub fn ties_are_broken_by_identity_and_by_path_test() {
  let tied = [
    entry("b", "second", "/src/b", 10, Live),
    entry("a", "first", "/src/b", 10, Live),
    entry("c", "other", "/src/a", 10, Live),
  ]
  let forward = sessions.grouped(tied)
  let backward = sessions.grouped(list.reverse(tied))
  assert forward == backward
  assert list.map(forward, fn(group) { group.workspace })
    == ["/src/a", "/src/b"]
  let assert [_, second] = forward
  assert names(second) == ["a", "b"]
}

pub fn no_sessions_make_no_groups_test() {
  assert sessions.grouped([]) == []
}

// A page reads the list when it opens: the transport's read is asked for once
// and its answer arrives as the page's own message.
pub fn a_page_reads_its_sessions_when_it_opens_test() {
  let answered = process.new_subject()
  let start = page_fixture.start()
  let asked = process.new_subject()
  let start =
    component.Start(
      ..start,
      transport: component.Transport(..start.transport, sessions: fn(deliver) {
        process.send(asked, Nil)
        deliver(listing())
      }),
    )
  let #(_, effects) =
    component.update(
      component.new(start),
      component.Opened(process.new_subject()),
    )
  effect.perform(
    effects,
    fn(message) { process.send(answered, message) },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  assert process.receive(asked, 0) == Ok(Nil)
  assert process.receive(answered, 0) == Ok(component.SessionsListed(listing()))
}

// The answer is grouped for the page and does not move the lane.
pub fn the_answer_fills_the_sidebar_test() {
  let model = component.new(page_fixture.start())
  assert component.session_groups(model) == []
  let #(listed, _) =
    component.update(model, component.SessionsListed(listing()))
  assert list.map(component.session_groups(listed), fn(group) {
      group.workspace
    })
    == ["/src/loom", "/src/notes", "/src/weft"]
}

// A list past the catalogue's page is cut, not drawn whole.
pub fn a_list_past_the_limit_is_cut_test() {
  let many =
    list.repeat(Nil, sessions.listed_limit + 20)
    |> list.index_map(fn(_, n) { n })
    |> list.map(fn(n) { entry(string.inspect(n), "s", "/src/x", n, Saved) })
  let #(listed, _) =
    component.update(
      component.new(page_fixture.start()),
      component.SessionsListed(many),
    )
  let assert [group] = component.session_groups(listed)
  assert list.length(group.entries) == sessions.listed_limit
}

// One read when the page opens, and the next only after the refresh interval,
// on the tick that follows it.
pub fn the_list_is_read_again_only_after_the_interval_test() {
  let asked = process.new_subject()
  let clock = page_fixture.clock()
  let start = page_fixture.start_with(clock)
  let start =
    component.Start(
      ..start,
      transport: component.Transport(..start.transport, sessions: fn(deliver) {
        process.send(asked, Nil)
        deliver([])
      }),
    )
  let model = component.new(start)
  let wire = process.new_subject()
  let run = fn(model, message) {
    let #(model, effects) = component.update(model, message)
    effect.perform(
      effects,
      fn(_) { Nil },
      fn(_, _) { Nil },
      fn(_) { Nil },
      fn() { panic as "no dynamic value" },
      fn(_, _) { Nil },
      fn(_, _) { Nil },
      fn(_) { Nil },
    )
    model
  }
  let model = run(model, component.Opened(wire))
  assert process.receive(asked, 0) == Ok(Nil)

  page_fixture.set(clock, component.sessions_refresh_ms - 1)
  let model = run(model, component.Ticked)
  assert process.receive(asked, 0) == Error(Nil)

  page_fixture.set(clock, component.sessions_refresh_ms)
  let _ = run(model, component.Ticked)
  assert process.receive(asked, 0) == Ok(Nil)
}

// The read never holds the page. A transport whose read answers late, or
// never, leaves `Opened` and every message after it to return at once with
// the sidebar empty, and the list lands as the page's own message when the
// transport's task delivers it: the runtime waits on no registry call
// (protocol-change/051, the runtime never blocks).
pub fn a_slow_sessions_read_does_not_hold_the_page_test() {
  let answered = process.new_subject()
  let delivery = process.new_subject()
  let start = page_fixture.start()
  let start =
    component.Start(
      ..start,
      transport: component.Transport(..start.transport, sessions: fn(deliver) {
        process.send(delivery, deliver)
      }),
    )
  let #(opened, effects) =
    component.update(
      component.new(start),
      component.Opened(process.new_subject()),
    )
  effect.perform(
    effects,
    fn(message) { process.send(answered, message) },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )

  // The effect started the read and returned without an answer; the page
  // goes on handling messages with no list.
  assert process.receive(answered, 0) == Error(Nil)
  assert component.session_groups(opened) == []
  let #(ticked, _) = component.update(opened, component.Ticked)
  assert component.session_groups(ticked) == []

  // The answer comes when the transport's task delivers it, as the message
  // the effect dispatches.
  let assert Ok(deliver) = process.receive(delivery, 0)
  deliver(listing())
  assert process.receive(answered, 0) == Ok(component.SessionsListed(listing()))
}

// A page holding a capture and a list, on `A`.
fn listed_page(entries: List(Entry)) {
  let #(model, _) =
    component.update(
      component.new(page_fixture.start())
        |> component.apply([lane_fixture.captured(10, None)]),
      component.SessionsListed(entries),
    )
  model
}

// The operator's page, the only one that draws the sidebar.
fn operator_html(model) -> String {
  element.to_string(operator_page.view(model))
}

// The sidebar draws each workspace by its last segment, with the whole path
// as a title, and each session by name; the session on screen is marked, and
// a session with no name is named by its identity.
pub fn the_sidebar_lists_workspaces_and_sessions_test() {
  let drawn = operator_html(listed_page(listing()))
  assert string.contains(
    drawn,
    "<aside aria-label=\"Sessions\" class=\"sidebar\" slot=\"left\">",
  )
  assert string.contains(drawn, "title=\"/src/loom\"")
  assert string.contains(drawn, ">loom<")
  assert string.contains(drawn, "vetting lint")
  assert string.contains(drawn, "Session D")

  // Sessions appear in the grouped order: the newer one of the current
  // workspace before the current session itself.
  let assert Ok(#(before_web, _)) = string.split_once(drawn, "web ui")
  assert string.contains(before_web, "vetting lint")
  assert string.contains(drawn, "class=\"session current\"")

  // Only the session on screen is current.
  assert list.length(string.split(drawn, "aria-current=\"true\"")) == 3
  assert string.contains(drawn, "running")
  assert !string.contains(drawn, "resident")
  assert string.contains(drawn, "saved")
}

// The catalogue's fields are drawn as text, never as markup.
pub fn the_sidebar_escapes_what_the_catalogue_holds_test() {
  let drawn =
    operator_html(
      listed_page([
        entry("A", "<b>bold</b> & co", "/src/<x>", 1, Live),
        entry("F", "<script>alert(1)</script>", "/src/<x>", 2, Saved),
      ]),
    )
  assert !string.contains(drawn, "<b>bold")
  assert !string.contains(drawn, "<script")
  assert string.contains(drawn, "&lt;b&gt;bold&lt;/b&gt; &amp; co")
  assert string.contains(drawn, "&lt;script&gt;")
}

// A page whose read found nothing draws no sidebar.
pub fn an_empty_list_draws_no_sidebar_test() {
  let drawn = operator_html(listed_page([]))
  assert !string.contains(drawn, "class=\"sidebar\"")
  assert string.contains(drawn, "sidebar=\"none\"")
  assert !string.contains(drawn, "<aside aria-label=\"Sessions\"")
}

// The sidebar adds one handler to the operator's page for each session other
// than the one on screen that is running or saved, a click beneath its own
// path, and none to the observer's. No row is a link or a form, and the paths the observer's
// socket admits and the operator's composer are exactly where they were.
pub fn the_sidebar_adds_only_its_session_buttons_test() {
  let bare =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.captured(10, None)])
  let listed = listed_page(listing())
  assert handlers(component.view(listed)) == handlers(component.view(bare))

  // `B` is running, and `C`, `D` and `E` are saved; none is on screen.
  let others = handlers(operator_page.view(bare))
  let added =
    list.filter(handlers(operator_page.view(listed)), fn(key) {
      !list.contains(others, key)
    })
  assert list.length(added) == 4
  assert list.all(added, fn(key) {
    string.starts_with(key, component.sidebar_path <> "\t")
    && string.ends_with(key, "\nclick")
  })

  let assert Ok(sidebar) = sidebar_of(operator_html(listed))
  assert !string.contains(sidebar, "<a ")
  assert !string.contains(sidebar, "<form")
  assert !string.contains(sidebar, "href")
  assert !string.contains(sidebar, "onclick")
  assert list.length(string.split(sidebar, "<button")) == 6
}

// The markup of the sidebar alone: from its opening tag to the first closing
// `</aside>`, which is its own, since the sidebar holds no other aside.
fn sidebar_of(drawn: String) -> Result(String, Nil) {
  use #(_, from) <- result.try(string.split_once(
    drawn,
    "<aside aria-label=\"Sessions\"",
  ))
  use #(sidebar, _) <- result.try(string.split_once(from, "</aside>"))
  Ok(sidebar)
}

// The operator's page draws the sidebar in the frame's second place: after
// the top bar and before the centre, whose composer and dock it precedes, and
// the strand panel, which is the last child.
pub fn the_operators_page_draws_the_sidebar_second_test() {
  let drawn = element.to_string(operator_page.view(listed_page(listing())))
  let assert Ok(#(before, after)) =
    string.split_once(drawn, "<aside aria-label=\"Sessions\"")
  assert string.contains(before, "class=\"session-head\"")
  assert !string.contains(before, "class=\"composer\"")
  assert string.contains(after, "class=\"composer\"")
  assert string.contains(after, "<aside aria-label=\"Strand panel\"")
}

// Focusing another strand leaves the sidebar as it was: it lists sessions,
// not strands.
pub fn focusing_a_strand_leaves_the_sidebar_alone_test() {
  let listed = listed_page(listing())
  let #(moved, _) = component.focus(listed, "advisor")
  assert component.session_groups(moved) == component.session_groups(listed)
}

// An observer's page draws no sidebar, whatever list it holds: the daemon
// supplies it none, and the view has nowhere to draw one.
pub fn an_observers_page_draws_no_sidebar_test() {
  let drawn = element.to_string(component.view(listed_page(listing())))
  assert !string.contains(drawn, "<aside aria-label=\"Sessions\"")
  assert !string.contains(drawn, "vetting lint")
  assert !string.contains(drawn, "/src/loom")
}

// The current row draws no strand bars: its activity word and dot are the one
// indicator, and the strands' states are the Strands panel's.
pub fn the_current_row_draws_no_strand_bars_test() {
  let drawn =
    element.to_string(sidebar.view(
      sessions.grouped(listing()),
      "A",
      dict.new(),
      fn(_) { Nil },
      resume.Never,
      archiving.Never,
    ))
  assert !string.contains(drawn, "dots")
  assert !string.contains(drawn, "class=\"bar")
  let page = operator_html(listed_page(listing()))
  assert !string.contains(page, "class=\"dots\"")
}

// A session with a subtitle draws it in a quiet line under its name
// (protocol-change/067), in a wrapper that holds the two; a session without one
// is the two words it always was, with no wrapper and no empty line.
pub fn a_subtitle_is_a_quiet_line_under_the_name_test() {
  let rows = [
    Entry(
      ..entry("B", "vetting lint", "/src/loom", 300, Live),
      subtitle: Some("Fix the flaky retry test"),
    ),
    entry("A", "web ui", "/src/loom", 100, Live),
  ]
  let drawn = operator_html(listed_page(rows))
  let assert Ok(sidebar) = sidebar_of(drawn)
  assert string.contains(
    sidebar,
    "<span class=\"session-text\"><span class=\"session-name\">vetting lint</span>"
      <> "<span class=\"session-subtitle\">Fix the flaky retry test</span></span>",
  )

  // The row without a subtitle has no wrapper, and only one row draws the
  // quiet line.
  assert string.contains(sidebar, "<span class=\"session-name\">web ui</span>")
  assert list.length(string.split(sidebar, "session-subtitle")) == 2
  assert list.length(string.split(sidebar, "session-text")) == 2
}

// The subtitle is a person's own prompt: it is a text node and nothing else, so
// a hostile one is escaped and is in no attribute, class, key or title.
pub fn a_subtitle_is_only_ever_a_text_node_test() {
  let hostile = "\"><img src=x onerror=alert(1)>"
  let rows = [
    Entry(
      ..entry("B", "vetting lint", "/src/loom", 300, Live),
      subtitle: Some(hostile),
    ),
    entry("A", "web ui", "/src/loom", 100, Live),
  ]
  let drawn = operator_html(listed_page(rows))
  assert !string.contains(drawn, "<img")
  assert string.contains(drawn, "&lt;img src=x onerror=alert(1)&gt;")
  assert list.length(string.split(drawn, "onerror"))
    == list.length(string.split(drawn, "onerror=alert(1)&gt;"))
  assert !string.contains(drawn, "title=\"" <> hostile)
  assert !string.contains(drawn, "class=\"" <> hostile)

  // It adds no handler beyond the row's own: the sidebar's keys are the same
  // with and without it.
  let plain = [
    entry("B", "vetting lint", "/src/loom", 300, Live),
    entry("A", "web ui", "/src/loom", 100, Live),
  ]
  assert handlers(operator_page.view(listed_page(rows)))
    == handlers(operator_page.view(listed_page(plain)))
}

// A session of a project that lives in `workspace`, which may be a worktree.
fn in_project(
  id: String,
  workspace: String,
  project: String,
  created_at: Int,
  residency: sessions.Residency,
) -> Entry {
  Entry(
    ..entry(id, "session " <> id, workspace, created_at, residency),
    project: Some(project),
  )
}

// The sessions of every worktree of one repository share a group, headed by
// the repository's directory name and not by the worktree's. A repository's own
// checkout, a worktree and a directory that is no repository are three
// sessions in two groups, and the group's key is the repository's whole path.
pub fn worktrees_group_under_their_repository_test() {
  let rows = [
    in_project("a", "/src/btcd", "/src/btcd", 100, Live),
    in_project(
      "b",
      "/src/btcd/.claude/worktrees/hungry-euclid-d93364",
      "/src/btcd",
      200,
      Live,
    ),
    entry("c", "notes", "/home/notes", 50, Live),
  ]
  let groups = sessions.grouped(rows)
  assert list.map(groups, fn(group) { group.project })
    == ["/src/btcd", "/home/notes"]
  let assert [btcd, _] = groups
  assert names(btcd) == ["b", "a"]
  assert dict.get(sessions.titles(groups), "/src/btcd") == Ok("btcd")
  assert dict.get(sessions.titles(groups), "/home/notes") == Ok("notes")

  // A new session under the heading goes to a workspace the catalogue lists:
  // the repository's own checkout when a session is there.
  assert btcd.workspace == "/src/btcd"
}

// When no session runs in the repository's own checkout, a new session under
// its heading goes where the newest session is.
pub fn a_group_with_no_checkout_session_creates_where_the_newest_runs_test() {
  let rows = [
    in_project("a", "/src/btcd/.claude/worktrees/one", "/src/btcd", 100, Live),
    in_project("b", "/src/btcd/.claude/worktrees/two", "/src/btcd", 200, Live),
  ]
  let assert [group] = sessions.grouped(rows)
  assert group.workspace == "/src/btcd/.claude/worktrees/two"
}

// Two repositories that share a base name stay two groups, and their headings
// say the parent directory so they can be told apart. A third whose parent is
// also shared is told apart by its whole path.
pub fn repositories_that_share_a_name_never_merge_test() {
  let rows = [
    in_project("a", "/work/api", "/work/api", 100, Live),
    in_project("b", "/play/api", "/play/api", 200, Live),
    in_project("c", "/src/loom", "/src/loom", 300, Live),
  ]
  let groups = sessions.grouped(rows)
  assert list.length(groups) == 3
  let titles = sessions.titles(groups)
  assert dict.get(titles, "/work/api") == Ok("work/api")
  assert dict.get(titles, "/play/api") == Ok("play/api")
  assert dict.get(titles, "/src/loom") == Ok("loom")

  let same_parent = [
    in_project("d", "/a/x/api", "/a/x/api", 100, Live),
    in_project("e", "/b/x/api", "/b/x/api", 200, Live),
  ]
  let titles = sessions.titles(sessions.grouped(same_parent))
  assert dict.get(titles, "/a/x/api") == Ok("/a/x/api")
  assert dict.get(titles, "/b/x/api") == Ok("/b/x/api")
}

// A worktree row names its worktree in a quiet word with the whole path as its
// title, in the sidebar; the repository's own checkout row says nothing extra,
// and the heading is the repository's name.
pub fn a_worktree_row_says_which_worktree_test() {
  let tree = "/src/btcd/.claude/worktrees/hungry-euclid-d93364"
  let rows = [
    in_project("A", "/src/btcd", "/src/btcd", 100, Live),
    in_project("B", tree, "/src/btcd", 200, Live),
  ]
  let drawn = operator_html(listed_page(rows))
  assert string.contains(drawn, ">btcd<")
  assert string.contains(
    drawn,
    "<span class=\"session-text\"><span class=\"session-name\">session B</span>"
      <> "<span class=\"session-subtitle\"><span class=\"session-tree\" title=\""
      <> tree
      <> "\">hungry-euclid-d93364</span></span></span>",
  )
  assert list.length(string.split(drawn, "session-tree")) == 2
  assert list.length(string.split(drawn, "class=\"workspace\"")) == 2
}

// The sidebar lists the sessions a process runs, and the saved ones sit behind
// a quiet "N saved" line, in the document but in a panel the stylesheet hides
// until the element opens it. The line is one button beneath the element, with
// the fixed mark the element reads and no handler of the page's.
pub fn saved_sessions_sit_behind_a_toggle_test() {
  let drawn = operator_html(listed_page(listing()))
  let assert Ok(sidebar) = sidebar_of(drawn)
  let assert Ok(#(running, saved)) =
    string.split_once(sidebar, "class=\"saved-region\"")

  // `B` runs and `A` is on screen; the three saved sessions are behind.
  assert string.contains(running, "vetting lint")
  assert string.contains(running, "web ui")
  assert !string.contains(running, "hex release")
  assert !string.contains(running, "older weft")
  assert !string.contains(running, "Session D")
  assert string.contains(saved, "hex release")
  assert string.contains(saved, "older weft")
  assert string.contains(saved, "Session D")

  // The toggle is one button in the element, closed to begin with.
  assert string.contains(
    saved,
    "<loom-saved><button aria-expanded=\"false\" class=\"saved-toggle\""
      <> " data-saved=\"toggle\" title=\"Show or hide the saved sessions\""
      <> " type=\"button\">3 saved</button></loom-saved>",
  )
  assert string.contains(saved, "<div class=\"saved-panel\">")
}

// The switcher reads the sidebar's `.session-open` buttons, so a saved session
// must still be one while it is folded away: every session that can be pressed
// is a button in the sidebar's markup whether or not it is showing.
pub fn the_saved_sessions_stay_in_the_document_for_the_switcher_test() {
  let drawn = operator_html(listed_page(listing()))
  let assert Ok(sidebar) = sidebar_of(drawn)

  // `B` plus the three saved ones.
  assert list.length(string.split(sidebar, "class=\"session-open\"")) == 5
  assert string.contains(sidebar, "title=\"Resume this session\"")
}

// The session on screen is always listed, though it is saved: the person sees
// where they are. With nothing else saved there is no toggle at all.
pub fn the_current_saved_session_still_shows_test() {
  let rows = [
    entry("A", "web ui", "/src/loom", 100, Saved),
    entry("B", "vetting lint", "/src/loom", 300, Live),
  ]
  let drawn = operator_html(listed_page(rows))
  let assert Ok(sidebar) = sidebar_of(drawn)
  assert string.contains(sidebar, "class=\"session current\"")
  assert string.contains(sidebar, "web ui")
  assert !string.contains(sidebar, "saved-region")
  assert !string.contains(sidebar, "loom-saved")
}

// A project whose sessions are all saved has no section above the line, and a
// session that is blocked is saved too.
pub fn a_project_with_only_saved_sessions_is_behind_the_toggle_test() {
  let rows = [
    entry("A", "web ui", "/src/loom", 100, Live),
    entry("Z", "stuck", "/src/weft", 50, sessions.Blocked),
  ]
  let drawn = operator_html(listed_page(rows))
  let assert Ok(sidebar) = sidebar_of(drawn)
  let assert Ok(#(running, saved)) =
    string.split_once(sidebar, "class=\"saved-region\"")
  assert !string.contains(running, "weft")
  assert string.contains(saved, "weft")
  assert string.contains(saved, ">1 needs attention<")
  assert !string.contains(saved, ">1 saved<")
}

// A group with both kinds says both counts, so the blocked row is never called
// saved.
pub fn the_toggle_counts_saved_and_blocked_rows_apart_test() {
  let rows = [
    entry("A", "web ui", "/src/loom", 100, Live),
    entry("Y", "older", "/src/weft", 60, Saved),
    entry("Z", "stuck", "/src/weft", 50, sessions.Blocked),
  ]
  let drawn = operator_html(listed_page(rows))
  let assert Ok(sidebar) = sidebar_of(drawn)

  assert string.contains(sidebar, ">1 saved · 1 needs attention<")
}

// A worktree row that also has a subtitle leads the quiet line with the
// worktree, then the subtitle as its own text after a dot, and the path is only
// ever in the worktree word's title.
pub fn a_worktree_row_with_a_subtitle_says_both_test() {
  let tree = "/src/btcd/.claude/worktrees/calm-turing"
  let rows = [
    Entry(
      ..in_project("B", tree, "/src/btcd", 200, Live),
      subtitle: Some("Fix the retry"),
    ),
    in_project("A", "/src/btcd", "/src/btcd", 100, Live),
  ]
  let drawn = operator_html(listed_page(rows))
  assert string.contains(
    drawn,
    "<span class=\"session-subtitle\"><span class=\"session-tree\" title=\""
      <> tree
      <> "\">calm-turing</span> · Fix the retry</span>",
  )
}

// A page whose transport answers the activity read with `rows`, after a list
// of `entries`, as the page's own messages arrive: the list, then the answer.
fn with_activity(
  entries: List(Entry),
  rows: List(#(String, sessions.Activity)),
) {
  let asked = process.new_subject()
  let start = page_fixture.start()
  let start =
    component.Start(
      ..start,
      transport: component.Transport(
        ..start.transport,
        activity: fn(ids, deliver) {
          process.send(asked, ids)
          deliver(rows)
        },
      ),
    )
  let messages = process.new_subject()
  let model =
    component.new(start) |> component.apply([lane_fixture.captured(10, None)])
  let #(model, effects) =
    component.update(model, component.SessionsListed(entries))
  effect.perform(
    effects,
    fn(message) { process.send(messages, message) },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  let assert Ok(answer) = process.receive(messages, 0)
  let #(model, _) = component.update(model, answer)
  #(model, process.receive(asked, 0))
}

// The session page asks the daemon what its running sessions are doing, once
// for each read of the list, naming only the running ones in the order the
// sidebar draws them, and the answer sets each other row's word and dot class:
// the same three states the home draws. The page's own row is its lane's
// (`the_current_row_follows_the_lane_not_the_read_test`).
pub fn the_session_pages_sidebar_draws_each_sessions_activity_test() {
  let #(model, asked) = with_activity(listing(), [#("B", sessions.NeedsYou)])
  assert asked == Ok(["B", "A"])
  let assert Ok(sidebar) = sidebar_of(operator_html(model))
  assert string.contains(sidebar, "residency live needs-you")
  assert string.contains(sidebar, "</span>needs you</span>")

  let #(idle, _) = with_activity(listing(), [#("B", sessions.Idle)])
  let assert Ok(sidebar) = sidebar_of(operator_html(idle))
  assert string.contains(sidebar, "residency live idle")
  assert string.contains(sidebar, "</span>idle</span>")

  let #(working, _) = with_activity(listing(), [#("B", sessions.Working)])
  let assert Ok(sidebar) = sidebar_of(operator_html(working))
  assert string.contains(sidebar, "residency live working")

  // A session the read has not named yet says "running" as it always did.
  let #(unnamed, _) = with_activity(listing(), [])
  let assert Ok(sidebar) = sidebar_of(operator_html(unnamed))
  assert string.contains(sidebar, "</span>running</span>")
}

// A page with nothing running asks nothing, and the daemon is never asked
// about a saved session.
pub fn a_list_with_nothing_running_asks_no_activity_test() {
  let rows = [entry("C", "hex release", "/src/weft", 900, Saved)]
  let start = page_fixture.start()
  let start =
    component.Start(
      ..start,
      transport: component.Transport(..start.transport, activity: fn(_, _) {
        panic as "nothing runs, so nothing is asked"
      }),
    )
  let #(_, effects) =
    component.update(component.new(start), component.SessionsListed(rows))
  effect.perform(
    effects,
    fn(_) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
}

// The page's own row is read from its lane, not from the activity read, so it
// never lags the Strands panel beside it. The read's answer for the page's own
// session is ignored in every state: here it says idle (or working) while the
// lane says otherwise.
pub fn the_current_row_follows_the_lane_not_the_read_test() {
  let row_of = fn(capture, said) {
    let model =
      component.new(page_fixture.start()) |> component.apply([capture])
    let #(model, _) =
      component.update(model, component.SessionsListed(listing()))
    let #(model, _) = component.update(model, component.ActivityObserved(said))
    let assert Ok(sidebar) = sidebar_of(operator_html(model))
    let assert Ok(#(_, from_current)) =
      string.split_once(sidebar, "class=\"session current\"")
    let assert Ok(#(row, _)) = string.split_once(from_current, "</li>")
    row
  }

  // A strand is working: the lane says working though the read says idle.
  let working = row_of(lane_fixture.captured(10, None), [#("A", sessions.Idle)])
  assert string.contains(working, "residency live working")
  assert string.contains(working, "</span>working</span>")

  // Nothing runs: idle, though the read still says working.
  let idle =
    row_of(lane_fixture.captured_with(10, None, []), [
      #("A", sessions.Working),
    ])
  assert string.contains(idle, "residency live idle")
  assert string.contains(idle, "</span>idle</span>")

  // A strand waits on an approval: needs you, at once, though the read says
  // idle.
  let waiting =
    row_of(
      lane_fixture.captured_cells(
        10,
        None,
        [#(lane_fixture.tester, lane_fixture.tests_op())],
        [
          lane_fixture.pending_approval(
            lane_fixture.tester,
            lane_fixture.tests_op(),
          ),
        ],
      ),
      [#("A", sessions.Idle)],
    )
  assert string.contains(waiting, "residency live needs-you")
  assert string.contains(waiting, "</span>needs you</span>")
}

// F146: a session whose last run failed, with nothing pending and nothing
// running, is not waiting on its operator, so its row says `failed` in the
// danger hue and not `needs you`. A pending approval still says `needs you`.
pub fn a_failed_run_reads_failed_and_not_needs_you_test() {
  let model =
    component.new(page_fixture.start())
    |> component.apply([
      lane_fixture.failed_main(lane_fixture.captured_with(10, None, [])),
    ])
  let #(model, _) = component.update(model, component.SessionsListed(listing()))
  let assert Ok(sidebar) = sidebar_of(operator_html(model))
  let assert Ok(#(_, from_current)) =
    string.split_once(sidebar, "class=\"session current\"")
  let assert Ok(#(row, _)) = string.split_once(from_current, "</li>")
  assert string.contains(row, "residency live failed")
  assert string.contains(row, "</span>failed</span>")
  assert !string.contains(row, "needs you")
}

// The home's read says `needs_you` for both a failed run and an approval
// waiting; its count of pending approvals tells them apart.
pub fn a_needs_you_read_with_no_approval_is_a_failed_run_test() {
  assert sessions.activity_from("needs_you", 0) == Ok(sessions.Failed)
  assert sessions.activity_from("needs_you", 1) == Ok(sessions.NeedsYou)
  assert sessions.activity_from("working", 0) == Ok(sessions.Working)
  assert sessions.activity_from("idle", 0) == Ok(sessions.Idle)
  assert sessions.activity_from("unknown", 0) == Error(Nil)
  assert sessions.activity_words(sessions.Failed) == "failed"

  let #(model, _) = with_activity(listing(), [#("B", sessions.Failed)])
  let assert Ok(sidebar) = sidebar_of(operator_html(model))
  assert string.contains(sidebar, "residency live failed")
  assert string.contains(sidebar, "</span>failed</span>")
}

// Before the first capture the page knows nothing of its own session, so the
// read's answer stands for its row.
pub fn the_current_row_uses_the_read_before_a_capture_test() {
  let #(model, _) =
    component.update(
      component.new(page_fixture.start()),
      component.SessionsListed(listing()),
    )
  let #(model, _) =
    component.update(
      model,
      component.ActivityObserved([#("A", sessions.NeedsYou)]),
    )
  assert dict.get(component.session_activity(model), "A")
    == Ok(sessions.NeedsYou)
}

// The activity is read again every `activity_refresh_ms`, on the tick, apart
// from the list: not before the interval, not for a page with no list, and
// never twice for one list read.
pub fn the_activity_is_read_on_its_own_faster_cadence_test() {
  let asked = process.new_subject()
  let clock = page_fixture.clock()
  let start = page_fixture.start_with(clock)
  let start =
    component.Start(
      ..start,
      transport: component.Transport(..start.transport, activity: fn(ids, _) {
        process.send(asked, ids)
      }),
    )
  let run = fn(model, message) {
    let #(model, effects) = component.update(model, message)
    effect.perform(
      effects,
      fn(_) { Nil },
      fn(_, _) { Nil },
      fn(_) { Nil },
      fn() { panic as "no dynamic value" },
      fn(_, _) { Nil },
      fn(_, _) { Nil },
      fn(_) { Nil },
    )
    model
  }

  // A tick with no list asks nothing, and the list read asks once.
  let model = run(component.new(start), component.Ticked)
  assert process.receive(asked, 0) == Error(Nil)
  let model = run(model, component.SessionsListed(listing()))
  assert process.receive(asked, 0) == Ok(["B", "A"])

  // Just under the interval, nothing; at it, one read for the running rows.
  page_fixture.set(clock, component.activity_refresh_ms - 1)
  let model = run(model, component.Ticked)
  assert process.receive(asked, 0) == Error(Nil)
  page_fixture.set(clock, component.activity_refresh_ms)
  let model = run(model, component.Ticked)
  assert process.receive(asked, 0) == Ok(["B", "A"])

  // The same tick again asks nothing, and the next interval asks once more.
  let model = run(model, component.Ticked)
  assert process.receive(asked, 0) == Error(Nil)
  page_fixture.set(clock, component.activity_refresh_ms * 2)
  let _ = run(model, component.Ticked)
  assert process.receive(asked, 0) == Ok(["B", "A"])
}
