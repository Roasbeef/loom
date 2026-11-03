//// A project's template against a real repository, the shipped sandbox helper
//// and strict enforcement.
////
//// The claim is the one that makes project mode usable on a real repository: a
//// check that needs a dependency can pass offline, because `setup` fetched the
//// dependency once, from a clean checkout, with the network on, and every
//// worker clone and check tree is a copy of what it left. The "network" here is
//// a loopback HTTP server the test starts, which `setup` reaches and a check
//// does not. The repository's check needs a file that only `setup` can produce,
//// so a tree cut without the template fails it.
////
//// Strict enforcement is asked for, so a host that cannot apply every layer
//// refuses to run the command at all. A test that meets that prints a SKIP line
//// to standard error and passes, which is how the suite counts skips. The
//// tests that need `git-cow` do the same when no binary is installed.

import broker/exec
import client/daemon/project_host
import client/daemon/project_start
import client/goalstate
import client/install
import client/internal/ffi_os
import client/project_repo
import client/project_template
import client/workspace_policy
import client/worktrees.{type Worktrees}
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import mist
import simplifile
import support/project_rig
import support/worktree_rig
import telemetry/log

// --- the scene ---------------------------------------------------------------------

// The sandboxed Git over the rig's repository, with strict enforcement, beside
// the rig's own, which the test uses for the Git it does as the operator.
fn strict(rig: worktree_rig.Rig) -> Worktrees {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  let assert Ok(trees) =
    worktrees.start(
      worktrees.Config(
        state_root: rig.state,
        ledger_path: rig.ledger_path,
        helper_path: here <> "/../sandbox/loom-exec",
        credentials: [],
        path: "",
        demand: exec.PlatformEnforcement,
        logger: log.discard(),
      ),
      [rig.workspace],
    )
    as "the worktrees start"
  trees
}

// A loopback HTTP server that answers every request with `PAYLOAD`. It is the
// "network" a dependency download reaches.
fn dependency_server() -> Int {
  let ports = process.new_subject()
  let assert Ok(_) =
    mist.new(fn(_request) {
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("PAYLOAD")))
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
    as "the dependency server starts"
  let assert Ok(port) = process.receive(ports, 2000)
    as "the server publishes its port"
  port
}

fn fetch(port: Int, into: String) -> String {
  "mkdir -p .deps && curl -sf --max-time 10 http://127.0.0.1:"
  <> int.to_string(port)
  <> "/dep -o "
  <> into
}

// What the project's check needs: a file only a fetch can make.
const needs_dependency = "test \"$(cat .deps/dep.txt)\" = PAYLOAD"

type Scene {
  Scene(
    rig: worktree_rig.Rig,
    trees: Worktrees,
    layout: project_repo.Layout,
    port: Int,
  )
}

fn scene(name: String) -> Scene {
  let rig = worktree_rig.rig_at(name, "main")
  let layout = project_rig.started(rig)

  // The dependency directory is ignored, as a real repository ignores its
  // build output.
  worktree_rig.write(rig.root <> "/.gitignore", ".deps/\n")
  worktree_rig.git(rig.root, ["add", ".gitignore"])
  worktree_rig.git(rig.root, ["commit", "--quiet", "-m", "ignore deps"])
  Scene(rig:, trees: strict(rig), layout:, port: dependency_server())
}

fn request(
  setup: String,
  check: option.Option(String),
) -> project_template.Request {
  project_template.Request(
    setup:,
    check:,
    setup_wall_ms: 120_000,
    check_wall_ms: 60_000,
    current: None,
  )
}

fn skip(why: String) -> Nil {
  io.println_error("SKIP project_template: " <> why)
}

// A degraded host refuses the command, and the build then reports that it did
// not finish. That is not a failure of the claim.
fn degraded(outcome: project_template.Outcome) -> Bool {
  case outcome {
    project_template.Failed(project_template.Failure(_, output)) ->
      string.contains(output, "did not finish")
    project_template.Built(_) | project_template.Unchanged(_) -> False
  }
}

// A copier that records how each copy was made.
fn copier(
  program: option.Option(String),
  seen: process.Subject(project_repo.Method),
) -> project_repo.Copier {
  project_repo.Copier(program:, report: fn(method, _elapsed_ms) {
    process.send(seen, method)
  })
}

fn warm(
  program: option.Option(String),
) -> #(project_repo.Seed, process.Subject(project_repo.Method)) {
  let seen = process.new_subject()
  #(project_repo.Warm(copier(program, seen)), seen)
}

