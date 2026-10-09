# Configuration reference: `loom.toml`

`loom.toml` is the operator's configuration file for Loom. It names the model
endpoints a session may call, routes roles onto them, and sets the limits and
trust decisions an operator owns: which tools may reach the network, which host
paths a jail may read, which credentials the daemon fetches, and how the daemon
admits connections. This page lists every key the file accepts, with its type,
default and allowed values. Where a subsystem needs more than a row to explain,
the row links to the architecture document that does.

Each table's key list is derived from the decoder's own list, and `make
doc-check` fails when a key is missing from this page or documented here without
being accepted (`scripts/config_keys.sh`). A table's section on this page is
therefore complete as far as keys go. Values, defaults and meanings are written
by hand from the decoders, so a mismatch there is a bug in this page to report.

Worked, commented files:

- [`examples/loom.toml`](examples/loom.toml): every table, with the reasoning
  behind each setting.
- [`examples/loom-baseten.toml`](examples/loom-baseten.toml): a single-provider
  catalogue for Baseten-hosted models.
- [`examples/loom-advisor.toml`](examples/loom-advisor.toml): the smallest
  catalogue that pairs a fast main model with an advisor.

## How the file is found

| Launcher | How it picks the file |
| --- | --- |
| `loomd --config <path>` | The path given. The last `--config` wins. With no `--config`, no file is read and the catalogue is one entry built from the `LOOM_*` environment variables (`LOOM_MODEL`, `LOOM_BASE_URL`, `LOOM_CONTEXT_WINDOW`, `LOOM_MAX_OUTPUT_TOKENS`, and the API key variable). |
| `loom --config <path>` | The path given, passed on to the daemon the launcher starts. |
| `loom` with no `--config` | `<state-dir>/loom.toml` when that file exists, where the state directory is `--state-dir` or `~/.loom`. When it does not exist, no file is read. |
| `loom --model-profile <name>` | Selects a `[profiles.<name>]` table of the file for a newly created session. A resumed session keeps the profile it was created with, or the one `/profile` last saved for it. |
| New-session form on the web home | Offers the file's profiles and its `[models.<name>]` keys (see [Choosing a model for one session](#choosing-a-model-for-one-session)). |

