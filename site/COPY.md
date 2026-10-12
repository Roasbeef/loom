# Homepage copy decisions

The homepage leads with **A coding agent harness built to recover.** Its lede names durable terminal/browser sessions, sandboxed tools, branching and distributed execution. Gleam and the BEAM remain visible as the supporting identity line.

Recovery is scoped to committed work. The durability section links to the full two-commit crash figure and tool replay policy. It does not promise to recover arbitrary effects in flight. The sandbox section links to approvals and the platform enforcement details. The distributed section explains the conversation/execution split and explicitly says that automatic failover is unavailable.

Real existing web and terminal captures follow the hero, with captions and full-size image links. The terminal capture uses a scripted local provider; compilation, execution and reads are real. The interactive rename/test/move replay is labelled a scripted illustration and keeps both approval outcomes.

Build from source is the primary action while GitHub has no published archive release. The existing version remains only in clearly conditional archive examples; publication is tracked separately in `release.gleam`. Do not enable the download action merely because a tag or package version exists. The owner will choose and publish a release later.

The warm paper, amber woven mark, charcoal actions and serif typography remain. The site follows the system's light/dark preference. License: TBD remains unchanged.

## Claim sources on main

- `docs/architecture/orchestration.md` and `durability.md`: supervision, committed history and recovery.
- `docs/architecture/effects.md` and `docs/adr/006-macos-seatbelt-boundary.md`: tool isolation, kernel enforcement and macOS gaps.
- `docs/architecture/distributed.md`: orchestrators, executors, movement and limits.
- `docs/distribution.md` and `README.md`: stock Gleam source-build prerequisites and release workflow targets.
- `site/public/content/terminal-and-web.md`: the two clients, loopback listener and opt-in web view.
