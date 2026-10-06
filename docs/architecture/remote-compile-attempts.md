# Two physical Compile attempts beneath one tool

A code-mode program can fail solely because Gleam reports unused imports. The
owner removes exactly those imports, vets the result again and builds once
more. Both builds use the same Build phase and original pooled deadline.
[Protocol 071](../../protocol-change/071-remote-compile-attempts.md) gives the two
physical compilations different immutable custody addresses.

The pipeline names its requests `Original` and `UnusedImportRewrite`. Original
retains the existing Compile and CompileCommand addresses and version-one key.
Rewrite uses two fixed additional addresses and a version-two key containing
the entire version-one predecessor. A checked constructor copies the parent,
scope, operation, step and enrollment digests. It admits a distinct UUID and
new input digest, and refuses a rewritten predecessor. An attempt therefore
cannot add a budget ledger or produce a third compilation.

The original owner actor reads its retained predecessor input and completion
before admitting Rewrite. The completion must be BuildRejected, and the shared
pure validator must derive exactly the new source under the same trusted vet
policy. Dependencies, policy limits, stage ceiling and enrollment remain exact;
generated modules are selected again from the fixed administrative catalogue.
The ordinary service reservation door refuses Rewrite. Storage independently
requires its predecessor and completion, while remaining independent of the
code-mode package.

The executor repeats the semantic check using its own resource journal. Its
resource writer also checks the committed predecessor failure on insertion and
historical row readback. Each physical Compile retains one immutable native
association. A successful artifact uses that attempt's UUID and input digest;
the first failed build remains available as history. Uncertainty has no
BuildRejected completion and cannot authorize the second attempt.

Launch selects the producer whose retained UUID matches the artifact among
exactly the Original and Rewrite addresses. The existing complete key, canonical
input, closed completion and exact artifact checks follow that selection. UUID
selection itself grants no authority. Historical reads recover the same
producer and cannot remint a service, command or live channel.

The owner can retain three fixed command offers for one tool: Original Compile,
Rewrite Compile and Satellite. Each remains charged against the configured
aggregate owner quotas. Collection includes the Rewrite child, so an outstanding
second build cannot disappear from the parent discharge checks.
