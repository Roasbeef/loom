//// Worktree observations through the real session broker and jailed Git.
////
//// The fixtures own their repositories beneath the build directory. Git setup
//// uses the same broker as capture, under the writable fixture policy; capture
//// must demote that policy before invoking Git. Exact pathname and net-change
//// assertions distinguish filesystem observations from captured tool history.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import client/catalog
import client/codemode
import client/daemon/transfer
import client/serve
import client/worktree_diff
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import host/bootstrap
import simplifile
import support/enforcement
import tools/tool

pub fn porcelain_keeps_whitespace_and_newline_identity_test() {
  let assert Ok(files) =
    worktree_diff.decode_status(
      bit_array.from_string(" M sub/a b\u{0}?? sub/-line\nname\u{0}"),
      "sub/",
    )
    as "NUL records retain exact paths"
  let assert [first, second] = files as "there are two identities"
  assert first.path == "a b"
  assert first.index_status == " "
  assert first.worktree_status == "M"
  assert second.path == "-line\nname"
  assert second.index_status == "?"
  let assert Ok([combining]) =
    worktree_diff.decode_status(
      bit_array.from_string("?? sub/\u{0301}name\u{0}"),
      "sub/",
    )
    as "prefix removal cannot consume a leading combining code point"
  assert combining.path == "\u{0301}name"
}

pub fn partial_or_lossy_status_never_claims_a_census_test() {
  assert worktree_diff.decode_status(<<" M file":utf8>>, "")
    == Error(worktree_diff.InvalidOutput)
  assert worktree_diff.decode_status(<<32, 77, 32, 255, 0>>, "")
    == Error(worktree_diff.InvalidOutput)
  assert worktree_diff.decode_status(<<" M ../outside\u{0}":utf8>>, "")
    == Error(worktree_diff.InvalidOutput)
  assert worktree_diff.decode_status(<<" M other/file\u{0}":utf8>>, "sub/")
    == Error(worktree_diff.InvalidOutput)
}

pub fn read_policy_preserves_granted_metadata_and_masks_test() {
  let base =
    policy.SandboxPolicy(
      ..policy.workspace_default("/workspace"),
      readable_roots: ["/libraries"],
      writable_roots: ["/workspace", "/repository/.git"],
      protected: ["/workspace/owner.token"],
      mounts: [
        policy.Mount("/toolchain", policy.MountReadWrite, policy.MountRequired),
      ],
    )
  let read = worktree_diff.read_policy(base)
  assert read.writable_roots == []
  assert read.readable_roots == ["/libraries", "/workspace", "/repository/.git"]
  assert read.protected == base.protected
  assert read.mounts
    == [policy.Mount("/toolchain", policy.MountReadOnly, policy.MountRequired)]
  assert read.network == policy.NetworkOff
  assert read.scratch == policy.ScratchTmpfs
  assert read.env_allow == base.env_allow
  assert policy.validate(read) == Ok(Nil)
}

pub fn jailed_git_reports_real_net_changes_and_repository_states_test() {
  use wiring <- with_fixture("states")
  let assert Ok(outside) = worktree_diff.capture(wiring)
    as "a directory outside Git has a distinct observation"
  assert outside.repository == worktree_diff.NotRepository
  setup(wiring, ["init", "--quiet"])
  write(wiring, "tracked name\npart.txt", "original\n")
  write(wiring, "undo.txt", "original\n")
  let assert Ok(Nil) =
    simplifile.write_bits(wiring.workspace <> "/binary.dat", <<0, 1, 2>>)
    as "the fixture has a binary original"
  setup(wiring, ["add", "--", "."])

  // An unborn repository compares the current files against empty originals.
  let assert Ok(unborn) = worktree_diff.capture(wiring)
    as "an unborn repository is observable"
  assert unborn.repository == worktree_diff.Unborn
  assert unborn.total == 3
  assert string.contains(
    file(unborn, "tracked name\npart.txt").patch,
    "+original",
  )
  assert file(unborn, "binary.dat").kind == worktree_diff.Binary
  setup(wiring, [
    "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c",
    "commit.gpgsign=false", "commit", "--quiet", "-m", "original",
  ])
  let assert Ok(clean) = worktree_diff.capture(wiring)
    as "a committed unchanged workspace is clean"
  assert clean.repository == worktree_diff.Head
  assert clean.entries == []
  assert clean.total == 0
  assert clean.extent == worktree_diff.Complete
  setup(wiring, ["config", "diff.external", "false"])

  // The patch must use HEAD versus current bytes, not index versus current
  // bytes. Separate status preserves the opposite changes that cancel out.
  write(wiring, "tracked name\npart.txt", "staged\n")
  write(wiring, "undo.txt", "staged\n")
  setup(wiring, ["add", "--", "."])
  write(wiring, "tracked name\npart.txt", "final\n")
  write(wiring, "undo.txt", "original\n")
  write(wiring, "-untracked \nname", "addition\n")
  let assert Ok(Nil) =
    simplifile.write_bits(wiring.workspace <> "/binary.dat", <<0, 3, 4>>)
    as "the binary worktree content changes"
  let assert Ok(board) = worktree_diff.capture(wiring)
    as "the broker returns the worktree observation"
  let changed = file(board, "tracked name\npart.txt")
  assert changed.index_status == "M"
  assert changed.worktree_status == "M"
  assert string.contains(changed.patch, "-original")
  assert string.contains(changed.patch, "+final")
  assert !string.contains(changed.patch, "+staged")
  assert file(board, "undo.txt").kind == worktree_diff.NoNetChange
  assert file(board, "binary.dat").kind == worktree_diff.Binary
  assert string.contains(file(board, "-untracked \nname").patch, "+addition")
  assert board.total == 4
  assert board.omitted == 0
}

