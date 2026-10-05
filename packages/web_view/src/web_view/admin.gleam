//// The owner's admin page's server component (protocol-change/065, the fifth
//// pull request): who exists, who holds a session, and the changes the owner
//// makes to either, drawn inside the frame the home draws and bound to no
//// session.
////
//// The page reads three things from the daemon and asks it eight. A read is the
//// principals the catalogue holds with the credential state of each, the owner's
//// sessions, and, once the owner has chosen one, that session's members. Every
//// read is the daemon's own, made as the page's principal with the digest of the
//// credential the page was admitted under, and it is also the page's check that
//// it may still be served: a read that answers `Closed` says the UI session ended
//// or the credential no longer authenticates as the owner, and the page draws why
//// and asks for nothing more. The asks are an invitation, a role change, a
//// membership's removal, a credential's revocation, a rotation, the ending of one
//// sign-in, a person's rename and the making of a private session shareable
//// (`web_view/grants`). A person's row has a Rename
//// button that opens a small form in that row (`Editing`); its submit asks the
//// daemon to rename that principal (protocol-change/065, the tenth pull request),
//// the owner's own row included, and the form closes when the daemon says it was
//// done.
////
//// Neither runs in the component's process. A read is a query the registry
//// answers, and an ask is a registry command that writes the catalogue, and the
//// registry's own call can wait seconds, so `Start.read` and `Start.act` each
//// start the daemon's own task and return at once, and the task delivers its
//// answer as a message when it finishes. The page keeps drawing while one is out.
//// An ask is followed by a read, so the page shows what the catalogue now holds
//// and not what the page believes it asked for, and the read's serial is how an
//// older answer that arrives after a newer one is recognised and dropped.
////
//// The page also runs one read at a time, because a read makes a registry call
//// for each listed session and overlapping reads would queue behind a slow
//// registry. A tick while a read is out only arms the timer again; a press or a
//// settled change marks that one more read is wanted, and it starts when the
//// answer lands (`Flight`). The page holds one request at a time: while an ask is out, every button is
//// drawn disabled, and a second ask asks nothing. That is the page's half of the
//// rule; the daemon counts the credential's grants itself, whatever any page
//// does, and refuses a fourth in an hour across this page and the invitation
//// control of a session's page.
////
//// A claim an ask makes is held in the model until the owner hides it
//// (`Dismissed`) and drawn once (`view/admin_claim`), beside the action that
//// made it: under the invitation form for an invitation, and under the person's
//// row for a rotation. It is the only secret the component ever holds and the
//// only frame of the page's socket that can carry one: a read holds none,
//// because the catalogue keeps only a claim's digest.
////
//// What the page says about an ask is a line beside what was acted on, not a
//// box at the top (`view/notice`): a change that was made is a quiet line that
//// fades, and a refusal stays beside its control, in words that name the
//// allowance and when it frees (`grants.reason_words`).
////
//// Every message but a press is the component's own. A press names the
//// principal or session the server drew into the tree, so the browser's event
//// names only the path it fired at, and the daemon's socket admits a click or a
//// submit only beneath `body_path`, where the page's controls are, and drops
//// every other frame (`client/daemon/ui_socket.admin_accepts`). A name is the
//// peer's and is only ever a text node.
////
//// ## Flow
////
//// `init` → `update` → `reading` → `landed` → `answered` → `view`
////
//// 1. `init` starts the refresh timer, and `update` answers the timer by asking
////    for a read (`reading`), which runs the daemon's read and returns at once.
//// 2. The read's answer arrives as `Answered`; `landed` drops one that was
////    overtaken, and `answered` applies a snapshot to the model.
//// 3. A press is `Choosing`, `Arming` or `Asking`. `Asking` sends the change to
////    the daemon through `acting` and `settled` words the answer, then reads again.
//// 4. `view` draws the model: the people, and the sessions with the chosen
////    session's members.
////
//// ## Transitions
////
//// <!-- transitions: admin.Status -->
////
//// | state | a read answers | a read is unreadable | a read is closed | the interval passes |
//// | --- | --- | --- | --- | --- |
//// | `Connecting` | `Connected` with the snapshot | stays `Connecting`, nothing drawn | `Ended` | reads again |
//// | `Connected` | stays `Connected` with the new snapshot | stays `Connected` with the last | `Ended` | reads again |
//// | `Ended` | stays `Ended` | stays `Ended` | stays `Ended` | reads nothing |
////
//// An ask is a second, smaller machine inside `Connected`:
////
//// | ask | a button is pressed | the daemon answers | the page ends |
//// | --- | --- | --- | --- |
//// | none out | sends one, or arms a revocation | nothing to answer | stays none |
//// | one out | asks nothing | clears it, shows a claim or the words, then reads again | clears it |

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import lustre/server_component
import web_view/creations
import web_view/ending.{type Ending}
import web_view/grants.{type Action, type Answer, type Claim, type Reading}
import web_view/invites
import web_view/view/admin_buttons.{type Busy, type Presses}
import web_view/view/admin_people
import web_view/view/admin_sessions
import web_view/view/ended
import web_view/view/heading
import web_view/view/home_bar
import web_view/view/notice.{type Spoken, Spoken}
import web_view/view/shell

