//// The catalogue's compare-and-set paths, raced by several callers that each
//// hold a connection of their own to one SQLite file.
////
//// `catalogue_model_test` drives the machine one command at a time. That says
//// nothing about the property the catalogue's transactions exist for: two
//// callers claiming the same delegate pair, or two sessions claiming the last
//// slot under a spawner's cap, must not both win. This module runs the same
//// machine, the same `step`, under `statem_parallel`: a sequential prefix
//// registers and moves sessions, then two branches of commands run at once,
//// and the checker asks whether some single order of all their calls gives
//// the answers the machine gives.
////
//// ## What races, and why connections
////
//// A `Catalogue` is one SQLite connection, and a connection is not safe to
//// drive from several processes: the binding does not serialize a caller's
//// `BEGIN IMMEDIATE ... COMMIT` against another's, so interleaved callers
//// get "cannot start a transaction within a transaction" and torn result
//// sets. The daemon never does that. It opens one connection and a single
//// process uses it, so inside the daemon every catalogue call is already
//// serialized and there is no race to find. The race the transactions
//// defend against is between connections, for instance a second process on
//// the same file during a restart overlap, and that is what this test
//// builds: the shared handle is the file's path, and every `run` opens its
//// own connection in the calling process, performs one command and closes
//// it. SQLite's file lock and the immediate transaction are then the only
//// things that can make two claims exclusive.
////
//// ## What the model claims
////
//// Every response is checked against `step`'s answer for the model at that
//// response's place in the order the checker finds. The two contested
//// shapes are generated on purpose (`contested_claim`): two sessions
//// claiming one (spawner, parent) pair, where exactly one is `Claimed` and
//// the other `Conflict`, and two sessions claiming under a limit of one,
//// where exactly one is `Claimed` and the other `AtLimit`. A lost or
//// doubled claim has no order the model agrees with.
////
//// ## What `finish` can and cannot say
////
//// `finish` receives the system and not the model, so it cannot compare the
//// final rows with the model's final state; the per-call audit of the
//// sequential test has no home here. It checks what holds of any final file
//// regardless of order, each under its own tag: the per-session reads agree
//// with the listings (`delegate-listing`, `custody-listing`, `mark-listing`),
//// a spawner's `delegates_held` is the number of rows it owns
//// (`delegate-count`), and no pair or session appears twice
//// (`delegate-unique`). A write torn by a race shows up as a view that
//// disagrees with another.
////
//// ## Flow
////
//// `catalogue_spec` → `run_on_own_connection` → `audit_views`
////
//// 1. `catalogue_spec` hands the checker the sequential machine's `step`
////    and the generator `commands`, which mixes its draws with
////    `contested_claim`.
//// 2. `run_on_own_connection` opens, performs and closes, in the branch's
////    own process.
//// 3. `audit_views` is the end-of-case invariant read.
////
//// The seed and counts are fixed constants. A case is a function of the seed
//// alone; the interleaving is not, which is why every case is repeated.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import qcheck
import statem
import statem_parallel.{type Config, type Spec, Case, Spec}
import storage/catalogue
import storage/catalogue_model_test.{
  type Answer, type Command, type Model, Claim, Model, Register, Reopen,
}
import support/fixtures

/// The number of cases generated. Every execution opens a database file and
/// every call a connection, and a failure is shrunk by re-executing, so the
/// count is kept to the order of a few dozen.
const case_count = 30

/// How many times a generated case runs before it counts as passing. The
/// seed fixes the case and never the interleaving, so a race that shows in
/// one execution in two is found with probability one in a hundred runs.
const repeat_count = 2

/// The seed every case derives from.
const case_seed = 4177

/// The number of racing branches. Two is the pair the catalogue's contested
/// shapes need, and it keeps the interleavings the checker enumerates small.
const branch_count = 2

/// The shared handle: the path of the catalogue file every caller opens its
/// own connection to.
type Handle {
  Handle(path: String)
}

