//// The standing ledger of an account pool, as a pure state machine.
////
//// A pool is an ordered list of credentials for one provider that sit behind
//// one logical route. This module decides only two things: which member the
//// next request should use, and when a member that a provider refused for
//// exhausted allowance becomes usable again. It holds no process, reads no
//// clock and touches no credential. The caller passes the time in with each
//// event, and a member is named by its configured label and nothing else, so
//// neither a token nor an account identifier can reach this module, its
//// effects or a log line built from them. `docs/design-notes/account-pool.md`
//// has the design this ledger serves, including what is deliberately left to
//// the caller.
////
//// Selection is a rule with no memory beyond the ledger: the first member, in
//// configured order, whose standing is `Available` when asked. A member that
//// the provider refused for usage limits is `Exhausted` until the reset time
//// the provider named, or until a configured hold when it named none, and
//// returns on its own: there is no timer, only the comparison of `until_ms`
//// with the `now_ms` of the next event. A member whose grant is gone or lacks
//// plan permission is `Unusable` and stays so until an operator reinstates
//// it, since waiting repairs neither.
////
//// A reading of the provider's own gauge (`Observed`) can move a member to
//// `Exhausted` before the provider refuses it, but never moves one back: only
//// a reset time passing or a reinstatement does that. The ledger therefore
//// never rests on a stale gauge to declare a seat usable.
////
//// ## Flow
////
//// `new` builds the ledger from labels, `step` applies one `Event`, and
//// `report` projects the ledger for display.
////
//// 1. `new` refuses an empty list, a repeated label and a non-positive hold,
////    so a ledger always has a member to choose and a finite wait.
//// 2. `step` with `Pick` first returns every expired `Exhausted` member to
////    `Available`, then chooses the first available one.
//// 3. `step` with `Refused` or `Observed` moves the named member; an unknown
////    label changes nothing.
//// 4. `report` shows each member's standing and the live reading of its
////    gauge, treating a reading whose window has reset as no reading.
////
//// ## Transitions
////
//// <!-- transitions: pool.Standing -->
////
//// | state | `Pick` | `Refused` by usage limit | `Refused` by authorization | `Observed` | `Reinstated` |
//// | --- | --- | --- | --- | --- | --- |
//// | `Available` | chosen, when it is the first available member | `Exhausted` until the named reset, or until the hold | `Unusable` | `Exhausted` when a window reads full, otherwise unchanged | unchanged |
//// | `Exhausted` | back to `Available` once `now_ms` reaches `until_ms`, then eligible; otherwise passed over | stays `Exhausted`, `until_ms` never moves earlier | `Unusable` | stays `Exhausted`, a full window can only move `until_ms` later | `Available` |
//// | `Unusable` | passed over | stays `Unusable` | stays `Unusable`, the first cause is kept | stays `Unusable` | `Available` |

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// Why a member cannot be used until an operator acts.
pub type UnusableCause {
  /// The member has no saved grant.
  SignedOut

  /// The member's grant exists but does not allow spending plan allowance.
  PlanNotGranted
}

/// Where one member stands. A member's standing is the only per-member fact
/// the selection rule reads.
pub type Standing {
  /// The member may be chosen.
  Available

  /// The provider refused the member for exhausted allowance. It returns when
  /// the clock reaches `until_ms`, in milliseconds since the Unix epoch.
  Exhausted(until_ms: Int)

  /// The member cannot be used until it is reinstated.
  Unusable(cause: UnusableCause)
}

/// One window of the provider's own gauge, such as a five-hour or weekly
/// allowance.
///
/// Constructor invariants: `used_percent` is a whole number from 0 to 100,
/// clamped by `window`; `resets_at_ms` is milliseconds since the Unix epoch.
pub type Window {
  Window(used_percent: Int, resets_at_ms: Int)
}

/// Why the provider refused a request that a member served.
pub type Refusal {
  /// The member's allowance is spent. `resets_at_ms` is the provider's stated
  /// reset time when the refusal carried one.
  UsageLimit(resets_at_ms: Option(Int))

  /// The member's credential was refused or could not be produced.
  Unauthorized(cause: UnusableCause)
}

/// An input to the ledger. Every event carries its own time, so a replay of
/// the same events gives the same ledger.
pub type Event {
  /// A request needs a member.
  Pick(now_ms: Int)

  /// A request served by `label` was refused.
  Refused(label: String, now_ms: Int, refusal: Refusal)

  /// A response served by `label` carried a reading of the provider's gauge.
  Observed(label: String, now_ms: Int, windows: List(Window))

  /// An operator repaired `label`, for example by signing in again.
  Reinstated(label: String)
}

/// What a step did, as data for the caller to log, count or act on.
pub type Effect {
  /// `Pick` chose this member.
  Chose(label: String)

  /// `Pick` found no member to choose. `returns_at_ms` is the earliest time
  /// an exhausted member comes back, or `None` when every member is
  /// unusable and only an operator can help.
  NoneAvailable(returns_at_ms: Option(Int))

  /// A member's standing changed.
  Changed(label: String, from: Standing, to: Standing)
}

