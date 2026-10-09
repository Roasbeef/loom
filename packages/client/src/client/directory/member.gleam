//// A daemon's membership in the session directory's Khepri cluster
//// (protocol-change/081): it keeps this node connected to the other members,
//// and it joins the cluster when this node's store has never joined.
////
//// One actor per member daemon, started with the daemon's services and linked
//// to them. It ticks every two seconds and does two things on each tick.
////
//// **It keeps the links.** For every other member missing from `nodes()`, it
//// connects through `distribution.connect`, which makes the link visible
//// because both ends are members. A member that does not answer is tried
//// again after a delay that doubles up to thirty seconds, so a machine that
//// is down costs one connection attempt per delay and not one per tick. Each
//// attempt runs in a task of its own, so the actor never waits on a handshake.
//// This is what lets a cut network heal without an operator, beside Ra's own
//// dial when its server starts.
////
//// **It joins, once.** A store whose data directory carries the `joined`
//// marker is started at boot, before the actor exists, and Ra resumes its
//// membership. A store without the marker has never joined, or lost its disk:
//// on each tick, until one attempt succeeds, the actor asks the first member
//// whose store answers to take this node in as a non-voter, which Ra promotes
//// once it has caught up (`store.join`). Only then is the marker written. While
//// the store is not joined, every store call answers that the store is not
//// running, which the callers report as no quorum, and nothing is served from a
//// store that has not joined.
////
//// The actor creates no cluster. `loomd directory bootstrap` does that once, by
//// hand, because a rule that let a member create one would let a member that
//// lost its disk create a second cluster beside the first.

import client/directory/store
import client/distribution.{type Membership, type Peer}
import gleam/dict.{type Dict}
import gleam/erlang/node
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import telemetry/field
import telemetry/log.{type Logger}
import weft
import weft/actor

/// How often the actor ticks, in milliseconds.
pub const tick_ms = 2000

/// The longest a member that does not answer waits between attempts.
pub const longest_wait_ms = 30_000

/// How long one join attempt may take.
pub const join_ms = 60_000

/// How long one connection attempt may take.
pub const connect_ms = 1500

/// What a member needs to start.
pub type Config {
  Config(
    /// The store's data directory, `<state root>/directory`.
    directory: String,
    /// Every member's node name, this node's included.
    members: List(String),
    /// This node's own name.
    local: String,
    /// The distribution membership the daemon started, through which the
    /// other members are resolved and connected.
    membership: Membership,
    /// Where the actor writes down what it did.
    logger: Logger,
  )
}

/// Whether this node's store has joined the cluster.
pub type Joining {
  /// The store has joined, now or before this daemon started.
  Joined

  /// The store has not joined yet; the actor is trying.
  NotJoined
}

/// What `directory.status` reports.
pub type Status {
  Status(
    /// The configured members.
    members: List(String),
    /// Whether this node's store has joined.
    joining: Joining,
    /// Ra's members and leader as this node sees them, or why it cannot say.
    ra: Result(store.Membership, store.Unavailable),
    /// The last log index this node has applied.
    applied_index: Int,
  )
}

/// A running member actor.
pub opaque type Member {
  Member(inbox: Subject(Message), members: List(String))
}

// What the actor is told.
type Message {
  Tick
  Reached(name: String, outcome: Result(Nil, distribution.Fault))
  JoinEnded(outcome: Result(Nil, String))
  Asked(reply: Subject(Joining))
}

// When a member that did not answer may be tried again, and how long the next
// wait will be.
type Backoff {
  Backoff(next_ms: Int, wait_ms: Int)
}

// Whether a join attempt is running. One at a time: a second attempt would
// race the first for the same member identity.
type Attempt {
  Idle
  Running
}

type State {
  State(
    config: Config,
    inbox: Subject(Message),
    peers: List(Peer),
    joining: Joining,
    attempt: Attempt,
    backoff: Dict(String, Backoff),
    connecting: List(String),
  )
}

/// Starts the store and the actor. A store already joined is started here and
/// must start, because a joined member that cannot open its own store has lost
/// data an operator has to look at. A store that has not joined is left for the
/// actor to join.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(member) = member.start(member.Config(..))
/// ```
pub fn start(config: Config) -> Result(Member, String) {
  use Nil <- result.try(store.start_system(config.directory))
  let joining = case store.is_joined(config.directory) {
    True -> Joined
    False -> NotJoined
  }
  use Nil <- result.try(case joining {
    Joined ->
      store.boot(30_000)
      |> result.map_error(fn(reason) {
        "the directory store in "
        <> config.directory
        <> " is marked joined but did not start: "
        <> reason
      })
    NotJoined -> Ok(Nil)
  })
  let peers =
    list.filter_map(config.members, fn(name) {
      case name == config.local {
        True -> Error(Nil)
        False ->
          distribution.peer(config.membership, name)
          |> result.replace_error(Nil)
      }
    })
  let started =
    actor.new_with_initialiser(1000, fn(inbox) {
      let state =
        State(
          config:,
          inbox:,
          peers:,
          joining:,
          attempt: Idle,
          backoff: dict.new(),
          connecting: [],
        )
      Ok(actor.initialised(state) |> actor.returning(inbox))
    })
    |> actor.on_message(handle)
    |> actor.periodic(every: tick_ms, sending: Tick)
    |> actor.start
  case started {
    Ok(started) -> {
      log.info(config.logger, "daemon.directory_member", [
        field.count("members", list.length(config.members)),
        field.text("joined", case joining {
          Joined -> "yes"
          NotJoined -> "no"
        }),
      ])
      process.send(started.data, Tick)
      Ok(Member(inbox: started.data, members: config.members))
    }
    Error(error) ->
      Error("the directory member did not start: " <> string.inspect(error))
  }
}

