//// The `--executor` launch flag and how it reaches a session creation
//// (protocol-change/078). With an executor, `--workspace` is a name registered
//// on that executor and not a directory: it is parsed apart from the launch's
//// own paths, sent to the daemon exactly as typed, and shown in listings with
//// its executor.

import etui/backend
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/bootstrap
import tui/connection
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection as daemon_selection
import tui/effect
import tui/frame
import tui/job
import tui/model as tui_model
import tui/placement
import tui/runtime
import tui/session_selector
import tui/session_table
import tui/view_set
import tui/workspace
import tui_test/stepping
import weft

// A launch that names nothing about executors is the launch it always was.
pub fn a_launch_without_the_flag_creates_on_this_host_test() {
  let assert Ok(options) = tui.launch_options([])
  assert options.placement == placement.OnThisHost
  let assert Ok(options) = tui.launch_options(["--workspace", "/work"])
  assert options.placement == placement.OnThisHost
  assert options.workspace == "/work"
}

// The registered name never reaches `Options.workspace`, which the launcher
// canonicalizes as a path; it lives only in the placement.
pub fn the_flag_names_an_executor_and_a_registered_workspace_test() {
  let assert Ok(options) =
    tui.launch_options([
      "--executor", "build-box", "--workspace", "app", "--config",
      "/etc/loom.toml", "--model-profile", "cheap",
    ])
  assert options.placement == placement.OnExecutor("build-box", "app")
  assert options.workspace == ""
  assert options.config == "/etc/loom.toml"
  assert options.profile == "cheap"
}

// The order of the two flags does not matter.
pub fn the_workspace_may_come_before_the_executor_test() {
  let assert Ok(options) =
    tui.launch_options(["--workspace", "app", "--executor", "box"])
  assert options.placement == placement.OnExecutor("box", "app")
}

pub fn an_executor_without_a_registered_workspace_is_refused_test() {
  let assert Error(reason) = tui.launch_options(["--executor", "box"])
  assert string.contains(reason, "--executor needs --workspace")
}

pub fn a_missing_or_flag_shaped_executor_is_refused_test() {
  let assert Error(reason) = tui.launch_options(["--executor"])
  assert string.contains(reason, "missing value for --executor")
  let assert Error(reason) =
    tui.launch_options(["--executor", "--workspace", "app"])
  assert string.contains(reason, "--executor needs a value")
}

pub fn a_repeated_executor_is_refused_test() {
  let assert Error(reason) =
    tui.launch_options([
      "--executor", "a", "--executor", "b", "--workspace", "app",
    ])
  assert string.contains(reason, "--executor was given more than once")
}

// A path where a registered name goes is refused before any request is built,
// so the daemon is never sent a directory to canonicalize on the wrong host.
pub fn a_path_is_not_a_registered_workspace_name_test() {
  let assert Error(reason) =
    tui.launch_options(["--executor", "box", "--workspace", "/work/app"])
  assert string.contains(reason, "registered workspace name")
  let assert Error(_) =
    tui.launch_options(["--executor", "box", "--workspace", "a/b"])
  let assert Error(_) =
    tui.launch_options(["--executor", "box", "--workspace", ""])
}

pub fn an_executor_name_must_be_a_configuration_key_test() {
  let assert Error(reason) =
    tui.launch_options(["--executor", "Build Box", "--workspace", "app"])
  assert string.contains(reason, "--executor needs an executor name")
}

// The placement decides where a new session goes; `--session` opens one that
// exists, so combining them would silently ignore one of the two.
pub fn an_executor_cannot_choose_where_an_existing_session_lives_test() {
  let assert Error(reason) =
    tui.launch_options([
      "--executor", "box", "--workspace", "app", "--session", "01a11401",
    ])
  assert string.contains(reason, "--session opens an existing one")
}

// `loom ui` and `loom sessions` create nothing, so they do not take the flag.
pub fn the_other_commands_do_not_take_the_flag_test() {
  let assert Error(reason) = tui.launch_sessions(["list", "--executor", "box"])
  assert string.contains(reason, "unknown local launch option --executor")
  let assert Error(reason) = tui.launch_view(["ui", "--executor", "box"])
  assert string.contains(reason, "unknown local launch option --executor")
}

pub fn the_usage_names_the_flag_test() {
  let assert Error(reason) = tui.launch_options(["--bogus", "x"])
  assert string.contains(
    reason,
    "--executor <name> --workspace <registered name>",
  )
}

