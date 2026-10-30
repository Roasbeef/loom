//// Admission checks use the host's real filesystem without a shell.

import broker/exec
import broker/policy
import client/git_identity
import client/internal/ffi_os
import client/repository_snapshot
import client/worktree_git
import client/worktrees
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/internal/ffi_proc
import support/worktree_rig

pub fn disk_space_preflight_accepts_and_refuses_real_directory_test() {
  let assert Ok(directory) = bootstrap.canonical_directory(".")
  assert repository_snapshot.check_space(directory, 1) == Ok(Nil)
  assert repository_snapshot.check_space(directory, 0)
    == Error("invalid snapshot staging space request")
  assert repository_snapshot.check_space(directory, 9_223_372_036_854_775_807)
    == Error("insufficient space for repository snapshot")
}

pub fn private_scope_keeps_authority_and_other_masks_test() {
  let base =
    "build/snapshot-scope-" <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = bootstrap.ensure_private_directory(base)
  let assert Ok(base) = bootstrap.canonical_directory(base)
  let workspace = base <> "/workspace"
  let store = base <> "/store"
  let stage = store <> "/stage"
  let secret = base <> "/secret"
  list.each([workspace, store, stage, secret], fn(path) {
    let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
  })
  let parent =
    policy.SandboxPolicy(..policy.workspace_default(workspace), protected: [
      store,
      secret,
    ])
  let assert Ok(private) =
    repository_snapshot.private_scope(
      parent,
      workspace,
      workspace,
      workspace,
      store,
      stage,
    )
  assert private.readable_roots == [workspace, workspace, workspace]
  assert private.writable_roots == []
  assert private.protected == [secret]
  assert private.mounts == []
  assert private.network == policy.NetworkOff
  let assert Error(_) =
    repository_snapshot.private_scope(
      parent,
      workspace,
      secret,
      workspace,
      store,
      stage,
    )
  let assert Error(_) =
    repository_snapshot.private_scope(
      parent,
      workspace,
      workspace,
      workspace,
      store,
      store,
    )
}

