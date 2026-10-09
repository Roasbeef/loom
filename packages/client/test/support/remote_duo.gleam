//// Two orchestrators from the shipment, for the fixtures that exercise what
//// one orchestrator does about a session another owns (issue #697,
//// protocol-change/078, phases 3 and 4).
////
//// A fixture needs the same four things each time: a short private directory
//// under `/var/tmp` (a daemon binds unix sockets below its state root), a
//// certificate authority with one leaf per node and the cookie they share,
//// configuration in which each orchestrator trusts and lists the other, and a
//// guarantee that both daemons are retired whether the body passed or not.
//// `shipped` does the gating and the retirement, `provision` mints the
//// credentials, and `configure` writes both `loom.toml` files.
////
//// A fixture that runs the session directory's Khepri cluster
//// (protocol-change/080) adds a third daemon, an executor, because a cluster of
//// two members has no majority once one is gone. `configure_members` writes
//// the three configurations with the same `[directory]` table, the executor
//// registering the checkout `repo` that the orchestrators reach as `box`, and
//// `start_members` bootstraps the cluster on the executor, starts the three and
//// waits until each has joined with three voters. The executor is laid out and
//// issued a certificate in every fixture and started only by those.
////
//// The credentials, the daemons and the control commands are the vocabulary of
//// `support/remote_daemons`. This module only arranges the daemons with it.

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/codec
import core/entry
import core/json.{type JsonValue}
import core/message
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as native
import host/endpoint
import simplifile
import sqlight
import support/enforcement
import support/internal/ffi_proc
import support/remote_daemons.{Trust}
import weft
import weft/poll

// The longest the body may run, and the EUnit timeout, which the runner scales
// by ten.
const body_ms = 420_000

const eunit_seconds = 60

/// The orchestrators' name for the executor of a member fixture, an
/// `[executors.<name>]` key.
pub const executor_name = "box"

/// The executor's name for its checkout, and the name a session uses for it.
pub const workspace_name = "repo"

/// The daemons of one fixture: where each lives.
pub type Duo {
  Duo(
    /// The fixture's private directory.
    directory: String,
    alpha: remote_daemons.Layout,
    bravo: remote_daemons.Layout,
    /// The executor, started only by a fixture that runs the directory.
    executor: remote_daemons.Layout,
    /// The executor's checkout, registered as `repo`.
    checkout: String,
  )
}

/// The credentials of one fixture.
pub type Credentials {
  Credentials(
    authority: remote_daemons.Authority,
    alpha: remote_daemons.Identity,
    bravo: remote_daemons.Identity,
    executor: remote_daemons.Identity,
  )
}

/// The three running daemons of a member fixture.
pub type Members {
  Members(
    alpha: remote_daemons.Running,
    bravo: remote_daemons.Running,
    executor: remote_daemons.Running,
  )
}

/// Gates the test on the host and runs `body` against a fresh duo, retiring both
/// daemons by their recorded identity afterward whether it passed or not. A host
/// that cannot run the shipment prints `SKIP <label>: ...` and passes, as the
/// other shipped fixtures do.
///
/// ## Examples
///
/// ```gleam
/// pub fn a_test_() -> EunitTest {
///   remote_duo.shipped("shipped remote directory", fn(duo) { Nil })
/// }
/// ```
pub fn shipped(label: String, body: fn(Duo) -> Nil) -> EunitTest {
  Timeout(eunit_seconds, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP " <> label <> ": LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) ->
        case enforcement.probe(server, label) {
          enforcement.EnforcementAbsent -> Nil
          enforcement.EnforcementLive -> fixture(label, body)
        }
    }
  })
}

fn fixture(label: String, body: fn(Duo) -> Nil) -> Nil {
  let directory =
    "/var/tmp/loom-rt-"
    <> string.lowercase(bit_array.base16_encode(token.production_entropy()(4)))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the fixture's state stays private"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the daemons receive absolute paths"
  let duo =
    Duo(
      directory:,
      alpha: remote_daemons.layout(directory, "alpha"),
      bravo: remote_daemons.layout(directory, "bravo"),
      executor: remote_daemons.layout(directory, "executor"),
      checkout: directory <> "/executor-checkout",
    )
  io.println_error(label <> " fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        body(duo)
        Ok(Nil)
      },
    ])
    |> weft.deadline(body_ms)
    |> weft.start

  // Native cleanup runs outside the body's deadline and before the outcome is
  // read, so a body that failed mid-drive still retires every daemon. A daemon
  // the body already killed has no process to retire, which `retire` accepts.
  // A daemon the body froze is thawed first, because a stopped process would
  // not act on the signal that retires it.
  list.each([duo.alpha, duo.bravo, duo.executor], fn(layout) {
    thaw(layout)
    remote_daemons.retire(layout.paths)
  })
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped body completes before native teardown"
  let _removed = simplifile.delete_all([directory])
  Nil
}

