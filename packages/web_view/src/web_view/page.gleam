//// The documents the daemon serves around the component: the page shell,
//// the ticket exchange's hand-off page, the stylesheet, the hand-off script
//// and the content security policy they are served under.
////
//// All of it is fixed text with no inline script and no inline style, which
//// is what lets the policy say `script-src 'self'` and `style-src 'self'`.
//// The only value interpolated into a document is the session identity,
//// which the router has already parsed as a canonical ID and which is
//// escaped here all the same. Lustre's client runtime is served from the
//// `lustre` application's own `priv` directory, so the file a browser runs
//// is the one the pinned package shipped.

import gleam/erlang/application
import gleam/result
import houdini

/// The route prefix every view path lives under.
pub const prefix = "/ui"

/// The name Lustre's client runtime is served under. The version is part
/// of the name so a browser never runs a cached runtime against a newer
/// server component.
pub const runtime_asset = "lustre-server-component-5.7.1.mjs"

/// The page's stylesheet.
pub const stylesheet_asset = "web_view.css"

/// The script the exchange page runs to move to the session page.
pub const enter_asset = "web_view_enter.js"

/// The page for one session: a shell holding one server component whose
/// socket is `/ui/sessions/<id>/ws`.
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
  <> "</head><body>"
  <> "<lustre-server-component route=\""
  <> prefix
  <> "/sessions/"
  <> id
  <> "/ws\"></lustre-server-component>"
  <> "</body></html>\n"
}

/// The page the ticket exchange answers with. Its script replaces the
/// location with the session page, which the browser loads as a same-origin
/// navigation and so sends the new `SameSite=Strict` cookie with, and which
/// keeps the ticket's URL out of the history.
///
/// ## Examples
///
/// ```gleam
/// // page.enter()
/// ```
pub fn enter() -> String {
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<title>Loom</title>"
  <> "<script src=\""
  <> asset_path(enter_asset)
  <> "\"></script>"
  <> "</head><body></body></html>\n"
}

/// The exchange page's script.
///
/// ## Examples
///
/// ```gleam
/// // page.enter_script()
/// ```
pub fn enter_script() -> String {
  "location.replace(location.pathname);\n"
}

/// The page's stylesheet: legible lines and nothing more.
///
/// ## Examples
///
/// ```gleam
/// // page.stylesheet()
/// ```
pub fn stylesheet() -> String {
  "body{margin:0;font:14px/1.45 ui-monospace,Menlo,monospace;}\n"
  <> "main.loom-session{max-width:100ch;margin:0 auto;padding:1rem;}\n"
  <> "header h1{font-size:1rem;margin:0;}\n"
  <> "header .status{margin:0 0 1rem 0;opacity:.7;}\n"
  <> "pre.line{margin:0;white-space:pre-wrap;word-break:break-word;}\n"
  <> "pre.line.user{font-weight:bold;}\n"
  <> "pre.line.system,pre.line.reasoning,pre.line.reasoning-digest{opacity:.7;}\n"
  <> "pre.line.failure,pre.line.tool-failure{color:#b00020;}\n"
  <> "pre.line.spacer{min-height:1em;}\n"
}

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
