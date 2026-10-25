//// The prompt search: a loop over the runner, the reflector and the pure
//// search state that proposes, screens and accepts candidate arms, and
//// writes a front the operator takes to the governed plane by hand.
////
//// Nothing here promotes anything. The search never calls `propose`,
//// `approve` or `select`; its last act is to write `PROPOSE.md`, which
//// prints the program an operator runs to put the top candidate through
//// `evolution.propose` and the governed `compare`. That is ADR-021's line
//// and the reason the instrument may search at all.
////
//// One step, given a pool whose every member has a complete Validate
//// ledger:
////
//// 1. a parent is drawn by `select.front` and `select.draw_parent` from a
////    generator seeded by the search id and the step number;
//// 2. the step's slot is `select.slot_for`, round robin over the mutable
////    set, and its minibatch is `select.minibatch` from the same generator;
//// 3. the parent runs the minibatch alone, as a sub-plan through
////    `run.execute`, to capture how it fares;
//// 4. the reflector reads those rows (`reflect.records`) and answers the
////    slot's new text; the child is `arm.mint` of the parent with that slot
////    replaced, and an arm the settings refuse is recorded `refused`;
//// 5. the child runs the same minibatch alone and `select.screen` decides
////    whether to pay for Validate;
//// 6. the child runs the whole Validate split alone, and
////    `evalstat.paired_verdict` pairs its rows against the parent's earlier
////    Validate rows and against the incumbent's; `verdict.dispose` in the
////    `gepa` library turns the verdicts into the step's disposition.
////
//// Pairing a child's run against a parent's earlier one is sequential, not
//// simultaneous. Every sub-plan stamps the same harness commit and pins the
//// same exact model identities, and the search ends by running the seed
//// and the best in one sub-plan, the only simultaneous comparison, whose
//// verdict is the headline; a confirm run that is not `Improved` demotes
//// the result to "not confirmed" in the first line.
////
//// Everything the search decides is in `search.jsonl` under the search
//// directory, appended one row at a time by one writer; resume is the same
//// command. The sub-runs are ordinary run directories under `runs/`, so
//// the runner's own resume applies to them unchanged. A dollar is counted
//// once, in the sub-run that spent it, and the search's spend is the sum of
//// those ledgers plus the priced reflections; each sub-plan is written with
//// `max_dollars` equal to what remained when it was created, and a resumed
//// sub-run gets the smaller of that cap less its own ledger and what the
//// search has left, so a sub-run cannot spend past the search on any
//// resume. The reflector is a live call on every lane, so its calls are
//// metered on every lane: the confirm run and one reflection are reserved
//// before a step is taken, and a reflection is made only when its worst
//// case is still covered. The arithmetic of those holds is `gepa/budget`'s,
//// and every decision the loop makes — the draws, the screen, the
//// disposition, the stop — is asked of the library's pure pieces; what
//// stays here is the ordering of effects, because each sub-run is a
//// resumable directory with its own ledger and cap, which the library's
//// own loop (`gepa.next`) has no way to see.
////
//// ## Flow
////
//// - `check`, `mint`, `to_json`, `decode`, `load`: the search plan
//// - `search`: the loop, from a plan to a front
//// - `step`: one step, fresh or resumed at the stage its rows reached
//// - `confirm`: the final `[seed, best]` sub-plan
//// - `write_front`, `report`: the front files and the proposal program

import client/mcp
import core/accounting
import core/json.{type JsonValue}
import eval/arm.{type Arm, type Component}
import eval/arm_settings
import eval/ledger
import eval/plan
import eval/reflect
import eval/report
import eval/run
import eval/search.{type Event, type State}
import eval/split
import eval/task.{type Task}
import eval/trial
import eval/wire
import evalstat
import evalstat/dominance
import evalstat/pairing
import evalstat/trial as stat
import evalstat/verdict.{type Verdict}
import gepa
import gepa/budget
import gepa/prng
import gepa/prompt
import gepa/select
import gepa/verdict as rule
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/pricing.{type Pricing}
import simplifile
import weft/actor

/// The search's ceilings.
pub type Budgets {
  Budgets(
    /// Dollars the whole search may spend, sub-runs and reflections together.
    max_dollars: Float,
    /// Steps the search may take.
    max_steps: Int,
    /// Reflections the search may make.
    max_reflections: Int,
    /// Children the search may mint.
    max_candidates: Int,
  )
}

/// One frozen search.
pub type Plan {
  Plan(
    /// SHA-256 hex of the canonical encoding with this field blank.
    id: String,
    /// The seed arm: the operator's, or the empty base arm.
    seed: Arm,
    /// What the search optimises for, in the operator's words.
    objective: String,
    /// The tune tasks, which supply minibatches and reflection records.
    tune: List(Task),
    /// The validate tasks, which supply acceptance and the front.
    validate: List(Task),
    /// Trials per cell on Validate, the K of the design.
    trials_per_cell: Int,
    /// Trials per cell on a minibatch.
    tune_trials: Int,
    /// Tasks per minibatch.
    minibatch: Int,
    /// The slots a reflection may rewrite, in round-robin order.
    slots: List(Component),
    /// The reflector, pinned.
    reflector: reflect.Identity,
    /// The search's ceilings.
    budgets: Budgets,
    /// The per-trial ceilings every sub-plan carries; its `max_dollars` is
    /// replaced by what remains at creation.
    trial: plan.Budgets,
    /// Replay or live.
    lane: plan.Lane,
    /// Quick or full, stamped on every sub-plan.
    profile: plan.Profile,
    /// The split salt the task sets were assigned with.
    split_salt: String,
    /// What ran the search.
    harness: plan.Harness,
  )
}

/// The effects the loop performs, as values, so a test can script the
/// runner and the reflector.
pub type Seams {
  Seams(
    /// Runs or resumes a sub-plan: `run.execute` in production.
    execute: fn(trial.Context, run.Loaded, String) ->
      Result(run.Summary, String),
    /// The reflection call.
    reflect: reflect.Reflector,
  )
}

/// Everything the loop needs that does not vary by step.
pub type Context {
  Context(
    /// The trial context sub-runs start from; its budgets and plan id are
    /// replaced per sub-plan.
    trial: trial.Context,
    /// The effects.
    seams: Seams,
    /// What one reflection could cost at worst; zero on a replay lane.
    reflection_worst: Float,
    /// The reflector's rate card, when its provider has one.
    reflector_card: Option(Pricing),
  )
}

/// What a search did.
pub type Outcome {
  Outcome(
    /// The search directory.
    directory: String,
    /// The state the log folds to at the end.
    state: State,
  )
}

/// What the log writer is told.
type WriterMessage {
  /// Append one line and answer when it is on disk.
  Append(line: String, reply: Subject(Result(Nil, String)))

  /// Stop the writer.
  Close
}

/// The process that owns `search.jsonl`, and the lookups the fold reads
/// the directory through.
type Writer {
  Writer(subject: Subject(WriterMessage), store: search.Store)
}

/// The encoding version of `search.json`.
pub const version = 1

/// How many of the top candidates get a `propose/` directory.
pub const propose_top = 3

/// Checks a search plan's invariants: nonempty task splits with no task on
/// both sides, positive bounded counts, at least one slot, and a per-trial
/// budget `plan.check` would accept. A minibatch wider than the tune split
/// is clamped at draw time, not refused.
///
/// ## Examples
///
/// ```gleam
/// // optimize.check(plan_with_no_slots) == Error("the mutable set is empty")
/// ```
///
pub fn check(frozen: Plan) -> Result(Plan, String) {
  let tune_ids = list.map(frozen.tune, fn(each) { each.id })
  let validate_ids = list.map(frozen.validate, fn(each) { each.id })

  use Nil <- result.try(require(
    tune_ids != [] && wire.is_distinct(tune_ids),
    "the tune split must be nonempty and unique",
  ))
  use Nil <- result.try(require(
    validate_ids != [] && wire.is_distinct(validate_ids),
    "the validate split must be nonempty and unique",
  ))
  use Nil <- result.try(require(
    !list.any(tune_ids, list.contains(validate_ids, _)),
    "a task cannot be in both tune and validate",
  ))
  use Nil <- result.try(require(
    !list.any(list.append(frozen.tune, frozen.validate), fn(each) {
      split.assign(frozen.split_salt, split.family(each)) == split.Holdout
    }),
    "a task the salt assigns to the holdout split cannot be searched over",
  ))
  use Nil <- result.try(require(
    list.all(frozen.tune, fn(each) {
      split.assign(frozen.split_salt, split.family(each)) == split.Tune
    })
      && list.all(frozen.validate, fn(each) {
      split.assign(frozen.split_salt, split.family(each)) == split.Validate
    }),
    "a task is listed under a split the salt does not assign it to",
  ))
  use Nil <- result.try(require(
    frozen.trials_per_cell >= 1
      && frozen.trials_per_cell <= 1000
      && frozen.tune_trials >= 1
      && frozen.tune_trials <= 1000
      && frozen.minibatch >= 1,
    "trials per cell and the minibatch must be positive, trials at most 1000",
  ))
  use Nil <- result.try(require(frozen.slots != [], "the mutable set is empty"))
  use Nil <- result.try(require(
    frozen.budgets.max_dollars >=. 0.0
      && frozen.budgets.max_steps >= 0
      && frozen.budgets.max_reflections >= 0
      && frozen.budgets.max_candidates >= 0,
    "search budgets must be non-negative",
  ))
  use Nil <- result.try(require(
    frozen.objective != "",
    "an objective is required",
  ))

  // The per-trial ceilings are checked by building the sub-plan they would
  // produce, so a refusal names the same rule a run would.
  plan.check(sub_plan(frozen, frozen.validate, [frozen.seed], 1, 0.0))
  |> result.replace(frozen)
}

/// Returns the plan with `id` set to the digest of its canonical encoding
/// taken with the id blank.
///
/// ## Examples
///
/// ```gleam
/// // optimize.mint(optimize.mint(p)) == optimize.mint(p)
/// ```
///
pub fn mint(frozen: Plan) -> Plan {
  Plan(..frozen, id: digest(frozen))
}

