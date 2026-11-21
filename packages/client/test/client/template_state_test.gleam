//// The template's states and the moves between them, the `setup` key that makes
//// a project have one, and the ledger records that carry it across a restart.
////
//// None of this needs a process. The states are pure functions, so a property
//// can walk random sequences of moves and hold the invariants that the actor
//// relies on: a worker starts only when the template can be copied, a failure is
//// shown only when there is one, and a ready template is never lost to a failed
//// rebuild.

import client/project_records
import client/project_retention
import client/project_settings
import client/project_template.{Failure}
import client/template_state.{type Standing}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/model
import project/state
import qcheck
import storage/project_ledger
import tom

// --- the setup key ---------------------------------------------------------------

pub fn setup_reads_like_check_and_is_none_when_unset_test() {
  assert project_settings.defaults.setup == None
  let assert Ok(document) =
    tom.parse("[project]\nsetup = \" make deps \"\ncheck = \"make check\"\n")
  let assert Ok(settings) = project_settings.from_document(document)
  assert settings.setup == Some("make deps")
  assert settings.check == Some("make check")

  // A blank command, a number and a command past the limit are refused by the
  // key's own name, as `check` is.
  list.each(["setup = \"\"", "setup = 3", "setup = \"   \""], fn(line) {
    let assert Ok(bad) = tom.parse("[project]\n" <> line <> "\n")
    let assert Error(why) = project_settings.from_document(bad)
    assert string.contains(why, "project.setup")
  })
  let long = string.repeat("x", project_settings.max_check_bytes + 1)
  let assert Ok(too_long) = tom.parse("[project]\nsetup = \"" <> long <> "\"\n")
  let assert Error(_) = project_settings.from_document(too_long)
  let exact = string.repeat("x", project_settings.max_check_bytes)
  let assert Ok(fits) = tom.parse("[project]\nsetup = \"" <> exact <> "\"\n")
  let assert Ok(_) = project_settings.from_document(fits)
}

// --- the states ------------------------------------------------------------------

fn failure(stage: project_template.Stage) -> project_template.Failure {
  Failure(stage, "exit status 2\nboom")
}

pub fn a_project_without_setup_is_unmanaged_and_always_admits_test() {
  assert template_state.start(None, 10) == template_state.Unmanaged
  assert template_state.admits(template_state.Unmanaged)
  assert template_state.word(template_state.Unmanaged) == None
  assert template_state.note(template_state.Unmanaged) == None
  assert !template_state.looks_due(template_state.Unmanaged, 1_000_000)
}

pub fn a_project_with_setup_waits_until_a_build_finishes_test() {
  let preparing = template_state.start(Some("make deps"), 10)
  assert preparing == template_state.Preparing(10)
  assert !template_state.admits(preparing)
  assert template_state.word(preparing) == Some("preparing")
  let assert Some(note) = template_state.note(preparing)
  assert string.contains(note, "none has failed")

  let ready = template_state.built("abc1234", "d1", 600_000)
  assert template_state.admits(ready)
  assert template_state.word(ready) == Some("ready")
  assert template_state.note(ready) == None
}

pub fn a_failed_first_build_breaks_the_project_and_names_the_setup_test() {
  let broken =
    template_state.failed(
      template_state.Preparing(0),
      failure(project_template.Setup),
      600_000,
    )
  assert !template_state.admits(broken)
  assert template_state.word(broken) == Some("failed")
  let assert Some(note) = template_state.note(broken)
  assert string.contains(note, "project's setup")
  assert string.contains(note, "not any ticket")
  assert string.contains(note, "exit status 2")

  let red =
    template_state.failed(
      template_state.Preparing(0),
      failure(project_template.BaseCheck),
      0,
    )
  assert template_state.word(red) == Some("base_check_red")
  let assert Some(red_note) = template_state.note(red)
  assert string.contains(red_note, "red on the clean base")
}

pub fn a_failed_rebuild_keeps_the_last_good_template_in_use_test() {
  let ready = template_state.built("abc1234", "d1", 0)
  let rebuilding = template_state.building(ready, 5)
  assert template_state.admits(rebuilding)
  assert !template_state.looks_due(rebuilding, 1_000_000)
  let stale =
    template_state.failed(rebuilding, failure(project_template.Setup), 700_000)
  assert template_state.admits(stale)
  assert template_state.word(stale) == Some("ready")
  assert template_state.failure_of(stale)
    == Some(failure(project_template.Setup))
  let assert Some(note) = template_state.note(stale)
  assert string.contains(note, "abc1234")

  // A later build that finds nothing to do clears the note.
  let quiet = template_state.unchanged(stale, 800_000)
  assert template_state.failure_of(quiet) == None
}

