//// The web view's tickets and UI sessions (protocol-change/051), owned by one
//// actor so that every mint, redemption and lookup happens in one mailbox.
////
//// A person's own `loom` asks for a ticket over its control connection
//// (`ui.link`). The browser presents the ticket once, and redeeming it
//// creates a UI session whose cookie the browser keeps. Two tables hold
//// them, and both are keyed by the SHA-256 digest of the secret, so the
//// actor never holds a plaintext ticket or cookie after it has handed one
//// out.
////
//// Redemption is single-use because it is serialized here. Two HTTP
//// handlers that present the same ticket at once reach this actor one after
//// the other: the first removes the ticket and the second finds nothing. A
//// check-then-delete split across two calls would let both succeed, which
//// is why redemption is one message and not a lookup followed by a delete.
////
//// Redeeming a ticket mints three secrets for the UI session it becomes
//// (protocol-change/051, the operator addendum): the cookie, the page key
//// the cookie's path is scoped to, and the page nonce the browser tab keeps
//// in `sessionStorage` and presents on the socket. The table keeps only
//// their digests. A principal may hold several UI sessions for one session
//// at once, an observer's tab beside an operator's, or two devices. Each
//// has its own cookie, key and nonce, so a redemption never touches
//// another page unless the principal already holds `max_pages` of them for
//// the session, and then it ends only the oldest (protocol-change/051, the
//// addendum on several pages).
////
//// A page's socket also leaves here the one way its images are read
//// (protocol-change/051, the addendum on images). A request for an image
//// arrives on an HTTP handler, which holds the page's cookie and nothing of
//// the component; the component holds the lane whose images are drawn. The
//// socket registers a function that asks its own component, under the page's
//// cookie, and the handler reads it back. The registration lives no longer
//// than the page: it is found only through a live UI session, and the sweep
//// drops what the sessions table has dropped.
//// The same actor keeps the page-minted invitations' allowance
//// (protocol-change/051, the addendum on inviting from the session page): how
//// many invitations a credential's pages have asked for lately, keyed by the
//// credential and not by any page, so that opening another page, or switching
//// from page to page, does not reset the count a stolen page is held to. The
//// owner's admin page (protocol-change/065, the fifth pull request) draws on the
//// same allowance for every change that grants access, an invitation, a rotation
//// or a role raised to operator, so the fourth grant in an hour across it and a
//// session page's invitation control is refused. An admin page is a third scope
//// beside a session's and the home's, redeemed only at its own exchange, and
//// lives `admin_ms` rather than `session_ms`.
////
//// A page and a ticket also know which browser login they belong to
//// (protocol-change/065, PR 8). A ticket that is `Remembered` sets a login when
//// it is exchanged, and every ticket carries the login of the context that
//// minted it (`Issuer`), so a device link inherits the issuing login's expiry
//// and a chain of tickets from one page cannot launder it. The table holds only
//// the login's fingerprint, expiry and key, never a token or a nonce. A grant
//// records how its page was reached (`Origin`): `Fresh` for a `loom ui`
//// exchange, a claim or a device link, and `Resumed` for one the login minted.
//// Only a fresh home may start an admin page or a device link, and a ticket a
//// page mints carries the minting page's origin, so a chain from a resumed home
//// stays resumed.
////
//// ## Flow
////
//// `start` → `mint` → `redeem` → `attach_login` → `lookup` → `still_open`
////
//// 1. `start` runs the actor, whose one mailbox `handle` reads.
//// 2. `mint`, `mint_before`, `mint_in`, `mint_device` and `mint_resumed` file a
////    ticket for a grant, and differ only in the deadline and the login the
////    ticket carries.
//// 3. `redeem` removes the ticket and, for a live one at its own exchange,
////    adds the page whose three secrets it hands back.
//// 4. `attach_login` records the login a remembered exchange set, once its row
////    exists.
//// 5. `lookup` finds a live page by its cookie, and `still_open` and
////    `open_until` are the check a page's socket repeats with every frame.
//// 6. `reserve_invite`, `reserve_creation` and `release_invite` keep the
////    credential's allowances in the same mailbox.
////
//// Each table is a per-key deadline table inside this one actor, which
//// `docs/weft.md` ("Per-key deadline tables stay") allows. Every read checks
//// the deadline itself, so an expired ticket or session is refused the
//// moment it expires; the periodic sweep only reclaims the memory of
//// entries nobody asked about again.

import broker/internal/call
import broker/internal/ffi_crypto
import broker/token
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/string
import host/bootstrap
import session_view/transcript_image
import storage/access
import telemetry/owner
import web_view/ending
import weft/actor

/// How long a ticket can be redeemed, in milliseconds.
pub const ticket_ms = 60_000

/// How long a device link's ticket can be redeemed, in milliseconds: ten
/// minutes, so a person has time to carry the link to another device
/// (protocol-change/065). A ticket for a page lives `ticket_ms`.
pub const device_ms = 600_000

/// How long a UI session lives from its exchange, in milliseconds: eight
/// hours, a working day. A page left open for a day's work keeps working,
/// and a cookie copied out of a browser stops working the same day.
///
/// The deadline is a ceiling on a chain of pages as well as on one. A page
/// opened by a ticket that another page minted (a session switch,
/// `mint_before`) ends at the earlier of that page's deadline and this long
/// from its own exchange, so switching from page to page never outlives the
/// page the chain started from, and a copied cookie cannot be renewed by
/// switching.
pub const session_ms = 28_800_000

