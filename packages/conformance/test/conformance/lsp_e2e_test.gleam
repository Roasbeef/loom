//// Issue #25's acceptance, end to end: a semantic rename across a fixture
//// repository, driven by the model, with the edits landing through the
//// ordinary hashline path so a concurrent modification still rejects.
////
//// Every part is the production one except the provider's HTTP transport.
//// The session boots through `serve.open_instance` — the same assembly a
//// daemon session gets — from a `loom.toml` carrying `[lsp.gleam]`, over
//// the real `loom-exec` helper. So the language server is started lazily
//// by the session's own manager, after its enforcement probe, in the jail,
//// as a helper lease. Compiled `cap/lsp` programs reach the door the boot
//// wired, while the provider sees no top-level `lsp_*` tools. A boot that
//// forgot the door refuses the program capability: these fixtures fail
//// when `serve` passes `None`.
////
//// The rename and Go fixtures each boot their own session:
////
//// - **Rename.** `cap/lsp.references` on a bare name, an `fs_edit` whose anchor
////   is the one the references answer printed, a rename preview, a rename
////   apply and an `fs_read`. The preview writes nothing; the apply lands
////   every file and reports clean settled diagnostics. Between the preview
////   and the apply the test adds a reference on disk, as an editor would,
////   and the apply renames it too: an apply asks the server again, over a
////   freshly pulled view (ADR-015 §3), and never replays the preview.
//// - **Stale.** The same rename, applied while another process keeps
////   rewriting one of the files. The server's answer is computed over one
////   version and the disk holds a later one by the time it is checked, so
////   that file is rejected as stale, every other file is not attempted,
////   and nothing the rename planned is written (ADR-015 §4).
//// - **Go.** `gopls`, when this host has it: a definition and the
////   references of a qualified name, through the same compiled capability
////   path.
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
import client/workspace_policy
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
import tools/fs
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
const util_source =
  "pub fn greet(name: String) -> String {
  \"Hello, \" <> name
}
"

const other_source =
  "import app/util

pub fn twice(name: String) -> String {
  util.greet(name) <> util.greet(name)
}
"

const app_source =
  "import app/other
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
const other_addition =
  "
pub fn thrice(name: String) -> String {
  util.greet(name) <> twice(name)
}
"

// The three files after the rename, byte for byte.
const util_renamed =
  "pub fn welcome(name: String) -> String {
  \"Hello, \" <> name
}
"

const other_renamed =
  "import app/util

pub fn twice(name: String) -> String {
  util.welcome(name) <> util.welcome(name)
}

pub fn thrice(name: String) -> String {
  util.welcome(name) <> twice(name)
}
"

const app_renamed =
  "import app/other
import app/util

pub fn main() -> String {
  util.welcome(\"loom\") <> other.twice(\"again\")
}
"

// The catalogue every Gleam session boots from. The `[lsp.gleam]` table
// is the documented one: `gleam lsp` writes its manifest and `build/`
// into the project, so the project is writable.
const gleam_toml =
  "
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
    case gleam_prerequisites(), code_mode_seed() {
      Ok(helper_path), Ok(seed) -> run_rename(helper_path, seed)
      Error(reason), _ | _, Error(reason) ->
        io.println_error("SKIP lsp rename end to end: " <> reason)
    }
  })
}

/// A compiled satellite reaches the production LSP door over a monorepo.
pub fn lsp_code_mode_monorepo_end_to_end_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    let assert Ok(here) = simplifile.current_directory()
      as "the test package has a working directory"
    let seed = here <> "/../../build/codemode-seed"
    case gleam_prerequisites(), codemode.discover(seed) {
      Ok(helper), Ok(_) -> run_code_mode(helper, seed)
      Error(reason), _ | _, Error(reason) ->
        io.println_error("SKIP lsp code mode monorepo: " <> reason)
    }
  })
}

const semantic_program =
  "import cap/lsp
import cap/report
import gleam/int
import gleam/list
import gleam/string

fn site(value: lsp.Site) -> report.Value {
  report.object([
    #(\"path\", report.string(value.path)),
    #(\"line\", report.int(value.line)),
    #(\"anchor\", report.string(value.anchor)),
    #(\"text\", report.string(value.text)),
  ])
}

