# Original Launch stream and finite binding review

The stream and binding slices are committed as `4a29db8a` and `5559b4c3`.
The independent combined gate passed all 364 executor tests, with format and
warning-free build included. Executor lint reported zero errors and 39 warnings;
documentation checks reported zero errors and 184 warnings before this review
record was added. These are component results, not full product acceptance.

## Reviewed behavior

The review covered the frozen stream bridge, closed stream codec, finite Bind
route, real fixtures and their pinned owner/channel dependencies. All sixteen
source hashes, nine preseed baseline hashes and thirteen dependency pins were
checked. The final two-file reader-test update was checked against both its
predecessor and successor hashes. The root then ran the combined gate on those
exact final sources and imported only the owned files.

No correctness blocker was found. One optional simplification noted the unread
private `Sending.payload` and `Sending.offset` fields. They remain unchanged in
this integration; no memory reduction is claimed.

Finite binding authenticates the original peer, door and full binding before
installing the host once. Its control credit waits for bounded installation
and actual network drain, while socket acceptance and live traffic belong to
the bridge. Known installation with a lost answer remains uncertain for the
caller but can return the finite credit after drain. Uncertain installation
retains its assignment. Neither case grants another installation attempt.

The bridge keeps one reservation per direction, bounded chunks and a lifetime
byte allowance that includes frame prefixes. A chunk ACK cannot substitute for
original frame consumption. Close retains the original observed transport and
resource dispositions, including an authenticated close arriving before the
local caller asks to close. Native terminal history is not resource retirement.

## Controls and mutation evidence

Real two-node TLS fixtures compose Compile preparation, token placement, the
original Unix listener, finite binding and actual duplex frames. They exercise
blocked writes, exact directional lifetime exhaustion, original sender and
sequence checks, Final, cancellation and finite-credit reuse. The explicit
maximum-frame read is test-only and bounded independently of peer bytes.

Five compiling Bind mutations were killed: charging Data instead of Control,
sharing route four, accepting ordinary byte transfer, losing a definite-refusal
credit and refunding an uncertain-install credit. Four compiling stream mutations
were killed: omitting the original sender, omitting sequence matching, treating
a chunk ACK as consumption and treating Final as Continue.

The initial Final mutation survived because the owner reducer also stops on
Final. Absence of another owner frame therefore did not prove that the executor
reader stopped. The strengthened regression monitors the exact local original
reader before Final and requires its NormalDown before cancellation or close.
The test-only probe checks the frozen local record and closure shapes and sends
no callback across distribution. Correct code passes; the compiling mutation
fails at the original reader exit assertion.

## Limits

The fixtures exercise a real Unix peer and Compile preparation; they do not
establish a completed native satellite Launch through ordinary client assembly.
The owner consumer, associated-native retirement, default registered Compile/LSP
assembly, separate physical hosts and full repository/hosted gates remain open.
TransportJoined with ResourcesUnresolved is an expected retained outcome here.
The independent review and combined gate do not convert it into cleanup proof.