pub fn a_changed_command_is_not_trusted_after_a_restart_test() {
  let built = template_state.recorded_build("abc1234", "old")
  assert template_state.after_replay(built, Some("make deps"), "new", 9)
    == template_state.Preparing(9)
  assert template_state.after_replay(built, Some("make deps"), "old", 9)
    == built
  assert template_state.current(built, "old") == Some("abc1234")
  assert template_state.current(built, "new") == None
  assert template_state.after_replay(built, None, "old", 9)
    == template_state.Unmanaged
}

// --- the walk --------------------------------------------------------------------

type Move {
  Building
  Built
  Unchanged
  Failed(project_template.Stage)
  Replayed
}

fn move_gen() -> qcheck.Generator(Move) {
  qcheck.from_generators(qcheck.return(Building), [
    qcheck.return(Built),
    qcheck.return(Unchanged),
    qcheck.return(Failed(project_template.Setup)),
    qcheck.return(Failed(project_template.BaseCheck)),
    qcheck.return(Replayed),
  ])
}

fn step(standing: Standing, move: Move) -> Standing {
  case move {
    Building -> template_state.building(standing, 1)
    Built -> template_state.built("abc1234", "d", 2)
    Unchanged -> template_state.unchanged(standing, 3)
    Failed(stage) -> template_state.failed(standing, failure(stage), 4)
    Replayed -> template_state.after_replay(standing, Some("s"), "d", 5)
  }
}

pub fn no_walk_loses_a_ready_template_to_a_failure_or_admits_a_broken_one_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(300)
    |> qcheck.with_seed(qcheck.seed(7))
  qcheck.run(config, qcheck.list_from(move_gen()), fn(moves) {
    let walked =
      list.fold(moves, [template_state.Preparing(0)], fn(seen, move) {
        let assert [last, ..] = seen
        [step(last, move), ..seen]
      })
      |> list.reverse
    list.each(list.window_by_2(walked), fn(pair) {
      let #(before, after) = pair

      // A failure never takes a ready template out of use, and nothing that is
      // broken or still preparing is let through to start a worker.
      case before, after {
        template_state.Ready(..), template_state.Broken(..) ->
          panic as "a ready template was lost to a failure"
        _, _ -> Nil
      }
      case after {
        template_state.Broken(..) | template_state.Preparing(_) -> {
          assert !template_state.admits(after)
          Nil
        }
        template_state.Ready(..) | template_state.Unmanaged -> {
          assert template_state.admits(after)
          Nil
        }
      }
    })
  })
}

// --- the ledger ------------------------------------------------------------------

pub fn the_template_records_survive_the_codec_test() {
  let built = project_records.TemplateBuilt("abc1234", "d1")
  let failed = project_records.TemplateFailed("base_check", "exit status 1\nno")
  assert project_records.decode_line(project_records.encode_record(built))
    == Ok(project_records.Host(built))
  assert project_records.decode_line(project_records.encode_record(failed))
    == Ok(project_records.Host(failed))
  assert project_template.stage_of_word(project_template.stage_word(
      project_template.BaseCheck,
    ))
    == project_template.BaseCheck
  assert project_template.stage_of_word("something new")
    == project_template.Cutting
}

pub fn the_build_row_has_one_key_and_decodes_test() {
  let draft = project_records.template_draft(7)
  assert draft.kind == "template"
  assert draft.key == "build"
  assert project_records.job(project_ledger.Effect(
      draft.kind,
      draft.key,
      draft.payload_json,
      0,
      7,
    ))
    == Ok(project_records.TemplateJob)
}

pub fn compaction_keeps_the_latest_build_and_the_latest_failure_test() {
  let lines =
    list.map(
      [
        project_records.TemplateBuilt("c1", "d"),
        project_records.TemplateFailed("setup", "one"),
        project_records.TemplateBuilt("c2", "d"),
        project_records.TemplateFailed("setup", "two"),
        project_records.TemplateFailed("setup", "three"),
      ],
      project_records.encode_record,
    )
  let kept = project_retention.select_records(lines, empty_state())
  assert kept
    == [
      project_records.encode_record(project_records.TemplateBuilt("c2", "d")),
      project_records.encode_record(project_records.TemplateFailed(
        "setup",
        "three",
      )),
    ]
}

fn empty_state() -> state.State {
  state.State(..state.start(state_config()), tickets: dict.new())
}

fn state_config() -> state.Config {
  state.Config(
    project: project_id(),
    workspace: "/w",
    max_workers: 1,
    queue_limit: 1,
    attention_limit: 1,
    policy_version: "v1",
  )
}

fn project_id() -> model.ProjectId {
  model.ProjectId("p1")
}
