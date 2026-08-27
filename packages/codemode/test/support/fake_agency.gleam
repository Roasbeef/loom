//// A scripted `tools/agent.Agency` for the orchestration-seam tests.
////
//// The Agency is a record of closures declared in `tools/agent` and
//// filled by whoever can see a live runtime — `client/agency` in
//// production. `codemode` can see the record but not the runtime, so the
//// tests on this side fill it themselves. That is the same arrangement
//// `support/satellite_peer` has with the jailed node and
//// `support/fake_helper` has with the jail: the seam under test is real
//// and the far side is scripted.
////
//// What these fakes prove and what they do not is worth stating, because
//// a fake Agency could easily be mistaken for a test of the
//// authorization model. It is not: descendant-only addressing, the depth
//// and fan-out caps, and the lineage ledger are `client/agency`'s, tested
//// against a live runtime in `client/test/client/agency_test.gleam` and
//// again through this seam in `client/test/client/codemode_test.gleam`.
//// What a scripted Agency proves here is the *carriage*: that a call
//// crosses the wire with the arguments the program gave it, that an
//// answer crosses back decoded into the right shape, and that a refusal
//// arrives under the name the Agency refused with.

import core/clock
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}
import tools/agent.{
  type Agency, type Caller, type Handle, type Refusal, type SpawnRequest,
  type Waited,
}

/// A fixed instant. The fakes mint ids rather than read time, so any
/// instant does; a real one would only make the ids harder to compare.
const t = 1_756_000_000_000

/// What a scripted Agency saw. Sent to a subject the test drains, which
/// is how a test asserts on the `Caller` a call was judged against
/// without the fake having to hold state.
pub type Seen {
  /// One `spawn`, with the caller it was judged against.
  SawSpawn(caller: Caller, request: SpawnRequest)
  /// One `wait`, with the handles it was given.
  SawWait(caller: Caller, handles: List(Handle), within_ms: Int)
  /// One `send`.
  SawSend(caller: Caller, to: String, text: String)
  /// One `note`.
  SawNote(caller: Caller, key: String, value: JsonValue)
  /// One `notes` read.
  SawNotes(caller: Caller, prefix: Option(String))
  /// One `roster` read.
  SawRoster(caller: Caller)
}

/// An Agency that admits every spawn, answers every join with `ready`,
/// and accepts everything else — recording what it saw into `into`.
///
/// `ready` is a function of the handle rather than a fixed answer so a
/// test can decide per child what came back; `always_completed` is the
/// ordinary one.
pub fn admitting(into: Subject(Seen), ready: fn(Handle) -> Waited) -> Agency {
  agent.Agency(
    spawn: fn(caller, request) {
      process.send(into, SawSpawn(caller:, request:))
      let handle = minted(caller, request)
      Ok(
        agent.Spawned(handle:, strand: handle.strand, tools: ["bash", "fs_read"]),
      )
    },
    wait: fn(caller, handles, within_ms) {
      process.send(into, SawWait(caller:, handles:, within_ms:))
      Ok(list.map(handles, ready))
    },
    send: fn(caller, to, text) {
      process.send(into, SawSend(caller:, to:, text:))
      Ok(agent.Steered(entry: entry_id(0)))
    },
    note: fn(caller, key, value) {
      process.send(into, SawNote(caller:, key:, value:))
      Ok(Nil)
    },
    notes: fn(caller, prefix) {
      process.send(into, SawNotes(caller:, prefix:))
      Ok([#("agent/main/note", json.String("kept"))])
    },
    roster: fn(caller) {
      process.send(into, SawRoster(caller:))
      Ok([
        agent.Peer(
          strand: "main",
          relation: agent.ParentOf,
          handle: option.None,
          outcome: option.None,
          tools: [],
        ),
      ])
    },
    max_wait_ms: 30_000,
  )
}

/// An Agency that refuses everything with `refusal`, so a test can watch
/// one refusal name travel the whole way to a program.
pub fn refusing(refusal: Refusal) -> Agency {
  agent.Agency(
    spawn: fn(_caller, _request) { Error(refusal) },
    wait: fn(_caller, _handles, _within_ms) { Error(refusal) },
    send: fn(_caller, _to, _text) { Error(refusal) },
    note: fn(_caller, _key, _value) { Error(refusal) },
    notes: fn(_caller, _prefix) { Error(refusal) },
    roster: fn(_caller) { Error(refusal) },
    max_wait_ms: 30_000,
  )
}

/// A join answer: the child completed, recorded `result`, and left no
/// notes.
pub fn completed_with(handle: Handle, result: agent.TerminalResult) -> Waited {
  agent.Ready(
    handle:,
    outcome: agent.Completed,
    report: "reviewed " <> handle.strand,
    result:,
    notes: [],
  )
}

/// A join answer for a child that asked for nothing and reported prose.
pub fn always_completed(handle: Handle) -> Waited {
  completed_with(handle, agent.NoResultAsked)
}

/// The child name a spawn mints, in the shape `client/agency.child_name`
/// mints it — the parent, the slugged purpose, and the call-site digest.
///
/// `codemode` cannot see `client`, so the concatenation is restated here;
/// the part that decides *identity* is not, because
/// `agent.call_site_digest` lives in `tools` and both sides call it. That
/// is deliberate. The previous version of this helper restated the
/// discriminating half too — the slugged step and the source index — and
/// so agreed with a derivation that could not tell two minters apart,
/// which is exactly the sort of agreement a fake should not be able to
/// reach on its own. The real derivation is pinned on the other side by
/// `client/test/client/agency_test.gleam`.
pub fn minted(caller: Caller, request: SpawnRequest) -> Handle {
  let assert Ok(slug) = agent.slug(request.purpose)
    as "a test purpose must slug"
  let name =
    "sub:"
    <> caller.strand
    <> "/"
    <> slug
    <> "-"
    <> agent.call_site_digest(caller)
  agent.Handle(strand: name, operation: op_id(ordinal_of(caller)))
}

// The fake's operation ids are per-spawn, so they have to vary with
// whatever varies per spawn. Within one execution that is the minter's
// ordinal; a caller minting as the tool call itself has only its source
// index.
fn ordinal_of(caller: Caller) -> Int {
  case caller.minter {
    agent.ToolCall -> caller.source_index
    agent.Program(ordinal:) -> ordinal
  }
}

/// A deterministic operation id, distinct per `seed`.
pub fn op_id(seed: Int) -> OpId {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: t), seed: seed + 1))
  op
}

fn entry_id(seed: Int) -> ids.EntryId {
  let #(entry, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: t), seed: seed + 1))
  entry
}

/// Everything the fake recorded, oldest first.
pub fn drain(into: Subject(Seen)) -> List(Seen) {
  drain_loop(into, [])
}

fn drain_loop(into: Subject(Seen), seen: List(Seen)) -> List(Seen) {
  case process.receive(into, 10) {
    Error(Nil) -> list.reverse(seen)
    Ok(one) -> drain_loop(into, [one, ..seen])
  }
}
