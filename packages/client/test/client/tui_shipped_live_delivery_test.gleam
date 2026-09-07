//// Live delivery through the shipped daemon, watched from three native
//// terminals.
////
//// The shipped server used to serve every terminal by pull: a peer's answer
//// arrived at the 250 ms idle refresh, a live answer was visible only as the
//// snapshot's discontinuous sample, and a second prompt on a busy strand came
//// back as a conflict. `protocol-change/018` replaced all three with pushed
//// frames, and this fixture is the shipped proof that they work end to end
//// rather than in the gateway's own tests.
////
//// Five properties, in the order the drive establishes them. Two operators
//// submit on one strand inside a single catch-up window and the hub holds the
//// loser's prompt rather than refusing it. Every terminal shows the first
//// answer's text while no entry for it exists in that terminal's cut. Both
//// answers are painted by a notice-driven capture, read from the capture's
//// own recorded provenance rather than from timing. The three terminals hold
//// the same durable records, in one order, with the two human turns
//// attributed to the two different operators. A third answer is then started
//// so that Bob can be revoked while an answer is being written to him: his
//// socket closes at the per-frame authority check and nothing further is
//// written to it.
////
//// The second of those is a statement about pushed deltas and not merely
//// about live text. `live_text_before_the_entry` requires the running
//// operation's stream to have accumulated at least two fragments, and a
//// credited cut cannot produce that: the snapshot preview projects as one
//// fragment however many tokens it summarises. So two fragments before the
//// entry exists are two `stream_delta` frames the daemon pushed, which is
//// what `client/serve` nesting `tap_provider` around `tap_preview_provider`
//// made true of the shipped binary.
////
//// Two deliberate choices make the drive independent of races it does not
//// test. The two operators submit the *same* prompt text, so which of them
//// the hub admitted first — a decision made by arrival order at one actor,
//// between two terminals that wrote within an actor call of each other —
//// changes no expectation here; the fixture reads which one was queued
//// instead of assuming it. And the scripted peer is paced, so an answer
//// occupies an interval rather than an instant; without that there is no
//// moment in which a fragment exists and its entry does not.
////
//// The coordinator retains the endpoint path outside the bounded body, so a
//// failed assertion still retires the native lifetime before reporting
//// failure.

import client/daemon/admin
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/tui_v2_test
import core/entry
import core/json
import core/message
import etui/backend
import filepath
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap as native
import host/endpoint
import simplifile
import support/provider_http
import support/tui_driver
import tui
import tui/bootstrap
import tui/daemon
import tui/daemon/bootstrap as daemon_bootstrap
import tui/daemon/protocol
import tui/daemon/selection
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import weft
import weft/actor
import weft/poll

// CI run 34056261144 exceeded the component's eight-second cold-open wait on
// macOS. Like the multiplayer fixture, this one allows twenty seconds for
// initial session opening and nothing else.
const shipped_open_timeout_ms = 20_000

// Milliseconds between the scripted peer's chunks. Nine chunks make an answer
// occupy about eight tenths of a second, which has to hold a terminal's 250 ms
// refresh, the capture it triggers, and the sampling that reads it.
const stream_gap_ms = 100

// Both operators send this exact text. Identical prompts are what make the
// drive independent of which terminal reached the hub first: the script
// matches either order, and authorship is read from the durable origins.
const window_prompt = "same window turn"

const first_answer = "livedeliveryone"

const second_answer = "livedeliverytwo"

const revoked_prompt = "revocation turn"

const third_answer = "revokedmidanswer"

// Which operator's prompt the hub held. The daemon decides it by arrival
// order at one actor and the fixture reads the decision back, because both
// terminals write within a single actor call of each other and neither
// order is a defect.
type Held {
  AliceHeld
  BobHeld
}

