# Architecture decision records

One file per decision whose consequences outlive the change that made it,
numbered in the order the decisions were taken. Numbers are append-only:
an ADR is amended by an addendum inside it, never by a silent edit, and
never by renumbering. ADR-006's addendum on the Darwin enforcement demand
is the format precedent.

**008 is unused.** No ADR was ever written under that number, and nothing
in the tree cites `ADR-008`. The number was skipped by mistake and is left
skipped, because renumbering 009 and 010 down would break links that
already point at them.

**012 is used twice.** Two unrelated decisions were filed under that
number. Neither is renumbered, for the same reason.

**015 and 016 were drafted as 013 and 014.** The two language-server ADRs
were written on branches that opened before `main` filed its own 013 and
014. They took the next free numbers before they merged, so no merged
document ever cited them under the old ones.

## Index

- [001](001-agent-message-fidelity.md): AgentMessage mirrors pi's
  provider-message shapes.
- [002](002-sqlite-binding.md): SQLite binding: sqlight.
- [003](003-msgpack.md): msgpack for the framing protocol.
- [004](004-parrot-sql-codegen.md): adopt parrot for typed SQL, gated on a
  pilot.
- [005](005-budget-pooling-granularity.md): the pooled budget bounds the
  batch, not the call.
- [006](006-macos-seatbelt-boundary.md): macOS uses Seatbelt, with explicit
  lifecycle limits.
- [007](007-extension-tiers-and-brokered-egress.md): extensions run jailed by
  default and reach the network through the broker.
- [009](009-record-terminal-attempt-custody.md): record terminal attempts
  before replaying adoption.
- [010](010-retain-one-unsent-terminal-command.md): retain one unsent command
  during reconciliation.
- [011](011-bounded-websocket-forks.md): bound websocket frames in a fork of
  mist and gramps.
- [012](012-release-manifests-and-updates.md): verified release manifests and
  native updates.
- [012](012-responses-and-subscription-boundaries.md): keep Responses
  inference separate from Codex authentication.
- [013](013-tui-effects-as-values.md): the terminal's step returns its effects
  as values, and a runtime performs them (issue #530, phase 1).
- [014](014-second-runtime.md): one client engine drives two views, the
  terminal and a web view served by the daemon (issue #530, phase 4).
- [015](015-language-servers-as-jailed-leases.md): language servers run as
  jailed session leases, addressed by symbol (issue #25).
- [016](016-language-profiles.md): a language server is a profile, and
  profiles ship as extensions (issue #25).
- [017](017-executor-service-seam.md): the executor service sits at the
  execution, one per session, inside the broker package (issue #696).
- [018](018-go-helper-keeps-its-protocol-code.md): the Go helper keeps its
  protocol code, and the tag vocabulary is pinned by a test rather than
  generated (issue #696).
- [019](019-khepri-for-session-ownership.md): Khepri holds session ownership,
  and its members are the orchestrators and the executors (issue #697).
