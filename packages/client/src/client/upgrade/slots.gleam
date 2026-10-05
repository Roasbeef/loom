//// A VM-wide owner prevents one session overwriting another session's code.
////
//// Current users and admitted transitions both retain a fixed slot. Release
//// follows an observed completed migration or the actual actor's DOWN, never
//// a control timeout. Losing this owner fails closed while slot code remains
//// loaded; an empty replacement ledger is not proof that old users disappeared.

import client/internal/ffi_upgrade as native
import client/upgrade/source
import client/upgrade/state as abi
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/list
import gleam/result
import weft/actor
import weft/upgrade

/// The sole VM-wide slot owner's typed handle.
pub opaque type Slots {
  Slots(subject: Subject(Message))
}

type Reservation {
  Reservation(token: String, expected: abi.Identity, target: abi.Identity)
}

type State {
  State(
    live: Dict(Pid, abi.Identity),
    pending: Dict(Pid, Reservation),
    watches: Dict(Pid, Monitor),
  )
}

type Message {
  Acquire(
    Pid,
    String,
    abi.Identity,
    source.Artifact,
    Subject(Result(Nil, String)),
  )
  Confirm(Pid, String, abi.Identity, Subject(Result(Nil, String)))
  Departed(process.Down)
}

/// Resolve or create the fixed VM-wide owner without unique name atoms.
/// ## Examples
/// `owner()` returns the same slot authority to every resident session.
pub fn owner() -> Result(Slots, String) {
  let name = native.fixed_name()
  let subject = process.named_subject(name)
  case process.subject_owner(subject) {
    Ok(_) -> Ok(Slots(subject))
    Error(Nil) -> {
      use _ <- result.try(native.pristine())
      let started =
        actor.new_with_initialiser(1000, fn(_) {
          Ok(
            actor.initialised(State(dict.new(), dict.new(), dict.new()))
            |> actor.selecting(
              process.new_selector()
              |> process.select(subject)
              |> process.select_monitors(Departed),
            )
            |> actor.returning(subject),
          )
        })
        |> actor.on_message(handle)
        |> actor.named(name)
        |> actor.unlinked
        |> actor.start
      case started {
        Ok(started) -> Ok(Slots(started.data))
        Error(_) ->
          case process.subject_owner(subject) {
            Ok(_) -> Ok(Slots(subject))
            Error(Nil) ->
              Error("reviewed slot ownership authority could not start")
          }
      }
    }
  }
}

/// Reserve the target slot and serialize this actual actor's transition.
/// ## Examples
/// `acquire(owner, pid, token, expected, artifact)` refuses occupied code.
pub fn acquire(
  slots: Slots,
  pid: Pid,
  token: String,
  expected: abi.Identity,
  artifact: source.Artifact,
) -> Result(Nil, String) {
  ask(slots, Acquire(pid, token, expected, artifact, _)) |> result.flatten
}

/// Confirm current identity after resume, releasing only the displaced slot.
/// ## Examples
/// `confirm(owner, pid, token, observed)` cannot release a newer transaction.
pub fn confirm(
  slots: Slots,
  pid: Pid,
  token: String,
  observed: abi.Identity,
) -> Result(Nil, String) {
  ask(slots, Confirm(pid, token, observed, _)) |> result.flatten
}

fn ask(
  slots: Slots,
  request: fn(Subject(answer)) -> Message,
) -> Result(answer, String) {
  use pid <- result.try(
    process.subject_owner(slots.subject)
    |> result.replace_error("reviewed slot owner is unavailable"),
  )
  let reply = process.new_subject()
  let monitor = process.monitor(pid)
  process.send(slots.subject, request(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) {
      Error("reviewed slot owner exited")
    })
    |> process.selector_receive(1500)
  process.demonitor_process(monitor)
  result.unwrap(answer, Error("reviewed slot owner did not answer"))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Acquire(pid, token, expected, artifact, reply) -> {
      let admitted = reserve(state, pid, token, expected, artifact)
      process.send(reply, result.map(admitted, fn(_) { Nil }))
      actor.continue(result.unwrap(admitted, state))
    }
    Confirm(pid, token, observed, reply) -> {
      let settled = settle(state, pid, token, observed)
      process.send(reply, result.map(settled, fn(_) { Nil }))
      actor.continue(result.unwrap(settled, state))
    }
    Departed(down) -> departed(state, down)
  }
}

