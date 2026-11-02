//// The repositories of one project, and the line between the ones a worker
//// may write and the ones only the host may (protocol-change/106, "Done means
//// verified", and the addendum on clone isolation).
////
//// A worker is an ordinary session, and a session's jail lets its model write
//// its workspace. If the workspace were a linked worktree of the owner's
//// checkout, the jail would also have to let it write the checkout's `.git`,
//// because that is where a linked worktree keeps its index, its refs and its
//// objects. A worker fed hostile text could then plant a hook or a
//// `core.fsmonitor` setting that the owner's next Git command runs outside any
//// jail, or rewrite the remote that the host's push trusts. So a worker never
//// has the owner's repository as its Git directory. It has a clone of its own,
//// and the host reads what the clone holds only through a repository the
//// worker cannot reach.
////
//// ## The three kinds of repository
////
//// - **The owner's checkout** is read by the host and written by no project
////   code. The host fetches its `HEAD` into the host repository, clones from
////   it, and reads one remote URL from it when the project is created.
//// - **A ticket's clone**, `<state>/projects/<id>/tickets/<ticket>-<seq>`, is
////   the worker's workspace. It is made by `git clone --no-hardlinks`, which
////   copies every object, so no write the worker makes can reach the source.
////   Its `origin` remote is removed, so it names nothing writable of the
////   owner's. Its `.git` is a real directory inside the workspace, so the
////   session's policy adds no writable root for it. Everything in it is the
////   worker's: its configuration, its hooks and its refs.
//// - **The host repository**, `<state>/projects/<id>/host.git`, is bare and is
////   written only by host code. It is in no session's writable roots, and the
////   session policy masks it (`workspace_policy.protecting_projects`). Every
////   diff, check and push reads this repository and none reads a clone.
////
//// ## Flow
////
//// `ensure_host` → `clone` → `intake` → `check_tree` → `release`
////
//// 1. `ensure_host` makes the host repository and pins the owner's push URL.
//// 2. `clone` makes a worker's workspace from the owner's checkout.
//// 3. `intake` takes the commit a worker's branch is at into the host
////    repository, and reads the paths it changed there.
//// 4. `check_tree` cuts a fresh repository from the host repository at a
////    commit, for the project's check to run in.
//// 5. `release` removes a clone whose work the host repository already holds.
////
//// ## Reading a hostile repository
////
//// Every Git command here runs in the sandbox (`worktrees.run_git`), with the
//// hostile repository readable and one directory writable. The one that reads
//// a clone is a fetch into the host repository, which can write the host
//// repository and nothing else, with `transfer.fsckObjects` on so that an
//// object whose shape Git rejects is refused. The fetch names the commit the
//// host just read from the clone, and the host then checks that the id it
//// holds is that commit's id. The environment disables replacement objects, so
//// a `refs/replace` entry in a clone changes nothing the host sees.

import client/worktree_git
import client/worktrees.{type Closed, type Worktrees}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile

/// Where one project's repositories are.
pub type Layout {
  Layout(
    /// The daemon's state root.
    state_root: String,
    /// The project's id.
    project: String,
    /// The owner's checkout, which the host reads and never writes.
    owner: String,
  )
}

/// What taking a worker's commit into the host repository came to.
pub type Intake {
  /// The commit is in the host repository, verified, and these are the paths
  /// it changed against the project's base. They are data, never a command.
  Accepted(
    /// The commit, as the host repository holds it.
    commit: String,
    /// The paths the commit changed, as Git names them.
    changed: List(String),
  )

  /// The host repository refused the commit, or what it holds is not what the
  /// clone said. A person is told why; nothing about the commit is trusted.
  Declined(
    /// The commit the clone's branch named.
    commit: String,
    /// The host's words for the refusal, cut to the wire's limit.
    why: String,
  )
}

/// The most refs of a clone that a release will look at before it keeps the
/// clone for a person. A worker can make as many as it likes.
pub const max_refs_checked = 64

/// The file, inside the host repository, that holds the pinned push URL. It is
/// inside so that the one mask over the repository covers it.
pub const origin_file_name = "loom-origin-url"

/// The project's own directory under the state root.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.project_directory(project_repo.Layout("/s", "p-1", "/repo"))
///   == "/s/projects/p-1"
/// ```
pub fn project_directory(layout: Layout) -> String {
  layout.state_root <> "/projects/" <> layout.project
}