pub fn tui_shipped_live_delivery_pushes_both_answers_test_() -> EunitTest {
  // The runner scales EUnit timeouts by ten. The provider callback has 120
  // seconds around the native body's 90-second budget and its cleanup, so
  // 150 seconds leaves both listener witnesses inside this outer deadline.
  Timeout(15, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP shipped live delivery: LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) -> {
        assert native.getenv("LOOM_TEST_PROVIDER_KEY")
          == Ok(provider_http.dummy_key)
          as "the shipped provider receives only the fixture's public dummy key"
        let paced = provider_http.Paced(stream_gap_ms)
        let #(Nil, report) =
          provider_http.with_server(
            [
              provider_http.PacedExchange(window_prompt, first_answer, paced),
              provider_http.PacedExchange(window_prompt, second_answer, paced),
              provider_http.PacedExchange(revoked_prompt, third_answer, paced),
            ],
            fn(base_url) { fixture(server, base_url) },
          )
        let assert Ok(observed) = report
          as "all three paced provider requests complete without a refused or extra call"

        // The first two requests carry the same latest text by construction.
        // What distinguishes them is that there are exactly two: a strand
        // that folded the second prompt into the first run would make one.
        assert list.map(observed, fn(request) { request.latest })
          == [
            provider_http.UserPrompt(window_prompt),
            provider_http.UserPrompt(window_prompt),
            provider_http.UserPrompt(revoked_prompt),
          ]
      }
    }
  })
}

fn fixture(server: String, provider_url: String) -> Nil {
  let directory =
    "build/shipped-live-delivery-"
    <> int.to_string(native.current_process_id())
    <> "-"
    <> int.to_string(native.system_time_ms())
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "fixture credentials and logs live below a private directory"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the native daemon receives absolute fixture paths"
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "cleanup retains the endpoint path before native startup"
  io.println_error("shipped live delivery fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise(server, directory, paths, provider_url)
        Ok(Nil)
      },
    ])
    |> weft.deadline(90_000)
    |> weft.start

  // The body may fail even during bootstrap, before publishing a connection.
  // Read its private reservation after the worker has stopped; never infer
  // native retirement from that worker's exit or from a closed control socket.
  retire_native(paths)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped live-delivery drive completes inside its deadline"
  Nil
}

fn exercise(
  server: String,
  directory: String,
  paths: endpoint.Paths,
  provider_url: String,
) -> Nil {
  let #(connected, address, owner, epoch, host) =
    open_daemon(server, directory, paths, provider_url)
  let workspace = filepath.join(directory, "workspace")
  let configuration = filepath.join(directory, "fixture.toml")
  let assert Ok(target) =
    selection.create(host, "shipped-live", workspace, configuration)
    as "explicit creation opens the fixture session"
  let id = target.expected.session
  share_session(connected.control, address, owner, epoch, id)
  let alice_token =
    invite(address, owner, epoch, id, "alice", "operator", "Alice")
  let bob_token = invite(address, owner, epoch, id, "bob", "operator", "Bob")
  let reader_token =
    invite(address, owner, epoch, id, "reader", "observer", "Reader")
  let assert Ok(_) = selection.open(host, id)
    as "only the owner's explicit reopen starts the isolated session"

  // Three independent native terminals, each with its own socket. Nothing
  // below fabricates a frame: every observation is one of these three
  // terminals' own model after its own traffic.
  let assert Ok(alice) = tui_driver.start(address, alice_token, id)
    as "Alice owns one native terminal and socket"
  let assert Ok(bob) = tui_driver.start(address, bob_token, id)
    as "Bob owns a separate native terminal and socket"
  let assert Ok(reader) = tui_driver.start(address, reader_token, id)
    as "the observer attaches without opening execution"
  let _ = await_open(alice.data, writable)
  let _ = await_open(bob.data, writable)
  let observed = await_open(reader.data, attached_observer)
  assert !writable(observed)

  let held = one_window(alice, bob)
  live_text_before_the_entry([alice, bob, reader])
  let #(winner, loser) = attribution(held)
  let shared = [
    #(winner, window_prompt),
    #(loser, window_prompt),
  ]
  notice_painted([alice, bob, reader], first_answer)
  notice_painted([alice, bob, reader], second_answer)
  assert_shared_turns([alice, bob, reader], shared, [
    first_answer,
    second_answer,
  ])
  revoke_mid_answer(address, owner, epoch, id, shared, alice, bob, reader)

  // Observe each driver exit before retiring the native daemon. Failure of
  // any preceding assertion instead closes them through their worker links.
  list.each([alice, bob, reader], stop_driver)
  daemon.close(connected.control)
}

