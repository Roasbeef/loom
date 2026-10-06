//// What the component's delivery costs, measured on Lustre's real runtime.
////
//// The simulator runs `update` and `view` and nothing else, so it cannot
//// show the two things this file is about. The first is how many renders a
//// burst of frames costs. Lustre 5.7.1 runs the view, diffs it and
//// broadcasts the patch for every message it takes, empty or not, so the
//// number of patches a registered client receives is the number of
//// messages the component handled. The selector drains the inbox behind the
//// frame it matched, so a burst already waiting is one message and one
//// patch. The second is the deadline timer: the component arms one timer
//// for the lane's next due reading, so a lane that has heard no push
//// refreshes a quarter of a second after its capture, and a lane that has
//// heard one waits `pushing_refresh_ms` and the page does no work in between.
////
//// A burst is made deterministic by suspending the component while the
//// frames are sent, which is the moment a burst reaches a busy component in
//// production: every frame is already in the mailbox when it next looks.

import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/otp/system
import gleam/string
import lustre
import lustre/server_component
import page_fixture
import session_view/connection_event
import session_view/session_channel
import session_view/snapshot
import web_view/component
import web_view/sessions

// A monotonic clock for the transport, as the daemon's relay supplies. A
// frozen clock would leave the lane never due at the timer's fire.
@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

fn now() -> Int {
  monotonic_time(atom.create("millisecond"))
}

type Page {
  Page(
    runtime: lustre.Runtime(component.Msg(Subject(String))),
    inbox: Subject(connection_event.Message),
    wire: Subject(String),
    renders: Subject(Int),
  )
}

// The size in bytes of the message the runtime hands a client, as its
// transport encodes it.
@external(erlang, "lane_memo_ffi", "wire_bytes")
fn wire_bytes(message: server_component.ClientMessage(message)) -> Int