/// Mints the authority, one leaf per node and the cookie they share.
///
/// ## Examples
///
/// ```gleam
/// // let keys = remote_duo.provision(duo)
/// ```
pub fn provision(duo: Duo) -> Credentials {
  let secrets = duo.directory <> "/credentials"
  let assert Ok(Nil) = native.ensure_private_directory(secrets)
    as "the credentials directory is private"
  let authority = remote_daemons.mint_authority(secrets)
  let suffix = remote_daemons.random_hex(4)
  let name = fn(role) { "loom_e2e_" <> role <> "_" <> suffix <> "@127.0.0.1" }
  let keys =
    Credentials(
      authority:,
      alpha: remote_daemons.issue(
        authority,
        secrets,
        "alpha",
        name("alpha"),
        duo.alpha.home,
      ),
      bravo: remote_daemons.issue(
        authority,
        secrets,
        "bravo",
        name("bravo"),
        duo.bravo.home,
      ),
      executor: remote_daemons.issue(
        authority,
        secrets,
        "executor",
        name("exec"),
        duo.executor.home,
      ),
    )
  let cookie = "loom-e2e-cookie-" <> remote_daemons.random_hex(16)
  list.each([keys.alpha, keys.bravo, keys.executor], fn(identity) {
    remote_daemons.write_cookie(identity, cookie)
  })
  keys
}

/// Writes both configuration files. Each daemon trusts and lists the other,
/// `alpha`'s row for `bravo` with no address and `bravo`'s row for `alpha` with
/// `alphas_address`, so a fixture can exercise both shapes of a redirect. The
/// configuration holds a model URL that nothing listens on, so a fixture takes
/// no model turn.
///
/// ## Examples
///
/// ```gleam
/// // remote_duo.configure(duo, keys, Some("wss://alpha.example.test:8443/v2/control"))
/// ```
pub fn configure(
  duo: Duo,
  keys: Credentials,
  alphas_address: Option(String),
) -> Nil {
  let write = fn(layout: remote_daemons.Layout, text) {
    let assert Ok(Nil) = simplifile.write(layout.config, text)
      as "the daemon configuration is written"
    remote_daemons.write_options(layout)
  }
  write(
    duo.alpha,
    string.join(
      [
        remote_daemons.model_table("http://127.0.0.1:9"),
        remote_daemons.distribution_table(keys.alpha, keys.authority, [
          Trust(keys.bravo.node, keys.bravo.pin),
        ]),
        remote_daemons.orchestrator_table("bravo", keys.bravo.node, None),
      ],
      "\n",
    ),
  )
  write(
    duo.bravo,
    string.join(
      [
        remote_daemons.model_table("http://127.0.0.1:9"),
        remote_daemons.distribution_table(keys.bravo, keys.authority, [
          Trust(keys.alpha.node, keys.alpha.pin),
        ]),
        remote_daemons.orchestrator_table(
          "alpha",
          keys.alpha.node,
          alphas_address,
        ),
      ],
      "\n",
    ),
  )
}

/// Writes the three configuration files of a member fixture. Each daemon
/// trusts the other two, each orchestrator lists the other as `configure`
/// writes it and the executor as `box`, the executor registers the checkout as
/// `repo`, and all three name the same three members under `[directory]`.
///
/// ## Examples
///
/// ```gleam
/// // remote_duo.configure_members(duo, keys, None)
/// ```
pub fn configure_members(
  duo: Duo,
  keys: Credentials,
  alphas_address: Option(String),
) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(duo.checkout)
    as "the executor checkout is created"
  let members =
    remote_daemons.directory_table([
      keys.alpha.node,
      keys.bravo.node,
      keys.executor.node,
    ])
  let trust = fn(identity: remote_daemons.Identity) {
    Trust(identity.node, identity.pin)
  }
  let write = fn(layout: remote_daemons.Layout, text) {
    let assert Ok(Nil) = simplifile.write(layout.config, text)
      as "the daemon configuration is written"
    remote_daemons.write_options(layout)
  }
  write(
    duo.executor,
    string.join(
      [
        remote_daemons.model_table("http://127.0.0.1:9"),
        remote_daemons.distribution_table(keys.executor, keys.authority, [
          trust(keys.alpha),
          trust(keys.bravo),
        ]),
        remote_daemons.workspace_table(workspace_name, duo.checkout),
        members,
      ],
      "\n",
    ),
  )
  write(
    duo.alpha,
    string.join(
      [
        remote_daemons.model_table("http://127.0.0.1:9"),
        remote_daemons.distribution_table(keys.alpha, keys.authority, [
          trust(keys.bravo),
          trust(keys.executor),
        ]),
        remote_daemons.executor_table(executor_name, keys.executor.node),
        remote_daemons.orchestrator_table("bravo", keys.bravo.node, None),
        members,
      ],
      "\n",
    ),
  )
  write(
    duo.bravo,
    string.join(
      [
        remote_daemons.model_table("http://127.0.0.1:9"),
        remote_daemons.distribution_table(keys.bravo, keys.authority, [
          trust(keys.alpha),
          trust(keys.executor),
        ]),
        remote_daemons.executor_table(executor_name, keys.executor.node),
        remote_daemons.orchestrator_table(
          "alpha",
          keys.alpha.node,
          alphas_address,
        ),
        members,
      ],
      "\n",
    ),
  )
}