/// The registered sessions with no delegate row: the ones a claim can still
/// win, which is what a race between claims needs at least two of.
fn unbound_slots(model: Model) -> List(Int) {
  catalogue_model_test.slots()
  |> list.filter(fn(slot) {
    case dict.get(model.rows, slot) {
      Ok(catalogue_model_test.Row(binding: None, ..)) -> True
      Ok(catalogue_model_test.Row(binding: Some(_), ..)) | Error(Nil) -> False
    }
  })
}

/// A claim aimed at the two contested shapes, for a session that can still
/// win. The spawner and parent come from pools of two, so two claims often
/// name the same pair; the limit is one or two, so a second session often
/// meets a full spawner. Simplest draws shrink to the first unbound session,
/// spawner zero, parent zero and limit one. It is offered only while two
/// sessions are unbound, since a lone claimant races nobody.
fn contested_claim(model: Model) -> List(#(Int, qcheck.Generator(Command))) {
  case unbound_slots(model) {
    [first, second, ..] as unbound -> [
      #(
        3,
        qcheck.map5(
          qcheck.from_generators(
            qcheck.return(first),
            list.map([second, ..list.drop(unbound, 2)], qcheck.return),
          ),
          qcheck.bounded_int(from: 0, to: 1),
          qcheck.bounded_int(from: 0, to: 1),
          qcheck.bounded_int(from: 1, to: 2),
          qcheck.bounded_int(from: 0, to: 9),
          Claim,
        ),
      ),
    ]
    [_] | [] -> []
  }
}

/// Mostly registrations while fewer than two sessions are unbound, then the
/// sequential machine's own draws, so custody moves, deletes and the rest
/// still shape the state, with `contested_claim` as often again as one of the
/// sequential claims. A claim race needs two registered sessions that are
/// still unbound, and a plain draw rarely gets there before the branches
/// start, so registering is favoured until they exist.
fn commands(model: Model) -> qcheck.Generator(Command) {
  let unregistered =
    list.filter(catalogue_model_test.slots(), fn(slot) {
      !dict.has_key(model.rows, slot)
    })
  let registering = case unbound_slots(model), unregistered {
    [_, _, ..], _ | _, [] -> []
    [_], [first, ..rest] | [], [first, ..rest] -> [
      #(
        6,
        qcheck.map(
          qcheck.from_generators(
            qcheck.return(first),
            list.map(rest, qcheck.return),
          ),
          Register,
        ),
      ),
    ]
  }
  qcheck.from_weighted_generators(
    #(1, catalogue_model_test.command(model)),
    list.append(registering, contested_claim(model)),
  )
}

/// `Reopen` closes and reopens one catalogue, which has no meaning when each
/// caller owns its connection, so it is never admitted. Every other command
/// keeps the sequential machine's admission.
fn admit(model: Model, command: Command) -> statem.Admission {
  case command {
    Reopen -> statem.Reject
    Register(..)
    | catalogue_model_test.Delete(..)
    | catalogue_model_test.BeginMove(..)
    | catalogue_model_test.FinishMove(..)
    | catalogue_model_test.AbortMove(..)
    | catalogue_model_test.Import(..)
    | catalogue_model_test.Mark(..)
    | catalogue_model_test.Unmark(..)
    | Claim(..)
    | catalogue_model_test.SetState(..) ->
      catalogue_model_test.admit(model, command)
  }
}

fn new_sut() -> Handle {
  let path = fixtures.scratch("catalogue-parallel") <> "/catalogue.db"

  // Opening initializes the schema once, so the racing callers only ever
  // open a file that is already current.
  let assert Ok(store) = catalogue.open(path) as "the catalogue initializes"
  let assert Ok(Nil) = catalogue.close(store) as "the catalogue closes"
  Handle(path:)
}

/// One caller's whole use of the catalogue: its own connection, one command,
/// then the close. The connection never leaves the calling process.
fn run_on_own_connection(handle: Handle, command: Command) -> Answer {
  let store = catalogue_model_test.open_store(handle.path)
  let answer = catalogue_model_test.perform(store, command)
  let assert Ok(Nil) = catalogue.close(store) as "the connection closes"
  answer
}

