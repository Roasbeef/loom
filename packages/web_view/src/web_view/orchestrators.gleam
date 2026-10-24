//// What a page holds of the orchestrators its daemon relays for
//// (protocol-change/094, the placement revamp's slice S2b): what each offers a
//// new session, the sessions it lists for the sidebar, and whether it answers.
////
//// The composer's Agent chip and the sidebar's relayed rows are the two places
//// the page draws another orchestrator. Both need the same small state for each
//// orchestrator the daemon is configured with, and neither may let one silent
//// box hold up the others, so the state is kept for each orchestrator on its own
//// (`Machine`) and every answer replaces one machine's part of it and no other's.
//// The daemon (`client/daemon/ui_top`) turns what an orchestrator said into the
//// types here after its own total decoders have judged the answer, so everything
//// below is already bounded and closed.
////
//// ## Two reads, two cadences
////
//// The offers are read when the person opens a chip that needs them, because a
//// create is judged against the offers the daemon reads again at the create, and
//// an hour-old list would only mislead. The listing is read every few seconds
//// while the page is open, so a request a session raises on a box reaches the
//// sidebar. A listing read that is still out is never asked again (`Flight`), so
//// a box that answers slowly costs one call at a time and not a pile.
////
//// ## Silence is not an empty list
////
//// A box that did not answer keeps the last rows it gave, marked `Silent` with
//// the time of the last good read, and the sidebar draws them with a line that
//// says so. Dropping the rows would make a dropped link look like a box with no
//// sessions. A box never heard from has no rows and no time (`Unasked`).
////
//// ## Untrusted text
////
//// A session's name and a folder are written on the other orchestrator. They are
//// drawn as text nodes, except that a folder's whole path is also a `title`
//// attribute, which Lustre escapes. The one value a link is built from is
//// the session's identity, which the daemon admits only in its canonical text,
//// and the page builds the link itself (`home`) from a row it holds, so a press
//// can name nothing the page did not draw.
////
//// ## Flow
////
//// `new` → `ask_offers` → `offers_heard` → `begin_listing` → `listing_heard` →
//// `ordered`
////
//// 1. `new` makes one machine for each configured orchestrator.
//// 2. `ask_offers` marks a read of the offers as out and numbers it, and
////    `offers_heard` applies an answer unless a newer read overtook it.
//// 3. `begin_listing` picks the machines with no listing read out, and
////    `listing_heard` applies one answer to its machine.
//// 4. `ordered` is the order the sidebar draws a machine's rows in.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import web_view/listing
import web_view/placements
import web_view/relayed

/// What an orchestrator offers a new session, as the daemon read it from the
/// orchestrator's `Placements` answer. Every name is the orchestrator's and is
/// drawn as a text node.
pub type Offers {
  Offers(
    /// The folders it remembers, as absolute paths on it.
    folders: List(String),
    /// The executors and pools its table lists, with their state.
    cards: placements.Cards,
    /// The profiles a session may start with.
    profiles: List(String),
    /// The model keys of its catalogue.
    models: List(String),
  )
}

/// The daemon's answer to one read of an orchestrator's offers.
pub type OffersRead {
  /// The orchestrator answered.
  Offered(
    /// What it offers.
    offers: Offers,
  )

  /// The orchestrator could not be reached, refused this daemon's page, or
  /// answered what could not be read.
  Withheld(
    /// The reason, in words for the person.
    why: String,
  )
}

/// What the page holds of one orchestrator's offers.
pub type Offer {
  /// A read is out and nothing has answered yet.
  Asking

  /// The last read was answered.
  Offering(
    /// What it offered.
    offers: Offers,
  )

  /// The last read was not answered, and the Agent chip draws the orchestrator
  /// with this reason and no way to choose it.
  Refusing(
    /// The reason.
    why: String,
  )
}

/// One session of an orchestrator, as its list gave it to the sidebar.
pub type Listed {
  Listed(
    /// The session's canonical identity on that orchestrator.
    session: String,
    /// The session's display name.
    name: String,
    /// Where its tools run.
    code: listing.Code,
    /// What it is doing.
    activity: relayed.Activity,
    /// When it last changed, in Unix milliseconds on that orchestrator's clock.
    updated_ms: Int,
  )
}

/// The daemon's answer to one read of an orchestrator's session list.
pub type ListRead {
  /// The orchestrator answered its list.
  Heard(
    /// The rows it listed, newest first.
    rows: List(Listed),
  )

  /// The orchestrator did not give its list.
  Missed(
    /// The reason, in words for the person.
    why: String,
  )
}

/// How far the page's knowledge of an orchestrator's list has got.
pub type Reach {
  /// No read has answered.
  Unasked

  /// The last read answered, at this time on the page's own clock.
  Fresh(
    /// Unix milliseconds.
    at_ms: Int,
  )

  /// The last read did not answer. The rows are the ones before it.
  Silent(
    /// The reason.
    why: String,
    /// When a read last answered, if one ever did.
    last_ms: Option(Int),
  )
}

