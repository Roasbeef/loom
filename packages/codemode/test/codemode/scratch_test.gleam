//// The scratch-root choice the real-helper suites share, tested without an
//// environment or a filesystem.
////
//// Two properties are load-bearing and neither is visible from a passing
//// end-to-end run: a root must be unique to the checkout that chose it, or
//// one checkout's rig deletes another's live state mid-execution; and a
//// socket path under that root must stay inside the kernel's `sun_path`
//// limit, or `bind` fails with an error that names nothing useful.

import gleam/string
import support/scratch

// Two checkouts of the same repository differ only in their directory, so
// that is the whole of what the digest has to separate.
const checkout_a = "/Users/dev/src/loom"

const checkout_b = "/Users/dev/src/loom-second"

pub fn distinct_checkouts_get_distinct_roots_test() {
  let a =
    scratch.base_for(
      configured: Error(Nil),
      home: Ok("/Users/dev"),
      checkout: checkout_a,
    )
  let b =
    scratch.base_for(
      configured: Error(Nil),
      home: Ok("/Users/dev"),
      checkout: checkout_b,
    )

  assert a != b
}

pub fn the_same_checkout_gets_a_stable_root_test() {
  let once =
    scratch.base_for(
      configured: Error(Nil),
      home: Ok("/Users/dev"),
      checkout: checkout_a,
    )
  let again =
    scratch.base_for(
      configured: Error(Nil),
      home: Ok("/Users/dev"),
      checkout: checkout_a,
    )

  assert once == again
}

// An explicitly configured scratch root is taken verbatim: whoever set the
// variable accepted responsibility for its length and its uniqueness, and a
// digest appended behind their back would break the one case where a
// caller needs to know the exact path.
pub fn a_configured_root_is_taken_verbatim_test() {
  assert scratch.base_for(
      configured: Ok("/short"),
      home: Ok("/Users/dev"),
      checkout: checkout_a,
    )
    == "/short"
}

// With no HOME either, the root stays inside the checkout, where the
// launcher's own guard is what reports a checkout too deep for a socket.
pub fn without_home_the_root_stays_in_tree_test() {
  assert scratch.base_for(
      configured: Error(Nil),
      home: Error(Nil),
      checkout: checkout_a,
    )
    == checkout_a <> "/build/e2e-codemode"
}

// The digest is what keeps the path short, so the check is on the whole
// socket-bearing path the rig builds: the base, the per-test directory, and
// the cap socket under it.
pub fn a_socket_path_under_the_root_fits_the_bound_test() {
  let base =
    scratch.base_for(
      configured: Error(Nil),
      home: Ok("/Users/dev"),
      checkout: checkout_a,
    )
  let socket = base <> "/e2e-happy/cap/cap.sock"

  assert string.byte_size(socket) <= scratch.socket_path_budget
}

// The tag has to be short as well as distinguishing, because it is the one
// component the checkout path contributes to the length.
pub fn the_tag_is_bounded_and_distinguishing_test() {
  assert string.length(scratch.tag(checkout_a)) == scratch.tag_length
  assert scratch.tag(checkout_a) != scratch.tag(checkout_b)
}