/// Whether a response is the one the model gives, at this place in the order.
fn postcondition(
  model: Model,
  command: Command,
  answer: Answer,
) -> Result(Nil, statem.Violation) {
  catalogue_model_test.agree(
    catalogue_model_test.family(command),
    string.inspect(command),
    catalogue_model_test.step(model, command).0,
    answer,
  )
}

/// Every view of the final file agrees with every other.
fn audit_views(handle: Handle) -> Result(Nil, statem.Violation) {
  let store = catalogue_model_test.open_store(handle.path)
  let verdict = check_views(store)
  let _closed = catalogue.close(store)
  verdict
}

fn check_views(store: catalogue.Catalogue) -> Result(Nil, statem.Violation) {
  let slots = catalogue_model_test.slots()
  let sessions = list.map(slots, catalogue_model_test.session)

  use delegates <- result.try(read(
    "delegate-listing",
    catalogue.delegates(store),
  ))
  use Nil <- result.try(
    list.try_each(slots, fn(slot) {
      let id = catalogue_model_test.session(slot)
      use own <- result.try(read(
        "delegate-listing",
        catalogue.delegate_of(store, id),
      ))
      catalogue_model_test.agree(
        "delegate-listing",
        "delegate row of session " <> int.to_string(slot),
        list.find(delegates, fn(row) { row.session_id == id })
          |> option.from_result,
        own,
      )
    }),
  )

  use Nil <- result.try(check_unique(delegates))
  use Nil <- result.try(check_counts(store, delegates))

  use custodies <- result.try(read(
    "custody-listing",
    catalogue.custodies(store),
  ))
  use Nil <- result.try(
    list.try_each(sessions, fn(id) {
      let own = catalogue.custody(store, id)
      case own, list.key_find(custodies, id) {
        Ok(catalogue.Resident), Error(Nil)
        | Error(catalogue.Missing), Error(Nil)
        -> Ok(Nil)
        Ok(custody), Ok(listed) ->
          catalogue_model_test.agree(
            "custody-listing",
            "custody of " <> id,
            custody,
            listed,
          )
        Ok(_), Error(Nil) | Error(_), Ok(_) | Error(_), Error(Nil) ->
          Error(statem.Violation(
            tag: "custody-listing",
            detail: "custody of "
              <> id
              <> " reads "
              <> string.inspect(own)
              <> " but the listing holds "
              <> string.inspect(list.key_find(custodies, id)),
          ))
      }
    }),
  )

  use deleting <- result.try(read("mark-listing", catalogue.deleting(store)))
  list.try_each(sessions, fn(id) {
    use own <- result.try(read("mark-listing", catalogue.deletion(store, id)))
    catalogue_model_test.agree(
      "mark-listing",
      "deletion mark of " <> id,
      case list.contains(deleting, id) {
        True -> catalogue.Deleting
        False -> catalogue.NotDeleting
      },
      own,
    )
  })
}

fn read(
  tag: String,
  outcome: Result(a, catalogue.Error),
) -> Result(a, statem.Violation) {
  result.map_error(outcome, fn(error) {
    statem.Violation(tag:, detail: "read failed: " <> string.inspect(error))
  })
}

