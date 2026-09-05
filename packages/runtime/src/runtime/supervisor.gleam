//// The SessionSupervisor: the OTP tree that turns an open session into a
//// living one.
////
//// Shape (design §4.1): a rest-for-one supervisor over six children, in
//// order —
////
//// 1. the **drain ledger** (logical strand → live effect reapers),
//// 2. the **strand registry** (strand ↔ reference address, so restarts keep
////    every strand addressable),
//// 3. the **StorageWriter**,
//// 4. the **StrandSupervisor** — a factory (simple-one-for-one) of strand
////    drivers, one per strand, restarted individually on crash,
//// 5. the **subagent StrandSupervisor** — a second factory, with its own
////    restart tolerance, for strands a model spawned,
//// 6. the **strand booter** — a worker whose start lists the `strand.*`
////    registers in the store and starts a driver for every strand found.
////
//// ## Why the drain ledger is separate
////
//// The name registry is meant to restart: rest-for-one then rebuilds the
//// writer and every driver beneath it. Effect reapers have the opposite
//// requirement. They must remain discoverable while those old drivers die,
//// or a replacement can replay durable work beside an undrained predecessor.
//// The drain ledger therefore precedes the name registry and survives its
//// restart. It is a significant temporary child: if the ledger itself dies,
//// the supervisor stops the whole session instead of restarting with an empty
//// ownership history.
////
//// ## Why subagents get their own factory
////
//// A strand whose register fails a total decode faults, restarts, and
//// faults again until its factory's tolerance is spent; the factory then
//// dies, and rest-for-one restarts *everything after it*. With one
//// factory that is every driver in the session — a model-spawned strand
//// in a crash loop reboots the strand a human is talking to, and spends
//// the restart budget that protects it. Letting a model spawn strands
//// multiplies the number of strands that can do this.
////
//// Splitting the factory bounds the blast radius by ordering: the
//// subagent factory sits *after* the primary one, so a subagent crash
//// loop restarts only the subagent factory and the booter, leaving the
//// primary factory's children — `main` — untouched. The reverse
//// containment is deliberately not claimed: a primary-factory failure
//// still restarts the subagent factory beneath it, which is the correct
//// direction for a session whose principal strand is in trouble.
////
//// `Config.subagent` decides which factory a name goes to. The runtime
//// has no idea which strands a model spawned — lineage is the Agency's
//// ledger, one layer up — so the host injects the predicate, and the same
//// host that mints subagent names owns it. The default says no strand is
//// a subagent, which is exactly the single-factory behaviour that came
//// before.
////
//// The booter is what makes recovery boot *all* strands, not just
//// "main": cold open, a writer crash (rest-for-one restarts the factory
//// empty and then the booter repopulates it), and a booter crash all
//// converge on "list the store, start what is missing" — crash recovery
//// and cold start are the same code. Subagent strands created mid-session
//// (`api.create_strand`) seed their registers first, so every reboot
//// finds them.
////
//// Services bind reference addresses in a session-local namespace. Strand
//// drivers bind addresses owned by the restartable registry. Neither path
//// allocates permanent atoms. The drain ledger's direct subject is retained
//// separately, so losing routing cannot erase the shutdown witness.

import core/register
import gleam/bool
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor as sup
import gleam/otp/supervision
import gleam/result
import runtime/internal/drain_registry
import runtime/internal/ffi_sup
import runtime/registry
import runtime/strand_runtime
import runtime/writer
import weft
import weft/registry as address

/// Restart-tolerance settings for the supervisors in the tree.
///
/// Constructor invariants: `intensity` restarts within `period` seconds
/// before the supervisor gives up (both positive). Tests that script
/// repeated crashes raise the intensity; production keeps it low so a
/// deterministic fault (corrupt restore) surfaces as a dead tree rather
/// than a restart storm.
pub type Tolerance {
  Tolerance(intensity: Int, period: Int)
}

