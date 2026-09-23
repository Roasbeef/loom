//// Vetting corpus — the adversarial exit criterion for WP-J1.
////
//// The vetting lint is code mode's single load-bearing security control, so it
//// is tested the way it is threat-modelled: as data. Each category below is a
//// family of hostile (or, at the end, legitimate) programs with the rule it
//// probes, asserted rejected-or-passed. The count is well past the spec's
//// 50-program floor; `corpus_size_test` pins it.
////
//// A note on unicode-lookalike imports: `glance`'s lexer rejects non-ASCII and
//// otherwise-malformed module segments at parse time, so those programs are
//// rejected as `Unparseable` before the allowlist comparison runs. That is a
//// correct rejection, and the ASCII grammar gate (`policy.is_legal_module_name`)
//// is tested directly as the belt-and-suspenders that would still reject such a
//// name if a future parser surfaced it in the AST. Both are asserted here.

import codemode/vet.{
  type Rule, type VetResult, ImportNotAllowed, NoForeignInterface, Passed,
  Rejected, Unparseable,
}
import codemode/vet/policy.{type VetPolicy}
import gleam/list
import gleam/string
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// --- Test helpers ----------------------------------------------------------

fn policy() -> VetPolicy {
  policy.default()
}

fn is_passed(result: VetResult) -> Bool {
  case result {
    Passed(_) -> True
    Rejected(_) -> False
  }
}

fn is_rejected(result: VetResult) -> Bool {
  !is_passed(result)
}

/// Whether `result` is a rejection carrying at least one rejection of `rule`.
fn has_rule(result: VetResult, rule: Rule) -> Bool {
  case result {
    Passed(_) -> False
    Rejected(rejections) -> list.any(rejections, fn(r) { r.rule == rule })
  }
}

/// Whether any rejection's `detail` contains `needle`.
fn any_detail_contains(result: VetResult, needle: String) -> Bool {
  case result {
    Passed(_) -> False
    Rejected(rejections) ->
      list.any(rejections, fn(r) { string.contains(r.detail, needle) })
  }
}

/// Every source in `sources` is rejected under the default policy.
fn all_rejected(sources: List(String)) -> Bool {
  list.all(sources, fn(source) { is_rejected(vet.vet(source, policy())) })
}

/// Every source in `sources` is rejected with at least one rejection of `rule`.
fn all_rejected_with(sources: List(String), rule: Rule) -> Bool {
  list.all(sources, fn(source) { has_rule(vet.vet(source, policy()), rule) })
}

/// Every source in `sources` passes under the default policy.
fn all_passed(sources: List(String)) -> Bool {
  list.all(sources, fn(source) { is_passed(vet.vet(source, policy())) })
}

// --- Category 1: FFI via @external and the fail-closed attribute class ------

/// The headline case: `@external` on a public function is the direct FFI reach.
pub fn external_on_public_function_test() {
  let source =
    "@external(erlang, \"os\", \"cmd\")\npub fn run(cmd: String) -> String\n"
  assert has_rule(vet.vet(source, policy()), NoForeignInterface)
}

/// `@external` on a private function must be caught too — privacy is no shield.
pub fn external_on_private_function_test() {
  let source =
    "@external(erlang, \"os\", \"cmd\")\nfn run(cmd: String) -> String\n"
  assert has_rule(vet.vet(source, policy()), NoForeignInterface)
}

/// A bare `@external` with no following definition. `glance` drops the dangling
/// attribute, so the raw-source backstop is what rejects it.
pub fn bare_external_test() {
  let source = "@external(erlang, \"os\", \"cmd\")"
  assert has_rule(vet.vet(source, policy()), NoForeignInterface)
}

/// `@external` trailing after real code is likewise dropped by the parser and
/// caught by the backstop.
pub fn trailing_external_after_code_test() {
  let source = "pub fn main() { 1 }\n@external(erlang, \"os\", \"cmd\")"
  assert has_rule(vet.vet(source, policy()), NoForeignInterface)
}

/// The fail-closed rule: even harmless-looking attributes are refused, because
/// attributes are the only construct that can reach foreign code. (`@internal`
/// carries no arguments and `glance` rejects the parenthesis-less form at parse
/// time, so it is asserted only as rejected, not with a specific rule.)
pub fn benign_attributes_rejected_test() {
  let with_args = [
    "@target(erlang)\npub fn main() { 1 }\n",
    "@deprecated(\"x\")\npub fn main() { 1 }\n",
  ]
  assert all_rejected_with(with_args, NoForeignInterface)
  assert is_rejected(vet.vet("@internal\npub fn main() { 1 }\n", policy()))
}

