# Jev MCP from code mode

Loom can call [Jev](https://github.com/Roasbeef/jevelin) through the
[Jevelin MCP server](https://github.com/Roasbeef/jevelin-mcp). A
`[mcp.jev]` entry starts that server, discovers its four tools, and generates
the `cap/mcp/jev` module. A model reads the generated API, then imports the
module in a code-mode program. The program's call crosses Loom's capability
broker before reaching the MCP server and Jev's HTTP API.

This guide covers setup, a complete mixed Choice/Score batch, and the local fixture used
to verify the integration without a Jev API key. The
[MCP architecture](architecture/mcp.md) explains generation and dispatch;
[code-mode architecture](architecture/code-mode.md) explains the jailed
build and satellite.

## Build the MCP server

Building Jevelin MCP requires Gleam >= 1.18 and Erlang/OTP >= 29:

```sh
git clone https://github.com/Roasbeef/jevelin-mcp.git
cd jevelin-mcp
make release
```

`bin/jevelin-mcp` runs the compiled shipment. Its stdout contains MCP
frames, so Loom must launch that executable rather than a build command.
For a launcher installed outside the checkout, the PATH installer in
[Jevelin MCP PR #1](https://github.com/Roasbeef/jevelin-mcp/pull/1) adds
`make install`, defaulting to `~/.local/bin/jevelin-mcp`. It bundles ERTS
and the OTP applications and boots from its own absolute runtime paths.
The installed server needs no host Erlang installation and does not select
`erl` through the daemon's `PATH`. Use that absolute path in `command`
after installation. `make release` builds the shipment
without publishing a launcher onto PATH.

The server consumes its Gleam libraries through pinned Git dependencies;
this setup does not require publishing them to Hex.

For a self-contained installation, use the reviewed installer from
[Jevelin MCP PR #1](https://github.com/Roasbeef/jevelin-mcp/pull/1). While that
PR remains open, select its tested commit explicitly:

```sh
git checkout 307b7e4d5c5720ebd070cc0bd2868cdf66f0cada
make install
```

The default prefix is `~/.local`; `make install PREFIX=/another/prefix`
selects another location. Add the prefix's `bin` directory to your shell's
PATH to invoke `jevelin-mcp` directly. Loom can use its absolute path without
that shell setting. The launcher runs the bundled ERTS and boot files by
absolute path, so it does not require host Erlang or resolve Loom's bundled
`erl` from PATH. The installed release is a launcher and its private runtime
tree, like Loom's distribution, rather than one statically linked executable.

Loom also needs a working code-mode toolchain and build seed. The normal
server distribution includes them. From a Loom checkout, build the helper
with `make sandbox`, then run `make server-shipment`, which prepares the seed
and creates `bin/loomd`. See [Running Loom](running.md) for installation and
daemon flags.

## Configure a separate Loom instance

Create a catalogue such as `~/.config/loom/jev.toml` containing your existing
`[models.<name>]` entries and `[roles]` routing. Add this table, replacing the
executable path with the absolute path to your Jevelin MCP checkout:

```toml
[mcp.jev]
command = ["/absolute/path/jevelin-mcp/bin/jevelin-mcp"]
api_key_env = "JEV_API_KEY"
```

For the default self-contained installation, use
`command = ["/Users/your-user/.local/bin/jevelin-mcp"]` instead. In an existing
normal daemon, add the table to its active catalogue, typically
`~/.loom/loom.toml`, rather than the separate test catalogue above. Restart
the daemon with the credential available, then open a fresh session: existing
sessions keep their generated capability modules.

The model provider and Jev use separate credentials. `api_key_env` names a
key in Loom's secret store; the TOML file contains no Jev credential. By
default, that store reads the daemon's environment. For a terminal-only setup,
set `JEV_API_KEY` using your secret manager and export it before starting the
daemon. To enter it interactively in Bash or Zsh:

```sh
read -r -s JEV_API_KEY
export JEV_API_KEY
```

The silent read waits for the key and Enter. Keep the credential out of
model prompts and tool arguments.

For a credential that survives daemon restarts, store it in your existing
secret manager and add Loom's existing command source to the same catalogue:

```toml
[secrets]
JEV_API_KEY = { command = ["/absolute/path/to/jev-secret-helper"] }
```

Replace the helper with the command you use to retrieve the key. Each list
entry is one argv argument; Loom performs no shell expansion. The helper
must print only the credential on stdout and exit zero. Loom removes one
trailing newline and resolves the command at session create/open, under a
ten-second deadline. A resolved value overrides the environment value for
that name and stays in daemon memory. Existing running sessions keep their
assembled store. The helper's stderr reaches the daemon log, so its
diagnostics must also keep the key private. This uses the existing
`client/secrets` store, with the same `api_key_env = "JEV_API_KEY"` reference.

Jevelin defaults to `jev-latest`; an exported `JEV_MODEL` selects another
default, and a tool's optional `model`
argument overrides it. The child inherits the daemon's process environment.
Loom's MCP table accepts `command` and `api_key_env`, without an `env` table.

Start an isolated daemon, then attach from another terminal:

```sh
# Terminal 1, with the Jev and model-provider credentials available.
loomd --state-dir "$HOME/.loom-jev-test" --bind 127.0.0.1:44124 \
  --config "$HOME/.config/loom/jev.toml"

# Terminal 2, using the same private state directory.
loom --state-dir "$HOME/.loom-jev-test" \
  --workspace /absolute/path/to/workspace
```

Use `bin/loomd` when running the server shipment from a checkout. Choose
**New session** in the picker. The separate state directory keeps this
experiment outside your normal daemon's catalogue. Keep it shallow: a
code-mode capability socket must fit the 100-byte Unix socket path limit.
For a source-checkout fixture, place state beneath a shallow checkout
`build/` directory; `/tmp` is replaced by the Linux jail's scratch mount.

At session startup, the daemon logs `mcp.ready` with `jev=4`. A failure
produces `mcp.unavailable` with the server name and reason. Missing credentials,
an unbuilt shipment, or an unavailable code-mode toolchain prevent discovery.
Configuration changes take effect when a new session runtime boots; existing
resident sessions retain their generated modules. Relaunch the test daemon
to pick up changed environment variables. Exporting a key in a new terminal
does not change the environment of an already-running daemon. A configured
server whose credential cannot be resolved has no generated module; its
`mcp.unavailable` log entry records the cause. The model currently sees the
missing module without that startup reason, so an absent `cap://mcp/jev`
is not proof that the TOML entry is missing. Check discovery before treating
a `cap/proc` command as a Jev integration test.

## Discover the generated API

The `code_mode` description lists `cap/mcp/jev`. Complete declarations are
available through Loom's `fs_read` tool:

```json
{"path":"cap://mcp/jev"}
```

Read `cap://report` too when constructing structured values. These references
resolve inside Loom; they are not filesystem paths or network URLs. No
manual code-generation command is required. Startup generates source in
memory, and each execution compiles the modules its program imports.

The Jev module exposes `jev_choice`, `jev_score`, `jev_noul`, and `jev_batch`.
The API follows the deployed Loom generator. The extraction baseline
`f84842d17` still exposes structured inputs as `report.Value` and optional
arguments as a list of wire-name/value pairs. A build with typed MCP
generation exposes the signature below. Read `cap://mcp/jev` from the
running session before submitting a program; that deployed surface is
authoritative.

The concise Batch signature is:

```gleam
pub fn jev_batch(
  state: State,
  questions: List(Question),
  options: JevBatchOptions,
) -> Result(JevBatchResult, mcp.McpError)
```

`StateText`, `StateObject`, and `StateArray` represent the supported state
shapes. `ChoiceQuestion`, `ScoreQuestion`, and `NoulQuestion` construct the
question variants directly. The encoder supplies the required wire discriminator
from the variant; callers cannot pair a Choice constructor with a Score tag.
The returned answer variants are `ChoiceAnswer`, `ScoreAnswer`, and `NoulAnswer`.
The result record exposes `model`, `answers`, and `usage`.

Generated names describe the nearest schema role. A deterministic allocator
adds a compact suffix only when a name is already occupied. Tool and node
ordinals remain internal identities rather than mandatory call-site prefixes.
The same allocation supplies the compilable module and the API read.

In Gleam, call a record's named constructor to build it, and use
`Constructor(..existing, field: value)` to update a field. Optional fields
use `Option`: `None` omits a key and `Some(value)` supplies it. Nullable
optional fields have a second layer: `Some(None)` sends null, while
`Some(Some(value))` sends data. Jev's descriptions and rubric levels accept
text, objects, or arrays, so `DescriptionText` and `LevelText` still express
real alternatives. Genuine single-branch schemas require no extra wrapper.
Read the deployed surface each session; schema and generator changes can
change the generated names, and existing resident runtimes keep their modules.

These types restrict structural questions at compile time. Jevelin's smart
constructors still validate conditions such as duplicate labels before HTTP
runs, and its answer decoder validates the service's decision. Loom's total
output decoder then checks the advertised structural schema inside the
satellite. A mismatch returns `mcp.ResultSchemaMismatch(error, result)` with
a path and the original content; a failed tool or transport keeps its own
error variant. Numeric bounds and general schema refinements remain
server admission checks.

## Run a mixed batch

Give the Loom session this instruction:

> Read `cap://mcp/jev` and `cap://report`. Use `code_mode` to evaluate a
> failed build in one Jev batch: choose between reading compiler logs and
> running tests, and score its priority against low and high rubric levels.
> Return the choice, confidence, score, and token usage.

This complete program constructs the question variants and matches the decoded
answer variants. A Choice constructor owns its tag and criteria together;
there is no separate discriminator enum or intermediate branch record.

```gleam
//// A mixed batch selects its wire discriminators through typed constructors.

import cap/mcp/jev
import cap/report
import gleam/list
import gleam/option.{None, Some}

/// Returns the decoded choice, score, and token usage from one batch.
///
/// ## Examples
///
/// This entry point runs in Loom's code-mode satellite.
pub fn main() -> report.Outcome {
  let questions = [
    jev.ChoiceQuestion(
      name: "route",
      choices: [
        jev.Choice(
          label: "logs",
          description: Some(Some(jev.DescriptionText("Read compiler logs"))),
        ),
        jev.Choice(label: "tests", description: None),
      ],
      instructions: None,
    ),
    jev.ScoreQuestion(
      name: "priority",
      levels: [jev.LevelText("low"), jev.LevelText("high")],
      instructions: None,
    ),
  ]

  case
    jev.jev_batch(
      jev.StateText("The user wants to inspect a failed build."),
      questions,
      jev.jev_batch_defaults,
    )
  {
    Ok(found) -> {
      case
        list.key_find(found.answers, "route"),
        list.key_find(found.answers, "priority")
      {
        Ok(jev.ChoiceAnswer(choice:, confidence:, ..)),
          Ok(jev.ScoreAnswer(score:, ..))
        ->
          report.value(
            report.object([
              #("model", report.string(found.model)),
              #("choice", report.string(choice)),
              #("confidence", report.float(confidence)),
              #("score", report.float(score)),
              #(
                "usage",
                report.object([
                  #("input_tokens", report.int(found.usage.input_tokens)),
                  #("output_tokens", report.int(found.usage.output_tokens)),
                ]),
              ),
            ]),
          )
        _, _ -> report.failure("The batch did not return its typed answers.")
      }
    }
    Error(_) -> report.failure("The Jev batch was refused.")
  }
}
```

`report.object` and the other builders construct the final report; MCP inputs
use generated records and variants. The program finds answers by their request
names, then pattern-matches their typed values. Loom stores the report and
supplies it to the model's next turn. A live Jev answer depends on the service;
the local fixture response below is deterministic.

## Try the HTTP fixture without a Jev key

The Jevelin checkout already contains a local Jev fixture in
`test/e2e.py`. From that checkout, run it in a separate terminal:

```sh
python3 - <<'PY'
import importlib.util
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("jev_fixture", "test/e2e.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with ThreadingHTTPServer(("127.0.0.1", 8182), module.Fixture) as fixture:
    fixture.daemon_threads = True
    fixture.requests, fixture.mode, fixture.delay = [], "success", 0
    print("Local Jev fixture listening on 127.0.0.1:8182", flush=True)
    fixture.serve_forever()
PY
```

In the terminal that launches the isolated Loom daemon, use these settings
instead of the live Jev credential:

```sh
export JEV_API_KEY=fixture-credential-not-a-live-key
export JEV_BASE_URL=http://127.0.0.1:8182
export JEV_MODEL=jev-default-fixture
export JEV_MCP_TRANSPORT=stdio
```

Keep the same `[mcp.jev]` table and query. Your normal model-provider
credential is still required to have a model submit the program. The
fixture uses Python's standard library and existing server test code; no
additional Python package or helper script is needed. Stop the fixture
with Ctrl-C when finished.

The documented program returns this report with the local fixture:

```json
{
  "model": "jev-fixture",
  "choice": "logs",
  "confidence": 0.9,
  "score": 0.25,
  "usage": {"input_tokens": 10, "output_tokens": 3}
}
```

## Validation boundary

On October 1, 2026, live Jev authentication and inference passed through
both the installed Loom distribution at `f84842d` and the typed-generation
shipment after `832f17a2`. Both launched the installed self-contained
Jevelin bundle at `18ab557`, discovered `cap://mcp/jev`, compiled the query
in the jail, executed it through the satellite and retained the completed
result in an authenticated session snapshot. The live service answered as
`jev-1.13.0`, chose `logs` with confidence `1.0`, and reported 324 input and
31 output tokens. A scripted local model submitted the program; Jev itself
was live. Authenticated cleanup exited zero for each isolated daemon.
The real credential remained outside model requests and stored configuration.
Evidence is retained in `build/jev-live-20261001-150405` for installed Loom
and `build/jev-live-20261001-151059` for typed Loom. Their own commands exited
zero; logs are `build/installed-live-jev-e2e.log` and
`build/typed-live-jev-e2e.log`.


A fresh session in the operator's already-running normal daemon also
passed discovery and the live Choice query with the installed launcher.
Its authenticated snapshot contained exactly one completed `code_mode`
execution. The enabled Stop hook added one model continuation, so this run
made four model calls with tools and one maintenance call. Cleanup stopped
only the verification session and confirmed its saved state; the normal
daemon and existing sessions were preserved. The command exited zero, with
evidence in `build/jev-live-20261001-151240` and log
`build/normal-live-jev-e2e.log`. This verifies the daemon launch environment
that previously selected Loom's incomplete generic Erlang boot path.

On October 1, 2026, the typed-generation worktree ran the exact program
above through a fresh production Loom daemon. A scripted local model read
`cap://mcp/jev` through `fs_read`, submitted the program to code mode, and
received its structured outcome. The jailed compiler, satellite, Jevelin MCP
process and HTTP fixture all executed. The satellite decoded the advertised
output schema into the generated record, and the program read its answer
and usage fields before constructing the durable report.

The run made one Jev HTTP request. It made three main model calls and one
tool-free maintenance call. The dummy credential stayed confined to the
configured server/HTTP exchange, and authenticated daemon cleanup exited
zero. The run's own command exited zero; its log is
`build/typed-reviewed-jev-daemon-e2e.log` and its retained evidence is
`build/jev-e2e-20261001-144704`. Both sandbox stages reported active macOS
Seatbelt filesystem and network enforcement, with degraded memory/process
resource limits and process lifecycle enforcement. This is a local-fixture
proof; the separate live-service results are recorded above.

The focused native client suite also passed eight typed-generation cases:
nested options retain exact wire keys and null presence, structured answers
decode into typed values, schema mismatch retains text and its failure path,
and wrong enums/options/nested inputs fail compilation before any tool call.
A schema-valid union result survives fallback of its nested discriminator
as a raw value. The complete GitHub-shaped listing compiles warning-free in
the jail, and the architecture guide example executes unchanged. An actual
Go SDK-generated listing also sends nested inputs and decodes its nested
result through the real jail, preserving SDK nullability. These results do not claim a full gate or hosted CI for the final head.

The earlier raw-value integration proof is retained below under the exact
heads that produced it.

On October 1, 2026, an isolated Loom daemon ran the compiled Jevelin MCP
server with this HTTP fixture and a scripted local model provider. The
model discovered the APIs through `fs_read`, submitted the earlier raw-value
Choice program, and received its result. Both the hermetic build and satellite executed;
Jevelin made exactly one HTTP request with the expected dummy bearer
credential. No model request contained that credential.

A fresh authenticated, credited session snapshot contained the final
assistant response and a durable `code_mode` tool result with
`isError=false`, `details.status=completed`, and the exact fixture value
above. The session returned to idle, and the daemon exited zero after
authenticated shutdown. Both sandbox stages reported active Seatbelt
filesystem and network enforcement. Their macOS posture was degraded for
memory/process resource limits and process lifecycle enforcement, as
recorded in the tool result.

The tested Loom tree was `5aad549bd17a34dd07f6549695ef1430b0efff5f`, merged
by [PR #669](https://github.com/Roasbeef/loom/pull/669). Jevelin MCP was
`ed86f60cac3c61a8acbabcd095de6743dfac40a1`, with SDK runtime pin
`686955fc0461630bf64a4dc8eb51565dc7ca1ac9`. That run proves the integration
against local fixtures.

A subsequent October 1 run used the normal installed Loom daemon at
`3819fec3d4ea999f51c6504b31c4d9b5d68c1501` and the self-contained Jevelin
release at `307b7e4d5c5720ebd070cc0bd2868cdf66f0cada`. A fresh scripted-model
session discovered `cap://mcp/jev`, compiled the program in the real jail,
and called the live Jev API over TLS. The durable successful code-mode
result reported model `jev-1.13.0`, choice `logs`, confidence 1.0, and 324
input / 31 output tokens. This verifies live authentication and inference
through the installed daemon; the scripted model made the submitted program
deterministic. The credential remained outside model requests. Only the
verification session was stopped, preserving the operator's existing sessions.
Seatbelt filesystem and network enforcement were active, with the same
explicit macOS resource and process-lifecycle limitations described above.

Loom currently connects MCP servers over stdio. Jevelin and the standalone
SDK also support HTTP transport, but that transport is not configured by
Loom's `[mcp.<name>]` table. Resources and prompts remain separate features,
tracked in [Gleam MCP issue #1](https://github.com/Roasbeef/gleam-mcp/issues/1).
