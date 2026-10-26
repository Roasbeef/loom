//// The only road from the instrument's task pool to the governed plane, and
//// the place the holdout seal is enforced.
////
//// The governed comparison can name only a task set that an operator admitted
//// into the source session, so the seal is not a password on the holdout: it
//// is that the holdout's ids are never offered to the door. This module builds
//// what is offered. It takes the instrument's tasks, keeps those whose family
//// hashes into the requested split under the plan's salt, converts them to a
//// version-two task-set payload, and hands that payload to a `Door`. A request
//// for the holdout is refused by `split.admissible` before any task is read,
//// so there is no code path on which a holdout id is converted, let alone
//// submitted (`docs/design-notes/eval-instrument.md` section 6).
////
//// ## How work moves
////
//// `prepare` is pure: it applies the seal, selects the split's tasks, converts
//// each to its version-two form, and lets the governed plane's own decoder
//// (`client/evolution/tasks.decode`) judge every task alone and then the set.
//// A task the decoder refuses is reported in `skipped` with the decoder's own
//// reason rather than failing the batch, because the pool holds tasks (a
//// repository tree, a hidden program) that the governed plane cannot score yet
//// and one of them must not hide the hand-written fixtures beside it.
//// `submit` is the impure edge reduced to a function: it bounds the payload to
//// what the operator door accepts and passes it on. `admit_cli` supplies the
//// door that shells out to `loomd evolution admit_tasks`, which keeps the
//// authority to admit in the daemon's existing operator door and out of this
//// package.

import client/evolution/tasks
import core/json.{type JsonValue}
import eval/split.{type Split}
import eval/task.{type Task, ExpectedFiles, GitTree, Inline, Program}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The largest argument file the operator door reads, in bytes
/// (`client/evolution/cli`, "at most 48 KiB").
pub const max_payload_bytes = 49_152

/// Submits a prepared payload to the operator door and answers the door's own
/// description of what it admitted, or the reason it refused.
pub type Door =
  fn(JsonValue) -> Result(String, String)

/// A task of the requested split that the governed plane cannot take.
pub type Skipped {
  Skipped(
    /// The instrument's id of the task that was left out.
    task_id: String,
    /// Why: the governed decoder's reason, or the shape that has no governed
    /// form.
    reason: String,
  )
}

/// What `prepare` decided to offer.
pub type Admission {
  Admission(
    /// The split these tasks were selected for; never `Holdout`.
    split: Split,
    /// The version-two task-set payload, ready for `admit_tasks`.
    payload: JsonValue,
    /// The ids of the tasks in `payload`, in payload order.
    admitted: List(String),
    /// The split's tasks that were left out, with reasons.
    skipped: List(Skipped),
  )
}

/// Reads a split's name as the command line spells it. `holdout` parses, so
/// that the refusal comes from the seal and names the holdout, not from a
/// parse error that would read as a typo.
///
/// ## Examples
///
/// ```gleam
/// assert admit.parse_split("tune") == Ok(split.Tune)
/// ```
///
pub fn parse_split(name: String) -> Result(Split, String) {
  case name {
    "tune" -> Ok(split.Tune)
    "validate" -> Ok(split.Validate)
    "holdout" -> Ok(split.Holdout)
    _ ->
      Error("unknown split " <> name <> "; expected tune, validate or holdout")
  }
}

/// The seal alone: lets `Tune` and `Validate` through and refuses `Holdout`
/// by name. `prepare` calls it first; a command line calls it before it reads
/// any file, so a holdout request touches nothing.
///
/// ## Examples
///
/// ```gleam
/// assert admit.seal(split.Tune) == Ok(split.Tune)
/// ```
///
pub fn seal(wanted: Split) -> Result(Split, String) {
  split.admissible(wanted)
}