/// The canonical encoding of a search plan. Tasks are named by id; the seed
/// and the mutable set are arms (the set as an arm whose components carry
/// empty text), so the arm codec is the only slot codec.
///
/// ## Examples
///
/// ```gleam
/// // json.to_string(optimize.to_json(p)) starts with {"budgets":…
/// ```
///
pub fn to_json(frozen: Plan) -> JsonValue {
  json.canonical(
    json.Object([
      #("v", json.Int(version)),
      #("id", json.String(frozen.id)),
      #("seed", arm.to_json(frozen.seed)),
      #("objective", json.String(frozen.objective)),
      #("tune", ids_json(frozen.tune)),
      #("validate", ids_json(frozen.validate)),
      #("trials_per_cell", json.Int(frozen.trials_per_cell)),
      #("tune_trials", json.Int(frozen.tune_trials)),
      #("minibatch", json.Int(frozen.minibatch)),
      #("slots", arm.to_json(slots_arm(frozen.slots))),
      #(
        "reflector",
        json.Object([
          #("entry", json.String(frozen.reflector.entry)),
          #("provider", json.String(frozen.reflector.provider)),
          #("model_id", json.String(frozen.reflector.model_id)),
          #("api", json.String(frozen.reflector.api)),
        ]),
      ),
      #(
        "budgets",
        json.Object([
          #("max_dollars", json.Float(frozen.budgets.max_dollars)),
          #("max_steps", json.Int(frozen.budgets.max_steps)),
          #("max_reflections", json.Int(frozen.budgets.max_reflections)),
          #("max_candidates", json.Int(frozen.budgets.max_candidates)),
        ]),
      ),
      #(
        "trial",
        plan.to_json(sub_plan(frozen, frozen.validate, [frozen.seed], 1, 0.0)),
      ),
      #("split_salt", json.String(frozen.split_salt)),
    ]),
  )
}

/// Decodes a search plan given the tasks it may name. Total.
///
/// ## Examples
///
/// ```gleam
/// // optimize.decode(optimize.to_json(p), tasks) == Ok(p)
/// ```
///
pub fn decode(value: JsonValue, tasks: List(Task)) -> Result(Plan, String) {
  use fields <- result.try(wire.object(value, plan_keys))
  use v <- result.try(wire.int(fields, "v"))
  use Nil <- result.try(require(v == version, "unsupported search plan version"))
  use id <- result.try(wire.text(fields, "id"))
  use seed <- result.try(
    wire.required(fields, "seed") |> result.try(arm.decode),
  )
  use objective <- result.try(wire.text(fields, "objective"))
  use tune <- result.try(
    wire.strings(fields, "tune") |> result.try(find_tasks(_, tasks)),
  )
  use validate <- result.try(
    wire.strings(fields, "validate") |> result.try(find_tasks(_, tasks)),
  )
  use trials_per_cell <- result.try(wire.int(fields, "trials_per_cell"))
  use tune_trials <- result.try(wire.int(fields, "tune_trials"))
  use minibatch <- result.try(wire.int(fields, "minibatch"))
  use slots <- result.try(
    wire.required(fields, "slots") |> result.try(arm.decode),
  )
  use reflector <- result.try(
    wire.required(fields, "reflector") |> result.try(decode_reflector),
  )
  use budgets <- result.try(
    wire.required(fields, "budgets") |> result.try(decode_budgets),
  )
  use sub <- result.try(
    wire.required(fields, "trial") |> result.try(plan.decode),
  )
  use split_salt <- result.try(wire.text(fields, "split_salt"))

  check(Plan(
    id:,
    seed:,
    objective:,
    tune:,
    validate:,
    trials_per_cell:,
    tune_trials:,
    minibatch:,
    slots: list.map(slots.components, fn(component) { component.0 }),
    reflector:,
    budgets:,
    trial: sub.budgets,
    lane: sub.lane,
    profile: sub.profile,
    split_salt:,
    harness: sub.harness,
  ))
}

/// Reads a search directory's plan and the task copies beside it, and
/// verifies the plan's digest.
///
/// ## Examples
///
/// ```gleam
/// // optimize.load("searches/<id>") -> Ok(plan)
/// ```
///
pub fn load(directory: String) -> Result(Plan, String) {
  use names <- result.try(
    simplifile.read_directory(directory <> "/tasks")
    |> result.map_error(fn(error) {
      "cannot list "
      <> directory
      <> "/tasks: "
      <> simplifile.describe_error(error)
    }),
  )
  use tasks <- result.try(
    list.try_map(names, fn(name) { task.load(directory <> "/tasks/" <> name) }),
  )
  use body <- result.try(
    simplifile.read(directory <> "/search.json")
    |> result.map_error(fn(error) {
      "cannot read "
      <> directory
      <> "/search.json: "
      <> simplifile.describe_error(error)
    }),
  )
  use value <- result.try(
    json.parse(body)
    |> result.map_error(fn(_report) { "search.json is not valid JSON" }),
  )
  use frozen <- result.try(decode(value, tasks))

  // A plan edited after minting would not be the search the log belongs to.
  case digest(frozen) == frozen.id {
    True -> Ok(frozen)
    False -> Error("search.json content changed: its id no longer matches")
  }
}

const plan_keys = [
  "v", "id", "seed", "objective", "tune", "validate", "trials_per_cell",
  "tune_trials", "minibatch", "slots", "reflector", "budgets", "trial",
  "split_salt",
]

/// The digest a search id is: the canonical encoding with the id blank.
fn digest(frozen: Plan) -> String {
  Plan(..frozen, id: "")
  |> to_json
  |> json.to_string
  |> mcp.sha256_hex
}

fn ids_json(tasks: List(Task)) -> JsonValue {
  json.Array(list.map(tasks, fn(each) { json.String(each.id) }))
}

/// The mutable set as an arm: a slot per component, text empty. The arm
/// codec sorts and dedupes, which is what a set wants.
fn slots_arm(slots: List(Component)) -> Arm {
  arm.Arm(
    id: "",
    name: "slots",
    components: list.map(slots, fn(slot) { #(slot, "") }),
    knobs: arm.Knobs(roles: [], thinking: [], disabled_tools: []),
  )
}

/// Resolves task ids against the loaded tasks, in the ids' order.
fn find_tasks(
  ids: List(String),
  tasks: List(Task),
) -> Result(List(Task), String) {
  list.try_map(ids, fn(id) {
    list.find(tasks, fn(each) { each.id == id })
    |> result.map_error(fn(_) {
      "the search names task " <> id <> " but it was not loaded"
    })
  })
}

/// Decodes the pinned reflector identity.
fn decode_reflector(value: JsonValue) -> Result(reflect.Identity, String) {
  use fields <- result.try(
    wire.object(value, ["entry", "provider", "model_id", "api"]),
  )
  use entry <- result.try(wire.text(fields, "entry"))
  use provider <- result.try(wire.text(fields, "provider"))
  use model_id <- result.try(wire.text(fields, "model_id"))
  use api <- result.try(wire.text(fields, "api"))

  Ok(reflect.Identity(entry:, provider:, model_id:, api:))
}

/// Decodes the search's ceilings; `check` bounds them afterwards.
fn decode_budgets(value: JsonValue) -> Result(Budgets, String) {
  use fields <- result.try(
    wire.object(value, [
      "max_dollars", "max_steps", "max_reflections", "max_candidates",
    ]),
  )
  use max_dollars <- result.try(wire.number(fields, "max_dollars"))
  use max_steps <- result.try(wire.int(fields, "max_steps"))
  use max_reflections <- result.try(wire.int(fields, "max_reflections"))
  use max_candidates <- result.try(wire.int(fields, "max_candidates"))

  Ok(Budgets(max_dollars:, max_steps:, max_reflections:, max_candidates:))
}

fn require(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

// --- the loop --------------------------------------------------------------------------

/// Runs, or resumes, a search under `out` and writes its front.
///
/// ## Examples
///
/// ```gleam
/// // optimize.search(ctx, plan, "searches") -> Ok(Outcome("searches/<id>", state))
/// ```
///
pub fn search(
  ctx: Context,
  frozen: Plan,
  out: String,
) -> Result(Outcome, String) {
  let directory = out <> "/" <> frozen.id

  use Nil <- result.try(prepare_directory(directory, frozen))
  use events <- result.try(read_log(directory))
  let store = store_for(directory)
  use writer <- result.try(start_writer(directory <> "/search.jsonl", store))

  // A fresh search opens with the seed's candidate row; a resumed one folds
  // what it has.
  let begun = case events {
    [] ->
      append(
        writer,
        search.Candidate(
          arm: frozen.seed.id,
          parent: None,
          step: 0,
          source: search.Seed,
          slot: None,
        ),
      )
      |> result.try(fn(event) { search.replay([event], store) })
    [_, ..] -> search.replay(events, store)
  }

  let ran = {
    use state <- result.try(begun)
    use state <- result.try(ensure_seed_validated(
      ctx,
      frozen,
      directory,
      writer,
      state,
    ))
    loop(ctx, frozen, directory, writer, state)
  }
  process.send(writer.subject, Close)

  use state <- result.try(ran)
  use Nil <- result.try(write_front(directory, frozen, state))

  Ok(Outcome(directory:, state:))
}

/// Creates the search directory and freezes the plan, its tasks and the
/// seed arm into it. A directory that already holds a plan must hold this
/// one, which the id in the path already says.
fn prepare_directory(directory: String, frozen: Plan) -> Result(Nil, String) {
  use Nil <- result.try(make_directory(directory <> "/tasks"))
  use Nil <- result.try(make_directory(directory <> "/arms"))
  use Nil <- result.try(make_directory(directory <> "/runs"))
  use Nil <- result.try(write_file(
    directory <> "/search.json",
    json.to_string(to_json(frozen)),
  ))
  use Nil <- result.try(
    list.try_each(list.append(frozen.tune, frozen.validate), fn(each) {
      write_file(
        directory <> "/tasks/" <> each.id <> ".json",
        json.to_string(task.to_json(each)),
      )
    }),
  )

  write_arm(directory, frozen.seed)
}

fn write_arm(directory: String, candidate: Arm) -> Result(Nil, String) {
  write_file(
    directory <> "/arms/" <> candidate.id <> ".json",
    json.to_string(arm.to_json(candidate)),
  )
}

/// Reads an arm the search wrote under `arms/`.
fn read_arm(directory: String, id: String) -> Result(Arm, String) {
  let path = directory <> "/arms/" <> id <> ".json"

  use body <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      "cannot read " <> path <> ": " <> simplifile.describe_error(error)
    }),
  )
  use value <- result.try(
    json.parse(body)
    |> result.map_error(fn(_report) { path <> ": not valid JSON" }),
  )
  use decoded <- result.try(arm.decode(value))
  use decoded <- result.try(arm.verify_id(decoded))

  // The file's name is the arm's id, so a copied file cannot stand in for another arm.
  case decoded.id == id {
    True -> Ok(decoded)
    False -> Error(path <> ": the file holds arm " <> decoded.id)
  }
}

fn make_directory(path: String) -> Result(Nil, String) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(error) {
    "cannot create " <> path <> ": " <> simplifile.describe_error(error)
  })
}

