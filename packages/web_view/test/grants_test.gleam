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
    grants.TooMany,
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
