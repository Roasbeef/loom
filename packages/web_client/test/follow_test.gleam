//// The pinned transcript's follow rules: where the reader is after a scroll,
//// who moved it, how a gap and a move are measured, and what a held row asks
//// for once older rows have landed above it.
////
//// The sequence tests feed the reader the steps the page would send and read
//// it back. The element's effects (the scroll to the bottom, the measuring)
//// need a page and are not run here.

import gleam/list
import gleam/option.{None, Some}
import web_client/follow_rule.{
  type Extent, Extent, Following, Input, Layout, Reading, Steady,
}

// What the page tells the follower, in the order it does. A resize changes
// nothing the reader knows: the element scrolls to the bottom in response,
// which arrives as the scroll that follows it.
type Step {
  Touch(at: Int)
  Scroll(top: Float, extent: Extent, at: Int)
  Resize
  Measure(gap: Int)
  Fold
  Page
  Jump
}

// A transcript 2000 pixels tall in a 500 pixel view, scrolled to the bottom
// (1500 pixels down), with the reader having touched nothing.
fn at_the_bottom() -> follow_rule.Reader {
  follow_rule.Reader(
    position: Following,
    gap: 0,
    top: 1500.0,
    extent: Extent(content: 2000.0, view: 500.0),
    touched: None,
  )
}

fn feed(reader: follow_rule.Reader, steps: List(Step)) -> follow_rule.Reader {
  list.fold(steps, reader, fn(reader, step) {
    case step {
      Touch(at:) -> follow_rule.touched(reader, at)
      Scroll(top:, extent:, at:) ->
        follow_rule.scrolled(reader, top, extent, at)
      Resize -> reader
      Measure(gap:) -> follow_rule.measured(reader, gap)
      Fold -> follow_rule.folded(reader)
      Page -> follow_rule.paged(reader)
      Jump -> follow_rule.jumped(reader)
    }
  })
}

pub fn position_is_following_within_the_slack_test() {
  assert follow_rule.position(0) == Following
  assert follow_rule.position(follow_rule.slack) == Following
  assert follow_rule.position(follow_rule.slack + 1) == Reading
}

pub fn a_scroll_up_by_the_reader_that_ends_away_leaves_the_tail_test() {
  assert follow_rule.after_scroll(Following, 300, -80, Input) == Reading
  assert follow_rule.after_scroll(Following, 300, -80, Steady) == Reading
}

pub fn a_scroll_up_by_the_layout_that_ends_away_does_not_test() {
  assert follow_rule.after_scroll(Following, 300, -80, Layout) == Following
  assert follow_rule.after_scroll(Reading, 300, -80, Layout) == Reading
}

pub fn a_scroll_down_that_ends_away_changes_nothing_test() {
  // It is the reader coming back, or the element's own scroll to the bottom
  // reported after more rows landed beneath it.
  assert follow_rule.after_scroll(Following, 300, 80, Input) == Following
  assert follow_rule.after_scroll(Following, 300, 80, Layout) == Following
  assert follow_rule.after_scroll(Reading, 300, 80, Input) == Reading
  assert follow_rule.after_scroll(Reading, 300, 0, Steady) == Reading
}

pub fn a_scroll_that_ends_at_the_bottom_follows_whoever_made_it_test() {
  assert follow_rule.after_scroll(Reading, 10, 80, Input) == Following
  assert follow_rule.after_scroll(Reading, 10, -80, Input) == Following
  assert follow_rule.after_scroll(Reading, 10, -80, Layout) == Following
  assert follow_rule.after_scroll(Reading, 0, 0, Steady) == Following
}

pub fn a_touch_within_the_window_makes_a_scroll_the_readers_test() {
  let same = Extent(1000.0, 500.0)
  let taller = Extent(1400.0, 500.0)

  assert follow_rule.origin(Some(1000), 1000, same, taller) == Input
  assert follow_rule.origin(
      Some(1000),
      1000 + follow_rule.touch_window,
      same,
      taller,
    )
    == Input
}

pub fn a_touch_that_has_expired_does_not_test() {
  let same = Extent(1000.0, 500.0)
  let taller = Extent(1400.0, 500.0)

  assert follow_rule.origin(
      Some(1000),
      1001 + follow_rule.touch_window,
      same,
      taller,
    )
    == Layout
  assert follow_rule.origin(
      Some(1000),
      1001 + follow_rule.touch_window,
      same,
      same,
    )
    == Steady
}

