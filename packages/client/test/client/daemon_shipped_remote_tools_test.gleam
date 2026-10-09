//// The workspace tools, hooks, goal checks and Git observation of a registered
//// session, against the shipped daemon: an orchestrator and an executor, two
//// real `bin/loomd` processes that trust each other over TLS distribution
//// (issue #697, protocol-change/078).
////
//// `daemon_shipped_remote_test` proves that `fs_write`, `bash` and `fs_read`
//// reach the executor's checkout. Phase 1 of the distributed runtime requires
//// the rest of the workspace plane to work there too, with the checkout absent
//// from the orchestrator. Each test below boots one pair, drives a session
//// through a scripted model, and reads the result where the model reads it and
//// where the executor kept it.
////
//// ## What it proves
////
//// `daemon_shipped_remote_search_and_cwd_test_`, one session across a reopen.
////
//// - `grep` finds a pattern in files that only the executor's checkout holds,
////   and its `globs` argument narrows the search to the files it names.
//// - `working_directory` selects a subdirectory of the checkout, and the next
////   `bash` call reports the executor-side path. A `bash` call's own `cwd`
////   moves that one call and leaves the selection alone. The orchestrator
////   keeps the selection as the `client/working_directory/main` fact in its
////   own store, so after the session is stopped and opened again the next
////   `bash` call still starts in the subdirectory.
//// - None of the checkout's files or directories exists on the orchestrator.
////
//// `daemon_shipped_remote_jobs_test_`, one session with two background jobs.
////
//// - A `bash` call whose `timeout_ms` passes becomes a background job that
////   waits for a file in the checkout. When the test creates the file the job
////   ends, the executor sends its completion notice to the orchestrator, and
////   the orchestrator wakes the idle session with it. The model answers by
////   reading the job with `job_poll` and finds the exit status and the output,
////   which names the executor's path.
//// - A second job, started with `mode: "background"`, appends to a file in the
////   checkout every fifth of a second. `job_kill` stops it, `job_poll` reports
////   it stopped at the owner's request, and the file stops growing, so the
////   process is gone from the executor.
//// - The `live_jobs` command lists both jobs while they run and none once they
////   have ended, and the orchestrator's store holds a `job/<id>` record for
////   each, in the phase the job ended in.
////
//// `daemon_shipped_remote_hooks_test_`, two sessions on one pair.
////
//// - The checkout's `.claude/settings.json` holds four hooks. A session opened
////   before the operator trusts that file runs none of them. The trust record
////   is the orchestrator's, written against the hash of the bytes the executor
////   sent.
//// - After the record is written a second session runs the `SessionStart` hook
////   once, and its output rides the session's first request. The `PreToolUse`
////   hook runs on the executor around a `bash` call: it is handed the call as
////   JSON, its working directory is the executor's checkout, and it leaves its
////   log there. The `PostToolUse` hook runs after the call and replaces the
////   output the model reads.
//// - A `PreToolUse` hook that exits 2 refuses an `fs_write`. The model reads the
////   hook's message as the error result, and the file is never created.
////
//// `daemon_shipped_remote_goal_test_`, two goals pinned on one session.
////
//// - A goal's check runs through the executor's broker in the executor's
////   checkout. One check names a file only the executor holds and passes,
////   printing the executor's path. The other names a file only the orchestrator
////   holds and fails there. Each result is on the goal board and in the feed the
////   reviewer is sent. The reviewer is a second scripted provider that completes
////   each goal, because the check, not the verdict, is under test.
////
//// `daemon_shipped_remote_git_and_guidance_test_`, one session over a repository.
////
//// - The executor's `AGENTS.md` and `CLAUDE.md` reach the system prompt of every
////   request, framed with the path they were read at. The operator's global
////   `AGENTS.md`, which lives on the orchestrator, reaches it too. Same-named
////   files in the orchestrator's launch directory, under the registered name
////   there, and in its home, reach no request.
//// - Git runs on the executor. The model's `git` call reports the executor's
////   branch and commit. The orchestrator's store records that commit as the
////   session's starting revision, and the repository root and branch in the
////   peer observation, all taken through the executor's broker. The worktree
////   observation lists a file the model added after the session began.
//// - The system prompt itself carries no Git state, local or remote
////   (`prompt/default`), so the Git facts are read where the harness keeps them.
////
//// ## Prerequisites and skips
////
//// Every test needs the shipment and a helper that enforces a policy, and a
//// search test needs `rg` and a Git test needs `git` for the programs the jailed
//// tools run. A host without one prints a `SKIP shipped remote tools: ...` line
//// naming it and passes, as the other shipped fixtures do.
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_tools_test:'
//// ```
////
//// The fixture is the one `daemon_shipped_remote_test` documents, arranged for
//// a single pair by `support/remote_pair`.

import client/advisorslice
import client/hookcompat
import client/hookserve
import client/hooktrust
import client/tui_e2e_test.{type EunitTest}
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import simplifile
import support/internal/ffi_proc
import support/provider_http as provider
import support/remote_daemons
import support/remote_pair.{type Pair}
import tools/advise
import weft/poll

const skip_label = "shipped remote tools"

// --- search and working directory --------------------------------------------

const search_prompt = "survey the repository"

const search_answer = "surveyed"

const where_prompt = "where am I now"

const where_answer = "located"

