//// Two fixed TLS BEAM roles preserve the original native component controls.
//// The executor owns the real helper, native service and SQLite journal. The
//// owner uses the production endpoint and dispatcher; opaque actor handles are
//// shared only for the original direct administrative evidence assertions.
//// A test-only service alias holds, rejects or parks an actual service answer
//// after the real operation completes. No test fabricates native evidence.

import argv
import distribution_fixture as provision
import executor/remote/beam_endpoint as endpoint
import executor/remote/distribution
import executor/remote/journal
import executor/remote/service
import executor/remote/wire
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/timestamp
import simplifile
import weft
import weft/actor
import weft/poll

/// The fixed owner receives the original concrete administrative handles.
pub type Fixture {
  /// No field grants fresh native permission; original production APIs do that.
  Fixture(
    /// Native scratch tree excludes the sibling private TLS credential tree.
    path: String,
    /// Peer derives from this owner's successful local membership.
    connection: endpoint.Config,
    /// Actual executor service, separate from the test fault alias.
    service: service.Service,
    /// Actual executor journal actor; its SQLite connection stays remote.
    journal: journal.Journal,
    /// Actual registered endpoint used to observe its finite credits.
    endpoint: endpoint.Server,
    /// Fixed test fault administration, never a production transport callback.
    fault: process.Subject(ProxyMessage),
  )
}

/// Fixed fault choices match the original real-service-then-fault controls.
pub type ReplyStage {
  /// Hold the real Submit response beyond owner observation.
  AdmissionReply

  /// Hold the real Stdin acknowledgement beyond owner observation.
  InputReply

  /// Refuse a Stdin response after the actual service consumes the input.
  RejectedInputReply

  /// Park an actual Output response behind this one test permit.
  PausedOutputReply(gate: process.Subject(process.Subject(Nil)))

  /// Hold the next actual terminal response.
  TerminalReply

  /// Hold the actual durable receipt response.
  ReceiptReply

  /// Hold actual Query responses to occupy the two control credits.
  HoldQueries

  /// Forward actual responses without further faults.
  Finished
}

/// Only the fixed fixture administrator and native service alias use this door.
pub type ProxyMessage {
  /// Same closed Exchange shape used by the original native service.
  Exchange(wire.Envelope, process.Subject(Result(wire.Body, service.Error)))

  /// Install one known test fault before any matching operation.
  Set(ReplyStage, process.Subject(Nil))

  /// Release all held actual answers without changing the fault sequence.
  Release(process.Subject(Nil))

  /// Release one held answer to prove credit recovery with another still held.
  ReleaseOne(process.Subject(Nil))

  /// The one parked Output permit has been explicitly returned.
  Permit

  /// Stop this test actor after the production endpoint has joined.
  Stop
}

type CaseState {
  CaseState(
    service: service.Service,
    journal: journal.Journal,
    endpoint: endpoint.Server,
    fault: process.Subject(ProxyMessage),
  )
}

type Choice {
  Forward
  Hold
  Reject
  Pause(process.Subject(process.Subject(Nil)))
}

type Held {
  Held(
    reply: process.Subject(Result(wire.Body, service.Error)),
    answer: Result(wire.Body, service.Error),
  )
}

type Proxy {
  Proxy(
    actual: service.Service,
    stage: ReplyStage,
    held: List(Held),
    permit: Option(process.Subject(Nil)),
    selector: process.Selector(ProxyMessage),
  )
}

type JournalControl {
  JournalCommand(Dynamic)
  JournalStop
}

// Erlang's term codec preserves actual PID/reference-bearing opaque handles
// between these fixed local test roles; no pure portable byte codec can do so.
@external(erlang, "executor_remote_native_beam_fixture_ffi", "publish")
fn publish(path: String, value: CaseState) -> Result(Nil, Nil)

@external(erlang, "executor_remote_native_beam_fixture_ffi", "read")
fn read(path: String) -> Result(CaseState, Nil)

// This test-only alias retains the original checked config and changes only
// its local reply door. Production has no opaque-service replacement API.
@external(erlang, "executor_remote_native_beam_fixture_ffi", "alias")
fn alias(
  actual: service.Service,
  subject: process.Subject(ProxyMessage),
  pid: process.Pid,
) -> service.Service

// Journal's public observer is intentionally local. This fixed owner relay
// forwards only Inspect, ReadPayload and Release to the original remote actor,
// keeping the real reply subject and immutable scope without reopening SQLite.
@external(erlang, "executor_remote_native_beam_fixture_ffi", "journal_alias")
fn journal_alias(
  actual: journal.Journal,
  subject: process.Subject(Dynamic),
) -> journal.Journal

