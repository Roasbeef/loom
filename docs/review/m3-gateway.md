# Adversarial review — M3 client-facing surface (gateway / wire / auth / TUI)

Scope reviewed in full: `packages/client/src/client/{gateway,protocol,grants,server,serve,wiring,demo}.gleam`,
`client/internal/ffi_os.gleam` + `client_ffi.erl`; `packages/tui/internal/{proto,client,ui,fake}`,
`cmd/loom-tui`, `proto/protocol.md`. Security weighted heavily (network attack surface).
Method: source read + confirmation against in-tree primitives (`broker/token`, `core/json`,
`broker/policy`). No package code was modified; no commits made.

**Counts:** 0 CRITICAL, 0 HIGH, 2 MEDIUM, 2 LOW, 1 informational. 10 areas checked and sound.

Most important finding: the privilege-escalation path — a malicious client approving its own
escalation with widened grants — is **airtight** (F-CS-1). The two MEDIUM findings are both in
the bearer-token auth for `LocalAuth`: a non-constant-time token comparison and a world-readable
window on the token file.

---

## MEDIUM findings

### M-1 — Bearer token compared with `==`, not constant-time (timing oracle) — CONFIRMED
`client/server.gleam:212-217`:
```gleam
fn authorized(request, token) -> Bool {
  case request.get_header(request, "authorization") {
    Ok(header) -> header == "Bearer " <> token
    Error(Nil) -> False
  }
}
```
`==` on BEAM binaries short-circuits at the first differing byte, so response time leaks a
prefix-match length of the presented token — a classic timing oracle on the auth secret. This is
the network authentication boundary, where the project's own priority order puts security first.
The tree already ships the correct primitive and uses it for the *other* token: `broker/token.check`
compares via `ffi_crypto.constant_time_equal` (`crypto:hash_equals`) and even scans without early
exit "so a match's position leaks nothing." The gateway's auth check does not reuse it.

Mitigating: the token is a full 128-bit CSPRNG value (see F-CS-2) and `LocalAuth` binds loopback,
so remote timing extraction across network jitter is impractical today. But `BearerAuth` exists
precisely for the remote case, and the fix is a one-line swap to the constant-time comparator
already in the dependency graph. Recommend comparing the raw token bytes with
`ffi_crypto.constant_time_equal` after stripping the `"Bearer "` prefix.

### M-2 — Token file has a world-readable window (write-then-chmod TOCTOU) — CONFIRMED
`client/server.gleam:186-192`:
```gleam
fn write_token_file(path, token) {
  use Nil <- result.try(simplifile.write(path, token))   // created with umask perms (e.g. 0644)
  simplifile.set_permissions_octal(path, 0o600)           // restricted only afterward
}
```
The file is created with the process umask (commonly `0644` = world-readable) and only narrowed
to `0600` on the next line. For `LocalAuth`, file permissions *are* the entire security model
("the peer-credential check moved into the filesystem" — module doc). Any local user polling the
token path during that window reads the bearer token and gains full session control. Boot time is
roughly predictable (server startup), which widens the practical window.

