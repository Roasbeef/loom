# Loom as a Harbor agent

An adapter that lets [Harbor](https://github.com/laude-institute/harbor), the
Terminal-Bench harness, run Loom as the agent under test. Harbor builds a task
container, hands the adapter the task's instruction, and afterwards verifies the
container; the adapter's job is the middle: put a Loom release in the container,
run it, and report what happened as Harbor expects.

This directory is a Python package, `loom_harbor`, because Harbor is Python and
loads agents by import path. It is the only non-Gleam integration in the
repository, so it has its own top-level directory rather than a place under
`packages/`, which holds Gleam packages that `make check` gates. Its gate is
separate: `make harbor-test`.

**Status.** The adapter has been verified without Docker, without a model and
without a Loom release. It has not been run through a real Harbor trial. The
last section lists exactly what that leaves unverified.

## Run Terminal-Bench with Loom

Prerequisites on the machine that runs Harbor:

- Harbor, installed from the commit this adapter was verified against (see
  below), and Docker for Harbor's default environment.
- This package importable by that Python: `uv tool install` and `pip` both work.
- A model key in the environment: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or
  `GEMINI_API_KEY` for the three providers Loom speaks natively.
- Network from the task container to GitHub Releases (or a mirror, or local
  archives; see "Offline"), and to the model provider.

```bash
# Harbor at the verified commit, with this adapter beside it.
uv tool install git+https://github.com/laude-institute/harbor@6099b8cf2bfbbb3e7ff1eb2163bfc4524dbd9ba5 \
    --with-editable integrations/harbor

export ANTHROPIC_API_KEY=...
harbor run --dataset terminal-bench@2.0 \
    --agent loom_harbor.agent:LoomAgent \
    --model anthropic/claude-opus-4-5 \
    --agent-kwarg timeout_sec=1500 \
    --n-concurrent 4
```

`--agent module.path:ClassName` is Harbor's own mechanism for an agent that is
not built in. `AgentFactory.create_agent_from_config` treats an `--agent` value
containing `:` as an import path and calls `importlib.import_module` and
`getattr` on it (`harbor/agents/factory.py`, `harbor/utils/import_path.py`).
The older `--agent-import-path` flag still works and prints a deprecation
notice. Any environment Harbor supports works (`--env daytona`, and so on), as
long as the container can run a Linux release; see "Isolation" for what the
environment must allow.

Harbor gives an agent its `-m provider/model`, its `--agent-env KEY=VALUE`
variables (which take precedence over the host's) and its `--agent-kwarg
key=value` options. It does **not** tell an agent the task's timeout, so set
`timeout_sec` a minute or two below it. The default is 1800 seconds.

### Options

Every `--agent-kwarg` is validated; an unknown one is refused, and
`harbor agents schema loom_harbor.agent:LoomAgent` prints the schema.

| Option | Default | Meaning |
| --- | --- | --- |
| `jail` | `container` | The isolation posture. See "Isolation". |
| `timeout_sec` | `1800` | Wall limit passed to `loom run --timeout`. |
| `release`, or Harbor's `version` | latest published | Release tag to install: `v0.3.2`, or `commit-<sha>` for a nightly. `0.3.2` is read as `v0.3.2`. |
| `release_base_url` | GitHub Releases | A directory holding `SHA256SUMS` and the platform archives, for a mirror. |
| `server_tarball`, `client_tarball` | none | Host paths of `loomd-<ver>-<platform>.tar.gz` and `loom-<ver>-<platform>.tar.gz`, for an offline run. Both or neither. |
| `reasoning_effort` | none | `none`, `minimal`, `low`, `medium`, `high`, `xhigh` map to Loom's `thinking` of `off`, `low`, `medium`, `high`. |
| `base_url` | provider default | The model endpoint (Harbor's common option). Required for providers Loom has no built-in address for. |
| `api_key_env` | per provider | Name of the host variable holding the key. |
| `dialect` | per provider | `anthropic`, `openai`, `openai-responses` or `gemini`. |
| `openai_api` | `responses` | `chat` makes `openai/...` use the chat-completions dialect. |
| `context_window`, `max_output_tokens` | 200000, 32000 | Loom requires both for every model. See "Model configuration". |
| `price_input`, `price_output`, `price_cache_read`, `price_cache_write` | none | USD per million tokens. Without them Loom reports no cost. |
| `network` | `full` | `off` disables egress for Loom's jailed tool shells. |
| `rw_mounts` | none | Comma-separated absolute paths, outside the working directory, that tools may write. |
| `bwrap` | `auto` | `container` jail only. See "Isolation". |
| `state_dir`, `install_dir` | `~/.loom-harbor`, `/opt/loom-harbor` | Where the daemon keeps its state and where the release is unpacked. |

Environment variables read from `--agent-env` or the host: `LOOM_RELEASE`,
`LOOM_RELEASE_BASE_URL`, `LOOM_SERVER_TARBALL`, `LOOM_CLIENT_TARBALL`. An
option wins over its variable.

### Offline

Build the archives with `make dist` (`docs/distribution.md`), or download them
from a release, then:

```bash
harbor run ... --agent-kwarg server_tarball=dist/loomd-0.3.2-linux-x86_64.tar.gz \
               --agent-kwarg client_tarball=dist/loom-0.3.2-linux-x86_64.tar.gz
```

The archives are uploaded into the container; the install step then needs no
network except for the model. The container's platform must match the archives'.

## What it does in the container

**Install** (once per container, as root, idempotent). Installs `curl`, `tar`,
`bash` and CA certificates if missing, and `git` and `ripgrep` best-effort.
Then it fetches `SHA256SUMS` from the release, selects the one `loomd-` and the
one `loom-` archive for the container's platform (never `loom-slim-`), downloads
them, checks both digests and refuses on any mismatch, unpacks both trees under
`/opt/loom-harbor`, and runs `loom version` to prove the client runs. A second
call with the same digests does nothing. Every failure names what failed and
exits nonzero, so Harbor records a setup error. The digests come from the same
origin as the archives, so they catch corruption and truncation, not a
compromised release; for that, pin `release` to a tag you have verified.

**Model configuration.** Harbor's `provider/model` becomes a one-entry
`loom.toml`:

| Harbor provider | Loom dialect | Key variable |
| --- | --- | --- |
| `anthropic` | `anthropic` | `ANTHROPIC_API_KEY` |
| `openai` | `openai-responses` (`auth = "api-key"`), or `openai` with `openai_api=chat` | `OPENAI_API_KEY` |
| `gemini`, `google` | `gemini` | `GEMINI_API_KEY`, else `GOOGLE_API_KEY` |
| anything else | `openai`, and `base_url` is required | `<PROVIDER>_API_KEY`, or `api_key_env` |

The file names the variable (`api_key_env`) and never contains a key. The key
travels only as an environment variable on the one `exec` that starts the
daemon; Harbor's debug log of that call redacts variables whose names look like credentials. The
rendered file is copied to `agent/loom.toml` in the trial directory. Loom's
decoder is strict, so each variant the adapter can render was checked against
`client/catalog.parse`, the daemon's own parser.

Loom requires `context_window` and `max_output_tokens` for every model, and
Harbor carries neither. The defaults are deliberately low (200000 and 32000):
a window smaller than the truth only makes Loom compact earlier, while a larger
one would let a request overflow. Set both for a faithful run of a model with a
larger window.

**Run.** The instruction is uploaded as a file (never put on a command line or
in a log). The run script starts `loomd --state-dir S --config C [--best-effort]`
from its own state directory, waits for the daemon's endpoint file, and runs
`loom run --workspace "$PWD" --timeout T -p "<instruction>"` against it. `loom
run` prints one JSON line with the session id, the outcome, usage, and the jail
label, and its exit status is the verdict (`0` completed, `1` failed or aborted,
`124` deadline). The script stops the daemon and copies the session database
(and its write-ahead log) and `daemon.log` into `/logs/agent`, which Harbor
collects. If Harbor cuts the run off at the task's timeout, a second, separate
call does the same copy and stops the daemon.

Outcomes are results, not errors: a model that fails the task, runs out of time
or is aborted returns normally and Harbor's verifier decides the reward. Two
things raise: a report the adapter cannot read (including one with no jail
label), and a `failed` run whose reason Harbor's own classifier recognises as a
provider problem (rate limit, bad key, overload), so `--retry-include
ApiRateLimitError` and its siblings work as they do for Harbor's built-in agents.

## Isolation

Loom refuses to run a model's tool calls unless its sandbox helper confines
them, and a Harbor task container is not a place that normally lets it:
`docs/docker.md` measured that under Docker's default seccomp profile `bwrap`
cannot create a user namespace, so the helper's namespace layer fails and its
self-test reports 0 of 11 probes enforced. The adapter therefore makes the
choice explicit, as the `jail` option, and records it.

- **`jail=container`** (default). The task container is the isolation boundary,
  which is also Harbor's own model (a disposable container per trial), and
  `docs/docker.md` calls the plain posture exactly that. The daemon starts with
  `--best-effort`, Loom's explicit "accept any honest degradation" flag.
  Before the run, the adapter probes whether `bwrap` works for the agent user.
  If there is none, Loom runs degraded (in-process layers only). If it works,
  Loom uses it. If one exists but cannot create namespaces, which is what
  `docs/docker.md` measured, it would make every tool call fail, so with
  `bwrap=auto` the adapter renames it aside (`bwrap.disabled-by-loom-harbor`)
  as root, logs a warning, and records `bubblewrap: disabled`. `bwrap=keep`
  never touches it and records `unusable`. Either way `loom run` then measures
  the helper and labels the run `enforced`, `degraded` or `unverified`, and
  that label is in the metadata.
- **`jail=platform`**. Loom's own kernel jail must come up completely. The
  adapter installs `bubblewrap` and, before spending any tokens, runs
  `loom-exec --self-test` as the agent user; unless every probe is enforced it
  refuses the trial with the self-test's output and the remedy. The daemon runs
  with Loom's default `PlatformEnforcement`. Harbor's default Docker environment
  does not satisfy this; it needs the flags `docs/docker.md` calls "full
  isolation" (`--cap-add SYS_ADMIN`, `seccomp=unconfined`, `apparmor=unconfined`,
  `systempaths=unconfined`, and a delegated cgroup v2), which means a custom
  environment definition for the task. That is the trade `docs/docker.md` states:
  it removes Docker's own confinement to replace it with Loom's.

Nothing is disabled silently: the chosen posture, the flag, what happened to
bubblewrap, the preflight result, and Loom's own measured label are all in
`results.json` (`agent_result.metadata.loom.jail`) and in the trajectory's
`agent.extra.jail`.

**A consequence to know about.** Loom's jail confines writes to the workspace
(the task's working directory, usually `/app`) and any `rw_mounts`. A Terminal-
Bench task whose solution must write elsewhere (`/etc`, `/usr/local`, a service
directory) cannot do so unless that path is named in `rw_mounts`. Under
`jail=container` with a missing or removed `bwrap` that confinement rests on
Landlock alone, and only where the kernel and Docker's seccomp profile permit
it; the `loom run` label says what was in force.

## What a trial leaves behind

In the trial's `agent/` directory: `trajectory.json` (ATIF), `loom-run.json` and
`loom-run.stderr.txt`, `loom-run.exit`, `loom.toml`, `loomd.log`, `daemon.log`
and `loom-session/<id>.db` with its `-wal`. In `results.json`,
`agent_result` carries:

- `n_input_tokens` (which includes cache, as Harbor defines it), `n_cache_tokens`
  and `n_output_tokens` from Loom's usage ledger, and `cost_usd`. Each is left
  unset, not zero, when Loom says it was not measured: tokens when the
  provider reported none, cost when no `price_*` was configured.
- `metadata.loom`: outcome, reason, turns, elapsed milliseconds, session id,
  model, usage evidence, release, and the `jail` record above.

**The trajectory.** `eval/atif.gleam` is the exporter Loom already has, but
`packages/eval` never ships, so a release cannot run it in the container. What a
release does leave is the session's SQLite file, whose entry and ledger payloads
are plain JSON, so `loom_harbor.trajectory` is a Python port of the exporter
that runs on the host over the file Harbor syncs back. It follows the Gleam one
rule for rule (contiguous steps; a tool result joins the step that most recently
issued its call id; orphan results dropped; per-step metrics from ledger rows
tied to the assistant entry, totals from every row; credentials scrubbed by the
replay lane's prefix rule) and adds one: the API key's exact value is scrubbed
too. `tests/test_loom_roundtrip.py` compares it step for step against the Gleam
exporter's output on a database Loom's own storage package wrote, including one
whose entries live only in the write-ahead log, and against Harbor's validator.

What the trajectory does **not** contain, and what would close each gap:

| Missing | Why | Loom-side change |
| --- | --- | --- |
| System prompt and tool definitions (`agent.tool_definitions`) | The session store does not hold them; the prompt is built per request. | Record the rendered system prompt and the tool schema as a custom entry when a session opens (`prompt` and `client`'s session assembly), so any exporter can read them. |
| Reasoning (`reasoning_content`) | Thinking blocks are opaque and provider-signed, so Loom's exporter deliberately never reads them. | None wanted. A decision, not a gap. |
| Subagent strands as `subagent_trajectories` | The exporter walks every entry in sequence order and does not separate strands, so a run that spawns subagents interleaves them. `extra.storage_branches` counts the branches. | Give `eval/atif` a strand filter and nested output, keyed by the strand registers the session store keeps. |
| A trajectory when the container has no `sqlite` of its own | Not needed; the conversion is on the host. | None. |
| An in-container export, so the file arrives already ATIF | `packages/eval` is not in the release. | Promote `eval/atif` (and `cassette.redact_text`, which it borrows) from `packages/eval` to a shipped package, and add an `export` verb to `tui` beside `run`, or a `--atif <path>` flag on `loom run`. Then this port can be deleted. |

## Tests

```bash
make harbor-test          # skips with a message when uv is missing; not part of make check
```

`scripts/harbor_test.sh` builds `integrations/harbor/.venv` with Harbor at the
verified commit (or `HARBOR_SRC=/path/to/harbor` for a local checkout) and runs
pytest. No Docker, no network once the environment exists, no model. The tests:

- **Config generation per provider** (`test_catalogue.py`), including quoting.
- **The JSON line** (`test_runreport.py`): success, failure, every outcome,
  malformed, truncated and missing mandatory fields, a missing jail label, and
  four lines printed by `tui/run.render` itself (`fixtures/loom-run-reports.jsonl`).
- **The shell, executed** (`test_scripts.py`): the install script against a
  `file://` release laid out like a real one (platform selection, `loom-slim-`
  ignored, digest mismatch, a corrupted archive, idempotence, a changed
  release, offline archives, a client that will not run), and the run script
  against stub `loomd` and `loom` (posture flag, arguments, exit mapping,
  report passthrough, key never written, session copied, daemon stopped,
  salvage after a cut-off run). The scripts under test are the shipped text.
- **The whole adapter over real processes** (`test_local_trial.py`): `setup`,
  `run` and `populate_context_post_run` driven against an environment that
  runs each `exec` in `bash` on the test machine with the container's paths
  mapped into a temporary directory, a fake `file://` release, and stub `loomd`
  and `loom` that hand back a real Loom-written session database. It shows the
  Python and shell halves agree on variable names, arguments and files.
- **The agent against a mocked environment** (`test_agent.py`), the way
  Harbor tests its own agents: loading through `AgentFactory`, options,
  install, run, error classification, context mapping, platform preflight
  refusal, bubblewrap handling, and the context staying empty in `run` so
  Harbor calls `populate_context_post_run`.
- **The trajectory** (`test_trajectory.py`, `test_loom_roundtrip.py`):
  against Harbor's `TrajectoryValidator` and its CLI, and against Loom's own
  exporter.

Harbor's `main` is not stable API for agents. The `harbor` 0.24.0 wheel on PyPI
predates the options and capabilities used here and fails at import, so the
tests and these instructions use commit `6099b8cf` of `laude-institute/harbor`
(`pyproject` version 0.24.0, 2026-10-23).

## Not verified

Everything below needs infrastructure this work did not have.

- **A real Harbor trial.** No Docker daemon was available. The install and run
  scripts were executed only against stubs and a fake `file://` release, and
  the Harbor calls only against a mock environment or the local stand-in above.
  What did run for real is Harbor's own CLI up to its Docker preflight:
  `harbor run --path <task> --agent loom_harbor.agent:LoomAgent -m anthropic/...
  --ak jail=container --dry-run` imports the class, validates the kwargs and
  stops at "Docker daemon is not running".
- **A real Loom release.** No release was downloaded or installed, so the
  archive layout the install script assumes (a single top-level directory;
  `bin/loomd`, `bin/loom-exec`, `bin/loom`; the aggregate `SHA256SUMS` on the
  release) comes from `scripts/release-archive.py`, `scripts/dist.sh` and
  `docs/distribution.md`, not from an asset. The `loom version` output format
  comes from `tui.print_version`.
- **`loomd` with `--best-effort`, then `loom run`, against a real daemon.** That
  `loom run` reuses a daemon started with the same `--state-dir`, and that
  `--best-effort` reaches the session, is read from `tui/daemon/bootstrap` and
  `client/daemon/main`, not exercised.
- **What Loom does inside a default Docker container.** Whether tool calls
  succeed with `--best-effort` and `bwrap` absent or moved aside depends on
  Landlock and seccomp being permitted by Docker's profile; `docs/docker.md`
  measured the self-test and not tool execution there.
- **A real model call**, so the model-name mapping, dialect choice and default
  limits are checked against Loom's decoder but not against any provider.
- **Terminal-Bench results.** Tasks that write outside the working directory
  may fail under Loom's jail for that reason alone (see "Isolation").
- **Platforms other than `linux-x86_64` hosts running Harbor,** and containers
  on musl libc (Alpine), where the glibc release will not run.

What *was* checked against Loom's own code: the report lines against
`tui/run.render`; every rendered `loom.toml` against `client/catalog.parse`;
the trajectory against `eval/atif.gleam` on a database written by
`storage/sqlite`.
