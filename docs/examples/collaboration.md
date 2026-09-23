# A review with resident specialists and durable child steps

This example uses three open sessions. The coordinator runs
[`collaboration_review.gleam`](collaboration_review.gleam), which starts a
security child and a performance child under one named review run. Two other
sessions run [`specialist_exchange.gleam`](specialist_exchange.gleam) and send
findings to one another through owner-granted peer links. The code-mode
programs run in jailed satellites; their capability calls still pass through
the production broker and session runtime.

Build the helper and offline code-mode seed before starting the daemon:

```sh
make sandbox codemode-seed
make release
```

Start `loomd`, then create and open three sessions through the client protocol.
Keep their canonical IDs as `COORDINATOR`, `SECURITY`, and `PERFORMANCE`. The
daemon's owner token and control endpoint are described in
[client protocol §2](../client-protocol.md#2-connecting).
Use the owner credential for peer administration. Both specialist sessions must
remain resident; a peer send never opens a saved session.

## Grant the exchange

The owner sends these requests on the authenticated v2 control connection,
using the `epoch` from its `hello` event. The first link lets the security
session's `main` strand address the performance session's `main` strand. The
second grants the reverse direction. Each `busy_only` grant delivers while the
recipient already has an active run; select `may_wake` if a finding must start
an idle recipient run.

```json
{"v":2,"id":1,"cmd":"peers.link","body":{"source_session":"SECURITY","source_strand":"main","target_session":"PERFORMANCE","target_strand":"main","wake":"busy_only","epoch":"EPOCH"}}
{"v":2,"id":2,"cmd":"peers.link","body":{"source_session":"PERFORMANCE","source_strand":"main","target_session":"SECURITY","target_strand":"main","wake":"busy_only","epoch":"EPOCH"}}
```

The replies identify whether both halves of each link were installed. An
outgoing link alone is insufficient: the recipient checks its grant when it
commits the message and receipt. The model-facing `peer_roster` tool shows
outgoing links; the recipient's grant is independently revocable. Granting
one direction gives neither side authority to join or cancel the other
side's work.

## Launch and exchange findings

Submit the *contents* of `specialist_exchange.gleam` as the `program` in a
`code_mode` tool call with `mode: "launch"` in each specialist session. The
server's default host offers the peer capability in either code-mode seam. A
launch returns an execution handle before the satellite is necessarily ready.
Poll `check` until `readiness` is `ready` and `endpoints` contains `finding`:

```json
{"mode":"launch","seam":"workspace","program":"<contents of specialist_exchange.gleam>","within_ms":180000}
{"mode":"check","handle":"<security execution id>"}
```

Send typed inputs only after readiness. `session` is the recipient's canonical
session ID, and `message_id` is a stable retry key for that exact destination
and text. A second input from the other session completes the exchange:

```json
{"mode":"send","handle":"<security execution id>","endpoint":"finding","value":{"session":"PERFORMANCE","message_id":"review-42-security-1","text":"The authorization check is missing on the retry path."}}
{"mode":"send","handle":"<performance execution id>","endpoint":"finding","value":{"session":"SECURITY","message_id":"review-42-performance-1","text":"The retry also starts a second scan; I measured the duplicate work."}}
```

`send` confirms durable input admission to the local satellite's journal.
`check.latest_delivery` reports whether its typed callback succeeded or
rejected the value. The callback calls `peer.send`; the peer receipt then
proves that the target stored the message. The recipient's conversation entry
records the source session and strand as `PeerOrigin`. A receipt does not
prove that the recipient's model read the finding or completed its review.
`check.progress` reports the most recently published message ID and target;
progress can be coalesced or lost when the satellite ends.

To see the refusal path, omit the first grant and send a finding. The local
input is admitted, then `latest_delivery` reports `rejected`; the target has
neither a peer receipt nor a conversation entry. Add the exact grant and send
the finding again with a *new* message ID. A retry of a successfully delivered
message instead reuses its original ID and identical text.

## Run the durable review

Launch `collaboration_review.gleam` in the coordinator session and wait for its
`review` endpoint. Send the run name and the immutable input commit:

```json
{"mode":"launch","seam":"orchestration","program":"<contents of collaboration_review.gleam>","within_ms":180000}
{"mode":"send","handle":"<coordinator execution id>","endpoint":"review","value":{"run":"review-42","commit":"<commit SHA>"}}
```

The source calls `workflow.step` for `security` and `performance`, then joins
the two handles under one 30-second wait. `check.progress` first reports
`reviewing`, then `joined` with the count and text of completed child reports.
The named steps retain their original child operations and durable results even if the
coordinator satellite is lost. The progress snapshot and typed endpoint do not
survive that loss.

If the coordinator execution is lost, launch the same source again on the
same strand and send the same `run` and `commit`. Each `workflow.step` returns
the prior child's handle, so the second launch can join an existing result
without spawning a duplicate. Use a new step name for an intentional child
retry; changing `version`, `input` or an existing step's assignment under the
same run is refused. This recovery does not replay arbitrary filesystem
effects or restore an actor heap.

Use `mode: "cancel"` with each live execution handle when the exchange is
over. Cancellation closes input admission, aborts in-flight effects and drains
work owned by that execution. `mode: "join"` waits for terminal custody;
`mode: "check"` exposes the final record. If the execution ends by idle
timeout, the host records it as lost and reaps the satellite. The specialist
messages already committed to recipient sessions remain durable.

The integration tests read both `.gleam` files from this directory. They run
the specialist source in two real jailed satellites against separate session
stores, check refusals before each directional grant, route both findings,
inspect their structured peer origins, and wait for cancellation to settle.
The coordinator test runs its source in a jailed satellite too. It records two
completed children, loses the first execution, then starts a second execution
which joins the same results without admitting another child. Run the focused
checks with `bash scripts/test.sh client --match collaboration_example` after
preparing the helper and seed.
