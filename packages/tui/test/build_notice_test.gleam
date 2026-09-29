//// The build-mismatch notice compares the daemon's build with the build
//// this client read when its model was created.
////
//// The notice is redrawn on every coherent cut, and it used to read the
//// client's build from two environment variables each time. Those do not
//// change while the process runs, so phase 3 of issue #530 reads them once,
//// into `View.client_build`, and a cut reads no environment. These tests
//// set that field to a build of their choosing, adopt a daemon and apply a
//// real cut, so a comparison that went back to the environment would compare
//// against the wrong build and draw the wrong answer.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import host/build_identity
import session_view/session_channel
import session_view/snapshot
import tui/daemon/selection as daemon_selection
import tui/inbound
import tui/model as tui_model
import tui/runtime
import tui_test/pushed

// A daemon whose build differs from the one the model was created with is
// reported on the cut, and one that matches is not. The matching case is
// the one a per-cut environment read would get wrong: the environment names
// whatever build the test runner has, not the daemon's.
pub fn the_notice_compares_with_the_build_read_at_creation_test() {
  let owner: Subject(Dynamic) = process.new_subject()
  let host = host_with_build(owner, "9.9.9", "feedface")

  // Adopting the control connection compares the daemon's build with the
  // client's and leaves the notice in the session state, which is what a
  // cut reads; the connection and the client's build stay the terminal's.
  let differing = adopted(host, build_identity.Identity("1.0.0", "abc123"))
  assert differing.shared.build_notice != []
    as "the adopted daemon's mismatch is shared data"
  assert has_notice(captured(differing))
    as "a daemon on another build is reported"

  let matching = adopted(host, build_identity.Identity("9.9.9", "feedface"))
  assert !has_notice(captured(matching))
    as "a daemon on the model's own build is not reported"
}

// An attached model whose client build is `client_build`, after it adopts
// the control connection `host`.
fn adopted(
  host: daemon_selection.Host,
  client_build: build_identity.Identity,
) -> tui_model.Model {
  let base = pushed.attached()
  tui_model.Model(..base, view: tui_model.View(..base.view, client_build:))
  |> runtime.adopt_control(host)
}

// Applies the first cut of a real credited transfer, which is where the
// transcript, and the notice in it, is rebuilt.
fn captured(model: tui_model.Model) -> tui_model.Model {
  let lane =
    session_channel.replay(snapshot.Expected("A", "epoch", "incarnation"))
  let #(_, updates) =
    list.fold(
      pushed.transfer(1, "1:1", "recent", 10),
      #(lane, []),
      fn(acc, frame) {
        let #(lane, updates) = session_channel.receive(acc.0, frame, now: 0)
        #(lane, list.append(acc.1, updates))
      },
    )
  let assert Ok(session_channel.Captured(cut, view, _)) =
    list.find(updates, is_captured)
    as "premise: the transfer completes one cut"
  inbound.apply_channel_update(
    model,
    session_channel.Captured(cut, view, session_channel.Refreshed),
  )
}

fn is_captured(update: session_channel.Update) -> Bool {
  case update {
    session_channel.Captured(..) -> True
    _ -> False
  }
}

fn has_notice(model: tui_model.Model) -> Bool {
  list.any(model.shared.transcript, fn(line) {
    string.contains(line.text, "differs from this client's")
  })
}

@external(erlang, "build_notice_test_ffi", "host_with_build")
fn host_with_build(
  owner: Subject(Dynamic),
  version: String,
  commit: String,
) -> daemon_selection.Host
