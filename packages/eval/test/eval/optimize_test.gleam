import client/catalog
import core/clock
import core/json
import eval/arm.{type Arm, Any, SystemSuffix, Target, TaskPrefix}
import eval/ledger
import eval/optimize
import eval/plan
import eval/reflect
import eval/repos
import eval/run
import eval/search
import eval/split
import eval/task.{type Task}
import eval/trial
import evalstat/verdict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import provider/gateway
import provider/http.{type Transport}
import provider/secret
import simplifile
import support/scripted

/// `count` planted tasks named `<prefix>-<n>` that the salt `salt` assigns
/// to `wanted`, so a search plan over them passes the holdout seal.
fn tasks_in(prefix: String, wanted: split.Split, count: Int) -> List(Task) {
  list.index_map(list.repeat(Nil, 20 * count), fn(_, position) {
    scripted.planted_task(prefix <> "-" <> int.to_string(position))
  })
  |> list.filter(fn(each) { split.assign("salt", split.family(each)) == wanted })
  |> list.take(count)
}

/// The three steps the scripted reflector proposes: an inert sentence, the
/// sentinel, then a paraphrase that keeps the sentinel.
fn planted_answers() -> List(String) {
  [
    "Be careful and concise.",
    scripted.sentinel,
    "Before you answer: " <> scripted.sentinel <> " Then stop.",
  ]
}

type Rig {
  Rig(root: String, ctx: optimize.Context, plan: optimize.Plan, out: String)
}

/// The shape of a search: task counts, trials, minibatch, steps, dollars.
type Shape {
  Shape(
    tune: Int,
    validate: Int,
    k: Int,
    k_tune: Int,
    minibatch: Int,
    steps: Int,
    max_dollars: Float,
  )
}

/// The default shape: six tune tasks, twelve validate tasks, K = 3.
fn shape() -> Shape {
  Shape(
    tune: 6,
    validate: 12,
    k: 3,
    k_tune: 2,
    minibatch: 4,
    steps: 3,
    max_dollars: 1000.0,
  )
}

