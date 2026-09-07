//// Live delivery through the shipped daemon, watched from two native
//// terminals and one raw wire client.
////
//// The shipped server used to serve every terminal by pull: a peer's answer
//// arrived at the 250 ms idle refresh, a live answer was visible only as the
//// snapshot's discontinuous sample, and a second prompt on a busy strand came
//// back as a conflict. `protocol-change/018` replaced all three with pushed
//// frames, and this fixture is the shipped proof that they work end to end
//// rather than in the gateway's own tests.
////
//// Five properties, in the order the drive establishes them. A second
//// operator submits on a strand that is already running and the hub holds his
//// prompt rather than refusing it. Both terminals show the first answer's
//// text while no entry for it exists in that terminal's cut. Both terminals
//// are pushed the commit notices for the two turns, counted on their own
//// models. The terminals and the wire client hold the same durable records,
//// in one order, with the two human turns attributed to the two different
//// operators. A third answer is then started so that Bob can be revoked while
//// an answer is being written to him: his socket closes at the per-frame
//// authority check and nothing further is written to it.
////
//// Bob is a wire client and not a terminal, because the queue is reachable
//// only from a client whose view of the strand is stale. A terminal sends
//// `prompt` while its own model shows the strand idle and `steer` once it has
//// captured a running operation, and against a daemon that pushes, the stale
//// window is a few milliseconds wide. There is no `queued` acknowledgement
//// for `steer`, so a terminal in that role tests the queue only when it loses
//// a race. A raw v2 client tracks no liveness and sends `prompt` whenever the
//// fixture says to, which makes the held prompt a fact about the hub rather
//// than about scheduling. It also gives the revocation a stronger witness:
//// frames can be counted directly off the socket instead of inferred from a
//// terminal's stream going quiet.
////
//// The live-text property is a statement about pushed deltas and not merely
//// about live text. `live_text_before_the_entry` requires the running
//// operation's stream to have accumulated at least two fragments, and a
//// credited cut cannot produce that: the snapshot preview projects as one
//// fragment however many tokens it summarises. So two fragments before the
//// entry exists are two `stream_delta` frames the daemon pushed, which is
//// what `client/serve` nesting `tap_provider` around `tap_preview_provider`
//// made true of the shipped binary.
////
//// The notice property is counted rather than read off a capture. Which
//// capture painted an answer is not a deterministic observable: the 250 ms
//// idle refresh is a path the design keeps, and when its catch-up is already
//// in flight at the commit it paints first, after which the notice arrives
//// for a sequence already held and is correctly dropped. `Model.notices`
//// counts arrivals instead, before that decision, so it moves for every
//// notice the daemon pushed however the lane spent it.
////
//// Two turns commit at least four durable records — two user entries and two
//// assistant entries — so at least four notices must reach every attached
//// terminal. The scripted peer is paced, so an answer occupies an interval
//// rather than an instant; without that there is no moment in which a
//// fragment exists and its entry does not.
////
//// The coordinator retains the endpoint path outside the bounded body, so a
//// failed assertion still retires the native lifetime before reporting
//// failure.

import client/daemon/admin
import client/daemon_server_test as wire
import client/session_socket_test
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/tui_v2_test
import core/codec
import core/entry
import core/json
import core/message
import etui/backend
import filepath
import gleam/bit_array
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap as native
import host/endpoint
import simplifile
import support/internal/ffi_ws.{type Socket}
import support/provider_http
import support/tui_driver
import tui
import tui/bootstrap
import tui/daemon
import tui/daemon/bootstrap as daemon_bootstrap
import tui/daemon/protocol
import tui/daemon/selection
import tui/protocol as conversation
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

// CI run 34156839616 failed `attach_wire` inside `daemon_server_test.frame`'s
// 1 s read: that default assumes an in-process fixture answering inside its
// own event loop turn, but this one attaches Bob's raw socket to the shipped
// daemon, where the reply waits behind `session_socket.admit` first — a
// one-second root permit transfer plus a five-second gateway attach
// (`packages/client/src/client/daemon/session_socket.gleam`, the module doc
// and `admit`) — and a loaded hosted runner can spend both in full before
// the socket answers at all. The command after that admission is itself
// bounded by the gateway's own five-second request budget. Ten seconds pays
// both budgets in full without hiding a wedged daemon behind a timeout that
// never fires, and the fixture's own eunit timeout leaves ample room around
// it. Every wire read this fixture makes against the shipped daemon passes
// this constant rather than the helper's in-process default.
const wire_read_ms = 10_000

