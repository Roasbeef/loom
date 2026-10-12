//// A daemon's membership in the session directory's Khepri cluster
//// (protocol-change/083): it keeps this node connected to the other members,
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
//// **It joins, and joins again if it was removed.** A store whose data
//// directory carries the `joined` marker is started at boot, before the actor exists, and Ra resumes its
//// membership. A store without the marker has never joined, or lost its disk:
//// on each tick, until one attempt succeeds, the actor asks the first member
//// whose store answers to take this node in as a non-voter, which Ra promotes
//// once it has caught up (`store.join`). Only then is the marker written, and
//// `store.mark_joined` writes Ra's record of the server to disk before it, so
//// that a marker on disk always has a server to restart (`store.restart`
//// refuses to create one if it has not). While the store is not joined, every
//// store call answers that the store is not running, which the callers report
//// as no quorum, and nothing is served from a store that has not joined.
////
//// The marker says the store joined once, and the leader can remove a member
//// afterwards: a revoke followed by an enrollment of the same name on the same
//// disk, or a repair of a member in the wrong seat. Ra never stops the server it
//// removed, so the node would go on believing it was in a cluster that no longer
//// lists it, and every store call would wait out its deadline and report no
//// quorum while the cluster was well. So a node the ledger seats whose own
//// server cannot say what the cluster holds, or does not list the node, asks a
//// peer's server, which forwards the question to the leader. When a leader
//// answers and its membership does not list the node, the node logs
//// `daemon.directory_not_a_member`, deletes the marker and its local server
//// (`store.reset`), and joins again in the seat the ledger gives it
//// (`directory.status` reports it as rejoining until then). The decision is
//// `seats.rejoin`. It never acts on a timeout or on no answer, and never on a
//// node the ledger does not seat, so a healthy member on a bad network does not
//// churn. It never creates a store: the reset goes through the join path above,
//// and a join is the only way back to a store.
////
//// The actor creates no cluster. `loomd directory bootstrap` does that once, by
//// hand, because a rule that let a member create one would let a member that
//// lost its disk create a second cluster beside the first.
////
//// ## Who the members are
////
//// Without a ledger the members are the configured list (`Listed`), all of them
//// voters, and nothing changes after start. With a ledger (`Followed`) the
//// actor reads the seats from the ledger on every tick, because they change
//// while the daemon runs: it links to every node the ledger seats, it joins in
//// the seat the ledger gives this node, and it does nothing when the ledger
//// gives this node none (protocol-change/086, phase 3).
////
//// **It reconciles, on the leader.** The ledger owns the list of members and
//// Ra follows it. A member adds itself, as above, because only it can start
//// its server. Removal is the leader's: on each tick the member that Ra names
//// leader asks `seats.plan` for the next change and applies it through
//// `store.remove_member`, one at a time and only while the removal can commit.
//// A member that is not the leader does nothing. A leader change needs no
//// event: the next tick on the new leader compares the same ledger with the
//// same Ra membership and gets the same answer, so the work is repeatable and
//// a removal is never issued twice (Ra refuses a second change until the first
//// commits, and a member already gone is `not_member`).
////
//// **A learner learns the leader late.** A learner never stands for election,
//// so a learner whose server has restarted learns who the leader is from the
//// leader's next append and not before. A join ends with such a restart
//// (`store.join` records the store through Khepri), and a directory with no
//// writes leaves the learner's own view of the cluster unanswered until one
//// arrives. Its local reads are not affected.

import client/directory/seats.{type Place, type Seats, type Verdict}
import client/directory/store
import client/distribution.{type Membership, type Peer}
import gleam/dict.{type Dict}
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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

/// Where a member learns who the members are.
pub type Members {
  /// The configured list of `[directory] members`, this node's name included.
  /// Every member is a voter, and the list never changes while the daemon runs.
  Listed(nodes: List(String))

  /// The membership ledger, read again on every tick. `read` answers the seats
  /// of the ledger as it stands now, or `Error` when the ledger process does
  /// not answer, in which case the tick acts on nothing.
  Followed(read: fn() -> Result(Seats, Nil))
}