/// Everything needed to boot one session tree.
///
/// Constructor invariants: `writer_options.session` is an open session
/// this tree becomes the sole committer for; `strand_options` is the
/// per-strand driver template, constructed only once the real writer address
/// and drain claim exist. Its `strand` is replaced per spawned strand by the
/// factory, so the same effects, stream options, retry policy, and poll
/// interval serve every strand
/// while each strand's model identity stays durable in its own
/// `strand.config` register; `subagent` decides, by name alone, which of
/// the two factories starts a strand, and must be a pure total function
/// giving the same answer for the same name at every reboot (the booter
/// re-asks it for every strand on every restart); `subagent_tolerance`
/// governs the subagent factory only.
pub type Config {
  Config(
    writer_options: writer.Options,
    strand_options: fn(
      address.Address(writer.Message),
      fn(String, Pid) -> List(Pid),
    ) -> strand_runtime.Options,
    tolerance: Tolerance,
    subagent: fn(String) -> Bool,
    subagent_tolerance: Tolerance,
  )
}

/// A running session tree: its root, service addresses, and factory slots.
pub type SessionTree {
  SessionTree(
    /// The root supervisor whose death ends ordinary session liveness.
    supervisor: Pid,
    /// The direct drain-ledger handle retained across root and namespace death.
    drains: Subject(drain_registry.Message),
    /// The reclaimable address of the session's sole durable writer.
    writer: address.Address(writer.Message),
    /// The address of the logical-strand and factory-handle registry.
    registry: address.Address(registry.Message),
    /// The service namespace, reclaimed when its runtime root exits.
    namespace: address.Registry,
    /// The primary-strand dynamic supervisor's registry slot.
    strands: registry.FactoryKind,
    /// The separately budgeted subagent factory's registry slot.
    subagent_strands: registry.FactoryKind,
    /// The pure classification used to choose one of the two factories.
    subagent: fn(String) -> Bool,
  )
}

/// Boots the tree: registry, writer, strand factory, then the booter,
/// which starts a driver for every strand the store knows. Each driver
/// immediately drives whatever its registers say, so opening a session
/// with crashed-open operations resumes all of them.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.start(config)
/// ```
///
pub fn start(config: Config) -> Result(SessionTree, actor.StartError) {
  start_published(config, fn(_tree) { Ok(Nil) })
}

