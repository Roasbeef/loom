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
| `loom --executor <name> --workspace <registered name>` | Not a file choice: creates new sessions in the workspace registered under that name on that `[executors.<name>]` of the file the daemon loaded. With `--executor`, `--workspace` is a name and not a path. |
| `loom --pool <name> --workspace <registered name>` | The same, but the daemon picks the executor from that `[pools.<name>]` when the session first opens. Exclusive with `--executor`. |
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

**A session reloads by reopening.** A session reads the file when it is built:
when it is created, opened, or resumed, and keeps what it read while it runs. A
daemon session also watches the file it loaded
([protocol-change/092](../protocol-change/092-config-proposals.md)): once an edit
has settled (two reads a second apart agree) and the new text loads under the
session's profile and model, the session reopens as soon as no strand is
running, which rebuilds everything the file configures. A save that does not load
is logged as `config.refused` and changes nothing. The reopen closes the session's
attachments (the terminal reattaches, a web page needs a reload) and ends its
background jobs. An agent can suggest an edit with `propose` and `target:
"config"`; the owner approves it in the proposals review, and the approval
writes the file. Eight tables are read once, when the daemon starts, and need a daemon
restart: [`[daemon]`](#daemon), [`[peers]`](#peers) (from protocol-change 077),
[`[distribution]`](#distribution), [`[executors.<name>]`](#executorsname),
[`[pools.<name>]`](#poolsname), [`[workspaces.<name>]`](#workspacesname) and
[`[orchestrators.<name>]`](#orchestratorsname) (from protocol-change 078) and
[`[spawners.<name>]`](#spawnersname) (from protocol-change 084). `[distribution]` also needs the VM booted for it.
The MCP, language-server, rule and schedule tables are trust decisions and
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
| `daemon` | table | The listener address, connection limits and the web view. | [`[daemon]`](#daemon) |
| `advisor` | table | What the advisor strand may read and how often it is fed. | [`[advisor]`](#advisor) |
| `memory` | table | What memory each run starts with. | [`[memory]`](#memory) |
| `jobs` | table | Background job wall ceiling and idle heartbeat. | [`[jobs]`](#jobs) |
| `retry` | table | Provider retry ladder. | [`[retry]`](#retry) |
| `peers` | table | Default peer links (from protocol-change 077). | [`[peers]`](#peers) |
| `distribution` | table and array of `[[distribution.peers]]` | Trusted TLS Erlang distribution (from protocol-change 078). | [`[distribution]`](#distribution) |
| `executors` | table of `[executors.<name>]` | Machines a session's workspace may be registered on (from protocol-change 078). | [`[executors.<name>]`](#executorsname) |
| `pools` | table of `[pools.<name>]` | Named groups of executors a session may be placed on without naming one (from protocol-change 078). | [`[pools.<name>]`](#poolsname) |
| `workspaces` | table of `[workspaces.<name>]` | Checkouts this machine serves to orchestrators (from protocol-change 078). | [`[workspaces.<name>]`](#workspacesname) |
| `orchestrators` | table of `[orchestrators.<name>]` | Other orchestrators this daemon asks who owns a session it does not know (from protocol-change 078). | [`[orchestrators.<name>]`](#orchestratorsname) |
| `directory` | table | Membership of the session directory's Khepri cluster (from protocol-change 083). | [`[directory]`](#directory) |
| `spawners` | table of `[spawners.<name>]` | Other orchestrators that may start subagents on this one, and on what terms (from protocol-change 084). | [`[spawners.<name>]`](#spawnersname) |

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
| `service_tier` | string | omitted, provider default | `fast`, `default`; Responses dialects only | Requests Fast mode or standard processing for this model entry. Fast mode can consume more subscription allowance or incur higher API charges; eligibility and the served tier are provider-controlled. |
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
| `summarize` | array of strings | unrouted | model names | Structural summaries and the glance loop. Unrouted, summaries use `main`, and the glance tries `subagent` and then `main`. A cheap entry here controls what those cost. |
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
| `runs_on` | string | `"orchestrator"` | `"orchestrator"`, `"executor"` | Where the server runs for a session whose workspace is on an executor. `"orchestrator"` spawns it here with the key this machine holds, and a program on the executor reaches it through the owner port. `"executor"` names a server the executor runs from its own `[mcp.<name>]` table, with that table's `command` and `api_key_env`; this table's `command` is then used only by local sessions. A local session ignores the key and starts every server here. |

A session whose workspace is on an executor reports, at attach, how each
server it expects the executor to run fared: the orchestrator logs `mcp.ready`
or `mcp.unavailable` with `placement: executor`, and an executor with no table
for the name refuses it with a reason that says so. An executor's own
`[mcp.<name>]` table is read the same way, and `runs_on` means nothing there,
since a server in the executor's file can only run on the executor. See
[distributed](architecture/distributed.md#background-code-mode-and-mcp-on-a-remote-session).

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

Optional. The listener address, connection limits and the web view belong to
the daemon, not to a session. The daemon reads the table once at startup from the last `--config`
file, and a running daemon never rereads it. The two limits reserve potential
payload capacity. They do not allocate memory in advance and do not bound total
RSS. See [daemon](architecture/daemon.md).

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `bind` | string | `"127.0.0.1:0"` | `127.0.0.1:<port>` or `[::1]:<port>`, port 0 to 65535 | The loopback address the daemon listens on. Port 0 asks for an ephemeral port, which the daemon publishes in its endpoint record for `loom` to find. An explicit `loomd --bind` outranks it; `loom` passes no `--bind` when it starts the daemon, so the file decides. A fixed port pairs with a stable browser name such as `http://loom.localhost:7440`, which the web view admits as loopback (protocol-change 052); `GET /` there forwards to a remembered sign-in. `loom ui` prints a `127.0.0.1` link, so open one with its host changed to the name once, and `/` forwards from then on, or keep using `127.0.0.1`. Any other host, such as `0.0.0.0` or `localhost`, refuses startup. A changed value takes effect only when the daemon restarts. |
| `max_connections` | integer | `64` | positive | HTTP upgrades reserved and WebSockets admitted, combined. |
| `max_reserved_message_bytes` | integer | `536870912` | positive | The sum, over admitted connections, of each one's reserved inbound message and delivery allowance. The default is 512 MiB, room for twelve ordinary terminal pairs. |
| `ui` | boolean | `false` | `true`, `false` | Turns the web view on for the life of the daemon, as `loomd --ui` does. Either one enables it; the file cannot turn off a view the flag turned on. See [web view](architecture/web-view.md). |
| `ui_origins` | array of strings | `[]` | each a full origin `https://host[:port]`: no user information, path, query or fragment, not a loopback host, which includes any `*.localhost` name (an `https` proxy must use another name); at most 16 | The `https` origins the web view is also served at, through a TLS proxy on the daemon's own host such as Tailscale Serve (protocol-change 052). A request whose `Host` names one is admitted, with `Secure` `__Secure-` cookies and a `wss:` socket. The daemon still binds loopback only, and reads no `X-Forwarded-*` header. Needs the view (`ui = true` or `--ui`): a list without it, or a bad entry, refuses startup and names the entry. `bind = "127.0.0.1:<port>"` (or `--bind`) gives the proxy a fixed target. See [web view](architecture/web-view.md#remote-origins). |
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

Optional. What memory is injected into runs. The notes index is injected by
default. The table is independent of a session's runtime configuration: it
belongs to the memory domain the daemon keeps. See
[memory](architecture/memory.md).

The distillation pass that once consolidated sessions into a digest was
removed. `distill` and `distill_wall_ms` are still accepted with any value,
and `inject = "digest"` is read as `notes`, so that an existing file loads.
They do nothing, and the daemon logs a `memory.config_retired_key` warning for
each; delete the key. A key that never existed is still refused.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `inject` | string | `notes` | `off`, `notes` | `notes` attaches an index of the notes `remember` wrote, one line per note, newest first, about a kilobyte, to each run's opening messages; a repository with no notes gets no message. The daemon rebuilds the index from the store when a session opens, so notes written before the index existed reach the first run. `off` attaches nothing and leaves the index file alone. See `docs/design-notes/memory-recall.md`. |
| `distill` | any | none | any | Removed. Accepted and ignored, with a warning, so a file written while the pass existed still loads. |
| `distill_wall_ms` | any | none | any | Removed with the pass it bounded. Accepted and ignored, with a warning. |

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

## `[distribution]`

(From protocol-change 078.) Optional, read once when the daemon starts, like
`[daemon]`. It lets this daemon join other Loom daemons as a trusted Erlang node
over TLS. Without the table the daemon never starts distribution and nothing
about it changes. This release provides membership only: the daemon starts
distribution, accepts the listed peers and can connect to them. The executor role
and remote tool calls build on it later.

A connected peer has the full privileges of a distributed Erlang node, so list
only machines you administer. The daemon is hidden, `dist_auto_connect` is
`never` (a message to a node that nobody connected to is dropped, not dialed),
and only the listed peers may connect. Every certificate chain is verified
against `ca`. The peer's leaf certificate must also hash to the configured
`sha256` and carry the peer's exact node name as its only DNS name that contains
an `@`, and both sides of a connection check this. The certificate may carry
other DNS names and IP addresses, which TLS needs for the host name check, such as
the host in the node name. The certificate of this daemon must carry its own
`node` name in the same way, or the daemon refuses to start.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `node` | string | required | `name@host`, ASCII letters, digits, `_`, `-` and `.`, with a dot in the host, at most 255 bytes | The full name of this node. |
| `ca` | string | required | absolute path | PEM file of the trusted roots. |
| `certificate` | string | required | absolute path | PEM file of this node's certificate chain. |
| `key` | string | required | absolute path, mode 0600 | PEM file of this node's private key. |
| `cookie` | string | required | absolute path, mode 0600 | The daemon's `$HOME/.erlang.cookie`: at least 16 characters of `A-Z`, `a-z`, `0-9`, `_` and `-`, no trailing newline. The emulator reads its cookie from that file, so the daemon refuses any other path. |
| `listen_port` | integer | any free port | 1 to 65535 | Fixes the port of the distribution listener, for a firewall. Peers still find it through `epmd`. |
| `ledger` | string | none, and then `peers` is required | absolute path, exclusive with `peers` | The membership ledger file (protocol-change 086). When set, the ledger decides who may connect: the daemon opens the file, checks that its genesis names the certificate in `ca`, publishes the pin table of the members this node is linked to, and only then starts distribution, so the table exists before the listener does. It also runs the `loom_ledger` process, which keeps the file current by exchanging heads with the peers it is connected to, and disconnects a member as soon as an entry revokes it or replaces its certificate. The file must exist and hold a valid ledger, and the daemon refuses to start otherwise, and also when its own `node` is not an active member of the ledger. The daemon is the file's only writer: the operator's tool appends to the operator's own copy and hands entries to a daemon, and nothing else should edit the file while the daemon runs. A document with both `ledger` and `[[distribution.peers]]` is refused at load. A ledger has at most 64 active members, so a node trusts at most 63 peers in ledger mode, not the 32 that `peers` allows. `[executors.<name>]`, `[orchestrators.<name>]` and `[spawners.<name>]` are checked for shape when the file is parsed, which does not open the ledger. At start the daemon compares their `node` with the ledger: a node that no ledger entry has ever named is refused, and a node that was a member and has been revoked (or is not linked to this node) is kept as an inert row and logged as a warning, so a `revoke` never stops the daemon from starting or from opening a session. A call through an inert row fails. In ledger mode an orchestrator also gets a row for each linked executor and each linked orchestrator without any table naming them (see [`[executors.<name>]`](#executorsname) and [`[orchestrators.<name>]`](#orchestratorsname)), and the executor names that `[pools.<name>]` and `[spawners.<name>]` list are compared with the ledger at start the same way. A `[directory]` table cannot be combined with a ledger: the session directory's members are then the ledger's active members whose `directory` standing is `voter` or `learner` (see [`[directory]`](#directory)). `loom distribution install` of a ledger bundle writes this key. |
| `peers` | array of tables | required unless `ledger` is set | one to 32 `[[distribution.peers]]` rows | The nodes allowed to connect, and the nodes this daemon may connect to. Fixed for the life of the VM; a ledger replaces them. |

## `[[distribution.peers]]`

One row per trusted node. A node may not list itself, and no two rows may share a
node name or a pin.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `node` | string | required | `name@host`, same form as `distribution.node` | The peer's full node name. |
| `sha256` | string | required | 64 hexadecimal characters | SHA-256 of the DER of the peer's leaf certificate, for example `openssl x509 -in peer.pem -outform DER \| openssl dgst -sha256`. |

Peers find each other through `epmd`, the Erlang name service. The VM is booted
without a node name, so the emulator does not launch one; the daemon checks for an
`epmd` on loopback when it starts distribution and starts the release's own
`epmd -daemon` if none answers. It honours `-start_epmd false` in `ERL_FLAGS`, for
an `epmd` you manage or forward yourself. `epmd` takes its port from
`ERL_EPMD_PORT` and its bind addresses from `ERL_EPMD_ADDRESS`, both read from the
daemon's environment. When no `epmd` can be had the daemon exits naming the port,
and it does not report a credential problem. See
[distributed-setup](distributed-setup.md#check-that-both-are-tls-nodes).

The VM has to be booted for distribution before any Gleam code runs, so starting
the daemon takes two steps. (`loom distribution install` does both for a
provisioned node; see [Provisioning a deployment](#provisioning-a-deployment).)
First write the options file from the same configuration:

```sh
loomd distribution options ~/.loom/loom.toml ~/.loom/distribution.options
```

The file names the credential paths and the public pins and holds no secret. It is
written with mode 0600, and the daemon refuses an options file that other users
can write or that was not generated from the current `[distribution]` table, so
rerun the command after editing the table. Then start the daemon through
`bin/loomd` with the file named in `LOOM_DISTRIBUTION_OPTFILE`:

```sh
LOOM_DISTRIBUTION_OPTFILE=~/.loom/distribution.options bin/loomd --config ~/.loom/loom.toml
```

The launcher appends `-proto_dist inet_tls -ssl_dist_optfile <file>` to any
`ERL_FLAGS` already set, and does nothing when the variable is unset. A daemon that
has the table but was started without the variable exits at startup, names this
step, and opens no catalogue. `ERL_FLAGS` must not also set `-name`, `-sname`,
`-setcookie` or `-ssl_dist_opt`. Code-mode satellites and other child VMs never
inherit these flags or the credential files.

## `[executors.<name>]`

(From protocol-change 078.) Optional, read once when the daemon starts, like
`[distribution]`. Each table names a machine whose registered workspaces a session
can use instead of a directory on this host: `sessions.create` accepts an
`executor` that is one of these names, and its `workspace` is then the name of a
workspace registered on that machine. `<name>` is a lowercase letter, then
lowercase letters, digits, `_` or `-`, at most 32 characters. The tables require a
`[distribution]` table, because an executor is a pinned peer, and a daemon
without `[executors]` refuses every creation that names an executor. A session is
created on one with `loom --executor <name> --workspace <registered name>` or with
the web home's "New session" form, whose "Runs on" choice lists executors only when
this table has an entry; see [Setting up a distributed Loom](distributed-setup.md).

An executor may also declare what its machine provides. A declaration is a claim
written in this file, not something the daemon discovers. A pool that requires a
platform, an enforcement or a toolchain skips the executors that did not declare
it, and when a session attaches, the executor's answer is compared with the
declaration: a session whose executor contradicts it fails to open with a reason
that names the declared and the reported value. An executor that provides more
than it declared is not contradicted.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `node` | string | required | one of the `node` values in `[[distribution.peers]]` | The peer node that serves this executor's workspaces. |
| `platform` | string | none declared | `<os>/<architecture>`, such as `linux/x86_64` or `macos/arm64` | The platform the machine reports in the system prompt. |
| `enforcement` | string | none declared | `enforced` or `degraded` | Whether the machine's sandbox helper confines what it runs. |
| `toolchains` | array of strings | none declared | distinct lowercase names | What the machine provides: `codemode` for the code-mode toolchain, or the key of an `[lsp.<name>]` server it serves. |

### Executors that come from the ledger

(From protocol-change 086, phase 2.) A daemon that runs from a membership ledger
(`[distribution] ledger`) and is an orchestrator needs no table for an executor it
is linked to. It lists every executor member it is linked to as if it had written
`[executors.<name>]` for it, using the ledger's name for the member and its Erlang
node, with no declaration. So `loom --executor <name>` and `sessions.create` accept
an executor the moment it is enrolled, and stop accepting it when it is revoked,
with no restart. The daemon reads the ledger each time it decides, and a session
that is already open keeps the executor it was placed on: a revoked one fails as an
executor that is down does.

The ledger carries what every node must agree on: the name, the node, the role and
the links. It does not carry what is one orchestrator's own claim. A derived row
therefore has no `platform`, `enforcement` or `toolchains`, a pool that requires one
skips it, and a workspace is still named by the session. To give a ledger executor
declarations, write its `[executors.<name>]` table with the same name. A row you
write replaces the derived row of the same name, and it also replaces a derived row
for the same `node` under any other name, so one machine is never listed twice. A
node that is not an orchestrator derives nothing.

A table that you write and the ledger later revokes stays in the file as an inert
row (see `ledger` above); `loom deployment status` shows it as down.

## `[pools.<name>]`

(From protocol-change 078.) Optional, read once when the daemon starts, like
`[executors.<name>]`. A pool is a named list of executors, so that a session can
be created on "any of these" instead of on one machine: `sessions.create` accepts
a `pool` in place of an `executor`, never both, and its `workspace` is the name of
a workspace that every executor of the pool is expected to register. `<name>` has
the same grammar as an executor name. The pool's executors must each be a
configured `[executors.<name>]`. In ledger mode a member may instead be the name
the ledger gave an executor ([above](#executors-that-come-from-the-ledger)): the
file is checked for the name's shape, and the daemon compares it with the ledger at
start. A name that no table and no ledger entry ever gave refuses the start. A name
whose member was revoked, or that this node is not linked to, is logged and skipped,
as an executor that is down is. A ledger executor declares nothing, so a pool that
sets a requirement skips it until you write its `[executors.<name>]` table.

The daemon picks the executor when the session first opens. It tries the pool's
executors in the order listed, after dropping the ones that do not satisfy the
pool's requirements, and it goes to the next executor only when the first could
not have created a scope: the machine could not be reached, or it answered that
it already holds its maximum number of scopes. Any other failure fails the open.
The chosen executor is recorded with the session and is never chosen again: a
session that is stopped and opened again goes back to the same executor, and
when that executor is full or down the open fails with `executor_unavailable:`
and no other machine is tried, because the checkout it holds is the session's
only copy. See [Setting up a distributed Loom](distributed-setup.md).

The three requirement keys have the same values as the declarations of an
executor. A pool that sets one admits only the executors that declared the same
value (for `toolchains`, every name listed), and an executor that declared nothing
is skipped, because the daemon would be guessing.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `executors` | array of strings | required | one or more distinct names of `[executors.<name>]` tables | The executors of the pool, in the order they are tried. |
| `platform` | string | no requirement | `<os>/<architecture>` | Admit only executors that declared this platform. |
| `enforcement` | string | no requirement | `enforced` or `degraded` | Admit only executors that declared this enforcement. |
| `toolchains` | array of strings | no requirement | distinct lowercase names | Admit only executors that declared all of these toolchains. |

## `[workspaces.<name>]`

(From protocol-change 078.) Optional, read once when the daemon starts, like
`[distribution]`. This is the executor's side of a registered workspace: each table
names a checkout this machine serves, and an orchestrator that registers a
workspace under that name is attached to it. The orchestrator sends only the name.
It never learns or sends a path, so a session cannot reach a directory that is not
listed here. `<name>` is 1 to 128 bytes with no `/` and no NUL. The tables require
a `[distribution]` table, and a daemon that has at least one starts the executor
host, which serves every listed workspace to the peers it pins. A daemon with no
`[workspaces]` starts no host.

The machine's own settings apply to every attached session: the `[tools]`,
`[workspace]`, `[lsp.<name>]`, `[jobs]` and `[secrets]` tables of this file, the
toolchain and code-mode seed it finds, and the helper it runs. A session's
scratch, blob and work directories are created under the daemon's state
directory, in `scopes/<session>`, and removed when the session's scope closes.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `root` | string | required | an absolute path with no `..` segment, naming an existing directory | The checkout served under this name. The daemon refuses to start when it is not a directory. |

## `[orchestrators.<name>]`

(From protocol-change 078.) Optional, read once when the daemon starts, like
`[executors.<name>]`. This is the table for a deployment with more than one
orchestrator. Each orchestrator keeps its own catalogue, and a session is created
on, and owned by, the orchestrator the client was connected to. A client that
connects to the other orchestrator and names that session gets no record there, so
the daemon asks the orchestrators listed here, over distribution, which of them
holds it. If one does, `sessions.get` and `sessions.open` answer `not_owner`,
naming that orchestrator and, when this table gives one, the address to connect
to; if none does, the answer is `not_found` as before, and if a listed
orchestrator cannot be reached the answer is `owner_unreachable`. Only the daemon's
owner is redirected. The daemon never connects a client to the other orchestrator
itself: the client needs that machine's own credential.

`<name>` is a lowercase letter, then lowercase letters, digits, `_` or `-`, at most
32 characters, and is the name a `not_owner` refusal carries. The grammar excludes `@`
and `#`, which a remote subagent's handle depends on. The table requires a
`[distribution]` table, because an orchestrator is a pinned peer, and two names may
not share a node. List each orchestrator on the other. A daemon with a
`[distribution]` table answers these questions for its peers whether or not it
lists any orchestrator itself; the table only says whom this daemon asks. A daemon
without `[orchestrators]` asks nobody.

Every row is also a value of `on` in `agent_spawn`, which starts a subagent on that
orchestrator instead of in the session. It is offered only in a session its owner
holds alone, and the other orchestrator's `[spawners.<name>]` table, below, is the
one authority: this table has no switch for it, and an orchestrator with no spawner
table for this machine refuses the spawn and says so.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `node` | string | required | one of the `node` values in `[[distribution.peers]]` | The peer node that answers for this orchestrator. |
| `address` | string | none | `wss://<host>[:<port>]/v2/control`, or `ws://` for a loopback host, with no credentials, query or fragment | The control address a client passes to `loom --addr` to reach this orchestrator. A daemon binds loopback only, so this is whatever the operator exposes (a tunnel, a proxy). When absent, `not_owner` names the orchestrator and no address. |

### Orchestrators that come from the ledger

(From protocol-change 086, phase 2.) A daemon that runs from a membership ledger and
is an orchestrator lists every orchestrator member it is linked to as if it had
written `[orchestrators.<name>]` for it, using the ledger's name and node and no
`address`. It asks them which holds a session it does not know, accepts a session
moved from them, and offers them to `sessions.move` and `agent_spawn`, and it does
so for a member enrolled after it started and stops for one that is revoked, with no
restart. A row you write replaces a derived row of the same name or the same
`node`; write one to give a ledger orchestrator an `address`.

A node whose ledger entry gives it a directory standing derives only the
orchestrators that have one too, because a directory member refuses an orchestrator
row for a node that is not a member. `[spawners.<name>]` is never derived: letting a
machine start subagents here is a decision the ledger does not make.

## `[directory]`

(From protocol-change 083.) Optional, read once when the daemon starts. It makes
the daemon a member of the session directory's Khepri cluster, which holds the
single authoritative record of which orchestrator owns each session on an
executor. Write the same table on every orchestrator and executor that is a member.
A daemon without the table is not a member and behaves exactly as described under
`[orchestrators.<name>]`. [docs/architecture/directory.md](architecture/directory.md)
describes what the cluster does.

The table requires `[distribution]`. A member starts distribution visible instead of
hidden, so the launcher boots its VM with `-kernel connect_all false`, which
`bin/loomd` and the release's `loomd` always pass with the TLS flags; a member VM
booted without it is refused. Every member must pin every other member in
`[[distribution.peers]]`, executors included. On a member daemon, every
`[orchestrators.<name>]` node must also be a member. The store keeps its data under
`<state root>/directory`. A new cluster is created once with
`loomd directory bootstrap` on one member; every other member joins on its own.

**With a membership ledger (`[distribution] ledger`) there is no `[directory]` table,
and a document that has both is refused.** The members are the ledger's active
members whose `directory` standing is `voter` or `learner`, and a daemon is a member
when its own entry says so. `loom distribution provision` gives the plan's
`directory` nodes the standing `voter`, and `enroll --directory voter|learner|none`
sets it for a later member (`none`, the default, suits a laptop; a `learner` reads
the directory locally and never counts toward the majority). The daemon reads the
seats when it starts to decide whether it is a member and whether each
`[orchestrators.<name>]` node is one, and again every two seconds while it runs: it
connects to the nodes the ledger seats, joins the cluster in its own seat, and, on
the Ra leader, removes the members the ledger unseats. `loomd directory bootstrap`
works from the ledger and requires it to seat this node as a voter. A count of voters
outside three to seven, or an even one, is logged as `daemon.directory_voters` and
not refused; `enroll` and `revoke` keep the count between three and seven.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `members` | array of strings | required | three to seven distinct node names: this daemon's own `[distribution] node` and `[[distribution.peers]]` nodes | The cluster's voting members, orchestrators and executors. An odd count is recommended: an even count is accepted with a warning, because it adds a member without letting the cluster survive one more failure. |

## `[spawners.<name>]`

(From protocol-change 084.) Optional, read once when the daemon starts, like
`[orchestrators.<name>]`. This is the table for a deployment in which a model on one
orchestrator, a laptop say, starts subagents on another, the box. It is written on
the box, and each table names one spawning orchestrator and the terms on which the
box will run its children. The box's table is the only authority: the spawning
daemon's `[orchestrators.<name>]` rows carry no spawn switch, and a box with no table
for the laptop refuses the spawn and says why. A daemon with no `[spawners]` table
accepts no spawns.

Every child of one spawning session runs in a delegate session that this daemon
creates on the spawner's first spawn, placed as the table says. The limits bound an
honest spawner and a model that spawns too much. They are not a security boundary: a
spawner is a pinned distribution peer, which is fully trusted. The table is separate
from `[orchestrators.<name>]` so that a spawner needs only to be a pinned peer;
under a Khepri directory, every orchestrator a member daemon lists must itself be a
member.

`<name>` is a lowercase letter, then lowercase letters, digits, `_` or `-`, at most
32 characters. The table requires a `[distribution]` table, and two names may not
share a node. Exactly one placement is required: `executor` with `workspace`, `pool`
with `workspace`, or `directory` alone. The daemon refuses a table whose
`default_within_s` is above `max_within_s`, and one whose `retain_s` is below
`max_within_s`, so that a delegate session past retention holds no child that could
still be running.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `node` | string | required | one of the `node` values in `[[distribution.peers]]`, used by no other spawner | The spawning orchestrator's node. A message is judged by the table whose node it came from. |
| `executor` | string | one placement is required | the name of an `[executors.<name>]` table, or in ledger mode the name the ledger gave an executor | Place every delegate session on this executor. Needs `workspace`. |
| `pool` | string | one placement is required | the name of a `[pools.<name>]` table | Place every delegate session on a member of this pool. Needs `workspace`. |
| `directory` | string | one placement is required | an absolute path with no `..` segment | Place every delegate session in this directory on this machine. Does not take `workspace`. |
| `workspace` | string | required with `executor` or `pool` | 1 to 128 bytes with no `/` and no NUL | The workspace name registered on the executor or the pool's executors. |
| `profile` | string | required | the name of a `[profiles.<name>]` table | The profile that seeds every delegate session, so this daemon's catalogue, roles and pricing apply. |
| `tools` | array of strings | every built-in tool except `remember`, the `peer_*` tools and the `schedule_*` tools, and except `agent_spawn` when `max_depth` is 1 | a nonempty array of distinct tool names | The ceiling on a child's tools. A child's tools are narrowed by its request and by its parent's own set, and never widened past this list. The default ceiling includes `agent_spawn` exactly when `max_depth` is above 1. A list you write is used as written, so with one a child can spawn only if `max_depth` allows it and the list names `agent_spawn`. |
| `max_depth` | integer | 1 | at least 1 | The deepest child allowed, counting the spawning orchestrator's own strand as depth 0, so a child here is at depth 1. One means children may not spawn. With 2 or more, a child below the limit keeps `agent_spawn` and may start children of its own, in its delegate session and on the orchestrators `spawn_on` lists. Every spawn in the delegate session is judged by this figure, and a child at the limit loses the spawn tool. |
| `spawn_on` | array of strings | none | distinct `[orchestrators.<name>]` keys of this daemon; needs `max_depth` above 1 | The other orchestrators on which a child of this spawner may start a child of its own (from protocol-change 084, phase 4). This daemon is then the spawner there, so the other orchestrator needs a `[spawners.<name>]` table for this daemon's node, and its own limits apply. A grandchild's deadline is cut to what its parent's deadline leaves, and when the spawning orchestrator releases the parent session, this daemon releases the grandchildren in turn. An orchestrator not in the list is not offered and is refused. Without the key, children spawn nowhere else. |
| `max_sessions` | integer | 4 | 1 to 16 | The delegate sessions this spawner may hold. Sixteen is the number of scopes an executor admits. |
| `max_within_s` | integer | 14400 (4 hours) | at least 1 | The longest deadline a spawn may ask for, in seconds. A longer request is refused, not shortened. |
| `default_within_s` | integer | 1800 (30 minutes) | 1 to `max_within_s` | The deadline a spawn gets when it names none, in seconds. |
| `retain_s` | integer | 604800 (7 days) | at least `max_within_s` | How long a delegate session with no message from its spawner is kept before the sweep deletes it, in seconds. A spawner whose table is removed has its sessions deleted at the next sweep whatever their age. |
| `idle_close_s` | integer | 3600 (1 hour) | at least 1 | How long a resident delegate session with no running child and no message from its spawner stays open before the hourly sweep closes it, in seconds. Closing frees the executor scope the session holds and deletes nothing: the next spawn or join reopens it, and pays the open again. |
| `token_budget_per_day` | integer | none (unmetered) | at least 1 | The tokens, input plus output, that every child of this spawner may use over a rolling day of 24 hours. A spawn is refused with `token_budget_per_day` named once the day's total has reached it. Children already running are not stopped by it. |
| `child_token_budget` | integer | none (unmetered) | at least 1 | The tokens one child may use. A child is stopped, with its outcome recorded as spent, after the request that takes it to the budget, so it can overshoot by one request. |
| `max_per_day` | integer | none (unmetered) | at least 1 | The spawns admitted for this spawner over a rolling day. A new spawn is refused with `max_per_day` named once the day's count has reached it. A resent spawn that finds its child already started is answered with that child and is not counted. |
| `approval_ceiling` | table | none (no ceiling) | a [`[spawners.<name>.approval_ceiling]`](#spawnersnameapproval_ceiling) table | What the spawning orchestrator's operator may approve for a child that asks for more than its sandbox allows (protocol-change 089). With no table, a delegate session counts as unattended and a refused call settles in band, as it always has, and no decision from the spawner is accepted. With a table, a refused call is held open while the spawner's node is connected, the spawner's operator is asked, and a decision is accepted only if every grant it carries is inside the table. |
| `transcript` | string | `"hidden"` | `"visible"` or `"hidden"` | Whether the spawning orchestrator may read its children's transcripts here, one bounded page at a time (protocol-change/090). With `"hidden"` a request for one is refused and the spawner sees a child's result, notes and glances and nothing of its working. The transcript is recorded on this machine and may hold what its tools returned, so it is this daemon's owner who allows it. |

## `[spawners.<name>.approval_ceiling]`

(From protocol-change 089.) Optional, written on the box inside a
`[spawners.<name>]` table, and read with it when the daemon starts. A child that
runs here can ask for more than its sandbox allows: write access to a directory, a
host on the network, an environment variable. Nobody is attached to a delegate
session, so without this table the child's call settles on the refusal. With it,
the refused call is held open for as long as the spawner's node is connected, the
operator on the spawning orchestrator is shown the request, and the box accepts
their decision only if every grant in it is inside the ceiling. A decision that
names anything wider is refused (`outside the spawner's approval ceiling`) and the
request stays pending for the owner of this machine, who can still attach to the
delegate session and answer it.

There is one key for each kind of grant. A key that is absent admits nothing of its
kind, and a table with no keys asks the operator and admits nothing. The ceiling
binds an honest spawner, like the rest of the spawn policy: it stops a mistaken
approval, and a compromised peer does not have to send the message it judges.

An operator on the spawning side may approve a grant for one call (once) or for the
rest of the delegate session (session). A session approval is remembered in the
delegate session and is honoured by every later call of that parent's children on
this machine, and by no other session. It is checked against the ceiling again each
time the delegate session opens, so narrowing the ceiling and restarting the daemon
revokes what the old ceiling let through.

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `writable_roots` | array of strings | none | absolute paths with no `..` or `.` segment | A writable root may be granted if it is one of these paths or under one, compared on a path segment (`/srv/work` admits `/srv/work/a` and not `/srv/workshop`). |
| `readable_roots` | array of strings | none | absolute paths with no `..` or `.` segment | A readable root may be granted under one of these paths. A path that is writable under `writable_roots` may be read as well. |
| `network` | string or array of strings | none | `"any"`, or `host:port` entries | `"any"` admits unrestricted network. A list admits a proxy grant whose every allowlist entry is in it. |
| `env` | array of strings | none | environment variable names | These variables may be added to the allowlist. |
| `limits` | table | none | any of `cpu_s`, `wall_s`, `mem_bytes`, `pids`, `fsize_bytes`, `output_bytes`, each a positive integer | A limit may be raised up to the value listed. A request for unlimited (`0`) is never admitted. |
| `scratch` | array of strings | none | `"tmpfs"`, or absolute paths | The scratch choices that may be granted: a fresh tmpfs, or a host path at or under one of the listed paths. |

## Provisioning a deployment

The tables above are what a node reads. Writing them for every machine by hand,
with a matching certificate, pin and cookie, is what `loom distribution` does
for you. It is a subcommand of `loom` that is forwarded to `loomd` the way
`loom ext` is, it is also `loomd distribution`, and `dist` is short for
`distribution` in both (`loom dist install node.loombundle`). It needs no
openssl and no script: the certificates are minted by the Erlang runtime the
daemon already runs on.

The flow has three steps. Provision once, on any machine. Copy each bundle to its
machine. Install it there.

```sh
loom distribution init plan.toml            # write an example plan
loom distribution provision plan.toml out --passphrase-file pass.txt   # mint everything, sign a ledger, write out/
scp out/devbox.loombundle devbox:           # a secure channel; see below
ssh devbox loom distribution install devbox.loombundle
```

`provision` writes `out/<node>.loombundle` (mode 0600) for each node and
`out/system.json`. A bundle holds the node's private key and the deployment's
cookie, so copy it only over a channel you trust, and delete it after installing.
`system.json` holds no private material: each node's role, Erlang node name,
host, port, certificate pin, peers, executors and workspaces. `loom distribution
show out` prints it as a table. `provision` refuses a directory that already
holds files unless you pass `--force`. By default it signs a membership ledger
(`out/ledger.log`, and in every bundle) and seals the certificate authority's key
under a passphrase in `~/.loom/authority/<deployment id>`, asking for the passphrase
on the terminal or reading `--passphrase-file PATH`; `loom distribution provision`
cannot ask, so it needs `--passphrase-file`, `--drop-authority` (keep no key, and
the ledger can never change) or `--static`. With the key kept, `loom distribution
enroll`, `renew` and `revoke` add, replace and remove nodes without provisioning
again, and `log` and `import` read the ledger and carry it to a node. `provision
--static` writes bundles that list their peers and discards the key, so every change
means provisioning again and reinstalling every bundle with `--force`. A plan
with a session directory is provisioned either way; with a ledger its directory
members are voters in it, and `enroll --directory voter|learner|none` seats a later
member. Certificates are valid for five years and the
authority for ten.

`revoke NAME [--reason TEXT] [--force] [--wait SECONDS]` checks three things before it
signs. It checks the link graph: it refuses a revoke that would leave an executor
with no orchestrator linked to it, or cut members off from the rest. It also asks the
deployment what the revoke would strand. The daemon the command talks to asks each
orchestrator it is linked to, and itself, how many sessions its catalogue owns and
how many are placed on each executor. Revoking an orchestrator is refused while it
owns sessions, and revoking an executor while an orchestrator linked to it has
sessions placed on it. An orchestrator that does not answer is unknown, not empty,
so a laptop that is off cannot be revoked without `--force`, and neither can any
member when no daemon is reachable. It also refuses a revoke of a session directory
voter that would leave fewer than three. `--force` skips all three checks. The refusal
lists whichever of the link-graph concerns, the sessions and the voter count apply, and
signs nothing. Revoking
deletes no session, and enrolling the same name again restores access. Archived
sessions are not counted.

`install BUNDLE [--home DIR] [--config PATH] [--force]` runs on the node's machine
and does everything the daemon needs before it starts:

- It validates the bundle: well formed, a role that carries only its own tables,
  a certificate that chains to the CA and is not expired, a key that belongs to the
  certificate, the node name as the certificate's only DNS name with an `@`, and a
  cookie the daemon accepts.
- It writes `ca.pem`, `cert.pem`, `key.pem` (mode 0600) and `dist.options` into a
  private directory: the plan's `bundle_dir`, or `<home>/.loom/distribution`.
- It writes the cookie to `<home>/.erlang.cookie`, where `home` is `--home` or
  `$HOME`. A different cookie already there is refused, because Erlang reads that
  one file for every distributed node you start; `--force` replaces it.
- It merges `[distribution]`, its `[[distribution.peers]]` rows (or, from a ledger bundle, a `ledger` key and the ledger file beside the credentials) and the role tables
  (`[executors.<name>]` on an orchestrator, `[workspaces.<name>]` on an executor)
  into `--config`, which defaults to `<home>/.loom/loom.toml`. Every other table
  and comment stays as it was. A table that already exists with different values is
  refused; `--force` replaces exactly the tables the bundle owns.
- It prints the command that starts the daemon, with `LOOM_DISTRIBUTION_OPTFILE`
  set.

Nothing is written unless every destination is acceptable, and installing the same
bundle twice changes nothing the second time. No command prints a key, a cookie or
a certificate.

### The plan

A plan is a TOML or JSON file, chosen by its extension, and both spellings mean the
same thing. The JSON form has the same keys, with a top-level `node` array.

```toml
[[node]]
name = "laptop"                              # bundle name
role = "orchestrator"
erlang_node = "loom@laptop.example"
host = "laptop.example"
listen_port = 4370
bundle_dir = "/Users/me/.loom/distribution"
executors = ["devbox"]

[[node]]
name = "devbox"
role = "executor"
erlang_node = "loom@devbox.example"
host = "devbox.example"
listen_port = 4370
bundle_dir = "/home/me/.loom/distribution"
[node.workspaces]
repo = "/home/me/src/loom"
```

| Key | Type | Required, default | Allowed values | Meaning |
| --- | --- | --- | --- | --- |
| `name` | string | required | lowercase letter, then lowercase letters, digits, `_` or `-`, at most 32; unique | The bundle's name, and for an executor its `[executors.<name>]` key on every orchestrator that uses it. |
| `role` | string | required | `orchestrator`, `executor` | What the daemon does. |
| `erlang_node` | string | required | the `distribution.node` form; unique | The Erlang node name, which becomes the certificate's exact node name. |
| `host` | string | host of `erlang_node` | DNS name or address | Also a name in the certificate, for the TLS host name check. |
| `listen_port` | integer | any free port | 1 to 65535 | The fixed distribution port. Two nodes on one host need different ports. |
| `bundle_dir` | string | `<home>/.loom/distribution` | absolute path | Where that machine's credential files go. |
| `executors` | list of strings | none | names of executor nodes | Orchestrators only. The executors this node uses. |
| `workspaces` | table of name = root | none | name of 1 to 128 bytes with no `/`, absolute root | Executors only. The workspaces it registers. |

Every orchestrator peers with the executors it uses and with every other
orchestrator, and each executor peers with the orchestrators that use it, always in
both directions. An executor that no orchestrator uses, and an orchestrator with no
peer, are errors. Unknown keys are refused.

A plan may also name, in a top-level `directory` list of node `name`s, the members
of a session directory (`[directory]` above): three to seven distinct nodes,
including every orchestrator, because a member refuses an
`[orchestrators.<name>]` peer that is not a member. Provisioning with `--static`
then peers every member with every other member, executors included, and writes
the `[directory]` table into each member's bundle. Provisioning with a ledger (the
default) makes the listed nodes voters in the ledger, links them to one another
through it, and writes no `[directory]` table. `directory` comes before the first
`[[node]]`:

```toml
directory = ["laptop", "desk", "devbox"]
```

## Releasing an executor's stuck scope

An executor keeps one scope for each session whose checkout it holds. When a
session closes and the executor cannot prove that every process of the scope has
exited, the scope records unknown cleanup and the executor refuses every later
open of that session. The executor never decides on its own that those processes
are gone. After an executor daemon restarts this happens to every session that
closes, because the new daemon has no workspace for the scope to retire. A daemon
that ends in the middle of a close leaves the scope closing, which is refused in
the same way. Each such scope holds one of the executor's sixteen slots for scopes
that are not cleanly closed.

`loom executor release SESSION [--state-dir PATH]` is the operator's override. It
is also `loomd executor release`. Run it on the executor, with the executor daemon
stopped: it opens the daemon's ledger at `<state-dir>/exec-ledger.db` (the state
directory defaults to `~/.loom`), and it refuses to start while a daemon holds that
state directory. It closes a closing scope, or one with unknown cleanup, as having
every child retired, and records the release in the ledger with the state the scope
was in and the time. It refuses a scope that is open, because its session may be
running, and a scope that is already closed cleanly. `SESSION` is the orchestrator
session id that the refused open names. The session's next open reopens the scope.
Check first that nothing from the session still runs on the machine, because the
command trusts you on that point and nothing else does.

The command holds the state directory's daemon reservation while it runs and leaves
that record behind when it exits. A daemon started during the release is refused
and has to be started again, and `loom` may report that the daemon is still
starting until the next daemon starts.

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
- **Executor scope limit.** `LOOM_EXECUTOR_MAX_SCOPES`, an environment variable
  read by a daemon that serves `[workspaces.<name>]`: the most scopes the executor
  admits that are not cleanly closed, 16 when unset. An executor at its limit
  refuses a further session's attach, which is what a pool moves past.
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
