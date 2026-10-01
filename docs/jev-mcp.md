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

Jevelin MCP requires Gleam >= 1.18 and Erlang/OTP >= 29:

```sh
git clone https://github.com/Roasbeef/jevelin-mcp.git
cd jevelin-mcp
make release
```

`bin/jevelin-mcp` runs the compiled shipment. Its stdout contains MCP
frames, so Loom must launch that executable rather than a build command.
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

The model provider and Jev use separate credentials. `api_key_env` names an
environment variable; the TOML file contains no Jev credential. Set
`JEV_API_KEY` in the terminal that starts the daemon, using your secret
manager, and export it. To enter it interactively in Bash or Zsh:

```sh
read -r -s JEV_API_KEY
export JEV_API_KEY
```

The silent read waits for the key and Enter. Keep the credential out of
model prompts and tool arguments. Jevelin defaults to `jev-latest`; an
exported `JEV_MODEL` selects another default, and a tool's optional `model`
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
to pick up changed environment variables.

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
The Choice signature is:

```gleam
pub fn jev_choice(
  state: report.Value,
  choices: report.Value,
  options: List(#(String, report.Value)),
) -> Result(mcp.ToolResult, mcp.McpError)
```

Required arguments have labelled parameters. Structured schema fields use
`report.Value`; optional arguments travel in `options` by their wire names.
This generated signature does not prove that every constructed JSON value
is a valid Jev question. Jevelin's smart constructors validate the input
before HTTP runs, and its answer decoder checks the returned decision.

## Run a Choice query

Give the Loom session this instruction:

> Read `cap://mcp/jev` and `cap://report`. Use `code_mode` to call
> `jev.jev_choice` for a failed build, choosing between reading compiler
> logs and running tests. Return the choice, confidence, and token usage.

The following complete program passed through the real code-mode tool:

```gleam
//// A generated MCP facade carries this evaluation through the harness.

import cap/mcp
import cap/mcp/jev
import cap/report

pub fn main() -> report.Outcome {
  let choices =
    report.list([
      report.object([
        #("label", report.string("logs")),
        #("description", report.string("Read the compiler error.")),
      ]),
      report.object([
        #("label", report.string("tests")),
        #("description", report.string("Run the test suite.")),
      ]),
    ])

  case
    jev.jev_choice(
      state: report.string("The user wants to inspect a failed build."),
      choices: choices,
      options: [
        #(
          "instructions",
          report.string("Choose the most relevant next action."),
        ),
      ],
    )
  {
    Ok(answer) -> report.text(mcp.text(answer))
    Error(_reason) -> report.failure("The Jev MCP evaluation failed.")
  }
}
```

The array builder is `report.list`, not `report.array`. `mcp.text` joins the
result's text blocks; Jevelin returns the evaluation as JSON text and as
structured MCP content. The program reports that JSON to Loom, which stores
the tool result and supplies it to the model's next turn. A live Jev answer
depends on the service; the fixture answer below is deterministic.

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

For the program above, the fixture returns:

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

## What the end-to-end run proved

On October 1, 2026, an isolated Loom daemon ran the compiled Jevelin MCP
server with this HTTP fixture and a scripted local model provider. The
model discovered the APIs through `fs_read`, submitted the program, and
received its result. Both the hermetic build and satellite executed;
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