/// How long an admin page lives from its exchange, in milliseconds: fifteen
/// minutes (protocol-change/065, the fifth pull request; 053's bound).
///
/// The admin page changes who may see the owner's sessions, so it is the page
/// a stolen cookie is worth most on and the one that lives shortest. The home
/// that minted it is unaffected when it ends, and the owner presses "Admin"
/// again for another. A page lives no longer than `Settings.session_ms` either,
/// so a table configured with a shorter page lifetime shortens this one too.
pub const admin_ms = 900_000

/// The most live UI sessions one principal holds for one session, and, as a
/// separate count, for its home and for its admin page (protocol-change/065):
/// each is a scope of its own, so opening homes never ends a session's page and
/// opening an admin page never ends a home.
///
/// The bound is on pages in this table, and so on the memory they hold: a
/// live page keeps a cookie, a key and a nonce, and while its browser is
/// connected, a socket, a relay process and a lane of up to 300 rows. It does
/// not bound sockets per page: one page's secrets can open several, as
/// before, and those are bounded by the root's admission capacity. A page
/// that is ended, by its deadline or by displacement, has its socket, relay
/// and lane torn down at its next frame, when the gateway revalidates it
/// (`check_binding`). Four covers what a person
/// does with one session: an observer tab, an operator tab, a second device,
/// and one spare.
///
/// A redemption at the bound ends the oldest page and adds the new one; it
/// is not refused. The daemon never learns that a tab was closed, because a
/// reload closes and reopens the same page's socket, so a closed tab's page
/// stays live until its eight hours end. A refusal would therefore lock a
/// person out of a long-running daemon after their fifth `loom ui` of the
/// day, with nothing to close. Ending the oldest keeps the newest four,
/// which are the ones a person can still be using.
pub const max_pages = ending.max_pages

/// How often the tables are swept, in milliseconds.
pub const sweep_ms = 60_000

/// The most grants of access the pages of one credential may make in
/// `invite_window_ms`: invitations from a session page, and from the admin page
/// invitations, rotations and roles raised to operator. The name is the
/// invitation's, which was the only grant a page could make when it was chosen.
///
/// A page's invitation is a claim that becomes a credential outliving the
/// page and every check the page is held to, so a page that a program other
/// than its owner's browser took (protocol-change/051, the addendum on
/// inviting from the session page) must not be able to mint many. Three covers an owner asking for two or three people in a sitting and the
/// press that had to be repeated, and it stops a program with the page's
/// three secrets from filling the catalogue with principals: at most 3 an
/// hour, 24 across the eight hours a page lives. The owner who needs more
/// invites from a terminal with `loomd access invite`, which has no such
/// limit and is not a page.
pub const invite_limit = 3

/// The window `invite_limit` is counted over, in milliseconds. It is the
/// lifetime of a page-minted claim (`web_view/invites.claim_ttl_ms`), so the
/// limit is also the most claims a credential's pages can have open and
/// unredeemed at once.
pub const invite_window_ms = 3_600_000

/// The most sessions the pages of one credential may create in
/// `creation_window_ms` (protocol-change/065, the fourth pull request).
///
/// A page's creation starts an agent and writes a catalogue row, so a page that
/// a program other than its owner's browser took must not be able to fill the
/// catalogue or the registry's slots. Ten covers an owner starting a few
/// sessions in a sitting and the press that had to be repeated, and it stops a
/// program with the page's three secrets at ten an hour. The owner who needs
/// more creates from a terminal, which has no such limit and is not a page. A
/// refused creation still costs its place, which frees within the hour.
pub const creation_limit = 10

/// The window `creation_limit` is counted over, in milliseconds.
pub const creation_window_ms = 3_600_000

/// How many worktree reads a credential's pages may start in
/// `worktree_read_window_ms`. A read is about twenty-six jailed Git calls on
/// the session's helper pool, which the agent's own tools share, so the count
/// is per credential and not per page: opening more sockets does not buy more
/// reads. Two in four seconds is one page's refresh rate (`web_view/worktrees`
/// asks at most once in four) with room for one reload.
pub const worktree_read_limit = 2

/// The window `worktree_read_limit` is counted over, in milliseconds.
pub const worktree_read_window_ms = 4000

/// What a page may be limited in the number of.
pub type Allowance {
  /// The invitations a credential's pages mint (`invite_limit`).
  Invitations

  /// The sessions a credential's pages create (`creation_limit`).
  Creations

  /// The worktree reads a credential's pages start (`worktree_read_limit`).
  WorktreeReads
}

/// What page a ticket opens, which is also the page the UI session it becomes
/// may be used for (protocol-change/065). The scope is part of the redemption:
/// a ticket is honoured only at the exchange of its own scope, so a session's
/// ticket cannot open a home and a home's cannot open a session.
pub type Scope {
  /// The page of one session. Every check a session page was held to before
  /// scopes existed applies to it unchanged.
  Session(id: String)

  /// The principal's home page, which lists the sessions the credential may
  /// see and is bound to no session.
  Home

  /// The owner's admin page (protocol-change/065, the fifth pull request),
  /// bound to no session. It lives `admin_ms`, and its ticket is redeemed only
  /// at the admin exchange, so a session's ticket and a home's both fail there.
  Admin
}

