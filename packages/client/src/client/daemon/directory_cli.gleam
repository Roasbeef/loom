//// The operator command that creates the session directory's Khepri cluster
//// (protocol-change/081).
////
//// `loomd directory bootstrap` runs once per deployment, on one member, with
//// that member's daemon stopped. It creates a store with that member as its
//// only voter and marks it joined. Every other member then joins on its own
//// when its daemon starts (`client/directory/member`).
////
//// Bootstrap is a command and not something a daemon does at boot, because the
//// mistake it guards against cannot be told apart from a first boot by looking
//// at one machine: a member that lost its disk looks exactly like a member that
//// never had one. So the command refuses in the two cases where it would start
//// a second cluster beside a real one: when this member already has a store on
//// disk, and when any other configured member it can reach answers that its
//// store is running. A member it cannot reach is named in the output, so the
//// operator knows what the command could not check.
////
//// The command takes the state directory's daemon reservation first, as
//// `loomd executor release` does, so it refuses while the daemon runs: the
//// daemon would be using the same node name and the same data directory.

import client/daemon/main as daemon
import client/directory/settings
import client/directory/store
import client/distribution
import client/internal/ffi_os
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import tom

/// Complete help for the directory operator command.
pub const usage =
  "usage: loomd directory bootstrap [--state-dir PATH] [--config PATH]

Create the session directory's cluster on this member. Run it once per
deployment, on one member, with this member's daemon stopped, through the same
launcher and LOOM_DISTRIBUTION_OPTFILE the daemon uses.

The configuration must have a [directory] table naming this node among its
members. The command refuses when this member already has a directory store on
disk, and when another member it can reach already runs one, because either
would start a second cluster. It names the members it could not reach.

Every other member joins the cluster by itself when its daemon starts.

--state-dir is the daemon's state directory (default ~/.loom); the store is
created under <state-dir>/directory. --config is the daemon's loom.toml.

Example:
  LOOM_DISTRIBUTION_OPTFILE=/etc/loom/dist.options \\
    loomd directory bootstrap --state-dir /var/lib/loom --config /etc/loom/loom.toml"

/// Runs the command and exits nonzero with a one-line reason when it fails.
///
/// ## Examples
///
/// ```gleam
/// // loomd directory bootstrap --config /etc/loom/loom.toml
/// ```
pub fn main(arguments: List(String)) -> Nil {
  case run(arguments) {
    Ok(text) -> io.println(text)
    Error(reason) -> {
      io.println_error("loomd: " <> reason)
      ffi_os.halt(1)
    }
  }
}

/// Runs one command and returns what it prints. A refused command has created
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(directory_cli.run(["bootstrap", "--nonsense"]))
/// ```
pub fn run(arguments: List(String)) -> Result(String, String) {
  case arguments {
    ["bootstrap", ..flags] -> {
      use #(state_dir, configuration) <- result.try(flags_of(flags, None, None))
      bootstrap(state_dir, configuration)
    }
    _ -> Error(usage)
  }
}

fn flags_of(
  flags: List(String),
  state_dir: option.Option(String),
  configuration: option.Option(String),
) -> Result(#(option.Option(String), String), String) {
  case flags {
    [] ->
      case configuration {
        Some(path) -> Ok(#(state_dir, path))
        None -> Error("--config is required\n\n" <> usage)
      }
    ["--state-dir", path, ..rest] -> flags_of(rest, Some(path), configuration)
    ["--config", path, ..rest] -> flags_of(rest, state_dir, Some(path))
    _ -> Error(usage)
  }
}

fn bootstrap(
  state_dir: option.Option(String),
  configuration: String,
) -> Result(String, String) {
  use config <- result.try(case state_dir {
    Some(path) -> daemon.parse(["--state-dir", path])
    None -> daemon.parse([])
  })
  use text <- result.try(
    simplifile.read(configuration)
    |> result.map_error(fn(error) {
      configuration <> " is unreadable: " <> simplifile.describe_error(error)
    }),
  )
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      configuration
      <> ": invalid daemon configuration: "
      <> string.inspect(error)
    }),
  )
  use found <- result.try(
    settings.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  use members <- result.try(case found {
    Some(settings.Settings(members:)) -> Ok(members)
    None -> Error(configuration <> " has no [directory] table")
  })
  use dist <- result.try(
    distribution.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  use dist <- result.try(case dist {
    Some(dist) -> Ok(dist)
    None -> Error(configuration <> " has no [distribution] table")
  })
  let directory = daemon.directory_path(config.state_root)

  // A store on disk is refused before anything is reserved or started: it is
  // either this cluster's, and must not be replaced, or a leftover an operator
  // removes on purpose. The refusal says which, and how to remove it.
  use Nil <- result.try(case store.holds_data(directory) {
    False -> Ok(Nil)
    True ->
      Error(
        directory
        <> " already holds a directory store; bootstrap creates a cluster "
        <> "only on a member that has none. If a cluster exists, do not "
        <> "bootstrap: start this daemon and it rejoins. If none exists and "
        <> "this store is left from an earlier attempt, remove "
        <> directory
        <> " and run bootstrap again",
      )
  })
  use _claimed <- result.try(
    daemon.claim_endpoint(config)
    |> result.map_error(fn(reason) {
      "the daemon may be running: " <> reason <> "; stop it first"
    }),
  )
  use membership <- result.try(
    distribution.start(dist, distribution.Member(members:))
    |> result.map_error(distribution.describe),
  )
  let local = distribution.local_node(dist)
  let others = list.filter(members, fn(member) { member != local })
  use unreachable <- result.try(survey(membership, others, []))
  use Nil <- result.try(store.start_system(directory))
  use Nil <- result.try(
    store.boot(30_000)
    |> result.map_error(fn(reason) {
      store.stop()
      "the store did not start: " <> reason
    }),
  )
  use Nil <- result.try(store.mark_joined(directory))
  store.stop()
  Ok(
    "created the directory cluster on "
    <> local
    <> " in "
    <> directory
    <> case unreachable {
      [] -> ""
      names ->
        "\nnot reached, so not checked for a store of their own: "
        <> string.join(names, ", ")
    }
    <> "\nstart this daemon, then the others; each joins by itself",
  )
}

// Asks every other member whether its store runs. One that answers yes means a
// cluster already exists, and the command refuses. One that cannot be reached
// is collected, in configuration order, for the output.
fn survey(
  membership: distribution.Membership,
  others: List(String),
  unreachable: List(String),
) -> Result(List(String), String) {
  case others {
    [] -> Ok(list.reverse(unreachable))
    [name, ..rest] -> {
      use peer <- result.try(
        distribution.peer(membership, name)
        |> result.map_error(distribution.describe),
      )
      case distribution.connect(peer, 3000) {
        Error(_) -> survey(membership, rest, [name, ..unreachable])
        Ok(Nil) ->
          case store.running_on(distribution.node(peer)) {
            True ->
              Error(
                name
                <> " already runs a directory store; this deployment has a "
                <> "cluster, and this member joins it when its daemon starts",
              )
            False -> survey(membership, rest, unreachable)
          }
      }
    }
  }
}
