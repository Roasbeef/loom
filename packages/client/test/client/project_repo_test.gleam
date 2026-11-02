//// A project's clones and host repository against real Git and the shipped
//// sandbox helper: the claim that a worker cannot reach the owner's repository
//// and cannot change what the host checks or pushes.
////
//// The tests run the production `client/project_repo` over a real owner
//// checkout. Where the claim is about a jail, the worker's session policy is
//// composed as the daemon composes it, the helper is asked for strict
//// enforcement, and a probe runs the shell commands a hostile worker would. A
//// host that cannot apply every layer refuses to run them, and the test then
//// prints a SKIP line to standard error and passes, which is how the suite
//// counts skips. Each jail claim has a control: the same probe, under a policy
//// that is allowed to write, succeeds, so a refusal is the jail's and not a
//// mistake in the probe.

import broker/exec
import broker/policy
import client/catalog
import client/host_git
import client/internal/ffi_os
import client/project_publish
import client/project_repo
import client/workspace_policy
import client/worktrees
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import project/model
import project/protect
import simplifile
import support/project_rig
import support/worktree_rig

// --- the clone ------------------------------------------------------------------

pub fn a_clone_shares_nothing_with_the_owners_repository_test() {
  let rig = worktree_rig.rig("clone-shape")
  let layout = project_rig.started(rig)
  let owners = project_rig.digest(rig.root)
  let clone = project_rig.cloned(rig, layout, "t-a-1")

  // The clone is a repository of its own: a real `.git` directory, no
  // alternates that would let a write through it reach the source, no remote
  // naming the owner's checkout, and no object that is a hard link to the
  // owner's.
  assert project_repo.sound_clone(clone) == Ok(Nil)
  assert !bootstrap.path_exists(clone <> "/.git/objects/info/alternates")
  assert worktree_rig.git(clone, ["remote"]) == ""
  assert worktree_rig.git(clone, ["rev-parse", "--abbrev-ref", "HEAD"])
    == "loom/t-a-1"
  assert worktree_rig.git(clone, ["rev-parse", "HEAD"])
    == worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  assert linked_objects(clone) == ""

  // Everything the worker does in it leaves the owner's repository as it was.
  let _head = project_rig.commit(clone, [#("src/a.go", "package a\n")])
  worktree_rig.write(clone <> "/.git/hooks/pre-commit", "#!/bin/sh\nexit 0\n")
  worktree_rig.git(clone, ["config", "core.fsmonitor", "/bin/true"])
  assert project_rig.digest(rig.root) == owners
  assert !bootstrap.path_exists(rig.root <> "/.git/hooks/pre-commit")
}

// The objects under a path that have more than one name. A `--shared` or a
// hard-linked clone has them, and a clone made by copying has none.
fn linked_objects(clone: String) -> String {
  let assert Ok(program) = ffi_os.find_executable("find")
  let assert Ok(#(_, output)) =
    ffi_os.run_capture(
      program,
      [clone <> "/.git/objects", "-type", "f", "-links", "+1"],
      10_000,
    )
  string.trim(output)
}

pub fn a_clone_is_adopted_on_a_second_start_and_never_replaced_test() {
  let rig = worktree_rig.rig("clone-adopt")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let head = project_rig.commit(clone, [#("work", "w\n")])

  // A restart repeats the start, and the worker's commit is still there.
  let assert Ok(again) =
    project_repo.clone(rig.trees, layout, "t-a-1", project_repo.FromOwner)
  assert again == clone
  assert worktree_rig.git(clone, ["rev-parse", "HEAD"]) == head
}

pub fn two_tickets_have_clones_that_share_nothing_test() {
  let rig = worktree_rig.rig("clone-two")
  let layout = project_rig.started(rig)
  let first = project_rig.cloned(rig, layout, "t-a-1")
  let second = project_rig.cloned(rig, layout, "t-b-1")
  assert first != second
  let work = project_rig.commit(first, [#("only-in-a", "a\n")])

  // The second clone does not have the first's commit, and neither borrows
  // the other's objects.
  let #(code, _) = worktree_rig.git_status(second, ["cat-file", "-e", work])
  assert code != 0
  assert !bootstrap.path_exists(second <> "/.git/objects/info/alternates")
  assert !bootstrap.path_exists(first <> "/.git/objects/info/alternates")
}

// The commit a first assignment left, taken into the host repository the way
// the host takes in a head, and the clone it was made in.
fn first_assignment_head(
  rig: worktree_rig.Rig,
  layout: project_repo.Layout,
) -> String {
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let head = project_rig.commit(clone, [#("src/first.go", "package first\n")])
  let assert Ok(project_repo.Accepted(commit:, changed: _)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
  assert commit == head
  head
}

pub fn a_clone_cut_from_a_head_holds_that_commit_and_names_no_remote_test() {
  let rig = worktree_rig.rig("clone-from-head")
  let layout = project_rig.started(rig)
  let head = first_assignment_head(rig, layout)
  let owners = project_rig.digest(rig.root)
  let host = project_repo.host_path(layout)

  // The second assignment's clone starts at the first one's commit, with that
  // commit's file in its working tree and a branch of its own at it.
  let second =
    project_rig.cloned_from(rig, layout, "t-a-2", project_repo.FromCommit(head))
  assert project_repo.sound_clone(second) == Ok(Nil)
  assert worktree_rig.git(second, ["rev-parse", "HEAD"]) == head
  assert worktree_rig.git(second, ["rev-parse", "--abbrev-ref", "HEAD"])
    == "loom/t-a-2"
  assert worktree_rig.exists(second <> "/src/first.go")

  // It names nothing writable: no remote of any kind, no alternates, no hard
  // link to an object file of the host's, and no mention of the host
  // repository's path in its configuration, which a worker could read and an
  // escape could use.
  assert worktree_rig.git(second, ["remote"]) == ""
  assert !bootstrap.path_exists(second <> "/.git/objects/info/alternates")
  assert linked_objects(second) == ""
  let assert Ok(config) = simplifile.read(second <> "/.git/config")
  assert !string.contains(config, host)
  assert !string.contains(config, rig.root)

  // The repository was made with no template, so it holds no hook to run.
  let hooks = case simplifile.read_directory(second <> "/.git/hooks") {
    Ok(names) -> names
    Error(_) -> []
  }
  assert hooks == []

  // A commit the new worker makes descends from the earlier one, which is what
  // lets a push of the ticket's branch fast-forward the one already pushed.
  let next =
    project_rig.commit(second, [#("src/second.go", "package second\n")])
  assert worktree_rig.git(second, ["merge-base", head, next]) == head

  // The owner's checkout is as it was, and the first assignment's clone and
  // the host repository are untouched by the second.
  assert project_rig.digest(rig.root) == owners
}

pub fn a_head_the_owner_already_has_starts_from_the_owners_checkout_test() {
  let rig = worktree_rig.rig("clone-from-merged-head")
  let layout = project_rig.started(rig)
  let head = first_assignment_head(rig, layout)

  // The ticket's pull request merged and the owner pulled it, and the owner
  // has moved on since. The head is an ancestor of the owner's `HEAD`.
  worktree_rig.git(rig.root, [
    "fetch",
    "--quiet",
    project_repo.clone_path(layout, "t-a-1"),
    "loom/t-a-1",
  ])
  worktree_rig.git(rig.root, ["merge", "--quiet", "--ff-only", "FETCH_HEAD"])
  worktree_rig.write(rig.root <> "/later", "later\n")
  worktree_rig.git(rig.root, ["add", "later"])
  worktree_rig.git(rig.root, ["commit", "--quiet", "-m", "later work"])
  let owners_head = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  assert owners_head != head

  // The clone starts at the owner's `HEAD` and so has the later work, and it
  // is the same clone a ticket with no head gets, remote removal included.
  let second =
    project_rig.cloned_from(rig, layout, "t-a-2", project_repo.FromCommit(head))
  assert worktree_rig.git(second, ["rev-parse", "HEAD"]) == owners_head
  assert worktree_rig.exists(second <> "/later")
  assert worktree_rig.git(second, ["remote"]) == ""
}

pub fn a_head_the_host_does_not_hold_is_refused_and_leaves_no_clone_test() {
  let rig = worktree_rig.rig("clone-from-unknown-head")
  let layout = project_rig.started(rig)
  let unknown = "0123456789abcdef0123456789abcdef01234567"
  let assert Error(_) =
    project_repo.clone(
      rig.trees,
      layout,
      "t-a-2",
      project_repo.FromCommit(unknown),
    )
  assert !bootstrap.path_exists(project_repo.clone_path(layout, "t-a-2"))

  // A name that is not a commit name never reaches a command line.
  let assert Error(_) =
    project_repo.clone(
      rig.trees,
      layout,
      "t-a-3",
      project_repo.FromCommit("--upload-pack=x"),
    )
  assert !bootstrap.path_exists(project_repo.clone_path(layout, "t-a-3"))
}

pub fn an_adopted_clone_ignores_the_start_it_is_given_test() {
  let rig = worktree_rig.rig("clone-adopt-start")
  let layout = project_rig.started(rig)
  let head = first_assignment_head(rig, layout)
  let clone = project_rig.cloned(rig, layout, "t-a-2")
  let work = project_rig.commit(clone, [#("kept", "k\n")])

  // A restart repeats the start of the second assignment, now naming a head.
  // The clone on disk holds the worker's commit and is not replaced.
  let again =
    project_rig.cloned_from(rig, layout, "t-a-2", project_repo.FromCommit(head))
  assert again == clone
  assert worktree_rig.git(clone, ["rev-parse", "HEAD"]) == work
}

pub fn a_git_file_where_the_directory_was_is_not_a_sound_clone_test() {
  let rig = worktree_rig.rig("clone-unsound")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")

  // A linked worktree of the owner's checkout has a `.git` file naming a
  // directory inside the owner's repository. If a worker replaced its clone's
  // `.git` directory with that file, a session policy built from it would
  // widen to the owner's repository: the door the soundness check closes.
  let linked = rig.state <> "/elsewhere-linked"
  worktree_rig.git(rig.root, ["worktree", "add", "--detach", linked])
  let assert Ok(file) = simplifile.read(linked <> "/.git")
  let assert Ok(Nil) = simplifile.delete(clone <> "/.git")
  let assert Ok(Nil) = simplifile.write(clone <> "/.git", file)
  assert workspace_policy.linked_git_directories(clone) != []
  let assert Error(why) = project_repo.sound_clone(clone)
  assert string.contains(why, "not a directory")

  // A link is no more a directory than a file is.
  let assert Ok(Nil) = simplifile.delete(clone <> "/.git")
  let assert Ok(Nil) =
    simplifile.create_symlink(rig.root <> "/.git", clone <> "/.git")
  assert project_repo.sound_clone(clone) != Ok(Nil)
}

// --- the jail ---------------------------------------------------------------------

pub fn a_workers_jail_cannot_write_the_owners_repository_or_the_host_repository_test() {
  let rig = worktree_rig.rig("jail-writes")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let host = project_repo.host_path(layout)
  let owners = project_rig.digest(rig.root)
  let session = worker_policy(rig.state, clone)
  case probe(rig, session, clone, ["true"]) {
    Error(why) -> skip(why)
    Ok(_) -> {
      // The writes a hostile worker would try, one probe each. A nonzero exit
      // is the jail refusing.
      let planted_hook = rig.root <> "/.git/hooks/pre-commit"
      let planted_config = "[core]\n\tfsmonitor = /tmp/x\n"
      assert refused(rig, session, clone, "printf x > " <> planted_hook)
      assert refused(
        rig,
        session,
        clone,
        "printf '" <> planted_config <> "' >> " <> rig.root <> "/.git/config",
      )
      assert refused(
        rig,
        session,
        clone,
        "touch " <> rig.root <> "/.git/refs/heads/planted",
      )
      assert refused(rig, session, clone, "touch " <> host <> "/planted")
      assert refused(rig, session, clone, "printf x >> " <> host <> "/config")
      assert refused(rig, session, clone, "mkdir " <> host <> "/hooks")

      // The host repository is masked as well: the jail cannot read it.
      assert refused(rig, session, clone, "cat " <> host <> "/HEAD")

      // Nothing landed.
      assert !bootstrap.path_exists(planted_hook)
      assert !bootstrap.path_exists(host <> "/planted")
      assert project_rig.digest(rig.root) == owners

      // The controls. The jail does let the worker write and commit in its
      // own clone, hooks directory included, so the refusals above are about
      // where the writes went.
      assert allowed(
        rig,
        session,
        clone,
        "mkdir -p "
          <> clone
          <> "/.git/hooks && printf x > "
          <> clone
          <> "/.git/hooks/h",
      )
      assert allowed(
        rig,
        session,
        clone,
        host_git.program()
          <> " -c user.name=a -c user.email=a@b.invalid commit --quiet --allow-empty -m x",
      )
    }
  }
}

pub fn a_linked_worktree_session_still_writes_the_owners_repository_test() {
  // The control for the test above. An ordinary session whose workspace is a
  // linked worktree keeps today's widening, so the probe that is refused for
  // a worker's clone succeeds here. Without this the refusals could be a
  // jail that refuses everything.
  let rig = worktree_rig.rig("jail-control")
  let layout = project_rig.started(rig)
  let _clone = project_rig.cloned(rig, layout, "t-a-1")
  let linked = rig.state <> "/ordinary-linked"
  worktree_rig.git(rig.root, ["worktree", "add", "--detach", linked])
  let session = worker_policy(rig.state, linked)
  case probe(rig, session, linked, ["true"]) {
    Error(why) -> skip(why)
    Ok(_) -> {
      let hook = rig.root <> "/.git/hooks/pre-commit"
      assert allowed(rig, session, linked, "printf x > " <> hook)
      assert bootstrap.path_exists(hook)
    }
  }
}

fn worker_policy(state: String, workspace: String) -> policy.SandboxPolicy {
  let basis =
    workspace_policy.Basis(
      base_policy: workspace_policy.base_policy(workspace),
      workspace:,
      tools: catalog.default_tools(),
      go_caches: None,
    )
  workspace_policy.session_base(basis, None, Error("no toolchain here"))
  |> workspace_policy.protecting_state_root(state)
  |> workspace_policy.protecting_projects(state)
}

fn refused(
  rig: worktree_rig.Rig,
  session: policy.SandboxPolicy,
  directory: String,
  script: String,
) -> Bool {
  case probe(rig, session, directory, [script]) {
    Ok(code) -> code != 0
    Error(_) -> False
  }
}

fn allowed(
  rig: worktree_rig.Rig,
  session: policy.SandboxPolicy,
  directory: String,
  script: String,
) -> Bool {
  case probe(rig, session, directory, [script]) {
    Ok(code) -> code == 0
    Error(_) -> False
  }
}

// Runs a shell script under a session policy with strict enforcement, and
// answers its exit code, or the reason a host without full enforcement gave.
fn probe(
  rig: worktree_rig.Rig,
  session: policy.SandboxPolicy,
  directory: String,
  scripts: List(String),
) -> Result(Int, String) {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a working directory"
  let scratch =
    rig.state <> "/probe-" <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(scratch <> "/tmp")
    as "the probe's scratch is made"
  let assert Ok(helper) =
    exec.spawn_helper(exec.SpawnConfig(
      helper_path: here <> "/../sandbox/loom-exec",
      shell_path: workspace_policy.shell_path,
      base_policy: session,
      helper_args: exec.unenforced_helper_args(exec.host_platform()),
      tmp_dir: scratch <> "/tmp",
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    ))
    as "the shipped helper starts"
  let events = process.new_subject()
  let outcome = case
    exec.run(
      helper,
      exec.ExecRequest(
        argv: [workspace_policy.shell_path, "-c", string.join(scripts, "\n")],
        env: [#("PATH", "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")],
        cwd: directory,
        policy: Some(session),
        token: <<0:size(32)-unit(8)>>,
        demand: exec.PlatformEnforcement,
      ),
      events:,
      waiting: 1000,
    )
  {
    Error(reason) -> Error(string.inspect(reason))
    Ok(Nil) -> terminal(events)
  }
  let assert Ok(Nil) = exec.close(helper, waiting: 5000) as "the helper retires"
  outcome
}

fn terminal(events: process.Subject(exec.ExecEvent)) -> Result(Int, String) {
  case process.receive(events, 20_000) {
    Error(Nil) -> Error("no terminal event")
    Ok(exec.Output(..)) -> terminal(events)
    Ok(exec.Exited(result)) -> Ok(result.code)
    Ok(exec.Failed(reason)) -> Error(string.inspect(reason))
  }
}

fn skip(why: String) -> Nil {
  io.println_error("SKIP project_repo jail: platform enforcement unavailable")
  io.println_error("  project_repo jail degraded: " <> why)
}

// --- intake ---------------------------------------------------------------------------

pub fn a_commit_is_taken_into_the_host_repository_and_its_paths_read_there_test() {
  let rig = worktree_rig.rig("intake")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let head =
    project_rig.commit(clone, [
      #("src/a.go", "package a\n"),
      #("Makefile", "check:\n"),
      #("odd name\nMakefile", "x\n"),
    ])

  // The owner's checkout moves on, which must not count its own new files.
  worktree_rig.write(rig.root <> "/elsewhere", "x\n")
  worktree_rig.git(rig.root, ["add", "elsewhere"])
  worktree_rig.git(rig.root, ["commit", "--quiet", "-m", "other work"])

  let assert Ok(project_repo.Accepted(commit:, changed:)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
  assert commit == head
  assert list.sort(changed, string.compare)
    == ["Makefile", "odd name\nMakefile", "src/a.go"]
  assert project_rig.ticket_ref_of(layout, "t-a", head) == head
}

pub fn no_program_a_clone_names_runs_when_the_host_takes_a_commit_in_test() {
  let rig = worktree_rig.rig("intake-programs")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let head = project_rig.commit(clone, [#("work", "w\n")])
  let marker = rig.state <> "/program-ran"
  let program = rig.state <> "/program.sh"
  worktree_rig.write(program, "#!/bin/sh\ntouch " <> marker <> "\n")
  let assert Ok(Nil) = simplifile.set_permissions_octal(program, 0o755)

  // The worker has committed, and only then does its clone name programs: the
  // operator's own Git in a hostile clone would run them. Every key of the clone's configuration that names a program, and the
  // hooks directory, point at the marker.
  list.each(
    [
      "core.fsmonitor", "core.alternateRefsCommand", "core.sshCommand",
      "core.hooksPath", "core.editor", "core.pager",
      "uploadpack.packObjectsHook", "credential.helper", "gpg.program",
      "diff.external", "core.askPass",
    ],
    fn(key) { worktree_rig.git(clone, ["config", key, program]) },
  )
  worktree_rig.write(
    clone <> "/.git/hooks/reference-transaction",
    "#!/bin/sh\ntouch " <> marker <> "\n",
  )
  worktree_rig.write(
    clone <> "/.git/hooks/pre-auto-gc",
    "#!/bin/sh\ntouch " <> marker <> "\n",
  )
  let assert Ok(project_repo.Accepted(commit:, changed: _)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
  assert commit == head
  assert !bootstrap.path_exists(marker)
}

pub fn objects_git_rejects_by_shape_are_refused_at_intake_test() {
  let rig = worktree_rig.rig("intake-fsck")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let parent = worktree_rig.git(clone, ["rev-parse", "HEAD"])
  let tree = worktree_rig.git(clone, ["rev-parse", "HEAD^{tree}"])

  // A commit whose timezone is not one, written past Git's own checks. It
  // reads fine; `transfer.fsckObjects` is what refuses it.
  let body =
    "tree "
    <> tree
    <> "\nparent "
    <> parent
    <> "\nauthor A <a@b.invalid> 1 +99999\ncommitter A <a@b.invalid> 1 +99999\n\nbad\n"
  worktree_rig.write(clone <> "/../bad-commit", body)
  let bad =
    worktree_rig.git(clone, [
      "hash-object",
      "-t",
      "commit",
      "-w",
      "--literally",
      clone <> "/../bad-commit",
    ])
  worktree_rig.git(clone, ["update-ref", "refs/heads/loom/t-a-1", bad])

  let assert Ok(project_repo.Declined(commit:, why:)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
  assert commit == bad
  assert why != ""
  assert project_rig.ticket_ref_of(layout, "t-a", bad) == ""
}

pub fn a_replace_ref_cannot_hide_a_protected_edit_from_the_host_test() {
  let rig = worktree_rig.rig("intake-replace")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let clean = worktree_rig.git(clone, ["rev-parse", "HEAD"])

  // The worker edits the Makefile, then makes the commit that holds the edit
  // read as the clean one before it.
  let edited =
    project_rig.commit(clone, [#("Makefile", "check:\n\trm -rf ~\n")])
  worktree_rig.git(clone, ["replace", edited, clean])

  let assert Ok(project_repo.Accepted(commit:, changed:)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")

  // The host sees the commit the branch names, and the edit in it.
  assert commit == edited
  assert list.contains(changed, "Makefile")
  assert protect.scope(changed, protect.default_paths)
    == model.ProtectedPathsTouched

  // The host repository takes in no replace ref from a clone, so what a clone
  // holds there changes nothing. A replace ref that did get into the host
  // repository, planted here by the operator, must not change what is read
  // either: the diff names the edit all the same.
  worktree_rig.git(project_repo.host_path(layout), ["replace", edited, clean])
  let assert Ok(project_repo.Accepted(commit: again, changed: again_changed)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
  assert again == edited
  assert list.contains(again_changed, "Makefile")

  // The tree the check would run in is that commit's, and the tree a push
  // would ship is the same one.
  let assert Ok(path) =
    project_repo.check_tree(rig.trees, layout, "t-a", edited)
  assert string.contains(read(path <> "/Makefile"), "rm -rf")
  assert worktree_rig.git(path, ["rev-parse", "HEAD"]) == edited
  assert worktree_rig.git(project_repo.host_path(layout), [
      "--no-replace-objects",
      "rev-parse",
      edited <> "^{tree}",
    ])
    == worktree_rig.git(path, ["rev-parse", "HEAD^{tree}"])
}

fn read(path: String) -> String {
  let assert Ok(text) = simplifile.read(path) as "the file is readable"
  text
}

// --- what is checked and what is pushed come from the host repository ----------------

pub fn a_check_tree_is_cut_from_the_host_repository_and_shares_nothing_with_it_test() {
  let rig = worktree_rig.rig("check-tree")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let head = project_rig.commit(clone, [#("src/a.go", "package a\n")])
  let assert Ok(project_repo.Accepted(..)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
  let assert Ok(path) = project_repo.check_tree(rig.trees, layout, "t-a", head)
  assert path == project_repo.check_tree_path(layout, "t-a", head)
  assert read(path <> "/src/a.go") == "package a\n"
  assert !bootstrap.path_exists(path <> "/.git/objects/info/alternates")

  // The owner's own commit is in the host repository too, as the base the
  // diff is read against. One it never took in is not a tree.
  let base = worktree_rig.git(clone, ["rev-parse", "HEAD~1"])
  let assert Ok(_) = project_repo.check_tree(rig.trees, layout, "t-a", base)
  let unknown = string.repeat("a", 40)
  let assert Error(_) =
    project_repo.check_tree(rig.trees, layout, "t-a", unknown)
  assert !bootstrap.path_exists(project_repo.check_tree_path(
    layout,
    "t-a",
    unknown,
  ))
  project_repo.discard_check_tree(path)
  assert !bootstrap.path_exists(path)
}

// A bare remote, a fake `gh` that opens one pull request, and the owner's
// checkout pointing at the remote.
type Remote {
  Remote(bare: String, bin: String, tools: project_publish.Tools)
}

const fake_gh =
  "#!/bin/sh
case \"$*\" in
  *\"--method POST\"*) printf '{\"html_url\":\"https://example.test/o/r/pull/7\"}' ;;
  *\"--method GET repos/\"*\"/pulls\"*) printf '[]' ;;
  *\"--method GET\"*) printf '{\"default_branch\":\"main\"}' ;;
esac
"

fn remote(rig: worktree_rig.Rig) -> Remote {
  let bare = rig.state <> "/origin/o/r.git"
  let assert Ok(Nil) = simplifile.create_directory_all(bare)
  worktree_rig.git(rig.state, ["init", "--quiet", "--bare", bare])
  worktree_rig.git(rig.root, ["remote", "add", "origin", bare])
  let bin = rig.state <> "/bin"
  let assert Ok(Nil) = simplifile.create_directory_all(bin)
  let assert Ok(Nil) = simplifile.write(bin <> "/gh", fake_gh)
  let assert Ok(Nil) = simplifile.set_permissions_octal(bin <> "/gh", 0o755)
  Remote(
    bare:,
    bin:,
    tools: project_publish.Tools(
      git: "git",
      env: "/usr/bin/env",
      gh: Some(bin <> "/gh"),
    ),
  )
}

// Publishing needs a GitHub URL, and the bare remote is a path. The host
// repository rewrites a GitHub address to the bare remote, so the push is real
// and reaches nothing else, and the address is what the publish is given.
fn github_alias(layout: project_repo.Layout, remote: Remote) -> String {
  let address = "https://github.com/o/r.git"
  worktree_rig.git(project_repo.host_path(layout), [
    "config",
    "url." <> remote.bare <> ".insteadOf",
    address,
  ])
  address
}

pub fn the_owners_push_url_is_pinned_when_the_host_repository_is_made_test() {
  let rig = worktree_rig.rig("pin")
  let remote = remote(rig)
  let layout = project_rig.started(rig)
  assert project_repo.pinned_url(layout) == Ok(remote.bare)

  // The pin is the owner's word at creation: a later change to the owner's
  // remote, or a second ensure, does not move it.
  worktree_rig.git(rig.root, [
    "remote",
    "set-url",
    "origin",
    "https://x.test/o/r",
  ])
  let assert Ok(Nil) = project_repo.ensure_host(rig.trees, layout)
  assert project_repo.pinned_url(layout) == Ok(remote.bare)
}

pub fn a_checkout_with_no_origin_pins_nothing_test() {
  let rig = worktree_rig.rig("pin-none")
  let layout = project_rig.started(rig)
  assert project_repo.pinned_url(layout) == Error(Nil)
}

pub fn only_urls_git_would_push_to_as_a_remote_are_pinned_test() {
  assert project_repo.acceptable_url("git@github.com:o/r.git")
  assert project_repo.acceptable_url("https://github.com/o/r")
  assert project_repo.acceptable_url("/srv/git/r.git")
  assert !project_repo.acceptable_url("")
  assert !project_repo.acceptable_url("--upload-pack=touch /tmp/x")
  assert !project_repo.acceptable_url("ext::sh -c touch% /tmp/x")
  assert !project_repo.acceptable_url("fd::17")
  assert !project_repo.acceptable_url("https://x.test/o/r\nhttps://evil.test")
}

pub fn what_a_worker_writes_in_its_clone_does_not_redirect_the_push_test() {
  let rig = worktree_rig.rig("push")
  let remote = remote(rig)
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")

  // The worker points every Git setting that names a destination at a decoy,
  // and one that would run a program for an ssh transport at a marker.
  let decoy = rig.state <> "/decoy.git"
  worktree_rig.git(rig.state, ["init", "--quiet", "--bare", decoy])
  let marker = rig.state <> "/ssh-ran"
  worktree_rig.git(clone, ["remote", "add", "origin", decoy])
  worktree_rig.git(clone, ["config", "remote.origin.pushurl", decoy])
  worktree_rig.git(clone, [
    "config",
    "url." <> decoy <> ".insteadOf",
    remote.bare,
  ])
  worktree_rig.git(clone, [
    "config",
    "core.sshCommand",
    "touch " <> marker <> " #",
  ])
  worktree_rig.git(clone, [
    "config",
    "credential.helper",
    "touch " <> marker <> " #",
  ])
  worktree_rig.git(clone, ["config", "http.proxy", "http://127.0.0.1:9"])
  let head = project_rig.commit(clone, [#("feature", "work\n")])

  // The host takes the commit in and publishes it from its own repository.
  let assert Ok(project_repo.Accepted(commit: taken, changed: _)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
  assert taken == head
  let url = github_alias(layout, remote)
  let assert Ok(opened) =
    project_publish.publish(
      remote.tools,
      project_publish.Repository(
        directory: project_repo.host_path(layout),
        url:,
      ),
      "project/t-a",
      head,
      "[loom t-a] \"work\"",
      "body",
    )
  assert opened == "https://example.test/o/r/pull/7"

  // The pinned remote has the commit, and the decoy has nothing.
  assert worktree_rig.git(remote.bare, ["rev-parse", "refs/heads/project/t-a"])
    == head
  assert !bootstrap.path_exists(decoy <> "/refs/heads/project")
  assert !bootstrap.path_exists(marker)
}

pub fn the_owners_repository_is_unchanged_across_a_whole_scenario_test() {
  let rig = worktree_rig.rig("owner-unchanged")
  let remote = remote(rig)
  let owners = project_rig.digest(rig.root)
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  worktree_rig.git(clone, ["config", "core.hooksPath", "/tmp/x"])
  worktree_rig.write(clone <> "/.git/hooks/post-commit", "#!/bin/sh\nexit 1\n")
  let head = project_rig.commit(clone, [#("feature", "work\n")])
  let assert Ok(project_repo.Accepted(..)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
  let assert Ok(path) = project_repo.check_tree(rig.trees, layout, "t-a", head)
  project_repo.discard_check_tree(path)
  let url = github_alias(layout, remote)
  let assert Ok(_) =
    project_publish.publish(
      remote.tools,
      project_publish.Repository(
        directory: project_repo.host_path(layout),
        url:,
      ),
      "project/t-a",
      head,
      "t",
      "b",
    )
  let _released = project_repo.release(rig.trees, layout, "t-a-1")
  assert project_rig.digest(rig.root) == owners
}

// --- releasing a clone ----------------------------------------------------------------

pub fn a_clone_with_nothing_the_host_lacks_is_removed_test() {
  let rig = worktree_rig.rig("release-clean")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  assert project_repo.release(rig.trees, layout, "t-a-1") == worktrees.Removed
  assert !bootstrap.path_exists(clone)
}

pub fn a_clone_with_a_commit_the_host_has_taken_in_is_removed_test() {
  let rig = worktree_rig.rig("release-taken")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let _head = project_rig.commit(clone, [#("work", "w\n")])
  let assert Ok(project_repo.Accepted(..)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
  assert project_repo.release(rig.trees, layout, "t-a-1") == worktrees.Removed
  assert !bootstrap.path_exists(clone)
}

pub fn a_clone_with_a_commit_the_host_has_not_seen_is_kept_test() {
  let rig = worktree_rig.rig("release-unseen")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let _head = project_rig.commit(clone, [#("work", "w\n")])
  let assert worktrees.Kept(reason) =
    project_repo.release(rig.trees, layout, "t-a-1")
  assert string.contains(reason, "has not taken in")
  assert bootstrap.path_exists(clone)
}

pub fn a_worker_that_moves_head_to_a_clean_branch_does_not_hide_its_commits_test() {
  let rig = worktree_rig.rig("release-head")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let base = worktree_rig.git(clone, ["rev-parse", "HEAD"])
  let _head = project_rig.commit(clone, [#("work", "w\n")])

  // HEAD names a branch at the base, so the clone looks clean from where
  // HEAD stands, and the commit is on the branch it left.
  worktree_rig.git(clone, ["checkout", "--quiet", "-b", "tidy", base])
  assert worktree_rig.git(clone, ["status", "--porcelain"]) == ""
  let assert worktrees.Kept(_) =
    project_repo.release(rig.trees, layout, "t-a-1")
  assert bootstrap.path_exists(clone)
}

pub fn a_clone_with_changes_in_its_working_tree_is_kept_test() {
  let rig = worktree_rig.rig("release-dirty")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  worktree_rig.write(clone <> "/notes", "unsaved\n")
  let assert worktrees.Kept(reason) =
    project_repo.release(rig.trees, layout, "t-a-1")
  assert reason == "it holds changes"
}

pub fn a_clone_that_is_gone_has_nothing_to_settle_test() {
  let rig = worktree_rig.rig("release-gone")
  let layout = project_rig.started(rig)
  assert project_repo.release(rig.trees, layout, "t-none-1")
    == worktrees.Removed
}

// --- the session policy -----------------------------------------------------------------

pub fn the_policy_masks_each_projects_host_repository_ledger_and_checks_test() {
  let rig = worktree_rig.rig("masks")
  let layout = project_rig.started(rig)
  let directory = project_repo.project_directory(layout)
  worktree_rig.write(directory <> "/ledger.db", "")
  let checks = project_repo.checks_path(layout)
  let assert Ok(Nil) = simplifile.create_directory_all(checks)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let masked =
    workspace_policy.protecting_projects(
      workspace_policy.base_policy(clone),
      rig.state,
    )
  assert list.contains(masked.protected, project_repo.host_path(layout))
  assert list.contains(masked.protected, directory <> "/ledger.db")
  assert list.contains(masked.protected, checks)

  // A clone is a worker's workspace and is not masked, and nothing that is not
  // on disk is, since the jail refuses a mask over a path that is not there.
  assert !list.contains(masked.protected, clone)
  assert !list.contains(masked.protected, directory <> "/ledger.db-wal")
}

// A worker's clone is made for one assignment, so a list of folders to start a
// session in leaves it out and keeps the owner's own folders.
pub fn a_workers_clone_is_not_a_folder_to_start_again_in_test() {
  assert project_repo.is_clone_path("/s/projects/p-1/tickets/t-a-1")
  assert project_repo.is_clone_path(project_repo.clone_path(
    project_repo.Layout("/s", "p-1", "/repo"),
    "t-b-2",
  ))
  assert !project_repo.is_clone_path("/Users/me/src/loom")
  assert !project_repo.is_clone_path("/Users/me/projects/tickets")
}

// A clone whose branch is still at the base made no work. A check at that head
// would pass, and the pass would say nothing about the worker, so the host
// withholds it from the check and a person is told why.
pub fn a_branch_with_no_commit_of_its_own_is_withheld_from_the_check_test() {
  let rig = worktree_rig.rig("intake-empty")
  let layout = project_rig.started(rig)
  let _clone = project_rig.cloned(rig, layout, "t-a-1")

  let assert Ok(project_repo.Withheld(commit: _, reason: project_repo.NoCommits)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
}

// The host reads the clone's HEAD and nothing beside it. Files that no commit
// holds are not in what a check would run, so a commit with such files beside
// it is withheld as well, whether the files are new or changed.
pub fn changes_no_commit_holds_are_withheld_from_the_check_test() {
  let rig = worktree_rig.rig("intake-dirty")
  let layout = project_rig.started(rig)
  let clone = project_rig.cloned(rig, layout, "t-a-1")
  let _head = project_rig.commit(clone, [#("src/a.go", "package a\n")])
  worktree_rig.write(clone <> "/notes.txt", "not committed\n")

  let assert Ok(project_repo.Withheld(
    commit: _,
    reason: project_repo.UncommittedChanges,
  )) = project_repo.intake(rig.trees, layout, "t-a", "t-a-1")

  // Once the worker commits them, the head is checked like any other.
  let _again = project_rig.commit(clone, [#("notes.txt", "committed\n")])
  let assert Ok(project_repo.Accepted(..)) =
    project_repo.intake(rig.trees, layout, "t-a", "t-a-1")
}