// Brings up the shipped executable through the ordinary native bootstrap and
// returns everything the drive needs to act as the owner. Written out here so
// the drive itself reads as the property under test rather than as setup.
fn open_daemon(
  server: String,
  directory: String,
  paths: endpoint.Paths,
  provider_url: String,
) -> #(daemon_bootstrap.Connected, String, String, String, selection.Host) {
  let workspace = filepath.join(directory, "workspace")
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the session workspace exists independently of private daemon state"
  let configuration = filepath.join(directory, "fixture.toml")
  let assert Ok(Nil) =
    simplifile.write(
      configuration,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \""
        <> provider_url
        <> "\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n",
    )
    as "normal provider configuration selects the loopback peer with maintenance off"
  let options =
    bootstrap.Options(workspace, "", server, paths.root, configuration)
  let assert Ok(connected) =
    bootstrap.resolve_daemon(options, process.self(), 40_000)
    as "the supplied shipped executable authenticates through native bootstrap"
  let assert Ok(address) = endpoint.address(connected.record)
    as "the published native endpoint supplies the real control address"
  let assert Ok(token) = simplifile.read(connected.paths.token)
    as "the private owner credential is available only to fixture setup"
  let owner = string.trim(token)
  let protocol.Epoch(epoch) = daemon.hello(connected.control).epoch
  let assert Ok(host) = selection.host(connected.control, address, owner)
    as "the authenticated control retains its own route"
  #(connected, address, owner, epoch, host)
}

// Sharing is not a fixture bypass: ordinary creation is workspace-private.
// Stop the session before the owner's explicit isolation acknowledgement, so
// the real invitation and reopen paths run without touching the store.
fn share_session(
  control: daemon.Connection,
  address: String,
  owner: String,
  epoch: String,
  id: String,
) -> Nil {
  let assert Ok(_) = daemon.request(control, protocol.StopSession(id), 5000)
    as "the owner requests retirement before changing isolation scope"
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case daemon.request(control, protocol.GetSession(id), 2000) {
        Ok(protocol.SessionReply(protocol.Session(status: protocol.Saved, ..))) ->
          poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
    as "isolation waits for the runtime's retirement witness"
  let assert Ok(isolate) =
    admin.parse(["isolate", id, "--share-existing-transcript"])
    as "the owner explicitly acknowledges transcript sharing"
  let assert Ok(_) = admin.exchange(address, owner, epoch, isolate)
    as "the shipped daemon enforces and persists session-only scope"
  Nil
}

// Two operators submit on one strand inside one catch-up window, and the
// fixture reads back which of them the hub held.
//
// The terminal sends `prompt` only while its own model still shows the strand
// idle; once it has captured a running operation, Enter means `steer`, which
// is a different command with different semantics and is not what the queue
// exists for. Under network delivery a terminal learns a strand went live
// only through a commit notice and the catch-up it triggers — a full snapshot
// transfer — so the window is the daemon's whole round trip. Bob's draft is
// therefore composed *first*, leaving exactly one actor call between Alice's
// submission and his. A terminal that lost that window sends `steer`, no
// queued acknowledgement ever appears, and this function fails on its
// deadline rather than quietly testing something else.
fn one_window(
  alice: actor.Started(process.Subject(tui_driver.Message)),
  bob: actor.Started(process.Subject(tui_driver.Message)),
) -> Held {
  let _ = tui_driver.play(bob.data, [backend.Paste(window_prompt)])
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste(window_prompt),
      backend.KeyPress("enter"),
    ])
  let _ = tui_driver.play(bob.data, [backend.KeyPress("enter")])

  // The acknowledgement is a transient line: the next capture rebuilds the
  // transcript. Both terminals are therefore sampled together on a short
  // period, and the first sighting settles the poll.
  let outcome =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 15_000,
      every: poll.Fixed(5),
      from: "no queued acknowledgement",
      attempt: fn(_) {
        let alice_sample = tui_driver.play(alice.data, [])
        let bob_sample = tui_driver.play(bob.data, [])
        case queued(alice_sample), queued(bob_sample) {
          True, False -> poll.Settled(AliceHeld)
          False, True -> poll.Settled(BobHeld)
          True, True ->
            poll.Broken("both prompts were held; neither opened the run")
          False, False -> poll.Pending(pending_note(alice_sample, bob_sample))
        }
      },
    )
  case outcome {
    poll.Answer(held) -> held
    poll.RanOut(note) -> {
      let reason = "no queued acknowledgement: " <> note
      panic as reason
    }
    poll.Failure(reason) -> panic as reason
  }
}

// The queued reply is rendered as a booked turn, never as a refusal. Reading
// the transcript line rather than the wire is the point: the property is that
// the terminal shows an operator their prompt was accepted for the next turn.
fn queued(sample: tui_driver.Sample) -> Bool {
  list.any(sample.model.transcript, fn(line) {
    let tui.Line(speaker:, text:) = line
    speaker == tui.System && string.contains(text, "prompt queued")
  })
}

