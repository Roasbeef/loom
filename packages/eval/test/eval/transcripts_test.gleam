//// Tests for the transcript export and the stratified sample, on synthetic
//// session databases: this environment has no production sessions, so every
//// database here is built by the test and every claim is about the exporter.

import client/evolution/trace
import client/workspace_policy
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/register
import core/tx
import eval/transcripts
import eval/transcripts_cli
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session/session
import simplifile
import storage/storage

/// A fresh directory under the operator's home, never `/tmp`.
fn fresh(name: String) -> String {
  let assert Some(home) = workspace_policy.home_directory() as "tests need HOME"
  let root = home <> "/evalwt/transcripts-test/" <> name
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "test root must be creatable"
  root
}

fn usage() -> message.Usage {
  storage.empty_usage()
}

fn assistant(
  model: String,
  content: List(message.AssistantBlock),
) -> message.AgentMessage {
  message.AssistantMessage(
    content:,
    api: "anthropic-messages",
    provider: "p",
    model:,
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: usage(),
    stop_reason: message.Stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: Some(True),
    timestamp: 1000,
  )
}

fn user(blocks: List(message.UserBlock)) -> message.AgentMessage {
  message.UserMessage(content: blocks, timestamp: 1000, origin: None)
}

fn mark_op(id: ids.EntryId, outcome: String) -> tx.Write {
  tx.SetRegister(
    register.FactCustom,
    "prompt/evolution-outcome/" <> ids.entry_id_to_string(id),
    register.value(
      json.Object([
        #("version", json.Int(1)),
        #("principal", json.String("owner")),
        #("outcome", json.String(outcome)),
      ]),
    ),
  )
}

/// Builds a closed session database holding `messages` as a chain, one entry
/// per message at ts 2000 + position, marking the assistant entries listed in
/// `marks` (position, outcome word). Returns the path.
fn build(
  root: String,
  name: String,
  messages: List(message.AgentMessage),
  marks: List(#(Int, String)),
) -> String {
  let path = root <> "/" <> name <> ".db"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "database directory is creatable"
  let assert Ok(opened) =
    session.open_sqlite(
      path:,
      owner: "builder",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(1000),
    )
    as "builder session opens"
  let assert Ok(#(_, generator)) =
    session.ensure_id(opened, ids.generator(clock.fixed(1000), seed: 3))
    as "identity is durable"

  let #(ops, _, _) =
    list.index_fold(messages, #([], None, generator), fn(acc, body, position) {
      let #(ops, parent, generator) = acc
      let #(id, generator) = ids.mint_entry(generator)
      let row = entry.MessageEntry(id, parent, 0, 2000 + position, body, False)
      let marking = case list.key_find(marks, position) {
        Ok(word) -> [mark_op(id, word)]
        Error(Nil) -> []
      }

      #(
        list.flatten([ops, [tx.InsertEntry(row)], marking]),
        Some(id),
        generator,
      )
    })

  let assert Ok(_) = storage.commit(opened.store, tx.Tx(ops, []))
    as "synthetic session commits"
  let assert Ok(Nil) = session.close(opened) as "builder session closes"
  path
}

fn read(path: String) -> String {
  let assert Ok(text) = simplifile.read(path) as "output file is readable"
  text
}

/// Every file in a directory with its bytes, to prove nothing moved.
fn listing(dir: String) -> List(#(String, BitArray)) {
  let assert Ok(names) = simplifile.read_directory(dir) as "directory lists"

  list.sort(names, string.compare)
  |> list.map(fn(name) {
    let assert Ok(bytes) = simplifile.read_bits(dir <> "/" <> name)
      as "file is readable"
    #(name, bytes)
  })
}

fn run_export(root: String, dbs: List(String)) -> transcripts.Census {
  let assert Ok(census) = transcripts.export_dbs(dbs, 0, root <> "/out")
    as "export succeeds"
  census
}

pub fn export_reads_copies_not_originals_test() {
  let root = fresh("copies")
  let held = root <> "/held"
  let db = build(held, "a", [user([message.UserText("hi", None)])], [])
  let before = listing(held)
  let census = run_export(root, [db])

  assert census.sessions == 1 && census.failed == []
  assert listing(held) == before
  assert simplifile.is_directory(root <> "/out/.copies") == Ok(False)
  assert simplifile.is_file(root <> "/out/a.jsonl") == Ok(True)
}

