//// A saved session does not acquire a scanner merely because its configuration
//// now contains overdue work. A real peer progresses while that work remains
//// absent, then explicit admission fires it once. Read-only SQLite captures
//// retain the exact fired cell and message records across another stop/open.
//// This exercises one-shot residency, not recurring cursor coverage or memory
//// database absence. Maintenance is disabled through ordinary configuration.
//// A Held or Failed first tick retries after sixty seconds, beyond the
//// terminal helper's eight-second wait. That startup failure fails this test
//// loudly; the fixture does not alter scanner timing to conceal it.

import broker/token
import client/schedule
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/tui_v2_test
import core/codec
import core/entry
import core/json
import core/message
import core/register
import etui/backend
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import host/bootstrap as native
import host/endpoint
import simplifile
import sqlight
import storage/internal/snapshot_sqlite
import storage/snapshot
import support/provider_http as provider
import support/tui_driver
import tui/bootstrap
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection
import tui/session_channel
import weft
import weft/actor
import weft/poll

/// Proves ordinary shipped one-shot work remains deferred until explicit open.
///
/// ## Examples
///
/// `scripts/test.sh client --match daemon_shipped_schedule`.
pub fn daemon_shipped_schedule_defers_saved_and_never_replays_test_() -> EunitTest {
  // The runner scales this EUnit timeout by ten. The 90-second body and
  // independent native cleanup remain inside the 150-second test deadline.
  Timeout(15, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP shipped schedule: LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) -> {
        assert native.getenv("LOOM_TEST_PROVIDER_KEY") == Ok(provider.dummy_key)
        let #(Nil, report) =
          provider.with_server(
            [
              provider.Exchange("initialize A", "initialized"),
              provider.Exchange("B while A saved", "savedpeer"),
              provider.Exchange(injection(), "scheduledanswer"),
              provider.Exchange("B after A reopened", "reopenedpeer"),
            ],
            fn(url) { fixture(server, url) },
          )
        let assert Ok(requests) = report
          as "only the four exact ordinary provider requests occur"
        assert list.map(requests, fn(request) { request.latest })
          == [
            provider.UserPrompt("initialize A"),
            provider.UserPrompt("B while A saved"),
            provider.UserPrompt(injection()),
            provider.UserPrompt("B after A reopened"),
          ]
      }
    }
  })
}

fn injection() -> String {
  schedule.injection(
    schedule.Schedule(
      name: "saved-once",
      target: "main",
      owner: schedule.OperatorOwned,
      timing: schedule.OneShot(0),
      wake: schedule.WakesIdle,
      body: "scheduled while saved",
    ),
    schedule.Late,
    schedule.OperatorConfigured,
  )
}

fn fixture(server: String, url: String) -> Nil {
  let directory =
    "build/shipped-schedule-"
    <> bit_array.base16_encode(token.production_entropy()(16))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the native fixture has private state"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the fixture uses canonical paths"
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "cleanup retains its endpoint before launch"
  io.println_error("shipped schedule fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise(server, directory, paths, url)
        Ok(Nil)
      },
    ])
    |> weft.deadline(90_000)
    |> weft.start

  // Cleanup runs outside the body's deadline and before reporting assertions.
  retire_native(paths)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped schedule body completes without crashing or timing out"
  Nil
}

fn configuration(url: String) -> String {
  "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \""
  <> url
  <> "\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n"
}

