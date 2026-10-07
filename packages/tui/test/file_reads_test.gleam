//// The step reads no file (ADR-013, phase 2 S6).
////
//// A pasted image path is read by `runtime.message` when it builds the
//// step's message, and the step attaches what that read found. These tests
//// pin both halves: a message whose read found nothing leaves a pasted path
//// as text even when the path names an image on disk, and a message built
//// before the file is deleted still attaches its image. The behaviour
//// through `tui.update` is unchanged: the image attaches in the step that
//// handled the paste, and a refused image reports the same error it did
//// when the step read the file itself. Since phase 3 the read travels
//// inside the paste's own message, so it cannot be attached to another
//// paste or outlive its event, and nothing needs a test to say so.
////
//// A new session's configuration is resolved by a keyed job
//// (`job.Configure`). The step that asks for a session queues the job and
//// resolves nothing; the tick that takes the job's reply continues the
//// creation exactly as the step used to after resolving it inline; a reply
//// under another key is not admitted; and a quit cancels the job. The
//// daemon host is a stand-in whose control connection is a subject this
//// process owns, as in `attachment_jobs_test`.

import etui/backend
import etui/widgets/textarea
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/composer
import session_view/pasted_image
import session_view/transcript_line
import simplifile
import tui
import tui/attachment
import tui/bootstrap
import tui/connection
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection as daemon_selection
import tui/effect
import tui/image_drop
import tui/job
import tui/model as tui_model
import tui/runtime
import tui/session_control
import tui/session_selector
import tui/submit
import tui/view_set
import tui/workspace
import tui_test/stepping
import weft

// The smallest byte string `image_drop.media_type` recognises as a PNG.
const png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01>>

fn model() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn write(path: String, bytes: BitArray) -> Nil {
  let assert Ok(Nil) = simplifile.write_bits(to: path, bits: bytes)
    as "the fixture file is written under the package build directory"
  Nil
}

fn image_names(model: tui_model.Model) -> List(String) {
  list.filter_map(model.shared.attachments, fn(attachment) {
    case attachment {
      composer.ImageAttachment(pasted_image.Image(filename:, ..)) ->
        Ok(filename)
      composer.Attachment(..) -> Error(Nil)
    }
  })
}

pub fn a_pasted_image_attaches_in_the_step_that_handled_the_paste_test() {
  let path = "build/s6-pasted.png"
  write(path, png)
  let pasted = tui.update(backend.Paste(path), model())
  let _ = simplifile.delete(path)

  assert image_names(pasted) == ["s6-pasted.png"]
  assert textarea.value(pasted.view.input) == ""
}

pub fn the_step_alone_leaves_a_pasted_image_path_as_text_test() {
  let path = "build/s6-unread.png"
  write(path, png)
  let #(stepped, _effects) = stepping.step(backend.Paste(path), model())
  let _ = simplifile.delete(path)

  assert image_names(stepped) == []
  assert textarea.value(stepped.view.input) == path
}

// The read that builds the message is the only read: the file is deleted
// between `runtime.message` and the step, and the image still attaches from
// what the read found. A step that read the file itself would find nothing
// there.
pub fn the_step_attaches_what_the_read_before_it_found_test() {
  let path = "build/s6-read-first.png"
  write(path, png)
  let message = runtime.message(backend.Paste(path), model())
  let assert Ok(Nil) = simplifile.delete(path)
  let #(stepped, _effects) = tui.step(message, model())

  assert image_names(stepped) == ["s6-read-first.png"]
  assert textarea.value(stepped.view.input) == ""
}

pub fn an_oversized_image_reports_the_error_the_step_reported_before_test() {
  let path = "build/s6-oversized.png"
  let padding = pasted_image.max_image_bytes + 1 - bit_array.byte_size(png)
  write(path, <<png:bits, 0:size(padding * 8)>>)
  let expected = image_drop.load_paste(path)
  let pasted = tui.update(backend.Paste(path), model())
  let _ = simplifile.delete(path)

  assert expected == Error("dropped image exceeds the 20 MiB limit")
  assert pasted.shared.notice == "dropped image exceeds the 20 MiB limit"
  let assert Ok(transcript_line.Line(transcript_line.Failure, reason)) =
    list.last(pasted.shared.transcript)
    as "the refusal is the transcript's newest line"
  assert reason == "dropped image exceeds the 20 MiB limit"
  assert image_names(pasted) == []
  assert textarea.value(pasted.view.input) == ""
}

