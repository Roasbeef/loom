//// Applies a stored state where it was received (protocol-change/107,
//// "Apply").
////
//// A receiving node holds a bundle in its state store and has to turn it into a
//// checkout for a session. The bundle came from another machine and describes a
//// repository the model has shaped, and the repository it lands in may have a
//// `.git/config` and hooks the model wrote as well. Rule Zero applies on both
//// sides: no Git runs in the daemon's VM, every command here goes through
//// `client/worktree_git` into the sandbox with a policy of its own, and the
//// commands are chosen so that nothing in either repository's configuration can
//// start a program.
////
//// ## What an apply may write
////
//// Objects, one ref under `refs/loom/in/`, and the checkout. It never moves an
//// existing ref. The ref is created with the zero object id as its expected old
//// value, so Git refuses when it exists with another value; an existing ref
//// that already names the state's tip is the state having been applied before,
//// which is how two children of one parent share an import. The session's
//// branch is created with `git worktree add -b` or `git checkout -b`, and Git
//// refuses a name that exists. No transport is used by apply itself. A fetch
//// from a path reads the repository's `url.<base>.insteadOf` and `protocol.*`
//// settings, which can turn a bundle path into a command, so the bundle is
//// unpacked with `git bundle unbundle`, checked for connectivity, and given its
//// ref by `git update-ref`.
////
//// Git can still start a transport on its own: a repository whose config names a
//// promisor remote fetches a missing object lazily, and a transport that runs a
//// command would run it during the base check, the unpack or the connectivity
//// walk. `worktree_git` sets `GIT_NO_LAZY_FETCH` in the environment of every
//// call, which is what stops that. The sandbox's lack of network does not,
//// because the command is a program on the machine.
////
//// Every Git call carries `-c core.hooksPath=/dev/null`, so no hook runs
//// whatever `.git/hooks` or `core.hooksPath` hold, and
//// `-c core.fsmonitor=false`, which stops the program a repository can name
//// there. `core.autocrlf` and the sparse checkout settings are forced off so
//// the checkout has the captured bytes and all of them. A filter or attribute
//// driver is the one thing a command line cannot turn off in general. Capture
//// refuses a tree whose attributes name one, and the sandbox, which has no
//// network and writes only the repository's `.git` and the destination's
//// directory, bounds what one could do.
////
//// ## What the caller owns
////
//// The caller serializes applies to one repository, as `client/worktrees` does
//// with its gate, because `git worktree add` takes locks in the repository's
//// `.git`. It also owns any record of the new tree: this module creates the
//// directory and the branch and writes no ledger row.
////
//// ## Flow
////
//// `apply` → `into_worktree` | `into_clone` → `import_bundle`
////
//// 1. `apply` reads the bundle within the declared size and has
////    `state_object.verify_bundle` compare it with the state. Nothing touches a
////    repository before that comparison passes.
//// 2. `into_worktree` checks the repository, the destination and, for a thin
////    state, that the base is held, then imports the bundle and runs
////    `git worktree add -b`.
//// 3. `into_clone` makes a fresh repository at the destination, imports the
////    bundle and checks out the session's branch. A thin state is refused,
////    because a new repository holds no base.
//// 4. `import_bundle` is the shared part: it answers the incoming ref, creating
////    it from the bundle when absent.

import client/state_object.{type State}
import client/worktree_git.{type Git}
import client/worktrees
import filepath
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile

/// Where an applied state becomes a checkout.
pub type Placement {
  /// A linked worktree of a registered workspace's repository, as
  /// protocol-change/095 makes for a session.
  Worktree(
    /// The repository's top directory. It must be canonical and a primary
    /// checkout, a directory with a `.git` directory in it.
    repository: String,
    /// The tree's directory, normally
    /// `<state root>/worktrees/<workspace>/<session>`. It must not exist, and
    /// its parent must be a canonical directory, which is the only place outside
    /// the repository's `.git` that the apply may write.
    destination: String,
    /// The session the tree is for. It names the branch `loom/<session>`.
    session: String,
  )

  /// A fresh repository in a plain `directory` placement, which has no
  /// repository to add a worktree to.
  Clone(
    /// The new repository's directory. It must not exist, and its parent must be
    /// a canonical directory.
    destination: String,
    /// The session the checkout is for. It names the branch `loom/<session>`.
    session: String,
  )
}

