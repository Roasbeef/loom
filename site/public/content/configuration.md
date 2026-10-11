# Configuration

Loom reads one file, `loom.toml`. It names the model endpoints a session may call, routes roles onto them, and sets the limits and trust decisions that belong to the operator: which tools may reach the network, which host paths a jail may read, and which credentials the daemon fetches. This page covers the parts you need to get started. The full list of keys, with every default, is `docs/configuration.md` in the repository.

## Where the file comes from

| You run | Loom reads |
|---|---|
| `loom` | `~/.loom/loom.toml`, if it exists. `--state-dir` changes the directory. |
| `loom --config PATH` | That file, and passes it to the daemon the launcher starts. |
| `loomd --config PATH` | That file. With no `--config`, `loomd` reads no file. |

With no file at all, Loom builds a one-entry catalogue from environment variables: `LOOM_MODEL` (default `claude-opus-5`), `LOOM_BASE_URL`, `LOOM_CONTEXT_WINDOW`, `LOOM_MAX_OUTPUT_TOKENS`, and the API key variable. A file given with `--config` replaces that environment surface entirely. Precedence is command-line flags, then the file, then the environment, then built-in defaults.

## Rules about the file

**The reader is strict.** An unknown key, an unknown table, a value of the wrong type, or a model name that no entry defines is an error. The error names the file, the table and the key, and the daemon or session does not start. A typo is an error and not a setting that quietly does nothing.

**There is no live reload.** A session reads the file when it is created, opened or resumed, and keeps what it read. To apply an edit, stop the session and open it again. The `[daemon]` and `[peers]` tables are read once when the daemon starts, so they need a daemon restart.

**Secrets stay out of the file.** A model entry names an environment variable with `api_key_env`, and the daemon reads that variable when it dispatches a request. A missing key does not stop the daemon. The request fails with an error that the model and the terminal can read.

## Models

Each `[models.<name>]` table is one provider endpoint. The name is the handle that roles, profiles and the `/model` picker use, and it becomes part of the identity that strands store. Pick a name once and keep it.

```toml
[models.anthropic-opus]
dialect = "anthropic"
api_key_env = "ANTHROPIC_API_KEY"
model_id = "claude-opus-5"
context_window = 1000000
max_output_tokens = 32000

[models.baseten-oss]
dialect = "openai"
base_url = "https://inference.baseten.example/v1"
api_key_env = "BASETEN_API_KEY"
model_id = "openai/gpt-oss-120b"
context_window = 128000
max_output_tokens = 16000
thinking = "unsupported"
```

| Key | Meaning |
|---|---|
| `dialect` | The wire adapter: `anthropic`, `openai` (any OpenAI-compatible Chat Completions endpoint), `gemini`, `openai-responses`, or `codex-subscription`. |
| `base_url` | The endpoint root. Each dialect has a default, except `codex-subscription`, which forbids it. |
| `api_key_env` | The variable that holds the API key. Required for API-key dialects. |
| `model_id` | The identifier the provider expects, verbatim. |
| `context_window` | Tokens of context the model accepts. Overflow detection uses it, so use the provider's figure. |
| `max_output_tokens` | The default per-turn output ceiling. |
| `thinking` | `off`, `low`, `medium`, `high` or `unsupported`. The default is `off`. |

An optional `[models.<name>.pricing]` table turns the usage ledger's cost columns from zeros into amounts. Every rate is US dollars per million tokens.

The `codex-subscription` dialect is experimental. The repository's `docs/codex-subscription.md` explains `loomd codex login`.

## Roles and fallbacks

The `[roles]` table is required. It routes each role to an ordered chain of model names, best first.

```toml
[roles]
main = ["baseten-oss", "anthropic-opus"]
subagent = ["baseten-oss"]
summarize = ["anthropic-opus"]
```

A later name is used only when an attempt on the earlier one fails with a retryable error, such as a rate limit or a transport failure. It is never used after a settled response. Only `main` is required. A subagent with no route inherits its parent's model. The `advisor` role enables [advisor mode](https://github.com/Roasbeef/loom/blob/main/docs/architecture/advisor.md): with no route there is no advisor.

## Profiles

A profile is a named alternative to `[roles]`, so one file can serve several model sets.

```toml
[profiles.gemini.roles]
main = ["gemini-flash"]
summarize = ["gemini-flash"]
```

A role that a profile names replaces the default chain whole, and a role it omits keeps the default. Choose a profile when you create a session with `loom --model-profile gemini`, or with the new-session form on the web. In a live session, `/profile gemini` switches it, and `/profile default` returns to `[roles]`. A switch restarts the session and is refused while any strand is running. Only the owner may switch.

## Limits that belong to the operator

These tables decide what a session may reach. The defaults suit development on your own machine.

| Table | What it sets |
|---|---|
| `[tools]` | `network = "full"` (the default) or `"off"` for shell commands, and which host environment variable names pass into every jailed shell. |
| `[workspace]` | `read_scope = "host"` (the default) lets jails read installed tools and host files except protected paths. `"workspace"` allows only the workspace, the system runtime and explicit mounts. |
| `[secrets]` | Host commands that supply a named credential that your shell has not exported, such as `gh auth token`. The command runs on the host, outside every jail. |
| `[daemon]` | `ui = true` serves the [web view](#/docs/terminal-and-web). Connection limits live here too. |
| `[mcp.<name>]` | A stdio MCP server, which becomes a typed module in [code mode](#/docs/code-mode). Adding one is a trust decision. |
| `[lsp.<name>]` | A language server that runs in the jail. |

For lockdown, the command-line flags `--read-scope workspace` and `--network off` override the file.

Two more tables are written by hand and are an operator's alone: `[[rule]]`, which injects a paragraph of instruction when a literal phrase appears in the model's own text, and `[[schedule]]`, which delivers a prompt to a strand on a clock. The model cannot edit or list either one.

## Next

Read `docs/examples/loom.toml` in the repository. It is a commented file that shows every table with the reasoning behind each setting, and `docs/examples/loom-advisor.toml` is the smallest catalogue that pairs a fast model with an advisor.