/// The Lustre event path of the page's body: the centre column is the third
/// child of the frame (`view/shell`), and the body is the centre's second child,
/// after the notice's place. Every handler of the page is beneath it, so the
/// admin page's socket admits a click or a submit beneath this path and no other
/// event. `admin_test` fails if the view moves the region.
pub const body_path = "0\t2\t1"

/// How long the page's snapshot stands before it is read again, in milliseconds.
/// The catalogue changes when someone claims an invitation or the owner changes
/// it from a terminal, which is rare, and a read is a pair of queries. It is the
/// home's own interval (`web_view/home.refresh_ms`).
pub const refresh_ms = 30_000

/// What the daemon supplies when it starts the component.
pub type Start {
  Start(
    /// The principal's display name, a catalogue field, for the top bar.
    name: String,
    /// The interval between reads, in milliseconds. Production passes
    /// `refresh_ms`; a test passes a short one.
    refresh_ms: Int,
    /// Asks the daemon for a snapshot, with the session the owner has chosen if
    /// they have, and returns at once. The answer goes to the function it is
    /// given, from the daemon's own task, as `Answered`'s message. The daemon
    /// makes every read as the page's principal with the page's own credential
    /// digest and answers `Closed` for a page that has ended.
    read: fn(Option(String), fn(Reading) -> Nil) -> Nil,
    /// Asks the daemon to make one change and returns at once. The answer goes
    /// to the function it is given, from the daemon's own task, as `Acted`'s
    /// message. The daemon checks the page, its ceiling, the credential, the
    /// owner and the allowance again, whatever this page said.
    act: fn(Action, fn(Answer) -> Nil) -> Nil,
    /// The wall-clock time in Unix milliseconds, which the people's ages are
    /// counted from. It is read once for each snapshot, in the component's
    /// process, and must return at once.
    now: fn() -> Int,
    /// The fingerprint of the browser login this page was opened from, if it
    /// was, which the owner's own sign-in list marks as "This browser".
    login: Option(String),
    /// The instant this page ends, in Unix milliseconds on `now`'s clock. The
    /// daemon takes it from the live UI session when the page opens: the
    /// earlier of the home's own end and fifteen minutes after the exchange. The
    /// bar's pill counts down to it (`home_bar.ending`), so no sentence of the
    /// body has to say when the page ends. It is an in-daemon value and no
    /// browser supplies it.
    ends_at: Int,
  )
}

// Whether a read also arms the timer for the next one. The first read and every
// tick do; a read that follows a press does not, since the interval that is
// already running will fire on its own.
type Interval {
  Rearm
  Continue
}

// Whether a read is out, and what the page does when it answers. A read can
// make a registry call for each listed session, so the page runs one at a time:
// a read that is asked for while one is out is not started but remembered, as one
// more to run when the answer arrives, never as a queue.
type Flight {
  /// No read is out.
  Landed

  /// A read is out, asked under `asked` (the session chosen when it started).
  Flying(asked: Option(String), then: Then)
}

// What a read that lands starts next.
type Then {
  /// Nothing: no one asked for another read while it ran.
  Nothing

  /// One more read, because a press or a settled change asked for one.
  Again
}

