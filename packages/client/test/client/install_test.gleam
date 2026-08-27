//// The installation anchor, and the two ladders built on it.
////
//// The interesting property here is **order**, and order is exactly what
//// a lookup against the host running the test cannot show: on this
//// machine `gleam` is on `PATH` and there is no release tree, so every
//// ladder would answer the same way whichever rung it consulted first.
//// So the ladders take their rungs as arguments and the tests supply
//// them, which is why `serve.helper_ladder` and `codemode.locate` are
//// shaped the way they are rather than reaching for `PATH` inline.
////
//// What is asserted against the real host is the anchor itself:
//// `code:root_dir()` answers on a development machine too, and the
//// `erts-<vsn>/bin/erl` under it is the emulator running these tests.
//// That is the claim the whole design rests on — that the anchor is not
//// a release-only trick — and it is checkable here.

import client/codemode
import client/install
import client/serve
import gleam/option.{None, Some}
import gleam/string
import simplifile

// --- the anchor ------------------------------------------------------------

pub fn the_root_is_an_absolute_directory_test() {
  // `gleam test` is not a release, so this is the second row of the
  // table in the module doc: the OTP installation the emulator came
  // from. It still has to be absolute and still has to exist, because
  // every path in the module is built by concatenating onto it.
  let root = install.root()
  assert string.starts_with(root, "/")
  assert simplifile.is_directory(root) == Ok(True)
}

pub fn the_root_does_not_move_with_the_working_directory_test() {
  // The whole reason for preferring `code:root_dir()` over anything
  // derived from argv or from `.`: it is resolved by the emulator at
  // boot and is a constant for the life of the node.
  assert install.root() == install.root()
}

pub fn the_bundled_erl_is_the_emulator_running_this_test_test() {
  // The rung that makes #102 nearly free. A release carries
  // `erts-<vsn>/bin/erl` and so does every ordinary OTP installation, so
  // this rung answers on both — which is what lets `discover` prefer it
  // unconditionally instead of special-casing releases.
  let path = install.erl()
  assert string.contains(path, "/erts-")
  assert string.ends_with(path, "/bin/erl")
  assert install.existing_file(path) == Ok(path)
}

pub fn every_in_tree_path_hangs_off_the_one_root_test() {
  // This is the seam between `scripts/release.sh`, which *writes* the
  // layout, and this module, which *reads* it. Nothing else pins the two
  // together: a release that put `gleam` somewhere else would still build
  // and still boot, and would simply drop code mode again with a message
  // naming a path nothing had written to. So the layout is asserted here
  // rather than left to agree by habit.
  let root = install.root()
  assert install.helper() == root <> "/bin/" <> install.helper_name
  assert install.gleam_compiler() == root <> "/bin/gleam"
  assert install.seed() == root <> "/" <> install.seed_directory
  assert install.seed_directory == "share/codemode-seed"
  assert string.starts_with(install.erl(), root <> "/erts-")
}

pub fn existence_is_the_discriminator_test() {
  assert install.existing_file("/bin/sh") == Ok("/bin/sh")
  assert install.existing_file("/no/such/binary") == Error(Nil)
  // A directory is not a file and a file is not a directory; the helper
  // ladder and the seed ladder ask different questions on purpose.
  assert install.existing_file("/tmp") == Error(Nil)
  assert install.existing_directory("/tmp") == Ok("/tmp")
  assert install.existing_directory("/bin/sh") == Error(Nil)
}

// --- the ladder, as an order ----------------------------------------------

pub fn the_first_rung_that_answers_wins_test() {
  assert install.first_of([fn() { Ok("a") }, fn() { Ok("b") }]) == Ok("a")
  assert install.first_of([fn() { Error(Nil) }, fn() { Ok("b") }]) == Ok("b")
  assert install.first_of([]) == Error(Nil)
}