@external(erlang, "executor_remote_native_beam_fixture_ffi", "forward_journal")
fn forward_journal(actual: journal.Journal, message: Dynamic) -> Nil

/// Runs one unchanged public test entrypoint in its fixed authenticated owner VM.
///
/// ## Examples
/// `use fixture <- run("fixed_test")` executes the body once in the owner role.
pub fn run(name: String, body: fn(Fixture) -> Nil) -> Nil {
  case argv.load().arguments {
    ["--native-beam-owner", root, actual] if actual == name -> {
      owner_body(root, name, body)
    }
    _ -> run_nodes(name, None)
  }
}

/// Runs both original stdin-fault scenarios as distinct fully checked role pairs.
///
/// ## Examples
/// `run_stage(name, InputReply, body)` runs exactly that fixed fault scenario.
pub fn run_stage(
  name: String,
  stage: ReplyStage,
  body: fn(Fixture) -> Nil,
) -> Nil {
  case argv.load().arguments {
    ["--native-beam-owner", root, actual, selected] if actual == name -> {
      case selected == stage_name(stage) {
        True -> owner_body(root, name, body)
        False -> Nil
      }
    }
    _ -> run_nodes(name, Some(stage_name(stage)))
  }
}

fn owner_body(root: String, name: String, body: fn(Fixture) -> Nil) -> Nil {
  let assert Ok(configured) = provision.read_provisioned(root <> "/tls.term")
    as "The owner reads its original fixed administrative fixture."
  let assert Ok(membership) = distribution.start(configured.owner_config)
    as "The owner boots real authenticated TLS distribution."
  let assert Ok(peer) = distribution.peer(membership, configured.executor_name)
    as "Peer provenance comes from this owner's successful bootstrap."
  await(root, "state.term")
  let assert Ok(state) = read(root <> "/state.term")
    as "Only the executor's actual opaque actor handles are published."

  // Administrative evidence handles are not endpoint discovery. Establish the
  // original authenticated peer before any fixed remote actor observation.
  let assert Ok(Nil) = distribution.connect(peer, 2500)
    as "The fixed executor peer connects before direct evidence queries."
  let native = service.configuration(state.service)
  let assert Ok(observer) =
    actor.new_with_initialiser(1000, fn(stop) {
      let observations = process.new_subject()
      Ok(
        actor.initialised(state.journal)
        |> actor.selecting(
          process.new_selector()
          |> process.select(stop)
          |> process.select_map(observations, JournalCommand),
        )
        |> actor.returning(#(observations, stop)),
      )
    })
    |> actor.on_message(fn(actual, message) {
      case message {
        JournalCommand(command) -> {
          forward_journal(actual, command)
          actor.continue(actual)
        }
        JournalStop -> actor.stop()
      }
    })
    |> actor.start
    as "The fixed local observer forwards only actual executor journal answers."
  let fixture =
    Fixture(
      root <> "/data",
      endpoint.Config(
        peer,
        native.owner,
        native.executor,
        native.scope,
        native.generation,
        2500,
      ),
      state.service,
      journal_alias(state.journal, observer.data.0),
      state.endpoint,
      state.fault,
    )
  body(fixture)
  let observer_down = process.monitor(observer.pid)
  process.send(observer.data.1, JournalStop)
  join(observer_down)
  mark(root, "owner-done")
  await(root, "executor-done")
  io.println("NATIVE_BEAM_OWNER_COMPLETED:" <> name)
}

fn stage_name(stage: ReplyStage) -> String {
  case stage {
    InputReply -> "held-input"
    RejectedInputReply -> "refused-input"
    _ -> panic as "Only the two original stdin scenarios select a role pair."
  }
}

/// Returns only the explicit fixed executor role's administrative arguments.
///
/// ## Examples
/// `executor_arguments()` identifies the original root and test name.
pub fn executor_arguments() -> #(String, String) {
  let assert ["--native-beam-executor", root, name, ..] = argv.load().arguments
    as "Only the fixed executor entrypoint uses this helper."
  #(root, name)
}

