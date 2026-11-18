//// A relayed page's Changes tab against a real repository, through the relay
//// (protocol-change/108, `108.worktree.1`).
////
//// The box is `support/feed_rig`: a real registry, a real `TopHost`, the real
//// stable endpoint and a real gateway for one relayed session. Its session
//// publishes the observation the daemon builds for its own page, which here is
//// `worktree_diff.capture_since` over a real Git repository through the
//// production broker and the jail (`support/worktree_wiring`). The laptop is the
//// production `top_relay` and the page's own read (`ui_socket.relayed_worktree_answer`),
//// so a change made in the repository is read by the page as the board its
//// Changes tab draws, with nothing between them restated.

import client/daemon/ui_socket
import client/relayed_session
import client/remote/top_relay
import client/remote_feed
import client/worktree_diff
import gleam/list
import gleam/result
import gleam/string
import support/feed_rig
import support/worktree_rig
import support/worktree_wiring
import web_view/worktrees

fn seen_by_the_page(rig: feed_rig.Rig, attached: remote_feed.Attached) {
  let relay =
    top_relay.through(fn(_name) { Ok(rig.peer) }, top_relay.production())
  ui_socket.relayed_worktree_answer(fn() { Ok(Nil) }, fn() {
    top_relay.worktree(relay, "box", attached)
  })
}

fn attach(rig: feed_rig.Rig) -> remote_feed.Attached {
  let relay =
    top_relay.through(fn(_name) { Ok(rig.peer) }, top_relay.production())
  let assert Ok(attached) =
    top_relay.attach(
      relay,
      "box",
      remote_feed.Attach(
        session: rig.session,
        principal: "page-1",
        name: "Laptop page",
      ),
    )
    as "the attach is admitted"
  attached
}

fn patch_of(read: worktrees.Read, path: String) -> String {
  let assert worktrees.Seen(board) = read
    as "the page was shown the box's board"
  let assert Ok(file) = list.find(board.files, fn(file) { file.path == path })
    as { "the board lists " <> path }
  file.patch
}

pub fn a_change_in_the_boxs_repository_is_the_relayed_pages_board_test() {
  use wiring <- worktree_wiring.with_fixture("relayed-changes")
  let root = worktree_rig.repository(wiring.workspace)
  let start = worktree_diff.starting_revision(wiring)
  let observe = fn() {
    worktree_diff.capture_since(wiring, start)
    |> result.map(worktree_diff.to_json)
    |> result.map_error(worktree_diff.error_message)
  }
  let rig =
    feed_rig.observing(
      "relayed-changes",
      feed_rig.deciding,
      remote_feed.lease_ms,
      relayed_session.Endpoint(..relayed_session.refusing(), worktree: observe),
    )
  let attached = attach(rig)

  // A clean tree has no file the agent changed.
  let assert worktrees.Seen(clean) = seen_by_the_page(rig, attached)
    as "a clean tree is a board"
  assert clean.repository == "head"
  assert !list.any(clean.files, fn(file) { file.path == "README" })

  // A change the agent's tools never reported, made in the workspace, is the
  // next board, and its patch is the repository's own text.
  worktree_rig.write(root <> "/README", "one\nchanged by a shell\n")
  let read = seen_by_the_page(rig, attached)
  assert string.contains(patch_of(read, "README"), "+changed by a shell")
}
