//// A model-based test of one machine's guests, driven over the pure decisions
//// `loom --vm` makes: `vm_spec.ensure_step`, `manifest_action`,
//// `effective_github`, `daemon_step` and `restart_refusal`.
////
//// The system under test is a `World`: the facts on disk and in the process
//// table that `vm_cli` would observe, as plain data. `ensure` and `up` are run
//// over it by applying the real decision functions to facts read from the world
//// and writing back what each step would write. A second, coarser account of
//// the same machine, the `Model`, is advanced by plain rules that do not call
//// the decision functions, so a decision that drifts from the rules fails the
//// check instead of agreeing with itself.
////
//// There are two guests (two workspaces), a daemon that is down, idle or busy,
//// a release build whose commit can change (`loom update`), and a manifest that
//// can lag it. The properties, by tag:
////
//// - `serving`: `ensure` answers `AlreadyServing` for a guest exactly when the
////   model says its process is alive, so it never claims a stopped guest and
////   never restarts a live one.
//// - `stale-boot`: a guest boots only against a manifest that matches the
////   running build, and a missing or lagging manifest is answered by
////   `NeedsSetup` first.
//// - `daemon-first`: `NeedsDaemon` is answered only when the guest has no
////   bundles, the deployment already exists and no daemon runs, and it changes
////   nothing.
//// - `refused`: a release build with a usable configuration never refuses.
//// - `github`: after any sequence, a guest that has booted records the last
////   `--github` choice made since its last `--fresh`, or the default.
////
//// The schedules are drawn from a fixed seed. `crash` leaves a stale pid
//// record in the real system; the world reads the process, not the record, so
//// the command checks that a dead process is never read as a live guest.

import client/vm_spec.{type GitHubAccess}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import qcheck
import statem

const seed = 2026

const version = "0.3.2"

// --- the machine -------------------------------------------------------------

type Life {
  Alive
  Dead
}

type Bundling {
  Bundled
  Unbundled
}

type Deployment {
  NotDeployed
  Deployed
}

// The daemon as the model sees it.
type Daemon {
  DaemonDown
  DaemonIdle
  DaemonBusy
}

type Table {
  HasTable
  NoTable
}

// The daemon as the world has it: it also knows whether it read the table.
type WorldDaemon {
  WorldDown
  WorldUp(sessions: Int, table: Table)
}

type WorldGuest {
  WorldGuest(life: Life, bundled: Bundling, github: Option(GitHubAccess))
}

type World {
  World(
    build: Int,
    manifest: Option(Int),
    deployed: Deployment,
    daemon: WorldDaemon,
    guests: List(WorldGuest),
  )
}

type ModelGuest {
  ModelGuest(life: Life, bundled: Bundling, explicit: Option(GitHubAccess))
}

type Model {
  Model(deployed: Deployment, daemon: Daemon, guests: List(ModelGuest))
}

type Command {
  // `loom vm setup` for the running build.
  Setup
  // `loom update`: the build's commit changes, the manifest does not.
  Update
  Ensure(guest: Int, given: Option(GitHubAccess))
  // `loom vm up --fresh` of a guest that has run before.
  UpFresh(guest: Int, given: Option(GitHubAccess))
  Down(guest: Int)
  // The guest's process dies and leaves its pid record.
  Crash(guest: Int)
  Rm(guest: Int)
  StartDaemon(sessions: Int)
  StopDaemon
}

fn commit_of(generation: Int) -> String {
  "commit" <> string.pad_start(int.to_string(generation), 4, "0")
}

fn manifest_at(generation: Int) -> vm_spec.Manifest {
  vm_spec.Manifest(
    revision: commit_of(generation),
    loom_vm: "/h/loom-vm",
    runner: "/h/runner",
    lib_dir: "/h/lib",
    firmware_dir: None,
    guest_root: "/h/root",
  )
}

fn start_world() -> World {
  World(
    build: 1,
    manifest: None,
    deployed: NotDeployed,
    daemon: WorldDown,
    guests: [
      WorldGuest(Dead, Unbundled, None),
      WorldGuest(Dead, Unbundled, None),
    ],
  )
}

