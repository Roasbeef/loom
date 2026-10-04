//// What `<loom-shell>` decides (`web_client/shell_rule`): which side columns
//// are open, which tab the panel shows, what each button and tab says, and
//// what a closed column lets the keyboard reach.

import gleam/list
import gleam/option.{None, Some}
import web_client/shell_rule.{
  Changes, Closed, Layout, Listed, Open, Panel, Reachable, Session, Sidebar,
  Strands, Trace, Unlisted, Unreachable,
}

pub fn a_page_starts_with_both_columns_open_on_the_strands_tab_test() {
  assert shell_rule.initial()
    == Layout(sidebar: Open, panel: Open, tab: Strands)
  assert shell_rule.state(shell_rule.initial(), Sidebar) == Open
  assert shell_rule.state(shell_rule.initial(), Panel) == Open
}

// A button changes its own column and leaves the other as it was, in either
// order, and pressing it again puts the column back.
pub fn each_button_moves_only_its_own_column_test() {
  let sidebar_closed = shell_rule.toggled(shell_rule.initial(), Sidebar)
  assert sidebar_closed == Layout(sidebar: Closed, panel: Open, tab: Strands)

  let both_closed = shell_rule.toggled(sidebar_closed, Panel)
  assert both_closed == Layout(sidebar: Closed, panel: Closed, tab: Strands)

  let other_order =
    shell_rule.toggled(shell_rule.toggled(shell_rule.initial(), Panel), Sidebar)
  assert other_order == both_closed

  assert shell_rule.toggled(both_closed, Sidebar)
    == Layout(sidebar: Open, panel: Closed, tab: Strands)
  assert shell_rule.toggled(shell_rule.toggled(both_closed, Panel), Panel)
    == both_closed
}

// The rule the design states for a hidden column: its content is not
// reachable by the keyboard. It follows the state alone, so no layout can
// hold a closed column that a key can reach.
pub fn a_closed_column_cannot_be_reached_and_an_open_one_can_test() {
  assert shell_rule.reach(Closed) == Unreachable
  assert shell_rule.reach(Open) == Reachable
}

// The frame starts still, so the layout restored from storage is drawn
// without the width transition, and carries no `still` class once the
// restore has been painted and motion is on.
pub fn the_frame_is_still_until_the_restore_is_drawn_test() {
  assert shell_rule.frame_classes(shell_rule.Still) == ["shell", "still"]
  assert shell_rule.frame_classes(shell_rule.Animated) == ["shell"]
}

pub fn each_button_says_what_pressing_it_does_test() {
  assert shell_rule.label(Sidebar, Open) == "Hide sessions"
  assert shell_rule.label(Sidebar, Closed) == "Show sessions"
  assert shell_rule.label(Panel, Open) == "Hide strands"
  assert shell_rule.label(Panel, Closed) == "Show strands"
}

// An observer's page has no sidebar, so its bar has no button for one; the
// strand panel's button is there either way.
pub fn a_page_without_a_sidebar_has_no_button_for_one_test() {
  assert shell_rule.has_button(Listed, Sidebar)
  assert !shell_rule.has_button(Unlisted, Sidebar)
  assert shell_rule.has_button(Listed, Panel)
  assert shell_rule.has_button(Unlisted, Panel)
}

// The server writes `listed` or `none`. Decoding is total: whatever else
// arrives, or nothing, is a page with no sidebar.
pub fn the_sidebar_attribute_decodes_totally_test() {
  assert shell_rule.presence("listed") == Listed
  assert shell_rule.presence("none") == Unlisted
  assert shell_rule.presence("") == Unlisted
  assert shell_rule.presence("Listed") == Unlisted
  assert shell_rule.presence(" listed") == Unlisted
  assert shell_rule.presence("listed listed") == Unlisted
  assert shell_rule.presence("<b>") == Unlisted
}