/// A search over the fixture catalogue with a seam-provided executor and
/// reflector, and a base that opens no session.
fn rig(
  name: String,
  seed: Arm,
  wanted: Shape,
  reflector: reflect.Reflector,
  execute: fn(trial.Context, run.Loaded, String) -> Result(run.Summary, String),
) -> Rig {
  let root = scripted.scratch(name)
  let base = scripted.base_unchecked(root <> "/base", scripted.transport(1))
  let assert Ok(#(identity, resolved)) =
    reflect.resolve(base.catalog, base.gateway, "fixture")
  let assert Ok(card) = gateway.card_for(base.gateway, "fixture")
  let trial_budgets =
    plan.Budgets(
      max_requests_per_trial: 4,
      max_dollars: 0.0,
      wall_ms_per_trial: 60_000,
      concurrency: 4,
    )
  let frozen =
    optimize.mint(optimize.Plan(
      id: "",
      seed:,
      objective: "Make the agent write the requested file.",
      tune: tasks_in("tune", split.Tune, wanted.tune),
      validate: tasks_in("validate", split.Validate, wanted.validate),
      trials_per_cell: wanted.k,
      tune_trials: wanted.k_tune,
      minibatch: wanted.minibatch,
      slots: [
        SystemSuffix(scripted.fixture_target()),
        TaskPrefix(scripted.fixture_target()),
      ],
      reflector: identity,
      budgets: optimize.Budgets(
        max_dollars: wanted.max_dollars,
        max_steps: wanted.steps,
        max_reflections: 100,
        max_candidates: 100,
      ),
      trial: trial_budgets,
      lane: plan.Live,
      profile: plan.Quick,
      split_salt: "salt",
      harness: plan.Harness(
        "0123456789abcdef0123456789abcdef01234567",
        plan.Clean,
      ),
    ))
  let assert Ok(_) = optimize.check(frozen)

  Rig(
    root:,
    ctx: optimize.Context(
      trial: trial.Context(
        base:,
        lane: trial.Live,
        budgets: trial_budgets,
        plan_id: "",
        seams: trial.default_seams(trial.refuse_program),
        repos: repos.empty(),
        selftest: trial.unprobed,
      ),
      seams: optimize.Seams(execute:, reflect: reflector),
      reflection_worst: reflect.worst_case(card, resolved),
      reflector_card: Some(card),
    ),
    plan: frozen,
    out: root <> "/searches",
  )
}

/// The same rig with its trials on a taped lane, which spends nothing.
fn taped(r: Rig) -> Rig {
  Rig(
    ..r,
    ctx: optimize.Context(
      ..r.ctx,
      trial: trial.Context(
        ..r.ctx.trial,
        lane: trial.Taped(open: fn(_key, _root) { Error("no tape") }),
      ),
    ),
  )
}

/// The same rig with another dollar ceiling, re-minted.
fn with_dollars(r: Rig, max_dollars: Float) -> Rig {
  Rig(
    ..r,
    plan: optimize.mint(
      optimize.Plan(
        ..r.plan,
        budgets: optimize.Budgets(..r.plan.budgets, max_dollars:),
      ),
    ),
  )
}

/// The runner may try a cell this many times, every attempt charged.
const attempts = 3.0

/// A cell's worst case: the per-trial worst case times the attempts.
fn cell_worst(r: Rig) -> Float {
  let assert Ok(w) = trial.worst_case(r.ctx.trial, scripted.baseline())
  assert w >. 0.0

  w *. attempts
}

/// The confirm run's reservation: seed and best on every validate cell.
fn confirm_hold(r: Rig) -> Float {
  cell_worst(r)
  *. 2.0
  *. int.to_float(list.length(r.plan.validate) * r.plan.trials_per_cell)
}

fn executor(
  config: scripted.Plant,
  fault: scripted.Fault,
) -> fn(trial.Context, run.Loaded, String) -> Result(run.Summary, String) {
  scripted.bernoulli_executor(config, fault, scripted.counter())
}

fn log_of(directory: String) -> List(search.Event) {
  let assert Ok(text) = simplifile.read(directory <> "/search.jsonl")
  let assert Ok(events) = search.parse(text)

  events
}

/// The verdict rows against a parent on the validate split.
fn validate_verdicts(events: List(search.Event)) -> List(search.Event) {
  let parents =
    list.filter_map(events, fn(event) {
      case event {
        search.Candidate(arm:, parent: Some(parent), ..) -> Ok(#(arm, parent))
        _ -> Error(Nil)
      }
    })

  list.filter(events, fn(event) {
    case event {
      search.Judgement(arm:, against:, split: split.Validate, ..) ->
        list.contains(parents, #(arm, against))
      _ -> False
    }
  })
}

fn is_improved(event: search.Event) -> Bool {
  case event {
    search.Judgement(verdict: verdict.Improved(..), ..) -> True
    _ -> False
  }
}

fn disposition_of(event: search.Event) -> search.Disposition {
  let assert search.Judgement(disposition:, ..) = event

  disposition
}

fn arm_file(directory: String, id: String) -> Result(Arm, String) {
  use text <- result.try(
    simplifile.read(directory <> "/arms/" <> id <> ".json")
    |> result.map_error(simplifile.describe_error),
  )
  use value <- result.try(
    json.parse(text) |> result.replace_error("not valid JSON"),
  )

  arm.decode(value)
}

/// The dollars every sub-run's ledger holds.
fn ledger_dollars(directory: String, events: List(search.Event)) -> Float {
  events
  |> list.filter_map(fn(event) {
    case event {
      search.Run(plan:, ..) -> Ok(plan)
      _ -> Error(Nil)
    }
  })
  |> list.map(fn(plan_id) {
    case simplifile.read(directory <> "/runs/" <> plan_id <> "/trials.jsonl") {
      Ok(text) -> {
        let assert Ok(rows) = ledger.parse(text)
        list.fold(rows, 0.0, fn(total, row) { total +. row.usage.dollars })
      }
      Error(_) -> 0.0
    }
  })
  |> list.fold(0.0, float.add)
}

pub fn a_planted_sentinel_is_found_and_confirmed_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    let r =
      rig(
        "plant",
        scripted.baseline(),
        shape(),
        scripted.scripted_reflector(planted_answers(), scripted.counter()),
        executor(scripted.plant(0.9, 0.1, "plant"), scripted.Never),
      )

    let assert Ok(outcome) = optimize.search(r.ctx, r.plan, r.out)
    let state = outcome.state
    let events = log_of(outcome.directory)

    // The incumbent carries the plant, became so at step 2, and the inert
    // step-1 child never did.
    let assert Ok(best) = arm_file(outcome.directory, state.incumbent)
    assert scripted.carries_sentinel(best)
    let verdicts = validate_verdicts(events)
    assert list.contains(list.map(verdicts, disposition_of), search.Incumbent)
    let assert [first, ..] =
      list.filter(state.members, fn(member) { member.step == 1 })
    assert !scripted.carries_sentinel(result.unwrap(
      arm_file(outcome.directory, first.arm),
      scripted.baseline(),
    ))
    assert first.disposition != Some(search.Incumbent)
      && first.disposition != Some(search.Joined)

    // The confirm run, the only simultaneous comparison, agrees.
    let assert Some(search.Confirmation(verdict: Some(verdict.Improved(..)), ..)) =
      state.confirmation
    assert state.stopped == Some(search.Steps)
    let assert Ok(markdown) = simplifile.read(outcome.directory <> "/front.md")
    assert string.starts_with(markdown, "Confirmed: ")
    assert string.contains(markdown, "| 1 | " <> string.slice(best.id, 0, 12))

    // Spend is the ledgers plus the priced reflections, counted once each.
    let assert Ok(front) = simplifile.read(outcome.directory <> "/front.json")
    let reflected =
      3.0 *. reflect.dollars(scripted.reflection_usage(), r.ctx.reflector_card)
    let expected = ledger_dollars(outcome.directory, events) +. reflected
    assert string.contains(front, "\"total\":" <> float.to_string(expected))
      || string.contains(
        front,
        "\"total\":" <> float.to_string(float.to_precision(expected, 6)),
      )

    // The proposal directory holds the payload the governed reader decodes,
    // and the program notes the confirm verdict.
    let assert Ok(payload) =
      simplifile.read(
        outcome.directory
        <> "/propose/"
        <> best.id
        <> "/fixture-fixture/prompt.json",
      )
    assert string.contains(payload, scripted.sentinel)
    let assert Ok(propose) = simplifile.read(outcome.directory <> "/PROPOSE.md")
    assert string.contains(propose, best.id)
    assert string.contains(propose, "): confirmed in the seed-and-best")

    // A report rebuilt from the directory renders the same front.
    let assert Ok(Nil) = optimize.report(outcome.directory)
    let assert Ok(after) = simplifile.read(outcome.directory <> "/front.md")
    assert markdown == after
    scripted.remove(r.root)
  })
}

