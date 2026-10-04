//// The layout memory: what is stored, how a bad file is read, and how two
//// terminals share it.
////
//// The file is a small JSON document of layout words under workspace
//// digests. These tests pin four things. What it holds is exactly the key
//// and the rail word, so no transcript text or path can reach it. Reading is
//// total, so a corrupt, oversized, foreign-version, foreign-owner or
//// group-readable file is the default layout and the terminal still starts.
//// Writing is atomic and keeps other workspaces, so two terminals never tear
//// the file or erase each other's workspaces. And the model queues a save
//// only when the layout changed, never from a replay.

import etui/backend
import filepath
import frame_scene
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as host_bootstrap
import simplifile
import tui/effect
import tui/layout_memory.{Layout, Target}
import tui/layout_save
import tui/model.{type Model, Model, View}
import tui_test/stepping

// A directory of this test's own, removed first so a run never reads the
// last one's file.
fn scratch(name: String) -> String {
  let dir =
    "/tmp/loom-layout-test-"
    <> int.to_string(host_bootstrap.system_time_ms())
    <> "-"
    <> name
  let _ = simplifile.delete_all([dir])
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "the scratch directory is made"
  dir
}

fn shown() -> layout_memory.Layout {
  Layout(rail: Some(layout_memory.RailShown))
}

fn hidden() -> layout_memory.Layout {
  Layout(rail: Some(layout_memory.RailHidden))
}

fn key(seed: String) -> String {
  layout_memory.workspace_key(seed)
}

// ------------------------------------------------------------- the key

pub fn the_key_is_the_workspace_digest_the_web_view_uses_test() {
  // SHA-256 of "abc" is the standard test vector.
  assert layout_memory.workspace_key("abc")
    == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  let found = layout_memory.workspace_key("/Users/operator/code/pi-gui")
  assert string.length(found) == 64
  assert found == string.lowercase(found)
  assert !string.contains(found, "pi-gui") as "the path is not in its key"
}

// ------------------------------------------------------- what is stored

pub fn only_the_key_and_the_rail_word_are_stored_test() {
  let memory =
    layout_memory.empty()
    |> layout_memory.remember(key("a"), shown())
    |> layout_memory.remember(key("b"), layout_memory.default())
  assert layout_memory.encode(memory)
    == "{\"version\":1,\"workspaces\":[{\"key\":\""
    <> key("b")
    <> "\"},{\"key\":\""
    <> key("a")
    <> "\",\"rail\":\"shown\"}]}"
    as "the document is the version, and a key with a word or none"
  assert layout_memory.decode(layout_memory.encode(memory)) == memory
}

// ----------------------------------------------------- reading is total

pub fn undecodable_text_is_the_empty_memory_test() {
  let bad = [
    "",
    "not json",
    "[]",
    "null",
    "{}",
    "{\"version\":1}",
    "{\"version\":1,\"workspaces\":{}}",
    "{\"version\":1,\"workspaces\":\"x\"}",
    "{\"version\":2,\"workspaces\":[]}",
    "{\"version\":\"1\",\"workspaces\":[]}",
    "{\"version\":1,\"workspaces\":[",
    string.repeat("[", 5000),
  ]
  list.each(bad, fn(text) {
    assert layout_memory.decode(text) == layout_memory.empty()
  })
}

pub fn a_bad_entry_is_dropped_and_its_neighbours_kept_test() {
  let good = key("good")
  let text =
    "{\"version\":1,\"workspaces\":[1,null,\"x\",[],{},{\"key\":7},"
    <> "{\"key\":\"/etc/passwd\"},{\"key\":\"ABCDEF\"},"
    <> "{\"key\":\""
    <> good
    <> "\",\"rail\":\"docked-left\"},"
    <> "{\"key\":\""
    <> good
    <> "\",\"rail\":\"shown\"}]}"
  let memory = layout_memory.decode(text)
  assert memory.entries == [layout_memory.Entry(good, layout_memory.default())]
    as "an unknown word is the default, and a repeated key keeps its first"
}

pub fn an_unknown_field_and_a_future_word_do_not_discard_the_file_test() {
  let a = key("a")
  let text =
    "{\"version\":1,\"extra\":true,\"workspaces\":[{\"key\":\""
    <> a
    <> "\",\"rail\":\"hidden\",\"tab\":\"trace\",\"todo\":\"open\"}]}"
  assert layout_memory.lookup(layout_memory.decode(text), a) == hidden()
}