fn start_model() -> Model {
  Model(NotDeployed, DaemonDown, [
    ModelGuest(Dead, Unbundled, None),
    ModelGuest(Dead, Unbundled, None),
  ])
}

// Replaces the guest at `index`.
fn set_at(items: List(a), index: Int, with replacement: a) -> List(a) {
  list.index_map(items, fn(item, at) {
    case at == index {
      True -> replacement
      False -> item
    }
  })
}

fn world_guest(world: World, index: Int) -> WorldGuest {
  case list.drop(world.guests, index) {
    [guest, ..] -> guest
    [] -> WorldGuest(Dead, Unbundled, None)
  }
}

fn model_guest(model: Model, index: Int) -> ModelGuest {
  case list.drop(model.guests, index) {
    [guest, ..] -> guest
    [] -> ModelGuest(Dead, Unbundled, None)
  }
}

// --- what the world shows ensure ---------------------------------------------

fn facts_of(world: World, index: Int) -> vm_spec.EnsureFacts {
  let guest = world_guest(world, index)
  let pid = case guest.life {
    Alive -> Some(100 + index)
    Dead -> None
  }
  vm_spec.EnsureFacts(
    name: "guest" <> int.to_string(index),
    state: vm_spec.guest_state(pid, vm_spec.Registered),
    manifest: Ok(manifest_decision(world)),
    enrolment: case guest.bundled, world.deployed {
      Unbundled, Deployed -> vm_spec.JoinsLedger
      _, _ -> vm_spec.NeedsNoDaemon
    },
    daemon: case world.daemon {
      WorldDown -> vm_spec.DaemonStopped
      WorldUp(..) -> vm_spec.DaemonRunning
    },
  )
}

fn manifest_decision(world: World) -> vm_spec.ManifestAction {
  vm_spec.manifest_action(
    option.map(world.manifest, manifest_at),
    version,
    commit_of(world.build),
    "/h/manifest.json",
  )
}

// What `up` does after a boot: mint the deployment when there was none, and
// deal with a daemon that started before it. Answers the world and whether the
// daemon asked for a restart.
fn after_boot(world: World, index: Int, github: GitHubAccess) -> World {
  let guest = WorldGuest(Alive, Bundled, Some(github))
  let world = World(..world, guests: set_at(world.guests, index, guest))

  // Only the guest that minted the deployment can leave a daemon without the
  // table; a join and a resume add nothing the daemon has not read.
  case world.deployed {
    Deployed -> world
    NotDeployed ->
      World(..world, deployed: Deployed, daemon: case world.daemon {
        WorldDown -> WorldDown
        WorldUp(sessions:, table:) ->
          case vm_spec.daemon_step(1, vm_spec.Counted(sessions)) {
            vm_spec.StopIt -> WorldDown
            vm_spec.LeaveAlone(_) -> WorldUp(sessions:, table:)
          }
      })
  }
}

// The refusal `ensure` ends with after a minting boot, from the same decision
// `vm_cli` takes, or Ok when no restart is needed.
fn restart_needed(before: World) -> Bool {
  case before.deployed, before.daemon {
    NotDeployed, WorldUp(sessions:, ..) ->
      case vm_spec.daemon_step(1, vm_spec.Counted(sessions)) {
        vm_spec.StopIt -> False
        vm_spec.LeaveAlone(outcome) ->
          case vm_spec.restart_refusal(outcome) {
            Ok(Nil) -> False
            Error(_) -> True
          }
      }
    _, _ -> False
  }
}

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

// Boots a guest through the `up` path, with the freshness the command has.
fn boot(
  world: World,
  index: Int,
  given: Option(GitHubAccess),
  freshness: vm_spec.Freshness,
) -> Result(World, statem.Violation) {
  // A guest boots only against a manifest that matches the running build.
  case world.manifest == Some(world.build) {
    False ->
      Error(violation("stale-boot", "booted against " <> describe_world(world)))
    True -> {
      let guest = world_guest(world, index)
      let github = vm_spec.effective_github(given, guest.github, freshness)
      Ok(after_boot(world, index, github))
    }
  }
}

