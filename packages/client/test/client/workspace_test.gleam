//// The harness-side closures the workspace capability bridge is built
//// from, against a real temporary workspace.
////
//// `codemode/workspace`'s own suite drives the *router* — decoding, the
//// wire shape of an answer, the code a refusal keeps — against scripted
//// closures. This is the other half, and the half where the security
//// claim lives: the closures themselves, over real files, real symlinks
//// and a real blob store.
////
//// What is being proved is that **nothing about the authorization model
//// is re-derived**. Containment is `tools/fs.resolve_real`'s and the
//// large-file guard is `fs_read`'s, so the tests below are written
//// against those functions' own behaviour rather than against a
//// restatement of it — a bridge that resolved paths itself would have to
//// re-earn every one of these, and would eventually get one wrong.

import broker/broker
import broker/exec
import broker/policy
import client/codemode
import client/scratch
import codemode/artifact
import codemode/vet/policy as vet_policy
import codemode/workspace
import core/clock
import core/ids
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import simplifile
import tools/blob
import tools/codemode as codemode_tool
import tools/fs

// --- fs.read ------------------------------------------------------------------

pub fn a_read_round_trips_a_real_file_test() {
  let root = fresh("read")
  let seam = seam_over(root)
  write(root, "notes.txt", "hello\nworld\n")
  assert seam.fs_read("notes.txt") == Ok("hello\nworld\n")
}

pub fn a_read_of_an_absent_file_is_not_found_test() {
  let seam = seam_over(fresh("absent"))
  let assert Error(refusal) = seam.fs_read("nothing.txt")
    as "an absent file is refused"
  assert workspace.fs_denial(refusal).code == workspace.not_found_code
}

pub fn an_empty_path_is_the_tools_own_refusal_test() {
  let seam = seam_over(fresh("empty"))
  let assert Error(workspace.PathRefused(fs.EmptyPath)) = seam.fs_read("")
    as "an empty path is refused before anything is read"
}

pub fn a_read_outside_the_workspace_is_refused_in_the_tools_vocabulary_test() {
  // The decisive containment test, and it is deliberately *three* shapes
  // of escape rather than one: a `..` traversal, an absolute path, and a
  // symlink planted inside the workspace pointing out of it. Only the
  // last distinguishes `resolve_real` from the lexical `resolve_path`,
  // and it is the one a bridge that wrote its own resolution would get
  // wrong — a lexical check passes a symlink straight through.
  let root = fresh("escape")
  let seam = seam_over(root)
  let secret = root <> "-outside/secret.txt"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "-outside")
    as "the outside directory must be creatable"
  let assert Ok(Nil) = simplifile.write(secret, "not yours")
    as "the outside file must be writable"
  let assert Ok(Nil) = simplifile.create_symlink(secret, root <> "/link.txt")
    as "the escaping symlink must be creatable"
  list.each(
    ["../" <> outside_name(root) <> "/secret.txt", secret, "link.txt"],
    fn(path) {
      let assert Error(refusal) = seam.fs_read(path)
        as { "a path escaping the workspace must be refused: " <> path }
      let denial = workspace.fs_denial(refusal)
      assert denial.code == workspace.permission_denied_code
      assert string.contains(denial.message, "outside the workspace root")
    },
  )
  // And the file really was readable to the harness, so the refusal is
  // containment rather than an absent file wearing its clothes.
  assert simplifile.read(secret) == Ok("not yours")
}

pub fn a_read_follows_a_symlink_that_stays_inside_test() {
  // The other direction of the same rule: containment refuses what leaves
  // the workspace, and permits what does not. A bridge that refused every
  // symlink would pass the test above and be wrong.
  let root = fresh("inside-link")
  let seam = seam_over(root)
  write(root, "real.txt", "inside\n")
  let assert Ok(Nil) =
    simplifile.create_symlink(root <> "/real.txt", root <> "/alias.txt")
    as "the internal symlink must be creatable"
  assert seam.fs_read("alias.txt") == Ok("inside\n")
}