pub fn a_rung_below_the_answer_is_never_run_test() {
  // Every rung stats the filesystem, so a ladder that evaluated its
  // lower rungs eagerly would pay for answers it already has — and, for
  // the helper, would stat a path the operator explicitly overrode.
  let exploded = fn() { panic as "a rung below the answer was evaluated" }
  assert install.first_of([fn() { Ok("a") }, exploded]) == Ok("a")
}

// --- the helper ladder (#101) ---------------------------------------------

pub fn an_explicit_helper_outranks_everything_test() {
  // The flag is how an operator points at a helper they audited
  // themselves, and it must keep winning over a shipped one — which is
  // the ordering the release smoke checks from outside by refusing to
  // boot on `--helper /nonexistent/loom-exec`.
  let chosen =
    serve.helper_ladder(
      Some("/audited/loom-exec"),
      beside: fn() { Ok("/release/bin/loom-exec") },
      on_path: fn() { Ok("/usr/bin/loom-exec") },
      in_bin: fn() { Ok("./bin/loom-exec") },
    )
  assert chosen == Ok("/audited/loom-exec")
}

pub fn the_helper_beside_the_server_outranks_path_test() {
  // #101's actual complaint: `loom-exec` is what applies Landlock and
  // seccomp, so a stray one an unrelated install left on PATH must not
  // be found ahead of the one shipped in this server's own tree.
  let chosen =
    serve.helper_ladder(
      None,
      beside: fn() { Ok("/release/bin/loom-exec") },
      on_path: fn() { Ok("/usr/bin/loom-exec") },
      in_bin: fn() { Ok("./bin/loom-exec") },
    )
  assert chosen == Ok("/release/bin/loom-exec")
}

pub fn path_still_outranks_the_repos_bin_test() {
  // The lowest rung is a checkout convenience — where `make binaries`
  // writes — and stays last, now unreachable from a release.
  let chosen =
    serve.helper_ladder(
      None,
      beside: fn() { Error(Nil) },
      on_path: fn() { Ok("/usr/bin/loom-exec") },
      in_bin: fn() { Ok("./bin/loom-exec") },
    )
  assert chosen == Ok("/usr/bin/loom-exec")
}

pub fn a_release_with_no_path_still_finds_its_helper_test() {
  // The constructed case the bug is about: PATH answers nothing, and the
  // file is sitting beside the server. Before the fix this was
  // `Error(Nil)` and the launcher had to inject `--helper`.
  let chosen =
    serve.helper_ladder(
      None,
      beside: fn() { Ok("/release/bin/loom-exec") },
      on_path: fn() { Error(Nil) },
      in_bin: fn() { Error(Nil) },
    )
  assert chosen == Ok("/release/bin/loom-exec")
}

pub fn nothing_anywhere_is_an_error_not_a_guess_test() {
  let chosen =
    serve.helper_ladder(
      None,
      beside: fn() { Error(Nil) },
      on_path: fn() { Error(Nil) },
      in_bin: fn() { Error(Nil) },
    )
  assert chosen == Error(Nil)
}

// --- the toolchain ladder (#102) ------------------------------------------

pub fn a_bundled_executable_outranks_path_test() {
  // Both rungs answer, and they answer differently: `sh` resolves on
  // PATH, and `beside` names the emulator running this test. So which
  // path comes back identifies which rung was consulted first, on any
  // host, rather than only on one where the two happen to differ. The
  // pairing is deliberately mismatched for exactly that reason — a name
  // PATH cannot answer for would let a reversed ladder pass, which is
  // how the first version of this test failed to catch the mutation.
  let assert Ok(found) =
    codemode.locate("sh", beside: install.erl(), remedy: "x")
    as "a bundled executable must be found"
  assert found == install.erl()
}

pub fn the_bundled_erl_outranks_the_one_on_path_test() {
  // The same order, stated as the production case it exists for. This is
  // not merely a release fallback: a satellite loads `.beam` files the
  // hermetic build has just produced, the running emulator is by
  // construction the one whose OTP that build resolved against, and the
  // first `erl` on PATH is whichever installation a shell profile points
  // at — a coin flip on a host with two OTPs.
  let assert Ok(found) =
    codemode.locate("erl", beside: install.erl(), remedy: "x")
    as "the bundled erl must be found"
  assert found == install.erl()
}