// Milliseconds between the scripted peer's chunks. Nine chunks make an answer
// occupy about eight tenths of a second, which has to hold a terminal's 250 ms
// refresh, the capture it triggers, and the sampling that reads it.
const stream_gap_ms = 100

// Both operators send this exact text, so the two provider requests are
// distinguished by there being two of them rather than by their content.
const window_prompt = "same window turn"

const first_answer = "livedeliveryone"

const second_answer = "livedeliverytwo"

const revoked_prompt = "revocation turn"

const third_answer = "revokedmidanswer"

// Two user entries and two assistant entries commit across the two shared
// turns, and every commit is one pushed notice to every attachment. Operation
// transitions and usage commit alongside them, so this is a floor and not a
// count: what it rules out is a terminal that was pushed nothing.
const shared_turn_records = 4

// Bob's own request identities on the raw socket. `subscribe` takes 1 and the
// credited transfer takes the small numbers after it, so the fixture's own
// commands start well clear of both.
const bob_prompt_id = 900

const bob_catch_up_id = 901

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
  let assert endpoint.Ready(port:, ..) = connected.record
    as "authenticated bootstrap retains the published listener port"
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

  // Two independent native terminals, each with its own socket, and one raw
  // v2 client. Nothing below fabricates a frame: every observation is one of
  // these three attachments' own state after its own traffic.
  let assert Ok(alice) = tui_driver.start(address, alice_token, id)
    as "Alice owns one native terminal and socket"
  let assert Ok(reader) = tui_driver.start(address, reader_token, id)
    as "the observer attaches without opening execution"
  let bob = attach_wire(port, bob_token, id)
  let _ = await_open(alice.data, writable)
  let observed = await_open(reader.data, attached_observer)
  assert !writable(observed)

  // The notice count is a delta, so the terminals are read before any of the
  // traffic under test exists.
  let before = list.map([alice, reader], notices_of)
  held_behind_a_running_turn(alice, bob)
  live_text_before_the_entry([alice, reader])
  let shared = [#("alice", window_prompt), #("bob", window_prompt)]
  let answers = [first_answer, second_answer]
  let painted = assert_shared_turns([alice, reader], shared, answers)
  notices_reached([alice, reader], before)
  let assert [alice_painted, ..] = painted
    as "Alice's completed sample is the fixture's durable reference"
  wire_saw_both_answers(bob, alice_painted)
  revoke_mid_answer(address, owner, epoch, id, shared, alice, bob, reader)

  // Observe each driver exit before retiring the native daemon. Failure of
  // any preceding assertion instead closes them through their worker links.
  list.each([alice, reader], stop_driver)
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

// Bob's attachment: the same authenticated websocket route the terminals use,
// subscribed and reconciled through its own credited transfer, with no client
// state machine above it. Draining that first transfer matters because a
// socket which still owes credit is not the socket the queue property is
// about; from here on Bob's only outstanding work is what the fixture asks
// for.
fn attach_wire(port: Int, bearer: String, session: String) -> Socket {
  let #(socket, response) =
    wire.connect(port, bearer, "/v2/sessions/" <> session <> "/ws")
  assert string.starts_with(response, "HTTP/1.1 101 ")
    as "the invited operator's credential upgrades on the shipped route"
  let #(_, transfer) =
    session_socket_test.begin(socket, session, within_ms: wire_read_ms)
  let _ =
    session_socket_test.drain(
      socket,
      transfer,
      0,
      [],
      32,
      within_ms: wire_read_ms,
    )
  socket
}

// Alice opens a turn, and Bob submits on the same strand while it is running.
//
// The strand being *observably* live before Bob writes is what makes the
// queue deterministic. Alice's terminal reports a live phase only after the
// daemon told it so, which means the run exists at the hub; Bob's prompt is
// therefore admitted against a busy strand every time, and a raw client never
// substitutes `steer` for it. The reply is read by correlation, past whatever
// the hub pushed around it.
fn held_behind_a_running_turn(
  alice: actor.Started(process.Subject(tui_driver.Message)),
  bob: Socket,
) -> Nil {
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste(window_prompt),
      backend.KeyPress("enter"),
    ])
  let _ = tui_v2_test.await(alice.data, strand_is_running)
  let outcome =
    wire.reply(
      bob,
      bob_prompt_id,
      "prompt",
      json.Object([
        #("strand", json.String("main")),
        #("text", json.String(window_prompt)),
      ]),
      within_ms: wire_read_ms,
    )
  assert field(outcome, "reply_to") == json.Int(bob_prompt_id)
    as "the acknowledgement answers Bob's own prompt and no pushed frame"
  assert field(outcome, "event") == json.String("mutation_outcome")
  assert field(field(outcome, "body"), "status") == json.String("queued")
    as "a prompt for a running strand is held for its next turn, not refused"
}