pub fn a_read_of_a_directory_is_refused_rather_than_answered_test() {
  let root = fresh("dir-read")
  let seam = seam_over(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/src")
    as "the directory must be creatable"
  let assert Error(refusal) = seam.fs_read("src") as "a directory is not text"
  // Whatever the platform calls it, it is not `Ok`: the point is that a
  // program never receives a directory's bytes as a file's contents.
  assert workspace.fs_denial(refusal).code != ""
}

pub fn a_read_past_the_size_cap_matches_fs_reads_own_guard_test() {
  // The same number and the same decision as `fs_read`, because it is the
  // same function: `tools/fs.read_text_file` is what both call. Driven
  // one byte over rather than at some round number, so a bridge that
  // copied the constant and then drifted would show.
  let root = fresh("large")
  let seam = seam_over(root)
  let oversized = string.repeat("x", fs.max_read_bytes + 1)
  let assert Ok(Nil) = simplifile.write(root <> "/big.txt", oversized)
    as "the oversized file must be writable"
  let assert Error(workspace.ReadRefused(fs.TooLarge(size:, limit:))) =
    seam.fs_read("big.txt")
    as "a file past the guard is refused"
  assert size == fs.max_read_bytes + 1
  assert limit == fs.max_read_bytes
  assert workspace.fs_denial(workspace.ReadRefused(fs.TooLarge(size:, limit:))).code
    == workspace.too_large_code
}

pub fn a_read_at_the_size_cap_is_admitted_test() {
  let root = fresh("at-cap")
  let seam = seam_over(root)
  let at_cap = string.repeat("y", fs.max_read_bytes)
  let assert Ok(Nil) = simplifile.write(root <> "/exact.txt", at_cap)
    as "the file at the cap must be writable"
  assert seam.fs_read("exact.txt") == Ok(at_cap)
}

pub fn a_binary_file_is_a_wrong_kind_rather_than_mangled_text_test() {
  // `cap/fs.read` answers a `String`, so bytes that are not UTF-8 have no
  // answer. Refusing is what keeps a program from acting on a lossy
  // transcoding it cannot detect.
  let root = fresh("binary")
  let seam = seam_over(root)
  let assert Ok(Nil) = simplifile.write_bits(root <> "/blob.bin", <<255, 254>>)
    as "the binary file must be writable"
  let assert Error(workspace.ReadRefused(fs.NotText)) = seam.fs_read("blob.bin")
    as "non-UTF-8 bytes are refused"
}

// --- fs.list --------------------------------------------------------------------

pub fn a_list_names_files_and_directories_test() {
  let root = fresh("list")
  let seam = seam_over(root)
  write(root, "gleam.toml", "name = \"x\"\n")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/src")
    as "the subdirectory must be creatable"
  let assert Ok(entries) = seam.fs_list(".") as "the workspace root lists"
  assert sorted_names(entries) == ["gleam.toml", "src"]
  assert directories(entries) == ["src"]
}

pub fn a_list_reports_a_symlink_as_not_a_directory_test() {
  // lstat semantics, and both halves matter. A link to a directory
  // *inside* the workspace is still reported as not a directory, which is
  // the conservative answer; a link pointing *outside* is reported the
  // same way, which is what keeps the listing from saying anything about
  // a target the program may not read.
  let root = fresh("list-links")
  let seam = seam_over(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/real")
    as "the real directory must be creatable"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "-elsewhere")
    as "the outside directory must be creatable"
  let assert Ok(Nil) =
    simplifile.create_symlink(root <> "/real", root <> "/inside-link")
    as "the internal symlink must be creatable"
  let assert Ok(Nil) =
    simplifile.create_symlink(root <> "-elsewhere", root <> "/outside-link")
    as "the escaping symlink must be creatable"
  let assert Ok(entries) = seam.fs_list(".") as "the workspace root lists"
  assert sorted_names(entries) == ["inside-link", "outside-link", "real"]
  assert directories(entries) == ["real"]
}

pub fn a_list_outside_the_workspace_is_refused_test() {
  let root = fresh("list-escape")
  let seam = seam_over(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "-outside")
    as "the outside directory must be creatable"
  let assert Error(refusal) = seam.fs_list(root <> "-outside")
    as "a directory outside the workspace must be refused"
  assert workspace.fs_denial(refusal).code == workspace.permission_denied_code
}

pub fn a_list_of_an_absent_directory_is_refused_test() {
  let seam = seam_over(fresh("list-absent"))
  let assert Error(refusal) = seam.fs_list("nowhere")
    as "an absent directory is refused"
  assert workspace.fs_denial(refusal).message != ""
}

pub fn a_listing_past_the_bound_is_refused_rather_than_truncated_test() {
  // `cap/fs.DirEntry` has no "and more" field, so a short listing is
  // indistinguishable from a complete one — which is a program looping
  // over a directory it believes it has seen. Refusing is the only honest
  // answer the wire allows.
  let root = fresh("list-bound")
  let seam = seam_over(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/many")
    as "the directory must be creatable"
  list.each(counting(workspace.max_list_entries + 1), fn(nth) {
    let assert Ok(Nil) =
      simplifile.write(root <> "/many/f" <> int.to_string(nth), "")
      as "each entry must be writable"
    Nil
  })
  let assert Error(workspace.TooManyEntries(count:, limit:)) =
    seam.fs_list("many")
    as "a directory past the bound is refused"
  assert count == workspace.max_list_entries + 1
  assert limit == workspace.max_list_entries
}

// --- report.emit ------------------------------------------------------------------

pub fn an_emit_writes_a_real_blob_at_its_content_address_test() {
  // The whole of the wiring: the id a program gets back is `blob.ref_for`
  // over the bytes it sent, and the file is at `blob.ref_path` under the
  // *same* root the harness's own overflow writes into. An artifact a
  // program cannot then find is worse than one it never minted.
  let root = fresh("emit")
  let seam = seam_over(root)
  let bytes = <<"the artifact's own bytes":utf8>>
  let assert Ok(id) =
    seam.emit(artifact.Artifact(
      name: "report.md",
      content_type: "text/markdown",
      bytes:,
    ))
    as "a well-formed emit is written"
  assert id == blob.ref_for(bytes)
  assert string.starts_with(id, "sha256-")
  let path = blob.ref_path(root <> "/" <> codemode.blob_directory, id)
  assert simplifile.read_bits(path) == Ok(bytes)
}

pub fn an_emit_leaves_no_staging_file_behind_test() {
  // The blob write is staged under a temporary name in the blob root and
  // renamed into place, so a crash mid-write can never leave a partial
  // file at an address whose SHA-256 name vouches for the whole of it
  // (`blob.write_addressed`; `tools/blob_test` holds the refused-rename
  // case). What this side owes is the other half: on the ordinary path
  // the staging file is *gone*, so the store holds addresses and nothing
  // else.
  let root = fresh("emit-staging")
  let seam = seam_over(root)
  let bytes = <<"staged then renamed":utf8>>
  let assert Ok(id) =
    seam.emit(artifact.Artifact(
      name: "report.md",
      content_type: "text/markdown",
      bytes:,
    ))
    as "a well-formed emit is written"
  let store = root <> "/" <> codemode.blob_directory
  let assert Ok(written) = simplifile.get_files(in: store)
    as "the blob root must be listable"
  assert written == [blob.ref_path(store, id)]
}

pub fn re_emitting_identical_bytes_answers_the_same_id_test() {
  // Content addressing, pinned by its consequence: the store is
  // idempotent, so a program that emits the same artifact twice pays for
  // one file. This is also why `report.emit`'s ceiling bounds *calls*
  // rather than storage — the thing that grows is distinct content.
  let root = fresh("emit-twice")
  let seam = seam_over(root)
  let bytes = <<"same bytes":utf8>>
  let assert Ok(first) =
    seam.emit(artifact.Artifact(
      name: "a.txt",
      content_type: "text/plain",
      bytes:,
    ))
    as "the first emit is written"
  // A different *name* and a different content type: neither is part of
  // the address, and a program must not be able to mint two artifacts by
  // relabelling one.
  let assert Ok(second) =
    seam.emit(artifact.Artifact(
      name: "b.txt",
      content_type: "application/octet-stream",
      bytes:,
    ))
    as "the second emit is written"
  assert first == second
  let assert Ok(written) =
    simplifile.get_files(in: root <> "/" <> codemode.blob_directory)
    as "the blob root must be listable"
  assert list.length(written) == 1
}

pub fn different_bytes_answer_different_ids_test() {
  let root = fresh("emit-distinct")
  let seam = seam_over(root)
  let assert Ok(first) =
    seam.emit(
      artifact.Artifact(name: "a.txt", content_type: "text/plain", bytes: <<
        "one":utf8,
      >>),
    )
    as "the first emit is written"
  let assert Ok(second) =
    seam.emit(
      artifact.Artifact(name: "a.txt", content_type: "text/plain", bytes: <<
        "two":utf8,
      >>),
    )
    as "the second emit is written"
  assert first != second
}

pub fn the_emit_bound_and_ceiling_are_the_documented_numbers_test() {
  // The two bounds are different instruments and the numbers say so: one
  // megabyte per artifact (well under the 16 MiB frame cap, because a
  // frame is transient and an artifact is a durable mint), and
  // sixty-four artifacts per execution.
  assert artifact.max_emit_bytes == 1_048_576
  assert artifact.default_emit_ceiling == 64
}

// --- the seam as a whole ------------------------------------------------------

pub fn the_seam_reports_the_caps_the_router_services_test() {
  // The sentence the model is charged for on every request, read off the
  // router rather than copied beside it. A description that promised
  // `fs.write` would cost a whole wasted submission to find out
  // otherwise.
  let caps = codemode.seam_caps(vet_policy.WorkspaceSeam)
  assert list.contains(caps, "proc.run")
  list.each(workspace.serviced_caps, fn(cap) {
    assert list.contains(caps, cap)
  })
}

pub fn the_kv_arms_come_from_the_configured_store_test() {
  // The seam's `kv.*` closures are the store's, not copies of them: a
  // value set through the seam is readable through the same seam and
  // through a second one built over the same name.
  let name = process.new_name(prefix: "loom_scratch_ws")
  let assert Ok(_started) = scratch.start(name, scratch.default_bounds())
    as "the scratch store must start"
  let root = fresh("kv")
  let seam =
    codemode.workspace_seam(
      config_over(root)
        |> codemode.over_scratch(scratch.seam(name, timeout_ms: 1000)),
      request_over(root),
    )
  assert seam.kv_set("k", <<"v":utf8>>) == Ok(Nil)
  assert seam.kv_get("k") == Ok(option.Some(<<"v":utf8>>))
  assert seam.kv_delete("k") == Ok(Nil)
  assert seam.kv_get("k") == Ok(option.None)
  scratch.stop(name)
}

pub fn a_host_with_no_store_refuses_kv_rather_than_pretending_test() {
  let seam = seam_over(fresh("no-kv"))
  let assert Error(workspace.StoreUnavailable(..)) = seam.kv_get("k")
    as "a host with no store refuses a get"
  let assert Error(workspace.StoreUnavailable(..)) =
    seam.kv_set("k", <<"v":utf8>>)
    as "a host with no store refuses a set"
}

// --- the write arms ------------------------------------------------------------

pub fn a_write_lands_and_reads_back_through_the_seam_test() {
  let root = fresh("write")
  let seam = seam_over(root)
  let assert Ok(Nil) = seam.fs_write("out.txt", "written through the bridge")
    as "a legitimate write is serviced"
  assert seam.fs_read("out.txt") == Ok("written through the bridge")
}

pub fn a_write_onto_a_protected_path_is_refused_and_nothing_lands_test() {
  // THE test issue #105 demanded and could not have until both pieces
  // existed: the bridge write arm meets the same protected-path refusal
  // the model's own fs_write does, from the same resolve_writable.
  let root = fresh("write-protected")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/.git/hooks")
    as "the fixture needs a .git"
  let seam = protected_seam_over(root)
  let assert Error(workspace.PathRefused(fs.ProtectedPath(..))) =
    seam.fs_write(".git/hooks/post-checkout", "#!/bin/sh\necho pwned")
    as "a protected write is refused"
  assert simplifile.is_file(root <> "/.git/hooks/post-checkout") == Ok(False)
}

pub fn a_symlink_onto_a_protected_path_is_refused_through_the_bridge_test() {
  // The ordering property, observed through the bridge: the protected
  // check runs on the *resolved* path, so a workspace-internal symlink
  // onto .git/config cannot walk through it.
  let root = fresh("write-symlink")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/.git")
    as "the fixture needs a .git"
  let assert Ok(Nil) = simplifile.write(root <> "/.git/config", "[core]\n")
    as "the fixture needs a config"
  let assert Ok(Nil) =
    simplifile.create_symlink(to: ".git/config", from: root <> "/innocent.txt")
    as "the fixture needs the symlink"
  let seam = protected_seam_over(root)
  let assert Error(workspace.PathRefused(fs.ProtectedPath(..))) =
    seam.fs_write("innocent.txt", "overwritten")
    as "the symlink resolves onto the protected entry and is refused"
  assert simplifile.read(root <> "/.git/config") == Ok("[core]\n")
}

pub fn a_relative_protected_entry_refuses_every_bridge_write_test() {
  // The second door onto the same fail-closed rule (`fs_test` holds the
  // first). A relative `protected` entry normalizes to `/.git`, which is
  // under no workspace and so covers nothing — the list would have
  // protected nothing while reading as though it did. The jail refuses
  // the very same policy as `RelativePath`, and the harness must not be
  // the door that quietly stays open.
  //
  // Refused for ANY path, not only the one the entry meant: what a
  // misconfigured list intended to cover is exactly what cannot be
  // recovered from it.
  let root = fresh("write-relative-protected")
  let seam = seam_protecting(root, [".git"])
  let assert Error(workspace.PathRefused(fs.ProtectionMisconfigured(
    protected: ".git",
    ..,
  ))) = seam.fs_write("src/main.gleam", "pub fn main() {}")
    as "a relative protected entry refuses the write"
  assert simplifile.is_file(root <> "/src/main.gleam") == Ok(False)
}

pub fn a_relative_protected_entry_refuses_a_bridge_edit_test() {
  let root = fresh("edit-relative-protected")
  write(root, "code.txt", "let value = old_name")
  let seam = seam_protecting(root, [root <> "/.git", "relative/entry"])
  let edits = [
    workspace.Replacement(find: "old_name", replace_with: "new_name"),
  ]
  let assert Error(workspace.PathRefused(fs.ProtectionMisconfigured(
    protected: "relative/entry",
    ..,
  ))) = seam.fs_edit("code.txt", edits)
    as "a relative protected entry refuses the edit"
  assert seam_over(root).fs_read("code.txt") == Ok("let value = old_name")
}

pub fn a_relative_protected_entry_travels_under_its_own_code_test() {
  // What a program actually reads. `cap/fs.map_error` turns this code
  // into `PermissionDenied`, which is honest: nothing is wrong with the
  // call, and there is no argument the program could change.
  let refusal =
    workspace.PathRefused(fs.ProtectionMisconfigured(
      path: "src/main.gleam",
      protected: ".git",
    ))
  // Its own code, deliberately: `cap/fs` decodes `permission_denied` to
  // a variant carrying only the path, while an unlearned code arrives as
  // `FsFailed` with the code and the whole sentence verbatim — and the
  // sentence, naming an operator misconfiguration, is the diagnosis.
  assert workspace.fs_denial(refusal).code
    == workspace.protection_misconfigured_code
  assert string.contains(workspace.fs_denial(refusal).message, ".git")
}

pub fn a_bridge_write_creates_missing_parent_directories_test() {
  // The two doors onto one workspace must not disagree about this. The
  // model's own `fs_write` creates parents and says so in its
  // description; a bridge that failed with an errno on the same path
  // would be one workspace behaving two ways depending on which door a
  // write came through.
  let root = fresh("write-parents")
  let seam = seam_over(root)
  let assert Ok(Nil) = seam.fs_write("new_dir/file.txt", "landed")
    as "a bridged write creates its parent directory"
  assert seam.fs_read("new_dir/file.txt") == Ok("landed")
}

pub fn a_list_of_a_file_is_not_a_directory_test() {
  // `fs.list` of a regular file is the one listing failure a program can
  // act on: it says `fs.read` was the call that was wanted. `cap/fs`
  // decodes the code to `WrongKind`.
  let root = fresh("list-not-a-directory")
  write(root, "notes.txt", "hello\n")
  let seam = seam_over(root)
  let assert Error(refusal) = seam.fs_list("notes.txt")
    as "listing a file is refused"
  assert refusal == workspace.NotADirectory(path: root <> "/notes.txt")
  assert workspace.fs_denial(refusal).code == workspace.not_a_directory_code
}

pub fn a_write_outside_the_workspace_is_refused_test() {
  let seam = seam_over(fresh("write-outside"))
  let assert Error(workspace.PathRefused(fs.EscapesWorkspace(..))) =
    seam.fs_write("../elsewhere.txt", "no")
    as "a write outside the workspace is refused"
}

pub fn an_edit_applies_in_one_closure_and_reads_back_test() {
  let root = fresh("edit")
  let seam = seam_over(root)
  let assert Ok(Nil) = seam.fs_write("code.txt", "let value = old_name")
    as "the fixture write must land"
  let edits = [
    workspace.Replacement(find: "old_name", replace_with: "new_name"),
  ]
  let assert Ok(Nil) = seam.fs_edit("code.txt", edits)
    as "a matching edit is serviced"
  assert seam.fs_read("code.txt") == Ok("let value = new_name")
}

pub fn a_stale_edit_leaves_the_file_untouched_test() {
  let root = fresh("edit-stale")
  let seam = seam_over(root)
  let assert Ok(Nil) = seam.fs_write("code.txt", "current text")
    as "the fixture write must land"
  let edits = [
    workspace.Replacement(find: "current", replace_with: "first"),
    workspace.Replacement(find: "vanished", replace_with: "second"),
  ]
  let assert Error(workspace.EditRefused(workspace.StaleFind(..))) =
    seam.fs_edit("code.txt", edits)
    as "a missed find is stale"
  // All-or-nothing: the first replacement matched, and still nothing
  // landed.
  assert seam.fs_read("code.txt") == Ok("current text")
}

pub fn an_edit_of_a_protected_path_is_refused_before_reading_test() {
  let root = fresh("edit-protected")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/.git")
    as "the fixture needs a .git"
  let assert Ok(Nil) = simplifile.write(root <> "/.git/config", "[core]\n")
    as "the fixture needs a config"
  let seam = protected_seam_over(root)
  let edits = [workspace.Replacement(find: "[core]", replace_with: "[evil]")]
  let assert Error(workspace.PathRefused(fs.ProtectedPath(..))) =
    seam.fs_edit(".git/config", edits)
    as "a protected edit is refused"
  assert simplifile.read(root <> "/.git/config") == Ok("[core]\n")
}

// --- the rig ---------------------------------------------------------------------

fn seam_over(root: String) -> workspace.Workspace {
  codemode.workspace_seam(config_over(root), request_over(root))
}

// A `Config` over a real workspace. The broker in it is an idle one that
// can check nothing out: the closures under test clear nothing — that is
// the whole of what `ServedHere` means — so a broker that answered would
// be proving something no capability call here can reach.
// The seam over a request whose base policy protects the workspace's
// .git — the shape a production base carries and `workspace_default`
// deliberately does not.
fn protected_seam_over(root: String) -> workspace.Workspace {
  seam_protecting(root, [root <> "/.git"])
}

// The seam over a request whose base policy protects exactly `entries` —
// including, for the fail-closed tests, entries no valid policy may hold.
fn seam_protecting(root: String, entries: List(String)) -> workspace.Workspace {
  let request = request_over(root)
  let base = request.base_policy
  codemode.workspace_seam(
    config_over(root),
    codemode_tool.Request(
      ..request,
      base_policy: policy.SandboxPolicy(..base, protected: entries),
    ),
  )
}

fn config_over(root: String) -> codemode.Config {
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: fn(bytes) { <<0:size(bytes)-unit(8)>> },
        clock: clock.fixed(at: 0),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker must start"
  codemode.default_config(
    broker: broker_actor,
    clock: clock.fixed(at: 1000),
    workspace: root,
    toolchain: codemode.Toolchain(
      gleam_path: "/opt/gleam/bin/gleam",
      erl_path: "/usr/lib/erlang/bin/erl",
      seed_root: "/opt/loom/codemode-seed",
    ),
  )
}

fn request_over(root: String) -> codemode_tool.Request {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 3))
  codemode_tool.Request(
    source: "pub fn main() { todo }",
    seam: codemode_tool.WorkspaceSeam,
    strand: "main",
    op_id: op,
    step_id: "turn-1:tools",
    source_index: 0,
    workspace: root,
    base_policy: policy.workspace_default(root),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    within_ms: 60_000,
    grants: [],
  )
}

// A fresh workspace directory per test, so nothing one test wrote is
// visible to another — several of these assert on a whole listing.
fn fresh(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let root = here <> "/build/workspace-seam/" <> name
  let _cleared = simplifile.delete(root)
  let _also = simplifile.delete(root <> "-outside")
  let _more = simplifile.delete(root <> "-elsewhere")
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the workspace must be creatable"
  root
}

fn outside_name(root: String) -> String {
  case string.split(root, "/") |> list.reverse {
    [last, ..] -> last <> "-outside"
    [] -> "-outside"
  }
}

fn write(root: String, name: String, contents: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(root <> "/" <> name, contents)
    as "the fixture file must be writable"
  Nil
}

fn sorted_names(entries: List(workspace.DirEntry)) -> List(String) {
  entries |> list.map(fn(entry) { entry.name }) |> list.sort(string.compare)
}

fn directories(entries: List(workspace.DirEntry)) -> List(String) {
  entries
  |> list.filter(fn(entry) { entry.is_directory })
  |> list.map(fn(entry) { entry.name })
  |> list.sort(string.compare)
}

fn counting(count: Int) -> List(Int) {
  int.range(from: count, to: 0, with: [], run: list.prepend)
}