// Pressing a tab shows that tab and moves nothing else: the columns keep
// their state, in either state, and pressing the shown tab again changes
// nothing.
pub fn a_tab_changes_only_the_tab_shown_test() {
  let layout = shell_rule.chosen(shell_rule.initial(), Changes)
  assert layout == Layout(sidebar: Open, panel: Open, tab: Changes)
  assert shell_rule.chosen(layout, Changes) == layout
  assert shell_rule.chosen(layout, Session).tab == Session
  assert shell_rule.chosen(layout, Strands) == shell_rule.initial()

  let closed = shell_rule.toggled(shell_rule.initial(), Panel)
  assert shell_rule.chosen(closed, Session)
    == Layout(sidebar: Open, panel: Closed, tab: Session)
}

// A column's button does not change the tab, so a panel closed and opened
// again comes back on the tab it left.
pub fn closing_and_opening_the_panel_keeps_the_tab_test() {
  let layout = shell_rule.chosen(shell_rule.initial(), Session)
  let reopened =
    layout
    |> shell_rule.toggled(Panel)
    |> shell_rule.toggled(Panel)
  assert reopened == layout
  assert shell_rule.toggled(layout, Sidebar).tab == Session
}

pub fn the_tabs_are_drawn_in_a_fixed_order_with_fixed_words_test() {
  assert shell_rule.tabs() == [Strands, Changes, Trace, Session]
  assert shell_rule.tab_label(Strands) == "Strands"
  assert shell_rule.tab_label(Changes) == "Changes"
  assert shell_rule.tab_label(Trace) == "Trace"
  assert shell_rule.tab_label(Session) == "Session"
}

// The stylesheet spells these states, so each is a fixed literal that no tab
// shares with another.
pub fn each_tab_has_its_own_custom_state_test() {
  assert shell_rule.tab_state(Strands) == "tab-strands"
  assert shell_rule.tab_state(Changes) == "tab-changes"
  assert shell_rule.tab_state(Session) == "tab-session"
  assert shell_rule.tab_state(Trace) == "tab-trace"
}

// The badge count is the server's number. Decoding is total: a value that is
// not a plain, short, non-negative number is none, whatever else it holds.
pub fn the_needing_attribute_decodes_totally_test() {
  assert shell_rule.needing("0") == 0
  assert shell_rule.needing("3") == 3
  assert shell_rule.needing("12") == 12
  assert shell_rule.needing("9999") == 9999
  assert shell_rule.needing("") == 0
  assert shell_rule.needing("-1") == 0
  assert shell_rule.needing("+2") == 0
  assert shell_rule.needing("1.5") == 0
  assert shell_rule.needing("2 ") == 0
  assert shell_rule.needing("99999") == 0
  assert shell_rule.needing("<b>2</b>") == 0
  assert shell_rule.needing("1e3") == 0
}

pub fn the_badge_shows_a_count_up_to_nine_and_nothing_for_none_test() {
  assert shell_rule.badge(0) == None
  assert shell_rule.badge(-3) == None
  assert shell_rule.badge(1) == Some("1")
  assert shell_rule.badge(9) == Some("9")
  assert shell_rule.badge(10) == Some("9+")
  assert shell_rule.badge(9999) == Some("9+")
}

// The number is not read by a screen reader from the badge, which is
// decoration, so the tab's own label says it.
pub fn the_strands_tab_names_how_many_strands_wait_test() {
  assert shell_rule.strands_words(0) == "Strands"
  assert shell_rule.strands_words(1) == "Strands, 1 needs approval"
  assert shell_rule.strands_words(2) == "Strands, 2 need approval"
  assert shell_rule.strands_words(-1) == "Strands"
}

