//// A model-based test of one vm home's guests when some are reached over the
//// untrusted link, driven over the pure decisions of `client/vm_link`.
////
//// The system under test is a `World`: the default `loom.toml` as real text,
//// the records beside each guest, the host ports strangers hold, and the
//// daemon. `up`, `down`, `rm` and the rest run over it by applying the real
//// decisions (`vm_link.settle`, `port_step`, `install`, `uninstall`,
//// `daemon_need`, `staging`, `vm_spec.daemon_step`) to what the world holds and
//// writing back what `vm_cli.bring_up_linked` would write, in the order it
//// writes it: the leaf, the port choice and the merge, the `link` record, the
//// `link-port` record, and last the file. The `Model` is a coarser account of
//// the same machine that advances by plain rules which call none of those
//// decisions, so a decision that drifts from the rules fails the check instead
//// of agreeing with itself.
////
//// There are three guests that can each be reached either way. A configuration
//// may already hold a ledger deployment, a trusted row with the first guest's
//// name, an operator's own `[executor_link]` that names other files, or an
//// operator's own untrusted row that relies on the table `up` adds. A daemon is
//// down, idle or busy, and a stranger can take a guest's port while the guest
//// is down. An `up` can also stop after any step (`UpStopped`), which is what a
//// refusal, a crash or a failed boot does. The properties, by tag:
////
//// - `untouched`: a command on an untrusted guest never changes the
////   `[distribution]` table or any row that is not one of the guests' own.
//// - `link-table`: a guest's row implies `[executor_link]`, the table `up` wrote
////   implies the vm home's credentials, and a table left with no guest is left
////   for an operator's row.
//// - `port-agrees`: every enrolled guest's recorded port and the address of its
////   row name the same loopback port, after every command.
//// - `no-cookie`: what `up` stages for an untrusted guest holds no cookie, no
////   ledger and no `[distribution]` table.
//// - `kind-fixed`: a guest asked for the other link is refused unchanged, and a
////   guest that has a leaf, with or without a record, is never a distribution
////   guest.
//// - `daemon`: a row the daemon has not read stops an idle daemon and leaves a
////   busy one stale, including a row an earlier `up` wrote and a failed boot
////   left unread, and a row it has read touches neither.
//// - `refused`: a trusted row of the guest's name, or an operator's own link
////   table, refuses an untrusted `up` and writes no row.
////
//// The schedules are drawn from a fixed seed, and the same rules run over
//// six starting configurations.

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

