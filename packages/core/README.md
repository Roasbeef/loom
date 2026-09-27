# core

`core` is the vocabulary every other package in Loom shares: the opaque
ids, the four write-once row shapes, the closed register-namespace set,
the transaction type, and the two codecs that guard every durability and
wire boundary. It is the root of the dependency graph: every other Gleam
package except the `lint` developer tool depends on it, and it depends on
`gleam_stdlib` and nothing else.

Two properties shape the whole package, and everything below is a
consequence of one of them.

> **It performs no I/O**, and that is structural rather than a convention:
> there is no `gleam_erlang`, no `gleam_otp`, no `simplifile`, and no FFI
> module. Time and randomness arrive as injected values.
>
> **Every decoder is total.** A decoder returns
> `Result(t, CorruptionReport)`. Wrong shapes, wrong types, and hostile
> input are reports; nothing here panics, and nothing here half-succeeds.

## What a decode boundary looks like

Durable bytes reach a caller through two total steps: a parser that turns
text or a byte string into plain data, and a codec that turns that data
into a typed value. Either step can refuse, and refusing always produces
the same thing — a `CorruptionReport`, which is itself plain data that can
be logged, stored, and sent across a process boundary.

```mermaid
flowchart TD
    B["a session-file blob,<br/>or a frame off the effect-plane wire"]
    P["core/json.parse<br/>core/msgpack.decode"]
    V["JsonValue / MsgPackValue<br/>plain, pattern-matchable data"]
    D["core/codec.decode_entry<br/>and every other total decoder"]
    OK["Ok(Entry)"]
    R["Error(CorruptionReport)<br/>boundary · subject · expected · context"]

    B --> P
    P -->|"well formed"| V
    P -->|"nesting past max_depth · duplicate key ·<br/>non-finite float · lone surrogate · trailing bytes"| R
    V --> D
    D -->|"every field present and well typed"| OK
    D -->|"missing field · wrong type ·<br/>unknown entry type · unknown namespace"| R
```

`decode_entry` is the representative case. It reads the placement fields
common to all four entry kinds, dispatches on the `type` string, and
returns a report for anything it does not recognise — the entry-kind set
is closed, so an unknown name is damage, not a value to skip:

```gleam
pub fn decode_entry(value: JsonValue) -> Result(Entry, CorruptionReport) {
  use fields <- result.try(fields_of(value, where))
  use id <- result.try(require_entry_id(fields, "id", where))
  use parent <- result.try(decode_parent(fields, where))
  ...
}
```

The shape matters as much as the totality. There is no "decode what you
can and carry on": a value is either fully constructed or it is a report,
because a partially decoded durable row is a bug that surfaces much later
and somewhere else.

### Bounded against hostile input

Both codecs are read by adversarial data — a provider response that ends
up in an entry, a frame from a sandboxed process — so the defences are
part of the contract rather than hardening added later.

- **Nesting is bounded** at `max_depth` (256) in both codecs. A thousand
  `[` characters is cheap to fabricate and would otherwise drive the
  parser into unbounded recursion.
- **Reports are bounded.** `corruption.report` truncates its `context`
  excerpt to `max_context_length` (256) graphemes, so a report derived
  from a multi-megabyte payload cannot bloat every log line that carries
  it.
- **Duplicate keys are corruption**, in JSON objects and msgpack maps
  alike. Decoders disagree on whether the first or last occurrence wins,
  so a document carrying duplicates has no single meaning; rejecting is
  the only rule with one interpretation.
- **Non-finite floats are corruption.** The BEAM cannot represent NaN or
  infinity, so a literal that would round to one is refused rather than
  silently changed.

The strictness applies to *our* boundaries. Third-party wire formats are
read leniently elsewhere, because strict decoding of a foreign vocabulary
breaks against real proxies and buys nothing. The line is ownership: data
Loom wrote must decode exactly as written, or it is damaged and we say so.

## Impurity is injected, never imported

Nothing in `core` reads a system clock or an entropy source. A `Clock` is
a value; reading it returns the time *and the clock to use next*, so a
fixture clock can step deterministically and a caller cannot accidentally
re-read the same instant twice without noticing it threaded nothing.

```gleam
pub fn read(clock: Clock) -> #(Int, Clock)
```

`ids.Generator` composes that clock with a seeded SplitMix64 state, and
mints the same way — value in, value out.

```mermaid
flowchart LR
    RT["the runtime<br/>a real time source, real entropy"] -->|"clock.from_function"| CK
    TS["a test<br/>a constant"] -->|"clock.fixed · clock.stepping"| CK["core/clock.Clock"]
    CK --> GEN["ids.generator(clock, seed:)"]
    GEN --> P1["an EntryId, plus the successor Generator"]
    P1 -.->|"thread the successor on"| GEN
    GEN --> DET["two generators built from the same clock and seed<br/>mint identical id sequences"]
```

