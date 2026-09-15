//// Build identity is read from the environment and compared for equality.
////
//// The interesting property is the default: a process that set no identity
//// variables must report `dev`/`unknown` rather than a version it invented,
//// because every release comparison is against whatever `current()` returns
//// and a fabricated default would make a checkout look like a release.

import envoy
import gleam/option.{None, Some}
import host/build_identity

pub fn current_reads_the_exported_identity_test() {
  envoy.set(build_identity.version_variable, "0.3.0")
  envoy.set(build_identity.commit_variable, "deadbeef")
  assert build_identity.current()
    == build_identity.Identity("0.3.0", "deadbeef")
  envoy.unset(build_identity.version_variable)
  envoy.unset(build_identity.commit_variable)
}

pub fn current_defaults_when_nothing_is_exported_test() {
  envoy.unset(build_identity.version_variable)
  envoy.unset(build_identity.commit_variable)
  assert build_identity.current()
    == build_identity.Identity(
      build_identity.development_version,
      build_identity.unknown_commit,
    )
}

pub fn an_empty_export_is_treated_as_absent_test() {
  // `LOOM_BUILD_VERSION=` exports an empty string rather than nothing, and an
  // empty version is not one a build may claim, so it reads as the default.
  envoy.set(build_identity.version_variable, "")
  envoy.set(build_identity.commit_variable, "")
  assert build_identity.current()
    == build_identity.Identity(
      build_identity.development_version,
      build_identity.unknown_commit,
    )
  envoy.unset(build_identity.version_variable)
  envoy.unset(build_identity.commit_variable)
}

pub fn matches_is_equality_of_both_halves_test() {
  let a = build_identity.Identity("0.1.0", "aaaa")
  assert build_identity.matches(a, build_identity.Identity("0.1.0", "aaaa"))
  assert !build_identity.matches(a, build_identity.Identity("0.2.0", "aaaa"))
  assert !build_identity.matches(a, build_identity.Identity("0.1.0", "bbbb"))
}

pub fn describe_names_both_halves_test() {
  assert build_identity.describe(build_identity.Identity("0.1.0", "4c266dde"))
    == "0.1.0 (4c266dde)"
}

pub fn from_fields_refuses_a_half_identity_test() {
  assert build_identity.from_fields("0.1.0", "4c266dde")
    == Some(build_identity.Identity("0.1.0", "4c266dde"))
  assert build_identity.from_fields("", "4c266dde") == None
  assert build_identity.from_fields("0.1.0", "") == None
  assert build_identity.from_fields("", "") == None
}
