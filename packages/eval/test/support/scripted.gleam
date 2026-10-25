//// Test support: a scripted in-process provider and the small builders the
//// runner's tests share.
////
//// The provider is a `provider/http.Transport` that answers from memory, so
//// no socket is opened and no model is involved. It follows the request
//// body: a prompt carrying `WRITE[<path>=<content>]` is answered with one
//// `fs_write` tool call, the request that carries the tool result is answered
//// with a closing text, a prompt carrying `REFUSE` is answered with a
//// refusal stop, and a prompt carrying `STALL` is never answered. That
//// is enough to drive a real jailed session through a real tool call and
//// leave a file for the grader, which is everything the runner's lifecycle
//// needs and nothing about a model.
////
//// The transport honours the same contract as the replay lane's: a parked
//// weft task per request, released by the begin permit, its scope the drain
//// witness.
////
//// For the search's falsifiers the provider also has a planted objective
//// and noise. `planted_transport` honours the `WRITE` directive only with a
//// probability that depends on whether the request carries the sentinel
//// sentence, drawn from a generator seeded by the request body, so outcomes
//// are Bernoulli and reproducible per request. `reflector_transport` answers
//// a request that is a reflection prompt (it carries the record frame) with
//// the next scripted sentence, so a search can be driven to a planted
//// improvement without a model. `bernoulli_executor` is the same plant
//// without sessions: it writes a sub-run's ledger directly, for the
//// falsifiers that need fifty searches rather than one.

import client/catalog.{type Catalog}
import client/mcp
import client/serve.{type Settings}
import core/accounting
import core/json
import core/message
import eval/arm.{type Arm, type Target, Any, Arm, Knobs, SystemSuffix, Target}
import eval/ledger
import eval/normalise
import eval/plan.{type Plan, Budgets, Clean, Harness, Plan, Quick}
import eval/reflect as reflect_reply
import eval/run
import eval/run_cli
import eval/task.{type Task, ExpectedFiles, HandWritten, Inline, Task}
import eval/trial
import evalstat/prng
import gepa
import gleam/bit_array
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import provider/http.{type Transport}
import provider/model
import provider/pricing
import provider/secret
import simplifile
import weft
import weft/actor

/// The EUnit timeout wrapper: a generator named `*_test_` returning this is
/// run with the given number of seconds instead of the five a bare test gets.
pub type EunitTest {
  Timeout(seconds: Int, body: fn() -> Nil)
}

/// Whether this checkout has what a real session needs: the jail helper and
/// the offline code-mode seed. A test that needs them prints a skip line to
/// standard error and passes when they are absent.
pub fn available() -> Bool {
  result.is_ok(bootstrap.find_executable("../sandbox/loom-exec"))
  && result.is_ok(bootstrap.canonical_directory("../../build/codemode-seed"))
}

/// Runs `body` only when a real session can be opened here.
pub fn when_available(name: String, body: fn() -> Nil) -> Nil {
  case available() {
    True -> body()
    False -> echo_skip(name)
  }
}

fn echo_skip(name: String) -> Nil {
  io.println_error("SKIP " <> name <> ": the jail helper or seed is absent")
}

/// A fresh canonical directory under this package's `build/`, never `/tmp`.
pub fn scratch(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory() as "the test has a cwd"
  let path =
    here
    <> "/build/eval-test/"
    <> name
    <> "-"
    <> int.to_string(bootstrap.system_time_ms())
    <> "-"
    <> int.to_string(bootstrap.current_process_id())
  let assert Ok(Nil) = simplifile.create_directory_all(path)
    as "the scratch directory is creatable"
  let assert Ok(canonical) = bootstrap.canonical_directory(path)
    as "the scratch directory is canonical"

  canonical
}

