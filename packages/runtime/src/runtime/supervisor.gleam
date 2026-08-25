//// The SessionSupervisor: the OTP tree that turns an open session into a
//// living one.
////
//// Shape (design §4.1): a rest-for-one supervisor over five children, in
//// order —
////
//// 1. the **strand registry** (name ↔ process-name map, so restarts keep
////    every strand addressable),
//// 2. the **StorageWriter**,
//// 3. the **StrandSupervisor** — a factory (simple-one-for-one) of strand
////    drivers, one per strand, restarted individually on crash,
//// 4. the **subagent StrandSupervisor** — a second factory, with its own
////    restart tolerance, for strands a model spawned,
//// 5. the **strand booter** — a worker whose start lists the `strand.*`
////    registers in the store and starts a driver for every strand found.
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
//// The writer and each strand register under stable process names owned
//// by the registry, so the tree's callers hold names, not pids.

import core/register
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor as sup
import gleam/otp/supervision
import runtime/internal/ffi_sup
import runtime/registry
import runtime/strand_runtime
import runtime/writer

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
/// per-strand driver template — its `strand` and `writer` fields are
/// replaced per spawned strand by the factory, so the same effects,
/// stream options, retry policy, and poll interval serve every strand
/// while each strand's model identity stays durable in its own
/// `strand.config` register; `subagent` decides, by name alone, which of
/// the two factories starts a strand, and must be a pure total function
/// giving the same answer for the same name at every reboot (the booter
/// re-asks it for every strand on every restart); `subagent_tolerance`
/// governs the subagent factory only.
pub type Config {
  Config(
    writer_options: writer.Options,
    strand_options: strand_runtime.Options,
    tolerance: Tolerance,
    subagent: fn(String) -> Bool,
    subagent_tolerance: Tolerance,
  )
}