pub fn discovery_uses_the_real_broker_and_original_context_test() {
  let rig = worktree_rig.rig("snapshot-discovery")
  let scratch = rig.state <> "/discovery"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(scratch)
  let assert Ok(here) = simplifile.current_directory()
  let assert Ok(git) =
    worktree_git.start(worktree_git.Config(
      helper_path: here <> "/../sandbox/loom-exec",
      scratch: rig.state <> "/git-runner",
      state_root: rig.state,
      demand: exec.BestEffort,
    ))
  let call =
    worktree_git.Capture(
      directory: rig.root,
      arguments: [],
      scope: policy.SandboxPolicy(
        ..policy.workspace_default(rig.root),
        protected: [
          rig.state <> "/repository-snapshots",
        ],
      ),
      staging: scratch,
      context: worktree_git.SourceContext,
      stdin: <<>>,
      limits: policy.Limits(
        cpu_s: 30,
        wall_s: 30,
        mem_bytes: 536_870_912,
        pids: 64,
        fsize_bytes: 1_073_741_824,
        output_bytes: 65_536,
      ),
    )
  let assert Ok(source) = repository_snapshot.discover(git, call, 30_000)
  assert source.workspace == rig.root
  assert source.git_dir == rig.root <> "/.git"
  assert source.common_dir == rig.root <> "/.git"
  assert source.head == worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  worktree_rig.write(rig.root <> "/.gitignore", "ignored\nignored-extra\n")
  worktree_rig.write(rig.root <> "/ignored", "staged ignored\n")
  worktree_rig.write(rig.root <> "/ignored-extra", "ignored canary\n")
  let _ = worktree_rig.git(rig.root, ["add", "-f", "ignored"])
  let _ = worktree_rig.git(rig.root, ["rm", "--cached", "README"])
  worktree_rig.write(rig.root <> "/ordinary", "untracked\n")
  worktree_rig.write(rig.root <> "/.git/info/grafts", source.head <> "\n")
  assert repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "grafts",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
    == Error("Git grafts are unsupported")
  let assert Ok(Nil) = simplifile.delete(rig.root <> "/.git/info/grafts")
  worktree_rig.write(rig.root <> "/:(glob)*", "literal path\n")
  worktree_rig.write(rig.root <> "/executable", "#!/bin/sh\nexit 0\n")
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(rig.root <> "/executable", 0o755)
  let assert Ok(Nil) =
    bootstrap.ensure_private_directory(rig.root <> "/.codemode")
  let assert Ok(Nil) =
    bootstrap.ensure_private_directory(rig.root <> "/.codemode/home")
  worktree_rig.write(rig.root <> "/.codemode/home/token", "runtime canary")
  worktree_rig.write(rig.root <> "/staged", "staged bytes\n")
  let _ = worktree_rig.git(rig.root, ["add", "staged"])
  worktree_rig.write(rig.root <> "/staged", "working bytes\n")
  let assert Ok(Nil) =
    simplifile.create_symlink("/outside/canary", rig.root <> "/link")
  let assert Ok(inventory) = repository_snapshot.inventory(git, call, 30_000)
  assert list.contains(inventory.tracked, "README")
  assert list.contains(inventory.tracked, "ignored")
  assert list.contains(inventory.untracked, "ordinary")
  let assert Ok(working) =
    repository_snapshot.working_entries(rig.root, call.scope, inventory)
  assert list.contains(working.present, "README")
  assert list.contains(working.present, "link")
  assert working.bytes > 0
  let protected =
    policy.SandboxPolicy(..call.scope, protected: [rig.root <> "/ordinary"])
  let assert Error(_) =
    repository_snapshot.working_entries(rig.root, protected, inventory)
  assert repository_snapshot.check_attributes(git, call, ["ordinary"], 30_000)
    == Ok(Nil)
  let refs_before =
    worktree_rig.git(rig.root, [
      "for-each-ref",
      "--format=%(refname) %(objectname)",
    ])
  worktree_rig.write(
    rig.root <> "/fsmonitor-hook",
    "#!/bin/sh\nprintf ran > '" <> scratch <> "/hook-ran'\n",
  )
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(rig.root <> "/fsmonitor-hook", 0o755)
  let _ =
    worktree_rig.git(rig.root, [
      "config",
      "core.fsmonitor",
      rig.root <> "/fsmonitor-hook",
    ])
  let _ = worktree_rig.git(rig.root, ["status", "--porcelain"])
  assert simplifile.is_file(scratch <> "/hook-ran") == Ok(True)
  let assert Ok(Nil) = simplifile.delete(scratch <> "/hook-ran")
  let assert Ok(index_before) = simplifile.read_bits(rig.root <> "/.git/index")
  let assert Ok(snapshot) =
    repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "first",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
  assert simplifile.is_file(scratch <> "/hook-ran") == Ok(False)
  let _ = worktree_rig.git(rig.root, ["config", "--unset", "core.fsmonitor"])
  assert simplifile.read(snapshot.child <> "/README") == Ok("one\n")
  assert simplifile.read(snapshot.child <> "/ignored") == Ok("staged ignored\n")
  assert simplifile.read(snapshot.child <> "/ordinary") == Ok("untracked\n")
  assert simplifile.read(snapshot.child <> "/:(glob)*") == Ok("literal path\n")
  assert simplifile.read(snapshot.child <> "/staged") == Ok("working bytes\n")
  let sibling = rig.state <> "/repository-snapshots/sibling"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(sibling)
  worktree_rig.write(sibling <> "/canary", "private sibling canary")
  let assert Ok(narrowed) =
    repository_snapshot.private_scope(
      call.scope,
      rig.root,
      source.git_dir,
      source.common_dir,
      rig.state <> "/repository-snapshots",
      snapshot.stage,
    )
  let assert Ok(denied) =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(
        ..call,
        scope: narrowed,
        staging: snapshot.stage,
        arguments: ["hash-object", sibling <> "/canary"],
      ),
      30_000,
    )
  assert denied.code != 0
  assert simplifile.is_file(snapshot.child <> "/ignored-extra") == Ok(False)
  assert simplifile.is_directory(snapshot.child <> "/.codemode") == Ok(False)
  assert string.starts_with(
    worktree_rig.git(snapshot.child, ["ls-tree", "HEAD", "executable"]),
    "100755 blob ",
  )
  assert worktree_rig.git(snapshot.child, ["show", "HEAD:link"])
    == "/outside/canary"
  assert string.starts_with(
    worktree_rig.git(snapshot.child, ["ls-tree", "HEAD", "link"]),
    "120000 blob ",
  )
  assert simplifile.read_bits(rig.root <> "/.git/index") == Ok(index_before)
  assert worktree_rig.git(rig.root, ["rev-parse", "HEAD"]) == source.head
  assert worktree_rig.git(rig.root, [
      "for-each-ref",
      "--format=%(refname) %(objectname)",
    ])
    == refs_before
  assert worktree_rig.git(snapshot.child, [
      "show",
      "-s",
      "--format=%an <%ae>",
      "HEAD",
    ])
    == "Owner <owner@example.invalid>"
  let linked = rig.root <> "-linked"
  let _ =
    worktree_rig.git(rig.root, ["worktree", "add", "--detach", linked, "HEAD"])
  let linked_scope =
    policy.SandboxPolicy(
      ..call.scope,
      readable_roots: [linked],
      writable_roots: [linked, rig.root <> "/.git"],
    )
  let assert Ok(linked_snapshot) =
    repository_snapshot.capture(
      git,
      worktree_git.Capture(..call, directory: linked, scope: linked_scope),
      rig.state <> "/repository-snapshots",
      "linked",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
  assert simplifile.read(linked_snapshot.child <> "/README") == Ok("one\n")
  let _ =
    worktree_rig.git(rig.root, ["config", "extensions.worktreeConfig", "true"])
  let _ =
    worktree_rig.git(linked, [
      "config",
      "--worktree",
      "remote.example.promisor",
      "true",
    ])
  assert repository_snapshot.capture(
      git,
      worktree_git.Capture(..call, directory: linked, scope: linked_scope),
      rig.state <> "/repository-snapshots",
      "linked-promisor",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
    == Error("partial or sparse Git repositories are unsupported")
  let _ =
    worktree_rig.git(linked, [
      "config",
      "--worktree",
      "--unset",
      "remote.example.promisor",
    ])
  worktree_rig.write(
    rig.root <> "/ordinary",
    "version https://git-lfs.github.com/spec/v1\noid sha256:fixture\n",
  )
  assert repository_snapshot.working_entries(rig.root, call.scope, inventory)
    == Error("repository contains a Git LFS pointer")
  worktree_rig.write(rig.root <> "/ordinary", "untracked\n")
  worktree_rig.write(rig.root <> "/ordinary", "one\r\ntwo\r\n")
  worktree_rig.write(rig.root <> "/.gitattributes", "ordinary crlf=input\n")
  assert repository_snapshot.check_attributes(git, call, ["ordinary"], 30_000)
    == Error("repository path has a content transformation")
  assert repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "legacy-crlf",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
    == Error("repository path has a content transformation")
  assert simplifile.is_directory(
      rig.state <> "/repository-snapshots/legacy-crlf",
    )
    == Ok(False)
  let assert Ok(Nil) = simplifile.delete(rig.root <> "/.gitattributes")
  worktree_rig.write(rig.root <> "/ordinary", "untracked\n")
  worktree_rig.write(rig.root <> "/.gitattributes", "ordinary text\n")
  assert repository_snapshot.check_attributes(git, call, ["ordinary"], 30_000)
    == Error("repository path has a content transformation")
  let assert Ok(Nil) = simplifile.delete(rig.root <> "/.gitattributes")
  worktree_rig.write(rig.root <> "/.git/shallow", source.head <> "\n")
  assert repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "shallow",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
    == Error("shallow Git repositories are unsupported")
  let assert Ok(Nil) = simplifile.delete(rig.root <> "/.git/shallow")
  worktree_rig.write(rig.root <> "/.gitattributes", "ordinary filter=lfs\n")
  assert repository_snapshot.check_attributes(git, call, ["ordinary"], 30_000)
    == Error("repository path has a content transformation")
  let assert Ok(Nil) = simplifile.delete(rig.root <> "/.gitattributes")
  let _ =
    worktree_rig.git(rig.root, ["config", "remote.example.promisor", "true"])
  assert repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "partial",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
    == Error("partial or sparse Git repositories are unsupported")
  let _ =
    worktree_rig.git(rig.root, ["config", "--unset", "remote.example.promisor"])
  let _ =
    worktree_rig.git(rig.root, ["update-index", "--skip-worktree", "staged"])
  assert repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "sparse",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
    == Error("sparse Git repositories are unsupported")
  let _ =
    worktree_rig.git(rig.root, ["update-index", "--no-skip-worktree", "staged"])
  let assert Error(_) =
    repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "no-identity",
      git_identity.Identity(None, None),
      120_000,
    )
  assert simplifile.is_directory(
      rig.state <> "/repository-snapshots/no-identity/child",
    )
    == Ok(False)
  let _ = worktree_rig.git(rig.root, ["add", "-f", ".codemode/home/token"])
  assert repository_snapshot.inventory(git, call, 30_000)
    == Error("tracked repository path overlaps Loom runtime data")
  let _ = worktree_rig.git(rig.root, ["rm", "--cached", "-r", ".codemode"])
  let _ =
    worktree_rig.git(rig.root, [
      "update-index",
      "--add",
      "--cacheinfo",
      "160000," <> source.head <> ",submodule",
    ])
  let assert Error(_) = repository_snapshot.inventory(git, call, 30_000)
  let _ = worktree_rig.git(rig.root, ["reset", "--hard", "HEAD"])
  let _ = worktree_rig.git(rig.root, ["checkout", "-b", "conflicting"])
  worktree_rig.write(rig.root <> "/README", "branch side\n")
  let _ = worktree_rig.git(rig.root, ["add", "README"])
  let _ = worktree_rig.git(rig.root, ["commit", "-m", "branch side"])
  let _ = worktree_rig.git(rig.root, ["checkout", "main"])
  worktree_rig.write(rig.root <> "/README", "main side\n")
  let _ = worktree_rig.git(rig.root, ["add", "README"])
  let _ = worktree_rig.git(rig.root, ["commit", "-m", "main side"])
  let #(merge_code, _) =
    worktree_rig.git_status(rig.root, ["merge", "conflicting"])
  assert merge_code != 0
  assert repository_snapshot.inventory(git, call, 30_000)
    == Error("unsupported unmerged or non-blob Git entry")
  let _ = worktree_rig.git(rig.root, ["reset", "--hard", "HEAD"])
  let blob = worktree_rig.git(rig.root, ["rev-parse", "HEAD:README"])
  let object =
    rig.root
    <> "/.git/objects/"
    <> string.slice(blob, 0, 2)
    <> "/"
    <> string.drop_start(blob, 2)
  let assert Ok(Nil) = simplifile.delete(object)
  let assert Error(_) =
    repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "missing-object",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
  assert simplifile.is_directory(
      rig.state <> "/repository-snapshots/missing-object",
    )
    == Ok(False)
  let _ =
    worktree_rig.git(rig.root, ["symbolic-ref", "HEAD", "refs/heads/unborn"])
  let assert Error(_) =
    repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "unborn",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
  assert simplifile.is_directory(rig.state <> "/repository-snapshots/unborn")
    == Ok(False)
  let denied = policy.SandboxPolicy(..call.scope, readable_roots: [scratch])
  let assert Error(_) =
    repository_snapshot.discover(
      git,
      worktree_git.Capture(..call, scope: denied),
      30_000,
    )
  let assert Ok(Nil) = worktree_git.stop(git)
  worktrees.stop(rig.trees)
}