/// What an apply made.
pub type Applied {
  Applied(
    /// The ref the state was imported under, `refs/loom/in/<hash8>`.
    ref: String,
    /// The commit that ref and the new branch name.
    tip: String,
    /// The checkout's directory.
    destination: String,
    /// The branch created in it, `loom/<session>`.
    branch: String,
  )
}

/// The most of Git's message carried into a refusal.
const reason_limit = 512

/// Arguments that go in front of every Git command here. They are what makes
/// "runs no hook" and "has the captured bytes" a property of the call and not of
/// the repository it runs in.
const guards = [
  "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c",
  "core.autocrlf=false", "-c", "core.sparseCheckout=false", "-c",
  "index.sparse=false", "-c", "gc.auto=0", "-c", "maintenance.auto=false",
]

/// Applies a state from a bundle file into a placement.
///
/// The state is validated and compared with the bundle's bytes first: the file
/// must be exactly the declared size, hash to the declared value and carry one
/// ref at the declared tip, with prerequisites exactly when a base is declared.
/// A hash or size that does not match, a truncated file and a bundle that is not
/// the one described are each refused before any repository is opened.
///
/// Git then runs in the sandbox. On success the state is under its incoming
/// ref and the session's branch is checked out in the destination. A failure
/// part way can leave the imported objects and the incoming ref, which name
/// commits the repository can use and which a later apply of the same state
/// reuses. A failed clone removes the directory it made.
///
/// ## Examples
///
/// ```gleam
/// // state_apply.apply(git, held.path, held.state, state_apply.Worktree(repository, destination, session))
/// ```
pub fn apply(
  git: Git,
  bundle: String,
  state: State,
  placement: Placement,
) -> Result(Applied, String) {
  use state <- result.try(state_object.validate(state))
  use <- bool.guard(
    when: state.size > state_object.size_limit,
    return: Error("the state is over the size limit"),
  )
  use bytes <- result.try(
    bootstrap.read_bounded(bundle, state.size)
    |> result.map_error(fn(reason) {
      "the bundle cannot be read within the declared size: " <> reason
    }),
  )
  use Nil <- result.try(state_object.verify_bundle(state, bytes))

  // Only a state that matches its bytes reaches a repository, and then by the
  // route its placement names.
  case placement {
    Worktree(repository:, destination:, session:) ->
      into_worktree(git, bundle, state, repository, destination, session)
    Clone(destination:, session:) ->
      into_clone(git, bundle, state, destination, session)
  }
}

/// Imports into a registered workspace's repository and adds a linked worktree
/// of the session's branch at the destination.
fn into_worktree(
  git: Git,
  bundle: String,
  state: State,
  repository: String,
  destination: String,
  session: String,
) -> Result(Applied, String) {
  use branch <- result.try(branch_of(session))
  use Nil <- result.try(check_repository(repository))
  use Nil <- result.try(check_destination(destination))
  use <- bool.guard(
    when: string.starts_with(destination, repository <> "/"),
    return: Error("the destination is inside the repository"),
  )
  use Nil <- result.try(require_base(git, repository, state))
  use ref <- result.try(import_bundle(git, repository, bundle, state))

  // The new branch is created by `-b`, which refuses a name that exists, and
  // the tree is its only checkout. Writes are the repository's `.git` and the
  // destination's parent, as `client/worktrees` grants them.
  let writable = [repository <> "/.git", filepath.directory_name(destination)]
  use _ <- result.map(
    git_ok(git, repository, writable, [
      "worktree", "add", "--quiet", "-b", branch, destination, ref,
    ]),
  )
  Applied(ref:, tip: state.tip, destination:, branch:)
}

