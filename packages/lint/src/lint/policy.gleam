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

/// A counting call R5 watches being compared against a bound, and the
/// bounded question to ask instead.
///
/// The two spellings of the same hazard: `list.length` walks a list to the
/// end, `string.length` walks a string grapheme by grapheme, and either one
/// answers "is this longer than k" by measuring the whole of it. `noun`,
/// `unit`, `stop` and `empty` are what the finding says instead of guessing
/// — the advice for a string is not `list.drop`.
pub type Counted {
  Counted(
    /// The module path as imported, e.g. `gleam/string`.
    module: String,
    /// The counting function within it, e.g. `length`.
    function: String,
    /// What it walks, for the finding's prose: `list`, `string`.
    noun: String,
    /// What it walks over, for the finding's prose: `elements`, `graphemes`.
    unit: String,
    /// The bounded question, up to the bound: `list.drop(xs, `.
    stop: String,
    /// What the bounded question compares against: `[]`, `""`.
    empty: String,
  )
}

/// The counting calls R5 watches.
///
/// `gleam/list.length` is the one the `core/json` regression was written
/// with; `gleam/string.length` is the same rule in the spelling that hid
/// two hot sites from the first census (issue #73, E) — a report built on
/// every corruption, and a length test run per token of every scrubbed log
/// line.
pub fn counted_calls() -> List(Counted) {
  [
    Counted(
      module: "gleam/list",
      function: "length",
      noun: "list",
      unit: "elements",
      stop: "list.drop(xs, ",
      empty: "[]",
    ),
    Counted(
      module: "gleam/string",
      function: "length",
      noun: "string",
      unit: "graphemes",
      stop: "string.drop_start(text, ",
      empty: "\"\"",
    ),
  ]
}

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
    /// R7 requires every admitted `let assert` to name the invariant it
    /// rests on. Off for test sources, where destructuring a fixture is
    /// the house style and the test's own name is the message.
    assert_message: Bool,
    /// R8 fires on a private function with strictly more parameters than
    /// this and exactly one caller.
    lone_caller_arity: Int,
    /// R11 fires on a function whose longest unbroken run of statements —
    /// nothing but code between them, no blank line and no comment —
    /// strictly exceeds this. Counted in statements, never in lines: a
    /// constructor the formatter broke over nine lines is one statement.
    dense_stanza_run: Int,
  )
}

/// The default policy: what the census was taken with.
pub fn default() -> Policy {
  Policy(
    nesting_threshold: 3,
    allow_panic: False,
    catch_all_multi_subject: False,
    assert_message: True,
    lone_caller_arity: 7,
    dense_stanza_run: 8,
  )
}

/// The policy for a test source: everything but R4 and R7.
///
/// R7 goes off here for the reason R4 does. A test that destructures a
/// fixture with `let assert` is naming the invariant in the test's own
/// name, and the failure it produces is the report; the rule is about
/// `src/`, where the crash reaches an operator instead.
pub fn for_tests() -> Policy {
  for_tests_like(default())
}

/// The same relaxations, applied to a policy the command line built rather
/// than to `default()`. Two functions because `lint/cli` must not lose a
/// `--depth` while granting a test source its exemptions — and one place
/// that decides what a test source is exempt from, rather than a copy in
/// the CLI that a new rule would have to remember to update.
pub fn for_tests_like(base: Policy) -> Policy {
  Policy(..base, allow_panic: True, assert_message: False)
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
/// R7 is deliberately not part of this exemption: `harness_packages`
/// excuses the *construct*, never the missing message, and the harness is
/// where all ninety of those are (issue #73, F).
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