pub fn a_bundled_executable_answers_when_path_cannot_test() {
  // The release's own case: nothing of the sort on PATH, the file
  // sitting in the tree. Before the fix this was the whole of #102's
  // discovery failure — for `erl`, which the tarball had carried all
  // along.
  let assert Ok(found) =
    codemode.locate("loom-no-such-compiler", beside: "/bin/sh", remedy: "x")
    as "a bundled executable must be found with nothing on PATH"
  assert found == "/bin/sh"
}

pub fn path_answers_when_nothing_is_bundled_test() {
  // The development host, unchanged: no release tree, so the ladder
  // falls through and finds what it always found.
  let assert Ok(found) =
    codemode.locate("sh", beside: "/no/such/release/bin/sh", remedy: "unused")
    as "PATH must still answer"
  assert string.ends_with(found, "/sh")
  assert found != "/no/such/release/bin/sh"
}

pub fn a_missing_executable_names_both_places_and_the_way_out_test() {
  // The message is the only thing anybody ever sees about an absent code
  // mode — there is no tool to fail later — so it has to carry what is
  // missing, where it was looked for, and how to supply it.
  let assert Error(reason) =
    codemode.locate(
      "loom-no-such-compiler",
      beside: "/opt/loom/bin/loom-no-such-compiler",
      remedy: "put it on PATH",
    )
    as "an absent executable must refuse"
  assert string.contains(reason, "loom-no-such-compiler")
  assert string.contains(reason, "/opt/loom/bin/loom-no-such-compiler")
  assert string.contains(reason, "PATH")
  assert string.contains(reason, "put it on PATH")
  assert string.contains(reason, "No code_mode tool is registered.")
}

// --- the seed ladder (#102) -----------------------------------------------

pub fn an_explicit_seed_outranks_both_test() {
  let chosen =
    serve.seed_ladder(
      Some("/audited/seed"),
      in_workspace: fn() { Ok("/ws/build/codemode-seed") },
      bundled: fn() { Ok("/release/share/codemode-seed") },
      otherwise: "/ws/build/codemode-seed",
    )
  assert chosen == "/audited/seed"
}

pub fn the_workspaces_own_seed_outranks_the_bundled_one_test() {
  // A contributor's `make codemode-seed` output is regenerated against
  // the tree being worked on; a bundled one is frozen at release time.
  // So the workspace goes first, or a checkout that changed the compile
  // service's dependency table would be handed a seed `seed.verify` then
  // rejects — a confusing way to be told to rebuild your own.
  let chosen =
    serve.seed_ladder(
      None,
      in_workspace: fn() { Ok("/ws/build/codemode-seed") },
      bundled: fn() { Ok("/release/share/codemode-seed") },
      otherwise: "/ws/build/codemode-seed",
    )
  assert chosen == "/ws/build/codemode-seed"
}

pub fn a_release_falls_through_to_the_bundled_seed_test() {
  // The release case: no workspace seed, and the tarball's own is found.
  // This is the rung `make release-smoke` exercises for real.
  let chosen =
    serve.seed_ladder(
      None,
      in_workspace: fn() { Error(Nil) },
      bundled: fn() { Ok("/release/share/codemode-seed") },
      otherwise: "/ws/build/codemode-seed",
    )
  assert chosen == "/release/share/codemode-seed"
}

pub fn with_no_seed_anywhere_the_workspace_path_is_still_named_test() {
  // Not a fallback so much as a choice about the refusal: naming the
  // workspace path tells a person where they can actually put a seed,
  // whereas naming a directory inside a release they may not have does
  // not.
  let chosen =
    serve.seed_ladder(
      None,
      in_workspace: fn() { Error(Nil) },
      bundled: fn() { Error(Nil) },
      otherwise: "/ws/build/codemode-seed",
    )
  assert chosen == "/ws/build/codemode-seed"
}
