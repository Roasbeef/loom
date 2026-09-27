//// The documents the daemon serves around the component: the page shell,
//// the ticket exchange's hand-off page, the stylesheet, the two scripts and
//// the content security policy they are served under.
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

/// The route prefix every view path lives under.
pub const prefix = "/ui"

/// The name Lustre's client runtime is served under. The version is part
/// of the name so a browser never runs a cached runtime against a newer
/// server component.
pub const runtime_asset = "lustre-server-component-5.7.1.mjs"

/// The page's stylesheet.
pub const stylesheet_asset = "web_view.css"

/// The script the exchange page runs to keep the nonce and move to the
/// session page.
pub const enter_asset = "web_view_enter.js"

/// The script the session page runs to connect its component with the
/// nonce.
pub const page_asset = "web_view_page.js"

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
  <> "<lustre-server-component></lustre-server-component>"
  <> "<script src=\""
  <> asset_path(page_asset)
  <> "\"></script>"
  <> "</body></html>\n"
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

/// The exchange page's script: keep the nonce for this tab, then move to
/// the keyed page. A `next` that is not a keyed page path is not followed.
///
/// ## Examples
///
/// ```gleam
/// // page.enter_script()
/// ```
pub fn enter_script() -> String {
  "(function () {\n"
  <> "  var body = document.body;\n"
  <> "  var next = body.getAttribute(\"data-next\") || \"\";\n"
  <> "  var nonce = body.getAttribute(\"data-nonce\") || \"\";\n"
  <> "  if (next.indexOf(\""
  <> prefix
  <> "/p/\") !== 0 || nonce === \"\") { return; }\n"
  <> "  try { sessionStorage.setItem(\""
  <> nonce_item
  <> "\", nonce); } catch (e) { return; }\n"
  <> "  location.replace(next);\n"
  <> "})();\n"
}

/// The `sessionStorage` item the nonce is kept under.
pub const nonce_item = "loom-page-nonce"

/// The session page's script: hand the tab's nonce to the component as its
/// `csrf-token`, then give it its route, so the client runtime opens the
/// socket with the nonce in its query. A tab with no nonce opens nothing
/// and says to run `loom --ui` again.
///
/// ## Examples
///
/// ```gleam
/// // page.page_script()
/// ```
pub fn page_script() -> String {
  "(function () {\n"
  <> "  var view = document.querySelector(\"lustre-server-component\");\n"
  <> "  if (!view) { return; }\n"
  <> "  var nonce = null;\n"
  <> "  try { nonce = sessionStorage.getItem(\""
  <> nonce_item
  <> "\"); } catch (e) { nonce = null; }\n"
  <> "  if (!nonce) {\n"
  <> "    var note = document.createElement(\"p\");\n"
  <> "    note.className = \"page-note\";\n"
  <> "    note.textContent = \"This tab has no key for the page. Run loom --ui again and open the new link.\";\n"
  <> "    document.body.appendChild(note);\n"
  <> "    return;\n"
  <> "  }\n"
  <> "  view.setAttribute(\"csrf-token\", nonce);\n"
  <> "  view.setAttribute(\"route\", location.pathname + \"/ws\");\n"
  <> "})();\n"
}

