//// The catalogue's custody, deletion-mark and delegate-state machines, run as
//// one stateful property over a real SQLite file.
////
//// `catalogue_test` pins each transition with an example. This module states
//// the whole machine once, as a pure model, and lets `statem` look for the
//// sequence of transitions that breaks it. The machine is the one
//// `packages/storage/CLAUDE.md` describes: custody moves `Resident` to
//// `Moving` to `Moved` (`Moving` back to `Resident` on an abort, `Resident`
//// to `Imported`, and onward or home again under a new op), every transition
//// is a compare-and-set keyed by the move's op, a repeat of the same op
//// answers the stored custody and writes nothing, anything else is
//// `Conflict`, `delete` refuses a session that is moving or moved, a deletion
//// mark needs a registration, and a delegate state only moves forward.
////
//// A command names its session, op, peer and spawner by index into a small
//// pool, so a stale op, a wrong peer and a transition out of order are all
//// common draws, and deleting commands during shrinking leaves a sequence
//// that still means something. The model is the whole machine and is pure,
//// so `step` gives both the answer a transition must return and the state it
//// must leave; `execute` runs the command on the catalogue, compares the
//// answer, and then reads back everything the catalogue exposes and compares
//// that too, including the catalogue revision, so a refused transition that
//// wrote anything shows up even if its answer was right.
////
//// ## Flow
////
//// `catalogue_spec` → `execute` → `step` → `audit`
////
//// 1. `step` is the machine: it returns the expected `Answer` and the next
////    `Model` for a command, and is also the spec's `next_model`.
//// 2. `perform` runs the same command on the real catalogue and reduces its
////    result to an `Answer`.
//// 3. `audit` reads every session's custody, mark and delegate row, the
////    listings, and the revision, and compares them with the model.
////
//// The seed and counts are fixed constants, so the gate is deterministic.

import core/clock
import core/ids
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import statem
import storage/catalogue.{type Catalogue}
import support/fixtures

/// The number of random sequences the property runs. Each opens a catalogue
/// file, so the count stays modest.
const sequence_count = 60

/// The longest sequence one run may draw.
const sequence_length = 40

/// The seed every sequence derives from. Fixed, so the gate is the same gate
/// on every machine.
const sequence_seed = 8831

/// How a command names a delegate state. The three words in order, so a
/// smaller index is an earlier state.
type Word {
  Opened
  Releasing
  Released
}

/// Whether a session carries a deletion mark.
type Marking {
  Marked
  Unmarked
}

/// A delegate session row as the model holds it: which spawner and parent
/// pair it serves, when it was last touched and how far its release has got.
type Binding {
  Binding(spawner: Int, parent: Int, contact: Int, state: Word)
}

/// What the model holds for one registered session.
type Row {
  Row(custody: catalogue.Custody, marking: Marking, binding: Option(Binding))
}

/// One catalogue operation, symbolic. A `slot` is a session out of three, an
/// `op` one of three move operations, a `peer` one of two orchestrators, a
/// `spawner` one of two spawners and a `parent` one of three parent sessions.
type Command {
  Register(slot: Int)
  Delete(slot: Int)
  BeginMove(slot: Int, op: Int, peer: Int)
  FinishMove(slot: Int, op: Int)
  AbortMove(slot: Int, op: Int)
  Import(slot: Int, op: Int, peer: Int)
  Mark(slot: Int)
  Unmark(slot: Int)
  Claim(slot: Int, spawner: Int, parent: Int, limit: Int, now: Int)
  SetState(slot: Int, word: Word)

  /// Close the catalogue and open the same file again.
  Reopen
}

/// The expected catalogue: the registered sessions and how many times the
/// revision has moved since the empty file.
type Model {
  Model(rows: Dict(Int, Row), revision: Int)
}

/// An operation's answer reduced to what the machine specifies.
type Answer {
  Registered(Result(String, catalogue.Error))
  Deleted(Result(String, catalogue.Error))
  Custody(Result(catalogue.Custody, catalogue.Error))
  Written(Result(Nil, catalogue.Error))
  Claimed(Result(catalogue.DelegateClaim, catalogue.Error))
  Done
}

/// The catalogue under test and the revision of the empty file, which the
/// model counts from.
type Sut {
  Sut(store: Catalogue, path: String, base: Int)
}

fn fail(tag: String, detail: String) -> Result(a, statem.Violation) {
  Error(statem.Violation(tag:, detail:))
}

