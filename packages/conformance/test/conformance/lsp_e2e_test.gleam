//// Issue #25's acceptance, end to end: a semantic rename across a fixture
//// repository, driven by the model, with the edits landing through the
//// ordinary hashline path so a concurrent modification still rejects.
////
//// Every part is the production one except the provider's HTTP transport.
//// The session boots through `serve.open_instance` — the same assembly a
//// daemon session gets — from a `loom.toml` carrying `[lsp.gleam]`, over
//// the real `loom-exec` helper. So the language server is started lazily
//// by the session's own manager, after its enforcement probe, in the jail,
//// as a helper lease, and the `lsp_*` tools reach it through the door the
//// boot wired. A boot that forgot to wire the door registers no `lsp_*`
//// tool, and the first scripted call fails as an unknown tool: this file is
//// the test that fails when `serve` passes `None`.
////
//// Three sessions, each its own boot:
////
//// - **Rename.** `lsp_references` on a bare name, an `fs_edit` whose anchor
////   is the one the references answer printed, a rename preview, a rename
////   apply and an `fs_read`. The preview writes nothing; the apply lands
////   every file and reports clean settled diagnostics. Between the preview
////   and the apply the test adds a reference on disk, as an editor would,
////   and the apply renames it too: an apply asks the server again, over a
////   freshly pulled view (ADR-013 §3), and never replays the preview.
//// - **Stale.** The same rename, applied while another process keeps
////   rewriting one of the files. The server's answer is computed over one
////   version and the disk holds a later one by the time it is checked, so
////   that file is rejected as stale, every other file is not attempted,
////   and nothing the rename planned is written (ADR-013 §4).
//// - **Go.** `gopls`, when this host has it: a definition and the
////   references of a qualified name, through the same tool path.
////
//// ## Why `BestEffort`
////
//// The session demands `exec.BestEffort`, as every jailed fixture of this
//// suite does, and for the reason `support/rig.config` records: the
//// ordinary runner's helper cannot apply every layer `PlatformEnforcement`
//// demands (this host has no delegated cgroup v2 base), and the manager's
//// probe would then refuse the server, correctly, before any query. The
//// language server still runs inside the helper's jail, with its mounts
//// and its network off; what the relaxed demand gives up is only the
//// refusal. The enforced settlement of a jailed `gleam lsp` is exercised
//// by `client/lsp/jail_test` wherever the jailed gate runs.

import broker/exec
import client/catalog
import client/codemode
import client/distillpass
import client/jobs
import client/retryconf
import client/schedule
import client/serve
import core/clock
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/adapter/anthropic
import provider/http
import provider/secret
import runtime/api
import session/session
import simplifile
import support/internal/ffi_shell
import support/jail
import support/script
import telemetry/log
import tools/hashline

/// One session's budget: an instance assembly, a cold language server
/// (the probe, a project compile), a handful of scripted turns, and the
/// graceful stop at close. Well under this on the hosts measured; the
/// headroom is for a slow runner, which would otherwise be reported as a
/// timeout at a line number rather than as the assertion it missed.
const test_timeout_seconds = 300

/// gleeunit runs eunit with `ScaleTimeouts(10)`, and that scale multiplies
/// a generator's own timeout too, so the number handed to eunit is the
/// number wanted divided by ten.
const gleeunit_timeout_scale = 10

/// eunit's `{timeout, Seconds, Body}`, built as a Gleam constructor so a
/// `*_test_` generator can ask for more than eunit's default.
pub type EunitTest {
  Timeout(seconds: Int, body: fn() -> Nil)
}

// --- the fixture repository ----------------------------------------------

// Three modules and one function they share. `greet` is defined in
// `app/util`, called twice on one line of `app/other`, and once from the
// entry module, so a rename of it touches every file and one line twice.
const util_source = "pub fn greet(name: String) -> String {
  \"Hello, \" <> name
}
"

const other_source = "import app/util

pub fn twice(name: String) -> String {
  util.greet(name) <> util.greet(name)
}
"

const app_source = "import app/other
import app/util