fn write_file(path: String, text: String) -> Result(Nil, String) {
  simplifile.write(path, text)
  |> result.map_error(fn(error) {
    "cannot write " <> path <> ": " <> simplifile.describe_error(error)
  })
}

/// Reads the search log, treating an absent file as empty.
fn read_log(directory: String) -> Result(List(Event), String) {
  case simplifile.read(directory <> "/search.jsonl") {
    Ok(text) -> search.parse(text)
    Error(simplifile.Enoent) -> Ok([])
    Error(error) -> Error(simplifile.describe_error(error))
  }
}

/// Step 0: the seed's Validate run, which every later comparison pairs
/// against. Seedless means no hand-written seed, never no baseline.
fn ensure_seed_validated(
  ctx: Context,
  frozen: Plan,
  directory: String,
  writer: Writer,
  state: State,
) -> Result(State, String) {
  // The seed's run row is the first run row; its presence says step 0 ran
  // or is running, and executing again resumes it.
  case search.runs(state) {
    [] -> {
      use left <- result.try(remaining(ctx, frozen, directory, state))
      use costs <- result.try(costs(ctx, frozen.seed))
      let remaining =
        budget.cap(
          remaining: left,
          hold: budget.confirm_worst_case(costs, design(frozen, 0)),
        )
      let sub =
        sub_plan(
          frozen,
          frozen.validate,
          [frozen.seed],
          frozen.trials_per_cell,
          remaining,
        )
      use state <- result.try(record(
        writer,
        state,
        search.Run(
          arm: frozen.seed.id,
          split: split.Validate,
          plan: sub.id,
          step: 0,
          role: search.ValidateRun,
          cap: remaining,
        ),
      ))
      use _summary <- result.try(
        execute(ctx, frozen, directory, state, sub, frozen.validate, [
          frozen.seed,
        ]),
      )

      Ok(state)
    }

    [search.Run(plan:, ..), ..] -> {
      use sub <- result.try(
        reloaded(directory, state, plan, fn(cap) {
          sub_plan(
            frozen,
            frozen.validate,
            [frozen.seed],
            frozen.trials_per_cell,
            cap,
          )
        }),
      )
      use _summary <- result.try(
        execute(ctx, frozen, directory, state, sub, frozen.validate, [
          frozen.seed,
        ]),
      )

      Ok(state)
    }

    [_, ..] -> Error("the first run row is not the seed's validate run")
  }
}

/// The steps, until a stop condition holds; then the confirm run and the
/// stop row.
fn loop(
  ctx: Context,
  frozen: Plan,
  directory: String,
  writer: Writer,
  state: State,
) -> Result(State, String) {
  // A stopped search is finished; an open step is resumed before anything
  // else is decided.
  case state.search.stopped, state.search.open {
    Some(_), _ -> Ok(state)

    None, Some(_) -> {
      use state <- result.try(step(ctx, frozen, directory, writer, state))
      use Nil <- result.try(write_front(directory, frozen, state))

      loop(ctx, frozen, directory, writer, state)
    }

    None, None -> {
      use decision <- result.try(stop_reason(ctx, frozen, directory, state))

      // A reason to stop ends the search after the confirm run; none means
      // another step.
      case decision {
        Some(reason) -> {
          // A confirm run the budget cannot cover is skipped, never a failure.
          use confirmed <- result.try(confirm(
            ctx,
            frozen,
            directory,
            writer,
            state,
          ))

          // Either way the state carries on to the stop row.
          let state = case confirmed {
            Ran(state:) | Unaffordable(state:) -> state
          }

          record(writer, state, search.Stop(reason:))
        }

        None -> {
          use state <- result.try(step(ctx, frozen, directory, writer, state))
          use Nil <- result.try(write_front(directory, frozen, state))

          loop(ctx, frozen, directory, writer, state)
        }
      }
    }
  }
}

/// Why the search should stop now, if it should: the counted ceilings
/// first, then whether the next step's worst case and the confirm run fit
/// the dollars left, all of it `budget.stop_reason`'s arithmetic over
/// Loom's numbers.
fn stop_reason(
  ctx: Context,
  frozen: Plan,
  directory: String,
  state: State,
) -> Result(Option(search.StopReason), String) {
  let budgets = frozen.budgets
  let limits =
    budget.Limits(
      budget: budgets.max_dollars,
      max_steps: budgets.max_steps,
      max_reflections: budgets.max_reflections,
      max_candidates: budgets.max_candidates,
    )
  let counts =
    budget.Counts(
      steps: state.search.step,
      reflections: state.search.reflections,
      candidates: gepa.children(state.search),
    )

  // The counted ceilings need no arithmetic; the dollar one prices the
  // step the search would take next, whose parent sets the cell cost.
  case
    budget.stop_reason(
      limits,
      counts,
      0.0,
      budget.Costs(trial: 0.0, attempts: 1, reflection: 0.0),
      design(frozen, 0),
    )
  {
    Some(budget.Steps) -> Ok(Some(search.Steps))
    Some(budget.Reflections) -> Ok(Some(search.Reflections))
    Some(budget.Candidates) -> Ok(Some(search.Candidates))
    Some(budget.Budget) | None -> {
      use remaining <- result.try(remaining(ctx, frozen, directory, state))
      use draws <- result.try(draws(
        frozen,
        directory,
        state,
        state.search.step + 1,
      ))
      use parent <- result.try(read_arm(directory, draws.parent))
      use costs <- result.try(costs(ctx, parent))

      // A taped lane's trials cost nothing, so only the reflections bind there.
      budget.stop_reason(
        limits,
        counts,
        remaining,
        costs,
        design(frozen, list.length(draws.tasks)),
      )
      |> option.map(search.stop_from_gepa)
      |> Ok
    }
  }
}

/// Whether the lane spends money.
fn metered(ctx: Context) -> Bool {
  case ctx.trial.lane {
    trial.Live | trial.Recording(..) -> True
    trial.Taped(..) -> False
  }
}

/// The dollars left to the search: the cap less every sub-run's measured
/// spend (on a metered lane) less the priced reflections (on every lane).
/// Read from the ledgers, not from memory, so a resumed search counts what
/// an earlier call spent.
fn remaining(
  ctx: Context,
  frozen: Plan,
  directory: String,
  state: State,
) -> Result(Float, String) {
  use ledgers <- result.map(ledger_total(directory, state))

  // A taped lane's rows carry what the tape says, which nobody paid.
  let trials = case metered(ctx) {
    True -> ledgers
    False -> 0.0
  }

  float.max(
    frozen.budgets.max_dollars -. trials -. state.search.spent_reflecting,
    0.0,
  )
}

// What the search has spent, and what its tapes were priced at but nobody
// paid.
type Spend {
  Spend(paid: Float, priced_not_paid: Float)
}

/// What the search has spent so far: on a live plan the ledgers and the
/// reflections; on a replay plan the reflections alone, with the taped
/// rows' prices kept apart as money nobody paid.
fn spent(
  frozen: Plan,
  directory: String,
  state: State,
) -> Result(Spend, String) {
  use ledgers <- result.map(ledger_total(directory, state))

  // A replay lane's rows carry the tape's prices, not a charge.
  case frozen.lane {
    plan.Live ->
      Spend(
        paid: ledgers +. state.search.spent_reflecting,
        priced_not_paid: 0.0,
      )
    plan.Replay ->
      Spend(paid: state.search.spent_reflecting, priced_not_paid: ledgers)
  }
}

/// The measured dollars of every sub-run's ledger.
fn ledger_total(directory: String, state: State) -> Result(Float, String) {
  use runs <- result.map(
    list.try_map(search.runs(state), fn(event) {
      case event {
        search.Run(plan:, ..) -> ledger_dollars(directory, plan)
        search.Candidate(..)
        | search.Reflection(..)
        | search.Refusal(..)
        | search.Judgement(..)
        | search.Stop(..) -> Ok(0.0)
      }
    }),
  )

  list.fold(runs, 0.0, float.add)
}

/// The measured dollars of every attempt in a sub-run's ledger, which is
/// what its account charged; an absent ledger is a run that has not started.
fn ledger_dollars(directory: String, plan_id: String) -> Result(Float, String) {
  use rows <- result.map(read_rows(directory, plan_id))

  list.fold(rows, 0.0, fn(total, row) { total +. row.usage.dollars })
}

/// A sub-run's ledger rows, or none when it has not started.
fn read_rows(
  directory: String,
  plan_id: String,
) -> Result(List(ledger.Row), String) {
  case simplifile.read(directory <> "/runs/" <> plan_id <> "/trials.jsonl") {
    Ok(text) -> ledger.parse(text)
    Error(simplifile.Enoent) -> Ok([])
    Error(error) -> Error(simplifile.describe_error(error))
  }
}

/// The latest finished row of each cell an arm owns in a sub-run, as
/// `evalstat` trials.
fn arm_rows(
  directory: String,
  plan_id: String,
  arm_id: String,
) -> Result(List(stat.Trial), String) {
  use rows <- result.map(read_rows(directory, plan_id))

  rows
  |> list.fold(dict.new(), fn(held, row) {
    dict.insert(held, #(row.task, row.arm, row.index), row)
  })
  |> dict.values
  |> list.filter(fn(row) { row.arm == arm_id && row.state != ledger.Running })
  |> list.map(report.to_stat)
}

/// What the host's evaluations and reflections cost at worst, in dollars:
/// a cell is the per-trial worst case at `ledger.max_attempts`, since an
/// infrastructure fault retries the cell and every attempt is charged.
/// `trial.worst_case` reads the arm's gateway target and never its text,
/// and a child is its parent with one slot's text replaced, so every arm
/// of a search prices as the seed: the step's holds priced at the parent
/// and the confirm run priced at the seed are one figure. A knob that
/// varied per child would break that, and `admit_child` is where such a
/// child would be refused.
fn costs(ctx: Context, candidate: Arm) -> Result(budget.Costs, String) {
  use per_trial <- result.map(trial.worst_case(ctx.trial, candidate))

  budget.Costs(
    trial: per_trial,
    attempts: ledger.max_attempts,
    reflection: ctx.reflection_worst,
  )
}

/// The shape of the search's evaluations for the library's arithmetic.
fn design(frozen: Plan, minibatch_tasks: Int) -> budget.Design {
  budget.Design(
    validate_tasks: list.length(frozen.validate),
    minibatch_tasks:,
    trials: frozen.trials_per_cell,
    tune_trials: frozen.tune_trials,
  )
}

/// The cap a sub-run started at `stage` is handed: what remains less the
/// library's hold for that stage, so a step whose cells retry cannot spend
/// the confirm's reservation.
fn capped(
  ctx: Context,
  frozen: Plan,
  directory: String,
  state: State,
  candidate: Arm,
  minibatch_tasks: Int,
  stage: budget.Stage,
) -> Result(Float, String) {
  use left <- result.try(remaining(ctx, frozen, directory, state))
  use costs <- result.map(costs(ctx, candidate))

  budget.cap(
    remaining: left,
    hold: budget.held_back(costs, design(frozen, minibatch_tasks), stage),
  )
}

// What a step draws before it runs anything: all from the pool as it stood
// and a generator seeded by the search id and the step, so a resumed step
// draws the same.
type Draws {
  Draws(parent: String, tasks: List(Task), slot: Component, step: Int)
}

/// The step's parent, minibatch and slot.
fn draws(
  frozen: Plan,
  directory: String,
  state: State,
  step: Int,
) -> Result(Draws, String) {
  use leaders <- result.try(pool_front(frozen, directory, state))
  let generator = prng.from_string(frozen.id <> "/" <> int.to_string(step))

  use #(parent, generator) <- result.try(
    select.draw_parent(leaders, generator)
    |> result.replace_error(
      "the front leads no task, so no parent can be drawn",
    ),
  )
  let tune_ids = list.map(frozen.tune, fn(each) { each.id })
  let #(drawn, _generator) =
    select.minibatch(tune_ids, frozen.minibatch, generator)
  use tasks <- result.try(find_tasks(drawn, frozen.tune))

  // The library rotates over slot names; the component is found back by
  // the same name.
  use slot <- result.try(
    select.slot_for(step, list.map(frozen.slots, search.slot_name))
    |> result.replace_error("the mutable set is empty")
    |> result.try(fn(name) {
      list.find(frozen.slots, fn(slot) { search.slot_name(slot) == name })
      |> result.replace_error("the mutable set is empty")
    }),
  )

  Ok(Draws(parent:, tasks:, slot:, step:))
}