fn agree(
  tag: String,
  label: String,
  expected: a,
  observed: a,
) -> Result(Nil, statem.Violation) {
  case expected == observed {
    True -> Ok(Nil)
    False ->
      fail(
        tag,
        label
          <> ": expected "
          <> string.inspect(expected)
          <> ", the catalogue answered "
          <> string.inspect(observed),
      )
  }
}

// --- the pools a command indexes -------------------------------------------

fn registration(slot: Int) -> catalogue.Registration {
  let generator =
    ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 500 + slot % 3)
  let #(id, _) = ids.mint_session(generator)
  let id = ids.session_id_to_string(id)
  catalogue.Registration(
    id:,
    path: "/unopened-loom-catalogue-model/" <> id <> ".db",
    workspace: "/workspace/model",
    name: "model " <> int.to_string(slot % 3),
    configuration: "/configuration/loom.toml",
    created_at: 1_700_000_000_000,
    request_key: "model-request-" <> int.to_string(slot % 3),
    state: catalogue.Reserved,
    profile: None,
    model: None,
    executor: "",
    pool: "",
    subtitle: None,
  )
}

fn session(slot: Int) -> String {
  registration(slot).id
}

fn parent(index: Int) -> String {
  let generator =
    ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 600 + index % 3)
  let #(id, _) = ids.mint_session(generator)
  ids.session_id_to_string(id)
}

fn op_name(op: Int) -> String {
  "move-" <> int.to_string(op % 3)
}

fn peer_name(peer: Int) -> String {
  case peer % 2 {
    0 -> "laptop"
    _ -> "desk"
  }
}

fn spawner_name(spawner: Int) -> String {
  peer_name(spawner)
}

fn state_of(word: Word) -> catalogue.DelegateState {
  case word {
    Opened -> catalogue.Open
    Releasing -> catalogue.Releasing
    Released -> catalogue.Released
  }
}

fn rank(word: Word) -> Int {
  case word {
    Opened -> 0
    Releasing -> 1
    Released -> 2
  }
}

fn delegate_of(slot: Int, binding: Binding) -> catalogue.Delegate {
  catalogue.Delegate(
    spawner: spawner_name(binding.spawner),
    parent_session: parent(binding.parent),
    session_id: session(slot),
    last_contact_ms: binding.contact,
    state: state_of(binding.state),
  )
}

// --- the machine ------------------------------------------------------------

fn bump(model: Model) -> Model {
  Model(..model, revision: model.revision + 1)
}

fn put(model: Model, slot: Int, row: Row) -> Model {
  Model(..model, rows: dict.insert(model.rows, slot % 3, row))
}

// A session the catalogue has never registered, or has since deleted, is
// `Missing` to every operation that reads its registration first.
fn on_row(
  model: Model,
  slot: Int,
  missing: Answer,
  found: fn(Row) -> #(Answer, Model),
) -> #(Answer, Model) {
  case dict.get(model.rows, slot % 3) {
    Ok(row) -> found(row)
    Error(Nil) -> #(missing, model)
  }
}

fn custody_missing() -> Answer {
  Custody(Error(catalogue.Missing))
}

// A transition that writes: the new custody, one revision.
fn moved_to(
  model: Model,
  slot: Int,
  row: Row,
  custody: catalogue.Custody,
) -> #(Answer, Model) {
  #(Custody(Ok(custody)), bump(put(model, slot, Row(..row, custody:))))
}