// Whether this terminal has captured a live operation on the shared strand.
fn strand_is_running(sample: tui_driver.Sample) -> Bool {
  list.any(sample.model.strands, fn(row) {
    row.id == "main" && row.live_phase != None
  })
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
  // Both terminals are sampled in one loop rather than one after the other.
  // The window this property lives in is the answer's own streaming interval
  // — under a second — and awaiting the terminals in sequence spends that
  // interval on the first one, so the second would be asked about a stream
  // that has already committed.
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

// Streams, phase and capture provenance only. The model, the frame and the
// records are excluded: EUnit prints a failed assertion's value, and this
// fixture's models carry member credentials.
//
// `last_capture` appears here and nowhere else. Which capture painted a given
// answer is a race with the idle refresh and so is not something to assert
// on, but it is exactly what a reader wants to know when the drive has just
// failed on a timeout.
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
  <> " notices="
  <> int.to_string(sample.model.notices)
  <> " capture="
  <> string.inspect(sample.model.last_capture)
  <> " streams="
  <> string.join(streams, ",")
  <> " answers="
  <> int.to_string(list.length(assistant_texts(sample)))
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

fn notices_of(
  driver: actor.Started(process.Subject(tui_driver.Message)),
) -> Int {
  let sample = tui_driver.play(driver.data, [])
  sample.model.notices
}

// Every terminal was pushed the commit notices for the two shared turns.
//
// This is the fixture's account of live delivery, and it is a count rather
// than a provenance because provenance is not deterministic here: the idle
// refresh may already have a catch-up in flight when a commit lands, in which
// case it paints first and the notice is correctly dropped as naming a
// sequence already held. `Model.notices` moves either way, so the floor below
// fails only if frames did not arrive.
fn notices_reached(
  drivers: List(actor.Started(process.Subject(tui_driver.Message))),
  before: List(Int),
) -> Nil {
  list.each(list.zip(drivers, before), fn(pair) {
    let #(driver, baseline) = pair
    let sample = tui_driver.play(driver.data, [])
    assert sample.model.notices - baseline >= shared_turn_records
      as "the two shared turns pushed a commit notice per record to this terminal"
  })
}

// Bob's socket is read only after both answers are durable at the terminals,
// which is what makes this a scan of buffered frames rather than a wait. The
// hub writes one notice to every attachment in a single fan-out, before any
// terminal can complete the catch-up that fan-out triggers, so a sequence a
// terminal has already painted is a sequence Bob's socket has already been
// sent.
//
// The durable comparison then runs on Bob's own credited catch-up rather than
// on anything the fixture kept, so what it compares is two independent reads
// of the same history.
fn wire_saw_both_answers(bob: Socket, painted: tui_driver.Sample) -> Nil {
  let wanted = answer_sequences(painted)
  let assert [_, _] = wanted
    as "the completed sample holds exactly the two shared answers"
  notices_for(bob, wanted, 4096)
  let entries = wire_entries(bob)
  assert entries == list.reverse(list.map(painted.model.records, entry_of))
    as "the wire client's own catch-up holds the terminals' durable records"
}

fn entry_of(record: conversation.EntryRecord) -> entry.Entry {
  record.entry
}

// The durable sequences of the assistant entries a terminal has painted.
fn answer_sequences(sample: tui_driver.Sample) -> List(Int) {
  list.filter_map(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(seq:, message: message.AssistantMessage(..), ..) ->
        Ok(seq)
      _ -> Error(Nil)
    }
  })
}