/// The search-level A/A: fifty seeded searches of four steps over an agent
/// whose pass probability is one half whichever arm runs, with a reflector
/// that only re-spaces an inert sentence. About half the children pass the
/// screen and reach Validate; the paired rule may call at most six percent
/// of those verdicts `Improved` (the evalstat A/A bound, `alpha` both ways),
/// the incumbent can change only on an `Improved` verdict, never on a
/// screen alone, and the confirm run, which draws fresh trials, may read
/// `Confirmed` on at most three of the fifty. "Never an incumbent change"
/// is not a property any rule at `alpha` = 0.05 can promise, so the test
/// holds the rates, not the counts.
pub fn search_level_aa_rarely_improves_and_never_promotes_on_a_screen_test_() -> scripted.EunitTest {
  scripted.Timeout(600, fn() {
    let seeds = list.index_map(list.repeat(Nil, 50), fn(_, i) { i + 1 })
    let counted =
      list.map(seeds, fn(number) {
        let name = "aa-" <> int.to_string(number)
        let r =
          rig(
            name,
            scripted.baseline(),
            Shape(..shape(), validate: 8, steps: 4),
            scripted.inert_reflector(scripted.counter()),
            executor(scripted.plant(0.5, 0.5, name), scripted.Never),
          )

        let assert Ok(outcome) = optimize.search(r.ctx, r.plan, r.out)
        let verdicts = validate_verdicts(log_of(outcome.directory))
        let promoted =
          list.count(verdicts, fn(event) {
            disposition_of(event) == search.Incumbent
            || disposition_of(event) == search.Joined
          })
        let confirmed = case outcome.state.confirmation {
          Some(search.Confirmation(verdict: Some(verdict.Improved(..)), ..)) ->
            1
          _ -> 0
        }

        // A child joins the pool above its parent only on an Improved verdict.
        assert promoted <= list.count(verdicts, is_improved)
        scripted.remove(r.root)

        #(
          list.length(verdicts),
          list.count(verdicts, is_improved),
          promoted,
          confirmed,
        )
      })
    let total = list.fold(counted, 0, fn(sum, each) { sum + each.0 })
    let improved = list.fold(counted, 0, fn(sum, each) { sum + each.1 })
    let promoted = list.fold(counted, 0, fn(sum, each) { sum + each.2 })
    let confirmed = list.fold(counted, 0, fn(sum, each) { sum + each.3 })

    assert total >= 50
    assert int.to_float(improved) <=. 0.06 *. int.to_float(total)
    assert promoted <= improved
    assert confirmed <= 3
  })
}