/// The pool's front over Validate: each member's per-task means from its
/// own Validate ledger, then `select.front`.
fn pool_front(
  frozen: Plan,
  directory: String,
  state: State,
) -> Result(List(select.Leader), String) {
  use members <- result.map(pool_means(
    frozen,
    directory,
    state,
    state.search.pool,
  ))

  select.front(members, validate_ids(frozen), frozen.trials_per_cell)
}

/// The validate tasks' ids, the task order every score vector follows.
fn validate_ids(frozen: Plan) -> List(String) {
  list.map(frozen.validate, fn(each) { each.id })
}

/// Per-task means for the given arms, each read from its Validate ledger.
fn pool_means(
  frozen: Plan,
  directory: String,
  state: State,
  arms: List(String),
) -> Result(List(#(String, List(#(String, Float)))), String) {
  let validate_ids = list.map(frozen.validate, fn(each) { each.id })

  list.try_map(arms, fn(arm_id) {
    use rows <- result.map(validate_rows(directory, state, arm_id))

    #(arm_id, search.per_task_means(rows, validate_ids))
  })
}

/// An arm's Validate rows, from the sub-plan the log recorded for it.
fn validate_rows(
  directory: String,
  state: State,
  arm_id: String,
) -> Result(List(stat.Trial), String) {
  use member <- result.try(
    list.find(search.members(state), fn(member) { member.arm == arm_id })
    |> result.map_error(fn(_) { "no candidate row for arm " <> arm_id }),
  )
  use plan_id <- result.try(option.to_result(
    member.validate_plan,
    "arm " <> arm_id <> " has no validate run",
  ))

  arm_rows(directory, plan_id, arm_id)
}

// --- one step --------------------------------------------------------------------------

/// One step, fresh or resumed. Every stage first checks the log for its own
/// row: a row present means the stage was reached by an earlier call, and
/// its sub-run is executed again, which the runner resumes.
fn step(
  ctx: Context,
  frozen: Plan,
  directory: String,
  writer: Writer,
  state: State,
) -> Result(State, String) {
  // A resumed step keeps its number; a fresh one is the next.
  let number = case state.search.open {
    Some(progress) -> progress.step
    None -> state.search.step + 1
  }

  use drawn <- result.try(draws(frozen, directory, state, number))
  use #(state, parent_rows) <- result.try(parent_minibatch(
    ctx,
    frozen,
    directory,
    writer,
    state,
    drawn,
  ))
  use #(state, child) <- result.try(child_of(
    ctx,
    frozen,
    directory,
    writer,
    state,
    drawn,
  ))

  // A refused step has no child to run; the log already says so.
  case child {
    None -> Ok(state)
    Some(child) ->
      screen_and_judge(
        ctx,
        frozen,
        directory,
        writer,
        state,
        drawn,
        child,
        parent_rows,
      )
  }
}

/// The parent's minibatch run, started or resumed, and its rows.
fn parent_minibatch(
  ctx: Context,
  frozen: Plan,
  directory: String,
  writer: Writer,
  state: State,
  drawn: Draws,
) -> Result(#(State, List(stat.Trial)), String) {
  use parent <- result.try(read_arm(directory, drawn.parent))

  // A fresh step writes the run row with the dollars left; a resumed one
  // must find the same parent and plan it wrote before.
  use #(state, sub) <- result.try(case state.search.open {
    None -> {
      use remaining <- result.try(capped(
        ctx,
        frozen,
        directory,
        state,
        parent,
        list.length(drawn.tasks),
        budget.BeforeParentMinibatch,
      ))
      let sub =
        sub_plan(frozen, drawn.tasks, [parent], frozen.tune_trials, remaining)
      use state <- result.map(record(
        writer,
        state,
        search.Run(
          arm: parent.id,
          split: split.Tune,
          plan: sub.id,
          step: drawn.step,
          role: search.ParentMinibatch,
          cap: remaining,
        ),
      ))

      #(state, sub)
    }

    Some(progress) -> {
      use Nil <- result.try(require(
        progress.parent == drawn.parent,
        "on resume the step drew parent "
          <> drawn.parent
          <> " but the log holds "
          <> progress.parent,
      ))
      use plan_id <- result.try(
        search.plan_of(state, progress.step, search.ParentMinibatch)
        |> result.replace_error(
          "search row missing: the parent minibatch run that opens the step",
        ),
      )
      use sub <- result.map(
        reloaded(directory, state, plan_id, fn(cap) {
          sub_plan(frozen, drawn.tasks, [parent], frozen.tune_trials, cap)
        }),
      )

      #(state, sub)
    }
  })

  use _summary <- result.try(
    execute(ctx, frozen, directory, state, sub, drawn.tasks, [parent]),
  )
  use rows <- result.map(arm_rows(directory, sub.id, parent.id))

  #(state, rows)
}

/// The step's child: the one the log holds, or a fresh reflection minted
/// and checked. `None` when the step ended in a refusal.
fn child_of(
  ctx: Context,
  frozen: Plan,
  directory: String,
  writer: Writer,
  state: State,
  drawn: Draws,
) -> Result(#(State, Option(Arm)), String) {
  // A child already minted is read back; otherwise the reflector is asked.
  case state.search.open {
    Some(gepa.Progress(child: Some(id), reached: gepa.ChildMeasured, ..))
    | Some(gepa.Progress(child: Some(id), reached: gepa.ChildValidated, ..)) -> {
      use child <- result.map(read_arm(directory, id))

      #(state, Some(child))
    }

    Some(gepa.Progress(child: Some(id), ..)) -> {
      use child <- result.try(read_arm(directory, id))

      admit_child(ctx, writer, state, drawn, child)
    }

    Some(gepa.Progress(child: None, ..)) | None ->
      reflect_child(ctx, frozen, directory, writer, state, drawn)
  }
}

/// Asks the reflector, records the call, and mints the child or records the
/// refusal.
fn reflect_child(
  ctx: Context,
  frozen: Plan,
  directory: String,
  writer: Writer,
  state: State,
  drawn: Draws,
) -> Result(#(State, Option(Arm)), String) {
  use parent <- result.try(read_arm(directory, drawn.parent))
  use ledger_rows <- result.try(parent_ledger_rows(directory, state, drawn))
  let request =
    reflect.Request(
      objective: frozen.objective,
      slot: search.slot_name(drawn.slot),
      current: result.unwrap(list.key_find(parent.components, drawn.slot), ""),
      records: reflect.records(ledger_rows, drawn.tasks),
    )
  let prompt = reflect.render(request)

  // The reflection is made only when what remains covers it and every
  // stage after it, the confirm run included: the hold the parent's
  // minibatch was given. Under the caps a first reflection always passes;
  // a sub-run that ignored its cap, or a resumed step reflecting again
  // after its answer was lost, can have spent into that hold, and a live
  // call cannot be truncated once made. A skipped call is still a
  // zero-dollar reflection row, so the step's rows keep the order the
  // fold expects.
  use left <- result.try(remaining(ctx, frozen, directory, state))
  use costs <- result.try(costs(ctx, parent))
  let affordable =
    budget.reflection_affordable(
      remaining: left,
      costs:,
      design: design(frozen, list.length(drawn.tasks)),
    )

  // An uncovered call is not made; the refusal carries no usage.
  let outcome = case affordable {
    True -> ctx.seams.reflect(prompt)
    False ->
      Error(reflect.Refused(
        reason: "budget: the search cannot cover a reflection's worst case",
        usage: accounting.zero_usage(),
      ))
  }

  use #(state, answered) <- result.try(ask_reflector(
    ctx,
    frozen,
    writer,
    state,
    drawn,
    prompt,
    outcome,
  ))

  // A refused call or answer ends the step with no arm; a good answer mints
  // the child.
  case answered {
    Error(reason) -> {
      use state <- result.map(record(
        writer,
        state,
        search.Refusal(step: drawn.step, arm: "", reason:),
      ))

      #(state, None)
    }

    Ok(text) -> {
      use child <- result.try(arm.mint(
        arm.Arm(
          ..parent,
          name: parent.name <> "+" <> int.to_string(drawn.step),
          components: list.key_set(parent.components, drawn.slot, text),
        ),
      ))

      // An answer that reproduces a candidate already in the search mints
      // nothing new; the arm id is content, so the log would refuse it twice.
      case
        list.any(search.members(state), fn(member) { member.arm == child.id })
      {
        True -> {
          use state <- result.map(record(
            writer,
            state,
            search.Refusal(
              step: drawn.step,
              arm: "",
              reason: "the reflection reproduced candidate " <> child.id,
            ),
          ))

          #(state, None)
        }

        False -> {
          use Nil <- result.try(write_arm(directory, child))
          use state <- result.try(record(
            writer,
            state,
            search.Candidate(
              arm: child.id,
              parent: Some(parent.id),
              step: drawn.step,
              source: search.Reflected,
              slot: Some(search.slot_name(drawn.slot)),
            ),
          ))

          admit_child(ctx, writer, state, drawn, child)
        }
      }
    }
  }
}