pub fn main() -> String {
  util.greet(\"world\") <> other.twice(\"again\")
}
"

// The line of `app.gleam` the scripted `fs_edit` rewrites, before and
// after. Its anchor is computed here, at script time, and the test then
// asserts the references answer printed exactly that anchor on exactly
// that line: the edit landing is the proof the answer feeds `fs_edit`.
const app_call_line = "  util.greet(\"world\") <> other.twice(\"again\")"

const app_call_edited = "  util.greet(\"loom\") <> other.twice(\"again\")"

// What the test appends to `app/other.gleam` between the preview and the
// apply: one more reference the preview never saw.
const other_addition = "
pub fn thrice(name: String) -> String {
  util.greet(name) <> twice(name)
}
"

// The three files after the rename, byte for byte.
const util_renamed = "pub fn welcome(name: String) -> String {
  \"Hello, \" <> name
}
"

const other_renamed = "import app/util

pub fn twice(name: String) -> String {
  util.welcome(name) <> util.welcome(name)
}

pub fn thrice(name: String) -> String {
  util.welcome(name) <> twice(name)
}
"

const app_renamed = "import app/other
import app/util

pub fn main() -> String {
  util.welcome(\"loom\") <> other.twice(\"again\")
}
"

// The catalogue every Gleam session boots from. The `[lsp.gleam]` table
// is the documented one: `gleam lsp` writes its manifest and `build/`
// into the project, so the project is writable.
const gleam_toml = "
[models.acme]
dialect = \"anthropic\"
base_url = \"https://acme.test\"
api_key_env = \"ACME_KEY\"
model_id = \"loom-1\"
context_window = 200000
max_output_tokens = 8192

[roles]
main = [\"acme\"]

[lsp.gleam]
command = [\"gleam\", \"lsp\"]
extensions = [\".gleam\"]
root_markers = [\"gleam.toml\"]
project = \"writable\"
"

// --- the rename ------------------------------------------------------------

/// The acceptance: references, an anchored edit, a preview, an apply and
/// a read, each checked against the transcript and the disk.
pub fn lsp_rename_end_to_end_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    case gleam_prerequisites() {
      Error(reason) ->
        io.println_error("SKIP lsp rename end to end: " <> reason)
      Ok(helper_path) -> run_rename(helper_path)
    }
  })
}

fn rename_turns() -> List(script.Turn) {
  [
    script.ToolUseTurn(
      call_id: "call_refs",
      tool: "lsp_references",
      arguments: json.Object([#("symbol", json.String("greet"))]),
      input_tokens: 100,
      output_tokens: 5,
    ),
    script.ToolUseTurn(
      call_id: "call_edit",
      tool: "fs_edit",
      arguments: edit_args(
        "app/src/app.gleam",
        app_source,
        5,
        app_call_line,
        app_call_edited,
      ),
      input_tokens: 110,
      output_tokens: 5,
    ),
    script.ToolUseTurn(
      call_id: "call_preview",
      tool: "lsp_rename",
      arguments: rename_args("preview"),
      input_tokens: 120,
      output_tokens: 5,
    ),
    script.ToolUseTurn(
      call_id: "call_apply",
      tool: "lsp_rename",
      arguments: rename_args("apply"),
      input_tokens: 130,
      output_tokens: 5,
    ),
    script.ToolUseTurn(
      call_id: "call_read",
      tool: "fs_read",
      arguments: json.Object([
        #("path", json.String("app/src/app/other.gleam")),
      ]),
      input_tokens: 140,
      output_tokens: 5,
    ),
    script.AnswerTurn(
      text: "greet is now welcome everywhere.",
      input_tokens: 150,
      output_tokens: 5,
    ),
  ]
}

fn run_rename(helper_path: String) -> Nil {
  let rig = rig("rename")
  write_gleam_project(rig)
  let project = rig.workspace <> "/app"
  let snapshots = process.new_subject()

  // The request carrying three tool results is the one the apply answers,
  // so this runs after the preview's result is committed and before the
  // apply is dispatched. The disk is read first, to prove the preview
  // wrote nothing, and then a reference is added, as an editor would.
  let hook = fn(index) {
    case index {
      3 ->
        once(rig, "between-preview-and-apply", fn() {
          process.send(snapshots, read_gleam_project(project))
          append(project <> "/src/app/other.gleam", other_addition)
        })
      _ -> Nil
    }
  }
  let messages =
    run_session(rig, helper_path, gleam_toml, rename_turns(), hook, "rename")

  let assert [
    message.UserMessage(..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "lsp_references",
      is_error: False,
      content: references,
      ..,
    ),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(tool_name: "fs_edit", is_error: False, ..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "lsp_rename",
      is_error: False,
      content: preview,
      ..,
    ),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "lsp_rename",
      is_error: False,
      content: applied,
      details: Some(applied_details),
      ..,
    ),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "fs_read",
      is_error: False,
      content: read,
      ..,
    ),
    message.AssistantMessage(stop_reason: message.Stop, ..),
  ] = messages
    as "the rename run must be five successful tool turns and an answer"
  let references = text_of(references)
  let preview = text_of(preview)
  let applied = text_of(applied)
  io.println_error("lsp e2e references:\n" <> references)
  io.println_error("lsp e2e rename applied:\n" <> applied)

  // The references answer counts, names every file, and prints each site
  // as `path:line:anchor|text` — the anchor the scripted edit used, on the
  // line it used it, which is why that edit landed.
  assert string.contains(references, "4 references")
  assert string.contains(
    references,
    "app/src/app.gleam:5:" <> hashline.anchor(app_call_line) <> "|",
  )
  assert string.contains(references, "app/src/app/util.gleam:1:")
  assert string.contains(references, "app/src/app/other.gleam:4:")

  // The preview showed the change and wrote nothing: the disk the hook
  // read between the preview and the apply is the fixture with only the
  // anchored edit on it.
  assert string.contains(preview, "welcome")
  let assert Ok(before_apply) = process.receive(snapshots, within: 0)
    as "the hook must have read the disk between the preview and the apply"
  assert before_apply
    == #(
      util_source,
      other_source,
      string.replace(app_source, app_call_line, app_call_edited),
    )

  // Every file landed, through the hashline path, and the diagnostics
  // after the rename settled clean.
  assert string.starts_with(applied, "Renamed `greet` to `welcome`: wrote 3")
  assert string.contains(applied, "diagnostics: clean (settled)")
  assert landing_statuses(applied_details)
    == [
      #("app/src/app.gleam", "landed"),
      #("app/src/app/other.gleam", "landed"),
      #("app/src/app/util.gleam", "landed"),
    ]

  // The disk, byte for byte — including the reference the preview never
  // saw, which only a rename recomputed at apply time could have reached.
  assert read_gleam_project(project)
    == #(util_renamed, other_renamed, app_renamed)

  // The read after the rename shows the new name with the anchors the
  // next edit would use.
  let read = text_of(read)
  assert string.contains(
    read,
    "4:" <> hashline.anchor("  util.welcome(name) <> util.welcome(name)") <> "|",
  )
}

// --- the stale apply -------------------------------------------------------

/// A concurrent modification rejects: a file rewritten while the rename
/// is being applied is refused as stale, and nothing is written.
pub fn lsp_rename_stale_end_to_end_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    case gleam_prerequisites() {
      Error(reason) -> io.println_error("SKIP lsp rename stale: " <> reason)
      Ok(helper_path) -> run_stale(helper_path)
    }
  })
}