/// Registers the real native service behind a fixed test reply barrier.
///
/// ## Examples
/// `host(root, actual, book)` joins transport after the owner's native drain.
pub fn host(
  root: String,
  actual: service.Service,
  book: journal.Journal,
) -> Nil {
  let assert Ok(configured) = provision.read_provisioned(root <> "/tls.term")
    as "The executor retains the original private administrative fixture."
  let assert Ok(membership) = distribution.start(configured.executor_config)
    as "The executor boots authenticated TLS before endpoint publication."
  let assert Ok(owner) = distribution.peer(membership, configured.owner_name)
    as "Only the original authenticated owner can reserve credits."
  let assert Ok(proxy) =
    actor.new_with_initialiser(1000, fn(subject) {
      let selector = process.new_selector() |> process.select(subject)
      Ok(
        actor.initialised(Proxy(actual, Finished, [], None, selector))
        |> actor.selecting(selector)
        |> actor.returning(subject),
      )
    })
    |> actor.on_message(handle_proxy)
    |> actor.start
    as "The fixed reply fault actor links to this executor role."
  let wrapped = alias(actual, proxy.data, proxy.pid)
  let assert Ok(row) =
    endpoint.registration(owner, wrapped, None, process.self())
    as "The alias retains exact original native scope, labels and generation."
  let assert Ok(server_config) = endpoint.configure_server([row], 10_000)
    as "The endpoint has fixed four data and two control credits."
  let assert Ok(server) = endpoint.start(server_config)
    as "The actual production endpoint publishes only after successful TLS boot."
  assert publish(
      root <> "/state.term",
      CaseState(actual, book, server, proxy.data),
    )
    == Ok(Nil)
  await(root, "owner-done")

  // Endpoint death is a transport witness only. The owner body separately
  // checks actual native scope retirement and journal release before this file.
  let endpoint_down = process.monitor(endpoint.pid(server))
  endpoint.stop(server)
  join(endpoint_down)
  let proxy_down = process.monitor(proxy.pid)
  process.send(proxy.data, Stop)
  join(proxy_down)
  mark(root, "executor-done")
  io.println("NATIVE_BEAM_EXECUTOR_COMPLETED")
}

/// Installs one fixed fault choice before production transport starts.
///
/// ## Examples
/// `fault(fixture, InputReply)` holds the real Stdin acknowledgement.
pub fn fault(fixture: Fixture, stage: ReplyStage) -> endpoint.Config {
  assert process.call(fixture.fault, 1000, Set(stage, _)) == Nil
  fixture.connection
}