/// Records a reflection's outcome, answered or not: a call that fails is
/// billed for its attempts all the same, and one skipped for budget costs
/// nothing, so either row carries its cost and an empty output digest, and
/// the step then ends as refused.
fn ask_reflector(
  ctx: Context,
  frozen: Plan,
  writer: Writer,
  state: State,
  drawn: Draws,
  prompt: String,
  outcome: Result(reflect.Reply, reflect.Refused),
) -> Result(#(State, Result(String, String)), String) {
  // An answer is judged by `prompt.answer`; a refused call keeps its reason.
  let #(usage, answered) = case outcome {
    Ok(reply) -> #(reply.usage, prompt.answer(reply.text))
    Error(reflect.Refused(reason:, usage:)) -> #(usage, Error(reason))
  }

  use state <- result.map(record(
    writer,
    state,
    search.Reflection(
      step: drawn.step,
      provider: frozen.reflector.provider,
      model: frozen.reflector.model_id,
      api: frozen.reflector.api,
      dollars: reflect.dollars(usage, ctx.reflector_card),
      input_digest: reflect.digest(prompt),
      output_digest: reflect.digest(result.unwrap(answered, "")),
    ),
  ))

  #(state, answered)
}

/// The parent's minibatch rows as ledger rows, for the reflective dataset.
fn parent_ledger_rows(
  directory: String,
  state: State,
  drawn: Draws,
) -> Result(List(ledger.Row), String) {
  // The minibatch plan is in the open step's rows once its row is written.
  use plan_id <- result.try(case state.search.open {
    Some(progress) ->
      search.plan_of(state, progress.step, search.ParentMinibatch)
      |> result.replace_error("the parent's minibatch has not been recorded")
    None -> Error("the parent's minibatch has not been recorded")
  })

  use rows <- result.map(read_rows(directory, plan_id))

  rows
  |> list.fold(dict.new(), fn(held, row) {
    dict.insert(held, #(row.task, row.arm, row.index), row)
  })
  |> dict.values
  |> list.filter(fn(row) { row.arm == drawn.parent })
}

/// A child the settings cannot apply is refused by name and costs nothing;
/// one they can goes on to its minibatch.
fn admit_child(
  ctx: Context,
  writer: Writer,
  state: State,
  drawn: Draws,
  child: Arm,
) -> Result(#(State, Option(Arm)), String) {
  let applied = {
    use _settings <- result.try(arm_settings.to_settings(child, ctx.trial.base))
    use _profiles <- result.try(arm_settings.profiles(child, ctx.trial.base))
    trial.worst_case(ctx.trial, child)
  }

  // The refusal's reason is the settings' own.
  case applied {
    Ok(_) -> Ok(#(state, Some(child)))
    Error(reason) -> {
      use state <- result.map(record(
        writer,
        state,
        search.Refusal(step: drawn.step, arm: child.id, reason:),
      ))

      #(state, None)
    }
  }
}

/// The child's minibatch, the screen, and on a pass the Validate run and
/// the verdicts.
fn screen_and_judge(
  ctx: Context,
  frozen: Plan,
  directory: String,
  writer: Writer,
  state: State,
  drawn: Draws,
  child: Arm,
  parent_rows: List(stat.Trial),
) -> Result(State, String) {
  use #(state, child_rows) <- result.try(child_minibatch(
    ctx,
    frozen,
    directory,
    writer,
    state,
    drawn,
    child,
  ))
  let task_ids = list.map(drawn.tasks, fn(each) { each.id })

  // A step the log already carried past the screen is not screened again;
  // the verdict rows decide what remains.
  let screened = case state.search.open {
    Some(gepa.Progress(reached: gepa.ChildValidated, ..)) -> select.Passed
    Some(gepa.Progress(..)) | None ->
      select.screen(
        search.per_task_means(parent_rows, task_ids),
        search.per_task_means(child_rows, task_ids),
        task_ids,
      )
  }

  // A failed screen is recorded as a tune-split verdict that claims nothing.
  case screened {
    select.Failed ->
      record(
        writer,
        state,
        search.Judgement(
          arm: child.id,
          against: drawn.parent,
          split: split.Tune,
          verdict: verdict.Incomplete("screened out on the tune minibatch"),
          disposition: search.ScreenedOut,
        ),
      )

    select.Passed ->
      validate(ctx, frozen, directory, writer, state, drawn, child)
  }
}

/// The child's minibatch run, started or resumed, and its rows.
fn child_minibatch(
  ctx: Context,
  frozen: Plan,
  directory: String,
  writer: Writer,
  state: State,
  drawn: Draws,
  child: Arm,
) -> Result(#(State, List(stat.Trial)), String) {
  // The row is written once; a resumed step finds it in its rows.
  use #(state, sub) <- result.try(
    case search.plan_of(state, drawn.step, search.ChildMinibatch) {
      Ok(plan_id) -> {
        use sub <- result.map(
          reloaded(directory, state, plan_id, fn(cap) {
            sub_plan(frozen, drawn.tasks, [child], frozen.tune_trials, cap)
          }),
        )

        #(state, sub)
      }

      Error(Nil) -> {
        use remaining <- result.try(capped(
          ctx,
          frozen,
          directory,
          state,
          child,
          list.length(drawn.tasks),
          budget.BeforeChildMinibatch,
        ))
        let sub =
          sub_plan(frozen, drawn.tasks, [child], frozen.tune_trials, remaining)
        use state <- result.map(record(
          writer,
          state,
          search.Run(
            arm: child.id,
            split: split.Tune,
            plan: sub.id,
            step: drawn.step,
            role: search.ChildMinibatch,
            cap: remaining,
          ),
        ))

        #(state, sub)
      }
    },
  )

  use _summary <- result.try(
    execute(ctx, frozen, directory, state, sub, drawn.tasks, [child]),
  )
  use rows <- result.map(arm_rows(directory, sub.id, child.id))

  #(state, rows)
}

/// The child's Validate run, then the verdicts against the parent and the
/// incumbent and the disposition they earn.
fn validate(
  ctx: Context,
  frozen: Plan,
  directory: String,
  writer: Writer,
  state: State,
  drawn: Draws,
  child: Arm,
) -> Result(State, String) {
  // As with the minibatches, the row is written once.
  use #(state, sub) <- result.try(
    case search.plan_of(state, drawn.step, search.ValidateRun) {
      Ok(plan_id) -> {
        use sub <- result.map(
          reloaded(directory, state, plan_id, fn(cap) {
            sub_plan(
              frozen,
              frozen.validate,
              [child],
              frozen.trials_per_cell,
              cap,
            )
          }),
        )

        #(state, sub)
      }

      Error(Nil) -> {
        use remaining <- result.try(capped(
          ctx,
          frozen,
          directory,
          state,
          child,
          list.length(drawn.tasks),
          budget.BeforeValidate,
        ))
        let sub =
          sub_plan(
            frozen,
            frozen.validate,
            [child],
            frozen.trials_per_cell,
            remaining,
          )
        use state <- result.map(record(
          writer,
          state,
          search.Run(
            arm: child.id,
            split: split.Validate,
            plan: sub.id,
            step: drawn.step,
            role: search.ValidateRun,
            cap: remaining,
          ),
        ))

        #(state, sub)
      }
    },
  )

  use _summary <- result.try(
    execute(ctx, frozen, directory, state, sub, frozen.validate, [child]),
  )
  use child_rows <- result.try(arm_rows(directory, sub.id, child.id))
  use parent_rows <- result.try(validate_rows(directory, state, drawn.parent))
  let against_parent =
    judge(frozen, parent_rows, drawn.parent, child_rows, child.id)

  // The incumbent comparison exists only when the parent is not the
  // incumbent, and a resumed step that already holds it does not write it twice.
  use #(state, against_incumbent) <- result.try(
    case state.search.incumbent == drawn.parent, state.search.open {
      True, _ -> Ok(#(state, None))
      False, Some(gepa.Progress(against_incumbent: Some(found), ..)) ->
        Ok(#(state, Some(found)))
      False, Some(gepa.Progress(against_incumbent: None, ..)) | False, None -> {
        use incumbent_rows <- result.try(validate_rows(
          directory,
          state,
          state.search.incumbent,
        ))
        let found =
          judge(
            frozen,
            incumbent_rows,
            state.search.incumbent,
            child_rows,
            child.id,
          )
        use state <- result.map(record(
          writer,
          state,
          search.Judgement(
            arm: child.id,
            against: state.search.incumbent,
            split: split.Validate,
            verdict: found,
            disposition: search.Unsettled,
          ),
        ))

        #(state, Some(search.acceptance_of(found)))
      }
    },
  )

  use #(child_led, incumbent_led) <- result.try(led_by(
    frozen,
    directory,
    state,
    child.id,
    sub.id,
  ))
  let disposition =
    rule.dispose(
      search.acceptance_of(against_parent),
      against_incumbent,
      child_led,
      incumbent_led,
    )
    |> search.disposition_from_gepa

  record(
    writer,
    state,
    search.Judgement(
      arm: child.id,
      against: drawn.parent,
      split: split.Validate,
      verdict: against_parent,
      disposition:,
    ),
  )
}

/// The paired verdict of a candidate's Validate rows against a baseline's,
/// over the plan's `(task, index)` set.
fn judge(
  frozen: Plan,
  baseline_rows: List(stat.Trial),
  baseline: String,
  candidate_rows: List(stat.Trial),
  candidate: String,
) -> Verdict {
  let expected =
    pairing.plan(
      list.map(frozen.validate, fn(each) { each.id }),
      frozen.trials_per_cell,
    )

  evalstat.paired_verdict(
    list.append(baseline_rows, candidate_rows),
    baseline,
    candidate,
    expected,
    verdict.default_policy(),
  )
}

/// How many tasks the child and the incumbent lead on a front that holds
/// the pool and the child.
fn led_by(
  frozen: Plan,
  directory: String,
  state: State,
  child: String,
  child_plan: String,
) -> Result(#(Int, Int), String) {
  let validate_ids = validate_ids(frozen)

  use pool <- result.try(pool_means(frozen, directory, state, state.search.pool))
  use child_rows <- result.map(arm_rows(directory, child_plan, child))
  let leaders =
    select.front(
      list.append(pool, [
        #(child, search.per_task_means(child_rows, validate_ids)),
      ]),
      validate_ids,
      frozen.trials_per_cell,
    )
  let led = fn(arm_id: String) {
    list.find(leaders, fn(leader) { leader.candidate == arm_id })
    |> result.map(fn(leader) { leader.tasks_led })
    |> result.unwrap(0)
  }

  #(led(child), led(state.search.incumbent))
}

