//// What the rules are configured with: the eager-combinator table, the
//// nesting threshold, and whether the file being linted is allowed to
//// `panic`.
////
//// The table is data rather than a `case` in the walker so that adding a
//// combinator is a one-line change and so that the tests can enumerate what
//// the linter claims to know about.

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

/// The eager combinators the linter knows.
///
/// Each of these is an ordinary function, so the named argument is built on
/// every call, taken or not. That is a correctness hazard when the argument
/// recurses and a performance hazard when it is merely expensive — the
/// `core/json` regression at `08cdbce` was the second kind.
pub fn eager_combinators() -> List(Eager) {
  [
    Eager("gleam/bool", "guard", "return", 1, "bool.lazy_guard"),
    Eager("gleam/result", "replace_error", "error", 1, "result.map_error"),
    Eager("gleam/result", "unwrap", "or", 1, "result.lazy_unwrap"),
    Eager("gleam/option", "unwrap", "or", 1, "option.lazy_unwrap"),
    Eager("gleam/result", "or", "second", 1, "result.lazy_or"),
    Eager("gleam/option", "or", "second", 1, "option.lazy_or"),
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