/// The host repository: bare, written only by host code.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.host_path(project_repo.Layout("/s", "p-1", "/repo"))
///   == "/s/projects/p-1/host.git"
/// ```
pub fn host_path(layout: Layout) -> String {
  project_directory(layout) <> "/host.git"
}

/// The directory a project's clones are made in.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.tickets_path(project_repo.Layout("/s", "p-1", "/repo"))
///   == "/s/projects/p-1/tickets"
/// ```
pub fn tickets_path(layout: Layout) -> String {
  project_directory(layout) <> "/tickets"
}

/// Whether a path is a clone a project made for a worker: a directory under a
/// project's `tickets` directory beneath a state root's `projects`. The host
/// makes it for one assignment, so a list of folders to start a session in
/// leaves it out.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.is_clone_path("/s/projects/p-1/tickets/t-a-1")
/// assert !project_repo.is_clone_path("/src/loom")
/// ```
pub fn is_clone_path(path: String) -> Bool {
  string.contains(path, "/projects/p-") && string.contains(path, "/tickets/")
}

/// The workspace of one assignment's worker: the clone `name` names.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.clone_path(project_repo.Layout("/s", "p-1", "/repo"), "t-a-1")
///   == "/s/projects/p-1/tickets/t-a-1"
/// ```
pub fn clone_path(layout: Layout, name: String) -> String {
  tickets_path(layout) <> "/" <> name
}

/// The directory the project's check trees are cut in.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.checks_path(project_repo.Layout("/s", "p-1", "/repo"))
///   == "/s/projects/p-1/checks"
/// ```
pub fn checks_path(layout: Layout) -> String {
  project_directory(layout) <> "/checks"
}

/// The tree a check runs in: the ticket and the first twelve digits of the
/// commit. The ticket id is already a safe path component.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.check_tree_path(project_repo.Layout("/s", "p-1", "/repo"), "t-a", "0123456789abcdef")
///   == "/s/projects/p-1/checks/chk-t-a-0123456789ab"
/// ```
pub fn check_tree_path(
  layout: Layout,
  ticket: String,
  commit: String,
) -> String {
  checks_path(layout) <> "/chk-" <> ticket <> "-" <> string.slice(commit, 0, 12)
}

/// The ref under which the host repository keeps a commit taken in for a
/// ticket. The commit is in the name so that a later commit of the same ticket
/// does not unpin an earlier one that was checked or published.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.ticket_ref("t-a", "abc1234") == "refs/tickets/t-a/abc1234"
/// ```
pub fn ticket_ref(ticket: String, commit: String) -> String {
  "refs/tickets/" <> ticket <> "/" <> commit
}

/// A commit name Git printed: seven to sixty-four lower-case hexadecimal
/// digits. Anything else never reaches an argument list.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.commit_name("abc1234") == Ok(Nil)
/// assert project_repo.commit_name("--upload-pack=x") == Error("not a commit name")
/// ```
pub fn commit_name(text: String) -> Result(Nil, String) {
  let size = string.length(text)
  let hex =
    list.all(string.to_graphemes(text), fn(each) {
      string.contains("0123456789abcdef", each)
    })

  // Seven digits is the shortest abbreviation Git prints; sixty-four is the
  // longest object name.
  case size >= 7 && size <= 64 && hex {
    True -> Ok(Nil)
    False -> Error("not a commit name")
  }
}