fn execute(
  world: World,
  model: Model,
  command: Command,
) -> Result(World, statem.Violation) {
  case command {
    Setup -> Ok(World(..world, manifest: Some(world.build)))
    Update -> Ok(World(..world, build: world.build + 1))
    Ensure(index, given) -> execute_ensure(world, model, index, given)
    UpFresh(index, given) -> {
      // `up` runs setup itself for a manifest from another release.
      let world = case manifest_decision(world) {
        vm_spec.InstallRelease(_) -> World(..world, manifest: Some(world.build))
        vm_spec.UseManifest(_) | vm_spec.RefuseManifest(_) -> world
      }
      boot(world, index, given, vm_spec.Fresh)
    }
    Down(index) | Crash(index) -> {
      let guest = world_guest(world, index)
      Ok(
        World(
          ..world,
          guests: set_at(world.guests, index, WorldGuest(..guest, life: Dead)),
        ),
      )
    }
    Rm(index) ->
      Ok(
        World(
          ..world,
          guests: set_at(world.guests, index, WorldGuest(Dead, Unbundled, None)),
        ),
      )
    StartDaemon(sessions) ->
      Ok(
        World(
          ..world,
          daemon: WorldUp(sessions:, table: case world.deployed {
            Deployed -> HasTable
            NotDeployed -> NoTable
          }),
        ),
      )
    StopDaemon -> Ok(World(..world, daemon: WorldDown))
  }
}

fn execute_ensure(
  world: World,
  model: Model,
  index: Int,
  given: Option(GitHubAccess),
) -> Result(World, statem.Violation) {
  let step = vm_spec.ensure_step(facts_of(world, index))
  let serving = step == vm_spec.AlreadyServing
  let alive = model_guest(model, index).life == Alive

  case serving == alive, step {
    False, _ ->
      Error(violation(
        "serving",
        "ensure answered "
          <> string.inspect(step)
          <> " for a guest that is "
          <> string.inspect(model_guest(model, index).life),
      ))
    True, vm_spec.AlreadyServing -> Ok(world)
    True, vm_spec.NeedsDaemon -> {
      let guest = world_guest(world, index)
      case world.daemon, guest.bundled, world.deployed {
        WorldDown, Unbundled, Deployed -> Ok(world)
        _, _, _ ->
          Error(violation(
            "daemon-first",
            "NeedsDaemon with " <> describe_world(world),
          ))
      }
    }
    True, vm_spec.NeedsSetup -> {
      // Setup is for a manifest that is missing or lags the build.
      case world.manifest == Some(world.build) {
        True -> Error(violation("stale-boot", "setup for a current manifest"))
        False ->
          boot(
            World(..world, manifest: Some(world.build)),
            index,
            given,
            vm_spec.Resume,
          )
      }
    }
    True, vm_spec.Boot -> boot(world, index, given, vm_spec.Resume)
    True, vm_spec.Refuse(reason) -> Error(violation("refused", reason))
  }
}

// --- the model's own rules -----------------------------------------------------

fn next_model(model: Model, command: Command) -> Model {
  case command {
    Setup | Update | StartDaemon(_) | StopDaemon -> next_daemon(model, command)
    Ensure(index, given) -> next_ensure(model, index, given)
    UpFresh(index, given) ->
      with_guest(mint(model), index, ModelGuest(Alive, Bundled, given))
    Down(index) | Crash(index) -> {
      let guest = model_guest(model, index)
      with_guest(model, index, ModelGuest(..guest, life: Dead))
    }
    Rm(index) -> with_guest(model, index, ModelGuest(Dead, Unbundled, None))
  }
}

fn next_daemon(model: Model, command: Command) -> Model {
  case command {
    StartDaemon(0) -> Model(..model, daemon: DaemonIdle)
    StartDaemon(_) -> Model(..model, daemon: DaemonBusy)
    StopDaemon -> Model(..model, daemon: DaemonDown)
    _ -> model
  }
}