/// Publishes the root and its drain witness before any writer or driver starts.
///
/// The callback runs once, in the root's first child-start callback. It must
/// only transfer custody, not call a writer or synchronously close the root:
/// those operations require this startup callback to return. Refusal prevents
/// recovery. Restarts below the drain ledger retain the original publication.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.start_published(config, fn(tree) { retain_custody(tree) })
/// ```
@internal
pub fn start_published(
  config: Config,
  publish: fn(SessionTree) -> Result(Nil, String),
) -> Result(SessionTree, actor.StartError) {
  use namespace <- result.try(
    address.start() |> result.map_error(actor.InitFailed),
  )
  let drains_name = address.new_address(namespace)
  let registry_name = address.new_address(namespace)
  let writer_name = address.new_address(namespace)
  let describe_tree = fn(root, drains) {
    SessionTree(
      supervisor: root,
      drains:,
      writer: writer_name,
      registry: registry_name,
      namespace:,
      strands: registry.Primary,
      subagent_strands: registry.Subagent,
      subagent: config.subagent,
    )
  }
  let factory = fn(strand_name) {
    use reg <- result.try(registry_subject(registry_name))
    use drains <- result.try(
      address.lookup(drains_name)
      |> result.replace_error(actor.InitFailed(
        "the drain ledger is unavailable",
      )),
    )
    let template =
      config.strand_options(writer_name, fn(strand, reaper) {
        drain_registry.claim(drains, strand, reaper)
      })
    let name = registry.ensure(reg, strand_name)
    strand_runtime.start(
      strand_runtime.Options(..template, strand: strand_name),
      name,
    )
  }
  let tree =
    sup.new(sup.RestForOne)
    |> sup.auto_shutdown(sup.AnySignificant)
    |> sup.restart_tolerance(
      intensity: config.tolerance.intensity,
      period: config.tolerance.period,
    )
    |> sup.add(
      supervision.supervisor(fn() {
        use started <- result.try(drain_registry.start(drains_name))

        // OTP invokes child-start callbacks in the root itself. Publish the
        // exact root and direct witness before returning the first child;
        // no later child can execute while custody is being acknowledged.
        let tree = describe_tree(process.self(), started.data)
        retain_namespace(namespace, tree.supervisor)
        use Nil <- result.try(
          publish(tree) |> result.map_error(actor.InitFailed),
        )
        Ok(started)
      })
      |> supervision.restart(supervision.Temporary)
      |> supervision.significant(True),
    )
    |> sup.add(registry.supervised(registry_name))
    |> sup.add(writer.supervised(config.writer_options, writer_name))
    |> sup.add(
      factory_supervisor.worker_child(factory)
      |> factory_supervisor.restart_tolerance(
        intensity: config.tolerance.intensity,
        period: config.tolerance.period,
      )
      |> registered_factory(registry_name, registry.Primary),
    )
    |> sup.add(
      factory_supervisor.worker_child(factory)
      |> factory_supervisor.restart_tolerance(
        intensity: config.subagent_tolerance.intensity,
        period: config.subagent_tolerance.period,
      )
      |> registered_factory(registry_name, registry.Subagent),
    )
    |> sup.add(
      supervision.worker(fn() {
        booter_start(writer_name, registry_name, config.subagent)
      }),
    )
    |> sup.start
  case tree {
    Ok(started) -> {
      // The starter owns the tree through this record, not through the
      // start link: unlinking lets `shutdown` (and the interleave
      // harness's kills) take the tree down without taking the owner
      // with it. A serving layer that wants to hear about the tree's
      // death monitors `SessionTree.supervisor` — `client/host` does.
      use drains <- result.try(
        address.lookup(drains_name)
        |> result.map_error(fn(_missing) {
          // No live handle may escape from a partially failed boot. Stopping
          // the root does not certify drain or release the caller's lease.
          process.unlink(started.pid)
          let _drained = stop_root(started.pid, Error(Nil), 5000)
          let _stopped = address.stop(namespace)
          actor.InitFailed("the drain ledger died during startup")
        }),
      )
      process.unlink(started.pid)
      Ok(describe_tree(started.pid, drains))
    }
    Error(error) -> {
      let _stopped = address.stop(namespace)
      Error(error)
    }
  }
}

// Routing owns no effects. The root's death therefore ends this namespace's
// useful lifetime even when the direct drain-ledger handle still witnesses
// external work. A Weft leaf task performs that cleanup without a custom
// monitor loop, including roots killed outside the ordinary close path.
fn retain_namespace(namespace: address.Registry, root: Pid) -> Nil {
  let _custody =
    weft.new_prepared([
      weft.prepared_leaf(
        owner: address.owner(namespace),
        cancel: fn() {
          let _stopped = address.stop(namespace)
          Nil
        },
        begin: fn() { Ok(Nil) },
      ),
    ])
    |> weft.cancel_when_exits(root)
    |> weft.start_witnessed
  Nil
}

// Publishing inside the child start callback orders discovery before the
// booter can use it. The registry outlives both factories and is rebuilt
// before them when rest-for-one restarts its own boundary.
fn registered_factory(
  builder: factory_supervisor.Builder(String, Subject(strand_runtime.Message)),
  registry_name: address.Address(registry.Message),
  kind: registry.FactoryKind,
) -> supervision.ChildSpecification(
  factory_supervisor.Supervisor(String, Subject(strand_runtime.Message)),
) {
  supervision.supervisor(fn() {
    use reg <- result.try(registry_subject(registry_name))
    use started <- result.try(factory_supervisor.start(builder))
    registry.publish_factory(
      reg,
      kind,
      registry.Factory(started.pid, started.data),
    )
    Ok(started)
  })
}

