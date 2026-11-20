//// The live rail, "Lifted from this session": what it draws from a page's
//// pieces and approvals, that no control in it decides anything, that an
//// insight folds once opened and a pinned row never does, that every marker
//// is a daemon key, and what the phone's bar counts.
////
//// The fixture page holds one pending approval, a peer message and a
//// sub-agent's result, which is what the rail lifts from it. The jump itself
//// is the browser's (`web_client/jump_rule`), so these tests pin what the
//// server owes it: the markers, and the rows they name.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element.{type Element}
import page_fixture
import qcheck
import session_view/attention
import web_view/component
import web_view/operator_page
import web_view/view/lane
import web_view/view/lifted

const sweep_seed = 20_261_118

@external(erlang, "page_events_ffi", "handlers")
fn every_handler(view: Element(message)) -> List(String)

// The page with a pending approval, a peer message and a child's result.
fn lifting() {
  component.new(page_fixture.start())
  |> component.apply([
    lane_fixture.captured_cells(10, None, [], [
      lane_fixture.pending_approval("main", lane_fixture.main_op()),
    ]),
  ])
}

fn quiet() {
  component.new(page_fixture.start())
}

fn operator(model) -> String {
  element.to_string(operator_page.view(model))
}

fn observer(model) -> String {
  element.to_string(component.view(model))
}

