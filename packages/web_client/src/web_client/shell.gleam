//// `<loom-shell sidebar="listed">`: the page's frame, with a button at each
//// end of the top bar that hides or shows a side column.
////
//// The server draws the regions (`web_view/view/shell`) as this element's
//// light-DOM children, each in a slot: `bar` for the top bar, `left` for the
//// sessions sidebar, `right` for the strand panel, and the centre in the
//// default slot. The shadow root here lays them out and draws the two
//// buttons. Which columns are open is the reader's preference and nothing
//// the server holds, so the server never renders it and a patch leaves the
//// reader's choice alone, as it does a fold's. A hidden column is drawn by
//// the server all the same, because the server does not know, so the
//// column's wrapper is what makes it inert: it takes no width, is not
//// painted, and is out of the tab order (`shell_rule.reach`), so the
//// keyboard never lands on a control the reader cannot see.
////
//// The one attribute, `sidebar`, is a fixed word the server writes, `listed`
//// or `none`, saying whether the page has a sidebar; an observer's page has
//// none, and the bar draws no button for it. The element renders no session
//// text, handles no key, takes no focus, and sends the server nothing. Its
//// buttons are real buttons, so a keyboard presses them as it presses any
//// button.
////
//// The element wraps the dock, and so holds an approval card in its
//// subtree, as `<loom-follow>` holds the lane. That is a fact about the
//// tree and not about behaviour: the element listens for no key and no
//// event beyond its own buttons' clicks, and it never moves focus. Nothing
//// it does can decide, or hide, an approval: the dock is in the centre
//// column, which has no button.

import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_client/shell_rule.{type Layout, type Presence, type Region}

/// The element's tag.
pub const name = "loom-shell"

/// What the element knows: which columns are open, and whether the page has
/// a sidebar.
pub type Model {
  Model(layout: Layout, sidebar: Presence)
}

/// Everything the element can be told.
pub type Msg {
  /// The reader pressed a column's button.
  Toggled(region: Region)

  /// The server set the `sidebar` attribute.
  SidebarChanged(presence: Presence)
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
  ])
  |> lustre.register(name)
}

// The attribute's word decoded totally: anything but `listed` is no sidebar.
fn sidebar(value: String) -> Result(Msg, Nil) {
  Ok(SidebarChanged(shell_rule.presence(value)))
}

// A page starts with both columns open and no sidebar. The sidebar's button
// appears when the server's attribute arrives, which is at once for a page
// that has one; assuming the opposite would draw a button that hides nothing
// on an observer's page for as long as the attribute took.
fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(
    Model(layout: shell_rule.initial(), sidebar: shell_rule.Unlisted),
    effect.none(),
  )
}

fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Toggled(region:) -> #(
      Model(..model, layout: shell_rule.toggled(model.layout, region)),
      effect.none(),
    )
    SidebarChanged(presence:) -> #(
      Model(..model, sidebar: presence),
      effect.none(),
    )
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
// no sidebar.
fn column(model: Model, region: Region) -> Element(Msg) {
  case shell_rule.has_button(model.sidebar, region) {
    False -> element.none()
    True ->
      html.div(column_attributes(model, region), [
        component.named_slot(slot(region), [], []),
      ])
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
