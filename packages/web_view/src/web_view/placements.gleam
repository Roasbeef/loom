//// Where a session may be placed, as the owner's home page shows it when the
//// form for a registered workspace opens (protocol-change/085).
////
//// The daemon knows the executors and pools its configuration defines, and a
//// reply to `deployment.status` says which executors its own connection
//// attempts reached. This module is the page's half of that: the names the page
//// was told when it opened, what the daemon reported about each when the form
//// opened, and the choice a person makes among them. The daemon and the page
//// agree on this vocabulary here, and the page learns nothing else about the
//// deployment: no node name, address, key or path. An executor that answered
//// also states how many scopes are free and whether its census contradicts its
//// declaration, which the card draws as words.
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

  /// It answered, and its report states a reason a person should know before
  /// choosing it. A session can still be placed on it.
  Degraded

  /// It answered, and every scope it admits is held, so the next attach is
  /// refused for lack of room until an operator releases one.
  Full

  /// The daemon's own connection attempt to it failed, or it did not give its
  /// report in time.
  Down
}

/// What the daemon reported about one executor.
pub type Report {
  Report(
    /// The state.
    state: State,
    /// The platform its operator declared, as `<os>/<architecture>`.
    platform: Option(String),
    /// The sandbox enforcement its operator declared.
    enforcement: Option(String),
    /// The toolchains its operator declared, possibly none.
    toolchains: List(String),
    /// How many more scopes it admits, when it reported.
    free_scopes: Option(Int),
    /// The words saying its census contradicts what its operator declared, when
    /// it does. They are the operator's own configuration values and the
    /// machine's report, drawn as text.
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

/// What the daemon answers to a request for the placements: it connected to the
/// executors and describes each.
pub type Read {
  Reported(placements: Placements)
}

/// How far the page's knowledge of the placements has got.
pub type Readiness {
  /// The names are known and the daemon's read is out.
  Checking

  /// The daemon's reply is in.
  Checked
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
/// arrives.
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

/// The cards after a read: the daemon's report, marked as checked.
///
/// ## Examples
///
/// ```gleam
/// let read = placements.Reported(placements.Placements([], []))
/// assert placements.after(read).readiness == placements.Checked
/// ```
pub fn after(read: Read) -> Cards {
  case read {
    Reported(placements:) -> Cards(placements:, readiness: Checked)
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

/// The pill tint for a state, from the three the page already has for a
/// connection, so no colour is added: `online` for a ready executor, `pending`
/// for one that answered with a reason, and `ended` for one that is full or
/// down.
///
/// ## Examples
///
/// ```gleam
/// assert placements.pill_class(placements.Degraded) == "pending"
/// ```
pub fn pill_class(state: State) -> String {
  case state {
    Ready -> "online"
    Degraded -> "pending"
    Full | Down -> "ended"
  }
}
