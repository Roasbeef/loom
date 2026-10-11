//// Executor pools, against the shipped daemon: one orchestrator and two
//// executors, three real `bin/loomd` processes that trust each other over TLS
//// distribution (issue #697, protocol-change/078, the addendum on pools).
////
//// `daemon_shipped_remote_test` proves that a session registered on one
//// executor runs its tools there. Phase 2 lets the orchestrator choose among
//// several, and the rules of that choice are about what is refused and where
//// the session may not go, so each test boots the trio, creates sessions with
//// `pool` in place of `executor`, and reads where they landed in three places:
//// the orchestrator's session record, and each executor's own ledger.
////
//// ## What it proves
////
//// `a_pool_skips_an_executor_that_declares_the_wrong_platform_test_`
////
//// - The pool requires the platform of the machine the test runs on. The first
////   executor in the pool declares another platform and the second declares the
////   real one, so the pool offers only the second and the session lands there:
////   its record names the second executor and the pool, the second executor's
////   ledger holds the session's open scope, and the first executor's ledger
////   holds nothing of the session.
//// - A pool with no requirement that lists only the first executor attaches to
////   it, and the executor's census contradicts its declaration. The open fails
////   with a reason naming the declared and the reported platform, and the
////   scope the attach created is closed cleanly in the executor's ledger, which
////   is also what returns its slot.
////
//// `a_full_executor_is_passed_over_and_a_reopen_never_moves_test_`
////
//// - Both executors admit one scope (`LOOM_EXECUTOR_MAX_SCOPES=1`). The first
////   session fills the first executor, so the second session is refused there
////   with a capacity answer and lands on the second executor.
//// - The second session is stopped and a third takes the slot it freed, and the
////   first session is stopped, so the first executor has room again. The second
////   session is then reopened: the second executor is full, the open fails with
////   `executor_unavailable:`, and the first executor, which has room, is never
////   asked. Its ledger holds nothing of the session, and the second session's
////   scope on the second executor is as it was left.
//// - Once the third session is stopped the second reopens on the second
////   executor at the next incarnation.
////
//// ## Prerequisites and skips
////
//// The executors jail every call, so a host whose helper cannot enforce a
//// policy prints `SKIP shipped remote pool: ...` and passes, as the other
//// shipped fixtures do. The sessions take no model turn, so no scripted provider
//// is started.
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_pool_test:'
//// ```
////
//// The credentials, the daemons and the control commands are the vocabulary of
//// `support/remote_daemons`. The directory is under `/var/tmp` and short, as the
//// other shipped remote fixtures use, because the executors bind unix sockets
//// below their state roots.

import broker/token
import client/internal/ffi_os
import client/system_prompt
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json
import gleam/bit_array
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as native
import simplifile
import storage/exec_ledger
import support/enforcement
import support/remote_daemons.{type Trio, Trust}
import weft

const skip_label = "shipped remote pool"

// The workspace every executor registers under this name, in a checkout of its
// own. The orchestrator is never told a path.
const workspace_name = "repo"

// A platform no test host has, so an executor that declares it is wrong about
// itself.
const wrong_platform = "plan9/mips64"

// The longest the body may run, and the EUnit timeout, which the runner scales
// by ten.
const body_ms = 420_000

const eunit_seconds = 60

// --- the fixture -------------------------------------------------------------

type Credentials {
  Credentials(
    authority: remote_daemons.Authority,
    orchestrator: remote_daemons.Identity,
    alpha: remote_daemons.Identity,
    bravo: remote_daemons.Identity,
  )
}

// Gates the test on the host and runs `body` against a fresh trio, retiring
// the three daemons by their recorded identity afterward whether it passed or
// not. The directory is removed only when it passed.
fn shipped(body: fn(Trio) -> Nil) -> EunitTest {
  Timeout(eunit_seconds, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP " <> skip_label <> ": LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) ->
        case enforcement.probe(server, skip_label) {
          enforcement.EnforcementAbsent -> Nil
          enforcement.EnforcementLive -> fixture(body)
        }
    }
  })
}

fn fixture(body: fn(Trio) -> Nil) -> Nil {
  let directory =
    "/var/tmp/loom-rt-"
    <> string.lowercase(bit_array.base16_encode(token.production_entropy()(4)))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the fixture's state stays private"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the daemons receive absolute paths"
  let trio = remote_daemons.trio(directory)
  io.println_error(skip_label <> " fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        body(trio)
        Ok(Nil)
      },
    ])
    |> weft.deadline(body_ms)
    |> weft.start

  // Native cleanup runs outside the body's deadline and before the outcome is
  // read, so a body that failed mid-drive still retires every daemon.
  list.each([trio.orchestrator, trio.alpha, trio.bravo], fn(layout) {
    remote_daemons.retire(layout.paths)
  })
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped pool body completes before native teardown"
  let _removed = simplifile.delete_all([directory])
  Nil
}

