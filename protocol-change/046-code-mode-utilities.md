# 046: Default orchestration and reusable code-mode helpers

Status: accepted for implementation at the owner's request.

## Problem

The shipped workspace-only default hides the existing agent orchestration API.
JSON parsing is available through gleam/json, but converting between JSON text
and the opaque report.Value used by notes and child results requires hand-built
conversions. Repeated spawn/wait loops also leave each program to account for
partial admission, pending children, and the lifetime of its concurrency slots.

## Decision

The server defaults to BothSeams. Explicit workspace/orchestration/both flags
continue to select the offered surfaces. An unnamed submission still chooses
workspace; an orchestration submission explicitly names its seam. The two
allowlists remain separate, and existing Agency authority checks and ceilings
remain in force. This does not grant extensions the orchestration surface.

report.decode_json(String) returns Result(Value, String), using the existing
core JSON parser. report.encode_json(Value) returns Result(String, String).
Both preserve scalar distinctions and object order. Binary values, non-text
keys, duplicate keys, and containers beyond the parser's depth bound fail
rather than being coerced. The satellite and host share core/json_wire's
conversion; no third-party dependency or external function is introduced.

strand.map(assignments, max_concurrency:, within_ms:) returns
Result(List(Mapped), StrandError). Concurrency must be 1..32 and the join
window nonnegative; invalid arguments cause no host calls. Assignments run
in bounded batches. Each batch uses one shared join window; the existing
execution deadline remains the outer bound. A Ready result releases a slot,
including failed/aborted child outcomes, whose verdicts remain visible.

A failed admission stops subsequent admissions and still joins previously
admitted children. Any Pending or failed join stops later batches. Every
input has exactly one output in input order: Joined(Waited), SpawnFailed,
JoinFailed(handle, error), or NotStarted(assignment). The helper retains all
known handles and never cancels admitted children. Transport loss during a
spawn may leave an admission with no returned handle, as with raw spawn; the
helper stops and does not retry an uncertain effect. The parent can inspect
its durable roster. Retrying NotStarted work while earlier children remain
live requires the caller to account for those children first.

## Alternatives and cost

A rolling scheduler could fill slots as individual children finish, but would
need new join/scheduling machinery. Batches reuse the current spawn and wait
contracts, preserve custody on partial progress, and avoid a process runner.
The tradeoff is idle slots while a batch's slowest child runs. map adds no RPC,
no new capability, and no additional authority.

Complete workspace and orchestration recipes are included only when their
imports are offered. Tests execute those exact model-visible strings through
the jailed pipeline and compare them with the documentation examples. This
costs prompt bytes, but makes the advertised workflows executable rather than
leaving agents to infer valid code from signatures alone.