/// Creates the directory cluster on the executor with `loomd directory
/// bootstrap`, starts the executor and then both orchestrators, and waits until
/// each of the three has joined a cluster with three voters. The control ids
/// the waits use start at 9000, out of a body's way.
///
/// ## Examples
///
/// ```gleam
/// // let members = remote_duo.start_members(duo)
/// ```
pub fn start_members(duo: Duo) -> Members {
  let #(status, output) = remote_daemons.bootstrap_directory(duo.executor)
  case status {
    0 -> Nil
    _ -> io.println_error("directory bootstrap failed: " <> output)
  }
  assert status == 0 as "the directory bootstrap succeeds"
  let executor = remote_daemons.start(duo.executor)
  let alpha = remote_daemons.start(duo.alpha)
  let bravo = remote_daemons.start(duo.bravo)
  list.each([executor, alpha, bravo], fn(running) {
    let _status =
      remote_daemons.await_directory(
        remote_daemons.open_control(running),
        9000,
        3,
      )
    Nil
  })
  Members(alpha:, bravo:, executor:)
}

/// A reserved fact of a session, read from a copy of the daemon's store.
///
/// The daemon keeps running, so the store is read from a copy of the file and
/// its write-ahead log, never from the live one. A copy taken while the session
/// is writing can be torn, which is why the answer is a `Result` and a caller
/// that is waiting for a fact asks again.
///
/// ## Examples
///
/// ```gleam
/// // remote_duo.session_fact(duo, duo.bravo, session, "client/peers/receipt/...")
/// ```
pub fn session_fact(
  duo: Duo,
  daemon: remote_daemons.Layout,
  session: String,
  key: String,
) -> Result(Option(JsonValue), String) {
  use copy <- result.try(copy_store(duo, daemon, session))
  let cell = {
    use blob <- decode.field(0, decode.bit_array)
    decode.success(blob)
  }
  use rows <- result.try(query(
    copy,
    "SELECT value FROM registers WHERE ns = 'fact.custom' AND key = ?1",
    [sqlight.text(key)],
    cell,
  ))
  case rows {
    [] -> Ok(None)
    [blob, ..] -> {
      use text <- result.try(
        bit_array.to_string(blob)
        |> result.replace_error("a register payload is not text"),
      )
      use parsed <- result.try(
        json.parse(text)
        |> result.replace_error("a register payload is not JSON"),
      )
      use value <- result.map(
        codec.decode_register_value(parsed)
        |> result.replace_error("a register payload is not a register value"),
      )
      Some(value.payload)
    }
  }
}

/// Every message entry of a session, read from a copy of the daemon's store as
/// `session_fact` reads a fact.
///
/// ## Examples
///
/// ```gleam
/// // remote_duo.session_messages(duo, duo.bravo, session)
/// ```
pub fn session_messages(
  duo: Duo,
  daemon: remote_daemons.Layout,
  session: String,
) -> Result(List(entry.Entry), String) {
  use copy <- result.try(copy_store(duo, daemon, session))
  let payload = {
    use blob <- decode.field(0, decode.bit_array)
    decode.success(blob)
  }
  use rows <- result.try(query(
    copy,
    "SELECT payload FROM entries WHERE type = 'message' ORDER BY seq",
    [],
    payload,
  ))
  list.try_map(rows, fn(blob) {
    use text <- result.try(
      bit_array.to_string(blob)
      |> result.replace_error("an entry payload is not text"),
    )
    use parsed <- result.try(
      json.parse(text) |> result.replace_error("an entry payload is not JSON"),
    )
    codec.decode_entry(parsed)
    |> result.replace_error("an entry payload is not an entry")
  })
}