pub fn clean_and_dirty_submodules_refuse_without_changing_parent_test() {
  let rig = worktree_rig.rig("snapshot-submodules")
  let subrepo = worktree_rig.repository(rig.root <> "-subrepo")
  let _ =
    worktree_rig.git(rig.root, [
      "-c", "protocol.file.allow=always", "submodule", "add", subrepo, "sub",
    ])
  let _ = worktree_rig.git(rig.root, ["commit", "-m", "add submodule"])
  let scratch = rig.state <> "/discovery"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(scratch)
  let assert Ok(here) = simplifile.current_directory()
  let assert Ok(git) =
    worktree_git.start(worktree_git.Config(
      helper_path: here <> "/../sandbox/loom-exec",
      scratch: rig.state <> "/git-runner",
      state_root: rig.state,
      demand: exec.BestEffort,
    ))
  let call =
    worktree_git.Capture(
      directory: rig.root,
      arguments: [],
      scope: policy.SandboxPolicy(
        ..policy.workspace_default(rig.root),
        protected: [
          rig.state <> "/repository-snapshots",
        ],
      ),
      staging: scratch,
      context: worktree_git.SourceContext,
      stdin: <<>>,
      limits: policy.Limits(
        cpu_s: 30,
        wall_s: 30,
        mem_bytes: 536_870_912,
        pids: 64,
        fsize_bytes: 1_073_741_824,
        output_bytes: 65_536,
      ),
    )
  let head = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let assert Ok(index) = simplifile.read_bits(rig.root <> "/.git/index")
  let identity =
    git_identity.Identity(Some("Owner"), Some("owner@example.invalid"))
  let assert Error(_) =
    repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "clean-submodule",
      identity,
      120_000,
    )
  assert simplifile.is_directory(
      rig.state <> "/repository-snapshots/clean-submodule",
    )
    == Ok(False)
  worktree_rig.write(rig.root <> "/sub/README", "dirty submodule bytes\n")
  let assert Error(_) =
    repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "dirty-submodule",
      identity,
      120_000,
    )
  assert simplifile.is_directory(
      rig.state <> "/repository-snapshots/dirty-submodule",
    )
    == Ok(False)
  assert simplifile.read(rig.root <> "/sub/README")
    == Ok("dirty submodule bytes\n")
  assert simplifile.read_bits(rig.root <> "/.git/index") == Ok(index)
  assert worktree_rig.git(rig.root, ["rev-parse", "HEAD"]) == head
  let assert Ok(Nil) = worktree_git.stop(git)
  worktrees.stop(rig.trees)
}