/// Imports into a repository made at the destination, and checks out the
/// session's branch there. The directory is removed again when any step fails,
/// since this call made it.
fn into_clone(
  git: Git,
  bundle: String,
  state: State,
  destination: String,
  session: String,
) -> Result(Applied, String) {
  use branch <- result.try(branch_of(session))
  use Nil <- result.try(check_destination(destination))
  use <- bool.guard(
    when: option.is_some(state.base),
    return: Error(
      "a new repository holds no base commit, so it cannot take a thin state",
    ),
  )

  // An empty template keeps the system's sample hooks out of the new
  // repository, which the model will run Git in without these guards.
  let parent = filepath.directory_name(destination)
  use _ <- result.try(
    git_ok(git, parent, [parent], [
      "init", "--quiet", "--template=", destination,
    ]),
  )
  let made = {
    use ref <- result.try(import_bundle(git, destination, bundle, state))
    use _ <- result.map(
      git_ok(git, destination, [destination], [
        "checkout", "--quiet", "-b", branch, ref,
      ]),
    )
    Applied(ref:, tip: state.tip, destination:, branch:)
  }

  // A failed clone leaves nothing behind: this call made the directory.
  case made {
    Ok(_) -> made
    Error(_) -> {
      let _removed = simplifile.delete(destination)
      made
    }
  }
}

/// Answers the incoming ref of a state in a repository, creating it from the
/// bundle when it does not exist.
///
/// A ref that exists and names the tip is a state already imported, and the
/// bundle is not read again. A ref that exists and names another commit is
/// refused and left alone. Otherwise the objects are unpacked, a walk from the
/// tip that stops at what the repository already had proves every object is
/// present, and the ref is created with the zero id as its old value.
fn import_bundle(
  git: Git,
  repository: String,
  bundle: String,
  state: State,
) -> Result(String, String) {
  let ref = state_object.incoming_ref(state.hash)
  use existing <- result.try(current_value(git, repository, ref))

  // Whether the ref is there already decides whether the bundle is unpacked.
  case existing {
    Some(oid) if oid == state.tip -> Ok(ref)
    Some(_) -> Error(ref <> " already names a different commit")
    None -> create_ref(git, repository, bundle, state, ref)
  }
}

/// Unpacks the bundle and names its tip. Nothing is named until the walk from
/// the tip finds every object: the bundle's pack is complete by construction,
/// and a crafted one need not be.
fn create_ref(
  git: Git,
  repository: String,
  bundle: String,
  state: State,
  ref: String,
) -> Result(String, String) {
  let writable = [repository <> "/.git"]

  // The unpack is the one call that reads the node's state store, so it is the
  // one call the runner lifts the store's mask for. The walk and the ref that
  // follow read only the repository.
  use _ <- result.try(
    git_ok_with(git, repository, writable, worktree_git.run_reading_store, [
      "bundle",
      "unbundle",
      bundle,
    ]),
  )
  use _ <- result.try(
    git_ok(git, repository, [], [
      "rev-list", "--objects", "--quiet", state.tip, "--not", "--all",
    ]),
  )

  // The zero id as the old value makes Git refuse when the ref exists.
  use _ <- result.map(
    git_ok(git, repository, writable, [
      "update-ref",
      ref,
      state.tip,
      string.repeat("0", string.length(state.tip)),
    ]),
  )
  ref
}

/// The commit a ref names, or `None` when it does not exist.
fn current_value(
  git: Git,
  repository: String,
  ref: String,
) -> Result(Option(String), String) {
  use output <- result.try(
    git_run(git, repository, [], [
      "rev-parse",
      "--verify",
      "--quiet",
      ref <> "^{commit}",
    ]),
  )

  // Git exits one for a ref that is not there, which is an answer.
  case output.code {
    0 -> Ok(Some(string.trim(output.stdout)))
    _ -> Ok(None)
  }
}

/// A thin state needs its base in the repository. Git would refuse the unpack
/// with a list of missing prerequisites, and this says which commit the state
/// was thin against.
fn require_base(
  git: Git,
  repository: String,
  state: State,
) -> Result(Nil, String) {
  // A full state needs nothing from the repository.
  case state.base {
    None -> Ok(Nil)
    Some(base) -> {
      use output <- result.try(
        git_run(git, repository, [], [
          "cat-file",
          "-e",
          base <> "^{commit}",
        ]),
      )
      use <- bool.lazy_guard(when: output.code != 0, return: fn() {
        Error("the repository does not hold the state's base commit " <> base)
      })
      Ok(Nil)
    }
  }
}