/// Why `new` refused its arguments.
pub type PoolError {
  /// A pool needs at least one member.
  NoMembers

  /// Two members share this label, so an event could not name one of them.
  DuplicateLabel(label: String)

  /// The hold for a refusal with no reset time must be positive, or an
  /// exhausted member would return the instant it was refused.
  NonPositiveHold(hold_ms: Int)
}

/// One member's row in a display of the pool.
pub type Report {
  Report(
    label: String,
    standing: Standing,
    /// The highest `used_percent` among windows that have not yet reset, or
    /// `None` when no reading is live.
    used_percent: Option(Int),
    /// The earliest reset among live windows, or `None` when no reading is
    /// live.
    resets_at_ms: Option(Int),
  )
}

/// The ledger. Opaque so that a standing changes only through `step`.
pub opaque type Pool {
  /// Invariants: `members` is nonempty and its labels are distinct;
  /// `hold_ms` is positive; configured order is selection order.
  Pool(members: List(Member), hold_ms: Int)
}

type Member {
  Member(label: String, standing: Standing, windows: List(Window))
}

/// Builds a ledger with every member `Available`, in selection order.
/// `unknown_reset_hold_ms` is how long a member rests after a usage-limit
/// refusal that names no reset time.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(_pool) = pool.new(["seat-a", "seat-b"], 600_000)
/// assert pool.new([], 600_000) == Error(pool.NoMembers)
/// assert pool.new(["a", "a"], 600_000) == Error(pool.DuplicateLabel("a"))
/// ```
///
pub fn new(
  labels: List(String),
  unknown_reset_hold_ms: Int,
) -> Result(Pool, PoolError) {
  case labels, unknown_reset_hold_ms > 0 {
    [], _ -> Error(NoMembers)
    _, False -> Error(NonPositiveHold(unknown_reset_hold_ms))
    [_, ..], True ->
      case first_duplicate(labels, []) {
        Some(label) -> Error(DuplicateLabel(label))
        None ->
          Ok(Pool(
            members: list.map(labels, fn(label) {
              Member(label:, standing: Available, windows: [])
            }),
            hold_ms: unknown_reset_hold_ms,
          ))
      }
  }
}

/// Clamps a reading into a `Window`, so a provider that reports a percentage
/// outside 0 to 100 cannot make the ledger's arithmetic lie.
///
/// ## Examples
///
/// ```gleam
/// assert pool.window(120, 5) == pool.Window(100, 5)
/// assert pool.window(-3, 5) == pool.Window(0, 5)
/// ```
///
pub fn window(used_percent: Int, resets_at_ms: Int) -> Window {
  Window(used_percent: int.clamp(used_percent, 0, 100), resets_at_ms:)
}

/// Applies one event and returns the new ledger with what changed.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(ledger) = pool.new(["a", "b"], 600_000)
/// let refusal = pool.Refused("a", 0, pool.UsageLimit(option.Some(9000)))
/// let #(ledger, _) = pool.step(ledger, refusal)
/// let #(_, effects) = pool.step(ledger, pool.Pick(1000))
/// assert effects == [pool.Chose("b")]
/// ```
///
pub fn step(pool: Pool, event: Event) -> #(Pool, List(Effect)) {
  case event {
    Pick(now_ms:) -> pick(pool, now_ms)

    Refused(label:, now_ms:, refusal:) ->
      update(pool, label, fn(member) {
        refuse(member, now_ms, refusal, pool.hold_ms)
      })

    Observed(label:, now_ms:, windows:) ->
      update(pool, label, fn(member) { observe(member, now_ms, windows) })

    Reinstated(label:) ->
      update(pool, label, fn(member) { Member(..member, standing: Available) })
  }
}

/// Projects the ledger for display, in selection order, at `now_ms`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(ledger) = pool.new(["a"], 600_000)
/// let assert [row] = pool.report(ledger, 0)
/// assert row.standing == pool.Available
/// assert row.used_percent == option.None
/// ```
///
pub fn report(pool: Pool, now_ms: Int) -> List(Report) {
  list.map(pool.members, fn(member) {
    let live =
      list.filter(member.windows, fn(window) { window.resets_at_ms > now_ms })

    Report(
      label: member.label,
      standing: member.standing,
      used_percent: list.map(live, fn(window) { window.used_percent })
        |> list.reduce(int.max)
        |> option.from_result,
      resets_at_ms: list.map(live, fn(window) { window.resets_at_ms })
        |> list.reduce(int.min)
        |> option.from_result,
    )
  })
}