pub fn without_a_touch_the_size_says_whether_the_layout_moved_test() {
  let same = Extent(1000.0, 500.0)

  assert follow_rule.origin(None, 0, same, same) == Steady
  assert follow_rule.origin(None, 0, same, Extent(1400.0, 500.0)) == Layout
  assert follow_rule.origin(None, 0, same, Extent(1000.0, 400.0)) == Layout
}

pub fn gap_is_the_distance_from_the_view_to_the_content_end_test() {
  assert follow_rule.gap(1000.0, 400.0, 500.0) == 100
  assert follow_rule.gap(1000.0, 500.0, 500.0) == 0
}

pub fn gap_is_never_negative_test() {
  assert follow_rule.gap(1000.0, 501.0, 500.0) == 0
  assert follow_rule.gap(1000.0, 500.4, 500.0) == 0
}

pub fn gap_rounds_to_whole_pixels_test() {
  assert follow_rule.gap(1000.0, 499.6, 500.0) == 0
  assert follow_rule.gap(1000.0, 449.4, 500.0) == 51
}

pub fn moved_is_signed_and_whole_test() {
  assert follow_rule.moved(120.0, 100.0) == 20
  assert follow_rule.moved(80.0, 100.0) == -20
  assert follow_rule.moved(100.0, 100.0) == 0
  assert follow_rule.moved(100.4, 100.0) == 0
}

pub fn rows_added_while_following_keep_following_test() {
  // The size change scrolls to the bottom, and that scroll is reported after
  // yet more rows landed beneath it: a move down that ends away.
  let model =
    feed(at_the_bottom(), [
      Resize,
      Scroll(
        top: 1800.0,
        extent: Extent(content: 2600.0, view: 500.0),
        at: 1000,
      ),
    ])

  assert model.position == Following
  assert model.gap == 300
}

pub fn the_box_shrinking_while_following_keeps_following_test() {
  // A panel drawn in the dock takes 100 pixels from the transcript. The scroll
  // position is where it was; the bottom is 100 pixels further down. The
  // element scrolls there, and that scroll is a move down.
  let model =
    feed(at_the_bottom(), [
      Resize,
      Scroll(
        top: 1600.0,
        extent: Extent(content: 2000.0, view: 400.0),
        at: 1000,
      ),
    ])

  assert model.position == Following
  assert model.gap == 0
}

pub fn the_box_shrinking_as_rows_land_in_one_frame_keeps_following_test() {
  // The content shrinks, which pulls the scroll position up to fit, then
  // grows by more than it shrank while the box loses 100 pixels to a panel
  // in the dock. The scroll event for the pull is heard after all of it, so
  // it reads as a move up that ends far from the bottom. Nobody touched the
  // transcript, and its size is not the size the last scroll saw.
  let model =
    feed(at_the_bottom(), [
      Scroll(
        top: 1300.0,
        extent: Extent(content: 2400.0, view: 400.0),
        at: 1000,
      ),
    ])

  assert model.position == Following
  assert model.gap == 700
  assert model.top == 1300.0

  // The size change is then heard and the element scrolls to the bottom.
  let model =
    feed(model, [
      Resize,
      Scroll(
        top: 2000.0,
        extent: Extent(content: 2400.0, view: 400.0),
        at: 1016,
      ),
    ])

  assert model.position == Following
  assert model.gap == 0
}

pub fn a_layout_scroll_long_after_a_touch_does_not_leave_the_tail_test() {
  let model =
    feed(at_the_bottom(), [
      Touch(at: 0),
      Scroll(
        top: 1300.0,
        extent: Extent(content: 2400.0, view: 400.0),
        at: 5000,
      ),
    ])

  assert model.position == Following
}

pub fn the_reader_scrolling_up_leaves_the_tail_and_rows_do_not_pull_them_back_test() {
  let model =
    feed(at_the_bottom(), [
      Touch(at: 1000),
      Scroll(
        top: 1000.0,
        extent: Extent(content: 2000.0, view: 500.0),
        at: 1010,
      ),
    ])

  assert model.position == Reading
  assert model.gap == 500

  // Rows land: the transcript grows and is reported, and nothing brings the
  // reader back.
  let model =
    feed(model, [
      Resize,
      Measure(gap: 800),
      Scroll(
        top: 1000.0,
        extent: Extent(content: 2300.0, view: 500.0),
        at: 3000,
      ),
      Resize,
    ])

  assert model.position == Reading
}

pub fn the_reader_scrolling_up_by_key_or_scrollbar_leaves_the_tail_test() {
  // No wheel, finger or press was heard, and the transcript is the size it
  // was at the last scroll.
  let model =
    feed(at_the_bottom(), [
      Scroll(
        top: 1000.0,
        extent: Extent(content: 2000.0, view: 500.0),
        at: 9000,
      ),
    ])

  assert model.position == Reading
}