fn step(model: Model, command: Command) -> #(Answer, Model) {
  case command {
    Register(slot:) ->
      case dict.get(model.rows, slot % 3) {
        Ok(_) -> #(Registered(Ok(session(slot))), model)
        Error(Nil) -> #(
          Registered(Ok(session(slot))),
          bump(put(
            model,
            slot,
            Row(custody: catalogue.Resident, marking: Unmarked, binding: None),
          )),
        )
      }

    // The row is the only record of who owns a session that is moving or
    // has moved, so such a session is not deleted, and nothing about it,
    // not even its mark or its delegate row, changes.
    Delete(slot:) ->
      on_row(model, slot, Deleted(Error(catalogue.Missing)), fn(row) {
        case row.custody {
          catalogue.Moving(..) | catalogue.Moved(..) -> #(
            Deleted(Error(catalogue.Conflict)),
            model,
          )
          catalogue.Resident | catalogue.Imported(..) -> #(
            Deleted(Ok(session(slot))),
            bump(Model(..model, rows: dict.delete(model.rows, slot % 3))),
          )
        }
      })

    BeginMove(slot:, op:, peer:) ->
      on_row(model, slot, custody_missing(), fn(row) {
        let to = peer_name(peer)
        case row.custody {
          catalogue.Resident | catalogue.Imported(..) ->
            moved_to(model, slot, row, catalogue.Moving(op: op_name(op), to:))
          catalogue.Moving(op: held, to: held_peer)
          | catalogue.Moved(op: held, to: held_peer) ->
            case held == op_name(op) && held_peer == to {
              True -> #(Custody(Ok(row.custody)), model)
              False -> #(Custody(Error(catalogue.Conflict)), model)
            }
        }
      })

    FinishMove(slot:, op:) ->
      on_row(model, slot, custody_missing(), fn(row) {
        let wanted = op_name(op)
        case row.custody {
          catalogue.Moving(op: held, to:) if held == wanted ->
            moved_to(model, slot, row, catalogue.Moved(op: held, to:))
          catalogue.Moved(op: held, ..) if held == wanted -> #(
            Custody(Ok(row.custody)),
            model,
          )
          catalogue.Resident
          | catalogue.Moving(..)
          | catalogue.Moved(..)
          | catalogue.Imported(..) -> #(
            Custody(Error(catalogue.Conflict)),
            model,
          )
        }
      })

    AbortMove(slot:, op:) ->
      on_row(model, slot, custody_missing(), fn(row) {
        let wanted = op_name(op)
        case row.custody {
          catalogue.Resident -> #(Custody(Ok(catalogue.Resident)), model)
          catalogue.Moving(op: held, ..) if held == wanted ->
            moved_to(model, slot, row, catalogue.Resident)
          catalogue.Moving(..) | catalogue.Moved(..) | catalogue.Imported(..) -> #(
            Custody(Error(catalogue.Conflict)),
            model,
          )
        }
      })

    Import(slot:, op:, peer:) ->
      on_row(model, slot, custody_missing(), fn(row) {
        let from = peer_name(peer)
        let wanted = op_name(op)
        case row.custody {
          catalogue.Resident ->
            moved_to(
              model,
              slot,
              row,
              catalogue.Imported(op: op_name(op), from:),
            )
          catalogue.Imported(op: held, from: source) ->
            case held == op_name(op) && source == from {
              True -> #(Custody(Ok(row.custody)), model)
              False -> #(Custody(Error(catalogue.Conflict)), model)
            }
          catalogue.Moved(op: held, ..) if held != wanted ->
            moved_to(
              model,
              slot,
              row,
              catalogue.Imported(op: op_name(op), from:),
            )
          catalogue.Moving(..) | catalogue.Moved(..) -> #(
            Custody(Error(catalogue.Conflict)),
            model,
          )
        }
      })

    Mark(slot:) ->
      on_row(model, slot, Written(Error(catalogue.Missing)), fn(row) {
        #(Written(Ok(Nil)), put(model, slot, Row(..row, marking: Marked)))
      })

    // Removing an absent mark, or the mark of a session that is not
    // registered, changes nothing and is not an error.
    Unmark(slot:) ->
      case dict.get(model.rows, slot % 3) {
        Ok(row) -> #(
          Written(Ok(Nil)),
          put(model, slot, Row(..row, marking: Unmarked)),
        )
        Error(Nil) -> #(Written(Ok(Nil)), model)
      }

    Claim(slot:, spawner:, parent:, limit:, now:) ->
      on_row(model, slot, Claimed(Error(catalogue.Missing)), fn(row) {
        claim(model, slot, row, spawner, parent, limit, now)
      })

    SetState(slot:, word:) ->
      on_row(model, slot, Written(Error(catalogue.Missing)), fn(row) {
        case row.binding {
          None -> #(Written(Error(catalogue.Missing)), model)
          Some(binding) ->
            case rank(word) < rank(binding.state) {
              True -> #(Written(Error(catalogue.Conflict)), model)
              False -> #(
                Written(Ok(Nil)),
                put(
                  model,
                  slot,
                  Row(..row, binding: Some(Binding(..binding, state: word))),
                ),
              )
            }
        }
      })

    Reopen -> #(Done, model)
  }
}

