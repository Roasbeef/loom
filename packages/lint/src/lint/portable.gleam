//// R6: the three packages held to the portable subset, and what that
//// membership protects.
////
//// `core`, `machine` and `prompt` contain no `@external` and reach for no
//// BEAM-only dependency. That has been true since they were written and
//// until now nothing said it had to be. Two properties rest on it, and one
//// external closes both:
////
//// - **The operation state space stays property-testable without
////   processes.** This is the reason `machine`'s package doc already gives
////   for its purity, and it is the right one: `next_action` is `State ×
////   Inputs → Action`, so a property test enumerates states instead of
////   spawning a supervision tree to observe them. Foreign code is trusted
////   unchecked — the annotation is the compiler's only evidence about what
////   is on the other side — so an external is a hole in exactly the claim
////   those tests rest on, however deterministic the function behind it is.
//// - **The three stay compilable to the JavaScript target.** The durable
////   model, the whole operation machine and prompt assembly are portable
////   today. That is enough to *decide but not act*: replay a conversation
////   tree, validate a transcript with the same total decoders the server
////   uses, run `next_action` over fetched state to show what the harness
////   would do next. Every effect still proxied through the broker.
////
//// The second property is the one nothing recorded, and it is the one a
//// contributor cannot be expected to infer. Reaching for a fast hash, a
//// clock or a UUID leaves the testability argument feeling satisfied — the
//// function is deterministic and side-effect-free — while closing a door
//// nobody knew was open.
////
//// # What portable does not mean
////
//// Not that the harness could run in a browser, and the rule should not be
//// read as a step toward it. `gleam_otp` has no JavaScript target and the
//// orchestration plane *is* supervision trees, actors, monitors and links;
//// there is nothing to port the design onto. Rule Zero is kernel-enforced —
//// bwrap namespaces, Landlock, seccomp, a helper over a port — and in a
//// browser the harness VM and the untrusted-code VM would be the same VM,
//// which inverts the invariant the whole architecture exists to hold. The
//// two-channel doctrine assumes both channels, and doorbells need
//// processes. The short path to a browser client is not porting the harness
//// at all: it is `packages/tui`'s seam, the frozen §1.6 protocol over the
//// client gateway, which gets the real harness and its real sandbox behind
//// a web front end.
////
//// # Why `@external` at all, and not `@external(erlang`
////
//// Because no target is the safe one. An Erlang external closes the
//// portable half. A JavaScript external keeps it and breaks the BEAM build
//// instead, which is the target Loom actually ships on. A matched pair
//// keeps both builds and still puts trusted-unchecked foreign code inside
//// the three packages whose entire claim is that they are pure functions of
//// their arguments. The rule therefore names no target: this is the strict
//// form of the FFI confinement rule (gleam-style Part IV §4), which already
//// confines `@external` to `*/internal/ffi_*.gleam` everywhere. These three
//// have no such module and may not grow one.
////
//// # Where each half looks
////
//// The `@external` half reads the **token stream** (`lint/source`), not the
//// AST: a policy rule must still report an external in a file `glance`
//// could not parse, rather than let it become an R0 warning. The
//// BEAM-only-import half reads the AST, where a module path is one string
//// and there is nothing a lexer would see more of. The `gleam.toml` half is
//// a **line scan**, not a parse: the question is only whether a dependency
//// name appears as a key, and a TOML parser would be a dependency bought
//// for three lines. That scan deliberately does not tell `[dependencies]`
//// from `[dev_dependencies]` — a BEAM-only dev dependency makes the
//// package's own test suite unrunnable on the other target, which is where
//// a lapsed property would first be noticed.

import glance
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lint/finding
import lint/policy.{type BeamOnly}
import lint/scan.{type Raw, Raw}

/// Every `@external` in a portable package's source, given the offsets
/// `source.external_offsets` lexed out of it. Nothing for any other
/// package: elsewhere `@external` is confined rather than forbidden, and
/// that confinement is a CI grep rather than a rule here.
pub fn externals(package: Option(String), offsets: List(Int)) -> List(Raw) {
  use name <- for_portable(package)
  list.map(offsets, fn(offset) {
    Raw(
      rule: finding.PortablePurity,
      offset:,
      function: "",
      detail: "`@external` in a package that may hold none. "
        <> protects(name)
        <> ". Any target closes both: an Erlang external ends the "
        <> "portability, a JavaScript one breaks the BEAM build instead, "
        <> "and a matched pair still puts trusted-unchecked foreign code "
        <> "where the purity claim is",
    )
  })
}