/// Releases actual replies, then requires both answer and managed transport drain.
///
/// ## Examples
/// `release(fixture)` cannot infer a credit from a caller timeout alone.
pub fn release(fixture: Fixture) -> Nil {
  assert process.call(fixture.fault, 1000, Release) == Nil
  let assert poll.Answered(Nil) =
    poll.until(2000, 5, fn() {
      case endpoint.inspect(fixture.endpoint) {
        Ok(endpoint.Capacity(1, 4, 2)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "Actual answers and network drain restore every fixed credit."
  Nil
}

/// Releases one answer while another original Query remains held.
///
/// ## Examples
/// `release_one(fixture)` proves recovery without replacing service or journal.
pub fn release_one(fixture: Fixture) -> Nil {
  assert process.call(fixture.fault, 1000, ReleaseOne) == Nil
  let assert poll.Answered(Nil) =
    poll.until(2000, 5, fn() {
      case endpoint.inspect(fixture.endpoint) {
        Ok(endpoint.Capacity(1, 4, 1)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "One actual answer and its drain reclaim one control credit."
  Nil
}

fn handle_proxy(
  state: Proxy,
  message: ProxyMessage,
) -> actor.Next(Proxy, ProxyMessage) {
  case message {
    Exchange(envelope, reply) -> {
      // The actual operation always happens before the test faults its answer.
      let answer = service.exchange(state.actual, envelope)
      let #(choice, stage) = choose(state.stage, envelope.body, answer)
      let state = Proxy(..state, stage:)
      case choice {
        Forward -> {
          process.send(reply, answer)
          actor.continue(state)
        }
        Reject -> {
          process.send(reply, Ok(wire.Rejected(2)))
          actor.continue(state)
        }
        Hold ->
          actor.continue(
            Proxy(..state, held: [Held(reply, answer), ..state.held]),
          )
        Pause(gate) -> {
          let permit = process.new_subject()
          process.send(gate, permit)
          let selector =
            process.select_map(state.selector, permit, fn(_) { Permit })
          actor.continue(
            Proxy(
              ..state,
              held: [Held(reply, answer)],
              permit: Some(permit),
              selector:,
            ),
          )
          |> actor.with_selector(selector)
        }
      }
    }
    Set(stage, reply) -> {
      process.send(reply, Nil)
      actor.continue(Proxy(..state, stage:))
    }
    Release(reply) -> {
      list.each(state.held, fn(held) { process.send(held.reply, held.answer) })
      process.send(reply, Nil)
      actor.continue(Proxy(..state, held: []))
    }
    ReleaseOne(reply) -> {
      let held = case state.held {
        [first, ..rest] -> {
          process.send(first.reply, first.answer)
          rest
        }
        [] -> []
      }
      process.send(reply, Nil)
      actor.continue(Proxy(..state, held:))
    }
    Permit -> {
      list.each(state.held, fn(held) { process.send(held.reply, held.answer) })
      let selector = case state.permit {
        Some(permit) -> process.deselect(state.selector, permit)
        None -> state.selector
      }
      actor.continue(Proxy(..state, held: [], permit: None, selector:))
      |> actor.with_selector(selector)
    }
    Stop -> actor.stop()
  }
}

fn choose(
  stage: ReplyStage,
  body: wire.Body,
  answer: Result(wire.Body, service.Error),
) -> #(Choice, ReplyStage) {
  case stage, body, answer {
    AdmissionReply, wire.Submit(_, _, _, _, _), Ok(_) -> #(Hold, TerminalReply)
    InputReply, wire.Stdin(_, _, _, _, _), Ok(_) -> #(Hold, Finished)
    RejectedInputReply, wire.Stdin(_, _, _, _, _), Ok(_) -> #(Reject, Finished)
    TerminalReply, _, Ok(wire.Terminal(_, _, _)) -> #(Hold, ReceiptReply)
    ReceiptReply, wire.DurableReceipt(_, _, _), Ok(_) -> #(Hold, Finished)
    PausedOutputReply(gate), _, Ok(wire.Output(_, _, _, _)) -> #(
      Pause(gate),
      Finished,
    )
    HoldQueries, wire.Query(_, _, _), Ok(_) -> #(Hold, HoldQueries)
    _, _, _ -> #(Forward, stage)
  }
}

fn run_nodes(name: String, stage: Option(String)) -> Nil {
  assert safe_name(name)
  let assert Ok(here) = simplifile.current_directory()
    as "The original package path is retained."
  assert simplifile.create_directory_all(here <> "/build") == Ok(Nil)
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    here
    <> "/build/native-beam-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(configured) = provision.provision(root, "native")
    as "Two distinct certificate pins and fixed private cookie homes are provisioned."
  assert provision.write_provisioned(configured, root <> "/tls.term") == Ok(Nil)
  let roles = [
    #(
      configured.executor_config,
      configured.executor_options,
      "remote_native_test:beam_executor_main(),halt(0).",
      "--native-beam-executor",
      "executor",
    ),
    #(
      configured.owner_config,
      configured.owner_options,
      "remote_native_test:'" <> name <> "'(),halt(0).",
      "--native-beam-owner",
      "owner",
    ),
  ]
  let outcomes =
    weft.new_prepared(
      list.map(roles, fn(role) {
        let #(config, options, entrypoint, flag, label) = role
        weft.managed(fn(_) {
          let answer =
            provision.run_node(
              provision.current_executable(),
              list.append(
                provision.node_arguments(options),
                list.append(
                  ["-noshell", "-eval", entrypoint, "-extra", flag, root, name],
                  case stage {
                    Some(stage) -> [stage]
                    None -> []
                  },
                ),
              ),
              here,
              distribution.bootstrap_home(config),
            )
          case answer {
            Ok(#(_, output)) -> {
              assert simplifile.write(root <> "/" <> label <> ".log", output)
                == Ok(Nil)
            }
            Error(error) -> {
              assert simplifile.write(root <> "/" <> label <> ".log", error)
                == Ok(Nil)
            }
          }
          answer
        })
      }),
    )
    |> weft.deadline(25_000)
    |> weft.start
  let assert [executor_result, owner_result] = weft.values(outcomes)
    as "Both role runners return; a failed run retains its original logs."
  list.each([executor_result, owner_result], fn(value) {
    let #(exit, output) = value
    assert exit == 0 as output
  })
  let assert Ok(output) = simplifile.read(root <> "/owner.log")
    as "Owner output is retained before checking witnesses."
  assert string.contains(output, "NATIVE_BEAM_OWNER_COMPLETED:" <> name)
  assert simplifile.is_file(root <> "/executor-done") == Ok(True)
  assert simplifile.delete(root) == Ok(Nil)
}

fn safe_name(name: String) -> Bool {
  name != ""
  && list.all(string.to_graphemes(name), fn(char) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", char)
  })
}

fn mark(root: String, name: String) -> Nil {
  assert simplifile.write(root <> "/" <> name, "done") == Ok(Nil)
}

fn await(root: String, name: String) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(20_000, 5, fn() {
      case simplifile.is_file(root <> "/" <> name) {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "The fixed role reaches its finite readiness or completion barrier."
  Nil
}

fn join(monitor: process.Monitor) -> Nil {
  let assert Ok(process.ProcessDown(_, _, process.Normal)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "The concrete transport or test actor actually stops normally."
  Nil
}