// --- the confirm run ---------------------------------------------------------------------

/// What `confirm` did: ran (or found nothing to run), or could not be paid
/// for, which is a clean stop rather than a failure.
type Confirmed {
  Ran(state: State)
  Unaffordable(state: State)
}

/// The one simultaneous comparison: seed and best in a single sub-plan over
/// Validate, started or resumed, then judged. A search whose incumbent is
/// still the seed has nothing to confirm.
fn confirm(
  ctx: Context,
  frozen: Plan,
  directory: String,
  writer: Writer,
  state: State,
) -> Result(Confirmed, String) {
  // Three cases: nothing to confirm, already judged, or a run to start or resume.
  case state.search.incumbent == frozen.seed.id, state.confirmation {
    True, _ -> Ok(Ran(state))
    False, Some(search.Confirmation(verdict: Some(_), ..)) -> Ok(Ran(state))
    False, found -> {
      use left <- result.try(remaining(ctx, frozen, directory, state))
      use costs <- result.try(costs(ctx, frozen.seed))
      let affordable =
        budget.confirm_affordable(
          remaining: left,
          costs:,
          design: design(frozen, 0),
        )

      // A confirm run the search can no longer cover is not started; the
      // headline then says the budget, not the evidence, left it unconfirmed.
      case found, affordable {
        None, False -> Ok(Unaffordable(state))
        None, True | Some(_), _ ->
          run_confirm(ctx, frozen, directory, writer, state, found)
          |> result.map(Ran)
      }
    }
  }
}

/// Starts or resumes the `[seed, best]` sub-plan and judges it.
fn run_confirm(
  ctx: Context,
  frozen: Plan,
  directory: String,
  writer: Writer,
  state: State,
  found: Option(search.Confirmation),
) -> Result(State, String) {
  use best <- result.try(read_arm(directory, state.search.incumbent))
  let arms = [frozen.seed, best]
  {
    // The run row is written once.
    use #(state, sub) <- result.try(case found {
      Some(search.Confirmation(plan: plan_id, ..)) -> {
        use sub <- result.map(
          reloaded(directory, state, plan_id, fn(cap) {
            sub_plan(frozen, frozen.validate, arms, frozen.trials_per_cell, cap)
          }),
        )

        #(state, sub)
      }

      None -> {
        use remaining <- result.try(remaining(ctx, frozen, directory, state))
        let sub =
          sub_plan(
            frozen,
            frozen.validate,
            arms,
            frozen.trials_per_cell,
            remaining,
          )
        use state <- result.map(record(
          writer,
          state,
          search.Run(
            arm: best.id,
            split: split.Validate,
            plan: sub.id,
            step: state.search.step,
            role: search.Confirm,
            cap: remaining,
          ),
        ))

        #(state, sub)
      }
    })

    use _summary <- result.try(execute(
      ctx,
      frozen,
      directory,
      state,
      sub,
      frozen.validate,
      arms,
    ))
    use seed_rows <- result.try(arm_rows(directory, sub.id, frozen.seed.id))
    use best_rows <- result.try(arm_rows(directory, sub.id, best.id))
    let found = judge(frozen, seed_rows, frozen.seed.id, best_rows, best.id)

    record(
      writer,
      state,
      search.Judgement(
        arm: best.id,
        against: frozen.seed.id,
        split: split.Validate,
        verdict: found,
        disposition: case found {
          verdict.Improved(..) -> search.Confirmed
          verdict.Harmed(..)
          | verdict.Indistinguishable(..)
          | verdict.Underpowered(..)
          | verdict.Incomplete(..) -> search.Unconfirmed
        },
      ),
    )
  }
}

// --- sub-plans ------------------------------------------------------------------------------

/// The sub-plan for a set of tasks and arms at `k` trials per cell, with
/// `max_dollars` what remained when it was created.
fn sub_plan(
  frozen: Plan,
  tasks: List(Task),
  arms: List(Arm),
  k: Int,
  max_dollars: Float,
) -> plan.Plan {
  plan.mint(plan.Plan(
    id: "",
    task_ids: list.map(tasks, fn(each) { each.id }),
    arm_ids: list.map(arms, fn(each) { each.id }),
    trials_per_cell: k,
    lane: frozen.lane,
    profile: frozen.profile,
    split_salt: frozen.split_salt,
    budgets: plan.Budgets(..frozen.trial, max_dollars:),
    harness: frozen.harness,
  ))
}

/// A resumed sub-plan: the one the run directory holds, or, when the run
/// never got as far as writing its directory, the one rebuilt from the cap
/// the Run row recorded. Either must carry the id the log recorded, and
/// its task and arm sets must be the ones the step drew again.
fn reloaded(
  directory: String,
  state: State,
  plan_id: String,
  rebuild: fn(Float) -> plan.Plan,
) -> Result(plan.Plan, String) {
  let run_directory = directory <> "/runs/" <> plan_id

  // The directory's copy is the authority once it exists; before that the
  // Run row's cap is enough to mint the same plan again.
  use loaded <- result.try(
    case simplifile.is_file(run_directory <> "/plan.json") {
      Ok(True) ->
        run.load(
          run_directory <> "/plan.json",
          run_directory <> "/tasks",
          run_directory <> "/arms",
        )
        |> result.map(fn(loaded) { loaded.plan })
      Ok(False) | Error(_) -> {
        use cap <- result.map(search.recorded_cap(state, plan_id))

        rebuild(cap)
      }
    },
  )

  use Nil <- result.try(require(
    loaded.id == plan_id,
    run_directory <> " holds plan " <> loaded.id <> ", not " <> plan_id,
  ))
  let rebuilt = rebuild(loaded.budgets.max_dollars)

  // The draws must come out the same on resume, or the log is not this search's.
  use Nil <- result.map(require(
    loaded.task_ids == rebuilt.task_ids
      && loaded.arm_ids == rebuilt.arm_ids
      && loaded.trials_per_cell == rebuilt.trials_per_cell,
    "on resume the step drew a different sub-plan than the log holds for "
      <> plan_id,
  ))

  loaded
}

/// Runs a sub-plan under `runs/` through the seam, with the trial context
/// narrowed to the sub-plan's id and a dollar cap of the smaller of the
/// sub-plan's own cap less what its ledger already holds and what the
/// search has left. The runner opens a fresh account on every call, so a
/// resumed sub-run handed its original cap would spend it twice.
fn execute(
  ctx: Context,
  frozen: Plan,
  directory: String,
  state: State,
  sub: plan.Plan,
  tasks: List(Task),
  arms: List(Arm),
) -> Result(run.Summary, String) {
  use own <- result.try(ledger_dollars(directory, sub.id))
  use left <- result.try(remaining(ctx, frozen, directory, state))
  let cap = float.max(float.min(sub.budgets.max_dollars -. own, left), 0.0)
  let narrowed =
    trial.Context(
      ..ctx.trial,
      budgets: plan.Budgets(..sub.budgets, max_dollars: cap),
      plan_id: sub.id,
    )

  ctx.seams.execute(
    narrowed,
    run.Loaded(plan: sub, tasks:, arms:),
    directory <> "/runs",
  )
}

// --- the log writer ------------------------------------------------------------------------

/// Starts the process that owns the search log.
fn start_writer(path: String, store: search.Store) -> Result(Writer, String) {
  actor.new(path)
  |> actor.on_message(write_line)
  |> actor.start
  |> result.map(fn(started) { Writer(started.data, store) })
  |> result.replace_error("the search log writer did not start")
}

/// One process appends, one whole line at a time, so a crash between rows
/// leaves a file `search.parse` still reads.
fn write_line(
  path: String,
  message: WriterMessage,
) -> actor.Next(String, WriterMessage) {
  // One writer process owns the file, so rows never interleave.
  case message {
    Close -> actor.stop()

    Append(line:, reply:) -> {
      let written =
        simplifile.append(path, line <> "\n")
        |> result.map_error(fn(error) {
          "cannot append to the search log: "
          <> simplifile.describe_error(error)
        })

      process.send(reply, written)
      actor.continue(path)
    }
  }
}

/// Appends one row and hands it back.
fn append(writer: Writer, event: Event) -> Result(Event, String) {
  actor.call(writer.subject, waiting: 10_000, sending: Append(
    search.encode_line(event),
    _,
  ))
  |> result.replace(event)
}

/// Applies one row to the state and then appends it, so a row the fold
/// refuses never reaches disk and the state in memory is always the fold of
/// the file.
fn record(writer: Writer, state: State, event: Event) -> Result(State, String) {
  use next <- result.try(search.apply(state, event, writer.store))
  use _event <- result.map(append(writer, event))

  next
}

/// The lookup the fold reads a search directory through: an arm's
/// components from `arms/`. Nothing else leaves the ledgers, which every
/// decision reads from disk.
fn store_for(directory: String) -> search.Store {
  search.Store(components: fn(arm_id) {
    read_arm(directory, arm_id) |> result.map(search.component_map)
  })
}

// --- the front -------------------------------------------------------------------------------