// Diagnostics carry the two notices and the strand phases, never the model,
// the frame, or anything a credential could be read out of.
fn pending_note(alice: tui_driver.Sample, bob: tui_driver.Sample) -> String {
  "alice="
  <> string.slice(alice.model.notice, 0, 160)
  <> "/"
  <> phase_of(alice)
  <> " bob="
  <> string.slice(bob.model.notice, 0, 160)
  <> "/"
  <> phase_of(bob)
}

fn phase_of(sample: tui_driver.Sample) -> String {
  case list.find(sample.model.strands, fn(row) { row.id == "main" }) {
    Ok(row) -> option.unwrap(row.live_phase, "idle")
    Error(Nil) -> "missing"
  }
}

// Every terminal must show the answer being written before any entry for it
// exists in that terminal's cut: a live text stream on the strand carrying
// the running operation, holding at least two fragments whose visible text is
// a genuine prefix of the answer that has not committed.
//
// The fragment count is what makes this a statement about pushed delivery
// rather than about polling. A catch-up cut carries the snapshot's sampled
// preview, and that preview always projects as exactly one fragment however
// many tokens it summarises, so a stream that has accumulated two of them was
// fed by `stream_delta` frames and by nothing else. The prefix check costs
// nothing beside it and rules out an unrelated fragment satisfying the count.
fn live_text_before_the_entry(
  drivers: List(actor.Started(process.Subject(tui_driver.Message))),
) -> Nil {
  // All three terminals are sampled in one loop rather than one after the
  // other. The window this property lives in is the answer's own streaming
  // interval — under a second — and awaiting the terminals in sequence spends
  // that interval on the first one, so the second would be asked about a
  // stream that has already committed.
  let outcome =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 8000,
      every: poll.Fixed(5),
      from: #(drivers, "no terminal sample"),
      attempt: fn(state) {
        let #(waiting, _) = state
        let #(remaining, note) = sample_waiting(waiting)
        case remaining {
          [] -> poll.Settled(Nil)
          [_, ..] -> poll.Pending(#(remaining, note))
        }
      },
    )
  case outcome {
    poll.Answer(Nil) -> Nil
    poll.RanOut(#(_, note)) -> {
      let reason = "no live answer text before the entry: " <> note
      panic as reason
    }
    poll.Failure(reason) -> panic as reason
  }
}

// One pass over the terminals that have not shown the property yet, returning
// those still waiting and a diagnostic for them.
fn sample_waiting(
  waiting: List(actor.Started(process.Subject(tui_driver.Message))),
) -> #(List(actor.Started(process.Subject(tui_driver.Message))), String) {
  list.fold(waiting, #([], ""), fn(carried, driver) {
    let #(kept, note) = carried
    let sample = tui_driver.play(driver.data, [])
    case live_prefix(sample) && assistant_texts(sample) == [] {
      True -> #(kept, note)
      False -> #([driver, ..kept], note <> " · " <> stream_note(sample))
    }
  })
}

// Streams and phase only. The model, the frame and the records are excluded:
// EUnit prints a failed assertion's value, and this fixture's models carry
// member credentials.
fn stream_note(sample: tui_driver.Sample) -> String {
  let streams =
    list.map(sample.model.streams, fn(stream) {
      let tui.Stream(strand:, kind:, fragments:, operation:) = stream
      strand
      <> "/"
      <> kind
      <> "/"
      <> int.to_string(list.length(fragments))
      <> "/op="
      <> string.slice(operation, 0, 8)
      <> "/text="
      <> string.slice(string.concat(list.reverse(fragments)), 0, 24)
    })
  "active="
  <> sample.model.active_strand
  <> " phase="
  <> phase_of(sample)
  <> " streams="
  <> string.join(streams, ",")
  <> " answers="
  <> int.to_string(list.length(assistant_texts(sample)))
}

// Live text on the active strand that is a nonempty prefix of the answer
// still being written. Fragments are newest first, so they are reversed
// before they are read as text.
fn live_prefix_of(sample: tui_driver.Sample, answer: String) -> Bool {
  list.any(sample.model.streams, fn(stream) {
    let tui.Stream(strand:, kind:, fragments:, ..) = stream
    let text = string.concat(list.reverse(fragments))
    strand == sample.model.active_strand
    && kind == "text"
    && text != ""
    && string.starts_with(answer, text)
  })
}