// The store of `session` on `daemon`, copied beside the fixture's other files.
fn copy_store(
  duo: Duo,
  daemon: remote_daemons.Layout,
  session: String,
) -> Result(String, String) {
  let source = daemon.paths.root <> "/sessions/" <> session <> ".db"
  let scratch = duo.directory <> "/store-copies"
  use Nil <- result.try(
    simplifile.create_directory_all(scratch)
    |> result.replace_error("the store copy has no directory"),
  )
  let copy = scratch <> "/" <> remote_daemons.random_hex(4) <> ".db"
  use _ <- result.try(
    list.try_each(["", "-wal", "-shm"], fn(suffix) {
      case simplifile.is_file(source <> suffix) {
        Ok(True) ->
          simplifile.copy_file(source <> suffix, copy <> suffix)
          |> result.replace_error("the store file could not be copied")
        _ -> Ok(Nil)
      }
    }),
  )
  Ok(copy)
}

fn query(
  copy: String,
  sql: String,
  with: List(sqlight.Value),
  expecting: decode.Decoder(a),
) -> Result(List(a), String) {
  use connection <- result.try(
    sqlight.open(copy) |> result.replace_error("the copied store did not open"),
  )
  let rows =
    sqlight.query(sql, on: connection, with:, expecting:)
    |> result.replace_error("the copied store did not answer")
  let _closed = sqlight.close(connection)
  rows
}

/// Stops a daemon's process without ending it. The daemon neither runs nor
/// answers, and its peers' connections to it stay open, so a peer that asks it
/// something gets no answer and no `DOWN`: the silence of a partition.
///
/// The signal goes to the process the daemon's endpoint file fenced, after
/// checking that process is still the daemon.
///
/// ## Examples
///
/// ```gleam
/// // remote_duo.freeze(duo.alpha)
/// ```
pub fn freeze(layout: remote_daemons.Layout) -> Nil {
  signal(layout, "-STOP")
}

/// Lets a frozen daemon run again. A daemon that is not frozen, or is not
/// running, is left as it is.
///
/// ## Examples
///
/// ```gleam
/// // remote_duo.thaw(duo.alpha)
/// ```
pub fn thaw(layout: remote_daemons.Layout) -> Nil {
  signal(layout, "-CONT")
}

fn signal(layout: remote_daemons.Layout, name: String) -> Nil {
  case endpoint.load(layout.paths) {
    Ok(Some(record)) ->
      case endpoint.is_present(record.fence) {
        Ok(True) -> {
          let assert Ok(kill) = ffi_proc.which("kill") as "kill is on PATH"
          let assert Ok(#(0, _)) =
            ffi_proc.run(
              kill,
              [name, int.to_string(record.fence.pid)],
              layout.directory,
            )
            as "the signal targets only this fixture's verified daemon"
          Nil
        }
        Ok(False) | Error(_) -> Nil
      }
    Ok(None) | Error(_) -> Nil
  }
}

/// How many messages in `session`'s transcript on `daemon` come from a peer and
/// carry `text`, read from a copy of the store as `session_messages` reads it.
///
/// ## Examples
///
/// ```gleam
/// // remote_duo.peer_messages(duo, duo.alpha, session, "first message")
/// ```
pub fn peer_messages(
  duo: Duo,
  daemon: remote_daemons.Layout,
  session: String,
  text: String,
) -> Result(Int, String) {
  use entries <- result.try(session_messages(duo, daemon, session))
  Ok(
    list.count(entries, fn(each) {
      case each {
        entry.MessageEntry(
          message: message.UserMessage(
            content: [message.UserText(body, _)],
            origin: Some(message.PeerOrigin(..)),
            ..,
          ),
          ..,
        ) -> string.contains(body, text)
        _ -> False
      }
    }),
  )
}

/// Waits until `session`'s transcript on `daemon` holds exactly `want` peer
/// messages carrying `text`, and fails at once if it holds more.
///
/// ## Examples
///
/// ```gleam
/// // remote_duo.await_peer_messages(duo, duo.alpha, session, "hello", 1)
/// ```
pub fn await_peer_messages(
  duo: Duo,
  daemon: remote_daemons.Layout,
  session: String,
  text: String,
  want: Int,
) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 40_000, every: 500, attempt: fn() {
      case peer_messages(duo, daemon, session, text) {
        Ok(found) if found == want -> poll.Done(Nil)
        Ok(found) if found > want ->
          poll.Fail("the transcript holds the message more than once")
        _ -> poll.Retry
      }
    })
    as { "the transcript holds the message " <> text }
  Nil
}