pub fn thinking_and_images_excluded_test() {
  let root = fresh("excluded")
  let db =
    build(
      root,
      "a",
      [
        user([
          message.UserText("visible question", None),
          message.UserImage("IMAGEBYTES", "image/png"),
        ]),
        assistant("m", [
          message.AssistantThinking("PRIVATE-THINKING", None, False),
          message.AssistantText("visible answer", None),
        ]),
        message.ToolResultMessage(
          tool_call_id: "c",
          tool_name: "fs_read",
          content: [
            message.ToolResultText("visible output", None),
            message.ToolResultImage("RESULTIMAGE", "image/png"),
          ],
          details: None,
          usage: None,
          added_tool_names: None,
          is_error: True,
          timestamp: 1000,
        ),
      ],
      [],
    )
  let _ = run_export(root, [db])
  let text = read(root <> "/out/a.jsonl")

  assert string.contains(text, "visible question")
  assert string.contains(text, "visible answer")
  assert string.contains(text, "visible output")
  assert !string.contains(text, "PRIVATE-THINKING")
  assert !string.contains(text, "IMAGEBYTES")
  assert !string.contains(text, "RESULTIMAGE")
  assert string.contains(text, "\"is_error\":true")
}

pub fn planted_secrets_are_scrubbed_test() {
  let root = fresh("secrets")
  let bearer = "Authorization: Bearer " <> string.repeat("Z9", 24)
  let db =
    build(
      root,
      "a",
      [
        user([message.UserText("use sk-planted-secret-value-123 now", None)]),
        assistant("m", [
          message.AssistantToolCall(message.ToolCall(
            "c",
            "http",
            json.Object([
              #("x-api-key", json.String("tiny")),
              #("url", json.String("https://example.test")),
            ]),
            None,
            None,
          )),
        ]),
        message.ToolResultMessage(
          tool_call_id: "c",
          tool_name: "http",
          content: [message.ToolResultText(bearer, None)],
          details: None,
          usage: None,
          added_tool_names: None,
          is_error: False,
          timestamp: 1000,
        ),
      ],
      [],
    )
  let _ = run_export(root, [db])
  let text = read(root <> "/out/a.jsonl")

  assert !string.contains(text, "sk-planted")
  assert !string.contains(text, "tiny")
  assert !string.contains(text, "Z9Z9Z9Z9")
  assert string.contains(text, "\"arg_keys\":[\"x-api-key\",\"url\"]")
  assert string.contains(text, "<redacted>")
  assert string.contains(text, transcripts.scrubber_limits)
}

pub fn unmarked_is_explicit_test() {
  let root = fresh("marks")
  let db =
    build(
      root,
      "a",
      [
        assistant("m", [message.AssistantText("one", None)]),
        assistant("m", [message.AssistantText("two", None)]),
      ],
      [#(1, "failed")],
    )
  let census = run_export(root, [db])
  let text = read(root <> "/out/a.jsonl")

  assert census.marked == 1 && census.unmarked == 1
  assert string.contains(text, "\"outcome\":\"unmarked\"")
  assert string.contains(text, "\"outcome\":\"failed\"")
  assert trace.Unmarked != trace.Failed
}

pub fn census_counts_by_model_test() {
  let root = fresh("census")
  let one =
    build(
      root,
      "a",
      [
        assistant("alpha", [message.AssistantText("x", None)]),
        assistant("beta", [message.AssistantText("y", None)]),
        assistant("alpha", [message.AssistantText("z", None)]),
      ],
      [],
    )
  let two =
    build(
      root,
      "b",
      [assistant("beta", [message.AssistantText("w", None)])],
      [],
    )
  let census = run_export(root, [one, two])

  assert census.sessions == 2 && census.entries == 4
  assert census.by_model == [#("p/alpha", 2), #("p/beta", 2)]
  assert transcripts_cli.parse_since("1970-01-02") == Ok(86_400_000)
}

/// Writes a header-only session file for `sample` to stratify.
fn fake_session(dir: String, name: String, model: String, outcome: String) {
  let header =
    json.to_string(
      json.Object([
        #("kind", json.String("header")),
        #("model", json.String(model)),
        #("outcome", json.String(outcome)),
      ]),
    )
  let assert Ok(Nil) = simplifile.write(dir <> "/" <> name <> ".jsonl", header)
    as "fake session writes"
  Nil
}

pub fn sample_is_stratified_and_reproducible_test() {
  let dir = fresh("sample")
  let _ =
    list.index_map(list.repeat(Nil, 12), fn(_, i) {
      fake_session(dir, "common-" <> string.inspect(i), "p/a", "unmarked")
    })

  fake_session(dir, "rare-1", "p/b", "failed")
  fake_session(dir, "rare-2", "p/c", "succeeded")

  let first = transcripts.sample(dir, 5, "seed-one")

  assert first == transcripts.sample(dir, 5, "seed-one")
  assert list.length(first) == 5
  assert list.any(first, string.ends_with(_, "rare-1.jsonl"))
  assert list.any(first, string.ends_with(_, "rare-2.jsonl"))
  assert first != transcripts.sample(dir, 5, "seed-two")
  assert list.length(transcripts.sample(dir, 99, "s")) == 14
}