// The executor travels as a field of its own, beside the registered name in
// `workspace`; a local creation sends the request it always did.
pub fn creation_sends_the_executor_only_for_a_registered_workspace_test() {
  let encoded = fn(workspace, executor) {
    let assert Ok(body) =
      protocol.encode(
        7,
        protocol.CreateSession(
          "key",
          workspace,
          "app",
          "/config",
          "",
          executor,
          "",
        ),
        protocol.Epoch("current"),
      )
    body
  }
  let remote = encoded("app", "build-box")
  assert string.contains(remote, "\"executor\":\"build-box\"")
  assert string.contains(remote, "\"workspace\":\"app\"")
  assert !string.contains(encoded("/work", ""), "\"executor\"")
}

pub fn an_over_long_executor_name_is_refused_before_it_is_sent_test() {
  let assert Error(_) =
    protocol.encode(
      7,
      protocol.CreateSession(
        "key",
        "app",
        "app",
        "",
        "",
        string.repeat("a", 65),
        "",
      ),
      protocol.Epoch("current"),
    )
  Nil
}

@external(erlang, "effects_test_ffi", "host_on")
fn host_on(owner: Subject(Dynamic)) -> daemon_selection.Host

fn options_in(placed: placement.Placement) -> bootstrap.Options {
  bootstrap.Options(
    "",
    "",
    "",
    "build",
    "build/s6-absent/loom.toml",
    "",
    placed,
  )
}

// A terminal at the session picker whose launch named an executor, with a
// stand-in daemon host, ready for `n`.
fn picker() -> tui_model.Model {
  picker_in(placement.OnExecutor("build-box", "app"))
}

// The same picker for any placement.
fn picker_in(placed: placement.Placement) -> tui_model.Model {
  let owner: Subject(Dynamic) = process.new_subject()
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("/cwd", None))
  tui_model.Model(
    ..base,
    view: base.view
      |> view_set.local_options(Some(options_in(placed)))
      |> view_set.overlay(
        tui_model.DaemonSelector(session_selector.new(
          protocol.Page(0, [], None),
          "",
        )),
      ),
  )
  |> runtime.adopt_control(host_on(owner))
}

fn is_job(requested: effect.Effect) -> Bool {
  case requested {
    effect.StartJob(..) | effect.CancelJob(_) -> True
    _ -> False
  }
}

// Pressing `n` creates on the executor: the attachment job carries the
// registered name, not the terminal's working directory, and names the
// executor. The session's display name comes from the registered name too.
pub fn a_creation_carries_the_launch_executor_test() {
  let #(asked, _effects) = stepping.step(backend.KeyPress("n"), picker())
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
        "app",
        "app",
        "/cfg/loom.toml",
        "",
        "build-box",
        "",
      ),
      90_000,
    )
}

fn row(
  id: String,
  workspace: String,
  executor: option.Option(String),
) -> protocol.Session {
  protocol.Session(id, workspace, "work", 0, protocol.Saved, None, executor)
}

// A registered name is no path, so a listing says which executor it is on, and
// the plain, script-read format shows it the way `scp` writes a host and path.
pub fn listings_show_the_executor_of_a_remote_session_test() {
  let local = row("a", "/work/app", None)
  let remote = row("b", "app", Some("build-box"))
  assert placement.label(local.executor, local.workspace) == "/work/app"
  assert placement.label(remote.executor, remote.workspace) == "build-box:app"
  assert frame.buffer_to_lines(session_table.render([local, remote]))
    == [
      "SESSION  STATE  WORKSPACE      NAME",
      "a        saved  /work/app      work",
      "b        saved  build-box:app  work",
    ]
  assert tui.format_listing([local, remote], tui.Every, Error("not a terminal"))
    == "a  saved  /work/app  work\nb  saved  build-box:app  work"
}

// Two executors may each register `app`; their sessions are not one project,
// and neither is a directory called `app` on the daemon's host.
pub fn the_picker_groups_by_executor_and_name_test() {
  let rows = [
    row("a", "app", Some("one")),
    row("b", "app", Some("two")),
    row("c", "app", Some("one")),
    row("d", "/work/app", None),
  ]
  let state = session_selector.new(protocol.Page(0, rows, None), "")
  let places = list.map(session_selector.groups(state), fn(group) { group.0 })
  assert places
    == [
      session_selector.Registered("one", "app"),
      session_selector.Registered("two", "app"),
      session_selector.Directory("/work/app"),
    ]
}

pub fn daemon_failures_for_an_executor_are_worded_test() {
  assert daemon_selection.failure(daemon.Refused(
      "executor_unknown",
      "no executor with that name is configured on this daemon",
    ))
    == "executor_unknown: no executor with that name is configured on this daemon; --executor must be an [executors.<name>] key of the daemon's configuration"
  assert daemon_selection.failure(daemon.Refused(
      "start_failed",
      "executor_unavailable: this daemon was not started with [distribution]",
    ))
    == "session startup failed (executor_unavailable): this daemon was not started with [distribution]"
  assert daemon_selection.failure(daemon.Refused("start_failed", "other"))
    == "session startup failed: other"
}