pub fn a_key_scroll_while_content_grows_leaves_the_tail_test() {
  // Page Up heard by the keydown listener stamps a touch, so the scroll is
  // the reader's although rows landing at the same time changed the extent.
  let model =
    feed(at_the_bottom(), [
      Touch(at: 8990),
      Scroll(
        top: 1000.0,
        extent: Extent(content: 2100.0, view: 500.0),
        at: 9000,
      ),
    ])

  assert model.position == Reading
}

pub fn a_scroll_with_no_input_while_content_grows_cannot_leave_the_tail_test() {
  // The remaining trade-off pinned: find-in-page, or a Firefox scrollbar drag
  // (no pointerdown there), raises none of the heard events, and rows landing
  // at the same time change the extent, so the scroll reads as the layout's.
  // The reader is not seen to leave until the growth stops.
  let growing =
    feed(at_the_bottom(), [
      Scroll(
        top: 1000.0,
        extent: Extent(content: 2100.0, view: 500.0),
        at: 9000,
      ),
    ])

  assert growing.position == Following

  // Once the transcript holds still, the same key scroll is the reader's.
  let still =
    feed(growing, [
      Scroll(top: 800.0, extent: Extent(content: 2100.0, view: 500.0), at: 9100),
    ])

  assert still.position == Reading
}

pub fn a_slow_scrollbar_drag_stays_the_readers_test() {
  // The press at the scrollbar, then a drag whose first scroll ends near the
  // bottom and whose next is heard later than one window after the press.
  // Each scroll the reader makes extends their touch.
  let model =
    feed(at_the_bottom(), [
      Touch(at: 0),
      Scroll(top: 1480.0, extent: Extent(content: 2000.0, view: 500.0), at: 400),
      Scroll(top: 1200.0, extent: Extent(content: 2100.0, view: 500.0), at: 800),
    ])

  assert model.position == Reading
}

pub fn the_reader_scrolling_back_to_the_bottom_follows_again_test() {
  let model =
    feed(at_the_bottom(), [
      Touch(at: 1000),
      Scroll(
        top: 1000.0,
        extent: Extent(content: 2000.0, view: 500.0),
        at: 1010,
      ),
      Touch(at: 2000),
      Scroll(
        top: 1480.0,
        extent: Extent(content: 2000.0, view: 500.0),
        at: 2010,
      ),
    ])

  assert model.position == Following
  assert model.gap == 20
}

pub fn the_jump_button_follows_again_from_anywhere_test() {
  let model =
    feed(at_the_bottom(), [
      Touch(at: 1000),
      Scroll(top: 200.0, extent: Extent(content: 2000.0, view: 500.0), at: 1010),
      Jump,
    ])

  assert model.position == Following
  assert model.gap == 0
}

pub fn a_fold_opened_by_the_reader_stops_the_follow_test() {
  assert feed(at_the_bottom(), [Fold]).position == Reading
}

pub fn pressing_load_older_stops_the_follow_and_the_rows_do_not_restart_it_test() {
  // The rows arrive above the reader: the transcript grows and the size
  // change is heard, and the browser may report a layout scroll. The reader
  // stays where they were, and the held row (not present without a page) is
  // what restores their place.
  let model =
    feed(at_the_bottom(), [
      Page,
      Resize,
      Scroll(
        top: 1500.0,
        extent: Extent(content: 3000.0, view: 500.0),
        at: 1000,
      ),
      Resize,
    ])

  assert model.position == Reading
}

pub fn a_held_row_still_first_keeps_waiting_test() {
  assert follow_rule.keeping(follow_rule.Leading, 80.0) == follow_rule.Waiting
}

pub fn a_displaced_row_is_put_back_by_how_far_it_moved_test() {
  assert follow_rule.keeping(follow_rule.Displaced(380.0), 80.0)
    == follow_rule.Restored(by: 300.0)
  assert follow_rule.keeping(follow_rule.Displaced(50.0), 80.0)
    == follow_rule.Restored(by: -30.0)
}

pub fn a_displaced_row_that_did_not_move_scrolls_nothing_test() {
  assert follow_rule.keeping(follow_rule.Displaced(80.0), 80.0)
    == follow_rule.Restored(by: 0.0)
}

pub fn a_row_that_left_the_page_releases_the_hold_test() {
  assert follow_rule.keeping(follow_rule.Detached, 80.0)
    == follow_rule.Restored(by: 0.0)
}

