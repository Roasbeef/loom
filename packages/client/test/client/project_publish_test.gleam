//// Publishing a verified commit against a real repository, a real bare remote
//// and a fake `gh`.
////
//// Nothing here reaches GitHub. The remote is a bare repository on disk, so the
//// push is the real one, and `gh` is a shell script that answers the REST
//// calls the module makes from a file, keeping a log of its arguments. What the
//// tests claim is about the daemon's side: what is pushed, to which ref, which
//// calls are made, how many pull requests are opened, and what the title and
//// the arguments look like.

import client/internal/ffi_os
import client/project_publish.{Failed, Unavailable}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/worktree_rig

type Rig {
  Rig(
    repository: project_publish.Repository,
    commit: String,
    remote: String,
    bin: String,
    tools: project_publish.Tools,
  )
}

// The fake `gh`: it logs its arguments, remembers the last title it was given
// and keeps the open pull requests in a file, so a second look finds what the
// first created.
const fake_gh =
  "#!/bin/sh
d=$(dirname \"$0\")
echo \"$*\" >> \"$d/calls\"
for a in \"$@\"; do
  case \"$a\" in
    title=*) printf '%s' \"${a#title=}\" > \"$d/title\" ;;
  esac
done
case \"$*\" in
  *\"--method POST\"*)
    printf '[{\"html_url\":\"https://example.test/o/r/pull/7\"}]' > \"$d/prs.json\"
    printf '{\"html_url\":\"https://example.test/o/r/pull/7\"}' ;;
  *\"--method GET repos/\"*\"/pulls\"*)
    cat \"$d/prs.json\" 2>/dev/null || printf '[]' ;;
  *\"--method GET\"*)
    printf '{\"default_branch\":\"main\"}' ;;
esac
"

fn rig(name: String) -> Rig {
  let scratch =
    "build/project-publish-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(scratch)
  let assert Ok(Nil) = simplifile.create_directory_all(scratch)
    as "the scratch directory is made"
  let assert Ok(scratch) = bootstrap.canonical_directory(scratch)
    as "the scratch directory resolves"
  let repository = worktree_rig.repository(scratch <> "/repo")
  let remote = scratch <> "/remote.git"
  let pinned = "https://github.com/o/r.git"
  worktree_rig.git(scratch, ["init", "--quiet", "--bare", remote])
  worktree_rig.git(repository, ["remote", "add", "origin", remote])

  // The pinned URL must be a GitHub one, or nothing is published. The repository
  // rewrites that address to the bare repository on disk, so the push is still a
  // real one and reaches nothing else.
  worktree_rig.git(repository, [
    "config",
    "url." <> remote <> ".insteadOf",
    pinned,
  ])
  worktree_rig.write(repository <> "/feature", "work\n")
  worktree_rig.git(repository, ["add", "feature"])
  worktree_rig.git(repository, ["commit", "--quiet", "-m", "work"])
  let commit = worktree_rig.git(repository, ["rev-parse", "HEAD"])
  let bin = scratch <> "/bin"
  let assert Ok(Nil) = simplifile.create_directory_all(bin)
    as "the bin directory is made"
  let assert Ok(Nil) = simplifile.write(bin <> "/gh", fake_gh)
    as "the fake gh is written"
  let assert Ok(Nil) = simplifile.set_permissions_octal(bin <> "/gh", 0o755)
    as "the fake gh is executable"
  Rig(
    repository: project_publish.Repository(directory: repository, url: pinned),
    commit:,
    remote:,
    bin:,
    tools: project_publish.Tools(
      git: "git",
      env: "/usr/bin/env",
      gh: Some(bin <> "/gh"),
    ),
  )
}

fn publish(rig: Rig) -> Result(String, project_publish.Failure) {
  project_publish.publish(
    rig.tools,
    rig.repository,
    "project/t-a",
    rig.commit,
    "[loom t-a] \"work\"",
    "the body",
  )
}

// The lines the fake `gh` logged.
fn calls(rig: Rig) -> List(String) {
  case simplifile.read(rig.bin <> "/calls") {
    Ok(text) -> string.split(text, "\n") |> list.filter(fn(line) { line != "" })
    Error(_) -> []
  }
}

fn creations(rig: Rig) -> Int {
  list.count(calls(rig), fn(line) { string.contains(line, "--method POST") })
}

// --- pushing and opening ------------------------------------------------------

pub fn the_commit_is_pushed_to_the_ticket_branch_and_one_pull_request_opens_test() {
  let rig = rig("opens")
  let assert Ok("https://example.test/o/r/pull/7") = publish(rig)

  // The remote holds exactly the verified commit on the derived branch.
  assert worktree_rig.git(rig.remote, [
      "rev-parse",
      "refs/heads/project/t-a",
    ])
    == rig.commit
  assert creations(rig) == 1

  // The title travelled as one argument, whole.
  let assert Ok(title) = simplifile.read(rig.bin <> "/title")
  assert title == "[loom t-a] \"work\""
}