// The marker on a control with no handler is the server's number, a card's
// position. Decoding is total: whatever else it holds is no request, so a
// control that says something else does nothing.
pub fn a_strand_marker_decodes_totally_test() {
  assert shell_rule.relay("0") == Ok(shell_rule.Relay(0, shell_rule.Keep))
  assert shell_rule.relay("1") == Ok(shell_rule.Relay(1, shell_rule.Show))
  assert shell_rule.relay("12") == Ok(shell_rule.Relay(12, shell_rule.Show))
  assert shell_rule.relay("999") == Ok(shell_rule.Relay(999, shell_rule.Show))
  assert shell_rule.relay("007") == Ok(shell_rule.Relay(7, shell_rule.Show))
  assert shell_rule.relay("") == Error(Nil)
  assert shell_rule.relay("1000") == Error(Nil)
  assert shell_rule.relay("-1") == Error(Nil)
  assert shell_rule.relay("+1") == Error(Nil)
  assert shell_rule.relay("1.0") == Error(Nil)
  assert shell_rule.relay(" 1") == Error(Nil)
  assert shell_rule.relay("main") == Error(Nil)
  assert shell_rule.relay("sub:tests") == Error(Nil)
  assert shell_rule.relay("<b>1</b>") == Error(Nil)
  assert shell_rule.relay("1\n2") == Error(Nil)
}

// A click on a strand shows the panel on the Strands tab wherever the reader
// left it, and leaves the sidebar alone, in either state.
pub fn a_relayed_strand_click_shows_the_strands_tab_test() {
  let away =
    shell_rule.initial()
    |> shell_rule.toggled(Panel)
    |> shell_rule.toggled(Sidebar)
    |> shell_rule.chosen(Session)
  assert away == Layout(sidebar: Closed, panel: Closed, tab: Session)

  let shown = shell_rule.relayed(away, shell_rule.Relay(2, shell_rule.Show))
  assert shown == Layout(sidebar: Closed, panel: Open, tab: Strands)

  // Already showing: nothing moves.
  assert shell_rule.relayed(
      shell_rule.initial(),
      shell_rule.Relay(2, shell_rule.Show),
    )
    == shell_rule.initial()
}

// `All strands` is a relay of position zero: it presses `main`'s card and does
// not reopen a panel the reader closed, or leave the tab they chose.
pub fn all_strands_leaves_the_layout_as_it_is_test() {
  let away =
    shell_rule.initial()
    |> shell_rule.toggled(Panel)
    |> shell_rule.chosen(Changes)
  let assert Ok(relay) = shell_rule.relay("0")
  assert shell_rule.relayed(away, relay) == away
}

// The card pressed is found by the server's fixed attribute and the number
// alone.
pub fn a_card_is_named_by_its_position_test() {
  assert shell_rule.card_selector(0) == "[data-loom-card=\"0\"]"
  assert shell_rule.card_selector(14) == "[data-loom-card=\"14\"]"
}

// --- the keyboard ---------------------------------------------------------

const free =
  shell_rule.Modifiers(
    meta: shell_rule.Free,
    ctrl: shell_rule.Free,
    alt: shell_rule.Free,
    shift: shell_rule.Free,
  )

// A keystroke pressed with nothing else going on, in the page and not in
// the composer or an approval card, with no input method composing.
fn stroke(
  key: String,
  code: String,
  modifiers: shell_rule.Modifiers,
) -> shell_rule.Keystroke {
  shell_rule.Keystroke(
    key:,
    code:,
    modifiers:,
    target: shell_rule.Elsewhere,
    composition: shell_rule.Settled,
    prevention: shell_rule.Unhandled,
    repetition: shell_rule.Fresh,
  )
}

fn command() -> shell_rule.Modifiers {
  shell_rule.Modifiers(..free, meta: shell_rule.Held)
}

fn control() -> shell_rule.Modifiers {
  shell_rule.Modifiers(..free, ctrl: shell_rule.Held)
}

fn command_alt() -> shell_rule.Modifiers {
  shell_rule.Modifiers(..free, meta: shell_rule.Held, alt: shell_rule.Held)
}

fn control_alt() -> shell_rule.Modifiers {
  shell_rule.Modifiers(..free, ctrl: shell_rule.Held, alt: shell_rule.Held)
}