/// What the page says about its own standing.
pub type Status {
  /// No read has answered yet.
  Connecting

  /// A read answered, and nothing since has ended the page.
  Connected

  /// A read said the page can no longer be served. The top bar words it with
  /// `ending`.
  Ended(ending: Ending)
}

/// The component's state: what it was started with, what the last read found,
/// what the owner has chosen and armed, and the one ask that may be out.
pub opaque type Model {
  Model(
    start: Start,
    status: Status,
    /// The last read's snapshot, or none before the first.
    snapshot: Option(grants.Snapshot),
    /// The time the last snapshot was read, in Unix milliseconds.
    now: Int,
    /// The session the owner pressed, or none. It is the next read's argument.
    chosen: Option(String),
    /// How many reads have been asked for, which numbers the next. An answer
    /// whose number is not the latest was overtaken and is dropped.
    reads: Int,
    /// Whether a read is out. At most one runs, whatever asks for another.
    flight: Flight,
    /// The refresh timer's subject, known once the runtime has made it.
    timer: Option(Subject(Nil)),
    /// The ask that is out, if one is. A second ask while it is set asks nothing.
    waiting: Option(Action),
    /// The revocation the owner has armed with a first press, if any.
    armed: Option(Action),
    /// What the page last said about an ask, in fixed words, with the action it
    /// is about, which decides where it is drawn.
    notice: Option(Spoken),
    /// The claim an ask made, until the owner hides it.
    claim: Option(Claim),
    /// How many invitations this page has made. It keys the invitation form, so
    /// an invitation that was made opens a fresh form with its name field empty,
    /// and a read, a refusal or any other change leaves the form as it is.
    invited: Int,
    /// The last refusal of a grant for want of allowance: the Unix time in
    /// milliseconds at which a place frees and the refusal's own words, which the
    /// buttons that grant carry in their `title` until then.
    spent: Option(#(Int, String)),
    /// The principal whose rename form is open, if one is. Only one is open at a
    /// time, and an answer that made the change, or a read that no longer lists
    /// the principal, closes it.
    editing: Option(String),
  )
}

/// Everything the component can be told. A browser sends only the presses; the
/// rest are sent by an effect the component ran, or by its own timer.
pub type Msg {
  /// The runtime made the refresh timer's subject. The first read and the first
  /// arming follow.
  TimerReady(timer: Subject(Nil))

  /// The refresh interval passed.
  Ticked

  /// The answer to a read, with the number it was asked under. It is the
  /// effect's own message, dispatched from the daemon's task, and no handler
  /// carries it.
  Answered(serial: Int, reading: Reading)

  /// A session's row was pressed: read its members. The identity is the
  /// catalogue's, fixed when the tree was drawn, and the daemon checks it again.
  Choosing(session: String)

  /// A button that changes something was pressed, or the invitation form was
  /// submitted. The identities in the action are the catalogue's, fixed when the
  /// tree was drawn; the text of a name is the browser's and nothing else is.
  Asking(action: Action)

  /// A revocation's first press: show what it will do and wait for the second.
  Arming(action: Action)

  /// The armed revocation's Cancel was pressed.
  Disarming

  /// The daemon answered an ask. It is the effect's own message, dispatched
  /// from the daemon's task, and no handler carries it, so a browser cannot put
  /// a claim or a notice in the page that the daemon did not make.
  Acted(answer: Answer)

  /// The button that hides the claim on screen was pressed.
  Dismissed

  /// A person's Rename button was pressed: open that row's form. The identity is
  /// the catalogue's, fixed when the tree was drawn, and the daemon checks it
  /// again when a name is sent.
  Editing(principal: String)

  /// The open rename form's Cancel was pressed: close it.
  EditCancelled
}

/// The application the daemon's socket starts, one per admin page.
///
/// ## Examples
///
/// ```gleam
/// // lustre.start_server_component(admin.app(), start)
/// ```
pub fn app() -> lustre.App(Start, Model, Msg) {
  lustre.application(init, update, view)
}

/// A component for `start`, before its timer exists: `init` without its
/// effects, for a test that drives it through `update`.
///
/// ## Examples
///
/// ```gleam
/// // let model = admin.new(start)
/// ```
pub fn new(start: Start) -> Model {
  Model(
    start:,
    status: Connecting,
    snapshot: None,
    now: 0,
    chosen: None,
    reads: 0,
    flight: Landed,
    timer: None,
    waiting: None,
    armed: None,
    notice: None,
    claim: None,
    invited: 0,
    spent: None,
    editing: None,
  )
}

/// The component's first state and the one subscription it runs for its life:
/// the refresh timer, whose subject the runtime makes.
///
/// ## Examples
///
/// ```gleam
/// // lustre.application(admin.init, admin.update, admin.view)
/// ```
pub fn init(start: Start) -> #(Model, Effect(Msg)) {
  #(new(start), wire())
}

