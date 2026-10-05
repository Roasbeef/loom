//// The admin page's vocabulary (protocol-change/065, the fifth pull request):
//// the fixed words for every refusal and for each change that is made, so
//// nothing the daemon or a peer wrote can reach a browser through them.

import gleam/list
import gleam/string
import web_view/grants
import web_view/invites

fn every_reason() -> List(grants.Reason) {
  [
    grants.NotOwner,
    grants.TooMany(used: 3, free_at_ms: 1_790_030_460_000),
    grants.NotIsolated,
    grants.NotFound,
    grants.InvalidName,
    grants.Unavailable,
  ]
}

// Each reason has its own sentence, ending in a full stop, and none is built from
// a value: the same reason is the same words every time.
pub fn every_reason_has_its_own_fixed_words_test() {
  let words = list.map(every_reason(), grants.reason_words)
  assert list.length(list.unique(words)) == list.length(words)
  list.each(words, fn(sentence) {
    assert string.ends_with(sentence, ".")
    assert sentence != ""
  })
  assert grants.reason_words(grants.NotOwner)
    == "Only the owner can administer from a page."
}

// The shared words are the session page's own: a session that is not shared is
// refused in the words the invitation control uses, so the owner hears one
// instruction wherever they meet it.
pub fn the_isolation_words_are_the_invitation_controls_test() {
  assert grants.reason_words(grants.NotIsolated)
    == invites.reason_words(invites.NotIsolated)
}

// Every change that makes no claim has words, and the two that make one say
// nothing here because their display is the claim's.
pub fn each_change_that_is_made_is_worded_test() {
  assert grants.changed_words(grants.SetRole("s", "p", invites.Operator))
    == "Role changed."
  assert grants.changed_words(grants.RevokeMembership("s", "p"))
    == "Membership removed."
  assert grants.changed_words(grants.RevokeCredentials("p"))
    == "Credentials revoked."
  assert grants.changed_words(grants.Rotate("p")) == "Done."
  assert grants.changed_words(grants.Invite("s", invites.Observer, ""))
    == "Done."
}

// The refusal of a spent allowance names how many grants were made and when the
// next is free, in UTC, to the minute, and it changes with both. The page draws
// the instant as an element the browser words in its own zone; these are the
// words that fill it, its title and the refusal in a button's tooltip.
pub fn the_allowance_refusal_names_the_count_and_the_reset_time_test() {
  let words =
    grants.reason_words(grants.TooMany(used: 3, free_at_ms: 1_790_030_460_000))
  assert string.contains(words, "3 grants in the last hour")
  assert string.contains(words, "free at 22:41 UTC")
  let later =
    grants.reason_words(grants.TooMany(
      used: 3,
      free_at_ms: 1_790_030_460_000 + 3_600_000,
    ))
  assert string.contains(later, "free at 23:41 UTC")

  // A time inside a minute rounds up, so it is never shown before it comes.
  assert string.contains(
    grants.reason_words(grants.TooMany(
      used: 3,
      free_at_ms: 1_790_030_460_000 + 1,
    )),
    "free at 22:42 UTC",
  )
  assert string.contains(
    grants.reason_words(grants.TooMany(
      used: 3,
      free_at_ms: 1_790_030_460_000 - 1,
    )),
    "free at 22:41 UTC",
  )

  // Midnight pads both fields, and a time before the epoch is the epoch.
  assert string.contains(
    grants.reason_words(grants.TooMany(
      used: 3,
      free_at_ms: 86_400_000 + 300_000,
    )),
    "free at 00:05 UTC",
  )
  assert string.contains(
    grants.reason_words(grants.TooMany(used: 3, free_at_ms: -5)),
    "free at 00:00 UTC",
  )
}

// A long identity is shortened to its prefix and eight characters, and a short
// one is left alone.
pub fn an_identity_is_shortened_to_eight_characters_after_its_prefix_test() {
  assert grants.short_identity(
      "owner-2056528fe1be0db0f7105a24da3aac4dcf722898c6655129c0eabc6231181a05",
    )
    == "owner-2056528f"
  assert grants.short_identity("guest-956fb176") == "guest-956fb176"
  assert grants.short_identity("bob") == "bob"
  assert grants.short_identity("0123456789abcdef") == "01234567"
}

// The words in two halves are the whole refusal with the UTC time between them,
// so a page that puts the browser's time there says the same sentence.
pub fn the_halves_of_the_refusal_join_around_the_time_test() {
  let reason = grants.TooMany(used: 3, free_at_ms: 1_790_030_460_000)
  assert grants.throttle_lead(3)
    <> grants.utc_clock(1_790_030_460_000)
    <> grants.throttle_tail
    == grants.reason_words(reason)
  assert grants.utc_clock(1_790_030_460_000) == "22:41 UTC"
}
