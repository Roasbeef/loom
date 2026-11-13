//// A model-based test of one vm home's guests when some are reached over the
//// untrusted link, driven over the pure decisions of `client/vm_link`.
////
//// The system under test is a `World`: the default `loom.toml` as real text,
//// the records beside each guest, the host ports strangers hold, and the
//// daemon. `up`, `down`, `rm` and the rest run over it by applying the real
//// decisions (`vm_link.settle`, `port_step`, `install`, `uninstall`,
//// `staging`, `vm_spec.daemon_step`) to what the world holds and writing back
//// what `vm_cli` would write, in the order it writes it. The `Model` is a
//// coarser account of the same machine that advances by plain rules which call
//// none of those decisions, so a decision that drifts from the rules fails the
//// check instead of agreeing with itself.
////
//// There are three guests that can each be reached either way, a configuration
//// that may already hold a ledger deployment and a trusted row, and a
//// configuration in which a trusted row already has the first guest's name. A
//// daemon is down, idle or busy, and a stranger can take a guest's port while
//// the guest is down. The properties, by tag:
////
//// - `untouched`: a command on an untrusted guest never changes the
////   `[distribution]` table or any row that is not untrusted.
//// - `link-table`: `[executor_link]` is in the file exactly while an untrusted
////   guest exists, and the vm home's link credentials with it.
//// - `port-agrees`: every untrusted guest's recorded port and the address of its
////   row name the same loopback port, after every command.
//// - `no-cookie`: what `up` stages for an untrusted guest holds no cookie, no
////   ledger and no `[distribution]` table.
//// - `kind-fixed`: a guest asked for the other link is refused and changes
////   nothing.
//// - `daemon`: a row that changed stops an idle daemon and leaves a busy one
////   stale, and a resumed guest whose row did not change touches neither.
//// - `refused`: a trusted row of the guest's own name refuses an untrusted
////   `up` and leaves no guest behind.
////
//// The schedules are drawn from a fixed seed, and the same rules run over
//// four starting configurations.

import client/distribution_install
import client/vm_link.{LinkFiles, Row}
import client/vm_spec.{type LinkKind, Distribution, Untrusted}
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import statem
import tom

const seed = 20_261_114

const first_port = 40_000

// --- the machine -------------------------------------------------------------

type Life {
  Alive
  Dead
}

// A guest as the world holds it: the records `vm_cli` wrote beside it.
type WorldSlot {
  WorldAbsent
  WorldGuest(
    // The `link` record's text, absent for a distribution guest.
    link: Option(String),
    // The `link-port` record's text.
    port: Option(String),
    bundles: vm_link.Bundles,
    life: Life,
  )
}