A file given with `--config` replaces the `LOOM_*` environment surface for model
and role configuration entirely. Precedence is command-line flags, then the
file, then the environment, then built-in defaults. The two flags that overlap
with a table are `--read-scope` and `--network`, which override
[`[workspace]`](#workspace) `read_scope` and [`[tools]`](#tools) `network`.

API keys are never written in this file. `api_key_env` names an environment
variable, and the daemon reads it when it dispatches a request. A credential the
host holds without exporting it (a keychain entry, a vault) is fetched by a
[`[secrets]`](#secrets) entry instead.

## How the file is read

**The decoder is strict.** A key it does not know is refused, as is a table it
does not know, a value of the wrong type, a word that is not one of the allowed
values, and a dangling model name in a role chain. The refusal names the file,
the table and the key, and the daemon or session does not start. A typo is an
error instead of a setting that silently does nothing.

**There is no live reload.** A session reads the file when it is built: when it
is created, opened, or resumed. It keeps what it read for as long as it runs, so
an edit reaches a running session only after that session is stopped and opened
again. Two tables are read once, when the daemon starts, and need a daemon
restart: [`[daemon]`](#daemon) and [`[peers]`](#peers) (from protocol-change
077). The MCP, language-server, rule and schedule tables are trust decisions and
have no flag, no discovery and no reload path; editing the file and reopening the
session is the decision.

**Tables are decoded by separate parsers over one document.** `client/catalog`
checks the top-level table names, so a table that is missing from its list is
refused however well its own parser would have read it. Each table's parser then
checks that table's keys. Failures are worded with the full path of the key, such
as `models.baseten-oss.context_window must be positive`.

**TOML conventions.** Table names that contain a user-chosen part are written
`<name>` below. Durations are in the unit the key's name states. A key that is
documented as optional has the default shown, and omitting the table that holds it
gives every key its default.

## Top-level tables

The top-level keys the decoder accepts are the tables below. A top-level key that
is not in this list is refused.

| Key | Form | Meaning | Reference |
| --- | --- | --- | --- |
| `models` | table of `[models.<name>]` | Provider endpoints. Required. | [`[models.<name>]`](#modelsname) |
| `roles` | table | Which models serve which role. Required, and must route `main`. | [`[roles]`](#roles) |
| `profiles` | table of `[profiles.<name>]` | Named alternatives to `[roles]`. | [`[profiles.<name>]`](#profilesname) |
| `mcp` | table of `[mcp.<name>]` | Stdio MCP servers exposed to code mode. | [`[mcp.<name>]`](#mcpname) |
| `lsp` | table of `[lsp.<name>]` | Language servers behind the `lsp_*` tools. | [`[lsp.<name>]`](#lspname) |
| `rule` | array of tables, `[[rule]]` | Triggered project rules. | [`[[rule]]`](#rule) |
| `schedule` | array of tables, `[[schedule]]` | Operator-written scheduled heartbeats. | [`[[schedule]]`](#schedule) |
| `schedules` | table | Whether the model may create schedules. | [`[schedules]`](#schedules) |
| `workspace` | table | Read scope, extra mounts and Go caches for jails. | [`[workspace]`](#workspace) |
| `tools` | table | Network and environment of jailed tool shells. | [`[tools]`](#tools) |
| `secrets` | table | Host commands that supply named credentials. | [`[secrets]`](#secrets) |
| `daemon` | table | Connection limits and the web view. | [`[daemon]`](#daemon) |
| `advisor` | table | What the advisor strand may read and how often it is fed. | [`[advisor]`](#advisor) |
| `memory` | table | Memory distillation cadence and wall time. | [`[memory]`](#memory) |
| `jobs` | table | Background job wall ceiling and idle heartbeat. | [`[jobs]`](#jobs) |
| `retry` | table | Provider retry ladder. | [`[retry]`](#retry) |
| `peers` | table | Default peer links (from protocol-change 077). | [`[peers]`](#peers) |

## `[models.<name>]`

One table per provider endpoint. `<name>` is any TOML key. It is the handle the
rest of the file and the clients use: roles and profiles name entries by it, the
`/model` picker switches a strand by it, and it becomes the provider half of the
`{provider, model_id}` identity that strands store durably. Choose a name once
and keep it. Entries are sorted by name when read, so file order has no meaning.

A `headers` key is refused with its own message: credentials come from the
selected adapter's authentication boundary. See
[models](architecture/models.md) for the gateway, dialects and fallback.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `dialect` | string | required | `anthropic`, `openai`, `gemini`, `openai-responses`, `codex-subscription` | The wire adapter. `openai` is any OpenAI-compatible chat-completions endpoint. `codex-subscription` uses native Sign in with ChatGPT and the public Responses API. |
| `auth` | string | required for Responses and subscription, refused otherwise | `api-key` for `openai-responses`; `codex` for `codex-subscription` | The authentication mode. Platform API billing and ChatGPT plan usage are separate arrangements. |
| `base_url` | string | the dialect's default; forbidden for `codex-subscription` | a URL | The endpoint root. A trailing slash is dropped. Defaults: `https://api.anthropic.com` for `anthropic`, `https://api.openai.com/v1` for `openai` and `openai-responses`, `https://generativelanguage.googleapis.com/v1beta` for `gemini`. |
| `api_key_env` | string | required for API-key dialects; forbidden for `codex-subscription` | an environment variable name | The variable holding the API key, read at dispatch. A missing key does not stop the daemon; the request fails in-band. |
| `model_id` | string | required | non-empty | The identifier the provider expects in the request body, verbatim. |
| `context_window` | integer | required | positive | Tokens of context the model accepts. Drives overflow detection, so use the provider's figure. |
| `max_output_tokens` | integer | required | positive | The default per-turn output ceiling. |
| `thinking` | string | `off` | `off`, `low`, `medium`, `high`, `unsupported` | The reasoning level requests ask for. `unsupported` is a synonym for `off` for models with no reasoning mode; neither sends a reasoning field. |
| `vision` | boolean | the known model default | `true`, `false` | Whether the endpoint reads image blocks. The default is `false` for `GLM-5.3` (`zai-org/GLM-5.3`) and `true` for every other model id, including `GLM-5.3-Flash`. An image-bearing run on a text-only entry uses the `vision` role or is refused. |
| `max_images` | integer | `8` | positive | The most image blocks in one provider request, history included. The oldest historical images become placeholders to fit; stored images are never deleted. Each fallback entry uses its own limit. |
| `pricing` | table | unpriced | see below | Turns the usage ledger's cost columns from zeros into amounts. |
| `cyber_access` | string | omitted, server default | `standard`, `daybreak_blue`, `daybreak_red`; Responses dialects only | Selects `access_programs.cyber` per request. Approval and model compatibility are enforced by the provider; setting it does not grant access. |
| `profile` | string | required for `codex-subscription`, forbidden otherwise | 1–64 ASCII letters, digits, `_` or `-`, starting with a letter or digit | A native credential profile created by `loomd codex login --profile NAME`. Several entries can share it. This is separate from the named role profiles below. |

## `[models.<name>.pricing]`

Optional. Every rate is US dollars per million tokens, the unit providers
publish. `input` and `output` are required once the table exists. The two cache
rates default to `input`, which can only over-report spend. A model without a
pricing table is unpriced and its usage records keep a zero cost. Pricing is
applied once, in the gateway ([models](architecture/models.md)). For subscription
entries, these are API reference estimates, not ChatGPT plan credits or account
charges. Missing usage or prices retain unknown or partial coverage.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `input` | number | required | zero or more | Dollars per million uncached prompt tokens. |
| `output` | number | required | zero or more | Dollars per million output tokens. |
| `cache_read` | number | `input` | zero or more | Dollars per million prompt tokens read from the provider's cache. |
| `cache_write` | number | `input` | zero or more | Dollars per million prompt tokens written to the provider's cache. |

## `[roles]`

Required. Routes each role to an ordered fallback chain of `[models]` names. Each
value is a non-empty array of model names, best first. A later name is used when
an attempt on the earlier one fails with a retryable error (a rate limit, a
transport failure), never after a settled response. The walk happens inside one
attempt, so it costs no retry from the harness's own retry ladder, and the first
name is always tried first. Every name must be defined in `[models]`.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `main` | array of strings | required | model names | The model a session runs on. The first name is the identity new strands start with. |
| `subagent` | array of strings | unrouted | model names | Strands an agent spawns. A spawned child with no route inherits its parent's model. |
| `plan` | array of strings | unrouted | model names | Reserved. It is parsed and validated and has no caller yet. |
| `summarize` | array of strings | unrouted | model names | Structural summaries, memory distillation and the glance loop. Unrouted, distillation uses `main`, and the glance tries `subagent` and then `main`. A cheap entry here controls what those cost. |
| `vision` | array of strings | unrouted | model names, each reading images | Image-bearing requests whose strand model is text-only. An entry that declares `vision = false` is refused. |
| `advisor` | array of strings | unrouted | model names | The advisor strand. With no `advisor` route there is no advisor. See [advisor](architecture/advisor.md). |

## `[profiles.<name>]`

Optional. A profile is a named alternative to `[roles]`, so one daemon and one
file serve several model sets. `<name>` is a lowercase letter followed by
lowercase letters, digits, `_` or `-`, at most 32 characters. A session picks one
when it is created (`loom --model-profile <name>`, or the new-session form on the
web) and keeps it when resumed. Every profile is validated when the file is read,
so a typo in a profile nobody has selected still refuses the file.

`default` is reserved: it is the word `/profile default` uses for the `[roles]`
table, so a `[profiles.default]` table is refused.

A live session changes its profile with `/profile <name>`, or `/model-profile
<name>`, in the terminal and on the web page. `/profile default` returns it to
`[roles]`, and `/profile` alone shows the current profile and the names the file
defines. A switch saves the name with the session and restarts the session so
that every role, including the subagent, summarizer and advisor routes, is built
from the new profile; it is refused while any strand is running. A strand that
holds the old profile's model for `main`, `subagent` or `advisor` moves to the
new profile's. A strand whose model was chosen with `/model` keeps it. Only the
session owner may switch
([protocol-change/082](../protocol-change/082-session-profile-switch.md)).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `roles` | table | required | see below | The roles this profile replaces. It must name at least one. |

## `[profiles.<name>.roles]`

Takes the same role keys as `[roles]`, with the same value form. A role the table
names replaces the default chain whole. A role it omits keeps the default chain.
`main` need not appear, since the default routes it.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `main` | array of strings | the `[roles]` chain | model names | Replacement chain for `main`. |
| `subagent` | array of strings | the `[roles]` chain | model names | Replacement chain for `subagent`. |
| `plan` | array of strings | the `[roles]` chain | model names | Replacement chain for `plan`. |
| `summarize` | array of strings | the `[roles]` chain | model names | Replacement chain for `summarize`. |
| `vision` | array of strings | the `[roles]` chain | model names, each reading images | Replacement chain for `vision`. |
| `advisor` | array of strings | the `[roles]` chain | model names | Replacement chain for `advisor`. |

### Choosing a model for one session

The web home's new-session forms and the `sessions.create` control command can
pin a session's `main` role to one `[models.<name>]` entry, with or without a
profile. The `main` chain becomes that one entry, so it has no fallbacks, and
every other role keeps the chain `[roles]` or the chosen profile gives it. A
profile and a model compose: the profile's roles are applied first and `main` is
pinned afterwards. The session stores the key and resolves it again at every
open, so renaming or removing the entry makes the session unopenable until it is
restored. The web form offers a key of at most 64 bytes; a longer `<name>` is
valid in the file and cannot be chosen this way. Only the key is given to the
web page.

## `[mcp.<name>]`

Optional, one table per stdio MCP server. `<name>` becomes the `cap/mcp/<name>`
module that code-mode programs import, so it is a single lowercase-ASCII
identifier segment (`[a-z][a-z0-9_]*`), is not `internal`, and is a name that
module-name mangling leaves unchanged. Adding a server is an operator trust
decision. There is no flag, discovery or live reload. See
[mcp](architecture/mcp.md) and [code mode](architecture/code-mode.md).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `command` | array of strings | required | non-empty, each element non-empty | The server's argv, executable first. Never a shell string. |
| `api_key_env` | string | none | an environment variable name | A host variable read when the server process starts and injected into its environment under the same name. |

## `[lsp.<name>]`

Optional, one table per language server. Language servers are configured, never
discovered: with no `[lsp]` table there are no `lsp_*` tools and nothing is
spawned. A table is a language profile
([ADR-016](adr/016-language-profiles.md)): an installed extension may ship the
same table, one decoder reads both, and a table in this file with the same name
replaces an installed profile whole. `<name>` follows the `[mcp.<name>]` rule.
Each server runs jailed and rooted at the nearest ancestor of a file that holds
one of its `root_markers`, and the table is the whole of what that jail grants
beyond the project. See [lsp](architecture/lsp.md).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `command` | array of strings | required | non-empty argv | The server's argv. An array, never a shell string. |
| `extensions` | array of strings | required | each with a leading dot | The file extensions the server answers for, compared case-insensitively. One extension has exactly one owning server. |
| `root_markers` | array of strings | required | bare file names | Names that mark a project root. |
| `project` | string | `read-only` | `read-only`, `writable` | Whether the server may write the project. `gleam lsp` writes `manifest.toml` and `build/`, so it needs `writable`. |
| `readable` | array of strings | none | absolute, `~/<path>`, or `<cache>/<path>` | Extra roots the server may read. Relative paths, `..` and a bare `~/` or `<cache>/` are refused. |
| `writable` | array of strings | none | absolute, `~/<path>`, or `<cache>/<path>` | Extra roots the server may write. Same rules as `readable`. |
| `env` | array of strings | none | names matching `[A-Z_][A-Z0-9_]*` | Variable names passed through from the daemon's environment. `PATH`, `HOME`, `TMPDIR`, `LOOM_SCRATCH_DIR` and `GIT_CONFIG_GLOBAL` are refused. |
| `cache_env` | table | none | variable name to relative directory | Private caches: each variable is set to `<cache>/loom/lsp/<server>/<dir>`, a directory Loom creates and grants writable. The directory has no `.` or `..` component and is not inside another entry's. A name may not also be in `env`. |
| `language_id` | string | the first extension without its dot | `[a-z0-9][a-z0-9+._-]*`, at most 40 characters | The `languageId` documents are opened with. |
| `qualifier_separators` | array of strings | `["."]` | non-empty strings, never `/` | What a qualified symbol is split on, such as `["::"]` for Rust. The longest listed is tried first. |
| `module_case` | string | `as-written` | `as-written`, `snake` | How a qualifier is compared with file and directory names. `snake` maps CamelCase segments first. |
| `hint` | string | none | one line, at most 200 bytes | Appended to the `lsp_definition` tool description, so the model reads it on every request. |
| `prepare` | string | none | `gleam-dependencies` | The operator approves networking for one finite dependency-preparation call while the server stays offline. Requires a command of the form `[<gleam>, "lsp"]`, `project = "writable"`, and `cache_env.XDG_CACHE_HOME`. |

## `[[rule]]`

Optional, one table per rule. A rule is a paragraph of standing instruction that
costs the model's context nothing until something the model itself says trips a
trigger. Then the harness injects the body once into the run in flight, fenced and
attributed. A rule fires at most once per strand per session, and the record is
durable. At most 64 rules. There is no flag or live reload. See
[automation](architecture/automation.md).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `name` | string | required | at most 64 characters, no `/`, quote or newline, unique | The rule's identity, and a key segment of its durable fired mark. |
| `triggers` | array of strings | required | 1 to 32 entries, each non-empty and at most 256 characters | Literal, case-sensitive substrings, not patterns. Any one fires the rule. Matched against settled assistant text only, not thinking, tool arguments or prompts. |
| `body` | string | required | non-empty, at most 8192 characters | The text injected when the rule fires. |

## `[[schedule]]`

Optional, one table per operator-written heartbeat. A schedule fires on a clock
rather than on something the model said. Each table sets exactly one of `every`,
`cron` or `at`. At most 16 tables. Every time is UTC unless `utc_offset` says
otherwise, and an offset is not a timezone: it does not follow daylight saving. A
recurring schedule always expires, on whichever of `max_fires` and
`expires_after_s` comes first. Fires are durable and exactly-once, and a window
missed while the server was down coalesces to at most one late fire. See
[automation](architecture/automation.md).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `name` | string | required | at most 64 characters, no `/`, quote or newline, unique | The schedule's identity and a key segment of its durable fired mark. |
| `target` | string | `main` | a strand address, at most 64 characters | The strand the text is injected onto. A schedule on a subagent strand ends when that subagent's work does. |
| `every` | string | one timing key required | a whole number of seconds and a literal `s`, from `60s` to `604800s` | A fixed interval on a grid aligned to the epoch. |
| `cron` | string | one timing key required | five fields: minute, hour, day of month, month, day of week | A calendar expression. Fields take `*`, numbers, ranges, steps and lists. No seconds field, no month or day names, no `L`, `W`, `?` or `#`. When both day fields are restricted they are ORed. |
| `at` | string | one timing key required | an RFC 3339 UTC timestamp | A one-shot. Refuses `max_fires`, `expires_after_s` and `utc_offset`. |
| `utc_offset` | string | `+00:00` | `[+-]HH:MM` from `-14:00` to `+14:00`, only beside `cron` | A fixed offset for the cron fields. |
| `max_fires` | integer | `1000` | 1 to 1000, recurring schedules only | The most fires before the schedule ends. |
| `expires_after_s` | integer | `604800` | 1 to 604800, recurring schedules only | Seconds from when a running server first loads the schedule until it ends, whether or not it fired. |
| `wake` | boolean | `false` | `true`, `false` | With `false` the schedule steers a run already open and holds while the strand is idle. With `true` it may start a run on an idle strand. |
| `body` | string | required | non-empty, at most 8192 characters | The text injected on each fire. |

## `[schedules]`

Optional. The policy for schedules the model creates with `schedule_create`,
`schedule_list` and `schedule_cancel`. The tables written under
[`[[schedule]]`](#schedule) are the operator's alone: a model cannot edit, list or
cancel one. A model-created schedule is held to every limit above, can fire only
onto the strand that created it or a strand that strand spawned, and one session
holds at most 16 of them.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `model_created` | string | `steer` | `off`, `steer`, `wake` | `off` registers no schedule tool. `steer` lets the model create schedules that only steer an open run. `wake` additionally lets one start a run on an idle strand, so a model can keep a session alive for as long as the server is up. |

## `[workspace]`

Optional. Selects what a jailed tool or language server may read, which extra host
regions it may mount, and how the workspace's private Go caches are bounded and
seeded. The defaults are a development posture: host files are readable, writes
stay in the workspace and writable mounts, and the daemon's protected paths stay
masked. `loomd --read-scope workspace` overrides `read_scope`. See
[effects](architecture/effects.md) (the jail and the Go caches).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `read_scope` | string | `host` | `host`, `workspace` | `host` makes installed tools and host files readable except protected paths. `workspace` allows only the workspace, the system runtime and explicit mounts. |
| `mounts` | array of tables | none | see [`[workspace] mounts`](#workspace-mounts) | Extra host regions the jails may reach. May be written as inline tables or as `[[workspace.mounts]]`. A path may appear once. |
| `go_cache_limit_mib` | integer | `10240` | positive | The size in MiB above which a starting session retires the workspace's private Go build cache. |
| `go_module_mirror` | string | none | an absolute path without `.` or `..` segments, using letters, digits and `. _ - + @ ~ /`; not the root | The operator's Go module cache (the directory that holds `cache/download`, `go env GOMODCACHE`), offered read-only as a module proxy so modules are not downloaded again. Whether it exists and clears the workspace and masked paths is judged at session boot. |

## `[workspace] mounts`

Each element of `mounts` is a table with these keys. A mount is the escape hatch
for regions that no manifest describes. The toolchain, sibling path dependencies
and per-user caches are derived and need no entry.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `path` | string | required | an absolute path | The host path to bind. A path that overlaps a protected region is refused when the session policy is composed. |
| `access` | string | required | `ro`, `rw` | Read-only or read-write. |

## `[tools]`

Optional. What the session's jailed shell may reach and carry in its environment.
Every name here is a variable name, and values are read from the daemon's own
environment at boot, the same discipline as `api_key_env`. A name the host has not
set is skipped with one warning line, not a boot failure. `PATH`, `HOME`, `TMPDIR`,
`LOOM_SCRATCH_DIR` and `GIT_CONFIG_GLOBAL` are server-owned and refused in `env`
and in `[tools.set]`. A name may be in `env` or `[tools.set]`, not both.
`loomd --network` overrides `network`. See
[effects](architecture/effects.md#the-shell-tools-the-operators-tools-table).

`[tools.set]` is a subtable whose keys are variable names and whose values are
literal strings, for pointing a tool at configuration outside the workspace, for
example `GH_CONFIG_DIR = "/home/me/.config/gh"`. Its keys are free, so it has no
fixed key list.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `network` | string | `full` | `off`, `full` | `full` gives every jailed shell unrestricted egress, which `gh`, `git fetch` and `curl` need. `off` disables shell egress. Native search is always offline. There is no host allowlist. |
| `env` | array of strings | none | non-empty variable names, no duplicates | Host variables passed into every jailed tool shell. |
| `set` | table | none | variable name to string | Literal variables set in every jailed tool shell. |
| `path` | array of strings | none | absolute directories, no duplicates | Appended to the shell's `PATH` after the server's own entries, which stay in front. |

## `[secrets]`

Optional. A `[secrets]` entry says how to obtain a credential the host holds but
does not export. Each key is the variable name that the rest of the file already
mentions (an `api_key_env`, an MCP server's `api_key_env`, a name in `[tools]
env`), and each value is a table with one key.

```toml
[secrets]
GH_TOKEN = { command = ["gh", "auth", "token"] }
```

The command runs on the host, outside every jail, as the operator, with the
daemon's environment. Its standard output less one trailing newline is the value.
A command that exits 0 with no output resolves nothing, and the name stays unset.
The value lives in the daemon's memory only and takes precedence over an
environment variable of the same name. Entries run afresh each time a session is
created or opened, one after another, each bounded by ten seconds. A failure or
timeout is one warning line naming the variable and never refuses the session. See
[effects](architecture/effects.md#secrets).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `command` | array of strings | required | non-empty, each argument non-empty | The argv of the command that prints the value. Never a shell line. |

## `[daemon]`

Optional. Connection limits and the web view belong to the daemon, not to a
session. The daemon reads the table once at startup from the last `--config`
file, and a running daemon never rereads it. The two limits reserve potential
payload capacity. They do not allocate memory in advance and do not bound total
RSS. See [daemon](architecture/daemon.md).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `max_connections` | integer | `64` | positive | HTTP upgrades reserved and WebSockets admitted, combined. |
| `max_reserved_message_bytes` | integer | `536870912` | positive | The sum, over admitted connections, of each one's reserved inbound message and delivery allowance. The default is 512 MiB, room for twelve ordinary terminal pairs. |
| `ui` | boolean | `false` | `true`, `false` | Turns the web view on for the life of the daemon, as `loomd --ui` does. Either one enables it; the file cannot turn off a view the flag turned on. See [web view](architecture/web-view.md). |
| `profile` | boolean | `false` | `true`, `false` | Read by the shell launcher, not the daemon, to start the daemon as a profiling node (`scripts/profile-launcher.sh`). The daemon accepts and ignores it. |

## `[advisor]`

Optional. Settings for the advisor strand, which exists only when `[roles]`
routes an `advisor`. See [advisor](architecture/advisor.md) and
[`examples/loom-advisor.toml`](examples/loom-advisor.toml).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `tools` | array of strings | `["fs_read", "grep"]` | non-empty built-in tool names | The tools the advisor is registered with besides `advise`, which is always present. An empty array is honoured. The default is read-only on purpose, since a second agent that can edit the workspace races the first. |
| `feed_every_steps` | integer | `20` | zero or more | How many of the primary's steps pass inside one run before the work so far is offered to the advisor. `0` leaves the end of the run as the only occasion. A floor, not a cadence: a feed that arrives while the advisor is reviewing is coalesced. |
| `block_cooldown_reviews` | integer | `2` | zero or more | How many reviews a delivered block silences the next one for. A block inside the window is downgraded to a nudge. `0` lets every block through. |

## `[memory]`

Optional. Whether and how long the memory distillation pass runs. The table is
independent of a session's runtime configuration: it belongs to the memory domain
the daemon maintains. See [memory](architecture/memory.md).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `distill` | string | `on-boot` | `on-boot`, `off` | `on-boot` runs a pass at domain admission and after successful session closes. `off` runs none and leaves remembered notes for a hand-run `loom-distill`. |
| `distill_wall_ms` | integer | `600000` | 1 to 600000 | How many milliseconds one whole pass may take before it is cut off. The ceiling is the memory session's writer lease, and a larger value is refused rather than clamped. |

## `[jobs]`

Optional. Limits on background jobs, the long-running shell processes a strand
starts and polls. See [effects](architecture/effects.md#background-jobs) and
[async collaboration](architecture/async-collaboration.md).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `max_wall` | integer | `3600` | positive, in seconds | Raises the ceiling a background job's wall time is clamped to. It cannot lower it: a value under one hour is raised to one hour. |
| `heartbeat_s` | integer | `600` | zero or more, in seconds | How long a strand may sit idle while its jobs are still running before it is woken with a listing of them. `0` turns the heartbeat off. |

## `[retry]`

Optional. The provider retry ladder: how a run waits and retries after a
retryable provider failure. Each key stands alone, so a table that sets only
`max_delay_ms` keeps the default attempts and first wait. Without the table the
ladder is the runtime default: unbounded attempts, a one-second first wait that
doubles up to a one-minute cap.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `attempts` | integer or string | `"unbounded"` | a whole number of at least 1, or `"unbounded"` | The retry budget. A bounded ladder fails the run once spent. `0` is refused. |
| `base_delay_ms` | integer | `1000` | zero or more | The first wait, in milliseconds. |
| `max_delay_ms` | integer | `60000` | zero or more | The ceiling the wait doubles toward, in milliseconds. |

## `[peers]`

(From protocol-change 077.) Optional, read once when the daemon starts, like
`[daemon]`. A peer link is a grant that lets one session's strand put a message
into another's prompt. By default every link is an explicit owner grant. This
table lets an owner say once that the sessions the daemon's owner holds alone are
linked, `main` to `main`. The default link is computed at admission and never
stored, a recorded unlink overrides it, and a session that has a member is not
eligible. A message to a session that is not running is refused for every link. See
[protocol-change 077](../protocol-change/077-web-peer-links.md) for the trust
argument and its costs, and [async collaboration](architecture/async-collaboration.md)
for explicit links.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `default_links` | string | `off` | `off`, `same_owner` | `same_owner` admits a `main` to `main` message between two different sessions that the owner holds alone and that have no recorded unlink. |
| `default_wake` | string | `busy_only` | `busy_only`, `may_wake` | The wake permission of a default link. `busy_only` adds to a running strand and does nothing to an idle one. `may_wake` may start a run on the recipient's `main`. An explicit grant for the pair overrides it. |

## What this file does not configure

- **Hooks.** Claude-compatible hooks are read from `~/.claude/settings.json`, the
  workspace's `.claude/settings.json` and `.claude/settings.local.json`. A `hooks`
  table in `loom.toml` is refused. See
  [hooks compatibility](architecture/hooks-compat.md).
- **Goals.** There is no goals table. See [goals](architecture/goals.md).
- **Compaction.** It is set by the `LOOM_COMPACTION`, `LOOM_COMPACTION_RESERVE`
  and `LOOM_COMPACTION_KEEP_RECENT` environment variables. See
  [compaction](architecture/compaction.md).
- **Helper pool and disabled tools.** `LOOM_HELPER_POOL` and
  `LOOM_DISABLE_TOOLS`, environment variables read by the daemon.
- **Daemon flags.** `--state-dir`, `--bind`, `--capacity`, `--owner-name`, `--ui`,
  `--helper`, `--codemode-seed`, `--codemode-seams`, `--best-effort` and
  `--full-enforcement` are flags with no table. Run `loomd --help`.

## Common setups

### One provider

A single model, no fallback. This is the smallest valid file: `[models]` with one
entry and a `[roles]` table that routes `main`.

```toml
[models.opus]
dialect = "anthropic"
api_key_env = "ANTHROPIC_API_KEY"
model_id = "claude-opus-5"
context_window = 1000000
max_output_tokens = 32000

[roles]
main = ["opus"]
```

With no `subagent` or `summarize` route, a spawned child inherits its parent's model and summaries use `main`.

### Several providers with roles

A cheap model for subagents and summaries, a strong one for the main strand, and a
second provider as the fallback when the first rate-limits.

```toml
[models.opus]
dialect = "anthropic"
api_key_env = "ANTHROPIC_API_KEY"
model_id = "claude-opus-5"
context_window = 1000000
max_output_tokens = 32000

[models.flash]
dialect = "gemini"
api_key_env = "GEMINI_API_KEY"
model_id = "gemini-3.8-flash"
context_window = 1048576
max_output_tokens = 65536

[roles]
main = ["opus", "flash"]
subagent = ["flash"]
summarize = ["flash"]
```

The fallback is walked only on a retryable failure, and never after a settled
response. Add `[models.<name>.pricing]` tables to see cost in the ledger.

### Profiles

One file, two model sets. A profile names only the roles it changes.

```toml
[profiles.cheap.roles]
main = ["flash"]

[profiles.review.roles]
main = ["opus"]
advisor = ["flash"]
```

Start a session with `loom --model-profile cheap`, or switch a running one with
`/profile cheap`. Roles a profile omits keep the `[roles]` chain.

### A Go module mirror

Jailed `go` commands use a private cache per workspace and download modules into
it. A mirror offers the host's module cache read-only so the first build does not
download everything again.

```toml
[workspace]
go_module_mirror = "/home/me/go/pkg/mod"
go_cache_limit_mib = 20480
```

The directory must hold `cache/download`, which is what `go env GOMODCACHE`
prints on most hosts.

### A jail network

Network is independent of read scope. For an offline, workspace-only jail:

```toml
[workspace]
read_scope = "workspace"
mounts = [{ path = "/srv/datasets", access = "ro" }]

[tools]
network = "off"
```

For the default posture with `gh` working inside the jail, keep `network = "full"`,
add the host's tool directory to `path`, and fetch the token from the keychain:

```toml
[tools]
network = "full"
path = ["/opt/homebrew/bin"]
env = ["GH_TOKEN"]

[secrets]
GH_TOKEN = { command = ["gh", "auth", "token"] }
```

The same two settings are available as `loomd --read-scope workspace --network
off`, and the flags win over the file.
