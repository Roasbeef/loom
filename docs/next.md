# Current handoff

Issue #25 landed on `claude/gleam-lsp-support-7oagc3`: Loom's own agent
can ask a language server about the code it is editing. The ruling is
[ADR-013](adr/013-language-servers-as-jailed-leases.md) and the account
is [the LSP architecture doc](architecture/lsp.md). Read both before
touching any of it; the ADR's "Measured" table and its corrections are
what the code is built against.

## What exists

A session whose `loom.toml` carries an `[lsp.<name>]` table gets:

- seven tools — `lsp_definition`, `lsp_references`, `lsp_hover`,
  `lsp_symbols`, `lsp_calls`, `lsp_diagnostics`, `lsp_rename` — that
  address symbols by name (optionally qualified, `util.Greet`, and
  narrowed by a path and a 1-based line), never by position, and answer
  with anchored sites a model can feed straight into `fs_edit`;
- settled diagnostics appended to `fs_write` and `fs_edit` results for
  files the running server owns;
- `cap/lsp` in code mode, admitted only when a server is configured, so
  a session without one pays nothing in its cached prefix;
- a rename that previews by default and applies through the hashline
  landing path, refusing the whole rename when any file on disk no
  longer matches what the server saw.

The server runs as an ordinary jailed exec under the session's own
enforcement demand, after a probe proves that demand is met, one per
session, with a lazy restart. Nothing is discovered or installed; an
unconfigured workspace starts nothing.

Validated here (a cgroup-v1 container, so under `BestEffort`): the
scripted-model acceptance in `conformance/lsp_e2e_test.gleam` against a
jailed `gleam lsp` (rename across three files, concurrent-write
rejection, an `fs_edit` using a references anchor) and a `gopls`
variant. **Not validated here:** the enforced path under
`PlatformEnforcement` (the probe refuses on this host, correctly), and
macOS. The jailed Linux gate and a sign-off host with a delegated
cgroup v2 base are where those run.

## Rulings to preserve

**Positions never leave `packages/lsp`.** The model and every surface
speak `lsp/query.Site`; `lsp/text` is the only converter, against the
exact text a position was computed on. A site's text is the line as
hashline sees it (a CRLF line keeps its `\r`) so its anchor is the one
`fs_read` prints.

**Gate every request on advertised capabilities.** `gleam lsp` never
answers a request it did not advertise.

**Edits land only through hashline.** The server never writes;
`workspace/applyEdit` is declined; resource operations are refused.

**The harness never reads a path a server merely names.** The jail
bounds what a server reads, not what it names; `client/lsp/resolve.admit`
admits a server-named path only under the server's root and outside
every protected entry, and anything else is shown with no text and
never opened (found by the final review, fixed before merge).

**Enforcement is proven before a server starts,** because the helper
reports enforcement only when an execution exits.

## A production race the LSP end-to-end exposed (not fixed here)

`make check` failed the LSP rename end-to-end once, under a machine
loaded by two parallel cold builds. The root cause is in weft, not in
this work: a custodian adopts a published transport owner as Transitive
and monitors it, but the begin permit reaches the owner through another
process chain and can overtake the monitor signal (BEAM orders signals
only per sender and receiver pair). An owner that exits normally in
that window is judged `noproc`, weft reads that as `weft_drain_proof_lost`,
and the session fails closed. A thirty-line plain-Erlang module
reproduces the ordering (a few dozen `noproc`s per 1.6M runs under load),
and a round trip or `process_info(Owner, current_function)` after the
monitor removes it. The proposed fix is that barrier in weft's
`adopt_published` and the `OwnedTask` arm of `fill_slots`, recording
`ProofAbsent` when the owner is really gone. weft is pinned from Hex at
0.4.4 with no sibling checkout here, so it waits for a weft release.
The scripted provider's owner exits about 100 µs after begin, which is
why this test finds the window first; real httpc owners are exposed
too, only rarely.

## Remaining work

1. Land the weft barrier above and bump the pin.
2. The daemon custody retirement path stops the manager with the
   service tree, racing the broker stop that follows; a graceful ordered
   stop needs a custody part in `internal/instance_owner`.
3. The helper writes stdin while holding the mutex `Cancel` needs
   (ADR-013 §1, known hazard); a wedged server blocks cancel until the
   broker's three-second helper kill. Worth fixing in the helper.
4. Count extension hosts against the per-session lease cap.
5. A second server per session (a Go and a Gleam project side by side
   evict each other today).
6. Follow-ups from the design discussion that are the owner's call: move
   #26 (DAP) out of release-blocker in favour of a satellite-local trace
   capability; bounded read-only BEAM introspection for the agent
   (#454); structured session-trace queries beside `history_search`
   (#236); write the upstreaming stance down.
7. Still open from before: measure how virtual-read discovery affects
   prompt size and cached-prefix reuse; a coordinator example that does
   independent work after launching children and then sends them
   follow-up tasks; saved-session outboxes, cross-machine transport and
   durable actor recovery, designed separately.

## Collaboration rulings (from #510, still in force)

**Authority and communication are separate.** A link grants neither child
custody nor filesystem access. The source index permits discovery; the
recipient grant authorizes admission. A peer receipt proves durable message
admission, not model consumption or review completion. `busy_only` never wakes
an idle target; `may_wake` is a separate owner choice.

**A virtual read is a capability call.** `cap://` serves generated declarations
for modules the selected code-mode seam admits. `job://` exposes only the
calling strand's jobs. Neither is an operating-system mount. Ordinary file
reads and image support retain their path. Prompt guidance must match the
installed router and generated prelude in both workspace and orchestration.

**Recovery retains identity, not execution state.** Typed input is admitted
before callback completion. Progress is an intermediate observation. A named
workflow step reconciles its original child operation and result after a lost
satellite. It cannot replay arbitrary effects or restore an actor heap.

**Operator surfaces do not open saved sessions.** CLI and TUI use the
owner/epoch-checked control protocol. Inspection is bounded into pages. A
large catalogue or grant set is not permission to activate a saved target.
The CLI reports partial unlink when source authority was removed but
recipient revocation could not finish.

## Developer tooling note

The root `CLAUDE.md` paragraph on `gleam lsp` is about the editor
tooling a developer drives this repo with: Claude Code still has no
Gleam server configured. A project-local plugin with an `.lsp.json`
(`gleam lsp`, `.gleam`) would give local CLI sessions go-to-definition
and post-edit diagnostics; cloud sessions do not start language
servers. That is separate from, and not needed by, anything above.