fn exercise(
  server: String,
  directory: String,
  paths: endpoint.Paths,
  url: String,
) -> Nil {
  let workspace = directory <> "/a"
  assert simplifile.create_directory_all(workspace) == Ok(Nil)
  assert simplifile.create_directory_all(directory <> "/b") == Ok(Nil)
  let a_config = directory <> "/a.toml"
  let b_config = directory <> "/b.toml"
  assert simplifile.write(a_config, configuration(url)) == Ok(Nil)
  assert simplifile.write(b_config, configuration(url)) == Ok(Nil)

  // Both sessions belong to the same ordinary daemon, but configuration edits
  // remain session-local because each registration names its own file.
  let assert Ok(connected) =
    bootstrap.resolve_daemon(
      bootstrap.Options(workspace, "", server, paths.root, a_config),
      process.self(),
      40_000,
    )
    as "ordinary bootstrap starts the native daemon"
  let assert Ok(address) = endpoint.address(connected.record)
    as "the native endpoint is ready"
  let assert Ok(secret) = simplifile.read(connected.paths.token)
    as "the fixture owner reads its private credential"
  let owner = string.trim(secret)
  let assert Ok(host) = selection.host(connected.control, address, owner)
    as "the owner has an authenticated selector"

  // A completes real work before detach and stop; B retains its original
  // attachment throughout both of A's later admissions.
  let assert Ok(a) = selection.create(host, "schedule-A", workspace, a_config)
    as "A is explicitly created"
  let assert Ok(b) =
    selection.create(host, "schedule-B", directory <> "/b", b_config)
    as "B uses its own ordinary configuration"
  let assert Ok(a_driver) = tui_driver.start(address, owner, a.expected.session)
    as "A attaches over the actual session socket"
  let assert Ok(b_driver) = tui_driver.start(address, owner, b.expected.session)
    as "B attaches independently"
  let _ = tui_v2_test.await(a_driver.data, writable)
  let b_ready = tui_v2_test.await(b_driver.data, writable)
  prompt(a_driver, "initialize A")
  let _ = completed(a_driver, ["initialized"], 2)
  stop_driver(a_driver)
  stop_saved(connected.control, a.expected.session, retained: 1)

  // The fixed epoch timestamp is already overdue on every supported test host.
  // Editing only A's file must not start a runtime or mutate its saved store.
  let database = paths.root <> "/sessions/" <> a.expected.session <> ".db"
  let #(before_cut, before_messages) = observe(database)
  assert before_cut.cells == [] as "no fired mark exists before admission"
  assert list.length(before_messages) == 2
  assert simplifile.write(
      a_config,
      configuration(url)
        <> "\n[[schedule]]\nname = \"saved-once\"\nat = \"1970-01-01T00:00:00Z\"\nwake = true\nbody = \"scheduled while saved\"\n",
    )
    == Ok(Nil)

  // A positive provider completion in B brackets the negative Saved assertion.
  prompt(b_driver, "B while A saved")
  let b_done = completed(b_driver, ["savedpeer"], 2)
  assert_same_attachment(b_ready, b_done)
  assert_saved(connected.control, a.expected.session)
  assert observe(database) == #(before_cut, before_messages)
    as "B's real completed work leaves saved A's cut, transcript, and absent mark unchanged"

  // Admission reloads A's ordinary configuration and creates its scanner.
  let assert Ok(opened) = selection.open(host, a.expected.session)
    as "explicit open admits the overdue schedule"
  assert opened.expected.incarnation != a.expected.incarnation
  let assert Ok(replacement) =
    tui_driver.start(address, owner, a.expected.session)
    as "a fresh native attachment observes the scheduled completion"
  let _ = completed(replacement, ["scheduledanswer", "initialized"], 4)
  stop_driver(replacement)
  stop_saved(connected.control, a.expected.session, retained: 1)

  // Compare immutable records after original retirement, not terminal text
  // alone. The exact-key selection also retains the fired value and sequence.
  let #(fired_cut, fired_messages) = observe(database)
  let assert [_] = fired_cut.cells
    as "the exact one-shot fired cell is now durable"
  assert list.length(fired_messages) == 4
  assert list.take(fired_messages, 2) == before_messages
    as "scheduled admission preserves the original immutable records"
  let assert [
    entry.MessageEntry(
      message: message.UserMessage(content: [message.UserText(text, None)], ..),
      ..,
    ),
    entry.MessageEntry(
      message: message.AssistantMessage(
        content: [message.AssistantText("scheduledanswer", None)],
        stop_reason: message.Stop,
        ..,
      ),
      ..,
    ),
  ] = list.drop(fired_messages, 2)
    as "one scheduled user and one successful assistant are the only added message records"
  assert text == injection()

  // A new validated attachment plus B's next committed response are positive
  // progress barriers. The final Saved read compares durable records and the
  // original fired sequence, rather than accepting a stale terminal sample.
  let assert Ok(reopened) = selection.open(host, a.expected.session)
    as "the same configured schedule is read on another explicit open"
  assert reopened.expected.incarnation != opened.expected.incarnation
  let assert Ok(last) = tui_driver.start(address, owner, a.expected.session)
    as "the second incarnation publishes a fresh credited cut"
  let _ = completed(last, ["scheduledanswer", "initialized"], 4)
  prompt(b_driver, "B after A reopened")
  let final_b = completed(b_driver, ["reopenedpeer", "savedpeer"], 4)
  assert_same_attachment(b_ready, final_b)
  stop_driver(last)
  stop_saved(connected.control, a.expected.session, retained: 1)

  // The second original runtime has retired before the final durable oracle.
  let #(final_cut, final_messages) = observe(database)
  assert final_cut.cells == fired_cut.cells
    as "reopen preserves the exact original fired value and sequence"
  assert final_messages == fired_messages
    as "reopen appends no repeated schedule prompt, response, or other message variant"
  stop_driver(b_driver)
  daemon.close(connected.control)
}