// One pool member as the front reports it.
type Line {
  Line(
    member: search.Member,
    candidate: Arm,
    rows: List(stat.Trial),
    against_parent: Option(Verdict),
    against_seed: Option(Verdict),
    tasks_led: Int,
    scores: List(#(String, Float)),
    dollars: Float,
  )
}

/// Writes `front.json`, `front.md`, `PROPOSE.md` and the `propose/`
/// directories for the top candidates from the log's state.
///
/// ## Examples
///
/// ```gleam
/// // optimize.write_front("searches/<id>", plan, state) == Ok(Nil)
/// ```
///
pub fn write_front(
  directory: String,
  frozen: Plan,
  state: State,
) -> Result(Nil, String) {
  use lines <- result.try(lines(directory, frozen, state))
  let ranked =
    select.rank(
      list.map(lines, fn(line) {
        select.Ranked(
          candidate: line.member.arm,
          disposition: option.unwrap(line.member.disposition, search.Unsettled)
            |> search.disposition_to_gepa,
          step: line.member.step,
          standing: search.standing_of(dominance_of(line, lines, frozen)),
          tasks_led: line.tasks_led,
        )
      }),
      state.search.incumbent,
    )
  let ordered =
    list.filter_map(ranked, fn(entry) {
      list.find(lines, fn(line) { line.member.arm == entry.candidate })
      |> result.map(fn(line) { #(line, dominance_of(line, lines, frozen)) })
    })
  use spend <- result.try(spent(frozen, directory, state))

  use Nil <- result.try(write_file(
    directory <> "/front.json",
    json.to_string(front_json(frozen, state, ordered, spend)),
  ))
  use Nil <- result.try(write_file(
    directory <> "/front.md",
    front_markdown(frozen, state, ordered, spend),
  ))

  write_proposals(directory, frozen, state, ordered)
}

/// Rebuilds the front of a search directory from its log without running
/// anything.
///
/// ## Examples
///
/// ```gleam
/// // optimize.report("searches/<id>") == Ok(Nil)
/// ```
///
pub fn report(directory: String) -> Result(Nil, String) {
  use frozen <- result.try(load(directory))
  use events <- result.try(read_log(directory))
  use state <- result.try(search.replay(events, store_for(directory)))

  write_front(directory, frozen, state)
}

/// The front's lines: one per pool member, with its Validate rows, its
/// verdicts against its parent and the seed, the tasks it leads and its
/// mean scores.
fn lines(
  directory: String,
  frozen: Plan,
  state: State,
) -> Result(List(Line), String) {
  use means <- result.try(pool_means(
    frozen,
    directory,
    state,
    state.search.pool,
  ))
  let leaders =
    select.front(means, validate_ids(frozen), frozen.trials_per_cell)
  use seed_rows <- result.try(validate_rows(directory, state, frozen.seed.id))

  search.members(state)
  |> list.filter(fn(member) { list.contains(state.search.pool, member.arm) })
  |> list.try_map(fn(member) {
    use candidate <- result.try(read_arm(directory, member.arm))
    use rows <- result.try(validate_rows(directory, state, member.arm))

    // The seed has no parent to be judged against.
    use against_parent <- result.map(case member.parent {
      None -> Ok(None)
      Some(parent) -> {
        use parent_rows <- result.map(validate_rows(directory, state, parent))
        Some(judge(frozen, parent_rows, parent, rows, member.arm))
      }
    })

    // Nor is it judged against itself.
    let against_seed = case member.arm == frozen.seed.id {
      True -> None
      False -> Some(judge(frozen, seed_rows, frozen.seed.id, rows, member.arm))
    }

    Line(
      member:,
      candidate:,
      rows:,
      against_parent:,
      against_seed:,
      tasks_led: list.find(leaders, fn(leader) {
        leader.candidate == member.arm
      })
        |> result.map(fn(leader) { leader.tasks_led })
        |> result.unwrap(0),
      scores: score_vector(rows),
      dollars: list.fold(rows, 0.0, fn(total, row) { total +. row.cost.dollars }),
    )
  })
}

/// A member's standing against the seed over outcome and scores, as the
/// report rules it: the seed itself is a tie.
fn dominance_of(
  line: Line,
  lines: List(Line),
  frozen: Plan,
) -> dominance.Dominance {
  let seed_scores =
    list.find(lines, fn(each) { each.member.arm == frozen.seed.id })
    |> result.map(fn(each) { each.scores })
    |> result.unwrap([])

  // The seed has no verdict against itself.
  case line.against_seed {
    None -> dominance.Tie
    Some(found) -> dominance.compare(found, line.scores, seed_scores)
  }
}

/// An arm's scores over its counted Validate rows: the mean reward, the
/// mean of each named score, and cost, turns and tool errors as
/// `1 / (1 + mean)`, every one oriented higher is better, as `eval/report`
/// builds them.
fn score_vector(rows: List(stat.Trial)) -> List(#(String, Float)) {
  let counted =
    list.filter(rows, fn(row) {
      case stat.standing(row.outcome) {
        stat.Counted(..) -> True
        stat.Excluded -> False
      }
    })
  let mean = fn(value: fn(stat.Trial) -> Float) {
    case counted {
      [] -> 0.0
      [_, ..] ->
        list.fold(counted, 0.0, fn(total, row) { total +. value(row) })
        /. int.to_float(list.length(counted))
    }
  }
  let names =
    counted
    |> list.flat_map(fn(row) { list.map(row.scores, fn(score) { score.0 }) })
    |> list.unique
    |> list.sort(string.compare)

  list.flatten([
    [#("reward", mean(fn(row) { row.reward }))],
    list.map(names, fn(name) {
      #(
        name,
        mean(fn(row) { result.unwrap(list.key_find(row.scores, name), 0.0) }),
      )
    }),
    [
      #("cost_inv", 1.0 /. { 1.0 +. mean(fn(row) { row.cost.dollars }) }),
      #(
        "turns_inv",
        1.0 /. { 1.0 +. mean(fn(row) { int.to_float(row.cost.turns) }) },
      ),
      #(
        "tool_errors_inv",
        1.0 /. { 1.0 +. mean(fn(row) { int.to_float(row.cost.tool_errors) }) },
      ),
    ],
  ])
}

/// The headline: the confirm verdict when there is one, else why not.
fn headline(frozen: Plan, state: State) -> String {
  // The confirm run's verdict leads; without one the seed is still the best.
  case state.confirmation {
    Some(search.Confirmation(
      best:,
      verdict: Some(verdict.Improved(effect:, ci:, mde:, ..)),
      ..,
    )) ->
      "Confirmed: "
      <> short(best)
      <> " improved on the seed in one sub-plan (effect "
      <> fmt(effect)
      <> ", interval "
      <> fmt(ci.0)
      <> " to "
      <> fmt(ci.1)
      <> ", minimum detectable effect "
      <> fmt(mde)
      <> ")"
    Some(search.Confirmation(best:, verdict: Some(found), ..)) ->
      "Not confirmed: "
      <> short(best)
      <> " led the search but the seed-and-best sub-plan read "
      <> verdict_word(found)
      <> " ("
      <> verdict_detail(found)
      <> ")"
    Some(search.Confirmation(best:, verdict: None, ..)) ->
      "Unconfirmed: the seed-and-best sub-plan for "
      <> short(best)
      <> " has not finished"
    None ->
      // Without a confirm run the search is unfinished, found nothing, or
      // stopped for dollars before the run could be paid for.
      case state.search.incumbent == frozen.seed.id, state.search.stopped {
        True, _ -> "No candidate improved on the seed"
        False, None ->
          "In progress: "
          <> short(state.search.incumbent)
          <> " leads, not yet confirmed"
        False, Some(reason) ->
          "Not confirmed (budget): "
          <> short(state.search.incumbent)
          <> " led the search but it stopped for "
          <> search.stop_name(search.stop_from_gepa(reason))
          <> " before the seed-and-best sub-plan could be paid for"
      }
  }
}

fn short(arm_id: String) -> String {
  string.slice(arm_id, 0, 12)
}

fn fmt(value: Float) -> String {
  float.to_string(float.to_precision(value, 3))
}

/// The one-word reading of a verdict.
fn verdict_word(found: Verdict) -> String {
  case found {
    verdict.Improved(..) -> "improved"
    verdict.Harmed(..) -> "harmed"
    verdict.Indistinguishable(..) -> "indistinguishable"
    verdict.Underpowered(..) -> "underpowered"
    verdict.Incomplete(..) -> "incomplete"
  }
}

/// The figures behind a verdict, for a table cell.
fn verdict_detail(found: Verdict) -> String {
  case found {
    verdict.Improved(effect:, ci:, mde:, ..)
    | verdict.Harmed(effect:, ci:, mde:, ..)
    | verdict.Indistinguishable(effect:, ci:, mde:, ..) ->
      "effect "
      <> fmt(effect)
      <> ", interval "
      <> fmt(ci.0)
      <> " to "
      <> fmt(ci.1)
      <> ", mde "
      <> fmt(mde)
    verdict.Underpowered(mde:, needed_tasks:, ..) ->
      "mde "
      <> fmt(mde)
      <> ", needs "
      <> int.to_string(needed_tasks)
      <> " tasks"
    verdict.Incomplete(reason:) -> reason
  }
}

/// `front.json`.
fn front_json(
  frozen: Plan,
  state: State,
  ordered: List(#(Line, dominance.Dominance)),
  spend: Spend,
) -> JsonValue {
  json.Object([
    #("v", json.Int(version)),
    #("search", json.String(frozen.id)),
    #("headline", json.String(headline(frozen, state))),
    #("incumbent", json.String(state.search.incumbent)),
    #("confirm", case state.confirmation {
      Some(search.Confirmation(verdict: Some(found), ..)) ->
        search.verdict_json(found)
      Some(search.Confirmation(verdict: None, ..)) | None -> json.Null
    }),
    #("steps", json.Int(state.search.step)),
    #("reflections", json.Int(state.search.reflections)),
    #("stopped", case state.search.stopped {
      Some(reason) ->
        json.String(search.stop_name(search.stop_from_gepa(reason)))
      None -> json.Null
    }),
    #(
      "spend",
      json.Object([
        #("total", json.Float(spend.paid)),
        #("reflections", json.Float(state.search.spent_reflecting)),
        #("trials", json.Float(spend.paid -. state.search.spent_reflecting)),
        #("trials_priced_not_paid", json.Float(spend.priced_not_paid)),
      ]),
    ),
    #(
      "members",
      json.Array(
        list.map(ordered, fn(entry) {
          let #(line, found) = entry

          json.Object([
            #("arm", json.String(line.member.arm)),
            #("name", json.String(line.candidate.name)),
            #("parent", case line.member.parent {
              Some(parent) -> json.String(parent)
              None -> json.Null
            }),
            #("step", json.Int(line.member.step)),
            #("slot", case line.member.slot {
              Some(slot) -> json.String(slot)
              None -> json.Null
            }),
            #("disposition", case line.member.disposition {
              Some(disposition) ->
                json.String(search.disposition_name(disposition))
              None -> json.Null
            }),
            #("vs_parent", option_verdict(line.against_parent)),
            #("vs_seed", option_verdict(line.against_seed)),
            #("dominance", json.String(dominance_word(found))),
            #("tasks_led", json.Int(line.tasks_led)),
            #(
              "scores",
              json.Object(
                list.map(line.scores, fn(score) {
                  #(score.0, json.Float(score.1))
                }),
              ),
            ),
            #("dollars", json.Float(line.dollars)),
          ])
        }),
      ),
    ),
  ])
}

fn option_verdict(found: Option(Verdict)) -> JsonValue {
  case found {
    Some(verdict) -> search.verdict_json(verdict)
    None -> json.Null
  }
}

/// The report's word for a dominance outcome.
fn dominance_word(found: dominance.Dominance) -> String {
  case found {
    dominance.Dominates(dominance.Outcome) -> "dominates on outcome"
    dominance.Dominates(dominance.Scores) -> "dominates on scores"
    dominance.Dominated(dominance.Outcome) -> "dominated on outcome"
    dominance.Dominated(dominance.Scores) -> "dominated on scores"
    dominance.Tie -> "tie"
    dominance.Tradeoff(better:, worse:) ->
      "tradeoff: better on "
      <> string.join(better, ", ")
      <> "; worse on "
      <> string.join(worse, ", ")
    dominance.Undecided -> "undecided"
  }
}

