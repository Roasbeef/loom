//// What a page knows of sessions that run on another orchestrator, and of the
//// orchestrators it can start them on (protocol-change/094, the placement
//// revamp's slice S2b).
////
//// A page is bound to the daemon that serves it, yet the owner may start a
//// session whose agent runs on the box and drive it from the laptop's page. The
//// daemon relays: it asks the box for what the page draws and tells the box what
//// the person decided. This module is the page's half of that vocabulary. The
//// daemon (`client/daemon/ui_top`) turns what the box said into these types after
//// its own total decoders have judged the answer, so everything here is already
//// bounded and closed, and nothing in it is a credential, a node name or an
//// address. The page decides nothing from it that the box does not decide again:
//// the box judges every request against its own table, and this daemon judges it
//// first, against the lists it handed the page.
////
//// ## Untrusted text
////
//// A session's name, a folder, a request's tool and preview are written on the
//// box, and a request's words are written by a model. They are drawn as text
//// nodes and nowhere else: never an attribute, a class, a key, a link or a
//// style. The two values this module builds a path from, the orchestrator's key
//// and the session's identity, are the daemon's configuration and a canonical
//// identity (`canonical_session`, `plain_name`), checked here again before
//// `path` joins them, so a hostile row cannot steer a navigation.
////
//// ## What the page keeps
////
//// Nothing is durable. The page keeps the last `Listing` each orchestrator gave
//// it, and the last `Agent` hearing the composer drew its Agent chip from. An
//// orchestrator that stopped answering keeps its last listing, marked `Stale`
//// with when the failures began, so the sidebar can grey its rows and say how
//// old they are, and the Agent chip says since when it has not answered.
////
//// ## Flow
////
//// `remote_rows` → `find_row` → `offers_for` → `path`
////
//// 1. `remote_rows` makes the sidebar's rows from the listings.
//// 2. `find_row` is how every press on a relayed row, request or session page
////    is checked against what the page last read.
//// 3. `offers_for` turns an orchestrator's offers into the lists the composer's
////    choices are checked against, and `path` writes the one navigation.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/remote_transcript
import web_view/listing
import web_view/placements
import web_view/sessions

/// The most relayed rows one orchestrator's listing holds. It is the box's own
/// cap on relayed sessions that are not archived (`max_sessions`, at most 64).
pub const listed_limit = 64

/// How current an orchestrator's listing is.
pub type Standing {
  /// The latest read succeeded, so the rows are what the box said then.
  Current

  /// The latest read failed. The rows are the last good ones, and the box has been
  /// out of reach since `since_ms`.
  Stale(
    /// When the failures began, in Unix milliseconds on this daemon's clock.
    since_ms: Int,
    /// Why the latest read failed, in words for the person.
    why: String,
  )
}

/// What a relayed session is doing, as the box's list says it. A session the owner
/// archived is not listed, so there is no word for it.
pub type Activity {
  /// A request is pending, or the last run failed and nothing has run since.
  NeedsYou

  /// A strand is running.
  Working

  /// Nothing runs and nothing is asked.
  Idle
}

/// Whether the page may decide a pending request.
pub type Ability {
  /// The box's approval ceiling admits some of what the request wants, so the
  /// buttons are drawn. The box judges the decision again.
  Decidable

  /// The ceiling admits nothing of it, or the spawner has no ceiling: the page
  /// shows the request and says it is decided on the box's own page.
  ViewOnly
}

/// One pending request of a relayed session, as the box's list says it.
pub type Need {
  Need(
    /// The box's identity for the request, which a decision names.
    escalation: String,
    /// The strand that asked.
    strand: String,
    /// The tool the call was for.
    tool: String,
    /// The words that say what is being asked, which the box wrote.
    preview: String,
    /// Why the sandbox refused it.
    reason: String,
    /// What approving would widen, in words, one line for each grant.
    wanted: List(String),
    /// The revision of the question the person was shown. A decision carries it,
    /// and the box refuses one for a question that has since changed.
    seq: Int,
    /// Whether the page may decide it.
    ability: Ability,
  )
}

