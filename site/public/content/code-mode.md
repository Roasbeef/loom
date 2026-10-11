# Code mode

In code mode the model writes a short Gleam program instead of issuing a sequence of tool calls. Loom vets the program, compiles it offline, runs it in a jailed BEAM node and returns one structured result. Every effect the program has, such as a file read, a command or a child agent, goes through the same broker that checks the model's direct tool calls. This page explains what a program can do and why running it is defensible.

## Why a program

A tool call is a round trip. The model emits one call, the harness runs it, and the result returns as context for the next turn. A program changes four things.

| | Tool calls | A code-mode program |
|---|---|---|
| Ten dependent steps | Ten model turns | One execution |
| Intermediate data | Every payload lands in the context | Stays inside the program, and only the result returns |
| Concurrency | Whatever the provider batches in one turn | Bounded parallel maps, races with cancellation, actors |
| A malformed call | Found at runtime, and it costs a turn | Found by the type checker before anything runs |

A program is also a file. The model can save it to the repository and run it again with `program_path`, and the same source can later become an installed extension.

## How the pipeline works

::figure code-mode

## A first program

This program counts the lines of three files at once and returns a map from each path to its count.

```gleam
import cap/fs
import cap/report
import cap/task
import gleam/list
import gleam/result
import gleam/string

pub fn main() -> report.Outcome {
  let paths = ["README.md", "docs/loom-design.md", "docs/code-mode.md"]
  case task.parallel_map(paths, max_concurrency: 3, with: line_count) {
    Ok(counts) ->
      list.zip(paths, counts)
      |> list.map(fn(pair) { #(pair.0, report.int(pair.1)) })
      |> report.object
      |> report.value
    Error(failures) -> report.failure(string.inspect(failures))
  }
}

fn line_count(path: String) -> Result(Int, fs.FsError) {
  use text <- result.map(fs.read(path))
  list.length(string.split(text, "\n"))
}
```

Three things to notice. The imports are the permissions: this program imported `cap/fs`, so it can read files, and it did not import `cap/proc` or `cap/net`, so it cannot run a command or open a connection. `main` returns a `report.Outcome` and not text on standard output, so the model receives a structured value. And `parallel_map` keeps input order and reports every failure, where `parallel_map_fail_fast` stops at the first error.

The model submits the program through the `code_mode` tool. Saved programs run the same way:

```json
{"program_path": "scripts/agent/line_counts.gleam", "seam": "workspace"}
```

Each run reads the file again and vets, compiles and authorizes it fresh. Saving a program saves only its source.

## What a program can import

A program may import the capability modules below and a fixed, pure part of the standard library: `gleam/list`, `string`, `string_tree`, `int`, `float`, `bool`, `result`, `option`, `dict`, `set`, `order`, `pair`, `function`, `json`, `dynamic` and `dynamic/decode`. Nothing else compiles.

| Module | What it gives a program |
|---|---|
| `cap/fs` | Read, write, list and edit files inside the workspace. |
| `cap/search` | Glob, grep, stat and line-range reads, with no write arm. A reviewer that imports only this module cannot change a file. |
| `cap/proc` | Run a command in its own kernel sandbox. A non-zero exit is data, not an error. |
| `cap/git` | Typed git status, diff and log. |
| `cap/job` | Start, poll, feed and kill background jobs that outlive the program. |
| `cap/net` | Outbound HTTP through a harness-owned proxy. Denied unless an operator approved the host. |
| `cap/task` | Structured concurrency: `parallel_map`, `race`, `both`, `all`. |
| `cap/actor` | Typed actors with bounded mailboxes, scoped to the program. |
| `cap/report` | The result value, JSON conversion, and durable artifacts through `emit`. |
| `cap/kv` | A scratch key-value store for the session, which can be evicted at any time. |
| `cap/notes` | Durable notes on the session blackboard. |
| `cap/strand` | Start, wait on and message child agents. |
| `cap/workflow` | Named child steps that a later launch can recover. |
| `cap/peer` | Read the inbox and send messages over granted peer links. |
| `cap/execution` | Typed input endpoints and progress for a background launch. |
| `cap/schedule` | Heartbeats that inject text into this strand's context on a timer. |
| `cap/lsp`, `cap/lsp_sql` | Language-server queries, and read-only SQL over captured language-server facts. |
| `cap/mcp/<server>` | Typed functions for each tool of a configured MCP server, generated at boot. |

The model has no autocomplete, so the `code_mode` tool description lists each admitted module and its public types. For a full signature the model reads `cap://<module>` with `fs_read`.

A strand's tool list also bounds its programs. `proc.run` needs the `bash` tool, `fs.write` needs `fs_write`, and `strand.spawn` needs `agent_spawn`. A reviewer whose parent withheld `bash` cannot run commands from a program either. A call that needs a tool the strand lacks is refused with `tool_not_held`.

## State that outlives a program

The satellite is destroyed when its program returns, so anything worth keeping goes somewhere else.

