//// Stop a shipped session during an unfinished real HTTP provider response.
//// A second session progresses before and after that stop on its original
//// native attachment. Explicit reopen resumes the admitted operation under a
//// new incarnation; it must not create a second durable user message.
//// This proves ordinary cancellation, not an uncooperative drain or a crash.

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/tui_v2_test
import core/entry
import core/message
import etui/backend
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as native
import host/endpoint
import simplifile
import support/provider_held_http as held
import support/provider_http as provider
import support/tui_driver
import tui/bootstrap
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection
import tui/session_channel
import tui/snapshot
import weft
import weft/actor
import weft/poll

/// Exercises ordinary stop and durable operation recovery in the shipped VM.
///
/// ## Examples
///
/// `scripts/test.sh client --match daemon_shipped_stop`.
pub fn daemon_shipped_stop_preserves_peer_and_recovers_operation_test_() -> EunitTest {
  // The runner scales EUnit timeouts by ten. Keep the 90-second native body,
  // its independent cleanup, and the 110/120-second peers inside 150 seconds.
  Timeout(15, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP shipped stop: LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) -> {
        assert native.getenv("LOOM_TEST_PROVIDER_KEY") == Ok(provider.dummy_key)
        let #(Nil, report) =
          provider.with_server(
            [
              provider.Exchange("B before stop", "beforeanswer"),
              provider.Exchange("B after stop", "afteranswer"),
            ],
            fn(b_url) {
              held.with_server(fn(a_url, witness) {
                fixture(server, a_url, b_url, witness)
              })
            },
          )
        let assert Ok(requests) = report
          as "B completes exactly the two expected provider exchanges"
        assert list.map(requests, fn(request) { request.latest })
          == [
            provider.UserPrompt("B before stop"),
            provider.UserPrompt("B after stop"),
          ]
      }
    }
  })
}

fn fixture(
  server: String,
  a_url: String,
  b_url: String,
  witness: held.Witness,
) -> Nil {
  let directory =
    "build/shipped-stop-"
    <> bit_array.base16_encode(token.production_entropy()(16))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the native fixture has private state"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the native fixture uses absolute paths"
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "cleanup retains the private endpoint before launch"
  io.println_error("shipped stop fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise(server, directory, paths, a_url, b_url, witness)
        Ok(Nil)
      },
    ])
    |> weft.deadline(90_000)
    |> weft.start

  // Native cleanup is outside the body deadline, including failed assertions.
  // A closed control port never substitutes for this original PID-birth check.
  retire_native(paths)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped stop body completes before cleanup reports success"
  Nil
}

fn configuration(path: String, url: String) -> Nil {
  assert simplifile.write(
      path,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \""
        <> url
        <> "\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n",
    )
    == Ok(Nil)
}

