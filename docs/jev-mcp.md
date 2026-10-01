# Jev MCP from code mode

Loom can call [Jev](https://github.com/Roasbeef/jevelin) through the
[Jevelin MCP server](https://github.com/Roasbeef/jevelin-mcp). A
`[mcp.jev]` entry starts that server, discovers its four tools, and generates
the `cap/mcp/jev` module. A model reads the generated API, then imports the
module in a code-mode program. The program's call crosses Loom's capability
broker before reaching the MCP server and Jev's HTTP API.

This guide covers setup, a complete Choice query, and the local fixture used
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

The model provider and Jev use separate credentials. `api_key_env` names a
credential in Loom's secret store; the TOML file contains no Jev credential.
By default, that store reads the daemon's environment. For a terminal-only
setup, set `JEV_API_KEY` using your secret manager and export it before
starting the daemon. To enter it interactively in Bash or Zsh:

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

The typed Choice signature is:

```gleam
pub fn jev_choice(
  state: McpT1InputN1JevChoiceState,
  choices: List(McpT1InputN6JevChoiceChoicesItem),
  options: McpT1OptionsJevChoice,
) -> Result(McpT1OutputN0JevChoiceResult, mcp.McpError)
```

The API read declares every type named in that signature. The Choice state
has variants for text, a JSON object and a JSON array. Each choice is a record
with a label and optional nullable description. The options record exposes
`model` and `instructions`; `jev_choice_defaults` omits both. The returned
record has `model`, `answer` and `usage` fields, so the program can read
`found.answer.choice` and `found.usage.input_tokens` directly.

In Gleam, call a record's named constructor to build it, and use
`Constructor(..existing, field: value)` to update a field. Optional fields
use `Option`: `None` omits a key and `Some(value)` supplies it. Nullable
optional fields have a second layer: `Some(None)` sends null, while
`Some(Some(value))` sends data. The generated API names every union branch
and enum constructor. Read that surface each session, because schema changes
can change the generated type names.

These types restrict structural questions at compile time. Jevelin's smart
constructors still validate conditions such as duplicate labels before HTTP
runs, and its answer decoder validates the service's decision. Loom's total
output decoder then checks the advertised structural schema inside the
satellite. A mismatch returns `mcp.ResultSchemaMismatch(error, result)` with
a path and the original content; a failed tool or transport keeps its own
error variant. Numeric bounds and general schema refinements remain
server admission checks.

## Run a Choice query

Give the Loom session this instruction:

> Read `cap://mcp/jev` and `cap://report`. Use `code_mode` to call
> `jev.jev_choice` for a failed build, choosing between reading compiler
> logs and running tests. Return the choice, confidence, and token usage.

This complete program uses the typed declarations above. It constructs
choice records and an instructions union, then reads the decoded answer and
usage fields. This exact program passed through a fresh production daemon
and the local HTTP fixture on October 1, 2026. The validation section below
separates that typed run from the earlier raw-value integration proof.

```gleam
//// A Choice request uses schema-derived inputs and a decoded answer record.

import cap/mcp/jev
import cap/report
import gleam/list
import gleam/option.{None, Some}

/// Returns the model, choice, confidence, probabilities, and token usage.
///
/// ## Examples
///
/// This entry point is run by Loom's code-mode satellite.
pub fn main() -> report.Outcome {
  let choices = [
    jev.McpT1InputN6JevChoiceChoicesItem(label: "logs", description: None),
    jev.McpT1InputN6JevChoiceChoicesItem(label: "tests", description: None),
  ]

  let options = jev.McpT1OptionsJevChoice(
    ..jev.jev_choice_defaults,
    instructions: Some(Some(
      jev.McpT1InputN15V0BranchJevChoiceInstructionsItem(
        "Choose the most relevant next action.",
      ),
    )),
  )

  case jev.jev_choice(
    state: jev.McpT1InputN1V0BranchJevChoiceState(
      "The user wants to inspect a failed build.",
    ),
    choices: choices,
    options: options,
  ) {
    Ok(found) -> {
      let probabilities = list.map(found.answer.probabilities, fn(pair) {
        #(pair.0, report.float(pair.1))
      })

      report.value(report.object([
        #("model", report.string(found.model)),
        #("usage", report.object([
          #("input_tokens", report.int(found.usage.input_tokens)),
          #("output_tokens", report.int(found.usage.output_tokens)),
        ])),
        #("answer", report.object([
          #("type", report.string("choice")),
          #("choice", report.string(found.answer.choice)),
          #("confidence", report.float(found.answer.confidence)),
          #("probabilities", report.object(probabilities)),
        ])),
      ]))
    }
    Error(_reason) -> report.failure("The Jev MCP evaluation failed.")
  }
}
```

`report.object` and the other builders construct the program's final report;
the MCP input is built with the generated records and variants. The success
branch uses normal field access rather than raw key lookup or parsing the
server's text block. The report contains the choice, confidence,
probabilities and token usage. Loom stores that result and supplies it to
the model's next turn. A live Jev answer depends on the service; the fixture
response below is deterministic.

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

The fixture's successful response contains:

```json
{
  "model": "jev-fixture",
  "usage": {"input_tokens": 10, "output_tokens": 3},
  "answer": {
    "type": "choice",
    "choice": "logs",
    "confidence": 0.9,
    "probabilities": {"logs": 1.0, "tests": 0.0}
  }
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
`686955fc0461630bf64a4dc8eb51565dc7ca1ac9`. This proves the integration
against local fixtures. Live Jev authentication and inference remain
untested until an API key is available.

Loom currently connects MCP servers over stdio. Jevelin and the standalone
SDK also support HTTP transport, but that transport is not configured by
Loom's `[mcp.<name>]` table. Resources and prompts remain separate features,
tracked in [Gleam MCP issue #1](https://github.com/Roasbeef/gleam-mcp/issues/1).