Secondary: `simplifile.write` truncates/follows an existing path, so a pre-planted symlink at
`<session>.token` would redirect the write (and the subsequent chmod) to an attacker-chosen target.
This requires write access to the session directory (the serving user's own dir), so it is a
lesser concern, but it compounds M-2.

Fix: create the file `O_CREAT|O_EXCL` with mode `0600` from the start (atomic), rather than
write-then-chmod. If simplifile cannot express that, mint into a fresh `0700` directory or write
via a mode-0600 temp + rename.

---

## LOW findings

### L-1 — No server-side inbound frame-size cap; catch_up amplification — CONFIRMED (DoS) / SUSPECTED (frame cap)
Two authenticated-DoS observations on the hub:

- **No inbound frame cap (SUSPECTED):** `client/server.gleam`'s websocket handler passes each
  `mist.Text(frame)` straight to `gateway.handle_text`; the Gleam side sets no read limit and I
  found no max-frame configuration in the vendored mist websocket internals
  (`build/packages/mist/.../internal/websocket.gleam`). A single authenticated client could send a
  multi-gigabyte text frame, which mist assembles in memory before `json.parse` ever runs. Note the
  asymmetry: the Go client *does* cap the server at `conn.SetReadLimit(16<<20)` (`client.go:327`);
  the server has no equivalent cap on the client. (Marked SUSPECTED because I did not fully trace
  mist's frame assembler — worth confirming whether glisten/mist imposes any ceiling.)
- **catch_up amplification (CONFIRMED):** one hub actor serves *all* connections of a session and
  processes `FromClient` serially. `catch_up{from_seq:1}` triggers full-transcript
  `scan_entries`/`scan_usage` plus per-strand register reads (`replay_events`, gateway.gleam:1174),
  with no rate limit and no per-connection budget. A client spamming `catch_up` from `1` does
  O(transcript) work per frame and blocks event delivery for every other connection on that session.

Both are gated behind a valid bearer token in a single-tenant trust model, so severity is LOW, but
a frame cap and a minimum-floor / debounce on `catch_up` would harden the hub against one bad
client. The `from_seq` value itself is correctly bounded (see F-CS-4).

### L-2 — Helper resolution trusts ambient PATH and CWD-relative `./bin` — informational/LOW
`client/serve.gleam:299-323` (`find_helper`) resolves the sandbox helper via
`ffi_os.find_executable("loom-exec")` (OS `PATH`) and falls back to the CWD-relative
`./bin/loom-exec`. A server launched with an attacker-influenced `PATH` or from an
attacker-writable working directory could load a counterfeit `loom-exec` — which is the process
that enforces the sandbox, so this is a high-value target. This is not reachable by a network
client (it is operator environment), so it is informational, but given the helper's role, an
explicit-path default or a verified install location would reduce foot-gun risk. (Distinct from
the sandbox's own `env: [#("PATH", "/usr/local/bin:/usr/bin:/bin")]`, which correctly fixes PATH
*inside* the jail, not for this boot-time lookup.)

---

## Checked and sound

### F-CS-1 — Grant subset check (the privilege-escalation path) is airtight — CONFIRMED
This is the highest-stakes path in scope: a malicious client sending `approve` with grants wider
than the denial (widening network / roots / env for its own re-execution). It is well defended:

- `gateway.approve` (gateway.gleam:1686-1757) derives `wanted` from `grants.decode_denial(record.denial)`
  where `record` is the **server-stored** escalation record (`find_escalation` → `api.escalations`),
  never from client input. The client cannot supply its own `wanted`.
- The check `grants.first_unwanted(chosen, wanted:)` (grants.gleam:249-257) requires every approved
  grant to satisfy `list.contains(wanted, grant)` — **structural equality** on the full `Grant`
  value. There is no prefix logic, no path normalization, no "network mode is looser" comparison
  that could be gamed. `GrantWritableRoot("/work")` only matches an identical wanted entry; a
  crafted `"/work/../etc"` or a widened `NetworkFull` is simply not in `wanted` and is rejected
  with `bad_request`.
- Only the validated subset is re-encoded (`grants.encode`) and handed to `api.approve_escalation`,
  so the consume path receives exactly what was approved. Defense-in-depth: the broker/kernel
  enforce at execution regardless.

No bypass found. This is the correct place for the check (before the grant reaches the runtime
consume path) and it is enforced correctly.

### F-CS-2 — Token entropy is a sound 128 bits of CSPRNG — CONFIRMED
`serve.mixed_entropy` returns `unique * 2^64 + random64` (random64 from `crypto:strong_rand_bytes`).
`server.mint_token` draws `entropy()` four times and reduces each with
`int.absolute_value(seed) % 4_294_967_296`. Because `2^64 ≡ 0 (mod 2^32)`, the `unique` high limb
is **entirely masked away** — each of the four 8-hex words is the low 32 bits of an independent
64-bit CSPRNG draw. The token is therefore 4×32 = 128 bits of pure CSPRNG. The hunt-list worry that
the predictable `unique_integer` half weakens the token is unfounded: it is discarded, not weakly
mixed in. (The `unique` limb still does its job on the *id-seed* path, where uniqueness matters and
the low `random` cannot collide the pair — that reasoning in the serve.gleam comment is about ids,
not the token.) Sound.

### F-CS-3 — Protocol decode is total and depth-bounded — CONFIRMED
`protocol.decode_command`/`decode_event` route through `core/json.parse`, which enforces
`max_depth = 256` via `check_depth` (json.gleam:400) — deeply nested JSON yields a
`CorruptionReport` → `MalformedFrame`, never runaway recursion. Every command body is a total
decoder returning `Result(_, String)` → `BadBody`, answered in-band. A malformed `prompt`/`steer`/
`approve` body crashes neither the per-connection flow nor the hub (the hub `dispatch` matches all
four `ProtocolFault`/`Ok` cases and always returns `state`). No `let assert`, `panic`, `todo`, or
partial match exists on the network path (grep-confirmed across all five gateway-side modules).
Unknown `cmd`/`event` names survive as `UnknownCommand`/`UnknownEvent` and are answered
`unsupported`, as designed.

### F-CS-4 — catch_up / subscribe `from_seq` is bounded; no negative/future OOB — CONFIRMED
Both `subscribe` (gateway.gleam:1116) and `replay` (gateway.gleam:1156) gate on
`from > 0 && from <= state.high_water + 1`; anything negative, zero, or beyond the high-water falls
back to a full snapshot. `replay_events` clamps its scans to `[from_seq, high_water]`. No unbounded
or attacker-driven scan range.

### F-CS-5 — No cross-session seq confusion — CONFIRMED
Each gateway hub serves exactly one session: `subscribe` rejects any `session` name other than
`state.session_id` with `unknown_session` (gateway.gleam:1101), and every storage read is against
the fixed `state.runtime.session.store`. Seqs are that store's own seqs. A client cannot address
or observe another session's entries by seq manipulation — there is no other store in reach.

### F-CS-6 — Cross-strand command access is by-design, not a flaw — CONFIRMED
A subscribed client may prompt/steer/abort/config any strand in the session. This is intentional:
one session = one gateway = one bearer token = one trust domain. There is no per-strand principal
to enforce against. Commands to unknown strands are rejected (`known_strand` → `unknown_strand`).
No cross-*session* reach exists (F-CS-5). Noting explicitly because the hunt list raised it.

### F-CS-7 — Pre-auth surface leaks nothing; no upgrade bypass — CONFIRMED
`route` (server.gleam:196): `/v1/ws` requires `authorized` before `upgrade` (401 emitted before any
websocket state exists); `/healthz` returns a static `"ok"` (no session/version/build info); all
other paths return a static `404`. There is no path that reaches `mist.websocket` without passing
the bearer check.

### F-CS-8 — SIGTERM/halt not client-reachable — CONFIRMED
`ffi_os.halt` is called only on boot failure and after `wait_for_sigterm` returns; the SIGTERM relay
(`client_ffi.erl`) responds to the OS signal only and ignores other signals. No websocket command
maps to shutdown or halt. `shutdown` closes the runtime (releasing the lease) in dependency order.

### F-CS-9 — TUI seq discipline resists a malicious server — CONFIRMED
`client.go:handleEvent` (438): a rewound/duplicate seq (`ev.Seq <= last`) is dropped — no
double-apply; a forward gap (`> last+1`, post-snapshot) triggers exactly one `catch_up` from
`last+1` and drops the out-of-order event — no silent skip. A hostile server can at worst stall the
client (never fill the gap), never corrupt its position, and the TUI holds no durable state.
`conn.SetReadLimit(16<<20)` bounds server frames. `readLoop` is the single reader, so the
Load/Store on `lastSeq` is not racy. Sound.

### F-CS-10 — Grant/denial decoders are total — CONFIRMED
`client/grants.decode`/`decode_denial` and `protocol.decode_grant`/`decode_network`/`decode_scratch`
all return `Result` with corruption reports / error strings on every malformed shape (unknown
discriminators, wrong types, missing fields). An escalation carrying a malformed stored denial is
answered `internal` ("the stored denial is unreadable"), not a crash (gateway.gleam:1700). Unknown
grant `type` → in-band error.

---

## Notes for other reviewers / follow-up
- Confirm mist/glisten imposes some inbound websocket payload ceiling (L-1); if not, add an explicit
  cap in the `server.gleam` handler before `handle_text`.
- M-1 and M-2 are both quick, high-value hardening: reuse `ffi_crypto.constant_time_equal`, and make
  the token-file creation atomic at `0600`.
- The `catch_up` amplification (L-1) interacts with the single-actor-per-session design; a rate/floor
  guard is the natural mitigation if untrusted clients are ever in scope.