pub fn a_file_with_too_many_entries_is_cut_test() {
  let entries =
    numbers(100)
    |> list.map(fn(n) {
      "{\"key\":\"" <> key(int.to_string(n)) <> "\",\"rail\":\"shown\"}"
    })
    |> string.join(",")
  let memory =
    layout_memory.decode("{\"version\":1,\"workspaces\":[" <> entries <> "]}")
  assert list.length(memory.entries) == layout_memory.max_workspaces
  assert list.first(memory.entries)
    == Ok(layout_memory.Entry(key("1"), shown()))
    as "the first, most recent, entries are the ones kept"
}

// -------------------------------------------------------- the file itself

pub fn an_unreadable_file_is_the_empty_memory_test() {
  let dir = scratch("unreadable")
  let path = filepath.join(dir, "layout.json")

  // Missing.
  assert layout_memory.load(path) == layout_memory.empty()

  // Corrupt, with the private mode the file would have.
  let assert Ok(Nil) = simplifile.write(path, "{\"version\":1,\"workspaces\":[")
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o600)
  assert layout_memory.load(path) == layout_memory.empty()

  // A well-formed file that another user could read is not trusted either.
  let assert Ok(Nil) =
    simplifile.write(
      path,
      layout_memory.encode(layout_memory.remember(
        layout_memory.empty(),
        key("a"),
        shown(),
      )),
    )
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o644)
  assert layout_memory.load(path) == layout_memory.empty()
    as "a group- or world-readable file is refused"
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o600)
  assert layout_memory.lookup(layout_memory.load(path), key("a")) == shown()

  // Larger than any file this release writes.
  let assert Ok(Nil) = simplifile.write(path, string.repeat(" ", 70_000))
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o600)
  assert layout_memory.load(path) == layout_memory.empty()

  // A directory where the file should be.
  let in_the_way = filepath.join(dir, "directory")
  let assert Ok(Nil) = simplifile.create_directory_all(in_the_way)
  assert layout_memory.load(in_the_way) == layout_memory.empty()
  let _ = simplifile.delete_all([dir])
}

pub fn a_save_makes_a_private_directory_and_file_test() {
  let dir = scratch("private")
  let path = filepath.join(filepath.join(dir, "tui"), "layout.json")
  let assert Ok(Nil) = layout_memory.save(path, key("a"), shown())
  let assert Ok(directory) = simplifile.file_info(filepath.directory_name(path))
  assert simplifile.file_info_permissions_octal(directory) == 0o700
  let assert Ok(file) = simplifile.file_info(path)
  assert simplifile.file_info_permissions_octal(file) == 0o600
  assert layout_memory.lookup(layout_memory.load(path), key("a")) == shown()
  let _ = simplifile.delete_all([dir])
}

pub fn a_save_over_a_corrupt_file_repairs_it_test() {
  let dir = scratch("repair")
  let path = filepath.join(dir, "layout.json")
  let assert Ok(Nil) = simplifile.write(path, "garbage")
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o600)
  let assert Ok(Nil) = layout_memory.save(path, key("a"), shown())
  assert layout_memory.lookup(layout_memory.load(path), key("a")) == shown()
  let _ = simplifile.delete_all([dir])
}

// ------------------------------------------------------------ two clients

pub fn two_clients_on_different_workspaces_keep_both_test() {
  let dir = scratch("two-workspaces")
  let path = filepath.join(dir, "layout.json")

  // The first client read the file when it launched, found it empty, and
  // saves long after the second has written its own workspace. It saves into
  // the file as it is now, not the file it launched with.
  let launched = layout_memory.load(path)
  assert launched == layout_memory.empty()
  let assert Ok(Nil) = layout_memory.save(path, key("second"), hidden())
  let assert Ok(Nil) = layout_memory.save(path, key("first"), shown())
  let memory = layout_memory.load(path)
  assert layout_memory.lookup(memory, key("first")) == shown()
  assert layout_memory.lookup(memory, key("second")) == hidden()
  let _ = simplifile.delete_all([dir])
}

pub fn two_clients_on_one_workspace_last_change_wins_test() {
  let dir = scratch("one-workspace")
  let path = filepath.join(dir, "layout.json")
  let assert Ok(Nil) = layout_memory.save(path, key("same"), shown())
  let assert Ok(Nil) = layout_memory.save(path, key("same"), hidden())
  let memory = layout_memory.load(path)
  assert memory.entries == [layout_memory.Entry(key("same"), hidden())]
    as "one entry, holding the later change"

  // Neither client sees the other's change until it launches again: a model
  // that applied the first layout at launch still draws it.
  let model =
    layout_save.apply(
      frame_scene.model(),
      Target(path:, key: key("same"), saved: shown()),
    )
  assert model.view.agent_rail_visible
  let _ = simplifile.delete_all([dir])
}