/// Whether a read of an orchestrator's list is out.
pub type Flight {
  /// None is out, and the next tick may start one.
  Quiet

  /// One is out, and no other is started until it answers.
  Out
}

/// Everything the page holds of one orchestrator.
pub type Machine {
  Machine(
    /// The `[orchestrators.<name>]` key.
    orchestrator: String,
    /// What it last offered.
    offer: Offer,
    /// How many offer reads have been started, which numbers the next: an answer
    /// that a newer read overtook is dropped.
    offer_reads: Int,
    /// The sessions it last listed.
    rows: List(Listed),
    /// Whether the rows are current.
    reach: Reach,
    /// Whether a listing read is out.
    flight: Flight,
  )
}

/// What the daemon says of a create on an orchestrator.
pub type Founding {
  /// The session was created and its first message, if there was one, was
  /// delivered.
  Founded(
    /// The session's identity on the orchestrator.
    session: String,
  )

  /// The session was created and its first message was not delivered. The
  /// person is offered the session, since the message may have arrived.
  Unsent(
    /// The session's identity on the orchestrator.
    session: String,
  )

  /// Nothing was created, or it is not known whether anything was.
  Refused(
    /// The reason, in words for the person.
    why: String,
  )
}

/// One machine for each configured orchestrator, in configuration order, with
/// nothing known of any.
///
/// ## Examples
///
/// ```gleam
/// assert list.map(orchestrators.new(["box"]), fn(each) { each.orchestrator }) == ["box"]
/// ```
pub fn new(names: List(String)) -> List(Machine) {
  list.map(names, fn(name) {
    Machine(
      orchestrator: name,
      offer: Asking,
      offer_reads: 0,
      rows: [],
      reach: Unasked,
      flight: Quiet,
    )
  })
}

/// The machine with this key.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.find(orchestrators.new(["box"]), "box") |> result.is_ok
/// assert orchestrators.find([], "box") == Error(Nil)
/// ```
pub fn find(machines: List(Machine), name: String) -> Result(Machine, Nil) {
  list.find(machines, fn(each) { each.orchestrator == name })
}

/// Marks a read of one machine's offers as out and numbers it, answering the
/// number. Offers the page already holds stay until the answer replaces them, so
/// a list that is being refreshed does not empty while it is. A name that is no
/// machine's changes nothing and gets no number.
///
/// ## Examples
///
/// ```gleam
/// let #(machines, serial) = orchestrators.ask_offers(orchestrators.new(["box"]), "box")
/// assert serial == Ok(1)
/// ```
pub fn ask_offers(
  machines: List(Machine),
  name: String,
) -> #(List(Machine), Result(Int, Nil)) {
  // Locate the target orchestrator machine entry.
  case find(machines, name) {
    Error(Nil) -> #(machines, Error(Nil))
    Ok(held) -> {
      let serial = held.offer_reads + 1

      // Retain existing offers or transition to Asking state.
      let offer = case held.offer {
        Offering(_) -> held.offer
        Asking | Refusing(_) -> Asking
      }

      let asked = Machine(..held, offer:, offer_reads: serial)

      #(replace(machines, asked), Ok(serial))
    }
  }
}

/// Applies the answer to the offers read numbered `serial`. An answer that is not
/// the newest read's, or one for an orchestrator the page does not hold, changes
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// let #(machines, _) = orchestrators.ask_offers(orchestrators.new(["box"]), "box")
/// let machines = orchestrators.offers_heard(machines, "box", 1, orchestrators.Withheld("down"))
/// assert orchestrators.standing(machines, "box") == orchestrators.Refusing("down")
/// ```
pub fn offers_heard(
  machines: List(Machine),
  name: String,
  serial: Int,
  read: OffersRead,
) -> List(Machine) {
  case find(machines, name) {
    Ok(held) if held.offer_reads == serial ->
      replace(
        machines,
        Machine(..held, offer: case read {
          Offered(offers:) -> Offering(offers:)
          Withheld(why:) -> Refusing(why:)
        }),
      )
    Ok(_) | Error(Nil) -> machines
  }
}

/// What the page holds of one orchestrator's offers. An orchestrator the page
/// does not hold offers nothing.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.standing([], "box") == orchestrators.Refusing("not configured")
/// ```
pub fn standing(machines: List(Machine), name: String) -> Offer {
  case find(machines, name) {
    Ok(held) -> held.offer
    Error(Nil) -> Refusing(why: "not configured")
  }
}

/// Marks a listing read as out for every machine that has none out, and answers
/// their keys, which are the reads the daemon owes. A machine whose read is still
/// out is left alone, so a slow box is asked once at a time.
///
/// ## Examples
///
/// ```gleam
/// let #(machines, owed) = orchestrators.begin_listing(orchestrators.new(["box"]))
/// assert owed == ["box"]
/// let #(_, again) = orchestrators.begin_listing(machines)
/// assert again == []
/// ```
pub fn begin_listing(
  machines: List(Machine),
) -> #(List(Machine), List(String)) {
  let owed =
    list.filter_map(machines, fn(each) {
      case each.flight {
        Quiet -> Ok(each.orchestrator)
        Out -> Error(Nil)
      }
    })
  let marked =
    list.map(machines, fn(each) {
      case each.flight {
        Quiet -> Machine(..each, flight: Out)
        Out -> each
      }
    })

  #(marked, owed)
}