fn stale_turns() -> List(script.Turn) {
  [
    script.ToolUseTurn(
      call_id: "call_preview",
      tool: "lsp_rename",
      arguments: rename_args("preview"),
      input_tokens: 100,
      output_tokens: 5,
    ),
    script.ToolUseTurn(
      call_id: "call_apply",
      tool: "lsp_rename",
      arguments: rename_args("apply"),
      input_tokens: 110,
      output_tokens: 5,
    ),
    script.AnswerTurn(
      text: "the rename was refused.",
      input_tokens: 120,
      output_tokens: 5,
    ),
  ]
}

// How the writer that races the apply is told to stop, and how it says
// it has.
type Writer {
  Halt(reply: process.Subject(Nil))
}

fn run_stale(helper_path: String) -> Nil {
  let rig = rig("stale")
  write_gleam_project(rig)
  let project = rig.workspace <> "/app"
  let other = project <> "/src/app/other.gleam"
  let writers = process.new_subject()

  // After the preview and before the apply, a writer outside the harness
  // starts rewriting `app/other.gleam` as fast as it can, each version a
  // valid module that still calls `greet`. The apply's pull reads one
  // version and hands it to the server; by the time the landing checks the
  // disk against the text the server answered over, a later one is there.
  // The hook waits for the first rewrite, so the race is running before
  // the apply is dispatched.
  let hook = fn(index) {
    case index {
      1 ->
        once(rig, "writer", fn() {
          let started = process.new_subject()
          process.spawn_unlinked(fn() {
            let control = process.new_subject()
            rewrite(other, project <> "/other.tmp", 1)
            process.send(started, control)
            rewrite_until_halted(other, project <> "/other.tmp", control, 2)
          })
          let assert Ok(control) = process.receive(started, within: 5000)
            as "the racing writer must start"
          process.send(writers, control)
        })
      _ -> Nil
    }
  }
  let messages =
    run_session(rig, helper_path, gleam_toml, stale_turns(), hook, "stale")

  // The writer is stopped before the disk is read, so what is read is
  // final.
  let assert Ok(control) = process.receive(writers, within: 0)
    as "the hook must have started the writer"
  process.call(control, waiting: 5000, sending: Halt)

  let assert [
    message.UserMessage(..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(tool_name: "lsp_rename", is_error: False, ..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "lsp_rename",
      is_error: True,
      content: refused,
      details: Some(refused_details),
      ..,
    ),
    message.AssistantMessage(stop_reason: message.Stop, ..),
  ] = messages
    as "the stale run must be a preview, a refused apply and an answer"
  let refused = text_of(refused)
  io.println_error("lsp e2e stale apply:\n" <> refused)

  // The raced file is the one rejected, and why is said; every other file
  // was checked and never attempted.
  assert string.contains(refused, "wrote nothing")
  assert string.contains(refused, "app/src/app/other.gleam: rejected")
  assert landing_statuses(refused_details)
    == [
      #("app/src/app.gleam", "not_attempted"),
      #("app/src/app/other.gleam", "rejected"),
      #("app/src/app/util.gleam", "not_attempted"),
    ]

  // Nothing the rename planned reached the disk: the two untouched files
  // are the fixture, and the raced one is the writer's, still calling
  // `greet`.
  let #(util, raced, app) = read_gleam_project(project)
  assert util == util_source
  assert app == app_source
  assert string.starts_with(raced, other_source)
  assert !string.contains(raced, "welcome")
}

// One rewrite of the raced file: the fixture text with a counter comment,
// written beside it and renamed over it, so a reader sees one whole
// version or the next and never half of one.
fn rewrite(path: String, temporary: String, tick: Int) -> Nil {
  let assert Ok(Nil) =
    simplifile.write(
      temporary,
      other_source <> "// tick " <> int.to_string(tick) <> "\n",
    )
    as "the racing writer must write its temporary file"
  let assert Ok(Nil) = simplifile.rename(at: temporary, to: path)
    as "the racing writer must rename over the file"
  Nil
}

// The writer's loop: rewrite, check for a halt without waiting, repeat.
fn rewrite_until_halted(
  path: String,
  temporary: String,
  control: process.Subject(Writer),
  tick: Int,
) -> Nil {
  rewrite(path, temporary, tick)
  case process.receive(control, within: 1) {
    Ok(Halt(reply:)) -> process.send(reply, Nil)
    Error(Nil) -> rewrite_until_halted(path, temporary, control, tick + 1)
  }
}

// --- gopls -----------------------------------------------------------------

/// `gopls` through the same tool path: the definition of a bare name and
/// the references of a qualified one.
pub fn lsp_gopls_end_to_end_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    case go_prerequisites() {
      Error(reason) ->
        io.println_error(
          "SKIP lsp e2e gopls: gopls or go is not installed (" <> reason <> ")",
        )
      Ok(#(helper_path, gopls, goroot)) -> run_gopls(helper_path, gopls, goroot)
    }
  })
}