// The daemon as the world has it: the untrusted rows it read at its start.
type WorldDaemon {
  WorldDown
  WorldUp(sessions: Int, rows: List(#(String, String)))
}

type World {
  World(
    config: String,
    slots: List(WorldSlot),
    // Ports a stranger listens on.
    taken: List(Int),
    // The next port a reservation would hand out.
    next: Int,
    daemon: WorldDaemon,
    link_home: Bool,
  )
}

type Slot {
  Absent
  Present(kind: LinkKind, life: Life, port: Option(Int))
}

type Daemon {
  DaemonDown
  DaemonIdle
  // The guests and ports whose rows the daemon read at its start.
  DaemonBusy(seen: List(#(Int, Int)))
}

// What a test can see of a daemon: whether it runs, holds sessions, and has
// read the rows the file now holds.
type Observed {
  ObservedDown
  ObservedIdle
  ObservedBusy(stale: Bool)
}

type Model {
  Model(
    slots: List(Slot),
    taken: List(Int),
    next: Int,
    daemon: Daemon,
    // Whether a trusted row already has the first guest's name.
    squatted: Bool,
  )
}

type Command {
  // `loom vm up`, with `--link` when given. A resume gives none.
  Up(guest: Int, asked: Option(LinkKind))
  Down(guest: Int)
  Rm(guest: Int)
  // A stranger starts listening on the guest's recorded port.
  PortTaken(guest: Int)
  StartDaemon(sessions: Int)
  StopDaemon
}

// How a run begins.
type Start {
  Start(deployment: Deployment, squatter: Squatter)
}

type Deployment {
  NoDeployment
  LedgerDeployment
}

type Squatter {
  NoSquatter
  TrustedRowForFirst
}

fn name_of(guest: Int) -> String {
  "vm" <> int.to_string(guest)
}

// Each guest has its own leaf, so its own pin. The values are not
// certificates: the pin's correctness is the pin test's, and here only that
// each guest's row names its own.
fn pin_of(guest: Int) -> String {
  string.repeat(int.to_string(guest + 1), 64)
}

fn files() -> vm_link.LinkFiles {
  LinkFiles(
    ca: "/vm/link/ca.pem",
    certificate: "/vm/link/orchestrator.pem",
    key: "/vm/link/orchestrator.key",
  )
}

const ledger_deployment =
  "[distribution]
node = \"owner@10.0.0.1\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"
ledger = \"/var/loom/ledger.log\"
"

const notes = "# the owner's own notes\n[tools]\nnetwork = \"full\"\n"

fn squatter_row() -> String {
  "[executors.vm0]\nnode = \"squatter@127.0.0.1\"\n"
}

fn start_config(start: Start) -> String {
  let deployment = case start.deployment {
    NoDeployment -> []
    LedgerDeployment -> [ledger_deployment]
  }
  let squatter = case start.squatter {
    NoSquatter -> []
    TrustedRowForFirst -> [squatter_row()]
  }
  string.join(list.flatten([[notes], deployment, squatter]), "\n")
}

fn start_world(start: Start) -> World {
  World(
    config: start_config(start),
    slots: [WorldAbsent, WorldAbsent, WorldAbsent],
    taken: [],
    next: first_port,
    daemon: WorldDown,
    link_home: False,
  )
}

fn start_model(start: Start) -> Model {
  Model(
    slots: [Absent, Absent, Absent],
    taken: [],
    next: first_port,
    daemon: DaemonDown,
    squatted: start.squatter == TrustedRowForFirst,
  )
}

fn set_at(items: List(a), index: Int, with replacement: a) -> List(a) {
  list.index_map(items, fn(item, at) {
    case at == index {
      True -> replacement
      False -> item
    }
  })
}

fn at(items: List(a), index: Int, default: a) -> a {
  case list.drop(items, index) {
    [item, ..] -> item
    [] -> default
  }
}

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

// --- reading the world ---------------------------------------------------------------

fn document(text: String) -> dict.Dict(String, tom.Toml) {
  let assert Ok(parsed) = tom.parse(text) as "the world's text is TOML"
  parsed
}

fn rows_of(text: String) -> dict.Dict(String, tom.Toml) {
  case dict.get(document(text), "executors") {
    Ok(tom.Table(rows)) -> rows
    _ -> dict.new()
  }
}

fn is_untrusted(row: tom.Toml) -> Bool {
  case row {
    tom.Table(fields) ->
      dict.get(fields, "trust") == Ok(tom.String("untrusted"))
    _ -> False
  }
}

// The name and address of every untrusted row, sorted, which is what a daemon
// reads at its start.
fn untrusted_rows(text: String) -> List(#(String, String)) {
  rows_of(text)
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    case entry.1 {
      tom.Table(fields) ->
        case is_untrusted(entry.1), dict.get(fields, "address") {
          True, Ok(tom.String(address)) -> Ok(#(entry.0, address))
          _, _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

// What a command on an untrusted guest must leave as it was: the deployment
// table and every row that is not untrusted.
fn kept(text: String) -> #(Option(tom.Toml), List(#(String, tom.Toml))) {
  let trusted =
    rows_of(text)
    |> dict.to_list
    |> list.filter(fn(entry) { !is_untrusted(entry.1) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  #(option.from_result(dict.get(document(text), "distribution")), trusted)
}

fn kind_of_slot(slot: WorldSlot) -> Option(LinkKind) {
  case slot {
    WorldAbsent -> None
    WorldGuest(link:, ..) ->
      case vm_link.decode_kind(link) {
        Ok(kind) -> Some(kind)
        Error(_) -> None
      }
  }
}

// The guest as the model would describe it, read from the world's records.
fn view_of(slot: WorldSlot) -> Slot {
  case slot {
    WorldAbsent -> Absent
    WorldGuest(port:, life:, ..) ->
      Present(
        kind: option.unwrap(kind_of_slot(slot), Distribution),
        life:,
        port: case port {
          Some(text) -> option.from_result(vm_link.decode_port(text))
          None -> None
        },
      )
  }
}

fn untrusted_guests(world: World) -> List(Int) {
  list.index_map(world.slots, fn(slot, index) { #(index, kind_of_slot(slot)) })
  |> list.filter_map(fn(entry) {
    case entry.1 {
      Some(Untrusted) -> Ok(entry.0)
      _ -> Error(Nil)
    }
  })
}

// --- commands on the world ------------------------------------------------------------------

fn execute(
  world: World,
  model: Model,
  command: Command,
) -> Result(World, statem.Violation) {
  use after <- result.try(apply(world, model, command))
  use after <- result.try(check_world(after))
  check_follows(after, next_model(model, command), command)
}

fn apply(
  world: World,
  model: Model,
  command: Command,
) -> Result(World, statem.Violation) {
  case command {
    Up(guest, asked) -> execute_up(world, model, guest, asked)
    Down(guest) -> Ok(with_life(world, guest, Dead))
    Rm(guest) -> execute_rm(world, guest)
    PortTaken(guest) ->
      case view_of(at(world.slots, guest, WorldAbsent)) {
        Present(port: Some(port), ..) ->
          Ok(World(..world, taken: [port, ..world.taken]))
        _ -> Ok(world)
      }
    StartDaemon(sessions) ->
      Ok(
        World(
          ..world,
          daemon: WorldUp(sessions:, rows: untrusted_rows(world.config)),
        ),
      )
    StopDaemon -> Ok(World(..world, daemon: WorldDown))
  }
}

fn with_life(world: World, guest: Int, life: Life) -> World {
  case at(world.slots, guest, WorldAbsent) {
    WorldAbsent -> world
    WorldGuest(..) as slot ->
      World(
        ..world,
        slots: set_at(world.slots, guest, WorldGuest(..slot, life:)),
      )
  }
}

// `up`: the link is settled from the guest's records and the flag, and then
// the guest is brought up the way its link says.
fn execute_up(
  world: World,
  model: Model,
  guest: Int,
  asked: Option(LinkKind),
) -> Result(World, statem.Violation) {
  let slot = at(world.slots, guest, WorldAbsent)
  let #(record, bundles) = case slot {
    WorldAbsent -> #(None, vm_link.NoBundles)
    WorldGuest(link:, bundles:, ..) -> #(link, bundles)
  }
  let settled = vm_link.settle(name_of(guest), record, bundles, asked)

  // A guest whose link differs from the flag is refused and changes nothing.
  case settled, view_of(slot) {
    Error(_), Present(kind:, ..) ->
      case asked {
        Some(wanted) if wanted != kind -> Ok(world)
        _ -> Error(violation("kind-fixed", "refused a settled guest"))
      }
    Error(reason), Absent ->
      Error(violation("kind-fixed", "refused a new guest: " <> reason))
    Ok(Distribution), _ -> Ok(distribution_up(world, guest))
    Ok(Untrusted), _ -> untrusted_up(world, model, guest)
  }
}

fn distribution_up(world: World, guest: Int) -> World {
  // A distribution guest enrols a deployment when there is none and adds its
  // own trusted row. It is the other kind of guest, present so the properties
  // of an untrusted guest can be held against it.
  let deployment = case dict.has_key(document(world.config), "distribution") {
    True -> []
    False -> [ledger_deployment]
  }
  let row = case dict.has_key(rows_of(world.config), name_of(guest)) {
    True -> []
    False -> [
      "[executors." <> name_of(guest) <> "]\nnode = \"peer@127.0.0.1\"\n",
    ]
  }
  World(
    ..world,
    config: string.join(
      list.flatten([[string.trim_end(world.config)], deployment, row]),
      "\n",
    ),
    slots: set_at(
      world.slots,
      guest,
      WorldGuest(None, None, vm_link.HasBundles, Alive),
    ),
  )
}

fn untrusted_up(
  world: World,
  model: Model,
  guest: Int,
) -> Result(World, statem.Violation) {
  let slot = at(world.slots, guest, WorldAbsent)
  let recorded = case slot {
    WorldGuest(port: Some(text), ..) ->
      option.from_result(vm_link.decode_port(text))
    _ -> None
  }
  let seen = case recorded {
    Some(port) ->
      vm_link.Recorded(port, case list.contains(world.taken, port) {
        True -> vm_link.InUse
        False -> vm_link.Free
      })
    None -> vm_link.NotRecorded
  }

  // The port is kept or reserved without being recorded, then the merge is
  // worked out, and only a merge the file accepts records anything.
  let #(port, next) = case vm_link.port_step(seen) {
    vm_link.Keep(port) -> #(port, world.next)
    vm_link.Reserve -> #(world.next, world.next + 1)
  }
  let row = Row(name: name_of(guest), port:, pin: pin_of(guest))
  case vm_link.install(world.config, files(), row, "loom.toml") {
    Error(_) -> refused(world, model, guest)
    Ok(merged) -> enrolled(world, guest, port, next, merged)
  }
}

// The user's file refused the guest's row. That is expected only when a trusted
// row has the guest's name, and it must leave nothing behind.
fn refused(
  world: World,
  model: Model,
  guest: Int,
) -> Result(World, statem.Violation) {
  case model.squatted && guest == 0 {
    True -> Ok(world)
    False ->
      Error(violation("refused", "the file refused an untrusted guest's row"))
  }
}

fn enrolled(
  world: World,
  guest: Int,
  port: Int,
  next: Int,
  merged: vm_link.Merged,
) -> Result(World, statem.Violation) {
  // What the command staged for the guest holds no cookie, ledger or
  // deployment.
  use Nil <- result.try(check_staged(guest))
  use Nil <- result.try(check_kept(world.config, merged.text))

  let daemon = case merged.change {
    vm_link.Unchanged -> world.daemon
    vm_link.Added | vm_link.Moved -> after_change(world.daemon)
  }
  Ok(
    World(
      ..world,
      config: merged.text,
      next:,
      daemon:,
      link_home: True,
      slots: set_at(
        world.slots,
        guest,
        WorldGuest(
          link: Some(vm_link.encode_kind(Untrusted)),
          port: Some(vm_link.encode_port(port)),
          bundles: vm_link.NoBundles,
          life: Alive,
        ),
      ),
    ),
  )
}

// What `up` does about a daemon that started before a row changed: stop an
// idle one and leave a busy one.
fn after_change(daemon: WorldDaemon) -> WorldDaemon {
  case daemon {
    WorldDown -> WorldDown
    WorldUp(sessions:, ..) ->
      case vm_spec.daemon_step(1, vm_spec.Counted(sessions)) {
        vm_spec.StopIt -> WorldDown
        vm_spec.LeaveAlone(_) -> daemon
      }
  }
}

fn check_staged(guest: Int) -> Result(Nil, statem.Violation) {
  let config =
    vm_link.guest_config(
      vm_spec.guest_files(),
      pin_of(9),
      ["proj"],
      vm_spec.GitHubOff,
      [],
    )
  let staged =
    vm_link.staging(vm_spec.guest_files(), "CA", "CERT", "KEY", config)
  let paths = list.map(staged, fn(file) { file.path })
  let texts = list.map(staged, fn(file) { file.contents })

  case
    list.any(paths, string.contains(_, "cookie"))
    || list.any(paths, string.contains(_, "ledger"))
    || list.any(texts, string.contains(_, "[distribution]"))
  {
    True ->
      Error(violation(
        "no-cookie",
        "guest " <> int.to_string(guest) <> " staged " <> string.inspect(paths),
      ))
    False -> Ok(Nil)
  }
}

fn check_kept(before: String, after: String) -> Result(Nil, statem.Violation) {
  case kept(before) == kept(after) {
    True -> Ok(Nil)
    False ->
      Error(violation(
        "untouched",
        "an untrusted guest changed a trusted row or the deployment",
      ))
  }
}

fn execute_rm(world: World, guest: Int) -> Result(World, statem.Violation) {
  let slot = at(world.slots, guest, WorldAbsent)
  case kind_of_slot(slot) {
    Some(Untrusted) -> {
      let others =
        list.index_map(world.slots, fn(other, index) {
          #(index, kind_of_slot(other))
        })
        |> list.filter_map(fn(entry) {
          case entry.0 != guest, entry.1 {
            True, Some(kind) -> Ok(kind)
            _, _ -> Error(Nil)
          }
        })
      let remaining = vm_link.remaining(others)
      case
        vm_link.uninstall(
          world.config,
          name_of(guest),
          remaining,
          files(),
          "loom.toml",
        )
      {
        Error(reason) -> Error(violation("untouched", reason))
        Ok(removal) -> {
          use Nil <- result.try(check_kept(world.config, removal.text))
          Ok(
            World(
              ..world,
              config: removal.text,
              slots: set_at(world.slots, guest, WorldAbsent),
              link_home: remaining == vm_link.OthersRemain,
            ),
          )
        }
      }
    }
    Some(Distribution) | None ->
      Ok(
        World(
          ..world,
          config: result.unwrap(
            distribution_install.without_tables(
              world.config,
              [["executors", name_of(guest)]],
              "loom.toml",
            ),
            world.config,
          ),
          slots: set_at(world.slots, guest, WorldAbsent),
        ),
      )
  }
}

// --- what must hold after every command ---------------------------------------------------------

fn check_world(world: World) -> Result(World, statem.Violation) {
  let guests = untrusted_guests(world)
  let has_link = dict.has_key(document(world.config), "executor_link")
  let rows = rows_of(world.config)

  // The link table and the link credentials exist exactly while an untrusted
  // guest does.
  use Nil <- result.try(
    case has_link == { guests != [] }, world.link_home == { guests != [] } {
      True, True -> Ok(Nil)
      _, _ ->
        Error(violation(
          "link-table",
          "executor_link "
            <> string.inspect(has_link)
            <> " link home "
            <> string.inspect(world.link_home)
            <> " guests "
            <> string.inspect(guests),
        ))
    },
  )

  // Every untrusted guest's record and row name one port and one pin.
  use Nil <- result.try(
    list.try_each(guests, fn(guest) {
      let recorded = case view_of(at(world.slots, guest, WorldAbsent)) {
        Present(port: Some(port), ..) -> Some(vm_link.address(port))
        _ -> None
      }
      let wanted = case dict.get(rows, name_of(guest)) {
        Ok(tom.Table(fields)) ->
          case dict.get(fields, "address"), dict.get(fields, "pin") {
            Ok(tom.String(address)), Ok(tom.String(pin)) ->
              case pin == pin_of(guest) {
                True -> Some(address)
                False -> None
              }
            _, _ -> None
          }
        _ -> None
      }
      case recorded == wanted && recorded != None {
        True -> Ok(Nil)
        False ->
          Error(violation(
            "port-agrees",
            name_of(guest)
              <> " records "
              <> string.inspect(recorded)
              <> " and its row says "
              <> string.inspect(wanted),
          ))
      }
    }),
  )
  Ok(world)
}

// The world is what the model says it is, guest by guest, and the daemon is
// stale exactly when a busy one has not read the rows the file now holds.
fn check_follows(
  world: World,
  model: Model,
  command: Command,
) -> Result(World, statem.Violation) {
  let views = list.map(world.slots, view_of)
  let seen = case world.daemon {
    WorldDown -> ObservedDown
    WorldUp(sessions: 0, ..) -> ObservedIdle
    WorldUp(rows:, ..) -> ObservedBusy(rows != untrusted_rows(world.config))
  }
  let expected = case model.daemon {
    DaemonDown -> ObservedDown
    DaemonIdle -> ObservedIdle
    DaemonBusy(seen:) -> ObservedBusy(seen != model_rows(model))
  }
  case views == model.slots, seen == expected {
    True, True -> Ok(world)
    False, _ ->
      Error(violation(
        "kind-fixed",
        string.inspect(command)
          <> " left "
          <> string.inspect(views)
          <> " where the model has "
          <> string.inspect(model.slots),
      ))
    _, False ->
      Error(violation(
        "daemon",
        string.inspect(command)
          <> " left the daemon "
          <> string.inspect(seen)
          <> " where the model has "
          <> string.inspect(expected),
      ))
  }
}

// The guests with an untrusted row and the port each row names, in guest
// order, which is what a daemon that starts now reads.
fn model_rows(model: Model) -> List(#(Int, Int)) {
  list.index_map(model.slots, fn(slot, index) {
    case slot {
      Present(kind: Untrusted, port: Some(port), ..) -> Ok(#(index, port))
      _ -> Error(Nil)
    }
  })
  |> list.filter_map(fn(entry) { entry })
}

// --- the model's own rules -----------------------------------------------------------------------

fn next_model(model: Model, command: Command) -> Model {
  case command {
    Up(guest, asked) -> model_up(model, guest, asked)
    Down(guest) -> with_life_of(model, guest, Dead)
    Rm(guest) -> Model(..model, slots: set_at(model.slots, guest, Absent))
    PortTaken(guest) ->
      case at(model.slots, guest, Absent) {
        Present(port: Some(port), ..) ->
          Model(..model, taken: [port, ..model.taken])
        _ -> model
      }
    StartDaemon(0) -> Model(..model, daemon: DaemonIdle)
    StartDaemon(_) -> Model(..model, daemon: DaemonBusy(model_rows(model)))
    StopDaemon -> Model(..model, daemon: DaemonDown)
  }
}

// The model with the guest alive or dead, and nothing for an absent one.
fn with_life_of(model: Model, guest: Int, life: Life) -> Model {
  case at(model.slots, guest, Absent) {
    Absent -> model
    Present(kind:, port:, ..) ->
      Model(
        ..model,
        slots: set_at(model.slots, guest, Present(kind:, life:, port:)),
      )
  }
}

fn model_up(model: Model, guest: Int, asked: Option(LinkKind)) -> Model {
  case at(model.slots, guest, Absent) {
    // A new guest takes the flag, and a trusted row of its name refuses an
    // untrusted one.
    Absent ->
      case option.unwrap(asked, Distribution), model.squatted && guest == 0 {
        Untrusted, True -> model
        Untrusted, False -> new_untrusted(model, guest)
        Distribution, _ ->
          Model(
            ..model,
            slots: set_at(
              model.slots,
              guest,
              Present(Distribution, Alive, None),
            ),
          )
      }

    // An existing guest keeps its link and is refused another.
    Present(kind:, port:, ..) ->
      case asked {
        Some(wanted) if wanted != kind -> model
        _ ->
          case kind {
            Distribution -> with_life_of(model, guest, Alive)
            Untrusted -> resume_untrusted(model, guest, port)
          }
      }
  }
}

fn new_untrusted(model: Model, guest: Int) -> Model {
  Model(
    ..model,
    slots: set_at(
      model.slots,
      guest,
      Present(Untrusted, Alive, Some(model.next)),
    ),
    next: model.next + 1,
    daemon: changed(model.daemon),
  )
}

// A resumed untrusted guest keeps its port unless a stranger took it, and a
// moved port is a changed row.
fn resume_untrusted(model: Model, guest: Int, port: Option(Int)) -> Model {
  case port {
    Some(kept) ->
      case list.contains(model.taken, kept) {
        False ->
          Model(
            ..model,
            slots: set_at(model.slots, guest, Present(Untrusted, Alive, port)),
          )
        True ->
          Model(
            ..model,
            slots: set_at(
              model.slots,
              guest,
              Present(Untrusted, Alive, Some(model.next)),
            ),
            next: model.next + 1,
            daemon: changed(model.daemon),
          )
      }
    None -> new_untrusted(model, guest)
  }
}

fn changed(daemon: Daemon) -> Daemon {
  case daemon {
    DaemonDown -> DaemonDown
    DaemonIdle -> DaemonDown
    DaemonBusy(_) -> daemon
  }
}

fn precondition(model: Model, command: Command) -> statem.Admission {
  let admitted = case command {
    Up(guest, asked) -> {
      let slot = at(model.slots, guest, Absent)
      let dead = case slot {
        Absent -> True
        Present(life:, ..) -> life == Dead
      }

      // A trusted row of the first guest's name is only ever met by an
      // untrusted `up`, which refuses it.
      let squatted = model.squatted && guest == 0
      dead && { !squatted || asked == Some(Untrusted) }
    }
    Down(guest) ->
      case at(model.slots, guest, Absent) {
        Present(life: Alive, ..) -> True
        _ -> False
      }
    Rm(guest) ->
      case at(model.slots, guest, Absent) {
        Present(life: Dead, ..) -> True
        _ -> False
      }
    PortTaken(guest) ->
      case at(model.slots, guest, Absent) {
        Present(kind: Untrusted, port: Some(_), life: Dead) -> True
        _ -> False
      }
    StartDaemon(_) -> model.daemon == DaemonDown
    StopDaemon -> model.daemon != DaemonDown
  }
  case admitted {
    True -> statem.Admit
    False -> statem.Reject
  }
}

// --- generation and description ------------------------------------------------------------------

fn command(_model: Model) -> qcheck.Generator(Command) {
  let guest = qcheck.bounded_int(0, 2)
  let asked =
    qcheck.bounded_int(0, 4)
    |> qcheck.map(fn(n) {
      case n {
        0 -> None
        1 -> Some(Distribution)
        _ -> Some(Untrusted)
      }
    })
  qcheck.from_weighted_generators(
    #(24, qcheck.map2(guest, asked, fn(index, kind) { Up(index, kind) })),
    [
      #(8, qcheck.map(guest, Down)),
      #(8, qcheck.map(guest, Rm)),
      #(6, qcheck.map(guest, PortTaken)),
      #(
        6,
        qcheck.bounded_int(0, 1)
          |> qcheck.map(fn(n) { StartDaemon(n * 2) }),
      ),
      #(4, qcheck.constant(StopDaemon)),
    ],
  )
}

fn describe(command: Command) -> String {
  string.inspect(command)
}

fn spec(start: Start) -> statem.Spec(Model, Command, World) {
  statem.Spec(
    initial: start_model(start),
    command:,
    precondition:,
    next_model:,
    new_sut: fn() { start_world(start) },
    execute:,
    finish: fn(_world, _model) { Ok(Nil) },
    teardown: fn(_) { Nil },
  )
}

fn campaign(start: Start) -> Nil {
  let config =
    statem.default_config(seed:)
    |> statem.with_test_count(300)
    |> statem.with_max_commands(40)

  case statem.check(spec(start), config) {
    Ok(Nil) -> Nil
    Error(failure) -> {
      io.println_error(statem.report(failure, describe))
      panic as "stateful property failed"
    }
  }
}

pub fn guests_follow_the_model_in_an_empty_file_test() {
  campaign(Start(NoDeployment, NoSquatter))
}

pub fn guests_follow_the_model_beside_a_ledger_deployment_test() {
  campaign(Start(LedgerDeployment, NoSquatter))
}

pub fn guests_follow_the_model_when_a_trusted_row_has_the_first_guests_name_test() {
  campaign(Start(NoDeployment, TrustedRowForFirst))
}

pub fn guests_follow_the_model_beside_a_ledger_and_a_squatting_row_test() {
  campaign(Start(LedgerDeployment, TrustedRowForFirst))
}

// --- scripted schedules through the same rules --------------------------------------------------------

fn replay(
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

const plain = Start(NoDeployment, NoSquatter)

const ledger = Start(LedgerDeployment, NoSquatter)

pub fn the_first_untrusted_guest_stops_an_idle_daemon_test() {
  let assert Ok(#(world, _)) =
    replay(plain, [StartDaemon(0), Up(0, Some(Untrusted))])
  assert world.daemon == WorldDown
  assert world.link_home
}

pub fn a_busy_daemon_is_left_stale_until_it_restarts_test() {
  let assert Ok(#(stale, _)) =
    replay(plain, [StartDaemon(2), Up(0, Some(Untrusted))])
  assert stale.daemon == WorldUp(2, [])

  // A restart reads the row, and the daemon is current again.
  let assert Ok(#(current, _)) =
    replay(plain, [
      StartDaemon(2),
      Up(0, Some(Untrusted)),
      StopDaemon,
      StartDaemon(2),
    ])
  assert current.daemon != WorldDown
}

pub fn a_resume_that_changes_no_row_touches_no_daemon_test() {
  let assert Ok(#(world, _)) =
    replay(plain, [
      Up(0, Some(Untrusted)),
      Down(0),
      StartDaemon(2),
      Up(0, None),
    ])
  assert world.daemon == WorldUp(2, untrusted_rows(world.config))
}

pub fn a_taken_port_moves_the_row_and_asks_the_daemon_to_restart_test() {
  let assert Ok(#(before, _)) =
    replay(plain, [Up(0, Some(Untrusted)), Down(0), StartDaemon(2)])
  let assert Ok(#(after, _)) =
    replay(plain, [
      Up(0, Some(Untrusted)),
      Down(0),
      PortTaken(0),
      StartDaemon(2),
      Up(0, None),
    ])

  // The row names a new port, the record agrees, and the busy daemon is stale.
  assert untrusted_rows(after.config) != untrusted_rows(before.config)
  assert after.daemon == WorldUp(2, untrusted_rows(before.config))
}

pub fn a_ledger_deployment_is_left_exactly_as_it_was_test() {
  let assert Ok(#(world, _)) =
    replay(ledger, [
      Up(0, Some(Untrusted)),
      Up(1, Some(Untrusted)),
      Down(0),
      Rm(0),
    ])
  assert string.starts_with(world.config, start_config(ledger))
  assert dict.has_key(document(world.config), "distribution")
}

pub fn removing_the_last_untrusted_guest_removes_the_link_table_test() {
  let assert Ok(#(world, _)) =
    replay(plain, [Up(0, Some(Untrusted)), Down(0), Rm(0)])
  assert !dict.has_key(document(world.config), "executor_link")
  assert !world.link_home
}

pub fn a_guest_is_refused_the_other_link_and_changes_nothing_test() {
  let assert Ok(#(first, _)) = replay(plain, [Up(0, Some(Untrusted)), Down(0)])
  let assert Ok(#(second, _)) =
    replay(plain, [Up(0, Some(Untrusted)), Down(0), Up(0, Some(Distribution))])
  assert second == first
}

pub fn a_trusted_row_of_the_guests_name_refuses_it_and_leaves_no_guest_test() {
  let assert Ok(#(world, _)) =
    replay(Start(NoDeployment, TrustedRowForFirst), [
      Up(0, Some(Untrusted)),
    ])
  assert world.slots == [WorldAbsent, WorldAbsent, WorldAbsent]
  assert !dict.has_key(document(world.config), "executor_link")
  assert world.config == start_config(Start(NoDeployment, TrustedRowForFirst))
}
