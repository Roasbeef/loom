# Running Loom

The **server** (`loomd`) and the default **client** (`loom`) each carry
the BEAM runtime system, so neither needs Erlang installed on its host.
An optional slim client uses the host's Erlang/OTP 29 instead. `make dist`
builds all three tarballs for the current platform;
[distribution guide](distribution.md) describes their contents and measured sizes.

The server tarball unpacks to `bin/loomd`, `bin/loom-exec` (the sandbox
helper, a file beside it — Loom never extracts an executable at run
time), the runtime system, the compiled applications, the code-mode
toolchain (`bin/gleam` and `share/codemode-seed`), and a `SHA256SUMS` over
every executable that `sha256sum -c` will check. Code mode is roughly half
the download; `DIST_CODEMODE=0 make release` leaves it out. A release is
built for one platform and cannot be otherwise.

## Running a session

Install `loom` and `loomd` beside one another, change into a workspace,
and run the client:

```sh
cd ~/src/myproj
loom
```

`loom` authenticates the daemon recorded under `~/.loom`, or starts
`loomd` after checking that it can claim the private endpoint. An
uncertain process identity or malformed endpoint blocks auto-start.
The daemon is shared across workspaces. The client opens a session picker:
press Enter to open
the selected saved session, or choose New session to create one. Starting
the daemon and listing its catalogue open no session runtimes; a daemon
restart restores saved metadata until you explicitly open a session.

Several terminals can attach to the same session or use independent
sessions in that daemon. `/sessions` opens the catalogue picker again.
Switching replaces that terminal's attachment after validating the new
session's snapshot; it leaves the previous session running for other
clients.

The launcher's options are `--workspace`, `--session <id>`, `--server`
(`LOOM_SERVER` is the environment form), `--state-dir`, and
`--config <loom.toml>`. An explicit `--session` selects and opens that
saved session without the picker. `--config` supplies the model catalogue
when launching a daemon; without it, the launcher uses
`<state-dir>/loom.toml` if present. It never loads workspace configuration
implicitly or runs the server from the workspace, because repository
content is not launch authority. It also ignores relative `PATH` entries
when looking for `loomd`. `loom --demo` renders a canned preview without a
server or network connection.

To manage the daemon yourself, use the same state directory in both
terminals:

```sh
# Terminal 1: one daemon for all sessions in this catalogue.
loomd --state-dir "$HOME/.loom-dev" --bind 127.0.0.1:44123

# Terminal 2: authenticate that daemon and open its session picker.
loom --state-dir "$HOME/.loom-dev" --workspace "$HOME/src/myproj"
```

The daemon stores its catalogue and session databases under the private
state directory. Its owner credential is `owner.token`, a `0600` file
reused across daemon restarts, not a token per session. Session IDs come
from the catalogue, not database filenames.

For a direct attachment, first open the session through the picker, then
replace `SESSION_ID` below with its catalogue ID:

```sh
loom --addr ws://127.0.0.1:44123/v2/sessions/SESSION_ID/ws \
  --session SESSION_ID --token-file "$HOME/.loom-dev/owner.token"
```

The direct route attaches only to an already-open session. For a remote
host, carry the connection through a secure tunnel or TLS proxy and use a
credential authorized for that session. The daemon itself binds only to
loopback; do not expose bearer credentials over plaintext remote traffic.

## The server

`loomd` opens the catalogue and owner credential, then publishes one
authenticated WebSocket listener. Each explicit session open assembles
that session's SQLite store, helper pool, ToolBroker, provider, runtime,
and gateway behind the shared listener. `SIGTERM` drains the sessions and
shared domain services before closing the listener. Its flags:

```
--state-dir <path>     private daemon state (default ~/.loom)
--bind host:port       loopback listen address (default 127.0.0.1:0; port printed)
--capacity <n>         maximum retained session instances (default 8)
--owner-name <name>    initial owner display name (default Owner)
--helper <path>        loom-exec location (default: beside the server, then PATH, then ./bin)
--config <loom.toml>   model catalogue file (default: the LOOM_* env vars)
--codemode-seed <dir>  the offline build seed (default <workspace>/build/codemode-seed, then the bundled one)
--codemode-seams <s>   workspace, orchestration, or both (default workspace)
--full-enforcement     require every layer, including the ones Darwin cannot provide
--best-effort          accept broader sandbox degradation for development
```

