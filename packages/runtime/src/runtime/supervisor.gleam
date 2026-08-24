//// The SessionSupervisor: the OTP tree that turns an open session into a
//// living one.
////
//// Shape (design §4.1): a rest-for-one supervisor whose first child is
//// the StorageWriter and whose second is the StrandSupervisor (a
//// one-for-one supervisor of strand drivers — one driver, "main", in
//// M1). Rest-for-one means a writer crash restarts the writer *and*
//// every strand, while a strand crash restarts only that strand; either
//// way the restarted strand's first drive re-reads its registers and
//// resumes (spec §3.1) — crash recovery and cold start are the same
//// code.
////
//// The writer and each strand register under fresh process names, so
//// restarts keep them addressable: the tree's callers hold names, not
//// pids.

import gleam/erlang/process.{type Name, type Pid}
import gleam/otp/actor
import gleam/otp/static_supervisor as sup
import gleam/otp/supervision
import runtime/strand_runtime
import runtime/writer

/// Restart-tolerance settings for both supervisors in the tree.
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
/// this tree becomes the sole committer for; `strand_options.writer`
/// must be `writer_name` (the constructor `start` wires it).
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
    strand: Name(strand_runtime.Message),
  )
}

/// Boots the tree: writer first, then the strand supervisor. The strand
/// immediately drives whatever its registers say, so opening a session
/// with a crashed-open operation resumes it.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.start(config)
/// ```
///
pub fn start(config: Config) -> Result(SessionTree, actor.StartError) {
  let writer_name = process.new_name(prefix: "loom_writer")
  let strand_name = process.new_name(prefix: "loom_strand")
  let strand_options =
    strand_runtime.Options(..config.strand_options, writer: writer_name)
  let tree =
    sup.new(sup.RestForOne)
    |> sup.restart_tolerance(
      intensity: config.tolerance.intensity,
      period: config.tolerance.period,
    )
    |> sup.add(writer.supervised(config.writer_options, writer_name))
    |> sup.add(
      supervision.supervisor(fn() {
        sup.new(sup.OneForOne)
        |> sup.restart_tolerance(
          intensity: config.tolerance.intensity,
          period: config.tolerance.period,
        )
        |> sup.add(strand_runtime.supervised(strand_options, strand_name))
        |> sup.start
      }),
    )
    |> sup.start
  case tree {
    Ok(started) -> {
      // The starter owns the tree through this record, not through the
      // start link: unlinking lets `api.close` (and the interleave
      // harness) kill the tree without taking the owner down with it.
      // M2's serving layer roots trees under an application supervisor
      // instead.
      process.unlink(started.pid)
      Ok(SessionTree(
        supervisor: started.pid,
        writer: writer_name,
        strand: strand_name,
      ))
    }
    Error(error) -> Error(error)
  }
}