pub fn an_interrupted_search_resumes_byte_identically_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    // The executor dies on its second call: the seed's Validate run is the
    // first, step 1's parent minibatch the second, after its ledger is written.
    let config = scripted.plant(0.9, 0.1, "resume")
    let r =
      rig(
        "resume",
        scripted.baseline(),
        Shape(..shape(), steps: 2),
        scripted.scripted_reflector(planted_answers(), scripted.counter()),
        executor(config, scripted.KilledAfter(call: 2, rows: 1_000_000)),
      )
    let assert Error(reason) = optimize.search(r.ctx, r.plan, r.out)
    assert string.contains(reason, "killed")
    let directory = r.out <> "/" <> r.plan.id
    let assert Ok(prefix) = simplifile.read(directory <> "/search.jsonl")
    assert list.length(log_of(directory)) == 3

    // The same command again, with an executor that never dies.
    let fresh_seams = fn() {
      optimize.Seams(
        execute: executor(config, scripted.Never),
        reflect: scripted.scripted_reflector(
          planted_answers(),
          scripted.counter(),
        ),
      )
    }
    let resumed = optimize.Context(..r.ctx, seams: fresh_seams())
    let assert Ok(outcome) = optimize.search(resumed, r.plan, r.out)
    let assert Ok(whole) = simplifile.read(directory <> "/search.jsonl")
    assert string.starts_with(whole, prefix)

    // An uninterrupted search with the same plan writes the same log, and
    // no sub-plan id repeats.
    let other_root = scripted.scratch("resume-fresh")
    let untouched = optimize.Context(..r.ctx, seams: fresh_seams())
    let assert Ok(other) =
      optimize.search(untouched, r.plan, other_root <> "/searches")
    let assert Ok(again) = simplifile.read(other.directory <> "/search.jsonl")
    assert again == whole
    let plans =
      list.filter_map(log_of(directory), fn(event) {
        case event {
          search.Run(plan:, ..) -> Ok(plan)
          _ -> Error(Nil)
        }
      })
    assert list.length(plans) == list.length(list.unique(plans))
    assert outcome.state.stopped == Some(search.Steps)
    scripted.remove(r.root)
    scripted.remove(other_root)
  })
}

pub fn a_crash_before_the_run_directory_exists_still_resumes_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    // The Run row is appended before the executor runs; a kill in that
    // window leaves a row naming a directory that was never written.
    let config = scripted.plant(0.9, 0.1, "window")
    let r =
      rig(
        "window",
        scripted.baseline(),
        Shape(..shape(), steps: 1),
        scripted.scripted_reflector(planted_answers(), scripted.counter()),
        executor(config, scripted.KilledAfter(call: 2, rows: 0)),
      )
    let assert Error(reason) = optimize.search(r.ctx, r.plan, r.out)
    assert string.contains(reason, "before writing anything")
    let directory = r.out <> "/" <> r.plan.id
    let assert [_, _, search.Run(plan: minibatch, ..)] = log_of(directory)
    assert simplifile.is_file(
        directory <> "/runs/" <> minibatch <> "/plan.json",
      )
      == Ok(False)

    // Resume rebuilds the sub-plan from the row's cap and runs it.
    let resumed =
      optimize.Context(
        ..r.ctx,
        seams: optimize.Seams(
          execute: executor(config, scripted.Never),
          reflect: scripted.scripted_reflector(
            planted_answers(),
            scripted.counter(),
          ),
        ),
      )
    let assert Ok(outcome) = optimize.search(resumed, r.plan, r.out)
    assert simplifile.is_file(
        directory <> "/runs/" <> minibatch <> "/plan.json",
      )
      == Ok(True)
    assert outcome.state.stopped == Some(search.Steps)
    scripted.remove(r.root)
  })
}

pub fn a_resumed_sub_run_cannot_spend_past_the_search_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    // Ten dollars; thirty-six validate cells at thirty cents each would be
    // $10.80. The executor is killed after thirty rows ($9).
    let config = scripted.Plant(..scripted.plant(0.5, 0.5, "cap"), price: 0.3)
    let base =
      rig(
        "cap",
        scripted.baseline(),
        Shape(..shape(), steps: 1, max_dollars: 10.0),
        scripted.scripted_reflector(planted_answers(), scripted.counter()),
        executor(config, scripted.KilledAfter(call: 1, rows: 30)),
      )

    // The confirm run is held back from the start, so the seed's own cap
    // is the search's ceiling less that hold: ten dollars here.
    let r = with_dollars(base, confirm_hold(base) +. 10.0)
    let assert Error(_) = optimize.search(r.ctx, r.plan, r.out)
    let directory = r.out <> "/" <> r.plan.id
    assert scripted.dollars_close(
      ledger_dollars(directory, log_of(directory)),
      9.0,
    )

    // On resume the sub-run's account is what the search has left, not the
    // $10 the plan was written with, so three more rows fit, not six.
    let resumed =
      optimize.Context(
        ..r.ctx,
        seams: optimize.Seams(
          execute: executor(config, scripted.Never),
          reflect: scripted.scripted_reflector(
            planted_answers(),
            scripted.counter(),
          ),
        ),
      )
    let assert Ok(outcome) = optimize.search(resumed, r.plan, r.out)
    let total = ledger_dollars(directory, log_of(directory))
    assert total <=. 10.0
    assert scripted.dollars_close(total, 9.9)
    assert outcome.state.stopped == Some(search.Dollars)
    scripted.remove(r.root)
  })
}