/// `front.md`.
fn front_markdown(
  frozen: Plan,
  state: State,
  ordered: List(#(Line, dominance.Dominance)),
  spend: Spend,
) -> String {
  let header = [
    headline(frozen, state),
    "",
    "Search " <> frozen.id,
    "",
    "- objective: " <> frozen.objective,
    "- reflector: "
      <> frozen.reflector.entry
      <> " ("
      <> frozen.reflector.provider
      <> "/"
      <> frozen.reflector.model_id
      <> ")",
    "- tune tasks: "
      <> int.to_string(list.length(frozen.tune))
      <> ", validate tasks: "
      <> int.to_string(list.length(frozen.validate))
      <> ", K "
      <> int.to_string(frozen.trials_per_cell)
      <> ", minibatch "
      <> int.to_string(frozen.minibatch)
      <> " at K "
      <> int.to_string(frozen.tune_trials),
    "- steps: "
      <> int.to_string(state.search.step)
      <> ", reflections: "
      <> int.to_string(state.search.reflections)
      <> ", children: "
      <> int.to_string(gepa.children(state.search)),
    "- spend: "
      <> fmt(spend.paid)
      <> " dollars ("
      <> fmt(state.search.spent_reflecting)
      <> " in reflections; "
      <> fmt(spend.priced_not_paid)
      <> " priced on tape, not paid)",
    "- stopped: "
      <> case state.search.stopped {
      Some(reason) -> search.stop_name(search.stop_from_gepa(reason))
      None -> "not yet"
    },
    "",
    "Acceptance is the paired verdict on the validate split; the minibatch screen is a spend filter and claims nothing. Candidates were judged against their parents' earlier runs; only the headline's sub-plan ran seed and best together.",
    "",
    "| rank | arm | name | step | slot | disposition | vs parent | vs seed | tasks led | reward | dollars |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
  ]
  let rows =
    list.index_map(ordered, fn(entry, position) {
      let #(line, _found) = entry

      string.join(
        [
          "| " <> int.to_string(position + 1),
          short(line.member.arm),
          line.candidate.name,
          int.to_string(line.member.step),
          option.unwrap(line.member.slot, "seed"),
          option.map(line.member.disposition, search.disposition_name)
            |> option.unwrap(""),
          option.map(line.against_parent, verdict_word) |> option.unwrap("seed"),
          option.map(line.against_seed, verdict_word) |> option.unwrap("seed"),
          int.to_string(line.tasks_led),
          fmt(result.unwrap(list.key_find(line.scores, "reward"), 0.0)),
          fmt(line.dollars) <> " |",
        ],
        " | ",
      )
    })
  let footer = [
    "",
    "Next: run the top candidate on the holdout split with `eval run`, then the governed `compare`; `PROPOSE.md` has the program. The search runs neither. The headline's improvement is on the validate tasks the search selected on; the holdout was not run.",
    "",
  ]

  string.join(list.flatten([header, rows, footer]), "\n")
}

/// `propose/<arm id>/<target>/prompt.json` for the top candidates that
/// improved over the seed, in the payload shape
/// `client/evolution/prompt.candidate_profile` reads, and `PROPOSE.md` with
/// the program that proposes one. A search in which nothing improved over
/// the seed writes no payload, and the file says so.
fn write_proposals(
  directory: String,
  frozen: Plan,
  state: State,
  ordered: List(#(Line, dominance.Dominance)),
) -> Result(Nil, String) {
  let top =
    ordered
    |> list.filter(fn(entry) {
      { entry.0 }.member.arm != frozen.seed.id && improved_over_seed(entry.0)
    })
    |> list.take(propose_top)

  use Nil <- result.try(
    list.try_each(top, fn(entry) {
      let line = entry.0
      let base = directory <> "/propose/" <> line.member.arm

      // One directory per exact target the arm's components name; most arms name one.
      list.try_each(payloads(line.candidate), fn(payload) {
        let folder = base <> "/" <> payload.0

        use Nil <- result.try(make_directory(folder))
        write_file(folder <> "/prompt.json", json.to_string(payload.1))
      })
    }),
  )

  write_file(
    directory <> "/PROPOSE.md",
    propose_markdown(directory, state, top),
  )
}

/// Whether a member's Validate rows read `Improved` against the seed's.
fn improved_over_seed(line: Line) -> Bool {
  case line.against_seed {
    Some(verdict.Improved(..)) -> True
    Some(verdict.Harmed(..))
    | Some(verdict.Indistinguishable(..))
    | Some(verdict.Underpowered(..))
    | Some(verdict.Incomplete(..))
    | None -> False
  }
}

/// The prompt candidate payloads of an arm: one per exact target its
/// components name, keyed by a directory-safe target label.
fn payloads(candidate: Arm) -> List(#(String, JsonValue)) {
  candidate.components
  |> list.filter_map(fn(component) { target_key(component.0) })
  |> list.unique
  |> list.map(fn(key) {
    let #(provider, model_id, api) = key
    let aimed =
      list.filter(candidate.components, fn(component) {
        target_key(component.0) == Ok(key)
      })
    let text_of = fn(wanted: fn(Component) -> Bool) {
      list.find(aimed, fn(component) { wanted(component.0) })
      |> result.map(fn(component) { component.1 })
      |> result.unwrap("")
    }
    let descriptions =
      list.filter_map(aimed, fn(component) {
        case component.0 {
          arm.ToolDescription(tool:, ..) ->
            Ok(#(tool, json.String(component.1)))
          arm.SystemSuffix(..) | arm.TaskPrefix(..) | arm.PromptPack ->
            Error(Nil)
        }
      })

    #(
      safe_label(provider <> "-" <> model_id),
      json.Object([
        #("version", json.Int(1)),
        #("provider", json.String(provider)),
        #("model", json.String(model_id)),
        #("api", json.String(api)),
        #("system", json.String(text_of(is_system_suffix))),
        #("task", json.String(text_of(is_task_prefix))),
        #("descriptions", json.Object(descriptions)),
      ]),
    )
  })
}

/// The exact-model key a component is aimed at; the pack has none.
fn target_key(component: Component) -> Result(#(String, String, String), Nil) {
  case component {
    arm.SystemSuffix(target:) | arm.TaskPrefix(target:) ->
      Ok(#(target.provider, target.model_id, target.api))
    arm.ToolDescription(target:, ..) ->
      Ok(#(target.provider, target.model_id, target.api))
    arm.PromptPack -> Error(Nil)
  }
}

/// Whether a component is the system suffix.
fn is_system_suffix(component: Component) -> Bool {
  case component {
    arm.SystemSuffix(..) -> True
    arm.TaskPrefix(..) | arm.ToolDescription(..) | arm.PromptPack -> False
  }
}

/// Whether a component is the task prefix.
fn is_task_prefix(component: Component) -> Bool {
  case component {
    arm.TaskPrefix(..) -> True
    arm.SystemSuffix(..) | arm.ToolDescription(..) | arm.PromptPack -> False
  }
}

/// A target label made of the characters a directory name is safe with.
fn safe_label(text: String) -> String {
  text
  |> string.to_graphemes
  |> list.map(fn(grapheme) {
    case
      string.contains(
        "abcdefghijklmnopqrstuvwxyz0123456789-_.",
        string.lowercase(grapheme),
      )
    {
      True -> string.lowercase(grapheme)
      False -> "_"
    }
  })
  |> string.join("")
}

/// `PROPOSE.md`: for each top candidate, the program a model or an operator
/// runs under `cap/evolution` to propose it, and the governed `compare` and
/// `loomd evolution` steps that follow. Nothing here runs them.
fn propose_markdown(
  directory: String,
  state: State,
  top: List(#(Line, dominance.Dominance)),
) -> String {
  let intro = [
    "# Proposing a candidate",
    "",
    "The search writes prompt candidate payloads under `propose/<arm id>/<target>/prompt.json`,",
    "in the shape `evolution.propose` with `Kind = Prompt` snapshots and",
    "`client/evolution/prompt.candidate_profile` reads back, for the candidates whose",
    "validate rows read `Improved` against the seed's. The search ran none of",
    "the steps below; the governed plane is the only route from a candidate to a",
    "selection (ADR-021).",
    "",
  ]
  let none = [
    "No candidate improved over the seed on the validate split, so no payload was",
    "written: there is nothing to propose.",
    "",
  ]
  let steps = [
    "1. Run the candidate on the holdout split with `eval run` to see the gap it",
    "   never tuned against.",
    "2. From a code-mode program with the `cap/evolution` capability, propose the",
    "   directory and run the governed comparison against the admitted task set:",
    "",
  ]
  let programs =
    list.flat_map(top, fn(entry) {
      let line = entry.0
      let folder = directory <> "/propose/" <> line.member.arm

      [
        "   ```gleam",
        "   // candidate "
          <> line.member.arm
          <> " ("
          <> line.candidate.name
          <> "): "
          <> confirm_status(state, line.member.arm),
        "   let proposal =",
        "     evolution.Proposal(",
        "       ..evolution.proposal(\""
          <> folder
          <> "/<target>\", \""
          <> line.candidate.name
          <> "\", evolution.Prompt),",
        "       description: Some(\"found by eval/optimize search\"),",
        "     )",
        "   use proposed <- result.try(evolution.propose(proposal) |> result.map_error(evolution.error_text))",
        "   // then evolution.compare(candidate_id, taskset_id, limits) and read its evidence",
        "   ```",
        "",
      ]
    })
  let outro = [
    "3. Approve and select through the operator door: `loomd evolution approve SESSION --args approval.json`,",
    "   then `loomd evolution select SESSION --args selection.json`, each naming the exact",
    "   candidate id and the evidence the comparison produced.",
    "",
  ]

  // A search with nothing to propose says so in place of the steps.
  case top {
    [] -> string.join(list.flatten([intro, none]), "\n")
    [_, ..] -> string.join(list.flatten([intro, steps, programs, outro]), "\n")
  }
}

/// What the confirm run said about a candidate, for the proposal note.
fn confirm_status(state: State, arm_id: String) -> String {
  case state.confirmation {
    Some(search.Confirmation(best:, verdict: Some(verdict.Improved(..)), ..))
      if best == arm_id
    -> "confirmed in the seed-and-best sub-plan"
    Some(search.Confirmation(best:, verdict: Some(_), ..)) if best == arm_id ->
      "NOT confirmed in the seed-and-best sub-plan"
    Some(_) | None ->
      "never run beside the seed in one sub-plan; its verdict is sequential"
  }
}
