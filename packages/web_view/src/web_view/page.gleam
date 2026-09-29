//// The documents the daemon serves around the component: the page shell,
//// the ticket exchange's hand-off page, the content security policy they
//// are served under, and where the page's stylesheet and scripts are.
////
//// The stylesheet and scripts are files, not strings: their sources are in
//// `packages/web_client`, and `make gen-client` builds them into this
//// package's `priv/static` (`static_file`), which a release carries like
//// any application's `priv`. The daemon reads them once when it starts.
////
//// All of it is fixed text with no inline script and no inline style, which
//// is what lets the policy say `script-src 'self'` and `style-src 'self'`.
//// The values interpolated into a document are the session identity, which
//// the router has already parsed as a canonical ID, and on the exchange page
//// the page's keyed address and its nonce, which the daemon generated; each
//// is escaped here all the same. Lustre's client runtime is served from the
//// `lustre` application's own `priv` directory, so the file a browser runs
//// is the one the pinned package shipped.
////
//// The page nonce (protocol-change/051, the operator addendum) reaches the
//// browser once, in the exchange's body. The exchange page's script keeps it
//// in `sessionStorage`, which is scoped to scheme, host and port, and the
//// page's own script hands it to Lustre's client runtime as the component's
//// `csrf-token`, which the runtime sends in the socket's query. A page on
//// another loopback port cannot read it, which is what it is for: the
//// cookie and the page key can leak to such a page, the nonce cannot. The
//// keyed page's HTML never carries it, since anyone holding the cookie and
//// the key can fetch that HTML.

import gleam/erlang/application
import gleam/result
import houdini
import web_view/ending.{type Ending}

/// The route prefix every view path lives under.
pub const prefix = "/ui"

/// The name Lustre's client runtime is served under. The version is part
/// of the name so a browser never runs a cached runtime against a newer
/// server component.
pub const runtime_asset = "lustre-server-component-5.7.1.mjs"

/// The page's stylesheet, built from `packages/web_client`.
pub const stylesheet_asset = "web_client.css"

/// The script the exchange page runs to keep the nonce and move to the
/// session page.
pub const enter_asset = "web_view_enter.js"

/// The script the session page runs to connect its component with the
/// nonce.
pub const page_asset = "web_view_page.js"

/// The client components (`packages/web_client`), bundled into one ES
/// module, which the page loads so the server component can render their
/// custom elements.
pub const client_asset = "web_client.mjs"

/// Where the keyed pages live: `/ui/p/<key>`, the path the page's cookie is
/// scoped to.
///
/// ## Examples
///
/// ```gleam
/// assert page.keyed_prefix("abc") == "/ui/p/abc"
/// ```
pub fn keyed_prefix(key: String) -> String {
  prefix <> "/p/" <> key
}

/// The keyed address of one session's page.
///
/// ## Examples
///
/// ```gleam
/// assert page.session_path("abc", "S") == "/ui/p/abc/sessions/S"
/// ```
pub fn session_path(key: String, session_id: String) -> String {
  keyed_prefix(key) <> "/sessions/" <> session_id
}

/// The page for one session: a shell holding one server component, and the
/// script that connects it with the tab's nonce. The component carries no
/// `route` of its own; the script sets its `csrf-token` and then its
/// `route`, the page's own address plus `/ws`, so the socket is opened only
/// with the nonce in its query.
///
/// The component holds a fixed paragraph as light-DOM content. Lustre's
/// client runtime attaches the component's shadow root only when the first
/// tree arrives, and a shadow root with no slot hides its host's light
/// content, so the paragraph is on screen exactly while the page has no
/// session: before the socket connects, and for as long as the daemon
/// refuses it. A refused handshake is a bare failure to the browser, which
/// cannot read its status, so this paragraph is the only place the page can
/// say why it is empty. It needs no script and no attribute the session
/// controls (protocol-change/051, the addendum on an ended page).
///
/// ## Examples
///
/// ```gleam
/// // page.shell("0198c0de-...")
/// ```
pub fn shell(session_id: String) -> String {
  let id = houdini.escape(session_id)
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  <> "<title>Loom · "
  <> id
  <> "</title>"
  <> "<link rel=\"stylesheet\" href=\""
  <> asset_path(stylesheet_asset)
  <> "\">"
  <> "<script type=\"module\" src=\""
  <> asset_path(runtime_asset)
  <> "\"></script>"
  <> "<script type=\"module\" src=\""
  <> asset_path(client_asset)
  <> "\"></script>"
  <> "</head><body>"
  <> "<lustre-server-component><p class=\"page-note\">"
  <> houdini.escape(waiting_notice(session_id))
  <> "</p></lustre-server-component>"
  <> "<script src=\""
  <> asset_path(page_asset)
  <> "\"></script>"
  <> "</body></html>\n"
}