/// No (spawner, parent) pair and no session is recorded twice.
fn check_unique(
  delegates: List(catalogue.Delegate),
) -> Result(Nil, statem.Violation) {
  let pairs =
    list.map(delegates, fn(row) { #(row.spawner, row.parent_session) })
  let owners = list.map(delegates, fn(row) { row.session_id })
  case
    list.length(list.unique(pairs)) == list.length(pairs)
    && list.length(list.unique(owners)) == list.length(owners)
  {
    True -> Ok(Nil)
    False ->
      Error(statem.Violation(
        tag: "delegate-unique",
        detail: "a pair or a session is recorded twice: "
          <> string.inspect(delegates),
      ))
  }
}

/// A spawner's held count is the number of rows it owns.
fn check_counts(
  store: catalogue.Catalogue,
  delegates: List(catalogue.Delegate),
) -> Result(Nil, statem.Violation) {
  list.try_each([0, 1], fn(spawner) {
    let name = catalogue_model_test.spawner_name(spawner)
    use held <- result.try(read(
      "delegate-count",
      catalogue.delegates_held(store, name),
    ))
    catalogue_model_test.agree(
      "delegate-count",
      "delegates held by " <> name,
      list.count(delegates, fn(row) { row.spawner == name }),
      held,
    )
  })
}

fn catalogue_spec() -> Spec(Model, Command, Handle, Answer) {
  Spec(
    initial: Model(rows: dict.new(), revision: 0),
    command: commands,
    precondition: admit,
    next_model: fn(model, command) {
      catalogue_model_test.step(model, command).1
    },
    new_sut:,
    run: run_on_own_connection,
    postcondition:,
    finish: audit_views,
    teardown: fn(_) { Nil },
  )
}

fn catalogue_config() -> Config {
  statem_parallel.default_config(seed: case_seed)
  |> statem_parallel.with_test_count(case_count)
  |> statem_parallel.with_repeat(repeat_count)
  |> statem_parallel.with_branches(branch_count)
}

pub fn racing_callers_see_one_winner_per_compare_and_set_test() {
  case statem_parallel.check(catalogue_spec(), catalogue_config()) {
    Ok(Nil) -> Nil
    Error(failure) ->
      panic as statem_parallel.report(failure, fn(command) {
          string.inspect(command)
        })
  }
}

/// The delegate row a command would create, as the pair it names and the
/// session it binds, when the session is registered and unbound in `model`.
fn claim_of(
  model: Model,
  command: Command,
) -> option.Option(#(Int, Int, Int, Int)) {
  case command {
    Claim(slot:, spawner:, parent:, limit:, ..) ->
      case dict.get(model.rows, slot % 3) {
        Ok(catalogue_model_test.Row(binding: None, ..)) ->
          Some(#(slot % 3, spawner % 2, parent % 3, limit))
        Ok(catalogue_model_test.Row(binding: Some(_), ..)) | Error(Nil) -> None
      }
    _ -> None
  }
}

/// The model after a case's prefix, which is where its branches start.
fn after_prefix(commands: List(Command)) -> Model {
  list.fold(commands, Model(rows: dict.new(), revision: 0), fn(model, command) {
    catalogue_model_test.step(model, command).1
  })
}

/// The claims in a branch that name a registered session with no delegate
/// row in `model`, as (slot, spawner, parent, limit): the ones that can win.
fn claims_that_can_win(
  model: Model,
  branch: List(Command),
) -> List(#(Int, Int, Int, Int)) {
  list.filter_map(branch, fn(command) {
    claim_of(model, command) |> option.to_result(Nil)
  })
}

/// Whether some case puts two claims of different registered sessions in
/// different branches, with `shape` deciding what they must share.
fn some_case_races(
  shape: fn(#(Int, Int, Int, Int), #(Int, Int, Int, Int)) -> Bool,
) -> Bool {
  int.range(0, case_count, [], fn(runs, run) { [run, ..runs] })
  |> list.any(fn(run) {
    let Case(prefix:, branches:) =
      statem_parallel.generate_case(catalogue_spec(), catalogue_config(), run)
    let start = after_prefix(prefix)
    case branches {
      [first, second, ..] ->
        list.any(claims_that_can_win(start, first), fn(left) {
          list.any(claims_that_can_win(start, second), fn(right) {
            left.0 != right.0 && shape(left, right)
          })
        })
      [_] | [] -> False
    }
  })
}

/// A test that never races the shapes it exists for proves nothing about
/// them, so generation is asked for both: two claims of one pair from
/// different sessions in different branches, and two claims under one
/// spawner's limit of one.
pub fn the_generator_races_both_contested_claims_test() {
  assert some_case_races(fn(left, right) {
    left.1 == right.1 && left.2 == right.2
  })
  assert some_case_races(fn(left, right) {
    left.1 == right.1 && left.2 != right.2 && left.3 == 1 && right.3 == 1
  })
}