Impurity belongs to whoever *built* the clock, which is why the runtime
can seed from real entropy while a test seeds from a constant and gets the
same ids every run.

## Ids that exist before their rows do

Every durable id — entry, usage row, operation — is a UUIDv7: 48 bits of
Unix-millisecond mint time, the version nibble, then randomness. Three
consequences are load-bearing.

The mint time reads back out of the id without touching storage. The
canonical lowercase text form sorts lexicographically in mint order, so an
id is a stable tiebreaker wherever rows are ordered by text. And an id can
be minted *before* the row it names exists, which is what lets a
transaction reserve an id for output that has not been produced yet — the
mechanism the whole effect sandwich is built on.

`EntryId`, `UsageId`, and `OpId` are distinct opaque wrappers over the
same shape, so an entry id can never be passed where an operation id
belongs. `SessionId` is a fourth wrapper that names a whole session
rather than a row in one: it exists before the session's first entry and
survives a rewrite that erases entries, so no row id can stand in for it
(`protocol-change/008`). Tool results are the one special case:

```mermaid
flowchart LR
    A["assistant EntryId<br/>ms = T"] -->|"ids.mint_follower(of:)"| R1["result EntryId<br/>ms = T, fresh random tail"]
    A --> R2["result EntryId<br/>ms = T, fresh random tail"]
    N["a slow tool settles<br/>in the next second — or the next day"] -.->|"has no effect on the prefix"| R2
```

A call-and-results group therefore stays contiguous under id order even
when a tool takes minutes to answer.

Ids are minted; `seq` is not. A `Seq` is assigned by storage at commit and
is strictly increasing within a session. Ids say when something was
created, seqs say in what order it became durable, and that is storage's
word alone.

## The durable vocabulary

**Entries** are the conversation tree, and there are four shapes:
`MessageEntry`, `CompactionEntry` (a self-contained checkpoint carrying
the complete retained suffix, so context assembly never reads past it),
`BranchSummaryEntry`, and `CustomEntry` (whose `custom_type` is
structural — branch queries filter on it without touching the payload).
Each carries its placement fields and its payload together, so a read
returns exactly what was committed with no materialization step.

**`UsageRow`** is the append-only cost ledger row.

**Registers** are the only mutable store, and the namespace set is closed:
`strand.leaf`, `strand.config`, `strand.state`, `strand.last_result`,
`op.meta`, `op.state`, `op.tool_args`, `op.preparation`, `pending.entry`,
`fact.name`, `fact.label`, `fact.custom`. Adding one is an interface
change. The *rich* payload types those namespaces force are orchestration
vocabulary and live in `machine`; `core` stores a `RegisterValue` — a thin
tagged wrapper around encoded JSON — so storage stays generic over
payloads it never has to understand. The single exception is
`strand.leaf`, whose `Option(EntryId)` payload `core` encodes and decodes
itself.

**`Tx`** is the unit of durability: an ordered `List(Write)` plus a list
of `SeqExpectation`s, applied all-or-none.

```gleam
pub type Write {
  InsertEntry(entry: Entry)
  InsertUsage(row: UsageRow)
  SetRegister(ns: RegisterNs, key: String, value: RegisterValue)
  DeleteRegister(ns: RegisterNs, key: String)
}
```

`CommitError` names four refusals, and the fourth is newer than the frozen
sketch. `LeaseLost(held_by:)` says the committer is no longer the
session's writer — the one refusal that no reload and no retry can get
past, which is exactly why it is a value rather than a string inside
`Faulted` (`protocol-change/005`). `tx.describe_lease_loss` is the single
place it is worded for humans, so every layer that has to flatten one into
prose says the same thing.

## The portable subset

`core` is one of four packages that lint rule R6 holds to a portable
subset; `machine`, `prompt` and `session_view` are the other three
(`lint/policy.portable_packages`). The rule forbids an `@external` of any
target, and it forbids `gleam_erlang` and `gleam_otp` both as imports and
as `gleam.toml` dependencies. R6 gates `make check` at error level, and
its census is zero. `core` meets it with room to spare, because its only
dependency is `gleam_stdlib`.

```mermaid
flowchart BT
    subgraph R6["held to the portable subset by lint R6"]
        CORE["core"]
        MACHINE["machine"]
        PROMPT["prompt"]
        SV["session_view"]
    end
    MACHINE --> CORE
    PROMPT --> CORE
    SV --> CORE
    SV --> MACHINE
    REST["storage, session, runtime, provider, broker, tools,<br/>client, tui and the other BEAM-only packages"] --> CORE
```

An arrow points from a package to one it depends on. The three packages
inside the box that depend on `core` can keep the rule only while `core`
does.

