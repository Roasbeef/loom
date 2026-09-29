//// `<loom-shell sidebar="listed" needing="0">`: the page's frame, with a
//// button at each end of the top bar that hides or shows a side column, and
//// the tabs of the strand panel.
////
//// The server draws the regions (`web_view/view/shell`) as this element's
//// light-DOM children, each in a slot: `bar` for the top bar, `left` for the
//// sessions sidebar, `right` for the strand panel, and the centre in the
//// default slot. The shadow root here lays them out and draws the two
//// buttons and the panel's tab bar. Which columns are open, and which tab
//// the panel shows, are the reader's preference and nothing the server
//// holds, so the server never renders them and a patch leaves the reader's
//// choice alone, as it does a fold's. A hidden column is drawn by the server
//// all the same, because the server does not know, so the column's wrapper
//// is what makes it inert: it takes no width, is not painted, and is out of
//// the tab order (`shell_rule.reach`), so the keyboard never lands on a
//// control the reader cannot see.
////
//// The panel's panes are the server's children of the `right` slot: one
//// section for each tab, all of them drawn. The element shows one by
//// setting a custom state on itself, `tab-strands`, `tab-changes` or
//// `tab-session` (Lustre's `component.set_pseudo_state`), which the
//// stylesheet reads to hide the other panes (`loom-shell:state(tab-changes)`).
//// A hidden pane is `display: none`, so its controls leave the tab order. A
//// browser without custom states shows every pane, stacked, which is
//// readable and loses nothing.
////
//// The attributes are fixed words and numbers the server writes: `sidebar`
//// is `listed` or `none`, saying whether the page has a sidebar, and
//// `needing` is how many strands wait on a decision, the number on the
//// Strands tab. An observer's page has no sidebar, and the bar draws no
//// button for it. The element renders no session text, handles no key, takes
//// no focus, and sends the server nothing. Its buttons and tabs are real
//// buttons, so a keyboard presses them as it presses any button.
////
//// The element wraps the dock, and so holds an approval card in its
//// subtree, as `<loom-follow>` holds the lane. That is a fact about the
//// tree and not about behaviour: the element listens for no key and no
//// event beyond its own buttons' clicks, and it never moves focus. Nothing
//// it does can decide, or hide, an approval: the dock is in the centre
//// column, which has no button, and the panel carries no decision control.

import gleam/list
import gleam/option.{Some}
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_client/shell_rule.{type Layout, type Presence, type Region, type Tab}

/// The element's tag.
pub const name = "loom-shell"

/// What the element knows: which columns are open and which tab shows,
/// whether the page has a sidebar, and how many strands wait on a decision.
pub type Model {
  Model(layout: Layout, sidebar: Presence, needing: Int)
}

/// Everything the element can be told.
pub type Msg {
  /// The reader pressed a column's button.
  Toggled(region: Region)

  /// The reader pressed a tab.
  Chosen(tab: Tab)

  /// The server set the `sidebar` attribute.
  SidebarChanged(presence: Presence)

  /// The server set the `needing` attribute.
  NeedingChanged(count: Int)
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = shell.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("sidebar", sidebar),
    component.on_attribute_change("needing", needing),
  ])
  |> lustre.register(name)
}

// The attribute's word decoded totally: anything but `listed` is no sidebar.
fn sidebar(value: String) -> Result(Msg, Nil) {
  Ok(SidebarChanged(shell_rule.presence(value)))
}

// The attribute's count decoded totally: anything but a small plain number
// is none.
fn needing(value: String) -> Result(Msg, Nil) {
  Ok(NeedingChanged(shell_rule.needing(value)))
}

// A page starts with both columns open on the first tab, no sidebar and no
// strand waiting. The sidebar's button appears when the server's attribute
// arrives, which is at once for a page that has one; assuming the opposite
// would draw a button that hides nothing on an observer's page for as long as
// the attribute took. The first tab's state is set here, since the stylesheet
// hides the other panes by the state of the tab that shows.
fn init(_: Nil) -> #(Model, Effect(Msg)) {
  let layout = shell_rule.initial()
  #(
    Model(layout:, sidebar: shell_rule.Unlisted, needing: 0),
    component.set_pseudo_state(shell_rule.tab_state(layout.tab)),
  )
}

fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Toggled(region:) -> #(
      Model(..model, layout: shell_rule.toggled(model.layout, region)),
      effect.none(),
    )

    // The state of the tab that stops showing is removed and the new one
    // added in the same turn, so the stylesheet never sees two tabs showing.
    Chosen(tab:) -> #(
      Model(..model, layout: shell_rule.chosen(model.layout, tab)),
      effect.batch([
        component.remove_pseudo_state(shell_rule.tab_state(model.layout.tab)),
        component.set_pseudo_state(shell_rule.tab_state(tab)),
      ]),
    )
    SidebarChanged(presence:) -> #(
      Model(..model, sidebar: presence),
      effect.none(),
    )
    NeedingChanged(count:) -> #(Model(..model, needing: count), effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("shell")], [
    html.div([attribute.class("shell-bar")], [
      button(model, shell_rule.Sidebar),
      component.named_slot("bar", [], []),
      button(model, shell_rule.Panel),
    ]),
    html.div([attribute.class("shell-body")], [
      column(model, shell_rule.Sidebar),
      html.div([attribute.class("shell-centre")], [
        component.default_slot([], []),
      ]),
      column(model, shell_rule.Panel),
    ]),
  ])
}

// A column's button, or nothing where the page has no such column. It is a
// real button whose words say what pressing does and whose `aria-expanded`
// says whether the column is open; its icon is drawn by the stylesheet and
// is decoration.
fn button(model: Model, region: Region) -> Element(Msg) {
  case shell_rule.has_button(model.sidebar, region) {
    False -> element.none()
    True -> {
      let state = shell_rule.state(model.layout, region)
      html.button(
        [
          attribute.type_("button"),
          attribute.class("shell-toggle"),
          button_class(region),
          attribute.aria_label(shell_rule.label(region, state)),
          attribute.aria_expanded(state == shell_rule.Open),
          event.on_click(Toggled(region)),
        ],
        [
          html.span(
            [attribute.class("toggle-icon"), attribute.aria_hidden(True)],
            [],
          ),
        ],
      )
    }
  }
}

fn button_class(region: Region) -> attribute.Attribute(Msg) {
  case region {
    shell_rule.Sidebar -> attribute.class("toggle-sidebar")
    shell_rule.Panel -> attribute.class("toggle-panel")
  }
}

// A column: the wrapper around its slot. A closed one is `inert`, which
// takes its whole subtree, the slotted content included, out of the tab
// order and away from assistive technology, and the stylesheet gives it no
// width and no paint. The sidebar's wrapper is not drawn when the page has
// no sidebar. The panel's wrapper holds the tab bar above the slot, so the
// tabs leave the tab order with the panes when the panel is closed.
fn column(model: Model, region: Region) -> Element(Msg) {
  case shell_rule.has_button(model.sidebar, region) {
    False -> element.none()
    True ->
      html.div(column_attributes(model, region), case region {
        shell_rule.Sidebar -> [component.named_slot(slot(region), [], [])]
        shell_rule.Panel -> [
          tab_bar(model),
          html.div([attribute.class("panel-body")], [
            component.named_slot(slot(region), [], []),
          ]),
        ]
      })
  }
}

fn column_attributes(
  model: Model,
  region: Region,
) -> List(attribute.Attribute(Msg)) {
  let base = [attribute.class("region"), region_class(region)]
  case shell_rule.reach(shell_rule.state(model.layout, region)) {
    shell_rule.Reachable -> base
    shell_rule.Unreachable -> [
      attribute.class("closed"),
      attribute.attribute("inert", ""),
      ..base
    ]
  }
}

fn region_class(region: Region) -> attribute.Attribute(Msg) {
  case region {
    shell_rule.Sidebar -> attribute.class("region-sidebar")
    shell_rule.Panel -> attribute.class("region-panel")
  }
}

fn slot(region: Region) -> String {
  case region {
    shell_rule.Sidebar -> "left"
    shell_rule.Panel -> "right"
  }
}

// The panel's tab bar: one real button per tab, the shown one marked
// pressed. The words are fixed by the rule; the Strands tab's badge is a
// number the server wrote, drawn beside the label and named in the button's
// own label, since the number alone says nothing to a screen reader.
fn tab_bar(model: Model) -> Element(Msg) {
  html.nav(
    [attribute.class("panel-tabs"), attribute.aria_label("Panel views")],
    list.map(shell_rule.tabs(), tab_button(model, _)),
  )
}

fn tab_button(model: Model, tab: Tab) -> Element(Msg) {
  let shown = model.layout.tab == tab
  let pressed = case shown {
    True -> "true"
    False -> "false"
  }
  let badge = case tab, shell_rule.badge(model.needing) {
    shell_rule.Strands, Some(count) -> [
      html.span([attribute.class("tab-badge"), attribute.aria_hidden(True)], [
        html.text(count),
      ]),
    ]
    _, _ -> []
  }
  let words = case tab {
    shell_rule.Strands -> shell_rule.strands_words(model.needing)
    _ -> shell_rule.tab_label(tab)
  }
  html.button(
    [
      attribute.type_("button"),
      attribute.class("panel-tab"),
      attribute.aria_pressed(pressed),
      attribute.aria_label(words),
      event.on_click(Chosen(tab)),
    ],
    [html.text(shell_rule.tab_label(tab)), ..badge],
  )
}
