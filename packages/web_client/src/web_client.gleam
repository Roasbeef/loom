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
//// - `<loom-elapsed since="...">` (`web_client/elapsed`) counts an
////   operation's elapsed time.
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
//// - `<loom-shell sidebar="listed">` (`web_client/shell`) is the page's
////   frame. It lays the server's regions out in its slots and draws the two
////   buttons that hide and show the sidebar and the strand panel.
//// - `<loom-switch to="...">` (`web_client/switch`) moves the browser to
////   another session's page when the server writes a ticket exchange's
////   address into its attribute.
//// - `<loom-copy subject="token" text="...">` (`web_client/copy`) draws one
////   of an invitation's two texts and copies it to the clipboard when the
////   owner presses its button.
//// - `<loom-popover wanted="open">` (`web_client/popover`) opens and closes
////   the home's account panel from the person's name in the bar.
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
import web_client/composer
import web_client/copy
import web_client/elapsed
import web_client/expand
import web_client/fold
import web_client/follow
import web_client/popover
import web_client/shell
import web_client/switch

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
  let _ = composer.register()
  let _ = copy.register()

  // The transcript, the strand panel and the page's frame.
  let _ = elapsed.register()
  let _ = expand.register()
  let _ = fold.register()
  let _ = follow.register()
  let _ = popover.register()
  let _ = shell.register()
  let _ = switch.register()
  Nil
}
