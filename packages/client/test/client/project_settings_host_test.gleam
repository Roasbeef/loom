//// A project's own settings in the project actor (protocol-change/106,
//// "Settings held per project"): precedence over the `[project]` table,
//// persistence across a restart, a change with no restart, the explicit
//// turn-on of `publish`, and two projects on one daemon staying independent.
////
//// The actor, the ledger and the engine are real. The build is a fake port
//// that reports the commands it was asked to run, so a test can say which
//// build ran with which `setup`.

import client/daemon/project_host
import client/internal/ffi_os
import client/project_overrides as overrides
import client/project_settings
import client/project_template
import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import project/model
import simplifile
import support/project_ports
import tools/project as tools
import weft/poll

type Seen {
  Built(setup: String, check: Option(String))
  Started(key: String)
  Stopped
}

const url = "https://github.com/o/r"

fn directory(name: String) -> String {
  let path =
    "build/project-settings-host-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(path)
  let assert Ok(Nil) = bootstrap.ensure_private_directory("build")
    as "the build directory exists"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
    as "the scratch directory is made"
  path
}

// Whether the fake build waits to be released, shared by every build of a
// project through a holder process.
type Gate {
  Open
  Closed
}

type Holder =
  Subject(Control)

type Control {
  Ask(reply: Subject(Gate))
  Put(Gate)
}

fn hold(first: Gate) -> Holder {
  let made = process.new_subject()
  process.spawn_unlinked(fn() {
    let inbox = process.new_subject()
    process.send(made, inbox)
    serve(inbox, first)
  })
  let assert Ok(inbox) = process.receive(made, 1000) as "the holder starts"
  inbox
}

fn serve(inbox: Holder, gate: Gate) -> Nil {
  case process.receive_forever(inbox) {
    Ask(reply) -> {
      process.send(reply, gate)
      serve(inbox, gate)
    }
    Put(next) -> serve(inbox, next)
  }
}

fn wait_open(holder: Holder, polls: Int) -> Nil {
  case process.call(holder, 1000, Ask), polls {
    Open, _ | Closed, 0 -> Nil
    Closed, _ -> {
      process.sleep(50)
      wait_open(holder, polls - 1)
    }
  }
}

// The file's policy: what `[project]` would give.
fn file_policy(check: String, setup: String) -> project_host.Policy {
  project_host.Policy(
    ..project_host.idle_policy,
    check: Some(check),
    setup: Some(setup),
    check_wall_ms: 5000,
    setup_wall_ms: 5000,
  )
}

fn config(
  path: String,
  seen: Subject(Seen),
  holder: Holder,
  policy: project_host.Policy,
  remote: Option(String),
) -> project_host.Config {
  let ports =
    project_host.Ports(
      ..project_ports.inert(),
      start_session: fn(request: project_host.StartRequest) {
        process.send(seen, Started(request.key))
        Ok("session-" <> request.key)
      },
      stop_session: fn(_) {
        process.send(seen, Stopped)
        Ok(Nil)
      },
      remote_url: fn() { remote },
      build_template: fn(request: project_template.Request) {
        process.send(seen, Built(request.setup, request.check))
        wait_open(holder, 600)
        project_template.Built("abc1234abc12")
      },
    )
  project_host.Config(
    project: "p1",
    workspace: "/work/repo",
    router_session: "router-1",
    ledger_path: path <> "/ledger.db",
    max_workers: 2,
    tick_ms: 3_600_000,
    router_turn_ms: 3_600_000,
    policy:,
    ports: fn() { ports },
  )
}

fn start(config: project_host.Config) -> project_host.Handle {
  let assert Ok(handle) = project_host.start(config) as "the actor starts"
  handle
}

fn stop(handle: project_host.Handle) -> Nil {
  let assert Ok(pid) = process.subject_owner(handle.commands)
    as "the actor has an owner"
  process.unlink(pid)
  process.kill(pid)
  process.sleep(50)
}

fn view(handle: project_host.Handle) -> overrides.View {
  let assert Ok(read) = project_host.settings(handle) as "the settings read"
  read
}

fn entry(handle: project_host.Handle, key: overrides.Key) -> overrides.Entry {
  let assert Ok(found) =
    list.find(view(handle).entries, fn(each) { each.key == key })
  found
}

fn hold_value(
  handle: project_host.Handle,
  key: overrides.Key,
  words: List(String),
) -> Result(overrides.View, project_host.SettingsFailure) {
  let assert Ok(override) = overrides.parse(key, words)
  project_host.change_settings(
    handle,
    view(handle).revision,
    [overrides.Hold(override)],
    None,
    "owner",
  )
}

