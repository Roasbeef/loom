//// The account pool's standing ledger, one transition at a time.
////
//// Every test drives `pool.step` with explicit times, so none depends on a
//// clock. The fixtures use round millisecond values; the hold for a refusal
//// that names no reset is ten units, and a pick at `t` follows a refusal at
//// `t0` by whatever the test is about.

import gleam/option.{None, Some}
import provider/pool.{
  type Pool, Available, Changed, Chose, Exhausted, NoneAvailable, Observed, Pick,
  PlanNotGranted, Refused, Reinstated, SignedOut, Unauthorized, Unusable,
  UsageLimit,
}

// --- fixtures ---------------------------------------------------------------

const hold = 10

fn ledger() -> Pool {
  let assert Ok(made) = pool.new(["a", "b", "c"], hold)
  made
}

fn apply(ledger: Pool, events: List(pool.Event)) -> Pool {
  case events {
    [] -> ledger
    [event, ..rest] -> apply(pool.step(ledger, event).0, rest)
  }
}

fn chosen(ledger: Pool, now_ms: Int) -> List(pool.Effect) {
  pool.step(ledger, Pick(now_ms)).1
}

fn limit(label: String, now_ms: Int, resets_at_ms: Int) -> pool.Event {
  Refused(label, now_ms, UsageLimit(Some(resets_at_ms)))
}

fn standing_of(ledger: Pool, label: String) -> pool.Standing {
  let assert Ok(row) =
    pool.report(ledger, 0)
    |> list_find(label)
  row.standing
}

fn list_find(
  rows: List(pool.Report),
  label: String,
) -> Result(pool.Report, Nil) {
  case rows {
    [] -> Error(Nil)
    [row, ..] if row.label == label -> Ok(row)
    [_, ..rest] -> list_find(rest, label)
  }
}

// --- construction -----------------------------------------------------------

pub fn a_pool_needs_members_distinct_labels_and_a_positive_hold_test() {
  assert pool.new([], hold) == Error(pool.NoMembers)
  assert pool.new(["a", "b", "a"], hold) == Error(pool.DuplicateLabel("a"))
  assert pool.new(["a"], 0) == Error(pool.NonPositiveHold(0))
}

pub fn a_window_clamps_the_percentage_the_provider_reports_test() {
  assert pool.window(250, 7) == pool.Window(100, 7)
  assert pool.window(-1, 7) == pool.Window(0, 7)
  assert pool.window(40, 7) == pool.Window(40, 7)
}

// --- selection --------------------------------------------------------------

pub fn the_first_available_member_in_configured_order_is_chosen_test() {
  assert chosen(ledger(), 0) == [Chose("a")]
}

pub fn a_refused_member_is_passed_over_until_its_named_reset_test() {
  let refused = apply(ledger(), [limit("a", 0, 100)])

  assert chosen(refused, 99) == [Chose("b")]
}

pub fn the_member_returns_at_its_reset_and_takes_priority_again_test() {
  let refused = apply(ledger(), [limit("a", 0, 100)])
  let #(_, effects) = pool.step(refused, Pick(100))

  // The return is reported before the choice, and the head of the order wins
  // again: rotation is a response to refusal, not a rotation for its own sake.
  assert effects == [Changed("a", Exhausted(100), Available), Chose("a")]
}

pub fn a_refusal_without_a_reset_rests_for_the_hold_test() {
  let refused = apply(ledger(), [Refused("a", 5, UsageLimit(None))])

  assert chosen(refused, 14) == [Chose("b")]
  assert pool.step(refused, Pick(15)).1
    == [Changed("a", Exhausted(15), Available), Chose("a")]
}

pub fn a_stated_reset_already_past_is_replaced_by_the_hold_test() {
  // A reset time at or before now would let the member straight back in, and
  // the refusal just proved it is not usable.
  let refused = apply(ledger(), [limit("a", 50, 40)])

  assert standing_of(refused, "a") == Exhausted(60)
}

pub fn nothing_available_reports_the_earliest_return_test() {
  let spent =
    apply(ledger(), [limit("a", 0, 300), limit("b", 0, 200), limit("c", 0, 400)])

  assert chosen(spent, 10) == [NoneAvailable(Some(200))]
}

pub fn nothing_available_with_every_member_unusable_names_no_return_test() {
  let gone =
    apply(ledger(), [
      Refused("a", 0, Unauthorized(SignedOut)),
      Refused("b", 0, Unauthorized(PlanNotGranted)),
      Refused("c", 0, Unauthorized(SignedOut)),
    ])

  assert chosen(gone, 10) == [NoneAvailable(None)]
}

pub fn one_available_member_keeps_the_pool_working_while_others_are_spent_test() {
  let spent = apply(ledger(), [limit("a", 0, 900), limit("b", 0, 900)])

  assert chosen(spent, 10) == [Chose("c")]
}

// --- refusals ---------------------------------------------------------------

