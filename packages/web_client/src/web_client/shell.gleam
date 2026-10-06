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
//// choice alone, as it does a fold's.
////
//// The preference is kept in the browser's storage, per workspace
//// (protocol-change/051, the addendum on the storage decision). When the
//// element connects it reads the `workspace` attribute the server wrote, a
//// digest the daemon computed, and asks `layout_rule` what the stored layout
//// for it is; the rule answers the default for a missing, blocked or
//// malformed item. Every change the reader makes writes the layout back. The
//// page draws its default first and the stored layout a frame later, since
//// the read runs after the paint. The frame carries the class `still` until
//// that later frame has been painted (`shell_rule.Motion`), and the
//// stylesheet turns the columns' width transition off while it does, so a
//// sidebar saved as closed is closed on the frame that shows it and does not
//// visibly slide shut on every load. The reader's own presses animate as
//// before. Nothing session-derived is kept: the focused
//// strand is not, and a reload shows `main`. A page with no `workspace`
//// attribute keeps nothing, reads nothing and never touches another
//// workspace's layout. The server never learns the layout.
////
//// A page with a sidebar also gets a `Search ⌘K` chip before the Theme button
//// (`search_chip`). It is a button the switcher recognises by an attribute and
//// opens from (`web_client/switcher`), so the shell holds no state for it.
////
//// The bar also draws a Theme button. Each press moves the page from following
//// the system's colour setting to light, then dark, then back
//// (`layout_rule.next_theme`), by setting or removing `data-theme` on the
//// document's root, which the stylesheet reads. The root is where the
//// attribute must go: custom properties inherit into every shadow root under
//// it, the server component's and each client component's, and the stylesheet
//// makes each of those take its tokens from the root (`web_client.css`, the
//// light tokens). The choice is kept per browser, not per workspace, under
//// its own storage item, and a missing or unknown value follows the system.
//// The button is a real button and sends the server nothing. A hidden column is drawn by the server
//// all the same, because the server does not know, so the column's wrapper
//// is what makes it inert: it takes no width, is not painted, and is out of
//// the tab order (`shell_rule.reach`), so the keyboard never lands on a
//// control the reader cannot see.
////
//// Below 1212 px the sidebar is a drawer (`shell_rule.Frame`). The element
//// asks the browser whether the page is narrow (`matchMedia`, one query,
//// `shell_rule.narrow_query`) when it connects and again on every change, and
//// keeps the answer in the model. While the page is narrow the sidebar's button
//// and `Command` or `Control` with `B` open and close a drawer, a second state
//// held beside the layout and never saved: the sidebar's wrapper is placed over
//// the centre by the stylesheet, a scrim is drawn behind it, a click on the scrim
//// or a press of a button inside the sidebar closes it, and `Escape` closes it
//// before it does anything else. The drawer starts closed on every page and
//// closes again when the page changes frame. It touches nothing the server holds
//// and no stored layout, and the `Still` motion of the restore does not apply
//// to it.
////
//// The panel's panes are the server's children of the `right` slot: one
//// section for each tab, all of them drawn. The element shows one by
//// setting a custom state on itself, `tab-strands`, `tab-changes`,
//// `tab-session` or `tab-trace` (Lustre's `component.set_pseudo_state`), which the
//// stylesheet reads to hide the other panes (`loom-shell:state(tab-changes)`).
//// A hidden pane is `display: none`, so its controls leave the tab order. A
//// browser without custom states shows every pane, stacked, which is
//// readable and loses nothing.
////
//// The attributes are fixed words and numbers the server writes: `sidebar`
//// is `listed` or `none`, saying whether the page has a sidebar, and
//// `needing` is how many strands wait on a decision, the number on the
//// Strands tab. An observer's page has no sidebar, and the bar draws no
//// button for it. The element renders no session text, takes no focus, and
//// sends the server nothing. Its buttons and tabs are real buttons, so a
//// keyboard presses them as it presses any button, and nothing is
//// keyboard-only.
////
//// The element acts on three keys (protocol-change/051, the addendum on the
//// keyboard): Command or Control with `B` hides or shows the sessions
//// sidebar, with Alt too the strand panel, and `Escape` puts the page back on
//// `main`. It listens for `keydown` on the document while it is connected,
//// because the page's usual state has focus on `body`, where a listener on the
//// frame would hear nothing. It decodes the keystroke into plain values, reads
//// where the key was pressed from the event's composed path, and lets
//// `shell_rule.intent` say whether it counts. Any other key is dropped before
//// the element looks at where it was pressed, and the listener is removed when
//// the element disconnects. The toggles
//// change the element's own layout and nothing the server holds. `Escape`
//// clicks the breadcrumb's `All strands` link, the click a pointer makes, so it
//// goes through the relay below and does nothing when there is no breadcrumb.
//// The element sends no event of its own and none of the keys decides an
//// approval or takes focus.
////
//// The element relays clicks (protocol-change/051, the addendum on the marker
//// relay). A server-drawn control that focuses a strand and has no handler of
//// its own, such as a dot or a tag in the transcript, the breadcrumb's `All
//// strands` or a strand view's back link, carries `data-loom-focus` with the
//// position of a strand card. The element hears a click that reaches the
//// centre or the panel through its slots, decodes the marker totally
//// (`shell_rule.relay`), shows the panel on its Strands tab where the rule
//// says to, and presses the card with that position. The press is an
//// ordinary click on the card's ordinary handler, so what the server hears is
//// what it hears when a person presses the card, and the observer's socket
//// admits nothing new. A click on anything else fails the decoder and does
//// nothing.
////
//// The element wraps the dock, and so holds an approval card in its
//// subtree, as `<loom-follow>` holds the lane. That is a fact about the
//// tree and not about behaviour: the element listens for no click but its own
//// buttons' and a marked control's, and for a key only in the three ways above,
//// and it never moves focus. A click on a marker inside an approval card cannot
//// decide it: the card carries no marker, and the card pressed is always a
//// strand card, whose only effect is to focus its strand. A key pressed inside
//// the region of approval cards is dropped by the rule, whatever the key. The
//// dock is in the centre column, which has no button, and the panel carries no
//// decision control.
////
//// ## Flow
////
//// `register` → `init` → `update` → `view` → `column`
////
//// 1. `register` defines the element and subscribes to the server's two
////    attributes and to connecting and disconnecting.
//// 2. `init` starts both columns open, the drawer closed and the frame wide.
//// 3. `update` is the one reducer: a press, a tab, a relayed click, a shortcut
////    or an answer from the browser each become a new `Model` and effects.
//// 4. `restore` reads the saved layout and theme after the first paint,
////    `watch_frame` reads whether the page is narrow and listens for it
////    to change, and `listen` hears the document's keys through `hear`
////    and `respond`.
//// 5. `view` draws the bar, the three body regions and, while a drawer is
////    open, the `scrim`; `column` wraps a side column, `region_state` says
////    which state the sidebar follows, and `row` and `marker` decode the
////    clicks the element relays or acts on.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import web_client/internal/ffi_dom.{type Listener}
import web_client/layout_rule.{type Theme, type Workspace}
import web_client/shell_rule.{
  type Frame, type Intent, type Layout, type Motion, type Presence, type Region,
  type Relay, type State, type Tab,
}
import web_client/switcher_rule