/// A running session tree: the supervisor pid and the stable names of
/// its members.
pub type SessionTree {
  SessionTree(
    supervisor: Pid,
    writer: Name(writer.Message),
    registry: Name(registry.Message),
    strands: Name(
      factory_supervisor.Message(String, Subject(strand_runtime.Message)),
    ),
    subagent_strands: Name(
      factory_supervisor.Message(String, Subject(strand_runtime.Message)),
    ),
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
  let registry_name = process.new_name(prefix: "loom_registry")
  let writer_name = process.new_name(prefix: "loom_writer")
  let strands_name = process.new_name(prefix: "loom_strands")
  let subagent_strands_name = process.new_name(prefix: "loom_subagent_strands")
  let template =
    strand_runtime.Options(..config.strand_options, writer: writer_name)
  let factory = fn(strand_name) {
    let name =
      registry.ensure(process.named_subject(registry_name), strand_name)
    strand_runtime.start(
      strand_runtime.Options(..template, strand: strand_name),
      name,
    )
  }
  let tree =
    sup.new(sup.RestForOne)
    |> sup.restart_tolerance(
      intensity: config.tolerance.intensity,
      period: config.tolerance.period,
    )
    |> sup.add(registry.supervised(registry_name))
    |> sup.add(writer.supervised(config.writer_options, writer_name))
    |> sup.add(
      factory_supervisor.worker_child(factory)
      |> factory_supervisor.restart_tolerance(
        intensity: config.tolerance.intensity,
        period: config.tolerance.period,
      )
      |> factory_supervisor.named(strands_name)
      |> factory_supervisor.supervised,
    )
    |> sup.add(
      factory_supervisor.worker_child(factory)
      |> factory_supervisor.restart_tolerance(
        intensity: config.subagent_tolerance.intensity,
        period: config.subagent_tolerance.period,
      )
      |> factory_supervisor.named(subagent_strands_name)
      |> factory_supervisor.supervised,
    )
    |> sup.add(
      supervision.worker(fn() {
        booter_start(
          writer_name,
          registry_name,
          strands_name,
          subagent_strands_name,
          config.subagent,
        )
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
      process.unlink(started.pid)
      Ok(SessionTree(
        supervisor: started.pid,
        writer: writer_name,
        registry: registry_name,
        strands: strands_name,
        subagent_strands: subagent_strands_name,
        subagent: config.subagent,
      ))
    }
    Error(error) -> Error(error)
  }
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
/// Blocks until the supervisor pid is gone, or `grace_ms` elapses. A
/// supervisor that will not answer, or will not finish inside the
/// grace, is killed: the caller's next act is usually to release the
/// writer lease, and a tree that refuses to stop must not hold that up.
/// Idempotent — a tree that is already dead returns at once.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.shutdown(tree, grace_ms: 5000)
/// ```
///
pub fn shutdown(tree: SessionTree, grace_ms grace_ms: Int) -> Nil {
  case process.is_alive(tree.supervisor) {
    False -> Nil
    True -> {
      case ffi_sup.terminate_supervisor(tree.supervisor, grace_ms) {
        Ok(Nil) -> Nil
        Error(Nil) -> process.kill(tree.supervisor)
      }
      await_death(tree.supervisor, grace_ms)
    }
  }
}

// Waits out a terminating supervisor in 5 ms slices, killing it if the
// grace is spent. Polling rather than monitoring keeps this callable
// from any process, including one that is already selecting on its own
// mailbox.
fn await_death(supervisor: Pid, remaining_ms: Int) -> Nil {
  case process.is_alive(supervisor) {
    False -> Nil
    True ->
      case remaining_ms <= 0 {
        True -> process.kill(supervisor)
        False -> {
          process.sleep(5)
          await_death(supervisor, remaining_ms - 5)
        }
      }
  }
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
fn factory_for(
  tree: SessionTree,
  strand: String,
) -> Name(factory_supervisor.Message(String, Subject(strand_runtime.Message))) {
  case tree.subagent(strand) {
    True -> tree.subagent_strands
    False -> tree.strands
  }
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
  case registry.lookup(process.named_subject(tree.registry), strand) {
    Ok(name) -> Ok(process.named_subject(name))
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
  writer_name: Name(writer.Message),
  registry_name: Name(registry.Message),
  strands_name: Name(
    factory_supervisor.Message(String, Subject(strand_runtime.Message)),
  ),
  subagent_strands_name: Name(
    factory_supervisor.Message(String, Subject(strand_runtime.Message)),
  ),
  subagent: fn(String) -> Bool,
) -> actor.StartResult(Subject(Nil)) {
  case
    boot_strands(
      writer_name,
      registry_name,
      strands_name,
      subagent_strands_name,
      subagent,
    )
  {
    Ok(Nil) ->
      actor.new(Nil)
      |> actor.on_message(fn(state, _message: Nil) { actor.continue(state) })
      |> actor.start
    Error(reason) -> Error(actor.InitFailed(reason))
  }
}

fn boot_strands(
  writer_name: Name(writer.Message),
  registry_name: Name(registry.Message),
  strands_name: Name(
    factory_supervisor.Message(String, Subject(strand_runtime.Message)),
  ),
  subagent_strands_name: Name(
    factory_supervisor.Message(String, Subject(strand_runtime.Message)),
  ),
  subagent: fn(String) -> Bool,
) -> Result(Nil, String) {
  let w = process.named_subject(writer_name)
  case writer.list_registers(w, register.StrandConfig, None) {
    Error(_error) -> Error("the strand booter could not list strand configs")
    Ok(cells) ->
      cells
      |> list.try_each(fn(cell) {
        let #(strand_name, _register) = cell
        let factory_name = case subagent(strand_name) {
          True -> subagent_strands_name
          False -> strands_name
        }
        case ensure_strand_running(registry_name, factory_name, strand_name) {
          Ok(Nil) -> Ok(Nil)
          Error(_error) ->
            Error("the strand booter could not start strand " <> strand_name)
        }
      })
  }
}

fn ensure_strand_running(
  registry_name: Name(registry.Message),
  strands_name: Name(
    factory_supervisor.Message(String, Subject(strand_runtime.Message)),
  ),
  strand: String,
) -> Result(Nil, actor.StartError) {
  let reg = process.named_subject(registry_name)
  let name = registry.ensure(reg, strand)
  case alive(name) {
    True -> Ok(Nil)
    // Sending into an unregistered name crashes the sender, and this is
    // called from `api.create_strand` on a tool's effect process: a spawn
    // racing a factory restart would take that process down and settle as
    // a synthetic tool failure rather than as a worded refusal. The guard
    // costs one liveness check and reads far better in the logs.
    False ->
      case factory_alive(strands_name) {
        False ->
          Error(actor.InitFailed(
            "the strand factory is restarting; retry the start",
          ))
        True ->
          case
            factory_supervisor.start_child(
              factory_supervisor.get_by_name(strands_name),
              strand,
            )
          {
            Ok(_started) -> Ok(Nil)
            // A concurrent starter won the race: the strand is running.
            Error(error) ->
              case alive(name) {
                True -> Ok(Nil)
                False -> Error(error)
              }
          }
      }
  }
}

fn alive(name: Name(strand_runtime.Message)) -> Bool {
  case process.subject_owner(process.named_subject(name)) {
    Ok(pid) -> process.is_alive(pid)
    Error(Nil) -> False
  }
}

fn factory_alive(
  name: Name(
    factory_supervisor.Message(String, Subject(strand_runtime.Message)),
  ),
) -> Bool {
  case process.subject_owner(process.named_subject(name)) {
    Ok(pid) -> process.is_alive(pid)
    Error(Nil) -> False
  }
}