**Models.** `--config` points at a catalogue: named entries (`dialect`,
`base_url`, `api_key_env`, `model_id`, context and output limits, thinking
level) plus role → fallback-chain routing. [model catalogue example](examples/loom.toml) is the
commented example — it carries all three dialects, `anthropic`, `openai`
and `gemini` — [Baseten example](examples/loom-baseten.toml) wires four
OpenAI-dialect models with per-role chains, and
[advisor example](examples/loom-advisor.toml) is the smallest catalogue that pairs a
fast primary model with a stronger one reviewing it through the optional
`advisor` role ([advisor guide](architecture/advisor.md)). Precedence is flags > config
file > environment > defaults: with `--config` the catalogue is the whole
model surface, and the launcher supplies `<state-dir>/loom.toml` when the
flag is absent and that file exists (`~/.loom/loom.toml` by default).
Without either, `LOOM_MODEL` (default `claude-opus-5`),
`LOOM_BASE_URL`, `LOOM_CONTEXT_WINDOW`, `LOOM_MAX_OUTPUT_TOKENS` and
`LOOM_SYSTEM_PROMPT` shape a one-entry catalogue. API keys never live in
the file — each entry's `api_key_env` names the variable read at dispatch,
`ANTHROPIC_API_KEY` in the env fallback — and a keyless server still boots
and serves; generation requests then fail in band. The TUI lists the
catalogue with `/model` and switches the active strand's model by name.

**Instruction files.** The system prompt carries the workspace's own
instructions verbatim, framed as project-authored data. Two files, in
this order: `AGENTS.md` — the [cross-tool convention](https://agents.md/)
every agent harness now reads — and then `CLAUDE.md`, which may add to
it. A workspace with no `AGENTS.md` of its own falls back to the
operator's global one, `~/.agents/AGENTS.md` then `~/.loom/AGENTS.md`;
a workspace file always wins over both, and nested `AGENTS.md` files in
subdirectories are not read. Each file reaches the model inside an
`<instructions>` fence naming its path and whether it came from the
workspace or the operator, so standing operator instructions are
distinguishable from a project's. Every one of these reads warns and
continues — an oversize, unreadable or absent file never stops a boot.

**Markdown skills.** The daemon discovers `SKILL.md` libraries under
`~/.agents/skills` and `~/.claude/skills`, with compatibility aliases described
in [the skills guide](skills.md). The terminal completes loaded skill
names with Tab. The model initially sees names and descriptions, then calls
`load_skill` to load a selected document. `/skill-name arguments` activates it
explicitly. Invocation flags control visibility; skill instructions do not
change tool permissions.

**Code mode** is registered only when the host has a Gleam compiler, an
emulator, and a build seed whose dependency table matches the compile
service's. A release carries all three; a checkout registers it once
`make codemode-seed` has run. A host missing any of them says so once on
stderr and ships no `code_mode` definition rather than one that always
refuses, because a tool definition is paid for on every request of every
strand. A strand's tool set is fixed when the strand is created, so a
session opened before code mode was available keeps its original set.

**The sandbox.** Run `loom-exec --self-test` on the kernel you actually
intend to run agents on; it prints `ENFORCED` or `SKIPPED` per probe. By
default the server demands platform enforcement — Linux fully strict,
Darwin admitting only ADR-006's three reported gaps — and refuses a
missing jail, an unexpected gap, or a silent layer. `--full-enforcement`
demands the cross-platform contract; `--best-effort` accepts broader
degradation for development machines. `LOOM_HELPER_POOL` bounds how many
`loom-exec` helpers run at once (the scheduler count clamped to `[4, 16]`),
which is the real ceiling on how wide a parallel tool batch runs.