/// One relayed session of a listing.
pub type Row {
  Row(
    /// The orchestrator's `[orchestrators.<name>]` key.
    orchestrator: String,
    /// The session's canonical identity there.
    session: String,
    /// The session's display name.
    name: String,
    /// Where its tools run.
    code: listing.Code,
    /// What it is doing.
    activity: Activity,
    /// When it last changed, in Unix milliseconds on the box's clock.
    updated_ms: Int,
    /// The oldest pending requests, at most eight.
    needs: List(Need),
    /// How many pending requests the box holds beyond `needs`.
    more_needs: Int,
  )
}

/// What one orchestrator's last read gave the page.
pub type Listing {
  Listing(
    /// The orchestrator's `[orchestrators.<name>]` key.
    orchestrator: String,
    /// The last good rows, newest first. Empty before any read has succeeded.
    rows: List(Row),
    /// When they were read, in Unix milliseconds, or `None` before any read
    /// succeeded.
    seen_ms: Option(Int),
    /// Whether the latest read succeeded.
    standing: Standing,
  )
}

/// The lists an orchestrator offers the composer, as its `Placements` answer says
/// them for this daemon: every field is already bounded by the daemon's decoder.
pub type Offers {
  Offers(
    /// The folders it remembers, which a session may start in. Empty when its
    /// table allows no folders.
    folders: List(String),
    /// Its executors and pools, with the state and workspaces it reported.
    cards: placements.Cards,
    /// The profiles a session may start with there.
    profiles: List(String),
    /// The models of its catalogue.
    models: List(String),
  )
}

/// Whether an orchestrator answered the composer's read, and what it said.
pub type Offering {
  /// It answered, and these are its offers.
  Answering(offers: Offers)

  /// It answered with a refusal: its table does not let this daemon start
  /// sessions, or names nothing this page may choose. The words are the box's
  /// reason as this daemon words it.
  Declined(why: String)

  /// It did not answer, or could not be reached. `since_ms` is when its failures
  /// began, so the row can say "not answering since 09:12".
  Silent(since_ms: Int)
}

/// An orchestrator the Agent chip lists.
pub type Agent {
  Agent(
    /// The orchestrator's `[orchestrators.<name>]` key.
    name: String,
    /// What it said.
    offering: Offering,
  )
}

/// Whether the person's own words are shown or sent: a transcript the page read.
pub type History {
  /// A page of the transcript, newest entries, drawn as text only.
  Shown(
    /// The page, oldest entry first. Images, reasoning and results are words in
    /// it (`session_view/remote_transcript.said`), never markup.
    page: remote_transcript.Page,
  )

  /// The page could not be read, and why.
  Unreadable(
    /// The reason, in words for the person.
    why: String,
  )
}

/// What the box said to a request that changed something: a message, a stop, an
/// archive or a decision.
pub type Outcome {
  /// The box did it.
  Done

  /// The box, or this daemon, refused. Nothing changed.
  Refusal(
    /// The refusal, in words for the person.
    why: String,
  )

  /// The box did not answer, so it is not known whether it happened. A message
  /// stays in the box so the person can look before sending it again.
  Unknown(
    /// What to tell the person.
    why: String,
  )
}

/// What a request to start a session came to.
pub type Created {
  /// The session exists on the orchestrator and took its first message, if there
  /// was one. The page departs for its relayed page.
  Opened(
    /// The orchestrator's key.
    orchestrator: String,
    /// The session's identity there.
    session: String,
  )

  /// The session exists and did not take its first message: it is kept, and the
  /// person is offered it, as for a local session.
  Kept(
    /// The orchestrator's key.
    orchestrator: String,
    /// The session's identity there.
    session: String,
  )

  /// Nothing was made, and why, in words for the person.
  Refused(
    /// The refusal.
    why: String,
  )

  /// The box did not answer, so it is not known whether the session was made. The
  /// next list names it if it was.
  Unsure(
    /// What to tell the person.
    why: String,
  )
}

/// How a person decides a request.
pub type Choice {
  /// Approve what the box's ceiling admits, once.
  Allow

  /// Approve it, and remember the grants for the session.
  AllowForSession

  /// Reject it.
  Deny
}

