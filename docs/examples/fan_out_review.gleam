//// A code-mode **orchestration sample**: fan out one reviewer strand per
//// package, join them all against one deadline, and reduce what they
//// found to a single structured result.
////
//// This is the shape the orchestration seam exists for. Written as tool
//// calls it is three `agent_spawn`s and an `agent_wait` — four turns,
//// four round trips, and a plan that exists only as the sequence of
//// decisions a model happened to make. Written as a program it is one
//// execution, and the plan is this file: readable, diffable, and
//// re-runnable against the same repository tomorrow.
////
//// The seam it runs on holds `cap/strand` and `cap/report` and nothing
//// else. There is no `cap/fs` here and no `cap/proc`, so this program
//// cannot read a file or run a command — the reviewing happens on the
//// child strands, which have their own tool sets, and all this program
//// does is decide who reviews what, wait for them together, and add up
//// the answer. An orchestrator that could also write files would be a
//// materially worse thing to hand a model than one that cannot, and that
//// is the whole reason the two seams are separate.
////
//// Three details are worth reading for rather than skimming past:
////
//// - **Each spawn states the shape it wants back** (`strand.expecting`).
////   The harness holds the child to it on the child's own terminal write,
////   so `hits` arrives here as an integer rather than as a sentence this
////   program would have to parse. A deterministic orchestrator over prose
////   is a script that regexes prose, which is worse than the model it
////   replaced.
//// - **The join is one call over every handle** against one deadline, not
////   one call per child. Joining three children costs one window, not
////   three, and a child that has not finished comes back `Pending` — an
////   answer, not a failure.
//// - **Every refusal is data.** A spawn that is refused, a child that
////   fails, and a child that is still running are three different rows in
////   the result, so the strand that reads this outcome learns which
////   packages were actually reviewed rather than being told a total it
////   cannot audit.

import cap/report
import cap/strand
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The packages to review, one child strand each. A program on this seam
/// cannot list a directory, so the set it fans out over is stated here —
/// which is also what makes the plan re-runnable against the same inputs.
const packages = ["packages/core", "packages/broker", "packages/runtime"]

/// The symbol the reviewers are counting.
const symbol = "deprecated_decode"

/// How long one child may take. Its own budget, so a child that wedges is
/// aborted rather than left to the session.
const review_ms = 60_000

/// How long the whole join may take. One deadline over every handle.
const join_ms = 20_000

