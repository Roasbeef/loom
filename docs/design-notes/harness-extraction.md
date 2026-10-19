# Extracting the provider-routing core into `harness`

Status: **implemented** in the pull request that closes
[issue #1030](https://github.com/Roasbeef/loom/issues/1030). Written against
`main` at `c444fca25` on 2026-10-19, before any code moved; the "what moved"
section was re-checked against the tree afterwards.

An application which wants to run loom sessions in its own process has to
depend on `client`, the whole daemon, because the provider half of
`runtime/effects.Effects` is built there. lightninglabs/aegis is the first such
application: it starts one session per review job with `runtime/api.open`, with
custom tools, its own system prompt and an in-memory session. This note maps
`client/wiring.gleam` into the part which is the daemon and the part which is
not, and decides the shape of the package the second part moves to.

## 1. What `wiring.gleam` holds

`wiring.gleam` is 2,381 lines and does five jobs.

| Job | Functions | Needs the daemon? |
| --- | --- | --- |
| Model facts: the window, ceiling, adapter api and image reading of one identity | `ModelFacts`, `model_facts*`, `strand_facts_from`, `strand_identity`, `strand_window` | No, except that the image reading is typed by `client/catalog.ImageReading` |
| Routing: which role a captured identity is on, and the target a request takes | `request_target*`, `resolved_target*`, `routed_role`, `candidate_roles`, `vision_route`, `thinking_level`, `strand_thinking_level` | No |
| Admission and dispatch: the pre-request decision, the request body, the begin permit | `admit_projected`, `prepare_dispatch`, `dispatch`, `provider_request*`, `generation_request`, `tool_specs*`, `unsupported`, `resolution*`, the image-bearing readers and `active_run_images` | No, except the vision rule, which lives in `client/vision` |
| The tool surface's declarations | `clear`, `replay_still_safe`, `execution_mode`, `replay_policy`, `terminates`, `completed` | No |
| Daemon assembly | `Config`, `build_effects*`, `compaction_hooks` and the checkpoint readers, `run_tool` and the `Authority` / `WorkspaceView` halves, `run_placed`, `tool_context`, the escalation seams | Yes |

The daemon assembly is what stays. It reads the notes checkpoint
(`client/checkpoint`, `client/notes`), the directory and permission grants
(`client/directories`, `client/permissions`), the escalation plane
(`client/escalate`), the placement of a tool across machines
(`client/tool_placement`) and the holder process which keeps one `Config` for
the whole session (`client/tool_holder`).

## 2. The three `client` imports in the routing core

Moving the other four rows needs exactly three things from `client`, and none
of them is daemon-specific.

1. **`client/catalog.ImageReading`.** A two-variant type, `ReadsImages |
   TextOnly`, which the catalogue parser fills from a model's `vision` key. The
   routing core only reads it. It becomes `harness/model_facts.ImageReading`.
   `client/catalog` keeps its own type, because its constructors are spelled
   `catalog.TextOnly` in the catalogue parser and in some forty test call sites,
   and `Config.facts` stays typed by it; `wiring` converts at the one place it
   hands the facts closure to `harness`. A type alias would not do: a Gleam alias
   does not re-export constructors.
2. **`client/vision`.** The pure rule: which turn carries an image, the
   placeholders, the refusals. It imports nothing from `client`. It moves to
   `harness/vision` unchanged, and `client/vision` becomes a set of one-line
   delegations so `vision_test` and every other caller compile as they did.
3. **`client/notes.strand_of`.** Two lines which read the strand an operation
   belongs to from `op.meta`. It moves to `harness/session_read`, and
   `client/notes.strand_of` calls it.

## 3. The shape of `harness`

The package depends on `core`, `machine`, `session`, `storage`, `provider`,
`runtime`, `tools` and `broker`. `broker` is below `tools` and is needed
because `tool.Ctx` carries `broker/policy` and `broker/exec` types; an
embedder building a context has to name them. Nothing above those is imported.
`gleam deps tree` shows no `client`.

```
harness                    HarnessConfig, new, effects, embedded_context
harness/provider           the provider surface: request, prepare, dispatch
harness/routing            roles, targets, thinking levels, vision route
harness/admission          the pre-request decision and the image readers
harness/model_facts        ImageReading, the facts seam, windows
harness/tool_table         clear, replay, execution mode, the outcome wrap
harness/vision             the vision rule (moved from client)
harness/session_read       strand_of, strand_identity
```

`harness` itself is the front door and holds only the typed configuration and
the assembly. The other modules are public because `client/wiring` is their
second caller: it builds the same records without going through `harness.new`.

### 3.1 A validated front door and an unvalidated floor

`HarnessConfig` is opaque and is built by `harness.new`, which refuses a state
the daemon would reject at run time:

- the `Main` role must resolve to a usable chain in the gateway
  (`RoleUnrouted(Main)`); an embedder with no route would otherwise see
  `model_unavailable` on its first request, and the daemon's admission check
  turns the same condition into that in-band error;
- the fallback context window, the fallback output ceiling and the provider
  timeout must be positive (`InvalidLimit(name)`), which `Config`'s own
  documentation has always required and nothing has checked.

The daemon does not go through `new`. Its tests, and some of its fixtures,
assemble a `Config` over a gateway which routes only part of the roles, and
today that is a runtime condition (`resolution` answers `ModelUnresolved`).
"Behaviour must not change" rules out turning it into a boot failure here, so
`client/wiring` builds `harness/provider.Provider` directly. The two paths share
every function below the record; only the check differs. That is the cost of
the two doors, and it is deliberate.

### 3.2 Defaults

`harness.effects` installs the default `effects.Hooks` with two slots replaced:
`admission` (the real facts-driven decision, including the vision rule) and
`resolution` (does the gateway still route the role). Everything else is the
runtime's default: no compaction (`api.default_options` already disables it, and
`threshold`, `overflow_preparation` and `structural_decision` decline), no
run-start injection, no escalation channel. The tool surface refuses nothing
beyond the registry: a call is cleared when its name is active and registered,
and runs through `tool.dispatch` under a `tool.Ctx` the configuration builds
(`embedded_context`), whose `clear_call` refuses every broker execution and
whose raise seam settles every refusal. An embedder whose tools need a jail
supplies its own `context` function instead.

