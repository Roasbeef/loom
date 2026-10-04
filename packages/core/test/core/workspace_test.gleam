import core/ids
import core/json as core_json
import core/workspace
import gleam/list
import gleam/result
import gleam/string

pub fn root_and_ordinary_relative_paths_preserve_spelling_test() {
  assert workspace.relative_path(".") == Ok(workspace.root())
  list.each(
    ["a", "src/main.gleam", ".git/HEAD", "space name/é文", "a..b"],
    fn(text) {
      let assert Ok(path) = workspace.relative_path(text)
      assert workspace.path_string(path) == text
    },
  )
}

pub fn posix_windows_drive_unc_and_stream_paths_are_refused_test() {
  list.each(["/work/a", "//server/share"], fn(text) {
    assert workspace.relative_path(text) == Error(workspace.AbsolutePath)
  })
  list.each(
    [
      "C:/work/a",
      "C:relative",
      "C:\\work\\a",
      "\\\\server\\share",
      "src\\a",
      "file:stream",
    ],
    fn(text) {
      assert workspace.relative_path(text) == Error(workspace.PathSeparator)
    },
  )
}

pub fn components_cannot_be_normalized_into_another_path_test() {
  list.each(
    ["a//b", "a/", "./a", "a/.", "a/../b", "..", "../a", "a/.."],
    fn(text) {
      assert workspace.relative_path(text) == Error(workspace.PathComponent)
    },
  )
  assert workspace.relative_path("") == Error(workspace.PathSize)
}

pub fn unicode_path_bound_counts_bytes_not_graphemes_test() {
  let ascii = string.repeat("a", 4096)
  let unicode = string.repeat("é", 2048)
  assert workspace.relative_path(ascii) |> result.is_ok
  assert workspace.relative_path(unicode) |> result.is_ok
  assert workspace.relative_path(ascii <> "a") == Error(workspace.PathSize)
  assert workspace.relative_path(unicode <> "é") == Error(workspace.PathSize)
}

pub fn nul_c0_del_and_c1_controls_are_refused_in_paths_and_steps_test() {
  list.each(
    [
      "\u{0000}",
      "\u{0001}",
      "\t",
      "\n",
      "\r",
      "\u{001f}",
      "\u{007f}",
      "\u{0080}",
      "\u{0085}",
      "\u{009f}",
    ],
    fn(control) {
      assert workspace.relative_path("a" <> control <> "b")
        == Error(workspace.ControlCharacter)
      assert workspace.step("a" <> control <> "b")
        == Error(workspace.ControlCharacter)
    },
  )

  // A multibyte character's continuation byte is not a control codepoint.
  assert workspace.relative_path("é文/\u{00a0}name") |> result.is_ok
  assert workspace.step("é文") |> result.is_ok
}

pub fn selector_names_are_bounded_case_sensitive_administrative_labels_test() {
  let assert Ok(lower) = workspace.selector("executor-1", "loom")
  let assert Ok(upper) = workspace.selector("Executor-1", "loom")
  assert lower != upper
  assert workspace.selector_fields(lower) == #("executor-1", "loom")
  assert workspace.selector(string.repeat("a", 128), "_.-09AZaz")
    |> result.is_ok
  assert workspace.selector(string.repeat("a", 129), "loom")
    == Error(workspace.LabelSize)
  assert workspace.selector("linux", "") == Error(workspace.LabelSize)
  list.each(["a/b", "a\\b", "é", "a b", "a\n", "host:22"], fn(label) {
    assert workspace.selector(label, "loom") == Error(workspace.LabelCharacter)
    assert workspace.selector("linux", label) == Error(workspace.LabelCharacter)
  })
}

pub fn both_epochs_are_positive_bounded_and_part_of_binding_equality_test() {
  let assert Ok(selector) = workspace.selector("linux", "loom")
  let assert Ok(binding) = workspace.registered_binding(selector, 2, 3)
  assert workspace.binding_fields(binding) == #(selector, 2, 3)
  assert workspace.registered_binding(selector, 1, 1) |> result.is_ok
  assert workspace.registered_binding(selector, 2_147_483_647, 2_147_483_647)
    |> result.is_ok
  list.each([-1, 0, 2_147_483_648], fn(epoch) {
    assert workspace.registered_binding(selector, epoch, 1)
      == Error(workspace.EpochRange)
    assert workspace.registered_binding(selector, 1, epoch)
      == Error(workspace.EpochRange)
  })
  assert workspace.registered_binding(selector, 3, 3) != Ok(binding)
  assert workspace.registered_binding(selector, 2, 4) != Ok(binding)
}

