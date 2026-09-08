import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui/daemon/protocol
import tui/workspace

pub fn workspace_and_cached_branch_name_test() {
  assert workspace.session_name(workspace.Context("/work/loom", Some("main")))
    == "loom · main"
  assert workspace.session_name(workspace.Context("/work/loom", None)) == "loom"
  assert workspace.session_name(workspace.Context(
      "/work/loom",
      Some("fix/start"),
    ))
    == "loom · fix/start"
  assert workspace.session_name(workspace.Context("/", None)) == "New session"
}

pub fn session_names_normalize_terminal_controls_test() {
  assert workspace.session_name(workspace.Context(
      "/work/\u{1b}[31mloom\u{1b}[0m",
      Some("main\nnext"),
    ))
    == "loom · main next"
}

pub fn unicode_names_fit_the_create_wire_limit_test() {
  list.each(
    [
      workspace.Context("/work/" <> string.repeat("é", 200), Some("main")),
      workspace.Context("/work/loom", Some(string.repeat("🧵", 100))),
      workspace.Context("/work/" <> "a" <> string.repeat("\u{301}", 200), None),
    ],
    fn(context) {
      let name = workspace.session_name(context)
      assert name != ""
      assert string.byte_size(name) <= 256
      let assert Ok(_) =
        protocol.encode(
          1,
          protocol.CreateSession("key", "/work", name, ""),
          protocol.Epoch("epoch"),
        )
        as "a generated name must be admitted by the production control codec"
    },
  )
  assert workspace.session_name(workspace.Context(
      "/work/" <> string.repeat("é", 200),
      None,
    ))
    == string.repeat("é", 128)
}