/// How a page was reached (protocol-change/065). The daemon writes it when it
/// mints a ticket, and a page never says it of itself. A page carries it onto
/// every ticket it mints, so a chain of switches from a resumed page stays
/// resumed, and a session's page knows it as the home it came from did.
pub type Origin {
  /// A `loom ui` exchange, a claim, or a device link: someone who held a
  /// credential or a link a moment ago opened it. Only a fresh home starts an
  /// admin page or a device link.
  Fresh

  /// A page the browser login minted when its bookmark was visited, or one
  /// reached from such a page. It lists and opens sessions and nothing more: a
  /// stolen bookmark cannot start the owner's admin page or make a second
  /// credential.
  Resumed
}

/// Whether exchanging a ticket sets a browser login as well as the page.
pub type Remember {
  /// The exchange sets the login cookie and delivers the login nonce: a `loom
  /// ui` home ticket without `--no-remember`, a device link, or a claim.
  Remembered

  /// The exchange sets the page only. A ticket a page mints for a switch or the
  /// way home is always this.
  Forgotten
}

/// The browser login a page or a ticket belongs to, as the table knows it: the
/// login's fingerprint, which identifies it and authenticates nothing, the
/// instant its token expires, in Unix milliseconds, and its login key, the path
/// of the bookmark the person keeps. A device link inherits the expiry, so no
/// family of logins outlives the one it began from. The key opens nothing
/// without the cookie and the nonce, which the table never holds.
pub type Issuer {
  Issuer(fingerprint: String, expires_at_ms: Int, key: String)
}

/// How long a ticket lives.
type Life {
  Brief
  Device
}

/// Which exchange a ticket is presented at. A ticket is honoured only at the
/// exchange of its own scope, whatever origin a home ticket carries.
pub type Exchange {
  /// `/ui/sessions/<id>`.
  SessionExchange(id: String)

  /// `/ui/home`.
  HomeExchange

  /// `/ui/admin`.
  AdminExchange
}

/// Which pages a link was minted for, which decides whether the page it
/// opens draws a way back to the home (protocol-change/065). The daemon
/// writes it when it mints and a page never says it of itself.
pub type Reach {
  /// A link `loom ui --session ID` printed, which a person may hand to
  /// someone who is to see one session and nothing around it.
  OneSession

  /// A home page, and every page opened from one, whose person has already
  /// seen the list of sessions.
  Workspace
}

/// What a ticket and the UI session it becomes stand for.
pub type Grant {
  Grant(
    /// The one page the ticket opens: a session's or the home.
    scope: Scope,
    /// The digest of the credential that asked for the ticket. Every later
    /// check re-authenticates it, so revoking that credential ends the UI
    /// session.
    credential: access.Digest,
    /// The principal that asked. The number of live UI sessions it holds
    /// for one session is bounded by `max_pages`.
    principal: String,
    /// The most the page may do, chosen when the link was minted: observer
    /// unless `loom ui --operate` asked for operator. It caps the
    /// membership role and never grants one (`ui_relay.capped`).
    ceiling: access.Role,
    /// What the link was minted for. Only the page's view reads it.
    reach: Reach,
    /// How the page was reached. Only a `Fresh` home may start an admin page or
    /// a device link, and every ticket a page mints carries its own.
    origin: Origin,
    /// Whether exchanging the ticket sets a browser login. Only an exchange
    /// reads it: the page it opens ignores it.
    remember: Remember,
  )
}

/// A live UI session: what it grants, and the digests of the page key its
/// cookie is scoped to and of the nonce its browser tab presents.
pub opaque type Page {
  Page(
    grant: Grant,
    key: String,
    nonce: String,
    /// The order pages were opened in, which is how the oldest is found
    /// when two share a millisecond.
    serial: Int,
    /// The login this page is the browser of: the one its exchange set, the one
    /// that resumed it, or the one the page that minted its ticket belonged to.
    /// Empty for a page opened with no login in play.
    login: Option(Issuer),
  )
}

/// A freshly minted ticket.
pub type Issued {
  Issued(
    /// The ticket's plaintext, which only the caller ever sees.
    ticket: String,
    /// The ticket's remaining lifetime, a duration and not an instant.
    expires_in_ms: Int,
  )
}

/// A redeemed ticket: the new UI session's three secrets, in plaintext for
/// the one response that hands them to the browser, and what it grants.
pub type Redeemed {
  Redeemed(
    cookie: String,
    key: String,
    nonce: String,
    grant: Grant,
    /// The login the ticket was minted in, if there was one. A `Remembered`
    /// exchange makes its new login inherit this one's expiry and name it as
    /// its parent.
    login: Option(Issuer),
  )
}

/// Why a ticket was not redeemed.
pub type Refusal {
  /// No live ticket has this value: it was never minted, it was already
  /// redeemed, or it expired.
  UnknownTicket

  /// The ticket is live but names another page than the exchange it was
  /// presented at: another session's, or the home's where a session's was
  /// expected and the reverse. It is spent all the same: a ticket presented
  /// where it does not belong has been copied somewhere it should not be,
  /// and a second try must not get another chance at it.
  OtherScope
}

/// The actor's clock and entropy, injected so a test can move time.
pub type Settings {
  Settings(
    /// A millisecond reading that only moves forward.
    now: fn() -> Int,
    /// The wall clock in Unix milliseconds, which a login's expiry is written
    /// in. It is a second clock because `now` is the monotonic one, whose zero is
    /// arbitrary: the two cannot be compared, and a ticket's login ends on the
    /// wall's time.
    wall: fn() -> Int,
    /// `n` random bytes.
    entropy: fn(Int) -> BitArray,
    /// A ticket's lifetime.
    ticket_ms: Int,
    /// A device link's ticket's lifetime.
    device_ms: Int,
    /// A UI session's lifetime.
    session_ms: Int,
  )
}