// Creates the timer's subject and selects it, in the component's own process,
// which owns both. The subject is handed to `update` so it can arm it.
fn wire() -> Effect(Msg) {
  use dispatch, timer <- server_component.select
  dispatch(TimerReady(timer))
  process.new_selector()
  |> process.select_map(timer, fn(_) { Ticked })
}

/// Applies one message.
///
/// Wiring the timer and every tick do the same two things, in the same order:
/// ask for a read, then arm the timer for the next one. A page that ended arms
/// nothing, so the last read is the last.
///
/// ## Examples
///
/// ```gleam
/// // let #(model, effect) = admin.update(model, admin.Ticked)
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    TimerReady(timer:) -> reading(Model(..model, timer: Some(timer)), Rearm)

    // An ended page is not read again, so its timer is left to lapse.
    Ticked ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected -> reading(model, Rearm)
      }

    Answered(serial:, reading:) ->
      case serial == model.reads {
        True -> landed(model, reading)
        False -> #(model, effect.none())
      }

    // Choosing a session reads its members at once. An ended page asks nothing:
    // its principal's access is gone, and the daemon would refuse.
    Choosing(session:) ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected ->
          reading(
            Model(
              ..model,
              chosen: Some(session),
              armed: None,
              notice: None,
              snapshot: unselected(model.snapshot),
            ),
            Continue,
          )
      }

    // An ask goes to the daemon from the daemon's own task so the runtime stays
    // free. An ended page, a page that has not connected and a page whose ask is
    // already out ask nothing; the buttons of such a page carry no handler, so
    // these arms are the second layer, and the daemon is the third. Making a
    // session shareable stops it, so it is sent only from the question its own
    // button opened: a press that names it while it is not armed asks nothing.
    Asking(action:) ->
      case model.status, model.waiting {
        Connected, None ->
          case confirmed(action, model.armed) {
            True -> #(
              Model(..model, waiting: Some(action), armed: None, notice: None),
              acting(model.start.act, action),
            )
            False -> #(model, effect.none())
          }
        Connected, Some(_) | Connecting, _ | Ended(_), _ -> #(
          model,
          effect.none(),
        )
      }

    // Arming a revocation changes nothing but what the page draws. A second
    // revocation armed replaces the first, so at most one is ever armed.
    Arming(action:) ->
      case model.status, model.waiting {
        Connected, None -> #(Model(..model, armed: Some(action)), effect.none())
        Connected, Some(_) | Connecting, _ | Ended(_), _ -> #(
          model,
          effect.none(),
        )
      }

    Disarming -> #(Model(..model, armed: None), effect.none())

    // The answer to the ask that is out. A claim is held until the owner hides
    // it, a change is worded, and a refusal is worded in the reason's fixed
    // words. Each is followed by a read, so the page shows what the catalogue now
    // holds. An answer that arrives when no ask is out was not asked for and is
    // dropped.
    Acted(answer:) ->
      case model.waiting {
        None -> #(model, effect.none())
        Some(action) -> settled(Model(..model, waiting: None), action, answer)
      }

    Dismissed -> #(Model(..model, claim: None), effect.none())

    // A rename form opens on a connected page that has no ask out. Opening one
    // disarms a revocation and clears the last notice, as every other press does.
    Editing(principal:) ->
      case model.status, model.waiting {
        Connected, None -> #(
          Model(..model, editing: Some(principal), armed: None, notice: None),
          effect.none(),
        )
        Connected, Some(_) | Connecting, _ | Ended(_), _ -> #(
          model,
          effect.none(),
        )
      }

    EditCancelled -> #(Model(..model, editing: None), effect.none())
  }
}

