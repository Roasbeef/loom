//// The pinned transcript's follow rules: where the reader is after a scroll,
//// who moved it, how a gap and a move are measured, and what a held row asks
//// for once older rows have landed above it.
////
//// The sequence tests drive `follow.update` with the messages the page would
//// send and read the model back. Its effects (the scroll to the bottom, the
//// measuring) need a page and are not run here.

import gleam/list
import gleam/option.{None, Some}
import web_client/follow.{Extent, Following, Input, Layout, Reading, Steady}

// A transcript 2000 pixels tall in a 500 pixel view, scrolled to the bottom
// (1500 pixels down), with the reader having touched nothing.
fn at_the_bottom() -> follow.Model {
  follow.Model(
    position: Following,
    gap: 0,
    top: 1500.0,
    extent: Extent(content: 2000.0, view: 500.0),
    touched: None,
    watching: None,
    anchor: None,
  )
}

fn feed(model: follow.Model, messages: List(follow.Msg)) -> follow.Model {
  list.fold(messages, model, fn(model, message) {
    let #(model, _effects) = follow.update(model, message)
    model
  })
}

pub fn position_is_following_within_the_slack_test() {
  assert follow.position(0) == Following
  assert follow.position(follow.slack) == Following
  assert follow.position(follow.slack + 1) == Reading
}

pub fn a_scroll_up_by_the_reader_that_ends_away_leaves_the_tail_test() {
  assert follow.after_scroll(Following, 300, -80, Input) == Reading
  assert follow.after_scroll(Following, 300, -80, Steady) == Reading
}

pub fn a_scroll_up_by_the_layout_that_ends_away_does_not_test() {
  assert follow.after_scroll(Following, 300, -80, Layout) == Following
  assert follow.after_scroll(Reading, 300, -80, Layout) == Reading
}

pub fn a_scroll_down_that_ends_away_changes_nothing_test() {
  // It is the reader coming back, or the element's own scroll to the bottom
  // reported after more rows landed beneath it.
  assert follow.after_scroll(Following, 300, 80, Input) == Following
  assert follow.after_scroll(Following, 300, 80, Layout) == Following
  assert follow.after_scroll(Reading, 300, 80, Input) == Reading
  assert follow.after_scroll(Reading, 300, 0, Steady) == Reading
}

pub fn a_scroll_that_ends_at_the_bottom_follows_whoever_made_it_test() {
  assert follow.after_scroll(Reading, 10, 80, Input) == Following
  assert follow.after_scroll(Reading, 10, -80, Input) == Following
  assert follow.after_scroll(Reading, 10, -80, Layout) == Following
  assert follow.after_scroll(Reading, 0, 0, Steady) == Following
}

pub fn a_touch_within_the_window_makes_a_scroll_the_readers_test() {
  let same = Extent(1000.0, 500.0)
  let taller = Extent(1400.0, 500.0)

  assert follow.origin(Some(1000), 1000, same, taller) == Input
  assert follow.origin(Some(1000), 1000 + follow.touch_window, same, taller)
    == Input
}

pub fn a_touch_that_has_expired_does_not_test() {
  let same = Extent(1000.0, 500.0)
  let taller = Extent(1400.0, 500.0)

  assert follow.origin(Some(1000), 1001 + follow.touch_window, same, taller)
    == Layout
  assert follow.origin(Some(1000), 1001 + follow.touch_window, same, same)
    == Steady
}

pub fn without_a_touch_the_size_says_whether_the_layout_moved_test() {
  let same = Extent(1000.0, 500.0)

  assert follow.origin(None, 0, same, same) == Steady
  assert follow.origin(None, 0, same, Extent(1400.0, 500.0)) == Layout
  assert follow.origin(None, 0, same, Extent(1000.0, 400.0)) == Layout
}

pub fn gap_is_the_distance_from_the_view_to_the_content_end_test() {
  assert follow.gap(1000.0, 400.0, 500.0) == 100
  assert follow.gap(1000.0, 500.0, 500.0) == 0
}

pub fn gap_is_never_negative_test() {
  assert follow.gap(1000.0, 501.0, 500.0) == 0
  assert follow.gap(1000.0, 500.4, 500.0) == 0
}

pub fn gap_rounds_to_whole_pixels_test() {
  assert follow.gap(1000.0, 499.6, 500.0) == 0
  assert follow.gap(1000.0, 449.4, 500.0) == 51
}