/// How a page's images are read: the image the page drew at a row's name and
/// position, or `Error(Nil)` when it drew none there or its component is gone.
/// The page socket makes one from its component and registers it.
pub type Images =
  fn(String, Int) -> Result(transcript_image.Image, Nil)

/// A handle on the actor.
pub opaque type Sessions {
  Sessions(subject: Subject(Message))
}

type Message {
  Mint(
    grant: Grant,
    until: Option(Int),
    login: Option(Issuer),
    life: Life,
    reply: Subject(Issued),
  )
  Redeem(
    ticket: String,
    exchange: Exchange,
    reply: Subject(Result(Redeemed, Refusal)),
  )
  Attach(cookie: String, login: Issuer, reply: Subject(Nil))
  LoginOf(cookie: String, reply: Subject(Option(Issuer)))
  Lookup(cookie: String, reply: Subject(Result(#(Page, Int), Nil)))
  Register(cookie: String, images: Images)
  Read(cookie: String, reply: Subject(Result(Images, Nil)))
  Sizes(reply: Subject(#(Int, Int)))
  Reserve(
    allowance: Allowance,
    credential: String,
    reply: Subject(Result(Nil, Int)),
  )
  Release(credential: String)
  Sweep
}

// A live ticket's grant, the deadline the page it becomes may not pass when
// another page minted it, and the login it was minted in.
type Ticket {
  Ticket(grant: Grant, until: Option(Int), login: Option(Issuer))
}

// One live ticket or UI session and the instant it stops being honoured.
type Entry(value) {
  Entry(value: value, expires_at: Int)
}

type State {
  State(
    settings: Settings,
    tickets: Dict(String, Entry(Ticket)),
    sessions: Dict(String, Entry(Page)),
    /// How many pages this actor has opened, which numbers the next one.
    opened: Int,
    /// The readers of each live page's images, by the digest of its cookie:
    /// the newest socket's, since a reload replaces the socket a page had.
    readers: Dict(String, Images),
    /// The instants of the invitations each credential's pages have asked
    /// for inside `invite_window_ms`, newest first, keyed by the
    /// credential's fingerprint. A credential with none has no entry.
    invites: Dict(String, List(Int)),
    /// The same for the sessions each credential's pages have created inside
    /// `creation_window_ms`.
    creations: Dict(String, List(Int)),
    /// The same for the worktree reads inside `worktree_read_window_ms`.
    reads: Dict(String, List(Int)),
  )
}

/// The production settings: OTP's `crypto:strong_rand_bytes`, the source
/// invitations use, and the lifetimes above.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.start(ui_sessions.production(clock))
/// ```
pub fn production(now: fn() -> Int) -> Settings {
  Settings(
    now:,
    wall: bootstrap.system_time_ms,
    entropy: token.production_entropy(),
    ticket_ms:,
    device_ms:,
    session_ms:,
  )
}

/// Starts the actor, linked to the caller, sweeping every `sweep_ms`.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(sessions) = ui_sessions.start(settings)
/// ```
pub fn start(settings: Settings) -> Result(Sessions, String) {
  actor.new_with_initialiser(1000, fn(subject) {
    // The table belongs to the daemon and not to any session, so its label
    // carries the empty owner path.
    owner.label([], owner.PageSessions)
    actor.initialised(State(
      settings,
      dict.new(),
      dict.new(),
      0,
      dict.new(),
      dict.new(),
      dict.new(),
      dict.new(),
    ))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.periodic(every: sweep_ms, sending: Sweep)
  |> actor.start
  |> result.map(fn(started) { Sessions(started.data) })
  |> result.replace_error("the web view's session table did not start")
}

/// Mints a ticket for `grant`.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.mint(sessions, grant)
/// ```
pub fn mint(sessions: Sessions, grant: Grant) -> Result(Issued, Nil) {
  ask_mint(sessions, grant, None, None, Brief)
}

fn ask_mint(
  sessions: Sessions,
  grant: Grant,
  until: Option(Int),
  login: Option(Issuer),
  life: Life,
) -> Result(Issued, Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Mint(
    grant,
    until,
    login,
    life,
    _,
  ))
  |> result.replace_error(Nil)
}

/// Mints a ticket for `grant` on behalf of another page whose deadline is
/// `until`, a reading of the table's clock. The page the ticket becomes ends
/// at the earlier of `until` and `session_ms` after its exchange, so a chain
/// of switches never outlives the page it began from.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.mint_before(sessions, grant, until)
/// ```
pub fn mint_before(
  sessions: Sessions,
  grant: Grant,
  until: Int,
) -> Result(Issued, Nil) {
  ask_mint(sessions, grant, Some(until), None, Brief)
}

/// `mint_before` for a page that belongs to a login: the ticket carries
/// `login`, so the page it opens belongs to the same login and a chain of
/// switches can neither lose it nor start another.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.mint_in(sessions, grant, until, page_login)
/// ```
pub fn mint_in(
  sessions: Sessions,
  grant: Grant,
  until: Int,
  login: Option(Issuer),
) -> Result(Issued, Nil) {
  ask_mint(sessions, grant, Some(until), login, Brief)
}

/// Mints a device link's ticket: a ticket that lives `device_ms` and not
/// `ticket_ms`, with the page it becomes ending no later than `until`, and
/// carrying `login`, whose expiry the login its exchange sets inherits.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.mint_device(sessions, grant, until, page_login)
/// ```
pub fn mint_device(
  sessions: Sessions,
  grant: Grant,
  until: Int,
  login: Option(Issuer),
) -> Result(Issued, Nil) {
  ask_mint(sessions, grant, Some(until), login, Device)
}

/// Mints a ticket on behalf of a browser login that has just verified: the
/// ticket carries the login, so the page its exchange opens is that login's
/// browser, and it is `Forgotten` so the exchange sets no further login.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.mint_resumed(sessions, grant, login)
/// ```
pub fn mint_resumed(
  sessions: Sessions,
  grant: Grant,
  login: Issuer,
) -> Result(Issued, Nil) {
  ask_mint(sessions, grant, None, Some(login), Brief)
}

/// Reserves one of the credential's invitations, or refuses when it has asked
/// for `invite_limit` in the last `invite_window_ms`. The count is made and
/// taken in one message, so two pages asking at once cannot both take the last
/// place. A caller whose invitation then failed gives the place back with
/// `release_invite`, so a refusal that minted nothing costs nothing.
///
/// A refusal answers the wall-clock Unix time in milliseconds at which a place
/// frees, so the page can say when the next grant is possible. A reply that
/// times out is reported as a refusal that frees `invite_window_ms` from the
/// wall clock's reading, the latest it could be, although the actor may still
/// have counted the place.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.reserve_invite(sessions, digest) == Ok(Nil)
/// // ui_sessions.reserve_invite(sessions, digest) == Error(1_790_003_600_000)
/// ```
pub fn reserve_invite(
  sessions: Sessions,
  credential: access.Digest,
) -> Result(Nil, Int) {
  call.try_call(sessions.subject, waiting: 1000, sending: Reserve(
    Invitations,
    access.fingerprint(credential),
    _,
  ))
  |> result.unwrap(Error(bootstrap.system_time_ms() + invite_window_ms))
}

/// Reserves one of the credential's session creations, or refuses when it has
/// created `creation_limit` in the last `creation_window_ms`
/// (protocol-change/065, the fourth pull request). The count is made and taken in
/// one message, so two pages asking at once cannot both take the last place. The
/// place is not given back: a refused creation may still have reserved a
/// session, and a reply that times out may have been counted, and either frees
/// within the hour.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.reserve_creation(sessions, digest) == Ok(Nil)
/// ```
pub fn reserve_creation(
  sessions: Sessions,
  credential: access.Digest,
) -> Result(Nil, Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Reserve(
    Creations,
    access.fingerprint(credential),
    _,
  ))
  |> result.unwrap(Error(0))
  |> result.replace_error(Nil)
}

/// Reserves one of the credential's worktree reads, or refuses when it has
/// started `worktree_read_limit` in the last `worktree_read_window_ms`. The
/// count is made and taken in one message, so pages asking at once cannot all
/// take the last place. The place is not given back: a read that failed still
/// spent its Git calls.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.reserve_worktree_read(sessions, digest) == Ok(Nil)
/// ```
pub fn reserve_worktree_read(
  sessions: Sessions,
  credential: access.Digest,
) -> Result(Nil, Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Reserve(
    WorktreeReads,
    access.fingerprint(credential),
    _,
  ))
  |> result.unwrap(Error(0))
  |> result.replace_error(Nil)
}

/// Gives back the credential's newest reserved invitation, for an invitation
/// that was reserved and did not mint.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.release_invite(sessions, digest)
/// ```
pub fn release_invite(sessions: Sessions, credential: access.Digest) -> Nil {
  process.send(sessions.subject, Release(access.fingerprint(credential)))
}

/// Redeems `ticket` once, for the page of `scope`. A successful redemption
/// adds a UI session. The principal's other pages of that scope keep their
/// own cookies and stay open until their eight hours run out, except that a
/// principal already holding `max_pages` live ones has its oldest ended to
/// make room. A refused redemption leaves every page
/// alone, so a stale or misdirected link cannot sign a working page out.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.redeem(sessions, ticket, ui_sessions.SessionExchange(session_id))
/// ```
pub fn redeem(
  sessions: Sessions,
  ticket: String,
  exchange: Exchange,
) -> Result(Redeemed, Refusal) {
  call.try_call(sessions.subject, waiting: 1000, sending: Redeem(
    ticket,
    exchange,
    _,
  ))
  |> result.unwrap(Error(UnknownTicket))
}

/// Records that the page behind `cookie` is the browser of `login`, which a
/// `Remembered` exchange does once the login's row is written. A cookie that
/// names no live page records nothing. The page's grant is untouched, so a
/// socket already holding it still matches. The call returns once the table
/// holds the login, so the exchange that makes it writes its response only
/// after any other process that reads the page's login will find it.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.attach_login(sessions, redeemed.cookie, issuer)
/// ```
pub fn attach_login(sessions: Sessions, cookie: String, login: Issuer) -> Nil {
  call.try_call(sessions.subject, waiting: 1000, sending: Attach(
    cookie,
    login,
    _,
  ))
  |> result.unwrap(Nil)
}

/// The login the page behind `cookie` is the browser of, when it has one and
/// the page is live.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.login_of(sessions, cookie)
/// ```
pub fn login_of(sessions: Sessions, cookie: String) -> Option(Issuer) {
  call.try_call(sessions.subject, waiting: 1000, sending: LoginOf(cookie, _))
  |> result.unwrap(None)
}

/// The live UI session a cookie names.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.lookup(sessions, cookie)
/// ```
pub fn lookup(sessions: Sessions, cookie: String) -> Result(Page, Nil) {
  lookup_until(sessions, cookie) |> result.map(pair.first)
}

// The live UI session a cookie names, with the deadline it ends at.
fn lookup_until(
  sessions: Sessions,
  cookie: String,
) -> Result(#(Page, Int), Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Lookup(cookie, _))
  |> result.unwrap(Error(Nil))
}

/// Records how the page behind `cookie` reads its images, replacing the
/// reader its previous socket left. A cookie that names no live UI session
/// records nothing, so a socket that outlived its page leaves no reader.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.register_images(sessions, cookie, reader)
/// ```
pub fn register_images(
  sessions: Sessions,
  cookie: String,
  images: Images,
) -> Nil {
  process.send(sessions.subject, Register(cookie, images))
}

/// The reader of the images of the page behind `cookie`, when the page is
/// live and a socket has registered one.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.images(sessions, cookie)
/// ```
pub fn images(sessions: Sessions, cookie: String) -> Result(Images, Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Read(cookie, _))
  |> result.unwrap(Error(Nil))
}

/// What a live UI session grants.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.grant(page).scope
/// ```
pub fn grant(page: Page) -> Grant {
  page.grant
}

/// Whether `key`, from a request's path, is the page key this UI session
/// was given. Compared by digest, in constant time.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.keyed(page, key)
/// ```
pub fn keyed(page: Page, key: String) -> Bool {
  same_digest(page.key, digest(key))
}

/// Whether `nonce`, from a socket's query, is the nonce this UI session
/// handed its browser tab. Compared by digest, in constant time.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.admits(page, nonce)
/// ```
pub fn admits(page: Page, nonce: String) -> Bool {
  same_digest(page.nonce, digest(nonce))
}

// Two digests are base16 SHA-256, the same length whatever they digest, so
// a constant-time comparison of them reveals nothing about the secret.
fn same_digest(stored: String, presented: String) -> Bool {
  ffi_crypto.constant_time_equal(
    bit_array.from_string(stored),
    bit_array.from_string(presented),
  )
}

/// A check that the UI session behind `cookie` still grants `grant`.
///
/// The page's socket runs it with every authorization the gateway asks for,
/// so a UI session that expires ends an open page the way a revoked
/// credential does. A lookup that answers with
/// a different grant counts as ended too.
///
/// ## Examples
///
/// ```gleam
/// // let open = ui_sessions.still_open(sessions, cookie, grant)
/// // open() == Ok(Nil)
/// ```
pub fn still_open(
  sessions: Sessions,
  cookie: String,
  grant: Grant,
) -> fn() -> Result(Nil, Nil) {
  let until = open_until(sessions, cookie, grant)
  fn() { until() |> result.replace(Nil) }
}

/// `still_open`, answering the page's deadline while it is open. The page
/// socket uses the deadline when the page asks to open another session, so the
/// ticket it mints carries it (`mint_before`).
///
/// ## Examples
///
/// ```gleam
/// // let until = ui_sessions.open_until(sessions, cookie, grant)
/// // until() == Ok(deadline)
/// ```
pub fn open_until(
  sessions: Sessions,
  cookie: String,
  grant: Grant,
) -> fn() -> Result(Int, Nil) {
  fn() {
    use #(current, until) <- result.try(lookup_until(sessions, cookie))
    case current.grant == grant {
      True -> Ok(until)
      False -> Error(Nil)
    }
  }
}

/// How many tickets and UI sessions the tables hold, expired or not, for a
/// test that checks the sweep.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.sizes(sessions) == #(0, 1)
/// ```
@internal
pub fn sizes(sessions: Sessions) -> Result(#(Int, Int), Nil) {
  call.try_call(sessions.subject, waiting: 1000, sending: Sizes)
  |> result.replace_error(Nil)
}

/// Sweeps now rather than at the next period, for a test.
///
/// ## Examples
///
/// ```gleam
/// // ui_sessions.sweep(sessions)
/// ```
@internal
pub fn sweep(sessions: Sessions) -> Nil {
  process.send(sessions.subject, Sweep)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let now = state.settings.now()
  case message {
    Mint(grant:, until:, login:, life:, reply:) -> {
      let ticket = secret(state.settings)
      let lasts = case life {
        Brief -> state.settings.ticket_ms
        Device -> state.settings.device_ms
      }
      let entry =
        Entry(value: Ticket(grant, until, login), expires_at: now + lasts)
      process.send(reply, Issued(ticket, lasts))
      actor.continue(
        State(
          ..state,
          tickets: dict.insert(state.tickets, digest(ticket), entry),
        ),
      )
    }

    // The whole redemption happens in this one turn: the ticket is removed
    // whether or not it was still live, and only a live ticket for this
    // scope becomes a new UI session. Making room and inserting in one
    // turn keeps the bound exact: two redemptions at the fourth place reach
    // this actor one after the other, and the second sees the first's page.
    Redeem(ticket:, exchange:, reply:) -> {
      let key = digest(ticket)
      let found = live(state.tickets, key, now)
      let tickets = dict.delete(state.tickets, key)
      let wall = state.settings.wall()

      // Whether a live ticket belongs at this exchange. A guard cannot call a
      // function, so the answer is made before the arms that read it.
      let belongs = case found {
        Ok(Ticket(grant:, ..)) -> at_exchange(grant.scope, exchange)
        Error(Nil) -> True
      }
      case found {
        Error(Nil) -> {
          process.send(reply, Error(UnknownTicket))
          actor.continue(State(..state, tickets:))
        }
        Ok(_) if !belongs -> {
          process.send(reply, Error(OtherScope))
          actor.continue(State(..state, tickets:))
        }

        // A switch ticket minted in the last minute of its source page's life
        // can outlive it. The page it would open is already past its
        // deadline, so it is refused as an unknown ticket before it can make
        // room by displacing one of the principal's live pages.
        Ok(Ticket(until: Some(bound), ..)) if bound <= now -> {
          process.send(reply, Error(UnknownTicket))
          actor.continue(State(..state, tickets:))
        }

        // A ticket that sets a login, a device link, minted under a login that
        // has since ended would open a page with no login behind it. It is
        // refused before it can take a page's place, so the owner's existing
        // homes survive the attempt. A `Forgotten` ticket (a switch, the way
        // home, an admin press) sets no login, and the page it opens keeps
        // working to its own deadline, so it is not held to the login's end.
        // The row-refused case is still the exchange's own (`server.entered`).
        Ok(Ticket(
          grant: Grant(remember: Remembered, ..),
          login: Some(issuer),
          ..,
        ))
          if issuer.expires_at_ms <= wall
        -> {
          process.send(reply, Error(UnknownTicket))
          actor.continue(State(..state, tickets:))
        }

        Ok(Ticket(grant:, until:, login:)) -> {
          let lasts = lifetime(state.settings, grant.scope)
          let ends = case until {
            Some(bound) -> int.min(bound, now + lasts)
            None -> now + lasts
          }
          let cookie = secret(state.settings)
          let key = secret(state.settings)
          let nonce = secret(state.settings)

          // A page opened by a `Remembered` exchange gets its login from
          // `attach_login`, once the login's row exists; any other page is the
          // browser of the login its ticket was minted in.
          let page_login = case grant.remember {
            Remembered -> None
            Forgotten -> login
          }
          let entry =
            Entry(
              value: Page(
                grant:,
                key: digest(key),
                nonce: digest(nonce),
                serial: state.opened,
                login: page_login,
              ),
              expires_at: ends,
            )
          process.send(
            reply,
            Ok(Redeemed(cookie:, key:, nonce:, grant:, login:)),
          )
          actor.continue(
            State(
              ..state,
              tickets:,
              sessions: state.sessions
                |> with_room(grant, now)
                |> dict.insert(digest(cookie), entry),
              opened: state.opened + 1,
            ),
          )
        }
      }
    }

    Lookup(cookie:, reply:) -> {
      process.send(reply, live_until(state.sessions, digest(cookie), now))
      actor.continue(state)
    }

    // A login is attached only to a page that is live now, and only once: the
    // exchange that made the page is the one that attaches, and a second
    // attachment would let a later message change which login a page is.
    Attach(cookie:, login:, reply:) -> {
      let key = digest(cookie)
      case live_until(state.sessions, key, now) {
        Ok(#(Page(login: None, ..) as page, ends)) -> {
          process.send(reply, Nil)
          actor.continue(
            State(
              ..state,
              sessions: dict.insert(
                state.sessions,
                key,
                Entry(value: Page(..page, login: Some(login)), expires_at: ends),
              ),
            ),
          )
        }
        Ok(_) | Error(Nil) -> {
          process.send(reply, Nil)
          actor.continue(state)
        }
      }
    }
    LoginOf(cookie:, reply:) -> {
      let found = case live(state.sessions, digest(cookie), now) {
        Ok(page) -> page.login
        Error(Nil) -> None
      }
      process.send(reply, found)
      actor.continue(state)
    }

    // A reader is recorded only for a page that is live now. The page's socket
    // registers from its own process after the router admitted it, so a page
    // that ended in between has no place to leave one.
    Register(cookie:, images:) -> {
      let key = digest(cookie)
      case live(state.sessions, key, now) {
        Ok(_) ->
          actor.continue(
            State(..state, readers: dict.insert(state.readers, key, images)),
          )
        Error(Nil) -> actor.continue(state)
      }
    }

    // A reader is found only through a live page, so one whose page ended is
    // never handed out before the sweep removes it.
    Read(cookie:, reply:) -> {
      let key = digest(cookie)
      let found = case live(state.sessions, key, now) {
        Ok(_) -> dict.get(state.readers, key)
        Error(Nil) -> Error(Nil)
      }
      process.send(reply, found)
      actor.continue(state)
    }

    Sizes(reply:) -> {
      process.send(reply, #(dict.size(state.tickets), dict.size(state.sessions)))
      actor.continue(state)
    }

    // The window is a rolling one: an instant older than it no longer counts,
    // so a place frees an hour after it was taken. The reservation is one
    // turn, so the count and the taking cannot be split by another page.
    Reserve(allowance: Invitations, credential:, reply:) -> {
      let recent =
        recent_instants(state.invites, credential, now, invite_window_ms)
      case list.drop(recent, invite_limit - 1) {
        [held, ..] -> {
          process.send(
            reply,
            Error(frees_at(state.settings, held + invite_window_ms)),
          )
          actor.continue(state)
        }
        [] -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            State(
              ..state,
              invites: dict.insert(state.invites, credential, [now, ..recent]),
            ),
          )
        }
      }
    }

    Reserve(allowance: Creations, credential:, reply:) -> {
      let recent =
        recent_instants(state.creations, credential, now, creation_window_ms)
      case list.drop(recent, creation_limit - 1) {
        [held, ..] -> {
          process.send(
            reply,
            Error(frees_at(state.settings, held + creation_window_ms)),
          )
          actor.continue(state)
        }
        [] -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            State(
              ..state,
              creations: dict.insert(state.creations, credential, [
                now,
                ..recent
              ]),
            ),
          )
        }
      }
    }

    Reserve(allowance: WorktreeReads, credential:, reply:) -> {
      let recent =
        recent_instants(state.reads, credential, now, worktree_read_window_ms)
      case list.drop(recent, worktree_read_limit - 1) {
        [held, ..] -> {
          process.send(
            reply,
            Error(frees_at(state.settings, held + worktree_read_window_ms)),
          )
          actor.continue(state)
        }
        [] -> {
          process.send(reply, Ok(Nil))
          actor.continue(
            State(
              ..state,
              reads: dict.insert(state.reads, credential, [now, ..recent]),
            ),
          )
        }
      }
    }

    Release(credential:) -> {
      let held = case
        recent_instants(state.invites, credential, now, invite_window_ms)
      {
        [] -> state.invites
        [_newest, ..older] ->
          case older {
            [] -> dict.delete(state.invites, credential)
            [_, ..] -> dict.insert(state.invites, credential, older)
          }
      }
      actor.continue(State(..state, invites: held))
    }

    Sweep -> {
      let sessions =
        dict.filter(state.sessions, fn(_, entry) { entry.expires_at > now })
      actor.continue(
        State(
          ..state,
          invites: dict.filter(state.invites, fn(_, instants) {
            list.any(instants, fn(at) { at > now - invite_window_ms })
          }),
          creations: dict.filter(state.creations, fn(_, instants) {
            list.any(instants, fn(at) { at > now - creation_window_ms })
          }),
          reads: dict.filter(state.reads, fn(_, instants) {
            list.any(instants, fn(at) { at > now - worktree_read_window_ms })
          }),
          tickets: dict.filter(state.tickets, fn(_, entry) {
            entry.expires_at > now
          }),
          sessions:,
          readers: dict.filter(state.readers, fn(cookie, _) {
            dict.has_key(sessions, cookie)
          }),
        ),
      )
    }
  }
}