/// Stops the tree the way OTP stops a supervision tree: children are
/// terminated in reverse start order — booter, subagent factory, strand
/// factory, writer, registry — each given the ordinary `shutdown` exit
/// and its child spec's grace period, and the supervisor then exits with
/// reason `shutdown` rather than `kill`. Every strand driver is
/// therefore gone before the writer it commits through, so nothing can
/// be mid-commit when the writer goes, and no supervisor report is
/// logged for a shutdown that was asked for.
///
/// `grace_ms` bounds the `sys:terminate` handshake, not provider teardown.
/// Once shutdown begins, this waits until the supervisor PID is gone. The
/// drain ledger is an unbounded-shutdown child and will not let that happen
/// while an incarnation reaper still owns provider work. Killing the root on
/// expiry would erase the only barrier that makes releasing the writer lease
/// safe. The drain ledger is monitored before root termination and its exit
/// reason is checked independently because it can outlive an abnormally killed
/// root. `Error(Nil)` means no live ledger could be captured or that ledger
/// died without the clean `normal`/OTP `shutdown` acknowledgement.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.shutdown(tree, grace_ms: 5000)
/// ```
///
pub fn shutdown(tree: SessionTree, grace_ms grace_ms: Int) -> Result(Nil, Nil) {
  let witness = watch_drains(tree.drains)
  let drained = stop_root(tree.supervisor, witness, grace_ms)
  let _stopped = address.stop(tree.namespace)
  drained
}

// Capture the ledger before shutdown, but keep an absent witness as a failed
// proof rather than using it to skip the root's teardown and routing cleanup.
fn watch_drains(
  drains: Subject(drain_registry.Message),
) -> Result(DrainWitness, Nil) {
  use drain_owner <- result.try(process.subject_owner(drains))
  use <- bool.guard(when: !process.is_alive(drain_owner), return: Error(Nil))
  Ok(register_drain_witness(drain_owner))
}

fn stop_root(
  root: Pid,
  witness: Result(DrainWitness, Nil),
  grace_ms: Int,
) -> Result(Nil, Nil) {
  case process.is_alive(root) {
    True -> {
      let _termination = ffi_sup.terminate_supervisor(root, grace_ms)
      Nil
    }
    False -> Nil
  }
  await_death(root)
  use witness <- result.try(witness)
  await_drain_witness(witness)
}

type DrainWitness {
  DrainWitness(monitor: Monitor, owner: Pid)
}

fn register_drain_witness(owner: Pid) -> DrainWitness {
  let monitor = process.monitor(owner)
  DrainWitness(monitor:, owner:)
}