/// The element's tag.
pub const name = "loom-shell"

/// What the element knows: which columns are open and which tab shows,
/// whether the page has a sidebar, and how many strands wait on a decision.
pub type Model {
  Model(
    layout: Layout,
    sidebar: Presence,
    needing: Int,
    /// The workspace the layout is kept for, known once the stored layout has
    /// been read. Until then, and for a page with no digest, it is
    /// `Anonymous` and nothing is written.
    workspace: Workspace,
    /// The page's theme, which the document's root carries as `data-theme`.
    theme: Theme,
    /// The listener on the document while the element is connected.
    keys: Option(Listener),
    /// Whether a change of layout animates. It is `Still` until the saved
    /// layout has been drawn, so the restore is not seen as a slide.
    motion: Motion,
    /// Whether the page is wide enough for a sidebar column, from the
    /// browser's media query. A page assumes `Wide` until the query answers.
    frame: Frame,
    /// Whether the sidebar drawer is open. It means something only while the
    /// frame is `Narrow`, it is never saved, and a change of frame closes it.
    drawer: State,
    /// The listener on the media query while the element is connected.
    watch: Option(Watch),
  )
}

/// A running listener on the narrow-page media query, with the query it
/// listens to, which `remove_listener` needs to name to stop it.
pub type Watch {
  Watch(query: ffi_dom.Element, listener: Listener)
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

  /// A click reached the centre or the panel on a control that carries a
  /// strand marker, and asks for the strand card at that position to be
  /// pressed.
  Relayed(relay: Relay)

  /// A key was pressed that `shell_rule.intent` took as a shortcut.
  Pressed(intent: Intent)

  /// The element joined the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The document's key listener is in place.
  Listening(listener: Listener)

  /// The reader pressed the Theme button.
  ThemeCycled

  /// The storage has been read for the page's workspace. `saved` is the
  /// layout to show, or `None` for a page that has no workspace, which keeps
  /// the layout it has. `theme` is the browser's saved theme, which does not
  /// depend on the workspace. `tab` is the browser's saved panel tab, which
  /// does not either, and replaces the layout's tab when there is one.
  Restored(
    workspace: Workspace,
    saved: Option(Layout),
    theme: Theme,
    tab: Option(Tab),
  )

  /// The frame that drew the restored layout has been painted, so later
  /// changes of layout may animate.
  Settled

  /// The browser said whether the page is narrow, on connecting and whenever
  /// the window crossed the breakpoint.
  Framed(frame: Frame)

  /// The media query's listener is in place.
  Watching(watch: Watch)

  /// The reader dismissed the drawer: a click on the scrim, or a press of a
  /// button inside the sidebar.
  DrawerDismissed
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
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
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
    Model(
      layout:,
      sidebar: shell_rule.Unlisted,
      needing: 0,
      workspace: layout_rule.Anonymous,
      theme: layout_rule.System,
      keys: None,
      motion: shell_rule.Still,
      frame: shell_rule.Wide,
      drawer: shell_rule.Closed,
      watch: None,
    ),
    component.set_pseudo_state(shell_rule.tab_state(layout.tab)),
  )
}

fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    // The sidebar's press is the frame's to interpret: a column changes the
    // saved layout, and a drawer changes only the drawer, which is not saved.
    Toggled(shell_rule.Sidebar) -> {
      let #(layout, drawer) =
        shell_rule.sidebar_pressed(model.layout, model.frame, model.drawer)
      let model = Model(..model, drawer:)
      case layout == model.layout {
        True -> #(model, effect.none())
        False -> changed(model, layout, effect.none())
      }
    }
    Toggled(region:) ->
      changed(model, shell_rule.toggled(model.layout, region), effect.none())

    // The state of the tab that stops showing is removed and the new one
    // added in the same turn, so the stylesheet never sees two tabs showing.
    Chosen(tab:) ->
      changed(
        model,
        shell_rule.chosen(model.layout, tab),
        tab_changed(model.layout.tab, tab),
      )
    SidebarChanged(presence:) -> #(
      Model(..model, sidebar: presence),
      effect.none(),
    )
    NeedingChanged(count:) -> #(Model(..model, needing: count), effect.none())

    // One listener per connection: moving the element stops the old one
    // before it starts another, so a page that replaced the element leaves
    // nothing listening on the document.
    Connected -> #(
      model,
      effect.batch([
        stop_keys(model.keys),
        stop_watch(model.watch),
        listen(),
        watch_frame(),
        restore(),
      ]),
    )

    // `listen` registers after the paint, so this can arrive after a later
    // `Connected` or a `Disconnected` has already run. Whatever listener the
    // model still holds is stopped as the new one is kept, so a reconnect
    // within one frame leaves exactly one listener on the document.
    Listening(listener:) -> #(
      Model(..model, keys: Some(listener)),
      stop_keys(model.keys),
    )
    Disconnected -> #(
      Model(..model, keys: None, watch: None),
      effect.batch([stop_keys(model.keys), stop_watch(model.watch)]),
    )

    // The same arrangement for the media query's listener as for the keys'.
    Watching(watch:) -> #(
      Model(..model, watch: Some(watch)),
      stop_watch(model.watch),
    )

    // A drawer open across a change of frame would be a drawer the reader
    // never asked for on the other side of it, so the change closes it.
    Framed(frame:) -> #(
      Model(..model, frame:, drawer: shell_rule.Closed),
      effect.none(),
    )
    DrawerDismissed -> #(
      Model(..model, drawer: shell_rule.Closed),
      effect.none(),
    )

    // The two toggles are the buttons' own turn, so a shortcut and a press
    // cannot differ. `Escape` presses the breadcrumb's link, which is the
    // click a pointer makes, and the relay takes it from there.
    Pressed(intent:) ->
      case intent {
        shell_rule.ToggleSidebar -> update(model, Toggled(shell_rule.Sidebar))
        shell_rule.TogglePanel -> update(model, Toggled(shell_rule.Panel))
        shell_rule.LeaveStrand ->
          case shell_rule.dismissal(model.frame, model.drawer) {
            shell_rule.Dismiss -> update(model, DrawerDismissed)
            shell_rule.Leave -> #(model, press_crumb())
          }
      }

    // The layout changes first, so a panel that was closed is open when the
    // card is pressed, and the press follows the render. The card's own
    // handler does the rest: the strand is focused by the server, exactly as
    // when a person presses the card. The panel a relay opened is saved like
    // one the reader opened.
    Relayed(relay:) -> {
      let layout = shell_rule.relayed(model.layout, relay)
      changed(
        model,
        layout,
        effect.batch([
          tab_changed(model.layout.tab, layout.tab),
          press_card(relay.card),
        ]),
      )
    }

    // The stored layout replaces the default the page drew first. The tab's
    // custom state moves with it, so the stylesheet shows the pane the
    // restored tab names. The saved theme is applied to the root in the same
    // turn, and is not written back: it is what the storage already holds.
    // The frame is still while the restored layout is drawn, so the width
    // transition does not run for it, and the settle that follows the paint
    // turns motion on for the reader's own changes.
    Restored(workspace:, saved:, theme:, tab:) -> {
      let layout = option.unwrap(saved, model.layout)
      let layout =
        shell_rule.Layout(..layout, tab: option.unwrap(tab, layout.tab))
      #(
        Model(..model, workspace:, layout:, theme:),
        effect.batch([
          tab_changed(model.layout.tab, layout.tab),
          apply_theme(theme),
          settle(),
        ]),
      )
    }

    Settled -> #(Model(..model, motion: shell_rule.Animated), effect.none())

    // The next theme is applied to the root and written to the storage in the
    // same turn, so a reload after the press shows the theme the reader chose.
    ThemeCycled -> {
      let theme = layout_rule.next_theme(model.theme)
      #(
        Model(..model, theme:),
        effect.batch([apply_theme(theme), save_theme(theme)]),
      )
    }
  }
}

