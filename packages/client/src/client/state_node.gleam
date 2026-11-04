//// What a daemon holds for moving repository states (protocol-change/107).
////
//// A node that sends, receives or captures a state needs four things that are
//// started once, before any session is admitted, and read by several modules: the
//// endpoint of the one process that owns its store (`client/state_service`), a
//// read handle on the same directory for the sender that cuts pieces out of a
//// held state (`client/state_transfer.send`), the sandboxed Git that capture and
//// apply run through (`client/worktree_git`), and the paths and credential files
//// that Git's jail masks. The daemon starts them in `client/daemon/main` and hands
//// the record to the session assembly, the executor and the spawn host, so none
//// of them starts a second owner of the store or a second runner.
////
//// A node that moves no states holds `none`: an endpoint that declines every
//// piece, no store and no Git. Every user of the record treats the absent parts
//// as "this node cannot", and answers a refusal that says so.

import client/state_capture.{type Capturer}
import client/state_store.{type Store}
import client/state_transfer.{type Endpoint}
import client/worktree_git.{type Git}
import gleam/option.{type Option, None, Some}
import telemetry/log.{type Logger}

/// A node's means of moving states.
pub type StateNode {
  StateNode(
    /// The three answers a carrier gives for the node's store, over the process
    /// that owns it.
    endpoint: Endpoint,
    /// A handle on the store's directory for reading bundles out. A reader holds
    /// no lock: the store's files are written whole, and every write goes
    /// through `endpoint`.
    store: Option(Store),
    /// The sandboxed Git that capture and apply run through, or `None` on a node
    /// with no sandbox helper to run it with.
    git: Option(Git),
    /// The node's canonical state root, which the store lives under.
    state_root: String,
    /// The node's distribution key and cookie, which every jailed call masks.
    credentials: List(String),
    /// Where the node says that a state arrived and was placed. It carries no
    /// path of another machine and no bundle content.
    logger: Logger,
  )
}

/// The record of a node that moves no states.
///
/// ## Examples
///
/// ```gleam
/// assert state_node.none().git == option.None
/// ```
pub fn none() -> StateNode {
  StateNode(
    endpoint: state_transfer.declining(),
    store: None,
    git: None,
    state_root: "",
    credentials: [],
    logger: log.discard(),
  )
}

/// The node's means of capturing a workspace, or `None` when it has no Git to
/// run the capture with.
///
/// ## Examples
///
/// ```gleam
/// assert state_node.capturer(state_node.none()) == option.None
/// ```
pub fn capturer(node: StateNode) -> Option(Capturer) {
  case node.git {
    Some(git) ->
      Some(state_capture.new(
        git,
        node.state_root,
        node.credentials,
        node.endpoint,
      ))
    None -> None
  }
}