/// Attributes on every kind of definition are swept, not just functions.
pub fn external_on_non_function_definitions_test() {
  let cases = [
    "@external(erlang, \"a\", \"b\")\npub type Foo\n",
    "@external(erlang, \"a\", \"b\")\npub const x = 1\n",
    "@external(erlang, \"a\", \"b\")\nimport cap/fs\n",
    // Glance 4+ surfaces attributes on individual variants separately from
    // the definition-level list. The token backstop must keep that newly
    // parsed location inside the same fail-closed attribute class.
    "pub type Choice {\n  @deprecated(\"legacy\")\n  Legacy\n}\n",
  ]
  assert all_rejected_with(cases, NoForeignInterface)
}

/// Stacked attributes and mixed spellings are all rejected.
pub fn stacked_attributes_test() {
  let cases = [
    "@target(erlang)\n@external(erlang, \"os\", \"cmd\")\npub fn run(c: String) -> String\n",
    "@external(javascript, \"./m.mjs\", \"f\")\npub fn f() -> Int\n",
    "@external(erlang, \"erlang\", \"apply\")\npub fn apply() -> Int\n",
  ]
  assert all_rejected_with(cases, NoForeignInterface)
}

// --- Category 1b: the @external backstop scans tokens, not raw bytes ---------
//
// The backstop must fire on a real `@external` token (attached, dangling, or
// whitespace/comment-separated) and on any other dangling attribute, but must
// NOT fire on the literal bytes `@external` appearing inside a string or a
// comment — those never lex to an `At` token followed by `Name("external")`.

/// The literal in a string constant is inert; the program must PASS (V-F1).
pub fn external_literal_in_string_passes_test() {
  let source = "import cap/fs\npub fn main() { \"@external\" }\n"
  assert is_passed(vet.vet(source, policy()))
}

/// The literal in a comment is inert; the program must PASS (V-F1).
pub fn external_literal_in_comment_passes_test() {
  let source = "import cap/fs\n// @external here\npub fn main() { 1 }\n"
  assert is_passed(vet.vet(source, policy()))
}

/// The realistic agent task — grepping source for the FFI keyword — must PASS
/// rather than train the model that the word is radioactive (V-F1 case c).
pub fn external_grep_task_passes_test() {
  let source =
    "import cap/fs\nimport gleam/string\npub fn scan(s: String) -> Bool { string.contains(s, \"@external\") }\n"
  assert is_passed(vet.vet(source, policy()))
}

/// A whitespace-separated dangling `@ external` still REJECTS: the token scan
/// sees `At` then `Name("external")` regardless of the gap (V-F2).
pub fn whitespace_separated_external_rejects_test() {
  let source = "@ external(erlang, \"os\", \"cmd\")"
  assert has_rule(vet.vet(source, policy()), NoForeignInterface)
}

/// A dangling non-`@external` attribute is dropped by `glance` but still caught
/// by the token backstop, so the whole attribute class fails closed (V-F5).
pub fn dangling_benign_attribute_rejects_test() {
  let source = "pub fn main() { 1 }\n@deprecated(\"x\")\n"
  assert has_rule(vet.vet(source, policy()), NoForeignInterface)
}

// --- Category 2: imports outside the allowlist (well-formed names) -----------

/// Well-formed imports outside the admitted surface remain forbidden,
/// including runtime modules and pure helpers kept off the workspace seam.
/// All are rejected on the allowlist rule.
fn forbidden_import_cases() -> List(String) {
  [
    "import gleam/erlang\npub fn main() { 1 }\n",
    "import gleam/erlang/os\npub fn main() { 1 }\n",
    "import gleam/erlang/process\npub fn main() { 1 }\n",
    "import gleam/erlang/atom\npub fn main() { 1 }\n",
    "import gleam/erlang/node\npub fn main() { 1 }\n",
    "import gleam/otp/actor\npub fn main() { 1 }\n",
    "import gleam/otp/task\npub fn main() { 1 }\n",
    "import gleam/otp/supervisor\npub fn main() { 1 }\n",
    "import gleam/io\npub fn main() { 1 }\n",
    "import gleam/bit_array\npub fn main() { 1 }\n",
    "import core/json\npub fn main() { 1 }\n",
    "import shellout\npub fn main() { 1 }\n",
    "import simplifile\npub fn main() { 1 }\n",
    "import gleam/regexp\npub fn main() { 1 }\n",
    "import gleam/uri\npub fn main() { 1 }\n",
    "import gleam/httpc\npub fn main() { 1 }\n",
    "import glance\npub fn main() { 1 }\n",
    // A cap-shaped name that is not one of the nine recognised cap modules.
    "import cap/db\npub fn main() { 1 }\n",
    "import cap/exec\npub fn main() { 1 }\n",
    "import cap/socket\npub fn main() { 1 }\n",
  ]
}