fn exercise(
  server: String,
  directory: String,
  paths: endpoint.Paths,
  a_url: String,
  b_url: String,
  witness: held.Witness,
) -> Nil {
  let workspace = directory <> "/a"
  assert simplifile.create_directory_all(workspace) == Ok(Nil)
  assert simplifile.create_directory_all(directory <> "/b") == Ok(Nil)
  let a_config = directory <> "/a.toml"
  let b_config = directory <> "/b.toml"
  configuration(a_config, a_url)
  configuration(b_config, b_url)
  let assert Ok(connected) =
    bootstrap.resolve_daemon(
      bootstrap.Options(workspace, "", server, paths.root, a_config),
      process.self(),
      40_000,
    )
    as "ordinary bootstrap starts and authenticates the supplied shipped daemon"
  let assert Ok(address) = endpoint.address(connected.record)
    as "the original native endpoint is ready"
  let assert Ok(token) = simplifile.read(connected.paths.token)
    as "the owner reads only its private fixture credential"
  let owner = string.trim(token)
  let assert Ok(host) = selection.host(connected.control, address, owner)
    as "the authenticated owner has a session selector"
  let assert Ok(a) = selection.create(host, "held-A", workspace, a_config)
    as "A starts through ordinary durable creation"
  let assert Ok(b) =
    selection.create(host, "peer-B", directory <> "/b", b_config)
    as "B has an independent configured workspace"
  let assert Ok(a_driver) = tui_driver.start(address, owner, a.expected.session)
    as "A uses a real native terminal"
  let assert Ok(b_driver) = tui_driver.start(address, owner, b.expected.session)
    as "B uses a concurrent native terminal"
  let a_ready = tui_v2_test.await(a_driver.data, writable)
  let b_ready = tui_v2_test.await(b_driver.data, writable)
  let b_attachment = attachment_of(b_ready)
  let assert Some(b_channel) = b_ready.model.channel
    as "B owns an adopted channel before A starts"

  // The actual complete request and streamed start precede A's captured live
  // operation. B's first completed answer is independent of the held response.
  prompt(a_driver, "held A prompt")
  held.await_started(witness)
  let _ =
    tui_v2_test.await(a_driver.data, fn(sample) {
      users(sample) == ["held A prompt"]
      && list.any(sample.model.strands, fn(strand) {
        strand.id == "main" && strand.live_phase != None
      })
    })
  prompt(b_driver, "B before stop")
  let _ = complete(b_driver, ["B before stop"], ["beforeanswer"])

  // Reject closure or a recovered request already observed before StopSession.
  // This snapshot is not a cross-sender linearization point for the next call.
  assert held.snapshot(witness) == #(1, None)
    as "the original request is still the only observed request before stop"
  let assert Ok(protocol.LifecycleReply(protocol.Stopping(_))) =
    daemon.request(
      connected.control,
      protocol.StopSession(a.expected.session),
      5000,
    )
    as "the owner receives A's stop acknowledgement on its original control"
  held.await_closed(witness)
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case
        daemon.request(
          connected.control,
          protocol.GetSession(a.expected.session),
          2000,
        )
      {
        Ok(protocol.SessionReply(protocol.Session(status: protocol.Saved, ..))) ->
          poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
    as "the same owner control observes authoritative Saved after real drain"

  prompt(b_driver, "B after stop")
  let b_done =
    complete(b_driver, ["B after stop", "B before stop"], [
      "afteranswer",
      "beforeanswer",
    ])
  assert attachment_of(b_done) == b_attachment
  let assert Some(channel) = b_done.model.channel
    as "B retains its channel after A's retirement"
  assert session_channel.socket(channel) == session_channel.socket(b_channel)
  stop_driver(a_driver)

  // Close deliberately leaves the admitted operation durable. Reopen must
  // issue its recovered request and finish once, not append another user turn.
  assert held.snapshot(witness) == #(1, Some(held.ClientClosed))
    as "original closure is observed without a replacement request before reopen"
  let assert Ok(reopened) = selection.open(host, a.expected.session)
    as "only explicit reopen resumes A"
  assert reopened.expected.session == a.expected.session
  assert reopened.expected.incarnation != a.expected.incarnation
  let assert Ok(replacement) =
    tui_driver.start(address, owner, a.expected.session)
    as "a fresh native terminal attaches after recovery"
  let recovered =
    tui_v2_test.await(replacement.data, fn(sample) {
      replies(sample) == ["recoveredanswer"]
      && list.length(recorded_messages(sample)) == 3
      && sample.model.streams == []
      && list.any(sample.model.strands, fn(strand) {
        strand.id == "main" && strand.live_phase == None
      })
    })
  assert held.snapshot(witness) == #(2, Some(held.ClientClosed))
    as "the completed recovery observes exactly the second request and original closure"

  // Recovery records the unknown outcome under its reserved message identity
  // before continuing. That synthetic settlement is required, not discarded.
  let assert [
    message.AssistantMessage(
      content: [message.AssistantText("recoveredanswer", None)],
      stop_reason: message.Stop,
      ..,
    ),
    message.AssistantMessage(
      content: [],
      stop_reason: message.Errored,
      error_message: Some(interruption),
      ..,
    ),
    message.UserMessage(content: [message.UserText("held A prompt", None)], ..),
  ] = recorded_messages(recovered)
    as "recovery completes one admitted durable user message, without duplicate admission or hidden message variants"
  assert interruption
    == "interrupted: the preceding content is the latest committed partial; newer live output may be missing and the external outcome is unknown"
  assert attachment_of(recovered).expected == reopened.expected
  assert attachment_of(recovered).expected.epoch
    == attachment_of(a_ready).expected.epoch
  list.each([replacement, b_driver], stop_driver)
  daemon.close(connected.control)
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

fn complete(
  driver: actor.Started(process.Subject(tui_driver.Message)),
  prompts: List(String),
  answers: List(String),
) -> tui_driver.Sample {
  tui_v2_test.await(driver.data, fn(sample) {
    users(sample) == prompts
    && replies(sample) == answers
    && list.length(recorded_messages(sample))
    == list.length(prompts) + list.length(answers)
    && sample.model.streams == []
    && list.any(sample.model.strands, fn(strand) {
      strand.id == "main" && strand.live_phase == None
    })
  })
}

// Count every message variant before applying the text projections, so an
// unexpected invocation, result, or malformed content cannot disappear.
fn recorded_messages(sample: tui_driver.Sample) -> List(message.AgentMessage) {
  list.filter_map(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(message:, ..) -> Ok(message)
      _ -> Error(Nil)
    }
  })
}

fn users(sample: tui_driver.Sample) -> List(String) {
  list.filter_map(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(
        message: message.UserMessage(
          content: [message.UserText(text, None)],
          ..,
        ),
        ..,
      ) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

fn replies(sample: tui_driver.Sample) -> List(String) {
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

fn writable(sample: tui_driver.Sample) -> Bool {
  case sample.model.channel {
    Some(channel) -> session_channel.mutation_available(channel)
    None -> False
  }
}

fn attachment_of(sample: tui_driver.Sample) -> snapshot.Attachment {
  let assert Some(#(cut, _)) = sample.model.captured
    as "identity comes from the accepted snapshot"
  cut.attachment
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
    as "cleanup decodes its private native reservation"
  case record {
    None -> Nil
    Some(record) -> {
      let assert Ok(present) = endpoint.is_present(record.fence)
        as "cleanup checks original PID birth before signalling"
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
        as "actual native departure is witnessed before fixture completion"
      Nil
    }
  }
}