Two properties rest on the rule, and one `@external` would end both. The
first is testability: code that makes no foreign call and starts no
process can be checked by property tests over plain values. The second
is that the package compiles to Gleam's JavaScript target as well as to
Erlang. That is enough to *decide but not act*: a JavaScript host could
replay a conversation tree or validate a transcript with the same total
decoders the server uses, while every effect still goes through the
server. It does not mean the harness can run in a browser. `gleam_otp`
has no JavaScript target, Rule Zero is enforced by the kernel, and the
two-channel doctrine needs processes on both sides.
[`docs/gleam-style.md`](../../docs/gleam-style.md) Part IV §5 has the
whole argument.

No build or gate in the tree compiles `core` for JavaScript today; R6
keeps the precondition, the absence of externals, and nothing checks the
result. Compiling is also not the same as agreeing. A Gleam `Int` is a
JavaScript number on that target, so the 64-bit SplitMix64 arithmetic in
`core/ids` and the 64-bit integers in `core/msgpack` would need their own
check before a JavaScript host relied on them.

## The modules

| Module | What it holds |
|---|---|
| `core/ids` | `EntryId`/`UsageId`/`OpId`/`SessionId`, `Seq`, the injected UUIDv7 `Generator`, `mint_follower`. |
| `core/clock` | The injected time capability: `from_function`, `fixed`, `stepping`, `read`. |
| `core/entry` | The four `Entry` variants and `UsageRow`. |
| `core/register` | The closed `RegisterNs` set, `RegisterValue`, the leaf codec, `ns_to_string`/`parse_ns`. |
| `core/message` | The `AgentMessage` family, `Origin`, `StopReason`, `DeferredHandle`, `Usage`, and the `malformed_arguments` sentinel for tool-call arguments that never parsed. |
| `core/origin` | Validation, encoding, total decoding and display of a message's human or peer-agent `Origin` (`protocol-change/016` and `048`). |
| `core/tx` | `Write`, `Tx`, `SeqExpectation`, `CommitResult`, `CommitError`, `describe_lease_loss`. |
| `core/json` | A pattern-matchable JSON ADT with a total parser and serializer. |
| `core/codec` | Total JSON codecs for every durable core type, in pi's exact field vocabulary. |
| `core/msgpack` | The canonical msgpack subset the effect-plane framing protocol uses. |
| `core/json_wire` | Conversion between `JsonValue` and `MsgPackValue`, shared by code mode's satellite and host. |
| `core/corruption` | `CorruptionReport`, its bounding smart constructor, and `describe`. |
| `core/todo_list` | A strand's todo `Board`: the shape the `todo` tool writes, the blackboard stores and the TUI decodes. |
| `core/glance` | A strand's `Glance`, the operator-facing title and one-line summary the daemon writes under `client/glance/{strand}`. |

Paths are relative to `packages/core/src/`: `core/ids` is
`packages/core/src/core/ids.gleam`.

## Tests

`make check-core` is the package gate: `gleam format --check` over `src`
and `test`, a warning-free build, and the EUnit suite through
`scripts/test.sh`. `make test-core` runs the tests alone. The house lint
is a separate target, `make lint-core`, which also reads `gleam.toml` for
R6; the full `make check` runs the lint over the whole tree.

`test/core/` holds one test module per source module, with three
exceptions: `entry` and `message` are exercised through `codec_test`, and
`json_wire` has no test module in this package.
`test/support/generate.gleam` is a seeded SplitMix64 generator with a
value generator for every durable core type. `codec_test`, `json_test`,
`msgpack_test`, `ids_test` and `glance_test` draw from it, so a failing
round-trip property reproduces from its seed. `msgpack_test` also asserts
hand-computed golden byte sequences in both directions; the same vectors
live as files under `protocol/msgpack-fixtures/` for the Go helper's
conformance tests (ADR-003).

## Reading further

- [`CLAUDE.md`](CLAUDE.md): the reference doc for changing this code,
  with key types, real dependency edges, register and wire traffic, and
  the invariants that break things when violated. Read it before editing.
- [`docs/architecture/durability.md`](../../docs/architecture/durability.md):
  the plane this package is the foundation of, covering the three stores,
  identity, transactions and expectations.
- [`docs/adr/001-agent-message-fidelity.md`](../../docs/adr/001-agent-message-fidelity.md):
  why the message family mirrors pi's shapes field for field.
- [`docs/adr/003-msgpack.md`](../../docs/adr/003-msgpack.md): why the
  msgpack codec is self-contained pure Gleam.
- [`protocol-change/005-lease-lost-commit-error.md`](../../protocol-change/005-lease-lost-commit-error.md),
  [`008-canonical-session-id.md`](../../protocol-change/008-canonical-session-id.md)
  and [`016-record-human-origin.md`](../../protocol-change/016-record-human-origin.md):
  the three amendments to frozen `core` types described above.
- [`docs/gleam-style.md`](../../docs/gleam-style.md): Part IV is the
  policy this package is the strictest instance of, covering total
  decoders, no panics outside tests, FFI confinement, and in §5 the
  portable subset.
- [`packages/lint/src/lint/portable.gleam`](../lint/src/lint/portable.gleam):
  R6's module doc, which states what the portable subset protects and
  what it does not mean.