pub fn forbidden_imports_test() {
  assert all_rejected_with(forbidden_import_cases(), ImportNotAllowed)
}

/// `gleam/erlang*` and `gleam/otp/*` are rejected by an explicit denylist with
/// a clear message, redundant to their mere absence from the allowlist (CH-F1).
pub fn denylisted_imports_rejected_with_clear_message_test() {
  let cases = [
    "import gleam/erlang\npub fn main() { 1 }\n",
    "import gleam/erlang/process\npub fn main() { 1 }\n",
    "import gleam/otp\npub fn main() { 1 }\n",
    "import gleam/otp/actor\npub fn main() { 1 }\n",
  ]
  assert list.all(cases, fn(source) {
    let result = vet.vet(source, policy())
    has_rule(result, ImportNotAllowed)
    && any_detail_contains(result, "explicitly denied")
  })
}

/// Aliasing a forbidden import does not launder it — the module named is still
/// forbidden.
pub fn aliased_forbidden_import_test() {
  let cases = [
    "import gleam/erlang/atom as a\npub fn main() { 1 }\n",
    "import gleam/io as safe\npub fn main() { 1 }\n",
    "import shellout as sh\npub fn main() { 1 }\n",
  ]
  assert all_rejected_with(cases, ImportNotAllowed)
}

/// Pulling unqualified names from a forbidden module is rejected on the module,
/// which is what carries the capability.
pub fn unqualified_forbidden_import_test() {
  let cases = [
    "import gleam/erlang/atom.{create_from_string}\npub fn main() { 1 }\n",
    "import gleam/io.{println}\npub fn main() { 1 }\n",
    "import gleam/erlang/os.{get_env}\npub fn main() { 1 }\n",
  ]
  assert all_rejected_with(cases, ImportNotAllowed)
}

/// One forbidden import among several allowed ones is still caught.
pub fn mixed_allowed_and_forbidden_test() {
  let source =
    "import cap/fs\nimport gleam/list\nimport gleam/erlang/os\npub fn main() { 1 }\n"
  assert has_rule(vet.vet(source, policy()), ImportNotAllowed)
}

// --- Category 3: unicode-lookalike and malformed import names ---------------

/// Lookalike and malformed import names. `glance` rejects these at parse time
/// (they never become AST imports), so they are asserted rejected, not
/// rejected-with-a-specific-rule.
fn lookalike_import_cases() -> List(String) {
  [
    // Cyrillic 'с' (U+0441) for ASCII 'c'.
    "import \u{0441}ap/fs\npub fn main() { 1 }\n",
    // Fullwidth 'f' (U+FF46).
    "import cap/\u{ff46}s\npub fn main() { 1 }\n",
    // Zero-width joiner (U+200D) inside a segment.
    "import cap/f\u{200d}s\npub fn main() { 1 }\n",
    // Greek omicron (U+03BF) for ASCII 'o' in a would-be 'gleam' lookalike.
    "import gleam/\u{03bf}ption\npub fn main() { 1 }\n",
    // Uppercase segment — not a legal module name.
    "import Gleam/List\npub fn main() { 1 }\n",
    // Dot separator instead of slash.
    "import gleam.list\npub fn main() { 1 }\n",
    // Combining acute (U+0301) — an NFD-style decomposition.
    "import cap/f\u{0301}s\npub fn main() { 1 }\n",
  ]
}

pub fn lookalike_imports_rejected_test() {
  assert all_rejected(lookalike_import_cases())
}

/// The ASCII grammar gate rejects every lookalike/malformed name directly, so
/// the defense holds even if a future parser surfaced such a name as an import.
pub fn grammar_gate_rejects_lookalikes_test() {
  let names = [
    "\u{0441}ap/fs", "cap/\u{ff46}s", "cap/f\u{200d}s", "gleam/\u{03bf}ption",
    "Gleam/List", "gleam.list", "cap/f\u{0301}s", "cap/fs ", " cap/fs", "cap-fs",
    "cap/fs/", "/cap/fs", "cap//fs", "", "cap/1fs", "cap/FS",
  ]
  assert list.all(names, fn(name) { !policy.is_legal_module_name(name) })
}