// Reports that the frame just drawn has been painted. The effect runs after
// the paint that follows the update returning it, and the update is the one
// that applied the restored layout, so by the time `Settled` arrives the
// browser has already computed the closed column's width without a
// transition.
fn settle() -> Effect(Msg) {
  use dispatch, _ <- effect.after_paint
  dispatch(Settled)
}

// Reports whether the page is narrow now, and again each time the window
// crosses the breakpoint. The answer is read from the query when it is set up
// and from the change event after that, and the query and its listener are
// handed back so the element can stop listening when it leaves.
fn watch_frame() -> Effect(Msg) {
  use dispatch <- effect.from
  let query = ffi_dom.media_query(shell_rule.narrow_query())
  dispatch(Framed(frame_of(ffi_dom.media_matches(query))))
  let listener =
    ffi_dom.add_listener(query, "change", fn(event) {
      case
        decode.run(event, decode.field("matches", decode.bool, decode.success))
      {
        Ok(narrow) -> dispatch(Framed(frame_of(narrow)))
        Error(_) -> Nil
      }
    })
  dispatch(Watching(Watch(query:, listener:)))
}

// Stops the media query's listener, if one is in place.
fn stop_watch(watch: Option(Watch)) -> Effect(Msg) {
  case watch {
    None -> effect.none()
    Some(Watch(query:, listener:)) -> {
      use _ <- effect.from
      ffi_dom.remove_listener(query, "change", listener)
    }
  }
}

// The frame a query answer names: matching the narrow query is narrow.
fn frame_of(matches: Bool) -> Frame {
  case matches {
    True -> shell_rule.Narrow
    False -> shell_rule.Wide
  }
}

// Sets `data-theme` on the document's root, or removes it where the theme
// follows the system, so the stylesheet's `prefers-color-scheme` rule decides.
fn apply_theme(theme: Theme) -> Effect(Msg) {
  use _ <- effect.from
  let root = ffi_dom.document_element()
  case layout_rule.data_theme(theme) {
    Some(word) -> ffi_dom.set_attribute(root, "data-theme", word)
    None -> ffi_dom.remove_attribute(root, "data-theme")
  }
}

