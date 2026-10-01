//// R15 (state first) and R16 (qualified domain call): a positive and a
//// negative case for every clause, because a rule that cannot fail reads as
//// coverage and provides none.

import glance
import gleam/list
import gleam/string
import lint
import lint/finding.{type Finding, type Rule}
import lint/policy
import lint/qualified
import lint/scan
import lint/state_first
import simplifile

// --- helpers ----------------------------------------------------------------

fn found(code: String, rule: Rule) -> List(Finding) {
  lint.check("t.gleam", code, policy.default())
  |> list.filter(fn(finding) { finding.rule == rule })
}

fn state_first_details(code: String) -> List(String) {
  found(code, finding.StateFirst)
  |> list.map(fn(finding) { finding.detail })
}

fn qualified_details(code: String) -> List(String) {
  found(code, finding.QualifiedDomainCall)
  |> list.map(fn(finding) { finding.detail })
}

// --- R15: the late type is reported -------------------------------------------

pub fn late_state_after_a_function_fails_test() {
  let code =
    "pub fn update(state: State, msg: Msg) -> State {
  state
}

pub type State {
  State(n: Int)
}

pub type Msg {
  Tick
}
"
  let details = state_first_details(code)
  assert list.length(details) == 2
  let text = string.join(details, "\n")
  assert string.contains(text, "`State`")
  assert string.contains(text, "`Msg`")
  assert string.contains(text, "`update`")
}

pub fn early_state_before_the_first_function_passes_test() {
  let code =
    "pub type State {
  State(n: Int)
}

pub type Msg {
  Tick
}

pub fn update(state: State, msg: Msg) -> State {
  state
}
"
  assert state_first_details(code) == []
}

pub fn late_type_is_reported_against_the_first_function_test() {
  let code =
    "fn helper() -> Int {
  1
}

pub fn step(state: State) -> State {
  state
}

pub type State {
  State
}
"
  let assert [detail] = state_first_details(code)
    as "one late type, one finding"
  assert string.contains(detail, "`helper`")
  assert string.contains(detail, "`step`")
}

pub fn a_type_in_a_nested_type_argument_counts_test() {
  let code =
    "import gleam/option.{type Option}

pub fn transition(
  input: Option(#(Int, fn(Inner) -> Int)),
) -> Result(Outer(List(Option(Deep))), Nil) {
  Error(Nil)
}

pub type Inner {
  Inner
}

pub type Outer(a) {
  Outer(a)
}

pub type Deep {
  Deep
}
"
  let text = string.join(state_first_details(code), "\n")
  assert string.contains(text, "`Inner`")
  assert string.contains(text, "`Outer`")
  assert string.contains(text, "`Deep`")
}

pub fn a_type_alias_in_the_signature_counts_test() {
  let code =
    "pub fn update(state: Model) -> Model {
  state
}

pub type Model =
  Int
"
  assert list.length(state_first_details(code)) == 1
}

pub fn private_step_functions_count_test() {
  let code =
    "fn handle_message(state: State) -> State {
  state
}

type State {
  State
}
"
  assert list.length(state_first_details(code)) == 1
}

// --- R15: the silent cases ------------------------------------------------------

pub fn a_module_without_a_step_function_is_silent_test() {
  let code =
    "pub fn render(value: Shape) -> String {
  \"\"
}

pub type Shape {
  Shape
}
"
  assert state_first_details(code) == []
}

pub fn a_type_the_step_function_does_not_name_is_silent_test() {
  let code =
    "pub fn update(state: State) -> State {
  state
}

pub type State {
  State
}

pub type Unrelated {
  Unrelated
}
"
  let details = state_first_details(code)
  assert list.length(details) == 1
  assert !string.contains(string.join(details, ""), "Unrelated")
}

pub fn a_constant_after_the_first_function_is_silent_test() {
  let code =
    "pub type State {
  State
}

pub fn update(state: State) -> State {
  state
}

pub const limit = 3
"
  assert state_first_details(code) == []
}