fn await_drain_witness(witness: DrainWitness) -> Result(Nil, Nil) {
  let down =
    process.new_selector()
    |> process.select_specific_monitor(witness.monitor, fn(down) { down })
    |> process.selector_receive_forever()
  process.demonitor_process(witness.monitor)
  case down {
    process.ProcessDown(pid:, reason: process.Normal, ..)
      if pid == witness.owner
    -> Ok(Nil)
    process.ProcessDown(pid:, reason: process.Abnormal(reason), ..)
      if pid == witness.owner
    ->
      case decode.run(reason, atom.decoder()) {
        Ok(reason) ->
          case atom.to_string(reason) == "shutdown" {
            True -> Ok(Nil)
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    process.ProcessDown(..) | process.PortDown(..) -> Error(Nil)
  }
}

// Polling rather than monitoring keeps shutdown callable from any process,
// including one that is already selecting on its own mailbox.
fn await_death(supervisor: Pid) -> Nil {
  use <- bool.guard(when: !process.is_alive(supervisor), return: Nil)
  process.sleep(5)
  await_death(supervisor)
}

/// Ensures a driver is running for `strand`, starting one through the
/// factory if none is alive. Idempotent: an alive driver is left alone.
/// Used by the booter at every tree (re)boot and by `api.create_strand`
/// for strands born mid-session.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.start_strand(tree, "sub:1")
/// ```
///
pub fn start_strand(
  tree: SessionTree,
  strand: String,
) -> Result(Nil, actor.StartError) {
  ensure_strand_running(tree.registry, factory_for(tree, strand), strand)
}

// Which factory owns a strand. Asked afresh every time rather than
// remembered, so the answer survives a restart without any state of its
// own.
fn factory_for(tree: SessionTree, strand: String) -> registry.FactoryKind {
  case tree.subagent(strand) {
    True -> tree.subagent_strands
    False -> tree.strands
  }
}

/// The current factory process, for observing its restart boundary.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.factory_pid(tree, tree.subagent_strands)
/// ```
pub fn factory_pid(
  tree: SessionTree,
  kind: registry.FactoryKind,
) -> Result(Pid, Nil) {
  use reg <- result.try(address.lookup(tree.registry))
  registry.factory(reg, kind)
  |> result.map(fn(factory) { factory.pid })
}

/// The live driver subject for a strand, when one has been started.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.strand_subject(tree, "main")
/// ```
///
pub fn strand_subject(
  tree: SessionTree,
  strand: String,
) -> Result(Subject(strand_runtime.Message), Nil) {
  use reg <- result.try(address.lookup(tree.registry))
  case registry.lookup(reg, strand) {
    Ok(name) -> address.lookup(name)
    Error(Nil) -> Error(Nil)
  }
}

// --- the strand booter ----------------------------------------------------

// The booter's whole job happens in its start function: list the strands
// the store knows and start a driver for each that is not already alive.
// The process it leaves behind does nothing — it exists so the boot
// re-runs under supervision whenever the children after the writer
// restart.
fn booter_start(
  writer_name: address.Address(writer.Message),
  registry_name: address.Address(registry.Message),
  subagent: fn(String) -> Bool,
) -> actor.StartResult(Subject(Nil)) {
  case boot_strands(writer_name, registry_name, subagent) {
    Ok(Nil) ->
      actor.new(Nil)
      |> actor.on_message(fn(state, _message: Nil) { actor.continue(state) })
      |> actor.start
    Error(reason) -> Error(actor.InitFailed(reason))
  }
}

fn boot_strands(
  writer_name: address.Address(writer.Message),
  registry_name: address.Address(registry.Message),
  subagent: fn(String) -> Bool,
) -> Result(Nil, String) {
  use cells <- result.try(
    writer.list_registers(writer_name, register.StrandConfig, None)
    |> result.replace_error("the strand booter could not list strand configs"),
  )
  list.try_each(cells, fn(cell) {
    let #(strand_name, _register) = cell
    let factory_name = case subagent(strand_name) {
      True -> registry.Subagent
      False -> registry.Primary
    }
    ensure_strand_running(registry_name, factory_name, strand_name)
    |> result.replace_error(
      "the strand booter could not start strand " <> strand_name,
    )
  })
}

fn ensure_strand_running(
  registry_name: address.Address(registry.Message),
  kind: registry.FactoryKind,
  strand: String,
) -> Result(Nil, actor.StartError) {
  use reg <- result.try(registry_subject(registry_name))
  let name = registry.ensure(reg, strand)
  use <- bool.guard(when: alive(name), return: Ok(Nil))

  // Resolve the current typed handle for each start. A dead predecessor is
  // a worded refusal during restart, not a send to an unregistered name.
  use factory <- result.try(
    registry.factory(reg, kind)
    |> result.replace_error(actor.InitFailed(
      "the strand factory is restarting; retry the start",
    )),
  )
  case factory_supervisor.start_child(factory.handle, strand) {
    Ok(_started) -> Ok(Nil)

    // A concurrent starter won the race: the strand is running.
    Error(error) ->
      case alive(name) {
        True -> Ok(Nil)
        False -> Error(error)
      }
  }
}

fn alive(name: address.Address(strand_runtime.Message)) -> Bool {
  address.lookup(name) |> result.is_ok
}

fn registry_subject(
  name: address.Address(registry.Message),
) -> Result(Subject(registry.Message), actor.StartError) {
  address.lookup(name)
  |> result.replace_error(actor.InitFailed(
    "the runtime registry is unavailable",
  ))
}
