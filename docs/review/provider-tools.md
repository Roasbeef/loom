# Adversarial review: provider and tool surface

## Scope and method

Read-only adversarial review of `packages/provider` (model, stream,
adapter/anthropic, adapter/openai, http, secret, retry, gateway, internal/\*),
`packages/tools` (tool, hashline, fs, bash, grep, blob, internal/\*), and
`packages/conformance/src/conformance/wiring.gleam`. Cross-referenced
`core/codec`, `core/msgpack`, and `docs/spec-gaps.md`.

Threat model followed: provider SSE is untrusted third-party wire (a hostile
proxy is in scope); tool arguments are model-influenced; the durability
boundary is a strict total codec while provider wire is read leniently — the
seam between "lenient read" and "strict store" is where a corrupt
`AgentMessage` can slip through. Findings were confirmed by reading the code
and, for the hashline defect, by a throwaway test run against the real
`tools/hashline` module (since removed).

Severity key: CRITICAL = file corruption / secret leak / crash-the-strand /
durable-store poison; HIGH / MEDIUM / LOW below that.

---

## CRITICAL

### C1 — `fs_edit` double-applies on duplicate lines; replay corrupts files (CONFIRMED)

`packages/tools/src/tools/hashline.gleam:311` (`apply`), refs at `:398`.

The module, `tools/fs` (lines 20-26), and `tools/tool` (lines 52-54) all claim
the anchor check makes double-apply impossible, and this is the entire
justification for `fs_edit` being `replay: Safe`. It is false whenever a
referenced line has an identical sibling that shifts into its position after
the splice — which is exactly what blank lines, `}` lines, `end` lines, etc.
produce.

`stale_references` (`:372`) checks the anchor of the line **currently** at
`ref.line`. After a `Delete`/`Replace` removes a line, the next identical line
slides up into that number, so its anchor still matches on a second apply.

Confirmed with a throwaway test against the real module:

```
content = "x\nx\n"
plan    = Delete(Ref(1, anchor("x")), Ref(1, anchor("x")))
apply(content, plan)      -> Ok("x\n")     // correct
apply("x\n",   plan)      -> Ok("\n")       // DOUBLE-APPLIED, should be StaleAnchors
```

Blank-line variant `"a\n\n\n\nb\n"` deleting line 2 (`anchor("")`) reapplied
three times yielded line counts 4 → 3 → 2: every replay eats another blank
line. Because `fs_edit` is `Safe`, the runtime re-dispatches the identical
call on crash-recovery; a file with a duplicate line in or adjacent to the
edited range is silently corrupted (extra deletion / lost lines).

Failing-test sketch: `apply(apply(c, delete_of_duplicate).unwrap(), same_plan)`
should be `Error(StaleAnchors(..))`; it returns `Ok` with a second deletion.

Fix direction: verifying only endpoint anchors cannot detect the shift. Either
(a) require every line in a removed range to be referenced and checked, and on
replay verify the *post-edit* shape is not itself a valid target (e.g. embed a
pre-image digest of the whole affected span in the plan), or (b) drop the
"double-apply impossible" claim and make `fs_edit` `Never` (synthesize an
interrupted result on recovery) rather than `Safe`.

---

## HIGH

### H1 — SSE parser: unbounded carry and O(n²) re-scan on a terminator-less line (CONFIRMED)

`packages/provider/src/provider/stream.gleam:249` (`feed`), `:258`
(`feed_loop`), `:276` (`take_line`).

`feed` appends the chunk to `carry` and scans for a line terminator from
offset 0. When no terminator is present, `feed_loop` puts the **entire**
buffer back into `carry` (`:268`). The next chunk re-appends and re-scans from
0 again. A provider/proxy that streams a long line with no `\n` therefore
drives:

- **Unbounded memory**: `carry` grows to hold every byte since the last
  newline, with no cap. A never-terminated line grows until the VM dies.
- **Quadratic time**: for a line of total size `T` delivered in `k` chunks the
  parser does ~`k·T/2` byte scans. The gateway's 300s idle timeout
  (`gateway.gleam:107`) never fires because every chunk resets the idle wait.

