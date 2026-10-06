//// Operator-admitted coding fixtures give prompt evaluation independent criteria.
////
//// A model may choose an admitted task-set identity, but cannot supply the files
//// that decide its success. Native admission captures bounded fixture bytes and
//// exact expected file contents together under their content digest. The reserved
//// fact survives resume; the production opener copies each fixture into a fresh
//// workspace and the native scorer compares files after actual tool execution.

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
  use Nil <- result.try(case authority {
    access.Owner | access.Participant(access.Operator) -> Ok(Nil)
    access.Participant(access.Observer) ->
      Error("Denied: task fixtures require an authenticated operator")
  })
  use task_set <- result.try(decode(payload))
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
  use Nil <- result.try(case valid_id(id) {
    True -> Ok(Nil)
    False -> Error("Bounds: invalid task-set identity")
  })
  use stored <- result.try(
    storage.get_register(session.store, register.FactCustom, key(id))
    |> result.replace_error("Unavailable: task-set fact could not be read"),
  )
  use payload <- result.try(case stored {
    None -> Error("Missing: task set has not been admitted by an operator")
    Some(storage.Register(value:, ..)) -> field(value.payload, "payload")
  })
  use task_set <- result.try(decode(payload))
  case task_set.id == id {
    True -> Ok(task_set)
    False -> Error("Corrupt: admitted task-set content identity changed")
  }
}

/// Decodes a version-one native admission payload before any workspace is opened.
/// Fixture and expected file maps each contain at most 64 paths, with total
/// captured bytes at most 256 KiB and ten tasks. Paths cannot escape the fixture.
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
  use values <- result.try(case version, tasks {
    json.Int(1), json.Array(values) if values != [] -> Ok(values)
    _, _ -> Error("Bounds: expected nonempty version-one task set")
  })
  use Nil <- result.try(
    case
      list.length(values) <= 10 && bytes(json.to_string(payload)) <= 262_144
    {
      True -> Ok(Nil)
      False -> Error("Bounds: task-set capture exceeds admission limits")
    },
  )
  use fixtures <- result.try(list.try_map(values, fixture))
  use Nil <- result.try(
    case
      list.length(list.unique(list.map(fixtures, fn(item) { item.task.id })))
      == list.length(fixtures)
    {
      True -> Ok(Nil)
      False -> Error("Bounds: task identifiers must be unique")
    },
  )
  let task_set = TaskSet(id: "", tasks: fixtures)
  Ok(
    TaskSet(..task_set, id: mcp.sha256_hex(json.to_string(canonical(task_set)))),
  )
}

fn fixture(value: json.JsonValue) -> Result(Fixture, String) {
  use fields <- result.try(object(value, ["id", "prompt", "files", "expected"]))
  use id <- result.try(text(fields, "id"))
  use prompt <- result.try(text(fields, "prompt"))
  use files_json <- result.try(required(fields, "files"))
  use expected_json <- result.try(required(fields, "expected"))
  use files <- result.try(file_map(files_json))
  use expected <- result.try(file_map(expected_json))
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

fn file_map(value: json.JsonValue) -> Result(List(#(String, String)), String) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("Bounds: fixture files require a map of at most 64 paths")
  })
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

fn canonical(task_set: TaskSet) -> json.JsonValue {
  json.Object([
    #("version", json.Int(1)),
    #(
      "tasks",
      json.Array(
        list.map(task_set.tasks, fn(fixture) {
          json.Object([
            #("id", json.String(fixture.task.id)),
            #("prompt", json.String(fixture.task.prompt)),
            #(
              "files",
              json.Object(
                list.map(fixture.files, fn(pair) {
                  #(pair.0, json.String(pair.1))
                }),
              ),
            ),
            #(
              "expected",
              json.Object(
                list.map(fixture.expected, fn(pair) {
                  #(pair.0, json.String(pair.1))
                }),
              ),
            ),
          ])
        }),
      ),
    ),
  ])
}

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

fn text(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(String, String) {
  use value <- result.try(
    list.key_find(fields, name)
    |> result.replace_error("Bounds: task field is missing"),
  )
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