/// Every BEAM-only import in a portable package's parsed module.
pub fn imports(package: Option(String), module: glance.Module) -> List(Raw) {
  use name <- for_portable(package)
  list.flat_map(module.imports, fn(imported) {
    let import_ = imported.definition
    matching(
      fn(dependency) { under(import_.module, dependency.module_prefix) },
      fn(dependency) {
        Raw(
          rule: finding.PortablePurity,
          offset: import_.location.start,
          function: "",
          detail: "`import "
            <> import_.module
            <> "` reaches "
            <> dependency.package
            <> ", which has no JavaScript target. "
            <> protects(name)
            <> ". Reaching a process from here closes both at once",
        )
      },
    )
  })
}

/// Every BEAM-only dependency a portable package's `gleam.toml` declares.
///
/// A line scan rather than a TOML parse, and blind to which table the key
/// sits in; this module's doc argues both.
pub fn manifest(package: Option(String), code: String) -> List(Raw) {
  use name <- for_portable(package)
  let #(_, found) =
    list.fold(string.split(code, "\n"), #(0, []), fn(state, line) {
      let #(offset, found) = state

      // Byte offsets, not codepoints: `lint/source`'s line index counts
      // bytes because `glance` reports bytes, and the two must agree.
      #(offset + string.byte_size(line) + 1, [
        declarations(line, offset, name),
        ..found
      ])
    })
  found |> list.reverse |> list.flatten
}

fn declarations(line: String, offset: Int, package: String) -> List(Raw) {
  matching(
    fn(dependency) { declares(line, dependency.package) },
    fn(dependency) {
      Raw(
        rule: finding.PortablePurity,
        offset:,
        function: "",
        detail: "`"
          <> dependency.package
          <> "` is declared here and has no JavaScript target. "
          <> protects(package)
          <> ". Declaring it ends the portability outright and leaves the "
          <> "testability one import away",
      )
    },
  )
}

/// What R6 protects, in one clause, shared by all three sites.
///
/// A refusal that names the violation and not the reason teaches nothing
/// and leaves the reader no way to judge whether their own case is the
/// exception worth arguing; this tree has been bitten by that three times
/// (#37, #60, #61). So every R6 finding carries both properties and the
/// place the argument is written down, and the site adds only what its own
/// violation costs.
fn protects(package: String) -> String {
  "`"
  <> package
  <> "` is one of three packages ("
  <> string.join(policy.portable_packages(), ", ")
  <> ") held free of foreign code and of BEAM-only dependencies by rule "
  <> "rather than by coincidence, and two properties rest on that: the "
  <> "operation state space stays property-testable without spawning "
  <> "processes, and these three stay compilable to the JavaScript target "
  <> "— enough to replay and validate a conversation, never to run the "
  <> "harness. `lint/portable` and gleam-style Part IV argue it; read one "
  <> "of them before landing an exception"
}

/// Run `continue` only for a source that belongs to a portable package.
///
/// `None` is a path outside the tree's layout — a doctest snippet, a
/// scratch file — and gets no finding rather than a guess at which package
/// it would have been in.
fn for_portable(
  package: Option(String),
  continue: fn(String) -> List(Raw),
) -> List(Raw) {
  case package {
    None -> []
    Some(name) ->
      case list.contains(policy.portable_packages(), name) {
        True -> continue(name)
        False -> []
      }
  }
}

/// The findings for every BEAM-only dependency a predicate accepts.
fn matching(
  wanted: fn(BeamOnly) -> Bool,
  report: fn(BeamOnly) -> Raw,
) -> List(Raw) {
  policy.beam_only_dependencies()
  |> list.filter(wanted)
  |> list.map(report)
}

/// A module path that belongs to a package: the prefix itself, or anything
/// beneath it. `gleam/erlangish/thing` is neither.
fn under(module: String, prefix: String) -> Bool {
  module == prefix || string.starts_with(module, prefix <> "/")
}

/// A line declaring `name` as a dependency: the key, then `=`, whitespace
/// aside. A comment that mentions the name, or a path inside a value, is
/// not a declaration and does not fire.
fn declares(line: String, name: String) -> Bool {
  case string.split_once(string.trim(line), "=") {
    Error(Nil) -> False
    Ok(#(key, _)) -> string.trim(key) == name
  }
}