// Starts a real server component whose transport hands the test the inbox
// it reads and the subject the open is answered on, and whose client is a
// callback that counts every patch the runtime broadcasts. The test answers
// the open on a wire it owns. It waits first, as a relay's attach does,
// because Lustre installs the selector for that answer only after `connect`
// returns and discards a message that arrives before it.
fn started() -> Page {
  let handed = process.new_subject()
  let wire = process.new_subject()
  let transport =
    component.Transport(
      connect: fn(inbox, opened) { process.send(handed, #(inbox, opened)) },
      transmit: fn(wire, frame) { process.send(wire, frame) },
      shut: fn(_) { Nil },
      now:,
      sessions: fn(deliver) { deliver([]) },
      activity: fn(_, _) { Nil },
      open: fn(_) { sessions.Declined(sessions.NotHeld) },
      resume: fn(_, _) { Nil },
      invite: None,
      home: None,
      rename: None,
      shareable: None,
      worktree: None,
      manage: None,
    )
  let start =
    component.Start(
      session_id: "A",
      label: None,
      workspace_digest: "",
      expected: snapshot.Expected("A", "epoch", "incarnation"),
      standing: component.unplaced,
      transport:,
    )
  let assert Ok(runtime) = lustre.start_server_component(component.app(), start)
  let assert Ok(#(inbox, opened)) = process.receive(handed, 1000)
  let renders = process.new_subject()
  lustre.send(
    runtime,
    server_component.register_callback(fn(message) {
      process.send(renders, wire_bytes(message))
    }),
  )
  process.sleep(50)
  process.send(opened, Ok(wire))
  let _ = settle(renders, 100)
  Page(runtime:, inbox:, wire:, renders:)
}

// How many patches arrived before the runtime went quiet for `quiet_ms`.
fn settle(renders: Subject(Int), quiet_ms: Int) -> Int {
  list.length(patches(renders, quiet_ms))
}

// The sizes, in bytes, of the patches that arrived before the runtime went
// quiet for `quiet_ms`, oldest first.
fn patches(renders: Subject(Int), quiet_ms: Int) -> List(Int) {
  case process.receive(renders, quiet_ms) {
    Ok(bytes) -> [bytes, ..patches(renders, quiet_ms)]
    Error(Nil) -> []
  }
}

// Delivers `frames` while the component is suspended, so all of them are in
// its mailbox when it resumes, and counts the patches they cost.
//
// The lane's idle refresh is a second out, and a slow run can reach it
// inside the window. A refresh is one render and one catch-up on the wire,
// so the renders it caused are taken back out and the count is the burst's
// alone.
fn burst(page: Page, frames: List(connection_event.Message)) -> Int {
  list.length(burst_patches(page, frames))
}

// `burst`, with the size of each patch the burst cost in place of their
// count.
fn burst_patches(
  page: Page,
  frames: List(connection_event.Message),
) -> List(Int) {
  let pid = server_component.pid(page.runtime)
  system.suspend(pid)
  list.each(frames, process.send(page.inbox, _))
  system.resume(pid)
  let sizes = patches(page.renders, 200)

  list.drop(sizes, catch_ups(written(page.wire, 0)))
}

fn delta(n: Int) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"event\":\"stream_delta\",\"body\":{\"strand\":\"main\",\"op\":\"o\",\"kind\":\"text\",\"text\":\""
    <> int.to_string(n)
    <> "\"}}",
  )
}

fn deltas(count: Int) -> List(connection_event.Message) {
  case count <= 0 {
    True -> []
    False -> list.append(deltas(count - 1), [delta(count)])
  }
}

// The frames the wire carried within `within_ms`, oldest first.
fn written(wire: Subject(String), within_ms: Int) -> List(String) {
  case process.receive(wire, within_ms) {
    Ok(frame) -> [frame, ..written(wire, within_ms)]
    Error(Nil) -> []
  }
}

fn catch_ups(frames: List(String)) -> Int {
  list.count(frames, string.contains(_, "\"cmd\":\"catch_up\""))
}

// Whether a frame is a read the shared step sent rather than one of the
// lane's own requests for a capture.
fn is_read(frame: String) -> Bool {
  !string.contains(frame, "\"cmd\":\"snapshot")
  && !string.contains(frame, "\"cmd\":\"subscribe\"")
  && !string.contains(frame, "\"cmd\":\"catch_up\"")
}

// Refuses each read the page writes, and the reads its refusals release,
// until it writes none, and returns every frame it wrote meanwhile. A first
// capture makes the step read the strand's notes and the session's context,
// and each read holds the lane's one command slot until it is answered, so a
// lane is idle only once they have been.
//
// After the last read the wire is watched for `last_ms` more, so a frame the
// lane's own timer sends shortly after is in the answer.
fn refusing(page: Page, last_ms: Int, seen: List(String)) -> List(String) {
  let frames = written(page.wire, 100)
  case list.filter(frames, is_read) {
    [] -> list.append(seen, list.append(frames, written(page.wire, last_ms)))
    reads -> {
      list.each(reads, fn(frame) {
        process.send(
          page.inbox,
          page_fixture.refusal(page_fixture.request_id(frame)),
        )
      })
      let _ = settle(page.renders, 100)
      refusing(page, last_ms, list.append(seen, frames))
    }
  }
}

// A page that has taken its first capture after hearing a push, so its lane
// is `Pushing`, its refresh is `pushing_refresh_ms` out, and nothing is in
// flight.
fn following_pushed() -> Page {
  let page = started()
  process.send(page.inbox, delta(0))
  list.each(page_fixture.transfer("observer", []), process.send(page.inbox, _))
  let _ = settle(page.renders, 200)
  let _ = refusing(page, 0, [])
  page
}

// The coalescing this component exists for: forty frames waiting in the
// mailbox are one message, so one view, one diff and one broadcast, and a
// burst longer than one batch costs one render per `arrival_batch` frames.
// A selector that took one frame per message would cost one per frame.
pub fn a_burst_costs_one_render_per_batch_test() {
  let page = following_pushed()
  assert burst(page, deltas(40)) == 1
  assert burst(page, deltas(150)) == 3
  assert component.arrival_batch == 64
}

// One sentence of a streaming answer, a blank line after every sixth so the
// answer is a run of paragraphs, as a stream delta of one request.
fn sentence(n: Int) -> connection_event.Message {
  let text = "Sentence " <> int.to_string(n) <> " of the answer, said. "
  let text = case n % 6 {
    0 -> text <> "\\n\\n"
    _ -> text
  }
  connection_event.Incoming(
    "{\"v\":2,\"event\":\"stream_delta\",\"body\":{\"strand\":\"main\",\"op\":\"o\",\"generation\":\"g\",\"kind\":\"text\",\"text\":\""
    <> text
    <> "\"}}",
  )
}

fn sentences(from: Int, to: Int) -> List(connection_event.Message) {
  int.range(from: from, to: to + 1, with: [], run: fn(acc, n) {
    [sentence(n), ..acc]
  })
  |> list.reverse
}

// A live answer costs its own patches and no more. Each burst of fragments
// is one message and so one patch, and the patch is the region's tail and
// not the page: it is the paragraph being written and a fixed envelope, a
// few hundred bytes however long the answer has become and whatever the
// page holds beneath it. This is what a page that drew every fragment into
// its own row, or reprojected the capture for each batch, could not say.
pub fn a_live_answer_costs_one_small_patch_per_burst_test() {
  let page = following_pushed()

  // The first burst opens the region: the answer's first paragraphs and the
  // region's envelope.
  let opening = burst_patches(page, sentences(1, 8))
  assert list.length(opening) == 1

  // Every burst after it is one patch of the paragraph being written.
  let later =
    list.map([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], fn(index) {
      burst_patches(page, sentences(index * 8 + 1, index * 8 + 8))
    })
  list.each(later, fn(sizes) {
    assert list.length(sizes) == 1
  })
  let assert Ok(largest) = list.reduce(list.flatten(later), int.max)
  assert largest < 1024
}

// One line of a streamed fenced block, as a stream delta of the same
// request. The fence opens with the first line.
fn code_line(n: Int) -> connection_event.Message {
  let opening = case n {
    1 -> "```\\n"
    _ -> ""
  }
  connection_event.Incoming(
    "{\"v\":2,\"event\":\"stream_delta\",\"body\":{\"strand\":\"main\",\"op\":\"o\",\"generation\":\"g\",\"kind\":\"text\",\"text\":\""
    <> opening
    <> "let value_"
    <> int.to_string(n)
    <> " = compute(input, "
    <> int.to_string(n)
    <> ")\\n\"}}",
  )
}

fn code_lines(from: Int, to: Int) -> List(connection_event.Message) {
  int.range(from: from, to: to + 1, with: [], run: fn(acc, n) {
    [code_line(n), ..acc]
  })
  |> list.reverse
}

// The integers from one to `last`, in order.
fn indexes(last: Int) -> List(Int) {
  int.range(from: 1, to: last + 1, with: [], run: fn(acc, n) { [n, ..acc] })
  |> list.reverse
}

// A streamed code block costs its new lines and no more. Each line of the
// fence is a keyed row, so a burst's patch adds the lines that arrived and
// leaves the ones already sent. A block drawn as one text node was sent
// whole on every burst, so the patch grew with the block: by the last burst
// below the block is over two hundred lines, several kilobytes, and the
// patch is still the size of eight lines and an envelope.
pub fn a_live_code_block_costs_its_new_lines_test() {
  let page = following_pushed()
  let opening = burst_patches(page, code_lines(1, 8))
  assert list.length(opening) == 1

  let later =
    list.map(indexes(26), fn(index) {
      burst_patches(page, code_lines(index * 8 + 1, index * 8 + 8))
    })
  list.each(later, fn(sizes) {
    assert list.length(sizes) == 1
  })
  let assert Ok(largest) = list.reduce(list.flatten(later), int.max)
  assert largest < 2048
}

// An idle page does no work between refreshes: with the lane pushing, the
// next refresh is `pushing_refresh_ms` away and no timer fires before it.
// Half that interval is still twice the polling interval, so a page that
// kept polling would render inside the window.
pub fn an_idle_pushing_page_renders_nothing_test() {
  let page = following_pushed()
  assert settle(page.renders, session_channel.pushing_refresh_ms / 2) == 0
  assert catch_ups(written(page.wire, 0)) == 0
}

// The deadline timer fires at the lane's next due reading and the tick acts
// there: a lane that has heard no push captures again a quarter of a second
// after its first capture, as the daemon that pushes nothing requires.
pub fn a_polling_lane_is_refreshed_by_its_deadline_timer_test() {
  let page = started()
  list.each(page_fixture.transfer("observer", []), process.send(page.inbox, _))
  let _ = settle(page.renders, 100)
  let frames = refusing(page, 600, [])
  assert catch_ups(frames) == 1
}