### 3.3 What a tool may do to the run

`terminate` is the one effect-plane field a tool controls: `tool.TerminateRun`
becomes `effects.ToolCompleted(terminate: True)` in `harness/tool_table.completed`,
the only place the two vocabularies meet. The embedding test uses it for a
`submit` tool, which is what ends an aegis job.

## 4. What `client/wiring` becomes

`wiring.Config` and every public function keep their signatures. The functions
which moved are now bodies of one or two lines which build the harness record
from the `Config` fields and call the harness function. `build_effects` and
`build_effects_held` assemble `Effects` the same way as before, taking the
provider surface and the declaration-driven tool functions from `harness` and
keeping `run`, the compaction hooks and the holder logic. `compaction_hooks`
calls `harness.admission` and `harness.resolution` where it called its own
copies, so admission cannot drift between the two.

The capture-size regressions in `wiring_test` (an unrelated registration's `run`
payload may not change the flat size of the provider callbacks) continue to hold
because the harness records carry the same fields the private records did.

## 5. Not done

- The compaction hooks stay in `client`. They read the notes checkpoint, which
  is a daemon concept; moving them would drag `client/notes`, `client/checkpoint`
  and the history-search tool name into the package.
- `harness` does not start processes. An embedder supplies the entropy source,
  and `harness.random_entropy` is a pure function over the broker's entropy
  primitive. Anything which becomes a process stays on weft in the package which
  owns it.
- `HarnessConfig` has no field for a broker-backed jail. The daemon's workspace
  half is `client`'s; an embedder who wants one builds `tool.Ctx` itself.

## 6. Verification

`wiring_test`, `vision_test`, `serve_test`, `blocksummary_test`,
`conformance/wiring_e2e_test` and the rest of the client and conformance suites
run unchanged against the refactored client. `harness` ships its own tests for
the construction errors, for on-route and off-route targets, and for the
embedding contract: a session opened with `runtime/api.open` over
`session.open_memory`, a custom tool, a terminating `submit` tool and a custom
system prompt, driven by a scripted provider transport.