// The strong form of the live-text property, and the only place that counts
// fragments. Two of them on the running operation's stream cannot have come
// from a credited cut, because the snapshot preview projects as one fragment
// whatever it holds; they are the pushed `stream_delta` frames themselves.
fn live_prefix(sample: tui_driver.Sample) -> Bool {
  list.any(sample.model.streams, fn(stream) {
    let tui.Stream(strand:, kind:, fragments:, ..) = stream
    let text = string.concat(list.reverse(fragments))
    strand == sample.model.active_strand
    && kind == "text"
    && accumulated(fragments)
    && string.starts_with(first_answer, text)
  })
}

// Whether a stream holds more than one fragment. The question is bounded, so
// it is answered by the list's shape rather than by measuring its length.
fn accumulated(fragments: List(String)) -> Bool {
  case fragments {
    [] | [_] -> False
    [_, _, ..] -> True
  }
}

// Each terminal's first sample carrying the answer must record a notice as
// what asked for the cut. The same answer painted by `Refreshed` means the
// notice never arrived and the terminal fell back to polling, which is
// correct behaviour and is not this property.
fn notice_painted(
  drivers: List(actor.Started(process.Subject(tui_driver.Message))),
  answer: String,
) -> Nil {
  list.each(drivers, fn(driver) {
    let sample =
      tui_v2_test.await(driver.data, fn(sample) {
        list.contains(assistant_texts(sample), answer)
      })
    assert sample.model.last_capture == session_channel.Notified
      as "the capture that painted a peer's answer was asked for by a pushed notice"
  })
}

// Alice submits a third turn only so that Bob can lose his membership while
// pushed frames are actually in flight to him. Waiting for his own stream to
// accumulate is what makes "mid-answer" a fact about his socket rather than
// about the clock.
fn revoke_mid_answer(
  address: String,
  owner: String,
  epoch: String,
  session: String,
  shared: List(#(String, String)),
  alice: actor.Started(process.Subject(tui_driver.Message)),
  bob: actor.Started(process.Subject(tui_driver.Message)),
  reader: actor.Started(process.Subject(tui_driver.Message)),
) -> Nil {
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste(revoked_prompt),
      backend.KeyPress("enter"),
    ])
  let _ = tui_v2_test.await(bob.data, live_prefix_of(_, third_answer))
  let assert Ok(revoke) = admin.parse(["revoke", session, "bob"])
    as "membership revocation names the existing principal and session"
  let assert Ok(_) = admin.exchange(address, owner, epoch, revoke)
    as "the owner receives acknowledgement of durable membership revocation"

  // The next frame the hub tries to write to Bob fails its per-delivery
  // authority check and retires the attachment. His terminal reports the
  // closure; his last authorized projection survives it.
  let closed =
    tui_v2_test.await(bob.data, fn(sample) {
      sample.model.peer == tui.Disconnected
    })
  assert !list.contains(assistant_texts(closed), third_answer)
    as "Bob loses the socket while the third answer is still being written"

  // A whole answer completing at the surviving terminals is the positive
  // barrier. Bob's records and his half-written stream must both be exactly
  // what they were at closure: not one further pushed frame reached him.
  let turns = list.append(shared, [#("alice", revoked_prompt)])
  let answers = [first_answer, second_answer, third_answer]
  let assert [alice_done, reader_done] =
    captured_turns([alice, reader], turns, answers)
    as "the two remaining terminals complete the third turn"
  assert alice_done.model.records == reader_done.model.records
  let retained = tui_driver.play(bob.data, [])
  assert retained.model.peer == tui.Disconnected
  assert retained.model.records == closed.model.records
  assert retained.model.streams == closed.model.streams
}

// The winner and loser as principals, in durable order.
fn attribution(held: Held) -> #(String, String) {
  case held {
    AliceHeld -> #("bob", "alice")
    BobHeld -> #("alice", "bob")
  }
}

