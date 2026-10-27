//// Managing peer links from an owner's page (protocol-change/077).
////
//// What these tests read is what the page draws and asks. An owner's page
//// lists the focused strand's links as `this › target` rows with the marks, and
//// draws every name and strand as a text node. Link asks the daemon for the
//// chosen session, strand, wake permission and the Both directions choice, and
//// only from the form; Unlink of a two-way pair offers each direction or both.
//// A page with no capability draws nothing and asks nothing whatever message
//// reaches it, and the section sits at `component.peers_path`.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lane_fixture
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import web_view/component
import web_view/operator_page
import web_view/peer_links.{
  type Row, Board, BothWays, BusyOnly, Default, Granted, Incoming, MayWake,
  OneWay, Outgoing, Row,
}
import web_view/sessions.{Entry, Live}

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn page(
  capable: Bool,
  asked: Subject(peer_links.Request),
) -> component.Model(page_fixture.Wire) {
  let start = page_fixture.start()
  component.Start(
    ..start,
    transport: component.Transport(..start.transport, peers: case capable {
      True ->
        Some(fn(request, deliver) {
          process.send(asked, request)
          case request {
            peer_links.Read(strand) ->
              deliver(peer_links.Listed(Board(strand, [], peer_links.AllShown)))
            peer_links.Link(..) | peer_links.Unlink(..) ->
              deliver(peer_links.Changed(peer_links.Complete))
          }
        })
      False -> None
    }),
  )
  |> component.new
  |> component.apply([lane_fixture.captured(10, None)])
}