// Launch options whose `--config` names a file that does not exist, so
// resolving them fails with the error the step used to report itself.
fn absent_config() -> bootstrap.Options {
  bootstrap.Options("/work", "", "", "build", "build/s6-absent/loom.toml", "")
}

// A terminal at the session picker, with local launch options and a
// stand-in daemon host, ready for `n` to ask for a new session.
fn picker(options: bootstrap.Options) -> tui_model.Model {
  let owner: Subject(Dynamic) = process.new_subject()
  {
    let base = model()
    tui_model.Model(
      ..base,
      view: base.view
        |> view_set.local_options(Some(options))
        |> view_set.overlay(
          tui_model.DaemonSelector(session_selector.new(
            protocol.Page(0, [], None),
            "",
          )),
        ),
    )
  }
  |> runtime.adopt_control(host_on(owner))
}

fn is_job(requested: effect.Effect) -> Bool {
  case requested {
    effect.StartJob(..) | effect.CancelJob(_) -> True
    _ -> False
  }
}

fn failures(model: tui_model.Model) -> List(String) {
  list.filter_map(model.shared.transcript, fn(line) {
    case line {
      transcript_line.Line(transcript_line.Failure, text) -> Ok(text)
      transcript_line.Line(..) -> Error(Nil)
    }
  })
}

// Asking for a session queues the configuration job under the key its slot
// holds, and the step resolves nothing: the absent `--config` is not
// noticed, no creation key is retained and no attachment starts.
pub fn asking_for_a_session_queues_the_configuration_job_test() {
  let options = absent_config()
  let #(asked, effects) = stepping.step(backend.KeyPress("n"), picker(options))
  let assert Some(slot) = asked.view.configuring
    as "the creation waits for its configuration job"

  assert list.filter(effects, is_job)
    == [effect.StartJob(job.key(slot), job.Configure(options))]
  assert failures(asked) == []
  assert asked.view.creation_key == None
  assert !attachment.busy(asked.view.candidate)
}

// Through `tui.update` the job really runs, and the tick that takes its
// failure reports the error the step used to report, retains no key and
// leaves the picker open for the operator to correct the invocation.
pub fn a_configuration_failure_reports_the_same_error_test() {
  let options = absent_config()
  let assert Error(expected) = bootstrap.session_configuration(options)
    as "the absent config does not resolve"
  let asked = tui.update(backend.KeyPress("n"), picker(options))
  let settled = tick_until_configured(asked, 200)

  assert failures(settled) == [expected]
  assert settled.view.creation_key == None
  assert !attachment.busy(settled.view.candidate)
  let assert tui_model.DaemonSelector(_) = settled.view.overlay
    as "the picker stays open after a local failure"
}

// A resolved configuration continues the creation in the tick that takes
// it: the creation key is retained and the attachment job starts with the
// resolved path. The relay's `AllDelivered` that follows finds the slot
// already cleared and reports nothing.
pub fn a_resolved_configuration_continues_the_creation_test() {
  let options = absent_config()
  let #(asked, _effects) = stepping.step(backend.KeyPress("n"), picker(options))
  let assert Some(slot) = asked.view.configuring
    as "the creation waits for its configuration job"
  let resolved =
    runtime.hold(
      asked,
      job.ConfigurationArrived(
        job.key(slot),
        weft.PulledOutcome(weft.Completed(0, "/cfg/loom.toml")),
      ),
    )
  let #(created, effects) = stepping.step(backend.Tick, resolved)
  let assert Some(creation_key) = created.view.creation_key
    as "the creation retained its key once the configuration arrived"
  let assert Some(host) = created.view.daemon_host
    as "the stand-in host remains"
  let assert [effect.StartJob(attach_key, spec)] = list.filter(effects, is_job)
    as "the tick starts exactly the attachment job"

  assert spec
    == job.Attach(
      job.CreateSession(
        host.control,
        creation_key,
        "/work",
        "work",
        "/cfg/loom.toml",
        "",
      ),
      90_000,
    )
  assert attachment.job_key(created.view.candidate) == Some(attach_key)
  assert created.view.configuring == None
  assert created.view.overlay == tui_model.NoOverlay
  assert created.shared.frame_revision > resolved.shared.frame_revision
    as "the tick repaints the closed picker"

  let finished =
    runtime.hold(
      created,
      job.ConfigurationArrived(job.key(slot), weft.AllDelivered),
    )
  let #(after, _effects) = stepping.step(backend.Tick, finished)
  assert failures(after) == []
}

