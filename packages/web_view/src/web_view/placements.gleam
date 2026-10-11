//// Where a session may be placed, as the owner's home page shows it when the
//// form for a registered workspace opens (protocol-change/085).
////
//// The daemon knows the executors and pools its configuration defines, and a
//// reply to `deployment.status` says which executors its own connection
//// attempts reached. This module is the page's half of that: the names the page
//// was told when it opened, what the daemon reported about each when the form
//// opened, and the choice a person makes among them. The daemon and the page
//// agree on this vocabulary here, and the page learns nothing else about the
//// deployment: no node name, address, key or path.
////
//// ## What the state means
////
//// A state is advice. It is what the daemon found a moment before the form
//// opened, and the form never refuses a choice because of it: an executor that
//// is `Down` is drawn with that word and can still be chosen, because the
//// daemon decides again when the session opens (`server.create_session` for the
//// configuration, the executor's own answer at the attach). A person who knows
//// the machine is about to come back is not stopped.
////
//// ## Where the text comes from
////
//// Every name here is the owner's configuration, and a state, a platform and a
//// toolchain are words the daemon chose or the operator declared. The page draws
//// each as a text node and never as an attribute, a class or a key. The only
//// strings that become classes are the fixed words `pill_class` returns.

import gleam/list
import gleam/option.{type Option}

/// The state the daemon gives an executor for placing a session on it.
pub type State {
  /// A session can be placed on it.
  Ready

  /// A session can be placed on it, with a caveat the report states.
  Degraded

  /// It would refuse the next attach for lack of room.
  Full

  /// The daemon's own connection attempt to it failed.
  Down
}

/// What the daemon reported about one executor.
pub type Report {
  Report(
    /// The state.
    state: State,
    /// How many more scopes it can take, when it said.
    free_scopes: Option(Int),
    /// The platform its operator declared, as `<os>/<architecture>`.
    platform: Option(String),
    /// The sandbox enforcement its operator declared.
    enforcement: Option(String),
    /// The toolchains its operator declared, possibly none.
    toolchains: List(String),
    /// Words saying its census contradicts its declaration, when it does.
    contradiction: Option(String),
  )
}

/// An executor the page can offer.
pub type Executor {
  Executor(
    /// The `[executors.<name>]` key.
    name: String,
    /// What the daemon reported, or `None` before it has or when it could not.
    report: Option(Report),
  )
}

/// What the daemon reported about one pool.
pub type PoolReport {
  PoolReport(
    /// The executors the pool admits, in the order a first open tries them.
    executors: List(String),
    /// Those of them the daemon reached, in the same order.
    eligible: List(String),
  )
}

/// A pool the page can offer.
pub type Pool {
  Pool(
    /// The `[pools.<name>]` key.
    name: String,
    /// What the daemon reported, or `None` before it has or when it could not.
    report: Option(PoolReport),
  )
}

/// The executors and pools the page offers, in the order the configuration
/// lists them.
pub type Placements {
  Placements(executors: List(Executor), pools: List(Pool))
}

/// What the daemon answers to a request for the placements.
pub type Read {
  /// The daemon connected to the executors and describes each.
  Reported(placements: Placements)

  /// The daemon could not say. The page keeps the names it was given.
  Unreported
}

/// How far the page's knowledge of the placements has got.
pub type Readiness {
  /// The names are known and the daemon's read is out.
  Checking

  /// The daemon's reply is in.
  Checked

  /// The daemon's read gave nothing, so the cards carry names alone.
  Unchecked
}

/// What the form draws its cards from.
pub type Cards {
  Cards(
    /// The executors and pools.
    placements: Placements,
    /// Whether they carry the daemon's report.
    readiness: Readiness,
  )
}

/// One executor or one pool, as a person chooses it. The name is always one the
/// page drew a card for: it is carried by the message the page built, and the
/// browser's event names only the card it fired at.
pub type Choice {
  /// A session on this executor.
  OnExecutor(name: String)

  /// A session in this pool, on whichever executor the daemon first opens it on.
  InPool(name: String)
}

/// The cards for names alone: what the page knows before the daemon's read
/// arrives, and keeps when the read gives nothing.
///
/// ## Examples
///
/// ```gleam
/// let cards = placements.listed(["box"], ["builders"])
/// assert cards.readiness == placements.Checking
/// ```
pub fn listed(executors: List(String), pools: List(String)) -> Cards {
  Cards(
    placements: Placements(
      executors: list.map(executors, fn(name) {
        Executor(name:, report: option.None)
      }),
      pools: list.map(pools, fn(name) { Pool(name:, report: option.None) }),
    ),
    readiness: Checking,
  )
}

/// The cards after a read: the daemon's report when it gave one, and otherwise
/// the names the page already had, marked as not checked.
///
/// ## Examples
///
/// ```gleam
/// let before = placements.listed(["box"], [])
/// assert placements.after(before, placements.Unreported).readiness
///   == placements.Unchecked
/// ```
pub fn after(cards: Cards, read: Read) -> Cards {
  case read {
    Reported(placements:) -> Cards(placements:, readiness: Checked)
    Unreported -> Cards(..cards, readiness: Unchecked)
  }
}

/// Whether the cards include the one a choice names. A choice the page did not
/// draw is never honoured.
///
/// ## Examples
///
/// ```gleam
/// let cards = placements.listed(["box"], ["builders"])
/// assert placements.offers(cards, placements.OnExecutor("box"))
/// assert !placements.offers(cards, placements.OnExecutor("builders"))
/// assert !placements.offers(cards, placements.InPool("box"))
/// ```
pub fn offers(cards: Cards, choice: Choice) -> Bool {
  case choice {
    OnExecutor(name:) ->
      list.any(cards.placements.executors, fn(each) { each.name == name })
    InPool(name:) ->
      list.any(cards.placements.pools, fn(each) { each.name == name })
  }
}

/// Whether there is anything to choose.
///
/// ## Examples
///
/// ```gleam
/// assert !placements.any(placements.listed([], []))
/// ```
pub fn any(cards: Cards) -> Bool {
  cards.placements.executors != [] || cards.placements.pools != []
}

/// The word a state is drawn as.
///
/// ## Examples
///
/// ```gleam
/// assert placements.state_words(placements.Down) == "down"
/// ```
pub fn state_words(state: State) -> String {
  case state {
    Ready -> "ready"
    Degraded -> "degraded"
    Full -> "full"
    Down -> "down"
  }
}

/// The pill tint for a state: the three the page already has for a connection,
/// so no colour is added. A state that is not `ready` and not `down` is a
/// caveat, and reads as the middle tint.
///
/// ## Examples
///
/// ```gleam
/// assert placements.pill_class(placements.Ready) == "online"
/// ```
pub fn pill_class(state: State) -> String {
  case state {
    Ready -> "online"
    Degraded | Full -> "pending"
    Down -> "ended"
  }
}
