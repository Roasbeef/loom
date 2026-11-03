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
////   owner's. A clone for a resumed ticket is instead a new repository that
////   fetches the ticket's head from the host repository, and it has no remote
////   to remove. Its `.git` is a real directory inside the workspace, so the
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
//// 2. `clone` makes a worker's workspace, from the owner's checkout or, for a
////    ticket whose earlier assignment left a commit, from that commit in the
////    host repository.
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

import client/internal/ffi_os
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

/// Where a new clone's work begins.
pub type Start {
  /// At the commit the owner's checkout is on now. A ticket that has not
  /// produced a commit starts here.
  FromOwner

  /// At a commit the host repository holds: the head the host last read from
  /// an earlier assignment of the same ticket. The new worker then sees that
  /// work, and a commit it makes is a descendant of the branch that was pushed.
  FromCommit(
    /// The commit, as the host repository names it. The clone resolves it
    /// again before it is part of any command.
    commit: String,
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

  /// The commit is in the host repository, but there is nothing for a check
  /// to vouch for: the branch made no commit of its own, or the clone holds
  /// changes that no commit has. The host reads the clone's `HEAD` and nothing
  /// else, so a check at that commit would pass work that is not the worker's
  /// work. A person is told which.
  Withheld(
    /// The commit, as the host repository holds it.
    commit: String,
    /// Why no check will run for it.
    reason: Withholding,
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

/// Why a commit in the host repository is not put to the check.
pub type Withholding {
  /// The branch has no commit beyond the base it was cut from, so the head is
  /// the base and a passing check would say nothing about the worker.
  NoCommits

  /// The clone has changes that no commit holds. The host reads only `HEAD`,
  /// so it never sees them, and a person decides what they are.
  UncommittedChanges
}

/// Where a new tree gets its files.
pub type Seed {
  /// From nothing but Git: a clone of the owner's checkout, or an empty
  /// repository that fetches one commit from the host repository. A project
  /// with no `setup` is always cold, and behaves as it did before templates.
  Cold

  /// From a copy of the project's template, moved to the commit it needs. The
  /// copy carries every ignored file the template holds, so the caches
  /// `setup` filled are there for the worker and the offline check.
  Warm(
    /// How the copy is made.
    copier: Copier,
  )
}

/// How a template is copied: with `git-cow` when the program is known, and
/// by a plain recursive copy otherwise.
pub type Copier {
  Copier(
    /// The `git-cow` binary, or `None` when none was found.
    program: Option(String),
    /// Told how each copy was made and how many milliseconds it took, so the
    /// daemon can log both.
    report: fn(Method, Int) -> Nil,
  )
}

/// How one copy of the template was made.
pub type Method {
  /// `git-cow copy`, which shares disk blocks where the file system allows.
  CopyOnWrite(
    /// The binary that ran.
    program: String,
  )

  /// A plain recursive copy: slower, and it behaves the same.
  PlainCopy(
    /// Why `git-cow` was not used.
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

/// The project's template: a normal repository, made by the host from the
/// recorded base commit, in which `setup` ran. Every worker clone and check
/// tree is a copy of it. Only host code writes it, and the session and check
/// policies mask it like `host.git`.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.template_path(project_repo.Layout("/s", "p-1", "/repo"))
///   == "/s/projects/p-1/template"
/// ```
pub fn template_path(layout: Layout) -> String {
  project_directory(layout) <> "/template"
}

/// The directory a new template is built in. It becomes `template` by a rename
/// only after `setup` and the base check passed, so a partial template never
/// has the template's name.
///
/// ## Examples
///
/// ```gleam
/// assert project_repo.template_making_path(project_repo.Layout("/s", "p-1", "/repo"))
///   == "/s/projects/p-1/.template.making"
/// ```
pub fn template_making_path(layout: Layout) -> String {
  project_directory(layout) <> "/.template.making"
}

// Where the template being replaced waits during a swap.
fn template_old_path(layout: Layout) -> String {
  project_directory(layout) <> "/.template.old"
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
/// exists only for a clone that is whole. The branch `loom/<name>` is made at
/// the commit `start` names. In both cases the clone ends with no remote at
/// all, and every object in it is a copy: a hard link would let a write through
/// the clone's object files change the repository it came from.
///
/// From the owner (`FromOwner`) the clone is `git clone --no-hardlinks` of the
/// owner's checkout with the `origin` remote removed.
///
/// From a commit (`FromCommit`) the clone is a new repository that fetches
/// that one commit from the host repository by its path. A fetch by path
/// writes no remote, so there is nothing to remove and nothing in the clone's
/// configuration that names the host repository. The host repository is the
/// source because it is the only place the earlier assignment's commit is
/// known to be: the host took the commit in before it recorded it as the
/// ticket's head. The commands run with hooks and `core.fsmonitor` switched
/// off on the command line, though a repository made with no template has
/// neither.
///
/// A commit that the owner's checkout already contains starts from the owner's
/// checkout instead. That is the ticket whose pull request merged and whose
/// owner has pulled: the work is in the base, and a clone cut from the older
/// commit would start behind it and carry the merged history into the next
/// pull request. A merged branch the owner has not pulled is not contained
/// and starts from its own commit, which is all the host can know about it.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.clone(trees, layout, "t-a-1", project_repo.FromOwner)
/// // project_repo.clone(trees, layout, "t-a-2", project_repo.FromCommit(head))
/// ```
pub fn clone(
  trees: Worktrees,
  layout: Layout,
  name: String,
  start: Start,
) -> Result(String, String) {
  clone_from(trees, layout, name, start, Cold)
}

/// Makes the clone like `clone`, from the seed given. A `Warm` seed copies the
/// project's template into place, fetches the commit `start` names from the
/// host repository and branches `loom/<name>` there, so the worker begins with
/// the template's ignored files and the same history a cold clone has. The
/// copy's `.git/config` holds the keys `git init` wrote and nothing the owner
/// has: no remote, no URL, no credential helper, because the template was made
/// by fetching one commit from the host repository by its path.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.clone_from(trees, layout, "t-a-1", project_repo.FromOwner, project_repo.Cold)
/// ```
pub fn clone_from(
  trees: Worktrees,
  layout: Layout,
  name: String,
  start: Start,
  seed: Seed,
) -> Result(String, String) {
  let tickets = tickets_path(layout)
  let final = clone_path(layout, name)
  use Nil <- result.try(bootstrap.ensure_private_directory(tickets))

  // A clone on disk is adopted if it is sound and refused if it is not. It is
  // never replaced, because it may hold the worker's commits, and the start is
  // not even looked at: the adopted clone is already where it began.
  case bootstrap.path_exists(final) {
    True -> result.replace(sound_clone(final), final)
    False -> {
      use settled <- result.try(settle_start(trees, layout, start))
      make_clone(trees, layout, name, tickets, final, settled, seed)
    }
  }
}

/// Decides where a new clone begins. A commit is read back from the host
/// repository, which both proves the host holds it and replaces a short name
/// with the full one, and then compared with the owner's `HEAD`, fetched just
/// now. A commit the owner's `HEAD` already contains is `FromOwner`.
fn settle_start(
  trees: Worktrees,
  layout: Layout,
  start: Start,
) -> Result(Start, String) {
  // The owner's start needs no reading, because it is the clone's own source.
  // A commit is proved held and then compared.
  case start {
    FromOwner -> Ok(FromOwner)
    FromCommit(commit:) -> {
      use Nil <- result.try(commit_name(commit))
      use text <- result.try(
        query(trees, host_path(layout), [
          "rev-parse",
          "--verify",
          commit <> "^{commit}",
        ]),
      )
      let held = string.trim(text)
      use Nil <- result.try(commit_name(held))
      use base <- result.try(refresh_base(trees, layout))
      use ahead <- result.map(commits_ahead(trees, layout, base, held))

      // No commit beyond the owner's `HEAD` means the owner's `HEAD` has it.
      case ahead {
        0 -> FromOwner
        _ -> FromCommit(held)
      }
    }
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
  start: Start,
  seed: Seed,
) -> Result(String, String) {
  let making = tickets <> "/." <> name <> ".making"
  use Nil <- result.try(force_remove(trees, tickets, making))

  // The two starts differ only in where the objects come from. Both end with a
  // clone that has no remote and a branch of the worker's own. A warm seed
  // supplies the files and the starts differ only in the commit.
  let made = case seed, start {
    Warm(copier:), _ ->
      cut_from_template(trees, layout, name, tickets, making, start, copier)
    Cold, FromOwner -> cut_from_owner(trees, layout, name, tickets, making)
    Cold, FromCommit(commit:) ->
      cut_from_commit(trees, layout, name, tickets, making, commit)
  }

  // A failed clone leaves nothing under the final name, and its partial
  // directory goes.
  case made {
    Error(why) -> {
      let _removed = force_remove(trees, tickets, making)
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

/// Cuts a clone from the owner's checkout: a copy of every object, with the
/// `origin` remote removed and a branch of the worker's own at the commit the
/// owner's checkout is on.
fn cut_from_owner(
  trees: Worktrees,
  layout: Layout,
  name: String,
  tickets: String,
  making: String,
) -> Result(String, String) {
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

/// Cuts a clone that holds one commit of the host repository and a branch of
/// the worker's own at it. The repository is new and made with no template,
/// and the commit comes in by a fetch of the host repository's path, so the
/// clone has no remote, no alternates and no link to a file of the host's.
fn cut_from_commit(
  trees: Worktrees,
  layout: Layout,
  name: String,
  tickets: String,
  making: String,
  commit: String,
) -> Result(String, String) {
  use _made <- result.try(
    change(trees, tickets, [tickets], [
      "init", "--quiet", "--template=", "--", making,
    ]),
  )
  use _fetched <- result.try(change(
    trees,
    making,
    [making],
    unhooked([
      "fetch",
      "--quiet",
      "--no-tags",
      "--no-write-fetch-head",
      "--",
      host_path(layout),
      commit,
    ]),
  ))
  change(
    trees,
    making,
    [making],
    unhooked(["checkout", "--quiet", "-b", worktrees.branch_of(name), commit]),
  )
}

/// Cuts a clone from the template: a copy of it, then the commit the start
/// names fetched from the host repository by path, and a branch of the worker's
/// own checked out there. A checkout from the template's commit to the worker's
/// leaves every untracked and ignored file in place, which is the point.
///
/// A start from the owner's checkout begins at the owner's `HEAD` as the host
/// repository holds it now, which can be ahead of the template's commit by
/// whatever was merged since the last rebuild.
fn cut_from_template(
  trees: Worktrees,
  layout: Layout,
  name: String,
  tickets: String,
  making: String,
  start: Start,
  copier: Copier,
) -> Result(String, String) {
  // A start from the owner's checkout begins at the owner's head as the host
  // repository holds it now, and a start from a commit begins at that commit.
  use commit <- result.try(case start {
    FromOwner -> refresh_base(trees, layout)
    FromCommit(commit:) -> Ok(commit)
  })

  use Nil <- result.try(copy_template(trees, layout, tickets, making, copier))
  use _fetched <- result.try(fetch_into(trees, layout, making, commit))
  change(
    trees,
    making,
    [making],
    unhooked(["checkout", "--quiet", "-b", worktrees.branch_of(name), commit]),
  )
}

/// Fetches one commit of the host repository into a tree by the repository's
/// path, which writes no remote, no `FETCH_HEAD` and no tag.
fn fetch_into(
  trees: Worktrees,
  layout: Layout,
  tree: String,
  commit: String,
) -> Result(String, String) {
  change(
    trees,
    tree,
    [tree],
    unhooked([
      "fetch",
      "--quiet",
      "--no-tags",
      "--no-write-fetch-head",
      "--",
      host_path(layout),
      commit,
    ]),
  )
}

/// How long a copy of the template may take. A plain copy of a large template
/// is the slow case, and ten minutes is the bound a checkout gets.
const copy_within_ms = 600_000

/// Copies the template to `dest`, a name that does not exist yet in `parent`.
///
/// `git-cow copy` is tried first when a binary is known. It runs in the same
/// sandbox as every other Git call, writable only in `parent`, because the
/// template holds what repository scripts wrote and the host should read it no
/// less jailed than a worker's clone. Exit 2 is its refusal of the template
/// (a linked worktree, an alternates file, a symlink under `.git`, a socket),
/// and it is an error: the template is wrong and a plain copy would hide that.
/// Any other failure, and a missing binary, falls back to a plain recursive
/// copy, which makes the same tree more slowly. The copier is told which
/// method was used.
fn copy_template(
  trees: Worktrees,
  layout: Layout,
  parent: String,
  dest: String,
  copier: Copier,
) -> Result(Nil, String) {
  let template = template_path(layout)
  let started = ffi_os.system_time_ms()

  // A copier with a known program tries it first, and one without goes
  // straight to the plain copy.
  case copier.program {
    None ->
      plain_copy(
        trees,
        parent,
        template,
        dest,
        copier,
        "git-cow not found",
        started,
      )
    Some(program) ->
      case
        worktrees.run_program(
          trees,
          program,
          parent,
          [parent],
          ["copy", template, dest],
          copy_within_ms,
        )
      {
        Ok(output) if output.code == 0 -> {
          copier.report(CopyOnWrite(program), ffi_os.system_time_ms() - started)
          Ok(Nil)
        }
        Ok(output) if output.code == 2 ->
          Error(
            "git-cow refused the template: "
            <> worktree_git.printable(output.stderr, 512),
          )
        Ok(output) -> {
          let why =
            "git-cow exited "
            <> int.to_string(output.code)
            <> ": "
            <> worktree_git.printable(output.stderr, 256)
          plain_copy(trees, parent, template, dest, copier, why, started)
        }
        Error(why) ->
          plain_copy(trees, parent, template, dest, copier, why, started)
      }
  }
}

/// The fallback copy: `cp -RPp` in the sandbox. A destination a failed `git-cow`
/// left behind is removed first.
fn plain_copy(
  trees: Worktrees,
  parent: String,
  template: String,
  dest: String,
  copier: Copier,
  why: String,
  started: Int,
) -> Result(Nil, String) {
  use Nil <- result.try(force_remove(trees, parent, dest))
  use output <- result.try(worktrees.run_program(
    trees,
    "/bin/cp",
    parent,
    [parent],
    ["-RPp", template, dest],
    copy_within_ms,
  ))

  // A zero exit is a finished copy. Any other exit removes what it left.
  case output.code {
    0 -> {
      copier.report(PlainCopy(why), ffi_os.system_time_ms() - started)
      Ok(Nil)
    }
    code -> {
      let _removed = force_remove(trees, parent, dest)
      Error(
        "the template was not copied: cp exited "
        <> int.to_string(code)
        <> ": "
        <> worktree_git.printable(output.stderr, 512),
      )
    }
  }
}

/// Removes a tree the host made, including one a build left read-only. A Go
/// module cache is read-only by design, and an ordinary removal stops at its
/// first directory, so a failed removal makes the tree writable in the sandbox
/// and removes it again.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.force_remove(trees, "/s/projects/p-1", "/s/projects/p-1/.template.old")
/// ```
pub fn force_remove(
  trees: Worktrees,
  parent: String,
  path: String,
) -> Result(Nil, String) {
  // A removal that works is done. One that fails may be a read-only tree.
  case remove(path) {
    Ok(Nil) -> Ok(Nil)
    Error(first) -> {
      let writable =
        worktrees.run_program(
          trees,
          "/bin/chmod",
          parent,
          [path],
          ["-R", "u+w", path],
          copy_within_ms,
        )

      // If the tree could be made writable, the removal is tried again.
      case writable {
        Ok(_) -> remove(path)
        Error(_) -> Error(first)
      }
    }
  }
}

/// Fetches the owner's `HEAD` into the host repository and answers its id: the
/// commit a new template is built at, and the one a rebuild compares with.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.base_commit(trees, layout)
/// ```
pub fn base_commit(trees: Worktrees, layout: Layout) -> Result(String, String) {
  refresh_base(trees, layout)
}

/// Cuts the tree a template is built in, at a commit of the host repository:
/// a new repository that fetches the one commit by path and checks it out
/// detached. Whatever stood at the building name from an earlier, interrupted
/// build is removed first, so a crash leaves nothing that could be taken for a
/// finished template.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.cut_template_tree(trees, layout, commit)
/// ```
pub fn cut_template_tree(
  trees: Worktrees,
  layout: Layout,
  commit: String,
) -> Result(String, String) {
  use Nil <- result.try(commit_name(commit))
  let directory = project_directory(layout)
  let making = template_making_path(layout)
  use Nil <- result.try(bootstrap.ensure_private_directory(directory))
  use Nil <- result.try(force_remove(trees, directory, making))
  cut_detached(trees, directory, making, layout, commit)
  |> result.replace(making)
}

/// A swap that stopped between its two renames left the old template under its
/// waiting name and nothing under the template's. The old one is the last good
/// template, so it goes back. A build does this before it looks at anything
/// else.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.restore_interrupted_swap(layout)
/// ```
pub fn restore_interrupted_swap(layout: Layout) -> Result(Nil, String) {
  let template = template_path(layout)
  let old = template_old_path(layout)

  // Only a template that is missing beside a waiting old one needs the swap
  // undone.
  case bootstrap.path_exists(template), bootstrap.path_exists(old) {
    False, True ->
      simplifile.rename(old, template)
      |> result.map_error(fn(error) {
        "the interrupted swap was not undone: "
        <> simplifile.describe_error(error)
      })
    _, _ -> Ok(Nil)
  }
}

/// Makes `path` a repository holding `commit` of the host repository, checked
/// out detached. Check trees and template trees are cut this way.
fn cut_detached(
  trees: Worktrees,
  parent: String,
  path: String,
  layout: Layout,
  commit: String,
) -> Result(String, String) {
  use _made <- result.try(
    change(trees, parent, [parent], [
      "init", "--quiet", "--template=", "--", path,
    ]),
  )
  use _fetched <- result.try(fetch_into(trees, layout, path, commit))
  change(trees, path, [path], ["checkout", "--quiet", "--detach", commit])
}

/// Fails the template tree unless it can be copied as it stands: its `.git` is
/// a real directory, it has no alternates file and it registers no linked
/// worktree. They are the things `git-cow` refuses, and a plain copy would
/// carry them to every worker, so they are looked for before the swap.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.sound_template("/s/projects/p-1/.template.making")
/// ```
pub fn sound_template(path: String) -> Result(Nil, String) {
  use Nil <- result.try(sound_clone(path))

  // An alternates file and a worktrees directory are what a copy must not
  // carry to every worker.
  case
    bootstrap.path_exists(path <> "/.git/objects/info/alternates"),
    bootstrap.path_exists(path <> "/.git/worktrees")
  {
    False, False -> Ok(Nil)
    _, _ ->
      Error(
        "the template has an alternates file or a linked worktree, which a copy would carry to every worker",
      )
  }
}

/// Excludes every file the build left that Git would list as untracked, by
/// writing it to the tree's `.git/info/exclude`. The caches `setup` and the
/// base check wrote (`HOME` for one) are not in the repository and not
/// ignored by it, and a worker's clone would otherwise read as holding changes
/// no commit has. The write runs in the sandbox, because the tree is not the
/// host's to trust: a link at `.git/info` would otherwise lead the host's own
/// write elsewhere.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.exclude_untracked(trees, "/s/projects/p-1/.template.making")
/// ```
pub fn exclude_untracked(
  trees: Worktrees,
  tree: String,
) -> Result(Nil, String) {
  use listing <- result.try(
    query(trees, tree, [
      "-c", "core.fsmonitor=false", "status", "--porcelain=v1", "-z",
      "--untracked-files=normal",
    ]),
  )
  let patterns =
    string.split(listing, "\u{0}")
    |> list.filter_map(fn(entry) {
      case string.starts_with(entry, "?? ") {
        True -> Ok("/" <> escape_pattern(string.drop_start(entry, 3)))
        False -> Error(Nil)
      }
    })

  // A tree with nothing untracked needs no write.
  case patterns {
    [] -> Ok(Nil)
    _ ->
      worktrees.run_program(
        trees,
        "/bin/sh",
        tree,
        [tree],
        [
          "-c",
          "mkdir -p .git/info && for p; do printf '%s\\n' \"$p\" >> .git/info/exclude; done",
          "exclude",
          ..patterns
        ],
        copy_within_ms,
      )
      |> result.try(fn(output) {
        case output.code {
          0 -> Ok(Nil)
          code ->
            Error(
              "the untracked files were not excluded: sh exited "
              <> int.to_string(code),
            )
        }
      })
  }
}

/// The pattern for a path: the characters Git reads as pattern syntax are
/// escaped, and a trailing slash stays so a directory matches.
///
/// A file name is data, so a name with a star in it excludes that file and no
/// other.
fn escape_pattern(path: String) -> String {
  string.to_graphemes(path)
  |> list.map(fn(each) {
    case each {
      "\\" | "*" | "?" | "[" | "]" | "!" | "#" | " " -> "\\" <> each
      _ -> each
    }
  })
  |> string.concat
}

/// Puts a finished template in place. The tree built under the building name
/// replaces the template by two renames, the old one waiting under its own
/// name in between, and the old one is removed last. A crash between the
/// renames is undone by the next build (`restore_interrupted_swap`).
///
/// A copy that is reading the old template while this runs can fail, and the
/// ticket that asked for it tries again. That is rare, because a rebuild is
/// at most one swap every few minutes.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.swap_template(trees, layout)
/// ```
pub fn swap_template(trees: Worktrees, layout: Layout) -> Result(Nil, String) {
  let directory = project_directory(layout)
  let template = template_path(layout)
  let old = template_old_path(layout)
  let renamed = fn(from, to) {
    simplifile.rename(from, to)
    |> result.map_error(fn(error) {
      "the template was not swapped in: " <> simplifile.describe_error(error)
    })
  }
  use Nil <- result.try(force_remove(trees, directory, old))

  // The template being replaced waits under its own name. A first template
  // has nothing to move.
  use Nil <- result.try(case bootstrap.path_exists(template) {
    True -> renamed(template, old)
    False -> Ok(Nil)
  })

  use Nil <- result.try(renamed(template_making_path(layout), template))

  // The old template is gone for good. A removal that fails leaves it under its
  // waiting name, where the next swap removes it, and is not an error.
  let _removed = force_remove(trees, directory, old)
  Ok(Nil)
}

/// Removes a tree being built that is not going to be used, so a failed build
/// leaves no disk behind.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.discard_template_tree(trees, layout)
/// ```
pub fn discard_template_tree(trees: Worktrees, layout: Layout) -> Nil {
  let _removed =
    force_remove(trees, project_directory(layout), template_making_path(layout))
  Nil
}

/// A Git command line with hooks and the file system monitor switched off for
/// that command, whatever any configuration file says. They are the two
/// settings the host already overrides when it reads a clone.
fn unhooked(arguments: List(String)) -> List(String) {
  ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", ..arguments]
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
  use base <- result.try(refresh_base(trees, layout))
  let taken = {
    use Nil <- result.try(fetch_commit(trees, layout, ticket, clone, head))
    use Nil <- result.try(confirm_commit(trees, layout, ticket, head))
    use ahead <- result.try(commits_ahead(trees, layout, base, head))
    use dirty <- result.try(uncommitted(trees, clone))
    use changed <- result.map(changed_paths(trees, layout, base, head))
    #(ahead, dirty, changed)
  }

  // Any refusal past this point is the host declining the commit. A commit
  // that is accepted still goes to the check only when it is the worker's own
  // and the clone holds nothing else.
  Ok(case taken {
    Ok(#(0, _, _)) -> Withheld(commit: head, reason: NoCommits)
    Ok(#(_, Unsaved, _)) -> Withheld(commit: head, reason: UncommittedChanges)
    Ok(#(_, Saved, changed)) -> Accepted(commit: head, changed:)
    Error(why) -> Declined(commit: head, why:)
  })
}

/// Whether a clone holds changes that no commit has.
type Tree {
  Saved
  Unsaved
}

/// How many commits the branch has that the base lacks, which is the work the
/// worker did. It is read in the host repository, where both are held.
fn commits_ahead(
  trees: Worktrees,
  layout: Layout,
  base: String,
  commit: String,
) -> Result(Int, String) {
  use text <- result.try(
    query(trees, host_path(layout), [
      "rev-list",
      "--count",
      base <> ".." <> commit,
    ]),
  )
  int.parse(string.trim(text))
  |> result.replace_error("the host could not count the branch's commits")
}

/// Whether the clone has modified, staged or untracked files. The command is
/// read only and runs in the sandbox, and the clone's own `core.fsmonitor` is
/// overridden on the command line, because that setting makes `status` run a
/// program of the worker's choosing.
fn uncommitted(trees: Worktrees, clone: String) -> Result(Tree, String) {
  use text <- result.map(
    query(trees, clone, [
      "-c",
      "core.fsmonitor=false",
      "status",
      "--porcelain",
      "--untracked-files=normal",
    ]),
  )

  // Any line of status output is a change that no commit holds.
  case string.trim(text) {
    "" -> Saved
    _ -> Unsaved
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
  check_tree_from(trees, layout, ticket, commit, Cold)
}

/// Cuts the check tree like `check_tree`, from the seed given. A warm seed
/// copies the template and moves the copy to the commit, so the tree holds the
/// template's ignored files and the offline check finds the dependencies
/// `setup` fetched. The copy is made at the tree's own name, so a tree that
/// stood there is removed first.
///
/// ## Examples
///
/// ```gleam
/// // project_repo.check_tree_from(trees, layout, "t-a", commit, project_repo.Cold)
/// ```
pub fn check_tree_from(
  trees: Worktrees,
  layout: Layout,
  ticket: String,
  commit: String,
  seed: Seed,
) -> Result(String, String) {
  use Nil <- result.try(commit_name(commit))
  let checks = checks_path(layout)
  let path = check_tree_path(layout, ticket, commit)
  use Nil <- result.try(bootstrap.ensure_private_directory(checks))
  use Nil <- result.try(force_remove(trees, checks, path))

  // A cold tree is cut from nothing, and a warm one is a copy of the template
  // moved to the commit.
  let cut = case seed {
    Cold -> cut_detached(trees, checks, path, layout, commit)
    Warm(copier:) -> {
      use Nil <- result.try(copy_template(trees, layout, checks, path, copier))
      use _fetched <- result.try(fetch_into(trees, layout, path, commit))
      change(trees, path, [path], ["checkout", "--quiet", "--detach", commit])
    }
  }

  // A tree that was not cut whole goes, so the next attempt starts clean.
  case cut {
    Ok(_) -> Ok(path)
    Error(why) -> {
      let _removed = force_remove(trees, checks, path)
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
        Ok(held) -> settle_clone(trees, layout, clone, held)
      }
  }
}

/// Removes a clone that held nothing the host lacks, or keeps it for the
/// reason given. A removal that fails keeps the clone too.
fn settle_clone(
  trees: Worktrees,
  layout: Layout,
  clone: String,
  held: Option(String),
) -> Closed {
  case held {
    Some(reason) -> worktrees.Kept(reason)
    None ->
      case force_remove(trees, tickets_path(layout), clone) {
        Ok(Nil) -> worktrees.Removed
        Error(why) -> worktrees.Kept("it could not be removed: " <> why)
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