// A reply under another key belongs to no creation this terminal waits
// for, so it is not admitted and the creation does not continue.
pub fn a_configuration_reply_for_another_key_is_not_admitted_test() {
  let #(asked, _effects) =
    stepping.step(backend.KeyPress("n"), picker(absent_config()))
  let #(asked, other) = tui_model.allocate_job(asked)
  let held =
    runtime.hold(
      asked,
      job.ConfigurationArrived(
        other,
        weft.PulledOutcome(weft.Completed(0, "/cfg/loom.toml")),
      ),
    )
  let #(after, _effects) = stepping.step(backend.Tick, held)

  assert after.view.configuring == asked.view.configuring
  assert after.view.creation_key == None
  assert !attachment.busy(after.view.candidate)
}

// Quit cancels the configuration job and clears its slot in the same step,
// so a reply the job sends afterwards reaches no creation.
pub fn quit_cancels_the_configuration_job_test() {
  let #(asked, _effects) =
    stepping.step(backend.KeyPress("n"), picker(absent_config()))
  let assert Some(slot) = asked.view.configuring
    as "the creation waits for its configuration job"
  let #(quitting, effects) = runtime.take(submit.quit(asked))

  assert list.contains(effects, effect.CancelJob(job.key(slot)))
  assert quitting.view.configuring == None
  let late =
    runtime.hold(
      quitting,
      job.ConfigurationArrived(
        job.key(slot),
        weft.PulledOutcome(weft.Completed(0, "/cfg/loom.toml")),
      ),
    )
  assert late.view.configuring == None
}

// A second request while a creation is still unreconciled says so in plain
// words. The creation key is an internal handle, here a process identity and
// a clock reading, and the person at the terminal can do nothing with it.
pub fn a_second_creation_names_no_internal_key_test() {
  let #(asked, _effects) =
    stepping.step(backend.KeyPress("n"), picker(absent_config()))
  let assert Some(slot) = asked.view.configuring
    as "the creation waits for its configuration job"
  let resolved =
    runtime.hold(
      asked,
      job.ConfigurationArrived(
        job.key(slot),
        weft.PulledOutcome(weft.Completed(0, "/cfg/loom.toml")),
      ),
    )
  let #(created, _effects) = stepping.step(backend.Tick, resolved)
  let assert Some(creation_key) = created.view.creation_key
    as "the first creation retained its key"

  let reopened =
    view_set.overlay(
      created.view,
      tui_model.DaemonSelector(session_selector.new(
        protocol.Page(0, [], None),
        "",
      )),
    )
  let #(again, _effects) =
    stepping.step(
      backend.KeyPress("n"),
      tui_model.Model(..created, view: reopened),
    )
  let assert Some(second) = again.view.configuring
    as "the second creation waits for its configuration job"
  let refused =
    runtime.hold(
      again,
      job.ConfigurationArrived(
        job.key(second),
        weft.PulledOutcome(weft.Completed(0, "/cfg/loom.toml")),
      ),
    )
  let #(after, _effects) = stepping.step(backend.Tick, refused)

  assert failures(after)
    == ["the previous session creation did not finish; reopen /sessions"]
  assert !string.contains(string.join(failures(after), "\n"), creation_key)
}

// Ticks through `tui.update` until the configuration slot is cleared, so a
// real job's reply has been taken, or the budget of ticks runs out.
fn tick_until_configured(
  model: tui_model.Model,
  remaining: Int,
) -> tui_model.Model {
  case model.view.configuring, remaining {
    None, _ -> model
    Some(_), 0 -> model
    Some(_), _ -> {
      process.sleep(5)
      tick_until_configured(tui.update(backend.Tick, model), remaining - 1)
    }
  }
}

