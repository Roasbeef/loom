# protocol-change/113: per-session subagent limits and higher defaults

**Status**: PROPOSED 2026-11-12. **Affects**: the control command
`sessions.create` (one optional `"agency"` object), the catalogue schema
(version 21, side table `catalogue_session_agency`), `client/agency` defaults
(`fan_out: 100`, `session_strands: 256`, `DepthCap` supporting unlimited depth),
`tools/agent.max_handles` (`256`), `codemode/orchestration.default_spawn_ceiling`
(`256`), and the new-session flows of the web home and TUI. No existing frame
from Part 1 is removed or broken for callers that omit `"agency"`.

## Problem

1. The shipped Agency defaults (`fan_out: 8`, `session_strands: 16`,
   `depth_cap: 1`, `max_handles: 32`, `default_spawn_ceiling: 32`) prevent a
   main strand from launching 100 concurrent subagents or testing deeper /
   recursive agent trees without rebuilding `loomd`.
2. Neither `sessions.create` nor the web/TUI session creation screens let an
   operator tune `fan_out`, `session_strands`, or `depth_cap` (including
   unlimited recursive spawning) for a session.

## Decision

### 1. Higher defaults for single-session fan-out

- `client/agency.default_config`: `fan_out: 100`, `session_strands: 256`,
  `depth_cap: BoundedDepth(1)`.
- `tools/agent.max_handles`: `256` (matching `session_strands` so `agent_wait`
  can join a full 100-child batch in one call).
- `codemode/orchestration.default_spawn_ceiling`: `256` (staying above
  `fan_out` so code-mode orchestration does not shadow the live cap).
- `agency.max_ancestor_walk`: `256` (matching `max_depth_cap` for descendant
  walks).
- `agency.child_tools`: keep the `None, Local` default narrowing (omitting `tools` excludes `agent_spawn`), and when `tools` explicitly includes `agent_spawn` retain it whenever `depth < depth_cap` (or always for `UnlimitedDepth`).

### 2. Optional `"agency"` object on `sessions.create`

`sessions.create` accepts an optional `"agency"` JSON object:

```json
{
  "agency": {
    "fan_out": 100,
    "session_strands": 256,
    "depth_cap": 1
  }
}
```

- All three keys inside `"agency"` are optional; omitted keys (or an omitted
  `"agency"` object) inherit the daemon/Agency defaults.
- `"fan_out"`: integer in `1..10000`.
- `"session_strands"`: integer in `1..10000` (if both `fan_out` and
  `session_strands` are provided, `fan_out <= session_strands` is enforced; if
  only `fan_out` exceeds the default `session_strands`, the session's
  `session_strands` rises to `max(default_session_strands, fan_out)`).
- `"depth_cap"`: integer in `1..256` (`BoundedDepth(n)`), or the string
  `"unlimited"` (`UnlimitedDepth`).
- Invalid types or out-of-range values are refused as `"bad_request"`.

### 3. Catalogue v21 persistence and retry equality

Catalogue version 21 adds `catalogue_session_agency`:

```sql
CREATE TABLE catalogue_session_agency(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id),
  fan_out INTEGER CHECK(fan_out IS NULL OR (fan_out >= 1 AND fan_out <= 10000)),
  session_strands INTEGER CHECK(session_strands IS NULL OR (session_strands >= 1 AND session_strands <= 10000)),
  depth_mode TEXT NOT NULL CHECK(depth_mode IN ('inherit', 'bounded', 'unlimited')),
  depth_cap INTEGER CHECK(
    (depth_mode = 'bounded' AND depth_cap >= 1 AND depth_cap <= 256)
    OR (depth_mode != 'bounded' AND depth_cap IS NULL)
  )
);
```

- Default creations (`fan_out: None, session_strands: None, depth_cap: None`)
  write no row.
- Retrying `sessions.create` with the same `request_key` compares the stored
  `AgencyLimits` against the request and returns `Conflict` on mismatch.
- Deleting a registration deletes its `catalogue_session_agency` row first.
- On open, delegate sessions still clamp `depth_cap` to their spawner's
  `max_depth` (`UnlimitedDepth` clamps to `BoundedDepth(spawner.max_depth)`).

### 4. Web UI and TUI

- The web new-session composer exposes a collapsed-by-default `"Subagent limits"`
  disclosure with inputs for `fan_out`, `session_strands`, and bounded vs.
  unlimited `depth_cap`.
- The TUI `/sessions` selector (`n`) keeps instant creation with defaults and
  adds an optional limits prompt (`l` on the new-session action / compact modal)
  accepting custom `fan_out`, `session_strands`, and `depth_cap` (`1..256` or
  `unlimited`).