pub fn reflections_are_metered_on_a_taped_lane_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    // Taped trials cost nothing, so only the reflector spends: its worst
    // case is reserved before each step and its actual cost charged after.
    let base =
      rig(
        "taped",
        scripted.baseline(),
        Shape(..shape(), steps: 6),
        scripted.scripted_reflector(planted_answers(), scripted.counter()),
        executor(scripted.plant(0.9, 0.1, "taped"), scripted.Never),
      )
      |> taped
    let worst = base.ctx.reflection_worst
    let actual =
      reflect.dollars(scripted.reflection_usage(), base.ctx.reflector_card)
    assert worst >. actual && actual >. 0.0
    let r = with_dollars(base, worst +. 1.5 *. actual)

    // Two reflections fit before the third's worst case does not.
    let assert Ok(outcome) = optimize.search(r.ctx, r.plan, r.out)
    assert outcome.state.reflections == 2
    assert outcome.state.stopped == Some(search.Dollars)
    assert outcome.state.reflection_dollars <=. r.plan.budgets.max_dollars
    scripted.remove(r.root)
  })
}

pub fn a_failed_reflection_is_charged_and_refused_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    let r =
      rig(
        "failing",
        scripted.baseline(),
        Shape(..shape(), steps: 2),
        scripted.failing_reflector("timed out"),
        executor(scripted.plant(0.9, 0.1, "failing"), scripted.Never),
      )
    let assert Ok(outcome) = optimize.search(r.ctx, r.plan, r.out)
    let refusals =
      list.filter_map(log_of(outcome.directory), fn(event) {
        case event {
          search.Refusal(reason:, ..) -> Ok(reason)
          _ -> Error(Nil)
        }
      })

    // Both steps failed to reflect, both were billed, nothing joined.
    assert list.length(refusals) == 2
    assert list.all(refusals, string.contains(_, "timed out"))
    assert outcome.state.reflections == 2
    assert scripted.dollars_close(
      outcome.state.reflection_dollars,
      2.0 *. reflect.dollars(scripted.reflection_usage(), r.ctx.reflector_card),
    )
    assert outcome.state.pool == [scripted.baseline().id]
    scripted.remove(r.root)
  })
}

pub fn a_confirm_run_can_fail_the_search_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    // The plant holds only in a one-arm sub-plan: the child wins its own
    // Validate run and loses its edge beside the seed.
    let config =
      scripted.Plant(
        ..scripted.plant(0.9, 0.1, "fickle"),
        scope: scripted.SingleArmOnly,
      )
    let r =
      rig(
        "fickle",
        scripted.baseline(),
        shape(),
        scripted.scripted_reflector(planted_answers(), scripted.counter()),
        executor(config, scripted.Never),
      )
    let assert Ok(outcome) = optimize.search(r.ctx, r.plan, r.out)
    let assert Ok(best) = arm_file(outcome.directory, outcome.state.incumbent)
    assert scripted.carries_sentinel(best)

    // Not confirmed, said so in the headline and the proposal note; the
    // payload is still written, since the validate rows did improve.
    let assert Some(search.Confirmation(verdict: Some(found), ..)) =
      outcome.state.confirmation
    assert !is_improved(search.Judgement(
      best.id,
      scripted.baseline().id,
      split.Validate,
      found,
      search.Unconfirmed,
    ))
    let assert Ok(markdown) = simplifile.read(outcome.directory <> "/front.md")
    assert string.starts_with(markdown, "Not confirmed: ")
    let assert Ok(propose) = simplifile.read(outcome.directory <> "/PROPOSE.md")
    assert string.contains(propose, "): NOT confirmed")
    assert simplifile.is_directory(outcome.directory <> "/propose/" <> best.id)
      == Ok(True)
    scripted.remove(r.root)
  })
}