// The key set is exactly three, and the two toggles are read from `code`:
// Option changes `key` on a Mac, so the letter is the physical key.
pub fn the_key_set_is_exactly_three_test() {
  let intent = fn(stroke) { shell_rule.intent(stroke, Listed) }

  assert intent(stroke("b", "KeyB", command()))
    == Some(shell_rule.ToggleSidebar)
  assert intent(stroke("b", "KeyB", control()))
    == Some(shell_rule.ToggleSidebar)
  assert intent(stroke("∫", "KeyB", command_alt()))
    == Some(shell_rule.TogglePanel)
  assert intent(stroke("b", "KeyB", control_alt()))
    == Some(shell_rule.TogglePanel)
  assert intent(stroke("Escape", "Escape", free))
    == Some(shell_rule.LeaveStrand)

  // The toggles are read by the physical key, not by what it typed, so a
  // layout where `KeyB` types another letter still toggles and a `b` typed
  // from another key does not.
  assert intent(stroke("x", "KeyB", command()))
    == Some(shell_rule.ToggleSidebar)
  assert intent(stroke("b", "KeyN", command())) == None
}

// Any other key is not read, whatever the modifiers: the listener never acts
// on a key outside the set, and the candidate test drops it before the target
// is looked at.
pub fn any_other_key_is_not_read_test() {
  let others = [
    #("a", "KeyA"),
    #("Enter", "Enter"),
    #("Tab", "Tab"),
    #("ArrowLeft", "ArrowLeft"),
    #(" ", "Space"),
    #("Delete", "Delete"),
    #("F5", "F5"),
    #("B", "KeyC"),
    #("]", "BracketRight"),
  ]
  list.each(others, fn(pair) {
    let #(key, code) = pair
    assert !shell_rule.candidate(key, code)
    list.each([free, command(), control(), command_alt(), control_alt()], fn(m) {
      assert shell_rule.intent(stroke(key, code, m), Listed) == None
    })
  })
  assert shell_rule.candidate("Escape", "Escape")
  assert shell_rule.candidate("b", "KeyB")
  assert shell_rule.candidate("∫", "KeyB")
}

// The exact modifier sets: `B` alone is a letter, Shift is never part of a
// shortcut, and `Escape` with any modifier is not the shortcut.
pub fn the_modifiers_are_exact_test() {
  let intent = fn(stroke) { shell_rule.intent(stroke, Listed) }
  let shift = shell_rule.Modifiers(..free, shift: shell_rule.Held)
  let alt_only = shell_rule.Modifiers(..free, alt: shell_rule.Held)
  let command_shift = shell_rule.Modifiers(..command(), shift: shell_rule.Held)
  let command_alt_shift =
    shell_rule.Modifiers(..command_alt(), shift: shell_rule.Held)
  let both = shell_rule.Modifiers(..command(), ctrl: shell_rule.Held)

  assert intent(stroke("b", "KeyB", free)) == None
  assert intent(stroke("B", "KeyB", shift)) == None
  assert intent(stroke("b", "KeyB", alt_only)) == None
  assert intent(stroke("b", "KeyB", command_shift)) == None
  assert intent(stroke("b", "KeyB", command_alt_shift)) == None
  assert intent(stroke("b", "KeyB", both)) == Some(shell_rule.ToggleSidebar)

  assert intent(stroke("Escape", "Escape", shift)) == None
  assert intent(stroke("Escape", "Escape", command())) == None
  assert intent(stroke("Escape", "Escape", alt_only)) == None
  assert intent(stroke("Escape", "Escape", control())) == None
}

// Not while an input method is composing, when the event's default was
// already cancelled, or while a held key repeats: for every key of the set.
pub fn a_key_does_nothing_while_composing_prevented_or_repeating_test() {
  let keys = [
    stroke("b", "KeyB", command()),
    stroke("b", "KeyB", command_alt()),
    stroke("Escape", "Escape", free),
  ]
  list.each(keys, fn(base) {
    assert shell_rule.intent(base, Listed) != None
    assert shell_rule.intent(
        shell_rule.Keystroke(..base, composition: shell_rule.Composing),
        Listed,
      )
      == None
    assert shell_rule.intent(
        shell_rule.Keystroke(..base, prevention: shell_rule.Prevented),
        Listed,
      )
      == None
    assert shell_rule.intent(
        shell_rule.Keystroke(..base, repetition: shell_rule.Repeating),
        Listed,
      )
      == None
  })
}

