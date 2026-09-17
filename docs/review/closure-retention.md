# Closure-retention review

Base: `7662215415a74de5b4ca7a0547b637a21d20e41d`.
Reviewed September 16, 2026. Line numbers below name that base, not later edits.

The audit covers all 90 R12 warnings: 11 confirmed retention boundaries,
35 candidates requiring measurements, nine small sites, and 35 dismissals.
The runtime and extension-wrapper repairs resolve all 11 confirmed warnings.
The relay's small `started.pid` capture is also narrowed. Two uncounted shapes
are fixed: the booter's direct callback argument and nested provider facades.
R12 remains warning-only and reports 78 sites after the patch.

The source and measurement reasoning is in
[the memory note](../design-notes/daemon-memory.md#2026-09-16-supervisor-restart-inputs-and-provider-facades).
Candidates remain candidates: their process lifetimes justify a size probe,
not an automatic patch. Dismissals cover request-scoped plans, local predicates,
simulation-only callbacks, and records with no unrelated fields.

## Independent closing review

The independent reader found no production correctness defect. It verified
supervisor start/restart order, parked provider preparation, legacy adaptation,
preview ownership, cancellation, consumer death, and drain handling. Two small
findings were verified and fixed: the preview layer now has its own growth
assertion, and three comments have the preceding blank line required by R10.
The reader inspected source and tests; local execution belongs to the gate
results in the handoff. The final full `make check` exited zero. Documentation
checks have zero errors; the final lint census has zero errors, 804 warnings,
and 78 R12 findings. Opt-in and platform skip messages remain visible in the
gate; no installed-daemon post-patch memory reduction is claimed.

The full gate exposed a timing assumption in an existing follow-up fixture.
A quiet admission can run on a checkpoint poll before the follow-up is queued.
The fixture now holds the first provider response on a provider-owned subject
until the test has admitted the follow-up. The original projection assertions
remain unchanged.

## Base warning inventory

`confirmed` means repaired here; `high` means measure next; `small` means low
priority; `dismiss` means the audited lifetime or record shape does not justify
a retention fix. Each row represents one emitted warning, including multiple
bindings at the same source line.

| File and base line | Function | Capture | Used fields | Disposition |
|---|---|---|---|---|
| `packages/cap/src/cap/internal/channel.gleam` line 224 | `to_channel` | `handle` | `subject` | dismiss |
| `packages/client/src/client/advisor.gleam` line 1482 | `seam` | `wiring` | `name` | high |
| `packages/client/src/client/codemode.gleam` line 2168 | `workspace_seam_with_access` | `access` | `readable` | high |
| `packages/client/src/client/codemode.gleam` line 2169 | `workspace_seam_with_access` | `access` | `readable` | high |
| `packages/client/src/client/codemode.gleam` line 2170 | `workspace_seam_with_access` | `access` | `writable` | high |
| `packages/client/src/client/codemode.gleam` line 2173 | `workspace_seam_with_access` | `access` | `writable` | high |
| `packages/client/src/client/codemode.gleam` line 2185 | `workspace_seam_with_access` | `config` | `schedules` | high |
| `packages/client/src/client/codemode.gleam` line 2188 | `workspace_seam_with_access` | `config` | `schedules` | high |
| `packages/client/src/client/codemode.gleam` line 2189 | `workspace_seam_with_access` | `config` | `schedules` | high |
| `packages/client/src/client/daemon/manager.gleam` line 2172 | `prepare_shared_domain` | `selected` | `id` | high |
| `packages/client/src/client/demo.gleam` line 1068 | `start_entropy` | `counter` | `data` | dismiss |
| `packages/client/src/client/directories.gleam` line 195 | `admin` | `base` | `protected` | small |
| `packages/client/src/client/extension/dispatch.gleam` line 769 | `reaching` | `egress` | `request`, `Request` | high |
| `packages/client/src/client/extension/dispatch.gleam` line 769 | `reaching` | `config` | `secrets` | high |
| `packages/client/src/client/extension/dispatch.gleam` line 798 | `remembering` | `door` | `remember` | high |
| `packages/client/src/client/extension/dispatch.gleam` line 802 | `remembering` | `door` | `recall` | high |
| `packages/client/src/client/extension/hooks.gleam` line 1547 | `wire` | `built` | `run_start` | confirmed |
| `packages/client/src/client/extension/hooks.gleam` line 1553 | `wire` | `built` | `context` | confirmed |
| `packages/client/src/client/extension/hooks.gleam` line 1556 | `wire` | `built` | `run_end` | confirmed |
| `packages/client/src/client/extension/hooks.gleam` line 1564 | `wire` | `built` | `compaction_note` | confirmed |
| `packages/client/src/client/extension/hooks.gleam` line 1570 | `wire` | `built` | `usage` | confirmed |
| `packages/client/src/client/extension/hooks.gleam` line 1577 | `wire` | `tools` | `clear` | confirmed |
| `packages/client/src/client/extension/hooks.gleam` line 1580 | `wire` | `tools` | `run` | confirmed |
| `packages/client/src/client/extension/seam.gleam` line 218 | `routing` | `extension` | `egress`, `memory` | high |
| `packages/client/src/client/extension/seam.gleam` line 308 | `remember_plan` | `memory` | `remember` | small |
| `packages/client/src/client/extension/seam.gleam` line 323 | `recall_plan` | `memory` | `recall` | small |
| `packages/client/src/client/history.gleam` line 322 | `with_source` | `config` | `pull`, `session` | high |
| `packages/client/src/client/internal/instance_host.gleam` line 95 | `prepare` | `started` | `data` | small |
| `packages/client/src/client/jobseam.gleam` line 189 | `door` | `wiring` | `name`, `clearance_ms` | high |
| `packages/client/src/client/jobseam.gleam` line 202 | `door` | `wiring` | `name` | high |
| `packages/client/src/client/jobseam.gleam` line 205 | `door` | `wiring` | `name` | high |
| `packages/client/src/client/jobseam.gleam` line 209 | `door` | `wiring` | `name` | high |
| `packages/client/src/client/jobtools.gleam` line 66 | `seam` | `door` | `start` | high |
| `packages/client/src/client/jobtools.gleam` line 76 | `seam` | `door` | `poll` | high |
| `packages/client/src/client/jobtools.gleam` line 80 | `seam` | `door` | `list` | high |
| `packages/client/src/client/jobtools.gleam` line 84 | `seam` | `door` | `kill` | high |
| `packages/client/src/client/jobtools.gleam` line 85 | `seam` | `door` | `send` | high |
| `packages/client/src/client/jobtools.gleam` line 129 | `capability_door_with_policy` | `door` | `start` | high |
| `packages/client/src/client/jobtools.gleam` line 133 | `capability_door_with_policy` | `door` | `poll` | high |
| `packages/client/src/client/jobtools.gleam` line 137 | `capability_door_with_policy` | `door` | `list` | high |
| `packages/client/src/client/jobtools.gleam` line 141 | `capability_door_with_policy` | `door` | `kill` | high |
| `packages/client/src/client/jobtools.gleam` line 142 | `capability_door_with_policy` | `door` | `send` | high |
| `packages/client/src/client/mcp.gleam` line 369 | `prepare_one` | `configured` | `name` | small |
| `packages/client/src/client/mcp.gleam` line 555 | `start_one` | `configured` | `name` | small |
| `packages/client/src/client/mcp.gleam` line 732 | `call_plan` | `server` | `client` | small |
| `packages/client/src/client/provider_relay.gleam` line 457 | `published` | `started` | `pid` | small |
| `packages/client/src/client/scheduleseam.gleam` line 244 | `seam` | `door` | `create` | high |
| `packages/client/src/client/scheduleseam.gleam` line 245 | `seam` | `door` | `list` | high |
| `packages/client/src/client/scheduleseam.gleam` line 246 | `seam` | `door` | `cancel` | high |
| `packages/client/src/client/serve.gleam` line 2657 | `assemble_in` | `settings` | `gateway` | high |
| `packages/client/src/client/server.gleam` line 141 | `serve` | `config` | `gateway` | small |
| `packages/client/src/client/wiring.gleam` line 1406 | `raising_seam` | `config` | `escalations` | high |
| `packages/client/src/client/wiring.gleam` line 1464 | `escalating_runner` | `config` | `escalations` | high |
| `packages/codemode/src/codemode/orchestration.gleam` line 381 | `spawn_plan` | `seam` | `agency` | dismiss |
| `packages/codemode/src/codemode/orchestration.gleam` line 552 | `wait_plan` | `seam` | `agency` | dismiss |
| `packages/codemode/src/codemode/orchestration.gleam` line 661 | `send_plan` | `seam` | `agency` | dismiss |
| `packages/codemode/src/codemode/orchestration.gleam` line 697 | `note_plan` | `seam` | `agency` | dismiss |
| `packages/codemode/src/codemode/orchestration.gleam` line 713 | `notes_plan` | `seam` | `agency` | dismiss |
| `packages/codemode/src/codemode/orchestration.gleam` line 729 | `roster_plan` | `seam` | `agency` | dismiss |
| `packages/codemode/src/codemode/search.gleam` line 172 | `glob_plan` | `seam` | `glob` | dismiss |
| `packages/codemode/src/codemode/search.gleam` line 196 | `grep_plan` | `seam` | `grep` | dismiss |
| `packages/codemode/src/codemode/search.gleam` line 214 | `stat_plan` | `seam` | `stat` | dismiss |
| `packages/codemode/src/codemode/search.gleam` line 236 | `read_lines_plan` | `seam` | `read_lines` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 743 | `read_plan` | `seam` | `fs_read` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 758 | `list_plan` | `seam` | `fs_list` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 777 | `write_plan` | `seam` | `fs_write` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 793 | `edit_plan` | `seam` | `fs_edit` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 847 | `kv_get_plan` | `seam` | `kv_get` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 872 | `kv_set_plan` | `seam` | `kv_set` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 887 | `kv_delete_plan` | `seam` | `kv_delete` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 1118 | `schedule_create_plan` | `seam` | `schedule_create` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 1241 | `schedule_list_plan` | `seam` | `schedule_list` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 1271 | `schedule_cancel_plan` | `seam` | `schedule_cancel` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 1333 | `job_start_plan` | `seam` | `jobs` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 1365 | `job_poll_plan` | `seam` | `jobs` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 1490 | `job_list_plan` | `seam` | `jobs` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 1531 | `job_kill_plan` | `seam` | `jobs` | dismiss |
| `packages/codemode/src/codemode/workspace.gleam` line 1548 | `job_send_plan` | `seam` | `jobs` | dismiss |
| `packages/conformance/src/conformance/simulation/daemon/domain_runner.gleam` line 173 | `cleanup` | `barrier` | `control`, `arrived` | dismiss |
| `packages/conformance/src/conformance/simulation/daemon/domain_runner.gleam` line 196 | `built` | `barrier` | `control` | dismiss |
| `packages/conformance/src/conformance/simulation/daemon/harness.gleam` line 547 | `render` | `harness` | `ready` | dismiss |
| `packages/conformance/src/conformance/simulation/surface.gleam` line 140 | `build` | `script` | `registry` | dismiss |
| `packages/conformance/src/conformance/simulation/vclock.gleam` line 172 | `timers` | `vc` | `subject` | dismiss |
| `packages/provider/src/provider/http.gleam` line 188 | `start_httpc` | `request` | `method`, `url`, `headers`, `body` | dismiss |
| `packages/runtime/src/runtime/api.gleam` line 339 | `open_published` | `options` | `strand`, `settings` | confirmed |
| `packages/runtime/src/runtime/api.gleam` line 356 | `open_published` | `options` | `strand`, `stream_options`, `retry_policy`, `poll_interval_ms`, `logger` | confirmed |
| `packages/runtime/src/runtime/supervisor.gleam` line 185 | `start_published` | `config` | `subagent` | confirmed |
| `packages/runtime/src/runtime/supervisor.gleam` line 197 | `start_published` | `config` | `strand_options` | confirmed |
| `packages/tui/src/tui.gleam` line 6859 | `receive_tail` | `incoming` | `strand`, `operation`, `step`, `source_index`, `call_id`, `stream` | dismiss |
| `packages/tui/src/tui/virtual_backend.gleam` line 214 | `run_script` | `loop` | `view` | dismiss |
