//// The browser half of the web view: the custom elements the server
//// component renders, written in Gleam and compiled to JavaScript.
////
//// The server component (`web_view/component`) holds every piece of session
//// state and is the only thing that talks to the session. Some behaviour
//// belongs in the browser anyway, because it changes with nothing the
//// server knows: a clock that moves every second, a fold the reader opens,
//// or where the reader has scrolled. Each such behaviour is one Lustre client component registered as
//// a custom element, which the server renders like any other tag:
////
//// - `<loom-elapsed offset="...">` (`web_client/elapsed`) counts an
////   operation's elapsed time, and with `remaining="..."` counts a page's
////   lifetime down.
//// - `<loom-fold>` (`web_client/fold`) opens and closes a turn's folded
////   work.
//// - `<loom-expand>` (`web_client/expand`) draws a row's line with one
////   chevron and shows the body behind it once the reader opens it, from two
////   slots the server wrote.
//// - `<loom-follow>` (`web_client/follow`) is the transcript's scroll
////   container. It keeps the lane's newest row in view while the reader is
////   at the bottom, and offers a way back to it while they are not.
//// - `<loom-composer>` (`web_client/composer`) wraps the operator's editor:
////   it lists slash commands as the draft grows, sends the draft on Command
////   or Control with Enter, and puts a returned prompt back in the editor.
//// - `<loom-attach name="images">` (`web_client/attach`) is the composer's
////   image attachments: a file picker, a paste, a chip for each image with
////   a Remove button, and the images as one form field.
//// - `drop_guard` (`web_client/drop_guard`) is no element: one listener on
////   the document that stops a dropped file from navigating the tab.
//// - `<loom-shell sidebar="listed">` (`web_client/shell`) is the page's
////   frame. It lays the server's regions out in its slots and draws the two
////   buttons that hide and show the sidebar and the strand panel.
//// - `<loom-switch to="...">` (`web_client/switch`) moves the browser to
////   another session's page when the server writes a ticket exchange's
////   address into its attribute.
//// - `<loom-switcher>` (`web_client/switcher`) is the session switcher that
////   Command or Control and K opens: it lists the sessions the sidebar
////   already draws and presses the chosen one's own sidebar button. The
////   bar's `Search` chip opens it too.
//// - `<loom-title>` (`web_client/title`) sets the tab's title to the
////   session's name, read from the bar's heading, with the count of strands
////   that wait on the person in front.
//// - `<loom-copy subject="token" text="...">` (`web_client/copy`) draws one
////   of an invitation's two texts and copies it to the clipboard when the
////   owner presses its button.
//// - `<loom-back>Home</loom-back>` (`web_client/back`) is a button that goes
////   one step back in the tab's history and mints nothing.
//// - `<loom-waiting>` (`web_client/waiting`) wraps the shell's waiting
////   paragraph and, after five seconds with no socket, draws the ended
////   document's shape in its place.
//// - `<loom-popover wanted="open">` (`web_client/popover`) opens and closes
////   the home's account panel from the person's name in the bar.
//// - `<loom-saved>` (`web_client/saved`) folds and unfolds the sidebar's saved
////   sessions from its quiet "N saved" line, and keeps the choice in the
////   browser's storage.
//// - `<loom-time at="...">` (`web_client/time`) draws an instant, in Unix
////   milliseconds, as the time of day in the browser's own zone.
//// - `<loom-link>` (`web_client/link`) makes a Markdown link clickable once the
////   browser has checked its destination, read from the element's own child
////   text, as an `http` or `https` address.
//// - `<loom-reveal>` (`web_client/reveal`) scrolls the box it sits in into view
////   once, when the box appears.
////
//// Every element keeps the page's rules (protocol-change/051): it renders
//// only what its own attributes say, and those hold daemon identities or
//// numbers (or, for the composer, the static table of command names, and for
//// the copy box the one text it was handed, of a shape it checks), never
//// session text; text inside a fold is the server's children, projected
//// through a slot; nothing handles a key or takes focus near an approval
//// card, and the composer handles keys only in its own editor; and Lustre
//// renders through its virtual DOM, never raw HTML. `make gen-client` bundles this package into one module in
//// `web_view`'s `priv/static`, which the page loads under the unchanged
//// policy (`script-src 'self'`).

import web_client/attach
import web_client/back
import web_client/composer
import web_client/copy
import web_client/drop_guard
import web_client/elapsed
import web_client/expand
import web_client/fold
import web_client/follow
import web_client/link
import web_client/popover
import web_client/rename
import web_client/reveal
import web_client/saved
import web_client/shell
import web_client/switch
import web_client/switcher
import web_client/time
import web_client/title
import web_client/waiting

/// Registers every element. The bundle calls this once when the page loads
/// it; an element already registered is left as it is.
///
/// ## Examples
///
/// ```gleam
/// // web_client.main()
/// ```
pub fn main() -> Nil {
  // The operator's composer: its editor and its image attachments.
  let _ = attach.register()
  let _ = back.register()
  let _ = composer.register()
  let _ = copy.register()

  // A file dropped anywhere else must not navigate the tab away.
  drop_guard.install()

  // The transcript, the strand panel and the page's frame.
  let _ = elapsed.register()
  let _ = expand.register()
  let _ = fold.register()
  let _ = follow.register()
  let _ = link.register()
  let _ = popover.register()
  let _ = rename.register()
  let _ = reveal.register()
  let _ = saved.register()
  let _ = shell.register()
  let _ = switch.register()
  let _ = switcher.register()
  let _ = time.register()
  let _ = title.register()
  let _ = waiting.register()
  Nil
}