pub fn main() -> report.Outcome {
  let path = \"app/src/app/util.gleam\"
  let query = lsp.in(lsp.at_line(lsp.symbol(\"sibling.prefix\"), 3), path)
  let outline = lsp.outline(path)
  let hover = lsp.hover(lsp.in(lsp.at_line(lsp.symbol(\"greet\"), 3), path))
  let definitions = lsp.definition(query)
  let references = lsp.references(query)
  case outline, hover, definitions, references {
    Ok([_, ..] as symbols), Ok(text), Ok(found), Ok(refs) ->
      report.value(report.object([
        #(\"marker\", report.string(\"lsp-cap-ok outline=\" <> int.to_string(list.length(symbols)))),
        #(\"hover\", report.string(text)),
        #(\"definitions\", report.object([
          #(\"sites\", report.list(list.map(found.items, site))),
          #(\"total\", report.int(found.total)),
        ])),
        #(\"references\", report.object([
          #(\"sites\", report.list(list.map(refs.items, fn(reference) { site(reference.site) }))),
          #(\"total\", report.int(refs.total)),
        ])),
      ]))
    _, _, _, _ -> report.failure(string.inspect(#(outline, hover, definitions, references)))
  }
}
"

fn run_code_mode(helper: String, seed: String) -> Nil {
  let rig = rig("code-mode")
  write_gleam_project(rig)
  write(
    rig.workspace <> "/app/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n[dependencies]\nsibling = { path = \"../sibling\" }\n",
  )
  write(
    rig.workspace <> "/app/src/app/util.gleam",
    "import sibling\n\npub fn greet(name: String) -> String { sibling.prefix() <> name }\n",
  )
  write(
    rig.workspace <> "/sibling/gleam.toml",
    "name = \"sibling\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n",
  )
  write(
    rig.workspace <> "/sibling/src/sibling.gleam",
    "pub fn prefix() -> String { \"Hello, \" }\n",
  )
  let turns = [
    script.ToolUseTurn(
      call_id: "semantic-program",
      tool: "code_mode",
      arguments: json.Object([
        #("program", json.String(semantic_program)),
        #("within_ms", json.Int(120_000)),
      ]),
      input_tokens: 100,
      output_tokens: 5,
    ),
    script.AnswerTurn(
      text: "semantic results received",
      input_tokens: 110,
      output_tokens: 5,
    ),
  ]
  let assert Ok(parsed) = catalog.parse(gleam_toml) as "the profile is valid"

  // Deep worktrees exceed the Unix socket path limit. The transport lives
  // in host scratch outside /tmp, which the satellite jail replaces.
  let socket_parent = "/var/tmp/"
  let socket_root =
    socket_parent <> "lsp-cap-" <> int.to_string(ffi_shell.unique_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(socket_root)
    as "the capability transport has a shallow socket root"
  let settings =
    serve.Settings(
      ..settings(rig, helper, parsed, script.transport(turns), "code-mode"),
      codemode_seed: seed,
      codemode_sockets: Some(socket_root),
    )
  let assert Ok(instance) = serve.open_instance(settings, log.discard())
    as "the real session wires code mode and its LSP door"
  let outcome = complete(instance)
  serve.close_instance(instance)
  let assert Ok(operation.RunLastResult(outcome: completion, ..)) = outcome
    as "the scripted run settles"
  assert completion == operation.RunCompleted(operation.CompletedByAssistant)
  let messages = transcript(settings.session_path)
  echo_language_server_results("code-mode", messages)
  let assert [#(content, details)] =
    list.filter_map(messages, fn(entry) {
      case entry {
        message.ToolResultMessage(
          tool_name: "code_mode",
          content:,
          is_error: False,
          details: Some(details),
          ..,
        ) -> Ok(#(content, details))
        _other -> Error(Nil)
      }
    })
    as "one successfully compiled code-mode result is persisted"
  let text = result_text(content)
  io.println_error("lsp code mode monorepo: " <> text)
  assert string.contains(text, "lsp-cap-ok outline=")
  assert string.contains(text, "fn(String) -> String")
  let payload = program_payload(details, "completed", "value")
  let definitions = json_field(payload, "definitions")
  let references = json_field(payload, "references")

  // A path dependency's definition is outside the queried app's root.
  // The server may name it, but the harness withholds its text rather than
  // reading a file the answer's identity did not admit.
  assert json_field(definitions, "total") == json.Int(1)
  assert reported_sites(definitions)
    == [#("sibling/src/sibling.gleam", 1, hashline.anchor(""), "")]
  let call = "pub fn greet(name: String) -> String { sibling.prefix() <> name }"
  assert json_field(references, "total") == json.Int(2)
  assert list.contains(reported_sites(references), #(
    "app/src/app/util.gleam",
    3,
    hashline.anchor(call),
    call,
  ))
  let _cleaned = simplifile.delete_all([socket_root])
  Nil
}

fn rename_turns() -> List(script.Turn) {
  [
    script.ToolUseTurn(
      call_id: "call_refs",
      tool: "code_mode",
      arguments: program_args(references_program("greet")),
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
      tool: "code_mode",
      arguments: program_args(rename_program("Preview")),
      input_tokens: 120,
      output_tokens: 5,
    ),
    script.ToolUseTurn(
      call_id: "call_apply",
      tool: "code_mode",
      arguments: program_args(rename_program("Apply")),
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

fn run_rename(helper_path: String, seed: String) -> Nil {
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
    run_session(
      rig,
      helper_path,
      gleam_toml,
      rename_turns(),
      hook,
      "rename",
      seed,
    )

  let assert [
    message.UserMessage(..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "code_mode",
      is_error: False,
      content: references,
      details: Some(reference_details),
      ..,
    ),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(tool_name: "fs_edit", is_error: False, ..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "code_mode",
      is_error: False,
      details: Some(preview_details),
      ..,
    ),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "code_mode",
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
  io.println_error("lsp e2e references:\n" <> text_of(references))
  io.println_error("lsp e2e rename applied:\n" <> text_of(applied))
  let references = program_payload(reference_details, "completed", "value")
  let preview = program_payload(preview_details, "completed", "value")
  let applied = program_payload(applied_details, "completed", "value")

  // The bare-name answer includes its declaration and all three callers.
  // The edit below uses exactly the anchor returned for app.gleam line 5.
  assert json_field(references, "total") == json.Int(4)
  let sites = reported_sites(references)
  assert list.length(sites) == 4
  assert list.contains(sites, #(
    "app/src/app.gleam",
    5,
    hashline.anchor(app_call_line),
    app_call_line,
  ))
  assert list.any(sites, fn(site) {
    site.0 == "app/src/app/util.gleam" && site.1 == 1
  })
  assert list.any(sites, fn(site) {
    site.0 == "app/src/app/other.gleam" && site.1 == 4
  })

  // The preview showed the change and wrote nothing: the disk the hook
  // read between the preview and the apply is the fixture with only the
  // anchored edit on it.
  assert json_field(preview, "phase") == json.String("previewed")
  assert string.contains(json.to_string(preview), "welcome")
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
  assert json_field(applied, "phase") == json.String("applied")
  assert json_field(applied, "cap_status") == json.String("answered")
  assert json_field(applied, "written") == json.Int(3)
  let diagnostics = json_field(applied, "diagnostics")
  assert json_field(diagnostics, "status") == json.String("settled")
  assert json_field(diagnostics, "count") == json.Int(0)
  assert landing_statuses(applied)
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
    case gleam_prerequisites(), code_mode_seed() {
      Ok(helper_path), Ok(seed) -> run_stale(helper_path, seed)
      Error(reason), _ | _, Error(reason) ->
        io.println_error("SKIP lsp rename stale: " <> reason)
    }
  })
}

fn stale_turns() -> List(script.Turn) {
  [
    script.ToolUseTurn(
      call_id: "call_preview",
      tool: "code_mode",
      arguments: program_args(rename_program("Preview")),
      input_tokens: 100,
      output_tokens: 5,
    ),
    script.ToolUseTurn(
      call_id: "call_apply",
      tool: "code_mode",
      arguments: program_args(rename_program("Apply")),
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

fn run_stale(helper_path: String, seed: String) -> Nil {
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
    run_session(
      rig,
      helper_path,
      gleam_toml,
      stale_turns(),
      hook,
      "stale",
      seed,
    )

  // The writer is stopped before the disk is read, so what is read is
  // final.
  let assert Ok(control) = process.receive(writers, within: 0)
    as "the hook must have started the writer"
  process.call(control, waiting: 5000, sending: Halt)

  let assert [
    message.UserMessage(..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(tool_name: "code_mode", is_error: False, ..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "code_mode",
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
  assert string.contains(refused, "rename did not land every file")
  let refused_report =
    program_payload(refused_details, "program_failed", "details")
  assert json_field(refused_report, "cap_status") == json.String("answered")
  assert json_field(refused_report, "phase") == json.String("applied")
  assert json_field(refused_report, "written") == json.Int(0)
  assert landing_statuses(refused_report)
    == [
      #("app/src/app.gleam", "not_attempted"),
      #("app/src/app/other.gleam", "rejected"),
      #("app/src/app/util.gleam", "not_attempted"),
    ]

  // A rejected landing names the disk-version race rather than a failed
  // transport or an unsupported request. The capability itself answered.
  let assert json.Array(files) = json_field(refused_report, "files")
    as "the refused apply reports each planned file"
  let assert [rejected] =
    list.filter(files, fn(file) {
      json_field(file, "status") == json.String("rejected")
    })
    as "only the raced file is rejected"
  let assert json.String(reason) = json_field(rejected, "reason")
    as "the rejected file explains the failed check"
  assert string.contains(
    reason,
    "the file changed after the language server computed the rename",
  )

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

/// `gopls` through the same compiled capability path: the definition of a bare
/// name and the references of a qualified one.
pub fn lsp_gopls_end_to_end_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    case go_prerequisites(), code_mode_seed() {
      Error(NotInstalled(reason)), _ ->
        io.println_error(
          "SKIP lsp e2e gopls: gopls or go is not installed (" <> reason <> ")",
        )
      Error(UnknownRoot(reason)), _ ->
        io.println_error(
          "SKIP lsp e2e gopls: go's GOROOT cannot be derived (" <> reason <> ")",
        )
      Ok(#(helper_path, gopls, places)), Ok(seed) ->
        run_gopls(helper_path, gopls, places, seed)
      _, Error(reason) -> io.println_error("SKIP lsp e2e gopls: " <> reason)
    }
  })
}

fn gopls_turns() -> List(script.Turn) {
  [
    script.ToolUseTurn(
      call_id: "call_definition",
      tool: "code_mode",
      arguments: program_args(definition_program("Greet")),
      input_tokens: 100,
      output_tokens: 5,
    ),
    script.ToolUseTurn(
      call_id: "call_refs",
      tool: "code_mode",
      arguments: program_args(references_program("util.Greet")),
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

fn run_gopls(
  helper_path: String,
  gopls: String,
  places: GoPlaces,
  seed: String,
) -> Nil {
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
  // its build and file caches under the user cache directory. Each is a
  // root the operator lists (see `go_places` for where the paths come
  // from), and a jail that grants the wrong cache leaves `go list` unable
  // to write, so `gopls` loads no packages and every definition comes back
  // empty.

  // The cache grant follows the test runner's GOCACHE override. Forwarding
  // the same name makes jailed Go write to the granted path; when unset,
  // both sides retain the native cache default.
  let gopls_cache = parent_directory(places.cache) <> "/gopls"
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
readable = [\"" <> places.root <> "\", \"" <> places.module_cache <> "\"]
writable = [\"" <> places.cache <> "\", \"" <> gopls_cache <> "\"]
env = [\"GOCACHE\", \"GOFLAGS\", \"GOTOOLCHAIN\"]
"
  let messages =
    run_session(
      rig,
      helper_path,
      toml,
      gopls_turns(),
      fn(_) { Nil },
      "gopls",
      seed,
    )
  let assert [
    message.UserMessage(..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "code_mode",
      is_error: False,
      content: definition,
      details: Some(definition_details),
      ..,
    ),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "code_mode",
      is_error: False,
      content: references,
      details: Some(reference_details),
      ..,
    ),
    message.AssistantMessage(stop_reason: message.Stop, ..),
  ] = messages
    as "the gopls run must be two successful queries and an answer"
  io.println_error("lsp e2e gopls definition:\n" <> text_of(definition))
  io.println_error("lsp e2e gopls references:\n" <> text_of(references))
  let definition = program_payload(definition_details, "completed", "value")
  let references = program_payload(reference_details, "completed", "value")
  let definition_line = "func Greet(name string) string {"
  assert list.contains(reported_sites(definition), #(
    "gomod/util/util.go",
    4,
    hashline.anchor(definition_line),
    definition_line,
  ))
  let sites = reported_sites(references)
  assert list.any(sites, fn(site) { site.0 == "gomod/main.go" && site.1 == 6 })
  assert list.any(sites, fn(site) { site.0 == "gomod/main.go" && site.1 == 7 })
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
  seed: String,
) -> List(message.AgentMessage) {
  let assert Ok(parsed) = catalog.parse(toml)
    as "the fixture loom.toml must parse"
  let socket_root =
    "/var/tmp/lsp-cap-" <> int.to_string(ffi_shell.unique_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(socket_root)
    as "the compiled fixture has a shallow capability socket"
  let settings =
    serve.Settings(
      ..settings(rig, helper_path, parsed, hooked(turns, hook), name),
      codemode_seed: seed,
      codemode_sockets: Some(socket_root),
    )
  let assert Ok(instance) = serve.open_instance(settings, log.discard())
    as "the session must boot"
  let outcome = complete(instance)
  serve.close_instance(instance)
  let assert Ok(operation.RunLastResult(outcome: completion, ..)) = outcome
    as "the run must settle"
  assert completion == operation.RunCompleted(operation.CompletedByAssistant)
  let messages = transcript(settings.session_path)

  echo_language_server_results(name, messages)
  let _cleaned = simplifile.delete_all([socket_root])
  messages
}

// Every language-server tool result, printed whole to stderr before any
// assertion reads the transcript. The assertions below print their value
// truncated, which cut the one line that named why a question failed on
// the jailed CI lane (ripgrep was missing there), where the
// enforced jail differs from a developer's container. Stderr survives
// EUnit's capture, so a failure there names its own cause.
fn echo_language_server_results(
  name: String,
  messages: List(message.AgentMessage),
) -> Nil {
  list.each(messages, fn(entry) {
    case entry {
      message.ToolResultMessage(tool_name:, content:, ..) ->
        case string.starts_with(tool_name, "lsp_") || tool_name == "code_mode" {
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
    let assert Ok(body) = json.parse(request.body)
      as "the real provider request is valid JSON"
    let assert json.Array(tools) = json_field(body, "tools")
      as "the provider carries its default tool registry"
    assert !list.any(tools, fn(tool) {
      let assert json.String(name) = json_field(tool, "name")
        as "each registered tool has a name"
      string.starts_with(name, "lsp_")
    })
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
    peer_defaults: None,
    first_prompt: None,
    secrets: secret.env(),
    secret_failures: [],
    session_path: rig.root <> "/session.db",
    domain_paths: None,
    bind_host: "not an interface",
    bind_port: -1,
    token_path: rig.root <> "/transport-only/daemon.token",
    workspace: rig.workspace,
    base_policy: workspace_policy.base_policy(rig.workspace),
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
    codemode_sockets: None,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    retry_policy: retryconf.default_policy,
    deactivated_tools: [],
    memory: distillpass.no_pass(),
    tools: catalog.default_tools(),
    advisor: None,
    go_caches: None,
  )
}

// --- prerequisites -------------------------------------------------------------

// The helper, and a `gleam` the manager can locate.
// The acceptance names a bare symbol, which the manager finds with
// ripgrep before asking the server, so ripgrep is as much a prerequisite
// here as `gleam` is.
fn code_mode_seed() -> Result(String, String) {
  let assert Ok(here) = simplifile.current_directory()
    as "the test package has a working directory"
  let seed = here <> "/../../build/codemode-seed"
  use _ <- result.try(codemode.discover(seed))
  Ok(seed)
}

fn gleam_prerequisites() -> Result(String, String) {
  case jail.find_executable("gleam"), jail.find_executable("rg") {
    Error(Nil), _ -> Error("gleam is not on PATH")
    Ok(_gleam), Error(Nil) -> Error("ripgrep (rg) is not on PATH")
    Ok(_gleam), Ok(_rg) -> jail.prebuilt_helper()
  }
}

// Where the Go toolchain keeps what `gopls` reads and writes.
type GoPlaces {
  GoPlaces(root: String, path: String, cache: String, module_cache: String)
}

// Why the gopls session cannot run. The two are kept apart because the
// declared-skips census accepts "gopls or go is not installed" on a lane
// that ships no language servers, and a lane that has both but cannot
// place the toolchain must not pass as one that lacks them.
type GoSkip {
  NotInstalled(reason: String)
  UnknownRoot(reason: String)
}

// The helper, `go` (which `gopls` shells out to), the places its toolchain
// and caches live, and `gopls` on `PATH` or where `go install` puts it.
fn go_prerequisites() -> Result(#(String, String, GoPlaces), GoSkip) {
  use go <- result.try(
    jail.find_executable("go")
    |> result.replace_error(NotInstalled("go is not on PATH")),
  )
  use places <- result.try(result.map_error(go_places(go), UnknownRoot))
  let installed = places.path <> "/bin/gopls"
  use gopls <- result.try(case jail.find_executable("gopls") {
    Ok(found) -> Ok(found)
    Error(Nil) ->
      case simplifile.is_file(installed) {
        Ok(True) -> Ok(installed)
        Ok(False) | Error(_) -> Error(NotInstalled("gopls was not found"))
      }
  })
  jail.prebuilt_helper()
  |> result.map_error(NotInstalled)
  |> result.map(fn(helper) { #(helper, gopls, places) })
}

// The places `go env` would report, read from the environment `go` itself
// reads and the defaults it falls back to, because a shell command to ask
// it would be a custom external for a question the filesystem answers.
// `GOROOT` falls back to the directory above the `bin` holding `go`, which
// is where a toolchain unpacks, after following the link `go` was found
// through, since Homebrew's `bin/go` is a link into the toolchain's
// `libexec`. It is refused unless it holds the standard library's sources.
// A root that cannot be derived skips the variant under its own text. The build
// cache is the first of the per-platform defaults that exists, since the
// cache directory is `~/.cache` on Linux and `~/Library/Caches` on macOS,
// and a jail that grants the wrong one leaves `go list` unable to write.
fn go_places(go: String) -> Result(GoPlaces, String) {
  let home = absolute_env("HOME")
  let path =
    absolute_env("GOPATH")
    |> result.try(fn(listed) {
      string.split(listed, ":") |> list.first |> result.replace_error(Nil)
    })
    |> result.lazy_or(fn() { result.map(home, fn(h) { h <> "/go" }) })
  use root <- result.try(
    absolute_env("GOROOT")
    |> result.lazy_or(fn() {
      fs.resolve_real(fs.real_filesystem(), "/", go)
      |> result.replace_error(Nil)
      |> result.try(fn(real) {
        case string.ends_with(real, "/bin/go") {
          True -> Ok(string.drop_end(real, 7))
          False -> Error(Nil)
        }
      })
    })
    |> result.try(fn(candidate) {
      case simplifile.is_directory(candidate <> "/src/runtime") {
        Ok(True) -> Ok(candidate)
        Ok(False) | Error(_) -> Error(Nil)
      }
    })
    |> result.replace_error("GOROOT is not set and go's root cannot be derived"),
  )
  use path <- result.try(result.replace_error(
    path,
    "neither GOPATH nor HOME is set",
  ))
  let module_cache =
    absolute_env("GOMODCACHE")
    |> result.unwrap(path <> "/pkg/mod")
  let defaults =
    [
      absolute_env("XDG_CACHE_HOME"),
      home |> result.map(fn(h) { h <> "/Library/Caches" }),
      home |> result.map(fn(h) { h <> "/.cache" }),
    ]
    |> list.filter_map(fn(base) { result.map(base, fn(b) { b <> "/go-build" }) })
    |> list.find(fn(candidate) {
      simplifile.is_directory(candidate) == Ok(True)
    })
  use cache <- result.try(
    absolute_env("GOCACHE")
    |> result.lazy_or(fn() { defaults })
    |> result.replace_error("GOCACHE is not set and no go-build cache exists"),
  )
  Ok(GoPlaces(root:, path:, cache:, module_cache:))
}

// An environment variable that holds an absolute path, or nothing.
fn absolute_env(name: String) -> Result(String, Nil) {
  case ffi_shell.get_env(name) {
    Ok("/" <> _ as value) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
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

// These programs serialize the typed capability answers into report values.
// The host checks the committed JSON, so an empty or malformed answer cannot
// pass by printing a plausible sentence.
const site_program =
  "import cap/lsp
import cap/report
import gleam/list
import gleam/string

fn site(value: lsp.Site) -> report.Value {
  report.object([
    #(\"path\", report.string(value.path)),
    #(\"line\", report.int(value.line)),
    #(\"column\", report.int(value.column)),
    #(\"anchor\", report.string(value.anchor)),
    #(\"text\", report.string(value.text)),
  ])
}
"

const references_main =
  "
pub fn main() -> report.Outcome {
  case lsp.references(lsp.symbol(__SYMBOL__)) {
    Ok(found) -> report.value(report.object([
      #(\"total\", report.int(found.total)),
      #(\"sites\", report.list(list.map(found.items, fn(reference) { site(reference.site) }))),
    ]))
    Error(error) -> report.failure(string.inspect(error))
  }
}
"

const definition_main =
  "
pub fn main() -> report.Outcome {
  case lsp.definition(lsp.symbol(__SYMBOL__)) {
    Ok(found) -> report.value(report.object([
      #(\"total\", report.int(found.total)),
      #(\"sites\", report.list(list.map(found.items, site))),
    ]))
    Error(error) -> report.failure(string.inspect(error))
  }
}
"

const rename_template =
  "import cap/lsp
import cap/report
import gleam/list
import gleam/string

fn planned(file: lsp.PlannedFile) -> report.Value {
  report.object([
    #(\"path\", report.string(file.path)),
    #(\"edits\", report.int(file.edits)),
    #(\"changes\", report.list(list.map(file.changes, fn(change) {
      report.object([
        #(\"line\", report.int(change.line)),
        #(\"before\", report.string(change.before)),
        #(\"after\", report.string(change.after)),
      ])
    }))),
  ])
}

fn landing(file: lsp.Landing) -> report.Value {
  case file {
    lsp.Landed(path, edits) -> report.object([
      #(\"path\", report.string(path)),
      #(\"status\", report.string(\"landed\")),
      #(\"edits\", report.int(edits)),
    ])
    lsp.Rejected(path, reason) -> report.object([
      #(\"path\", report.string(path)),
      #(\"status\", report.string(\"rejected\")),
      #(\"reason\", report.string(reason)),
    ])
    lsp.NotAttempted(path) -> report.object([
      #(\"path\", report.string(path)),
      #(\"status\", report.string(\"not_attempted\")),
    ])
  }
}

fn diagnostics(value: lsp.Diagnostics) -> report.Value {
  let #(status, diagnostics) = case value {
    lsp.Settled(items) -> #(\"settled\", items)
    lsp.Unsettled(items) -> #(\"unsettled\", items)
  }
  report.object([
    #(\"status\", report.string(status)),
    #(\"count\", report.int(list.length(diagnostics))),
  ])
}

pub fn main() -> report.Outcome {
  case lsp.rename(lsp.symbol(\"greet\"), \"welcome\", lsp.__MODE__) {
    Ok(lsp.Previewed(files)) -> report.value(report.object([
      #(\"phase\", report.string(\"previewed\")),
      #(\"files\", report.list(list.map(files, planned))),
    ]))
    Ok(lsp.Applied(files, after)) -> {
      let payload = report.object([
        #(\"phase\", report.string(\"applied\")),
        #(\"cap_status\", report.string(\"answered\")),
        #(\"written\", report.int(list.count(files, fn(file) {
          case file {
            lsp.Landed(_, _) -> True
            lsp.Rejected(_, _) | lsp.NotAttempted(_) -> False
          }
        }))),
        #(\"files\", report.list(list.map(files, landing))),
        #(\"diagnostics\", diagnostics(after)),
      ])
      case list.all(files, fn(file) {
        case file {
          lsp.Landed(_, _) -> True
          lsp.Rejected(_, _) | lsp.NotAttempted(_) -> False
        }
      }) {
        True -> report.value(payload)
        False -> report.Errored(\"rename did not land every file\", payload)
      }
    }
    Error(error) -> report.failure(string.inspect(error))
  }
}
"

fn references_program(symbol: String) -> String {
  site_program
  <> string.replace(
    references_main,
    "__SYMBOL__",
    json.to_string(json.String(symbol)),
  )
}

fn definition_program(symbol: String) -> String {
  site_program
  <> string.replace(
    definition_main,
    "__SYMBOL__",
    json.to_string(json.String(symbol)),
  )
}

fn rename_program(mode: String) -> String {
  string.replace(rename_template, "__MODE__", mode)
}

fn program_args(program: String) -> JsonValue {
  json.Object([
    #("program", json.String(program)),
    #("within_ms", json.Int(120_000)),
  ])
}

// A successful program's value and a failed program's details occupy different
// fields. Checking the status before reading either keeps a compile failure or
// a refused capability from masquerading as a typed rename report.
fn program_payload(
  details: JsonValue,
  status: String,
  field: String,
) -> JsonValue {
  assert json_field(details, "status") == json.String(status)
  json_field(details, field)
}

fn json_field(value: JsonValue, field: String) -> JsonValue {
  let assert json.Object(fields) = value as "the report is an object"
  let assert Ok(value) = list.key_find(fields, field)
    as "the typed report contains the required field"
  value
}

fn reported_sites(value: JsonValue) -> List(#(String, Int, String, String)) {
  let assert json.Array(sites) = json_field(value, "sites")
    as "the typed answer contains a site list"
  list.map(sites, fn(site) {
    let assert json.String(path) = json_field(site, "path")
      as "a reported site has a path"
    let assert json.Int(line) = json_field(site, "line")
      as "a reported site has a line"
    let assert json.String(anchor) = json_field(site, "anchor")
      as "a reported site has a hashline anchor"
    let assert json.String(text) = json_field(site, "text")
      as "a reported site has its source line"
    #(path, line, anchor, text)
  })
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

// --- SQL over real bounded observations ------------------------------------

/// A saved Gleam program reaches real LSP collection and jailed typed SQL.
pub fn lsp_sql_gleam_end_to_end_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    let assert Ok(here) = simplifile.current_directory()
      as "the conformance package has a working directory"
    let seed = here <> "/../../build/codemode-seed"
    case gleam_prerequisites(), codemode.discover(seed) {
      Ok(helper), Ok(_) -> run_sql_gleam(helper, seed)
      Error(reason), _ | _, Error(reason) ->
        io.println_error("SKIP lsp sql gleam: " <> reason)
    }
  })
}

/// Real gopls collection reaches the same production capture and SQLite seam.
pub fn lsp_sql_gopls_end_to_end_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    let assert Ok(here) = simplifile.current_directory()
      as "the conformance package has a working directory"
    let seed = here <> "/../../build/codemode-seed"
    case go_prerequisites(), codemode.discover(seed) {
      Ok(#(helper, gopls, places)), Ok(_) ->
        run_sql_gopls(helper, gopls, places, seed)
      Error(NotInstalled(reason)), _ ->
        io.println_error(
          "SKIP lsp sql gopls: gopls or go is not installed (" <> reason <> ")",
        )
      Error(UnknownRoot(reason)), _ ->
        io.println_error(
          "SKIP lsp sql gopls: go's GOROOT cannot be derived (" <> reason <> ")",
        )
      _, Error(reason) -> io.println_error("SKIP lsp sql gopls: " <> reason)
    }
  })
}

const sql_program_template =
  "import cap/lsp_sql as sql
import cap/report
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string

fn count(row: List(sql.Cell)) -> Result(Int, String) {
  case row { [sql.Integer(n)] -> Ok(n) _ -> Error(\"expected one integer count\") }
}

fn named_count(row: List(sql.Cell)) -> Result(#(String, Int), String) {
  case row { [sql.Text(name), sql.Integer(n)] -> Ok(#(name,n)) _ -> Error(\"expected symbol text and integer count\") }
}

fn named(row: List(sql.Cell)) -> Result(String, String) {
  case row { [sql.Text(name)] -> Ok(name) _ -> Error(\"expected one symbol text\") }
}

pub fn main() -> report.Outcome {
  let path = \"__PATH__\"
  let plan = sql.Plan(\"__SERVER__\", \"__ROOT__\", [path], [sql.Target(\"__USED__\",path,Some(__USEDLINE__)),sql.Target(\"__UNUSED__\",path,Some(__UNUSEDLINE__))])
  let captured = sql.collect(plan)
  case captured {
    Error(error) -> report.failure(string.inspect(error))
    Ok(observation) -> {
      let counted = sql.query(observation, \"SELECT t.symbol,count(r.target_id) FROM targets t LEFT JOIN \\\"references\\\" r ON r.target_id=t.id AND (r.path!=t.path OR r.line!=t.line OR r.column!=t.column) GROUP BY t.id,t.symbol ORDER BY t.id\", [], named_count)
      let unused = sql.query(observation, \"SELECT t.symbol FROM targets t WHERE NOT EXISTS (SELECT 1 FROM \\\"references\\\" r WHERE r.target_id=t.id AND (r.path!=t.path OR r.line!=t.line OR r.column!=t.column)) ORDER BY t.id\", [], named)
      let joined = sql.query(observation, \"SELECT count(*) FROM symbols s JOIN documents d ON d.path=s.path\", [], count)
      let mismatch = sql.query(observation,\"SELECT count(*) FROM symbols\",[],named)
      let denied = sql.query(observation,\"DELETE FROM symbols\",[],count)
      let missing = sql.collect(sql.Plan(\"unconfigured-server\", \"__ROOT__\", [path], []))
      case counted,unused,joined,mismatch,denied,missing {
        Ok(counted),Ok(unused),Ok(joined),Error(sql.DecodeFailed(0,_)),Error(sql.ReadOnlyDenied(_)),Error(sql.InvalidScope(_)) -> {
          let expected = [#(\"__USED__\",__MINREFS__),#(\"__UNUSED__\",0)]
          let complete = counted.rows == expected && unused.rows == [\"__UNUSED__\"] && case joined.rows { [n] -> n >= 2 _ -> False }
          let same = counted.observation == sql.metadata(observation) && unused.observation == counted.observation && joined.observation == counted.observation
          let metadata = sql.metadata(observation)
          let scoped = metadata.server == \"__SERVER__\" && list.length(metadata.outlined) == 1 && list.length(metadata.targets) == 2 && metadata.withheld == 0 && metadata.finished_ms >= metadata.started_ms && string.starts_with(metadata.generation,\"sha256-\")
          case complete && same && scoped {
            True -> report.text(\"lsp-sql-ok references=\" <> string.inspect(counted.rows) <> \" unused=\" <> string.inspect(unused.rows) <> \" joined=\" <> string.inspect(joined.rows) <> \" facts=\" <> int.to_string(metadata.facts))
            False -> report.failure(string.inspect(#(counted,unused,joined,metadata)))
          }
        }
        _,_,_,_,_,_ -> report.failure(string.inspect(#(counted,unused,joined,mismatch,denied,missing)))
      }
    }
  }
}
"

fn sql_program(
  server: String,
  root: String,
  path: String,
  used: String,
  unused: String,
  used_line: Int,
  unused_line: Int,
  references: Int,
) -> String {
  sql_program_template
  |> string.replace("__SERVER__", server)
  |> string.replace("__ROOT__", root)
  |> string.replace("__PATH__", path)
  |> string.replace("__USED__", used)
  |> string.replace("__UNUSED__", unused)
  |> string.replace("__USEDLINE__", int.to_string(used_line))
  |> string.replace("__UNUSEDLINE__", int.to_string(unused_line))
  |> string.replace("__MINREFS__", int.to_string(references))
}

fn run_sql_gleam(helper: String, seed: String) -> Nil {
  let rig = rig("sql-gleam")
  write(
    rig.workspace <> "/app/gleam.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ntarget = \"erlang\"\n",
  )
  write(
    rig.workspace <> "/app/src/app/util.gleam",
    "pub fn greet() -> String { \"hello\" }\n\npub fn lonely() -> String { \"unused\" }\n\npub fn twice() -> String { greet() <> greet() }\n",
  )
  // The saved program exercises the production filesystem admission and
  // source loader before the same compile, vet, jail, LSP and SQLite path.
  let program_path = "observe.gleam"
  write(
    rig.workspace <> "/" <> program_path,
    sql_program(
      "gleam",
      "app",
      "app/src/app/util.gleam",
      "greet",
      "lonely",
      1,
      3,
      2,
    ),
  )
  run_sql_program(
    rig,
    helper,
    gleam_toml,
    seed,
    json.Object([
      #("program_path", json.String(program_path)),
      #("within_ms", json.Int(120_000)),
    ]),
    "sql-gleam",
  )
}

fn run_sql_gopls(
  helper: String,
  gopls: String,
  places: GoPlaces,
  seed: String,
) -> Nil {
  let rig = rig("sql-gopls")
  let module = rig.workspace <> "/gomod"
  write(module <> "/go.mod", "module example.com/probe\n\ngo 1.21\n")
  write(
    module <> "/util/util.go",
    "package util\n\nfunc Greet() string { return \"hello\" }\n\nfunc Lonely() string { return \"unused\" }\n\nfunc Twice() string { return Greet() + Greet() }\n",
  )
  let gopls_cache = parent_directory(places.cache) <> "/gopls"
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
readable = [\"" <> places.root <> "\", \"" <> places.module_cache <> "\"]
writable = [\"" <> places.cache <> "\", \"" <> gopls_cache <> "\"]
env = [\"GOFLAGS\", \"GOTOOLCHAIN\"]
"
  run_sql_program(
    rig,
    helper,
    toml,
    seed,
    program_args(sql_program(
      "go",
      "gomod",
      "gomod/util/util.go",
      "Greet",
      "Lonely",
      3,
      5,
      2,
    )),
    "sql-gopls",
  )
}

fn run_sql_program(
  rig: Rig,
  helper: String,
  toml: String,
  seed: String,
  arguments: JsonValue,
  name: String,
) -> Nil {
  let turns = [
    script.ToolUseTurn(
      call_id: "sql-observation",
      tool: "code_mode",
      arguments:,
      input_tokens: 100,
      output_tokens: 5,
    ),
    script.AnswerTurn(
      text: "SQL observation received",
      input_tokens: 110,
      output_tokens: 5,
    ),
  ]
  let assert Ok(parsed) = catalog.parse(toml)
    as "the SQL fixture profile is valid"
  let socket_root =
    "/var/tmp/lsp-sql-" <> int.to_string(ffi_shell.unique_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(socket_root)
    as "the real jailed program has a shallow capability socket"
  let settings =
    serve.Settings(
      ..settings(rig, helper, parsed, script.transport(turns), name),
      codemode_seed: seed,
      codemode_sockets: Some(socket_root),
    )
  let assert Ok(instance) = serve.open_instance(settings, log.discard())
    as "production boot wires the observation door"
  let outcome = complete(instance)
  serve.close_instance(instance)
  let assert Ok(operation.RunLastResult(outcome: completion, ..)) = outcome
    as "the SQL fixture operation settles"
  assert completion == operation.RunCompleted(operation.CompletedByAssistant)
  let messages = transcript(settings.session_path)
  echo_language_server_results(name, messages)
  let assert [content] =
    list.filter_map(messages, fn(entry) {
      case entry {
        message.ToolResultMessage(
          tool_name: "code_mode",
          is_error: False,
          content:,
          ..,
        ) -> Ok(content)
        _other -> Error(Nil)
      }
    })
    as "one successful real code-mode SQL result is persisted"
  let text = result_text(content)
  io.println_error("lsp SQL " <> name <> ": " <> text)
  assert string.contains(text, "lsp-sql-ok references=")
  let _cleaned = simplifile.delete_all([socket_root])
  Nil
}
