import gleam/string
import tui/command
import tui/protocol

pub fn add_directory_defaults_to_read_and_keeps_spaces_test() {
  assert command.parse("/add-dir /work/shared files")
    == command.AddDirectory("/work/shared files", "read")
  assert command.parse("/add-dir --write ../sibling")
    == command.AddDirectory("../sibling", "write")
  assert command.parse("/add-write-dir /work/shared files")
    == command.AddDirectory("/work/shared files", "write")
  assert command.parse("/add-write-dir")
    == command.MissingArgument("add-write-dir")
  assert command.parse("/add-dir") == command.MissingArgument("add-dir")
  assert command.parse("/add-dir --write") == command.MissingArgument("add-dir")
}

pub fn add_directory_is_session_scoped_on_the_wire_test() {
  let frame = protocol.add_directory(7, "/work/shared", "read")
  assert string.contains(frame, "add_directory")
  assert !string.contains(frame, "strand")
  assert string.contains(frame, "\"access\":\"read\"")
}