/// Returns the first label that appears twice, or `None`.
fn first_duplicate(labels: List(String), seen: List(String)) -> Option(String) {
  case labels {
    [] -> None
    [label, ..rest] ->
      case list.contains(seen, label) {
        True -> Some(label)
        False -> first_duplicate(rest, [label, ..seen])
      }
  }
}

/// Chooses the first available member, after returning expired members.
fn pick(pool: Pool, now_ms: Int) -> #(Pool, List(Effect)) {
  let #(members, returned) = return_expired(pool.members, now_ms)
  let pool = Pool(..pool, members:)

  // A pick never blocks: with nothing to choose it says when to look again.
  case list.find(members, fn(member) { member.standing == Available }) {
    Ok(member) -> #(pool, list.append(returned, [Chose(member.label)]))
    Error(Nil) -> #(
      pool,
      list.append(returned, [NoneAvailable(earliest_return(members))]),
    )
  }
}

/// Returns every `Exhausted` member whose reset time has been reached to
/// `Available`, with one `Changed` effect for each.
fn return_expired(
  members: List(Member),
  now_ms: Int,
) -> #(List(Member), List(Effect)) {
  let stepped =
    list.map(members, fn(member) {
      case member.standing {
        Exhausted(until_ms:) if now_ms >= until_ms -> #(
          Member(..member, standing: Available),
          [Changed(member.label, member.standing, Available)],
        )
        Exhausted(..) | Available | Unusable(..) -> #(member, [])
      }
    })

  #(
    list.map(stepped, fn(pair) { pair.0 }),
    list.flat_map(stepped, fn(p) { p.1 }),
  )
}

/// The earliest `until_ms` among exhausted members, or `None` when none is
/// exhausted.
fn earliest_return(members: List(Member)) -> Option(Int) {
  list.filter_map(members, fn(member) {
    case member.standing {
      Exhausted(until_ms:) -> Ok(until_ms)
      Available | Unusable(..) -> Error(Nil)
    }
  })
  |> list.reduce(int.min)
  |> option.from_result
}

/// Applies `change` to the member named `label`, reporting a `Changed` effect
/// when its standing moved. An unknown label leaves the ledger as it was.
fn update(
  pool: Pool,
  label: String,
  change: fn(Member) -> Member,
) -> #(Pool, List(Effect)) {
  let #(effects, members) =
    list.map_fold(pool.members, [], fn(effects, member) {
      // Only the named member changes; the fold carries effects past the rest.
      case member.label == label {
        False -> #(effects, member)
        True -> {
          let changed = change(member)

          // Only a move between standings is worth reporting; a refreshed
          // gauge reading alone is not.
          case changed.standing == member.standing {
            True -> #(effects, changed)
            False -> #(
              [Changed(label, member.standing, changed.standing), ..effects],
              changed,
            )
          }
        }
      }
    })

  #(Pool(..pool, members:), list.reverse(effects))
}

/// A refusal moves a member to `Exhausted` or `Unusable`. An existing
/// `Unusable` standing is never softened, and an `Exhausted` return time
/// never moves earlier.
fn refuse(
  member: Member,
  now_ms: Int,
  refusal: Refusal,
  hold_ms: Int,
) -> Member {
  // Authorization failures outrank usage limits, because waiting for a reset
  // does not repair a missing grant, and `Unusable` is never softened.
  case member.standing, refusal {
    Unusable(..), _ -> member

    _, Unauthorized(cause:) -> Member(..member, standing: Unusable(cause:))

    standing, UsageLimit(resets_at_ms:) -> {
      let named = option.unwrap(resets_at_ms, 0)

      // A reset at or before now would readmit a member that was just proved
      // unusable, so the hold stands in for it.
      let until_ms = case named > now_ms {
        True -> named
        False -> now_ms + hold_ms
      }

      Member(..member, standing: exhausted_until(standing, until_ms))
    }
  }
}

/// The later of an existing return time and a new one.
fn exhausted_until(standing: Standing, until_ms: Int) -> Standing {
  case standing {
    Exhausted(until_ms: current) ->
      Exhausted(until_ms: int.max(current, until_ms))
    Available | Unusable(..) -> Exhausted(until_ms:)
  }
}

/// Records a gauge reading. A window that reads full and has not reset moves
/// an available or exhausted member to `Exhausted` until the last such
/// window resets.
fn observe(member: Member, now_ms: Int, windows: List(Window)) -> Member {
  let full =
    list.filter(windows, fn(window) {
      window.used_percent >= 100 && window.resets_at_ms > now_ms
    })
  let recorded = Member(..member, windows:)

  // A reading can only close a member, never open one: reopening is the
  // reset time passing, which `Pick` observes, or an operator.
  case member.standing, list.map(full, fn(window) { window.resets_at_ms }) {
    Unusable(..), _ -> recorded
    _, [] -> recorded
    standing, resets -> {
      let until_ms = list.fold(resets, 0, int.max)

      Member(..recorded, standing: exhausted_until(standing, until_ms))
    }
  }
}