/// Selects the tasks of `wanted` under `salt` and converts them to a
/// version-two task-set payload. Holdout is refused first, by name, so no
/// holdout task is read, converted or counted. Tasks are ordered by id so the
/// same pool and salt always mint the same task-set identity.
///
/// ## Examples
///
/// ```gleam
/// // admit.prepare(tasks, split.Holdout, "salt") is Error(".. holdout ..")
/// ```
///
pub fn prepare(
  pool: List(Task),
  wanted: Split,
  salt: String,
) -> Result(Admission, String) {
  use wanted <- result.try(seal(wanted))

  let selected =
    pool
    |> list.filter(fn(each) { split.assign(salt, split.family(each)) == wanted })
    |> list.sort(fn(left, right) { string.compare(left.id, right.id) })
  let converted =
    list.map(selected, fn(each) {
      #(each.id, convert(each) |> result.try(governed_alone))
    })
  let kept =
    list.filter_map(converted, fn(entry) {
      result.map(entry.1, fn(value) { #(entry.0, value) })
    })
  let skipped =
    list.filter_map(converted, fn(entry) {
      case entry.1 {
        Ok(_) -> Error(Nil)
        Error(reason) -> Ok(Skipped(task_id: entry.0, reason:))
      }
    })

  assemble(wanted, kept, skipped)
}

/// Builds the set from the convertible tasks, or says why there is none.
fn assemble(
  wanted: Split,
  kept: List(#(String, JsonValue)),
  skipped: List(Skipped),
) -> Result(Admission, String) {
  let payload =
    json.Object([
      #("version", json.Int(2)),
      #("tasks", json.Array(list.map(kept, fn(entry) { entry.1 }))),
    ])

  // An empty selection is a refusal with a count, never an empty set offered.
  case kept {
    [] ->
      Error(
        "no task of the "
        <> split_name(wanted)
        <> " split can be admitted to a governed comparison ("
        <> int.to_string(list.length(skipped))
        <> " skipped)",
      )
    _ -> {
      // The set is judged whole as well: the ten-task ceiling and the
      // independence rule are properties of the set, not of any one task.
      use _admitted <- result.try(
        tasks.decode(payload)
        |> result.map_error(fn(reason) {
          "the " <> split_name(wanted) <> " task set is refused: " <> reason
        }),
      )
      Ok(Admission(
        split: wanted,
        payload:,
        admitted: list.map(kept, fn(entry) { entry.0 }),
        skipped:,
      ))
    }
  }
}

/// Submits the payload through the door after bounding it to what the door
/// reads. The bound is checked here so an oversized split fails with its size
/// rather than with the door's generic refusal.
///
/// ## Examples
///
/// ```gleam
/// // admit.submit(admission, fn(payload) { Ok("admitted") }) == Ok("admitted")
/// ```
///
pub fn submit(admission: Admission, door: Door) -> Result(String, String) {
  let size =
    bit_array.byte_size(
      bit_array.from_string(json.to_string(admission.payload)),
    )

  // The door reads a bounded argument file; refuse here with the size.
  case size <= max_payload_bytes {
    True -> door(admission.payload)
    False ->
      Error(
        "the task set is "
        <> int.to_string(size)
        <> " bytes; the operator door reads at most "
        <> int.to_string(max_payload_bytes),
      )
  }
}

/// The argv that asks the daemon's operator door to admit the payload at
/// `args_path` into `session`. The authority stays in the daemon: this builds
/// a command line and carries no credential.
///
/// ## Examples
///
/// ```gleam
/// assert admit.door_argv("loomd", "/s", "ses", "/s/args.json")
///   == ["loomd", "evolution", "--state-dir", "/s", "admit_tasks", "ses",
///       "--args", "/s/args.json"]
/// ```
///
pub fn door_argv(
  loomd: String,
  state_dir: String,
  session: String,
  args_path: String,
) -> List(String) {
  [
    loomd,
    "evolution",
    "--state-dir",
    state_dir,
    "admit_tasks",
    session,
    "--args",
    args_path,
  ]
}

/// The version-two JSON of one task, or the reason it has no governed form.
fn convert(each: Task) -> Result(JsonValue, String) {
  use files <- result.try(inline_files(each.workspace))
  use expected <- result.try(expected_of(each.verifier))

  Ok(
    json.Object([
      #("id", json.String(each.id)),
      #("prompt", json.String(each.prompt)),
      #(
        "workspace",
        json.Object([
          #("kind", json.String("inline")),
          #("files", file_map(files)),
        ]),
      ),
      #(
        "verifier",
        json.Object([
          #("kind", json.String("expected_files")),
          #("expected", file_map(expected)),
        ]),
      ),
    ]),
  )
}

/// Lets the governed decoder judge one converted task by itself, so the
/// reason a task is skipped is the reason the door would have given.
fn governed_alone(value: JsonValue) -> Result(JsonValue, String) {
  let single =
    json.Object([#("version", json.Int(2)), #("tasks", json.Array([value]))])

  tasks.decode(single)
  |> result.map(fn(_admitted) { value })
}

/// The files of an inline workspace; a repository tree has no governed form.
fn inline_files(
  workspace: task.Workspace,
) -> Result(List(#(String, String)), String) {
  // Only the inline member of the workspace sum can be copied by the governed opener.
  case workspace {
    Inline(files:) -> Ok(files)
    GitTree(..) -> Error("a git-tree workspace has no governed form yet")
  }
}

/// The expected files of an exact-files verifier; a program is not admitted.
fn expected_of(
  verifier: task.Verifier,
) -> Result(List(#(String, String)), String) {
  // Only exact files can be scored by the governed plane's native comparison.
  case verifier {
    ExpectedFiles(expected:) -> Ok(expected)
    Program(..) ->
      Error("program verifiers are not admitted to governed comparisons yet")
  }
}

/// A file list as the JSON object keyed by path.
fn file_map(files: List(#(String, String))) -> JsonValue {
  json.Object(list.map(files, fn(pair) { #(pair.0, json.String(pair.1)) }))
}

/// The split's name as the command line and messages spell it.
fn split_name(value: Split) -> String {
  case value {
    split.Tune -> "tune"
    split.Validate -> "validate"
    split.Holdout -> "holdout"
  }
}