pub fn a_qualified_type_is_not_a_local_type_test() {
  let code =
    "import other

pub fn update(state: other.State) -> other.State {
  state
}

pub type State {
  State
}
"
  assert state_first_details(code) == []
}

pub fn a_candidate_name_outside_the_table_is_silent_test() {
  let code =
    "pub fn reduce(state: State) -> State {
  state
}

pub type State {
  State
}
"
  assert state_first_details(code) == []
  let assert Ok(module) = glance.module(code) as "fixture parses"
  assert list.length(state_first.findings_named(module, ["reduce"])) == 1
}

pub fn the_name_table_is_data_test() {
  assert state_first.step_names()
    == ["update", "step", "transition", "handle_message", "handle"]
}

// --- R16: what is flagged -------------------------------------------------------

pub fn a_loom_value_import_is_flagged_test() {
  let details =
    qualified_details(
      "import session_view/approval.{project}

pub fn go() {
  project(1)
}
",
    )
  assert list.length(details) == 1
  let text = string.join(details, "")
  assert string.contains(text, "import `session_view/approval`")
  assert string.contains(text, "`approval.project`")
}

pub fn the_alias_is_the_qualifier_in_the_advice_test() {
  let text =
    qualified_details(
      "import tools/fs.{read} as files

pub fn go() {
  read(1)
}
",
    )
    |> string.join("")
  assert string.contains(text, "`files.read`")
}

pub fn a_loom_constant_import_is_flagged_test() {
  let details = qualified_details("import tui/limits.{max_bytes}\n")
  assert list.length(details) == 1
}

pub fn every_lowercase_name_in_the_list_is_flagged_test() {
  let details = qualified_details("import core/json.{decode, encode}\n")
  assert list.length(details) == 2
}

// --- R16: what is not -----------------------------------------------------------

pub fn a_stdlib_import_is_silent_test() {
  assert qualified_details("import gleam/list.{map}\n") == []
}

pub fn a_third_party_import_is_silent_test() {
  assert qualified_details("import gleam_mcp/json.{decode}\n") == []
}

pub fn a_type_import_is_silent_test() {
  assert qualified_details("import session_view/approval.{type Approval}\n")
    == []
}

pub fn a_constructor_import_is_silent_test() {
  assert qualified_details("import session_view/approval.{Pending}\n") == []
}

pub fn a_qualified_loom_import_is_silent_test() {
  assert qualified_details("import session_view/approval\n") == []
}

pub fn an_allow_listed_name_is_silent_test() {
  let code = "import tools/tool.{or_outcome, other}\n"
  let assert Ok(module) = glance.module(code) as "fixture parses"
  let allow = [#("tools/tool", "or_outcome")]
  let flagged = qualified.findings_allowing(module, allow)
  assert list.map(flagged, fn(raw: scan.Raw) { raw.function }) == ["other"]
  assert list.length(qualified.findings_allowing(module, [])) == 2
}

// --- R16: the root table matches the tree ---------------------------------------

/// The first path segment every `src/` in `packages/` defines: each
/// directory, and each top-level `.gleam` file less its extension. Foreign
/// files (`*_ffi.erl`, a stylesheet) are not modules and give no root.
fn roots_on_disk() -> List(String) {
  let assert Ok(packages) = simplifile.read_directory("../")
    as "packages/ is readable from packages/lint"
  packages
  |> list.flat_map(fn(package) {
    case simplifile.read_directory("../" <> package <> "/src") {
      Ok(entries) -> list.filter_map(entries, root_of(package, _))
      Error(_) -> []
    }
  })
  |> list.unique
  |> list.sort(string.compare)
}

fn root_of(package: String, entry: String) -> Result(String, Nil) {
  let path = "../" <> package <> "/src/" <> entry
  case simplifile.is_directory(path), string.ends_with(entry, ".gleam") {
    Ok(True), _ -> Ok(entry)
    _, True -> Ok(string.drop_end(entry, 6))
    _, False -> Error(Nil)
  }
}

pub fn loom_roots_match_the_source_tree_test() {
  assert list.sort(qualified.loom_roots(), string.compare) == roots_on_disk()
}