// The button is for a reader who is away from the bottom by more than a row:
// a reader one row up is still reading, and is not offered a jump over the
// row they are about to read.
pub fn the_jump_button_is_withheld_within_a_row_of_the_bottom_test() {
  assert follow_rule.jump(Reading, follow_rule.jump_gap + 1)
    == follow_rule.Offered
  assert follow_rule.jump(Reading, follow_rule.jump_gap) == follow_rule.Withheld
  assert follow_rule.jump(Reading, follow_rule.slack + 1)
    == follow_rule.Withheld
  assert follow_rule.jump(Following, 600) == follow_rule.Withheld
  assert follow_rule.jump_gap > follow_rule.slack
}

// The reader's place in each strand they leave is kept under the strand's
// numeric key, and put back when they return.

fn reading_at(top: Float) -> follow_rule.Reader {
  follow_rule.Reader(..at_the_bottom(), position: Reading, top: top, gap: 900)
}

pub fn a_strand_left_while_reading_resumes_at_its_offset_test() {
  let memory =
    follow_rule.leaving(follow_rule.forgotten(), 7, reading_at(420.0))
  assert follow_rule.arriving(memory, 7) == follow_rule.Resume(top: 420.0)
  let resumed = follow_rule.arrived(at_the_bottom(), follow_rule.Resume(420.0))
  assert resumed.position == Reading
  assert resumed.top == 420.0
}

pub fn a_strand_left_at_the_bottom_follows_the_tail_test() {
  let memory = follow_rule.leaving(follow_rule.forgotten(), 7, at_the_bottom())
  assert follow_rule.arriving(memory, 7) == follow_rule.Tail
  let followed = follow_rule.arrived(reading_at(420.0), follow_rule.Tail)
  assert followed.position == Following
  assert followed.gap == 0
}

pub fn a_strand_never_left_follows_the_tail_test() {
  let memory =
    follow_rule.leaving(follow_rule.forgotten(), 7, reading_at(420.0))
  assert follow_rule.arriving(memory, 8) == follow_rule.Tail
}

pub fn each_strand_keeps_its_own_place_and_the_latest_leaving_wins_test() {
  let memory =
    follow_rule.forgotten()
    |> follow_rule.leaving(7, reading_at(420.0))
    |> follow_rule.leaving(8, reading_at(90.0))
    |> follow_rule.leaving(7, reading_at(610.0))
  assert follow_rule.arriving(memory, 7) == follow_rule.Resume(top: 610.0)
  assert follow_rule.arriving(memory, 8) == follow_rule.Resume(top: 90.0)
}

// The decision a change of key makes, which the element then performs.

pub fn the_key_already_shown_changes_nothing_test() {
  assert follow_rule.keyed(
      Some(7),
      follow_rule.forgotten(),
      reading_at(420.0),
      7,
    )
    == follow_rule.Unchanged
}

pub fn the_first_key_follows_the_tail_and_saves_nothing_test() {
  let assert follow_rule.Changed(key:, memory:, reader:, arrival:) =
    follow_rule.keyed(None, follow_rule.forgotten(), at_the_bottom(), 7)
  assert key == 7
  assert memory == follow_rule.forgotten()
  assert reader.position == Following
  assert arrival == follow_rule.Tail
}

pub fn leaving_is_saved_before_arriving_test() {
  // Left while reading at 420, shown again: the place just saved is the one
  // the arrival resumes, so the departure is recorded before the lookup.
  let assert follow_rule.Changed(memory:, ..) =
    follow_rule.keyed(Some(7), follow_rule.forgotten(), reading_at(420.0), 8)
  assert follow_rule.arriving(memory, 7) == follow_rule.Resume(top: 420.0)

  let assert follow_rule.Changed(key:, reader:, arrival:, ..) =
    follow_rule.keyed(Some(8), memory, at_the_bottom(), 7)
  assert key == 7
  assert arrival == follow_rule.Resume(top: 420.0)
  assert reader.position == Reading
  assert reader.top == 420.0
}

pub fn a_strand_left_at_the_bottom_arrives_as_a_tail_test() {
  let assert follow_rule.Changed(memory:, ..) =
    follow_rule.keyed(Some(7), follow_rule.forgotten(), at_the_bottom(), 8)
  let assert follow_rule.Changed(arrival:, reader:, ..) =
    follow_rule.keyed(Some(8), memory, reading_at(90.0), 7)
  assert arrival == follow_rule.Tail
  assert reader.position == Following
}

// A send from the composer follows the tail again, as the button does: the
// reader who had scrolled up to read is `Following` after it.
pub fn a_send_returns_a_reader_to_the_tail_test() {
  assert follow_rule.jumped(reading_at(90.0)).position == Following
  assert follow_rule.sent_event == "loom-composer-sent"
}
