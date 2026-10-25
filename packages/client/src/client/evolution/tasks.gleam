//// Operator-admitted coding fixtures give prompt evaluation independent criteria.
////
//// A model may choose an admitted task-set identity, but cannot supply the files
//// that decide its success. Native admission captures bounded fixture bytes and
//// exact expected file contents together under their content digest. The reserved
//// fact survives resume; the production opener copies each fixture into a fresh
//// workspace and the native scorer compares files after actual tool execution.
////
//// Two payload versions are admitted and neither changes the meaning of the
//// other. Version one is a file map and an exact expected-file map per task.
//// Version two is the evaluation instrument's task shape, with `workspace` and
//// `verifier` as tagged sums; what it can carry is bounded by what the governed
//// plane can score. The only workspace is `inline` and the only verifier is
//// `expected_files`, so a version-two task set that is admitted scores through
//// the same native comparison as a version-one set. A `git_tree` workspace or a
//// `program` verifier is refused here, at admission, with a reason naming the
//// missing capability: the jailed verifier lives in `packages/eval`, which this
//// package cannot depend on, and a task set nobody can run should never reach
//// the catalogue. `protocol-change/100` records the decision and the follow-up.

import client/evolution/rollout
import client/mcp
import core/json
import core/register
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import runtime/api
import session/session
import storage/access
import storage/storage

/// Immutable operator-captured task set, addressed by its canonical byte digest.
pub type TaskSet {
  TaskSet(
    /// Native content identity; candidate text never supplies this digest.
    id: String,
    /// The payload version this set was admitted under, one or two. It is part
    /// of the canonical bytes, so a version-one and a version-two set of the
    /// same fixtures are different sets.
    version: Int,
    /// Independent fixtures, each copied separately for baseline and candidate.
    tasks: List(Fixture),
  )
}

