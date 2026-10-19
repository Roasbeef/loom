# harness

## Purpose

Loom's session runtime without the daemon. `runtime/api.open` takes a
`Session` and an `Effects` record, and the provider half of that record, the
routing and admission which turn a `RequestSpec` into a gateway call, used to
exist only inside `client/wiring`. This package is that half, extracted
(issue #1030, `docs/design-notes/harness-extraction.md`), plus a typed front
door, `harness.new`, and an assembly, `harness.effects`, for a program which
embeds a session in its own process. lightninglabs/aegis, a continuous
security-review service, is the first such program: one session per job, with
custom tools, its own system prompt and an in-memory session.

`client/wiring` is the second caller. It builds the same records from its
daemon `Config` and keeps the daemon-only parts: the notes checkpoint and the
compaction hooks, directory and permission grants, the escalation plane, tool
placement across machines and the holder process.

## Key Types

- `harness.Settings` and `harness.HarnessConfig` — plain data in, opaque value
  out. `settings(..)` fills the defaults (the `Main` role, no model facts
  beyond the fallback, random entropy, no system prompt, a ten minute provider
  timeout); `new(settings)` refuses what the daemon would turn into an in-band
  `model_unavailable` at run time. `ConfigError` is `RoleUnrouted(role)`,
  `InvalidLimit(name)` or `RelativePath(path)`.
- `harness.Tools` — `Embedded(workspace, blob_root)` runs tools in this VM
  under a context with no broker (`embedded_context`), `Hosted(context)` under
  one the embedder builds per call.
- `harness.open(config, options)` — the documented entry point: `api.open` over
  the configuration's own session, so the session is named once. A plain
  `api.open` must be given the same session.
- `harness.effects(config)` — the `Effects` record: the provider surface, the
  registry-driven tool surface, and the runtime's default hooks with
  `admission` and `resolution` replaced. No compaction, no escalation channel.
- `harness/provider.Provider` — routing, session, system prompt and the
  rendered tool definitions. `new` is the unchecked floor `client/wiring`
  builds on; `surface`, `dispatch`, `prepare` and `request` are the surface.
  `definitions` and `tool_specs` render the tool array in one canonical order
  (sorted by name, duplicates collapsed, unregistered names omitted).
- `harness/routing.Routing` — gateway, role, `Lookup`, `Fallback`.
  `request_target` is `ForRole` when the captured identity heads a role's
  usable chain, `ForResolved` otherwise; `resolved_target` is always the
  latter; `vision_route` is the vision chain's target; `resolution` asks the
  gateway about a role; `thinking_level` and `strand_thinking_level` are the
  two directions of the thinking map.
- `harness/model_facts` — `ImageReading`, `Known`, `Lookup`, `Fallback`,
  `ModelFacts`, and `of_identity`, `of_strand`, `strand_window`.
- `harness/admission` — `admit` (the pre-request decision, including the
  vision rule), `image_bearing`, `active_run_images`.
- `harness/tool_table` — `surface`, `clear`, `replay_still_safe`,
  `execution_mode`, `replay_policy`, `terminates`, `completed`, `finished`,
  `run_registry`.
- `harness/vision` — the image-bearing classification, the placeholders and
  the two refusals, moved unchanged from `client/vision`, which now delegates.
- `harness/session_read` — `strand_of` and `strand_identity`, the two durable
  reads routing needs. `client/notes.strand_of` delegates here.

## Relationships

- **Depends on**: `core`, `machine`, `session`, `storage`, `provider`,
  `runtime`, `tools` and `broker`. `broker` is below `tools` and is named
  because `tool.Ctx` carries `broker/policy` and `broker/exec` types. Nothing
  above those, and in particular never `client`: `gleam deps tree` must not
  show it. A new dependency here is a design change, not a convenience.
- **Depended on by**: `client` (`wiring`, `notes`, `vision`) and any embedder.
- The package holds no `@external` and starts no process. Anything which
  becomes a process stays on weft in the package which owns it.

## Traffic

- **Provider surface**: `Provider.surface` closes over the `Provider` record
  and the effect timeout. A request enters at `dispatch` (`prepare` followed
  by the begin permit); only a `GenerationRequest` reaches the gateway, and a
  `PollRequest` or `SummaryRequest` settles at once as a terminally classified
  in-band failure.
- **Hooks**: `admission` is asked per query and answered from the query's own
  configuration; `resolution` asks the gateway whether the role still routes.
  Everything else is `effects.default_hooks()`.
- **Tools**: `tool_table.run_registry` builds a fresh `tool.Ctx` per call
  (`embedded_context` or the embedder's), dispatches through `tool.dispatch`
  and answers `ToolCompleted`, whose `terminate` is the outcome's own.

## Invariants

- **Two doors, one floor.** `harness.new` validates; `Provider.new` and
  `Routing` do not. `client/wiring` builds the floor directly because the
  daemon's behaviour must not change and some of its fixtures assemble a
  gateway which routes only part of the roles. Do not make the floor validate.
- **Role follows identity, and the decision is a function of durable state.**
  No per-request rerouting, health tracking or sticky chain position. A
  deferred poll is always `ForResolved`. These are the rules `routing` quotes
  from `client/wiring`; a change that breaks one breaks crash recovery.
- **The tool array is sorted and unique.** It is the byte prefix of the
  provider's cached region. The sort does not touch authorization, which is
  set membership in the same list.
- **Declarations are projected.** `clear`, `replay_still_safe` and
  `execution_mode` take `tool.Declarations`, never a registry, so a closure
  built from them does not copy every tool's executor into each process which
  holds the effects.
- **`embedded_context` refuses every broker execution.** `clear_call` answers
  `BrokerUnavailable` and `raise_refusal` settles in band. A tool which needs a
  jail uses `Hosted`.
- **A `Fallback` is positive.** `new` checks the window and ceiling; the
  daemon's `Config` documents the same rule and does not check it.

## Embedding contract

`test/harness/embedding_test.gleam` is the contract in code: a custom
`tool.Tool` whose `run` closes over a per-job grant, a `submit` tool returning
`tool.TerminateRun`, a custom system prompt, `session.open_memory`, a routed
gateway over a scripted Anthropic transport, `harness.open`, `api.prompt` and
`api.await_result`, ending in `RunCompleted(CompletedByTerminatedTools)` with
exactly two model requests. The embedder starts the session under its own
supervisor; `api.open` links the tree to its caller.

## Deep Docs

- [docs/design-notes/harness-extraction.md](../../docs/design-notes/harness-extraction.md)
  — the map of `client/wiring` into what moved and what stayed, and why the
  daemon keeps its own `ImageReading`.
- [docs/architecture/effects.md](../../docs/architecture/effects.md) — the
  `Effects` seam, and the layering section for this package.
- [packages/client/CLAUDE.md](../client/CLAUDE.md) — `client/wiring`, the
  daemon-specific assembly built on this package.
- [packages/runtime/CLAUDE.md](../runtime/CLAUDE.md) — `Effects`, `api.open`.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