fn gopls_turns() -> List(script.Turn) {
  [
    script.ToolUseTurn(
      call_id: "call_definition",
      tool: "lsp_definition",
      arguments: json.Object([#("symbol", json.String("Greet"))]),
      input_tokens: 100,
      output_tokens: 5,
    ),
    script.ToolUseTurn(
      call_id: "call_refs",
      tool: "lsp_references",
      arguments: json.Object([#("symbol", json.String("util.Greet"))]),
      input_tokens: 110,
      output_tokens: 5,
    ),
    script.AnswerTurn(
      text: "Greet is defined in util.",
      input_tokens: 120,
      output_tokens: 5,
    ),
  ]
}

fn run_gopls(helper_path: String, gopls: String, goroot: String) -> Nil {
  let rig = rig("gopls")
  let module = rig.workspace <> "/gomod"
  write(module <> "/go.mod", "module example.com/probe\n\ngo 1.21\n")
  write(
    module <> "/util/util.go",
    "package util\n\n// Greet greets.\nfunc Greet(name string) string {\n"
      <> "\treturn \"Hello, \" + name\n}\n",
  )
  write(
    module <> "/main.go",
    "package main\n\nimport \"example.com/probe/util\"\n\nfunc main() {\n"
      <> "\tprintln(util.Greet(\"world\"))\n\tprintln(util.Greet(\"again\"))\n}\n",
  )

  // `gopls` shells out to `go`, whose toolchain it must read, and writes
  // its build and file caches under the daemon's `HOME`. Each is a root the
  // operator lists; `~/` is resolved against the daemon's `HOME` at boot.
  let toml = "
[models.acme]
dialect = \"anthropic\"
base_url = \"https://acme.test\"
api_key_env = \"ACME_KEY\"
model_id = \"loom-1\"
context_window = 200000
max_output_tokens = 8192

[roles]
main = [\"acme\"]

[lsp.go]
command = [\"" <> gopls <> "\", \"serve\"]
extensions = [\".go\"]
root_markers = [\"go.mod\"]
readable = [\"" <> goroot <> "\", \"~/go/pkg/mod\"]
writable = [\"~/.cache/go-build\", \"~/.cache/gopls\"]
env = [\"GOFLAGS\", \"GOTOOLCHAIN\"]
"
  let messages =
    run_session(rig, helper_path, toml, gopls_turns(), fn(_) { Nil }, "gopls")
  let assert [
    message.UserMessage(..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "lsp_definition",
      is_error: False,
      content: definition,
      ..,
    ),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "lsp_references",
      is_error: False,
      content: references,
      ..,
    ),
    message.AssistantMessage(stop_reason: message.Stop, ..),
  ] = messages
    as "the gopls run must be two successful queries and an answer"
  let definition = text_of(definition)
  let references = text_of(references)
  io.println_error("lsp e2e gopls definition:\n" <> definition)
  io.println_error("lsp e2e gopls references:\n" <> references)
  assert string.contains(
    definition,
    "gomod/util/util.go:4:"
      <> hashline.anchor("func Greet(name string) string {")
      <> "|",
  )
  assert string.contains(references, "gomod/main.go:6:")
  assert string.contains(references, "gomod/main.go:7:")
}

// --- one session -------------------------------------------------------------

// A run's directory tree: the root the session file and the operator's
// home live in, and the workspace the fixture is written into. Under the
// package's `build/`, never `/tmp`, which the jail replaces.
type Rig {
  Rig(root: String, home: String, workspace: String)
}

fn rig(name: String) -> Rig {
  let assert Ok(here) = simplifile.current_directory()
    as "the test process must know where it is"
  let root =
    here
    <> "/build/lsp-e2e/"
    <> name
    <> "-"
    <> int.to_string(ffi_shell.unique_integer())
  let _cleared = simplifile.delete_all([root])
  let rig = Rig(root:, home: root <> "/home", workspace: root <> "/work")
  let assert Ok(Nil) = simplifile.create_directory_all(rig.home)
    as "the operator's home must be creatable"
  let assert Ok(Nil) = simplifile.create_directory_all(rig.workspace)
    as "the workspace must be creatable"
  rig
}

// Boots one session from `toml`, drives one prompt through the scripted
// turns to its end, closes the session, and reads the transcript back from
// the file — the durable record, not a cache of it.
fn run_session(
  rig: Rig,
  helper_path: String,
  toml: String,
  turns: List(script.Turn),
  hook: fn(Int) -> Nil,
  name: String,
) -> List(message.AgentMessage) {
  let assert Ok(parsed) = catalog.parse(toml)
    as "the fixture loom.toml must parse"
  let settings = settings(rig, helper_path, parsed, hooked(turns, hook), name)
  let assert Ok(instance) = serve.open_instance(settings, log.discard())
    as "the session must boot"
  let outcome = complete(instance)
  serve.close_instance(instance)
  let assert Ok(operation.RunLastResult(outcome: completion, ..)) = outcome
    as "the run must settle"
  assert completion == operation.RunCompleted(operation.CompletedByAssistant)
  let messages = transcript(settings.session_path)

  echo_language_server_results(name, messages)
  messages
}

// Every language-server tool result, printed whole to stderr before any
// assertion reads the transcript. The assertions below print their value
// truncated, which cut the one line that names why a server failed ("the
// language server did not answer: …") on the jailed CI lane, where the
// enforced jail differs from a developer's container. Stderr survives
// EUnit's capture, so a failure there names its own cause.
fn echo_language_server_results(
  name: String,
  messages: List(message.AgentMessage),
) -> Nil {
  list.each(messages, fn(entry) {
    case entry {
      message.ToolResultMessage(tool_name:, content:, ..) ->
        case string.starts_with(tool_name, "lsp_") {
          True ->
            io.println_error(
              "lsp e2e "
              <> name
              <> " "
              <> tool_name
              <> ": "
              <> result_text(content),
            )
          False -> Nil
        }
      _ -> Nil
    }
  })
}

fn result_text(content: List(message.ToolResultBlock)) -> String {
  content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      message.ToolResultImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

// The scripted transport with a hook in front of it. The hook runs in the
// process preparing the request, before the turn is delivered, and is
// handed the request's key — how many tool results it carries — so it can
// act between two named turns.
fn hooked(turns: List(script.Turn), hook: fn(Int) -> Nil) -> http.Transport {
  let inner = script.transport(turns)
  http.Transport(prepare_streaming: fn(request, subject) {
    hook(script.tool_results_in(request.body))
    inner.prepare_streaming(request, subject)
  })
}

// Runs `act` at most once per rig, however often the request it hangs on
// is prepared: a retried request must not append twice.
fn once(rig: Rig, name: String, act: fn() -> Nil) -> Nil {
  let marker = rig.root <> "/hook-" <> name
  case simplifile.is_file(marker) {
    Ok(True) -> Nil
    Ok(False) | Error(_) -> {
      write(marker, "")
      act()
    }
  }
}

fn complete(instance: serve.Instance) -> Result(operation.LastResult, Nil) {
  let assert Ok(op) =
    api.prompt(instance.runtime, [
      message.UserMessage(
        content: [
          message.UserText(
            text: "rename greet to welcome",
            text_signature: None,
          ),
        ],
        timestamp: 0,
        origin: None,
      ),
    ])
    as "the instance must admit through its own writer"
  api.await_result(instance.runtime, op, within_ms: 240_000)
}

fn transcript(path: String) -> List(message.AgentMessage) {
  let assert Ok(reopened) =
    session.open_sqlite(
      path:,
      owner: "lsp-e2e-reader",
      lease_ttl_ms: 60_000,
      clock: clock.stepping(from: 1_700_000_300_000, by: 11),
    )
    as "the closed session must reopen"
  let leaf = case session.strand_leaf(reopened, "main") {
    Ok(Some(session.Cell(value: leaf, ..))) -> leaf
    Ok(None) | Error(_) -> None
  }
  let assert Ok(messages) = session.project_context(reopened, leaf)
    as "the projection must read cleanly"
  messages
}

fn settings(
  rig: Rig,
  helper_path: String,
  parsed: catalog.Catalog,
  transport: http.Transport,
  name: String,
) -> serve.Settings {
  serve.Settings(
    peer_directory: None,
    secrets: secret.env(),
    secret_failures: [],
    session_path: rig.root <> "/session.db",
    domain_paths: None,
    bind_host: "not an interface",
    bind_port: -1,
    token_path: rig.root <> "/transport-only/daemon.token",
    workspace: rig.workspace,
    base_policy: serve.base_policy(rig.workspace),
    helper_path:,
    // The smallest pool the boot allows, which is also the one where the
    // lease cap (`pool_size - 3`) admits exactly the one server.
    helper_pool_size: exec.min_pool_size,
    session_id: "lsp-e2e-" <> name,
    // See the module documentation, "Why `BestEffort`".
    demand: exec.BestEffort,
    gateway: catalog.gateway(
      parsed,
      transport:,
      secrets: secret.from_list([#("ACME_KEY", "lsp-e2e-key")]),
      clock: clock.fixed(at: 0),
    ),
    catalog: parsed,
    system: None,
    home: Some(rig.home),
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    context_window: 200_000,
    max_output_tokens: 8192,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000,
    ),
    codemode_seed: rig.root <> "/no-such-seed",
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    retry_policy: retryconf.default_policy,
    deactivated_tools: [],
    memory: distillpass.no_pass(),
    tools: catalog.default_tools(),
    advisor: None,
  )
}

// --- prerequisites -------------------------------------------------------------

// The helper, and a `gleam` the manager can locate.
fn gleam_prerequisites() -> Result(String, String) {
  case ffi_shell.find_executable("gleam") {
    Error(Nil) -> Error("gleam is not on PATH")
    Ok(_gleam) -> jail.build_helper()
  }
}

// The helper, `go` (which `gopls` shells out to) and its root, and `gopls`
// on `PATH` or where `go install` puts it.
fn go_prerequisites() -> Result(#(String, String, String), String) {
  case ffi_shell.find_executable("go") {
    Error(Nil) -> Error("go is not on PATH")
    Ok(_go) -> {
      let goroot = string.trim(ffi_shell.os_cmd("go env GOROOT"))
      let installed =
        string.trim(ffi_shell.os_cmd("go env GOPATH")) <> "/bin/gopls"
      let gopls = case ffi_shell.find_executable("gopls") {
        Ok(found) -> Ok(found)
        Error(Nil) ->
          case simplifile.is_file(installed) {
            Ok(True) -> Ok(installed)
            Ok(False) | Error(_) -> Error("gopls was not found")
          }
      }
      case gopls, string.starts_with(goroot, "/") {
        Ok(gopls), True ->
          jail.build_helper()
          |> result.map(fn(helper) { #(helper, gopls, goroot) })
        Error(reason), _ -> Error(reason)
        Ok(_gopls), False -> Error("go env GOROOT is not absolute")
      }
    }
  }
}

// --- reading and writing the fixture -------------------------------------------

fn write_gleam_project(rig: Rig) -> Nil {
  let project = rig.workspace <> "/app"
  write(
    project <> "/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n",
  )
  write(project <> "/src/app/util.gleam", util_source)
  write(project <> "/src/app/other.gleam", other_source)
  write(project <> "/src/app.gleam", app_source)
}

// The three modules, in a fixed order: util, other, the entry module.
fn read_gleam_project(project: String) -> #(String, String, String) {
  #(
    read(project <> "/src/app/util.gleam"),
    read(project <> "/src/app/other.gleam"),
    read(project <> "/src/app.gleam"),
  )
}

fn read(path: String) -> String {
  let assert Ok(text) = simplifile.read(path)
    as "a fixture file must be readable"
  text
}

fn write(path: String, body: String) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(parent_directory(path))
    as "a fixture directory must be creatable"
  let assert Ok(Nil) = simplifile.write(path, body)
    as "a fixture file must be writable"
  Nil
}

fn append(path: String, body: String) -> Nil {
  let assert Ok(Nil) = simplifile.append(path, body)
    as "a fixture file must be appendable"
  Nil
}

fn parent_directory(path: String) -> String {
  let segments = string.split(path, "/")
  segments
  |> list.take(list.length(segments) - 1)
  |> string.join("/")
}

// --- the scripted arguments and the results ----------------------------------

fn rename_args(mode: String) -> JsonValue {
  json.Object([
    #("symbol", json.String("greet")),
    #("new_name", json.String("welcome")),
    #("mode", json.String(mode)),
  ])
}

// One anchored `fs_edit` replacing line `line` of a file whose whole text
// is `content`: the digest binds the edit to that text and the anchor to
// that line.
fn edit_args(
  path: String,
  content: String,
  line: Int,
  old: String,
  new: String,
) -> JsonValue {
  let at =
    json.Object([
      #("line", json.Int(line)),
      #("anchor", json.String(hashline.anchor(old))),
    ])
  json.Object([
    #("path", json.String(path)),
    #("digest", json.String(hashline.digest(content))),
    #(
      "hunks",
      json.Array([
        json.Object([
          #("op", json.String("replace")),
          #("from", at),
          #("to", at),
          #("lines", json.Array([json.String(new)])),
        ]),
      ]),
    ),
  ])
}

fn text_of(content: List(message.ToolResultBlock)) -> String {
  content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      message.ToolResultImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

// Each file's fate from a rename's details, as `#(path, status)`.
fn landing_statuses(details: JsonValue) -> List(#(String, String)) {
  let files = case details {
    json.Object(fields) ->
      case list.key_find(fields, "files") {
        Ok(json.Array(files)) -> files
        Ok(_) | Error(Nil) -> []
      }
    _ -> []
  }
  list.filter_map(files, fn(file) {
    case file {
      json.Object(fields) ->
        case list.key_find(fields, "path"), list.key_find(fields, "status") {
          Ok(json.String(path)), Ok(json.String(status)) -> Ok(#(path, status))
          _, _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}
