//// What the rules are configured with: the eager-combinator table, the
//// nesting threshold, and whether the file being linted is allowed to
//// `panic`.
////
//// The table is data rather than a `case` in the walker so that adding a
//// combinator is a one-line change and so that the tests can enumerate what
//// the linter claims to know about.

import gleam/list
import gleam/option.{type Option, None, Some}

/// One eager combinator and the argument it evaluates unconditionally.
pub type Eager {
  Eager(
    /// The module path as imported, e.g. `gleam/bool`.
    module: String,
    /// The function name, e.g. `guard`.
    function: String,
    /// The label of the eager argument, when it is given by label.
    label: String,
    /// The eager argument's position when it is given positionally, counting
    /// from zero in the call as written.
    position: Int,
    /// What to reach for instead.
    lazy: String,
  )
}

/// The eager combinators the linter knows by name.
///
/// Each of these is an ordinary function, so the named argument is built on
/// every call, taken or not. That is a correctness hazard when the argument
/// recurses and a performance hazard when it is merely expensive — the
/// `core/json` regression at `08cdbce` was the second kind.
///
/// This is the hand-curated half of R1: the stdlib combinators, plus the
/// occasional locally-defined one whose hazard is real but whose shape
/// `scan`'s structural detection cannot reach on its own (see that module's
/// doc comment for why — `tools/fs.require` is the one example today, and
/// the row stays a permanent regression guard even after it is fixed,
/// exactly like any other entry here). Every *use*-compatible local
/// combinator — the `or_fault` lineage, last parameter `fn(…)`, found by
/// signature rather than by name — is detected structurally instead, in
/// `scan.local_eager_rows`, and never needs an entry here at all.
pub fn eager_combinators() -> List(Eager) {
  [
    Eager("gleam/bool", "guard", "return", 1, "bool.lazy_guard"),
    Eager("gleam/result", "replace_error", "error", 1, "result.map_error"),
    Eager("gleam/result", "unwrap", "or", 1, "result.lazy_unwrap"),
    Eager("gleam/option", "unwrap", "or", 1, "option.lazy_unwrap"),
    Eager("gleam/result", "or", "second", 1, "result.lazy_or"),
    Eager("gleam/option", "or", "second", 1, "option.lazy_or"),
    // `require`'s `when_absent` is exactly `option.unwrap`'s `or`: built on
    // every call, discarded whenever `optional` is `Ok(Some(_))`. It is not
    // reachable structurally because `require` takes no continuation at
    // all — it is a two-argument helper, not a `use`-compatible combinator
    // — so it is curated here the same way the six stdlib rows above are.
    Eager(
      "tools/fs",
      "require",
      "when_absent",
      1,
      "a thunk: change `when_absent` to `fn() -> String` and call it only "
        <> "in the `Ok(None)` branch",
    ),
  ]
}

/// The module and function whose result R5 watches being compared to a
/// literal.
pub const length_module: String = "gleam/list"

/// The function within `length_module`.
pub const length_function: String = "length"

/// How the rules are tuned for one run.
pub type Policy {
  Policy(
    /// R2 fires when a function's `case` nesting strictly exceeds this.
    nesting_threshold: Int,
    /// R4 is off for test sources, where both constructs are house style.
    allow_panic: Bool,
    /// R3 fires on a `case` with more than one subject. Off by default: a
    /// multi-subject catch-all stands for a matrix of combinations, and
    /// "you could enumerate it" is usually false.
    catch_all_multi_subject: Bool,
  )
}

/// The default policy: what the census was taken with.
pub fn default() -> Policy {
  Policy(
    nesting_threshold: 3,
    allow_panic: False,
    catch_all_multi_subject: False,
  )
}

/// The policy for a test source: everything but R4.
pub fn for_tests() -> Policy {
  Policy(..default(), allow_panic: True)
}

/// The packages whose `src/` tree is test infrastructure, and where R4
/// therefore does not reach.
///
/// R4 asks whether a file is a test by asking whether it sits under
/// `test/`, which is true of every package here but one. `conformance` is
/// a test harness that compiles as a library: the simulation runner and
/// the storage suite are `src/` because the packages under test depend on
/// them being importable, not because they are harness code, and their
/// `let assert`s are fixture destructuring in a process whose crash *is*
/// the failure report. Ninety findings with no signal in them are worse
/// than none: they were a third of the census, and they are what kept the
/// one rule `CLAUDE.md` states as policy from being enforced anywhere.
///
/// The exemption is about *presence* and nothing else. Part IV rule 3 also
/// requires every admitted `let assert` to carry an `as "message"` naming
/// the invariant, none of these ninety do, and no rule checks it — so this
/// list excuses the construct here, never the missing message (issue #73,
/// item F).
///
/// Keyed by package rather than by path prefix for the reason
/// `portable_packages` is: membership is a decision someone made, so it
/// should read as one line of data that the tests can enumerate.
pub fn harness_packages() -> List(String) {
  ["conformance"]
}

/// `base`, with R4 off when the source belongs to a package whose `src/`
/// is a test harness. `None` — a path outside the tree's layout — is never
/// exempt.
///
/// This is `for_tests` keyed by package instead of by directory. It lives
/// here rather than in `lint/cli` so that the exemption is part of the
/// library's answer about a path: a caller that asks `lint.check` about a
/// `conformance` source gets the same verdict `make lint` does.
pub fn for_package(base: Policy, package: Option(String)) -> Policy {
  case is_harness(package) {
    True -> Policy(..base, allow_panic: True)
    False -> base
  }
}

fn is_harness(package: Option(String)) -> Bool {
  case package {
    Some(name) -> list.contains(harness_packages(), name)
    None -> False
  }
}

/// The packages R6 holds to the portable subset: no `@external`, no
/// BEAM-only dependency, in source or in `gleam.toml`.
///
/// Data rather than a `case` in the rule for the same reason
/// `eager_combinators` is: adding or removing a package is a one-line
/// change, and the tests can enumerate what the rule claims to cover rather
/// than trusting that it covers anything. `lint/portable` argues what the
/// membership protects.
pub fn portable_packages() -> List(String) {
  ["core", "machine", "prompt"]
}

/// A dependency that exists only on the BEAM, named from both sides.
pub type BeamOnly {
  BeamOnly(
    /// The dependency name as `gleam.toml` declares it, e.g. `gleam_otp`.
    package: String,
    /// The prefix its modules are imported under, e.g. `gleam/otp`.
    module_prefix: String,
  )
}

/// The BEAM-only dependencies R6 refuses. Two, and they are the two that
/// decide the question: `gleam_otp` has no JavaScript target at all, and
/// `gleam_erlang` is the process, atom and node surface underneath it.
/// A package outside this table may still be BEAM-shaped in practice —
/// `simplifile` is, in the sense that its JavaScript target is Node — but
/// the rule refuses only what cannot compile at all, so that a finding is
/// never a matter of opinion.
pub fn beam_only_dependencies() -> List(BeamOnly) {
  [
    BeamOnly("gleam_erlang", "gleam/erlang"),
    BeamOnly("gleam_otp", "gleam/otp"),
  ]
}
