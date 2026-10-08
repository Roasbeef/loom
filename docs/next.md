# Current handoff

This edition covers the distributed runtime (issue #697) on
`distributed/simplify`, rebuilt from `main` at `7091d5a42` after PR #819 was
archived. An orchestrator daemon keeps a session's runtime, SQLite store and
approvals. An executor daemon of the same release holds the checkout and runs
the session's workspace tool calls. The two talk over TLS Erlang distribution
with pinned leaf certificates.

The branch is **not pushed and has no PR**. Publishing it needs the owner's
explicit authorization. Every claim below was verified on the code candidate
`3318250e0` (`3318250e0b32fd9f470c611d7e2022935f73f8e9`, 195 commits over
`7091d5a42`). The next commit, `88a70dd34`, changes one shipped test to wait for
a file rename it raced on Linux, and the commit after it changes only this file;
no source file differs from `3318250e0`. After that, `7628912ba` changes
`client/distribution` so the daemon starts `epmd` when none answers, and
`6c945a8c2` documents it (see "Rulings already made"). The gated signoff is
green on `6c945a8c2`, and `main` was then merged into the branch as
`3a541c1d4`.

The previous edition on `main` covered the compile and export work of
[PR #917](https://github.com/Roasbeef/loom/pull/917); its measurements are in
[the compile-time report](review/compile-hill-climb-2026-10-07.md).

Read [the design note](design-notes/distributed-runtime.md) for the design,
[protocol-change/078](../protocol-change/078-distributed-runtime.md) and its
addenda for the wire and the rules, and [the setup guide](distributed-setup.md)
for running it. `packages/client/CLAUDE.md` has one section per phase, from
"Trusted distribution membership" to "Moving a session between orchestrators".

## Merged from main

A second merge of `main` (after `3a541c1d4`) brought in four PRs, each
described in its own record. None changes the distributed runtime's rulings
below; the two code conflicts were in `client/serve.gleam` (main's
`usable_seed` beside this branch's move of `mixed_entropy` into
`workspace_plane`) and the imports of `ui_route_test`.

- [PR #925](https://github.com/Roasbeef/loom/pull/925): terminal large-result
  wrapping by a linear cursor over code rows. Measurements are in
  [the wrapping report](review/tui-large-result-wrap-2026-10-08.md).
- [PR #926](https://github.com/Roasbeef/loom/pull/926): the web Link form hides
  sessions that are already linked.
- [PR #927](https://github.com/Roasbeef/loom/pull/927): code-mode and LSP
  readiness. Automatic code-mode selection admits a workspace seed only after
  `seed.verify` accepts it, and the LSP diagnostics scope is recorded in
  `protocol-change/078-lsp-diagnostics-scope.md`.
- [PR #928](https://github.com/Roasbeef/loom/pull/928): paged and downloadable
  full tool results in the browser, keyed by immutable result records
  ([protocol-change/079](../protocol-change/079-browser-result-records.md),
  [the browser report](review/browser-large-results-2026-10-08.md)). Paging
  reads one storage fragment through `serve.Resident.result_reader`, and a
  download reads a complete bounded record under one deadline. Search in the
  viewer applies to one page, and byte windows can split JSON syntax or lines.
  Output summarization and whole-result browser search are not done.

Main's handoff for that work also said: run `make gen-client` after changing
browser source, and judge every gate by its own exit code. A gate run on a
PR's original head does not attest to a later integration head, so each merge
checks its own current SHA.

## Where the tree is

| Phase | What exists |
| --- | --- |
| 1. One orchestrator, one executor | `ToolSurface.run` is the cut. The executor runs main's own workspace plane behind `remote/host`, with one SQLite ledger per executor (`storage/exec_ledger`, schema version 3). Scope rows carry an incarnation and an attach token; call rows are keyed by `(session, op, step, source_index)`. A session attaches once per open. A reconnect re-sends the same `Run`. Only a non-`noconnection` DOWN cancels. Recovery fences `ReplayNever` keys. An acknowledgement leaves a tombstone until the incarnation changes, so a key admitted once in an incarnation never starts again in it. Owner-bound code-mode capabilities answer over the owner port. `loom distribution` (`dist`) provisions and installs bundles, and `loomd executor release` is the operator override for a scope whose cleanup was never proven. |
| 2. Executor pools | `[pools.<name>]` with a trial order and declared requirements. The scope record names the executor before `Attach`. The next candidate is tried only on a failed connection or `CapacityExhausted` at first open. A census that contradicts the declaration closes the scope. |
| 3. Two orchestrators | Option C: `session_directory` is a Khepri-shaped interface backed by a 2 s parallel lookup over pinned peers, and each catalogue stays the source of truth. `not_owner` and `owner_unreachable` redirect the owner principal only, with no automatic follow. |
| 4. Peer mail between orchestrators | A sender outbox (`client/peers/outbox/<digest>`: pending, admitted or refused) drained by a weft state machine; `PeerCommand` (Allow, Revoke, Deliver, SentReceipt) on the `loom_orchestrator` port; a typed `peer_mail.Failure`. |
| 5. Controlled movement | `sessions.move` and `loom sessions move`. Authority is two catalogue CAS rows (v12 `catalogue_session_moves`), a write-ahead intent and the executor's token fence, over six steps with resume at boot. A committed activation is always answered `Accepted`. An imported session cannot be moved on or deleted until its origin has retired. |
| 6. Acceptance | Two independent Fable 5.1 reviews of the assembled system (remote core; directory, peer mail and movement), each with re-verification of its fixes; a P model of remote execution and a TLA+ model of a move, both gated; the evidence below. |

### Evidence

All rows are for `3318250e0` unless marked. Mac: Darwin arm64 (macOS 15.5).
Linux: the box described below.

| Gate | Host | Result |
| --- | --- | --- |
| `make check-gleam` (format, warning-free build, every package's tests, lint) | Mac | exit 0, 636 s. host 75, core 140, storage 256, session 65, machine 93, prompt 103, session_view 427, web_view 927, telemetry 34, runtime 190, provider 257, broker 401, executor 10, mcp 123, lsp 191, tools 680, cap 182, ext 37, codemode 381, events 47, client 3591, conformance 97, tui 1312, lint 240 |
| `make doc-check`, `make prelude-check` | Mac | exit 0, exit 0 |
| `make server-shipment`, `make sandbox` | Mac | exit 0, exit 0 |
| Ten shipped modules against `bin/loomd` (`daemon_shipped_remote`, `_codemode`, `_caps`, `_tools`, `_pool`, `_strand`, `_owner_loss`, `daemon_shipped_directory`, `_peer_mail`, `daemon_shipped_remote_move`) | Mac | every one exit 0, 0 SKIP lines |
| `make model-check` | Mac | exit 0. TLA+ `session-move`: 1179 states, 392 distinct, depth 20; four mutants each violate their invariant. P `terminal-attachment`: every case and probe. P `remote-execution`: every case and probe; seven mutants (token ignored, `noconnection` cancels, recovery without a fence, second run for a key, reply before commit, plane checked before ledger, ack deletes the row) each caught by its spec |
| `make selftest` | Linux | exit 0, 11 layers enforced (cgroup-v2 included), none skipped |
| `make check-gleam` | Linux | exit 0, 1698 s, the same per-package counts as the Mac row |
| `make e2e` | Linux | exit 0, 97 tests; two gopls tests skip because the box has no gopls |
| Ten shipped modules | Linux | every one exit 0 with 0 SKIP lines, except `daemon_shipped_remote_move_test`'s first run, which failed asserting the moved session's file was gone in the instant between the `moved` row and the rename. It passed when rerun alone, and on `88a70dd34` (the test waits for the rename) it passed three runs out of three |
| `make model-check` | Linux | not run: the box has no Java, TLA+ jar or P tool |
| Cross-host, both directions (Mac brains with box hands, and the reverse): file, `bash`, `fs_read` and `git` in the remote checkout and absent locally; stop then `Closed(AllRetired)`; reopen at incarnation 2; tunnel cut during a 75 s call, which ran once and was delivered after recovery | Mac and Linux | passed on `193dbd8db`. The remote execution path has changed since (clock stamp, ledger v3), and the cross-host run was not repeated on `3318250e0` |
| Shipped SIGKILL restart and partition drills (`daemon_shipped_remote_test`) | Mac | in the shipped row above |
| Gated signoff (`make signoff-remote`), fresh Linux container | Linux | green on `6c945a8c2`. An earlier run in a fresh container, with no `epmd` running, found the missing `epmd` start that `7628912ba` fixes |

## Rulings already made

**The cut.** The cut is `effects.ToolSurface.run`. Clearance and approvals stay on the
orchestrator. The executor never sees the conversation.

**One ledger, durable outcomes.** One SQLite file per executor, short transactions,
full sync and a digest over each stored outcome. A row is terminal before any reply.
An unknown call is never run again. A key answered from the ledger is answered before
any question about whether a plane exists.

**Phase 3 is option C** (owner, 2026-10-08). The directory is an interface, not a
store. Creation happens on the connected orchestrator, and ids are UUIDv7, so there is
no register step.

**Phase 5 authority is two catalogue rows, not a third store.** The owner's wording was
"an authoritative store behind the directory". The adopted design has no third party:
the source's `moving`/`moved` row and the receiver's `imported` row are ordered by a
write-ahead intent, and the executor's incarnation fence is a second guard. Only an
answer abandons a move; silence stalls. This difference was flagged to the owner.

**Unproven cleanup is released by hand.** A scope whose children could not be proven
gone gets no automatic successor. `loomd executor release` (daemon stopped) records the
override in the ledger's `scope_release` table, and the next open reopens at the next
incarnation.

**The daemon starts `epmd`.** The daemon VM boots without a node name and starts
distribution with `net_kernel:start/2`, and that dynamic start never launches
`epmd`, unlike `erl -name` at boot. On a machine where nothing had started one,
the node failed to register. `distribution.start` now asks the loopback `epmd`
first and, when none answers, runs the release's `epmd -daemon` (or the one on
`PATH`) and waits up to three seconds; `-start_epmd false` turns this off. The
signoff caught the defect in a fresh container (`7628912ba`, documented in
`6c945a8c2`).

**Formal models.** `make model-check` runs TLC on `session-move` and P on
`terminal-attachment` and `remote-execution`, with probes and mutants. No directory
model was written, because the directory holds no state of its own.

**Trust.** An executor is a trusted Erlang peer. The TLS check binds a leaf to some
configured pin and that pin's node name, so per-node identity between pinned peers is
not established at the distribution layer. The owner port limits the kinds of command
a peer can send, which is scope hygiene and not a security boundary.

## Known limits and follow-ups

- No failover, and no moving a session between executors. Ra/Khepri comes later.
- After an executor restart, a session that stays open keeps failing new tool calls
  with "attach first" until it is closed and reopened. Calls the ledger knows are
  answered honestly. Orphan runs left by an orchestrator that died hold their budget
  until the session is reopened and closed; there is no executor-side listing.
- An imported session whose origin is decommissioned, renamed or reinstalled can never
  move on, and has no override yet. The web home's delete button does not apply the
  inbound hold that the control `sessions.delete` applies.
- Roster and Describe are not served across orchestrators. Remote roster rows show
  `running: true` and `exported_strands` as unavailable.
- A message queued to a session that is saved on its owner is refused `not_running`
  after the owner restarts (077 semantics), not delivered.
- The TUI does not render the `moving` and `moved` members of a session view. The
  source keeps a tombstone row, which lists as saved.
- The receiver identifies the sender by `from_node` through its `[orchestrators]`
  table, as claimed by the sender. Copies refused or abandoned stay in `incoming/`,
  and a failed rename of the moved-away file is not logged.
- `loomd executor release` leaves its own endpoint reservation behind, so `loom` may
  report "still starting" until the next daemon starts.
- On macOS, an executor started from a checkout looks for its code-mode seed under
  the workspace's `build/` by default, which is wrong there. Pass `--codemode-seed`.
- Remote sessions refuse extension tools, operator directory additions, background
  code mode and MCP facades.
- `remote/protocol` and `storage/exec_ledger` each keep their own `Key` and
  `CloseOutcome` types with mappers between them.
- Two recorded flakes: `daemon_shipped_remote_test`'s partition drill saw an
  `options_mismatch` at executor boot once, and the macOS gate's skip census flags two
  undeclared broker `/proc` skips. Both are filed as tasks.

## The Linux box

Owner-provided, used for every Linux and cross-host run: `sectional-falcon.exe.xyz`,
user `exedev` (uid 1000), x86_64, 2 cores, kernel 6.12, OTP 29.1.1 at
`/opt/erlang/29.1.1/bin`, gleam 1.19.0, go 1.27.1, bwrap 0.9.0, and docker (the user is
in the `docker` group). There is no Java and no P tool, so `make model-check` cannot run
there.

- Environment: `PATH=/opt/erlang/29.1.1/bin:$HOME/.local/bin:$PATH` and
  `ERL_FLAGS='+S 2:2'`.
- Keep checkouts and sockets outside `/tmp`. Each candidate goes to
  `~/loom-distributed-tests/<sha>/src` through `git archive` streamed over ssh, with
  `LOOM_TEST_SCRATCH=~/loom-distributed-tests/<sha>/sockets`.
- cgroups: `systemctl --user` runs and `user@1000` delegates `cpu memory pids`. Run each
  step in a fresh scope with a fresh name,
  `systemd-run --user --scope --unit=loom-crosshost-<step>-<sha>`. The recorded wrapper
  (`~/loom-distributed-tests/<sha>/inner.sh`, called by `run-step.sh` and `driver.sh`)
  creates `supervisor/` and `base/` inside its own scope, enables `+memory +pids`, and
  sets `LOOM_CGROUP_BASE=<scope>/base`. Without it the pids-limit selftest layer is
  skipped. Do not change global cgroups.
- Verify read-only first (ssh, `systemctl --user`, `/run/user/1000/bus`, toolchain,
  free space), then prepare the new candidate in its own directory and record its
  results beside the earlier ones.
- Cross-host: the box's ports sit behind the provider's proxy, so distribution needs
  ssh forwards. For a box executor, forward epmd and the executor's distribution port
  with `ssh -L` to an address the Mac's own epmd does not hold. For a box orchestrator,
  use `ssh -R` to loopback ports, with `ERL_EPMD_PORT` set on the box side. Section 5 of
  the setup guide has the commands. For a partition drill, kill the ssh process itself,
  not a wrapper shell.

## What to do next

1. Owner: authorize publishing `distributed/simplify` (push and PR). Then run the gated
   signoff (`LOOM_SIGNOFF_HOST=gilgamesh-signoff make signoff-remote`) and hosted CI on
   the exact head. Exit: both green on the PR's head.
2. Repeat the cross-host run on the published head, since the remote execution path
   changed after `193dbd8db`. Exit: both directions pass with the tunnel cut.
3. Close the cheap follow-ups above: the web delete hold, re-attach after an executor
   restart, an override for an imported session whose origin is gone, and the TUI's
   `moving`/`moved` rendering.
4. Failover and executor movement: design a store behind `session_directory` (Khepri)
   only when automatic failover is taken on.