// Inside the approval cards' region no key acts: none of the three, in any
// modifier set. This is the rule that no key may decide an approval, and no
// key may reach one through the shell either: nothing happens there at all.
pub fn no_key_acts_inside_an_approval_card_test() {
  let keys = [
    stroke("b", "KeyB", command()),
    stroke("b", "KeyB", control()),
    stroke("b", "KeyB", command_alt()),
    stroke("b", "KeyB", control_alt()),
    stroke("Escape", "Escape", free),
    stroke("Enter", "Enter", free),
    stroke("y", "KeyY", free),
    stroke(" ", "Space", free),
  ]
  list.each(keys, fn(base) {
    assert shell_rule.intent(
        shell_rule.Keystroke(..base, target: shell_rule.Approvals),
        Listed,
      )
      == None
    assert shell_rule.intent(
        shell_rule.Keystroke(..base, target: shell_rule.Approvals),
        Unlisted,
      )
      == None
  })
}

// `Escape` in the composer never changes the focus of a draft, so a person
// typing and closing a list does not leave the strand they are addressing;
// the two toggles act there, since `B` with a command key means nothing in a
// plain text field.
pub fn escape_in_the_composer_is_the_composers_and_the_toggles_are_not_test() {
  let in_editor = fn(base) {
    shell_rule.Keystroke(..base, target: shell_rule.Editor)
  }
  assert shell_rule.intent(in_editor(stroke("Escape", "Escape", free)), Listed)
    == None
  assert shell_rule.intent(in_editor(stroke("b", "KeyB", command())), Listed)
    == Some(shell_rule.ToggleSidebar)
  assert shell_rule.intent(
      in_editor(stroke("b", "KeyB", command_alt())),
      Listed,
    )
    == Some(shell_rule.TogglePanel)
}

// An observer's page has no sidebar, so its shortcut has nothing to toggle
// and is not taken: the browser keeps its own `Ctrl+B`.
pub fn the_sidebar_shortcut_needs_a_sidebar_test() {
  assert shell_rule.intent(stroke("b", "KeyB", command()), Unlisted) == None
  assert shell_rule.intent(stroke("b", "KeyB", command_alt()), Unlisted)
    == Some(shell_rule.TogglePanel)
  assert shell_rule.intent(stroke("Escape", "Escape", free), Unlisted)
    == Some(shell_rule.LeaveStrand)
}

// A key it takes as a toggle has its browser action cancelled, since the
// browser binds the toggles to bookmarks and the like; `Escape` is left alone.
pub fn the_toggles_cancel_the_browsers_action_and_escape_does_not_test() {
  assert shell_rule.cancels(shell_rule.ToggleSidebar) == shell_rule.Cancelled
  assert shell_rule.cancels(shell_rule.TogglePanel) == shell_rule.Cancelled
  assert shell_rule.cancels(shell_rule.LeaveStrand) == shell_rule.Untouched
}

// The intents are the three the page has and none of them names anything the
// session can act on: the rule's whole output is a change of layout or a press
// of the breadcrumb's link. There is no intent that decides, sends or focuses.
pub fn every_intent_is_a_layout_change_or_the_breadcrumb_test() {
  let all = [
    shell_rule.ToggleSidebar,
    shell_rule.TogglePanel,
    shell_rule.LeaveStrand,
  ]
  let taken =
    [
      stroke("b", "KeyB", command()),
      stroke("b", "KeyB", command_alt()),
      stroke("Escape", "Escape", free),
    ]
    |> list.filter_map(fn(base) {
      option.to_result(shell_rule.intent(base, Listed), Nil)
    })
  assert taken == all
}

// The buttons name their shortcuts beside what pressing them does.
pub fn the_toggles_name_their_shortcuts_test() {
  assert shell_rule.title(Sidebar, Open)
    == "Hide sessions (Command or Control B)"
  assert shell_rule.title(Panel, Closed)
    == "Show strands (Command or Control Alt B)"
  assert shell_rule.shortcuts(Sidebar) == "Meta+B Control+B"
  assert shell_rule.shortcuts(Panel) == "Meta+Alt+B Control+Alt+B"
  assert shell_rule.hint(Sidebar) == "⌘B"
  assert shell_rule.hint(Panel) == "⌘⌥B"
}

