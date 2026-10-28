//// Real verifier proofs run on Linux; Darwin runs the production refusal.
//// The generator prints assigned coverage and claims no Linux proof on Darwin.
//// Pure and scripted checks retain their coverage on every platform.
////
//// The prover's proofs: the admission rule, the package a verifier names,
//// the record line, and the real thing — `eccdddad0`'s task proved from
//// this repository's history in a real jail.

import client/evolution/rollout.{Grade, ProgramRun}
import client/internal/ffi_os
import client/secrets
import core/json
import eval/mine
import eval/prove
import eval/repos
import eval/task
import eval/verify_test
import gleam/io
import gleam/option.{None, Some}
import gleam/string
import simplifile

fn graded(reward: Float) -> rollout.Grade {
  Grade(reward:, scores: [], side_info: "", verifier: ProgramRun([], 0, 1))
}

fn scored(reward: Float, f2p: Float, p2p: Float) -> rollout.Grade {
  Grade(..graded(reward), scores: [#("f2p", f2p), #("p2p", p2p)])
}

pub fn verdict_requires_gold_one_and_null_zero_test() {
  let gold = scored(1.0, 1.0, 1.0)
  let null = scored(0.0, 0.0, 1.0)
  assert prove.verdict(gold, null) == prove.Admitted
  assert prove.verdict(scored(0.0, 0.0, 1.0), null)
    == prove.Refused(
      "gold reward scored 0.0, wanted 1.0; gold f2p scored 0.0, wanted 1.0",
    )
  assert prove.verdict(gold, scored(1.0, 1.0, 1.0))
    == prove.Refused(
      "null reward scored 1.0, wanted 0.0; null f2p scored 1.0, wanted below 1.0",
    )
  assert prove.verdict(scored(1.0, 1.0, 0.5), null)
    == prove.Refused(
      "gold p2p scored 1.0, wanted 1.0"
      |> string.replace("1.0, wanted", "0.5, wanted"),
    )
}

pub fn verdict_needs_the_test_ids_not_just_the_reward_test() {
  // A gold grade with no scores at all scored no ids, which is not a pass.
  assert prove.verdict(graded(1.0), scored(0.0, 0.0, 1.0))
    == prove.Refused(
      "gold f2p scored 0.0, wanted 1.0; gold p2p scored 0.0, wanted 1.0",
    )

  // A null whose fail-to-pass tests all pass proves nothing about them.
  assert prove.verdict(scored(1.0, 1.0, 1.0), scored(0.0, 1.0, 0.0))
    == prove.Refused("null f2p scored 1.0, wanted below 1.0")
}

pub fn package_of_names_the_test_sh_package_test() {
  assert prove.package_of([
      "bash", "scripts/test.sh", "machine", "--match", "m:",
    ])
    == Ok("machine")
  assert prove.package_of(["bash", "-c", "x"]) == Error(Nil)
  assert prove.package_of([]) == Error(Nil)
  assert prove.package_of(["bash", "scripts/test.sh"]) == Error(Nil)

  // The chained form the miner writes for two touched modules.
  assert prove.package_of([
      "bash", "-c",
      "status=0; 'bash' 'scripts/test.sh' 'provider' '--match' 'provider@stream_test:' || status=1; 'bash' 'scripts/test.sh' 'provider' '--match' 'provider@gateway_test:' || status=1; exit $status",
    ])
    == Ok("provider")
}

pub fn package_for_prefers_the_pkg_tag_test() {
  let base = scripted_task(["bash", "-c", "make check"])
  assert prove.package_for(task.Task(..base, tags: ["family:x", "pkg:lint"]), [
      "bash",
      "-c",
      "make check",
    ])
    == Ok("lint")
  assert prove.package_for(task.Task(..base, tags: []), [
      "bash",
      "scripts/test.sh",
      "core",
      "--match",
      "c:",
    ])
    == Ok("core")
  assert prove.package_for(task.Task(..base, tags: ["pkg:"]), ["make"])
    == Error(Nil)
}

fn scripted_task(argv: List(String)) -> task.Task {
  task.Task(
    id: "",
    name: "t",
    prompt: "p",
    workspace: task.Inline(files: []),
    verifier: task.Program(
      files: [],
      argv:,
      fail_to_pass: [],
      pass_to_pass: [],
      timeout_ms: 1000,
      scoring: task.AllRewardsOne,
    ),
    tags: [],
    provenance: task.HandWritten(author: "t"),
  )
}

pub fn to_json_carries_the_verdict_and_census_test() {
  let proof =
    prove.Proof(
      task_id: "abc",
      name: "mined/x",
      gold: graded(1.0),
      null: graded(0.0),
      sabotage: mine.Caught,
      sabotaged: Some(graded(0.0)),
      verdict: prove.Admitted,
      prepare_ms: 12,
      demand: "best-effort",
      enforcement: ["bwrap", "skip:cgroup-v2: none"],
    )
  let text = json.to_string(prove.to_json(proof))
  assert string.contains(text, "\"verdict\":\"admitted\"")
  assert string.contains(text, "\"sabotage\":\"sabotage:caught\"")
  assert string.contains(text, "\"prepare_ms\":12")
  assert string.contains(text, "\"demand\":\"best-effort\"")
  assert string.contains(
    text,
    "\"enforcement\":[\"bwrap\",\"skip:cgroup-v2: none\"]",
  )
  let none = prove.Proof(..proof, sabotage: mine.NotApplicable, sabotaged: None)
  assert string.contains(
    json.to_string(prove.to_json(none)),
    "\"sabotaged\":null",
  )
}

const probe_commit = "eccdddad0c6f92b4bd8812246d36753477eae4b1"

const probe_task =
  "95b6559abe8c308f12cf612a5c8497a8beb06739721287952b055f096a14897f.json"

/// Selects this module's Linux proofs or Darwin's production refusal.
///
/// ## Examples
///
/// `scripts/test.sh eval --match eval@prove_test:prove_verifier_proofs_test_`.
pub fn prove_verifier_proofs_test_() -> List(#(String, fn() -> Nil)) {
  let #(platform, _) = ffi_os.platform()
  case platform {
    "linux" -> {
      io.println_error("NOTE prove coverage: linux real proofs assigned=1")
      [
        #(
          "eccdddad0_proves_gold_one_null_zero_test",
          eccdddad0_proves_gold_one_null_zero,
        ),
      ]
    }
    "darwin" -> {
      io.println_error(
        "NOTE prove coverage: darwin real proofs assigned=0; production refusal assigned=1; Linux proof coverage is not claimed",
      )
      [
        #(
          "darwin_refuses_unenforceable_verifier",
          verify_test.darwin_refuses_unenforceable_verifier,
        ),
      ]
    }
    other -> panic as { "unsupported prove proof platform: " <> other }
  }
}

