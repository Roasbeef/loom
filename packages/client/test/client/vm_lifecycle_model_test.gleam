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
//// There are two guests (two workspaces), a daemon that is down, idle or busy
//// and that has or has not read the deployment, a release build whose commit
//// can change (`loom update`), a manifest that can lag it, a guest another loom
//// is booting, and an `ensure` whose boot fails after the deployment was
//// installed. The properties, by tag:
////
//// - `serving`: `ensure` answers `AlreadyServing` for a guest exactly when the
////   model says it serves, so it never claims a stopped or booting guest and
////   never restarts a live one.
//// - `starting`: a guest whose process is there and whose executor is not ready
////   is refused, never booted a second time and never called serving.
//// - `stale-boot`: a guest boots only against a manifest that matches the
////   running build once `bring_up`'s own setup has run.
//// - `daemon-first`: `NeedsDaemon` is answered only when the guest has no
////   bundles, the deployment already exists and no daemon runs, and it changes
////   nothing.
//// - `refused`: a release build refuses only a guest that is booting.
//// - `restart`: after an `ensure` that boots a guest, a running daemon that has
////   not read the deployment exists only together with the refusal that names
////   its restart. A failed first boot leaves such a daemon, and the retry must
////   find it.
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
import gleam/result
import gleam/string
import qcheck
import statem

const seed = 2026

const version = "0.3.2"

// --- the machine -------------------------------------------------------------

type Life {
  Alive
  Dead
  // Another loom started it: the process is there, the executor is not ready.
  Booting
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
  Model(
    deployed: Deployment,
    daemon: Daemon,
    table: Table,
    guests: List(ModelGuest),
  )
}

// Whether the boot an `ensure` starts reaches the guest's executor.
type BootOutcome {
  BootSucceeds
  // The deployment is installed and the files are staged, then the boot fails:
  // no token for the credential proxy, say.
  BootFails
}

