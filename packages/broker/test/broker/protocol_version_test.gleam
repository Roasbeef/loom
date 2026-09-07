//// The two ends of the exec channel are written in different languages
//// and compiled by different toolchains, so nothing in either build can
//// notice that their version constants have drifted apart. This module
//// is that notice: it reads the Go helper's `framing.go` as text and
//// compares the literals it declares against the ones `broker/framing`
//// declares.
////
//// A test that merely pinned `3` on both sides would pass a commit that
//// bumped one and forgot the other, which is exactly the mistake this
//// exists to catch — `protocol-change/006` added a required key to
//// `exec_exit` and moved no version at all, and issue #61 is what that
//// cost. Reading the other language's source is the only check that
//// fails on the forgetting rather than on the remembering.
////
//// The extraction is deliberately a `Result` over a small pure function
//// rather than a regex or a Go parser: the shape it looks for is one
//// line of the form `const Name = <int>`, and if the Go file ever stops
//// having that shape the test says so by name instead of quietly
//// finding nothing to compare.

import broker/framing
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

// Where the Go helper's constants live, relative to this package's
// directory (the test runner's working directory, see `scripts/test.sh`).
const go_framing_path = "../sandbox/internal/framing/framing.go"

pub fn go_and_gleam_envelope_versions_agree_test() {
  let source = read_go_framing()
  let assert Ok(go_value) = constant_in(source, "EnvelopeVersion")
    as "framing.go must declare EnvelopeVersion as an integer constant"
  assert go_value == framing.envelope_version
}

pub fn go_and_gleam_exec_protocol_versions_agree_test() {
  let source = read_go_framing()
  let assert Ok(go_value) = constant_in(source, "ExecProtocolVersion")
    as "framing.go must declare ExecProtocolVersion as an integer constant"
  assert go_value == framing.exec_protocol_version
}

pub fn a_missing_constant_is_named_rather_than_ignored_test() {
  let assert Error(reason) =
    constant_in("package framing\n", "ExecProtocolVersion")
    as "an absent constant must not read as agreement"
  assert string.contains(reason, "ExecProtocolVersion")
}

pub fn a_non_integer_constant_is_refused_test() {
  let source = "const ExecProtocolVersion = iota\n"
  let assert Error(reason) = constant_in(source, "ExecProtocolVersion")
    as "a constant that is not a literal integer must not read as agreement"
  assert string.contains(reason, "iota")
}

fn read_go_framing() -> String {
  let assert Ok(source) = simplifile.read(go_framing_path)
    as "the Go helper's framing.go must be readable from the broker package"
  source
}

/// The integer value of a top-level Go `const <name> = <int>` declaration
/// in `source`, or a reason naming what was found instead.
///
/// ## Examples
///
/// ```gleam
/// assert constant_in("const ExecProtocolVersion = 3\n", "ExecProtocolVersion")
///   == Ok(3)
/// ```
///
fn constant_in(source: String, name: String) -> Result(Int, String) {
  let prefix = "const " <> name <> " = "
  let declaration =
    source
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.find(string.starts_with(_, prefix))

  case declaration {
    Error(Nil) -> Error("framing.go declares no `" <> prefix <> "<int>` line")
    Ok(line) ->
      parse_value(name, string.drop_start(line, string.length(prefix)))
  }
}

// The remainder of a const line, which is the value and possibly a
// trailing comment. Go writes `const MaxFrameLen = 1 << 24 // 16 MiB`, so
// the first whitespace-separated word is the literal and anything after it
// is commentary — or an expression this check has no business guessing at,
// which `int.parse` then refuses by name.
fn parse_value(name: String, rest: String) -> Result(Int, String) {
  let trimmed = string.trim(rest)
  let literal = case string.split_once(trimmed, " ") {
    Ok(#(first, _commentary)) -> first
    Error(Nil) -> trimmed
  }

  int.parse(literal)
  |> result.replace_error(
    "`" <> name <> "` is `" <> literal <> "`, not an integer",
  )
}
