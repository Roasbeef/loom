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
`<state-dir>/loom.toml` if present. `--model-profile <name>` creates new
sessions under one of that file's `[profiles.<name>.roles]` tables (the
default roles with the named roles replaced); an existing session keeps the
profile it was created with. It is not `--profile`, which enables BEAM
profiling. `--executor <name> --workspace <registered name>` makes the
picker's `n` create sessions in a workspace registered on one of the daemon's
`[executors.<name>]` (the name is not resolved as a path on this machine, and
the flag cannot be combined with `--session`). `--pool <name> --workspace
<registered name>` does the same for one of the daemon's `[pools.<name>]`, which
picks the executor when the session first opens; it is exclusive with
`--executor`. It never loads workspace configuration
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

To add a tools MCP server, put a `[mcp.<name>]` table in the model catalogue
and export its credential before launching the daemon. The
[Jev MCP walkthrough](jev-mcp.md) includes a separate test instance, generated
API discovery, and a code-mode query with a local fixture option.

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
`--token-file` must be a file only you can read, and neither
`--token-file` nor `--token` accepts a claim token.

## Inviting someone, and joining as the invitee

For the same steps in a browser, with the terminal commands beside them, read
the [guide to working with other people](guide/multiplayer.md).

The owner invites a person to one session. The session must be
`session_only` first (`loomd access isolate SESSION
--share-existing-transcript` for an existing one); the
[multiplayer guide](architecture/multiplayer.md) explains why.

```sh
# The owner, on the daemon's host:
loomd access invite SESSION_ID alice operator Alice \
  --claim-addr wss://loom.example.com/v2/control
```

Standard output is one JSON line with a single-use `claim` token
(`loomclaim_…`), its `expires_in_ms` (24 hours unless `--ttl 30m`,
`--ttl 7d` or similar chose otherwise), and a `claim_command` that names
the address but not the token. Send the invitee the token and the command
over a channel outside Loom, never through a Loom session. Without
`--claim-addr` the command names the daemon's loopback address, which
works only on that host. A lost or leaked claim is replaced with `loomd
access rotate alice`, which voids it and prints a new one.

The invitee runs the command and pastes the token at its prompt, or pipes
it in; the token is not accepted as a flag value by default so it stays
out of shell history:

```sh
loom claim --addr wss://loom.example.com/v2/control
claim token: loomclaim_…
```

Add `--name "Alex Doe"` to choose the display name other participants see;
without it the name the owner gave stays. The daemon refuses a blank name,
one over 256 bytes, or one with control characters, binds nothing, and the
same claim can be run again.

`loom claim` draws a new credential, stores it in
`~/.loom/remotes/loom.example.com/credential` (mode `0600`, in a `0700`
directory) before connecting, and sends the daemon only its digest. It
prints the credential's fingerprint on standard error and, on standard
output, the sessions the claim granted and a `launch` line:

```sh
loom --addr wss://loom.example.com/v2/control \
  --token-file ~/.loom/remotes/loom.example.com/credential --session SESSION_ID
```

Tell the owner the fingerprint over a second channel; the owner confirms
it before relying on the new member. If `loom claim` loses its connection
after sending, run the same command again with the same token: it reuses
the stored credential and the daemon answers the same way. A `conflict`
means the claim was redeemed with another credential; ask the owner to
compare fingerprints and rotate. `expired` and `not_found` mean the claim
is no longer redeemable; ask for a new one.

For an operator invitation the owner may prefer enrollment by digest,
where nothing secret is sent at all. The invitee runs `loom enroll --addr
wss://loom.example.com/v2/control`, sends the printed `credential_digest`
to the owner, and the two compare its fingerprint over a second channel.
The owner then runs `loomd access invite SESSION_ID alice operator Alice
--credential-digest HEX`, and the invitee launches with the stored
credential as above.

## Seeing who has access, and administering remotely

`loom access` takes the same commands as `loomd access` and prints the same
lines, and adds two that only read:

```sh
loom access list                 # one JSON line per principal
loom access show alice           # one JSON line per session alice can reach
```

Each `list` line gives the principal's `kind` and one `credential` state:
`active` with a `fingerprint` (and `claimed_at_ms`, the instant a claim was
redeemed, when a claim bound it), `claim_open` with the time it has left,
`claim_expired` for a claim nobody redeemed in time, or `none`. Compare the
fingerprint with the invitee's out of band before relying on a new member.
When a page is full the last line is `{"next":"PRINCIPAL"}`; pass it back as
`--after PRINCIPAL` (`--after SESSION` for `show`). Neither command prints a
claim or a credential, and a member's credential is refused.

