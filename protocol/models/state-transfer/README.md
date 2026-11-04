# State transfer protocol model

A small [P](https://p-org.github.io/P/) model of the resumable transfer of a
repository state in `protocol-change/107-state-transport.md` ("Send"), as
`client/state_transfer` and `client/state_store` build it: a sender that cuts a
held bundle into pieces and a receiver that appends them to a half-written file,
over a connection that drops, with either end restarting. It sits beside the
remote subagents model of 084 and is run by `make model-check`.

The code is the specification. Where the proposal and the code differ, the model
follows the code.

## What is modelled

| Machine | Stands for |
|---|---|
| `Sender` (`PSrc/Sender.p`) | `state_transfer.send` and the drainer that calls it again. A pass asks where the receiver stands, sends the piece at that offset, and continues at the offset each verdict reports. A pass that loses its connection, gives up or is cut off by a restart ends with no result, and the next poke begins another. |
| `Receiver` (`PSrc/Receiver.p`) | `state_transfer.take` and `stage` over `state_store`: a durable half-written file and a durable record. A piece at the end of the file is appended, a piece inside it is accepted again and not written, a piece beyond it is refused with the length held, and the last piece makes the state only if the bytes are the described bundle. |
| `Wire` (`PSrc/Wire.p`) | The network. One queue for each direction, delivered in any interleaving, lost whole when the connection breaks. |
| `Chaos`, `Harness` (`PTst/Tests.p`) | The environment: dropped connections, a restart of the receiver that may leave its half-written file shorter, a restart of the sender, and a pass that gives up while its request is in flight so that the next pass's requests follow the abandoned ones. When the faults are spent it pokes the sender on a quiet network. |

A bundle is a sequence of pieces, one element each, so an offset is an index. The
honest bundle is all ones, and a forged one has a zero in its last piece, which is
how a hash mismatch is told.

## What is checked

| Spec | Rule |
|---|---|
| `OnlyTheDescribedBytesAreStored` | A record names a state only if the bytes received are the described bundle. `state_store.finish` compares the size and SHA-256 before the record is written, and a mismatch discards the half-written file. |
| `PartIsAlwaysAPrefix` | The half-written file is always a prefix of the bundle, through drops, restarts and overlapping retries. |
| `DeliveredOnlyAfterStored` | The sender concludes `Delivered` only after a record names the state. |
| `EveryTransferEnds` | A transfer that begins ends, with the state held or refused for good. Bounded faults delay the end and cannot lose it. |

Four mutants (`mutate.py`) each reintroduce one bug and must be caught by the
spec that names it: a store that names forged bytes, a sender that takes the first
acceptance for delivery, a status that says complete for any bytes, and a restart
that invents a byte.

The `tcProbe*` cases must fail: each finds a witness that the model reaches a
situation the specs are only meaningful if it reaches. A pass resumed at a
non-zero offset, a restart shortened a non-empty file, and a forged bundle was
refused at its last piece.

## What the model leaves out

- **A second sender of the same state.** The model has one, as the design does:
  each state has one writer and one transfer drives it. With one sender and a
  connection that loses messages only by breaking, a repeated piece and a gap are
  both unreachable, because a status question queues behind every piece the
  abandoned pass left in flight, and a restart drops the connection with them.
  The receiver's repeat and gap arms, and the sender's following of a correction,
  are the defence against a second concurrent sender, and
  `packages/client/test/client/state_transfer_test.gleam` covers them against a
  real store. A probe for either found no witness at 2,000 schedules, which is
  why there is none here.
- **A record lost to a crash.** The record is taken as durable once the receiver
  has answered that it holds the whole state. In the code it is written by an atomic
  rename, which is not a flush, and `get` verifies it on every read, so a record
  lost to a crash is a state that is absent and is sent again. The model checks
  that nothing wrong is ever named, not that every record survives.
- **Sizes and caps.** The store's size limit and total cap are refusals decided
  before a byte is written and are tested against the real store.

## Running it

From this directory, with the P tool installed
(`dotnet tool install --global P`):

    p compile
    p check -tc tcAll -s 1000
    p check -tc tcProbeResumed -s 2000    # must find a bug
    python3 mutate.py --check
