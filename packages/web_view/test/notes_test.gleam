//// Notes reads use the real shared lane, while navigation remains local.
//// The board's strand and revision are checked before its text can be drawn.

import core/json
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/connection_event
import session_view/notes_view
import session_view/protocol
import session_view/session_channel
import web_view/component
import web_view/notes
import web_view/view/notes as notes_panel

fn board(strand: String, revision: Int) -> notes_view.Board {
  notes_view.Board(strand, revision, 4, [
    notes_view.Note(
      "plan",
      revision - 1,
      "{\"result\":\"<script>boom</script>\"}",
      notes_view.Complete,
    ),
    notes_view.Note(
      "prefix",
      revision,
      "\"literal excerpt\"",
      notes_view.Excerpt,
    ),
  ])
}

fn frame(id: Int, board: notes_view.Board) -> connection_event.Message {
  connection_event.Incoming(
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("reply_to", json.Int(id)),
        #("event", json.String("snapshot")),
        #(
          "body",
          json.Object([
            #("mode", json.String("notes")),
            #(
              "board",
              json.Object([
                #("strand", json.String(board.strand)),
                #("as_of", json.Int(board.as_of)),
                #("total", json.Int(board.total)),
                #(
                  "notes",
                  json.Array(
                    list.map(board.notes, fn(note) {
                      json.Object([
                        #("key", json.String(note.key)),
                        #("seq", json.Int(note.seq)),
                        #("text", json.String(note.text)),
                        #(
                          "extent",
                          json.String(case note.extent {
                            notes_view.Complete -> "complete"
                            notes_view.Excerpt -> "excerpt"
                          }),
                        ),
                      ])
                    }),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  )
}

fn press(model, action: notes.Press) {
  component.update(
    model,
    component.NotesPressed(component.strand(model), action),
  ).0
}

fn drawn(model) -> String {
  element.to_string(component.view(model))
}

pub fn notes_read_uses_lane_and_refusal_can_retry_test() {
  let wire = process.new_subject()
  let model = page_fixture.ready(wire, "observer")
  let asked =
    page_fixture.run(model, component.update, [
      component.NotesPressed("main", notes.Refresh),
    ])
  let assert [request] = page_fixture.sent(wire)
    as "Exactly one explicit notes read."
  assert string.contains(request, "\"cmd\":\"notes\"")
  assert string.contains(request, "\"strand\":\"main\"")
  assert component.notes_state(asked).read == notes.Waiting
  let refused =
    page_fixture.run(asked, component.update, [
      component.Arrived([page_fixture.refusal(page_fixture.request_id(request))]),
    ])
  assert component.notes_state(refused).read == notes.Unavailable
  assert string.contains(drawn(refused), "Notes unavailable")
  let again =
    page_fixture.run(refused, component.update, [
      component.NotesPressed("main", notes.Refresh),
    ])
  let assert [retry] = page_fixture.sent(wire) as "Retry sends one fresh read."
  let answered =
    page_fixture.run(again, component.update, [
      component.Arrived([
        frame(page_fixture.request_id(retry), board("main", 20)),
      ]),
    ])
  assert component.status(answered) == component.Connected
  assert component.notes_state(answered).read == notes.Ready
  assert component.notes_state(answered).board == Some(board("main", 20))
}

pub fn notes_focus_drops_scope_and_late_reply_test() {
  let wire = process.new_subject()
  let model = page_fixture.ready(wire, "observer")
  let model = component.apply(model, [lane_fixture.forked(None, [])])
  let shown =
    component.apply(model, [
      session_channel.Auxiliary(protocol.NotesSnapshot(board("main", 20))),
    ])
  let selected = press(shown, notes.Open("plan"))
  let searched =
    component.update(selected, component.NotesSearched("main", "plan")).0
  let other = component.update(searched, component.FocusRequested("advisor")).0
  assert component.notes_state(other).board == None
  assert component.notes_state(other).query == ""
  assert component.notes_state(other).selected == None
  let late =
    component.apply(other, [
      session_channel.Auxiliary(protocol.NotesSnapshot(board("main", 30))),
    ])
  assert component.notes_state(late) == component.notes_state(other)
  assert component.update(
      late,
      component.NotesPressed("main", notes.Open("plan")),
    ).0
    == late
  assert component.update(late, component.NotesSearched("main", "old")).0
    == late
}

pub fn notes_projection_raw_excerpt_and_injection_test() {
  let initial = notes.receive(notes.new(), "main", board("main", 20))
  let render = fn(state) {
    notes_panel.view(state, "main", fn(action) { action }, fn(_) { notes.Back })
    |> element.to_string
  }
  let index = render(initial)
  assert string.contains(index, "2 of 4 notes")
  assert string.contains(index, "2 omitted")
  assert string.contains(index, "snapshot rev 20")
  assert string.contains(index, "cell rev 19")
  assert !string.contains(index, "<script>")
  let detail = notes.press(initial, notes.Open("plan"))
  let raw = render(notes.press(detail, notes.ShowRaw))
  assert string.contains(raw, "&lt;script&gt;boom&lt;/script&gt;")
  assert string.contains(raw, "Raw value")
  let excerpt = render(notes.press(initial, notes.Open("prefix")))
  assert string.contains(excerpt, "Excerpt only")
  assert string.contains(excerpt, "&quot;literal excerpt&quot;")
  assert !string.contains(excerpt, "Raw value")
}

pub fn notes_search_back_refresh_and_numeric_identity_test() {
  let state = notes.receive(notes.new(), "main", board("main", 20))
  let state = notes.State(..state, query: "BOOM")
  let assert [match] = notes.rows(state) as "Search includes original content."
  assert match.key == "plan"
  let selected = notes.press(state, notes.Open("plan"))
  assert notes.press(selected, notes.Back).query == "BOOM"
  let replacement =
    notes_view.Board("main", 21, 1, [
      notes_view.Note("prefix", 21, "new", notes_view.Complete),
    ])
  let refreshed = notes.receive(selected, "main", replacement)
  assert refreshed.selected == None
  assert dict.get(refreshed.keys, "prefix") == dict.get(state.keys, "prefix")
  assert notes.receive(refreshed, "main", board("main", 20)) == refreshed
  assert notes.rows(notes.State(..refreshed, query: "absent")) == []
}

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: element.Element(message)) -> List(String)

pub fn notes_handler_paths_stay_confined_and_numeric_test() {
  let model =
    component.new(page_fixture.start())
    |> component.apply([
      session_channel.Auxiliary(protocol.NotesSnapshot(board("main", 20))),
    ])
  let keys = handlers(component.view(model))
  assert list.contains(keys, component.notes_path <> "\t0\t1\nclick")
  assert list.contains(keys, component.notes_search_path <> "\ninput")
  assert list.contains(keys, component.notes_path <> "\t2\t1\t0\t0\nclick")
  let searched =
    component.update(model, component.NotesSearched("main", "prefix")).0
  let filtered = handlers(component.view(searched))
  assert list.contains(filtered, component.notes_path <> "\t2\t1\t1\t0\nclick")
  assert !list.contains(filtered, component.notes_path <> "\t2\t1\t0\t0\nclick")
  let opened = press(model, notes.Open("plan"))
  assert list.contains(
    handlers(component.view(opened)),
    component.notes_path <> "\t3\t0\nclick",
  )
}

pub fn numeric_row_paths_never_reuse_a_departing_scope_test() {
  let main = notes.receive(notes.new(), "main", board("main", 20))
  let other = notes.receive(notes.clear(main), "advisor", board("advisor", 21))
  assert dict.get(main.keys, "plan") != dict.get(other.keys, "plan")
  let removed = notes.receive(main, "main", notes_view.Board("main", 22, 0, []))
  assert dict.size(removed.keys) == 0
  let returned = notes.receive(removed, "main", board("main", 23))
  assert dict.get(main.keys, "plan") != dict.get(returned.keys, "plan")
}

pub fn lost_notes_read_leaves_loading_and_reports_unavailable_test() {
  let wire = process.new_subject()
  let model = page_fixture.ready(wire, "observer")
  let asked =
    page_fixture.run(model, component.update, [
      component.NotesPressed("main", notes.Refresh),
    ])
  let lost =
    page_fixture.run(asked, component.update, [
      component.Arrived([connection_event.NetworkFault("offline")]),
    ])
  assert component.notes_state(lost).read == notes.Unavailable
  assert string.contains(drawn(lost), "Notes unavailable")
}

pub fn focusing_cancels_the_departing_strands_unsent_notes_read_test() {
  let wire = process.new_subject()
  let model =
    page_fixture.ready(wire, "observer")
    |> component.apply([lane_fixture.forked(None, [])])
  let busy =
    page_fixture.run(model, component.update, [
      component.ContextRefreshRequested,
    ])
  let assert [context] = page_fixture.sent(wire)
    as "A context read occupies the shared lane."
  let queued =
    page_fixture.run(busy, component.update, [
      component.NotesPressed("main", notes.Refresh),
    ])
  assert component.notes_state(queued).read == notes.Queued
  assert page_fixture.sent(wire) == []
  let focused =
    page_fixture.run(queued, component.update, [
      component.FocusRequested("advisor"),
    ])
  let _ = page_fixture.sent(wire)
  let released =
    page_fixture.run(focused, component.update, [
      component.Arrived([page_fixture.refusal(page_fixture.request_id(context))]),
    ])
  assert_no_departing_notes(released, wire, 8)
}

// The release can expose another ordinary side read. Check each actual write
// before refusing it, so a stale notes demand cannot hide behind that traffic.
fn assert_no_departing_notes(model, wire: page_fixture.Wire, left: Int) -> Nil {
  let frames = page_fixture.sent(wire)
  list.each(frames, fn(frame) {
    assert !{
      string.contains(frame, "\"cmd\":\"notes\"")
      && string.contains(frame, "\"strand\":\"main\"")
    }
  })
  case frames, left {
    [], _ | _, 0 -> Nil
    _, _ -> {
      let next =
        page_fixture.run(model, component.update, [
          component.Arrived(
            list.map(frames, fn(frame) {
              page_fixture.refusal(page_fixture.request_id(frame))
            }),
          ),
        ])
      assert_no_departing_notes(next, wire, left - 1)
    }
  }
}
