//// R17, the census of helpers defined above their first caller (issue #593, 2).
////
//// A module that reads top to bottom as its own call flow — the entry point
//// first, then the helpers it calls, then the helpers those call — can be
//// skimmed from the top and entered anywhere. A module ordered the other
//// way, leaves before the branches that use them, makes the reader hold a
//// stack of unexplained names until the function that finally uses them
//// arrives. Gleam does not care about definition order, so nothing but
//// habit decides it, and habit from languages that need declaration before
//// use runs the wrong way here.
////
//// The measurement is per module. A *helper* is a private function with at
//// least one in-module caller (`lint/calls` says what a caller is, and
//// where it stops seeing: recursion is not a caller, a reference from a
//// constant is invisible). Public functions are entry points and are never
//// counted. A helper is *above its caller* when its definition starts
//// before the earliest-defined of its callers, so a helper shared by
//// several callers is judged against the first of them: it can be placed
//// after all of them or not at all, and "after the first" is the weakest
//// reading that is still a call-flow order.
////
//// The rule reports once per module, at offset 0, and only for a module
//// with `flow_order_min_helpers` helpers or more where strictly more than
//// `flow_order_percent` per cent are above their caller. Below the floor a
//// percentage is anecdote, and a module that is half-and-half has no
//// order to recommend. It is a census, never a gate: a leaf helper that a
//// section header groups with its siblings is a legitimate reason to
//// disagree, so the number is the point, not any one module's verdict.

import glance
import gleam/int
import gleam/list
import gleam/string
import lint/calls.{type Helper}
import lint/finding
import lint/policy.{type Policy}
import lint/scan.{type Raw, Raw}
import lint/source.{type Lines}

/// Every finding this rule makes about one parsed module.
///
/// ## Examples
///
/// ```gleam
/// flow_order.findings(module, code, lines, policy.default(), "tools/fs")
/// // -> []
/// ```
pub fn findings(
  module: glance.Module,
  code: String,
  lines: Lines,
  policy: Policy,
  own_path: String,
) -> List(Raw) {
  let _ = #(code, lines, own_path)
  let helpers = calls.private_helpers(module)
  let total = list.length(helpers)
  let above = list.filter(helpers, is_above_caller)
  let count = list.length(above)

  // The comparison is in integers (`count * 100 > percent * total`) so a
  // threshold of 50 means "strictly more than half" with no rounding to
  // argue about; the percentage printed below is for the reader only.
  case
    total >= policy.flow_order_min_helpers
    && count * 100 > policy.flow_order_percent * total
  {
    True -> [report(above, count, total)]
    False -> []
  }
}

/// A helper defined before the earliest-defined of its callers. Callers
/// arrive in definition order, so the first is the earliest; the guard
/// against an empty list is the type's, not a case the data produces.
fn is_above_caller(helper: Helper) -> Bool {
  case helper.callers {
    [first, ..] -> helper.function.location.start < first.location.start
    [] -> False
  }
}

/// The module's one finding: the tally, then up to three helpers that
/// show what is meant, each beside the caller it precedes.
fn report(above: List(Helper), count: Int, total: Int) -> Raw {
  let percent = count * 100 / total
  Raw(
    rule: finding.FlowOrder,
    offset: 0,
    function: "",
    detail: int.to_string(count)
      <> " of "
      <> int.to_string(total)
      <> " private helpers are defined above their first caller ("
      <> int.to_string(percent)
      <> "%); order by call flow — the entry point first, then the helpers "
      <> "it calls. e.g. "
      <> string.join(list.map(list.take(above, 3), example), ", "),
  )
}

fn example(helper: Helper) -> String {
  let caller = case helper.callers {
    [first, ..] -> first.name
    [] -> ""
  }
  "`" <> helper.function.name <> "` above `" <> caller <> "`"
}
