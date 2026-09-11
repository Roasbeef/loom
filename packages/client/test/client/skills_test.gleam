//// The shared catalogue preserves prompt attribution and bounds wire pages.

import client/daemon/transfer
import client/protocol
import client/skill_tool
import client/skills
import core/message
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import host/skill
import simplifile
import tui/skills as terminal_skills

fn root() -> String {
  let assert Ok(root) =
    bootstrap.absolute_path(
      "build/skill-pages-"
      <> int.to_string(bootstrap.system_time_ms())
      <> "-"
      <> int.to_string(int.random(1_000_000_000)),
    )
    as "each catalogue fixture owns an absolute path"
  root
}

fn write_skill(root: String, name: String, description: String, flags: String) {
  assert simplifile.create_directory_all(root <> "/" <> name) == Ok(Nil)
  assert simplifile.write(
      root <> "/" <> name <> "/SKILL.md",
      "---\nname: "
        <> name
        <> "\ndescription: "
        <> description
        <> "\n"
        <> flags
        <> "---\nInstructions for $ARGUMENTS.\n",
    )
    == Ok(Nil)
}

pub fn skill_pages_round_trip_without_omitting_or_duplicating_commands_test() {
  let root = root()
  int.range(from: 0, to: 15, with: Nil, run: fn(_, index) {
    write_skill(
      root,
      "sample-" <> int.to_string(index),
      string.repeat("🦋", 1024),
      "",
    )
  })
  let catalogue = skill.discover([root])
  let rows = collect(catalogue, 0, [])
  let assert Ok(first) = skills.page(catalogue, 0) as "the first page exists"
  let assert Ok(decoded) = terminal_skills.decode(first)
    as "both endpoints agree on the page shape"
  assert decoded.next != None
    as "this valid catalogue crosses the byte page boundary"
  assert list.map(rows, fn(row) { row.command })
    == list.map(skill.entries(catalogue), fn(entry) { "/" <> entry.name })
  assert skills.page(catalogue, -1) == Error("invalid skills offset")
  assert skills.page(catalogue, 17) == Error("invalid skills offset")
  assert simplifile.delete(root) == Ok(Nil)
}

fn collect(catalogue, offset, rows) {
  let assert Ok(board) = skills.page(catalogue, offset)
    as "the next cursor names an available page"
  let envelope =
    protocol.EventEnvelope(
      Some(7),
      None,
      protocol.SnapshotEvent(protocol.SkillsSnapshot(board)),
    )
  let assert Ok(_) =
    transfer.encoded_size(protocol.event_value(envelope), 65_536)
    as "the complete envelope fits the actual wire budget"
  assert protocol.decode_event(protocol.encode_event(envelope)) == Ok(envelope)
  let assert Ok(page) = terminal_skills.decode(board)
    as "the terminal accepts each bounded page"
  let rows = list.append(rows, page.commands)
  case page.next {
    None -> rows
    Some(next) -> collect(catalogue, next, rows)
  }
}

pub fn expansion_preserves_other_blocks_and_unchanged_messages_test() {
  let root = root()
  write_skill(root, "sample", "Description", "")
  let catalogue = skill.discover([root])
  list.each(["/sample\n", "/sample\n ", "/sample\t", " /sample\r\n"], fn(text) {
    let assert Ok(message.UserMessage(
      content: [message.UserText(expanded, _)],
      ..,
    )) =
      skills.expand_message(
        catalogue,
        message.UserMessage([message.UserText(text, None)], 42, None),
      )
      as "command-only pasted whitespace still selects the loaded skill"
    assert string.contains(expanded, "Instructions for .")
  })
  let image = message.UserImage("aW1hZ2U=", "image/png")
  let trailing = message.UserText("untouched", Some("opaque-signature"))
  let original =
    message.UserMessage(
      [
        message.UserText("/sample the queue", None),
        image,
        trailing,
      ],
      42,
      None,
    )
  let assert Ok(message.UserMessage(content:, timestamp: 42, origin: None)) =
    skills.expand_message(catalogue, original)
    as "the expanded message keeps its attribution and timestamp"
  let assert [message.UserText(text:, ..), ..rest] = content
    as "the first text block owns invocation"
  assert string.contains(text, "Instructions for the queue.")
  assert rest == [image, trailing]
  let unchanged =
    message.UserMessage(
      [message.UserText("ordinary input", Some("signature")), image],
      43,
      None,
    )
  assert skills.expand_message(catalogue, unchanged) == Ok(unchanged)
  assert simplifile.delete(root) == Ok(Nil)
}

pub fn invocation_flags_separate_user_and_model_catalogues_test() {
  let root = root()
  write_skill(
    root,
    "manual",
    "Explicit description",
    "disable-model-invocation: true\n",
  )
  write_skill(
    root,
    "automatic",
    "Automatic description",
    "user-invocable: false\n",
  )
  let catalogue = skill.discover([root])
  let assert [tool] = skill_tool.tools(catalogue)
    as "automatic skills contribute one load tool"
  assert string.contains(tool.description, "Automatic description")
  assert !string.contains(tool.description, "Explicit description")
  assert !string.contains(tool.description, "Instructions for")
  let assert Ok(board) = skills.page(catalogue, 0)
    as "user metadata is available"
  let assert Ok(page) = terminal_skills.decode(board)
    as "the terminal decodes metadata"
  assert list.map(page.commands, fn(row) { row.command }) == ["/manual"]
  assert skills.expand_message(
      catalogue,
      message.UserMessage([message.UserText("/automatic", None)], 0, None),
    )
    == Error("skill is not user-invocable: automatic")
  assert simplifile.delete(root) == Ok(Nil)
}