// Writes the theme to its item. As with the layout, a refused write is
// dropped: the page shows the theme the reader chose and the next load
// follows the system.
fn save_theme(theme: Theme) -> Effect(Msg) {
  use _ <- effect.from
  let _ =
    ffi_dom.storage_write(
      layout_rule.theme_key,
      layout_rule.encode_theme(theme),
    )
  Nil
}

// A change of layout the reader made: kept in the model, written to the
// storage under the page's workspace, and followed by `effects`, the ones the
// change needs on the page. The write is one effect, so a change that is not
// saved because the storage is blocked still shows.
fn changed(
  model: Model,
  layout: Layout,
  effects: Effect(Msg),
) -> #(Model, Effect(Msg)) {
  #(
    Model(..model, layout:),
    effect.batch([save(model.workspace, layout), effects]),
  )
}

// Writes the layout under the workspace's item, and the tab under the
// browser's. A page with no workspace writes no layout, but its tab is still
// the reader's. A refused write, from blocked or full storage, is dropped:
// the layout on screen is right, the next load starts from the default, and
// there is nothing the reader could do about it.
fn save(workspace: Workspace, layout: Layout) -> Effect(Msg) {
  use _ <- effect.from
  let _ =
    ffi_dom.storage_write(
      layout_rule.tab_key,
      layout_rule.encode_tab(layout.tab),
    )
  case layout_rule.layout_key(workspace) {
    None -> Nil
    Some(key) -> {
      let _ = ffi_dom.storage_write(key, layout_rule.encode(layout))
      Nil
    }
  }
}

// Reads the workspace's digest from the host's own attribute, which the
// server wrote before the element connected, and the stored layout under it.
// It runs after the paint, so the page has drawn its default when the stored
// layout arrives. A page whose attribute is not a digest reads nothing and
// answers no layout, so the one it has stands.
fn restore() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))
  let workspace =
    layout_rule.workspace(result.unwrap(
      ffi_dom.attribute(host, "workspace"),
      "",
    ))
  let saved =
    layout_rule.layout_key(workspace)
    |> option.map(fn(key) { layout_rule.restore(ffi_dom.storage_read(key)) })
  let theme = layout_rule.theme(ffi_dom.storage_read(layout_rule.theme_key))
  let tab = layout_rule.restored_tab(ffi_dom.storage_read(layout_rule.tab_key))
  dispatch(Restored(workspace:, saved:, theme:, tab:))
}

// The custom states for a change of tab: the old one out and the new one in
// in the same turn, or nothing when the tab did not change.
fn tab_changed(from: Tab, to: Tab) -> Effect(Msg) {
  case from == to {
    True -> effect.none()
    False ->
      effect.batch([
        component.remove_pseudo_state(shell_rule.tab_state(from)),
        component.set_pseudo_state(shell_rule.tab_state(to)),
      ])
  }
}

// Presses the breadcrumb's `All strands` link, which is drawn only while a
// strand other than `main` is in focus, so with none drawn nothing happens.
fn press_crumb() -> Effect(Msg) {
  use _, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))
  case ffi_dom.query_selector(host, shell_rule.crumb_link()) {
    Ok(link) -> ffi_dom.click(link)
    Error(Nil) -> Nil
  }
}

// Presses the strand card at `card`. The cards are the server's light-DOM
// descendants of the host, so the host's own query reaches them; a card that
// is not there, because the strand left the list between the click and now,
// is not pressed and nothing happens.
fn press_card(card: Int) -> Effect(Msg) {
  use _, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))
  case ffi_dom.query_selector(host, shell_rule.card_selector(card)) {
    Ok(element) -> ffi_dom.click(element)
    Error(Nil) -> Nil
  }
}

fn view(model: Model) -> Element(Msg) {
  html.div(list.map(shell_rule.frame_classes(model.motion), attribute.class), [
    html.div([attribute.class("shell-bar")], [
      button(model, shell_rule.Sidebar),
      component.named_slot("bar", [], []),
      search_chip(model),
      theme_button(model),
      button(model, shell_rule.Panel),
    ]),
    html.div([attribute.class("shell-body")], [
      column(model, shell_rule.Sidebar),
      html.div([attribute.class("shell-centre")], [
        component.default_slot([event.on("click", marker())], []),
      ]),
      column(model, shell_rule.Panel),
      scrim(model),
    ]),
  ])
}

