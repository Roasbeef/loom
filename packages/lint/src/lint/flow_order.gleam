//// R17, the census of helpers defined above their first caller (issue #593, 2).
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
  let _ = #(module, code, lines, policy, own_path)
  []
}