// Two files hold the pattern and only one is Markdown, so a glob that keeps
// only `*.md` is told apart from a search that ignores it.
const notes_path = "survey/notes.txt"

const notes_text = "alpha\nneedle one\nomega\n"

const guide_path = "survey/guide.md"

const guide_text = "# guide\nneedle two\n"

fn tool_call(
  after: String,
  call: String,
  tool: String,
  arguments: json.JsonValue,
) -> provider.Exchange {
  provider.ComputedExchange(provider.AwaitToolResult(after), fn(_seen) {
    provider.ReplyToolUse(call, tool, arguments)
  })
}

fn answer_after(call: String, text: String) -> provider.Exchange {
  provider.ComputedExchange(provider.AwaitToolResult(call), fn(_seen) {
    provider.ReplyText(text)
  })
}

fn search_script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      search_prompt,
      "grep-all",
      "grep",
      json.Object([#("pattern", json.String("needle"))]),
    ),
    tool_call(
      "grep-all",
      "grep-md",
      "grep",
      json.Object([
        #("pattern", json.String("needle")),
        #("globs", json.Array([json.String("*.md")])),
      ]),
    ),
    tool_call(
      "grep-md",
      "cd-call",
      "working_directory",
      json.Object([#("path", json.String("survey"))]),
    ),
    tool_call(
      "cd-call",
      "pwd-call",
      "bash",
      json.Object([#("command", json.String("pwd"))]),
    ),

    // One call may name another directory without moving the selection.
    tool_call(
      "pwd-call",
      "up-call",
      "bash",
      json.Object([
        #("command", json.String("pwd")),
        #("cwd", json.String("..")),
      ]),
    ),
    answer_after("up-call", search_answer),
    provider.ToolUseExchange(
      where_prompt,
      "again-call",
      "bash",
      json.Object([#("command", json.String("pwd"))]),
    ),
    answer_after("again-call", where_answer),
  ]
}

/// Searches the executor's checkout, selects a subdirectory, and finds the
/// selection again after the session is stopped and opened.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_tools_test:'`.
pub fn daemon_shipped_remote_search_and_cwd_test_() -> EunitTest {
  remote_pair.shipped(skip_label, ["rg"], search_and_cwd)
}

fn search_and_cwd(prepared: Pair) -> Nil {
  let keys = remote_pair.provision(prepared)
  remote_pair.write_files(prepared.checkout, [
    #(notes_path, notes_text),
    #(guide_path, guide_text),
  ])
  let #(Nil, report) =
    provider.with_server_for(
      search_script(),
      provider.OnlySuccessful,
      remote_pair.callback_ms,
      fn(url) {
        remote_pair.configure(prepared, keys, remote_pair.plain(url))
        let opened = remote_pair.open_registered(prepared, [], "e2e-search")
        remote_pair.converse_for(opened, search_prompt, [search_answer])
        remote_pair.stop_and_close(prepared, opened, 1)

        // The choice is the orchestrator's fact, and the executor is asked
        // for it again when the session comes back.
        assert remote_pair.session_fact(
            prepared,
            opened.session,
            "client/working_directory/main",
          )
          == option.Some(json.String(prepared.checkout <> "/survey"))
        remote_pair.reopen(opened, 2000)
        remote_pair.converse_for(opened, where_prompt, [
          search_answer,
          where_answer,
        ])
        remote_pair.stop_and_close(prepared, opened, 2)
        remote_pair.close_daemons([opened.orchestrator])
      },
    )
  let assert Ok(requests) = report
    as "the provider saw the scripted conversation and nothing else"
  assert_search(requests)
  assert_directory(prepared, requests)
  assert_checkout_absent_from_orchestrator(prepared, [
    "survey", "notes.txt", "guide.md",
  ])
}

// The first search found both files. The glob kept the Markdown one only.
fn assert_search(requests: List(provider.ObservedRequest)) -> Nil {
  let all = remote_daemons.result_text(requests, "grep-all")
  assert string.contains(all, "needle one")
  assert string.contains(all, "needle two")
  assert string.contains(all, "notes.txt")
  assert string.contains(all, "guide.md")
  let markdown = remote_daemons.result_text(requests, "grep-md")
  assert string.contains(markdown, "needle two")
  assert string.contains(markdown, "guide.md")
  assert !string.contains(markdown, "needle one")
  assert !string.contains(markdown, "notes.txt")
}

// The selection and the shell that followed it both name the executor's path.
fn assert_directory(
  prepared: Pair,
  requests: List(provider.ObservedRequest),
) -> Nil {
  let directory = prepared.checkout <> "/survey"
  let selected = remote_daemons.result_text(requests, "cd-call")
  assert string.contains(selected, "shell cwd: " <> directory)
  assert string.contains(selected, "workspace: " <> prepared.checkout)
  assert string.trim(remote_daemons.result_text(requests, "pwd-call"))
    == directory
  assert string.trim(remote_daemons.result_text(requests, "up-call"))
    == prepared.checkout
  assert string.trim(remote_daemons.result_text(requests, "again-call"))
    == directory
}

// Nothing by these names exists anywhere in the orchestrator's directory or
// its home, so no part of what the executor holds was copied or created there.
fn assert_checkout_absent_from_orchestrator(
  prepared: Pair,
  names: List(String),
) -> Nil {
  list.each(names, fn(name) {
    remote_daemons.assert_absent_from(
      [prepared.orchestrator.directory, prepared.orchestrator.home],
      name,
    )
  })
}

// --- background jobs ----------------------------------------------------------

const jobs_prompt = "start the jobs"

const jobs_started = "jobs started"

const jobs_done = "jobs done"

// The first job waits for a file the test creates, so its end happens when the
// test says and not when a timer does: a job that ended while the model was
// still in its run would be reported as a steer in the middle of the turn.
const quick_command =
  "while [ ! -f go ]; do sleep 0.2; done; echo quick-finished-in $(pwd)"

// The second job never ends by itself. It appends a line to a file in the
// checkout every fifth of a second, so a file that stops growing is the
// evidence that the process behind the job is gone.
const beat_command = "while true; do echo tick >> beat.log; sleep 0.2; done"

fn background(command: String) -> json.JsonValue {
  json.Object([
    #("command", json.String(command)),
    #("mode", json.String("background")),
  ])
}

// A call in the default mode with a window too short for the command. It is
// not killed when the window passes: it becomes a background job, and the
// answer names the job.
fn outlasting(command: String) -> json.JsonValue {
  json.Object([
    #("command", json.String(command)),
    #("timeout_ms", json.Int(1000)),
  ])
}

// The job id a `bash` call announced, read back out of the evidence the way a
// model reads it from the sentence. Two sentences name one: the start of a
// background job, and the hand-off of a call that outlived its window.
fn started_id(seen: List(provider.ObservedRequest), call: String) -> String {
  let text = remote_daemons.result_text(seen, call)
  let assert Ok(#(_before, rest)) =
    string.split_once(text, on: "background job ")
    as "a call that runs a job names it"
  let assert [word, ..] = string.split(rest, on: " ")
    as "the job's id is the word after the phrase"
  let assert [id, ..] = string.split(word, on: ",")
    as "a comma may close the id"
  id
}

fn jobs_script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      jobs_prompt,
      "quick-call",
      "bash",
      outlasting(quick_command),
    ),
    tool_call("quick-call", "beat-call", "bash", background(beat_command)),
    answer_after("beat-call", jobs_started),

    // The quick job ends after the test releases it, the executor tells the
    // orchestrator, and the orchestrator wakes the idle session with a notice
    // that names the job. The model answers by reading that job.
    provider.ComputedExchange(
      provider.AwaitPromptPrefix("[loom] background job "),
      fn(seen) {
        provider.ReplyToolUse(
          "poll-quick",
          "job_poll",
          json.Object([
            #("job_id", json.String(started_id(seen, "quick-call"))),
          ]),
        )
      },
    ),
    provider.ComputedExchange(provider.AwaitToolResult("poll-quick"), fn(seen) {
      provider.ReplyToolUse(
        "kill-call",
        "job_kill",
        json.Object([#("job_id", json.String(started_id(seen, "beat-call")))]),
      )
    }),
    provider.ComputedExchange(provider.AwaitToolResult("kill-call"), fn(seen) {
      provider.ReplyToolUse(
        "poll-beat",
        "job_poll",
        json.Object([
          #("job_id", json.String(started_id(seen, "beat-call"))),
          #("wait_ms", json.Int(20_000)),
        ]),
      )
    }),
    answer_after("poll-beat", jobs_done),
  ]
}

/// Starts two background jobs, reads one that ended by itself through the
/// notice it sent, and stops the other.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_tools_test:'`.
pub fn daemon_shipped_remote_jobs_test_() -> EunitTest {
  remote_pair.shipped(skip_label, [], jobs)
}

fn jobs(prepared: Pair) -> Nil {
  let keys = remote_pair.provision(prepared)
  let #(opened, report) =
    provider.with_server_for(
      jobs_script(),
      provider.OnlySuccessful,
      remote_pair.callback_ms,
      fn(url) {
        remote_pair.configure(prepared, keys, remote_pair.plain(url))
        let opened = remote_pair.open_registered(prepared, [], "e2e-jobs")
        remote_pair.converse_for(opened, jobs_prompt, [jobs_started])

        // Both jobs are live on the executor: the beat file grows, and the
        // quick job has not been released. The orchestrator lists both from
        // the records the executor wrote to its store.
        await_lines(prepared.checkout <> "/beat.log", 3)
        assert simplifile.is_file(prepared.checkout <> "/go") == Ok(False)
        let socket = remote_pair.session_socket(opened)
        let #(live, socket) = live_jobs(socket)
        assert remote_daemons.field(live, "total") == json.Int(2)
        let assert json.Array(rows) = remote_daemons.field(live, "jobs")
        assert list.map(rows, remote_daemons.field(_, "state"))
          == [json.String("running"), json.String("running")]

        // Releasing the quick job ends it. Nothing is typed from here: the
        // rest of the conversation is the notice's wake.
        remote_pair.write_files(prepared.checkout, [#("go", "")])
        remote_pair.await_answers(opened, [jobs_started, jobs_done])
        assert_beat_stopped(prepared.checkout <> "/beat.log")
        let #(settled, _socket) = live_jobs(socket)
        assert remote_daemons.field(settled, "total") == json.Int(0)
        remote_pair.stop_and_close(prepared, opened, 1)
        remote_pair.close_daemons([opened.orchestrator])
        opened
      },
    )
  let assert Ok(requests) = report
    as "the provider saw the scripted conversation and nothing else"
  assert_jobs(prepared, requests, opened.session)
  assert_checkout_absent_from_orchestrator(prepared, ["beat.log", "go"])
}

// The strand's live jobs as the session socket reports them: the board the
// owner reads, built from the job records in the orchestrator's store.
fn live_jobs(
  socket: remote_pair.SessionSocket,
) -> #(json.JsonValue, remote_pair.SessionSocket) {
  let #(reply, socket) =
    remote_pair.session_command(
      socket,
      "live_jobs",
      json.Object([#("strand", json.String("main"))]),
    )
  #(remote_daemons.field(remote_daemons.field(reply, "body"), "board"), socket)
}

// Waits until `path` holds at least `count` lines.
fn await_lines(path: String, count: Int) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 30_000, every: 50, attempt: fn() {
      case line_count(path) >= count {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as { path <> " grows while its job runs" }
  Nil
}

fn line_count(path: String) -> Int {
  case simplifile.read(path) {
    Ok(text) -> list.length(string.split(text, "\n")) - 1
    Error(_) -> 0
  }
}

// The job was stopped, so its file stops growing. A process that outlived its
// job would add a line every fifth of a second, so a quiet second is five
// missed lines.
fn assert_beat_stopped(path: String) -> Nil {
  let before = line_count(path)
  process.sleep(1000)
  assert line_count(path) == before
}

// The quick job finished by itself in the executor's checkout, and its output
// reached the model through `job_poll`. The beat job was stopped on request.
//
// The orchestrator holds the jobs' records, which the executor wrote through
// the owner port: one `job/<id>` cell each, in the phase the job ended in.
fn assert_jobs(
  prepared: Pair,
  requests: List(provider.ObservedRequest),
  session: String,
) -> Nil {
  let handed_off = remote_daemons.result_text(requests, "quick-call")
  assert string.contains(handed_off, "now as background job ")
  let quick = remote_daemons.result_text(requests, "poll-quick")
  assert string.contains(quick, "finished, exit code 0")
  assert string.contains(quick, "quick-finished-in " <> prepared.checkout)
  let killed = remote_daemons.result_text(requests, "kill-call")
  assert string.starts_with(killed, "stopped ")
  let beat = remote_daemons.result_text(requests, "poll-beat")
  assert string.contains(beat, "stopped (you asked)")
  assert job_phase(prepared, session, started_id(requests, "quick-call"))
    == "exited"
  assert job_phase(prepared, session, started_id(requests, "beat-call"))
    == "killed"
}

// The phase the orchestrator's record of a job says it ended in.
fn job_phase(prepared: Pair, session: String, id: String) -> String {
  let assert option.Some(record) =
    remote_pair.session_fact(prepared, session, "job/" <> id)
    as "the orchestrator holds the job's record"
  let assert json.String(phase) =
    remote_daemons.field(remote_daemons.field(record, "state"), "phase")
    as "a record names its phase"
  phase
}

// --- project hooks -----------------------------------------------------------

// The first session loads the checkout's hooks without the operator's yes and
// runs none of them. The second loads the same file after the yes is recorded
// and runs them around its calls.
const untrusted_prompt = "run it untrusted"

const untrusted_answer = "untrusted done"

const trusted_prompt = "run it trusted"

const trusted_answer = "trusted done"

// What the blocking hook writes to standard error, which the contract routes to
// the model as the reason for the refusal.
const freeze_reason = "project hook: the checkout is frozen"

// What the `PostToolUse` hook puts in place of the call's output.
const post_note = "post-hook-note"

// The file the refused write would have created.
const frozen_path = "frozen.txt"

// What the `SessionStart` hook prints, which the harness adds to the model's
// first request of a session.
const start_context = "session-start-ran-on-executor"

fn hook(matcher: String, command: String) -> json.JsonValue {
  json.Object([
    #("matcher", json.String(matcher)),
    #(
      "hooks",
      json.Array([
        json.Object([
          #("type", json.String("command")),
          #("command", json.String(command)),
          #("timeout", json.Int(30)),
        ]),
      ]),
    ),
  ])
}

// The checkout's `.claude/settings.json`, in the shape Claude reads. Every
// effect lands in a file under `$CLAUDE_PROJECT_DIR`, which a jailed hook may
// write, and which names the checkout the hook ran in.
fn hook_settings() -> String {
  let log = fn(name) { "cat >> \"$CLAUDE_PROJECT_DIR/" <> name <> "\"" }
  json.to_string(
    json.Object([
      #(
        "hooks",
        json.Object([
          #(
            "SessionStart",
            json.Array([
              hook(
                "startup",
                "pwd >> \"$CLAUDE_PROJECT_DIR/hook-start.log\"; echo "
                  <> start_context,
              ),
            ]),
          ),
          #(
            "PreToolUse",
            json.Array([
              hook(
                "Bash",
                log("hook-pre.log")
                  <> "; echo >> \"$CLAUDE_PROJECT_DIR/hook-pre.log\"",
              ),
              hook("Write", "echo '" <> freeze_reason <> "' >&2; exit 2"),
            ]),
          ),
          #(
            "PostToolUse",
            json.Array([
              hook(
                "Bash",
                log("hook-post.log")
                  <> "; echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"updatedToolOutput\":{\"note\":\""
                  <> post_note
                  <> "\"}}}'",
              ),
            ]),
          ),
        ]),
      ),
    ]),
  )
}

fn hooks_script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      untrusted_prompt,
      "plain-call",
      "bash",
      json.Object([#("command", json.String("echo one"))]),
    ),
    answer_after("plain-call", untrusted_answer),
    provider.ToolUseExchange(
      trusted_prompt,
      "hooked-call",
      "bash",
      json.Object([#("command", json.String("echo two"))]),
    ),
    tool_call(
      "hooked-call",
      "frozen-call",
      "fs_write",
      json.Object([
        #("path", json.String(frozen_path)),
        #("content", json.String("never written\n")),
      ]),
    ),
    provider.ComputedExchange(
      provider.AwaitFailedToolResult("frozen-call"),
      fn(_seen) { provider.ReplyText(trusted_answer) },
    ),
  ]
}

/// Loads a hook file that the checkout holds, runs it around a call on the
/// executor once the operator has trusted it, and lets it refuse a write.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_tools_test:'`.
pub fn daemon_shipped_remote_hooks_test_() -> EunitTest {
  remote_pair.shipped(skip_label, [], hooks)
}

fn hooks(prepared: Pair) -> Nil {
  let keys = remote_pair.provision(prepared)
  remote_pair.write_files(prepared.checkout, [
    #(".claude/settings.json", hook_settings()),
  ])
  let #(Nil, report) =
    provider.with_server_for(
      hooks_script(),
      provider.AlsoFailed,
      remote_pair.callback_ms,
      fn(url) {
        remote_pair.configure(prepared, keys, remote_pair.plain(url))
        let first = remote_pair.open_registered(prepared, [], "e2e-hooks-first")

        // The file arrived with the checkout and nobody has trusted it, so
        // the call runs bare.
        remote_pair.converse_for(first, untrusted_prompt, [untrusted_answer])
        assert !present(prepared.checkout <> "/hook-pre.log")
        remote_pair.stop_and_close(prepared, first, 1)

        // The trust record is the orchestrator's: it holds the operator's yes
        // against the hash of the bytes the executor sent.
        trust_project_hooks(prepared)
        let second =
          remote_pair.register_another(first, 1000, "e2e-hooks-second")
        remote_pair.converse_for(second, trusted_prompt, [trusted_answer])
        remote_pair.stop_and_close(prepared, second, 1)
        remote_pair.close_daemons([second.orchestrator])
      },
    )
  let assert Ok(requests) = report
    as "the provider saw both conversations and nothing else"
  assert_hooks(prepared, requests)
  assert_checkout_absent_from_orchestrator(prepared, [
    "hook-pre.log", "hook-post.log", frozen_path, "settings.json",
  ])
}

// Records the operator's yes for the checkout's settings file, as the intended
// `loom hooks trust` will: against the hash of the definition read from the
// file, in the record directory beside the orchestrator's home.
fn trust_project_hooks(prepared: Pair) -> Nil {
  let home = prepared.orchestrator.home
  let assert [_user, project, _local] =
    hookserve.locations(option.Some(home), prepared.checkout)
    as "the session imports three settings files"
  let assert hookserve.Bytes(bytes) = hookserve.read_contents(project.path)
    as "the executor's checkout holds the settings file"
  let assert Ok(text) = bit_array.to_string(bytes)
    as "the settings file is text"
  let assert Ok(config) =
    hookcompat.parse_claude_settings(
      text,
      hookcompat.Source(label: project.path, origin: project.origin),
    )
    as "the settings file parses"
  let assert Ok(Nil) =
    hooktrust.trust(
      hooktrust.record_path(home <> "/hooktrust", project.path),
      config,
      1,
    )
    as "the trust record is written"
  Nil
}

// What the trusted session's hooks did on the executor and what the model saw.
fn assert_hooks(
  prepared: Pair,
  requests: List(provider.ObservedRequest),
) -> Nil {
  // The start hook ran once, in the executor's checkout, and its output rode
  // the trusted session's first request and no other.
  assert string.trim(remote_pair.read_file(prepared.checkout, "hook-start.log"))
    == prepared.checkout
  let began = "[SessionStart hook] " <> start_context
  let assert Ok(untrusted_first) = request_to(requests, untrusted_prompt)
  assert !string.contains(remote_pair.request_text(untrusted_first.body), began)
  let assert Ok(trusted_first) = request_to(requests, trusted_prompt)
  assert string.contains(remote_pair.request_text(trusted_first.body), began)

  // The pre hook ran before the call, in the executor's checkout, and was
  // handed the call. The post hook ran after it. Each ran once, for the one
  // trusted `bash` call.
  let pre = remote_pair.read_file(prepared.checkout, "hook-pre.log")
  assert string.contains(pre, "\"hook_event_name\":\"PreToolUse\"")
  assert string.contains(pre, "echo two")
  assert string.contains(pre, prepared.checkout)
  assert occurrences(pre, "PreToolUse") == 1
  let post = remote_pair.read_file(prepared.checkout, "hook-post.log")
  assert string.contains(post, "\"hook_event_name\":\"PostToolUse\"")
  assert occurrences(post, "PostToolUse") == 1

  // The model read what the post hook put in place of the call's output. A
  // result with the hook's note beside the output would be a second content
  // block, which the scripted provider does not admit.
  let hooked = remote_daemons.result_text(requests, "hooked-call")
  assert hooked == "{\"note\":\"" <> post_note <> "\"}"

  // The blocking hook's reason is the error the model read, and the write it
  // refused never happened.
  let refused = remote_daemons.failed_result_text(requests, "frozen-call")
  assert string.contains(refused, freeze_reason)
  assert !present(prepared.checkout <> "/" <> frozen_path)
}

// --- Git and guidance --------------------------------------------------------

const git_prompt = "check the repository"

const git_answer = "checked"

const branch_name = "e2e-trunk"

// What each guidance file says, so a request body can be searched for the file
// it came from. The orchestrator's decoys carry a word of their own, and a
// request that holds it read a path on the orchestrator.
const executor_agents = "executor-agents-sentinel"

const executor_claude = "executor-claude-sentinel"

const global_guidance = "orchestrator-global-sentinel"

const decoy_guidance = "decoy-orchestrator-sentinel"

fn git_script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      git_prompt,
      "git-call",
      "bash",
      json.Object([
        #(
          "command",
          json.String("git rev-parse --abbrev-ref HEAD && git rev-parse HEAD"),
        ),
      ]),
    ),
    tool_call(
      "git-call",
      "scratch-call",
      "fs_write",
      json.Object([
        #("path", json.String("scratch.txt")),
        #("content", json.String("new\n")),
      ]),
    ),
    answer_after("scratch-call", git_answer),
  ]
}

/// Reads the guidance files and the Git state of the executor's checkout, and
/// none of the orchestrator's same-named files.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_tools_test:'`.
pub fn daemon_shipped_remote_git_and_guidance_test_() -> EunitTest {
  remote_pair.shipped(skip_label, ["git"], git_and_guidance)
}

fn git_and_guidance(prepared: Pair) -> Nil {
  let keys = remote_pair.provision(prepared)
  remote_pair.write_files(prepared.checkout, [
    #("AGENTS.md", executor_agents <> "\n"),
    #("CLAUDE.md", executor_claude <> "\n"),
    #("README.md", "a repository\n"),
  ])
  let head = commit_repository(prepared.checkout)

  // The orchestrator is given every file the checkout has, under the names the
  // session could be tempted to resolve: its own launch directory, that
  // directory with the registered name beneath it, and its home. The one file
  // it is meant to read is the operator's global guidance.
  remote_pair.write_files(prepared.orchestrator.workspace, [
    #("AGENTS.md", decoy_guidance <> "\n"),
    #("CLAUDE.md", decoy_guidance <> "\n"),
    #(remote_pair.workspace_name <> "/AGENTS.md", decoy_guidance <> "\n"),
    #(remote_pair.workspace_name <> "/CLAUDE.md", decoy_guidance <> "\n"),
  ])
  remote_pair.write_files(prepared.orchestrator.home, [
    #(".agents/AGENTS.md", global_guidance <> "\n"),
    #(remote_pair.workspace_name <> "/AGENTS.md", decoy_guidance <> "\n"),
  ])
  let #(#(board, session), report) =
    provider.with_server_for(
      git_script(),
      provider.OnlySuccessful,
      remote_pair.callback_ms,
      fn(url) {
        remote_pair.configure(prepared, keys, remote_pair.plain(url))
        let opened = remote_pair.open_registered(prepared, [], "e2e-git")
        remote_pair.converse_for(opened, git_prompt, [git_answer])
        let board = worktree_board(remote_pair.session_socket(opened))
        remote_pair.stop_and_close(prepared, opened, 1)
        remote_pair.close_daemons([opened.orchestrator])
        #(board, opened.session)
      },
    )
  let assert Ok(requests) = report
    as "the provider saw the scripted conversation and nothing else"
  assert_guidance(prepared, requests)
  assert_git(prepared, requests, head, board, session)
  assert_checkout_absent_from_orchestrator(prepared, [
    ".git", "scratch.txt", "README.md",
  ])
}

// A repository of one commit on a branch of its own, made on the executor's
// disk. Returns the commit.
fn commit_repository(checkout: String) -> String {
  let assert Ok(git) = ffi_proc.which("git") as "git is on PATH"
  let run = fn(arguments) {
    let assert Ok(#(0, output)) = ffi_proc.run(git, arguments, in: checkout)
      as { "git " <> string.join(arguments, " ") <> " succeeds" }
    output
  }
  let identity = [
    "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c",
    "commit.gpgsign=false",
  ]
  run(["init", "--quiet", "-b", branch_name])
  run(["add", "--", "."])
  run(list.append(identity, ["commit", "--quiet", "-m", "first"]))
  string.trim(run(["rev-parse", "HEAD"]))
}

// Asks for the worktree observation and waits for the finished board, which the
// daemon pushes after acknowledging the command with a pending one.
fn worktree_board(socket: remote_pair.SessionSocket) -> json.JsonValue {
  let #(acknowledged, socket) =
    remote_pair.session_command(socket, "worktree_diff", json.Object([]))
  let pending =
    remote_daemons.field(remote_daemons.field(acknowledged, "body"), "board")
  assert remote_daemons.field(pending, "status") == json.String("pending")
  next_board(socket, 20)
}

fn next_board(
  socket: remote_pair.SessionSocket,
  remaining: Int,
) -> json.JsonValue {
  assert remaining > 0
    as "the worktree board arrives in a bounded run of frames"
  let frame = remote_pair.next_frame(socket)
  let board = case frame {
    json.Object(fields) ->
      case list.key_find(fields, "body") {
        Ok(json.Object(body)) -> list.key_find(body, "board")
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case board {
    Ok(json.Object(fields) as found) ->
      case list.key_find(fields, "status") {
        Ok(json.String("ready")) -> found
        _ -> next_board(socket, remaining - 1)
      }
    _ -> next_board(socket, remaining - 1)
  }
}

// Every request carried the executor's two guidance files, framed with the
// path the executor read them at, and the operator's own global file. No
// request carried a word of the orchestrator's decoys.
fn assert_guidance(
  prepared: Pair,
  requests: List(provider.ObservedRequest),
) -> Nil {
  assert requests != []
  list.each(requests, fn(request) {
    let text = remote_pair.request_text(request.body)
    assert string.contains(text, executor_agents)
    assert string.contains(text, executor_claude)
    assert string.contains(text, global_guidance)
    assert !string.contains(text, decoy_guidance)
    assert string.contains(text, "path=" <> prepared.checkout <> "/AGENTS.md")
    assert string.contains(text, "origin=workspace")
    assert string.contains(text, "origin=user-default")
  })
}

// The orchestrator recorded the executor's repository, not its own. The
// starting revision is the executor's commit, the peer observation names the
// branch and the repository root there, and the worktree board lists the file
// the model wrote after the session began.
fn assert_git(
  prepared: Pair,
  requests: List(provider.ObservedRequest),
  head: String,
  board: json.JsonValue,
  session: String,
) -> Nil {
  let git_output = remote_daemons.result_text(requests, "git-call")
  assert git_output == branch_name <> "\n" <> head <> "\n"

  let assert option.Some(start) =
    remote_pair.session_fact(prepared, session, "session/git-start")
    as "the orchestrator recorded the session's starting revision"
  assert remote_daemons.field(start, "kind") == json.String("revision")
  assert remote_daemons.field(start, "value") == json.String(head)
  assert remote_daemons.field(start, "workspace")
    == json.String(prepared.checkout)

  let assert option.Some(observed) =
    remote_pair.session_fact(prepared, session, "client/peers/git-observation")
    as "the orchestrator recorded the repository identity"
  let repository = remote_daemons.field(observed, "repository")
  assert remote_daemons.field(repository, "repository_root")
    == json.String(prepared.checkout)
  assert remote_daemons.field(repository, "branch") == json.String(branch_name)

  assert remote_daemons.field(board, "repository") == json.String("head")
  let assert json.Array([entry]) = remote_daemons.field(board, "entries")
    as "the board lists the one file the model added"
  assert remote_daemons.field(entry, "path") == json.String("scratch.txt")
}

// --- goal checks -------------------------------------------------------------

// The check commands name files by relative path, so they mean whatever
// directory they run in. `only-on-executor` is in the executor's checkout and
// nowhere else. `only-on-orchestrator` is in the orchestrator's own launch
// directory and not in the checkout: a check that ran on the orchestrator would
// find it, and one that ran on the executor does not.
const executor_marker = "only-on-executor"

const orchestrator_marker = "only-on-orchestrator"

const first_objective = "make the executor checkout ready"

const second_objective = "make the other checkout ready"

const passing_check = "test -f only-on-executor && echo checked-in $(pwd)"

const failing_check = "test -f only-on-orchestrator"

// The reviewer's two answers, one per goal. Each feed is answered with one
// `advise` call and then a closing text, so the review ends and the goal is
// judged complete whatever the check said: the reviewer is not what is under
// test, the check is.
fn advisor_script() -> List(provider.Exchange) {
  let review = fn(feed_call: String, answer_call: String) {
    [
      provider.ComputedExchange(
        provider.AwaitPromptPrefix(advisorslice.goal_feed_header),
        fn(_seen) {
          provider.ReplyToolUse(
            feed_call,
            advise.name,
            json.Object([
              #("verdict", json.String("complete")),
              #("text", json.String("reviewed")),
            ]),
          )
        },
      ),
      provider.ComputedExchange(provider.AwaitToolResult(feed_call), fn(_seen) {
        provider.ReplyText("noted " <> answer_call)
      }),
    ]
  }
  list.append(
    review("advise-first", "first"),
    review("advise-second", "second"),
  )
}

/// Pins goals whose checks run in the executor's checkout, one that passes
/// and one that fails there.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_tools_test:'`.
pub fn daemon_shipped_remote_goal_test_() -> EunitTest {
  remote_pair.shipped(skip_label, [], goal)
}

fn goal(prepared: Pair) -> Nil {
  let keys = remote_pair.provision(prepared)
  remote_pair.write_files(prepared.checkout, [#(executor_marker, "")])
  remote_pair.write_files(prepared.orchestrator.workspace, [
    #(orchestrator_marker, ""),
  ])

  // The primary model takes no turn, so its provider has an empty script. The
  // reviewer's has the two reviews.
  let #(#(Nil, primary), advisor) =
    provider.with_watched_server(
      advisor_script(),
      provider.OnlySuccessful,
      remote_pair.callback_ms,
      fn(advisor_url, advisor_watch) {
        provider.with_server_for(
          [],
          provider.OnlySuccessful,
          remote_pair.callback_ms - 20_000,
          fn(url) {
            remote_pair.configure(
              prepared,
              keys,
              remote_pair.Tables(
                ..remote_pair.plain(url),
                models: remote_pair.models(url, option.Some(advisor_url)),
              ),
            )
            let opened = remote_pair.open_registered(prepared, [], "e2e-goal")
            let socket = remote_pair.session_socket(opened)
            let socket = pin_goal(socket, first_objective, passing_check)
            let first = await_goal(socket, "complete")
            assert_check(first, passing_check, 0)
            let socket = pin_goal(socket, second_objective, failing_check)
            let second = await_goal(socket, "complete")
            assert_check(second, failing_check, 1)
            assert remote_daemons.field(second, "objective")
              == json.String(second_objective)

            // The board turns `complete` when the reviewer's `advise` call is
            // judged, which is before the reviewer's turn is over: the tool
            // result still has to reach it and it answers with a closing text.
            // Stopping the session on the board alone races that last request
            // and leaves the script unexhausted. The provider's own record is
            // the barrier, since it has answered the closing text only once the
            // request carrying the tool result has arrived.
            let assert Ok(Nil) = provider.await_exhausted(advisor_watch, 30_000)
              as "the reviewer's closing turn reached its provider"
            remote_pair.stop_and_close(prepared, opened, 1)
            remote_pair.close_daemons([opened.orchestrator])
          },
        )
      },
    )
  assert primary == Ok([])
  let assert Ok(feeds) = advisor
    as "the reviewer saw one feed for each goal and nothing else"
  assert_feeds(prepared, feeds)
  assert_checkout_absent_from_orchestrator(prepared, [executor_marker])
}

// Pins a goal with a check, the one command the operator's terminal sends for
// `/goal --budget N objective` followed by `/goal check command`.
fn pin_goal(
  socket: remote_pair.SessionSocket,
  objective: String,
  check: String,
) -> remote_pair.SessionSocket {
  let #(reply, socket) =
    remote_pair.session_command(
      socket,
      "goal_set",
      json.Object([
        #("objective", json.String(objective)),
        #("token_budget", json.Int(100_000)),
        #("check", json.String(check)),
      ]),
    )
  assert remote_daemons.field(reply, "event") != json.String("error")
    as { "the goal is pinned: " <> json.to_string(reply) }
  socket
}

// Reads the goal until it reaches `status`, and returns its board. A goal
// that never gets there fails the test with the last board it was read as,
// because "the goal did not reach complete" does not say which goal, nor
// whether it was waiting on a check, a reviewer, or nothing at all.
fn await_goal(
  socket: remote_pair.SessionSocket,
  status: String,
) -> json.JsonValue {
  let #(board, _socket) = await_goal_from(socket, status, 600, json.Null)
  board
}

fn await_goal_from(
  socket: remote_pair.SessionSocket,
  status: String,
  remaining: Int,
  last: json.JsonValue,
) -> #(json.JsonValue, remote_pair.SessionSocket) {
  assert remaining > 0
    as {
      "the goal reaches "
      <> status
      <> ", and the last board read was "
      <> json.to_string(last)
    }
  let #(reply, socket) =
    remote_pair.session_command(socket, "goal_get", json.Object([]))
  let board = remote_daemons.field(remote_daemons.field(reply, "body"), "board")
  case remote_daemons.field(board, "status") == json.String(status) {
    True -> #(board, socket)
    False -> {
      process.sleep(100)
      await_goal_from(socket, status, remaining - 1, board)
    }
  }
}

// The run the board recorded: the command, and the exit status it ended with.
fn assert_check(board: json.JsonValue, command: String, status: Int) -> Nil {
  let run = remote_daemons.field(board, "last_check")
  assert remote_daemons.field(run, "command") == json.String(command)
  assert remote_daemons.field(run, "status") == json.Int(status)
  assert remote_daemons.field(run, "not_finished") == json.Null
}

// What the reviewer was shown: the passing check's own output, which names the
// executor's checkout, then the failing one's status.
fn assert_feeds(prepared: Pair, feeds: List(provider.ObservedRequest)) -> Nil {
  let bodies =
    list.map(feeds, fn(request) { remote_pair.request_text(request.body) })
  let assert Ok(first) = list.find(bodies, string.contains(_, first_objective))
    as "the reviewer was fed the first goal"
  assert string.contains(first, "exit status 0")
  assert string.contains(first, "(the check passed)")
  assert string.contains(first, "checked-in " <> prepared.checkout)
  let assert Ok(second) =
    list.find(bodies, string.contains(_, second_objective))
    as "the reviewer was fed the second goal"
  assert string.contains(second, "exit status 1")
  assert string.contains(second, "(the check failed)")
}

// The request that carried `prompt` as its latest message.
fn request_to(
  requests: List(provider.ObservedRequest),
  prompt: String,
) -> Result(provider.ObservedRequest, Nil) {
  list.find(requests, fn(request) {
    request.latest == provider.UserPrompt(prompt)
  })
}

fn present(path: String) -> Bool {
  simplifile.is_file(path) == Ok(True)
}

fn occurrences(text: String, needle: String) -> Int {
  list.length(string.split(text, needle)) - 1
}
