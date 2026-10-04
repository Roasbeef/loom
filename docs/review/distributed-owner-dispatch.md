# Joined remote native dispatch review

The owner adapter joins the original tool-child identity to the actual
physical operation and step, configured full scope and exact broker-cleared
command. It reserves an immutable outgoing envelope in the owner journal
before transmission and commits ordered binary output and terminal evidence
before acknowledging receipt. A changed token, policy, scope or command cannot
replace an existing child under the same identity.

The focused adapter suite passes thirteen SQLite tests. Independent review
found no actionable defect in identity binding, exact receipt verification or
cancellation fencing. The joined fixture then uses the actual owner custodian,
broker, pinned TLS transport, administrative registration, executor journal and
sandbox helper. It receives real stdout/stderr, compares exact evidence in both
journals, advances transport generation, stops and reopens the owner custodian,
and retries the original cleared request. The filesystem marker remains one
byte across both retries.

The root ran `bash scripts/e2e_remote_owner.sh` successfully, with its emulator
phase completing in 0.86 seconds. Registration-digest mismatch, broadened native
policy and altered full scope all refuse without their attempted filesystem
mutation. The script compiles the existing test PKIX fixture into a private
transient ebin directory and fails explicitly on missing prerequisites.

Two executable counterexamples demonstrate the joined assertions. The
`--mutation bypass-registration` mode accepts a command that must be refused,
so the expected failure assertion sees a real Completed result and exits 1.
The `--mutation skip-owner-receipt` mode falsely acknowledges publication;
the owner journal has no terminal receipt and the exact-evidence assertion
exits 1. Neither negative result is a compilation or setup failure.

A final independent adversarial review found no actionable issue in the joined
fixture or adapter. Its ordering conclusion combines the synchronous production
receipt path with the observed postcondition; this fixture does not force every
possible receipt-commit interleaving.

This runs local TLS and a real native helper in one emulator. It does not
prove cross-host deployment, power-loss durability, owner-runtime final report
recovery, remote workspace/code-mode/LSP assembly or native service supervision.
The remote service's explicit host lifetime is a subsequent assembly slice.
The final distributed acceptance still requires the shipped daemon to operate
against another host's checkout without an owner-local fallback.