/// What a member needs to start.
pub type Config {
  Config(
    /// The store's data directory, `<state root>/directory`.
    directory: String,
    /// Who the members are, this node's name included.
    members: Members,
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

  /// The store had joined, the leader has removed this node since, and the
  /// actor reset the store and is joining again in the seat the ledger gives.
  /// It is `NotJoined` in every other respect, and apart so that
  /// `directory.status` can say why.
  Rejoining
}

/// What `directory.status` reports.
pub type Status {
  Status(
    /// The members as of now: the configured list, or the nodes the ledger
    /// seats.
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
  Member(inbox: Subject(Message), members: Members)
}

// What the actor is told.
type Message {
  Tick
  Reached(name: String, outcome: Result(Nil, distribution.Fault))
  JoinEnded(outcome: Result(Nil, String))
  Reconciled(pass: Pass)
  Asked(reply: Subject(Joining))
}

// What one reconciliation pass did. It plans a removal from the leader's side,
// or it finds that this node is no member of the cluster it believes it is in
// and resets the store so that the next tick joins again.
type Pass {
  Planned(verdict: Verdict, outcome: Result(Nil, String))
  Reset(outcome: Result(Nil, String))
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
    joining: Joining,
    attempt: Attempt,
    backoff: Dict(String, Backoff),
    connecting: List(String),
    // Whether a reconciliation is running, and what the last one decided and
    // did, so a log line is written when that changes and not at every tick.
    reconciling: Attempt,
    decided: Option(#(Verdict, Result(Nil, String))),
  )
}

/// Starts the store and the actor. A store already joined is started here and
/// must start, because a joined member that cannot open its own store has lost
/// data an operator has to look at. It is restarted, never created: when Ra has
/// no record of the member's server the start is refused, because creating a
/// store there would make a second cluster of one member. A store that has not
/// joined is left for the actor to join.
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
      store.restart(30_000)
      |> result.map_error(fn(refusal) { restart_refusal(config, refusal) })
    NotJoined | Rejoining -> Ok(Nil)
  })
  let started =
    actor.new_with_initialiser(1000, fn(inbox) {
      let state =
        State(
          config:,
          inbox:,
          joining:,
          attempt: Idle,
          backoff: dict.new(),
          connecting: [],
          reconciling: Idle,
          decided: None,
        )
      Ok(actor.initialised(state) |> actor.returning(inbox))
    })
    |> actor.on_message(handle)
    |> actor.periodic(every: tick_ms, sending: Tick)
    |> actor.start
  case started {
    Ok(started) -> {
      log.info(config.logger, "daemon.directory_member", [
        field.count("members", list.length(nodes_of(config.members))),
        field.text("joined", case joining {
          Joined -> "yes"
          NotJoined | Rejoining -> "no"
        }),
      ])
      process.send(started.data, Tick)
      Ok(Member(inbox: started.data, members: config.members))
    }
    Error(error) ->
      Error("the directory member did not start: " <> string.inspect(error))
  }
}

// The seats as of now. A configured list seats every node as a voter and has
// no ledger to ask whether a node was ever named, so it names every node. A
// ledger that does not answer seats no one.
fn seats_of(members: Members) -> Seats {
  case members {
    Listed(nodes:) ->
      seats.Seats(
        places: list.map(nodes, fn(node) { seats.Place(node, store.Voter) }),
        named: fn(_) { True },
      )
    Followed(read:) ->
      result.unwrap(read(), seats.Seats(places: [], named: fn(_) { False }))
  }
}

fn nodes_of(members: Members) -> List(String) {
  list.map(seats_of(members).places, fn(place) { place.node })
}

// The message for a joined store that did not start. A store Ra has no record
// of is not started at all, because starting it would create a second cluster,
// and the way back depends on whether the cluster has other members to rejoin.
fn restart_refusal(config: Config, refusal: store.RestartRefusal) -> String {
  let marked =
    "the directory store in " <> config.directory <> " is marked joined but "
  case refusal {
    store.CouldNotStart(reason:) -> marked <> "did not start: " <> reason
    store.NoServerRecord ->
      marked
      <> "Ra has no record of its server, and starting it would create a"
      <> " second cluster. "
      <> case
        list.any(nodes_of(config.members), fn(name) { name != config.local })
      {
        True ->
          "Remove "
          <> store.joined_marker(config.directory)
          <> " and start the daemon again: the member then rejoins the"
          <> " cluster as a non-voter and the other members send it the data."
        False ->
          "This cluster has no other member to rejoin, so remove "
          <> config.directory
          <> " and run `loomd directory bootstrap` again."
      }
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
    Rejoining ->
      Error(store.Unavailable(
        "this member was removed from the cluster and is joining it again",
      ))
  }
  Status(
    members: nodes_of(member.members),
    joining:,
    ra:,
    applied_index: store.applied_index(),
  )
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Tick -> {
      let wanted = seats_of(state.config.members)
      state
      |> keep_links(wanted.places)
      |> try_join(wanted.places)
      |> reconcile(wanted)
      |> actor.continue
    }

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

    // A reconciliation ended. What it decided and did is written down when it
    // differs from the last pass, so a leader holding a removal it cannot commit
    // says so once and not every two seconds. A real failure is written every
    // time, because it is not going to settle by itself.
    Reconciled(pass: Planned(verdict:, outcome:)) -> {
      let now = Some(#(verdict, outcome))
      let repeated = state.decided == now && quiet(outcome)
      case repeated {
        True -> Nil
        False -> report(state.config.logger, verdict, outcome)
      }
      actor.continue(State(..state, reconciling: Idle, decided: now))
    }

    // The pass found this node out of the cluster and reset its store. From the
    // next tick the join path takes it in again in the seat the ledger gives it;
    // a reset that failed leaves the store as it was, and the next pass asks
    // again.
    Reconciled(pass: Reset(outcome: Ok(Nil))) ->
      actor.continue(
        State(..state, joining: Rejoining, reconciling: Idle, decided: None),
      )
    Reconciled(pass: Reset(outcome: Error(reason))) -> {
      log.warn(state.config.logger, "daemon.directory_reset_failed", [
        field.text("reason", reason),
      ])
      actor.continue(State(..state, reconciling: Idle))
    }

    Asked(reply:) -> {
      process.send(reply, state.joining)
      actor.continue(state)
    }
  }
}