fn release(
  handle: project_host.Handle,
  key: overrides.Key,
) -> Result(overrides.View, project_host.SettingsFailure) {
  project_host.change_settings(
    handle,
    view(handle).revision,
    [overrides.Release(key)],
    None,
    "owner",
  )
}

fn sources(handle: project_host.Handle) -> String {
  let assert Ok(shown) = project_host.board(handle, 0) as "the board reads"
  json.to_string(json.Array(shown.sources))
}

fn eventually(read: fn() -> String, wanted: String) -> Bool {
  case
    poll.until(within: 20_000, every: 25, attempt: fn() {
      case string.contains(read(), wanted) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  {
    poll.Answered(Nil) -> True
    poll.Expired | poll.Failed(_) -> False
  }
}

fn saw(seen: Subject(Seen), wanted: Seen, ms: Int) -> Bool {
  case process.receive(seen, ms) {
    Ok(one) if one == wanted -> True
    Ok(_) -> saw(seen, wanted, ms)
    Error(Nil) -> False
  }
}

// Whether nothing of these kinds shows up for a while: no worker started and
// no session stopped.
fn quiet_of_workers(seen: Subject(Seen)) -> Bool {
  case process.receive(seen, 300) {
    Ok(Started(_)) | Ok(Stopped) -> False
    Ok(Built(..)) -> quiet_of_workers(seen)
    Error(Nil) -> True
  }
}

// How many builds show up within a while.
fn builds(seen: Subject(Seen), count: Int) -> Int {
  case process.receive(seen, 400) {
    Ok(Built(..)) -> builds(seen, count + 1)
    Ok(_) -> builds(seen, count)
    Error(Nil) -> count
  }
}

fn accept(trigger: String) -> tools.Item {
  tools.Item(
    trigger: model.TriggerId(trigger),
    action: tools.Accept(model.title("work on " <> trigger)),
    holds: [],
    related: [],
    prior_hand_back: None,
  )
}

fn want_worker(handle: project_host.Handle, trigger: String) -> Nil {
  let assert Ok(_) = project_host.post(handle, trigger, "fix " <> trigger)
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept(trigger)])
  Nil
}

// --- precedence ----------------------------------------------------------------------

