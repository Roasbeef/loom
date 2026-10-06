//// The CLI discovers a native owner endpoint and uses its real resident gateway.
//// No JSON fixture supplies a role or attachment; the daemon authenticates its
//// own private credential, reserves the incarnation, and upgrades the socket.

import broker/token
import client/daemon/domain as domain_service
import client/daemon/limits
import client/daemon/main as daemon
import client/daemon/manager
import client/daemon/root
import client/daemon/session_socket
import client/evolution/cli
import client/evolution_acceptance_test
import client/serve
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/clock
import core/ids
import core/json
import gleam/bit_array
import gleam/list
import gleam/result
import host/bootstrap
import simplifile
import storage/domain
import support/extensions
import telemetry/log
import weft
import weft/poll

pub fn owner_cli_crosses_resident_transport_and_refuses_saved_session_test_() -> EunitTest {
  Timeout(60, exercise)
}

fn exercise() {
  let directory =
    extensions.scratch(
      "cli-" <> bit_array.base16_encode(token.production_entropy()(5)),
    )
  let settings =
    evolution_acceptance_test.settings(directory, "http://127.0.0.1:1")
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "native owner discovery starts with a private state directory"
  let assert Ok(Nil) = simplifile.create_directory_all(settings.workspace)
    as "the real session workspace exists"
  let assert Ok(config) = daemon.parse(["--state-dir", directory])
    as "the default daemon listener configuration resolves"
  let assert Ok(#(config, endpoint_paths, fence)) =
    daemon.claim_endpoint(config)
    as "the native process identity owns endpoint publication"
  let assert Ok(owner) =
    root.start(
      root.Config(config.state_root, "Owner", 2, limits.defaults),
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(registration, _domain, _services, custody, _directory) {
          use id <- result.try(
            ids.parse_session_id(registration.id)
            |> result.replace_error("reserved session identity is invalid"),
          )
          let settings =
            serve.Settings(..settings, session_path: registration.path)
          serve.assemble_owned(settings, id, log.discard(), custody)
          |> result.map(serve.resident)
        },
        drain: serve.drain_resident,
        fatal: serve.resident_children,
      ),
    )
    as "the real daemon owns the registry and native session custody"
  let assert Ok(serving) =
    daemon.listen(config, owner, fn(request, attachment) {
      session_socket.upgrade(
        owner,
        request,
        attachment,
        attachment.instance.gateway,
      )
    })
    as "the original authenticated daemon listener is published"
  let assert Ok(Nil) =
    daemon.publish_endpoint(config, serving, endpoint_paths, fence)
    as "the real ready listener becomes discoverable under its native fence"

  // The outer task lets cleanup run even if a wire assertion fails.
  let outcomes =
    weft.new([
      fn() {
        let assert Ok(view) =
          manager.create_scoped(
            serving.ready.registry,
            manager.Creation("evolution-cli", settings.workspace, "CLI", ""),
            directory: serving.ready.sessions_directory,
            generator: ids.generator(clock.fixed(1_700_000_000_000), 807),
            scope: domain.SessionOnly,
            configuration: "",
          )
          as "only an explicit native creation opens this session"
        let session = view.registration.id
        let assert poll.Answered(Nil) =
          poll.until(within: 15_000, every: 10, attempt: fn() {
            case manager.get(serving.ready.registry, session) {
              Ok(manager.View(status: manager.Resident(_), ..)) ->
                poll.Done(Nil)
              _ -> poll.Retry
            }
          })
          as "native assembly publishes the exact resident incarnation"
        let assert Ok(command) =
          cli.parse(["--state-dir", directory, "catalogue", session])
          as "the CLI receives no credential or role in its arguments"
        let assert Ok(catalogue) = cli.run(command)
          as "private endpoint discovery reaches the authenticated resident gateway"
        let assert json.Object(fields) = catalogue
          as "catalogue is the native paged result"
        assert list.key_find(fields, "items") == Ok(json.Array([]))
          as "the original empty native catalogue survives transport exactly"
        let assert Ok(command) =
          cli.parse([
            "--state-dir",
            directory,
            "status",
            session,
            "--request-id",
            "cli-never-seen",
          ])
          as "status uses the same resident identity"
        let assert Ok(status) = cli.run(command)
          as "status is read over the actual socket"
        let assert json.Object(fields) = status
          as "native status retains its structured fields"
        assert list.key_find(fields, "state") == Ok(json.String("unknown"))
          as "an absent exact request receipt cannot imply completion"
        assert list.key_find(fields, "request_id")
          == Ok(json.String("cli-never-seen"))
        let assert Ok(_) = manager.stop_session(serving.ready.registry, session)
          as "native retirement is admitted"
        let assert poll.Answered(Nil) =
          poll.until(within: 15_000, every: 10, attempt: fn() {
            case manager.get(serving.ready.registry, session) {
              Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
              _ -> poll.Retry
            }
          })
          as "cleanup must finish before the session becomes saved"
        let assert Error(cli.NotSent(_)) = cli.run(command)
          as "the CLI refuses a saved session instead of opening a new incarnation"
        Ok(Nil)
      },
    ])
    |> weft.deadline(45_000)
    |> weft.start
  assert root.shutdown(owner, within: 15_000) == Ok(Nil)
    as "daemon retirement supplies native cleanup before reporting assertions"
  let assert [weft.Completed(0, Nil)] = outcomes
    as "owner CLI wire checks completed within their deadline"
  Nil
}