// The peers the seats name other than this node, for the nodes the pin table
// lists. A node it does not list yet is skipped: the ledger entry that seats it
// has not reached this node, and the next tick asks again.
fn peers_of(state: State, places: List(Place)) -> List(Peer) {
  list.filter_map(places, fn(place) {
    case place.node == state.config.local {
      True -> Error(Nil)
      False ->
        distribution.peer(state.config.membership, place.node)
        |> result.replace_error(Nil)
    }
  })
}

// Starts a connection attempt for every other seated node that is not
// connected, is not being connected, and is not waiting out a backoff.
fn keep_links(state: State, places: List(Place)) -> State {
  let visible = node.visible()
  let now = bootstrap.monotonic_time_ms()
  list.fold(peers_of(state, places), state, fn(state, peer) {
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

// Starts a join attempt when the store has not joined, none is running and the
// ledger gives this node a seat. The seat decides what the join makes of it.
fn try_join(state: State, places: List(Place)) -> State {
  case state.joining, state.attempt, seats.seat_of(places, state.config.local) {
    Joined, _, _ -> state
    NotJoined, Running, _ | Rejoining, Running, _ -> state
    NotJoined, Idle, Error(Nil) | Rejoining, Idle, Error(Nil) -> state
    NotJoined, Idle, Ok(seat) | Rejoining, Idle, Ok(seat) -> {
      let inbox = state.inbox
      let peers = peers_of(state, places)
      let directory = state.config.directory
      let _witness =
        weft.new([
          fn() {
            process.send(
              inbox,
              JoinEnded(outcome: join_any(peers, directory, seat)),
            )
            Ok(Nil)
          },
        ])
        |> weft.start_witnessed
      State(..state, attempt: Running)
    }
  }
}

// Joins through the first member, in seat order, whose store answers. A
// member that cannot be reached, or whose store is not running, is skipped;
// a join that starts and fails is reported, because the next tick tries again
// from the start of the list.
fn join_any(
  peers: List(Peer),
  directory: String,
  seat: store.Seat,
) -> Result(Nil, String) {
  case peers {
    [] -> Error("no member's store answered")
    [peer, ..rest] -> {
      let _connected = distribution.connect(peer, connect_ms)
      case store.running_on(distribution.node(peer)) {
        False -> join_any(rest, directory, seat)
        True -> {
          use Nil <- result.try(
            store.join(distribution.node(peer), join_ms, seat)
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

// Starts a reconciliation when the seats come from a ledger, the store has
// joined and none is running. It runs in a task of its own because it asks Ra
// and may issue a removal, and either can wait on a quorum.
fn reconcile(state: State, wanted: Seats) -> State {
  case state.config.members, state.joining, state.reconciling {
    Followed(..), Joined, Idle -> {
      let inbox = state.inbox
      let config = state.config
      let asked =
        peers_of(state, wanted.places)
        |> list.map(distribution.node)
        |> list.filter(fn(peer) { list.contains(node.visible(), peer) })
      let _witness =
        weft.new([
          fn() {
            process.send(
              inbox,
              Reconciled(pass: reconcile_once(wanted, config, asked)),
            )
            Ok(Nil)
          },
        ])
        |> weft.start_witnessed
      State(..state, reconciling: Running)
    }
    _, _, _ -> state
  }
}

// One pass. A member the ledger seats first makes sure it is a member of the
// cluster it believes it is in, and otherwise plans from the leader's side.
//
// Ra never stops a server it removes, so a node the leader removed (a revoke
// and an enrollment of the same name, or an other-seat repair) goes on running
// a store that belongs to no cluster, and its calls queue until their deadline.
// The cheap sign is that its own server cannot say what the cluster holds, or
// says and does not list this node. Then, and only then, it asks a peer, whose
// server forwards the question to the leader (`store.membership_through`), and
// resets when a leader answers without it (`seats.rejoin`). Most passes find
// this node listed and ask nothing.
//
// Otherwise the pass is the leader's: the plan against the seats and the
// removal the plan names. A member that cannot read Ra's membership has no
// verdict to give and reports it as not the leader, which does nothing and says
// nothing.
fn reconcile_once(wanted: Seats, config: Config, asked: List(Node)) -> Pass {
  let local = config.local
  let own = store.membership()
  case rejoin_due(wanted, local, own, asked) {
    seats.Rejoin -> {
      log.warn(config.logger, "daemon.directory_not_a_member", [
        field.text("node", local),
      ])
      Reset(store.reset(config.directory))
    }
    seats.Stay ->
      case own {
        Error(_) -> Planned(seats.NotLeader, Ok(Nil))
        Ok(ra) -> {
          let verdict = seats.plan(wanted, ra, local)
          case verdict {
            seats.Remove(node: gone, ..) ->
              Planned(verdict, store.remove_member(gone))
            seats.NotLeader
            | seats.NotSeated
            | seats.Settled(..)
            | seats.Held(..) -> Planned(verdict, Ok(Nil))
          }
        }
      }
  }
}

// Whether to reset, asking the peers only when this node's own view does not
// settle the question. The first peer that gives an answer decides; one that
// does not is skipped, and no answer at all is `Stay`.
fn rejoin_due(
  wanted: Seats,
  local: String,
  own: Result(store.Membership, store.Unavailable),
  asked: List(Node),
) -> seats.Rejoin {
  case seats.seat_of(wanted.places, local), own {
    Error(Nil), _ -> seats.Stay
    Ok(_), Ok(ra) ->
      case list.key_find(ra.members, local) {
        Ok(_) -> seats.Stay
        Error(Nil) -> seats.rejoin(wanted, local, first_answer(asked))
      }
    Ok(_), Error(_) -> seats.rejoin(wanted, local, first_answer(asked))
  }
}

fn first_answer(asked: List(Node)) -> Result(store.Membership, Nil) {
  list.find_map(asked, fn(peer) {
    store.membership_through(peer) |> result.replace_error(Nil)
  })
}

// Whether a pass that repeats the last one is worth no line: it did what it did
// before, or it is waiting out a change that will settle by itself.
fn quiet(outcome: Result(Nil, String)) -> Bool {
  case outcome {
    Ok(Nil) -> True
    Error(reason) -> reason == store.settling
  }
}

// Writes down what a reconciliation decided or did. `NotLeader` is the state of
// every member but one and is not worth a line, and a leader the ledger no longer
// seats has been cut off by the revoke that unseated it.
fn report(
  logger: Logger,
  verdict: Verdict,
  outcome: Result(Nil, String),
) -> Nil {
  case verdict, outcome {
    seats.NotLeader, _ | seats.NotSeated, _ -> Nil
    seats.Settled(missing:, foreign:), _ ->
      case missing, foreign {
        [], [] -> Nil
        _, _ ->
          log.info(logger, "daemon.directory_reconciled", [
            field.text("missing", string.join(missing, ",")),
            field.text("foreign", string.join(foreign, ",")),
          ])
      }
    seats.Remove(node: gone, why:), Ok(Nil) ->
      log.info(logger, "daemon.directory_member_removed", [
        field.text("node", gone),
        field.text("why", why_word(why)),
      ])
    seats.Remove(node: gone, why:), Error(reason) if reason == store.settling ->
      log.info(logger, "daemon.directory_remove_held", [
        field.text("node", gone),
        field.text("why", why_word(why)),
        field.text("reason", reason),
      ])
    seats.Remove(node: gone, why:), Error(reason) ->
      log.warn(logger, "daemon.directory_remove_failed", [
        field.text("node", gone),
        field.text("why", why_word(why)),
        field.text("reason", reason),
      ])
    seats.Held(node: gone, why:), _ ->
      log.warn(logger, "daemon.directory_remove_held", [
        field.text("node", gone),
        field.text("why", why_word(why)),
        field.text(
          "reason",
          "a majority of the voters that would remain is not replicating",
        ),
      ])
  }
}

fn why_word(why: seats.Why) -> String {
  case why {
    seats.Unseated -> "unseated"
    seats.OtherSeat -> "other_seat"
  }
}