fn assert_shared_turns(
  drivers: List(actor.Started(process.Subject(tui_driver.Message))),
  turns: List(#(String, String)),
  answers: List(String),
) -> Nil {
  let assert [first, second, observer] = captured_turns(drivers, turns, answers)
    as "the two operators and observer each completed their own credited capture"
  assert first.model.records == second.model.records
  assert first.model.records == observer.model.records
  assert !writable(observer)
}

// Waits until each terminal's own records are exactly the expected human
// turns, with their authors, and exactly the expected answers, in order,
// with the strand idle and nothing left streaming.
fn captured_turns(
  drivers: List(actor.Started(process.Subject(tui_driver.Message))),
  turns: List(#(String, String)),
  answers: List(String),
) -> List(tui_driver.Sample) {
  let expected_users =
    list.reverse(turns)
    |> list.map(fn(turn) {
      let #(principal, text) = turn
      #([message.UserText(text, None)], Some(principal))
    })
  let expected_answers = list.reverse(answers)
  list.map(drivers, fn(driver) {
    tui_v2_test.await(driver.data, fn(sample) {
      user_turns(sample) == expected_users
      && assistant_texts(sample) == expected_answers
      && sample.model.streams == []
      && sample.model.submitting == None
      && list.any(sample.model.strands, fn(strand) {
        strand.id == "main" && strand.live_phase == None
      })
      && list.all(answers, fn(answer) { string.contains(sample.frame, answer) })
    })
  })
}

fn user_turns(
  sample: tui_driver.Sample,
) -> List(#(List(message.UserBlock), Option(String))) {
  list.filter_map(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(
        message: message.UserMessage(content:, origin:, ..),
        ..,
      ) -> Ok(#(content, option.map(origin, fn(author) { author.principal })))
      _ -> Error(Nil)
    }
  })
}

// Answers as plain text, newest first. Every assistant entry in this drive is
// one text block, so anything else is a script the fixture did not write.
fn assistant_texts(sample: tui_driver.Sample) -> List(String) {
  list.filter_map(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(
        message: message.AssistantMessage(
          content: [message.AssistantText(text, None)],
          ..,
        ),
        ..,
      ) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

// Shipped cold attachment can exceed the component helper's eight seconds on
// loaded macOS runners. Only initial opening gets this bounded allowance.
fn await_open(
  driver: process.Subject(tui_driver.Message),
  predicate: fn(tui_driver.Sample) -> Bool,
) -> tui_driver.Sample {
  let outcome =
    poll.fold_until(
      clock: poll.monotonic(),
      within: shipped_open_timeout_ms,
      every: poll.Fixed(10),
      from: "no terminal sample",
      attempt: fn(_) {
        let sample = tui_driver.play(driver, [])
        case predicate(sample) {
          True -> poll.Settled(sample)
          False -> poll.Pending(string.slice(sample.model.notice, 0, 512))
        }
      },
    )
  case outcome {
    poll.Answer(sample) -> sample
    poll.RanOut(notice) -> {
      let reason = "shipped session-open deadline: " <> notice
      panic as reason
    }
    poll.Failure(reason) -> panic as reason
  }
}

fn attached_observer(sample: tui_driver.Sample) -> Bool {
  case sample.model.captured {
    Some(#(cut, view)) ->
      cut.attachment.role == snapshot.Observer && peer_count(view) == 3
    None -> False
  }
}

fn peer_count(view: snapshot_view.View) -> Int {
  list.length(view.peers)
}

fn stop_driver(
  driver: actor.Started(process.Subject(tui_driver.Message)),
) -> Nil {
  let monitor = process.monitor(driver.pid)
  tui_driver.stop(driver.data)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "the native terminal closes normally before daemon teardown"
  Nil
}

fn invite(address, owner, epoch, session, principal, role, name) {
  let assert Ok(request) =
    admin.parse(["invite", session, principal, role, name])
    as "member setup uses the shipped owner CLI parser"
  let assert Ok(json.Object(fields)) =
    admin.exchange(address, owner, epoch, request)
    as "the native daemon issues the authorized member credential"
  let assert Ok(json.String(bearer)) = list.key_find(fields, "bearer")
    as "the one-shot credential remains fixture-local and is never printed"
  bearer
}

fn writable(sample: tui_driver.Sample) -> Bool {
  case sample.model.channel {
    Some(channel) -> session_channel.mutation_available(channel)
    None -> False
  }
}

fn retire_native(paths: endpoint.Paths) -> Nil {
  let assert Ok(record) = endpoint.load(paths)
    as "cleanup can decode its private native reservation"
  case record {
    None -> Nil
    Some(record) -> {
      let assert Ok(present) = endpoint.is_present(record.fence)
        as "cleanup checks the original PID birth before sending any signal"
      case present {
        True -> native.terminate_process_group(record.fence.pid)
        False -> Nil
      }
      let assert poll.Answered(Nil) =
        poll.until(within: 10_000, every: 25, attempt: fn() {
          case endpoint.is_present(record.fence) {
            Ok(False) -> poll.Done(Nil)
            Ok(True) -> poll.Retry
            Error(reason) -> poll.Fail(reason)
          }
        })
        as "native retirement is witnessed before reporting the fixture result"
      Nil
    }
  }
}