// --- pools -------------------------------------------------------------------

pub fn the_flag_names_a_pool_and_a_registered_workspace_test() {
  let assert Ok(options) =
    tui.launch_options([
      "--pool", "builders", "--workspace", "app", "--model-profile", "cheap",
    ])
  assert options.placement == placement.InPool("builders", "app")
  assert options.workspace == ""
  assert options.profile == "cheap"
  let assert Ok(options) =
    tui.launch_options(["--workspace", "app", "--pool", "builders"])
  assert options.placement == placement.InPool("builders", "app")
}

pub fn a_pool_and_an_executor_are_exclusive_test() {
  let assert Error(reason) =
    tui.launch_options([
      "--executor", "box", "--pool", "builders", "--workspace", "app",
    ])
  assert string.contains(reason, "--executor and --pool are exclusive")
}

pub fn a_pool_needs_a_registered_workspace_name_test() {
  let assert Error(reason) = tui.launch_options(["--pool", "builders"])
  assert string.contains(reason, "--pool needs --workspace")
  let assert Error(reason) =
    tui.launch_options(["--pool", "builders", "--workspace", "/work/app"])
  assert string.contains(reason, "registered workspace name")
  let assert Error(reason) =
    tui.launch_options(["--pool", "Big Pool", "--workspace", "app"])
  assert string.contains(reason, "--pool needs a pool name")
  let assert Error(reason) =
    tui.launch_options(["--pool", "a", "--pool", "b", "--workspace", "app"])
  assert string.contains(reason, "--pool was given more than once")
}

pub fn a_pool_cannot_choose_where_an_existing_session_lives_test() {
  let assert Error(reason) =
    tui.launch_options([
      "--pool", "builders", "--workspace", "app", "--session", "01a11401",
    ])
  assert string.contains(reason, "--session opens an existing one")
}

pub fn the_other_commands_do_not_take_the_pool_flag_test() {
  let assert Error(reason) = tui.launch_sessions(["list", "--pool", "builders"])
  assert string.contains(reason, "unknown local launch option --pool")
}

pub fn the_usage_names_the_pool_flag_test() {
  let assert Error(reason) = tui.launch_options(["--bogus", "x"])
  assert string.contains(reason, "--pool <name> --workspace <registered name>")
}

pub fn creation_sends_the_pool_only_for_a_pooled_workspace_test() {
  let encoded = fn(workspace, pool) {
    let assert Ok(body) =
      protocol.encode(
        7,
        protocol.CreateSession("key", workspace, "app", "/config", "", "", pool),
        protocol.Epoch("current"),
      )
    body
  }
  let pooled = encoded("app", "builders")
  assert string.contains(pooled, "\"pool\":\"builders\"")
  assert string.contains(pooled, "\"workspace\":\"app\"")
  assert !string.contains(pooled, "\"executor\"")
  assert !string.contains(encoded("/work", ""), "\"pool\"")
}

pub fn an_over_long_pool_name_is_refused_before_it_is_sent_test() {
  let assert Error(_) =
    protocol.encode(
      7,
      protocol.CreateSession(
        "key",
        "app",
        "app",
        "",
        "",
        "",
        string.repeat("a", 65),
      ),
      protocol.Epoch("current"),
    )
  Nil
}

// Pressing `n` in a terminal launched with `--pool` asks the daemon to create in
// that pool: the attachment job carries the registered name and the pool, and no
// executor.
pub fn a_creation_carries_the_launch_pool_test() {
  let #(asked, _effects) =
    stepping.step(
      backend.KeyPress("n"),
      picker_in(placement.InPool("builders", "app")),
    )
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
        "app",
        "app",
        "/cfg/loom.toml",
        "",
        "",
        "builders",
      ),
      90_000,
    )
}

pub fn daemon_failures_for_a_pool_are_worded_test() {
  assert daemon_selection.failure(daemon.Refused(
      "pool_unknown",
      "no pool with that name is configured on this daemon",
    ))
    == "pool_unknown: no pool with that name is configured on this daemon; --pool must be a [pools.<name>] key of the daemon's configuration"
}

pub fn the_placement_new_rules_are_total_test() {
  assert placement.new(None, None, None) == Ok(placement.OnThisHost)
  assert placement.new(None, None, Some("/work")) == Ok(placement.OnThisHost)
  assert placement.new(Some("box"), None, Some("app"))
    == Ok(placement.OnExecutor("box", "app"))
  assert placement.new(None, Some("builders"), Some("app"))
    == Ok(placement.InPool("builders", "app"))
  let assert Error(_) = placement.new(Some("a"), Some("b"), Some("app"))
  let assert Error(_) = placement.new(Some("a"), Some("b"), None)
}