// Whether an ask may be sent now. Every change but one is sent by the press
// that names it; making a session shareable stops and restarts it, so it is sent
// only once the owner has armed it with a first press and been shown what it
// does.
fn confirmed(action: Action, armed: Option(Action)) -> Bool {
  case action {
    grants.MakeShareable(..) -> armed == Some(action)
    grants.Invite(..)
    | grants.SetRole(..)
    | grants.RevokeMembership(..)
    | grants.RevokeCredentials(..)
    | grants.Rotate(..)
    | grants.RevokeSignin(..)
    | grants.Rename(..) -> True
  }
}

// The model after an ask was answered, and the read that follows it. A refusal
// of a thing that is no longer there also reads again, so the page stops
// drawing it.
fn settled(
  model: Model,
  action: Action,
  answer: Answer,
) -> #(Model, Effect(Msg)) {
  case answer {
    grants.Claimed(claim:) ->
      reading(
        Model(
          ..model,
          claim: Some(claim),
          notice: None,
          invited: invitations(model.invited, claim.purpose),
        ),
        Continue,
      )
    grants.Changed ->
      reading(
        Model(
          ..model,
          notice: Some(Spoken(action, notice.Said(grants.changed_words(action)))),
          editing: closed_by(model.editing, action),
        ),
        Continue,
      )
    grants.Declined(reason:) ->
      reading(
        Model(
          ..model,
          notice: Some(Spoken(action, refusal(reason))),
          spent: spent_by(reason, model.spent),
        ),
        Continue,
      )
  }
}

// The count of invitations after a claim: an invitation makes a fresh form, a
// rotation leaves the form alone.
fn invitations(invited: Int, purpose: grants.Purpose) -> Int {
  case purpose {
    grants.Invited(..) -> invited + 1
    grants.Rotated -> invited
  }
}

// What the page says about a refusal. An allowance that is spent says when a
// place frees as an instant the browser words in its own zone; every other
// reason is its fixed words.
fn refusal(reason: grants.Reason) -> notice.Notice {
  case reason {
    grants.TooMany(used:, free_at_ms:) -> notice.Throttled(used:, free_at_ms:)
    grants.NotOwner
    | grants.NotIsolated
    | grants.NotFound
    | grants.NotStopped
    | grants.NotMoved
    | grants.Stranded
    | grants.NotResumed
    | grants.InvalidName
    | grants.Unavailable -> notice.Refused(grants.reason_words(reason))
  }
}

// The allowance state after a refusal: a refusal for want of allowance records
// when a place frees and the words that say so, and any other refusal leaves what
// was recorded, since it says nothing about the allowance.
fn spent_by(
  reason: grants.Reason,
  before: Option(#(Int, String)),
) -> Option(#(Int, String)) {
  case reason {
    grants.TooMany(free_at_ms:, ..) ->
      Some(#(free_at_ms, grants.reason_words(reason)))
    grants.NotOwner
    | grants.NotIsolated
    | grants.NotFound
    | grants.NotStopped
    | grants.NotMoved
    | grants.Stranded
    | grants.NotResumed
    | grants.InvalidName
    | grants.Unavailable -> before
  }
}

// Asks for a read and, when `interval` says so, arms the timer for the next one
// in the same effect, so the next read is counted from this ask. The number the
// read is asked under is the model's next.
//
// Only one read is out at a time. While one is, a tick starts nothing and only
// arms the timer again, and a press or a settled change marks that one more read
// is wanted, which starts when the answer lands.
fn reading(model: Model, interval: Interval) -> #(Model, Effect(Msg)) {
  case model.flight, interval {
    Flying(..), Rearm -> #(model, rearming(model))
    Flying(asked:, ..), Continue -> #(
      Model(..model, flight: Flying(asked:, then: Again)),
      effect.none(),
    )
    Landed, _ -> {
      let serial = model.reads + 1
      let model =
        Model(
          ..model,
          reads: serial,
          flight: Flying(asked: model.chosen, then: Nothing),
        )
      let effect = {
        use dispatch <- effect.from
        model.start.read(model.chosen, fn(reading) {
          dispatch(Answered(serial, reading))
        })
        arm(model, interval)
      }
      #(model, effect)
    }
  }
}

// The effect that arms the timer for the next tick and does nothing else.
fn rearming(model: Model) -> Effect(Msg) {
  use _ <- effect.from
  arm(model, Rearm)
}