// A crash after the request and before the record leaves the publish job to
// run again. The second run finds the pull request the first opened.
pub fn a_second_publish_after_a_crash_opens_no_second_pull_request_test() {
  let rig = rig("twice")
  let assert Ok(first) = publish(rig)
  let assert Ok(second) = publish(rig)
  assert first == second
  assert creations(rig) == 1

  // The second run asked before it created, and it did not even look up the
  // default branch.
  let lookups =
    list.count(calls(rig), fn(line) {
      string.contains(line, "--method GET") && string.contains(line, "/pulls")
    })
  assert lookups == 2
}

pub fn a_later_commit_reaches_the_same_branch_and_the_same_pull_request_test() {
  let rig = rig("later")
  let assert Ok(_) = publish(rig)
  worktree_rig.write(rig.repository.directory <> "/more", "more\n")
  worktree_rig.git(rig.repository.directory, ["add", "more"])
  worktree_rig.git(rig.repository.directory, ["commit", "--quiet", "-m", "more"])
  let later = worktree_rig.git(rig.repository.directory, ["rev-parse", "HEAD"])
  let assert Ok(_) =
    project_publish.publish(
      rig.tools,
      rig.repository,
      "project/t-a",
      later,
      "t",
      "b",
    )
  assert worktree_rig.git(rig.remote, ["rev-parse", "refs/heads/project/t-a"])
    == later
  assert creations(rig) == 1
}

pub fn the_repositorys_hooks_do_not_run_on_the_push_test() {
  let rig = rig("hooks")
  let marker = rig.bin <> "/hook-ran"
  let hook = rig.repository.directory <> "/.git/hooks/pre-push"
  let assert Ok(Nil) =
    simplifile.write(hook, "#!/bin/sh\ntouch " <> marker <> "\n")
  let assert Ok(Nil) = simplifile.set_permissions_octal(hook, 0o755)
  let assert Ok(_) = publish(rig)
  assert !bootstrap.path_exists(marker)
  assert worktree_rig.git(rig.remote, ["rev-parse", "refs/heads/project/t-a"])
    == rig.commit
}

pub fn a_push_the_remote_refuses_is_a_failure_that_may_pass_test() {
  let rig = rig("refused")

  // The remote's branch holds something else, so a push without force is
  // refused.
  worktree_rig.git(rig.repository.directory, [
    "push",
    "--quiet",
    "origin",
    "main:refs/heads/project/t-a",
  ])
  worktree_rig.git(rig.repository.directory, ["checkout", "--quiet", "-b", "x"])
  worktree_rig.git(rig.repository.directory, [
    "commit",
    "--quiet",
    "--amend",
    "-m",
    "rewritten",
  ])
  let diverged =
    worktree_rig.git(rig.repository.directory, ["rev-parse", "HEAD"])
  let assert Error(Failed(_)) =
    project_publish.publish(
      rig.tools,
      rig.repository,
      "project/t-a",
      diverged,
      "t",
      "b",
    )
  assert creations(rig) == 0
}

// --- when nothing can be published ----------------------------------------------

pub fn a_url_with_no_owner_and_name_is_unavailable_and_asks_nothing_of_gh_test() {
  let rig = rig("noowner")
  let nameless = project_publish.Repository(..rig.repository, url: "r")
  let assert Error(Unavailable(why)) =
    project_publish.publish(
      rig.tools,
      nameless,
      "project/t-a",
      rig.commit,
      "t",
      "b",
    )
  assert string.contains(why, "no GitHub owner and name")
  assert calls(rig) == []
}

// The repository's own configuration names other places to push, as a worker's
// clone could. The push goes to the pinned URL, which it was given literally.
pub fn the_repositorys_configuration_does_not_redirect_the_push_test() {
  let rig = rig("redirect")
  let decoy = rig.bin <> "/decoy.git"
  worktree_rig.git(rig.bin, ["init", "--quiet", "--bare", decoy])
  let directory = rig.repository.directory
  worktree_rig.git(directory, ["config", "remote.origin.url", decoy])
  worktree_rig.git(directory, ["config", "remote.origin.pushurl", decoy])
  let assert Ok(_) = publish(rig)
  assert worktree_rig.git(rig.remote, ["rev-parse", "refs/heads/project/t-a"])
    == rig.commit
  assert !bootstrap.path_exists(decoy <> "/refs/heads/project")
}

pub fn a_machine_without_gh_is_unavailable_test() {
  let rig = rig("nogh")
  let bare = project_publish.Tools(..rig.tools, gh: None)
  let assert Error(Unavailable(why)) =
    project_publish.publish(
      bare,
      rig.repository,
      "project/t-a",
      rig.commit,
      "t",
      "b",
    )
  assert string.contains(why, "gh")
  assert !bootstrap.path_exists(rig.remote <> "/refs/heads/project")
}

// --- the title and the body ---------------------------------------------------