// How long a page of this scope lives from its exchange. An admin page lives
// `admin_ms` unless the table's own page lifetime is shorter.
fn lifetime(settings: Settings, scope: Scope) -> Int {
  case scope {
    Admin -> int.min(admin_ms, settings.session_ms)
    Home | Session(_) -> settings.session_ms
  }
}

// The instants of a credential's invitations or creations that are still inside
// the window, newest first. A table is read with its own window.
// The wall-clock Unix time, in milliseconds, of an instant on the actor's
// monotonic clock. The two clocks cannot be compared, so the instant is carried
// over as how far it is from the monotonic clock now, added to the wall clock
// now.
fn frees_at(settings: Settings, instant: Int) -> Int {
  settings.wall() + { instant - settings.now() }
}

fn recent_instants(
  table: Dict(String, List(Int)),
  credential: String,
  now: Int,
  window: Int,
) -> List(Int) {
  dict.get(table, credential)
  |> result.unwrap([])
  |> list.filter(fn(at) { at > now - window })
}

// The table with room for one more of `grant`'s pages: unchanged while the
// principal holds fewer than `max_pages` live ones of the same scope (a
// principal's home is counted apart from each session, and each session
// apart from the others), and otherwise without the
// oldest, so the new page makes `max_pages`. An expired page is not counted
// even before the sweep removes it, so a place frees at its deadline.
fn with_room(
  sessions: Dict(String, Entry(Page)),
  grant: Grant,
  now: Int,
) -> Dict(String, Entry(Page)) {
  let held =
    sessions
    |> dict.to_list
    |> list.filter(fn(row) {
      let #(_cookie, entry) = row
      let other = entry.value.grant
      entry.expires_at > now
      && other.principal == grant.principal
      && other.scope == grant.scope
    })
    |> list.sort(fn(a, b) {
      int.compare({ a.1 }.value.serial, { b.1 }.value.serial)
    })
  let surplus = list.length(held) - max_pages + 1

  // A surplus of zero or less takes nothing, so below the bound this drops
  // no page.
  dict.drop(sessions, list.map(list.take(held, surplus), pair.first))
}

