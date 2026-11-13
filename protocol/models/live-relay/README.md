# Live session relay protocol model

A small [P](https://p-org.github.io/P/) model of the live session relay of
`protocol-change/108-live-session-relay.md`: the box's feed host with its numbered
queue, bound, lease and poll, the link between the laptop and the box, `ui_feed`
on the laptop, and a stop-and-wait lane. It checks that frames cross in one
order and at most once in each direction, that nothing crosses after a feed ends,
that a decision from the page reaches the hub only through its relayed door, and
that a partition shorter than the lease loses nothing.

The model is abstract. It has frames, pieces, polls, ticks and a bound, and no
envelope, no encoding and no session. The numbers (a lease of 10 ticks, a wait of
2, a bound of 3 frames and 4 bytes) are scaled down from the proposal's 15 s,
5 s, 512 frames and 1 MiB so the state space stays small. The properties depend
on the relations between them: a poll is held for less than the lease, a poll or
piece with no answer is repeated sooner than the lease ends, and a single frame
larger than the byte bound is admitted to an empty queue.

## Agreement with the code

The box half is built and the model follows it: `FeedHost` is
`client/remote/feed_host` with its pure parts `feed_queue`, `feed_pieces` and
`feed_filter`, and the laptop's lease, wait and cursor rules are the proposal's.
The laptop half, `ui_feed`, is not built when this model is written, so `UiFeed`
and `Lane` are modelled from the text of protocol-change/108 ("The laptop's socket
adapter" and "When the link drops"). Slice 3 builds `client/daemon/ui_feed` and must
keep this model and the code in agreement: a rule the code gives up, such as the
cursor that drops a frame numbered `after` or less or the piece resent only when its
answer was lost, fails a property here, and a rule the code adds must be added here
before the code relies on it. The tests that restate the box's rules over the real
modules are `feed_queue_test` and `feed_pieces_test`, with fixed seeds.

One difference is deliberate. The proposal admits a single frame larger than the byte
bound to an empty queue, and `tcOversize` models it. The code carries a frame only if
one answer can (1,044,480 bytes, which is below the 1,048,576-byte bound), so no frame
larger than the bound is ever admitted, and a frame too large for an answer lapses the
feed. A lapse is a case the model has, so the properties hold for the code's smaller
set of runs.

## What is modelled

| Machine | Stands for |
|---|---|
| `Gateway` (`PSrc/Gateway.p`) | The session's gateway, which writes replies and pushes to the feed host's sink in one order, accepts the lane frames the feed host forwards, and holds the hub. The hub has a relayed door, which the feed host calls for an approval, and a distinct local door, which is the box owner's own approve. |
| `FeedHost` (`PSrc/FeedHost.p`) | One feed host. A queue numbered from 1, bounded by a frame count and a byte count of unacknowledged frames, with an oversized single frame admitted to an empty queue. A lease measured in ticks. A poll with `after` drops the frames numbered `after` or less and answers the frames beyond it. A poll is held up to `wait` ticks, and a second poll releases the held one with an empty answer. A lapse when the bound or the lease is passed drops the queue and any partial frame, keeps the ended token for one more lease, and then forgets it, after which a poll is refused. Stopped and revoked endings. An idempotent detach. Pieces of a lane frame admitted in order, a repeated admitted piece answered again without effect, and a piece out of order or for a frame other than the next refused. The filter that forwards `CMD_FORWARD`, judges `CMD_APPROVE` through the relayed door, and answers `CMD_FORBID` itself. |
| `Link` (`PSrc/Link.p`) | The link, for poll answers and send answers in both directions. It loses requests and answers, duplicates them, delays them past a tick, and partitions until it heals. Losses, duplications and delays have a budget per case. |
| `UiFeed` (`PSrc/UiFeed.p`) | `ui_feed` on the laptop. One poll and one send in flight. It polls again with the same `after` after a timeout, ignores a frame numbered `after` or less, drops an answer for a poll no longer in flight, resends a piece whose admission answer was lost, and sends frame n + 1 only after every piece of n was admitted. A gap in the numbering ends the feed. |
| `Lane` (`PSrc/Lane.p`) | A stop-and-wait lane. It transmits one frame and waits for its reply. A reply that has not come at the deadline is an unknown outcome and the lane fails. |
| `Clock`, `Harness` (`PTst/Clock.p`) | The environment. A plan says which pushes, commands, partitions, page closes, stops and revocations happen at which tick. |

### Time

Time is logical. The `Clock` sends one tick to every machine at a time and waits
for every acknowledgement. Before and after a tick it runs `settle` flush rounds:
it sends a flush to every machine and waits for every acknowledgement. A machine
acknowledges only after it handled every message queued before the flush, and
whatever it sent meanwhile is queued before its acknowledgement. After `settle`
rounds a chain of at most `settle` messages has run to the end. A tick therefore
never overtakes a message in flight, so a lease or a deadline passes only because
time passed. This synchrony is what makes the liveness property meaningful. With
`settle` of 0 a tick may overtake messages, which `TestRacing` uses to check the
safety properties under adversarial timing.

## Specs

| Spec | Rule |
|---|---|
| `FeedOrderedAtMostOnce` | Every frame the gateway wrote reaches the lane at most once and in the gateway's order. The gateway frames delivered are the written frames with nothing skipped and nothing repeated, so with a lapse they are a prefix of the written frames. A gap in the box's numbering, which `ui_feed` reports, is a violation: an honest box never drops a frame the laptop did not acknowledge. A frame the feed host wrote itself is held to at most once. |
| `LaneFrameOnceWhole` | Every frame the lane transmitted reaches the gateway at most once and whole, with every piece admitted. |
| `NothingAfterEnd` | After a feed ends no frame of it reaches a lane. This is checked at the two places the end is visible: the feed host sends no frame once it has ended, and `ui_feed` delivers no frame from an answer that reports the feed ended. |
| `RelayedDoorOnly` | A decision reaches the hub only through the relayed door, and the feed host never calls the local door. A command outside the forwarding rows never reaches the gateway as a frame. The box owner's own approve uses the local door and is allowed. |
| `ShortPartitionLosesNothing` | Liveness. A case that announces a partition shorter than the lease, with the lane deadline above the longest recovery, must end with every written frame delivered. The monitor is hot while a written frame is undelivered, so a run that ends there fails. A lapse or a lane failure in such a run is reported, not excused. |

Frames of an answer the box sent before the feed ended may still arrive at the
laptop after it. They were written before the end, and `FeedOrderedAtMostOnce`
covers them. `NothingAfterEnd` does not forbid them.

P reports a violation of a liveness spec when a run ends with its monitor in the
hot state, so the liveness spec holds only because every fault in its case is
bounded.

## Test cases

| Case | Plan |
|---|---|
| `tcNormal` | No faults. Pushes of two sizes, one command of each kind, a command of two pieces, the owner approving at the local door, and the page closing. |
| `tcLossy` | The same traffic with requests and answers lost, answers duplicated and messages delayed past a tick. |
| `tcRacing` | The same with `settle` of 0, so ticks overtake messages. |
| `tcShortPartition` | A partition of four ticks, shorter than the lease, with pushes written inside it and a command sent before it. The liveness spec is checked. |
| `tcBoundLapse` | A partition during which four frames pass the frame bound, so the feed lapses and the poll after the heal learns it. |
| `tcOversize` | A frame larger than the byte bound goes to an empty queue and is delivered. |
| `tcByteLapse` | An oversized frame is unacknowledged and another frame passes the byte bound. |
| `tcLeaseLapse` | A partition longer than the lease and the ended token's second lease, so the poll that gets through is refused. |
| `tcStop`, `tcRevoke`, `tcDetach` | The session stops, access is revoked, and the page detaches twice, each with traffic in flight. |
| `tcApprovals`, `tcPieces` | Approvals and two-piece frames through a link that loses, duplicates and delays. |
| `tcOnly*` | One spec each, for `mutate.py`. |
| `tcProbe*` | Reachability probes. Each must fail. |

## Probes

The `tcProbe*` cases must fail: each finds a witness for a situation the specs are
only meaningful if the model reaches. They cover a lapse by the bound, by bytes
and by the lease, an oversized frame admitted to an empty queue, a superseded poll,
a repeated piece answered again, a forgotten token refused, a stopped, revoked and
detached feed, a decision through the relayed door, a two-piece frame reaching the
gateway, a lane that failed at its deadline, and a message lost to a partition.

## Mutants

`mutate.py` applies each mutant as exact text replacements, runs the test case
that names the rule, and requires the case to fail on that rule.

| Mutant | Violates |
|---|---|
| The queue empties when it answers a poll, before the laptop acknowledged the frames | `FeedOrderedAtMostOnce` |
| A repeated admitted piece is handed to the filter again | `LaneFrameOnceWhole` |
| A lapse keeps the queue and the poll that learns of it is answered with the frames | `NothingAfterEnd` |
| The feed host sends an `approve` to the hub's local door | `RelayedDoorOnly` |
| The lease is shorter than a partition the lane survives | `ShortPartitionLosesNothing` |

## What is not modelled

- The 105 envelope, discovery, the epoch and the revision checks. The fences that
  answer `stale` or `feed_ended` before the session is touched are one rule in the
  model: a request after the end is refused.
- The feed cap, the spawner, the table, `page` and the relayed row. One feed is
  attached for the whole run.
- A new attach after a feed ended. A lapsed page reconnects through 097 and starts
  from a fresh subscribe, which is always correct and is a new feed.
- The numbers in the proposal. The lease, wait, timeouts and bounds are scaled down,
  and `PollTimeout` and `SendTimeout` are fixed, with no backoff from 250 ms to 2 s.
- Byte sizes of frames and of answers. A frame has a size for the bound and
  nothing else. The envelope bound, the piece size of 393,216 bytes and the
  answer that carries one large frame alone are not modelled.
- A box answer a hostile or broken box would send: a non-JSON answer, a frame
  numbered backwards, frames for another token. The model's box is honest, and a
  gap is checked only as the sign of a box that dropped a frame.
- The contents of a decision. `Approve`, `Deny` and `Forget`, the ceiling, the
  canonical-path test and the sequence compare-and-set belong to `admit_relayed`
  and its tests. The model has the door a decision uses.
- The hub's answer to the page beyond the fact that the feed host writes a reply
  frame, and what the gateway does with an escalation record.
- `gateway.attached` counting a `PeerDoor` only when it decides.
- Strands, subagents, the advisor and remote children.
- The lane's 5 s refresh and its other deadlines. The lane has one deadline, for
  the reply to its one frame in flight.
- The history window, snapshot transfers and fragment rate.

## Running it

From this directory:

```sh
p compile
p check -tc tcNormal -s 1000
p check -tc tcShortPartition -s 1000
python3 mutate.py --check
```

`p check` with no `--max-steps` explores up to 10,000 unfair and 100,000 fair
steps per schedule, and a schedule of these cases takes about 6,000 steps. A case
of 1,000 schedules takes about two minutes. Running P from another directory
writes `PGenerated` and `PCheckerOutput` there, so run from this one.