/// Applies one machine's answer to its listing read, stamped with the page's
/// clock. A list replaces the rows. A silence keeps the rows and the time of the
/// last list that answered.
///
/// ## Examples
///
/// ```gleam
/// let machines = orchestrators.listing_heard(orchestrators.new(["box"]), "box", orchestrators.Missed("down"), 5)
/// assert orchestrators.find(machines, "box") |> result.map(fn(each) { each.reach }) == Ok(orchestrators.Silent("down", None))
/// ```
pub fn listing_heard(
  machines: List(Machine),
  name: String,
  read: ListRead,
  now_ms: Int,
) -> List(Machine) {
  case find(machines, name), read {
    Error(Nil), _ -> machines
    Ok(held), Heard(rows:) ->
      replace(
        machines,
        Machine(..held, rows:, reach: Fresh(at_ms: now_ms), flight: Quiet),
      )
    Ok(held), Missed(why:) ->
      replace(
        machines,
        Machine(
          ..held,
          reach: Silent(why:, last_ms: seen(held.reach)),
          flight: Quiet,
        ),
      )
  }
}

/// When a list last answered, given how far the knowledge had got.
fn seen(reach: Reach) -> Option(Int) {
  case reach {
    Unasked -> None
    Fresh(at_ms:) -> Some(at_ms)
    Silent(last_ms:, ..) -> last_ms
  }
}

/// Replaces the matching machine record by orchestrator identity.
fn replace(machines: List(Machine), changed: Machine) -> List(Machine) {
  list.map(machines, fn(each) {
    case each.orchestrator == changed.orchestrator {
      True -> changed
      False -> each
    }
  })
}

/// The rows of a machine in the order the sidebar draws them: sessions that need
/// the person, then those working, then the quiet ones, each newest first.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.ordered([]) == []
/// ```
pub fn ordered(rows: List(Listed)) -> List(Listed) {
  list.sort(rows, fn(a, b) {
    case int.compare(rank(a.activity), rank(b.activity)) {
      order.Eq -> int.compare(b.updated_ms, a.updated_ms)
      other -> other
    }
  })
}

/// Assigns a sorting priority rank for relayed activity states.
fn rank(activity: relayed.Activity) -> Int {
  case activity {
    relayed.NeedsYou -> 0
    relayed.Working -> 1
    relayed.Idle -> 2
  }
}

/// The row of a machine that a press names, if the page holds it. A press is
/// honoured only for a row the page drew from a list it holds.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.held_row([], "box", "S") == Error(Nil)
/// ```
pub fn held_row(
  machines: List(Machine),
  name: String,
  session: String,
) -> Result(Listed, Nil) {
  use machine <- result.try(find(machines, name))
  list.find(machine.rows, fn(row) { row.session == session })
}

/// What the sidebar says under a machine's heading when its list is not current:
/// nothing while it is, "box not reachable" with how long ago its list last
/// answered when it is not, and nothing before the first read.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.reach_words("box", orchestrators.Silent("down", Some(0)), 125_000)
///   == "box not reachable, seen 2m ago"
/// assert orchestrators.reach_words("box", orchestrators.Unasked, 0) == ""
/// ```
pub fn reach_words(name: String, reach: Reach, now_ms: Int) -> String {
  case reach {
    Unasked | Fresh(..) -> ""
    Silent(last_ms: None, ..) -> name <> " not reachable"
    Silent(last_ms: Some(at), ..) ->
      name <> " not reachable, seen " <> relayed.age_words(now_ms - at)
  }
}

/// The short line under an orchestrator's row in the Agent chip's list: what it is
/// doing for the owner now, from the sessions last listed.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.busy_words([]) == "no sessions yet"
/// ```
pub fn busy_words(rows: List(Listed)) -> String {
  let needs = list.count(rows, fn(row) { row.activity == relayed.NeedsYou })
  let working = list.count(rows, fn(row) { row.activity == relayed.Working })

  // Generate human-readable summary of active, working, and idle sessions.
  case list.length(rows), working, needs {
    0, _, _ -> "no sessions yet"
    total, 0, 0 -> int.to_string(total) <> " idle"
    _, working, 0 -> int.to_string(working) <> " working"
    _, 0, needs -> int.to_string(needs) <> " needs you"
    _, working, needs ->
      int.to_string(working)
      <> " working, "
      <> int.to_string(needs)
      <> " needs you"
  }
}

/// The name a session is drawn under: its display name, or the first eight
/// characters of its identity when it has none.
///
/// ## Examples
///
/// ```gleam
/// assert orchestrators.label(orchestrators.Listed("0198c0de-0000", "", listing.Folder("/w"), relayed.Idle, 0))
///   == "0198c0de"
/// ```
pub fn label(row: Listed) -> String {
  case string.trim(row.name) {
    "" -> string.slice(row.session, 0, 8)
    named -> named
  }
}