// The veil behind an open drawer, which a click dismisses. It is drawn only
// while the drawer is open on a narrow page, and a pointer is the only thing
// that reaches it: the keyboard has `Escape` and the sidebar's own button.
fn scrim(model: Model) -> Element(Msg) {
  case shell_rule.scrimmed(model.frame, model.drawer) {
    True ->
      html.div(
        [
          attribute.class("drawer-scrim"),
          attribute.aria_hidden(True),
          event.on_click(DrawerDismissed),
        ],
        [],
      )
    False -> element.none()
  }
}

// The state a column shows: the sidebar's depends on the frame, the panel's is
// the layout's.
fn region_state(model: Model, region: Region) -> State {
  case region {
    shell_rule.Sidebar ->
      shell_rule.sidebar_state(model.layout, model.frame, model.drawer)
    shell_rule.Panel -> shell_rule.state(model.layout, region)
  }
}

// Listens for `keydown` on the document. The document hears every key pressed
// in the page whatever has focus, `body` included, which is the usual state
// after a load or after a click on text or on a button in a browser that does
// not focus buttons. The callback runs in the event, so it can cancel the
// browser's action, and it drops every key but the two the rule may read
// before it looks at where the key was pressed. The event is never stopped.
fn listen() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let host = ffi_dom.host(ffi_dom.as_element(root))
  let listener =
    ffi_dom.add_listener(ffi_dom.get_document(), "keydown", fn(event) {
      hear(host, event, dispatch)
    })
  dispatch(Listening(listener))
}

// Removes the document's listener, if one is in place.
fn stop_keys(keys: Option(Listener)) -> Effect(Msg) {
  case keys {
    None -> effect.none()
    Some(listener) -> {
      use _ <- effect.from
      ffi_dom.remove_listener(ffi_dom.get_document(), "keydown", listener)
    }
  }
}

// One keydown. A key that is not one the rule may read is dropped here,
// before the path is looked at.
fn hear(
  host: ffi_dom.Element,
  event: Dynamic,
  dispatch: fn(Msg) -> Nil,
) -> Nil {
  case decode.run(event, heard()) {
    Ok(#(key, code, modifiers, composition, prevention, repetition)) ->
      case shell_rule.candidate(key, code) {
        True ->
          respond(
            host,
            event,
            dispatch,
            shell_rule.Keystroke(
              key:,
              code:,
              modifiers:,
              target: target_of(event),
              composition:,
              prevention:,
              repetition:,
            ),
          )
        False -> Nil
      }
    Error(_) -> Nil
  }
}

// What a keystroke the rule may read asks for. Whether the page has a
// sidebar is read from the host's own attribute, since the event cannot wait
// for a message to be reduced before the browser's action is cancelled or
// not.
fn respond(
  host: ffi_dom.Element,
  event: Dynamic,
  dispatch: fn(Msg) -> Nil,
  keystroke: shell_rule.Keystroke,
) -> Nil {
  let presence =
    shell_rule.presence(result.unwrap(ffi_dom.attribute(host, "sidebar"), ""))
  case shell_rule.intent(keystroke, presence) {
    None -> Nil
    Some(intent) -> {
      cancel(event, intent)
      dispatch(Pressed(intent))
    }
  }
}

// Cancels the browser's action for the two toggles.
fn cancel(event: Dynamic, intent: Intent) -> Nil {
  case shell_rule.cancels(intent) {
    shell_rule.Cancelled -> ffi_dom.prevent_default(event)
    shell_rule.Untouched -> Nil
  }
}

// What a `keydown` says, but where it was pressed.
fn heard() -> decode.Decoder(
  #(
    String,
    String,
    shell_rule.Modifiers,
    shell_rule.Composition,
    shell_rule.Prevention,
    shell_rule.Repetition,
  ),
) {
  use key <- decode.field("key", decode.string)
  use code <- decode.field("code", decode.string)
  use meta <- decode.field("metaKey", modifier())
  use ctrl <- decode.field("ctrlKey", modifier())
  use alt <- decode.field("altKey", modifier())
  use shift <- decode.field("shiftKey", modifier())
  use composing <- decode.field("isComposing", composition())
  use handled <- decode.field("defaultPrevented", prevention())
  use repeating <- decode.field("repeat", repetition())
  decode.success(#(
    key,
    code,
    shell_rule.Modifiers(meta:, ctrl:, alt:, shift:),
    composing,
    handled,
    repeating,
  ))
}

