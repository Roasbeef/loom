//// The operator command that creates the session directory's Khepri cluster
//// (protocol-change/083).
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
//// With a membership ledger (`[distribution] ledger`) there is no `[directory]`
//// table and the members are the ledger's: the command starts the node's ledger
//// process and distribution as the daemon does, requires the ledger to seat this
//// node as a voter, and checks every other seated node. Everything after that is
//// the same.
////
//// The command takes the state directory's daemon reservation first, as
//// `loomd executor release` does, so it refuses while the daemon runs: the
//// daemon would be using the same node name and the same data directory.

import client/daemon/main as daemon
import client/directory/roster
import client/directory/settings
import client/directory/store
import client/distribution
import client/internal/ffi_os
import client/ledger_boot
import client/ledger_service
import gleam/dict
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import telemetry/log
import tom

/// Complete help for the directory operator command.
pub const usage =
  "usage: loomd directory bootstrap [--state-dir PATH] [--config PATH]

Create the session directory's cluster on this member. Run it once per
deployment, on one member, with this member's daemon stopped, through the same
launcher and LOOM_DISTRIBUTION_OPTFILE the daemon uses.

The configuration must have a [directory] table naming this node among its
members, or a membership ledger that seats this node as a voter. The command refuses when this member already has a directory store on
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
  use dist <- result.try(
    distribution.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason })
    |> result.try(fn(dist) {
      option.to_result(dist, configuration <> " has no [distribution] table")
    }),
  )

  // The members of a static deployment are read first, so that a configuration
  // with no `[directory]` is refused before anything is reserved. A ledger's
  // members are read once the ledger process runs.
  use listed <- result.try(case distribution.ledger_path(dist) {
    Some(_) -> Ok(None)
    None ->
      listed_members(document, configuration) |> result.map(fn(m) { Some(m) })
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
  use #(membership, members) <- result.try(case listed {
    None -> start_ledgered(dist)
    Some(members) -> start_listed(dist, members)
  })
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

// The members a static configuration lists, from its `[directory]` table.
fn listed_members(
  document: dict.Dict(String, tom.Toml),
  configuration: String,
) -> Result(List(String), String) {
  use found <- result.try(
    settings.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  case found {
    Some(settings.Settings(members:)) -> Ok(members)
    None -> Error(configuration <> " has no [directory] table")
  }
}

// Distribution started as a member of a static deployment's directory.
fn start_listed(
  dist: distribution.Config,
  members: List(String),
) -> Result(#(distribution.Membership, List(String)), String) {
  use membership <- result.map(
    distribution.start(dist, distribution.Member(members:))
    |> result.map_error(distribution.describe),
  )
  #(membership, members)
}

// The members of a deployment whose trust is a ledger: the nodes it seats. The
// ledger process and distribution start the way the daemon starts them, so the
// pin table exists before the listener does, and the node is visible because
// its own entry seats it. Only a voter can create the cluster: a learner has no
// vote to start one with.
fn start_ledgered(
  dist: distribution.Config,
) -> Result(#(distribution.Membership, List(String)), String) {
  use booted <- result.try(ledger_boot.start(
    dist,
    distribution.NotMember,
    log.discard(),
  ))
  use service <- result.try(option.to_result(
    booted.ledger,
    "the ledger process did not start",
  ))
  use status <- result.try(
    ledger_service.status(service, 5000)
    |> result.replace_error("the ledger process did not answer"),
  )
  let local = distribution.local_node(dist)
  let places = roster.places(status.ledger)
  use Nil <- result.map(case roster.seat_of(places, local) {
    Ok(store.Voter) -> Ok(Nil)
    Ok(store.Learner) ->
      Error(
        local
        <> " is a learner in the ledger, and a learner cannot create the "
        <> "cluster: bootstrap on a voter",
      )
    Error(Nil) ->
      Error(
        local
        <> " has no directory standing in the ledger: enroll it with "
        <> "`--directory voter` first",
      )
  })
  #(booted.membership, list.map(places, fn(place) { place.node }))
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