// A claim answers the pair's existing row and touches it, whatever the count;
// a pair bound to another session is a conflict; a new pair is recorded unless
// the spawner already holds `limit` sessions, which writes nothing. Claims
// move no revision, because no listing shows them.
fn claim(
  model: Model,
  slot: Int,
  row: Row,
  spawner: Int,
  parent: Int,
  limit: Int,
  now: Int,
) -> #(Answer, Model) {
  let pair_holder =
    dict.to_list(model.rows)
    |> list.find(fn(entry) {
      case { entry.1 }.binding {
        Some(held) -> held.spawner == spawner % 2 && held.parent == parent % 3
        None -> False
      }
    })
  case pair_holder {
    Ok(#(holder, Row(binding: Some(held), ..) as held_row)) ->
      case holder == slot % 3 {
        True -> {
          let touched = Binding(..held, contact: now)
          #(
            Claimed(Ok(catalogue.Claimed(delegate_of(slot, touched)))),
            put(model, slot, Row(..held_row, binding: Some(touched))),
          )
        }
        False -> #(Claimed(Error(catalogue.Conflict)), model)
      }
    Ok(#(_, Row(binding: None, ..))) | Error(Nil) -> {
      let held = held_by(model, spawner)
      case held >= limit {
        True -> #(Claimed(Ok(catalogue.AtLimit(held:))), model)
        False -> {
          let recorded =
            Binding(
              spawner: spawner % 2,
              parent: parent % 3,
              contact: now,
              state: Opened,
            )
          #(
            Claimed(Ok(catalogue.Claimed(delegate_of(slot, recorded)))),
            put(model, slot, Row(..row, binding: Some(recorded))),
          )
        }
      }
    }
  }
}

fn held_by(model: Model, spawner: Int) -> Int {
  list.count(dict.values(model.rows), fn(row) {
    case row.binding {
      Some(held) -> held.spawner == spawner % 2
      None -> False
    }
  })
}

// --- the catalogue ----------------------------------------------------------

fn open_store(path: String) -> Catalogue {
  let assert Ok(store) = catalogue.open(path) as "the catalogue opens"
  store
}

fn revision_of(store: Catalogue) -> Result(Int, statem.Violation) {
  case catalogue.page(store, after: "") {
    Ok(page) -> Ok(page.revision)
    Error(error) -> fail("read", "page: " <> string.inspect(error))
  }
}

fn id_of(record: catalogue.Registration) -> String {
  record.id
}

fn perform(store: Catalogue, command: Command) -> Answer {
  case command {
    Register(slot:) ->
      Registered(
        catalogue.reserve(store, registration(slot)) |> result.map(id_of),
      )

    Delete(slot:) ->
      Deleted(catalogue.delete(store, session(slot)) |> result.map(id_of))

    BeginMove(slot:, op:, peer:) ->
      Custody(catalogue.begin_move(
        store,
        session(slot),
        op: op_name(op),
        to: peer_name(peer),
      ))

    FinishMove(slot:, op:) ->
      Custody(catalogue.finish_move(store, session(slot), op: op_name(op)))

    AbortMove(slot:, op:) ->
      Custody(catalogue.abort_move(store, session(slot), op: op_name(op)))

    Import(slot:, op:, peer:) ->
      Custody(catalogue.import_session(
        store,
        session(slot),
        op: op_name(op),
        from: peer_name(peer),
      ))

    Mark(slot:) -> Written(catalogue.mark_deleting(store, session(slot)))

    Unmark(slot:) -> Written(catalogue.unmark_deleting(store, session(slot)))

    Claim(slot:, spawner:, parent: parent_index, limit:, now:) ->
      Claimed(catalogue.claim_delegate(
        store,
        spawner_name(spawner),
        parent(parent_index),
        session(slot),
        limit:,
        now_ms: now,
      ))

    SetState(slot:, word:) ->
      Written(catalogue.set_delegate_state(store, session(slot), state_of(word)))

    Reopen -> Done
  }
}

// The family a command belongs to, which names the violation when its answer
// is wrong, so shrinking a bad custody answer never slides into a bad mark.
fn family(command: Command) -> String {
  case command {
    Register(..) -> "registration-answer"
    Delete(..) -> "delete-answer"
    BeginMove(..) | FinishMove(..) | AbortMove(..) | Import(..) ->
      "custody-answer"
    Mark(..) | Unmark(..) -> "mark-answer"
    Claim(..) -> "claim-answer"
    SetState(..) -> "delegate-state-answer"
    Reopen -> "reopen"
  }
}

// --- reading the whole catalogue back ----------------------------------------

fn slots() -> List(Int) {
  [0, 1, 2]
}

fn expected_custody(
  model: Model,
  slot: Int,
) -> Result(catalogue.Custody, catalogue.Error) {
  case dict.get(model.rows, slot) {
    Ok(row) -> Ok(row.custody)
    Error(Nil) -> Error(catalogue.Missing)
  }
}