type Command {
  // `loom vm setup` for the running build.
  Setup
  // `loom update`: the build's commit changes, the manifest does not.
  Update
  Ensure(guest: Int, given: Option(GitHubAccess), boot: BootOutcome)
  // `loom vm up --fresh` of a guest that has run before.
  UpFresh(guest: Int, given: Option(GitHubAccess))
  Down(guest: Int)
  // The guest's process dies and leaves its pid record.
  Crash(guest: Int)
  Rm(guest: Int)
  // Another loom begins booting a guest that has run before, and later ends.
  StartBoot(guest: Int)
  FinishBoot(guest: Int)
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
  Model(NotDeployed, DaemonDown, NoTable, [
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
    Alive | Booting -> Some(100 + index)
    Dead -> None
  }

  // The node is listed as soon as the guest starts, but the executor serves
  // only once its console says so, so a booting guest is not registered.
  let registration = case guest.life {
    Alive -> vm_spec.Registered
    Booting | Dead -> vm_spec.Unregistered
  }
  vm_spec.EnsureFacts(
    name: "guest" <> int.to_string(index),
    state: vm_spec.guest_state(pid, registration),
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

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

// What `restart_check` does for a guest the call booted that was not a join:
// a daemon that runs without the table is asked about by `daemon_step`, which
// stops an idle one, and any daemon left running without the table is refused
// with the sentence that names the restart. Answers the daemon after and the
// refusal.
fn restart_effect(daemon: WorldDaemon) -> #(WorldDaemon, Result(Nil, String)) {
  case daemon {
    WorldUp(sessions:, table: NoTable) ->
      case vm_spec.daemon_step(1, vm_spec.Counted(sessions)) {
        vm_spec.StopIt -> #(WorldDown, vm_spec.restart_refusal(vm_spec.Stopped))
        vm_spec.LeaveAlone(outcome) -> #(
          daemon,
          vm_spec.restart_refusal(outcome),
        )
      }
    WorldUp(table: HasTable, ..) | WorldDown -> #(daemon, Ok(Nil))
  }
}

// Makes the manifest current the way `bring_up` does before it boots: a
// missing or stale one is installed, a refused one is a violation.
fn current_manifest(world: World) -> Result(World, statem.Violation) {
  case manifest_decision(world) {
    vm_spec.InstallRelease(_) -> Ok(World(..world, manifest: Some(world.build)))
    vm_spec.UseManifest(_) -> Ok(world)
    vm_spec.RefuseManifest(reason) -> Error(violation("refused", reason))
  }
}

// Boots a guest through the `up` path, with the freshness the command has.
// `restart` says whether this call checks the daemon, which `ensure` does and
// `up --fresh` does not.
fn boot(
  world: World,
  index: Int,
  given: Option(GitHubAccess),
  freshness: vm_spec.Freshness,
  outcome: BootOutcome,
  restart: Restart,
) -> Result(World, statem.Violation) {
  use world <- result.try(current_manifest(world))

  // A guest boots only against a manifest that matches the running build.
  case world.manifest == Some(world.build) {
    False ->
      Error(violation("stale-boot", "booted against " <> describe_world(world)))
    True -> {
      let guest = world_guest(world, index)
      let github = vm_spec.effective_github(given, guest.github, freshness)
      let life = case outcome {
        BootSucceeds -> Alive
        BootFails -> Dead
      }
      let world =
        World(
          ..world,
          deployed: Deployed,
          guests: set_at(
            world.guests,
            index,
            WorldGuest(life, Bundled, Some(github)),
          ),
        )
      daemon_after_boot(world, outcome, restart)
    }
  }
}

// Whether a call checks the daemon after it boots.
type Restart {
  Checks
  Skips
}

// A failed boot never reaches the daemon check; a successful one does when the
// command is `ensure`, and the result must be a world in which a daemon without
// the table exists only with its refusal.
fn daemon_after_boot(
  world: World,
  outcome: BootOutcome,
  restart: Restart,
) -> Result(World, statem.Violation) {
  case outcome, restart {
    BootFails, _ | _, Skips -> Ok(world)
    BootSucceeds, Checks -> {
      let #(daemon, refusal) = restart_effect(world.daemon)
      let unread = case daemon {
        WorldUp(table: NoTable, ..) -> True
        WorldUp(table: HasTable, ..) | WorldDown -> False
      }

      // A daemon left without the table must have been refused.
      case unread, result.is_error(refusal) {
        True, False ->
          Error(violation(
            "restart",
            "a daemon without the table was left with no refusal",
          ))
        _, _ -> Ok(World(..world, daemon:))
      }
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
    Ensure(index, given, outcome) ->
      execute_ensure(world, model, index, given, outcome)
    UpFresh(index, given) ->
      boot(world, index, given, vm_spec.Fresh, BootSucceeds, Skips)
    Down(index) | Crash(index) -> Ok(set_life(world, index, Dead))
    Rm(index) ->
      Ok(
        World(
          ..world,
          guests: set_at(world.guests, index, WorldGuest(Dead, Unbundled, None)),
        ),
      )
    StartBoot(index) -> Ok(set_life(world, index, Booting))
    FinishBoot(index) -> Ok(set_life(world, index, Alive))
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

fn set_life(world: World, index: Int, life: Life) -> World {
  let guest = world_guest(world, index)
  World(
    ..world,
    guests: set_at(world.guests, index, WorldGuest(..guest, life:)),
  )
}

fn execute_ensure(
  world: World,
  model: Model,
  index: Int,
  given: Option(GitHubAccess),
  outcome: BootOutcome,
) -> Result(World, statem.Violation) {
  let step = vm_spec.ensure_step(facts_of(world, index))
  let life = model_guest(model, index).life
  let serving = step == vm_spec.AlreadyServing

  case serving == { life == Alive }, step, life {
    False, _, _ ->
      Error(violation(
        "serving",
        "ensure answered "
          <> string.inspect(step)
          <> " for a guest that is "
          <> string.inspect(life),
      ))
    True, vm_spec.AlreadyServing, _ -> Ok(world)
    True, vm_spec.Refuse(_), Booting -> Ok(world)
    True, vm_spec.Refuse(reason), _ -> Error(violation("refused", reason))
    True, _, Booting ->
      Error(violation("starting", "a booting guest was not refused"))
    True, vm_spec.NeedsDaemon, _ -> needs_daemon(world, index)
    True, vm_spec.Boot, _ -> {
      let guest = world_guest(world, index)

      // A join goes through the daemon and does not ask it to restart; a
      // daemon that never read the table cannot take it.
      case guest.bundled, world.deployed, world.daemon {
        Unbundled, Deployed, WorldUp(table: NoTable, ..) -> Ok(world)
        Unbundled, Deployed, _ ->
          boot(world, index, given, vm_spec.Resume, outcome, Skips)
        _, _, _ -> boot(world, index, given, vm_spec.Resume, outcome, Checks)
      }
    }
  }
}

fn needs_daemon(world: World, index: Int) -> Result(World, statem.Violation) {
  let guest = world_guest(world, index)

  // `NeedsDaemon` is for a join with no daemon, and writes nothing.
  case world.daemon, guest.bundled, world.deployed {
    WorldDown, Unbundled, Deployed -> Ok(world)
    _, _, _ ->
      Error(violation(
        "daemon-first",
        "NeedsDaemon with " <> describe_world(world),
      ))
  }
}

// --- the model's own rules -----------------------------------------------------

fn next_model(model: Model, command: Command) -> Model {
  case command {
    Setup | Update -> model
    StartDaemon(_) | StopDaemon -> next_daemon(model, command)
    Ensure(index, given, outcome) -> next_ensure(model, index, given, outcome)
    UpFresh(index, given) ->
      with_guest(
        Model(..model, deployed: Deployed),
        index,
        ModelGuest(Alive, Bundled, given),
      )
    Down(index) | Crash(index) -> with_life(model, index, Dead)
    Rm(index) -> with_guest(model, index, ModelGuest(Dead, Unbundled, None))
    StartBoot(index) -> with_life(model, index, Booting)
    FinishBoot(index) -> with_life(model, index, Alive)
  }
}

fn next_daemon(model: Model, command: Command) -> Model {
  case command {
    StartDaemon(0) -> Model(..model, daemon: DaemonIdle, table: table_of(model))
    StartDaemon(_) -> Model(..model, daemon: DaemonBusy, table: table_of(model))
    StopDaemon -> Model(..model, daemon: DaemonDown)
    _ -> model
  }
}

// A daemon started now reads the deployment if there is one.
fn table_of(model: Model) -> Table {
  case model.deployed {
    Deployed -> HasTable
    NotDeployed -> NoTable
  }
}

fn with_guest(model: Model, index: Int, guest: ModelGuest) -> Model {
  Model(..model, guests: set_at(model.guests, index, guest))
}

fn with_life(model: Model, index: Int, life: Life) -> Model {
  let guest = model_guest(model, index)
  with_guest(model, index, ModelGuest(..guest, life:))
}

// A boot that checks the daemon: an idle daemon that has not read the table is
// stopped so the next launch reads it, and a busy one stays.
fn daemon_checked(model: Model) -> Model {
  case model.daemon, model.table {
    DaemonIdle, NoTable -> Model(..model, daemon: DaemonDown)
    _, _ -> model
  }
}

fn next_ensure(
  model: Model,
  index: Int,
  given: Option(GitHubAccess),
  outcome: BootOutcome,
) -> Model {
  let guest = model_guest(model, index)
  let join = guest.bundled == Unbundled && model.deployed == Deployed
  let booted =
    ModelGuest(
      case outcome {
        BootSucceeds -> Alive
        BootFails -> Dead
      },
      Bundled,
      case given {
        Some(access) -> Some(access)
        None -> guest.explicit
      },
    )

  case guest.life, join, model.daemon, model.table {
    // A serving or booting guest is left as it is, whatever flag was given.
    Alive, _, _, _ | Booting, _, _, _ -> model
    // Joining needs a daemon that read the table; without one nothing happens.
    Dead, True, DaemonDown, _ | Dead, True, _, NoTable -> model
    // A join does not ask the daemon to restart.
    Dead, True, _, _ ->
      with_guest(Model(..model, deployed: Deployed), index, booted)
    Dead, False, _, _ ->
      case outcome {
        BootFails ->
          with_guest(Model(..model, deployed: Deployed), index, booted)
        BootSucceeds ->
          with_guest(
            daemon_checked(Model(..model, deployed: Deployed)),
            index,
            booted,
          )
      }
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
    StartBoot(index) -> {
      let guest = model_guest(model, index)
      guest.life == Dead && guest.bundled == Bundled
    }
    FinishBoot(index) -> model_guest(model, index).life == Booting
    StartDaemon(_) -> model.daemon == DaemonDown
    StopDaemon -> model.daemon != DaemonDown
  }
  case admitted {
    True -> statem.Admit
    False -> statem.Reject
  }
}

// Every guest that has booted records the last explicit choice since its last
// `--fresh`, or the default, which is what the model keeps for it. A daemon
// the model says has read the table is one the world says has.
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

  let daemon_agrees = case world.daemon, model.daemon {
    WorldDown, DaemonDown -> True
    WorldUp(0, table), DaemonIdle -> table == model.table
    WorldUp(_, table), DaemonBusy -> table == model.table
    _, _ -> False
  }

  case list.all(checked, fn(ok) { ok }), daemon_agrees {
    True, True -> Ok(Nil)
    _, _ ->
      Error(violation(
        "github",
        "the world differs from the model: "
          <> string.inspect(world)
          <> " against "
          <> string.inspect(model),
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

fn outcome() -> qcheck.Generator(BootOutcome) {
  qcheck.from_weighted_generators(#(4, qcheck.constant(BootSucceeds)), [
    #(1, qcheck.constant(BootFails)),
  ])
}

fn command(_model: Model) -> qcheck.Generator(Command) {
  let guest = qcheck.bounded_int(0, 1)
  qcheck.from_weighted_generators(#(2, qcheck.constant(Setup)), [
    #(2, qcheck.constant(Update)),
    #(
      30,
      qcheck.map3(guest, access(), outcome(), fn(index, given, boot) {
        Ensure(index, given, boot)
      }),
    ),
    #(
      6,
      qcheck.map2(guest, access(), fn(index, given) { UpFresh(index, given) }),
    ),
    #(6, qcheck.map(guest, Down)),
    #(3, qcheck.map(guest, Crash)),
    #(3, qcheck.map(guest, Rm)),
    #(3, qcheck.map(guest, StartBoot)),
    #(3, qcheck.map(guest, FinishBoot)),
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
    |> statem.with_test_count(400)
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

fn ok(index: Int) -> Command {
  Ensure(index, None, BootSucceeds)
}

pub fn the_first_guest_with_an_idle_daemon_stops_it_test() {
  let assert Ok(#(world, _)) = replay([StartDaemon(0), ok(0)])
  assert world.daemon == WorldDown
  assert world.deployed == Deployed
}

pub fn the_first_guest_with_a_busy_daemon_leaves_it_and_needs_a_restart_test() {
  let assert Ok(#(world, _)) = replay([StartDaemon(2), ok(0)])
  assert world.daemon == WorldUp(2, NoTable)

  // The refusal that names the restart is what that daemon is left with.
  assert result.is_error(restart_effect(world.daemon).1)
}

pub fn a_failed_first_boot_leaves_a_daemon_that_has_not_read_the_table_test() {
  let assert Ok(#(failed, _)) =
    replay([StartDaemon(0), Ensure(0, None, BootFails)])
  assert world_guest(failed, 0).life == Dead
  assert failed.deployed == Deployed
  assert failed.daemon == WorldUp(0, NoTable)

  // The retry is a resume, and it finds the daemon: an idle one is stopped.
  let assert Ok(#(retried, _)) =
    replay([StartDaemon(0), Ensure(0, None, BootFails), ok(0)])
  assert retried.daemon == WorldDown
  assert world_guest(retried, 0).life == Alive
}

pub fn a_failed_first_boot_under_a_busy_daemon_is_refused_on_the_retry_test() {
  let assert Ok(#(world, _)) =
    replay([StartDaemon(2), Ensure(0, None, BootFails), ok(0)])
  assert world.daemon == WorldUp(2, NoTable)
  assert result.is_error(restart_effect(world.daemon).1)
}

pub fn a_second_guest_needs_the_daemon_and_changes_nothing_without_it_test() {
  // The first guest minted the deployment and its idle daemon was stopped, so
  // the second guest's join must ask for the daemon and write nothing.
  let assert Ok(#(before, _)) = replay([StartDaemon(0), ok(0)])
  let assert Ok(#(after, _)) = replay([StartDaemon(0), ok(0), ok(1)])
  assert after == before
}

pub fn a_second_guest_joins_once_the_daemon_runs_test() {
  let assert Ok(#(world, _)) =
    replay([
      StartDaemon(0),
      ok(0),
      StartDaemon(2),
      Ensure(1, Some(vm_spec.GitHubOff), BootSucceeds),
    ])
  assert world_guest(world, 1).life == Alive
  assert world_guest(world, 1).github == Some(vm_spec.GitHubOff)
  assert world.daemon == WorldUp(2, HasTable)
}

pub fn a_guest_another_loom_is_booting_is_refused_not_served_test() {
  let assert Ok(#(world, _)) = replay([ok(0), Down(0), StartBoot(0), ok(0)])
  assert world_guest(world, 0).life == Booting

  // Once the other loom's boot ends the guest serves.
  let assert Ok(#(done, _)) =
    replay([ok(0), Down(0), StartBoot(0), ok(0), FinishBoot(0), ok(0)])
  assert world_guest(done, 0).life == Alive
}

pub fn a_new_build_sets_up_again_before_a_dead_guest_boots_test() {
  let assert Ok(#(world, _)) = replay([ok(0), Down(0), Update, ok(0)])
  assert world.manifest == Some(world.build)
  assert world.build == 2
}

pub fn a_resume_keeps_the_access_and_fresh_forgets_it_test() {
  let assert Ok(#(kept, _)) =
    replay([Ensure(0, Some(vm_spec.GitHubOff), BootSucceeds), Down(0), ok(0)])
  assert world_guest(kept, 0).github == Some(vm_spec.GitHubOff)

  let assert Ok(#(forgotten, _)) =
    replay([
      Ensure(0, Some(vm_spec.GitHubOff), BootSucceeds),
      Down(0),
      UpFresh(0, None),
    ])
  assert world_guest(forgotten, 0).github == Some(vm_spec.GitHubFromGh)
}

pub fn a_crashed_guest_boots_again_not_serves_test() {
  let assert Ok(#(world, _)) = replay([ok(0), Crash(0), ok(0)])
  assert world_guest(world, 0).life == Alive
}