/// Whether a remote URL is one the host will push to. It must be a single
/// printable line that does not begin with a dash, so it cannot be read as an
/// option, and it must not use a transport helper such as `ext::` or `fd::`,
/// which run a program Git is told to start.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.acceptable_url("git@github.com:o/r.git")
/// assert !project_repo.acceptable_url("ext::sh -c 'touch /tmp/x'")
/// assert !project_repo.acceptable_url("--upload-pack=x")
/// ```
pub fn acceptable_url(url: String) -> Bool {
  let printable =
    list.all(string.to_utf_codepoints(url), fn(point) {
      let code = string.utf_codepoint_to_int(point)
      code >= 0x20 && code != 0x7f
    })

  // A transport helper is a scheme before a double colon. A double colon after
  // a slash is part of a path, such as an address in square brackets.
  let helper = case string.split_once(url, "::") {
    Ok(#(scheme, _)) -> !string.contains(scheme, "/")
    Error(Nil) -> False
  }

  url != "" && printable && !string.starts_with(url, "-") && !helper
}

/// The URL pinned for the project's pushes, or `Error(Nil)` when the owner's
/// checkout had no usable `origin` when the project was created.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.pinned_url(layout)
/// ```
pub fn pinned_url(layout: Layout) -> Result(String, Nil) {
  simplifile.read(host_path(layout) <> "/" <> origin_file_name)
  |> result.replace_error(Nil)
  |> result.map(string.trim)
  |> result.try(fn(url) {
    case acceptable_url(url) {
      True -> Ok(url)
      False -> Error(Nil)
    }
  })
}

/// Whether a clone's `.git` is a real directory inside it, and not a file or
/// a link that names a Git directory elsewhere. A session's policy widens its
/// writable roots to a Git directory that a `.git` file names, so a worker
/// whose clone had been turned into such a file would, at its next start, be
/// handed the owner's repository. The daemon refuses to build a worker
/// session on a clone that fails this.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.sound_clone("/state/projects/p-1/tickets/t-a-1")
/// ```
pub fn sound_clone(path: String) -> Result(Nil, String) {
  case simplifile.link_info(path <> "/.git") {
    Ok(info) ->
      case simplifile.file_info_type(info) {
        simplifile.Directory -> Ok(Nil)
        simplifile.File | simplifile.Symlink | simplifile.Other ->
          Error(
            "the worker's .git is not a directory, so it could name a Git"
            <> " directory outside the clone",
          )
      }
    Error(_) -> Error("the worker's clone has no .git directory")
  }
}

/// Makes the host repository if it is not there, and pins the owner's push URL
/// if none is pinned. Both are idempotent, so the daemon runs this every time a
/// project's actor starts.
///
/// The URL is `origin`'s push URL in the owner's checkout, read once. Nothing
/// a worker writes can reach that checkout, so the value read when the project
/// is created is the owner's. A checkout with no `origin` pins nothing, and a
/// publish then says so.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.ensure_host(trees, layout)
/// ```
pub fn ensure_host(trees: Worktrees, layout: Layout) -> Result(Nil, String) {
  let host = host_path(layout)

  // A repository that has its `HEAD` is made; otherwise Git makes it, with no
  // template so that no sample hook is copied in.
  use Nil <- result.try(case bootstrap.path_exists(host <> "/HEAD") {
    True -> Ok(Nil)
    False -> create_host(trees, layout)
  })

  pin_origin(trees, layout)
}

/// Makes the bare repository, with no template so that no sample hook is
/// copied in. The project's directory is made first if it is not there.
fn create_host(trees: Worktrees, layout: Layout) -> Result(Nil, String) {
  let directory = project_directory(layout)
  use Nil <- result.try(bootstrap.ensure_private_directory(directory))
  use _made <- result.map(
    change(trees, directory, [directory], [
      "init", "--quiet", "--bare", "--template=", "--", "host.git",
    ]),
  )
  Nil
}

/// Writes the owner's push URL into the host repository, once. A pin that is
/// there is never replaced, and an owner with no usable `origin` pins nothing.
fn pin_origin(trees: Worktrees, layout: Layout) -> Result(Nil, String) {
  let file = host_path(layout) <> "/" <> origin_file_name

  // A pinned URL is never replaced. The pin is the owner's word at creation.
  case bootstrap.path_exists(file) {
    True -> Ok(Nil)
    False ->
      case
        query(trees, layout.owner, ["remote", "get-url", "--push", "origin"])
      {
        // No remote named origin: nothing to pin, and a publish says so.
        Error(_) -> Ok(Nil)
        Ok(text) -> {
          let url = string.trim(text)

          // A URL the host would not push to is left unpinned for the same
          // reason a missing one is.
          case acceptable_url(url) {
            True ->
              simplifile.write(file, url <> "\n")
              |> result.map_error(fn(error) {
                "the origin URL was not pinned: "
                <> simplifile.describe_error(error)
              })
            False -> Ok(Nil)
          }
        }
      }
  }
}

/// Makes the clone that is an assignment's workspace, or adopts the one an
/// earlier start made, and answers its path.
///
/// The clone is made beside its final name and moved into place, so the name
/// exists only for a clone that is whole. `--no-hardlinks` makes the object
/// copy a real one: hard links would let a write through the clone's object
/// files change the owner's. The `origin` remote is removed, and the branch
/// `loom/<name>` is made at the commit the owner's checkout was on.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.clone(trees, layout, "t-a-1")
/// ```
pub fn clone(
  trees: Worktrees,
  layout: Layout,
  name: String,
) -> Result(String, String) {
  let tickets = tickets_path(layout)
  let final = clone_path(layout, name)
  use Nil <- result.try(bootstrap.ensure_private_directory(tickets))

  // A clone on disk is adopted if it is sound and refused if it is not. It is
  // never replaced, because it may hold the worker's commits.
  case bootstrap.path_exists(final) {
    True -> result.replace(sound_clone(final), final)
    False -> make_clone(trees, layout, name, tickets, final)
  }
}

/// Makes a clone beside its final name and moves it into place. A failure
/// removes the partial directory and leaves nothing under the final name.
fn make_clone(
  trees: Worktrees,
  layout: Layout,
  name: String,
  tickets: String,
  final: String,
) -> Result(String, String) {
  let making = tickets <> "/." <> name <> ".making"
  use Nil <- result.try(remove(making))
  let made = {
    use _cloned <- result.try(
      change(trees, tickets, [tickets], [
        "clone", "--quiet", "--no-hardlinks", "--no-tags", "--", layout.owner,
        making,
      ]),
    )

    // The clone must name nothing of the owner's that it could write.
    use _unlinked <- result.try(
      change(trees, making, [making], ["remote", "remove", "origin"]),
    )
    change(trees, making, [making], [
      "checkout",
      "--quiet",
      "-b",
      worktrees.branch_of(name),
    ])
  }

  // A failed clone leaves nothing under the final name, and its partial
  // directory goes.
  case made {
    Error(why) -> {
      let _removed = remove(making)
      Error(why)
    }
    Ok(_) ->
      simplifile.rename(making, final)
      |> result.replace(final)
      |> result.map_error(fn(error) {
        "the clone was not moved into place: "
        <> simplifile.describe_error(error)
      })
  }
}

/// Takes the commit an assignment's branch is at into the host repository, and
/// reads the paths it changed there.
///
/// The commit's id is read from the clone first. The fetch then names exactly
/// that id, runs read-only against the clone and writable only in the host
/// repository, and checks every object's shape. The host then asks its own
/// repository for the commit and requires the same id. A refusal at any step is
/// `Declined`: nothing about the commit is trusted, and a person is told why.
/// An `Error` is a failure that may pass, such as a clone whose `HEAD` cannot
/// be read, and the caller tries again.
///
/// The diff is `base...commit` in the host repository, where `base` is the
/// owner's `HEAD`, fetched just now. The commits are the ones the branch has
/// that the base has not, so a base that has moved on since the clone was cut
/// does not count its own new files.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.intake(trees, layout, "t-a", "t-a-1")
/// ```
pub fn intake(
  trees: Worktrees,
  layout: Layout,
  ticket: String,
  name: String,
) -> Result(Intake, String) {
  let clone = clone_path(layout, name)
  use head <- result.try(clone_head(trees, clone))
  use base <- result.map(refresh_base(trees, layout))
  let taken = {
    use Nil <- result.try(fetch_commit(trees, layout, ticket, clone, head))
    use Nil <- result.try(confirm_commit(trees, layout, ticket, head))
    changed_paths(trees, layout, base, head)
  }

  // Any refusal past this point is the host declining the commit.
  case taken {
    Ok(changed) -> Accepted(commit: head, changed:)
    Error(why) -> Declined(commit: head, why:)
  }
}

/// The commit a clone's `HEAD` names, as a validated object name.
fn clone_head(trees: Worktrees, clone: String) -> Result(String, String) {
  use text <- result.try(
    query(trees, clone, ["rev-parse", "--verify", "HEAD^{commit}"]),
  )
  let commit = string.trim(text)
  use Nil <- result.map(commit_name(commit))
  commit
}

/// Fetches the owner's `HEAD` into the host repository as `refs/base/head` and
/// answers its id. The owner's checkout is read and not written.
fn refresh_base(trees: Worktrees, layout: Layout) -> Result(String, String) {
  let host = host_path(layout)
  use _fetched <- result.try(
    change(trees, host, [host], [
      "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--",
      layout.owner, "+HEAD:refs/base/head",
    ]),
  )
  use text <- result.try(
    query(trees, host, ["rev-parse", "--verify", "refs/base/head^{commit}"]),
  )
  let base = string.trim(text)
  use Nil <- result.map(commit_name(base))
  base
}

/// The fetch that reads a hostile repository.
fn fetch_commit(
  trees: Worktrees,
  layout: Layout,
  ticket: String,
  clone: String,
  commit: String,
) -> Result(Nil, String) {
  let host = host_path(layout)
  use _fetched <- result.map(
    change(trees, host, [host], [
      "-c",
      "transfer.fsckObjects=true",
      "-c",
      "fetch.fsckObjects=true",
      "fetch",
      "--quiet",
      "--no-tags",
      "--no-write-fetch-head",
      "--",
      clone,
      commit <> ":" <> ticket_ref(ticket, commit),
    ]),
  )
  Nil
}

/// Requires the host repository to hold the commit the clone named, under the
/// ref the fetch wrote, and no other.
fn confirm_commit(
  trees: Worktrees,
  layout: Layout,
  ticket: String,
  commit: String,
) -> Result(Nil, String) {
  use text <- result.try(
    query(trees, host_path(layout), [
      "rev-parse",
      "--verify",
      ticket_ref(ticket, commit) <> "^{commit}",
    ]),
  )

  // The id the host repository holds must be the id the clone named.
  case string.trim(text) == commit {
    True -> Ok(Nil)
    False ->
      Error("the host repository holds a different commit than the clone named")
  }
}

/// The paths the commit changed against the base, cut at the NUL bytes Git
/// puts between them and never at a newline or a space.
fn changed_paths(
  trees: Worktrees,
  layout: Layout,
  base: String,
  commit: String,
) -> Result(List(String), String) {
  use names <- result.map(
    query(trees, host_path(layout), [
      "diff",
      "--name-only",
      "-z",
      "--no-renames",
      "--no-ext-diff",
      base <> "..." <> commit,
      "--",
    ]),
  )
  string.split(names, "\u{0}") |> list.filter(fn(path) { path != "" })
}

/// Cuts a fresh repository from the host repository at a commit, for the
/// project's check to run in, and answers its path. The tree is made by
/// fetching the commit from the host repository into a new repository, so it
/// shares nothing with the host repository and a clone is not involved. A
/// commit the host repository does not hold fails here.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.check_tree(trees, layout, "t-a", commit)
/// ```
pub fn check_tree(
  trees: Worktrees,
  layout: Layout,
  ticket: String,
  commit: String,
) -> Result(String, String) {
  use Nil <- result.try(commit_name(commit))
  let checks = checks_path(layout)
  let path = check_tree_path(layout, ticket, commit)
  use Nil <- result.try(bootstrap.ensure_private_directory(checks))
  use Nil <- result.try(remove(path))
  let cut = {
    use _made <- result.try(
      change(trees, checks, [checks], [
        "init", "--quiet", "--template=", "--", path,
      ]),
    )
    use _fetched <- result.try(
      change(trees, path, [path], [
        "fetch",
        "--quiet",
        "--no-tags",
        "--no-write-fetch-head",
        "--",
        host_path(layout),
        commit,
      ]),
    )
    change(trees, path, [path], ["checkout", "--quiet", "--detach", commit])
  }

  // A tree that was not cut whole goes, so the next attempt starts clean.
  case cut {
    Ok(_) -> Ok(path)
    Error(why) -> {
      let _removed = remove(path)
      Error(why)
    }
  }
}

/// Removes a check tree whatever the check left in it. The host made the tree
/// for one job and has no use for what the job produced.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.discard_check_tree(path)
/// ```
pub fn discard_check_tree(path: String) -> Nil {
  let _removed = remove(path)
  Nil
}

/// Settles an assignment's clone when its ticket has ended. The clone goes
/// unless it holds work the host repository does not: changes in its working
/// tree, or any ref or `HEAD` naming an object the host repository lacks.
///
/// Every ref is compared, not the branch the clone says it is on. A worker
/// controls which branch `HEAD` names, and a clone that looked clean from its
/// own `HEAD` could hold commits on another. The owner's `HEAD` is fetched
/// first, so the branch the clone started from counts as taken in. A clone
/// that cannot be examined is kept, and so is one with more refs than
/// `max_refs_checked`.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.release(trees, layout, "t-a-1")
/// ```
pub fn release(trees: Worktrees, layout: Layout, name: String) -> Closed {
  let clone = clone_path(layout, name)

  // No clone has nothing to settle.
  case bootstrap.path_exists(clone) {
    False -> worktrees.Removed
    True ->
      case unrecorded_work(trees, layout, clone) {
        Error(why) -> worktrees.Kept("it could not be examined: " <> why)
        Ok(held) -> settle_clone(clone, held)
      }
  }
}

/// Removes a clone that held nothing the host lacks, or keeps it for the
/// reason given. A removal that fails keeps the clone too.
fn settle_clone(clone: String, held: Option(String)) -> Closed {
  case held {
    Some(reason) -> worktrees.Kept(reason)
    None ->
      case simplifile.delete(clone) {
        Ok(Nil) -> worktrees.Removed
        Error(error) ->
          worktrees.Kept(
            "it could not be removed: " <> simplifile.describe_error(error),
          )
      }
  }
}

/// What the clone holds that deleting it would lose, as the reason to keep it,
/// or `None` when it holds nothing.
fn unrecorded_work(
  trees: Worktrees,
  layout: Layout,
  clone: String,
) -> Result(Option(String), String) {
  use status <- result.try(
    query(trees, clone, [
      "-c", "core.fsmonitor=false", "status", "--porcelain=v1",
      "--untracked-files=normal", "--", ".", ":(exclude).codemode",
    ]),
  )

  // A working tree with changes is kept as it is. A clean one is compared with
  // the host repository.
  case string.trim(status) {
    "" -> {
      use _base <- result.try(refresh_base(trees, layout))
      use named <- result.try(named_objects(trees, clone))
      missing_from_host(trees, layout, named)
    }
    _changes -> Ok(Some("it holds changes"))
  }
}

/// The object names every ref of the clone and its `HEAD` point at.
fn named_objects(
  trees: Worktrees,
  clone: String,
) -> Result(List(String), String) {
  use refs <- result.map(
    query(trees, clone, ["for-each-ref", "--format=%(objectname)"]),
  )

  // A detached `HEAD` is a name no ref holds, so it is read separately. An
  // unborn one has none, and that is not a failure.
  let head =
    query(trees, clone, ["rev-parse", "--verify", "--quiet", "HEAD"])
    |> result.unwrap("")
  [head, ..string.split(refs, "\n")]
  |> list.map(string.trim)
  |> list.filter(fn(name) { name != "" })
  |> list.unique
}

/// Compares object names with the host repository, and keeps the clone when
/// any is missing there or is not a name Git could have printed.
fn missing_from_host(
  trees: Worktrees,
  layout: Layout,
  named: List(String),
) -> Result(Option(String), String) {
  // More names than the cap are kept for a person, whatever they are.
  case list.length(named) > max_refs_checked {
    True -> Ok(Some("it has too many refs to compare with the host repository"))
    False -> {
      let missing =
        list.count(named, fn(name) {
          case commit_name(name) {
            Error(_) -> True
            Ok(Nil) ->
              result.is_error(
                query(trees, host_path(layout), ["cat-file", "-e", name]),
              )
          }
        })

      // Any object the host repository lacks is work that deleting would lose.
      case missing {
        0 -> Ok(None)
        _ ->
          Ok(Some(
            "it holds "
            <> int.to_string(missing)
            <> " object(s) the host repository has not taken in",
          ))
      }
    }
  }
}

// --- running Git -------------------------------------------------------------

/// A read-only Git command, in the sandbox, answering its standard output.
fn query(
  trees: Worktrees,
  directory: String,
  arguments: List(String),
) -> Result(String, String) {
  worktrees.read(trees, directory, arguments)
}

/// A Git command that writes the directories named and nothing else.
fn change(
  trees: Worktrees,
  directory: String,
  writable: List(String),
  arguments: List(String),
) -> Result(String, String) {
  worktrees.run_git(
    trees,
    directory,
    writable,
    arguments,
    worktree_git.checkout_within_ms,
  )
}

/// Removes a path the host made, if it is there. The host's own process does
/// it, and Erlang's removal of a tree does not follow a link out of it.
fn remove(path: String) -> Result(Nil, String) {
  case simplifile.delete(path) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(
        "could not remove " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}
