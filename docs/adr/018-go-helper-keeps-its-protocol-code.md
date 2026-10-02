# ADR-018: the Go helper keeps its protocol code; the tag vocabulary is pinned by a test, not generated

**Status**: accepted · **Date**: 2026-10-02 · **Supersedes**: nothing ·
**Spec ref**: Part 1.4 (effect-plane wire, unchanged), Part 2 WP-H ·
**Issue**: #696 (S5)

## The question

Issue #696 ends with a decision rather than a deliverable: with the executor
service built in Gleam, should any of the helper's protocol or orchestration
code move out of Go? The issue requires the answer to be measured, by
prototyping a narrow slice and comparing lines removed against glue added,
failure semantics, performance, retained memory and native-test coverage. It
names keeping the Go server and stage 2 as an acceptable result.
[ADR-017](017-executor-service-seam.md) predicted the answer. This record
measures it.

## Measured

`loom-exec` has 8,788 lines of non-test Go. About 1,260 of them are protocol
and validation code with a Gleam twin: the frame codec, the strict policy
decoder, the 316-line server loop and part of `main`. A further 620 or so are
near-protocol vocabulary and state. The remaining roughly 6,900 lines are
kernel-facing: spawn, pumps, wait, kill, bwrap and Seatbelt, Landlock,
seccomp, cgroups and the self-test. Those cannot leave a native process under
Rule Zero and ADR-006. The S0 survey
(`docs/architecture/executor.md`, "The native side") has the per-file account.

Each of the four candidates for moving was examined against the code.

- **The frame codec.** Go is the peer that receives `exec_start` and `stdin`
  and sends `hello`, output and `exec_exit`. It must parse and build every frame
  whoever else does, so no lines would leave. A second implementation
  (`broker/framing`) already exists, and the golden fixtures under
  `protocol/msgpack-fixtures` pin the two together.
- **Policy validation.** Stage 2 re-reads the policy from fd 3 inside the
  jail's pre-exec process, and that re-read is the trust boundary into the
  target, so the strict decoder stays native. Even the 70-line encoder that
  re-sends the policy to stage 2 should stay. Forwarding the broker's bytes
  verbatim would move rejection of a malformed policy from an error frame
  before any process exists to a skip after bwrap has built namespaces, which
  is later and noisier.
- **The TERM-to-KILL ladder.** The ladder (`escalate.go`, 103 lines) must
  finish when the peer is dead or wedged. With its rungs on the wire, a helper
  whose broker died mid-cancel would hang, or would need its own ladder again.
  Moving it would also be a Part 1.4 change.
- **The server loop.** It owns the one-execution-at-a-time contract, the split
  between an execution being free and its cleanup being joined, and the reap
  on shutdown. Replacing it means a finer-grained RPC surface in both
  languages (spawn, write, signal, wait, report), which is larger than the 316
  lines it deletes and is itself a protocol change.

The one slice the design ruling judged worth prototyping was the enforcement
tag vocabulary. The helper emits hello features, applied layer tags and
`skip:` entries as string literals. The broker's required-layer checks match
the same strings, and nothing but tests keeps the two aligned. The prototype
(the three commits before the revert on this branch) put the vocabulary in one
TOML source. A generator rendered it into a Go constants file and a Gleam
module, a byte-compare gate wired wherever `prelude-check` runs, and both
sides' literals were replaced one for one. It worked: wire bytes were
unchanged, the self-test summary and the bench's enforcement fixture matched
the previous helper byte for byte, and renaming a tag became a compile error
on both sides. It added about 750 lines and a gate and removed none.

What it was meant to prevent had not happened. A census of both vocabularies
found zero spelling drift. Go emits 22 tags. The broker names 14 of them,
every one spelled as Go emits it. The eight Go-only tags (`rlimits`, `pgroup`,
`seccomp`, `platform-unsupported`, `stage2`, `network-proxy`,
`platform-restrictions`, `jail`) are ones the broker has no reason to read. The
incident usually cited for this class, issue #54, belongs to a different
class. A dead stage 2 produced a correctly spelled `[bwrap]` report with no
`skip:` entry, and silence satisfied full enforcement. Shared constants would
not have caught it. `enforcementEntries` on the Go side and `required_layers`
on the broker's side closed it, by treating a missing report as a skip.

Performance and memory do not enter. Nothing on the execution path changed in
either the prototype or the decision.

## Decision

**D1. No Go moves.** The codec, the policy decoder, the cancel ladder and the
server loop stay native, for the reasons above. ADR-017's reading that the Go
side holds no orchestration worth moving is confirmed by measurement.

**D2. The tag vocabulary stays spelled where it is emitted, and a broker test
pins it.** `enforcement_tags_test` reads the helper's jail sources as text, the
way `protocol_version_test` already reads `framing.go`. It asserts that every
tag the broker's layer checks name, and every prefix they parse, appears there
as a quoted literal. It takes the tag set from the broker's own layer
functions, so a tag the broker starts requiring is pinned without editing the
test. The generator, the TOML source, the generated modules and their gate are
reverted.

**D3. `skip:` gets one Gleam constant**, `exec.skip_prefix`, which replaces a
hard-coded prefix length. That was the one real improvement in the prototype.
Three other places in the tree spell `skip:` independently
(`codemode/enforcement.gleam`, `client/lsp/manager.gleam`,
`client/lsp/jail.gleam`). Moving them onto the constant is a follow-up, not a
gate.

## Consequences

The contract costs one test and a few milliseconds of file reads, with no new
generator, build target, CI step or Python dependency. A rename still fails
before merge, as a failing test rather than a compile error. The helper
leaves the epic with no protocol code removed. Its one change from this work,
the stdin queue that keeps a non-reading payload from stalling cancel, changes
behaviour and not the wire, and is recorded in `packages/sandbox/CLAUDE.md`. The eight Go-only tags, and the fact that the
broker treats a helper advertising `platform-unsupported` as degraded only
because the helper also advertises `degraded`, are recorded here as
properties of absence rather than defects. The pin proves a tag is spelled
somewhere in the jail sources, not at each emit site. A rename at a single
site can survive if another literal of the same spelling remains (for example
`exec.LookPath("bwrap")`), and the fixtures and the real-helper tests are what
catch emission.

## Alternatives considered

**Keep the generated contract.** Refused on the measurement: about 750 lines
and a gate guard against a drift that has never occurred, and the one incident
in the area would have passed it.

**A TOML source with a check but no call-site substitution.** Refused: the
source becomes a third spelling that nothing binds.

**Hand-written Gleam constants only.** Refused: the helper is the emitter, and
its literals would still be free.

## What would prove this wrong

Four events reopen this decision, and each is observable.

1. A tag-spelling drift reaches `main`, or is caught only by a real-helper
   run. That is the first incident of the class, and it reopens generation.
2. A second native emitter of the vocabulary appears. The microVM tier in
   `docs/design-notes/microvm-executor-tier.md` is the live candidate. A shared
   source then has two consumers and earns its cost.
3. The transport changes so that Gleam hosts the frame loop, through #697 or a
   later phase. The objection to moving the codec and the server loop is that
   Go is the peer, so both would be re-measured.
4. The shared vocabulary grows past about thirty tags, or a fourth Gleam module
   needs the whole set rather than the `skip:` prefix.
