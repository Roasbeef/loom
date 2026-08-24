//// The SessionSupervisor: the OTP tree that turns an open session into a
//// living one.
////
//// Shape (design §4.1): a rest-for-one supervisor over four children, in
//// order —
////
//// 1. the **strand registry** (name ↔ process-name map, so restarts keep
////    every strand addressable),
//// 2. the **StorageWriter**,
//// 3. the **StrandSupervisor** — a factory (simple-one-for-one) of strand
////    drivers, one per strand, restarted individually on crash,
//// 4. the **strand booter** — a worker whose start lists the `strand.*`
////    registers in the store and starts a driver for every strand found.
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
/// `strand.config` register.
pub type Config {
  Config(
    writer_options: writer.Options,
    strand_options: strand_runtime.Options,
    tolerance: Tolerance,
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
  let template =
    strand_runtime.Options(..config.strand_options, writer: writer_name)
  let tree =
    sup.new(sup.RestForOne)
    |> sup.restart_tolerance(
      intensity: config.tolerance.intensity,
      period: config.tolerance.period,
    )
    |> sup.add(registry.supervised(registry_name))
    |> sup.add(writer.supervised(config.writer_options, writer_name))
    |> sup.add(
      factory_supervisor.worker_child(fn(strand_name) {
        let name =
          registry.ensure(process.named_subject(registry_name), strand_name)
        strand_runtime.start(
          strand_runtime.Options(..template, strand: strand_name),
          name,
        )
      })
      |> factory_supervisor.restart_tolerance(
        intensity: config.tolerance.intensity,
        period: config.tolerance.period,
      )
      |> factory_supervisor.named(strands_name)
      |> factory_supervisor.supervised,
    )
    |> sup.add(
      supervision.worker(fn() {
        booter_start(writer_name, registry_name, strands_name)
      }),
    )
    |> sup.start
  case tree {
    Ok(started) -> {
      // The starter owns the tree through this record, not through the
      // start link: unlinking lets `api.close` (and the interleave
      // harness) kill the tree without taking the owner down with it.
      // A serving layer roots trees under an application supervisor
      // instead.
      process.unlink(started.pid)
      Ok(SessionTree(
        supervisor: started.pid,
        writer: writer_name,
        registry: registry_name,
        strands: strands_name,
      ))
    }
    Error(error) -> Error(error)
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
  ensure_strand_running(tree.registry, tree.strands, strand)
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
) -> actor.StartResult(Subject(Nil)) {
  case boot_strands(writer_name, registry_name, strands_name) {
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
) -> Result(Nil, String) {
  let w = process.named_subject(writer_name)
  case writer.list_registers(w, register.StrandConfig, None) {
    Error(_error) -> Error("the strand booter could not list strand configs")
    Ok(cells) ->
      cells
      |> list.try_each(fn(cell) {
        let #(strand_name, _register) = cell
        case ensure_strand_running(registry_name, strands_name, strand_name) {
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
    False ->
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

fn alive(name: Name(strand_runtime.Message)) -> Bool {
  case process.subject_owner(process.named_subject(name)) {
    Ok(pid) -> process.is_alive(pid)
    Error(Nil) -> False
  }
}