@external(erlang, "effects_test_ffi", "host_on")
fn host_on(owner: Subject(Dynamic)) -> daemon_selection.Host

// The profile the launch asked for travels with the creation: the attachment job
// that creates the session carries `--model-profile`'s name beside the resolved
// configuration path (protocol-change/076).
pub fn a_creation_carries_the_launch_profile_test() {
  let options = bootstrap.Options(..absent_config(), profile: "deepseek")
  let #(asked, _effects) = stepping.step(backend.KeyPress("n"), picker(options))
  let assert Some(slot) = asked.view.configuring
    as "the creation waits for its configuration job"
  let resolved =
    runtime.hold(
      asked,
      job.ConfigurationArrived(
        job.key(slot),
        weft.PulledOutcome(weft.Completed(0, "/cfg/loom.toml")),
      ),
    )
  let #(created, effects) = stepping.step(backend.Tick, resolved)
  let assert Some(creation_key) = created.view.creation_key
    as "the creation retained its key once the configuration arrived"
  let assert Some(host) = created.view.daemon_host
    as "the stand-in host remains"
  let assert [effect.StartJob(_, spec)] = list.filter(effects, is_job)
    as "the tick starts exactly the attachment job"
  assert spec
    == job.Attach(
      job.CreateSession(
        host.control,
        creation_key,
        "/work",
        "work",
        "/cfg/loom.toml",
        "deepseek",
      ),
      90_000,
    )
}

// A launch that names a profile but opens an existing session owes the line
// that says the profile only applies to new sessions; a launch without one
// owes nothing.
pub fn opening_an_existing_session_says_the_profile_is_kept_test() {
  let named =
    session_control.kept_profile_line(picker(
      bootstrap.Options(..absent_config(), profile: "deepseek"),
    ))
  let assert Some(line) = named as "a named profile is owed a line"
  assert string.contains(
    line,
    "--model-profile deepseek applies to new sessions",
  )
  assert session_control.kept_profile_line(picker(absent_config())) == None
}

@external(erlang, "effects_test_ffi", "control_on")
fn control_on(owner: Subject(Dynamic)) -> daemon.Connection

// The line `tui.attach_daemon` leaves owed for one launch, through the
// credential read, the control adoption and the first request a local launch
// makes. It is owed rather than written, because adopting the attach replaces
// the transcript (`attempt_replay_test` drives that half).
fn attached_note(
  options: bootstrap.Options,
  selected: String,
) -> option.Option(String) {
  let token = "build/r8-attach-token"
  write(token, <<"token":utf8>>)
  let assert Ok(Nil) = simplifile.set_permissions_octal(token, 0o600)
  let owner: Subject(Dynamic) = process.new_subject()
  let local =
    tui_model.Model(
      ..model(),
      view: view_set.local_options(model().view, Some(options)),
    )
  let attached =
    tui.attach_daemon(
      local,
      control_on(owner),
      Ok("ws://127.0.0.1:1/v2/control"),
      token,
      selected,
    )
  let _ = simplifile.delete(token)

  attached.view.launch_note
}

fn names_kept_profile(note: option.Option(String)) -> Bool {
  case note {
    Some(line) -> string.contains(line, "--model-profile beta applies to new")
    None -> False
  }
}

// The flag is silently ignored on resume unless the local launch says so:
// `--session <id> --model-profile beta` opens a session and keeps its profile.
pub fn a_local_launch_opening_a_session_says_the_profile_is_kept_test() {
  let options = bootstrap.Options(..absent_config(), profile: "beta")

  assert names_kept_profile(attached_note(options, "01a11401"))
}

// Nothing is opened when the launch lands on the picker, and a launch that
// named no profile has nothing to say.
pub fn a_local_launch_that_opens_nothing_or_names_no_profile_is_silent_test() {
  let options = bootstrap.Options(..absent_config(), profile: "beta")

  assert attached_note(options, "") == None
  assert attached_note(absent_config(), "01a11401") == None
}