pub fn missing_head_promisor_include_never_runs_transport_test() {
  let rig = worktree_rig.rig("snapshot-promisor")
  let scratch = rig.state <> "/discovery"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(scratch)
  let assert Ok(here) = simplifile.current_directory()
  let assert Ok(git) =
    worktree_git.start(worktree_git.Config(
      helper_path: here <> "/../sandbox/loom-exec",
      scratch: rig.state <> "/git-runner",
      state_root: rig.state,
      demand: exec.BestEffort,
    ))
  let call =
    worktree_git.Capture(
      directory: rig.root,
      arguments: [],
      scope: policy.SandboxPolicy(
        ..policy.workspace_default(rig.root),
        protected: [rig.state <> "/repository-snapshots"],
      ),
      staging: scratch,
      context: worktree_git.SourceContext,
      stdin: <<>>,
      limits: policy.Limits(
        cpu_s: 30,
        wall_s: 30,
        mem_bytes: 536_870_912,
        pids: 64,
        fsize_bytes: 1_073_741_824,
        output_bytes: 65_536,
      ),
    )
  let head_commit = worktree_rig.git(rig.root, ["rev-parse", "HEAD"])
  let transport = rig.root <> "/promisor-transport"
  worktree_rig.write(
    transport,
    "#!/bin/sh\nprintf ran > '" <> scratch <> "/transport-ran'\nexit 1\n",
  )
  let assert Ok(Nil) = simplifile.set_permissions_octal(transport, 0o755)
  worktree_rig.write(
    rig.root <> "/promisor.inc",
    "[remote \"origin\"]\n  promisor = true\n  partialclonefilter = blob:none\n  url = ext::"
      <> transport
      <> "\n[protocol \"ext\"]\n  allow = always\n",
  )
  let _ =
    worktree_rig.git(rig.root, [
      "config",
      "--local",
      "--add",
      "include.path",
      "../promisor.inc",
    ])
  let head_path =
    rig.root
    <> "/.git/objects/"
    <> string.slice(head_commit, 0, 2)
    <> "/"
    <> string.drop_start(head_commit, 2)
  let assert Ok(Nil) = simplifile.delete(head_path)
  let #(native_code, _) =
    worktree_rig.git_status(rig.root, ["rev-parse", "--verify", "HEAD^{commit}"])
  assert native_code != 0
  assert simplifile.is_file(scratch <> "/transport-ran") == Ok(True)
  let assert Ok(Nil) = simplifile.delete(scratch <> "/transport-ran")
  assert repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "missing-head-promisor",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
    == Error("partial or sparse Git repositories are unsupported")
  assert simplifile.is_file(scratch <> "/transport-ran") == Ok(False)
  assert simplifile.is_directory(
      rig.state <> "/repository-snapshots/missing-head-promisor",
    )
    == Ok(False)
  let _ =
    worktree_rig.git(rig.root, ["config", "--local", "--unset", "include.path"])
  let assert Ok(Nil) = worktree_git.stop(git)
  worktrees.stop(rig.trees)
}