pub fn a_hostile_title_is_capped_and_fenced_test() {
  let hostile =
    "ping @everyone and @alice\nfixes #12\r\n```rm -rf```\u{202e}[x](http://evil)<b>"
  let title = project_publish.title("t-c1", hostile)
  assert title
    == "[loom t-c1] \"ping everyone and alice fixes 12 rm -rfx(http://evil)b\""
  assert !string.contains(title, "\n")
  assert !string.contains(title, "@")
  assert !string.contains(title, "#")
  assert !string.contains(title, "`")
  assert !string.contains(title, "\u{202e}")
}

pub fn a_long_title_is_cut_and_an_empty_one_leaves_only_the_ticket_test() {
  let long = project_publish.title("t-c1", string.repeat("a", 500))
  assert string.length(long)
    == string.length("[loom t-c1] \"\"") + project_publish.max_title_chars
  assert project_publish.title("t-c1", "@#`") == "[loom t-c1]"
}

pub fn a_title_that_names_a_branch_changes_no_ref_test() {
  // The title is data for one argument. A title that reads like an option or
  // a refspec is still only a title.
  let title = project_publish.title("t-c1", "--delete main:refs/heads/main")
  assert title == "[loom t-c1] \"--delete main:refs/heads/main\""
}

pub fn the_body_is_built_from_ledger_facts_test() {
  let passed =
    project_publish.body(project_publish.Facts(
      "t-c1",
      "abc123",
      project_publish.Passed("d1g3st", "e12"),
    ))
  assert string.contains(passed, "`t-c1`")
  assert string.contains(passed, "`abc123`")
  assert string.contains(passed, "`d1g3st`")
  assert string.contains(passed, "`e12`")
  let overridden =
    project_publish.body(project_publish.Facts(
      "t-c1",
      "abc123",
      project_publish.Overridden("owner"),
    ))
  assert string.contains(overridden, "published past the check by owner")
}

pub fn the_owner_and_name_come_from_a_github_url_test() {
  let accepted = [
    #("https://github.com/o/r", #("o", "r")),
    #("https://github.com/o/r.git", #("o", "r")),
    #("https://github.com/o/r/", #("o", "r")),
    #("git@github.com:o/r", #("o", "r")),
    #("git@github.com:o/r.git", #("o", "r")),
    #("ssh://git@github.com/o/r", #("o", "r")),
    #("ssh://git@github.com/o/r.git", #("o", "r")),
    #("ssh://git@github.com/o/r/", #("o", "r")),
    #("HTTPS://GitHub.COM/o/r.git", #("o", "r")),
    #("git@GITHUB.com:Own-er/na_me.js.git", #("Own-er", "na_me.js")),
    #("  https://github.com/o/r.git\n", #("o", "r")),
  ]
  list.each(accepted, fn(each) {
    assert project_publish.repository_of(each.0) == Ok(each.1)
  })
}

// Each of these used to be read as a GitHub repository, or could be made to
// name one the origin does not. None of them names a GitHub repository.
pub fn a_url_that_is_not_github_names_no_repository_test() {
  let refused = [
    // A path on this machine whose last two parts look like an owner and name.
    "/x/pd2/remoteA.git",
    "/tmp/x/remote.git",
    "../pd2/remoteA",
    "file:///x/pd2/remoteA.git",
    "pd2/remoteA",
    // A path that carries the host in a directory name.
    "/srv/github.com/o/r.git",
    "/srv/https://github.com/o/r.git",
    // Other hosts, and a host that only starts like GitHub's.
    "https://gitlab.com/o/r.git",
    "https://github.com.evil.test/o/r.git",
    "https://evilgithub.com/o/r.git",
    "git@gitlab.com:o/r.git",
    "ssh://git@github.com.evil.test/o/r.git",
    // Spellings outside the three: a plain http address, a user, a port.
    "http://github.com/o/r.git",
    "https://user@github.com/o/r.git",
    "https://github.com:443/o/r.git",
    "ssh://git@github.com:22/o/r.git",
    "git@github.com/o/r.git",
    // Extra or missing parts, and names that are not plain.
    "https://github.com/o",
    "https://github.com/o/r/extra",
    "https://github.com//r",
    "https://github.com/o/..",
    "https://github.com/o/r;rm",
    "https://github.com/o/r?x=1",
    "https://github.com/o/r#frag",
    "https://github.com/o/.git",
    "",
    "r",
  ]
  list.each(refused, fn(each) {
    assert project_publish.repository_of(each) == Error(Nil)
  })
}

pub fn a_local_origin_is_unavailable_and_asks_nothing_of_gh_test() {
  let rig = rig("local")
  let local = project_publish.Repository(..rig.repository, url: rig.remote)
  let assert Error(Unavailable(why)) =
    project_publish.publish(
      rig.tools,
      local,
      "project/t-a",
      rig.commit,
      "t",
      "b",
    )
  assert string.contains(why, "no GitHub owner and name")
  assert calls(rig) == []
  assert !bootstrap.path_exists(rig.remote <> "/refs/heads/project")
}