The parser stays *total* but is not *bounded*, contrary to the module's
sans-io contract. This is a denial-of-service reachable from untrusted wire:
it hangs the pump process (and thus the strand's generation) and exhausts
memory.

Failing-test sketch: feed 2000 chunks of 64 KiB containing no `\n`; assert the
parser rejects or bounds the buffer. Today it accumulates ~128 MB of `carry`
and re-scans it every chunk.

Fix direction: cap the carry / maximum SSE line length and fail the stream as
`MalformedStream` when exceeded; track a scan offset so re-scanning resumes
past the already-examined prefix instead of restarting at 0.

### H2 — `fs.resolve_path` is lexical-only; a workspace symlink escapes the root (CONFIRMED)

`packages/tools/src/tools/fs.gleam:108` (`resolve_path`), `:145` (`normalize`),
`:127` (`check_under`).

`normalize` collapses `.`/`..` textually and `check_under` verifies the
string is under the root. No symlink resolution happens. The module doc
(`:90-95`) waves this off — "no symlink traversal — the sandbox owns that
concern for jailed processes; this is harness-side defense in depth" — but the
fs tools run **harness-side and never go through the broker/jail** (their own
doc, `:8-12`, `:646-649`). `real_filesystem` calls `simplifile` directly, which
follows symlinks.

So a symlink at `/work/link -> /etc` (checked into a repo, or planted by a
prior jailed `bash` write inside the workspace, which is permitted) makes
`fs_read`/`fs_write`/`fs_edit` on `link/passwd` resolve lexically to
`/work/link/passwd` — passes `check_under` — and simplifile follows it to
`/etc/passwd`. Model-influenced path + a symlink yields arbitrary read and
overwrite outside the workspace, harness-side, which is precisely the Rule
Zero boundary these tools are supposed to hold.

Failing-test sketch: under a real FS, `ln -s /etc /work/link`, then
`fs_write` `link/x`; assert refusal. Today the write lands at `/etc/x`.

Fix direction: resolve the real path (realpath / lstat each component) and
re-check containment, or refuse any path component that is a symlink; do not
rely on a jail these tools bypass.

### H3 — Untrusted usage counts exceed the durable msgpack int range (CONFIRMED)

`packages/provider/src/provider/internal/wire.gleam:47` (`int_field_or`),
`adapter/anthropic.gleam:581-588` and `:937` (`build_usage`), vs
`core/msgpack.gleam:127` (`encode_int` → `IntegerOutOfRange`) and spec-gaps
item 8.

Usage fields are read with `int_field_or`, which accepts any `json.Int`.
`core/json` ints are arbitrary precision (spec-gaps 8), so a proxy sending
`"usage":{"input_tokens": 100000000000000000000}` yields
`Usage.input = 10^20` and `total_tokens = input + output + …` well beyond
`2^64 - 1`. There is no clamp anywhere between the adapter and the settled
`AgentMessage`.

When the durability plane msgpack-encodes that assistant `MessageEntry`,
`encode_int` returns `Error(IntegerOutOfRange)` — the lenient read has produced
a value the strict store cannot encode. This is the decode/encode asymmetry
the doctrine is meant to exclude: untrusted wire controls whether a core
durable write of a settled turn succeeds (turn lost / strand stalled,
depending on how the durability layer handles the encode error). Same path in
`adapter/openai.gleam:882` (`build_usage`).

Failing-test sketch: run `anthropic.response_machine` over a `message_start`
with an oversized `input_tokens` plus a valid stop, take the `Settled`
message, encode its usage through `core/codec` → `core/msgpack`; expect
success, get `IntegerOutOfRange`.

Fix direction: clamp/validate usage counters to the msgpack-encodable range at
the provider boundary (saturate to a sentinel or reject as `MalformedStream`),
so nothing downstream of the lenient read can be unencodable.

---

## MEDIUM

### M1 — Range hunks anchor-check only their endpoints (CONFIRMED)

`hashline.gleam:398` (`refs`). A `Delete`/`Replace` over `[from, to]` produces
references for `from` and `to` only; interior lines are never checked against
current content. The apply doc claims "every referenced anchor is checked" —
true but misleading, because interior lines are unreferenced. A concurrent
modification to an interior line between read and write is invisible and gets
deleted/replaced silently. This weakens the TOCTOU guarantee for exactly the
multi-line edits where it matters most. Fix: reference and verify every line
in a removed range.

### M2 — Wiring drops the strand's per-turn thinking level on the happy path (CONFIRMED)

`wiring.gleam:239` (`request_target`). When `gateway.resolve(role)` matches the
captured identity, the request uses `resolved` — whose `thinking` is the
route's **static** config — and `configuration.thinking_level` is discarded.
The mapped `thinking_level(configuration.thinking_level)` is applied *only* on
the fallback branch (`:249`). So a strand that raises/lowers thinking per turn
is silently overridden by route config whenever routing agrees (the common
case): a turn asking for `ThinkingOff` still burns the route's `ThinkingHigh`
budget, and vice versa. The asymmetry (mapping computed but used only in
fallback) reads as an oversight. Fix: carry `configuration.thinking_level`
into the resolved target's `thinking`, not just the fallback's.

### M3 — Adapter overflow is driven by provider-reported usage (SUSPECTED)

`anthropic.gleam:843-856`, `openai.gleam:792-805`. Overflow is computed as
`input + cache_read > context_window && output <= 64`, from provider-supplied
counts. A hostile/broken proxy can report a huge `input_tokens` with small
`output` on an ordinary short answer, rewriting a normal `Settled` response to
`Errored` + the canonical overflow message, which drives the machine to
compact and retry needlessly (and, if the proxy repeats the lie, to compact
repeatedly). A genuinely short real answer against a conservatively-configured
window can also misfire. The negligible-output guard limits but does not close
this. Fix: prefer a locally-computed input estimate, or gate overflow behind an
HTTP-status/error-type corroboration rather than trusting streamed usage
alone.

---

## LOW

- **L1 (CONFIRMED)** `anthropic.gleam:581-588`: `handle_message_start` sets
  `input/output/cache_*` unconditionally from the event's usage (default 0). A
  duplicate `message_start` carrying an empty `usage` object zeroes previously
  accumulated counts, so a proxy can suppress usage accounting. Use
  `int_field_or(.., or: acc.input)` (as `message_delta` already does) or ignore
  a second `message_start`.
- **L2 (SUSPECTED)** `wiring.gleam:190`: `unsupported()` returns
  `TransportFailed`, which `retry.classify` treats as `Retryable`. If a
  `PollRequest`/`SummaryRequest` ever reaches it (documented as "never" for M2),
  the machine burns its whole retry ladder on a permanently-failing surface
  instead of failing terminally. Prefer a terminal-classified error here.
- **L3 (informational)** `http.gleam` / `stream.gleam`: `api_key` is confined
  to headers and never appears in any `ProviderError`, event, or returned
  structure — verified. The only residual: if an operator configures a
  `base_url` with embedded userinfo, a transport `reason`/URL could surface it;
  the API key itself is unaffected.

---

## Checked and sound

- **SSE framing correctness / chunk-boundary invariance** (`stream.gleam`
  `take_line`/`handle_line`/`dispatch`): `\n`, `\r\n`, and split-`\r\n`
  boundaries are handled correctly; a UTF-8 sequence or `\uXXXX` escape split
  across chunks is reassembled in `carry` before `to_string`, so feeding any
  chunking yields the same events. Functionally invariant — the only defect is
  boundedness (H1).
- **Stop-reason mapping totality** (`anthropic.map_stop_reason`,
  `openai.map_finish_reason`): unknown values return `Error(Nil)` and settle as
  `Failed(UnmappedStopReason)` in-band; never a crash. The
  `stream.settle(Pending)` "unreachable" branches are reported totally.
- **Retry** (`retry.gleam`): `classify` is total; `backoff_ms` is bounded and
  terminates (`exponent_of_two` decrements to 0); `is_overflow_message`
  excludes throttling phrasings. The gateway fallback walk (`gateway.attempt`)
  terminates on every input (chain shrinks; last terminal delivered as-is).
- **Secrets** (`secret.gleam`, `gateway.attempt_one`): the store yields values
  only into request headers; `ProviderError` carries names only; no event or
  returned value embeds a secret.
- **blob** (`blob.gleam`): SHA-256 content addressing makes writes idempotent;
  `utf8_prefix`/`utf8_suffix` back off to a character boundary correctly; the
  `> 65536` threshold is a strict boundary.
- **hashline byte-exactness** (`split_lines`/`join_lines`): round-trips CRLF
  and no-trailing-newline content byte-for-byte; overlap detection rejects
  intersecting ranges and coincident insertions. (The double-apply and
  interior-check gaps are C1/M1, not framing defects.)
- **fs path prefix-sibling** (`check_under`): `/work` vs `/worktree` is
  correctly rejected; empty and root escapes are rejected. (Symlinks are the
  hole — H2.)
- **tool.dispatch** is total: an unknown name returns an in-band
  unavailable-tool result rather than crashing.