pub fn source_tool_home_excludes_are_honored_and_unreadable_files_refused_test() {
  let rig = worktree_rig.rig("snapshot-tool-home-exclude")
  let scratch = rig.state <> "/discovery"
  let home = rig.root <> "/.codemode/home"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(scratch)
  let assert Ok(Nil) =
    bootstrap.ensure_private_directory(rig.root <> "/.codemode")
  let assert Ok(Nil) = bootstrap.ensure_private_directory(home)
  worktree_rig.write(home <> "/ignore", "private-canary\n")
  worktree_rig.write(
    home <> "/gitconfig",
    "[user]\n name = Owner\n email = owner@example.invalid\n",
  )
  worktree_rig.write(rig.root <> "/private-canary", "private content\n")
  let _ =
    worktree_rig.git(rig.root, ["config", "core.excludesFile", "~/ignore"])

  // Reproduce the parent tool environment with fixed argv and no host globals.
  let assert Ok(program) = ffi_proc.which("git")
  let assert Ok(#(code, parent)) =
    ffi_proc.run(
      "/usr/bin/env",
      [
        "HOME=" <> home,
        "GIT_CONFIG_GLOBAL=" <> home <> "/gitconfig",
        "GIT_CONFIG_NOSYSTEM=1",
        program,
        "ls-files",
        "--others",
        "--exclude-standard",
      ],
      in: rig.root,
    )
  assert code == 0
  assert !string.contains(parent, "private-canary")

  // The broker must use the same source home as the parent tool.
  let assert Ok(here) = simplifile.current_directory()
  let assert Ok(git) =
    worktree_git.start(worktree_git.Config(
      helper_path: here <> "/../sandbox/loom-exec",
      scratch: rig.state <> "/git-runner",
      state_root: rig.state,
      demand: exec.BestEffort,
    ))
  let call =
    worktree_git.Capture(
      directory: rig.root,
      arguments: [],
      scope: policy.SandboxPolicy(
        ..policy.workspace_default(rig.root),
        protected: [rig.state <> "/repository-snapshots"],
      ),
      staging: scratch,
      context: worktree_git.SourceContext,
      stdin: <<>>,
      limits: policy.Limits(
        cpu_s: 30,
        wall_s: 30,
        mem_bytes: 536_870_912,
        pids: 64,
        fsize_bytes: 1_073_741_824,
        output_bytes: 65_536,
      ),
    )
  let assert Ok(inventory) = repository_snapshot.inventory(git, call, 30_000)
  assert !list.contains(inventory.untracked, "private-canary")
  let assert Ok(snapshot) =
    repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "excluded-canary",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
  assert simplifile.is_file(snapshot.child <> "/private-canary") == Ok(False)

  // Git reports an unreadable absolute excludes file only on stderr.
  let _ =
    worktree_rig.git(rig.root, [
      "config",
      "core.excludesFile",
      home <> "/ignore",
    ])
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(home <> "/ignore", 0o000)
  let assert Ok(unreadable) =
    worktree_git.run_capture(
      git,
      worktree_git.Capture(..call, arguments: [
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
      ]),
      30_000,
    )
  assert unreadable.code == 0
  let assert Ok(stderr) = bit_array.to_string(unreadable.stderr)
  assert string.contains(stderr, "Permission denied")
  let assert Ok(stdout) = bit_array.to_string(unreadable.stdout)
  assert string.contains(stdout, "private-canary")
  assert repository_snapshot.inventory(git, call, 30_000)
    == Error("repository ignore rules could not be evaluated reliably")
  assert repository_snapshot.capture(
      git,
      call,
      rig.state <> "/repository-snapshots",
      "unreadable-exclude",
      git_identity.Identity(Some("Owner"), Some("owner@example.invalid")),
      120_000,
    )
    == Error("repository ignore rules could not be evaluated reliably")
  assert simplifile.is_directory(
      rig.state <> "/repository-snapshots/unreadable-exclude",
    )
    == Ok(False)
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(home <> "/ignore", 0o600)
  let assert Ok(info) = simplifile.file_info(home <> "/ignore")
  assert simplifile.file_info_permissions_octal(info) == 0o600
  let assert Ok(Nil) = worktree_git.stop(git)
  worktrees.stop(rig.trees)
}