fn observe(path: String) -> #(snapshot.Cut, List(entry.Entry)) {
  let encoded =
    path
    |> string.split("/")
    |> list.map(uri.percent_encode)
    |> string.join("/")
  let assert Ok(connection) =
    sqlight.open("file:" <> encoded <> "?mode=ro&cache=private")
    as "observation opens an existing database read-only without a writer lease"
  let captured =
    snapshot_sqlite.capture(
      connection,
      snapshot.Plan(
        [
          snapshot.ExactKey(
            register.FactCustom,
            schedule.fired_key("main", "saved-once", 0),
          ),
        ],
        [],
        100,
      ),
    )
  let records =
    result.map(captured, fn(cut) {
      assert list.length(cut.recent) < 100
        as "the bounded fixture inventory is complete"
      list.map(cut.recent, fn(descriptor) {
        assert descriptor.byte_length <= snapshot.fragment_bytes_limit
          as "each fixture record fits a single bounded fragment"
        snapshot_sqlite.fragment(connection, descriptor, 0)
      })
    })
  assert sqlight.close(connection) == Ok(Nil)
    as "the original read-only native connection closes before assertions decode payloads"
  let assert Ok(cut) = captured as "the coherent saved cut is readable"
  let assert Ok(records) = records
    as "the complete bounded inventory is readable"
  let entries =
    list.map(records, fn(record) {
      let assert Ok(bytes) = record as "the immutable fragment is readable"
      let assert Ok(text) = bit_array.to_string(bytes)
        as "entry bytes are UTF-8"
      let assert Ok(value) = json.parse(text) as "entry bytes contain JSON"
      let assert Ok(decoded) = codec.decode_entry(value)
        as "the core entry codec accepts the record"
      decoded
    })
  #(
    cut,
    list.filter(entries, fn(item) {
      case item {
        entry.MessageEntry(..) -> True
        _ -> False
      }
    }),
  )
}

// Saved is a claim about one session slot, not about the workspace domain that
// slot depended on. The registry fences that domain when its last dependent
// retires and keeps the fenced slot in its book until the witness exits, and
// every admission naming it in that window is refused `unavailable` — the same
// retention `closing_domain_counts_capacity_after_session_slot_retires_test`
// pins down against the registry directly. So a stop that another explicit open
// follows needs the daemon's own domain census as its second barrier, and
// `retained` is the domains that legitimately outlive this stop: B holds one
// workspace domain of its own and stays resident across every stop here.
fn stop_saved(
  control: daemon.Connection,
  session: String,
  retained retained: Int,
) -> Nil {
  let assert Ok(protocol.LifecycleReply(protocol.Stopping(_))) =
    daemon.request(control, protocol.StopSession(session), 5000)
    as "the owner receives the exact stop acknowledgement"
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case daemon.request(control, protocol.GetSession(session), 2000) {
        Ok(protocol.SessionReply(protocol.Session(status: protocol.Saved, ..))) ->
          poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
    as "original retirement reaches Saved before offline observation"

  // Reading the census is also what advances it: the registry reclaims drained
  // domain slots on every message it handles, so the poll that observes the
  // count is the same traffic that retires the slot being waited on.
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case daemon.request(control, protocol.Status, 2000) {
        Ok(protocol.StatusReply(summary))
          if summary.domain_occupied <= retained
        -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
    as "the retired session's domain is reclaimed before the next admission"
  Nil
}

fn assert_saved(control: daemon.Connection, session: String) -> Nil {
  let assert Ok(protocol.SessionReply(protocol.Session(
    status: protocol.Saved,
    ..,
  ))) = daemon.request(control, protocol.GetSession(session), 2000)
    as "a fresh control request confirms A remains Saved"
  Nil
}

fn assert_same_attachment(
  before: tui_driver.Sample,
  after: tui_driver.Sample,
) -> Nil {
  let assert Some(#(before, _)) = before.model.captured
    as "B originally has a validated cut"
  let assert Some(#(after, _)) = after.model.captured
    as "B still has a validated cut"
  assert before.attachment == after.attachment
}

fn prompt(
  driver: actor.Started(process.Subject(tui_driver.Message)),
  text: String,
) -> Nil {
  let _ =
    tui_driver.play(driver.data, [
      backend.Paste(text),
      backend.KeyPress("enter"),
    ])
  Nil
}

fn completed(
  driver: actor.Started(process.Subject(tui_driver.Message)),
  answers: List(String),
  count: Int,
) -> tui_driver.Sample {
  tui_v2_test.await(driver.data, fn(sample) {
    let messages =
      list.filter_map(sample.model.records, fn(record) {
        case record.entry {
          entry.MessageEntry(message:, ..) -> Ok(message)
          _ -> Error(Nil)
        }
      })
    let actual =
      list.filter_map(messages, fn(item) {
        case item {
          message.AssistantMessage(
            content: [message.AssistantText(text, None)],
            stop_reason: message.Stop,
            ..,
          ) -> Ok(text)
          _ -> Error(Nil)
        }
      })
    writable(sample)
    && actual == answers
    && list.length(messages) == count
    && sample.model.streams == []
    && list.any(sample.model.strands, fn(strand) {
      strand.id == "main" && strand.live_phase == None
    })
  })
}

fn writable(sample: tui_driver.Sample) -> Bool {
  case sample.model.channel {
    Some(channel) -> session_channel.mutation_available(channel)
    None -> False
  }
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
    as "the original native driver retires normally"
  Nil
}

fn retire_native(paths: endpoint.Paths) -> Nil {
  let assert Ok(record) = endpoint.load(paths)
    as "cleanup reads its private reservation"
  case record {
    None -> Nil
    Some(record) -> {
      let assert Ok(present) = endpoint.is_present(record.fence)
        as "cleanup checks original PID birth"
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
        as "native departure is observed before fixture completion"
      Nil
    }
  }
}
