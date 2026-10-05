//// Fixed executor-side host tests run in two actual TLS-distributed OS nodes.
//// The original helper and journal stay local to executor assertions. A bounded
//// owner actor invokes the production endpoint under its own authenticated Peer.
//// This fixture supplies no native answer or retirement evidence.

import argv
import distribution_fixture as provision
import executor/remote/beam_endpoint as endpoint
import executor/remote/distribution
import executor/remote/identity
import executor/remote/wire
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam/time/timestamp
import simplifile
import weft
import weft/actor
import weft/poll

/// Original local endpoint and authenticated owner test door.
pub type Context {
  /// These are administration handles, not native outcome witnesses.
  Context(
    /// One shared executor-node endpoint for all hosts in this role.
    endpoint: endpoint.Server,
    /// Owner Peer from this executor's actual successful membership.
    owner: distribution.Peer,
    /// Remote owner administration door used only by this fixed fixture.
    door: process.Subject(OwnerMessage),
  )
}

/// Fixed binding selected by the test, with the original owner request door.
pub type Client {
  /// Peer authentication occurs in the owner VM's production exchange.
  Client(
    /// Original scope, including both epochs.
    scope: identity.Scope,
    /// Concrete remote owner test actor.
    door: process.Subject(OwnerMessage),
  )
}

/// Closed test administration performs only native endpoint exchange and stop.
pub type OwnerMessage {
  /// The reply contains the production endpoint's actual answer.
  Exchange(
    /// Full original native scope used by the real production exchange.
    scope: identity.Scope,
    /// Closed actual native request; no fixture-supplied outcome is accepted.
    body: wire.Body,
    /// Original executor-side observer of the real owner exchange result.
    reply: process.Subject(Result(wire.Body, endpoint.Error)),
  )

  /// Ends this fixed test role after executor-side teardown.
  Stop
}

// A bounded trusted Subject requires Erlang's PID/reference term representation.
// The fixed decoder accepts only a Subject, never code or arbitrary fixture data.
@external(erlang, "executor_scoped_host_test_ffi", "publish")
fn publish(
  path: String,
  door: process.Subject(OwnerMessage),
) -> Result(Nil, Nil)

@external(erlang, "executor_scoped_host_test_ffi", "read")
fn read(path: String) -> Result(process.Subject(OwnerMessage), Nil)

/// Runs each existing host scenario in its original executor role.
///
/// ## Examples
/// `use context <- scoped_host_beam_fixture.run("host_case_test")` enters once.
pub fn run(name: String, body: fn(Context) -> Nil) -> Nil {
  case argv.load().arguments {
    ["--scoped-host-executor", root, actual] if actual == name -> {
      let assert Ok(configured) =
        provision.read_provisioned(root <> "/tls.term")
        as "The fixed executor has its original private TLS provisioning."
      let assert Ok(membership) = distribution.start(configured.executor_config)
        as "The real executor OS node starts mutually authenticated distribution."
      let assert Ok(owner) =
        distribution.peer(membership, configured.owner_name)
        as "Only the original configured owner is enrolled."
      await(root, "owner.term")
      let assert Ok(door) = read(root <> "/owner.term")
        as "The original owner publishes only its bounded test subject."
      assert distribution.connect(owner, 2500) == Ok(Nil)
      let assert Ok(config) = endpoint.configure_server([], 5000)
        as "The endpoint starts without privately unpublished scope rows."
      let assert Ok(server) = endpoint.start(config)
        as "Only the node owner publishes the fixed shared rendezvous."
      body(Context(server, owner, door))
      let monitor = process.monitor(endpoint.pid(server))
      endpoint.stop(server)
      joined(monitor, 2000)
      process.send(door, Stop)
      await(root, "owner-done")
      io.println("SCOPED_HOST_EXECUTOR_COMPLETED:" <> name)
    }
    _ -> run_nodes(name)
  }
}