fn arm(model: Model, interval: Interval) -> Nil {
  case interval, model.timer {
    Rearm, Some(timer) -> {
      let _ = process.send_after(timer, model.start.refresh_ms, Nil)
      Nil
    }
    Rearm, None | Continue, _ -> Nil
  }
}

// A read landed: what it found is applied, and the one more read that was asked
// for while it ran starts now. A read asked under a session that is no longer the
// chosen one found that session's members, which the page must not draw under the
// new choice, so its selection is dropped and the choice kept; the read that
// follows finds the right one. A page that ended starts nothing.
fn landed(model: Model, result: Reading) -> #(Model, Effect(Msg)) {
  let #(asked, then) = case model.flight {
    Flying(asked:, then:) -> #(asked, then)
    Landed -> #(model.chosen, Nothing)
  }
  let found = case result, asked == model.chosen {
    grants.Read(snapshot:), False ->
      grants.Read(grants.Snapshot(..snapshot, selection: None))
    _, _ -> result
  }
  let after = answered(Model(..model, flight: Landed), found)
  let after = case asked == model.chosen {
    True -> after
    False -> Model(..after, chosen: model.chosen)
  }
  case then, after.status {
    Again, Connecting | Again, Connected -> reading(after, Continue)
    Again, Ended(_) | Nothing, _ -> #(after, effect.none())
  }
}

// Starts the daemon's task for one ask and returns at once; the answer arrives
// later as `Acted`, dispatched from the task's own process.
fn acting(
  act: fn(Action, fn(Answer) -> Nil) -> Nil,
  action: Action,
) -> Effect(Msg) {
  use dispatch <- effect.from
  act(action, fn(answer) { dispatch(Acted(answer)) })
}

// What a read changes. A snapshot replaces what the page holds, so a person who
// is gone is gone from the page; a closed page keeps the last snapshot it drew
// with the notice beside it, as the home keeps its last list. A session the
// owner chose that the catalogue no longer holds is forgotten.
fn answered(model: Model, reading: Reading) -> Model {
  case reading {
    grants.Read(snapshot:) ->
      Model(
        ..model,
        status: Connected,
        snapshot: Some(snapshot),
        now: model.start.now(),
        chosen: still_chosen(model.chosen, snapshot),
        armed: still_armed(model.armed, snapshot),
        editing: still_editing(model.editing, snapshot),
        waiting: still_waiting(model.waiting, snapshot),
      )
    grants.Unread -> model
    grants.Closed(ending:) -> Model(..model, status: Ended(ending:))
  }
}

// An ask that is out survives a read, except making a session shareable once a
// read finds that session shareable. The task runs in a process no page owns and
// its answer goes to this page's runtime, which can be gone; a task that never
// delivers would leave every button disabled for good. A read that shows the
// scope already changed is the page's proof the change was made, so the ask is
// no longer out. The task may still be resuming the session, and its answer, if
// it arrives later, finds no ask out and is dropped.
fn still_waiting(
  waiting: Option(Action),
  snapshot: grants.Snapshot,
) -> Option(Action) {
  case waiting {
    Some(grants.MakeShareable(session:)) ->
      case
        list.any(snapshot.summaries, fn(row) {
          row.session == session && row.scope == creations.Shareable
        })
      {
        True -> None
        False -> waiting
      }
    Some(_) | None -> waiting
  }
}

// The chosen session survives a read that found its members, and is forgotten
// when the read found none because the catalogue no longer holds it.
fn still_chosen(
  chosen: Option(String),
  snapshot: grants.Snapshot,
) -> Option(String) {
  case chosen, snapshot.selection {
    Some(_), None -> None
    Some(_), Some(_) | None, _ -> chosen
  }
}