// A guest as the world holds it: the records and traces `vm_cli` wrote beside
// it.
type WorldSlot {
  WorldAbsent
  WorldGuest(
    // The `link` record's text, absent for a distribution guest and for a first
    // untrusted run that stopped before it wrote the record.
    link: Option(String),
    // The `link-port` record's text.
    port: Option(String),
    traces: vm_link.Traces,
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

// Whether the guest's row is in the file, and the port it names. An `up` that
// stops after it records a new port leaves the record and the row naming
// different ports until the next `up` moves the row.
type Enrolment {
  EnrolledAt(port: Int)
  NotEnrolled
}

type Slot {
  Absent
  // A first untrusted run that minted its leaf and stopped before recording
  // anything else.
  Stub
  Present(kind: LinkKind, life: Life, port: Option(Int), row: Enrolment)
}

type Daemon {
  DaemonDown
  // Whether it holds sessions, and the guests and ports whose rows it read.
  DaemonUp(busy: Busy, seen: List(#(Int, Int)))
}

type Busy {
  Idle
  Occupied
}

// What a test can see of a daemon: whether it runs, holds sessions, and has read
// the rows the file now holds.
type Observed {
  ObservedDown
  ObservedIdle
  ObservedBusy(stale: Stale)
}

type Stale {
  Current
  Behind
}

type Model {
  Model(
    slots: List(Slot),
    taken: List(Int),
    next: Int,
    daemon: Daemon,
    start: Start,
  )
}

// How far an `up` that stops early got.
type Step {
  AfterLeaf
  AfterKind
  AfterPort
  AfterConfig
}

type Stop {
  RunsOn
  StopsAfter(Step)
}

type Command {
  // `loom vm up`, with `--link` when given. A resume gives none.
  Up(guest: Int, asked: Option(LinkKind))
  // An `up --link untrusted` that stops after a step.
  UpStopped(guest: Int, step: Step)
  Down(guest: Int)
  Rm(guest: Int)
  // A stranger starts listening on the guest's recorded port.
  PortTaken(guest: Int)
  StartDaemon(sessions: Int)
  StopDaemon
}

// How a run begins.
type Start {
  Start(deployment: Deployment, squatter: Squatter, operator: Operator)
}

type Deployment {
  NoDeployment
  LedgerDeployment
}

type Squatter {
  NoSquatter
  TrustedRowForFirst
}

// What the operator wrote of the untrusted link by hand.
type Operator {
  NothingOfTheOperators
  // An `[executor_link]` that names other files.
  OperatorLink
  // An untrusted row that will rely on the table `up` adds.
  OperatorRow
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

const operator_pin =
  "9999999999999999999999999999999999999999999999999999999999999999"

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

const operator_link =
  "[executor_link]
ca = \"/else/ca.pem\"
certificate = \"/else/orchestrator.pem\"
key = \"/else/orchestrator.key\"
"

fn operator_row() -> String {
  "[executors.theirs]\ntrust = \"untrusted\"\naddress = \"127.0.0.1:9000\"\n"
  <> "pin = \""
  <> operator_pin
  <> "\"\n"
}

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
  let operator = case start.operator {
    NothingOfTheOperators -> []
    OperatorLink -> [operator_link]
    OperatorRow -> [operator_row()]
  }
  string.join(list.flatten([[notes], deployment, squatter, operator]), "\n")
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
    start:,
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

// Whether the starting configuration makes an untrusted `up` of the guest
// refuse: a trusted row of its name, or an operator's own link table.
fn refuses(start: Start, guest: Int) -> Bool {
  { start.squatter == TrustedRowForFirst && guest == 0 }
  || start.operator == OperatorLink
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

// Whether a row carries the pin of one of the three guests, which is what makes
// it a guest's own.
fn is_guests(row: tom.Toml) -> Bool {
  case row {
    tom.Table(fields) ->
      case dict.get(fields, "pin") {
        Ok(tom.String(pin)) ->
          list.contains([pin_of(0), pin_of(1), pin_of(2)], pin)
        _ -> False
      }
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
// table and every row that is not one of the guests' own, whether trusted or an
// operator's untrusted one.
fn kept(text: String) -> #(Option(tom.Toml), List(#(String, tom.Toml))) {
  let others =
    rows_of(text)
    |> dict.to_list
    |> list.filter(fn(entry) { !is_guests(entry.1) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  #(option.from_result(dict.get(document(text), "distribution")), others)
}

// The link a guest has, read as `vm_cli.recorded_kind` reads it: from its
// record, and failing that from the traces a first run left.
fn kind_of_slot(slot: WorldSlot) -> Option(LinkKind) {
  case slot {
    WorldAbsent -> None
    WorldGuest(link:, traces:, ..) ->
      option.from_result(vm_link.settle("", link, traces, None))
  }
}

// The port the guest's own row names, when the file has one.
fn row_port(world: World, guest: Int) -> Option(Int) {
  case dict.get(rows_of(world.config), name_of(guest)) {
    Ok(tom.Table(fields) as row) ->
      case is_guests(row), dict.get(fields, "address") {
        True, Ok(tom.String(address)) ->
          case string.split(address, ":") {
            [_, port] -> option.from_result(int.parse(port))
            _ -> None
          }
        _, _ -> None
      }
    _ -> None
  }
}

fn has_row(world: World, guest: Int) -> Bool {
  case dict.get(rows_of(world.config), name_of(guest)) {
    Ok(row) -> is_untrusted(row) && is_guests(row)
    Error(Nil) -> False
  }
}

// The guest as the model would describe it, read from what the world holds.
fn view_of(world: World, guest: Int) -> Slot {
  case at(world.slots, guest, WorldAbsent) {
    WorldAbsent -> Absent
    WorldGuest(link: None, traces: vm_link.LeafTrace, ..) -> Stub
    WorldGuest(port:, life:, ..) as slot -> {
      let kind = option.unwrap(kind_of_slot(slot), Distribution)
      Present(
        kind:,
        life:,
        port: case port {
          Some(text) -> option.from_result(vm_link.decode_port(text))
          None -> None
        },
        row: case kind == Untrusted, row_port(world, guest) {
          True, Some(port) -> EnrolledAt(port)
          _, _ -> NotEnrolled
        },
      )
    }
  }
}

fn enrolled_guests(world: World) -> List(Int) {
  list.filter([0, 1, 2], fn(guest) { has_row(world, guest) })
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
    UpStopped(guest, step) ->
      untrusted_up(world, model, guest, StopsAfter(step))
    Down(guest) -> Ok(with_life(world, guest, Dead))
    Rm(guest) -> execute_rm(world, guest)
    PortTaken(guest) ->
      case view_of(world, guest) {
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

// `up`: the link is settled from the guest's records, its traces and the flag,
// and then the guest is brought up the way its link says.
fn execute_up(
  world: World,
  model: Model,
  guest: Int,
  asked: Option(LinkKind),
) -> Result(World, statem.Violation) {
  let slot = at(world.slots, guest, WorldAbsent)
  let #(record, traces) = case slot {
    WorldAbsent -> #(None, vm_link.NoTraces)
    WorldGuest(link:, traces:, ..) -> #(link, traces)
  }
  let settled = vm_link.settle(name_of(guest), record, traces, asked)

  // A guest whose link differs from the flag is refused and changes nothing.
  case settled, kind_of_slot(slot) {
    Error(_), Some(kind) ->
      case asked {
        Some(wanted) if wanted != kind -> Ok(world)
        _ -> Error(violation("kind-fixed", "refused a settled guest"))
      }
    Error(reason), None ->
      Error(violation("kind-fixed", "refused a new guest: " <> reason))
    Ok(Distribution), _ -> Ok(distribution_up(world, guest))
    Ok(Untrusted), _ -> untrusted_up(world, model, guest, RunsOn)
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
      WorldGuest(None, None, vm_link.DeployTrace, Alive),
    ),
  )
}

// `bring_up_linked`, step by step, as far as `stop` lets it go. Each step
// writes what the real one writes and nothing more, so a stop leaves exactly
// what an interrupted `up` leaves.
fn untrusted_up(
  world: World,
  model: Model,
  guest: Int,
  stop: Stop,
) -> Result(World, statem.Violation) {
  // Step one mints the leaf, and with it the vm home's credentials.
  let slot = case at(world.slots, guest, WorldAbsent) {
    WorldAbsent -> WorldGuest(None, None, vm_link.LeafTrace, Dead)
    WorldGuest(..) as slot -> WorldGuest(..slot, traces: vm_link.LeafTrace)
  }
  let world =
    World(..world, link_home: True, slots: set_at(world.slots, guest, slot))
  case stop {
    StopsAfter(AfterLeaf) -> Ok(world)
    _ -> chosen_and_merged(world, model, guest, slot, stop)
  }
}

// Step two chooses the port and works out the merge, writing nothing.
fn chosen_and_merged(
  world: World,
  model: Model,
  guest: Int,
  slot: WorldSlot,
  stop: Stop,
) -> Result(World, statem.Violation) {
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
  let #(port, next, reserved) = case vm_link.port_step(seen) {
    vm_link.Keep(port) -> #(port, world.next, False)
    vm_link.Reserve -> #(world.next, world.next + 1, True)
  }
  let row = Row(name: name_of(guest), port:, pin: pin_of(guest))

  // The file either takes the row or refuses it, and a refusal is the end.
  case vm_link.install(world.config, files(), row, "loom.toml") {
    Error(_) -> refused(world, model, guest)
    Ok(merged) ->
      recorded_and_written(
        World(..world, next:),
        guest,
        slot,
        stop,
        #(port, reserved),
        merged,
      )
  }
}

// The user's file refused the guest's row. That is expected only when a trusted
// row has the guest's name or an operator's link table differs, and it writes
// no row and records nothing.
fn refused(
  world: World,
  model: Model,
  guest: Int,
) -> Result(World, statem.Violation) {
  case refuses(model.start, guest) {
    True -> Ok(world)
    False ->
      Error(violation("refused", "the file refused an untrusted guest's row"))
  }
}

// Steps three to five record the link, record a new port and write the file,
// and what follows is the staging and the boot.
fn recorded_and_written(
  world: World,
  guest: Int,
  slot: WorldSlot,
  stop: Stop,
  chosen: #(Int, Bool),
  merged: vm_link.Merged,
) -> Result(World, statem.Violation) {
  let #(port, reserved) = chosen
  let with_kind = case slot {
    WorldGuest(..) as found ->
      WorldGuest(..found, link: Some(vm_link.encode_kind(Untrusted)))
    WorldAbsent -> slot
  }
  let with_port = case with_kind, reserved {
    WorldGuest(..) as found, True ->
      WorldGuest(..found, port: Some(vm_link.encode_port(port)))
    _, _ -> with_kind
  }
  let put = fn(world: World, slot: WorldSlot) {
    World(..world, slots: set_at(world.slots, guest, slot))
  }

  case stop {
    StopsAfter(AfterKind) -> Ok(put(world, with_kind))
    StopsAfter(AfterPort) -> Ok(put(world, with_port))
    StopsAfter(AfterConfig) -> written(put(world, with_port), guest, merged)
    _ -> {
      use written <- result.try(written(put(world, with_port), guest, merged))
      Ok(booted(written, guest, merged))
    }
  }
}

// Step five: the file takes the merged text. Nothing it held of anyone else's
// has changed.
fn written(
  world: World,
  guest: Int,
  merged: vm_link.Merged,
) -> Result(World, statem.Violation) {
  use Nil <- result.try(check_kept(world.config, merged.text))
  use Nil <- result.try(check_staged(guest))
  Ok(World(..world, config: merged.text))
}

// What follows a successful boot: the guest is alive, and the daemon is asked
// whether it holds the row, by the decision both `restart_check` and
// `restart_of` take (`vm_link.daemon_need`).
fn booted(world: World, guest: Int, merged: vm_link.Merged) -> World {
  let rows = case merged.change {
    vm_link.Unchanged -> vm_link.RowStanding
    vm_link.Added | vm_link.Moved -> vm_link.RowChanged
  }
  let saw = case world.daemon {
    WorldDown -> vm_link.SawNoDaemon
    WorldUp(rows: held, ..) ->
      vm_link.SawExecutors(list.map(held, fn(row) { row.0 }))
  }
  let daemon = case vm_link.daemon_need(rows, saw, name_of(guest)) {
    vm_link.MustRestart -> after_change(world.daemon)
    vm_link.NeedsNothing -> world.daemon
  }
  World(..with_life(world, guest, Alive), daemon:)
}

// What `up` does about a daemon that has not read a row: stop an idle one and
// leave a busy one.
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
        "an untrusted guest changed a trusted row, an operator's row or the "
          <> "deployment",
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
          Row(name: name_of(guest), port: 1, pin: pin_of(guest)),
          remaining,
          files(),
          "loom.toml",
        )
      {
        Error(reason) -> Error(violation("untouched", reason))
        Ok(removal) -> {
          use Nil <- result.try(check_kept(world.config, removal.text))

          // The credentials go with the last guest, and only when no table
          // names them any more.
          let link_home = case remaining, removal.table {
            vm_link.LastLinked, vm_link.LinkTableGone -> False
            _, _ -> world.link_home
          }
          Ok(
            World(
              ..world,
              config: removal.text,
              slots: set_at(world.slots, guest, WorldAbsent),
              link_home:,
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

fn ours_present(world: World) -> Bool {
  let wanted = dict.get(document(vm_link.link_table(files())), "executor_link")
  dict.get(document(world.config), "executor_link") == wanted
}

fn check_world(world: World) -> Result(World, statem.Violation) {
  let guests = enrolled_guests(world)
  let ours = ours_present(world)

  // A guest's row needs the link table, the table needs the credentials it
  // names, and a table left with no guest is left for an operator's own row.
  let operator_rows =
    list.filter(untrusted_rows(world.config), fn(row) {
      !list.contains(list.map(guests, name_of), row.0)
    })
  use Nil <- result.try(case guests != [] && !ours {
    True -> Error(violation("link-table", "a guest's row has no link table"))
    False -> Ok(Nil)
  })
  use Nil <- result.try(case ours && !world.link_home {
    True ->
      Error(violation(
        "link-table",
        "the link table names credentials that were removed",
      ))
    False -> Ok(Nil)
  })
  let untrusted_guests =
    list.any(world.slots, fn(slot) { kind_of_slot(slot) == Some(Untrusted) })
  use Nil <- result.try(
    case ours && guests == [] && operator_rows == [] && !untrusted_guests {
      True -> Error(violation("link-table", "a link table is left for no one"))
      False -> Ok(Nil)
    },
  )

  // Every guest that is up has a record and a row that name one port. A run
  // that stopped after the record leaves them apart until the next `up`, which
  // is why only a guest that is up is held to it, and no boot ever follows such
  // a stop.
  use Nil <- result.try(
    list.try_each([0, 1, 2], fn(guest) {
      case view_of(world, guest) {
        Present(kind: Untrusted, life: Alive, port:, row:) ->
          case
            row == option.map(port, EnrolledAt) |> option.unwrap(NotEnrolled)
          {
            True -> Ok(Nil)
            False ->
              Error(violation(
                "port-agrees",
                name_of(guest)
                  <> " is up and records "
                  <> string.inspect(port)
                  <> " while its row says "
                  <> string.inspect(row),
              ))
          }
        _ -> Ok(Nil)
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
  let views = list.map([0, 1, 2], view_of(world, _))
  let seen = case world.daemon {
    WorldDown -> ObservedDown
    WorldUp(sessions: 0, ..) -> ObservedIdle
    WorldUp(rows:, ..) ->
      ObservedBusy(case rows == untrusted_rows(world.config) {
        True -> Current
        False -> Behind
      })
  }
  let expected = case model.daemon {
    DaemonDown -> ObservedDown
    DaemonUp(busy: Idle, ..) -> ObservedIdle
    DaemonUp(busy: Occupied, seen: held) ->
      ObservedBusy(case held == model_rows(model) {
        True -> Current
        False -> Behind
      })
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

// The guests with an enrolled untrusted row and the port each row names, in
// guest order, which is what a daemon that starts now reads.
fn model_rows(model: Model) -> List(#(Int, Int)) {
  list.index_map(model.slots, fn(slot, index) {
    case slot {
      Present(kind: Untrusted, row: EnrolledAt(port), ..) -> Ok(#(index, port))
      _ -> Error(Nil)
    }
  })
  |> list.filter_map(fn(entry) { entry })
}

// --- the model's own rules -----------------------------------------------------------------------

fn next_model(model: Model, command: Command) -> Model {
  case command {
    Up(guest, asked) -> model_up(model, guest, asked)
    UpStopped(guest, step) -> model_untrusted(model, guest, StopsAfter(step))
    Down(guest) -> with_life_of(model, guest, Dead)
    Rm(guest) -> Model(..model, slots: set_at(model.slots, guest, Absent))
    PortTaken(guest) ->
      case at(model.slots, guest, Absent) {
        Present(port: Some(port), ..) ->
          Model(..model, taken: [port, ..model.taken])
        _ -> model
      }
    StartDaemon(sessions) ->
      Model(
        ..model,
        daemon: DaemonUp(
          busy: case sessions {
            0 -> Idle
            _ -> Occupied
          },
          seen: model_rows(model),
        ),
      )
    StopDaemon -> Model(..model, daemon: DaemonDown)
  }
}

// The model with the guest alive or dead, and nothing for an absent one.
fn with_life_of(model: Model, guest: Int, life: Life) -> Model {
  case at(model.slots, guest, Absent) {
    Present(kind:, port:, row:, ..) ->
      Model(
        ..model,
        slots: set_at(model.slots, guest, Present(kind:, life:, port:, row:)),
      )
    Absent | Stub -> model
  }
}

fn model_up(model: Model, guest: Int, asked: Option(LinkKind)) -> Model {
  case at(model.slots, guest, Absent) {
    // A new guest takes the flag.
    Absent ->
      case option.unwrap(asked, Distribution) {
        Untrusted -> model_untrusted(model, guest, RunsOn)
        Distribution ->
          Model(
            ..model,
            slots: set_at(
              model.slots,
              guest,
              Present(Distribution, Alive, None, NotEnrolled),
            ),
          )
      }

    // A leaf with no record is an untrusted guest, and is refused the other.
    Stub ->
      case asked {
        Some(Distribution) -> model
        _ -> model_untrusted(model, guest, RunsOn)
      }

    // An existing guest keeps its link and is refused another.
    Present(kind:, ..) ->
      case asked {
        Some(wanted) if wanted != kind -> model
        _ ->
          case kind {
            Distribution -> with_life_of(model, guest, Alive)
            Untrusted -> model_untrusted(model, guest, RunsOn)
          }
      }
  }
}

// An untrusted `up` as the model sees it, as far as `stop` lets it go.
fn model_untrusted(model: Model, guest: Int, stop: Stop) -> Model {
  // The leaf is minted first.
  let slot = case at(model.slots, guest, Absent) {
    Absent -> Stub
    other -> other
  }
  let model = Model(..model, slots: set_at(model.slots, guest, slot))
  case stop, refuses(model.start, guest) {
    StopsAfter(AfterLeaf), _ -> model
    _, True -> model
    _, False -> model_recorded(model, guest, slot, stop)
  }
}

// The port is kept unless a stranger took it, the link is recorded, a new port
// is recorded, and the row is written.
fn model_recorded(model: Model, guest: Int, slot: Slot, stop: Stop) -> Model {
  let #(recorded, row) = case slot {
    Present(port:, row:, ..) -> #(port, row)
    Absent | Stub -> #(None, NotEnrolled)
  }
  let #(port, next, reserved) = case recorded {
    Some(kept) ->
      case list.contains(model.taken, kept) {
        False -> #(kept, model.next, False)
        True -> #(model.next, model.next + 1, True)
      }
    None -> #(model.next, model.next + 1, True)
  }
  let model = Model(..model, next:)
  let with_kind = Present(Untrusted, Dead, recorded, row)
  let with_port = case reserved {
    True -> Present(Untrusted, Dead, Some(port), row)
    False -> with_kind
  }
  let put = fn(model: Model, slot: Slot) {
    Model(..model, slots: set_at(model.slots, guest, slot))
  }
  let enrolled = Present(Untrusted, Dead, Some(port), EnrolledAt(port))

  case stop {
    StopsAfter(AfterKind) -> put(model, with_kind)
    StopsAfter(AfterPort) -> put(model, with_port)
    StopsAfter(AfterConfig) -> put(model, enrolled)
    _ -> {
      // A boot that succeeds asks the daemon whether it holds this row: one
      // that does not is stopped when idle and left stale when busy.
      let model =
        put(model, Present(Untrusted, Alive, Some(port), EnrolledAt(port)))
      Model(..model, daemon: unread(model.daemon, guest, port))
    }
  }
}

// A daemon that has not read the guest's row at its port is stopped when it is
// idle and left behind when it is busy, and one that has is left alone.
fn unread(daemon: Daemon, guest: Int, port: Int) -> Daemon {
  case daemon {
    DaemonDown -> DaemonDown
    DaemonUp(busy:, seen:) ->
      case list.contains(seen, #(guest, port)), busy {
        True, _ -> daemon
        False, Idle -> DaemonDown
        False, Occupied -> daemon
      }
  }
}

fn precondition(model: Model, command: Command) -> statem.Admission {
  let admitted = case command {
    Up(guest, asked) -> {
      let dead = case at(model.slots, guest, Absent) {
        Absent | Stub -> True
        Present(life:, ..) -> life == Dead
      }

      // A trusted row of the first guest's name is only ever met by an
      // untrusted `up`, which refuses it.
      let squatted = model.start.squatter == TrustedRowForFirst && guest == 0
      dead && { !squatted || asked == Some(Untrusted) }
    }
    UpStopped(guest, _) ->
      case at(model.slots, guest, Absent) {
        Absent | Stub -> True
        Present(kind: Untrusted, life: Dead, ..) -> True
        Present(..) -> False
      }
    Down(guest) ->
      case at(model.slots, guest, Absent) {
        Present(life: Alive, ..) -> True
        _ -> False
      }
    Rm(guest) ->
      case at(model.slots, guest, Absent) {
        Present(life: Dead, ..) | Stub -> True
        _ -> False
      }
    PortTaken(guest) ->
      case at(model.slots, guest, Absent) {
        Present(kind: Untrusted, port: Some(_), life: Dead, ..) -> True
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
  let step =
    qcheck.bounded_int(0, 3)
    |> qcheck.map(fn(n) {
      case n {
        0 -> AfterLeaf
        1 -> AfterKind
        2 -> AfterPort
        _ -> AfterConfig
      }
    })
  qcheck.from_weighted_generators(
    #(24, qcheck.map2(guest, asked, fn(index, kind) { Up(index, kind) })),
    [
      #(
        10,
        qcheck.map2(guest, step, fn(index, step) { UpStopped(index, step) }),
      ),
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
  campaign(Start(NoDeployment, NoSquatter, NothingOfTheOperators))
}

pub fn guests_follow_the_model_beside_a_ledger_deployment_test() {
  campaign(Start(LedgerDeployment, NoSquatter, NothingOfTheOperators))
}

pub fn guests_follow_the_model_when_a_trusted_row_has_the_first_guests_name_test() {
  campaign(Start(NoDeployment, TrustedRowForFirst, NothingOfTheOperators))
}

pub fn guests_follow_the_model_beside_a_ledger_and_a_squatting_row_test() {
  campaign(Start(LedgerDeployment, TrustedRowForFirst, NothingOfTheOperators))
}

pub fn guests_follow_the_model_beside_an_operators_own_link_table_test() {
  campaign(Start(LedgerDeployment, NoSquatter, OperatorLink))
}

pub fn guests_follow_the_model_beside_an_operators_own_untrusted_row_test() {
  campaign(Start(NoDeployment, NoSquatter, OperatorRow))
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

const plain = Start(NoDeployment, NoSquatter, NothingOfTheOperators)

const ledger = Start(LedgerDeployment, NoSquatter, NothingOfTheOperators)

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

pub fn a_failed_first_boot_leaves_a_row_the_next_up_finds_unread_test() {
  // The first `up` wrote the row and its boot failed, so no daemon step ran. A
  // daemon that started before the row, and holds no session, is stopped by the
  // next `up` even though the row is unchanged.
  let assert Ok(#(world, _)) =
    replay(plain, [
      StartDaemon(0),
      UpStopped(0, AfterConfig),
      Up(0, None),
    ])
  assert world.daemon == WorldDown

  // A busy one is left running and is stale, which `ensure` turns into a
  // refusal.
  let assert Ok(#(busy, _)) =
    replay(plain, [
      StartDaemon(2),
      UpStopped(0, AfterConfig),
      Up(0, None),
    ])
  assert busy.daemon == WorldUp(2, [])
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

pub fn an_operators_row_keeps_the_table_and_its_credentials_test() {
  let assert Ok(#(world, _)) =
    replay(Start(NoDeployment, NoSquatter, OperatorRow), [
      Up(0, Some(Untrusted)),
      Down(0),
      Rm(0),
    ])

  // The operator's row relies on the table, so neither it nor the files it
  // names are removed with the last guest.
  assert dict.has_key(document(world.config), "executor_link")
  assert world.link_home
  assert untrusted_rows(world.config) |> list.map(fn(row) { row.0 })
    == ["theirs"]
}

pub fn a_guest_is_refused_the_other_link_and_changes_nothing_test() {
  let assert Ok(#(first, _)) = replay(plain, [Up(0, Some(Untrusted)), Down(0)])
  let assert Ok(#(second, _)) =
    replay(plain, [Up(0, Some(Untrusted)), Down(0), Up(0, Some(Distribution))])
  assert second == first
}

pub fn a_run_that_stopped_after_its_leaf_stays_untrusted_when_resumed_flagless_test() {
  // Neither record nor bundles, only the leaf: a flagless `up` must resume the
  // guest as untrusted and never make it a distribution guest.
  let assert Ok(#(world, model)) =
    replay(plain, [UpStopped(0, AfterLeaf), Up(0, None)])
  assert at(model.slots, 0, Absent)
    == Present(Untrusted, Alive, Some(first_port), EnrolledAt(first_port))
  assert view_of(world, 0) == at(model.slots, 0, Absent)
  assert !string.contains(world.config, "peer@127.0.0.1")
}

pub fn a_trusted_row_of_the_guests_name_refuses_it_and_writes_no_row_test() {
  let squatted = Start(NoDeployment, TrustedRowForFirst, NothingOfTheOperators)
  let assert Ok(#(world, _)) = replay(squatted, [Up(0, Some(Untrusted))])

  // The leaf was minted before the file refused the row, so the guest is a
  // stub that a flagless `up` still reads as untrusted, and the file is as it
  // was.
  assert view_of(world, 0) == Stub
  assert !dict.has_key(document(world.config), "executor_link")
  assert world.config == start_config(squatted)
}

pub fn an_operators_own_link_table_refuses_every_guest_test() {
  let operator = Start(NoDeployment, NoSquatter, OperatorLink)
  let assert Ok(#(world, _)) =
    replay(operator, [Up(0, Some(Untrusted)), Up(1, Some(Untrusted))])
  assert world.config == start_config(operator)
  assert enrolled_guests(world) == []
}