pub fn a_later_refusal_never_moves_the_return_earlier_test() {
  let refused = apply(ledger(), [limit("a", 0, 500), limit("a", 10, 200)])

  assert standing_of(refused, "a") == Exhausted(500)
}

pub fn a_later_refusal_can_move_the_return_later_test() {
  let refused = apply(ledger(), [limit("a", 0, 200), limit("a", 10, 500)])

  assert standing_of(refused, "a") == Exhausted(500)
}

pub fn an_authorization_refusal_makes_a_member_unusable_test() {
  let refused = apply(ledger(), [Refused("a", 0, Unauthorized(SignedOut))])

  assert standing_of(refused, "a") == Unusable(SignedOut)
  assert chosen(refused, 1_000_000) == [Chose("b")]
}

pub fn an_unusable_member_is_not_softened_by_a_usage_limit_refusal_test() {
  let refused =
    apply(ledger(), [
      Refused("a", 0, Unauthorized(SignedOut)),
      limit("a", 1, 50),
      Refused("a", 2, Unauthorized(PlanNotGranted)),
    ])

  assert standing_of(refused, "a") == Unusable(SignedOut)
}

pub fn an_exhausted_member_can_become_unusable_test() {
  let refused =
    apply(ledger(), [
      limit("a", 0, 500),
      Refused("a", 1, Unauthorized(PlanNotGranted)),
    ])

  assert standing_of(refused, "a") == Unusable(PlanNotGranted)
}

pub fn reinstating_returns_an_unusable_or_exhausted_member_test() {
  let refused =
    apply(ledger(), [
      Refused("a", 0, Unauthorized(SignedOut)),
      limit("b", 0, 900),
      Reinstated("a"),
      Reinstated("b"),
    ])

  assert standing_of(refused, "a") == Available
  assert standing_of(refused, "b") == Available
}

pub fn an_unknown_label_changes_nothing_test() {
  let #(unchanged, effects) =
    pool.step(ledger(), Refused("nobody", 0, UsageLimit(None)))

  assert effects == []
  assert chosen(unchanged, 0) == [Chose("a")]
}

pub fn a_refusal_reports_the_change_it_made_test() {
  let #(_, effects) = pool.step(ledger(), limit("a", 0, 100))

  assert effects == [Changed("a", Available, Exhausted(100))]
}

// --- the provider's gauge ---------------------------------------------------

pub fn a_full_window_closes_a_member_before_the_provider_refuses_it_test() {
  let seen =
    apply(ledger(), [
      Observed("a", 0, [pool.window(100, 300), pool.window(40, 900)]),
    ])

  assert standing_of(seen, "a") == Exhausted(300)
  assert chosen(seen, 10) == [Chose("b")]
}

pub fn the_member_stays_closed_until_every_full_window_resets_test() {
  let seen =
    apply(ledger(), [
      Observed("a", 0, [pool.window(100, 300), pool.window(100, 900)]),
    ])

  assert standing_of(seen, "a") == Exhausted(900)
}

pub fn a_window_that_is_not_full_never_reopens_an_exhausted_member_test() {
  let seen =
    apply(ledger(), [
      limit("a", 0, 500),
      Observed("a", 10, [pool.window(20, 800)]),
    ])

  // A response that raced the refusal, or a gauge reading from another
  // window, must not outvote the provider's refusal.
  assert standing_of(seen, "a") == Exhausted(500)
}

pub fn a_full_window_that_has_already_reset_is_ignored_test() {
  let seen = apply(ledger(), [Observed("a", 400, [pool.window(100, 300)])])

  assert standing_of(seen, "a") == Available
}

pub fn a_reading_does_not_soften_an_unusable_member_test() {
  let seen =
    apply(ledger(), [
      Refused("a", 0, Unauthorized(SignedOut)),
      Observed("a", 1, [pool.window(100, 300)]),
    ])

  assert standing_of(seen, "a") == Unusable(SignedOut)
}

// --- report -----------------------------------------------------------------

pub fn the_report_shows_the_live_reading_and_hides_a_reset_one_test() {
  let seen =
    apply(ledger(), [
      Observed("a", 0, [pool.window(30, 300), pool.window(70, 900)]),
    ])

  let assert Ok(live) = list_find(pool.report(seen, 100), "a")
  assert live.used_percent == Some(70)
  assert live.resets_at_ms == Some(300)

  // After the first window resets only the second remains, and after both
  // reset the reading says nothing rather than something stale.
  let assert Ok(partial) = list_find(pool.report(seen, 300), "a")
  assert partial.used_percent == Some(70)
  assert partial.resets_at_ms == Some(900)

  let assert Ok(stale) = list_find(pool.report(seen, 900), "a")
  assert stale.used_percent == None
  assert stale.resets_at_ms == None
}

pub fn the_report_lists_members_in_selection_order_test() {
  let labels =
    pool.report(ledger(), 0)
    |> map_label
  assert labels == ["a", "b", "c"]
}

fn map_label(rows: List(pool.Report)) -> List(String) {
  case rows {
    [] -> []
    [row, ..rest] -> [row.label, ..map_label(rest)]
  }
}