/// One coding task and its exact independent file criterion.
pub type Fixture {
  Fixture(
    /// Versioned task identity, model prompt and native fixture/criterion digests.
    task: rollout.Task,
    /// Safe relative fixture paths and immutable UTF-8 file contents.
    files: List(#(String, String)),
    /// Safe relative result paths and exact independently expected contents.
    expected: List(#(String, String)),
  )
}

/// Captures a bounded immutable task set through authenticated operator control.
/// Model-facing tools cannot call this native reserved-fact capability.
///
/// ## Examples
///
/// ```gleam
/// // tasks.admit(runtime, native_authority, principal, operator_payload)
/// ```
pub fn admit(
  runtime: api.Runtime,
  authority: access.Authority,
  principal: String,
  payload: json.JsonValue,
) -> Result(TaskSet, String) {
  // Verify caller authority holds operator admission rights.
  use Nil <- result.try(case authority {
    access.Owner | access.Participant(access.Operator) -> Ok(Nil)
    access.Participant(access.Observer) ->
      Error("Denied: task fixtures require an authenticated operator")
  })

  use task_set <- result.try(decode(payload))

  // Verify that admitted principal string is non-empty and bounded.
  use Nil <- result.try(case principal != "" && bytes(principal) <= 256 {
    True -> Ok(Nil)
    False -> Error("Denied: task admission requires a native principal")
  })

  use Nil <- result.try(
    api.put_reserved_fact(
      runtime,
      key(task_set.id),
      json.Object([
        #("principal", json.String(principal)),
        #("payload", canonical(task_set)),
      ]),
    )
    |> result.replace_error("Unavailable: task-set admission did not commit"),
  )
  Ok(task_set)
}

/// Reads the exact admitted task set and verifies its durable content identity.
///
/// ## Examples
///
/// ```gleam
/// // tasks.load(session, model_requested_task_set_id)
/// ```
pub fn load(session: session.Session, id: String) -> Result(TaskSet, String) {
  // Ensure task identifier is a valid 64-character hexadecimal hash.
  use Nil <- result.try(case valid_id(id) {
    True -> Ok(Nil)
    False -> Error("Bounds: invalid task-set identity")
  })

  use stored <- result.try(
    storage.get_register(session.store, register.FactCustom, key(id))
    |> result.replace_error("Unavailable: task-set fact could not be read"),
  )

  // Verify task-set custom register presence and extract payload.
  use payload <- result.try(case stored {
    None -> Error("Missing: task set has not been admitted by an operator")
    Some(storage.Register(value:, ..)) -> field(value.payload, "payload")
  })

  use task_set <- result.try(decode(payload))

  // Verify that admitted task-set content identity matches requested ID.
  case task_set.id == id {
    True -> Ok(task_set)
    False -> Error("Corrupt: admitted task-set content identity changed")
  }
}

/// Decodes a native admission payload before any workspace is opened. Version
/// one carries `{id, prompt, files, expected}` per task; version two carries
/// `{id, prompt, workspace, verifier}` with the sums described in the module
/// documentation. Both bound a set to ten tasks and 256 KiB, each file map to
/// 64 paths, and keep paths inside the fixture. A version-two set additionally
/// refuses two tasks with the same fixture and expected bytes, because each
/// admitted task counts as one independent cluster of the paired verdict.
///
/// ## Examples
///
/// ```gleam
/// // tasks.decode(operator_json)
/// ```
pub fn decode(payload: json.JsonValue) -> Result(TaskSet, String) {
  use fields <- result.try(object(payload, ["version", "tasks"]))
  use version <- result.try(required(fields, "version"))
  use tasks <- result.try(required(fields, "tasks"))

  // The version word picks the per-task decoder; any other word is refused
  // before a task is read, so a future version is never half-understood.
  use #(version, values, decoder) <- result.try(case version, tasks {
    json.Int(1), json.Array(values) if values != [] ->
      Ok(#(1, values, fixture_v1))
    json.Int(2), json.Array(values) if values != [] ->
      Ok(#(2, values, fixture_v2))
    _, _ ->
      Error("Bounds: expected nonempty version-one or version-two task set")
  })

  // Validate total task items and payload byte size.
  use Nil <- result.try(
    case
      list.length(values) <= 10 && bytes(json.to_string(payload)) <= 262_144
    {
      True -> Ok(Nil)
      False -> Error("Bounds: task-set capture exceeds admission limits")
    },
  )

  use fixtures <- result.try(list.try_map(values, decoder))
  use Nil <- result.try(distinct_ids(fixtures))
  use Nil <- result.try(independent(version, fixtures))

  let task_set = TaskSet(id: "", version:, tasks: fixtures)
  Ok(
    TaskSet(..task_set, id: mcp.sha256_hex(json.to_string(canonical(task_set)))),
  )
}

/// Ensures every task within the set has a unique identifier.
fn distinct_ids(fixtures: List(Fixture)) -> Result(Nil, String) {
  case
    list.length(list.unique(list.map(fixtures, fn(item) { item.task.id })))
    == list.length(fixtures)
  {
    True -> Ok(Nil)
    False -> Error("Bounds: task identifiers must be unique")
  }
}

/// Refuses a version-two set in which two tasks share fixture and expected
/// bytes. The paired verdict treats every task as an independent cluster, so a
/// duplicated pair would turn one task's evidence into several votes. Version
/// one is exempt: its payloads stay valid and mean what they meant.
fn independent(version: Int, fixtures: List(Fixture)) -> Result(Nil, String) {
  let pairs =
    list.map(fixtures, fn(item) { #(item.task.fixture, item.task.criteria) })

  // Only the new version carries the rule; an older set is admitted as before.
  case version != 2 || list.length(list.unique(pairs)) == list.length(pairs) {
    True -> Ok(Nil)
    False ->
      Error(
        "Bounds: tasks must be independent; a fixture and expected pair repeats",
      )
  }
}

/// Decodes and validates a single version-one task.
fn fixture_v1(value: json.JsonValue) -> Result(Fixture, String) {
  use fields <- result.try(object(value, ["id", "prompt", "files", "expected"]))
  use files_json <- result.try(required(fields, "files"))
  use expected_json <- result.try(required(fields, "expected"))
  use files <- result.try(file_map(files_json))
  use expected <- result.try(file_map(expected_json))
  captured(fields, files, expected)
}

/// Decodes and validates a single version-two task: the inline workspace and
/// the expected-files verifier are the only members of their sums admitted.
fn fixture_v2(value: json.JsonValue) -> Result(Fixture, String) {
  use fields <- result.try(
    object(value, ["id", "prompt", "workspace", "verifier"]),
  )
  use workspace <- result.try(required(fields, "workspace"))
  use verifier <- result.try(required(fields, "verifier"))
  use files <- result.try(inline_workspace(workspace))
  use expected <- result.try(expected_files(verifier))
  captured(fields, files, expected)
}

/// Reads a workspace sum. A tree from a repository is a real member of the sum
/// and is refused by name, so the operator learns the capability is missing
/// rather than that the payload is malformed.
fn inline_workspace(
  value: json.JsonValue,
) -> Result(List(#(String, String)), String) {
  use #(kind, fields) <- result.try(tagged(value, "workspace"))

  // The kind word decides whether the members are read, refused as a missing
  // capability, or refused as malformed.
  case kind, fields {
    "inline", [#("files", files)] -> file_map(files)
    "git_tree", _ ->
      Error(
        "Bounds: git-tree workspaces are not admitted to governed comparisons yet",
      )
    _, _ -> Error("Bounds: workspace must be an inline file map")
  }
}

/// Reads a verifier sum. A program verifier needs the jailed runner in
/// `packages/eval`, which this package cannot call, so it is refused by name.
fn expected_files(
  value: json.JsonValue,
) -> Result(List(#(String, String)), String) {
  use #(kind, fields) <- result.try(tagged(value, "verifier"))

  // The kind word decides whether the members are read, refused as a missing
  // capability, or refused as malformed.
  case kind, fields {
    "expected_files", [#("expected", expected)] -> file_map(expected)
    "program", _ ->
      Error(
        "Bounds: program verifiers are not admitted to governed comparisons yet",
      )
    _, _ -> Error("Bounds: verifier must be exact expected files")
  }
}

/// Splits a tagged object into its `kind` word and its other members.
fn tagged(
  value: json.JsonValue,
  name: String,
) -> Result(#(String, List(#(String, json.JsonValue))), String) {
  case value {
    json.Object(fields) ->
      case list.key_pop(fields, "kind") {
        Ok(#(json.String(kind), rest)) -> Ok(#(kind, rest))
        _ -> Error("Bounds: task " <> name <> " needs a kind")
      }
    _ -> Error("Bounds: task " <> name <> " must be an object")
  }
}

/// Finishes either version's task from its id, prompt and decoded file maps,
/// so the bounds and the digests are one rule rather than two.
fn captured(
  fields: List(#(String, json.JsonValue)),
  files: List(#(String, String)),
  expected: List(#(String, String)),
) -> Result(Fixture, String) {
  use id <- result.try(text(fields, "id"))
  use prompt <- result.try(text(fields, "prompt"))

  // Validate identifier, prompt and expected assertions are non-empty and bounded.
  use Nil <- result.try(
    case
      id != ""
      && bytes(id) <= 128
      && prompt != ""
      && bytes(prompt) <= 512
      && expected != []
    {
      True -> Ok(Nil)
      False ->
        Error(
          "Bounds: task identity, prompt or independent criteria are invalid",
        )
    },
  )

  Ok(Fixture(
    task: rollout.Task(
      id:,
      prompt:,
      criteria: mcp.sha256_hex(json.to_string(files_value(expected))),
      fixture: mcp.sha256_hex(json.to_string(files_value(files))),
    ),
    files:,
    expected:,
  ))
}

/// Decodes and checks a map of relative workspace fixture file paths to UTF-8 contents.
fn file_map(value: json.JsonValue) -> Result(List(#(String, String)), String) {
  // Verify fixture files payload is a JSON object map.
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("Bounds: fixture files require a map of at most 64 paths")
  })

  // Ensure fixture map does not exceed 64 entries and contains unique keys.
  use Nil <- result.try(
    case
      list.length(fields) <= 64
      && list.length(list.unique(list.map(fields, fn(pair) { pair.0 })))
      == list.length(fields)
    {
      True -> Ok(Nil)
      False -> Error("Bounds: repeated fixture paths are invalid")
    },
  )

  use files <- result.try(
    list.try_map(fields, fn(pair) {
      case pair {
        #(path, json.String(contents)) ->
          case safe_path(path) {
            True -> Ok(#(path, contents))
            False ->
              Error(
                "Bounds: fixture paths must remain inside the fresh workspace",
              )
          }
        _ -> Error("Bounds: fixture file contents must be UTF-8 text")
      }
    }),
  )
  Ok(list.sort(files, fn(left, right) { string.compare(left.0, right.0) }))
}

/// Validates that a fixture path does not escape the workspace or access forbidden paths.
fn safe_path(path: String) -> Bool {
  let pieces = string.split(path, "/")
  path != ""
  && bytes(path) <= 256
  && !string.contains(path, "\\")
  && !string.contains(path, "\u{0}")
  && list.all(pieces, fn(piece) {
    piece != ""
    && piece != "."
    && piece != ".."
    && piece != ".git"
    && piece != ".loom"
  })
}

/// Encodes a task set into canonical JSON structure for deterministic hashing.
/// Version one keeps its original bytes, so every identity admitted before
/// version two existed still verifies; version two writes the sums.
fn canonical(task_set: TaskSet) -> json.JsonValue {
  json.Object([
    #("version", json.Int(task_set.version)),
    #(
      "tasks",
      json.Array(
        list.map(task_set.tasks, fn(fixture) {
          case task_set.version {
            2 -> task_v2(fixture)
            _ -> task_v1(fixture)
          }
        }),
      ),
    ),
  ])
}

/// The version-one task object.
fn task_v1(fixture: Fixture) -> json.JsonValue {
  json.Object([
    #("id", json.String(fixture.task.id)),
    #("prompt", json.String(fixture.task.prompt)),
    #("files", files_value(fixture.files)),
    #("expected", files_value(fixture.expected)),
  ])
}

/// The version-two task object, with the workspace and verifier tagged.
fn task_v2(fixture: Fixture) -> json.JsonValue {
  json.Object([
    #("id", json.String(fixture.task.id)),
    #("prompt", json.String(fixture.task.prompt)),
    #(
      "workspace",
      json.Object([
        #("kind", json.String("inline")),
        #("files", files_value(fixture.files)),
      ]),
    ),
    #(
      "verifier",
      json.Object([
        #("kind", json.String("expected_files")),
        #("expected", files_value(fixture.expected)),
      ]),
    ),
  ])
}

/// Decodes a JSON object and verifies it contains exactly the declared field names.
fn object(
  value: json.JsonValue,
  names: List(String),
) -> Result(List(#(String, json.JsonValue)), String) {
  case value {
    json.Object(fields) ->
      case
        list.length(fields) == list.length(names)
        && list.all(names, fn(name) {
          list.key_find(fields, name) |> result.is_ok
        })
      {
        True -> Ok(fields)
        False ->
          Error(
            "Bounds: task-set object has missing, repeated or unknown fields",
          )
      }
    _ -> Error("Bounds: expected a task-set object")
  }
}

/// Extracts a named field value from a JSON object.
fn field(
  value: json.JsonValue,
  name: String,
) -> Result(json.JsonValue, String) {
  case value {
    json.Object(fields) ->
      list.key_find(fields, name)
      |> result.replace_error("Corrupt: task-set fact has no payload")
    _ -> Error("Corrupt: task-set fact is not an object")
  }
}

/// Extracts a string text property from a key-value fields list.
fn text(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(String, String) {
  use value <- result.try(
    list.key_find(fields, name)
    |> result.replace_error("Bounds: task field is missing"),
  )

  // Ensure field value is a string primitive.
  case value {
    json.String(value) -> Ok(value)
    _ -> Error("Bounds: task field requires text")
  }
}

fn valid_id(id: String) -> Bool {
  bytes(id) == 64
  && list.all(string.to_graphemes(id), fn(char) {
    string.contains("0123456789abcdef", char)
  })
}

fn key(id: String) -> String {
  "prompt/evolution-taskset/" <> id
}

fn bytes(value: String) -> Int {
  bit_array.byte_size(bit_array.from_string(value))
}

/// Looks up a required JSON property by name from a fields list.
fn required(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(json.JsonValue, String) {
  list.key_find(fields, name)
  |> result.replace_error("Bounds: required task-set field is absent")
}

fn files_value(files: List(#(String, String))) -> json.JsonValue {
  json.Object(list.map(files, fn(pair) { #(pair.0, json.String(pair.1)) }))
}