fn deliver(
  model: component.Model(page_fixture.Wire),
  message: operator_page.Msg(page_fixture.Wire),
) -> component.Model(page_fixture.Wire) {
  let #(model, effects) = operator_page.update(model, message)
  let dispatched = process.new_subject()
  effect.perform(
    effects,
    fn(next) { process.send(dispatched, next) },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  case process.receive(dispatched, 0) {
    Ok(next) -> deliver(model, next)
    Error(Nil) -> model
  }
}

fn drawn(model: component.Model(page_fixture.Wire)) -> String {
  element.to_string(operator_page.view(model))
}

// Only the peer-link section, since the page's sidebar lists the same sessions.
fn section(model: component.Model(page_fixture.Wire)) -> String {
  case string.split_once(drawn(model), "aria-label=\"Peer links\"") {
    Ok(#(_, rest)) -> rest
    Error(Nil) -> ""
  }
}

fn listed(
  model: component.Model(page_fixture.Wire),
  rows: List(peer_links.Row),
) -> component.Model(page_fixture.Wire) {
  let model =
    deliver(
      model,
      operator_page.Observed(
        component.SessionsListed([
          Entry("A", "this one", "/src/loom", 100, Live, None, None, None, None),
          Entry(
            "B",
            "review <b>auth</b>",
            "/src/loom",
            50,
            Live,
            None,
            None,
            None,
            None,
          ),
          Entry(
            "C",
            "saved one",
            "/src/loom",
            20,
            sessions.Saved,
            None,
            None,
            None,
            None,
          ),
        ]),
      ),
    )
  deliver(
    model,
    operator_page.Observed(
      component.PeersAnswered(
        peer_links.Listed(Board("main", rows, peer_links.AllShown)),
      ),
    ),
  )
}

fn out(session: String, strand: String) -> Row {
  Row(Outgoing, session, "review <b>auth</b>", strand, Some(MayWake), Granted)
}

fn back(session: String, strand: String) -> Row {
  Row(Incoming, session, "review <b>auth</b>", strand, Some(BusyOnly), Default)
}

// The next change the page asked for, skipping the reads it makes after one.
fn change(
  asked: Subject(peer_links.Request),
) -> Result(peer_links.Request, Nil) {
  case process.receive(asked, 0) {
    Ok(peer_links.Read(_)) -> change(asked)
    other -> result.replace_error(other, Nil)
  }
}

fn peer_handlers(model: component.Model(page_fixture.Wire)) -> List(String) {
  handlers(operator_page.view(model))
  |> list.filter(fn(key) { string.starts_with(key, component.peers_path) })
}

pub fn an_owners_page_lists_rows_with_their_marks_as_text_test() {
  let model =
    listed(page(True, process.new_subject()), [
      out("B", "main"),
      back("B", "main"),
    ])
  let html = drawn(model)
  assert string.contains(html, "aria-label=\"Peer links\"")
  assert string.contains(html, "main › review &lt;b&gt;auth&lt;/b&gt; / main")
  assert string.contains(html, "review &lt;b&gt;auth&lt;/b&gt; / main › main")
  assert !string.contains(html, "<b>auth</b>")
  assert string.contains(html, " · may wake")
  assert string.contains(html, " · default")
}

pub fn an_empty_board_says_so_and_an_unread_one_says_that_test() {
  let model = page(True, process.new_subject())
  assert string.contains(drawn(model), "not read yet")
  assert string.contains(
    drawn(listed(model, [])),
    "No links from or to this strand.",
  )
}

pub fn the_section_is_the_session_panes_last_child_at_its_path_test() {
  let model = listed(page(True, process.new_subject()), [out("B", "main")])
  let keys = peer_handlers(model)
  assert keys != []
  assert list.all(keys, fn(key) {
    key == component.peers_path
    || string.starts_with(key, component.peers_path <> "\t")
  })
  // The paths of the other controls did not move.
  assert list.all(handlers(operator_page.view(model)), fn(key) {
    key != component.remembered_path
  })
}

pub fn a_page_with_no_capability_draws_nothing_and_asks_nothing_test() {
  let asked = process.new_subject()
  let model = page(False, asked)
  let model = listed(model, [out("B", "main")])
  assert !string.contains(drawn(model), "Peer links")
  assert peer_handlers(model) == []
  let model = deliver(model, operator_page.Peering(peer_links.OpenLink))
  let model =
    deliver(
      model,
      operator_page.Peering(peer_links.AskUnlink(out("B", "main"))),
    )
  let model = deliver(model, operator_page.Linking("main"))
  assert !string.contains(drawn(model), "Peer links")
  assert process.receive(asked, 0) == Error(Nil)
}

// A session the focused strand already sends to, in any strand, by a grant or
// by the default link, is not offered: the board says so and the form follows it.
pub fn a_session_already_linked_is_not_offered_by_the_form_test() {
  let asked = process.new_subject()
  let model = listed(page(True, asked), [out("B", "main")])
  let model = deliver(model, operator_page.Peering(peer_links.OpenLink))
  let html = section(model)

  assert !string.contains(html, "auth&lt;/b&gt;</button>")
  assert string.contains(html, "Every other running session is already linked.")

  // A link into another strand of the same session hides it as well.
  let other = listed(page(True, asked), [out("B", "worker")])
  let other = deliver(other, operator_page.Peering(peer_links.OpenLink))
  assert !string.contains(section(other), "auth&lt;/b&gt;</button>")
  assert string.contains(
    section(other),
    "Every other running session is already linked.",
  )
}

pub fn the_link_form_asks_for_the_chosen_session_wake_and_both_directions_test() {
  let asked = process.new_subject()
  let model = listed(page(True, asked), [])
  let model = deliver(model, operator_page.Peering(peer_links.OpenLink))

  // Only running sessions other than this page's own are offered.
  let html = section(model)
  assert string.contains(html, "Link to which session?")
  assert string.contains(html, "review &lt;b&gt;auth&lt;/b&gt;")
  assert !string.contains(html, "saved one")
  assert !string.contains(html, "this one</button>")

  // A session the page does not list as running cannot be chosen.
  let refused =
    deliver(model, operator_page.Peering(peer_links.PickSession("C", "x")))
  assert string.contains(drawn(refused), "Link to which session?")
  let model =
    deliver(model, operator_page.Peering(peer_links.PickSession("B", "x")))
  let model =
    deliver(model, operator_page.Peering(peer_links.ChooseWake(MayWake)))
  let model =
    deliver(model, operator_page.Peering(peer_links.ChooseReverse(BothWays)))
  let html = drawn(model)
  assert string.contains(html, "Link main to review &lt;b&gt;auth&lt;/b&gt;")
  assert string.contains(html, "aria-pressed=\"true\"")
  assert string.contains(html, "value=\"main\"")
  assert process.receive(asked, 0) == Error(Nil)

  let model = deliver(model, operator_page.Linking("reviewer"))
  let assert Ok(peer_links.Link("main", "B", "reviewer", MayWake, BothWays)) =
    change(asked)
  assert string.contains(drawn(model), "Done.")
}

pub fn a_link_defaults_to_busy_only_one_way_test() {
  let asked = process.new_subject()
  let model = listed(page(True, asked), [])
  let model = deliver(model, operator_page.Peering(peer_links.OpenLink))
  let model =
    deliver(model, operator_page.Peering(peer_links.PickSession("B", "x")))
  let _ = deliver(model, operator_page.Linking("main"))
  let assert Ok(peer_links.Link("main", "B", "main", BusyOnly, OneWay)) =
    change(asked)
}

pub fn a_blank_or_control_strand_is_refused_before_it_is_sent_test() {
  let asked = process.new_subject()
  let model = listed(page(True, asked), [])
  let model = deliver(model, operator_page.Peering(peer_links.OpenLink))
  let model =
    deliver(model, operator_page.Peering(peer_links.PickSession("B", "x")))
  let blank = deliver(model, operator_page.Linking("   "))
  assert string.contains(
    drawn(blank),
    peer_links.reason_words(peer_links.InvalidStrand),
  )
  let control = deliver(model, operator_page.Linking("a\u{0}b"))
  assert string.contains(
    drawn(control),
    peer_links.reason_words(peer_links.InvalidStrand),
  )
  assert process.receive(asked, 0) == Error(Nil)
}

pub fn unlinking_a_two_way_pair_offers_each_direction_or_both_test() {
  let asked = process.new_subject()
  let row = out("B", "main")
  let model = listed(page(True, asked), [row, back("B", "main")])
  let model = deliver(model, operator_page.Peering(peer_links.AskUnlink(row)))
  let html = drawn(model)
  assert string.contains(html, "These two strands link both ways.")
  assert string.contains(html, "Both directions")

  let this =
    deliver(
      model,
      operator_page.Peering(peer_links.ConfirmUnlink(peer_links.ThisWay)),
    )
  let assert Ok(peer_links.Unlink(
    "main",
    [peer_links.Edge(Outgoing, "B", "main")],
  )) = change(asked)
  assert string.contains(drawn(this), "Done.")

  let _ =
    deliver(
      model,
      operator_page.Peering(peer_links.ConfirmUnlink(peer_links.OtherWay)),
    )
  let assert Ok(peer_links.Unlink(
    "main",
    [peer_links.Edge(Incoming, "B", "main")],
  )) = change(asked)

  let _ =
    deliver(
      model,
      operator_page.Peering(peer_links.ConfirmUnlink(peer_links.EitherWay)),
    )
  let assert Ok(peer_links.Unlink(
    "main",
    [
      peer_links.Edge(Outgoing, "B", "main"),
      peer_links.Edge(Incoming, "B", "main"),
    ],
  )) = change(asked)
}

pub fn unlinking_a_single_link_asks_to_confirm_one_removal_test() {
  let asked = process.new_subject()
  let row = out("B", "main")
  let model = listed(page(True, asked), [row])
  let model = deliver(model, operator_page.Peering(peer_links.AskUnlink(row)))
  assert !string.contains(drawn(model), "link both ways")
  // A direction the pair does not have cannot be removed.
  let refused =
    deliver(
      model,
      operator_page.Peering(peer_links.ConfirmUnlink(peer_links.EitherWay)),
    )
  assert process.receive(asked, 0) == Error(Nil)
  assert string.contains(
    drawn(refused),
    peer_links.reason_words(peer_links.Unavailable),
  )
}

pub fn a_question_for_a_row_the_board_does_not_hold_does_not_open_test() {
  let asked = process.new_subject()
  let model = listed(page(True, asked), [out("B", "main")])
  let model =
    deliver(
      model,
      operator_page.Peering(peer_links.AskUnlink(out("B", "other"))),
    )
  let _ =
    deliver(
      model,
      operator_page.Peering(peer_links.ConfirmUnlink(peer_links.ThisWay)),
    )
  assert process.receive(asked, 0) == Error(Nil)
}

pub fn a_refusal_is_shown_in_fixed_words_test() {
  let model = listed(page(True, process.new_subject()), [])
  let model =
    deliver(
      model,
      operator_page.Observed(
        component.PeersAnswered(peer_links.Declined(peer_links.NotRunning)),
      ),
    )
  assert string.contains(
    drawn(model),
    peer_links.reason_words(peer_links.NotRunning),
  )
}

pub fn partial_and_complete_changes_have_their_own_words_test() {
  assert peer_links.outcome_words(peer_links.Complete) == "Done."
  assert string.contains(
    peer_links.outcome_words(peer_links.Partial),
    "this side only",
  )
}

pub fn stale_boards_are_read_again_only_when_idle_test() {
  let control = peer_links.start(capable: True)
  assert peer_links.stale(control, "main")
  assert !peer_links.stale(peer_links.waiting(control), "main")
  let read =
    peer_links.answered(
      control,
      peer_links.Listed(Board("main", [], peer_links.AllShown)),
    )
  assert !peer_links.stale(read, "main")
  assert peer_links.stale(read, "reviewer")
  assert !peer_links.stale(peer_links.start(capable: False), "main")
}

/// A real operator page with a catalogue and the requested peer-link control
/// state. The normal SessionsListed path applies the page's 100-entry bound,
/// so a count of 128 submits 128 entries and retains only 100.
///
/// ## Examples
///
/// ```gleam
/// peer_links_test.catalogue_fixture(3, "resting")
/// ```
pub fn catalogue_fixture(
  count: Int,
  phase: String,
) -> component.Model(page_fixture.Wire) {
  catalogue(count, phase, process.new_subject())
}

fn catalogue(
  count: Int,
  phase: String,
  asked: Subject(peer_links.Request),
) -> component.Model(page_fixture.Wire) {
  let model = page(phase != "withheld", asked)
  let entries =
    list.index_map(list.repeat(Nil, count), fn(_, offset) {
      let index = offset + 1
      let id = case index {
        1 -> "A"
        _ -> "peer-" <> int.to_string(index)
      }
      Entry(
        id,
        "peer <b>" <> int.to_string(index) <> "</b>",
        "/src/loom",
        index,
        Live,
        None,
        None,
        None,
        None,
      )
    })
  let model =
    deliver(model, operator_page.Observed(component.SessionsListed(entries)))
  let model =
    deliver(
      model,
      operator_page.Observed(
        component.PeersAnswered(
          peer_links.Listed(Board(
            "main",
            [out("peer-2", "main")],
            peer_links.AllShown,
          )),
        ),
      ),
    )

  // Enter each state through the same messages that the page's controls send.
  case phase {
    "choosing" -> deliver(model, operator_page.Peering(peer_links.OpenLink))
    "configuring" -> {
      let model = deliver(model, operator_page.Peering(peer_links.OpenLink))
      deliver(
        model,
        operator_page.Peering(peer_links.PickSession("peer-3", "peer <b>3</b>")),
      )
    }
    "removing" ->
      deliver(
        model,
        operator_page.Peering(peer_links.AskUnlink(out("peer-2", "main"))),
      )
    _ -> model
  }
}

// The performance fixture uses real control transitions and the real catalogue
// bound, so its labels describe the page that the operator would see.
pub fn catalogue_fixture_enters_control_states_and_respects_the_limit_test() {
  let resting = section(catalogue_fixture(3, "resting"))
  assert string.contains(resting, "Link a session")
  assert !string.contains(resting, "Link to which session?")

  let choosing = section(catalogue_fixture(3, "choosing"))
  assert string.contains(choosing, "Link to which session?")
  assert string.contains(choosing, "peer &lt;b&gt;3&lt;/b&gt;</button>")
  assert !string.contains(choosing, "peer &lt;b&gt;2&lt;/b&gt;</button>")

  let configuring = section(catalogue_fixture(3, "configuring"))
  assert string.contains(configuring, "Link main to peer &lt;b&gt;3&lt;/b&gt;")
  assert string.contains(configuring, "Strand in the other session")
  let removing = section(catalogue_fixture(3, "removing"))
  assert string.contains(removing, "Remove main")
  assert string.contains(removing, "Keep it")
  assert section(catalogue_fixture(3, "withheld")) == ""

  let bounded = drawn(catalogue_fixture(128, "resting"))
  assert string.contains(bounded, "peer &lt;b&gt;100&lt;/b&gt;")
  assert !string.contains(bounded, "peer &lt;b&gt;101&lt;/b&gt;")
}

// A second valid picker event can arrive while the first has already opened
// the form. It replaces the selection using the catalogue's name and resets
// the permissions, rather than retaining the first session or browser text.
pub fn a_second_valid_selection_replaces_the_first_before_submission_test() {
  let asked = process.new_subject()
  let model = catalogue(4, "choosing", asked)
  let model =
    deliver(
      model,
      operator_page.Peering(peer_links.PickSession("peer-3", "forged first")),
    )
  let model =
    deliver(model, operator_page.Peering(peer_links.ChooseWake(MayWake)))
  let model =
    deliver(model, operator_page.Peering(peer_links.ChooseReverse(BothWays)))
  let model =
    deliver(
      model,
      operator_page.Peering(peer_links.PickSession("peer-4", "forged second")),
    )
  let html = section(model)
  assert string.contains(html, "Link main to peer &lt;b&gt;4&lt;/b&gt;")
  assert !string.contains(html, "forged")
  let _model = deliver(model, operator_page.Linking("main"))
  let assert Ok(peer_links.Link("main", "peer-4", "main", BusyOnly, OneWay)) =
    change(asked)
    as "The latest catalogue selection receives the narrow default link."
}