fn with_guest(model: Model, index: Int, guest: ModelGuest) -> Model {
  Model(..model, guests: set_at(model.guests, index, guest))
}

// A boot that finds no deployment makes one, and an idle daemon that started
// before it is stopped so the next launch reads the table; a busy one stays.
fn mint(model: Model) -> Model {
  case model.deployed, model.daemon {
    Deployed, _ -> model
    NotDeployed, DaemonIdle ->
      Model(..model, deployed: Deployed, daemon: DaemonDown)
    NotDeployed, _ -> Model(..model, deployed: Deployed)
  }
}

fn next_ensure(model: Model, index: Int, given: Option(GitHubAccess)) -> Model {
  let guest = model_guest(model, index)
  case guest.life, guest.bundled, model.deployed, model.daemon {
    // A serving guest is left as it is, whatever flag was given.
    Alive, _, _, _ -> model
    // Joining needs the daemon, and without it nothing happens.
    Dead, Unbundled, Deployed, DaemonDown -> model
    Dead, _, _, _ ->
      with_guest(
        mint(model),
        index,
        ModelGuest(Alive, Bundled, case given {
          Some(access) -> Some(access)
          None -> guest.explicit
        }),
      )
  }
}

fn precondition(model: Model, command: Command) -> statem.Admission {
  let admitted = case command {
    Setup | Update | Ensure(..) -> True
    UpFresh(index, _) -> {
      let guest = model_guest(model, index)
      guest.life == Dead && guest.bundled == Bundled
    }
    Down(index) | Crash(index) -> model_guest(model, index).life == Alive
    Rm(index) -> {
      let guest = model_guest(model, index)
      guest.life == Dead && guest.bundled == Bundled
    }
    StartDaemon(_) -> model.daemon == DaemonDown
    StopDaemon -> model.daemon != DaemonDown
  }
  case admitted {
    True -> statem.Admit
    False -> statem.Reject
  }
}

// Every guest that has booted records the last explicit choice since its last
// `--fresh`, or the default, which is what the model keeps for it.
fn finish(world: World, model: Model) -> Result(Nil, statem.Violation) {
  let checked =
    list.index_map(model.guests, fn(guest, index) {
      case guest.bundled {
        Unbundled ->
          case world_guest(world, index).github {
            None -> True
            Some(_) -> False
          }
        Bundled ->
          world_guest(world, index).github
          == Some(option.unwrap(guest.explicit, vm_spec.default_github))
      }
    })

  case list.all(checked, fn(ok) { ok }) {
    True -> Ok(Nil)
    False ->
      Error(violation(
        "github",
        "recorded access differs from the last explicit choice: "
          <> string.inspect(world.guests)
          <> " against "
          <> string.inspect(model.guests),
      ))
  }
}

// --- generation and description ---------------------------------------------------

fn access() -> qcheck.Generator(Option(GitHubAccess)) {
  qcheck.bounded_int(0, 3)
  |> qcheck.map(fn(n) {
    case n {
      0 -> None
      1 -> Some(vm_spec.GitHubFromGh)
      2 -> Some(vm_spec.GitHubFromEnv)
      _ -> Some(vm_spec.GitHubOff)
    }
  })
}

fn command(_model: Model) -> qcheck.Generator(Command) {
  let guest = qcheck.bounded_int(0, 1)
  qcheck.from_weighted_generators(#(2, qcheck.constant(Setup)), [
    #(2, qcheck.constant(Update)),
    #(
      30,
      qcheck.map2(guest, access(), fn(index, given) { Ensure(index, given) }),
    ),
    #(
      6,
      qcheck.map2(guest, access(), fn(index, given) { UpFresh(index, given) }),
    ),
    #(6, qcheck.map(guest, Down)),
    #(3, qcheck.map(guest, Crash)),
    #(3, qcheck.map(guest, Rm)),
    #(
      6,
      qcheck.bounded_int(0, 1)
        |> qcheck.map(fn(n) { StartDaemon(n * 2) }),
    ),
    #(4, qcheck.constant(StopDaemon)),
  ])
}