/// The catalogue: one priced Anthropic-dialect model named `fixture`, and a
/// second named `fixture-b`, both routed to nothing real.
pub fn catalogue() -> Catalog {
  catalog.Catalog(
    models: [model_named("fixture"), model_named("fixture-b")],
    roles: [#(model.Main, ["fixture"])],
    profiles: [],
    mcp_servers: [],
    lsp_servers: [],
  )
}

fn model_named(name: String) -> catalog.CatalogModel {
  catalog.CatalogModel(
    name:,
    dialect: catalog.Anthropic,
    base_url: "http://fixture.invalid",
    api_key_env: "FIXTURE_KEY",
    model_id: name,
    context_window: 100_000,
    max_output_tokens: 4096,
    thinking: model.ThinkingOff,
    pricing: Some(pricing.Pricing(1.0, 1.0, 1.0, 1.0)),
    vision: catalog.TextOnly,
    max_images: 8,
    cyber_access: None,
    service_tier: None,
  )
}

/// The base session settings over a scripted transport, rooted at `root`.
pub fn base(root: String, transport: Transport) -> Settings {
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "the base workspace exists"
  let assert Ok(helper) = bootstrap.find_executable("../sandbox/loom-exec")
    as "the jail helper exists"
  let assert Ok(seed) =
    bootstrap.canonical_directory("../../build/codemode-seed")
    as "the seed exists"
  let assert Ok(settings) =
    run_cli.base_settings(
      catalogue(),
      transport,
      secret.from_list([#("FIXTURE_KEY", "fixture-key")]),
      root,
      helper,
      seed,
    )
    as "the base settings build"

  settings
}

/// A hand-written task that asks the scripted provider to write
/// `out.txt` with `written` and expects `expected`.
pub fn task_named(name: String, written: String, expected: String) -> Task {
  task.mint(Task(
    id: "",
    name:,
    prompt: "Make the file. " <> name <> " WRITE[out.txt=" <> written <> "]",
    workspace: Inline([#("seed.txt", "seed\n")]),
    verifier: ExpectedFiles([#("out.txt", expected)]),
    tags: ["kind:write"],
    provenance: HandWritten("test"),
  ))
}

/// A task whose agent is answered with a refusal.
pub fn refused_task() -> Task {
  task.mint(Task(
    id: "",
    name: "refused",
    prompt: "Make the file. REFUSE",
    workspace: Inline([#("seed.txt", "seed\n")]),
    verifier: ExpectedFiles([#("out.txt", "never")]),
    tags: [],
    provenance: HandWritten("test"),
  ))
}

/// A task whose agent never gets an answer.
pub fn stalled_task() -> Task {
  task.mint(Task(
    id: "",
    name: "stalled",
    prompt: "Make the file. STALL",
    workspace: Inline([#("seed.txt", "seed\n")]),
    verifier: ExpectedFiles([#("out.txt", "never")]),
    tags: [],
    provenance: HandWritten("test"),
  ))
}

/// The baseline arm: no components, no knobs.
pub fn baseline() -> Arm {
  let assert Ok(minted) =
    arm.mint(Arm(
      id: "",
      name: "baseline",
      components: [],
      knobs: Knobs(roles: [], thinking: [], disabled_tools: []),
    ))
    as "the baseline arm mints"

  minted
}

/// A candidate arm: the baseline plus a system suffix on the fixture model.
pub fn suffixed() -> Arm {
  let assert Ok(minted) =
    arm.mint(Arm(
      id: "",
      name: "suffixed",
      components: [
        #(
          SystemSuffix(Target("fixture", "fixture", "anthropic-messages", Any)),
          "Check your work.",
        ),
      ],
      knobs: Knobs(roles: [], thinking: [], disabled_tools: []),
    ))
    as "the suffixed arm mints"

  minted
}

/// A minted live-lane plan over the given tasks and arms.
pub fn plan_of(
  tasks: List(Task),
  arms: List(Arm),
  trials: Int,
  concurrency: Int,
  max_dollars: Float,
  wall_ms: Int,
) -> Plan {
  plan.mint(Plan(
    id: "",
    task_ids: list.map(tasks, fn(each) { each.id }),
    arm_ids: list.map(arms, fn(each) { each.id }),
    trials_per_cell: trials,
    lane: plan.Live,
    profile: Quick,
    split_salt: "salt",
    budgets: Budgets(
      max_requests_per_trial: 4,
      max_dollars:,
      wall_ms_per_trial: wall_ms,
      concurrency:,
    ),
    harness: Harness("0123456789abcdef0123456789abcdef01234567", Clean),
  ))
}

/// The scripted transport. `input_tokens` is the usage each response reports.
pub fn transport(input_tokens: Int) -> Transport {
  http.Transport(prepare_streaming: fn(request, events) {
    parked(events, fn() { respond(request.body, events, input_tokens, True) })
  })
}

/// The sentinel sentence the planted transport looks for in a request: an
/// agent that is told it writes the file, one that is not answers in text.
pub const sentinel = "Write the file the task names before answering."

/// Whether the scripted agent follows the task's `WRITE` directive.
pub type Compliance {
  /// Always: the original transport's behaviour.
  Compliant

  /// With probability `with` when the request carries the sentinel and
  /// `without` otherwise, drawn from a generator seeded by `seed` and the
  /// request body normalised under `root` (`eval/normalise.text`: the root
  /// and every timestamp stripped), so a request draws the same whichever
  /// scratch directory and minute the test ran in.
  Planted(with: Float, without: Float, seed: String, root: String)
}

/// The planted, noisy transport: `transport` whose `WRITE` compliance is
/// decided per request by `Planted`.
pub fn planted_transport(
  input_tokens: Int,
  compliance: Compliance,
) -> Transport {
  http.Transport(prepare_streaming: fn(request, events) {
    parked(events, fn() {
      respond(
        request.body,
        events,
        input_tokens,
        complies(compliance, request.body),
      )
    })
  })
}

/// Whether one request complies: the planted probability for its sentinel
/// state, against a unit draw seeded by the body.
fn complies(compliance: Compliance, body: String) -> Bool {
  case compliance {
    Compliant -> True
    Planted(with:, without:, seed:, root:) -> {
      let p = case string.contains(body, sentinel) {
        True -> with
        False -> without
      }
      let #(draw, _) =
        prng.unit(prng.from_string(
          seed <> "|" <> mcp.sha256_hex(normalise.text(body, root)),
        ))

      draw <. p
    }
  }
}

fn respond(
  body: String,
  events: process.Subject(http.HttpEvent),
  input_tokens: Int,
  compliant: Bool,
) -> Nil {
  case string.contains(body, "STALL") {
    True -> process.sleep_forever()
    False -> {
      process.send(
        events,
        http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
      )
      list.each(script(body, input_tokens, compliant), fn(piece) {
        process.send(events, http.ResponseChunk(bit_array.from_string(piece)))
      })
      process.send(events, http.ResponseEnd)
    }
  }
}

fn script(body: String, input_tokens: Int, compliant: Bool) -> List(String) {
  case
    string.contains(body, "REFUSE"),
    string.contains(body, "\"tool_result\"") || !compliant
  {
    True, _ ->
      transcript(
        text_block(),
        "text_delta",
        "text",
        json.String(""),
        "refusal",
        input_tokens,
      )
    False, True ->
      transcript(
        text_block(),
        "text_delta",
        "text",
        json.String("done"),
        "end_turn",
        input_tokens,
      )
    False, False -> {
      let #(path, content) = written_in(body)

      transcript(
        tool_block(),
        "input_json_delta",
        "partial_json",
        json.String(
          json.to_string(
            json.Object([
              #("path", json.String(path)),
              #("content", json.String(content)),
            ]),
          ),
        ),
        "tool_use",
        input_tokens,
      )
    }
  }
}

fn written_in(body: String) -> #(String, String) {
  case string.split(body, "WRITE[") {
    [_, rest, ..] ->
      case string.split(rest, "]") {
        [spec, ..] ->
          case string.split(spec, "=") {
            [path, content] -> #(path, content)
            _ -> #("out.txt", "")
          }
        [] -> #("out.txt", "")
      }
    _ -> #("out.txt", "")
  }
}

fn text_block() -> json.JsonValue {
  json.Object([#("type", json.String("text")), #("text", json.String(""))])
}

fn tool_block() -> json.JsonValue {
  json.Object([
    #("type", json.String("tool_use")),
    #("id", json.String("call-1")),
    #("name", json.String("fs_write")),
    #("input", json.Object([])),
  ])
}

fn event(name: String, fields: List(#(String, json.JsonValue))) -> String {
  "event: "
  <> name
  <> "\ndata: "
  <> json.to_string(json.Object(fields))
  <> "\n\n"
}

fn transcript(
  block: json.JsonValue,
  delta_type: String,
  delta_key: String,
  delta_value: json.JsonValue,
  reason: String,
  input_tokens: Int,
) -> List(String) {
  [
    event("message_start", [
      #("type", json.String("message_start")),
      #(
        "message",
        json.Object([
          #("id", json.String("scripted")),
          #("model", json.String("fixture")),
          #(
            "usage",
            json.Object([
              #("input_tokens", json.Int(input_tokens)),
              #("output_tokens", json.Int(0)),
            ]),
          ),
        ]),
      ),
    ]),
    event("content_block_start", [
      #("type", json.String("content_block_start")),
      #("index", json.Int(0)),
      #("content_block", block),
    ]),
    event("content_block_delta", [
      #("type", json.String("content_block_delta")),
      #("index", json.Int(0)),
      #(
        "delta",
        json.Object([
          #("type", json.String(delta_type)),
          #(delta_key, delta_value),
        ]),
      ),
    ]),
    event("content_block_stop", [
      #("type", json.String("content_block_stop")),
      #("index", json.Int(0)),
    ]),
    event("message_delta", [
      #("type", json.String("message_delta")),
      #("delta", json.Object([#("stop_reason", json.String(reason))])),
      #("usage", json.Object([#("output_tokens", json.Int(1))])),
    ]),
    event("message_stop", [#("type", json.String("message_stop"))]),
  ]
}

fn parked(
  events: process.Subject(http.HttpEvent),
  operation: fn() -> Nil,
) -> Result(http.PreparedRequest, String) {
  use consumer <- result.try(
    process.subject_owner(events)
    |> result.replace_error("the response consumer is not a live process"),
  )
  let ready = process.new_subject()
  let witnessed =
    weft.new_prepared([
      weft.managed(fn(_ledger) {
        let begin = process.new_subject()
        process.send(ready, begin)
        process.receive_forever(begin)
        operation()
        Ok(Nil)
      }),
    ])
    |> weft.on_failure(weft.CancelSiblings)
    |> weft.cancel_when_exits(consumer)
    |> weft.start_witnessed
  let watch = process.monitor(weft.witness_pid(witnessed))
  let readiness =
    process.new_selector()
    |> process.select_map(ready, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
  let publication = process.selector_receive(readiness, 5000)
  process.demonitor_process(watch)

  case publication {
    Ok(Ok(begin)) ->
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(
            owner: weft.witness_pid(witnessed),
            cancel: fn() { weft.cancel_witnessed(witnessed) },
          ),
          begin: fn() { process.send(begin, Nil) },
        ),
      )
    Ok(Error(Nil)) | Error(Nil) -> {
      weft.cancel_witnessed(witnessed)
      Error("the scripted provider could not park the request")
    }
  }
}

/// A shared counter, for seams that must remember across trial processes.
pub opaque type Counter {
  Counter(subject: process.Subject(CounterMessage))
}

pub type CounterMessage {
  Bump(reply: process.Subject(Int))
  Peek(reply: process.Subject(Int))
}

/// Starts a counter at zero.
pub fn counter() -> Counter {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(total, message) {
      case message {
        Bump(reply:) -> {
          process.send(reply, total + 1)
          actor.continue(total + 1)
        }
        Peek(reply:) -> {
          process.send(reply, total)
          actor.continue(total)
        }
      }
    })
    |> actor.start
    as "the counter starts"

  Counter(started.data)
}

/// Adds one and answers the new total.
pub fn bump(counter: Counter) -> Int {
  actor.call(counter.subject, waiting: 5000, sending: Bump)
}

/// The present total.
pub fn count(counter: Counter) -> Int {
  actor.call(counter.subject, waiting: 5000, sending: Peek)
}

// --- the search's scripted pieces -------------------------------------------------------

/// A transport that answers a reflection prompt (any request carrying the
/// record frame) with the next of `answers`, cycling through the last one,
/// and every other request as `transport` would. The count of reflection
/// requests served is the counter's.
pub fn reflector_transport(
  answers: List(String),
  served: Counter,
  input_tokens: Int,
) -> Transport {
  http.Transport(prepare_streaming: fn(request, events) {
    parked(events, fn() {
      case string.contains(request.body, "[[record]]") {
        True -> {
          let ordinal = bump(served)
          let answer =
            list.drop(answers, int.min(ordinal, list.length(answers)) - 1)
            |> list.first
            |> result.unwrap("")

          answer_text(events, answer, input_tokens)
        }
        False -> respond(request.body, events, input_tokens, True)
      }
    })
  })
}

/// Streams one text answer with an end-turn stop.
fn answer_text(
  events: process.Subject(http.HttpEvent),
  text: String,
  input_tokens: Int,
) -> Nil {
  process.send(
    events,
    http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
  )
  list.each(
    transcript(
      text_block(),
      "text_delta",
      "text",
      json.String(text),
      "end_turn",
      input_tokens,
    ),
    fn(piece) {
      process.send(events, http.ResponseChunk(bit_array.from_string(piece)))
    },
  )
  process.send(events, http.ResponseEnd)
}

/// Base settings over a transport without checking for the jail helper or
/// the seed, for tests that never open a session.
pub fn base_unchecked(root: String, transport: Transport) -> Settings {
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "the base workspace exists"
  let assert Ok(settings) =
    run_cli.base_settings(
      catalogue(),
      transport,
      secret.from_list([#("FIXTURE_KEY", "fixture-key")]),
      root,
      root <> "/no-helper",
      root <> "/no-seed",
    )
    as "the base settings build"

  settings
}

/// A hand-written task for the planted transport: the prompt asks for
/// `out.txt` with `name` and the grade expects it.
pub fn planted_task(name: String) -> Task {
  task_named(name, name, name)
}

/// `count` planted tasks named `<prefix>-<n>`.
pub fn planted_tasks(prefix: String, count: Int) -> List(Task) {
  list.index_map(list.repeat(Nil, count), fn(_, position) {
    planted_task(prefix <> "-" <> int.to_string(position))
  })
}

/// The target every fixture component is aimed at.
pub fn fixture_target() -> Target {
  Target("fixture", "fixture", "anthropic-messages", Any)
}

/// An arm with one system suffix on the fixture model.
pub fn arm_with_suffix(name: String, text: String) -> Arm {
  let assert Ok(minted) =
    arm.mint(Arm(
      id: "",
      name:,
      components: [#(SystemSuffix(fixture_target()), text)],
      knobs: Knobs(roles: [], thinking: [], disabled_tools: []),
    ))
    as "the suffixed arm mints"

  minted
}

/// Whether an arm carries the sentinel in any component.
pub fn carries_sentinel(candidate: Arm) -> Bool {
  list.any(candidate.components, fn(component) {
    string.contains(component.1, sentinel)
  })
}

/// Where the planted sentinel takes effect.
pub type Scope {
  /// In every sub-plan, the confirm run included.
  Everywhere

  /// Only in a one-arm sub-plan: the planted arm loses its edge the moment
  /// it runs beside the seed, so the confirm run must be able to fail.
  SingleArmOnly
}

/// The planted, noisy agent as the ledger-writing executor sees it.
pub type Plant {
  Plant(
    /// Pass probability of a cell whose arm carries the sentinel.
    with: Float,
    /// Pass probability otherwise.
    without: Float,
    /// The seed every draw is salted with.
    seed: String,
    /// What each written row costs, so a search's dollars can be driven.
    price: Float,
    /// Where the sentinel counts.
    scope: Scope,
    /// Which cells retry, and how often.
    retrying: Retrying,
    /// Whether the context's cap is honoured.
    cap: Cap,
  )
}

/// Which cells retry: a retrying cell writes `attempts - 1` infrastructure
/// rows before its scored one, each at the plant's price, the way the
/// runner charges a cell that faults and is tried again.
pub type Retrying {
  /// Every cell scores at its first attempt.
  Nowhere

  /// Cells of tasks whose name starts with `tune` retry; the validate and
  /// confirm cells do not.
  TuneCells(attempts: Int)
}

/// Whether the executor honours the context's `max_dollars`.
pub type Cap {
  /// As the runner's account would: no row past the cap.
  Honoured

  /// Every cell is written whatever the cap says, standing in for a run
  /// whose worst case was underestimated.
  Ignored
}

/// The default plant: a strong edge, a cent a row, everywhere, one attempt
/// per cell, the cap honoured.
pub fn plant(with: Float, without: Float, seed: String) -> Plant {
  Plant(
    with:,
    without:,
    seed:,
    price: 0.01,
    scope: Everywhere,
    retrying: Nowhere,
    cap: Honoured,
  )
}

/// How the scripted executor fails, if it does.
pub type Fault {
  /// It never fails.
  Never

  /// On the call numbered `call` it writes `rows` rows of the ledger and
  /// then fails; `rows` of zero fails before the run directory exists.
  KilledAfter(call: Int, rows: Int)
}

/// A sub-run executor that writes the ledger a planted, noisy agent would
/// have produced, without opening a session: each cell passes with
/// probability `with` when the arm carries the sentinel (within the plant's
/// scope) and `without` otherwise, drawn from a generator seeded by the
/// plant's seed, the plan, the task, the arm and the index, so a confirm
/// sub-plan draws fresh trials. It lays the run directory out as
/// `run.execute` does, keeps every row already in the ledger and writes
/// only the missing cells, and on a metered lane writes no row the
/// context's `max_dollars` would not cover at the plant's price, which is
/// what the runner's account would have refused. `fault` stands in for a
/// crash.
pub fn bernoulli_executor(
  config: Plant,
  fault: Fault,
  calls: Counter,
) -> fn(trial.Context, run.Loaded, String) -> Result(run.Summary, String) {
  fn(ctx: trial.Context, loaded: run.Loaded, out: String) {
    let ordinal = bump(calls)
    let directory = out <> "/" <> loaded.plan.id

    // A kill before any write leaves no directory; one after writes first.
    case fault {
      KilledAfter(call:, rows: 0) if call == ordinal ->
        Error("the executor was killed before writing anything")
      Never | KilledAfter(..) -> {
        write_run_directory(directory, loaded)
        let limit = case fault {
          KilledAfter(call:, rows:) if call == ordinal -> rows
          Never | KilledAfter(..) -> 1_000_000
        }
        let started =
          append_rows(ctx, loaded, directory <> "/trials.jsonl", config, limit)

        case fault {
          KilledAfter(call:, ..) if call == ordinal ->
            Error("the executor was killed after writing its ledger")
          Never | KilledAfter(..) ->
            Ok(run.Summary(
              directory:,
              started:,
              budget_note: None,
              futility_note: None,
            ))
        }
      }
    }
  }
}

/// The run directory as `run.execute` lays it out, idempotently.
fn write_run_directory(directory: String, loaded: run.Loaded) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(directory <> "/tasks")
    as "the run directory is creatable"
  let assert Ok(Nil) = simplifile.create_directory_all(directory <> "/arms")
    as "the run directory is creatable"
  let assert Ok(Nil) =
    simplifile.write(
      directory <> "/plan.json",
      json.to_string(plan.to_json(loaded.plan)),
    )
    as "the plan is writable"
  list.each(loaded.tasks, fn(each) {
    let assert Ok(Nil) =
      simplifile.write(
        directory <> "/tasks/" <> each.id <> ".json",
        json.to_string(task.to_json(each)),
      )
      as "the task copy is writable"
  })
  list.each(loaded.arms, fn(each) {
    let assert Ok(Nil) =
      simplifile.write(
        directory <> "/arms/" <> each.id <> ".json",
        json.to_string(arm.to_json(each)),
      )
      as "the arm copy is writable"
  })
}

/// Appends the rows of the cells the ledger lacks, at most `limit` of
/// them and never past the metered cap, and says how many it wrote.
fn append_rows(
  ctx: trial.Context,
  loaded: run.Loaded,
  path: String,
  config: Plant,
  limit: Int,
) -> Int {
  let existing = case simplifile.read(path) {
    Ok(text) -> {
      let assert Ok(rows) = ledger.parse(text) as "the ledger parses"
      rows
    }
    Error(_) -> []
  }
  let done =
    existing
    |> list.filter(fn(row) { row.state == ledger.Scored })
    |> list.map(fn(row) { #(row.task, row.arm, row.index) })
  let attempts_so_far = fn(key: plan.RowKey) {
    list.count(existing, fn(row) {
      #(row.task, row.arm, row.index) == #(key.task, key.arm, key.index)
    })
  }
  let attempts_of = fn(key: plan.RowKey) { attempts_for(loaded, key, config) }

  // The rows still owed: for each unscored cell, its remaining attempts,
  // infrastructure rows first and the scored one last.
  let missing =
    plan.rows(loaded.plan)
    |> list.filter(fn(key) {
      !list.contains(done, #(key.task, key.arm, key.index))
    })
    |> list.flat_map(fn(key) {
      list.index_map(
        list.repeat(Nil, attempts_of(key) - attempts_so_far(key)),
        fn(_, offset) { #(key, attempts_so_far(key) + offset + 1) },
      )
    })

  // A metered lane affords only what the cap covers. The cap alone, not the
  // cap less the ledger: the runner opens a fresh account on every call,
  // and this executor must spend the way the runner would.
  let affordable = case ctx.lane, config.cap {
    trial.Live, Honoured | trial.Recording(..), Honoured ->
      float.truncate(ctx.budgets.max_dollars /. config.price +. 0.000001)
      |> int.max(0)
    trial.Taped(..), _ | _, Ignored -> 1_000_000
  }
  let rows =
    missing
    |> list.take(int.min(limit, affordable))
    |> list.map(fn(owed) {
      bernoulli_row(ctx.plan_id, loaded, owed.0, owed.1, config)
    })
  let assert Ok(Nil) =
    simplifile.append(
      path,
      string.concat(list.map(rows, fn(row) { ledger.encode_line(row) <> "\n" })),
    )
    as "the ledger is appendable"

  list.length(rows)
}

/// How many attempts a cell takes under the plant.
fn attempts_for(loaded: run.Loaded, key: plan.RowKey, config: Plant) -> Int {
  let name =
    list.find(loaded.tasks, fn(each) { each.id == key.task })
    |> result.map(fn(each) { each.name })
    |> result.unwrap("")

  // Only the named cells retry.
  case config.retrying {
    Nowhere -> 1
    TuneCells(attempts:) ->
      case string.starts_with(name, "tune") {
        True -> attempts
        False -> 1
      }
  }
}

/// One row of the Bernoulli ledger: scored at the cell's last attempt,
/// infrastructure before it.
fn bernoulli_row(
  plan_id: String,
  loaded: run.Loaded,
  key: plan.RowKey,
  attempt: Int,
  config: Plant,
) -> ledger.Row {
  let carries =
    list.find(loaded.arms, fn(each) { each.id == key.arm })
    |> result.map(carries_sentinel)
    |> result.unwrap(False)

  // The plant's scope decides whether the sentinel counts in this sub-plan.
  let planted = case config.scope {
    Everywhere -> carries
    SingleArmOnly -> carries && list.length(loaded.arms) == 1
  }
  let p = case planted {
    True -> config.with
    False -> config.without
  }
  let #(draw, _) =
    prng.unit(prng.from_string(
      config.seed
      <> "|"
      <> loaded.plan.id
      <> "|"
      <> key.task
      <> "|"
      <> key.arm
      <> "|"
      <> int.to_string(key.index),
    ))
  let #(outcome, reward) = case draw <. p {
    True -> #(ledger.Passed, 1.0)
    False -> #(ledger.VerifierFailed, 0.0)
  }
  let priced =
    ledger.Row(
      ..trial.infra_row(plan_id, key, attempt, "retried"),
      usage: ledger.Usage(10, 1, 0, 0, config.price, ledger.Complete),
    )

  // Every attempt but the last is an infrastructure row that is charged.
  case attempt < attempts_for(loaded, key, config) {
    True -> priced
    False ->
      ledger.Row(
        ..priced,
        state: ledger.Scored,
        outcome: Some(outcome),
        reward:,
      )
  }
}

/// A reflector whose answers are scripted in order, the last one repeating,
/// each reported at a fixed usage.
pub fn scripted_reflector(
  answers: List(String),
  served: Counter,
) -> fn(String) -> Result(reflect_reply.Reply, reflect_reply.Refused) {
  fn(_prompt) {
    let ordinal = bump(served)
    let answer =
      list.drop(answers, int.min(ordinal, list.length(answers)) - 1)
      |> list.first
      |> result.unwrap("")

    Ok(reflect_reply.Reply(
      text: answer,
      usage: reflect_usage(),
      finish: gepa.Complete,
    ))
  }
}

/// A reflector whose every answer stopped at the output limit: the text
/// is the scripted one, the finish says the provider cut it.
pub fn truncating_reflector(
  answers: List(String),
  served: Counter,
) -> fn(String) -> Result(reflect_reply.Reply, reflect_reply.Refused) {
  fn(prompt) {
    use reply <- result.map(scripted_reflector(answers, served)(prompt))

    reflect_reply.Reply(..reply, finish: gepa.Truncated)
  }
}

/// The usage every scripted reflection reports: a thousand tokens in, a
/// hundred out, which the fixture card prices at a few thousandths.
fn reflect_usage() -> message.Usage {
  message.Usage(
    ..accounting.zero_usage(),
    input: 1000,
    output: 100,
    total_tokens: 1100,
  )
}

/// A reflector that only re-spaces an inert sentence, so each child differs
/// from the last in nothing the planted agent can see: the search-level A/A.
pub fn inert_reflector(
  served: Counter,
) -> fn(String) -> Result(reflect_reply.Reply, reflect_reply.Refused) {
  fn(_prompt) {
    let ordinal = bump(served)

    Ok(reflect_reply.Reply(
      text: "Keep" <> string.repeat(" ", ordinal) <> "going.",
      usage: reflect_usage(),
      finish: gepa.Complete,
    ))
  }
}

/// A reflector that never answers but is billed for the attempt all the
/// same, as a timed-out call is.
pub fn failing_reflector(
  reason: String,
) -> fn(String) -> Result(reflect_reply.Reply, reflect_reply.Refused) {
  fn(_prompt) { Error(reflect_reply.Refused(reason:, usage: reflect_usage())) }
}

/// The usage one scripted reflection reports, for a test's arithmetic.
pub fn reflection_usage() -> message.Usage {
  reflect_usage()
}

/// Removes a test's scratch root and everything under it.
pub fn remove(root: String) -> Nil {
  let _ = simplifile.delete(root)

  Nil
}

/// The spend a float carries, for assertions that compare money.
pub fn dollars_close(left: Float, right: Float) -> Bool {
  float.absolute_value(left -. right) <. 0.000001
}