/// What a page says while it has no session and nothing more specific is
/// known: the socket has not connected, or the daemon refuses it. The causes
/// it lists are the ones a person can tell apart by trying, in the order to
/// try them.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(
///   page.waiting_notice("0192ab"),
///   "loom ui --session 0192ab",
/// )
/// ```
pub fn waiting_notice(session_id: String) -> String {
  "This page is not connected to the session. The daemon may still be "
  <> "starting, this page may have ended, or this tab may have lost its key "
  <> "for the page. Reload it. If it stays like this, run `loom ui --session "
  <> session_id
  <> "` for a fresh link."
}

/// The document a browser gets when it asks for a page that cannot be
/// served: the reason class and what to do, and nothing else. It replaces
/// the bare status text those requests used to answer, which said "no page
/// session under this key" to a person who had done nothing wrong.
///
/// The status code is the caller's and does not change; this is only the
/// body. It carries the stylesheet and no script, so it is served under the
/// same policy as every `/ui` response and needs nothing more from it.
///
/// ## Examples
///
/// ```gleam
/// // page.refusal(ending.PageEnded, "0198c0de-...")
/// ```
pub fn refusal(reason: Ending, session_id: String) -> String {
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  <> "<title>Loom</title>"
  <> "<link rel=\"stylesheet\" href=\""
  <> asset_path(stylesheet_asset)
  <> "\"></head><body>"
  <> "<section class=\"ended-notice ended-document\" role=\"alert\">"
  <> "<p class=\"ended-headline\">"
  <> houdini.escape(ending.headline(reason))
  <> "</p><p class=\"ended-advice\">"
  <> houdini.escape(ending.advice(reason, session_id))
  <> "</p></section></body></html>\n"
}

/// The page the ticket exchange answers with. Its body names the keyed page
/// to move to and the tab's nonce, as data attributes; its script, which
/// runs at the end of the body, keeps the nonce in `sessionStorage` and
/// replaces the location with the keyed page. That navigation is
/// same-origin, so it carries the new `SameSite=Strict` cookie, and the
/// replace keeps the ticket's URL out of the history.
///
/// ## Examples
///
/// ```gleam
/// // page.enter("/ui/p/abc/sessions/S", nonce)
/// ```
pub fn enter(next: String, nonce: String) -> String {
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<title>Loom</title>"
  <> "</head><body data-next=\""
  <> houdini.escape(next)
  <> "\" data-nonce=\""
  <> houdini.escape(nonce)
  <> "\">"
  <> "<script src=\""
  <> asset_path(enter_asset)
  <> "\"></script>"
  <> "</body></html>\n"
}

/// The `sessionStorage` item the nonce is kept under. The two scripts in
/// `assets/` spell the same name; the daemon's route tests check that the
/// served scripts carry it.
pub const nonce_item = "loom-page-nonce"

/// The content security policy for every `/ui` response, for a request
/// whose `Host` header is `host`.
///
/// `style-src-attr 'unsafe-inline'` allows only `style` attributes, which
/// Lustre's client runtime sets directly; stylesheets and scripts must come
/// from this origin. The WebSocket origin is named as well as `'self'` for
/// browsers that do not map `'self'` onto `ws:`.
///
/// ## Examples
///
/// ```gleam
/// // page.content_security_policy("127.0.0.1:4000")
/// ```
pub fn content_security_policy(host: String) -> String {
  "default-src 'none'; script-src 'self'; style-src 'self'; "
  <> "style-src-attr 'unsafe-inline'; connect-src 'self' ws://"
  <> host
  <> "; img-src 'self'; base-uri 'none'; form-action 'none'; "
  <> "frame-ancestors 'none'"
}

/// The path an asset is served at.
///
/// ## Examples
///
/// ```gleam
/// assert page.asset_path("web_view.css") == "/ui/assets/web_view.css"
/// ```
pub fn asset_path(name: String) -> String {
  prefix <> "/assets/" <> name
}

/// Where one of the page's own assets (`stylesheet_asset`, `enter_asset`,
/// `page_asset`, `client_asset`) is on disk, inside this package's own
/// `priv/static` directory. The sources are in `packages/web_client`, and
/// `make gen-client` builds them here; `make client-check` fails when a
/// committed output has drifted from its sources.
///
/// ## Examples
///
/// ```gleam
/// // page.static_file(page.stylesheet_asset)
/// ```
pub fn static_file(name: String) -> Result(String, Nil) {
  application.priv_directory("web_view")
  |> result.map(fn(directory) { directory <> "/static/" <> name })
}

/// Where Lustre's client runtime is on disk, inside the `lustre`
/// application's `priv` directory.
///
/// ## Examples
///
/// ```gleam
/// // page.runtime_file()
/// ```
pub fn runtime_file() -> Result(String, Nil) {
  application.priv_directory("lustre")
  |> result.map(fn(directory) {
    directory <> "/static/lustre-server-component.min.mjs"
  })
}