// Mints the authority, one leaf per node and the cookie all three share.
fn provision(trio: Trio) -> Credentials {
  let secrets = trio.directory <> "/credentials"
  let assert Ok(Nil) = native.ensure_private_directory(secrets)
    as "the credentials directory is private"
  let authority = remote_daemons.mint_authority(secrets)
  let suffix = remote_daemons.random_hex(4)
  let name = fn(role) { "loom_e2e_" <> role <> "_" <> suffix <> "@127.0.0.1" }
  let keys =
    Credentials(
      authority:,
      orchestrator: remote_daemons.issue(
        authority,
        secrets,
        "orchestrator",
        name("orch"),
        trio.orchestrator.home,
      ),
      alpha: remote_daemons.issue(
        authority,
        secrets,
        "alpha",
        name("alpha"),
        trio.alpha.home,
      ),
      bravo: remote_daemons.issue(
        authority,
        secrets,
        "bravo",
        name("bravo"),
        trio.bravo.home,
      ),
    )
  let cookie = "loom-e2e-cookie-" <> remote_daemons.random_hex(16)
  list.each([keys.orchestrator, keys.alpha, keys.bravo], fn(identity) {
    remote_daemons.write_cookie(identity, cookie)
  })
  keys
}

// Writes the three configuration files. Each executor registers `repo` over a
// checkout of its own, and the orchestrator's `tables` say how it names them and
// which pools it offers.
fn configure(trio: Trio, keys: Credentials, tables: String) -> Nil {
  let write = fn(layout: remote_daemons.Layout, text) {
    let assert Ok(Nil) = simplifile.write(layout.config, text)
      as "the daemon configuration is written"
    remote_daemons.write_options(layout)
  }
  let executor = fn(layout: remote_daemons.Layout, identity) {
    let checkout = layout.directory <> "/checkout"

    // The executor refuses to start when a registered root is not a directory.
    let assert Ok(Nil) = simplifile.create_directory_all(checkout)
      as "the executor checkout is created"
    write(
      layout,
      string.join(
        [
          remote_daemons.model_table("http://127.0.0.1:9"),
          remote_daemons.distribution_table(identity, keys.authority, [
            Trust(keys.orchestrator.node, keys.orchestrator.pin),
          ]),
          remote_daemons.workspace_table(workspace_name, checkout),
        ],
        "\n",
      ),
    )
  }
  executor(trio.alpha, keys.alpha)
  executor(trio.bravo, keys.bravo)
  write(
    trio.orchestrator,
    string.join(
      [
        remote_daemons.model_table("http://127.0.0.1:9"),
        remote_daemons.distribution_table(keys.orchestrator, keys.authority, [
          Trust(keys.alpha.node, keys.alpha.pin),
          Trust(keys.bravo.node, keys.bravo.pin),
        ]),
        tables,
      ],
      "\n",
    ),
  )
}

// The platform label the executors will report for this machine, as the system
// prompt words it. The daemons run on the machine the test runs on.
fn host_platform() -> String {
  system_prompt.platform(ffi_os.platform())
}

fn ledger_copies(trio: Trio) -> String {
  trio.directory <> "/ledger-copies"
}

// Where an executor's ledger holds a scope for the session.
fn held_by(
  trio: Trio,
  executor: remote_daemons.Layout,
  session: String,
) -> option.Option(exec_ledger.Scope) {
  remote_daemons.scope_if_held(executor, ledger_copies(trio), session)
}

fn text_of(value: json.JsonValue, key: String) -> String {
  let assert json.String(text) = remote_daemons.field(value, key)
    as "the member is text"
  text
}

fn member(record: json.JsonValue, key: String) -> Result(String, Nil) {
  let assert json.Object(fields) = record as "a session record is an object"
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Ok(text)
    _ -> Error(Nil)
  }
}

// The reason a settled opening failed with, asserting that it did.
fn failure_reason(settled: json.JsonValue) -> String {
  assert remote_daemons.field(settled, "event") == json.String("error")
  assert text_of(remote_daemons.field(settled, "body"), "code")
    == "start_failed"
  text_of(remote_daemons.field(settled, "body"), "message")
}

// --- the declared platform ---------------------------------------------------