/// The grammar gate accepts the legal ASCII names it must.
pub fn grammar_gate_accepts_legal_names_test() {
  let names = [
    "cap/fs", "gleam/list", "gleam/string_tree", "a", "a/b/c", "a_b/c_d",
    "cap/fs2",
  ]
  assert list.all(names, policy.is_legal_module_name)
}

// --- Category 4: prelude shadowing and re-export attempts -------------------

/// Aliasing an *allowed* cap module to a prelude-looking name does not grant a
/// new capability; the module named is still the allowlisted one, so it passes.
pub fn aliased_allowed_import_passes_test() {
  let cases = [
    "import cap/fs as os\npub fn main() { 1 }\n",
    "import gleam/list as l\npub fn main() { 1 }\n",
  ]
  assert all_passed(cases)
}

/// A program defining its own `fs` binding shadows nothing capability-bearing —
/// it declares no import and no @external, so it passes. (The submitted
/// module's *own* name is fixed by the compile service, not present in source,
/// so a program cannot declare itself to be `cap/fs`.)
pub fn local_shadow_definition_passes_test() {
  let cases = [
    "pub fn fs() -> Int { 1 }\n", "pub type Report { Report(ok: Bool) }\n",
    "pub const proc = 1\n",
  ]
  assert all_passed(cases)
}

/// A re-export via type alias still needs the underlying import, so a forbidden
/// re-export is caught on its import.
pub fn forbidden_reexport_test() {
  let source =
    "import gleam/erlang/atom\npub type Atom = atom.Atom\npub fn main() { 1 }\n"
  assert has_rule(vet.vet(source, policy()), ImportNotAllowed)
}

// --- Category 5: parse-level attacks (must not crash; clean rejection) -------

/// Malformed sources must settle as rejections, never crash the linter.
fn unparseable_cases() -> List(String) {
  [
    "import\n", "pub fn (\n", "pub fn main() { 1 ", "fn main() { case }", "@\n",
    "import cap/\n", "pub fn main() { [1, 2, ", "pub type\n", "let x = 1\n",
    "}}}}}}\n",
  ]
}

pub fn unparseable_sources_rejected_test() {
  assert all_rejected_with(unparseable_cases(), Unparseable)
}

/// Deeply nested source must not blow the linter up; any total result is fine.
pub fn deep_nesting_is_total_test() {
  let opens = list.repeat("[", 2000) |> string_concat
  let closes = list.repeat("]", 2000) |> string_concat
  let source = "pub fn main() { " <> opens <> closes <> " }\n"
  let result = vet.vet(source, policy())
  // The assertion is simply that a value came back (totality).
  assert is_passed(result) || is_rejected(result)
}

fn string_concat(parts: List(String)) -> String {
  list.fold(parts, "", fn(acc, part) { acc <> part })
}

/// The empty program parses to an empty module and is safe: no imports, no
/// externals, no effects. It passes.
pub fn empty_source_passes_test() {
  assert is_passed(vet.vet("", policy()))
}

// --- Category 6: legitimate programs (must pass) ----------------------------