pub fn the_confirm_run_is_reserved_before_a_step_is_taken_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    // Rows cost exactly the per-trial worst case, so spend equals the
    // reservation: a budget of the seed run, one step and the confirm run
    // (plus a cent) takes exactly one step and still pays for the confirm.
    let base =
      rig(
        "reserve",
        scripted.baseline(),
        Shape(..shape(), steps: 5),
        scripted.scripted_reflector([scripted.sentinel], scripted.counter()),
        executor(scripted.plant(0.9, 0.1, "reserve"), scripted.Never),
      )
    let w = cell_worst(base) /. attempts
    let cells = fn(tasks: Int, k: Int) { int.to_float(tasks * k) }
    let seed_run = w *. cells(12, 3)
    let step =
      cell_worst(base)
      *. { 2.0 *. cells(4, 2) +. cells(12, 3) }
      +. base.ctx.reflection_worst
    let confirm = confirm_hold(base)
    let config = scripted.Plant(..scripted.plant(0.9, 0.1, "reserve"), price: w)
    let r =
      Rig(
        ..with_dollars(base, seed_run +. step +. confirm +. 0.01),
        ctx: optimize.Context(
          ..base.ctx,
          seams: optimize.Seams(
            ..base.ctx.seams,
            execute: executor(config, scripted.Never),
          ),
        ),
      )

    let assert Ok(outcome) = optimize.search(r.ctx, r.plan, r.out)
    assert outcome.state.step == 1
    assert outcome.state.stopped == Some(search.Dollars)
    let assert Some(search.Confirmation(verdict: Some(_), ..)) =
      outcome.state.confirmation
    let assert Ok(markdown) = simplifile.read(outcome.directory <> "/front.md")
    assert !string.contains(markdown, "(budget)")
    scripted.remove(r.root)
  })
}

pub fn an_unaffordable_reflection_stops_cleanly_and_resumes_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    // An executor that ignores its cap stands in for a run whose worst case
    // was underestimated: the parent's minibatch overspends so far that the
    // reflection's worst case is no longer covered when its turn comes.
    let base =
      rig(
        "skipped",
        scripted.baseline(),
        Shape(..shape(), steps: 3),
        scripted.scripted_reflector(planted_answers(), scripted.counter()),
        executor(scripted.plant(0.9, 0.1, "skipped"), scripted.Never),
      )
    let w = cell_worst(base) /. attempts
    let price = 50.0 *. w
    let step_need =
      cell_worst(base) *. int.to_float(2 * 8 + 36) +. base.ctx.reflection_worst
    let budget = 36.0 *. price +. step_need +. confirm_hold(base) +. 0.001
    let config =
      scripted.Plant(
        ..scripted.plant(0.9, 0.1, "skipped"),
        price:,
        cap: scripted.Ignored,
      )
    let r =
      Rig(
        ..with_dollars(base, budget),
        ctx: optimize.Context(
          ..base.ctx,
          seams: optimize.Seams(
            ..base.ctx.seams,
            execute: executor(config, scripted.Never),
          ),
        ),
      )

    let assert Ok(outcome) = optimize.search(r.ctx, r.plan, r.out)
    let events = log_of(outcome.directory)

    // The skipped call is a zero-dollar reflection row and a refusal naming
    // the budget; the search then stops for dollars with a log that replays.
    let assert [search.Reflection(dollars: 0.0, output_digest:, ..)] =
      list.filter(events, fn(event) {
        case event {
          search.Reflection(..) -> True
          _ -> False
        }
      })
    assert output_digest == reflect.digest("")
    let assert [search.Refusal(arm: "", reason:, ..)] =
      list.filter(events, fn(event) {
        case event {
          search.Refusal(..) -> True
          _ -> False
        }
      })
    assert string.starts_with(reason, "budget:")
    assert outcome.state.stopped == Some(search.Dollars)
    assert outcome.state.step == 1
    let assert Ok(Nil) = optimize.report(outcome.directory)
    let assert Ok(again) = optimize.search(r.ctx, r.plan, r.out)
    assert again.state == outcome.state
    scripted.remove(r.root)
  })
}

pub fn retrying_cells_cannot_spend_the_confirm_reservation_test_() -> scripted.EunitTest {
  scripted.Timeout(300, fn() {
    // Minibatch cells retry three times at twice the per-trial worst case,
    // so each minibatch costs twice its reservation. The holds truncate the
    // minibatches instead of letting them eat the confirm run's money: the
    // validate run completes, the child is accepted, and the confirm runs.
    let base =
      rig(
        "retry",
        scripted.baseline(),
        Shape(..shape(), steps: 5),
        scripted.scripted_reflector([scripted.sentinel], scripted.counter()),
        executor(scripted.plant(0.9, 0.1, "retry"), scripted.Never),
      )
    let w = cell_worst(base) /. attempts
    let config =
      scripted.Plant(
        ..scripted.plant(0.9, 0.1, "retry"),
        price: 2.0 *. w,
        retrying: scripted.TuneCells(3),
      )
    let r =
      Rig(
        ..with_dollars(base, 450.0 *. w),
        ctx: optimize.Context(
          ..base.ctx,
          seams: optimize.Seams(
            ..base.ctx.seams,
            execute: executor(config, scripted.Never),
          ),
        ),
      )

    let assert Ok(outcome) = optimize.search(r.ctx, r.plan, r.out)
    assert outcome.state.step == 1
    assert outcome.state.incumbent != scripted.baseline().id
    let assert Some(search.Confirmation(verdict: Some(found), ..)) =
      outcome.state.confirmation
    assert is_improved(search.Judgement(
      outcome.state.incumbent,
      scripted.baseline().id,
      split.Validate,
      found,
      search.Confirmed,
    ))
    scripted.remove(r.root)
  })
}