// `Escape` clicks the link a pointer clicks, which the server draws only
// while a strand other than `main` is in focus.
pub fn escape_clicks_the_breadcrumbs_link_test() {
  assert shell_rule.crumb_link() == "[data-loom-crumb] [data-loom-focus]"
}

// --- where a key was pressed, from the event's composed path ---------------

fn node(tag: String) -> shell_rule.Step {
  shell_rule.Step(
    tag:,
    approvals: shell_rule.Unmarked,
    editing: shell_rule.Fixed,
  )
}

fn region() -> shell_rule.Step {
  shell_rule.Step(..node("section"), approvals: shell_rule.Marked)
}

// The document's listener sees the target retargeted to the outermost shadow
// host, so the rule reads the whole path: from the focused node outward,
// through shadow roots (which have no tag), up to the window.
pub fn a_path_through_the_approval_region_is_approvals_test() {
  // A card's button, its card, the region, then the dock and the page.
  let path = [
    node("button"),
    node("article"),
    region(),
    node("footer"),
    node("main"),
    node("loom-shell"),
    node(""),
    node("body"),
    node("html"),
    node(""),
  ]
  assert shell_rule.target(path) == shell_rule.Approvals
}

// The region wins over anything that would make the path an editor: a
// textarea inside a card is still inside the region, where no key acts.
pub fn the_approval_region_wins_over_an_editor_test() {
  assert shell_rule.target([node("textarea"), region(), node("body")])
    == shell_rule.Approvals
  assert shell_rule.target([region(), node("loom-composer")])
    == shell_rule.Approvals
}

// A path through the composer's shadow root: the focused node is inside the
// composer's own tree, shadow roots in the path have no tag, and the
// composer's tag is further out.
pub fn a_path_through_the_composers_shadow_root_is_the_editor_test() {
  let path = [
    node("li"),
    node("ul"),
    node(""),
    node("loom-composer"),
    node("form"),
    node("footer"),
    node("body"),
  ]
  assert shell_rule.target(path) == shell_rule.Editor

  // The editor slotted into the composer, seen from its textarea.
  assert shell_rule.target([
      node("textarea"),
      node("loom-composer"),
      node("form"),
    ])
    == shell_rule.Editor
}

// A field that takes text is the editor wherever it is: the Fork and Set goal
// forms are not the composer, and what is typed in them is theirs.
pub fn a_text_field_anywhere_is_the_editor_test() {
  list.each(["input", "textarea", "select"], fn(tag) {
    assert shell_rule.target([node(tag), node("form"), node("details")])
      == shell_rule.Editor
  })
}

// An element whose text can be edited is the editor whatever its tag.
pub fn editable_text_anywhere_is_the_editor_test() {
  let editable = shell_rule.Step(..node("div"), editing: shell_rule.Editable)
  assert shell_rule.target([editable, node("main"), node("body")])
    == shell_rule.Editor
}

// Focus on `body`, the page's usual state, is neither: the shortcuts act. So
// is a click's leftovers on a span, a button, or no path at all.
pub fn body_and_the_rest_of_the_page_are_elsewhere_test() {
  assert shell_rule.target([node("body"), node("html"), node("")])
    == shell_rule.Elsewhere
  assert shell_rule.target([node("span"), node("button"), node("aside")])
    == shell_rule.Elsewhere
  assert shell_rule.target([]) == shell_rule.Elsewhere
}

// The rule's answer feeds the intent: on `body` the toggles act, in a field
// `Escape` does not, and in the region nothing does.
pub fn the_path_decides_what_a_key_does_test() {
  let with = fn(path, base: shell_rule.Keystroke) {
    shell_rule.Keystroke(..base, target: shell_rule.target(path))
  }
  let toggle = stroke("b", "KeyB", command())
  let escape = stroke("Escape", "Escape", free)

  assert shell_rule.intent(with([node("body")], toggle), Listed)
    == Some(shell_rule.ToggleSidebar)
  assert shell_rule.intent(with([node("body")], escape), Listed)
    == Some(shell_rule.LeaveStrand)

  assert shell_rule.intent(with([node("input"), node("body")], escape), Listed)
    == None
  assert shell_rule.intent(with([node("input"), node("body")], toggle), Listed)
    == Some(shell_rule.ToggleSidebar)

  assert shell_rule.intent(with([node("button"), region()], toggle), Listed)
    == None
  assert shell_rule.intent(with([node("button"), region()], escape), Listed)
    == None
}

