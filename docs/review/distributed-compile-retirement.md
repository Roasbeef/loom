# Compile attempts and original Launch retirement

The October 6 integration implements the approved two-attempt Compile contract
and exact-helper Launch retirement. Protocol 071 and `85fa75c20` retain immutable
Original and UnusedImportRewrite inputs. The protocol-067 addendum, `23c6fabd9`
and `a57c907f0` add original borrowed-helper observation and executor cleanup.
The composed owner path in `81c7c83f7` requires both original observers to drain before
forwarding authenticated resource retirement.

## Contracts and review dispositions

Compile version 1 remains unchanged. Rewrite has one Original predecessor,
distinct service/native identities and deterministic source derived from the
retained rejected input. Owner and executor admission both validate that
predecessor before preparation. Neither attempt renews the parent deadline,
budget or grants. The owner permits the three fixed service offers needed for
Original, Rewrite and Launch. Launch accepts only the exact successful producer.
See [protocol 071](../../protocol-change/071-remote-compile-attempts.md).

Independent review identified a tautological ledger assertion. The replacement
observes the actual dispatched contexts and absolute deadlines. The full client
gate then exposed a production regression missed by that initial review: a
wrong Original producer UUID followed by an absent optional Rewrite was reported
as uncertain custody. The correction maps only that confirmed optional absence
to definite refusal before Launch reservation. Other storage errors remain
uncertain. The same reviewer checked both corrections.

Launch installs the exact pool observer before dispatch and permanently removes
that borrowed helper from reuse. Positive proof requires the existing native
retirement boundary and the original helper-owner normal exit. The native row
retains that proof independently of adapter lifetime. At most two confirmation
attempts share the original effect deadline plus six seconds; actual report
drain precedes retry or promotion. Compile and ordinary native work retain reuse.
See [the retirement architecture](../architecture/launch-native-retirement.md).

Review found one alternate notification path through scope closure that could
bypass the per-Launch deadline and repeat notification. Removing that new path
leaves one bounded promotion path. Existing scope retirement keeps its separate
meaning. The same reviewer checked the correction and found no remaining source
blocker in that packet.

Actual composition exposed a second gap: the owner observer discarded the
bridge's resource proof unconditionally. The correction forwards that original
authenticated value only after both observers report actual drainage. Lost
observers remain unresolved. Transport and capability drainage remain independent
requirements downstream. A bounded review checked this projection and the
composed controls without repeating the earlier whole-component review.

## Execution evidence

The root compared all 59 final source paths between the integration checkout and
the independent verification checkout; every byte matched before documentation
updates. Independent complete gates passed core with 189 tests and JavaScript
checks, storage with 224, code mode with 483, broker with 444 and the combined
executor with 370. The final combined client gate passed all 3,084 tests with
its own exit status zero. Fifteen explicit optional controls remain skipped:
one Linux `/proc` witness, thirteen shipped-server controls and one
rust-analyzer control.

Final formatting, all six changed-package lint targets, documentation and
prelude checks passed with exit zero. Documentation reported 186 warnings and
zero errors. An initial static invocation used an invalid relocated runtime
path; its failed exit is preserved separately from the corrected invocation.

Five compiling Compile mutants failed runtime assertions: nested rewrite keys,
generic owner rewrite admission, changed rewrite source, deadline renewal and
the three-offer boundary. Two compiling retirement mutants also failed: native
proof published before the original owner boundary, and retaining the adapter
row after its loss. These are targeted checks, not exhaustive fault coverage.

The real executor control completes three Launches through one active slot and
checks original joins, retained association and directory removal. Other controls
cover a foreign actual pool, lost registration acknowledgement, adapter death,
confirmation-worker death and overlapping scope closure. Composed owner controls
pass both Original and Rewrite builds through real satellite capability traffic.
They require Released from the exact retained Launch input, matching producer
and canonical paths, native/outer receipts, and absence of directory, socket and
token. Scope loss and uncertain clearance continue to retain unresolved custody.

Earlier red results remain part of the record. Two root client runs failed in
unchanged SQLite shutdown and Git initialization controls respectively; their
focused reruns passed. A worker executor run lost a drain report in the real
finite BEAM test; the independent combined executor gate later passed that same
control without weakening it. Host load was observed, but these results do not
prove a load-related cause or justify a blanket flake classification.

## Limits

The retirement grade is the existing platform-dependent scoped native grade.
No stronger descendant-containment claim follows. Parked startup acknowledgement
loss is checked through source ordering and the existing managed-child contract;
retiring relay death has no separate new runtime experiment. Missing witnesses
continue to hold custody and capacity.

Full repository gates, ordinary registered daemon assembly, remote LSP,
separate-host acceptance and hosted CI remain open. Cross-node orchestrator
ownership, durable messaging and controlled movement remain required by issue
#697. Component review and these execution controls do not complete that issue.