| Store | Lifetime | Use it for |
|---|---|---|
| `cap/kv` | Until evicted, at most the session | A cache. A program must tolerate a missing key. |
| `cap/notes` | The session, across satellite exits, restarts and compaction | Small structured findings that later programs and other agents read. |
| Workspace files and `report.emit` artifacts | Beyond the session | Large or binary output, with a small reference in a note. |

Notes are cells on the session blackboard, which every strand in the session can read. A program writes with `notes.put("analysis", value)`, and any agent reads it back with `notes.get("main/analysis")`. A write notifies nobody, so pair it with `strand.send` to make another agent act on it. Notes belong to the session. They do not carry into a new session.

## Running other agents

`cap/strand` lets a program start child agents and collect their results under the same rules as the model's `agent_*` tools. A loop pays nothing per spawn, so the host replaces the throttle that a model turn provides with explicit limits: a ceiling on spawn admissions per execution, the existing depth and fan-out limits, and addressing limited to the parent and its descendants.

```gleam
strand.map(assignments, max_concurrency: 2, within_ms: 20_000)
```

## One-shot and launch

By default a program runs for one tool call and returns its result. With `"mode": "launch"` it becomes a background execution that keeps its actors alive across model turns. It registers typed input endpoints with `cap/execution`, and the model can later `send`, `check`, `join` or `cancel` it through a handle. When it finishes, the harness notifies the launching strand and wakes it if it is idle. Later input cannot widen the program's grants or extend its deadline.

A daemon restart keeps the execution record and its input journal but cannot restore the running actors, and Loom reports that loss and replays no effects. For work that must survive a restart, `cap/workflow.step` gives each child a stable name, and a later launch with the same name recovers that child and its result instead of starting another. The limits are eight live executions per session, 32 launches per initiating operation, and a 128-entry input journal.

## Concurrency and budgets

The satellite is a full BEAM, so programs get real parallelism, but only through `cap/task` and `cap/actor`. Raw `spawn` is absent, because it would allow unbounded processes.

- `race` cancels the losers for real. Killing a losing task cancels its capability call, and the broker kills the sandboxed process group behind it.
- Actor mailboxes are bounded, so a send waits for room.
- The budget is pooled per execution. One execution shares a cap on outstanding effects, six by default, and one wall-clock deadline, five minutes by default and fifteen at most. Each `proc.run` still gets its own sandbox.

## Why this is safe to run

Loom's first rule is that model-influenced code never runs in the harness VM. Two independent layers protect that rule: the lint in the harness, and the kernel jail around the build and the run. An escape needs a bypass of both. Four stages make up the layers.

1. **Vetting, in the harness.** A lint over the parsed source rejects any `@external` and, failing closed, any other attribute. It rejects any import outside the allowlist, including look-alike Unicode module names, and a token-level scan backs up the parser.
2. **A hermetic build, in the jail.** `gleam build --warnings-as-errors` runs offline against a pinned, vendored prelude. The program is written to a fixed module path, so it cannot shadow `cap/fs`.
3. **The satellite, in the jail.** The node starts with Erlang distribution disabled. It has no network, enforced by seccomp and an empty network namespace. A cgroup, a CPU limit and a wall deadline bound it.
4. **The broker, in the harness.** The satellite's only link out is one Unix socket for capability calls. The broker checks each call against the execution's token, the session policy and the strand's tools, and the network denial is the broker's, so a program has no setting it could flip.

The first stage and the fourth run in the harness. The second and third run in the kernel jail. Each rejection comes back to the model as a value it can act on: a vetting refusal, compiler diagnostics, or a runtime failure.

This works because of the language. Gleam has no `eval`, no reflection, no macros and no dynamic module lookup, and every effect enters through an import that reaches an `@external`. The transitive closure of a program's imports is therefore the most it can ever do, and vetting can check it without running anything. Python, JavaScript and Erlang can each reach the whole runtime through a string, so an import list tells you little about them.

The trade-off is fluency. Models have seen far more JavaScript than Gleam, and every run pays for a compile. Loom offsets it by returning compiler diagnostics as an ordinary result, retrying once when a build fails only on unused imports, arguments or bindings, and listing the admitted modules' types in the tool description.

## On an executor

Work on the [distributed runtime](#/docs/distributed-runtime) separates the session's owner from the machine that holds the checkout. For code mode, the owner still vets the program. The executor compiles it beside the checkout and runs the satellite there, in the same jail with distribution disabled. Filesystem and language-server calls run against the executor's workspace, while notes, strand operations and reports keep the owner's session authority. This is in development and is not on `main` yet.

## Read more

- `docs/code-mode.md`: the overview this page follows.
- `docs/architecture/code-mode.md`: vetting, the build, the satellite and the broker routing.
- `docs/async-collaboration.md`: launch mode, endpoints, workflows and peer links.
- `docs/examples/`: programs that tests run verbatim.