/// The branch a session's checkout gets, `loom/<session>`, once the session
/// name is safe to use as a path component and a ref component.
fn branch_of(session: String) -> Result(String, String) {
  case worktrees.safe_component(session) {
    True -> Ok(worktrees.branch_of(session))
    False -> Error("the session name is not usable as a branch name")
  }
}

/// A registered workspace's repository must be a canonical primary checkout:
/// the common directory this module writes through is `<root>/.git`, and in a
/// linked worktree `.git` is a file that points somewhere else. The `.git`
/// entry itself must be a directory and not a link to one, because the writable
/// root named from it is resolved when the sandbox grants it.
fn check_repository(repository: String) -> Result(Nil, String) {
  use canonical <- result.try(bootstrap.canonical_directory(repository))
  use <- bool.lazy_guard(
    when: canonical != repository || !is_plain_directory(repository <> "/.git"),
    return: fn() {
      Error(
        "the repository is not a canonical primary checkout: " <> repository,
      )
    },
  )
  Ok(Nil)
}

/// Whether the path itself is a directory. A link is not one, whatever it
/// points at.
fn is_plain_directory(path: String) -> Bool {
  case simplifile.link_info(path) {
    Ok(info) -> simplifile.file_info_type(info) == simplifile.Directory
    Error(_) -> False
  }
}

/// A destination must be an absolute path that does not exist yet, under a
/// parent that is a canonical directory. The parent is the writable root, so a
/// link or a `..` in it would move the grant, and the canonical comparison
/// refuses both.
fn check_destination(destination: String) -> Result(Nil, String) {
  let parent = filepath.directory_name(destination)
  use <- bool.guard(
    when: !string.starts_with(destination, "/")
      || bootstrap.path_exists(destination),
    return: Error("the destination exists or is not an absolute path"),
  )
  use canonical <- result.try(bootstrap.canonical_directory(parent))
  use <- bool.guard(
    when: canonical != parent,
    return: Error("the destination's parent is not a canonical directory"),
  )
  Ok(Nil)
}

/// Runs Git in the sandbox with the guards and answers however it exited. A
/// call that writes gets the long deadline, and a read the short one.
fn git_run(
  git: Git,
  directory: String,
  writable: List(String),
  arguments: List(String),
) -> Result(worktree_git.Output, String) {
  git_run_with(git, directory, writable, worktree_git.run, arguments)
}

/// Runs Git through the given runner call and answers however it exited.
fn git_run_with(
  git: Git,
  directory: String,
  writable: List(String),
  runner: fn(Git, worktree_git.Run, Int) -> Result(worktree_git.Output, String),
  arguments: List(String),
) -> Result(worktree_git.Output, String) {
  // An empty list of writable roots is how a read says it writes nothing.
  let within = case writable {
    [] -> worktree_git.query_within_ms
    _ -> worktree_git.checkout_within_ms
  }

  runner(
    git,
    worktree_git.Run(
      directory:,
      writable:,
      arguments: list.append(guards, arguments),
    ),
    within,
  )
}

/// Runs Git that must exit zero. A failure answers Git's own message, cut to
/// `reason_limit` and made printable.
fn git_ok(
  git: Git,
  directory: String,
  writable: List(String),
  arguments: List(String),
) -> Result(String, String) {
  git_ok_with(git, directory, writable, worktree_git.run, arguments)
}

/// Runs Git that must exit zero through the given runner call, which is how the
/// one call that reads the state store asks for it.
fn git_ok_with(
  git: Git,
  directory: String,
  writable: List(String),
  runner: fn(Git, worktree_git.Run, Int) -> Result(worktree_git.Output, String),
  arguments: List(String),
) -> Result(String, String) {
  use output <- result.try(git_run_with(
    git,
    directory,
    writable,
    runner,
    arguments,
  ))

  // Zero is the only success. Anything else is Git's own account of why not.
  case output.code {
    0 -> Ok(output.stdout)
    code ->
      Error(worktree_git.printable(
        "git "
          <> string.join(list.take(arguments, 2), " ")
          <> " exited "
          <> int.to_string(code)
          <> ": "
          <> output.stderr,
        reason_limit,
      ))
  }
}