fn describe(command: Command) -> String {
  string.inspect(command)
}

fn describe_world(world: World) -> String {
  "manifest "
  <> string.inspect(world.manifest)
  <> " build "
  <> int.to_string(world.build)
}

fn spec() -> statem.Spec(Model, Command, World) {
  statem.Spec(
    initial: start_model(),
    command:,
    precondition:,
    next_model:,
    new_sut: start_world,
    execute:,
    finish:,
    teardown: fn(_) { Nil },
  )
}

pub fn guests_follow_the_model_test() {
  let config =
    statem.default_config(seed:)
    |> statem.with_test_count(300)
    |> statem.with_max_commands(40)

  case statem.check(spec(), config) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, describe)
  }
}

// --- scripted schedules through the same rules --------------------------------------

// Runs commands in order through `execute` and `next_model`, answering the
// world and the model, or the first violation.
fn replay(
  commands: List(Command),
) -> Result(#(World, Model), statem.Violation) {
  list.try_fold(commands, #(start_world(), start_model()), fn(state, command) {
    let #(world, model) = state
    case execute(world, model, command) {
      Ok(world) -> Ok(#(world, next_model(model, command)))
      Error(reason) -> Error(reason)
    }
  })
}

pub fn the_first_guest_with_an_idle_daemon_stops_it_test() {
  let assert Ok(#(world, _)) = replay([StartDaemon(0), Ensure(0, None)])
  assert world.daemon == WorldDown
  assert world.deployed == Deployed
}

pub fn the_first_guest_with_a_busy_daemon_leaves_it_and_needs_a_restart_test() {
  let assert Ok(#(world, _)) = replay([StartDaemon(2), Ensure(0, None)])
  assert world.daemon == WorldUp(2, NoTable)
  assert restart_needed(World(..start_world(), daemon: WorldUp(2, NoTable)))
}

pub fn a_second_guest_needs_the_daemon_and_changes_nothing_without_it_test() {
  // The first guest minted the deployment and its idle daemon was stopped, so
  // the second guest's join must ask for the daemon and write nothing.
  let assert Ok(#(before, _)) = replay([StartDaemon(0), Ensure(0, None)])
  let assert Ok(#(after, _)) =
    replay([StartDaemon(0), Ensure(0, None), Ensure(1, None)])
  assert after == before
}

pub fn a_second_guest_joins_once_the_daemon_runs_test() {
  let assert Ok(#(world, _)) =
    replay([
      StartDaemon(0),
      Ensure(0, None),
      StartDaemon(2),
      Ensure(1, Some(vm_spec.GitHubOff)),
    ])
  assert world_guest(world, 1).life == Alive
  assert world_guest(world, 1).github == Some(vm_spec.GitHubOff)
  assert world.daemon == WorldUp(2, HasTable)
}

pub fn a_new_build_sets_up_again_before_a_dead_guest_boots_test() {
  let assert Ok(#(world, _)) =
    replay([Ensure(0, None), Down(0), Update, Ensure(0, None)])
  assert world.manifest == Some(world.build)
  assert world.build == 2
}

pub fn a_resume_keeps_the_access_and_fresh_forgets_it_test() {
  let assert Ok(#(kept, _)) =
    replay([
      Ensure(0, Some(vm_spec.GitHubOff)),
      Down(0),
      Ensure(0, None),
    ])
  assert world_guest(kept, 0).github == Some(vm_spec.GitHubOff)

  let assert Ok(#(forgotten, _)) =
    replay([
      Ensure(0, Some(vm_spec.GitHubOff)),
      Down(0),
      UpFresh(0, None),
    ])
  assert world_guest(forgotten, 0).github == Some(vm_spec.GitHubFromGh)
}

pub fn a_crashed_guest_boots_again_not_serves_test() {
  let assert Ok(#(world, _)) =
    replay([Ensure(0, None), Crash(0), Ensure(0, None)])
  assert world_guest(world, 0).life == Alive
}