/// The migration-style sample from the design: cap/fs, cap/lsp, cap/proc,
/// cap/task, cap/report, no @external. Must pass.
pub fn migration_sample_passes_test() {
  let source =
    "import cap/fs
import cap/lsp
import cap/proc
import cap/task
import cap/report
import gleam/list
import gleam/string

pub fn main() -> report.Outcome {
  let files = fs.list(\"src\")
  let renamed = list.map(files, fn(f) { string.replace(f, \".old\", \".new\") })
  let _ = task.parallel_map(renamed, fn(f) { proc.run(\"mv\", [f]) })
  report.ok(\"migrated\")
}
"
  let result = vet.vet(source, policy())
  let assert Passed(vetted) = result
  // The token carries the exact source, so the compile service compiles what
  // was vetted.
  assert vet.vetted_source(vetted) == source
}

/// Pure-stdlib programs across the allowed subset pass.
pub fn pure_stdlib_programs_pass_test() {
  let cases = [
    "import gleam/list\nimport gleam/int\npub fn main() { list.map([1], int.to_string) }\n",
    "import gleam/string\nimport gleam/result\npub fn main() { string.uppercase(\"x\") }\n",
    "import gleam/dict\nimport gleam/option\npub fn main() { dict.new() }\n",
    "import gleam/set\nimport gleam/order\nimport gleam/pair\npub fn main() { 1 }\n",
    "import gleam/float\nimport gleam/bool\nimport gleam/function\npub fn main() { 1 }\n",
    "import gleam/string_tree\npub fn main() { string_tree.new() }\n",
    // Vetting must accept the same labelled-argument shorthand that Gleam's
    // compiler and Loom's own house style accept. Rejecting it strands stored
    // skills before their source can reach the hermetic compiler.
    "fn keep(value value: Int) -> Int { value }\npub fn main() { let value = 1 keep(value:) }\n",
    "pub type Box { Box(value: Int) }\npub fn main() { let value = 1 case Box(value:) { Box(value:) -> value } }\n",
    "pub fn main() { assert 1 == 1 }\n",
    "pub fn main() { let assert Ok(value) = Ok(1) as \"message\" value }\n",
    "pub fn main() { let value = 1 echo value value }\n",
    "pub fn main() { case \"abc\" { \"a\" as prefix <> rest -> #(prefix, rest) value -> #(value, \"\") } }\n",
  ]
  assert all_passed(cases)
}

/// JSON values can be decoded on both program seams without importing a
/// runtime or granting any additional capability.
pub fn json_decoding_passes_on_both_program_seams_test() {
  let source =
    "import gleam/json\n"
    <> "import gleam/dynamic\n"
    <> "import gleam/dynamic/decode\n"
    <> "pub fn main() -> Result(dynamic.Dynamic, json.DecodeError) {\n"
    <> "  json.parse(\"{}\", decode.dynamic)\n"
    <> "}\n"
  assert is_passed(vet.vet(source, policy.default()))
  assert is_passed(vet.vet(source, policy.orchestration()))
}

/// A cap/actor + cap/kv program passes.
pub fn cap_actor_kv_program_passes_test() {
  let source =
    "import cap/actor\nimport cap/kv\nimport cap/net\npub fn main() { 1 }\n"
  assert is_passed(vet.vet(source, policy()))
}

// --- Category 7: full program capabilities and bounded host variants --------

/// Both installed program modes admit effect and child capabilities together.
///
/// The default server serves both modes. A program may inspect the workspace,
/// start a child, and report the result without changing modes or splitting its
/// source across tool calls.
pub fn both_program_modes_admit_the_full_capability_union_test() {
  let combined =
    "import cap/fs\nimport cap/proc\nimport cap/strand\nimport cap/workflow\npub fn main() { 1 }\n"
  assert is_passed(vet.vet(combined, policy.default()))
  assert is_passed(vet.vet(combined, policy.orchestration()))

  let expected = policy.program_cap_modules()
  assert list.all(expected, policy.contains(policy.default(), _))
  assert list.all(expected, policy.contains(policy.orchestration(), _))
  assert policy.allowed_imports(policy.default())
    == policy.allowed_imports(policy.orchestration())
}

/// An explicitly effect-only host never advertises child custody.
pub fn effect_only_host_policy_refuses_child_capabilities_test() {
  let restricted = policy.workspace_effects()
  assert policy.contains(restricted, "cap/fs")
  assert has_rule(
    vet.vet("import cap/strand\npub fn main() { 1 }\n", restricted),
    ImportNotAllowed,
  )
  assert has_rule(
    vet.vet("import cap/workflow\npub fn main() { 1 }\n", restricted),
    ImportNotAllowed,
  )
}

/// The shared standard-library list holds no capability module.
///
/// `default()` and `orchestration()` append `default_stdlib_modules`.
/// Keeping capabilities out of that list ensures the explicit effect-only
/// host and extension policies cannot acquire an import by accident.
pub fn the_shared_stdlib_list_admits_no_capability_test() {
  assert list.all(policy.default_stdlib_modules(), fn(name) {
    !string.starts_with(name, "cap/")
  })
}

/// A capability on no seam is a decision, written down.
///
/// `cap/runtime` is the boot runtime and belongs to the harness, not to a
/// submitted program; `cap/mcp` is the generated `cap/mcp/<server>`
/// modules' types-only vocabulary, off every seam until the generated
/// path lands end to end (issue #106). The list exists so that
/// "unreachable" is a claim somebody made rather than an omission nobody
/// noticed, and `scripts/gen-prelude.sh --check` holds it against the
/// modules `packages/cap` actually ships (issue #95). Here we pin the
/// list itself and that it contradicts neither seam.
pub fn a_harness_only_capability_is_on_no_seam_test() {
  let harness_only = policy.harness_only_cap_modules()
  assert harness_only == ["cap/notes", "cap/mcp", "cap/runtime"]
  assert list.all(harness_only, fn(name) {
    !policy.contains(policy.default(), name)
    && !policy.contains(policy.orchestration(), name)
    && !policy.contains(policy.extension(), name)
  })
}

/// The extension seam widens the workspace effect subset, not child custody.
///
/// An extension tool can use the workspace effect modules, but it has no
/// Agency owner for `cap/strand` or `cap/workflow`. Keep the effect subset in
/// sync while preserving that custody boundary.
pub fn the_extension_seam_is_the_workspace_seam_widened_test() {
  let workspace = policy.default_cap_modules()
  let extension = policy.extension_cap_modules()
  assert list.all(workspace, fn(name) { list.contains(extension, name) })
  assert list.all(policy.default_stdlib_modules(), fn(name) {
    list.contains(policy.extension_stdlib_modules(), name)
  })

  // And the widening is real rather than an equality dressed up as one.
  // *Which* names it adds is the next test's, which pins the whole set
  // rather than sampling it.
  assert list.length(extension) > list.length(workspace)
}

/// The extension adds only its own vocabulary and durable memory.
///
/// It must not acquire child custody from the program-mode union. The only
/// additions to workspace effects are `ext`, `ext/hook`, and `ext/memory`.
pub fn the_extension_seam_widens_by_exactly_three_names_test() {
  let extra =
    list.filter(policy.extension_cap_modules(), fn(name) {
      !list.contains(policy.default_cap_modules(), name)
    })
  assert extra == ["ext", "ext/hook", "ext/memory"]
  assert !policy.contains(policy.extension(), "cap/strand")
}

/// The extension seam's own standard-library list holds no capability
/// module, for the reason the shared list does not: a `cap/*` name added
/// where a pure helper belongs would widen a seam without appearing in
/// any capability list.
pub fn the_extension_stdlib_list_admits_no_capability_test() {
  assert list.all(policy.extension_stdlib_modules(), fn(name) {
    !string.starts_with(name, "cap/")
  })
}

/// An extension's own source is judged against its seam and no other.
pub fn an_extension_module_passes_only_its_own_seam_test() {
  let source =
    "import ext
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json

pub fn run(arguments: dynamic.Dynamic, _ctx: ext.Ctx) {
  let decoder = decode.success(json.to_string(json.null()))
  case ext.decode_args(arguments, decoder) {
    Ok(text) -> Ok(ext.text(text))
    Error(refusal) -> Error(refusal)
  }
}
"
  assert is_passed(vet.vet(source, policy.extension()))
  assert has_rule(vet.vet(source, policy.default()), ImportNotAllowed)
  assert has_rule(vet.vet(source, policy.orchestration()), ImportNotAllowed)
}

/// The resident seam reaches no capability at all.
///
/// This is the seam a harness-resident hook body would be judged
/// against, and the whole of its claim is subtractive: a body running
/// inside the harness VM gets the vocabulary and the pure standard
/// library, and not one `cap/*` module. Asserted over the allowlist
/// rather than over the prelude list, because the standard-library half
/// is shared with the jailed seam and a capability added there would
/// reach this seam without ever appearing in `resident_prelude_modules`.
pub fn the_resident_seam_reaches_no_capability_test() {
  assert list.all(policy.allowed_imports(policy.resident()), fn(name) {
    !string.starts_with(name, "cap/")
  })
  assert list.all(policy.default_cap_modules(), fn(name) {
    !policy.contains(policy.resident(), name)
  })
  assert !policy.contains(policy.resident(), "cap/strand")
}

/// The resident seam is the extension seam with the capabilities taken
/// away, and nothing else changed.
///
/// Stated as a difference in both directions so the relation is a fact
/// about the code: everything the resident seam admits, the extension
/// seam admits too, and everything the extension seam admits and this
/// one does not carries authority. A future widening of either that
/// broke the relation fails here rather than passing quietly.
///
/// "Carries authority" is asked as `cap/*` or a name
/// `extension_authority_modules` lists, rather than as the prefix alone,
/// because `ext/memory` is a broker client spelled like the two
/// authority-free `ext` modules beside it. The prefix stopped being the
/// whole answer the day it landed, and a test that still asked only
/// about the prefix would have gone green over a resident body holding
/// the durable store.
pub fn the_resident_seam_is_the_extension_seam_disarmed_test() {
  let resident = policy.allowed_imports(policy.resident())
  let extension = policy.allowed_imports(policy.extension())
  assert list.all(resident, fn(name) { list.contains(extension, name) })
  let removed =
    list.filter(extension, fn(name) { !list.contains(resident, name) })
  assert list.all(removed, fn(name) {
    string.starts_with(name, "cap/")
    || list.contains(policy.extension_authority_modules(), name)
  })

  // And the removal is real rather than an equality dressed up as one,
  // and it reaches the capability that does not wear the prefix.
  assert removed != []
  assert list.contains(removed, "ext/memory")
}

/// The resident seam's prelude half is exactly the two vocabulary
/// modules, neither of which carries authority.
///
/// `ext/memory` is the third `ext` module on the jailed seam and is not
/// here: it opens a channel to the broker, and a resident body has no
/// broker between it and the store it would be writing.
pub fn the_resident_prelude_is_the_two_vocabulary_modules_test() {
  assert policy.resident_prelude_modules() == ["ext", "ext/hook"]
}

/// `for_seam` is the selector, and it selects the allowlists above.
pub fn for_seam_selects_the_allowlist_test() {
  assert policy.allowed_imports(policy.for_seam(policy.WorkspaceSeam))
    == policy.allowed_imports(policy.default())
  assert policy.allowed_imports(policy.for_seam(policy.OrchestrationSeam))
    == policy.allowed_imports(policy.orchestration())
  assert policy.allowed_imports(policy.for_seam(policy.ExtensionSeam))
    == policy.allowed_imports(policy.extension())
  assert policy.allowed_imports(policy.for_seam(policy.ResidentSeam))
    == policy.allowed_imports(policy.resident())
}

/// A child program passes under both full-capability program modes.
pub fn an_orchestration_program_passes_its_own_seam_test() {
  let source =
    "import cap/report
import cap/strand
import gleam/list

pub fn main() -> report.Outcome {
  let _ = list.map([1], fn(n) { n })
  report.text(\"orchestrated\")
}
"
  assert is_passed(vet.vet(source, policy.orchestration()))
  assert is_passed(vet.vet(source, policy.default()))
}

// --- Vetted token & bypass-prevention properties ---------------------------

/// A pass carries the parsed module, so downstream need not re-parse.
pub fn vetted_carries_module_test() {
  let source = "import cap/fs\npub fn main() { 1 }\n"
  let assert Passed(vetted) = vet.vet(source, policy())
  let module = vet.vetted_module(vetted)
  assert list.length(module.imports) == 1
}

/// All rule violations are reported in one pass, not one-per-round-trip.
pub fn all_violations_reported_at_once_test() {
  let source =
    "@external(erlang, \"os\", \"cmd\")\nimport gleam/io\nimport shellout\npub fn run(c: String) -> String\n"
  let assert Rejected(rejections) = vet.vet(source, policy())
  // One @external + two forbidden imports.
  assert list.length(rejections) >= 3
}

// --- Policy unit tests ------------------------------------------------------

/// The default cap allowlist is exactly the canonical nine.
pub fn default_cap_modules_test() {
  let p = policy.default()
  let caps = [
    "cap/fs", "cap/proc", "cap/net", "cap/git", "cap/lsp", "cap/report",
    "cap/task", "cap/actor", "cap/kv",
  ]
  assert list.all(caps, fn(m) { policy.contains(p, m) })
  // A cap module outside the nine is not recognised.
  assert !policy.contains(p, "cap/db")
}

/// The default stdlib subset is present and the effectful modules are absent.
pub fn default_stdlib_membership_test() {
  let p = policy.default()
  let allowed = [
    "gleam/list", "gleam/string", "gleam/int", "gleam/result", "gleam/option",
    "gleam/dict", "gleam/json", "gleam/dynamic", "gleam/dynamic/decode",
  ]
  let denied = [
    "gleam/io", "gleam/erlang", "gleam/erlang/os", "gleam/otp/actor",
  ]
  assert list.all(allowed, fn(m) { policy.contains(p, m) })
  assert list.all(denied, fn(m) { !policy.contains(p, m) })
}

/// `new` and `allow` compose a policy; `contains` is byte-identical.
pub fn policy_new_and_allow_test() {
  let p = policy.new(["cap/fs"]) |> policy.allow("cap/db")
  assert policy.contains(p, "cap/fs")
  assert policy.contains(p, "cap/db")
  assert !policy.contains(p, "cap/proc")
  // A one-byte-different name is not a member.
  assert !policy.contains(p, "cap/f")
}

/// A custom policy governs vetting: a module allowed only by the custom policy
/// passes under it and fails under the default.
pub fn custom_policy_governs_vet_test() {
  let source = "import cap/db\npub fn main() { 1 }\n"
  let custom = policy.default() |> policy.allow("cap/db")
  assert is_passed(vet.vet(source, custom))
  assert is_rejected(vet.vet(source, policy.default()))
}

// --- Corpus size floor ------------------------------------------------------

/// Pins the corpus well past the spec's 50-program floor.
pub fn corpus_size_test() {
  let hostile =
    list.flatten([
      forbidden_import_cases(),
      lookalike_import_cases(),
      unparseable_cases(),
    ])
  // Plus the many inline cases in the named tests above; this list alone,
  // combined with those, clears 50 with margin.
  assert list.length(hostile) >= 37
}

// --- the import backstop (M4 triage V-F3) ---------------------------------
//
// Vetting reads `glance`'s AST; the harness compiles with `gleam`. An import
// `glance` did not surface would be one the allowlist was never applied to,
// so a token-stream sweep cross-checks it. These test the sweep itself —
// a scanner that quietly saw nothing would make the check vacuous — and the
// false positive a raw-source scan would have.

pub fn token_imports_sees_every_import_form_test() {
  let source =
    "import cap/fs\n"
    <> "import gleam/list as l\n"
    <> "import gleam/string.{trim}\n"
    <> "import cap/report\n"
    <> "pub fn main() { l.length([]) }\n"
  assert vet.token_imports(source)
    == ["cap/fs", "gleam/list", "gleam/string", "cap/report"]
}

pub fn token_imports_counts_a_repeated_import_twice_test() {
  // A multiset, not a set: the cross-check subtracts occurrences, so a
  // doubled import must be seen twice or the subtraction goes wrong.
  assert vet.token_imports("import cap/fs\nimport cap/fs\n")
    == ["cap/fs", "cap/fs"]
}

pub fn token_imports_ignores_the_word_in_a_string_test() {
  // The V-F1 lesson applied to imports: a raw-source scan would fire on
  // this, rejecting an effect-free program. A string is one token.
  assert vet.token_imports("pub const c = \"import cap/proc\"\n") == []
}

pub fn token_imports_ignores_the_word_in_a_comment_test() {
  assert vet.token_imports("// import cap/proc\npub fn main() { 1 }\n") == []
}

pub fn a_program_naming_an_import_in_a_string_still_passes_test() {
  // The whole point of the false-positive care above: this program reaches
  // nothing, and vetting must not invent a rejection for it.
  let source =
    "import cap/report\n"
    <> "pub fn main() -> report.Outcome {\n"
    <> "  report.text(\"grep for: import cap/proc\")\n"
    <> "}\n"
  let assert Passed(_vetted) = vet.vet(source, policy.default())
}

pub fn the_backstop_stays_silent_on_ordinary_programs_test() {
  // Non-vacuity in the other direction: the sweep and the AST agree on a
  // realistic program, so the cross-check adds no rejections of its own.
  let source =
    "import cap/proc\n"
    <> "import cap/report\n"
    <> "import gleam/int\n"
    <> "import gleam/string as text\n"
    <> "pub fn main() -> report.Outcome {\n"
    <> "  let _ = proc.command([\"/bin/echo\"])\n"
    <> "  report.text(text.trim(int.to_string(1)))\n"
    <> "}\n"
  let assert Passed(_vetted) = vet.vet(source, policy.default())
}

// A real submission repeatedly failed at an inner grouping parenthesis. The
// rejection must identify source syntax and its repair without accepting it.
pub fn grouping_parentheses_report_the_gleam_syntax_test() {
  let source =
    "import gleam/float\npub fn main() { float.to_string((10.0 -. 5.0) /. 5.0) }"
  let assert Rejected([rejection]) = vet.vet(source, policy())
    as "Parenthesized grouping must still be rejected"
  assert rejection.rule == Unparseable
  assert string.contains(rejection.detail, "unexpected token: \"(\"")
  assert string.contains(rejection.detail, "groups expressions with `{ ... }`")
  assert !string.contains(rejection.detail, "LeftParen")
  assert is_passed(vet.vet(
    string.replace(source, "(10.0 -. 5.0)", "{ 10.0 -. 5.0 }"),
    policy(),
  ))
}

pub fn incomplete_source_points_to_eof_test() {
  let source = "pub fn main() {\n"
  let assert Rejected([rejection]) = vet.vet(source, policy())
    as "An incomplete body must be rejected"
  assert rejection.rule == Unparseable
  assert rejection.location == vet.SourcePoint(16)
  assert string.contains(rejection.detail, "ended unexpectedly")
}
