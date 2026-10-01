//// R15, state-machine types before the code that moves through them (issue #593, 5).
////
//// Stub: wired into `lint.check_with`, reports nothing yet.

import glance
import lint/policy.{type Policy}
import lint/scan.{type Raw}
import lint/source.{type Lines}

/// Every finding this rule makes about one parsed module.
///
/// ## Examples
///
/// ```gleam
/// state_first.findings(module, code, lines, policy.default(), "tools/fs")
/// // -> []
/// ```
pub fn findings(
  module: glance.Module,
  code: String,
  lines: Lines,
  policy: Policy,
  own_path: String,
) -> List(Raw) {
  let _ = #(module, code, lines, policy, own_path)
  []
}