/// What this member knows about the cluster. Ra's view is asked from the
/// caller's process, so a slow store never holds up the actor.
///
/// ## Examples
///
/// ```gleam
/// // member.status(member).joining // -> member.Joined
/// ```
pub fn status(member: Member) -> Status {
  let joining = process.call(member.inbox, waiting: 5000, sending: Asked)
  let ra = case joining {
    Joined -> store.membership()
    NotJoined -> Error(store.Unavailable("this member has not joined"))
  }
  Status(
    members: member.members,
    joining:,
    ra:,
    applied_index: store.applied_index(),
  )
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Tick -> state |> keep_links |> try_join |> actor.continue

    // A connection attempt ended. A success forgets the member's backoff; a
    // failure doubles the wait before the next attempt.
    Reached(name:, outcome:) -> {
      let connecting = list.filter(state.connecting, fn(held) { held != name })
      let backoff = case outcome {
        Ok(Nil) -> dict.delete(state.backoff, name)
        Error(_) -> {
          let wait = case dict.get(state.backoff, name) {
            Ok(Backoff(wait_ms:, ..)) ->
              int.min(longest_wait_ms, int.max(tick_ms, wait_ms * 2))
            Error(Nil) -> tick_ms
          }
          dict.insert(
            state.backoff,
            name,
            Backoff(
              next_ms: bootstrap.monotonic_time_ms() + wait,
              wait_ms: wait,
            ),
          )
        }
      }
      actor.continue(State(..state, connecting:, backoff:))
    }

    JoinEnded(outcome:) ->
      case outcome {
        Ok(Nil) -> {
          log.info(state.config.logger, "daemon.directory_joined", [])
          actor.continue(State(..state, joining: Joined, attempt: Idle))
        }
        Error(reason) -> {
          log.warn(state.config.logger, "daemon.directory_join_failed", [
            field.text("reason", reason),
          ])
          actor.continue(State(..state, attempt: Idle))
        }
      }

    Asked(reply:) -> {
      process.send(reply, state.joining)
      actor.continue(state)
    }
  }
}

// Starts a connection attempt for every other member that is not connected,
// is not being connected, and is not waiting out a backoff.
fn keep_links(state: State) -> State {
  let visible = node.visible()
  let now = bootstrap.monotonic_time_ms()
  list.fold(state.peers, state, fn(state, peer) {
    let name = distribution.name(peer)
    let due = case dict.get(state.backoff, name) {
      Ok(Backoff(next_ms:, ..)) -> now >= next_ms
      Error(Nil) -> True
    }
    case
      list.contains(visible, distribution.node(peer))
      || list.contains(state.connecting, name)
      || !due
    {
      True -> state
      False -> {
        let inbox = state.inbox
        let _witness =
          weft.new([
            fn() {
              process.send(
                inbox,
                Reached(name:, outcome: distribution.connect(peer, connect_ms)),
              )
              Ok(Nil)
            },
          ])
          |> weft.start_witnessed
        State(..state, connecting: [name, ..state.connecting])
      }
    }
  })
}

// Starts a join attempt when the store has not joined and none is running.
fn try_join(state: State) -> State {
  case state.joining, state.attempt {
    Joined, _ | NotJoined, Running -> state
    NotJoined, Idle -> {
      let inbox = state.inbox
      let peers = state.peers
      let directory = state.config.directory
      let _witness =
        weft.new([
          fn() {
            process.send(inbox, JoinEnded(outcome: join_any(peers, directory)))
            Ok(Nil)
          },
        ])
        |> weft.start_witnessed
      State(..state, attempt: Running)
    }
  }
}

// Joins through the first member, in configuration order, whose store answers.
// A member that cannot be reached, or whose store is not running, is skipped;
// a join that starts and fails is reported, because the next tick tries again
// from the start of the list.
fn join_any(peers: List(Peer), directory: String) -> Result(Nil, String) {
  case peers {
    [] -> Error("no member's store answered")
    [peer, ..rest] -> {
      let _connected = distribution.connect(peer, connect_ms)
      case store.running_on(distribution.node(peer)) {
        False -> join_any(rest, directory)
        True -> {
          use Nil <- result.try(
            store.join(distribution.node(peer), join_ms)
            |> result.map_error(fn(reason) {
              "joining through " <> distribution.name(peer) <> ": " <> reason
            }),
          )
          store.mark_joined(directory)
        }
      }
    }
  }
}