fn sorted(ids: List(String)) -> List(String) {
  list.sort(ids, string.compare)
}

fn registered_slots(model: Model) -> List(Int) {
  list.filter(slots(), fn(slot) { dict.has_key(model.rows, slot) })
}

fn check_slot(
  sut: Sut,
  model: Model,
  slot: Int,
) -> Result(Nil, statem.Violation) {
  let label = " of session " <> int.to_string(slot)
  use Nil <- result.try(agree(
    "custody-state",
    "custody" <> label,
    expected_custody(model, slot),
    catalogue.custody(sut.store, session(slot)),
  ))
  use Nil <- result.try(agree(
    "mark-state",
    "deletion mark" <> label,
    Ok(case dict.get(model.rows, slot) {
      Ok(Row(marking: Marked, ..)) -> catalogue.Deleting
      Ok(Row(marking: Unmarked, ..)) | Error(Nil) -> catalogue.NotDeleting
    }),
    catalogue.deletion(sut.store, session(slot)),
  ))
  agree(
    "delegate-state",
    "delegate row" <> label,
    Ok(case dict.get(model.rows, slot) {
      Ok(Row(binding: Some(binding), ..)) -> Some(delegate_of(slot, binding))
      Ok(Row(binding: None, ..)) | Error(Nil) -> None
    }),
    catalogue.delegate_of(sut.store, session(slot)),
  )
}