// An armed revocation survives a read, so a refresh does not take back a first
// press the owner has not yet followed with the second, unless what it names has
// gone: a principal no longer listed, or a member no longer holding the session.
fn still_armed(
  armed: Option(Action),
  snapshot: grants.Snapshot,
) -> Option(Action) {
  case armed {
    Some(grants.RevokeCredentials(principal:)) ->
      case list.any(snapshot.principals, fn(row) { row.id == principal }) {
        True -> armed
        False -> None
      }
    Some(grants.RevokeMembership(principal:, ..)) ->
      case snapshot.selection {
        Some(selection) ->
          case
            list.any(selection.holders, fn(row) { row.principal == principal })
          {
            True -> armed
            False -> None
          }
        None -> None
      }
    Some(grants.RevokeSignin(principal:, fingerprint:)) ->
      case
        list.any(snapshot.logins, fn(held) {
          held.principal == principal
          && list.any(held.shown, fn(row) { row.fingerprint == fingerprint })
        })
      {
        True -> armed
        False -> None
      }
    Some(grants.MakeShareable(session:)) ->
      case snapshot.selection {
        Some(selection) ->
          case selection.session == session, selection.scope {
            True, creations.Private -> armed
            True, creations.Shareable | False, _ -> None
          }
        None -> None
      }
    Some(grants.Invite(..))
    | Some(grants.SetRole(..))
    | Some(grants.Rename(..))
    | Some(grants.Rotate(_)) -> None
    None -> None
  }
}

// The rename form that is open after a change: the one the change was for is
// closed, since its name has been stored, and any other stays.
fn closed_by(editing: Option(String), action: Action) -> Option(String) {
  case action, editing {
    grants.Rename(principal: renamed, ..), Some(open) if renamed == open -> None
    _, _ -> editing
  }
}

// The open rename form survives a read that still lists its principal, so a
// refresh does not take back a name the owner is typing, and goes when the
// principal is no longer listed.
fn still_editing(
  editing: Option(String),
  snapshot: grants.Snapshot,
) -> Option(String) {
  case editing {
    Some(principal) ->
      case list.any(snapshot.principals, fn(row) { row.id == principal }) {
        True -> editing
        False -> None
      }
    None -> None
  }
}

// The snapshot with the previous session's members dropped, for the instant
// between choosing another session and the read that finds its members.
fn unselected(snapshot: Option(grants.Snapshot)) -> Option(grants.Snapshot) {
  option.map(snapshot, fn(held) { grants.Snapshot(..held, selection: None) })
}

/// Where the page stands.
///
/// ## Examples
///
/// ```gleam
/// assert admin.status(admin.new(start)) == admin.Connecting
/// ```
pub fn status(model: Model) -> Status {
  model.status
}

/// The claim on screen, if one is.
///
/// ## Examples
///
/// ```gleam
/// assert admin.claim(admin.new(start)) == None
/// ```
pub fn claim(model: Model) -> Option(Claim) {
  model.claim
}

/// The page: the frame the home draws, with no sidebar and no panel. Its top bar
/// names the page, the principal and the most the page may do, and carries the
/// notice of a page that ended.
///
/// The centre's children are, in order, a place that holds nothing (the notice
/// used to be drawn there, and `body_path` and the daemon's socket pin the body
/// at the place after it), and the body (`body_path`), which holds a line of
/// lead, the people and the sessions. A notice and a claim are drawn inside the
/// section of what was acted on, so nothing on the page is sticky and nothing
/// covers the lists.
///
/// ## Examples
///
/// ```gleam
/// // element.to_string(admin.view(model))
/// ```
pub fn view(model: Model) -> Element(Msg) {
  shell.view(
    shell.Home,
    home_bar.with(
      title: "Admin",
      // The owner's own page carries no role pill, as the owner's home does not
      // (the round-4 ruling on F72). It carries the time it has left instead,
      // once a read has said what time it is.
      who: home_bar.ending(model.start.name, remaining(model)),
      status: status_words(model.status),
      tone: status_tone(model.status),
      notice: ended.admin(ended_ending(model.status)),
      trailing: back_home(),
    ),
    shell.Unlisted,
    [element.none(), body(model)],
    element.none(),
    0,
    "",
  )
}

// The milliseconds the page has left as of the last read, which is when `now`
// was taken, or nothing before the first read. The pill's element counts on
// from this in the browser, and a later read brings a fresh figure, so the
// count is anchored again every read.
fn remaining(model: Model) -> Option(Int) {
  case model.snapshot {
    Some(_) -> Some(int.max(0, model.start.ends_at - model.now))
    None -> None
  }
}

// The bar's trailing control: Back to the page the owner came from. It is a
// `<loom-back>`, which calls `history.back()` in the browser and sends this
// component nothing, so it mints no ticket and the admin page's fifteen
// minutes are not carried to a home (protocol-change/051, the addendum on
// navigation). Its label is the element's light text.
fn back_home() -> Element(Msg) {
  element.element("loom-back", [], [html.text("Home")])
}