fn eccdddad0_proves_gold_one_null_zero() {
  let repo = absolute_repo("../..")
  let file = "test/fixtures/" <> probe_task
  let present =
    secrets.host_runner()(
      ["git", "-C", repo, "cat-file", "-e", probe_commit <> "^{commit}"],
      30_000,
    )

  // The task file is the miner's output and the commit is this repository's
  // history; without either there is nothing to prove, and the jail's own
  // refusal is reported by the fixture that opens it.
  case present, task.load(file) {
    Ok(secrets.Capture(status: 0, ..)), Ok(loaded) ->
      prove_it(known(repo), loaded)
    Ok(secrets.Capture(status: 0, ..)), Error(reason) ->
      io.println_error(
        "SKIP eccdddad0_proves_gold_one_null_zero_test: task file "
        <> file
        <> " unreadable ("
        <> reason
        <> "); run eval/mine_cli --commit "
        <> probe_commit,
      )
    _, _ ->
      io.println_error(
        "SKIP eccdddad0_proves_gold_one_null_zero_test: commit absent",
      )
  }
}

fn prove_it(known: repos.Repos, loaded: task.Task) -> Nil {
  use jail, root <- verify_test.with_jail("eccdddad0")
  let assert Ok(proof) =
    prove.prove(loaded, known, root <> "/work", jail, secrets.host_runner())
  io.println_error("PROOF eccdddad0: " <> json.to_string(prove.to_json(proof)))

  // Gold recognises the fix, null refuses its absence, and the sabotage is
  // a census whose answer the miner already recorded as caught.
  assert proof.verdict == prove.Admitted
  assert proof.gold.reward == 1.0
  assert proof.null.reward == 0.0
  assert proof.sabotage == mine.Caught
  assert proof.demand == "best-effort" || proof.demand == "platform"
  assert proof.enforcement != []
  assert simplifile.is_directory(
      root <> "/work/" <> string.slice(loaded.id, 0, 12) <> "/tree/.git",
    )
    == Ok(False)
}

// The operator's side of the task's `loom`: this checkout.
fn known(repo: String) -> repos.Repos {
  let assert Ok(known) = repos.from_flags(["loom=" <> repo])
    as "the checkout path is absolute"

  known
}

fn absolute_repo(relative: String) -> String {
  let assert Ok(here) = simplifile.current_directory() as "package directory"
  here <> "/" <> relative
}