pub fn a_pool_skips_an_executor_that_declares_the_wrong_platform_test_() -> EunitTest {
  shipped(fn(trio) {
    let keys = provision(trio)
    let host = host_platform()
    configure(
      trio,
      keys,
      string.join(
        [
          remote_daemons.declared_executor_table(
            "alpha",
            keys.alpha.node,
            wrong_platform,
          ),
          remote_daemons.declared_executor_table("bravo", keys.bravo.node, host),
          remote_daemons.pool_table("fleet", ["alpha", "bravo"], Some(host)),
          remote_daemons.pool_table("careful", ["alpha"], None),
        ],
        "\n",
      ),
    )
    let _alpha = remote_daemons.start(trio.alpha)
    let _bravo = remote_daemons.start(trio.bravo)
    let orchestrator = remote_daemons.start(trio.orchestrator)
    let control = remote_daemons.open_control(orchestrator)

    // The pool requires this machine's platform, alpha declared another, so
    // alpha is never offered and the session lands on bravo.
    let #(session, settled) =
      remote_daemons.create_pooled_and_settle(
        control,
        1,
        "e2e-pool-platform",
        workspace_name,
        "fleet",
      )
    assert remote_daemons.settled_state(settled) == "resident"
    let record = remote_daemons.session_record(control, 100, session)
    assert member(record, "pool") == Ok("fleet")
    assert member(record, "executor") == Ok("bravo")
    assert member(record, "workspace") == Ok(workspace_name)
    let assert Some(scope) = held_by(trio, trio.bravo, session)
      as "bravo holds the session's scope"
    assert scope.incarnation == 1
    assert scope.state == exec_ledger.Open
    assert scope.workspace == workspace_name
    assert held_by(trio, trio.alpha, session) == None

    // A pool with no requirement that lists alpha attaches to it, and the
    // census it answers with contradicts what the file declares about it.
    let #(refused, settled) =
      remote_daemons.create_pooled_and_settle(
        control,
        200,
        "e2e-pool-declaration",
        workspace_name,
        "careful",
      )
    assert failure_reason(settled)
      == "executor_unavailable: executor alpha declares platform "
      <> wrong_platform
      <> " but its census reports "
      <> host

    // The scope the attach created was closed at once, which returns its slot
    // to alpha, and the session never recorded an executor.
    let assert Some(created) = held_by(trio, trio.alpha, refused)
      as "alpha created the scope before the census was compared"
    assert created.state == exec_ledger.Closed(exec_ledger.AllRetired)
    assert created.incarnation == 1
    assert member(
        remote_daemons.session_record(control, 300, refused),
        "executor",
      )
      == Error(Nil)
    Nil
  })
}

// --- capacity ----------------------------------------------------------------

pub fn a_full_executor_is_passed_over_and_a_reopen_never_moves_test_() -> EunitTest {
  shipped(fn(trio) {
    let keys = provision(trio)
    configure(
      trio,
      keys,
      string.join(
        [
          remote_daemons.executor_table("alpha", keys.alpha.node),
          remote_daemons.executor_table("bravo", keys.bravo.node),
          remote_daemons.pool_table("fleet", ["alpha", "bravo"], None),
        ],
        "\n",
      ),
    )

    // Each executor admits one scope that is not cleanly closed.
    let small = [#("LOOM_EXECUTOR_MAX_SCOPES", "1")]
    let _alpha = remote_daemons.start_with_environment(trio.alpha, [], small)
    let _bravo = remote_daemons.start_with_environment(trio.bravo, [], small)
    let orchestrator = remote_daemons.start(trio.orchestrator)
    let control = remote_daemons.open_control(orchestrator)
    let place = fn(id, key) {
      let #(session, settled) =
        remote_daemons.create_pooled_and_settle(
          control,
          id,
          key,
          workspace_name,
          "fleet",
        )
      assert remote_daemons.settled_state(settled) == "resident"
      session
    }
    let landed = fn(session, id) {
      member(remote_daemons.session_record(control, id, session), "executor")
    }

    // The first session fills alpha. The second is refused there for capacity,
    // which proves alpha created nothing for it, and lands on bravo.
    let first = place(1000, "e2e-pool-first")
    assert landed(first, 1900) == Ok("alpha")
    let second = place(2000, "e2e-pool-second")
    assert landed(second, 2900) == Ok("bravo")
    assert held_by(trio, trio.alpha, second) == None
    let assert Some(second_scope) = held_by(trio, trio.bravo, second)
    assert second_scope.state == exec_ledger.Open

    // Free bravo's slot and let a third session take it: alpha is still full
    // with the first, so the pool moves past it again.
    remote_daemons.stop_session(orchestrator, control, 3000, second)
    let third = place(4000, "e2e-pool-third")
    assert landed(third, 4900) == Ok("bravo")

    // Alpha has room again, bravo has none, and the second session's checkout is
    // on bravo. Reopening it fails and does not ask alpha.
    remote_daemons.stop_session(orchestrator, control, 5000, first)
    let reopened = remote_daemons.reopen_session(control, 6000, second)
    let reason = failure_reason(reopened)
    assert string.starts_with(reason, "executor_unavailable: ")
    assert string.contains(reason, "already holds 1 scopes")
    assert held_by(trio, trio.alpha, second) == None
    assert landed(second, 6900) == Ok("bravo")
    let assert Some(unmoved) = held_by(trio, trio.bravo, second)
    assert unmoved.incarnation == 1
    assert unmoved.state == exec_ledger.Closed(exec_ledger.AllRetired)

    // Once bravo has room the session reopens there at the next incarnation.
    remote_daemons.stop_session(orchestrator, control, 7000, third)
    let settled = remote_daemons.reopen_session(control, 8000, second)
    assert remote_daemons.settled_state(settled) == "resident"
    let assert Some(back) = held_by(trio, trio.bravo, second)
    assert back.incarnation == 2
    assert back.state == exec_ledger.Open
    assert held_by(trio, trio.alpha, second) == None
    Nil
  })
}