fn modifier() -> decode.Decoder(shell_rule.Modifier) {
  decode.map(decode.bool, fn(down) {
    case down {
      True -> shell_rule.Held
      False -> shell_rule.Free
    }
  })
}

fn composition() -> decode.Decoder(shell_rule.Composition) {
  decode.map(decode.bool, fn(composing) {
    case composing {
      True -> shell_rule.Composing
      False -> shell_rule.Settled
    }
  })
}

fn prevention() -> decode.Decoder(shell_rule.Prevention) {
  decode.map(decode.bool, fn(prevented) {
    case prevented {
      True -> shell_rule.Prevented
      False -> shell_rule.Unhandled
    }
  })
}

fn repetition() -> decode.Decoder(shell_rule.Repetition) {
  decode.map(decode.bool, fn(repeating) {
    case repeating {
      True -> shell_rule.Repeating
      False -> shell_rule.Fresh
    }
  })
}

// Where the key was pressed, from the nodes the event passed through. At the
// document an event's target is the outermost shadow host, so the page's own
// composer and approval cards would look like one element; the composed path
// has every node from the focused one outward, shadow trees included. Each is
// read for the three facts the rule needs, and the rule decides.
fn target_of(event: Dynamic) -> shell_rule.Target {
  ffi_dom.composed_path(event)
  |> list.map(step)
  |> shell_rule.target
}

fn step(node: ffi_dom.Element) -> shell_rule.Step {
  shell_rule.Step(
    tag: result.unwrap(ffi_dom.tag_name(node), ""),
    approvals: case ffi_dom.attribute(node, "data-loom-approvals") {
      Ok(_) -> shell_rule.Marked
      Error(Nil) -> shell_rule.Unmarked
    },
    editing: case ffi_dom.is_content_editable(node) {
      Ok(True) -> shell_rule.Editable
      Ok(False) | Error(Nil) -> shell_rule.Fixed
    },
  )
}

// A click on a control that carries the server's strand marker. The marker's
// value is read from the click's own target, so a click on anything else, a
// child of a marked control included, fails the decoder and dispatches
// nothing; a value that is not a plain number fails it too.
fn marker() -> decode.Decoder(Msg) {
  use value <- decode.subfield(
    ["target", "dataset", "loomFocus"],
    decode.string,
  )
  case shell_rule.relay(value) {
    Ok(relay) -> decode.success(Relayed(relay))
    Error(Nil) ->
      decode.failure(
        Relayed(shell_rule.Relay(card: 0, reveal: shell_rule.Keep)),
        "a strand marker",
      )
  }
}

// A press inside the sidebar that closes the drawer: the tags of the nodes the
// click passed through hold a button, whichever child of the button was hit.
// Any other click fails the decoder and does nothing.
fn row() -> decode.Decoder(Msg) {
  use event <- decode.then(decode.dynamic)
  let tags = ffi_dom.composed_path(event) |> list.filter_map(ffi_dom.tag_name)
  case shell_rule.presses_button(tags) {
    True -> decode.success(DrawerDismissed)
    False -> decode.failure(DrawerDismissed, "a press on a sidebar button")
  }
}

// A column's button, or nothing where the page has no such column. It is a
// real button whose words say what pressing does and whose `aria-expanded`
// says whether the column is open; its icon is drawn by the stylesheet and
// is decoration.
fn button(model: Model, region: Region) -> Element(Msg) {
  case shell_rule.has_button(model.sidebar, region) {
    False -> element.none()
    True -> {
      let state = region_state(model, region)
      html.button(
        [
          attribute.type_("button"),
          attribute.class("shell-toggle"),
          button_class(region),
          attribute.aria_label(shell_rule.label(region, state)),
          attribute.title(shell_rule.title(region, state)),
          attribute.aria("keyshortcuts", shell_rule.shortcuts(region)),
          attribute.aria_expanded(state == shell_rule.Open),
          event.on_click(Toggled(region)),
        ],
        toggle_face(region),
      )
    }
  }
}

// What a toggle draws: its icon and the visible key hint beside it. The
// hint sits on the side facing the centre, so the icon stays at the edge of
// the bar. Both are decoration, since the button's label and its
// `aria-keyshortcuts` are what assistive technology reads.
fn toggle_face(region: Region) -> List(Element(Msg)) {
  let icon =
    html.span([attribute.class("toggle-icon"), attribute.aria_hidden(True)], [])
  let hint =
    html.kbd([attribute.class("toggle-hint"), attribute.aria_hidden(True)], [
      html.text(shell_rule.hint(region)),
    ])

  case region {
    shell_rule.Sidebar -> [icon, hint]
    shell_rule.Panel -> [hint, icon]
  }
}