// Whether a ticket of `scope` is honoured at `exchange`: the session's own
// ticket at its exchange, a home's at the home's and an admin page's at the
// admin exchange, and no other pairing.
fn at_exchange(scope: Scope, exchange: Exchange) -> Bool {
  case scope, exchange {
    Session(id), SessionExchange(wanted) -> id == wanted
    Home, HomeExchange | Admin, AdminExchange -> True
    Session(_), HomeExchange
    | Home, SessionExchange(_)
    | Home, AdminExchange
    | Session(_), AdminExchange
    | Admin, SessionExchange(_)
    | Admin, HomeExchange
    -> False
  }
}

// An entry is honoured strictly before its deadline, and the check is made
// on every read, so the sweep is never what enforces expiry.
fn live(table: Dict(String, Entry(value)), key: String, now: Int) {
  case dict.get(table, key) {
    Ok(entry) if entry.expires_at > now -> Ok(entry.value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

// A live UI session and the instant it ends.
fn live_until(
  table: Dict(String, Entry(Page)),
  key: String,
  now: Int,
) -> Result(#(Page, Int), Nil) {
  case dict.get(table, key) {
    Ok(entry) if entry.expires_at > now -> Ok(#(entry.value, entry.expires_at))
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

fn secret(settings: Settings) -> String {
  settings.entropy(32) |> bit_array.base16_encode |> string.lowercase
}

fn digest(value: String) -> String {
  value
  |> bit_array.from_string
  |> bootstrap.sha256
  |> bit_array.base16_encode
  |> string.lowercase
}
