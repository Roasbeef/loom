import gleam/bit_array
import gleam/string
import mcp/name

// The injected digest stub: lowercase hex over the original's UTF-8
// bytes. Injective over full strings, deliberately weak in its first 8
// characters (`mangle` uses only those), which is exactly what the
// engineered near-miss cases below need. Production injects SHA-256.
fn stub_digest(text: String) -> String {
  bit_array.base16_encode(bit_array.from_string(text))
  |> string.lowercase
}

// The suffix `mangle` appends: the first 8 characters of the digest.
fn tag8(text: String) -> String {
  string.slice(stub_digest(text), 0, 8)
}

fn mangle(text: String) -> String {
  name.mangle(text, stub_digest)
}

fn label(text: String) -> String {
  name.mangle_label(text, stub_digest)
}

// --- untouched names ---------------------------------------------------------

pub fn snake_case_survives_untagged_test() {
  assert mangle("create_issue") == "create_issue"
}

pub fn main_is_not_reserved_test() {
  assert mangle("main") == "main"
}

pub fn options_is_a_fine_function_name_test() {
  assert mangle("options") == "options"
}

pub fn short_alnum_name_survives_test() {
  assert mangle("get2") == "get2"
}

// --- case folding ------------------------------------------------------------

pub fn camel_case_gains_underscores_and_tag_test() {
  assert mangle("createIssue") == "create_issue_" <> tag8("createIssue")
}

pub fn punctuation_becomes_underscores_test() {
  assert mangle("Create-Issue!") == "create_issue_" <> tag8("Create-Issue!")
}

pub fn uppercase_run_does_not_stutter_test() {
  assert mangle("HTTPServer") == "httpserver_" <> tag8("HTTPServer")
}

pub fn digit_then_uppercase_splits_test() {
  assert mangle("getV2Data") == "get_v2_data_" <> tag8("getV2Data")
}

// Names differing only in case must never fold together: each changed
// name carries a digest of its own original.
pub fn case_only_difference_stays_distinct_test() {
  let folded = mangle("Foo")
  assert folded == "foo_" <> tag8("Foo")
  assert folded != mangle("foo")
  assert mangle("foo") == "foo"
}

// --- names with nothing to keep ----------------------------------------------

pub fn non_ascii_name_is_fronted_and_tagged_test() {
  assert mangle("名前") == "t_" <> tag8("名前")
  assert mangle("名前") == "t_e5908de5"
}

pub fn empty_name_is_fronted_test() {
  assert mangle("") == "t_"
}

pub fn digit_led_name_is_fronted_test() {
  assert mangle("123abc") == "t_123abc_" <> tag8("123abc")
}

pub fn underscore_edges_are_trimmed_test() {
  assert mangle("_tool_") == "tool_" <> tag8("_tool_")
}

pub fn underscore_runs_collapse_test() {
  assert mangle("a--b") == "a_b_" <> tag8("a--b")
}

// --- keywords ------------------------------------------------------------

pub fn keyword_fn_is_guarded_test() {
  assert mangle("fn") == "fn_" <> tag8("fn")
}

pub fn keyword_import_is_guarded_test() {
  assert mangle("import") == "import_" <> tag8("import")
}

pub fn keyword_type_is_guarded_test() {
  assert mangle("type") == "type_" <> tag8("type")
}

pub fn keyword_use_is_guarded_test() {
  assert mangle("use") == "use_" <> tag8("use")
}

// --- the label reserved set --------------------------------------------------

// `options` is the label every façade spends on its optional-parameters
// argument, so as a *label* it is reserved even though it is no keyword.
pub fn options_label_is_reserved_test() {
  assert label("options") == "options_" <> tag8("options")
}

pub fn ordinary_label_matches_mangle_test() {
  assert label("issueNumber") == mangle("issueNumber")
}

// --- length ------------------------------------------------------------------

pub fn long_name_is_clipped_then_tagged_test() {
  let long = string.repeat("a", 200)
  let mangled = mangle(long)
  assert mangled == string.repeat("a", 32) <> "_" <> tag8(long)
  assert string.length(mangled) == 41
}

pub fn boundary_length_is_untagged_test() {
  let exactly = string.repeat("a", 32)
  assert mangle(exactly) == exactly
}

pub fn one_past_boundary_is_tagged_test() {
  let long = string.repeat("a", 33)
  assert mangle(long) == string.repeat("a", 32) <> "_" <> tag8(long)
}

// --- collisions ---------------------------------------------------------

pub fn distinct_mangles_report_no_collision_test() {
  assert name.first_collision([#("a", "a"), #("b", "b"), #("c", "c")])
    == Ok(Nil)
}

pub fn byte_identical_originals_collide_test() {
  assert name.first_collision([#("dup", "dup"), #("dup", "dup")])
    == Error(#("dup", "dup"))
}

// An engineered digest near-miss: same flattened base, same first 8
// digest characters (the stub hexes the leading bytes, which the two
// originals share), so the full mangled names coincide.
pub fn engineered_near_miss_collides_test() {
  let first = mangle("aaaa!")
  let second = mangle("aaaa?")
  assert first == second
  assert name.first_collision([#("aaaa!", first), #("aaaa?", second)])
    == Error(#("aaaa!", "aaaa?"))
}

pub fn collision_names_the_earliest_pair_test() {
  assert name.first_collision([#("x", "same"), #("y", "other"), #("z", "same")])
    == Error(#("x", "z"))
}