fn check_request(commit: String, command: String) -> project_host.CheckRequest {
  project_host.CheckRequest(ticket: "t-a", commit:, command:, wall_ms: 60_000)
}

fn head(scene: Scene) -> String {
  worktree_rig.git(scene.rig.root, ["rev-parse", "HEAD"])
}

// Takes a commit into the host repository the way the host takes in a head, so
// a check can be cut at it.
fn taken(scene: Scene, files: List(#(String, String))) -> String {
  let clone = project_rig.cloned(scene.rig, scene.layout, "t-a-1")
  let commit = project_rig.commit(clone, files)
  let assert Ok(project_repo.Accepted(commit: held, changed: _)) =
    project_repo.intake(scene.rig.trees, scene.layout, "t-a", "t-a-1")
    as "the host repository takes the commit in"
  assert held == commit
  commit
}

// --- the claim -----------------------------------------------------------------------

pub fn a_check_that_needs_a_fetched_file_passes_offline_only_from_the_template_test() {
  let scene = scene("tpl-claim")
  let commit = taken(scene, [#("src/a.go", "package a\n")])
  let command = check_request(commit, needs_dependency)

  // Without a template the offline check fails: nothing fetched the file.
  let cold =
    project_start.run_check(
      ffi_os.system_time_ms,
      scene.layout,
      Ok(scene.trees),
      command,
    )
  assert cold.ending != goalstate.Exited(status: 0)

  // Setup fetches it once, and the base check, which needs it too, passes on
  // the clean base before any worker has a copy.
  let outcome =
    project_template.build(
      scene.trees,
      scene.layout,
      request(fetch(scene.port, ".deps/dep.txt"), Some(needs_dependency)),
    )
  case degraded(outcome) {
    True -> skip("the sandbox could not run the setup command")
    False -> {
      let assert project_template.Built(built) = outcome
      assert built == head(scene) |> string.slice(0, 40)
      assert worktree_rig.exists(project_repo.template_path(scene.layout))
      assert !worktree_rig.exists(project_repo.template_making_path(
        scene.layout,
      ))

      // The same offline check now passes in a tree cut from the template.
      let #(seed, seen) = warm(None)
      let result =
        project_start.run_check_from(
          ffi_os.system_time_ms,
          scene.layout,
          Ok(scene.trees),
          seed,
          command,
        )
      assert result.ending == goalstate.Exited(status: 0)
      assert process.receive(seen, 100)
        == Ok(project_repo.PlainCopy("git-cow not found"))
    }
  }
}

pub fn the_check_has_no_network_though_setup_had_it_test() {
  let scene = scene("tpl-offline")
  let commit = taken(scene, [#("src/a.go", "package a\n")])
  let outcome =
    project_template.build(
      scene.trees,
      scene.layout,
      request(fetch(scene.port, ".deps/dep.txt"), None),
    )
  case degraded(outcome) {
    True -> skip("the sandbox could not run the setup command")
    False -> {
      // The control is the build above: the same fetch, with the network on,
      // made the file. A check that tries it again is refused.
      assert worktree_rig.exists(
        project_repo.template_path(scene.layout) <> "/.deps/dep.txt",
      )
      let #(seed, _) = warm(None)
      let result =
        project_start.run_check_from(
          ffi_os.system_time_ms,
          scene.layout,
          Ok(scene.trees),
          seed,
          check_request(
            commit,
            "touch written-in-tree || exit 9\n"
              <> fetch(scene.port, "again.txt")
              <> "\ntest $? -ne 0 || exit 55\ntest ! -s again.txt || exit 56\nexit 0",
          ),
        )

      // Exit 0 says the fetch failed and left nothing. Exit 55 or 56 would say
      // the check reached the network.
      assert result.ending == goalstate.Exited(status: 0)
    }
  }
}

// --- the mask -------------------------------------------------------------------------

pub fn a_workers_policy_and_a_checks_policy_cannot_read_the_template_test() {
  let scene = scene("tpl-mask")
  let commit = taken(scene, [#("src/a.go", "package a\n")])
  let outcome =
    project_template.build(
      scene.trees,
      scene.layout,
      request("mkdir -p .deps && echo SECRET-CACHE > .deps/secret", None),
    )
  case degraded(outcome) {
    True -> skip("the sandbox could not run the setup command")
    False -> {
      let template = project_repo.template_path(scene.layout)

      // Both policies list the template as protected, as they list host.git.
      let worker =
        workspace_policy.protecting_projects(
          workspace_policy.base_policy(scene.rig.root),
          scene.rig.state,
        )
      let check =
        workspace_policy.protecting_project_files(
          workspace_policy.base_policy(scene.rig.root),
          scene.rig.state,
        )
      assert list.contains(worker.protected, template)
      assert list.contains(check.protected, template)
      assert list.contains(
        check.protected,
        project_repo.host_path(scene.layout),
      )

      // The check's real jail refuses the read. Exit 9 says the check's own
      // tree could not be written, which would make exit 0 mean nothing.
      let #(seed, _) = warm(None)
      let result =
        project_start.run_check_from(
          ffi_os.system_time_ms,
          scene.layout,
          Ok(scene.trees),
          seed,
          check_request(
            commit,
            string.join(
              [
                "touch written-in-tree || exit 9",
                "test -f .deps/secret || exit 6",
                "cat " <> template <> "/.deps/secret > /dev/null && exit 8",
                "cat " <> template <> "/.git/HEAD > /dev/null && exit 8",
                "exit 0",
              ],
              "\n",
            ),
          ),
        )
      assert result.ending == goalstate.Exited(status: 0)
    }
  }
}

// --- failures -------------------------------------------------------------------------

pub fn a_red_base_check_builds_no_template_and_keeps_its_output_test() {
  let scene = scene("tpl-red")
  let outcome =
    project_template.build(
      scene.trees,
      scene.layout,
      request(
        fetch(scene.port, ".deps/dep.txt"),
        Some("echo the-base-is-broken >&2; exit 4"),
      ),
    )
  case degraded(outcome) {
    True -> skip("the sandbox could not run the setup command")
    False -> {
      let assert project_template.Failed(project_template.Failure(
        stage:,
        output:,
      )) = outcome
      assert stage == project_template.BaseCheck
      assert string.contains(output, "exit status 4")
      assert string.contains(output, "the-base-is-broken")
      assert !worktree_rig.exists(project_repo.template_path(scene.layout))
      assert !worktree_rig.exists(project_repo.template_making_path(
        scene.layout,
      ))
    }
  }
}

pub fn a_failing_setup_builds_no_template_and_its_output_is_bounded_test() {
  let scene = scene("tpl-setup")
  let outcome =
    project_template.build(
      scene.trees,
      scene.layout,
      request(
        "yes line | head -c 20000; echo no-such-dependency >&2; exit 2",
        None,
      ),
    )
  case degraded(outcome) {
    True -> skip("the sandbox could not run the setup command")
    False -> {
      let assert project_template.Failed(project_template.Failure(
        stage:,
        output:,
      )) = outcome
      assert stage == project_template.Setup
      assert string.contains(output, "no-such-dependency")
      assert string.length(output) <= project_template.max_output_chars + 40
      assert !worktree_rig.exists(project_repo.template_path(scene.layout))
    }
  }
}

pub fn a_failed_rebuild_keeps_the_last_good_template_test() {
  let scene = scene("tpl-rebuild")
  let first =
    project_template.build(
      scene.trees,
      scene.layout,
      request(fetch(scene.port, ".deps/dep.txt"), None),
    )
  case degraded(first) {
    True -> skip("the sandbox could not run the setup command")
    False -> {
      let assert project_template.Built(old) = first
      let template = project_repo.template_path(scene.layout)

      // The owner's checkout moves on. A rebuild whose setup fails changes
      // nothing about the template that is in use.
      worktree_rig.write(scene.rig.root <> "/newer", "n\n")
      worktree_rig.git(scene.rig.root, ["add", "newer"])
      worktree_rig.git(scene.rig.root, ["commit", "--quiet", "-m", "newer"])
      let failed =
        project_template.build(
          scene.trees,
          scene.layout,
          project_template.Request(
            ..request("exit 3", None),
            current: Some(old),
          ),
        )
      let assert project_template.Failed(_) = failed
      assert worktree_rig.git(template, ["rev-parse", "HEAD"]) == old
      assert !worktree_rig.exists(template <> "/newer")
      assert worktree_rig.exists(template <> "/.deps/dep.txt")
      assert !worktree_rig.exists(project_repo.template_making_path(
        scene.layout,
      ))

      // A rebuild at an unmoved base does nothing, and one that succeeds swaps
      // the new tree in whole.
      let unmoved =
        project_template.build(
          scene.trees,
          scene.layout,
          project_template.Request(
            ..request("exit 3", None),
            current: Some(head(scene)),
          ),
        )
      assert unmoved == project_template.Unchanged(head(scene))
      let rebuilt =
        project_template.build(
          scene.trees,
          scene.layout,
          request(fetch(scene.port, ".deps/dep.txt"), None),
        )
      assert rebuilt == project_template.Built(head(scene))
      assert worktree_rig.exists(template <> "/newer")
      assert worktree_rig.git(template, ["rev-parse", "HEAD"]) == head(scene)
    }
  }
}

pub fn an_interrupted_build_leaves_nothing_the_next_one_could_use_test() {
  let scene = scene("tpl-crash")

  // A crash left a half-built tree under the building name, and a swap that
  // stopped between its renames left the last good template under the waiting
  // name. Neither is a template.
  let making = project_repo.template_making_path(scene.layout)
  let old = project_repo.project_directory(scene.layout) <> "/.template.old"
  worktree_rig.write(making <> "/half-built", "x\n")
  worktree_rig.write(old <> "/kept", "good\n")
  assert !worktree_rig.exists(project_repo.template_path(scene.layout))

  let outcome =
    project_template.build(
      scene.trees,
      scene.layout,
      request(fetch(scene.port, ".deps/dep.txt"), None),
    )
  case degraded(outcome) {
    True -> skip("the sandbox could not run the setup command")
    False -> {
      let assert project_template.Built(_) = outcome
      let template = project_repo.template_path(scene.layout)
      assert !worktree_rig.exists(template <> "/half-built")
      assert !worktree_rig.exists(making)

      // The restored template was replaced by the new one, which holds the
      // fetched file.
      assert worktree_rig.exists(template <> "/.deps/dep.txt")
    }
  }
}

// --- copies ----------------------------------------------------------------------------

// A template with a cache in it, built under the sandbox. `Error` carries the
// reason a degraded host gives.
fn with_template(scene: Scene) -> Result(String, String) {
  case
    project_template.build(
      scene.trees,
      scene.layout,
      request(
        fetch(scene.port, ".deps/dep.txt")
          <> " && mkdir -p build && echo cache > build/out",
        None,
      ),
    )
  {
    project_template.Built(_) -> Ok(project_repo.template_path(scene.layout))
    project_template.Unchanged(_) ->
      Ok(project_repo.template_path(scene.layout))
    project_template.Failed(project_template.Failure(_, output)) ->
      Error(output)
  }
}

pub fn a_warm_clone_by_plain_copy_keeps_the_caches_and_reads_clean_test() {
  let scene = scene("tpl-plain")
  case with_template(scene) {
    Error(why) -> skip(why)
    Ok(template) -> {
      let owners = project_rig.digest(scene.rig.root)
      let before = project_rig.digest(template)
      let #(seed, seen) = warm(None)
      let assert Ok(clone) =
        project_repo.clone_from(
          scene.trees,
          scene.layout,
          "t-a-1",
          project_repo.FromOwner,
          seed,
        )

      // The fallback was used and said so.
      let assert Ok(project_repo.PlainCopy(_)) = process.receive(seen, 100)

      // The clone is a whole repository at the owner's head on a branch of its
      // own, holding the caches, and Git reads it as clean.
      assert project_repo.sound_clone(clone) == Ok(Nil)
      assert worktree_rig.git(clone, ["rev-parse", "HEAD"]) == head(scene)
      assert worktree_rig.git(clone, ["rev-parse", "--abbrev-ref", "HEAD"])
        == "loom/t-a-1"
      assert worktree_rig.exists(clone <> "/.deps/dep.txt")
      assert worktree_rig.exists(clone <> "/build/out")
      assert worktree_rig.git(clone, ["status", "--porcelain"]) == ""
      assert worktree_rig.git(clone, ["remote"]) == ""

      // What the clone's configuration holds: the keys `git init` wrote and
      // nothing the owner has. No remote, no URL, no credential helper, no
      // extra header, no rewrite.
      let assert Ok(config) = simplifile.read(clone <> "/.git/config")
      list.each(
        ["remote", "url", "credential", "extraheader", "insteadof", "token"],
        fn(word) {
          assert !string.contains(string.lowercase(config), word)
        },
      )

      // Nothing a worker writes reaches the template, the host repository or
      // the owner's repository.
      worktree_rig.write(
        clone <> "/.git/hooks/pre-commit",
        "#!/bin/sh\nexit 0\n",
      )
      worktree_rig.git(clone, ["config", "core.fsmonitor", "/bin/true"])
      worktree_rig.write(clone <> "/.deps/dep.txt", "TAMPERED\n")
      worktree_rig.write(clone <> "/build/out", "TAMPERED\n")
      let _head = project_rig.commit(clone, [#("work", "w\n")])
      assert project_rig.digest(template) == before
      assert project_rig.digest(scene.rig.root) == owners
      assert simplifile.read(template <> "/.deps/dep.txt") == Ok("PAYLOAD")
      assert !worktree_rig.exists(template <> "/work")
    }
  }
}

pub fn a_warm_clone_from_a_commit_starts_there_with_the_caches_test() {
  let scene = scene("tpl-commit")
  case with_template(scene) {
    Error(why) -> skip(why)
    Ok(_) -> {
      let commit = taken(scene, [#("src/first.go", "package first\n")])
      let #(seed, _) = warm(None)
      let assert Ok(second) =
        project_repo.clone_from(
          scene.trees,
          scene.layout,
          "t-a-2",
          project_repo.FromCommit(commit),
          seed,
        )
      assert worktree_rig.git(second, ["rev-parse", "HEAD"]) == commit
      assert worktree_rig.exists(second <> "/src/first.go")
      assert worktree_rig.exists(second <> "/.deps/dep.txt")
      assert worktree_rig.git(second, ["status", "--porcelain"]) == ""
    }
  }
}

pub fn a_program_that_cannot_run_falls_back_to_the_plain_copy_test() {
  let scene = scene("tpl-badcow")
  case with_template(scene) {
    Error(why) -> skip(why)
    Ok(_) -> {
      let #(seed, seen) = warm(Some("/nonexistent/git-cow"))
      let assert Ok(clone) =
        project_repo.clone_from(
          scene.trees,
          scene.layout,
          "t-a-1",
          project_repo.FromOwner,
          seed,
        )
      let assert Ok(project_repo.PlainCopy(_)) = process.receive(seen, 100)
      assert worktree_rig.exists(clone <> "/.deps/dep.txt")
    }
  }
}

pub fn git_cow_makes_the_copy_when_it_is_installed_and_refuses_a_bad_template_test() {
  case install.git_cow() {
    Error(Nil) ->
      skip("git-cow is not installed, so the copy-on-write path is not run")
    Ok(program) -> {
      let scene = scene("tpl-cow")
      case with_template(scene) {
        Error(why) -> skip(why)
        Ok(template) -> {
          let owners = project_rig.digest(scene.rig.root)
          let #(seed, seen) = warm(Some(program))
          let assert Ok(clone) =
            project_repo.clone_from(
              scene.trees,
              scene.layout,
              "t-a-1",
              project_repo.FromOwner,
              seed,
            )
          assert process.receive(seen, 100)
            == Ok(project_repo.CopyOnWrite(program))
          assert worktree_rig.exists(clone <> "/.deps/dep.txt")
          assert worktree_rig.git(clone, ["status", "--porcelain"]) == ""
          let assert Ok(config) = simplifile.read(clone <> "/.git/config")
          assert !string.contains(config, "[remote")

          // A write in the copy changes neither the template nor the owner.
          let before = project_rig.digest(template)
          worktree_rig.write(clone <> "/.deps/dep.txt", "TAMPERED\n")
          let _head = project_rig.commit(clone, [#("work", "w\n")])
          assert project_rig.digest(template) == before
          assert project_rig.digest(scene.rig.root) == owners
          assert simplifile.read(template <> "/.deps/dep.txt") == Ok("PAYLOAD")

          // A template git-cow refuses is an error, not a reason to copy by
          // hand: an alternates file would be carried to every worker.
          worktree_rig.write(
            template <> "/.git/objects/info/alternates",
            "/somewhere/else/objects\n",
          )
          let assert Error(why) =
            project_repo.clone_from(
              scene.trees,
              scene.layout,
              "t-a-2",
              project_repo.FromOwner,
              seed,
            )
          assert string.contains(why, "git-cow refused the template")
          assert !worktree_rig.exists(project_repo.clone_path(
            scene.layout,
            "t-a-2",
          ))
          assert !worktree_rig.exists(
            project_repo.tickets_path(scene.layout) <> "/.t-a-2.making",
          )
        }
      }
    }
  }
}

pub fn a_tree_that_is_not_a_template_is_refused_before_the_swap_test() {
  let rig = worktree_rig.rig_at("tpl-sound", "main")
  let layout = project_rig.started(rig)
  let tree = project_repo.template_making_path(layout)
  worktree_rig.write(tree <> "/file", "x\n")
  let assert Error(_) = project_repo.sound_template(tree)

  // A repository whose `.git` is a directory is sound, and one that registers
  // a linked worktree or an alternates file is not.
  worktree_rig.git(tree, ["init", "--quiet"])
  assert project_repo.sound_template(tree) == Ok(Nil)
  worktree_rig.write(tree <> "/.git/objects/info/alternates", "/x\n")
  let assert Error(_) = project_repo.sound_template(tree)
}
