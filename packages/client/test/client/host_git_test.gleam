//// Git resolution is a pure decision over injected host probes, so each case
//// here runs on any host. The `xcrun` probe records that it ran, because the
//// point of the Darwin branch is that `xcrun` runs only for the shim.

import client/host_git
import gleam/erlang/process

const toolchain_git = "/Applications/Xcode.app/Contents/Developer/usr/bin/git"

pub fn darwin_shim_uses_the_xcrun_answer_test() {
  let #(probes, asked) =
    probes(host_git.Darwin, Ok(host_git.xcode_shim), Ok(toolchain_git))
  assert host_git.resolve(probes) == Ok(toolchain_git)
  assert process.receive(asked, 0) == Ok(Nil)
}

// A failed or missing `xcrun` must not leave the call with no executable: the
// shim path is what the call named before resolution existed.
pub fn darwin_shim_keeps_the_shim_when_xcrun_fails_test() {
  let #(probes, asked) =
    probes(host_git.Darwin, Ok(host_git.xcode_shim), Error(Nil))
  assert host_git.resolve(probes) == Ok(host_git.xcode_shim)
  assert process.receive(asked, 0) == Ok(Nil)
}

// A Git outside `/usr/bin` is a real binary, such as Homebrew's. Replacing it
// with the Xcode toolchain's copy would change which Git the operator chose.
pub fn darwin_non_shim_git_is_used_as_found_test() {
  let #(probes, asked) =
    probes(host_git.Darwin, Ok("/opt/homebrew/bin/git"), Ok(toolchain_git))
  assert host_git.resolve(probes) == Ok("/opt/homebrew/bin/git")
  assert process.receive(asked, 0) == Error(Nil)
}

pub fn other_platforms_are_unchanged_test() {
  let #(probes, asked) =
    probes(host_git.OtherPlatform, Ok("/usr/bin/git"), Ok(toolchain_git))
  assert host_git.resolve(probes) == Ok("/usr/bin/git")
  assert process.receive(asked, 0) == Error(Nil)
}

pub fn a_missing_git_stays_missing_test() {
  let #(probes, asked) =
    probes(host_git.Darwin, Error("git not found"), Ok(toolchain_git))
  assert host_git.resolve(probes) == Error("git not found")
  assert process.receive(asked, 0) == Error(Nil)
}

pub fn subprocess_lookup_uses_the_resolved_git_directory_test() {
  assert host_git.tool_path("/usr/bin:/bin", toolchain_git)
    == "/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin"
  assert host_git.tool_path(
      "/opt/homebrew/bin:/usr/bin",
      "/opt/homebrew/bin/git",
    )
    == "/opt/homebrew/bin:/usr/bin"
  assert host_git.tool_path("/usr/bin:/bin", "git") == "/usr/bin:/bin"
  assert host_git.tool_path("/usr/bin:/bin", host_git.xcode_shim)
    == "/usr/bin:/bin"
}

fn probes(
  platform: host_git.Platform,
  found: Result(String, String),
  answer: Result(String, Nil),
) -> #(host_git.Probes, process.Subject(Nil)) {
  let asked = process.new_subject()
  #(
    host_git.Probes(platform:, find: fn(_) { found }, xcrun: fn() {
      process.send(asked, Nil)
      answer
    }),
    asked,
  )
}