/// Whether a text is a canonical session identity: five hyphen-separated groups
/// of eight, four, four, four and twelve hexadecimal digits. A path is built only
/// from one that is.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.canonical_session("0198c0de-0000-7000-8000-000000000001")
/// assert !relayed.canonical_session("../../admin")
/// ```
pub fn canonical_session(text: String) -> Bool {
  let groups = string.split(text, "-")
  list.length(groups) == 5
  && list.all(list.zip(groups, [8, 4, 4, 4, 12]), fn(pair) {
    string.length(pair.0) == pair.1
    && list.all(string.to_graphemes(pair.0), fn(digit) {
      string.contains("0123456789abcdefABCDEF", digit)
    })
  })
}

/// Whether a text is an orchestrator's key as a page may carry it: one to 64
/// letters, digits, hyphens and underscores, beginning with a letter, which is
/// the grammar of every `[orchestrators.<name>]` key.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.plain_name("box-2")
/// assert !relayed.plain_name("a/b")
/// ```
pub fn plain_name(text: String) -> Bool {
  case string.to_graphemes(text) {
    [first, ..rest] ->
      string.length(text) <= 64
      && string.contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", first)
      && list.all(rest, fn(grapheme) {
        string.contains(
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
          grapheme,
        )
      })
    [] -> False
  }
}

/// The path of a relayed session's page below the page key,
/// `orchestrators/<name>/sessions/<id>`, or nothing when either part is not one a
/// path may be built from. `<loom-switch>` resolves it against the key it is on
/// (`web_client/switch_rule.keyed`), so no key is written here.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.path("box", "0198c0de-0000-7000-8000-000000000001")
///   == Ok("orchestrators/box/sessions/0198c0de-0000-7000-8000-000000000001")
/// assert relayed.path("box", "../x") == Error(Nil)
/// ```
pub fn path(orchestrator: String, session: String) -> Result(String, Nil) {
  case plain_name(orchestrator), canonical_session(session) {
    True, True -> Ok("orchestrators/" <> orchestrator <> "/sessions/" <> session)
    False, _ | _, False -> Error(Nil)
  }
}

/// The row of a session in what the page last read, or nothing when the page
/// holds no such row. Every press on a relayed row and every request about a
/// relayed session is checked against this, so a message that names a session the
/// page did not draw changes nothing.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.find_row([], "box", "s") == Error(Nil)
/// ```
pub fn find_row(
  listings: List(Listing),
  orchestrator: String,
  session: String,
) -> Result(Row, Nil) {
  list.find_map(listings, fn(each) {
    case each.orchestrator == orchestrator {
      True -> list.find(each.rows, fn(row) { row.session == session })
      False -> Error(Nil)
    }
  })
}

/// The rows of every listing, as one list in the order the listings came.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.rows([]) == []
/// ```
pub fn rows(listings: List(Listing)) -> List(Row) {
  list.flat_map(listings, fn(each) { each.rows })
}

/// The sidebar's rows for the listings: each relayed session as a synthetic
/// entry the sidebar draws, in the group its activity says, tagged with its
/// orchestrator and its code. A row whose identity or orchestrator is not one a
/// path may be built from is left out, so no row the page draws can steer
/// `path`. A listing that is stale marks every row of it greyed with its age,
/// counted from `now_ms` back to when the failures began.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.remote_rows([], 0) == []
/// ```
pub fn remote_rows(listings: List(Listing), now_ms: Int) -> List(listing.Remote) {
  list.flat_map(listings, fn(each) {
    let seen = case each.standing {
      Current -> listing.Fresh
      Stale(since_ms:, ..) ->
        listing.Stale(age_ms: int.max(now_ms - since_ms, 0))
    }
    list.filter_map(each.rows, fn(row) {
      case path(row.orchestrator, row.session) {
        Ok(_) -> Ok(remote(row, seen))
        Error(Nil) -> Error(Nil)
      }
    })
  })
}

