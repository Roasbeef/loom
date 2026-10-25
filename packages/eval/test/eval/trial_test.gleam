import broker/exec
import client/secrets
import client/serve
import core/json
import eval/arm.{
  type Arm, type Knobs, Any, Arm, Knobs, Main, PromptPack, SystemSuffix, Target,
  ToolDescription,
}
import eval/arm_settings
import eval/git
import eval/ledger
import eval/plan.{Budgets, RowKey}
import eval/repos
import eval/task
import eval/trial
import eval/verify
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import provider/gateway
import provider/model
import provider/profile
import simplifile
import support/scripted

fn fixture_target() -> arm.Target {
  Target("fixture", "fixture", "anthropic-messages", Any)
}

fn arm_with(components: List(#(arm.Component, String)), knobs: Knobs) -> Arm {
  let assert Ok(minted) =
    arm.mint(Arm(id: "", name: "under test", components:, knobs:))
    as "the arm under test mints"

  minted
}

fn no_knobs() -> Knobs {
  Knobs(roles: [], thinking: [], disabled_tools: [])
}

fn settings() -> serve.Settings {
  scripted.base(scripted.scratch("arm-settings"), scripted.transport(1))
}

pub fn grade_expected_passes_exact_bytes_test() {
  let dir = scripted.scratch("grade-pass")
  let assert Ok(Nil) = simplifile.write(dir <> "/a.txt", "exact\n")

  assert trial.grade_expected([#("a.txt", "exact\n")], dir)
    == Ok(rollout_pass())
}

pub fn grade_expected_names_the_first_differing_path_test() {
  let dir = scripted.scratch("grade-differ")
  let assert Ok(Nil) = simplifile.write(dir <> "/a.txt", "exact\n")
  let assert Ok(Nil) = simplifile.write(dir <> "/b.txt", "other\n")

  let assert Ok(grade) =
    trial.grade_expected([#("a.txt", "exact\n"), #("b.txt", "wanted\n")], dir)

  assert grade.reward == 0.0
  assert grade.side_info == "expected file differs: b.txt"
}

pub fn grade_expected_treats_a_missing_file_and_a_symlink_as_differing_test() {
  let dir = scripted.scratch("grade-link")
  let assert Ok(Nil) = simplifile.write(dir <> "/real.txt", "exact\n")
  let assert Ok(Nil) = simplifile.create_symlink("real.txt", dir <> "/link.txt")

  let assert Ok(missing) = trial.grade_expected([#("nope.txt", "x")], dir)
  let assert Ok(linked) = trial.grade_expected([#("link.txt", "exact\n")], dir)

  assert missing.reward == 0.0
  assert linked.reward == 0.0
}

fn rollout_pass() {
  let assert Ok(grade) = trial.grade_expected([], "/")

  grade
}

pub fn an_infra_row_keeps_the_end_of_a_long_reason_within_the_ledger_bound_test() {
  let long = string.repeat("x", 20_000) <> "THE-END"
  let row = trial.infra_row("p", RowKey("t", "a", 0), 2, long)

  assert row.state == ledger.Infra
  assert row.outcome == Some(ledger.Infrastructure)
  assert string.ends_with(row.side_info, "THE-END")
  assert ledger.decode_line(ledger.encode_line(row)) == Ok(row)
}

pub fn a_running_row_has_no_outcome_and_round_trips_test() {
  let row = trial.running_row("p", RowKey("t", "a", 1), 1)

  assert row.state == ledger.Running
  assert row.outcome == None
  assert ledger.decode_line(ledger.encode_line(row)) == Ok(row)
}

pub fn a_program_verifier_is_refused_by_name_without_a_grader_test() {
  let assert Error("program verifier not built") =
    trial.refuse_program(scripted.stalled_task(), "/f", "/o", None)
}

pub fn unapplied_knob_is_refused_test_() -> scripted.EunitTest {
  scripted.Timeout(60, fn() {
    scripted.when_available("unapplied_knob_is_refused", fn() {
      let base = settings()

      let aimed =
        arm_with(
          [
            #(
              SystemSuffix(Target(
                "fixture",
                "fixture",
                "anthropic-messages",
                Main,
              )),
              "x",
            ),
          ],
          no_knobs(),
        )
      let assert Error(role_reason) = arm_settings.to_settings(aimed, base)
      assert string.contains(role_reason, "protocol-change 101")

      let packed = arm_with([#(PromptPack, "{}")], no_knobs())
      let assert Error(pack_reason) = arm_settings.to_settings(packed, base)
      assert string.contains(pack_reason, "PromptPack")

      let unknown =
        arm_with([], Knobs(..no_knobs(), roles: [#(model.Main, ["ghost"])]))
      let assert Error(model_reason) = arm_settings.to_settings(unknown, base)
      assert string.contains(model_reason, "ghost")

      let off_catalogue =
        arm_with(
          [
            #(
              SystemSuffix(Target("ghost", "ghost", "anthropic-messages", Any)),
              "x",
            ),
          ],
          no_knobs(),
        )
      let assert Error(profile_reason) =
        arm_settings.profiles(off_catalogue, base)
      assert string.contains(profile_reason, "ghost")

      let wrong_api =
        arm_with(
          [
            #(
              SystemSuffix(Target(
                "fixture",
                "fixture",
                "openai-completions",
                Any,
              )),
              "x",
            ),
          ],
          no_knobs(),
        )
      let assert Error(api_reason) = arm_settings.profiles(wrong_api, base)
      assert string.contains(api_reason, "anthropic-messages")
    })
  })
}

pub fn knobs_reach_the_catalogue_the_routes_and_the_withheld_tools_test_() -> scripted.EunitTest {
  scripted.Timeout(60, fn() {
    scripted.when_available("knobs_reach_the_session", fn() {
      let chosen =
        arm_with(
          [],
          Knobs(
            roles: [#(model.Main, ["fixture-b"])],
            thinking: [#("fixture-b", model.ThinkingHigh)],
            disabled_tools: ["bash", "bash"],
          ),
        )
      let assert Ok(applied) = arm_settings.to_settings(chosen, settings())
      let assert Ok(main) = gateway.resolve(applied.gateway, model.Main)

      assert applied.catalog.roles == [#(model.Main, ["fixture-b"])]
      assert main.model_id == "fixture-b"
      assert main.thinking == model.ThinkingHigh
      assert applied.deactivated_tools == ["bash"]
    })
  })
}

pub fn components_become_one_profile_per_exact_target_test_() -> scripted.EunitTest {
  scripted.Timeout(60, fn() {
    scripted.when_available("components_become_profiles", fn() {
      let arm =
        arm_with(
          [
            #(SystemSuffix(fixture_target()), "Check your work."),
            #(
              ToolDescription(fixture_target(), "fs_write"),
              "Prefer small edits.",
            ),
          ],
          no_knobs(),
        )
      let assert Ok([only]) = arm_settings.profiles(arm, settings())
      let #(_id, provider, model_id, api, suffix, prefix, descriptions) =
        profile.fields(only)

      assert provider == "fixture"
      assert model_id == "fixture"
      assert api == "anthropic-messages"
      assert suffix == "Check your work."
      assert prefix == ""
      assert descriptions == [#("fs_write", "Prefer small edits.")]
      assert list.length(descriptions) == 1
    })
  })
}

// --- the program path ------------------------------------------------------

const mined_fixture =
  "test/fixtures/95b6559abe8c308f12cf612a5c8497a8beb06739721287952b055f096a14897f.json"

fn skip(name: String, reason: String) -> Nil {
  io.println_error("SKIP " <> name <> ": " <> reason)
}

// The mined task, with the repository history it needs present.
fn mined_task() -> Result(task.Task, String) {
  use text <- result.try(
    simplifile.read(mined_fixture)
    |> result.map_error(simplifile.describe_error),
  )
  use value <- result.try(
    json.parse(text) |> result.map_error(fn(_) { "the fixture is not JSON" }),
  )
  use decoded <- result.try(task.decode(value))
  use decoded <- result.try(task.verify_id(decoded))

  case decoded.workspace, decoded.provenance {
    task.GitTree(commit:, ..), task.MinedCommit(fix:, ..) -> {
      let runner = secrets.host_runner()
      let repository = checkout()

      use _parent <- result.try(git.ask(
        runner,
        repository,
        ["cat-file", "-e", commit <> "^{commit}"],
        30_000,
      ))
      use _fix <- result.map(git.ask(
        runner,
        repository,
        ["cat-file", "-e", fix <> "^{commit}"],
        30_000,
      ))

      decoded
    }
    _, _ -> Error("the fixture is not a mined git task")
  }
}

// The clone this checkout is: the operator's side of the task's `loom`.
fn checkout() -> String {
  let known = repos.with_default(repos.empty(), secrets.host_runner())
  let assert Ok(path) = repos.path(known, "loom")
    as "the tests run in a checkout"

  path
}

// The fix's source patch, as `eval/prove` computes it.
fn gold_patch(found: task.Task, into: String) -> String {
  let assert task.GitTree(commit:, ..) = found.workspace
  let repository = checkout()
  let assert task.MinedCommit(fix:, ..) = found.provenance
  let assert Ok(diff) =
    git.ask(
      secrets.host_runner(),
      repository,
      [
        "diff", commit, fix, "--", ".", ":!packages/*/test/*", ":!*CLAUDE.md",
        ":!*AGENTS.md", ":!docs/*",
      ],
      60_000,
    )
  let assert Ok(Nil) = simplifile.write(into, diff)

  into
}

// The production demand first; best-effort only when the one skipped layer is
// the cgroup v2 ceilings, with a NOTE, as the verifier's own tests do.
fn open_jail(
  base: serve.Settings,
  root: String,
) -> Result(verify.Jail, String) {
  case verify.open_jail(base, root) {
    Ok(jail) -> Ok(jail)
    Error(reason) ->
      case string.contains(reason, "skip:cgroup-v2") {
        True -> {
          io.println_error(
            "NOTE program trial: cgroup-v2 ceilings are not enforceable on this host; the jail runs under best-effort enforcement",
          )
          verify.open_jail(
            serve.Settings(..base, demand: exec.BestEffort),
            root,
          )
        }
        False -> Error(reason)
      }
  }
}

fn program_trial(
  name: String,
  apply_gold: Bool,
  expect: fn(ledger.Row) -> Nil,
) -> Nil {
  scripted.when_available(name, fn() {
    case mined_task() {
      Error(reason) ->
        skip(name, "the mined task or its history is absent: " <> reason)
      Ok(mined) -> {
        let root = scripted.scratch(name)
        let base = scripted.base(root <> "/base", scripted.transport(1))
        case open_jail(base, root) {
          Error(reason) -> skip(name, "the jail refused: " <> reason)
          Ok(jail) -> {
            let patch = gold_patch(mined, root <> "/gold.patch")
            let grader = fn(found, frozen, out, pristine) {
              case apply_gold {
                True -> {
                  let assert Ok(capture) =
                    git.run_in(
                      secrets.host_runner(),
                      frozen,
                      ["patch", "-p1", "-i", patch],
                      60_000,
                    )
                  assert capture.status == 0
                }
                False -> Nil
              }
              verify.grade(found, frozen, out, jail, pristine)
            }
            let ctx =
              trial.Context(
                base:,
                lane: trial.Live,
                budgets: Budgets(4, 100.0, 120_000, 1),
                plan_id: "program",
                seams: trial.default_seams(grader),
                repos: repos.with_default(repos.empty(), secrets.host_runner()),
                selftest: "test jail probe",
              )
            let key = RowKey(mined.id, scripted.baseline().id, 0)
            let row =
              trial.run_one(
                ctx,
                mined,
                scripted.baseline(),
                key,
                1,
                root <> "/attempt",
              )
            let _closed = verify.close_jail(jail)

            case row.state {
              ledger.Infra ->
                skip(
                  name,
                  "the environment could not run the trial: " <> row.side_info,
                )
              ledger.Scored | ledger.Running -> expect(row)
            }
          }
        }
      }
    }
  })
}

pub fn a_gold_patched_mined_task_scores_passed_test_() -> scripted.EunitTest {
  scripted.Timeout(1500, fn() {
    program_trial("gold_patched_mined_task", True, fn(row) {
      assert row.outcome == Some(ledger.Passed)
      assert list.key_find(row.scores, "f2p") == Ok(1.0)
      assert row.jail.selftest == "test jail probe"
    })
  })
}

pub fn an_agent_that_changes_nothing_fails_the_mined_verifier_test_() -> scripted.EunitTest {
  scripted.Timeout(1500, fn() {
    program_trial("unchanged_mined_task", False, fn(row) {
      assert row.outcome == Some(ledger.VerifierFailed)
      assert list.key_find(row.scores, "f2p") == Ok(0.0)
    })
  })
}