pub fn main() -> report.Outcome {
  let started = list.map(packages, fn(package) { #(package, start(package)) })
  let handles = list.filter_map(started, fn(one) { one.1 })
  case strand.wait(handles, within_ms: join_ms) {
    Error(error) -> failed_to_join(error)
    Ok(joined) -> reduce(started, joined)
  }
}

/// Starts one reviewer, telling it what to look for and what shape to
/// answer in.
///
/// The purpose is distinct per package on purpose: a child's name is
/// minted from it, so two spawns sharing a purpose are two spawns the
/// harness cannot tell apart.
fn start(package: String) -> Result(strand.Handle, strand.StrandError) {
  strand.assignment(
    purpose: "review " <> package,
    brief: "Search "
      <> package
      <> " for uses of the symbol `"
      <> symbol
      <> "`. Count the files that mention it, then record your result as a "
      <> "note under the key `result`.",
  )
  |> strand.within(review_ms)
  |> strand.expecting([
    strand.required("package", strand.StringField),
    strand.required("hits", strand.IntegerField),
  ])
  |> strand.spawn
}

/// What one package's review came to.
type Review {
  /// The child answered, in the shape that was asked for.
  Counted(package: String, hits: Int)
  /// The child did not answer usefully, and this is why. Kept as its own
  /// variant so the total below is a total over reviews that happened.
  Unfinished(package: String, why: String)
}

/// One structured result out of every child's answer.
fn reduce(
  started: List(#(String, Result(strand.Handle, strand.StrandError))),
  joined: List(strand.Waited),
) -> report.Outcome {
  // `wait` answers one `Waited` per handle in the order the handles were
  // given, and the handles were given in the order they were started, so
  // zipping the two recovers which package each answer belongs to.
  let admitted = list.filter_map(started, fn(one) { started_package(one) })
  let reviews =
    list.append(
      list.map(list.zip(admitted, joined), fn(pair) { review(pair.0, pair.1) }),
      list.filter_map(started, refused_package),
    )
  let counted = list.filter_map(reviews, counted_only)
  report.value(
    report.object([
      #("symbol", report.string(symbol)),
      #("packages_asked", report.int(list.length(packages))),
      #("packages_reviewed", report.int(list.length(counted))),
      #("hits", report.int(list.fold(counted, 0, fn(sum, one) { sum + one.1 }))),
      #(
        "by_package",
        report.object(
          list.map(counted, fn(one) { #(one.0, report.int(one.1)) }),
        ),
      ),
      #("unfinished", report.list(list.filter_map(reviews, unfinished_only))),
    ]),
  )
}

fn started_package(
  one: #(String, Result(strand.Handle, strand.StrandError)),
) -> Result(String, Nil) {
  case one.1 {
    Ok(_handle) -> Ok(one.0)
    Error(_error) -> Error(Nil)
  }
}

fn refused_package(
  one: #(String, Result(strand.Handle, strand.StrandError)),
) -> Result(Review, Nil) {
  case one.1 {
    Ok(_handle) -> Error(Nil)
    Error(error) ->
      Ok(Unfinished(
        package: one.0,
        why: "was never started: " <> strand.error_text(error),
      ))
  }
}

fn review(package: String, waited: strand.Waited) -> Review {
  case waited {
    strand.Pending(_handle, waited_ms) ->
      Unfinished(
        package: package,
        why: "still running after " <> int.to_string(waited_ms) <> "ms",
      )
    strand.Ready(_handle, outcome, _report, verdict, _notes) ->
      case outcome {
        strand.Completed -> from_result(package, verdict)
        strand.Failed(reason) ->
          Unfinished(package: package, why: "failed: " <> reason)
        strand.Aborted -> Unfinished(package: package, why: "was aborted")
      }
  }
}

// The four verdicts on a child's structured result are four different
// facts, and the reason a count is missing is worth reporting as
// precisely as the count itself.
fn from_result(package: String, verdict: strand.TerminalResult) -> Review {
  case verdict {
    strand.NoResultAsked ->
      Unfinished(package: package, why: "no result shape was asked for")
    strand.ResultAbsent(_schema) ->
      Unfinished(package: package, why: "finished without recording a result")
    strand.ResultUnusable(_schema, _received, reason) ->
      Unfinished(
        package: package,
        why: "recorded an unusable result: " <> reason,
      )
    strand.ResultGiven(value) ->
      case hits_of(value) {
        Ok(hits) -> Counted(package: package, hits: hits)
        Error(Nil) ->
          Unfinished(
            package: package,
            why: "recorded a result with no `hits` count",
          )
      }
  }
}

fn hits_of(value: report.Value) -> Result(Int, Nil) {
  use held <- result.try(report.field(value, "hits"))
  report.as_int(held)
}

fn counted_only(review: Review) -> Result(#(String, Int), Nil) {
  case review {
    Counted(package, hits) -> Ok(#(package, hits))
    Unfinished(_package, _why) -> Error(Nil)
  }
}

fn unfinished_only(review: Review) -> Result(report.Value, Nil) {
  case review {
    Counted(_package, _hits) -> Error(Nil)
    Unfinished(package, why) ->
      Ok(
        report.object([
          #("package", report.string(package)),
          #("why", report.string(why)),
        ]),
      )
  }
}

// The join itself failed — the messaging plane is down, or a handle would
// not parse. Nothing was learned, so nothing is reported as learned.
fn failed_to_join(error: strand.StrandError) -> report.Outcome {
  report.Errored(
    message: "the join over "
      <> int.to_string(list.length(packages))
      <> " reviewers failed: "
      <> strand.error_text(error),
    details: report.object([
      #("packages", report.string(string.join(packages, " "))),
    ]),
  )
}