// The body: a line that says what the page is, then the lists. When the page
// ends is the bar's pill, not a sentence here.
// Before the first read it holds that line and one that says the page is reading.
fn body(model: Model) -> Element(Msg) {
  let presses = presses()
  let busy = busy(model)
  html.div([attribute.class("admin-body")], [
    html.p([attribute.class("admin-lead")], [
      html.text("Who can use this daemon, and what each can do."),
    ]),
    ..case model.snapshot {
      None -> [
        html.p([attribute.class("home-empty")], [
          html.text("Reading the catalogue."),
        ]),
      ]
      Some(snapshot) -> [
        admin_people.principals(
          snapshot.principals,
          snapshot.more_principals,
          snapshot.logins,
          model.start.login,
          model.now,
          model.armed,
          model.notice,
          model.claim,
          model.editing,
          presses,
          busy,
        ),
        admin_sessions.view(
          snapshot.sessions,
          model.chosen,
          snapshot.selection,
          snapshot.summaries,
          model.armed,
          model.waiting,
          model.notice,
          model.claim,
          model.invited,
          presses,
          busy,
        ),
      ]
    }
  ])
}

// Whether a button may be pressed: not while an ask is out.
fn busy(model: Model) -> Busy {
  case model.waiting, model.spent {
    Some(_), _ -> admin_buttons.Occupied
    None, Some(#(frees, words)) if model.now < frees ->
      admin_buttons.Spent(words)
    None, Some(_) | None, None -> admin_buttons.Free
  }
}

// The messages the controls send, as values.
fn presses() -> Presses(Msg) {
  admin_buttons.Presses(
    ask: Asking,
    arm: Arming,
    disarm: Disarming,
    choose: Choosing,
    dismiss: Dismissed,
    invite: submitting,
    edit: Editing,
    cancel: EditCancelled,
    rename: renaming,
  )
}

// A rename form's submit as the message that names the principal the server drew
// into the tree and carries the one text field the form has. Any other field, a
// repeated one or a missing one refuses the event, as the invitation form does.
fn renaming(principal: String) -> attribute.Attribute(Msg) {
  event.on("submit", renamed(principal)) |> event.prevent_default
}

fn renamed(principal: String) -> decode.Decoder(Msg) {
  use listed <- decode.subfield(
    ["detail", "formData"],
    admin_sessions.form_data(),
  )
  case listed {
    [#("text", name)] -> decode.success(Asking(grants.Rename(principal, name)))

    // Lustre drops an event whose decoder failed, so the message stood in here
    // is never delivered.
    _ -> decode.failure(Asking(grants.Rename(principal, "")), "rename form")
  }
}

// The invitation form's submit as the message that names the session the
// server drew into the tree and carries the two fields the form has. Any other
// field, a repeated one or a missing one refuses the event, as the control forms
// do.
fn submitting(session: String) -> attribute.Attribute(Msg) {
  event.on("submit", submitted(session)) |> event.prevent_default
}

fn submitted(session: String) -> decode.Decoder(Msg) {
  use listed <- decode.subfield(
    ["detail", "formData"],
    admin_sessions.form_data(),
  )
  case admin_sessions.fields(listed) {
    Ok(#(name, role)) ->
      decode.success(Asking(grants.Invite(session, role, name)))

    // Lustre drops an event whose decoder failed, so the message stood in here
    // is never delivered.
    Error(Nil) ->
      decode.failure(
        Asking(grants.Invite(session, invites.Observer, "")),
        "invitation form",
      )
  }
}

fn status_tone(status: Status) -> heading.Tone {
  case status {
    Connecting -> heading.Pending
    Connected -> heading.Live
    Ended(_) -> heading.Closed
  }
}

fn status_words(status: Status) -> String {
  case status {
    Connecting -> "connecting"
    Connected -> "connected"
    Ended(_) -> "disconnected"
  }
}

// The ending a page that ended draws a notice for.
fn ended_ending(status: Status) -> Option(Ending) {
  case status {
    Connecting | Connected -> None
    Ended(ending:) -> Some(ending)
  }
}