pub fn executor_projected_scope_conversion_keeps_both_epoch_positions_test() {
  let uuid = "00000000-0000-7000-8000-000000000001"
  let assert Ok(session) = ids.parse_session_id(uuid)
  let assert Ok(selector) = workspace.selector("linux", "loom")
  let assert Ok(binding) = workspace.registered_binding(selector, 2, 3)
  let assert Ok(scope) =
    workspace.scope_from_fields(uuid, "loom", "linux", 3, 2)
  assert scope == workspace.scope(session, binding)
  assert workspace.scope_fields(scope) == #(session, binding)
  assert workspace.scope_from_fields(uuid, "loom", "linux", 2, 3) != Ok(scope)
  assert workspace.scope_from_fields("bad", "loom", "linux", 3, 2)
    == Error(workspace.InvalidSession)
  assert workspace.scope_from_fields(uuid, "loom", "linux", 0, 2)
    == Error(workspace.EpochRange)
}

pub fn local_selection_and_binding_preserve_existing_path_semantics_test() {
  let local_path = "../checkout/./file\\name"
  assert workspace.LocalDirectory(local_path).path == local_path
  assert workspace.LocalBinding(local_path).path == local_path
  let assert Ok(selector) = workspace.selector("linux", "loom")
  assert workspace.RegisteredWorkspace(selector).selector == selector
  let assert Ok(binding) = workspace.registered_binding(selector, 1, 1)
  assert workspace.Registered(binding).binding == binding
}

pub fn external_step_bound_preserves_generated_job_hook_build_and_uuid_names_test() {
  list.each(
    [
      "00000000-0000-7000-8000-000000000001",
      "job/j1",
      "hook:before-tool/fs_read",
      "turn-4-build",
      "worktree-observation",
      string.repeat("a", 1024),
      string.repeat("é", 512),
    ],
    fn(name) {
      let assert Ok(step) = workspace.step(name)
      assert workspace.step_string(step) == name
    },
  )
  assert workspace.step("") == Error(workspace.StepSize)
  assert workspace.step(string.repeat("a", 1025)) == Error(workspace.StepSize)
  assert workspace.step(string.repeat("é", 513)) == Error(workspace.StepSize)
}

pub fn catalogue_keys_preserve_local_identity_and_validate_registered_labels_test() {
  let assert Ok(selected) = workspace.selector("linux-1", "project")
    as "selector is valid"
  let assert Ok(bound) = workspace.registered_binding(selected, 2, 3)
    as "epochs are valid"
  assert workspace.binding_key(workspace.Registered(bound))
    == workspace.RegisteredKey(selected)
  assert workspace.key_string(workspace.RegisteredKey(selected))
    == "registered:linux-1:project"
  assert workspace.decode_key("registered:linux-1:project")
    == Ok(workspace.RegisteredKey(selected))
  assert workspace.decode_key("/registered:linux-1:project")
    == Ok(workspace.LocalKey("/registered:linux-1:project"))
  list.each(
    [
      "registered::project",
      "registered:linux:project:extra",
      "registered:linux:bad/name",
      "relative",
      "",
    ],
    fn(text) {
      assert workspace.decode_key(text) |> result.is_error
    },
  )
}

pub fn binding_codec_roundtrips_and_refuses_extra_duplicate_or_invalid_authority_test() {
  let assert Ok(selected) = workspace.selector("linux", "project")
    as "selector is valid"
  let assert Ok(bound) = workspace.registered_binding(selected, 2, 3)
    as "epochs are valid"
  list.each(
    [workspace.LocalBinding("/work"), workspace.Registered(bound)],
    fn(binding) {
      assert workspace.decode_binding(workspace.encode_binding(binding))
        == Ok(binding)
    },
  )
  let assert core_json.Object(fields) =
    workspace.encode_binding(workspace.Registered(bound))
    as "registered codec emits an object"
  assert workspace.decode_binding(
      core_json.Object([#("root", core_json.String("/host")), ..fields]),
    )
    == Error(workspace.BindingShape)
  assert workspace.decode_binding(
      core_json.Object([#("kind", core_json.String("registered")), ..fields]),
    )
    == Error(workspace.BindingShape)
  let invalid =
    list.map(fields, fn(field) {
      case field.0 {
        "session_epoch" -> #("session_epoch", core_json.Int(0))
        _ -> field
      }
    })
  assert workspace.decode_binding(core_json.Object(invalid))
    == Error(workspace.EpochRange)
  assert workspace.decode_binding(core_json.Null)
    == Error(workspace.BindingShape)
}