/// Starts the fixed owner role before executor-side scope publication.
///
/// ## Examples
/// `scoped_host_beam_fixture.owner_main()` is the test's explicit OS entrypoint.
pub fn owner_main() -> Nil {
  let assert ["--scoped-host-owner", root, _name] = argv.load().arguments
    as "Only the fixed owner role invokes this entrypoint."
  let assert Ok(configured) = provision.read_provisioned(root <> "/tls.term")
    as "The owner has independent credentials and its private cookie home."
  let assert Ok(membership) = distribution.start(configured.owner_config)
    as "The owner starts TLS distribution before any endpoint request."
  let assert Ok(peer) = distribution.peer(membership, configured.executor_name)
    as "Destination Peer comes from this actual owner membership."
  let assert Ok(started) =
    actor.new(peer)
    |> actor.on_message(fn(peer, message) {
      case message {
        Exchange(scope, body, reply) -> {
          let answer =
            endpoint.exchange(
              endpoint.Config(peer, "owner", "linux", scope, 1, 500),
              body,
            )
          process.send(reply, answer)
          actor.continue(peer)
        }
        Stop -> actor.stop()
      }
    })
    |> actor.start
    as "The fixed test door executes the actual production endpoint exchange."
  assert publish(root <> "/owner.term", started.data) == Ok(Nil)
  let monitor = process.monitor(started.pid)

  // A failed executor OS role cannot send Stop. Its runner marks that actual
  // exit, so this independent owner still joins instead of hiding the failure
  // behind a hundred-second idle wait. No marker supplies native drain proof.
  let assert poll.Answered(Nil) =
    poll.until(100_000, 10, fn() {
      case process.is_alive(started.pid) {
        False -> poll.Done(Nil)
        True -> {
          case simplifile.is_file(root <> "/executor-failed") {
            Ok(True) -> {
              process.send(started.data, Stop)
              poll.Retry
            }
            Ok(False) | Error(_) -> poll.Retry
          }
        }
      }
    })
    as "The owner joins after actual executor success or its observed OS failure."
  joined(monitor, 2000)
  assert simplifile.write(root <> "/owner-done", "done") == Ok(Nil)
  io.println("SCOPED_HOST_OWNER_COMPLETED")
}

/// Constructs only a fixed test-side route to the original owner actor.
///
/// ## Examples
/// `scoped_host_beam_fixture.client(context, scope)` carries no native authority.
pub fn client(context: Context, scope: identity.Scope) -> Client {
  Client(scope, context.door)
}

/// Returns the actual production endpoint exchange from the authenticated owner.
///
/// ## Examples
/// `scoped_host_beam_fixture.exchange(client, wire.Hello)` invokes real TLS BEAM.
pub fn exchange(
  client: Client,
  body: wire.Body,
) -> Result(wire.Body, endpoint.Error) {
  process.call(client.door, 2000, Exchange(client.scope, body, _))
}

fn run_nodes(name: String) -> Nil {
  assert list.all(string.to_graphemes(name), fn(char) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", char)
  })
  let assert Ok(here) = simplifile.current_directory()
    as "Executor package root."
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    here
    <> "/build/scoped-host-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(configured) = provision.provision(root, "scopedhost")
    as "The fixed roles have separate TLS pins and credential directories."
  assert provision.write_provisioned(configured, root <> "/tls.term") == Ok(Nil)
  let roles = [
    #(
      configured.owner_config,
      configured.owner_options,
      "scoped_host_beam_fixture:owner_main(),halt(0).",
      "--scoped-host-owner",
      "owner",
    ),
    #(
      configured.executor_config,
      configured.executor_options,
      "'executor@remote@host_test':'" <> name <> "'(),halt(0).",
      "--scoped-host-executor",
      "executor",
    ),
  ]
  let reports =
    weft.new_prepared(
      list.map(roles, fn(role) {
        let #(config, options, entry, flag, label) = role
        weft.managed(fn(_) {
          let outcome =
            provision.run_node(
              provision.current_executable(),
              list.append(provision.node_arguments(options), [
                "-noshell",
                "-eval",
                entry,
                "-extra",
                flag,
                root,
                name,
              ]),
              here,
              distribution.bootstrap_home(config),
            )
          let output = case outcome {
            Ok(#(_, output)) -> output
            Error(error) -> error
          }
          assert simplifile.write(root <> "/" <> label <> ".log", output)
            == Ok(Nil)
          case outcome, label {
            Ok(#(exit, _)), "executor" if exit != 0 -> {
              assert simplifile.write(root <> "/executor-failed", "failed")
                == Ok(Nil)
            }
            _, _ -> Nil
          }
          outcome
        })
      }),
    )
    |> weft.deadline(110_000)
    |> weft.start
  let assert [owner_result, executor_result] = weft.values(reports)
    as "Both OS roles joined; failure retains their original logs."
  list.each([owner_result, executor_result], fn(value) {
    let #(exit, output) = value
    assert exit == 0 as output
  })
  let assert Ok(output) = simplifile.read(root <> "/executor.log")
    as "Actual role output."
  assert string.contains(output, "SCOPED_HOST_EXECUTOR_COMPLETED:" <> name)
  assert simplifile.is_file(root <> "/owner-done") == Ok(True)
  assert simplifile.delete(root) == Ok(Nil)
}

fn await(root: String, name: String) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(10_000, 10, fn() {
      case simplifile.is_file(root <> "/" <> name) {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "The finite independent-role barrier must complete."
  Nil
}

fn joined(monitor: process.Monitor, within: Int) -> Nil {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(within)
    as "The actual OS-role actor must terminate."
  process.demonitor_process(monitor)
}
