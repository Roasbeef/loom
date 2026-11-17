//// A model-based test of one machine's guests, driven over the pure decisions
//// `loom --vm` makes: `vm_link.settle`, `vm_spec.ensure_step`,
//// `manifest_action`, `effective_github` and `vm_link.daemon_need`.
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
//// and that has or has not read each guest's row, a release build whose commit
//// can change (`loom update`), a manifest that can lag it, a guest another loom
//// is booting, and an `ensure` whose boot fails after the row was written.
//// Every guest a command makes is on the untrusted link. The second guest can
//// start out as one made over distribution before that was the default,
//// stopped or running, because such guests exist on developers' machines. The
//// properties, by tag:
////
//// - `serving`: `ensure` answers `AlreadyServing` for a guest exactly when the
////   model says it serves, so it never claims a stopped or booting guest and
////   never restarts a live one.
//// - `starting`: a guest whose process is there and whose executor is not ready
////   is refused, never booted a second time and never called serving.
//// - `stale-boot`: a guest boots only against a manifest that matches the
////   running build once `bring_up`'s own setup has run.
//// - `daemon-first`: `NeedsDaemon` is never answered, because only a guest
////   joining a ledger deployment needed a daemon, and no guest joins one now.
//// - `refused`: a release build refuses only a guest that is booting.
//// - `restart`: after a boot `ensure` or `up` ran, a running daemon holds the
////   guest's row, whether the boot wrote it or an earlier failed boot did. The
////   model's daemon answers `executors.reload` (protocol-change/116); one that
////   predates it takes the older stop-or-name path, which
////   `vm_link_model_test` and `vm_link_test` hold.
//// - `retired`: `ensure` and `up` of a guest made over distribution are refused
////   with the commands that move its work to a new guest, and change nothing.
//// - `no-distribution`: no command makes a distribution guest where there was
////   none, or turns an untrusted guest into one.
//// - `github`: after any sequence, a guest that has booted records the last
////   `--github` choice made since its last `--fresh`, or the default.
////
//// The schedules are drawn from a fixed seed. `crash` leaves a stale pid
//// record in the real system; the world reads the process, not the record, so
//// the command checks that a dead process is never read as a live guest.

import client/vm_link
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

// Whether a guest was made, and over which link.
type Made {
  NotMade
  MadeOver(kind: vm_spec.LinkKind)
}

// The daemon as the model sees it.
type Daemon {
  DaemonDown
  DaemonIdle
  DaemonBusy
}

// The daemon as the world has it: the guests whose untrusted rows it read.
type WorldDaemon {
  WorldDown
  WorldUp(sessions: Int, rows: List(Int))
}

type WorldGuest {
  WorldGuest(life: Life, made: Made, github: Option(GitHubAccess))
}

type World {
  World(
    build: Int,
    manifest: Option(Int),
    daemon: WorldDaemon,
    guests: List(WorldGuest),
  )
}

type ModelGuest {
  ModelGuest(life: Life, made: Made, explicit: Option(GitHubAccess))
}

type Model {
  Model(daemon: Daemon, seen: List(Int), guests: List(ModelGuest))
}