pub fn jailed_git_marks_patch_and_file_limits_test() {
  use wiring <- with_fixture("limits")
  setup(wiring, ["init", "--quiet"])
  write(wiring, "00-large.txt", string.repeat("line\n", 10_000))
  int.range(from: 1, to: 26, with: Nil, run: fn(_, index) {
    write(wiring, "file-" <> int.to_string(index), "small\n")
  })
  let assert Ok(board) = worktree_diff.capture(wiring)
    as "large workspaces retain a bounded observation"
  assert board.total == 26
  assert board.omitted == board.total - list.length(board.entries)
  assert board.omitted >= 2
  assert board.extent == worktree_diff.Limited
  assert file(board, "00-large.txt").extent == worktree_diff.Limited
  assert string.contains(file(board, "00-large.txt").patch, "+line")
  assert transfer.encoded_size(
      worktree_diff.to_json(board),
      worktree_diff.board_byte_limit,
    )
    |> is_ok
}

pub fn jailed_git_subtree_and_read_only_capture_test() {
  use wiring <- with_fixture("subtree")
  setup(wiring, ["init", "--quiet"])
  let assert Ok(Nil) =
    simplifile.create_directory_all(wiring.workspace <> "/sub dir")
    as "the attached session can be a repository subtree"
  write(wiring, "outside.txt", "outside\n")
  write(wiring, "sub dir/inside\nname", "inside\n")
  let scoped =
    worktree_diff.Wiring(..wiring, workspace: wiring.workspace <> "/sub dir")
  let assert Ok(board) = worktree_diff.capture(scoped)
    as "status identities are relative to the attached subtree"
  assert board.total == 1
  assert file(board, "inside\nname").index_status == "?"

  // The capture policy cannot write into the workspace even when a caller
  // supplies a command whose only purpose is to attempt that write.
  let read = worktree_diff.read_policy(wiring.base_policy)
  let outcome = invoke(wiring, ["touch", "must-not-exist"], read)
  let assert broker.CallExited(report) = outcome.outcome
    as "the denied write still has an execution settlement"
  assert report.code != 0
  assert simplifile.is_file(wiring.workspace <> "/must-not-exist") == Ok(False)
}