fn count(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

// The rail's own markup: from its section to the section's end.
fn rail_of(html: String) -> String {
  let assert Ok(#(_, from)) =
    string.split_once(html, "<section aria-label=\"Lifted from this session\"")
    as "the page draws the rail"
  let assert Ok(#(rail, _)) = string.split_once(from, "</p></div></section>")
    as "the rail is closed"
  rail
}

fn rail_handlers(view: Element(message)) -> List(String) {
  every_handler(view)
  |> list.filter(fn(key) {
    string.starts_with(key, component.rail_path <> "\t")
  })
}

fn open(model, key: String) {
  component.update(model, component.RailOpened(key)).0
}

pub fn the_rail_draws_both_groups_from_the_pieces_and_the_approvals_test() {
  let rail = rail_of(operator(lifting()))
  assert string.contains(rail, "Lifted from this session")
  assert string.contains(rail, "Needs you")
  assert string.contains(rail, "Insights")
  assert string.contains(rail, "write a file · write the file")
  assert string.contains(rail, "another session")
  assert string.contains(rail, "messaged this session")
  assert string.contains(rail, "Approval")
  assert string.contains(rail, "Peer")
  assert string.contains(rail, "Result")
}

pub fn the_rail_is_the_strands_panes_last_child_at_the_admitted_path_test() {
  let html = operator(lifting())
  let assert Ok(#(before, _)) =
    string.split_once(html, "<section aria-label=\"Lifted from this session\"")
  assert string.contains(before, "pane-strands")
  assert component.rail_path == "0\t3\t0\t4"
}

pub fn an_empty_rail_draws_nothing_test() {
  let html = operator(quiet())
  assert !string.contains(html, "Lifted from this session")
  assert !string.contains(html, "lift-sheet")
  assert !string.contains(observer(quiet()), "lift-sheet")
}

pub fn an_empty_group_draws_nothing_test() {
  let only_insights =
    lifted.Rail(
      items: [
        lifted.Item(
          attention.Lifted(
            "9.0",
            attention.FailedTurn,
            attention.FoldsOnceOpened,
            "boom",
          ),
          "9.0",
          None,
        ),
      ],
      opened: [],
      strand: "main",
      dock: lifted.InDock,
      names: fn(_) { None },
      open: None,
      under: fn(_) { element.none() },
      offer: fn(_) { lifted.NoOffer },
      status: "",
    )
  let html = element.to_string(lifted.view(only_insights))
  assert string.contains(html, "Insights")
  assert !string.contains(html, "Needs you")
}

fn one_card(at: option.Option(Int)) -> String {
  lifted.Rail(
    items: [
      lifted.Item(
        attention.Lifted(
          "9.0",
          attention.FailedTurn,
          attention.FoldsOnceOpened,
          "boom",
        ),
        "9.0",
        at,
      ),
    ],
    opened: [],
    strand: "main",
    dock: lifted.InDock,
    names: fn(_) { None },
    open: None,
    under: fn(_) { element.none() },
    offer: fn(_) { lifted.NoOffer },
    status: "",
  )
  |> lifted.view
  |> element.to_string
}

// A card's time comes before its source, in the browser's zone, and a card whose
// record carries none draws the source alone.
pub fn a_cards_time_comes_before_its_source_test() {
  assert string.contains(
    one_card(Some(1_790_030_460_000)),
    "<span class=\"lift-source\"><loom-time at=\"1790030460000\" class=\"lift-time\" title=\"22:41 UTC\">22:41</loom-time> · main</span>",
  )
  let without = one_card(None)
  assert string.contains(without, "<span class=\"lift-source\">main</span>")
  assert !string.contains(without, "loom-time")
}

// The lane's gutter draws the time of every row whose records carry one, as an
// element the browser words in its own zone, so a row is never given a time the
// records did not.
pub fn the_lane_draws_each_rows_time_in_the_gutter_test() {
  let html = observer(lifting())
  assert string.contains(html, "class=\"tl-time\" title=\"")
}

// An approval is decided in the dock under 051's rules. The rail points at the
// card and has no control that acts: no form, no submit, none of the card's
// words, and no handler on the pinned row.
pub fn an_approval_entry_has_no_deciding_control_test() {
  let rail = rail_of(operator(lifting()))
  assert string.contains(rail, "Decide in the dock ↓")
  assert string.contains(rail, "data-loom-jump=\"dock\"")
  assert !string.contains(rail, "<form")
  assert !string.contains(rail, "type=\"submit\"")
  assert !string.contains(rail, "Approve")
  assert !string.contains(rail, "Deny")
  assert !string.contains(rail, "Allow")
  assert !string.contains(rail, "autofocus")

  // The two insights are the rail's only handlers, and the approval has none.
  assert list.length(rail_handlers(operator_page.view(lifting()))) == 2
  assert list.all(rail_handlers(operator_page.view(lifting())), fn(key) {
    string.ends_with(key, "\nclick")
  })
}

pub fn the_dock_still_holds_the_approval_card_test() {
  let html = operator(lifting())
  assert string.contains(html, "<footer class=\"dock\"")
  assert string.contains(html, "fs_write")
}

pub fn an_observers_approval_entry_points_nowhere_test() {
  let rail = rail_of(observer(lifting()))
  assert string.contains(rail, "The operator decides")
  assert !string.contains(rail, "Decide in the dock")
  assert !string.contains(rail, "data-loom-jump=\"dock\"")

  // An observer may still open an insight, which acts on nothing.
  assert list.length(rail_handlers(component.view(lifting()))) == 2
}

pub fn an_insight_folds_after_one_open_and_stays_folded_test() {
  let before = rail_of(operator(lifting()))
  assert count(before, "lift-open") == 2
  assert count(before, "lift-folded") == 0

  let once = open(lifting(), "9.0")
  let rail = rail_of(operator(once))
  assert count(rail, "lift-open") == 1
  assert count(rail, "lift-folded") == 1
  assert list.length(rail_handlers(operator_page.view(once))) == 1

  // Opening it again changes nothing, and neither do later renders.
  let again = open(once, "9.0")
  assert again == once
  assert count(rail_of(operator(again)), "lift-folded") == 1
}

pub fn a_pinned_row_never_folds_and_an_unknown_key_opens_nothing_test() {
  let model = lifting()
  assert open(model, "approval:esc-1") == model
  assert open(model, "no such row") == model

  let rail = rail_of(operator(open(model, "approval:esc-1")))
  assert count(rail, "lift-pinned") == 1
  assert count(rail, "lift-open") == 2
}

pub fn opened_insights_are_bounded_test() {
  let model = lifting()
  assert list.length(component.lifted(model)) == 3
  assert component.open_insights >= 8
}

// A marker's value is a transcript row's key or `dock`. The child's name in
// the fixture carries markup, and reaches the page as escaped text only.
pub fn markers_carry_keys_and_text_stays_text_test() {
  let html = operator(lifting())
  let rail = rail_of(html)
  assert string.contains(rail, "data-loom-jump=\"9.0\"")
  assert string.contains(rail, "data-loom-jump=\"6.0/0/0\"")
  assert string.contains(rail, "data-loom-jump=\"dock\"")
  assert count(rail, "data-loom-jump=") == 3
  assert !string.contains(html, "<b>review")
}

// A result says only its outcome, and a peer's message names the session by a
// catalogue name or by "another session": no raw identity reaches the rail.
pub fn heads_and_sources_carry_no_raw_identity_test() {
  let rail = rail_of(operator(lifting()))
  assert !string.contains(rail, "review-1a2b3c")
  assert !string.contains(rail, "lint-census")
  assert string.contains(rail, "<span class=\"lift-head\">completed</span>")
}

// The rows are plain buttons: only a disclosure would say `aria-expanded`.
pub fn the_rows_state_no_expansion_test() {
  assert !string.contains(rail_of(operator(lifting())), "aria-expanded")
}

// Every handler the rail draws is at a path the observer's socket admits, on
// a page with an approval and on one with none.
pub fn every_rail_handler_is_at_the_admitted_shape_test() {
  let without_approval =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.captured(10, None)])
  list.each([lifting(), without_approval], fn(model) {
    let keys = rail_handlers(component.view(model))
    assert list.length(keys) == 2
    assert list.all(keys, fn(key) {
      let assert Ok(#(path, _)) = string.split_once(key, "\n")
      component.rail_click(path)
    })
  })
}

// A key that names no lane row stays as it is, and the browser finds none.
pub fn a_key_with_no_row_is_left_alone_test() {
  let step =
    attention.Lifted(
      "work:7",
      attention.FailedStep,
      attention.FoldsOnceOpened,
      "1 step failed",
    )
  let items = lifted.items([], [step], lifted.InDock, fn(_) { None })
  assert list.map(items, fn(item) { item.target }) == ["work:7"]
}

pub fn rows_carry_their_key_and_lifted_rows_a_tag_test() {
  let html = operator(lifting())
  assert string.contains(html, "data-loom-row=\"9.0\"")
  assert string.contains(html, "data-loom-row=\"6.0/0/0\"")
  assert count(html, "<span class=\"lift-tag\">lifted · ") == 2

  // The insights are not tinted: only a row that needs the owner is.
  assert !string.contains(html, "needs-you\"")
}

pub fn the_marks_carry_the_lifted_rows_test() {
  let model = lifting()
  let pieces = component.pieces(model)
  let marks =
    component.marked(model, component.lift(model, pieces, lifted.InDock))
  let assert Ok(turn) = dict.get(marks.lifted, "9.0")
    as "the failed turn is marked"
  let assert Ok(block) = dict.get(marks.lifted, "6.0/0/0")
    as "the failed response is marked"
  assert turn.hold == attention.FoldsOnceOpened
  assert block.hold == attention.FoldsOnceOpened
  assert turn.word == "Peer"
  assert dict.size(marks.lifted) == 2
}

pub fn only_a_row_that_needs_the_owner_is_tinted_test() {
  let model = lifting()
  let pieces = component.pieces(model)
  let marks =
    lane.Marks(
      ..component.marks(model),
      lifted: dict.from_list([
        #("9.0", lane.Lifting(attention.PinnedUntilAnswered, "Failed")),
        #("6.0/0/0", lane.Lifting(attention.FoldsOnceOpened, "Result")),
      ]),
    )
  let html =
    element.to_string(lane.view(
      pieces,
      [],
      lane.Beginning,
      Nil,
      lane.NoReplies,
      marks,
      lane.NoFolds,
      "",
    ))
  assert count(html, "needs-you") == 1
  assert count(html, "lifted-row") == 2
  assert count(html, "lift-tag") == 2
}

pub fn the_phone_bar_counts_what_needs_you_and_the_insights_test() {
  let html = operator(lifting())
  assert string.contains(
    html,
    "<summary class=\"lift-bar\"><span class=\"lift-bar-need\">1 needs you</span><span class=\"lift-bar-count\">· 2 insights</span><span class=\"lift-bar-more\">Lifted ▴</span><span class=\"lift-bar-title\">Lifted from this session</span><span class=\"lift-bar-close\">Close ▾</span></summary>",
  )
  assert string.contains(
    observer(lifting()),
    "<span class=\"lift-bar-need\">1 needs you</span>",
  )
}

pub fn the_sheet_rows_are_not_handlers_and_close_on_a_jump_marker_test() {
  let html = operator(lifting())
  assert string.contains(
    html,
    "<details class=\"lift-sheet\" data-loom-sheet=\"lifted\"",
  )

  // The sheet is drawn after everything else in the centre, so it moves no
  // path, and its rows send nothing: only the rail's two insights do.
  assert list.length(rail_handlers(operator_page.view(lifting()))) == 2
  assert count(html, "data-loom-jump=\"dock\"") == 2
}

pub fn the_bar_words_leave_out_a_zero_part_test() {
  assert lifted.count_words(2, 1) == "2 need you · 1 insight"
  assert lifted.count_words(0, 3) == "3 insights"
  assert lifted.count_words(1, 0) == "1 needs you"
  assert lifted.count_words(0, 0) == ""
}

// For any choice of opened insights, the handlers the rail draws are exactly
// the unopened insights, and a pinned row is drawn pinned whatever is opened.
pub fn handlers_are_the_unopened_insights_and_pins_never_fold_test() {
  let insight = fn(key) {
    lifted.Item(
      attention.Lifted(
        key,
        attention.FailedTurn,
        attention.FoldsOnceOpened,
        "head " <> key,
      ),
      key,
      None,
    )
  }
  let pin =
    lifted.Item(
      attention.Lifted(
        "approval:a",
        attention.ApprovalPending("fs_write"),
        attention.PinnedUntilAnswered,
        "wants",
      ),
      "dock",
      None,
    )
  let keys = ["a", "b", "c", "d"]

  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(200)
    |> qcheck.with_seed(qcheck.seed(sweep_seed))

  qcheck.run(
    config,
    qcheck.generic_list(
      qcheck.bounded_int(0, 5),
      length_from: qcheck.bounded_int(0, 8),
    ),
    fn(picked) {
      let opened =
        list.filter_map(picked, fn(n) { list.drop(keys, n) |> list.first })
        |> list.append(["approval:a"])
      let view =
        lifted.view(lifted.Rail(
          items: [pin, ..list.map(keys, insight)],
          opened:,
          strand: "main",
          dock: lifted.InDock,
          names: fn(_) { None },
          open: Some(fn(key) { key }),
          under: fn(_) { element.none() },
          offer: fn(_) { lifted.NoOffer },
          status: "",
        ))
      let html = element.to_string(view)
      let unopened = list.filter(keys, fn(key) { !list.contains(opened, key) })

      assert list.length(every_handler(view)) == list.length(unopened)
      assert count(html, "lift-pinned") == 1
      assert count(html, "lift-folded") == 4 - list.length(unopened)
    },
  )
}