// Whether the boot an `ensure` starts reaches the guest's executor.
type BootOutcome {
  BootSucceeds
  // The row is written and the files are staged, then the boot fails: no
  // token for the credential proxy, say.
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

// How a run begins: with no guest, or with the second guest made over
// distribution before the untrusted link was the default.
type Start {
  Fresh
  OldGuest(life: Life)
}

// The guest a start can make an old one of.
const old_index = 1

fn name_of(index: Int) -> String {
  "guest" <> int.to_string(index)
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

// An old guest booted before with the default access, which is what its
// `github` record holds.
fn start_world(start: Start) -> World {
  let second = case start {
    Fresh -> WorldGuest(Dead, NotMade, None)
    OldGuest(life:) ->
      WorldGuest(
        life,
        MadeOver(vm_spec.Distribution),
        Some(vm_spec.default_github),
      )
  }
  World(build: 1, manifest: None, daemon: WorldDown, guests: [
    WorldGuest(Dead, NotMade, None),
    second,
  ])
}

fn start_model(start: Start) -> Model {
  let second = case start {
    Fresh -> ModelGuest(Dead, NotMade, None)
    OldGuest(life:) -> ModelGuest(life, MadeOver(vm_spec.Distribution), None)
  }
  Model(DaemonDown, [], [ModelGuest(Dead, NotMade, None), second])
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
    [] -> WorldGuest(Dead, NotMade, None)
  }
}

fn model_guest(model: Model, index: Int) -> ModelGuest {
  case list.drop(model.guests, index) {
    [guest, ..] -> guest
    [] -> ModelGuest(Dead, NotMade, None)
  }
}

// The guests whose untrusted rows the file holds, in order: a row is written
// when the guest is made, before its boot, and goes with `rm`.
fn world_rows(world: World) -> List(Int) {
  list.index_map(world.guests, fn(guest, index) { #(guest.made, index) })
  |> list.filter_map(fn(entry) {
    case entry.0 {
      MadeOver(vm_spec.Untrusted) -> Ok(entry.1)
      MadeOver(vm_spec.Distribution) | NotMade -> Error(Nil)
    }
  })
}

// --- what the world shows ensure ---------------------------------------------

// The `link` record and the traces `vm_cli.link_of` reads for a guest.
fn records_of(guest: WorldGuest) -> #(Option(String), vm_link.Traces) {
  case guest.made {
    NotMade -> #(None, vm_link.NoTraces)
    MadeOver(vm_spec.Untrusted) -> #(
      Some(vm_link.encode_kind(vm_spec.Untrusted)),
      vm_link.LeafTrace,
    )
    MadeOver(vm_spec.Distribution) -> #(None, vm_link.DeployTrace)
  }
}

fn facts_of(world: World, index: Int) -> vm_spec.EnsureFacts {
  let guest = world_guest(world, index)
  let pid = case guest.life {
    Alive | Booting -> Some(100 + index)
    Dead -> None
  }

  // The console says the executor serves only once it does, so a booting
  // guest is not registered.
  let registration = case guest.life {
    Alive -> vm_spec.Registered
    Booting | Dead -> vm_spec.Unregistered
  }
  vm_spec.EnsureFacts(
    name: name_of(index),
    state: vm_spec.guest_state(pid, registration),
    manifest: Ok(manifest_decision(world)),
    // An untrusted guest joins no deployment, so `vm_cli.enrolment_for`
    // answers this for every guest that reaches `ensure_step`.
    enrolment: vm_spec.NeedsNoDaemon,
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

// Makes the manifest current the way `bring_up` does before it boots: a
// missing or stale one is installed, a refused one is a violation.
fn current_manifest(world: World) -> Result(World, statem.Violation) {
  case manifest_decision(world) {
    vm_spec.InstallRelease(_) -> Ok(World(..world, manifest: Some(world.build)))
    vm_spec.UseManifest(_) -> Ok(world)
    vm_spec.RefuseManifest(reason) -> Error(violation("refused", reason))
  }
}

// The link `bring_up` settles for a guest, read from its records. A refusal
// must be of a distribution guest and must name the way on; it ends the
// command with the world as it was, which is `Refused`.
fn settled(world: World, index: Int) -> Result(Settled, statem.Violation) {
  let guest = world_guest(world, index)
  let #(record, traces) = records_of(guest)
  case vm_link.settle(name_of(index), record, traces), guest.made {
    Ok(vm_spec.Untrusted), _ -> Ok(OnTheLink)
    Ok(vm_spec.Distribution), _ ->
      Error(violation("no-distribution", "settled a guest over distribution"))
    Error(reason), MadeOver(vm_spec.Distribution) ->
      case names_the_way_on(reason, name_of(index)) {
        True -> Ok(Refused)
        False -> Error(violation("retired", "the refusal says " <> reason))
      }
    Error(reason), _ ->
      Error(violation("retired", "refused a guest that is not old: " <> reason))
  }
}

// What `settled` decided.
type Settled {
  OnTheLink
  Refused
}

fn names_the_way_on(reason: String, name: String) -> Bool {
  list.all(
    [
      "`loom vm sync --name " <> name <> "`",
      "`loom vm rm --name " <> name <> " --yes`",
      "`loom vm up --name " <> name <> "`",
    ],
    string.contains(reason, _),
  )
}

// Boots a guest through the `up` path, with the freshness the command has, and
// then asks the daemon about its row as `restart_check` and `restart_of` do.
fn boot(
  world: World,
  index: Int,
  given: Option(GitHubAccess),
  freshness: vm_spec.Freshness,
  outcome: BootOutcome,
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

      // The row is written before the boot, so it is there whatever the boot
      // does; it changed only when the guest was new.
      let rows = case guest.made {
        NotMade -> vm_link.RowChanged
        MadeOver(_) -> vm_link.RowStanding
      }
      let world =
        World(
          ..world,
          guests: set_at(
            world.guests,
            index,
            WorldGuest(life, MadeOver(vm_spec.Untrusted), Some(github)),
          ),
        )
      daemon_after_boot(world, index, rows, outcome)
    }
  }
}

// A failed boot never reaches the daemon; a successful one asks a running
// daemon to reload when `daemon_need` says, and the result must be a world in
// which a running daemon holds the guest's row.
fn daemon_after_boot(
  world: World,
  index: Int,
  rows: vm_link.Rows,
  outcome: BootOutcome,
) -> Result(World, statem.Violation) {
  case outcome {
    BootFails -> Ok(world)
    BootSucceeds -> {
      let saw = case world.daemon {
        WorldDown -> vm_link.SawNoDaemon
        WorldUp(rows: held, ..) -> vm_link.SawExecutors(list.map(held, name_of))
      }
      let daemon = case vm_link.daemon_need(rows, saw, name_of(index)) {
        vm_link.MustReload -> reloaded(world)
        vm_link.NeedsNothing -> world.daemon
      }

      // A daemon left running without the guest's row cannot place a session
      // on it.
      case daemon {
        WorldUp(rows: held, ..) ->
          case list.contains(held, index) {
            True -> Ok(World(..world, daemon:))
            False ->
              Error(violation(
                "restart",
                "a running daemon was left without the row of "
                  <> name_of(index),
              ))
          }
        WorldDown -> Ok(World(..world, daemon:))
      }
    }
  }
}

// What `executors.reload` does to a running daemon: it reads the rows the file
// holds now, whatever sessions it has.
fn reloaded(world: World) -> WorldDaemon {
  case world.daemon {
    WorldDown -> WorldDown
    WorldUp(sessions:, ..) -> WorldUp(sessions:, rows: world_rows(world))
  }
}

fn execute(
  world: World,
  model: Model,
  command: Command,
) -> Result(World, statem.Violation) {
  use after <- result.try(apply(world, model, command))
  use Nil <- result.try(check_no_distribution(world, after, command))
  Ok(after)
}

fn apply(
  world: World,
  model: Model,
  command: Command,
) -> Result(World, statem.Violation) {
  case command {
    Setup -> Ok(World(..world, manifest: Some(world.build)))
    Update -> Ok(World(..world, build: world.build + 1))
    Ensure(index, given, outcome) ->
      execute_ensure(world, model, index, given, outcome)
    UpFresh(index, given) -> {
      use decided <- result.try(settled(world, index))
      case decided {
        Refused -> Ok(world)
        OnTheLink -> boot(world, index, given, vm_spec.Fresh, BootSucceeds)
      }
    }
    Down(index) | Crash(index) -> Ok(set_life(world, index, Dead))
    Rm(index) -> {
      // `rm` of an untrusted guest takes its row out of the default file and
      // asks a running daemon to reload (`removal_daemon_lines`); a
      // distribution guest's teardown touches no untrusted row.
      let removed =
        World(
          ..world,
          guests: set_at(world.guests, index, WorldGuest(Dead, NotMade, None)),
        )
      case world_guest(world, index).made {
        MadeOver(vm_spec.Untrusted) ->
          Ok(World(..removed, daemon: reloaded(removed)))
        MadeOver(vm_spec.Distribution) | NotMade -> Ok(removed)
      }
    }
    StartBoot(index) -> Ok(set_life(world, index, Booting))
    FinishBoot(index) -> Ok(set_life(world, index, Alive))
    StartDaemon(sessions) ->
      Ok(World(..world, daemon: WorldUp(sessions:, rows: world_rows(world))))
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

// No command makes a distribution guest: a guest made over distribution after
// the command was one before it.
fn check_no_distribution(
  before: World,
  after: World,
  command: Command,
) -> Result(Nil, statem.Violation) {
  list.try_each([0, 1], fn(index) {
    let was = world_guest(before, index).made
    let now = world_guest(after, index).made
    case now == MadeOver(vm_spec.Distribution) && was != now {
      False -> Ok(Nil)
      True ->
        Error(violation(
          "no-distribution",
          string.inspect(command)
            <> " made "
            <> name_of(index)
            <> " a distribution guest from "
            <> string.inspect(was),
        ))
    }
  })
}

fn execute_ensure(
  world: World,
  model: Model,
  index: Int,
  given: Option(GitHubAccess),
  outcome: BootOutcome,
) -> Result(World, statem.Violation) {
  // The link is settled before `ensure_step`, so an old guest is refused even
  // when it serves.
  use decided <- result.try(settled(world, index))
  case decided {
    Refused -> Ok(world)
    OnTheLink -> ensure_on_the_link(world, model, index, given, outcome)
  }
}

fn ensure_on_the_link(
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
    True, vm_spec.NeedsDaemon, _ ->
      Error(violation(
        "daemon-first",
        "NeedsDaemon for "
          <> name_of(index)
          <> " with "
          <> describe_world(world),
      ))
    True, vm_spec.Boot, _ -> boot(world, index, given, vm_spec.Resume, outcome)
  }
}

// --- the model's own rules -----------------------------------------------------

fn next_model(model: Model, command: Command) -> Model {
  case command {
    Setup | Update -> model
    StartDaemon(_) | StopDaemon -> next_daemon(model, command)
    Ensure(index, given, outcome) -> next_ensure(model, index, given, outcome)
    UpFresh(index, given) ->
      case model_guest(model, index).made {
        MadeOver(vm_spec.Distribution) -> model
        _ -> booted(model, index, given, BootSucceeds)
      }
    Down(index) | Crash(index) -> with_life(model, index, Dead)
    Rm(index) -> {
      let removed = with_guest(model, index, ModelGuest(Dead, NotMade, None))

      // Removing an untrusted guest makes a running daemon read the file.
      case model_guest(model, index).made, model.daemon {
        MadeOver(vm_spec.Untrusted), DaemonIdle
        | MadeOver(vm_spec.Untrusted), DaemonBusy
        -> Model(..removed, seen: rows_of(removed))
        _, _ -> removed
      }
    }
    StartBoot(index) -> with_life(model, index, Booting)
    FinishBoot(index) -> with_life(model, index, Alive)
  }
}

fn next_daemon(model: Model, command: Command) -> Model {
  case command {
    StartDaemon(0) -> Model(..model, daemon: DaemonIdle, seen: rows_of(model))
    StartDaemon(_) -> Model(..model, daemon: DaemonBusy, seen: rows_of(model))
    StopDaemon -> Model(..model, daemon: DaemonDown)
    _ -> model
  }
}

// The guests made on the untrusted link, whose rows a daemon starting now reads.
fn rows_of(model: Model) -> List(Int) {
  list.index_map(model.guests, fn(guest, index) {
    case guest.made {
      MadeOver(vm_spec.Untrusted) -> Ok(index)
      _ -> Error(Nil)
    }
  })
  |> list.filter_map(fn(entry) { entry })
}

fn with_guest(model: Model, index: Int, guest: ModelGuest) -> Model {
  Model(..model, guests: set_at(model.guests, index, guest))
}

fn with_life(model: Model, index: Int, life: Life) -> Model {
  let guest = model_guest(model, index)
  with_guest(model, index, ModelGuest(..guest, life:))
}

// A guest brought up on the untrusted link, alive or not, with the access it
// was given. After a boot that succeeded, a running daemon reads the file
// unless the guest's row was there before and it had read it.
fn booted(
  model: Model,
  index: Int,
  explicit: Option(GitHubAccess),
  outcome: BootOutcome,
) -> Model {
  let was = model_guest(model, index)
  let life = case outcome {
    BootSucceeds -> Alive
    BootFails -> Dead
  }
  let model =
    with_guest(
      model,
      index,
      ModelGuest(life, MadeOver(vm_spec.Untrusted), explicit),
    )
  let unread = was.made == NotMade || !list.contains(model.seen, index)

  case outcome, model.daemon, unread {
    BootSucceeds, DaemonIdle, True | BootSucceeds, DaemonBusy, True ->
      Model(..model, seen: rows_of(model))
    _, _, _ -> model
  }
}

fn next_ensure(
  model: Model,
  index: Int,
  given: Option(GitHubAccess),
  outcome: BootOutcome,
) -> Model {
  let guest = model_guest(model, index)
  let explicit = case given {
    Some(access) -> Some(access)
    None -> guest.explicit
  }

  case guest.made, guest.life {
    // An old guest is refused and stays as it was.
    MadeOver(vm_spec.Distribution), _ -> model
    // A serving or booting guest is left as it is, whatever flag was given.
    _, Alive | _, Booting -> model
    _, Dead -> booted(model, index, explicit, outcome)
  }
}

fn precondition(model: Model, command: Command) -> statem.Admission {
  let admitted = case command {
    Setup | Update | Ensure(..) -> True
    UpFresh(index, _) -> {
      let guest = model_guest(model, index)
      guest.life == Dead && guest.made != NotMade
    }
    Down(index) | Crash(index) -> model_guest(model, index).life == Alive
    Rm(index) -> {
      let guest = model_guest(model, index)
      guest.life == Dead && guest.made != NotMade
    }
    // No loom boots an old guest any more, since `up` refuses it.
    StartBoot(index) -> {
      let guest = model_guest(model, index)
      guest.life == Dead && guest.made == MadeOver(vm_spec.Untrusted)
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
// `--fresh`, or the default, which is what the model keeps for it. Every guest
// was made over the link the model says. A daemon the model says has read a
// guest's row is one the world says has.
fn finish(world: World, model: Model) -> Result(Nil, statem.Violation) {
  let checked =
    list.index_map(model.guests, fn(guest, index) {
      let found = world_guest(world, index)
      found.made == guest.made
      && case guest.made {
        NotMade -> found.github == None
        MadeOver(_) ->
          found.github
          == Some(option.unwrap(guest.explicit, vm_spec.default_github))
      }
    })

  let daemon_agrees = case world.daemon, model.daemon {
    WorldDown, DaemonDown -> True
    WorldUp(0, rows), DaemonIdle -> rows == model.seen
    WorldUp(_, rows), DaemonBusy -> rows == model.seen
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

fn spec(start: Start) -> statem.Spec(Model, Command, World) {
  statem.Spec(
    initial: start_model(start),
    command:,
    precondition:,
    next_model:,
    new_sut: fn() { start_world(start) },
    execute:,
    finish:,
    teardown: fn(_) { Nil },
  )
}

fn campaign(start: Start) -> Nil {
  let config =
    statem.default_config(seed:)
    |> statem.with_test_count(400)
    |> statem.with_max_commands(40)

  case statem.check(spec(start), config) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, describe)
  }
}

pub fn guests_follow_the_model_test() {
  campaign(Fresh)
}

pub fn guests_follow_the_model_beside_a_stopped_distribution_guest_test() {
  campaign(OldGuest(Dead))
}

pub fn guests_follow_the_model_beside_a_running_distribution_guest_test() {
  campaign(OldGuest(Alive))
}

// --- scripted schedules through the same rules --------------------------------------

// Runs commands in order through `execute` and `next_model`, answering the
// world and the model, or the first violation.
fn replay_from(
  start: Start,
  commands: List(Command),
) -> Result(#(World, Model), statem.Violation) {
  list.try_fold(
    commands,
    #(start_world(start), start_model(start)),
    fn(state, command) {
      let #(world, model) = state
      case execute(world, model, command) {
        Ok(world) -> Ok(#(world, next_model(model, command)))
        Error(reason) -> Error(reason)
      }
    },
  )
}

fn replay(
  commands: List(Command),
) -> Result(#(World, Model), statem.Violation) {
  replay_from(Fresh, commands)
}

fn ok(index: Int) -> Command {
  Ensure(index, None, BootSucceeds)
}

pub fn the_first_guest_makes_an_idle_daemon_read_its_row_test() {
  let assert Ok(#(world, _)) = replay([StartDaemon(0), ok(0)])
    as "the first guest boots"
  assert world.daemon == WorldUp(0, [0])
}

pub fn a_busy_daemon_reads_the_row_and_keeps_running_test() {
  let assert Ok(#(world, _)) = replay([StartDaemon(2), ok(0)])
    as "the first guest boots beside a busy daemon"
  assert world.daemon == WorldUp(2, [0])
}

pub fn a_failed_first_boot_leaves_a_row_the_retry_has_read_test() {
  let assert Ok(#(failed, _)) =
    replay([StartDaemon(0), Ensure(0, None, BootFails)])
    as "the first boot fails"
  assert world_guest(failed, 0).life == Dead
  assert world_guest(failed, 0).made == MadeOver(vm_spec.Untrusted)
  assert failed.daemon == WorldUp(0, [])

  // The retry is a resume, the row is standing and unlisted, and the daemon is
  // asked to read it.
  let assert Ok(#(retried, _)) =
    replay([StartDaemon(0), Ensure(0, None, BootFails), ok(0)])
    as "the retry boots"
  assert retried.daemon == WorldUp(0, [0])
  assert world_guest(retried, 0).life == Alive
}

pub fn a_second_guest_needs_no_daemon_test() {
  // No guest joins a deployment, so the second guest boots with no daemon
  // where it once had to wait for one.
  let assert Ok(#(world, _)) = replay([ok(0), ok(1)]) as "both guests boot"
  assert world_guest(world, 1).life == Alive
  assert world.daemon == WorldDown
}

pub fn a_second_guest_is_read_by_the_running_daemon_test() {
  let assert Ok(#(world, _)) =
    replay([
      StartDaemon(0),
      ok(0),
      StopDaemon,
      StartDaemon(2),
      Ensure(1, Some(vm_spec.GitHubOff), BootSucceeds),
    ])
    as "the second guest boots"
  assert world_guest(world, 1).life == Alive
  assert world_guest(world, 1).github == Some(vm_spec.GitHubOff)
  assert world.daemon == WorldUp(2, [0, 1])
}

pub fn a_guest_another_loom_is_booting_is_refused_not_served_test() {
  let assert Ok(#(world, _)) = replay([ok(0), Down(0), StartBoot(0), ok(0)])
    as "the booting guest is refused"
  assert world_guest(world, 0).life == Booting

  // Once the other loom's boot ends the guest serves.
  let assert Ok(#(done, _)) =
    replay([ok(0), Down(0), StartBoot(0), ok(0), FinishBoot(0), ok(0)])
    as "the guest serves after the other boot"
  assert world_guest(done, 0).life == Alive
}

pub fn a_new_build_sets_up_again_before_a_dead_guest_boots_test() {
  let assert Ok(#(world, _)) = replay([ok(0), Down(0), Update, ok(0)])
    as "the guest boots after the update"
  assert world.manifest == Some(world.build)
  assert world.build == 2
}

pub fn a_resume_keeps_the_access_and_fresh_forgets_it_test() {
  let assert Ok(#(kept, _)) =
    replay([Ensure(0, Some(vm_spec.GitHubOff), BootSucceeds), Down(0), ok(0)])
    as "the resume boots"
  assert world_guest(kept, 0).github == Some(vm_spec.GitHubOff)

  let assert Ok(#(forgotten, _)) =
    replay([
      Ensure(0, Some(vm_spec.GitHubOff), BootSucceeds),
      Down(0),
      UpFresh(0, None),
    ])
    as "the fresh up boots"
  assert world_guest(forgotten, 0).github == Some(vm_spec.GitHubFromGh)
}

pub fn a_crashed_guest_boots_again_not_serves_test() {
  let assert Ok(#(world, _)) = replay([ok(0), Crash(0), ok(0)])
    as "the crashed guest boots again"
  assert world_guest(world, 0).life == Alive
}

pub fn an_old_guest_is_refused_by_ensure_and_up_and_changes_nothing_test() {
  // Stopped or running, with a daemon or not: `ensure` and `up --fresh` of the
  // old guest leave the world as it was.
  list.each([Dead, Alive], fn(life) {
    let start = OldGuest(life)
    let assert Ok(#(before, _)) = replay_from(start, [StartDaemon(2)])
      as "the daemon starts"
    let assert Ok(#(after, _)) =
      replay_from(start, [StartDaemon(2), ok(old_index)])
      as "ensure of the old guest is refused"
    assert after == before
  })

  let assert Ok(#(before, _)) = replay_from(OldGuest(Dead), [])
    as "nothing runs"
  let assert Ok(#(after, _)) =
    replay_from(OldGuest(Dead), [UpFresh(old_index, None)])
    as "up of the old guest is refused"
  assert after == before
}

pub fn an_old_guest_removed_comes_back_on_the_untrusted_link_test() {
  let assert Ok(#(world, _)) =
    replay_from(OldGuest(Dead), [Rm(old_index), StartDaemon(0), ok(old_index)])
    as "the removed guest is made again"
  assert world_guest(world, old_index).made == MadeOver(vm_spec.Untrusted)
  assert world.daemon == WorldUp(0, [old_index])
}