fn check_listings(sut: Sut, model: Model) -> Result(Nil, statem.Violation) {
  let live = registered_slots(model)
  let rows =
    list.filter_map(live, fn(slot) {
      dict.get(model.rows, slot) |> result.map(fn(row) { #(slot, row) })
    })
  use Nil <- result.try(agree(
    "deleting-list",
    "sessions marked for deletion",
    Ok(
      list.filter_map(rows, fn(entry) {
        case { entry.1 }.marking {
          Marked -> Ok(session(entry.0))
          Unmarked -> Error(Nil)
        }
      })
      |> sorted,
    ),
    catalogue.deleting(sut.store),
  ))
  use Nil <- result.try(agree(
    "moving-list",
    "moves still moving",
    Ok(
      list.filter_map(rows, fn(entry) {
        case { entry.1 }.custody {
          catalogue.Moving(op:, to:) ->
            Ok(catalogue.Pending(session: session(entry.0), op:, to:))
          catalogue.Resident | catalogue.Moved(..) | catalogue.Imported(..) ->
            Error(Nil)
        }
      })
      |> list.sort(fn(left, right) {
        string.compare(left.session, right.session)
      }),
    ),
    catalogue.moving(sut.store),
  ))
  use Nil <- result.try(agree(
    "custody-state",
    "every custody row",
    Ok(
      list.filter_map(rows, fn(entry) {
        case { entry.1 }.custody {
          catalogue.Resident -> Error(Nil)
          custody -> Ok(#(session(entry.0), custody))
        }
      })
      |> list.sort(fn(left, right) { string.compare(left.0, right.0) }),
    ),
    catalogue.custodies(sut.store)
      |> result.map(
        list.sort(_, fn(left, right) { string.compare(left.0, right.0) }),
      ),
  ))
  check_delegates(sut, rows)
}

fn check_delegates(
  sut: Sut,
  rows: List(#(Int, Row)),
) -> Result(Nil, statem.Violation) {
  use Nil <- result.try(agree(
    "delegate-state",
    "every delegate row",
    Ok(
      list.filter_map(rows, fn(entry) {
        case { entry.1 }.binding {
          Some(binding) -> Ok(delegate_of(entry.0, binding))
          None -> Error(Nil)
        }
      })
      |> list.sort(fn(left, right) {
        string.compare(left.session_id, right.session_id)
      }),
    ),
    catalogue.delegates(sut.store),
  ))
  list.try_each([0, 1], fn(spawner) {
    agree(
      "delegate-count",
      "delegates held by " <> spawner_name(spawner),
      Ok(
        list.count(rows, fn(entry) {
          case { entry.1 }.binding {
            Some(binding) -> binding.spawner == spawner
            None -> False
          }
        }),
      ),
      catalogue.delegates_held(sut.store, spawner_name(spawner)),
    )
  })
}

// Registrations move the revision, and so does every custody row that
// changes; a refused or repeated transition, a mark and a delegate write do
// not. The revision is read against the empty file's.
fn check_revision(sut: Sut, model: Model) -> Result(Nil, statem.Violation) {
  use revision <- result.try(revision_of(sut.store))
  agree("revision", "revision", sut.base + model.revision, revision)
}

fn audit(sut: Sut, model: Model) -> Result(Nil, statem.Violation) {
  use Nil <- result.try(list.try_each(slots(), check_slot(sut, model, _)))
  use Nil <- result.try(check_listings(sut, model))
  check_revision(sut, model)
}

fn reopen(sut: Sut) -> Result(Sut, statem.Violation) {
  case catalogue.close(sut.store) {
    Ok(Nil) -> Ok(Sut(..sut, store: open_store(sut.path)))
    Error(error) -> fail("reopen", "close failed: " <> string.inspect(error))
  }
}

fn execute(
  sut: Sut,
  model: Model,
  command: Command,
) -> Result(Sut, statem.Violation) {
  let #(expected, after) = step(model, command)
  use sut <- result.try(case command {
    Reopen -> reopen(sut)
    Register(..)
    | Delete(..)
    | BeginMove(..)
    | FinishMove(..)
    | AbortMove(..)
    | Import(..)
    | Mark(..)
    | Unmark(..)
    | Claim(..)
    | SetState(..) -> Ok(sut)
  })
  use Nil <- result.try(agree(
    family(command),
    string.inspect(command),
    expected,
    perform(sut.store, command),
  ))
  use Nil <- result.try(audit(sut, after))
  Ok(sut)
}

// --- generation -------------------------------------------------------------

fn slot() -> qcheck.Generator(Int) {
  qcheck.bounded_int(from: 0, to: 2)
}

fn op() -> qcheck.Generator(Int) {
  qcheck.bounded_int(from: 0, to: 2)
}

fn peer() -> qcheck.Generator(Int) {
  qcheck.bounded_int(from: 0, to: 1)
}

fn word() -> qcheck.Generator(Word) {
  qcheck.bounded_int(from: 0, to: 2)
  |> qcheck.map(fn(n) {
    case n {
      0 -> Opened
      1 -> Releasing
      _ -> Released
    }
  })
}

// The ops in the pool are `move-0` to `move-2`; the index is the last digit.
fn op_index(name: String) -> Int {
  string.last(name)
  |> result.try(int.parse)
  |> result.unwrap(0)
}

// A generator that picks one of these, or nothing when there are none.
fn from_pool(
  weight: Int,
  pool: List(a),
  make: fn(a) -> Command,
) -> List(#(Int, qcheck.Generator(Command))) {
  case pool {
    [] -> []
    [first, ..rest] -> [
      #(
        weight,
        qcheck.from_generators(
          qcheck.return(make(first)),
          list.map(rest, fn(item) { qcheck.return(make(item)) }),
        ),
      ),
    ]
  }
}

// Random indices alone rarely line up: a finish needs the op the session is
// moving under, a delete of a tombstone needs a session that got that far.
// So the generator reads the model and aims some draws at the states the
// refusals are about. It reads only the model, never the catalogue.
fn aimed(model: Model) -> List(#(Int, qcheck.Generator(Command))) {
  let rows = dict.to_list(model.rows)
  let moving =
    list.filter_map(rows, fn(entry) {
      case { entry.1 }.custody {
        catalogue.Moving(op:, ..) -> Ok(#(entry.0, op_index(op)))
        catalogue.Resident | catalogue.Moved(..) | catalogue.Imported(..) ->
          Error(Nil)
      }
    })
  let moved =
    list.filter_map(rows, fn(entry) {
      case { entry.1 }.custody {
        catalogue.Moved(op:, ..) -> Ok(#(entry.0, op_index(op)))
        catalogue.Resident | catalogue.Moving(..) | catalogue.Imported(..) ->
          Error(Nil)
      }
    })
  let imported =
    list.filter_map(rows, fn(entry) {
      case { entry.1 }.custody {
        catalogue.Imported(..) -> Ok(entry.0)
        catalogue.Resident | catalogue.Moving(..) | catalogue.Moved(..) ->
          Error(Nil)
      }
    })
  let delegated =
    list.filter_map(rows, fn(entry) {
      case { entry.1 }.binding {
        Some(_) -> Ok(entry.0)
        None -> Error(Nil)
      }
    })
  list.flatten([
    from_pool(5, moving, fn(pair) { FinishMove(pair.0, pair.1) }),
    from_pool(2, moving, fn(pair) { AbortMove(pair.0, pair.1) }),
    from_pool(1, moving, fn(pair) { Delete(pair.0) }),
    from_pool(3, moved, fn(pair) { Delete(pair.0) }),
    from_pool(1, moved, fn(pair) { AbortMove(pair.0, pair.1) }),
    from_pool(2, moved, fn(pair) { Import(pair.0, pair.1, 0) }),
    from_pool(3, imported, fn(slot) { BeginMove(slot, 0, 1) }),
    from_pool(1, imported, Delete),
    from_pool(3, delegated, fn(slot) { SetState(slot, Opened) }),
  ])
}

// Weights favour the custody transitions, whose compare-and-set rules are the
// densest, and register first so that something exists to move. A command
// names only indices, so any sub-sequence stays a sequence.
fn command(model: Model) -> qcheck.Generator(Command) {
  let registering = case dict.size(model.rows) {
    3 -> 1
    _ -> 10
  }
  qcheck.from_weighted_generators(
    #(registering, qcheck.map(slot(), Register)),
    list.append(aimed(model), [
      #(2, qcheck.map(slot(), Delete)),
      #(5, qcheck.map3(slot(), op(), peer(), BeginMove)),
      #(3, qcheck.map2(slot(), op(), FinishMove)),
      #(2, qcheck.map2(slot(), op(), AbortMove)),
      #(3, qcheck.map3(slot(), op(), peer(), Import)),
      #(2, qcheck.map(slot(), Mark)),
      #(1, qcheck.map(slot(), Unmark)),
      #(
        6,
        qcheck.map5(
          slot(),
          qcheck.bounded_int(from: 0, to: 1),
          qcheck.bounded_int(from: 0, to: 2),
          qcheck.bounded_int(from: 1, to: 2),
          qcheck.bounded_int(from: 0, to: 9),
          Claim,
        ),
      ),
      #(4, qcheck.map2(slot(), word(), SetState)),
      #(1, qcheck.return(Reopen)),
    ]),
  )
}

// A claim binds a session to one pair for good, so a session that already
// serves another pair has no meaningful claim for this one: the catalogue's
// unique key on the session would answer a database error the machine does
// not specify. The precondition keeps such a draw out; a shrink candidate that
// reaches it has deleted the command it depended on. A claim for a session
// with no registration is drawn, because the machine specifies it: `Missing`.
fn admit(model: Model, command: Command) -> statem.Admission {
  case command {
    Claim(slot:, spawner:, parent:, ..) ->
      case dict.get(model.rows, slot % 3) {
        Ok(Row(binding: Some(held), ..)) ->
          case held.spawner == spawner % 2 && held.parent == parent % 3 {
            True -> statem.Admit
            False -> statem.Reject
          }
        Ok(Row(binding: None, ..)) -> statem.Admit

        // The registration must exist, and the catalogue answers `Missing`
        // when it does not, so the model checks that refusal.
        Error(Nil) -> statem.Admit
      }
    Register(..)
    | Delete(..)
    | BeginMove(..)
    | FinishMove(..)
    | AbortMove(..)
    | Import(..)
    | Mark(..)
    | Unmark(..)
    | SetState(..)
    | Reopen -> statem.Admit
  }
}

// The directory is named for this module, outside the `catalogue-<name>`
// directories `catalogue_test` makes. Under LOOM_TEST_PARALLEL the two modules
// run at once, and the name `catalogue-model` was also the directory of
// `catalogue_test`'s model-key test: each deleted and recreated the other's
// catalogue mid-run, so a reopen found a file the model never wrote.
fn new_sut() -> Sut {
  let path = fixtures.scratch("catalogue_model_test") <> "/catalogue.db"
  let store = open_store(path)
  let assert Ok(base) = revision_of(store) as "the empty catalogue has a page"
  Sut(store:, path:, base:)
}

fn catalogue_spec() -> statem.Spec(Model, Command, Sut) {
  statem.Spec(
    initial: Model(rows: dict.new(), revision: 0),
    command:,
    precondition: admit,
    next_model: fn(model, command) { step(model, command).1 },
    // Each execution opens a catalogue file of its own in a scratch directory
    // that `fixtures.scratch` empties first.
    new_sut:,
    execute:,
    // A last close and reopen proves the final state is what the disk holds.
    finish: fn(sut, model) {
      use reopened <- result.try(reopen(sut))
      let verdict = audit(reopened, model)
      let _closed = catalogue.close(reopened.store)
      verdict
    },
    teardown: fn(sut) {
      let _closed = catalogue.close(sut.store)
      Nil
    },
  )
}

fn catalogue_config() -> statem.Config {
  statem.default_config(seed: sequence_seed)
  |> statem.with_test_count(sequence_count)
  |> statem.with_max_commands(sequence_length)
}

pub fn the_catalogue_follows_its_custody_mark_and_delegate_machine_test() {
  case statem.check(catalogue_spec(), catalogue_config()) {
    Ok(Nil) -> Nil
    Error(failure) ->
      panic as statem.report(failure, fn(command) { string.inspect(command) })
  }
}

/// One drawn command with the model it ran in and the answer the machine gave.
type Seen {
  Seen(before: Model, command: Command, answer: Answer)
}

fn custody_of(model: Model, slot: Int) -> Option(catalogue.Custody) {
  case dict.get(model.rows, slot % 3) {
    Ok(row) -> Some(row.custody)
    Error(Nil) -> None
  }
}

fn drawn_commands() -> List(Seen) {
  int.range(0, sequence_count, [], fn(runs, run) { [run, ..runs] })
  |> list.flat_map(fn(run) {
    let spec = catalogue_spec()
    statem.commands(spec, catalogue_config(), run)
    |> list.fold(#(spec.initial, []), fn(state, command) {
      let #(model, seen) = state
      let #(answer, next) = step(model, command)
      #(next, [Seen(before: model, command:, answer:), ..seen])
    })
    |> fn(done) { done.1 }
  })
}

// A property that cannot reach a case proves nothing about it, so the
// generator is asked whether the runs it checks draw each transition and
// refusal the machine specifies: a delete refused on a moving session and on
// a tombstone, a stale op, an import over a tombstone, an onward move, a
// repeat that writes nothing, a late abort, a backward delegate state and a
// claim at its limit and a claim for a session never registered.
pub fn the_generator_reaches_the_refusals_test() {
  let drawn = drawn_commands()
  assert list.any(drawn, fn(seen) {
    case seen.command, custody_of(seen.before, slot_of(seen.command)) {
      Delete(..), Some(catalogue.Moving(..)) ->
        seen.answer == Deleted(Error(catalogue.Conflict))
      _, _ -> False
    }
  })
  assert list.any(drawn, fn(seen) {
    case seen.command, custody_of(seen.before, slot_of(seen.command)) {
      Delete(..), Some(catalogue.Moved(..)) ->
        seen.answer == Deleted(Error(catalogue.Conflict))
      _, _ -> False
    }
  })
  assert list.any(drawn, fn(seen) {
    case seen.command, seen.answer {
      FinishMove(..), Custody(Error(catalogue.Conflict)) -> True
      _, _ -> False
    }
  })
  assert list.any(drawn, fn(seen) {
    case seen.command, custody_of(seen.before, slot_of(seen.command)) {
      Import(..), Some(catalogue.Moved(..)) ->
        case seen.answer {
          Custody(Ok(catalogue.Imported(..))) -> True
          _ -> False
        }
      _, _ -> False
    }
  })
  assert list.any(drawn, fn(seen) {
    case seen.command, custody_of(seen.before, slot_of(seen.command)) {
      BeginMove(..), Some(catalogue.Imported(..)) ->
        case seen.answer {
          Custody(Ok(catalogue.Moving(..))) -> True
          _ -> False
        }
      _, _ -> False
    }
  })
  assert list.any(drawn, fn(seen) {
    case seen.command, custody_of(seen.before, slot_of(seen.command)) {
      AbortMove(..), Some(catalogue.Moved(..)) ->
        seen.answer == Custody(Error(catalogue.Conflict))
      _, _ -> False
    }
  })
  assert list.any(drawn, fn(seen) {
    case seen.command, seen.answer {
      SetState(..), Written(Error(catalogue.Conflict)) -> True
      _, _ -> False
    }
  })
  assert list.any(drawn, fn(seen) {
    case seen.command, seen.answer {
      Claim(..), Claimed(Ok(catalogue.AtLimit(..))) -> True
      _, _ -> False
    }
  })
  assert list.any(drawn, fn(seen) {
    case seen.command, seen.answer {
      Claim(..), Claimed(Error(catalogue.Missing)) -> True
      _, _ -> False
    }
  })
}

// The slot a command acts on, for the census; a command with none reads as
// slot zero, which no census arm above asks about.
fn slot_of(command: Command) -> Int {
  case command {
    Register(slot:)
    | Delete(slot:)
    | BeginMove(slot:, ..)
    | FinishMove(slot:, ..)
    | AbortMove(slot:, ..)
    | Import(slot:, ..)
    | Mark(slot:)
    | Unmark(slot:)
    | Claim(slot:, ..)
    | SetState(slot:, ..) -> slot
    Reopen -> 0
  }
}