pub fn the_file_is_capped_most_recent_first_test() {
  let dir = scratch("cap")
  let path = filepath.join(dir, "layout.json")
  list.each(numbers(70), fn(n) {
    let assert Ok(Nil) =
      layout_memory.save(path, key(int.to_string(n)), shown())
  })
  let memory = layout_memory.load(path)
  assert list.length(memory.entries) == layout_memory.max_workspaces
  assert list.first(memory.entries)
    == Ok(layout_memory.Entry(key("70"), shown()))
  assert layout_memory.lookup(memory, key("1")) == layout_memory.default()
    as "the least recently changed are the ones dropped"
  let _ = simplifile.delete_all([dir])
}

// ------------------------------------------------------- the model

fn target(path: String, saved: layout_memory.Layout) -> layout_memory.Target {
  Target(path:, key: key("/work/loom"), saved:)
}

fn with_target(base: Model, found: layout_memory.Target) -> Model {
  layout_save.apply(base, found)
}

fn saves(effects: List(effect.Effect)) -> List(effect.Effect) {
  list.filter(effects, fn(requested) {
    case requested {
      effect.SaveLayout(..) -> True
      _ -> False
    }
  })
}

pub fn a_remembered_rail_is_applied_at_launch_test() {
  let model =
    with_target(frame_scene.model(), target("/x/layout.json", shown()))
  assert model.view.agent_rail_visible
  let model =
    with_target(frame_scene.model(), target("/x/layout.json", hidden()))
  assert !model.view.agent_rail_visible
  let model =
    with_target(
      frame_scene.model(),
      target("/x/layout.json", layout_memory.default()),
    )
  assert !model.view.agent_rail_visible
}

pub fn toggling_the_rail_queues_one_save_and_nothing_else_does_test() {
  let path = "/x/layout.json"
  let model =
    with_target(frame_scene.model(), target(path, layout_memory.default()))

  // A launch, a tick and a keystroke change no layout, so nothing is saved.
  let #(model, effects) = stepping.step(backend.Resize(120, 40), model)
  assert saves(effects) == []
  let #(model, effects) = stepping.step(backend.Tick, model)
  assert saves(effects) == []
  let #(model, effects) = stepping.step(backend.KeyPress("x"), model)
  assert saves(effects) == []

  // Shift+Tab shows the rail: one save, naming the file, the key and the
  // layout.
  let #(model, effects) = stepping.step(backend.KeyPress("backtab"), model)
  assert saves(effects) == [effect.SaveLayout(path, key("/work/loom"), shown())]
  let #(model, effects) = stepping.step(backend.Tick, model)
  assert saves(effects) == [] as "the same layout is not saved twice"

  // Hiding it again is a change, and a remembered choice: the file says so.
  let #(_, effects) = stepping.step(backend.KeyPress("backtab"), model)
  assert saves(effects)
    == [effect.SaveLayout(path, key("/work/loom"), hidden())]
}

pub fn a_terminal_with_no_target_reads_and_writes_nothing_test() {
  let model = frame_scene.model()
  assert model.view.layout_target == None
  let #(model, effects) = stepping.step(backend.KeyPress("backtab"), model)
  assert model.view.agent_rail_visible
  assert saves(effects) == []
    as "a replay or a test keeps no layout, whatever it toggles"
}

pub fn the_launcher_reads_the_file_under_the_state_root_test() {
  let dir = scratch("launch")
  let state = dir
  let path = filepath.join(filepath.join(state, "tui"), "layout.json")
  let base = frame_scene.model()
  let workspace_key = layout_memory.workspace_key(base.view.workspace.path)
  let assert Ok(Nil) = layout_memory.save(path, workspace_key, shown())

  // The workspace's own entry applies.
  let model = layout_save.remember_launch(base, state)
  assert model.view.agent_rail_visible
  assert model.view.layout_target
    == Some(Target(path:, key: workspace_key, saved: shown()))
  // A corrupt file starts the terminal with the defaults.
  let assert Ok(Nil) = simplifile.write(path, "}{")
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o600)
  let model = layout_save.remember_launch(base, state)
  assert !model.view.agent_rail_visible
  let _ = simplifile.delete_all([dir])
}

// The numbers from one to `last`.

fn numbers(last: Int) -> List(Int) {
  int.range(from: 1, to: last + 1, with: [], run: fn(all, n) { [n, ..all] })
  |> list.reverse
}