// One relayed row as the sidebar's remote row. The entry is what the sidebar
// draws a session with: the identity, the name, a workspace written the way the
// sidebar writes it, the time the session last changed and, for a session that
// needs the person, the words of its first request as the quiet third line.
fn remote(row: Row, seen: listing.Seen) -> listing.Remote {
  let entry =
    sessions.Entry(
      id: row.session,
      name: row.name,
      workspace: workspace_text(row.code),
      created_at: row.updated_ms,
      residency: sessions.Live,
      subtitle: wanting(row),
      role: None,
      project: None,
      executor: executor_of(row.code),
    )

  listing.Remote(
    entry:,
    place: listing.Place(agent: row.orchestrator, code: row.code),
    bucket: bucket(row.activity),
    door: listing.Relayed(orchestrator: row.orchestrator, seen:),
  )
}

// What the first request says, for a row that has one.
fn wanting(row: Row) -> Option(String) {
  case row.needs {
    [first, ..] -> Some("asks: " <> first.preview)
    [] -> None
  }
}

// The text the sidebar's entry carries as its workspace.
fn workspace_text(code: listing.Code) -> String {
  case code {
    listing.Folder(path:) -> path
    listing.Registered(workspace:, ..) | listing.Pooled(workspace:, ..) ->
      workspace
  }
}

// The executor the entry names, for a workspace registered on one.
fn executor_of(code: listing.Code) -> Option(String) {
  case code {
    listing.Registered(executor:, ..) -> Some(executor)
    listing.Pooled(..) | listing.Folder(_) -> None
  }
}

/// The group a relayed session's activity puts its row in.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.bucket(relayed.NeedsYou) == listing.NeedsYou
/// ```
pub fn bucket(activity: Activity) -> listing.Bucket {
  case activity {
    NeedsYou -> listing.NeedsYou
    Working -> listing.Working
    Idle -> listing.Idle
  }
}

/// The word a relayed session's activity is drawn as.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.activity_words(relayed.NeedsYou) == "needs you"
/// ```
pub fn activity_words(activity: Activity) -> String {
  case activity {
    NeedsYou -> "needs you"
    Working -> "working"
    Idle -> "idle"
  }
}

/// The listing of one orchestrator, or nothing when the page holds none.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.listing_of([], "box") == Error(Nil)
/// ```
pub fn listing_of(
  listings: List(Listing),
  orchestrator: String,
) -> Result(Listing, Nil) {
  list.find(listings, fn(each) { each.orchestrator == orchestrator })
}

/// The agent the chip lists under a name, or nothing when the page holds none.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.agent_named([], "box") == Error(Nil)
/// ```
pub fn agent_named(agents: List(Agent), name: String) -> Result(Agent, Nil) {
  list.find(agents, fn(each) { each.name == name })
}

/// The offers of an orchestrator that answered, or nothing for one that did not.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.offers_of(relayed.Agent("box", relayed.Silent(5))) == Error(Nil)
/// ```
pub fn offers_of(agent: Agent) -> Result(Offers, Nil) {
  case agent.offering {
    Answering(offers:) -> Ok(offers)
    Declined(_) | Silent(_) -> Error(Nil)
  }
}

/// How many relayed sessions of an orchestrator are working and how many need the
/// person, for the short count the Agent chip's row shows.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.counts([], "box") == #(0, 0)
/// ```
pub fn counts(listings: List(Listing), orchestrator: String) -> #(Int, Int) {
  case listing_of(listings, orchestrator) {
    Ok(held) -> #(
      list.count(held.rows, fn(row) { row.activity == Working }),
      list.count(held.rows, fn(row) { row.activity == NeedsYou }),
    )
    Error(Nil) -> #(0, 0)
  }
}

/// The words of the short count: how many are working and how many need the
/// person, or nothing when neither is the case.
///
/// ## Examples
///
/// ```gleam
/// assert relayed.count_words(#(2, 1)) == "2 working, 1 needs you"
/// assert relayed.count_words(#(0, 0)) == ""
/// ```
pub fn count_words(counts: #(Int, Int)) -> String {
  case counts {
    #(0, 0) -> ""
    #(working, 0) -> int.to_string(working) <> " working"
    #(0, needing) -> int.to_string(needing) <> " needs you"
    #(working, needing) ->
      int.to_string(working) <> " working, " <> int.to_string(needing) <> " needs you"
  }
}