pub fn moved_is_signed_and_whole_test() {
  assert follow.moved(120.0, 100.0) == 20
  assert follow.moved(80.0, 100.0) == -20
  assert follow.moved(100.0, 100.0) == 0
  assert follow.moved(100.4, 100.0) == 0
}

pub fn rows_added_while_following_keep_following_test() {
  // The size change scrolls to the bottom, and that scroll is reported after
  // yet more rows landed beneath it: a move down that ends away.
  let model =
    feed(at_the_bottom(), [
      follow.Resized,
      follow.Scrolled(
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
      follow.Resized,
      follow.Scrolled(
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
      follow.Scrolled(
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
      follow.Resized,
      follow.Scrolled(
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
      follow.Touched(at: 0),
      follow.Scrolled(
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
      follow.Touched(at: 1000),
      follow.Scrolled(
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
      follow.Resized,
      follow.Measured(gap: 800),
      follow.Scrolled(
        top: 1000.0,
        extent: Extent(content: 2300.0, view: 500.0),
        at: 3000,
      ),
      follow.Resized,
    ])

  assert model.position == Reading
}

pub fn the_reader_scrolling_up_by_key_or_scrollbar_leaves_the_tail_test() {
  // No wheel, finger or press was heard, and the transcript is the size it
  // was at the last scroll.
  let model =
    feed(at_the_bottom(), [
      follow.Scrolled(
        top: 1000.0,
        extent: Extent(content: 2000.0, view: 500.0),
        at: 9000,
      ),
    ])

  assert model.position == Reading
}

pub fn a_slow_scrollbar_drag_stays_the_readers_test() {
  // The press at the scrollbar, then a drag whose first scroll ends near the
  // bottom and whose next is heard later than one window after the press.
  // Each scroll the reader makes extends their touch.
  let model =
    feed(at_the_bottom(), [
      follow.Touched(at: 0),
      follow.Scrolled(
        top: 1480.0,
        extent: Extent(content: 2000.0, view: 500.0),
        at: 400,
      ),
      follow.Scrolled(
        top: 1200.0,
        extent: Extent(content: 2100.0, view: 500.0),
        at: 800,
      ),
    ])

  assert model.position == Reading
}

pub fn the_reader_scrolling_back_to_the_bottom_follows_again_test() {
  let model =
    feed(at_the_bottom(), [
      follow.Touched(at: 1000),
      follow.Scrolled(
        top: 1000.0,
        extent: Extent(content: 2000.0, view: 500.0),
        at: 1010,
      ),
      follow.Touched(at: 2000),
      follow.Scrolled(
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
      follow.Touched(at: 1000),
      follow.Scrolled(
        top: 200.0,
        extent: Extent(content: 2000.0, view: 500.0),
        at: 1010,
      ),
      follow.Jumped,
    ])

  assert model.position == Following
  assert model.gap == 0
  assert model.anchor == None
}

pub fn a_fold_opened_by_the_reader_stops_the_follow_test() {
  assert feed(at_the_bottom(), [follow.Folded]).position == Reading
}

pub fn pressing_load_older_stops_the_follow_and_the_rows_do_not_restart_it_test() {
  // The rows arrive above the reader: the transcript grows and the size
  // change is heard, and the browser may report a layout scroll. The reader
  // stays where they were, and the held row (not present without a page) is
  // what restores their place.
  let model =
    feed(at_the_bottom(), [
      follow.Paged,
      follow.Resized,
      follow.Scrolled(
        top: 1500.0,
        extent: Extent(content: 3000.0, view: 500.0),
        at: 1000,
      ),
      follow.Resized,
    ])

  assert model.position == Reading
}

pub fn a_held_row_still_first_keeps_waiting_test() {
  assert follow.keeping(follow.Leading, 80.0) == follow.Waiting
}

pub fn a_displaced_row_is_put_back_by_how_far_it_moved_test() {
  assert follow.keeping(follow.Displaced(380.0), 80.0)
    == follow.Restored(by: 300.0)
  assert follow.keeping(follow.Displaced(50.0), 80.0)
    == follow.Restored(by: -30.0)
}

pub fn a_displaced_row_that_did_not_move_scrolls_nothing_test() {
  assert follow.keeping(follow.Displaced(80.0), 80.0)
    == follow.Restored(by: 0.0)
}

pub fn a_row_that_left_the_page_releases_the_hold_test() {
  assert follow.keeping(follow.Detached, 80.0) == follow.Restored(by: 0.0)
}