fn is_ok(value: Result(a, e)) -> Bool {
  case value {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn file(board: worktree_diff.Board, path: String) -> worktree_diff.File {
  let assert Ok(file) = list.find(board.entries, fn(file) { file.path == path })
    as { "the board retains the exact path " <> string.inspect(path) }
  file
}

fn write(wiring: worktree_diff.Wiring, path: String, text: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(wiring.workspace <> "/" <> path, text)
    as "the fixture controls the workspace bytes"
  Nil
}

fn setup(wiring: worktree_diff.Wiring, arguments: List(String)) -> Nil {
  let result = invoke(wiring, ["git", ..arguments], wiring.base_policy)
  let assert broker.CallExited(report) = result.outcome
    as "repository setup settles through the broker"
  assert report.code == 0
    as { "repository setup failed: " <> string.inspect(result.stderr) }
}

fn invoke(
  wiring: worktree_diff.Wiring,
  arguments: List(String),
  base: policy.SandboxPolicy,
) -> tool.Collected {
  let #(now, _) = clock.read(wiring.clock)
  let #(operation, _) =
    ids.mint_op(ids.generator(wiring.clock, wiring.entropy()))
  let events = process.new_subject()
  let assert Ok(call) =
    broker.clear_call(
      wiring.broker,
      broker.CallSpec(
        op_id: operation,
        step_id: "fixture",
        base_policy: base,
        requirements: base,
        grants: [],
        response: broker.RefuseNarrowed,
        demand: exec.PlatformEnforcement,
        argv: arguments,
        env: wiring.env,
        cwd: wiring.workspace,
        budget: budget.Budget(1, now + 10_000),
      ),
      events:,
      waiting: 5000,
    )
    as "the fixture clears its jailed command"
  broker.stdin(wiring.broker, call, data: <<>>, eof: True)
  let assert Ok(collected) = tool.collect_events(events, waiting: 15_000)
    as "the fixture's jailed command settles"
  collected
}

fn with_fixture(label: String, run: fn(worktree_diff.Wiring) -> Nil) -> Nil {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner has a package working directory"
  let assert Ok(repository) = bootstrap.canonical_directory(here <> "/../..")
    as "the source repository locates the built helper"
  case enforcement.probe(repository <> "/bin/loom", "worktree observation") {
    enforcement.EnforcementAbsent -> Nil
    enforcement.EnforcementLive -> {
      let directory =
        here
        <> "/build/worktree-observation-"
        <> label
        <> "-"
        <> int.to_string(bootstrap.system_time_ms())
      let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
        as "the fixture owns a workspace"
      let assert Ok(workspace) = bootstrap.canonical_directory(directory)
        as "the fixture policy uses absolute paths"

      // Production boot creates the protected blob store before starting its
      // effect plane. A read-only observation must find that mask mount point
      // already present; bubblewrap cannot create it through a read-only root.
      let assert Ok(Nil) =
        bootstrap.ensure_private_directory(
          workspace <> "/" <> codemode.blob_directory,
        )
        as "the fixture materializes the protected store as production boot does"

      // Keep ancestor repositories outside this fixture's readable scope.
      // Host reads would let the empty workspace discover the CI checkout.
      let base = serve.base_policy_for(workspace, catalog.WorkspaceReads)

      // Apple ships the real Git executable with Xcode; /usr/bin/git is a
      // launcher whose discovery needs unrelated host preferences. Admit only
      // the installed developer usr tree and put its real binary first.
      let developer_usr = "/Applications/Xcode.app/Contents/Developer/usr"
      let #(base, path) = case simplifile.is_directory(developer_usr) {
        Ok(True) -> #(
          policy.SandboxPolicy(..base, readable_roots: [
            developer_usr,
          ]),
          developer_usr <> "/bin:/usr/bin:/bin:/usr/local/bin",
        )
        Ok(False) | Error(_) -> #(base, "/usr/local/bin:/usr/bin:/bin")
      }
      let clock = clock.from_function(bootstrap.system_time_ms)
      let assert Ok(#(pool, broker)) =
        serve.start_effect_plane(
          helper: repository <> "/bin/loom-exec",
          base_policy: base,
          tmp_dir: workspace <> "/.helper",
          size: 1,
          clock:,
        )
        as "the fixture starts the production broker and pool"
      run(
        worktree_diff.Wiring(
          workspace:,
          broker:,
          base_policy: base,
          clock:,
          demand: exec.PlatformEnforcement,
          env: [
            #("PATH", path),
            #("HOME", "/nonexistent"),
          ],
          entropy: fn() { bootstrap.system_time_ms() },
        ),
      )

      // The pool's original helper witnesses, not a stop request, prove drain.
      broker.stop(broker)
      assert exec.close_pool(pool, waiting: 5000) == Ok(Nil)
    }
  }
}

// Generated caches must not spend the worktree's file or byte budget. A user
// who deliberately tracks a file in the same directory still sees its edits.
pub fn untracked_runtime_caches_do_not_hide_tracked_changes_test() {
  use wiring <- with_fixture("runtime-caches")
  setup(wiring, ["init", "--quiet"])
  let assert Ok(Nil) =
    simplifile.create_directory_all(wiring.workspace <> "/.codemode/cache")
    as "the generated cache directory exists"
  let assert Ok(Nil) =
    simplifile.create_directory_all(wiring.workspace <> "/.blobs")
    as "the generated blob directory exists"
  write(wiring, ".codemode/tracked.txt", "before\n")
  setup(wiring, ["add", "--", "."])
  setup(wiring, [
    "-c",
    "user.name=Fixture",
    "-c",
    "user.email=fixture@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--quiet",
    "-m",
    "tracked fixture",
  ])
  write(wiring, ".codemode/tracked.txt", "after\n")
  write(wiring, "new-source.txt", "real source\n")
  int.range(from: 1, to: 80, with: Nil, run: fn(_, index) {
    write(wiring, ".codemode/cache/" <> int.to_string(index), "cache\n")
  })
  write(wiring, ".blobs/generated", "blob\n")
  let assert Ok(board) = worktree_diff.capture(wiring)
    as "generated files cannot displace source changes"
  assert board.total == 2
  assert board.omitted == 0
  assert string.contains(file(board, ".codemode/tracked.txt").patch, "+after")
  assert string.contains(file(board, "new-source.txt").patch, "+real source")
}