Both binaries run against the daemon on the same host. `loom access` also
runs against a remote daemon, given its control address and a file holding
the owner token:

```sh
loom access --addr wss://loom.example.com/v2/control \
  --token-file ~/owner.token list
```

The token file must be readable by you alone. This adds no authority, but
it only works if the owner token has been copied to the second machine, and
the token then sits on that machine. Running `ssh HOST loom access ...`
keeps the token where it is. In remote mode `invite` and `rotate` print a
`claim_command` for the address you connected to unless `--claim-addr` says
otherwise.

## Language-server setup

Install optional profiles for Gleam, Go and Rust to give the agent semantic
code queries and rename tools. The [setup guide](language-servers.md) covers
server prerequisites, profile installation, `loomd ext check`, offline
dependencies and activation in new sessions. Language servers inherit the
daemon's tool environment and run in its jail.

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
--ui                   serve the web view (also enabled by [daemon] ui = true)
--helper <path>        loom-exec location (default: beside the server, then PATH, then ./bin)
--config <loom.toml>   model catalogue file (default: the LOOM_* env vars)
--codemode-seed <dir>  the offline build seed (default <workspace>/build/codemode-seed, then the bundled one)
--codemode-seams <s>   workspace, orchestration, or both (default both)
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
Sessions run through the executor service (issue #696); there is no setting
to choose another path. The service writes one `executor.settled` log line per
execution and an `executor.closed` line when the session shuts down.

### Daemon settings

The daemon reads these optional settings from its startup `--config` file.
The ordinary `loom` launcher supplies the selected catalogue, defaulting to
`~/.loom/loom.toml` when present. A manually launched `loomd` needs that
`--config` flag explicitly:

```toml
[daemon]
ui = true # Serve the web view on every daemon start.
max_connections = 64
max_reserved_message_bytes = 536870912 # 512 MiB.
```

`ui` must be a boolean and defaults to false; `--ui` enables the view even
when the file says `ui = false`. The connection limits must be positive
integers. Omitted limits use the defaults above;
`profile` is optional in the same table. Changes take effect after a daemon
restart. The startup file must be readable, valid TOML even before any
session opens; invalid models and unavailable helpers still fail only when a
session uses them. A session's own configuration does not change daemon-wide limits.

A terminal normally holds one control socket and one operator socket. Control
reserves 64 KiB, while an operator reserves 32 MiB for inbound messages plus
8 MiB for retained delivery. The default budget therefore admits twelve such
pairs. These are potential payload allowances, not preallocated memory or a
bound on the daemon's entire RSS. The independent connection-count ceiling
includes HTTP upgrades awaiting transfer and admitted sockets.

At either ceiling, a new connection receives HTTP 503 with the exhausted
setting named in the response. The terminal explains the admission failure
and names both settings because its transport does not expose that HTTP body.
Closing another terminal releases its connections without deleting its saved
session. `--capacity` controls resident sessions separately from these socket
limits.

### A page in a browser

A daemon started with `--ui` or `[daemon] ui = true` serves a web page for
any session you are a member of. Set `ui = true` in `~/.loom/loom.toml` to
enable it when ordinary `loom` starts a daemon, then use the terminal as
usual. Ask your own `loom` for a link:

```sh
# Print a single-use link to an observer's page for one session.
loom ui --session SESSION_ID

# Ask for an operator's page, and open the link in the default browser.
loom ui --session SESSION_ID --operate --open

# Name the daemon's state directory and config, in any order.
loom ui --state-dir ~/.loom --config ~/.loom/loom.toml --session SESSION_ID
```

`loom --ui ...` is an older spelling of the same command and still works,
with the options before or after `--ui`.

If no daemon is running, `loom ui` starts one with `--ui`. If the
running daemon has the view disabled, `loom ui` says so and exits with
status 1; it never restarts a daemon other people may be using. The link
works once, within 60 seconds, and only in the browser tab that opens it;
a new tab or a daemon restart needs a new link. Each link opens its own
page, so an observer's tab and an operator's tab, or two devices, can be open
at once; a session keeps your newest four pages, and opening a fifth ends the
oldest. A page is an observer's
unless you pass `--operate`, and even then it never carries more than
operator authority. The daemon binds only loopback, so a browser on
another machine reaches the page through a local forward such as
`ssh -L`. [The web view](architecture/web-view.md) explains the page and
its security checks.
