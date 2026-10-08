//// The session directory's replicated store is Khepri, over Ra
//// (protocol-change/079, ADR-019). Neither `gleam_stdlib`, `gleam_erlang`,
//// `gleam_otp` nor weft has a replicated store, so this module is the one
//// place the client calls into them. The Erlang side, `client_khepri_ffi.erl`,
//// normalizes every Khepri and Ra return to the shapes declared here, catches
//// exceptions at the boundary, and builds no atom from input: the Ra system,
//// the store name and the path components are literals or strings, and node
//// atoms come from the distribution membership made at boot.
////
//// Only `client/directory/store` imports this module. Every call here may
//// wait on a quorum, and Khepri's consistent read ignores its own timeout when
//// the majority is gone, so the store runs each call in a weft task under a
//// deadline of its own.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/node.{type Node}
import gleam/option.{type Option}

/// Why a read or a write did not give an answer, or gave a refusal.
pub type Failure {
  /// The command did not commit, or the fence did not complete, within its
  /// timeout. Its outcome may be unknown.
  NoQuorum

  /// The store is not running on this node.
  NotRunning

  /// The condition did not hold. Carries what the node holds now, or `None`
  /// when there is no node at the path.
  Mismatch(found: Option(Dynamic))
}

/// Whether a member of the Ra cluster votes.
pub type Voting {
  /// A voting member, counted toward the majority.
  Voter

  /// A member that receives the log but does not vote, such as one that
  /// joined and has not caught up yet.
  NonVoter
}

/// Starts the Khepri and Ra applications and the Ra system rooted at a data
/// directory. A system already running is success.
///
/// Ra `ra_system:start/1` over its default configuration with this name and
/// directory; Khepri's own start would create a system that always elects a
/// fresh server, and the non-voter join needs a server that does not.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.start_system("/home/op/.loom/directory") // -> Ok(Nil)
/// ```
@external(erlang, "client_khepri_ffi", "start_system")
pub fn start_system(directory: String) -> Result(Nil, String)

/// Stops the store and the Ra system.
///
/// Khepri `khepri:stop/1` and Ra `ra_system:stop/1`.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.stop_system() // -> Nil
/// ```
@external(erlang, "client_khepri_ffi", "stop_system")
pub fn stop_system() -> Nil

/// Starts the store: restarts a server Ra knows, or creates and elects a
/// one-member cluster when Ra knows none.
///
/// Khepri `khepri:start/3`.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.boot(10_000) // -> Ok(Nil)
/// ```
@external(erlang, "client_khepri_ffi", "boot")
pub fn boot(timeout_ms: Int) -> Result(Nil, String)

/// Joins the cluster through the member on `remote` as a promotable
/// non-voter, after the cluster forgets this member's old identity, and
/// returns once Ra has promoted it to a voter.
///
/// Ra `ra:start_server/2`, `ra:remove_member/3`, `ra:add_member/3` and
/// `ra:members_info/2`, then Khepri `khepri:start/3`; Khepri's own join adds a
/// voter at once.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.join(remote, 60_000) // -> Ok(Nil)
/// ```
@external(erlang, "client_khepri_ffi", "join")
pub fn join(remote: Node, timeout_ms: Int) -> Result(Nil, String)

/// Deletes this member's local server and its data. Only for a store that is
/// not joined.
///
/// Ra `ra:force_delete_server/2`.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.forget_local() // -> Nil
/// ```
@external(erlang, "client_khepri_ffi", "forget_local")
pub fn forget_local() -> Nil

/// Reads this member's own copy of a node's payload.
///
/// Khepri `khepri:get/3` with `favor => low_latency`.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.read(["loom", "sessions", id], 2000) // -> Ok(Some(payload))
/// ```
@external(erlang, "client_khepri_ffi", "read")
pub fn read(
  path: List(String),
  timeout_ms: Int,
) -> Result(Option(Dynamic), Failure)

/// Waits for this member's copy to hold everything the leader has committed,
/// then reads it.
///
/// Khepri `khepri:fence/2` followed by `khepri:get/3`.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.consistent(["loom", "sessions", id], 3000, 2000) // -> Ok(None)
/// ```
@external(erlang, "client_khepri_ffi", "consistent")
pub fn consistent(
  path: List(String),
  fence_ms: Int,
  timeout_ms: Int,
) -> Result(Option(Dynamic), Failure)

/// Creates a node, refusing when one exists.
///
/// Khepri `khepri:create/4`.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.create(path, value, 3000) // -> Ok(Nil)
/// ```
@external(erlang, "client_khepri_ffi", "create")
pub fn create(
  path: List(String),
  value: a,
  timeout_ms: Int,
) -> Result(Nil, Failure)

/// Replaces a node's payload only if it is exactly `expected`.
///
/// Khepri `khepri:compare_and_swap/5`.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.swap(path, expected, value, 3000) // -> Ok(Nil)
/// ```
@external(erlang, "client_khepri_ffi", "swap")
pub fn swap(
  path: List(String),
  expected: a,
  value: a,
  timeout_ms: Int,
) -> Result(Nil, Failure)

/// Deletes a node only if its payload is exactly `expected`.
///
/// Khepri `khepri_adv:delete/3` with an `if_data_matches` condition.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.delete_if(path, expected, 3000) // -> Ok(Nil)
/// ```
@external(erlang, "client_khepri_ffi", "delete_if")
pub fn delete_if(
  path: List(String),
  expected: a,
  timeout_ms: Int,
) -> Result(Nil, Failure)

/// Writes a node's payload unconditionally.
///
/// Khepri `khepri:put/4`.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.put(path, value, 3000) // -> Ok(Nil)
/// ```
@external(erlang, "client_khepri_ffi", "put")
pub fn put(
  path: List(String),
  value: a,
  timeout_ms: Int,
) -> Result(Nil, Failure)

/// Ra's members by node name with whether each votes, and the leader's node
/// name when there is one.
///
/// Ra `ra:members_info/2`.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.membership(2000) // -> Ok(#([#("a@h", Voter)], Some("a@h")))
/// ```
@external(erlang, "client_khepri_ffi", "membership")
pub fn membership(
  timeout_ms: Int,
) -> Result(#(List(#(String, Voting)), Option(String)), Failure)

/// The last log index this member has applied, or 0 when the store is not
/// running.
///
/// Ra `ra:member_overview/1`.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.applied_index() // -> 42
/// ```
@external(erlang, "client_khepri_ffi", "applied_index")
pub fn applied_index() -> Int

/// The log index of this member's latest snapshot, or 0 when it has none.
///
/// Ra `ra:member_overview/1`.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.snapshot_index() // -> 0
/// ```
@external(erlang, "client_khepri_ffi", "snapshot_index")
pub fn snapshot_index() -> Int

/// Whether the directory store answers on another node.
///
/// Ra `ra:members/2` addressed to that node's server.
///
/// ## Examples
///
/// ```gleam
/// ffi_khepri.store_running_on(node, 2000) // -> False
/// ```
@external(erlang, "client_khepri_ffi", "store_running_on")
pub fn store_running_on(node: Node, timeout_ms: Int) -> Bool