/// The page's stylesheet: the web UI's dark tokens, legible transcript
/// lines, the composer, and the approval card, which is drawn in a face no
/// transcript line uses so that nothing the session writes can pass for it.
///
/// ## Examples
///
/// ```gleam
/// // page.stylesheet()
/// ```
pub fn stylesheet() -> String {
  ":root{--bg:#181B1F;--bg-raised:#1F252B;--bg-user:#26221D;--bg-agent:#142023;\n"
  <> "--fg:#E7EDF5;--fg-quiet:#A0ABB8;--divider:#3C4A5B;--signal:#FFBD69;\n"
  <> "--current:#6EDBE8;--danger:#FF8E9B;--added:#8ED6A1;color-scheme:dark;}\n"
  <> "body{margin:0;background:var(--bg);color:var(--fg);\n"
  <> "font:14px/1.5 'IBM Plex Sans',Inter,system-ui,sans-serif;}\n"
  <> "main.loom-session{max-width:100ch;margin:0 auto;padding:1rem;}\n"
  <> "header h1{font-size:1rem;margin:0;font-family:'IBM Plex Mono','JetBrains Mono',ui-monospace,monospace;}\n"
  <> "header .status{margin:0 0 1rem 0;color:var(--fg-quiet);font-size:13px;}\n"
  <> "pre.line{margin:0;white-space:pre-wrap;word-break:break-word;\n"
  <> "font:14px/1.4 'IBM Plex Mono','JetBrains Mono',ui-monospace,monospace;}\n"
  <> "pre.line.user{background:var(--bg-user);font-weight:600;}\n"
  <> "pre.line.assistant{background:var(--bg-agent);}\n"
  <> "pre.line.system,pre.line.reasoning,pre.line.reasoning-digest{color:var(--fg-quiet);}\n"
  <> "pre.line.failure,pre.line.tool-failure{color:var(--danger);}\n"
  <> "pre.line.spacer{min-height:1em;}\n"
  <> ".observer-bar{margin:1rem 0 0 0;padding:.75rem 1rem;border-top:1px solid var(--divider);\n"
  <> "color:var(--fg-quiet);font-size:13px;}\n"
  <> ".page-note{margin:1rem;color:var(--fg-quiet);}\n"
  <> "section.approvals{margin:1rem 0;}\n"
  <> "article.approval-card{background:var(--bg-raised);border:1px solid var(--signal);\n"
  <> "border-left:4px solid var(--signal);border-radius:6px;padding:.75rem 1rem;margin:.5rem 0;}\n"
  <> ".approval-head{margin:0 0 .25rem 0;color:var(--signal);font-size:12px;\n"
  <> "font-family:'IBM Plex Mono',ui-monospace,monospace;text-transform:lowercase;}\n"
  <> ".approval-question{margin:0 0 .5rem 0;font-weight:600;}\n"
  <> "pre.approval-action{margin:0 0 .5rem 0;padding:.5rem;background:var(--bg);\n"
  <> "white-space:pre-wrap;word-break:break-word;font:13px/1.4 'IBM Plex Mono',ui-monospace,monospace;}\n"
  <> "ul.approval-authority{margin:0 0 .75rem 0;padding-left:1.25rem;color:var(--fg-quiet);\n"
  <> "font:12px/1.4 'IBM Plex Mono',ui-monospace,monospace;}\n"
  <> ".approval-actions{display:flex;gap:.5rem;}\n"
  <> "form.composer{margin-top:1rem;background:var(--bg-raised);border:1px solid var(--divider);\n"
  <> "border-radius:6px;padding:.75rem;}\n"
  <> ".identity{display:flex;gap:.5rem;align-items:center;font-size:12px;margin-bottom:.5rem;}\n"
  <> ".identity-name{color:var(--fg);}\n"
  <> ".role-badge{border:1px solid var(--signal);color:var(--signal);border-radius:999px;padding:0 .5rem;}\n"
  <> ".addressed{color:var(--current);font-family:'IBM Plex Mono',ui-monospace,monospace;}\n"
  <> ".editor textarea{box-sizing:border-box;width:100%;background:var(--bg);color:var(--fg);\n"
  <> "border:1px solid var(--divider);border-radius:4px;padding:.5rem;font:inherit;resize:vertical;}\n"
  <> ".composer-actions{display:flex;gap:.5rem;align-items:center;justify-content:flex-end;margin-top:.5rem;}\n"
  <> ".notice{margin:0 auto 0 0;color:var(--fg-quiet);font-size:13px;}\n"
  <> ".notice.warned{color:var(--danger);}\n"
  <> "button{font:inherit;font-size:13px;border-radius:4px;padding:.3rem .8rem;cursor:pointer;\n"
  <> "border:1px solid var(--divider);background:var(--bg);color:var(--fg);}\n"
  <> "button.send,button.queue{border-color:var(--current);color:var(--current);}\n"
  <> "button.steer{border-color:var(--signal);color:var(--signal);}\n"
  <> "button.approval-deny{border-color:var(--danger);color:var(--danger);}\n"
  <> "button.approval-allow{border-color:var(--added);color:var(--added);}\n"
  <> "button:focus-visible,textarea:focus-visible{outline:2px solid var(--current);outline-offset:1px;}\n"
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