// The `Search` chip, on the pages that have a switcher: a real button with the
// shortcut's hint beside its word, for a person who has not been told the
// shortcut and for a touch screen that has no keys. It carries no handler of
// the shell's. `<loom-switcher>` hears a click on anything marked with the
// attribute below, so the shell neither reaches the switcher nor holds a
// state for it. The hint hides on a narrow bar, as the toggles' do.
fn search_chip(model: Model) -> Element(Msg) {
  case shell_rule.has_search(model.sidebar) {
    False -> element.none()
    True ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("bar-search"),
          attribute.attribute(
            switcher_rule.summon_attribute,
            switcher_rule.summon_value,
          ),
          attribute.aria_label("Search sessions and pages"),
          attribute.title("Search sessions and pages"),
          attribute.aria("keyshortcuts", "Control+K Meta+K"),
        ],
        [
          html.span([attribute.class("bar-search-word")], [html.text("Search")]),
          html.kbd(
            [attribute.class("bar-search-hint"), attribute.aria_hidden(True)],
            [html.text("⌘K")],
          ),
        ],
      )
  }
}

// The Theme button: a real button whose icon shows which theme the page is in
// and whose label says what pressing it does. The label is fixed words from
// the rule and holds nothing from the session, and the icon is decoration
// drawn from fixed shapes, so assistive technology reads only the label.
fn theme_button(model: Model) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("shell-theme"),
      attribute.aria_label(layout_rule.label(model.theme)),
      attribute.title(layout_rule.label(model.theme)),
      event.on_click(ThemeCycled),
    ],
    [theme_icon(model.theme)],
  )
}

// The icon for a theme: a half-filled disc while the page follows the system,
// a sun for light and a moon for dark. Each is a stroked outline in the
// button's text colour, 16 units square, with no text and no session data.
fn theme_icon(theme: Theme) -> Element(Msg) {
  let shapes = case theme {
    layout_rule.System -> [
      svg.circle([
        attribute.attribute("cx", "8"),
        attribute.attribute("cy", "8"),
        attribute.attribute("r", "5.5"),
      ]),
      svg.path([
        attribute.attribute("d", "M8 2.5a5.5 5.5 0 0 1 0 11z"),
        attribute.attribute("fill", "currentColor"),
      ]),
    ]

    layout_rule.Light -> [
      svg.circle([
        attribute.attribute("cx", "8"),
        attribute.attribute("cy", "8"),
        attribute.attribute("r", "2.8"),
      ]),
      svg.path([
        attribute.attribute(
          "d",
          "M8 1.5v1.7M8 12.8v1.7M1.5 8h1.7M12.8 8h1.7M3.4 3.4l1.2 1.2M11.4 11.4l1.2 1.2M12.6 3.4l-1.2 1.2M4.6 11.4l-1.2 1.2",
        ),
      ]),
    ]

    layout_rule.Dark -> [
      svg.path([
        attribute.attribute(
          "d",
          "M13.2 9.6A5.6 5.6 0 0 1 6.4 2.8a5.6 5.6 0 1 0 6.8 6.8z",
        ),
      ]),
    ]
  }

  svg.svg(
    [
      attribute.attribute("viewBox", "0 0 16 16"),
      attribute.attribute("fill", "none"),
      attribute.attribute("stroke", "currentColor"),
      attribute.attribute("stroke-width", "1.4"),
      attribute.attribute("stroke-linecap", "round"),
      attribute.attribute("stroke-linejoin", "round"),
      attribute.aria_hidden(True),
    ],
    shapes,
  )
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
        shell_rule.Sidebar -> [
          component.named_slot(slot(region), [event.on("click", row())], []),
        ]
        shell_rule.Panel -> [
          tab_bar(model),
          html.div([attribute.class("panel-body")], [
            component.named_slot(
              slot(region),
              [event.on("click", marker())],
              [],
            ),
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
  let state = region_state(model, region)
  case shell_rule.reach(state) {
    shell_rule.Reachable ->
      case region, model.frame {
        shell_rule.Sidebar, shell_rule.Narrow -> [
          attribute.class("drawer"),
          ..base
        ]
        _, _ -> base
      }
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
