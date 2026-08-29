//// A code-mode migration sample: the shape of program a model writes
//// instead of a sequence of tool calls.
////
//// The task is an ordinary migration chore. A symbol is being retired, and
//// the model wants to know how much of it is left in three packages, and
//// whether the tree still builds. As tool calls that is five round trips
//// and five intermediate payloads landing in the conversation — three
//// directory-sized `grep` dumps and two build logs. As a program it is one
//// execution that returns a single line.
////
//// Everything the program is allowed to do is in its first six lines. It
//// can run processes (`cap/proc`), fan out and race them (`cap/task`),
//// return a result (`cap/report`), and do list, string, and integer work.
//// It cannot open a socket, because `cap/net` is not imported and so is
//// not in its build graph; it cannot touch git history, because `cap/git`
//// is not imported either. Vetting confirms both absences before the
//// program compiles, the compiler refuses to resolve what is not in the
//// build graph, and the jailed satellite guarantees no other path exists.
////
//// Three properties of the runtime are on display, and each one is
//// asserted against in `migration_sample_test.gleam` under
//// `packages/codemode/test/`, which submits *this file, verbatim*
//// through the real pipeline:
////
//// 1. **A race with real cancellation.** `task.race` returns the first
////    build strategy to finish; the loser is killed, which makes the cap
////    channel emit a `cancel` for its in-flight `proc.run`, and the broker
////    kills the executor process group behind it. The losing build stops
////    mid-flight rather than grinding on spending pooled budget.
//// 2. **Parallel fan-out with order preservation.** `parallel_map` runs
////    all three sweeps at once, and the results come back in *input*
////    order regardless of which package finished first — so the first
////    element is always `packages/core`'s.
//// 3. **A structured result.** `main` returns a `report.Outcome`. The boot
////    runtime marshals it back as the terminal frame, so the strand
////    receives a value; nothing is scraped from stdout.
////
//// Two things the shipped runtime cannot do yet shape the program.
//// `proc.run` is the only capability the default router services, so the
//// sweep shells out rather than calling `fs.read`; and a program cannot
//// import `core/msgpack` (it is a transitive dependency of the prelude,
//// which the hermetic build refuses), so the richest outcome available is
//// `report.text`. See `docs/architecture/code-mode.md`.

import cap/proc
import cap/report
import cap/task
import gleam/int
import gleam/list
import gleam/string

/// The symbol being retired.
const symbol = "deprecated_decode"

/// The packages to sweep, in the order the report should list them.
const packages = ["packages/core", "packages/broker", "packages/runtime"]

pub fn main() -> report.Outcome {
  // Two ways to confirm the tree still builds, started together. The
  // first to finish wins and the other is cancelled where it stands.
  let build =
    task.race([
      fn() { proc.run(proc.command(["/bin/sh", "tools/build-quick"])) },
      fn() { proc.run(proc.command(["/bin/sh", "tools/build-thorough"])) },
    ])

  // One sweep per package, all at once. Each is its own `cap_call`, each
  // checked against policy, all drawing on one pooled budget — and the
  // results arrive in `packages` order however they finish.
  let sweeps =
    task.parallel_map(packages, max_concurrency: 3, with: fn(dir) {
      proc.run(proc.command(["/bin/sh", "tools/sweep", symbol, dir]))
    })

  case build, sweeps {
    Ok(built), Ok(outputs) -> report_commands(built, outputs)
    Error(_failure), _ -> report.failure("no build strategy finished")
    _, Error(_failures) -> report.failure("the sweep did not settle")
  }
}

fn report_commands(
  built: proc.Output,
  outputs: List(proc.Output),
) -> report.Outcome {
  case
    built.exit_code == 0
    && list.all(outputs, fn(output) { output.exit_code == 0 })
  {
    True ->
      report.text(
        string.join(
          list.map2(packages, outputs, fn(dir, output) {
            dir <> "=" <> int.to_string(match_count(output.stdout))
          }),
          " ",
        )
        <> " build="
        <> string.trim(built.stdout)
        <> " exit="
        <> int.to_string(built.exit_code),
      )
    False -> report.failure(command_failure(built, outputs))
  }
}

fn command_failure(built: proc.Output, outputs: List(proc.Output)) -> String {
  "command failed: build exit="
  <> int.to_string(built.exit_code)
  <> " stderr="
  <> string.trim(built.stderr)
  <> "; sweeps: "
  <> string.join(
    list.map2(packages, outputs, fn(dir, output) {
      dir
      <> " exit="
      <> int.to_string(output.exit_code)
      <> " stderr="
      <> string.trim(output.stderr)
    }),
    "; ",
  )
}

/// How many files one sweep listed. The whole file listing stays here, in
/// the program; only the count reaches the conversation.
fn match_count(stdout: String) -> Int {
  stdout
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.length
}
