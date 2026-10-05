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
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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

/// The script the resume page runs to post the login nonce.
pub const resume_asset = "web_view_resume.js"

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

/// Where a browser login's pages live: `/ui/l/<key>`, the path the login's
/// cookie is scoped to (protocol-change/065).
///
/// ## Examples
///
/// ```gleam
/// assert page.login_prefix("abc") == "/ui/l/abc"
/// ```
pub fn login_prefix(key: String) -> String {
  prefix <> "/l/" <> key
}

/// The bookmark a browser login's person keeps: the address that resumes a
/// home page while the login lasts.
///
/// ## Examples
///
/// ```gleam
/// assert page.login_home_path("abc") == "/ui/l/abc/home"
/// ```
pub fn login_home_path(key: String) -> String {
  login_prefix(key) <> "/home"
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

/// The address that exchanges a ticket for a page of one session. `loom ui`
/// opens it, and an operator's page navigates to it to open another session
/// (protocol-change/051, the addendum on switching sessions). The client's
/// `web_client/switch_rule` accepts exactly this shape and no other.
///
/// ## Examples
///
/// ```gleam
/// assert page.exchange_path("S", "t") == "/ui/sessions/S?ticket=t"
/// ```
pub fn exchange_path(session_id: String, ticket: String) -> String {
  prefix <> "/sessions/" <> session_id <> "?ticket=" <> ticket
}

/// The keyed address of the principal's home page
/// (protocol-change/065). Its socket is this address and `/ws`, which is what
/// the page's script derives from `location.pathname`.
///
/// ## Examples
///
/// ```gleam
/// assert page.home_path("abc") == "/ui/p/abc/home"
/// ```
pub fn home_path(key: String) -> String {
  keyed_prefix(key) <> "/home"
}

/// The address that exchanges a ticket for a home page. `loom ui` with no
/// session opens it.
///
/// ## Examples
///
/// ```gleam
/// assert page.home_exchange_path("t") == "/ui/home?ticket=t"
/// ```
pub fn home_exchange_path(ticket: String) -> String {
  prefix <> "/home?ticket=" <> ticket
}

/// The keyed address of the owner's admin page (protocol-change/065, the
/// fifth pull request). Its socket is this address and `/ws`, as the home's is.
///
/// ## Examples
///
/// ```gleam
/// assert page.admin_path("abc") == "/ui/p/abc/admin"
/// ```
pub fn admin_path(key: String) -> String {
  keyed_prefix(key) <> "/admin"
}

/// The address that exchanges a ticket for an admin page. The home's "Admin"
/// button navigates to it, and the client's `web_client/switch_rule` accepts
/// exactly this shape and the two others.
///
/// ## Examples
///
/// ```gleam
/// assert page.admin_exchange_path("t") == "/ui/admin?ticket=t"
/// ```
pub fn admin_exchange_path(ticket: String) -> String {
  prefix <> "/admin?ticket=" <> ticket
}

/// The title of a session page until the component has connected and
/// `<loom-title>` has read the session's name from the bar. It is the product's
/// name alone: the shell knows the session only by its identity, which names
/// nothing a person could tell tabs apart by.
pub const session_title = "Loom"

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
/// The paragraph sits inside `<loom-waiting>` (`web_client/waiting`), which
/// shows it and, after five seconds with no socket, replaces it with the ended
/// document's shape drawn from fixed words. A page that connects hides all of
/// it with the rest of the light DOM, so the element costs a connected page
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// // page.shell("0198c0de-...")
/// ```
pub fn shell(session_id: String) -> String {
  component_document(session_title, waiting_notice(session_id))
}

/// The page for the home: the same shell and scripts as a session's, with
/// the home's own title and waiting paragraph. The page's script derives the
/// socket's route from the address it was served at, so nothing in the
/// document names the home.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(page.home_shell(), "Home — Loom")
/// ```
pub fn home_shell() -> String {
  component_document("Home — Loom", home_waiting_notice())
}

/// The page for the admin page: the same shell and scripts as the home's, with
/// the admin page's own title and waiting paragraph.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(page.admin_shell(), "Admin — Loom")
/// ```
pub fn admin_shell() -> String {
  component_document("Admin — Loom", admin_waiting_notice())
}

// A shell holding one server component, titled `title` (escaped here) and
// with `waiting` as the paragraph shown while the component has no socket.
// The title is fixed words and never a session's identity or name: the home
// and the admin page name themselves, and a session page says only the product
// until `<loom-title>` (`web_client/title`) reads the name its bar draws.
fn component_document(title: String, waiting: String) -> String {
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  <> "<title>"
  <> houdini.escape(title)
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
  <> "<lustre-server-component><loom-waiting><p class=\"page-note\">"
  <> houdini.escape(waiting)
  <> "</p></loom-waiting></lustre-server-component>"
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
  <> "starting, the session may not be open (open it again), this page may "
  <> "have ended, or this tab may have lost its key for the page. Reload it. "
  <> "If it stays like this, run loom ui --session "
  <> session_id
  <> " for a fresh link."
}

/// The document a browser gets when it asks for a page that cannot be
/// served: the reason class and what to do, and nothing else. It replaces
/// the bare status text those requests used to answer, which said "no page
/// session under this key" to a person who had done nothing wrong.
///
/// The status code is the caller's and does not change; this is only the
/// body. It carries the brand, the stylesheet and the client bundle, whose
/// `<loom-copy>` element draws the command for a fresh link with a copy button.
/// The bundle is the page's own file from this origin, so the document is served
/// under the same policy as every `/ui` response and needs nothing more from
/// it.
///
/// ## Examples
///
/// ```gleam
/// // page.refusal(ending.PageEnded, "0198c0de-...")
/// ```
pub fn refusal(reason: Ending, session_id: String) -> String {
  let advice = ending.advised(reason, session_id)

  // `<loom-copy>` copies only a command whose identity is hexadecimal digits
  // and hyphens, and draws nothing for any other. An identity that is not one
  // (the router answers an unparsed route with its placeholder) gets no box
  // rather than a box the element would blank.
  let advice = case copyable_identity(session_id) {
    True -> advice
    False -> ending.Advice(..advice, command: None)
  }
  ended_document(ending.headline(reason), advice, way_for(reason))
}

// Whether `identity` has the shape `<loom-copy>` accepts in a `loom ui
// --session` command: one to 64 hexadecimal digits and hyphens.
fn copyable_identity(identity: String) -> Bool {
  let graphemes = string.to_graphemes(identity)
  graphemes != []
  && list.length(graphemes) <= 64
  && list.all(graphemes, fn(character) {
    string.contains("0123456789abcdefABCDEF-", character)
  })
}

/// What a home page says while it has no socket: the daemon may still be
/// starting, the page may have ended, or the tab may have lost its key.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(page.home_waiting_notice(), "run loom ui")
/// ```
pub fn home_waiting_notice() -> String {
  "This page is not connected to the daemon. The daemon may still be "
  <> "starting, this page may have ended, or this tab may have lost its key "
  <> "for the page. Reload it. If it stays like this, run loom ui for a "
  <> "fresh link."
}

/// What an admin page says while it has no socket: the daemon may still be
/// starting, the page may have ended (it lasts fifteen minutes), or the tab may
/// have lost its key. The fresh link is the home's "Admin" button.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(page.admin_waiting_notice(), "fifteen minutes")
/// ```
pub fn admin_waiting_notice() -> String {
  "This page is not connected to the daemon. The daemon may still be "
  <> "starting, this page may have ended (an admin page lasts fifteen "
  <> "minutes), or this tab may have lost its key for the page. Reload it. "
  <> "If it stays like this, run loom ui and press Admin on the home page "
  <> "for a fresh one."
}

/// `refusal` for an admin page: the same document with the admin page's
/// advice, which names `loom ui` and the home's "Admin" button.
///
/// ## Examples
///
/// ```gleam
/// // page.admin_refusal(ending.PageEnded)
/// ```
pub fn admin_refusal(reason: Ending) -> String {
  ended_document(
    ending.admin_headline(reason),
    ending.admin_advised(reason),
    way_for(reason),
  )
}

/// `refusal` for a home page: the same document with the home's advice, which
/// names `loom ui` and no session.
///
/// ## Examples
///
/// ```gleam
/// // page.home_refusal(ending.PageEnded)
/// ```
pub fn home_refusal(reason: Ending) -> String {
  ended_document(
    ending.home_headline(reason),
    ending.home_advised(reason),
    way_for(reason),
  )
}

// What an ended document offers besides the command. A spent ticket reached
// by Back or a reload is a link the person already used, so the page they used
// it for may still be a step away in the history: the document draws a Back
// control that only moves the browser (`<loom-back>`, `web_client/back`) and
// mints nothing. A browser whose sign-in ended may hold no `loom` at all, so
// its document also names the claim form, the way back in for a person who was
// invited. Every other ending has neither.
type Way {
  GoBack
  ClaimLink
  NoWay
}

fn way_for(reason: Ending) -> Way {
  case reason {
    ending.LinkExpired -> GoBack
    _ -> NoWay
  }
}

// The document a refused request is answered with: the brand, a headline, the
// advice's lead, and the command that mints a fresh link as a `<loom-copy>`
// box. The box's light content is the same command in a `code` element, which
// shows until the client bundle registers the element and which is all a
// browser without scripts sees. The only script is the page's own client
// bundle, from this origin, so the policy is the one every `/ui` response has.
fn ended_document(headline: String, advice: ending.Advice, way: Way) -> String {
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  <> "<title>Loom</title>"
  <> "<link rel=\"stylesheet\" href=\""
  <> asset_path(stylesheet_asset)
  <> "\"><script type=\"module\" src=\""
  <> asset_path(client_asset)
  <> "\"></script></head><body><main class=\"ended-page\">"
  <> "<section class=\"ended-document\" role=\"alert\">"
  <> "<p class=\"ended-brand\">Loom</p>"
  <> "<p class=\"ended-headline\">"
  <> houdini.escape(headline)
  <> "</p><p class=\"ended-advice\">"
  <> houdini.escape(advice.lead)
  <> "</p>"
  <> fresh_link_box(advice.command, way)
  <> way_control(way)
  <> "</section></main></body></html>\n"
}

// What `way` adds after the command's box, or nothing. The Back control's
// light content is the word it shows until the client bundle registers it. The
// claim link is a fixed same-origin address.
fn way_control(way: Way) -> String {
  case way {
    GoBack -> "<loom-back>Go back</loom-back>"
    ClaimLink ->
      "<p class=\"ended-advice\">Otherwise ask the person who invited you "
      <> "for a new invitation and accept it at <a class=\"ended-link\" href=\""
      <> claim_path
      <> "\">"
      <> claim_path
      <> "</a>.</p>"
    NoWay -> ""
  }
}

// The command that mints a fresh link and a button that copies it, or nothing
// for an ending a fresh link would not help.
fn fresh_link_box(command: Option(String), way: Way) -> String {
  case command {
    None -> ""
    Some(command) -> {
      let escaped = houdini.escape(command)
      let words = case way {
        ClaimLink -> "If you use loom, run this in a terminal for a fresh link."
        GoBack | NoWay -> "Run this in a terminal for a fresh link."
      }
      "<p class=\"ended-advice\">"
      <> words
      <> "</p>"
      <> "<loom-copy subject=\"link\" text=\""
      <> escaped
      <> "\"><code class=\"ended-command\">"
      <> escaped
      <> "</code></loom-copy>"
    }
  }
}

/// The page for a browser's visit to its bookmark: a fixed document whose
/// script reads the login nonce this browser kept and posts it, in a form to
/// this same address, so the daemon can verify the login (protocol-change/065).
/// A browser with no nonce is told what to do instead. The document names no
/// key and no principal: the script takes the key from the address it was
/// served at, and the form posts to that address.
///
/// It is the one document, with the claim form, served under a policy that lets
/// a form submit to this origin (`OwnForms`).
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(page.login_page(), "name=\"nonce\"")
/// ```
pub fn login_page() -> String {
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  <> "<title>Loom</title>"
  <> "<link rel=\"stylesheet\" href=\""
  <> asset_path(stylesheet_asset)
  <> "\"><script type=\"module\" src=\""
  <> asset_path(client_asset)
  <> "\"></script></head><body><main class=\"ended-page\">"
  <> "<section class=\"ended-document\" role=\"status\">"
  <> "<p class=\"ended-brand\">Loom</p>"
  <> "<p class=\"ended-headline\" id=\"login-status\">Signing in.</p>"
  <> "<div id=\"login-help\" hidden>"
  <> fresh_link_box(Some("loom ui"), ClaimLink)
  <> way_control(ClaimLink)
  <> "</div>"
  <> "<form id=\"login-form\" method=\"post\" action=\"\" hidden>"
  <> "<input type=\"hidden\" name=\"nonce\" value=\"\"></form>"
  <> "<noscript><p class=\"ended-advice\">"
  <> houdini.escape(login_script_notice())
  <> "</p></noscript>"
  <> "</section></main><script src=\""
  <> asset_path(resume_asset)
  <> "\"></script></body></html>\n"
}

/// What the resume page says when this browser holds no nonce for the login:
/// a new profile, cleared storage or a private window. The way back in is
/// `loom ui` for a person who has it, and for one who does not, a new
/// invitation accepted at the claim form. The document draws the first
/// sentence with the command in a copy box and the second with the address as
/// a link, from the same pieces the refused sign-in's document uses; this is
/// the same words as one string.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(page.login_unknown_notice(), "loom ui")
/// assert string.contains(page.login_unknown_notice(), "/ui/claim")
/// ```
pub fn login_unknown_notice() -> String {
  "If you use loom, run loom ui in a terminal for a fresh link. Otherwise "
  <> "ask the person who invited you for a new invitation and accept it at "
  <> claim_path
  <> "."
}

fn login_script_notice() -> String {
  "Signing in needs scripts. Run loom ui in a terminal and open the link "
  <> "it prints."
}

/// The document a sign-in that was refused is answered with: fixed words and
/// the command that signs in again, and nothing the request said. The status is
/// the caller's, and every refusal reads the same, so the answer does not tell
/// a forged token from an expired or revoked one.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(page.login_refused(), "loom ui")
/// ```
pub fn login_refused() -> String {
  ended_document(
    "This browser is not signed in.",
    ending.Advice(
      lead: "The sign-in has ended, was signed out, or did not match this "
        <> "browser.",
      command: Some("loom ui"),
    ),
    ClaimLink,
  )
}

/// Where the claim form lives and posts: `GET` draws it and `POST` redeems.
pub const claim_path = "/ui/claim"

/// Why a claim the form posted was refused. Each is a fixed paragraph over the
/// form, drawn again so the person can try another token or name, and none
/// repeats anything the request carried.
pub type ClaimNotice {
  /// The token was not `loomclaim_` and 64 lowercase hexadecimal digits, which
  /// is also what a bearer or a login looks like: it was refused before the
  /// catalogue was asked anything.
  NotAClaim

  /// No such claim, or the owner withdrew it.
  ClaimUnknown

  /// The claim was open and its time ran out.
  ClaimExpired

  /// The claim is spent, or its member already holds a credential.
  ClaimUsed

  /// The name is blank, too long or holds a control character. The claim
  /// bound nothing and is still open.
  NameRefused

  /// The daemon could not answer, or another redemption of the same claim is
  /// in progress. The claim may be open.
  ClaimBusy
}

/// The claim form: a fixed document with two fields, the token and an optional
/// name, that posts to `claim_path`, and no script. It is the one document, with
/// the resume page, served under a policy that lets a form submit to this origin
/// (`OwnForms`). The words under the name field are the inviter's name being
/// the default. A refusal draws the same form with `notice` above it
/// (protocol-change/065, PR 9).
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(page.claim_page(None), "name=\"token\"")
/// ```
pub fn claim_page(notice: Option(ClaimNotice)) -> String {
  let refusal = case notice {
    Some(why) ->
      "<p class=\"claim-notice\" role=\"alert\">"
      <> houdini.escape(claim_notice(why))
      <> "</p>"
    None -> ""
  }
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  <> "<title>Loom</title>"
  <> "<link rel=\"stylesheet\" href=\""
  <> asset_path(stylesheet_asset)
  <> "\"></head><body><main class=\"ended-page\">"
  <> "<section class=\"ended-document\">"
  <> "<p class=\"ended-brand\">Loom</p>"
  <> "<p class=\"claim-title\">Accept your invitation</p>"
  <> "<p class=\"ended-advice\">Paste the claim token you were sent, and "
  <> "choose the name others will see.</p>"
  <> refusal
  <> "<form class=\"claim-form\" method=\"post\" action=\""
  <> claim_path
  <> "\">"
  <> "<label class=\"claim-field\"><span class=\"claim-label\">Claim token"
  <> "</span><input class=\"claim-input\" type=\"text\" name=\"token\" "
  <> "autocomplete=\"off\" autocapitalize=\"off\" spellcheck=\"false\" "
  <> "required></label>"
  <> "<label class=\"claim-field\"><span class=\"claim-label\">Your name"
  <> "</span><input class=\"claim-input\" type=\"text\" name=\"name\" "
  <> "autocomplete=\"off\" maxlength=\"256\"><span class=\"claim-hint\">"
  <> houdini.escape(claim_name_hint())
  <> "</span></label>"
  <> "<button class=\"claim-submit\" type=\"submit\">Accept</button></form>"
  <> "<p class=\"ended-advice\">"
  <> houdini.escape(claim_keep_notice())
  <> "</p>"
  <> "</section></main></body></html>\n"
}

/// What the form says under the name field.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(page.claim_name_hint(), "inviter chose")
/// ```
pub fn claim_name_hint() -> String {
  "Leave empty to keep the name the inviter chose."
}

/// The words a refused claim is answered with, one fixed paragraph for each
/// reason. None of them can tell a person who holds a claim anything they could
/// not learn from the claim.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(page.claim_notice(page.ClaimExpired), "expired")
/// ```
pub fn claim_notice(notice: ClaimNotice) -> String {
  case notice {
    NotAClaim ->
      "That is not a claim token. A claim token starts with loomclaim_."
    ClaimUnknown ->
      "This claim is not valid. It was never issued here, or the owner "
      <> "withdrew it. Ask the owner for a new invitation."
    ClaimExpired ->
      "This claim has expired. Ask the owner for a new invitation."
    ClaimUsed ->
      "This claim has already been used. If that was not you, tell the "
      <> "owner, who can issue a new claim."
    NameRefused ->
      "That name cannot be used. A name is not blank, is at most 256 bytes "
      <> "and holds no control characters. Nothing was claimed; try again."
    ClaimBusy ->
      "The daemon could not take the claim just now. Nothing was lost; try "
      <> "again in a moment."
  }
}

fn claim_keep_notice() -> String {
  "Accepting signs this browser in for thirty days. There is nothing else to "
  <> "keep, and a claim works once."
}

/// The page the ticket exchange answers with. Its body names the keyed page
/// to move to and the tab's nonce, as data attributes; its script, which
/// runs at the end of the body, keeps the nonce in `sessionStorage` under the
/// keyed page's own item (`nonce_item` and the key in `next`) and replaces the
/// location with the keyed page. That navigation is same-origin, so it carries
/// the new `SameSite=Strict` cookie, and the replace keeps the ticket's URL
/// out of the history, so Back never lands on a spent ticket.
///
/// ## Examples
///
/// ```gleam
/// // page.enter("/ui/p/abc/sessions/S", nonce)
/// ```
pub fn enter(next: String, nonce: String) -> String {
  enter_document(next, nonce, "")
}

/// `enter` for an exchange that also set a browser login: the body carries the
/// login's key and nonce as well, and the same script keeps the nonce in
/// `localStorage` under `loom.login.<key>` before it moves on
/// (protocol-change/065). The nonce is delivered here once and the daemon keeps
/// only its digest, inside the token.
///
/// ## Examples
///
/// ```gleam
/// // page.enter_remembered("/ui/p/abc/home", nonce, login_key, login_nonce)
/// ```
pub fn enter_remembered(
  next: String,
  nonce: String,
  login_key: String,
  login_nonce: String,
) -> String {
  enter_document(
    next,
    nonce,
    " data-login-key=\""
      <> houdini.escape(login_key)
      <> "\" data-login-nonce=\""
      <> houdini.escape(login_nonce)
      <> "\"",
  )
}

// The exchange's document, with `login` the login's two attributes, or nothing.
fn enter_document(next: String, nonce: String, login: String) -> String {
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<title>Loom</title>"
  <> "</head><body data-next=\""
  <> houdini.escape(next)
  <> "\" data-nonce=\""
  <> houdini.escape(nonce)
  <> "\""
  <> login
  <> ">"
  <> "<script src=\""
  <> asset_path(enter_asset)
  <> "\"></script>"
  <> "</body></html>\n"
}

/// The `localStorage` item prefix a login's nonce is kept under: the item is
/// this and the login key. The enter and resume scripts spell the same name; the
/// daemon's route tests check that the served scripts carry it.
pub const login_nonce_item = "loom.login."

/// The `sessionStorage` item prefix a page's nonce is kept under: the item is
/// this and the page's key, so each keyed page the tab has visited keeps its
/// own nonce and Back can return to it (protocol-change/051, the addendum on
/// navigation). The two scripts in `assets/` spell the same prefix; the
/// daemon's route tests check that the served scripts carry it.
pub const nonce_item = "loom-page-nonce."

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
  content_security_policy_for(host, NoForms)
}

/// Whether a document may submit a form.
pub type Forms {
  /// No form submits anywhere: `form-action 'none'`, the policy of every `/ui`
  /// document but one.
  NoForms

  /// A form may submit to this origin and to no other: `form-action 'self'`.
  /// Only the resume page and the claim form are served so (protocol-change/065).
  OwnForms
}

/// `content_security_policy` for a document that may hold a form. Nothing else
/// in the policy differs.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(
///   page.content_security_policy_for("127.0.0.1:4000", page.OwnForms),
///   "form-action 'self'",
/// )
/// ```
pub fn content_security_policy_for(host: String, forms: Forms) -> String {
  let action = case forms {
    NoForms -> "'none'"
    OwnForms -> "'self'"
  }
  "default-src 'none'; script-src 'self'; style-src 'self'; "
  <> "style-src-attr 'unsafe-inline'; connect-src 'self' ws://"
  <> host
  <> "; img-src 'self'; base-uri 'none'; form-action "
  <> action
  <> "; frame-ancestors 'none'"
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