pub fn a_projects_own_value_outranks_the_file_and_release_gives_it_back_test() {
  let path = directory("precedence")
  let seen = process.new_subject()
  let handle =
    start(config(
      path,
      seen,
      hold(Open),
      file_policy("file check", "file setup"),
      None,
    ))

  // Nothing held: the file's check is in force, from the file, and the
  // built-in default of publish is from the default.
  assert entry(handle, overrides.CheckKey).values == ["file check"]
  assert entry(handle, overrides.CheckKey).source == overrides.FromFile
  assert entry(handle, overrides.PublishKey).source == overrides.FromDefault
  assert entry(handle, overrides.MaxWorkersKey).values == ["2"]

  // A held value is in force and says it is the project's own, with who set it.
  let assert Ok(_) = hold_value(handle, overrides.CheckKey, ["own check"])
  let held = entry(handle, overrides.CheckKey)
  assert held.values == ["own check"]
  assert held.source == overrides.FromProject
  let assert Some(#("owner", at)) = held.changed
  assert at > 0

  // Releasing it returns the file's value and keeps the other keys as they were.
  let assert Ok(_) = release(handle, overrides.CheckKey)
  assert entry(handle, overrides.CheckKey).values == ["file check"]
  assert entry(handle, overrides.CheckKey).source == overrides.FromFile
  assert entry(handle, overrides.SetupKey).values == ["file setup"]
  stop(handle)
}

pub fn a_file_default_that_changes_at_boot_shows_under_a_projects_own_value_test() {
  let path = directory("boot")
  let seen = process.new_subject()
  let first =
    start(config(
      path,
      seen,
      hold(Open),
      file_policy("file check", "file setup"),
      None,
    ))
  let assert Ok(_) = hold_value(first, overrides.CheckKey, ["own check"])
  let assert Ok(_) = hold_value(first, overrides.MaxWorkersKey, ["3"])
  stop(first)

  // The file changes while the daemon is down. The project's own values
  // survive the restart and still win, and the key it does not hold follows
  // the file.
  let second =
    start(config(
      path,
      seen,
      hold(Open),
      file_policy("new file check", "new file setup"),
      None,
    ))
  assert entry(second, overrides.CheckKey).values == ["own check"]
  assert entry(second, overrides.CheckKey).source == overrides.FromProject
  assert entry(second, overrides.MaxWorkersKey).values == ["3"]
  assert entry(second, overrides.SetupKey).values == ["new file setup"]
  assert entry(second, overrides.SetupKey).source == overrides.FromFile

  // Releasing the check now shows the file's new one.
  let assert Ok(_) = release(second, overrides.CheckKey)
  assert entry(second, overrides.CheckKey).values == ["new file check"]
  stop(second)
}

pub fn the_whole_history_survives_a_compaction_and_a_restart_test() {
  let path = directory("compact")
  let seen = process.new_subject()
  let first = start(config(path, seen, hold(Open), file_policy("c", "s"), None))
  let assert Ok(_) = hold_value(first, overrides.CheckKey, ["own check"])
  let assert Ok(_) =
    hold_value(first, overrides.ProtectedPathsKey, ["Makefile", "ci/**"])
  let assert Ok(_) = project_host.compact(first)
  stop(first)
  let second =
    start(config(path, seen, hold(Open), file_policy("c", "s"), None))
  assert entry(second, overrides.CheckKey).values == ["own check"]
  assert entry(second, overrides.ProtectedPathsKey).values
    == ["Makefile", "ci/**"]
  assert view(second).revision == 2
  stop(second)
}

// --- the same rules as the file --------------------------------------------------------

pub fn a_value_is_refused_in_the_files_words_test() {
  // A value the file would refuse is refused by `parse` with the file's own
  // sentence, since both call the same functions.
  let assert Error(blank) = overrides.parse(overrides.CheckKey, ["   "])
  assert blank
    == "project.check must be a non-empty command of at most 4096 bytes"
  let long = string.repeat("x", 4097)
  let assert Error(_) = overrides.parse(overrides.SetupKey, [long])
  let assert Error(workers) = overrides.parse(overrides.MaxWorkersKey, ["17"])
  assert workers == "project.max_workers must be an integer in range"
  let assert Error(_) = overrides.parse(overrides.MaxWorkersKey, ["many"])
  let assert Error(mode) = overrides.parse(overrides.PublishKey, ["yes"])
  assert mode == "project.publish must be \"off\" or \"pull_request\""
  let assert Error(paths) = overrides.parse(overrides.ProtectedPathsKey, [""])
  assert paths == "project.protected_paths must hold non-empty strings"
  let assert Error(_) = overrides.parse(overrides.CheckKey, ["a", "b"])
  let assert Error(unknown) = overrides.key_from_word("token_ceiling")
  assert string.contains(unknown, "token_ceiling")

  // The file refuses the same values with the same words.
  let assert Error(from_file) = project_settings.command_text("check", "   ")
  assert from_file == blank
}

// --- no restart ------------------------------------------------------------------------

pub fn a_changed_setup_rebuilds_the_template_without_a_restart_test() {
  let path = directory("rebuild")
  let seen = process.new_subject()
  let holder = hold(Open)
  let handle =
    start(config(
      path,
      seen,
      holder,
      file_policy("file check", "file setup"),
      None,
    ))
  assert saw(seen, Built("file setup", Some("file check")), 5000)
  assert eventually(fn() { sources(handle) }, "\"ready\"")

  // The new setup holds new workers back until its own build is ready.
  process.send(holder, Put(Closed))
  let assert Ok(_) = hold_value(handle, overrides.SetupKey, ["own setup"])
  assert saw(seen, Built("own setup", Some("file check")), 5000)
  assert eventually(fn() { sources(handle) }, "\"preparing\"")
  want_worker(handle, "a")
  assert quiet_of_workers(seen)

  // The build ends and the worker starts.
  process.send(holder, Put(Open))
  assert saw(seen, Started("project:p1:t-a:1"), 10_000)
  assert eventually(fn() { sources(handle) }, "\"ready\"")
  stop(handle)
}

pub fn a_changed_check_proves_the_base_check_again_test() {
  let path = directory("check")
  let seen = process.new_subject()
  let handle =
    start(config(
      path,
      seen,
      hold(Open),
      file_policy("file check", "file setup"),
      None,
    ))
  assert saw(seen, Built("file setup", Some("file check")), 5000)
  let assert Ok(_) = hold_value(handle, overrides.CheckKey, ["own check"])
  assert saw(seen, Built("file setup", Some("own check")), 5000)
  stop(handle)
}

pub fn a_change_that_moves_neither_command_does_not_rebuild_test() {
  let path = directory("no-rebuild")
  let seen = process.new_subject()
  let handle =
    start(config(
      path,
      seen,
      hold(Open),
      file_policy("file check", "file setup"),
      None,
    ))
  assert saw(seen, Built("file setup", Some("file check")), 5000)
  assert eventually(fn() { sources(handle) }, "\"ready\"")
  assert builds(seen, 0) == 0
  let assert Ok(_) = hold_value(handle, overrides.MaxWorkersKey, ["5"])
  let assert Ok(_) =
    hold_value(handle, overrides.ProtectedPathsKey, ["Makefile"])
  assert builds(seen, 0) == 0
  stop(handle)
}

pub fn a_running_worker_is_not_disturbed_by_a_change_test() {
  let path = directory("running")
  let seen = process.new_subject()
  let holder = hold(Open)
  let handle =
    start(config(
      path,
      seen,
      holder,
      file_policy("file check", "file setup"),
      None,
    ))
  assert eventually(fn() { sources(handle) }, "\"ready\"")
  want_worker(handle, "a")
  assert saw(seen, Started("project:p1:t-a:1"), 10_000)

  // A new setup and a new check change what new workers wait for. The worker
  // that is running keeps its session: nothing stops it.
  process.send(holder, Put(Closed))
  let assert Ok(_) = hold_value(handle, overrides.SetupKey, ["own setup"])
  let assert Ok(_) = hold_value(handle, overrides.CheckKey, ["own check"])
  assert quiet_of_workers(seen)
  process.send(holder, Put(Open))
  stop(handle)
}

pub fn a_build_that_ends_under_old_commands_is_not_recorded_test() {
  let path = directory("stale")
  let seen = process.new_subject()
  let holder = hold(Closed)
  let handle =
    start(config(
      path,
      seen,
      holder,
      file_policy("file check", "file setup"),
      None,
    ))

  // The first build is in flight when the setup changes. Its answer says
  // nothing about the template that is wanted, so the build that is wanted
  // runs after it, and the board becomes ready only for that one.
  assert saw(seen, Built("file setup", Some("file check")), 5000)
  let assert Ok(_) = hold_value(handle, overrides.SetupKey, ["own setup"])
  assert eventually(fn() { sources(handle) }, "\"preparing\"")
  process.send(holder, Put(Open))
  assert saw(seen, Built("own setup", Some("file check")), 10_000)
  assert eventually(fn() { sources(handle) }, "\"ready\"")
  stop(handle)
}

pub fn a_stale_revision_is_refused_and_writes_nothing_test() {
  let path = directory("stale-revision")
  let seen = process.new_subject()
  let handle =
    start(config(path, seen, hold(Open), file_policy("c", "s"), None))
  let read = view(handle).revision
  let assert Ok(override) = overrides.parse(overrides.CheckKey, ["one"])
  let assert Ok(_) =
    project_host.change_settings(
      handle,
      read,
      [overrides.Hold(override)],
      None,
      "owner",
    )
  let assert Ok(other) = overrides.parse(overrides.CheckKey, ["two"])
  assert project_host.change_settings(
      handle,
      read,
      [overrides.Hold(other)],
      None,
      "owner",
    )
    == Error(project_host.StaleSettings)
  assert entry(handle, overrides.CheckKey).values == ["one"]
  stop(handle)
}

// --- publish ---------------------------------------------------------------------------

pub fn turning_publish_on_must_name_where_it_publishes_test() {
  let path = directory("publish")
  let seen = process.new_subject()
  let handle =
    start(config(path, seen, hold(Open), file_policy("c", "s"), Some(url)))
  let assert Ok(on) = overrides.parse(overrides.PublishKey, ["pull_request"])
  let revision = view(handle).revision

  // A write that carries the key, with nothing named, is refused and says
  // where publishing would go. A blanket write of other keys beside it is
  // refused whole.
  let assert Ok(workers) = overrides.parse(overrides.MaxWorkersKey, ["3"])
  let assert Error(project_host.RefusedSettings(words)) =
    project_host.change_settings(
      handle,
      revision,
      [overrides.Hold(workers), overrides.Hold(on)],
      None,
      "owner",
    )
  assert string.contains(words, url)
  assert entry(handle, overrides.MaxWorkersKey).values == ["2"]
  assert entry(handle, overrides.PublishKey).values == ["off"]

  // Naming another URL is no confirmation.
  let assert Error(project_host.RefusedSettings(_)) =
    project_host.change_settings(
      handle,
      revision,
      [overrides.Hold(on)],
      Some("https://github.com/o/other"),
      "owner",
    )

  // Naming the URL turns it on.
  let assert Ok(done) =
    project_host.change_settings(
      handle,
      revision,
      [overrides.Hold(on)],
      Some(url),
      "owner",
    )
  assert done.publish_url == Some(url)
  assert entry(handle, overrides.PublishKey).values == ["pull_request"]

  // Turning it off again needs no confirmation.
  let assert Ok(off) = overrides.parse(overrides.PublishKey, ["off"])
  let assert Ok(_) =
    project_host.change_settings(
      handle,
      view(handle).revision,
      [overrides.Hold(off)],
      None,
      "owner",
    )
  assert entry(handle, overrides.PublishKey).values == ["off"]
  stop(handle)
}

pub fn a_project_with_no_remote_cannot_turn_publish_on_test() {
  let path = directory("no-remote")
  let seen = process.new_subject()
  let handle =
    start(config(path, seen, hold(Open), file_policy("c", "s"), None))
  let assert Ok(on) = overrides.parse(overrides.PublishKey, ["pull_request"])
  let assert Error(project_host.RefusedSettings(words)) =
    project_host.change_settings(
      handle,
      view(handle).revision,
      [overrides.Hold(on)],
      Some(url),
      "owner",
    )
  assert string.contains(words, "no remote")
  stop(handle)
}

pub fn publish_is_still_off_after_a_restart_unless_it_was_turned_on_test() {
  let path = directory("publish-restart")
  let seen = process.new_subject()
  let first =
    start(config(path, seen, hold(Open), file_policy("c", "s"), Some(url)))
  let assert Ok(on) = overrides.parse(overrides.PublishKey, ["pull_request"])
  let assert Ok(_) =
    project_host.change_settings(
      first,
      view(first).revision,
      [overrides.Hold(on)],
      Some(url),
      "owner",
    )
  stop(first)
  let second =
    start(config(path, seen, hold(Open), file_policy("c", "s"), Some(url)))
  assert entry(second, overrides.PublishKey).values == ["pull_request"]
  assert entry(second, overrides.PublishKey).source == overrides.FromProject
  stop(second)
}

// --- two projects ------------------------------------------------------------------------

pub fn two_projects_keep_their_own_commands_and_templates_test() {
  let first_seen = process.new_subject()
  let second_seen = process.new_subject()
  let one =
    start(config(
      directory("one"),
      first_seen,
      hold(Open),
      file_policy("check one", "setup one"),
      None,
    ))
  let two =
    start(config(
      directory("two"),
      second_seen,
      hold(Open),
      file_policy("check two", "setup two"),
      None,
    ))

  // Each builds its own template with its own commands.
  assert saw(first_seen, Built("setup one", Some("check one")), 5000)
  assert saw(second_seen, Built("setup two", Some("check two")), 5000)
  assert eventually(fn() { sources(one) }, "\"ready\"")
  assert eventually(fn() { sources(two) }, "\"ready\"")

  // A change to one is seen there and leaves the other alone: no new build,
  // and the same values.
  let assert Ok(_) = hold_value(one, overrides.SetupKey, ["setup one b"])
  assert saw(first_seen, Built("setup one b", Some("check one")), 5000)
  assert builds(second_seen, 0) == 0
  assert entry(two, overrides.SetupKey).values == ["setup two"]
  assert entry(two, overrides.SetupKey).source == overrides.FromFile
  assert entry(one, overrides.SetupKey).source == overrides.FromProject
  assert view(two).revision == 0
  stop(one)
  stop(two)
}

// --- authority ---------------------------------------------------------------------------

pub fn no_router_or_worker_tool_reaches_a_projects_settings_test() {
  // The router has three tools and a worker two. None of them is a settings
  // tool, and the router's `project_read` has no resource for them, so
  // nothing a model, a worker or a GitHub comment says can change a setting.
  assert tools.router_tool_names == ["route", "project_read", "reply"]
  assert tools.worker_tool_names == ["project_report", "project_handback"]
  assert list.all(
    list.append(tools.router_tool_names, tools.worker_tool_names),
    fn(name) { !string.contains(name, "setting") },
  )
  assert result.is_error(tools.parse_resource("settings"))
  assert result.is_error(tools.parse_resource("project/settings"))
}
