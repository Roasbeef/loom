//// Stubs of children on other orchestrators, written into a session file for the
//// tests that read a closed session (protocol-change/084, phase 2).
////
//// A deleted parent owes each orchestrator that may hold a child a `Release`, and
//// a move is refused while a child may be running. Both read the parent's stubs
//// straight from its file, so the tests need a file that holds stubs without a
//// live session behind it. `write` opens the file as a session would, commits one
//// reserved cell for each stub under the prefix the Agency uses, and closes it.

import client/remote_child.{type State, type Stub, Placed, Stub}
import client/remote_spawn
import core/clock
import core/ids
import core/register
import core/tx
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import runtime/api
import session/session
import storage/storage
import tools/agent

fn an_op(seed: Int) -> ids.OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

/// A stub for `orchestrator` in `state`, distinguished by `seed`, so two stubs
/// of one test are two call sites.
///
/// ## Examples
///
/// ```gleam
/// let stub = remote_stubs.stub("box", 1, remote_child.Requested)
/// ```
pub fn stub(orchestrator: String, seed: Int, state: State) -> Stub {
  Stub(
    orchestrator:,
    strand: "main",
    site: remote_spawn.CallSite(
      operation: an_op(seed),
      step_id: "step-" <> string.inspect(seed),
      source_index: 0,
      minter: agent.ToolCall,
    ),
    depth: 0,
    parent_tools: ["agent_note", "agent_send", "bash"],
    request: remote_spawn.Request(
      purpose: "run the suite",
      brief: "Run make e2e.",
      model: None,
      tools: None,
      within_ms: None,
      result_schema: None,
      detach: remote_spawn.Detached,
    ),
    name: "sub:^main/run-the-suite-" <> string.inspect(seed),
    glance: None,
    owed: 0,
    state:,
  )
}

/// What an orchestrator answered when it started a child whose deadline falls at
/// `deadline_ms` on the session's clock.
///
/// ## Examples
///
/// ```gleam
/// let placed = remote_stubs.placed(1, 9_000_000_000_000)
/// ```
pub fn placed(seed: Int, deadline_ms: Int) -> remote_child.Placed {
  Placed(
    handle: agent.Handle(
      strand: "sub:^main/child-" <> string.inspect(seed),
      operation: an_op(seed + 100),
    ),
    tools: ["agent_note", "agent_send"],
    model: "cheap",
    model_id: "cheap-1",
    deadline_ms:,
  )
}

/// Writes each stub into the session file at `path` under the key its seed names,
/// and closes the file.
///
/// ## Examples
///
/// ```gleam
/// remote_stubs.write(path, [remote_stubs.stub("box", 1, remote_child.Requested)])
/// ```
pub fn write(path: String, stubs: List(Stub)) -> Nil {
  let assert Ok(opened) =
    session.open_sqlite(
      path:,
      owner: "stub-writer",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(at: 1000),
    )
    as "the session file opens"
  let writes =
    list.index_map(stubs, fn(stub, index) {
      tx.SetRegister(
        register.FactCustom,
        api.remote_child_fact_prefix <> string.inspect(index),
        register.value(remote_child.encode(stub)),
      )
    })
  let assert Ok(_) =
    storage.commit(opened.store, tx.Tx(writes:, expected: []))
    |> result.map_error(string.inspect)
    as "the stubs commit"
  let assert Ok(Nil) = session.close(opened) as "the session file closes"
  Nil
}