pub fn refused_answers_and_inapplicable_children_cost_nothing_test_() -> scripted.EunitTest {
  scripted.Timeout(120, fn() {
    let calls = scripted.counter()
    let base =
      rig(
        "refused",
        scripted.baseline(),
        Shape(..shape(), tune: 4, validate: 6, k: 2, k_tune: 1, minibatch: 2),
        scripted.scripted_reflector(
          ["", "[[record]] smuggled", "fine text"],
          scripted.counter(),
        ),
        scripted.bernoulli_executor(
          scripted.plant(0.5, 0.5, "refused"),
          scripted.Never,
          calls,
        ),
      )

    // The third slot aims at a model the catalogue lacks, so the third
    // step's child mints but cannot be applied.
    let frozen =
      optimize.mint(
        optimize.Plan(..base.plan, slots: [
          SystemSuffix(scripted.fixture_target()),
          TaskPrefix(scripted.fixture_target()),
          SystemSuffix(Target("absent", "absent", "anthropic-messages", Any)),
        ]),
      )
    let assert Ok(outcome) = optimize.search(base.ctx, frozen, base.out)
    let refusals =
      list.filter_map(log_of(outcome.directory), fn(event) {
        case event {
          search.Refusal(arm:, reason:, ..) -> Ok(#(arm, reason))
          _ -> Error(Nil)
        }
      })

    let assert [first, second, third] = refusals
    assert first.0 == "" && string.contains(first.1, "answered nothing")
    assert second.0 == "" && string.contains(second.1, "frame token")
    assert third.0 != "" && string.contains(third.1, "catalogue holds no model")

    // Three steps, three parent minibatches, no child ever ran: the seed's
    // Validate run plus three runs, and the pool is still the seed.
    assert scripted.count(calls) == 4
    assert outcome.state.pool == [scripted.baseline().id]
    assert outcome.state.confirmation == None
    let assert Ok(propose) = simplifile.read(outcome.directory <> "/PROPOSE.md")
    assert string.contains(propose, "nothing to propose")
    assert simplifile.is_directory(outcome.directory <> "/propose") == Ok(False)
    scripted.remove(base.root)
  })
}

pub fn the_search_stops_for_dollars_it_cannot_cover_test_() -> scripted.EunitTest {
  scripted.Timeout(120, fn() {
    let r =
      rig(
        "dollars",
        scripted.baseline(),
        Shape(
          tune: 4,
          validate: 6,
          k: 2,
          k_tune: 1,
          minibatch: 2,
          steps: 5,
          max_dollars: 1.0,
        ),
        scripted.scripted_reflector(planted_answers(), scripted.counter()),
        executor(scripted.plant(0.9, 0.1, "dollars"), scripted.Never),
      )

    let assert Ok(outcome) = optimize.search(r.ctx, r.plan, r.out)

    // One dollar covers the seed's run only as far as the executor lets it;
    // the first step's worst case does not fit, so no step is taken.
    assert outcome.state.stopped == Some(search.Dollars)
    assert outcome.state.step == 0
    let assert Ok(markdown) = simplifile.read(outcome.directory <> "/front.md")
    assert string.starts_with(markdown, "No candidate improved on the seed")
    assert string.contains(markdown, "stopped: dollars")
    scripted.remove(r.root)
  })
}

pub fn the_search_plan_round_trips_loads_and_refuses_the_holdout_test_() -> scripted.EunitTest {
  scripted.Timeout(60, fn() {
    let r =
      rig(
        "codec",
        scripted.suffixed(),
        Shape(
          tune: 3,
          validate: 4,
          k: 2,
          k_tune: 1,
          minibatch: 2,
          steps: 1,
          max_dollars: 10.0,
        ),
        scripted.scripted_reflector(planted_answers(), scripted.counter()),
        executor(scripted.plant(0.9, 0.1, "codec"), scripted.Never),
      )
    let tasks = list.append(r.plan.tune, r.plan.validate)

    assert optimize.decode(optimize.to_json(r.plan), tasks) == Ok(r.plan)
    let assert Error(reason) = optimize.decode(optimize.to_json(r.plan), [])
    assert string.contains(reason, "was not loaded")

    // A task the salt assigns to the holdout is refused however it arrives.
    let holdout =
      list.index_map(list.repeat(Nil, 200), fn(_, i) {
        scripted.planted_task("h-" <> int.to_string(i))
      })
      |> list.find(fn(each) {
        split.assign("salt", split.family(each)) == split.Holdout
      })
    let assert Ok(holdout) = holdout
    let assert Error(sealed) =
      optimize.check(optimize.Plan(..r.plan, tune: [holdout, ..r.plan.tune]))
    assert string.contains(sealed, "holdout")

    // So is a task listed under the other split than the salt assigns.
    let assert Error(swapped) =
      optimize.check(
        optimize.Plan(..r.plan, tune: r.plan.validate, validate: r.plan.tune),
      )
    assert string.contains(swapped, "does not assign")

    // A directory the search wrote loads back to the plan it ran.
    let assert Ok(outcome) = optimize.search(r.ctx, r.plan, r.out)
    let assert Ok(loaded) = optimize.load(outcome.directory)
    assert loaded == r.plan
    scripted.remove(r.root)
  })
}

// --- the real session -------------------------------------------------------------

/// A gateway over a transport, for the reflector's own wire.
fn gateway_over(transport: Transport) -> gateway.Gateway {
  catalog.gateway(
    scripted.catalogue(),
    transport:,
    secrets: secret.from_list([#("FIXTURE_KEY", "fixture-key")]),
    clock: clock.from_function(bootstrap.system_time_ms),
  )
}

pub fn a_planted_sentinel_is_found_through_real_sessions_test_() -> scripted.EunitTest {
  scripted.Timeout(1500, fn() {
    scripted.when_available(
      "a_planted_sentinel_is_found_through_real_sessions",
      fn() {
        let root = scripted.scratch("plant-live")
        let base =
          scripted.base(
            root <> "/base",
            scripted.planted_transport(
              1,
              scripted.Planted(0.85, 0.05, "live", root),
            ),
          )
        let reflections = scripted.counter()
        let reflector_wire =
          gateway_over(scripted.reflector_transport(
            planted_answers(),
            reflections,
            1,
          ))
        let assert Ok(#(identity, resolved)) =
          reflect.resolve(base.catalog, reflector_wire, "fixture")
        let assert Ok(card) = gateway.card_for(base.gateway, "fixture")
        let trial_budgets =
          plan.Budgets(
            max_requests_per_trial: 4,
            max_dollars: 0.0,
            wall_ms_per_trial: 60_000,
            concurrency: 4,
          )
        let frozen =
          optimize.mint(optimize.Plan(
            id: "",
            seed: scripted.baseline(),
            objective: "Make the agent write the requested file.",
            tune: tasks_in("tune", split.Tune, 6),
            validate: tasks_in("validate", split.Validate, 12),
            trials_per_cell: 3,
            tune_trials: 2,
            minibatch: 4,
            slots: [SystemSuffix(scripted.fixture_target())],
            reflector: identity,
            budgets: optimize.Budgets(
              max_dollars: 100_000.0,
              max_steps: 2,
              max_reflections: 10,
              max_candidates: 10,
            ),
            trial: trial_budgets,
            lane: plan.Live,
            profile: plan.Quick,
            split_salt: "salt",
            harness: plan.Harness(
              "0123456789abcdef0123456789abcdef01234567",
              plan.Clean,
            ),
          ))
        let ctx =
          optimize.Context(
            trial: trial.Context(
              base:,
              lane: trial.Live,
              budgets: trial_budgets,
              plan_id: "",
              seams: trial.default_seams(trial.refuse_program),
              repos: repos.empty(),
              selftest: trial.unprobed,
            ),
            seams: optimize.Seams(
              execute: run.execute,
              reflect: reflect.through_gateway(reflector_wire, resolved),
            ),
            reflection_worst: reflect.worst_case(card, resolved),
            reflector_card: Some(card),
          )

        let assert Ok(outcome) =
          optimize.search(ctx, frozen, root <> "/searches")
        let state = outcome.state

        // Two reflections went through the gateway; the second planted the
        // sentinel, which reached the agent's system text and was confirmed.
        assert scripted.count(reflections) == 2
        let assert Ok(best) = arm_file(outcome.directory, state.incumbent)
        assert scripted.carries_sentinel(best)
        let assert Some(search.Confirmation(
          verdict: Some(verdict.Improved(..)),
          ..,
        )) = state.confirmation
        let assert Ok(markdown) =
          simplifile.read(outcome.directory <> "/front.md")
        assert string.starts_with(markdown, "Confirmed: ")
        scripted.remove(root)
      },
    )
  })
}