// A wide page's sidebar is the saved column, and a narrow page's is the
// drawer; the saved layout never shows through on a narrow page, so a column
// saved as closed does not close the drawer, and a saved-open column does not
// open it.
pub fn the_sidebar_follows_the_layout_when_wide_and_the_drawer_when_narrow_test() {
  let saved_open = shell_rule.initial()
  let saved_closed = shell_rule.toggled(saved_open, Sidebar)

  assert shell_rule.sidebar_state(saved_open, shell_rule.Wide, Closed) == Open
  assert shell_rule.sidebar_state(saved_closed, shell_rule.Wide, Open) == Closed
  assert shell_rule.sidebar_state(saved_open, shell_rule.Narrow, Closed)
    == Closed
  assert shell_rule.sidebar_state(saved_closed, shell_rule.Narrow, Open) == Open
}

// The press that hides the column on a wide page opens the drawer on a narrow
// one, and the layout, which is what is saved, comes back unchanged from it.
// A wide page's press leaves the drawer as it was.
pub fn a_narrow_press_moves_only_the_drawer_and_a_wide_press_only_the_layout_test() {
  let layout = shell_rule.initial()

  let #(after, drawer) =
    shell_rule.sidebar_pressed(layout, shell_rule.Narrow, Closed)
  assert after == layout
  assert drawer == Open

  let #(closed_again, drawer) =
    shell_rule.sidebar_pressed(after, shell_rule.Narrow, drawer)
  assert closed_again == layout
  assert drawer == Closed

  let #(after, drawer) =
    shell_rule.sidebar_pressed(layout, shell_rule.Wide, Closed)
  assert after == Layout(sidebar: Closed, panel: Open, tab: Strands)
  assert drawer == Closed
}

// `Escape` closes the drawer first and leaves the strand only when there is
// none to close; a wide page has no drawer, whatever state a stale one holds.
pub fn escape_closes_an_open_drawer_before_it_leaves_a_strand_test() {
  assert shell_rule.dismissal(shell_rule.Narrow, Open) == shell_rule.Dismiss
  assert shell_rule.dismissal(shell_rule.Narrow, Closed) == shell_rule.Leave
  assert shell_rule.dismissal(shell_rule.Wide, Open) == shell_rule.Leave
  assert shell_rule.dismissal(shell_rule.Wide, Closed) == shell_rule.Leave
}

// The scrim is drawn for exactly the states in which `Escape` dismisses.
pub fn the_scrim_is_drawn_only_behind_an_open_drawer_test() {
  assert shell_rule.scrimmed(shell_rule.Narrow, Open)
  assert !shell_rule.scrimmed(shell_rule.Narrow, Closed)
  assert !shell_rule.scrimmed(shell_rule.Wide, Open)
  assert !shell_rule.scrimmed(shell_rule.Wide, Closed)
}

// A press on a row closes the drawer wherever in the row it lands, since the
// click's path holds the row's button; a click on a heading or the padding
// does not.
pub fn a_press_on_a_button_in_the_sidebar_closes_the_drawer_test() {
  assert shell_rule.presses_button(["span", "button", "li", "ul", "aside"])
  assert shell_rule.presses_button(["button"])
  assert !shell_rule.presses_button(["h2", "section", "aside"])
  assert !shell_rule.presses_button([])
}

// The listener's query and the stylesheet's breakpoint are the same number:
// 1212 px is where a sidebar, a 340 px panel and a 640 px transcript fit.
pub fn the_narrow_query_is_the_stylesheets_breakpoint_test() {
  assert shell_rule.narrow_query() == "(max-width: 1211px)"
}