// Reads forward until a `committed` notice has been seen for every wanted
// sequence. The budget is a frame count rather than a clock: the frames are
// already in the socket, so a run of this loop that does not find them is a
// missing notice and not a slow one.
fn notices_for(socket: Socket, wanted: List(Int), remaining: Int) -> Nil {
  case wanted {
    [] -> Nil
    [_, ..] -> {
      assert remaining > 0
        as "every answer's commit notice reaches the wire client"
      let frame = wire.frame(socket, within_ms: wire_read_ms)
      let seen = case field(frame, "event") {
        json.String("committed") -> [field(frame, "seq")]
        _other -> []
      }
      let left =
        list.filter(wanted, fn(seq) { !list.contains(seen, json.Int(seq)) })
      notices_for(socket, left, remaining - 1)
    }
  }
}

// Bob's whole history, read back through his own credited catch-up from the
// first sequence and reassembled with the shared core decoder.
fn wire_entries(socket: Socket) -> List(entry.Entry) {
  let response =
    wire.reply(
      socket,
      bob_catch_up_id,
      "catch_up",
      json.Object([#("from_seq", json.Int(0))]),
      within_ms: wire_read_ms,
    )
  let assert json.String(transfer) =
    field(field(response, "body"), "snapshot_id")
    as "the catch-up owns a new fixed cut"
  let chunks =
    session_socket_test.drain(
      socket,
      transfer,
      0,
      [],
      128,
      within_ms: wire_read_ms,
    )
  chunks
  |> list.filter_map(fn(chunk) {
    case field(chunk, "record_id") {
      json.String("metadata") -> Error(Nil)
      json.String(record) -> Ok(record)
      _other -> Error(Nil)
    }
  })
  |> list.unique
  |> list.map(fn(record) { decoded_entry(chunks, record) })
}

// One record's fragments, in the order the transfer wrote them, decoded
// through the same codec the terminal's snapshot decoder uses.
fn decoded_entry(chunks: List(json.JsonValue), record: String) -> entry.Entry {
  let bytes =
    chunks
    |> list.filter(fn(chunk) {
      field(chunk, "record_id") == json.String(record)
    })
    |> list.map(fn(chunk) {
      let assert json.String(data) = field(chunk, "data")
        as "fragment data is base64"
      let assert Ok(bytes) = bit_array.base64_decode(data)
        as "fragment data decodes"
      bytes
    })
    |> bit_array.concat
  let assert Ok(text) = bit_array.to_string(bytes)
    as "the reassembled record is UTF-8"
  let assert Ok(value) = json.parse(text)
    as "the reassembled record is total JSON"
  let assert Ok(row) = codec.decode_entry(value)
    as "the reassembled record decodes through the shared core codec"
  row
}

fn field(value: json.JsonValue, name: String) -> json.JsonValue {
  let assert json.Object(fields) = value as "the wire value is an object"
  let assert Ok(found) = list.key_find(fields, name)
    as "the expected wire field is present"
  found
}

// Alice submits a third turn only so that Bob can lose his membership while
// pushed frames are actually in flight to him. Reading his socket forward
// until it carries a prefix of the third answer is what makes "mid-answer" a
// fact about that socket rather than about the clock.
//
// The witness is then a frame count rather than an absence. A terminal can
// only show that nothing further arrived, which is a statement about a quiet
// interval; a raw socket can be read until the server's own close frame and
// then read again, and the second read is the transport refusing to produce
// anything at all.
fn revoke_mid_answer(
  address: String,
  owner: String,
  epoch: String,
  session: String,
  shared: List(#(String, String)),
  alice: actor.Started(process.Subject(tui_driver.Message)),
  bob: Socket,
  reader: actor.Started(process.Subject(tui_driver.Message)),
) -> Nil {
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste(revoked_prompt),
      backend.KeyPress("enter"),
    ])
  pushed_prefix(bob, third_answer, 4096)
  let assert Ok(revoke) = admin.parse(["revoke", session, "bob"])
    as "membership revocation names the existing principal and session"
  let assert Ok(_) = admin.exchange(address, owner, epoch, revoke)
    as "the owner receives acknowledgement of durable membership revocation"

  // The next frame the hub tries to write to Bob fails its per-delivery
  // authority check and retires the attachment. Frames already written before
  // that check are legitimately his; frames after the close are the property.
  let _ = frames_until_close(bob, 0, 4096)
  let assert Error(reason) = ffi_ws.tcp_receive(bob, 1, 250)
    as "no pushed frame follows the close the revocation caused"
  assert reason == atom.to_dynamic(atom.create("closed"))
    as "actual TCP closure, never a timeout, proves the transport retired"
  let _ = ffi_ws.tcp_close(bob)

  // A whole answer completing at the surviving terminals is the positive
  // barrier: the hub kept pushing, and it kept pushing to everyone else.
  let turns = list.append(shared, [#("alice", revoked_prompt)])
  let answers = [first_answer, second_answer, third_answer]
  let assert [alice_done, reader_done] =
    captured_turns([alice, reader], turns, answers)
    as "the two remaining terminals complete the third turn"
  assert alice_done.model.records == reader_done.model.records
}

// Reads forward until the socket carries a nonempty prefix of the answer now
// being written. Earlier answers cannot satisfy it: no other answer in this
// drive shares a first character with this one.
fn pushed_prefix(socket: Socket, answer: String, remaining: Int) -> Nil {
  assert remaining > 0
    as "the third answer is pushed to the wire client before its budget runs out"
  let frame = wire.frame(socket, within_ms: wire_read_ms)
  let text = case field(frame, "event") {
    json.String("stream_delta") -> field(field(frame, "body"), "text")
    _other -> json.Null
  }
  case text {
    json.String(text) if text != "" ->
      case string.starts_with(answer, text) {
        True -> Nil
        False -> pushed_prefix(socket, answer, remaining - 1)
      }
    _other -> pushed_prefix(socket, answer, remaining - 1)
  }
}

// Frames written before the server's close, counted rather than inspected.
// The count itself asserts nothing — those frames were authorized when they
// were written — but the loop has to consume them to reach the close, and
// reporting it keeps a failure here readable.
fn frames_until_close(socket: Socket, seen: Int, remaining: Int) -> Int {
  assert remaining > 0
    as "the revoked attachment is closed within the fixture's frame budget"
  let assert Ok(<<opcode, marker>>) = ffi_ws.tcp_receive(socket, 2, 5000)
    as "the hub writes a frame or closes the revoked socket"
  case opcode {
    // A close frame ends the stream. Its payload is the status code, read so
    // that the next receive observes the transport and not a leftover byte.
    0x88 -> {
      let assert Ok(<<1000:16>>) = ffi_ws.tcp_receive(socket, marker, 1000)
        as "the server closes normally rather than aborting the connection"
      seen
    }
    _other -> {
      assert opcode == 0x81
        as "the hub writes text frames until it closes the socket"
      skip_payload(socket, marker)
      frames_until_close(socket, seen + 1, remaining - 1)
    }
  }
}

// Consumes one text frame's body without decoding it. `wire.frame` is the
// decoder a fixture normally wants; here the frames are being counted on the
// way to a close, and their contents were already authorized.
fn skip_payload(socket: Socket, marker: Int) -> Nil {
  let size = case marker {
    126 -> {
      let assert Ok(<<size:16>>) = ffi_ws.tcp_receive(socket, 2, 1000)
        as "an extended frame length arrives with its frame"
      size
    }
    size if size < 126 -> size
    _other -> panic as "a pushed frame exceeds the fixture's frame budget"
  }
  let assert Ok(_) = ffi_ws.tcp_receive(socket, size, 1000)
    as "a frame's announced payload arrives complete"
  Nil
}

fn assert_shared_turns(
  drivers: List(actor.Started(process.Subject(tui_driver.Message))),
  turns: List(#(String, String)),
  answers: List(String),
) -> List(tui_driver.Sample) {
  let assert [operator, observer] = captured_turns(drivers, turns, answers)
    as "the operator and the observer each completed their own credited capture"
  assert operator.model.records == observer.model.records
  assert !writable(observer)
  [operator, observer]
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
