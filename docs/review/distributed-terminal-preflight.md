# Terminal preflight review

The foreground satellite host now validates the transport header and scans the
terminal body before generic MessagePack allocation. The opaque raw envelope
preserves the original encoded body and reuses ordinary header validation.
A terminal preflight failure cannot fall back to an unbounded generic decode.
Ordinary capability traffic and persistent-host behavior retain their prior
semantic decoders.

## Independent evidence

The worker froze six source and test files under manifest digest
`538c914925591790c71e339f3ac7ef46da32ea733108459d0f868c3aeb8f911d`.
A separate Sol review accepted that exact slice without an actionable defect.
Its independent replay passed 185 core, 24 focused broker and 36 satellite
controls, plus twelve JavaScript scanner controls. Those counts describe the
review snapshot; root integration includes the later compiler-fingerprint fix.

An Erlang call trace provided the allocation-order witness. Its positive
control sent a 2,000,005-byte input to the generic decoder. The correct terminal
path made fifteen generic calls, all for header values at most 27 bytes. A
compiling ordering mutation made three large generic calls, up to 2,000,042
bytes, and failed the trace assertion even though its eventual error assertions
still passed. The worker also killed five compiling semantic mutations.

The scanner's JavaScript sibling loop now stays tail-recursive. The unchanged
generic JavaScript decoder still overflows its stack on a 70,000-sibling input;
that separate limitation is neither hidden nor repaired by this slice. Existing
unsafe-u64 JavaScript warnings remain. These controls do not prove remote Launch,
consumed-stream transport, or whole-system memory bounds.

The independent review report digest is
`b0c4417f7bff7495b20108a8f33fc8a45d0788428b1962c626eb07805310563e`.
Root's serial full package gate exited 0: 186 core, 440 broker and 429
code-mode tests passed. The broker suite explicitly skipped two Linux `/proc`
kill-evidence controls on macOS. The first offline-seed preparation failed
while fetching a Hex dependency inside the restricted shell; the separately
permissioned retry exited 0 before the code-mode gate. No skipped native
witness is counted as proven.