fn reserve(
  state: State,
  pid: Pid,
  token: String,
  expected: abi.Identity,
  artifact: source.Artifact,
) -> Result(State, String) {
  use <- bool.guard(
    dict.has_key(state.pending, pid),
    Error("scratch already has a reserved upgrade"),
  )
  let target = source.identity(artifact)
  use <- bool.guard(
    !source.accepts(artifact, expected.state_version),
    Error("reviewed release has no migration from current state version"),
  )
  let identities =
    list.append(
      dict.values(state.live),
      list.map(dict.values(state.pending), fn(item) { item.target }),
    )
  let users =
    list.filter(identities, fn(identity) {
      identity.slot == target.slot && target.slot != abi.Builtin
    })
  use <- bool.guard(
    list.any(users, fn(identity) { identity != target }),
    Error("reviewed implementation slot is occupied by another live component"),
  )
  use _ <- result.try(case target.slot, users {
    abi.Builtin, _ -> Ok(Nil)
    abi.SlotA, [] | abi.SlotB, [] -> load_checked(target, artifact)
    abi.SlotA, [_, ..] | abi.SlotB, [_, ..] -> Ok(Nil)
  })

  // The actual actor is monitored before a slot permit can leave this owner.
  let watches = case dict.get(state.watches, pid) {
    Ok(_) -> state.watches
    Error(Nil) -> dict.insert(state.watches, pid, process.monitor(pid))
  }
  use <- bool.guard(
    !native.deliver_signals(pid),
    Error("scratch target exited before slot admission"),
  )
  Ok(State(
    watches:,
    live: dict.insert(state.live, pid, expected),
    pending: dict.insert(
      state.pending,
      pid,
      Reservation(token, expected, target),
    ),
  ))
}

fn settle(
  state: State,
  pid: Pid,
  token: String,
  observed: abi.Identity,
) -> Result(State, String) {
  // Confirmation retires only this token's reservation. A missing or newer
  // token means that custody has already ended; acknowledging it again cannot
  // overwrite the successor's live identity or release its pending slot.
  case dict.get(state.pending, pid) {
    Error(Nil) -> Ok(state)
    Ok(pending) ->
      case pending.token == token {
        False -> Ok(state)
        True -> {
          use <- bool.guard(
            observed != pending.expected && observed != pending.target,
            Error("unrecognized implementation identity retains slot custody"),
          )
          Ok(
            State(
              ..state,
              pending: dict.delete(state.pending, pid),
              live: dict.insert(state.live, pid, observed),
            ),
          )
        }
      }
  }
}

fn departed(state: State, down: process.Down) -> actor.Next(State, Message) {
  case
    list.find(dict.to_list(state.watches), fn(entry) { entry.1 == down.monitor })
  {
    Error(Nil) -> actor.continue(state)
    Ok(#(pid, _)) ->
      actor.continue(State(
        live: dict.delete(state.live, pid),
        pending: dict.delete(state.pending, pid),
        watches: dict.delete(state.watches, pid),
      ))
  }
}

fn load_checked(
  target: abi.Identity,
  artifact: source.Artifact,
) -> Result(Nil, String) {
  use _ <- result.try(native.load(
    target.slot,
    source.bytes(artifact),
    target.version,
  ))
  upgrade.prepare(100, fn() {
    case native.version(target.slot) == target.version {
      True -> Ok(Nil)
      False -> Error("loaded component version differs from reviewed manifest")
    }
  })
}
