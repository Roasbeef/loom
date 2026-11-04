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
//// ## Returned work
////
//// `apply_returned` is the other direction: the commits a child made on a remote
//// machine, on top of a state this machine sent, come back as a bundle and are
//// kept under one ref, `refs/loom/children/<child>/<tip8>`, in the repository the
//// state was captured from. It creates no worktree and no branch, moves no
//// existing ref, and asks for nothing the sent state does not already supply. The
//// bundle is untrusted exactly as a sent one is, so the same comparison runs
//// first, and the header must list the sent tip and nothing else as its
//// prerequisite.
////
//// ## Flow
////
//// `apply` → `into_worktree` | `into_clone` → `import_bundle`, and
//// `apply_returned` → `hold_sent` → `create_child_ref`
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
  use #(state, _bytes) <- result.try(verified(bundle, state))

  // Only a state that matches its bytes reaches a repository, and then by the
  // route its placement names.
  case placement {
    Worktree(repository:, destination:, session:) ->
      into_worktree(git, bundle, state, repository, destination, session)
    Clone(destination:, session:) ->
      into_clone(git, bundle, state, destination, session)
  }
}

/// Reads the bundle within the declared size and compares it with the
/// description, answering the validated description and the bytes. This is the
/// check every route makes before a repository is opened.
fn verified(
  bundle: String,
  state: State,
) -> Result(#(State, BitArray), String) {
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
  use Nil <- result.map(state_object.verify_bundle(state, bytes))
  #(state, bytes)
}

/// The state a spawn sent, as this machine still holds it: the description and
/// the bundle file in its store.
pub type Sent {
  Sent(
    /// The path of the bundle in the state store.
    bundle: String,
    /// The description the spawn named.
    state: State,
  )
}

/// Whether a returned ref was made by this apply.
pub type Creation {
  /// The ref did not exist and this apply made it.
  Created

  /// The ref already named the returned tip, so an earlier apply of the same
  /// return made it and this one changed nothing.
  AlreadyThere
}

/// What an apply of a child's returned commits left in the repository.
pub type Returned {
  Returned(
    /// The ref the commits are under, `refs/loom/children/<child>/<tip8>`.
    ref: String,
    /// The commit that ref names.
    tip: String,
    /// Whether this apply made the ref.
    creation: Creation,
    /// How many commits the ref holds above the state that was sent: what the
    /// child made.
    commits: Int,
  )
}

/// Applies the commits a finished child made on top of the state it was sent,
/// creating one ref and nothing else (protocol-change/107, "Return").
///
/// The bundle is untrusted: the child that made it ran on another machine under a
/// model's direction. It is compared with its description first, as for every
/// route. The description must name the state that was sent as its base, the
/// bundle's header must list that state's tip as its only prerequisite, and the
/// child's name must pass the grammar of a ref component, so a child can neither
/// ask for objects the parent was not asked to supply nor name a ref outside
/// `refs/loom/children/`. Git then unpacks the bundle with no network and no hook,
/// a walk from the tip proves every object arrived, and the ref is created with
/// the zero id as its old value.
///
/// A dirty state's tip is a snapshot commit that only the bundle holds, so when
/// the repository lacks the sent tip the sent bundle is unpacked first. That
/// writes objects and no ref. A ref that already names the returned tip is a
/// replay and is answered `AlreadyThere` with nothing written; one that names
/// another commit is refused and left alone. No branch, index, working tree or
/// other ref is touched. The caller holds the repository's workspace gate.
///
/// ## Examples
///
/// ```gleam
/// // state_apply.apply_returned(git, repository, child, sent, bundle, returned)
/// // == Ok(Returned(ref: "refs/loom/children/fix-cache/01234567", tip:, creation: Created, commits: 2))
/// ```
pub fn apply_returned(
  git: Git,
  repository: String,
  child: String,
  sent: Sent,
  bundle: String,
  returned: State,
) -> Result(Returned, String) {
  use #(returned, bytes) <- result.try(verified(bundle, returned))
  use child <- result.try(state_object.child_component(child))
  use Nil <- result.try(thin_against(sent.state, returned, bytes))
  use Nil <- result.try(check_repository(repository))
  let ref = state_object.child_ref(child, returned.tip)
  use existing <- result.try(current_value(git, repository, ref))

  // Whether the ref is there already decides whether anything is unpacked.
  use creation <- result.try(case existing {
    Some(oid) if oid == returned.tip -> Ok(AlreadyThere)
    Some(_) -> Error(ref <> " already names a different commit")
    None -> {
      use Nil <- result.try(hold_sent(git, repository, sent))
      create_child_ref(git, repository, bundle, returned, sent.state.tip, ref)
    }
  })

  // The ref now holds the child's commits, and only they are counted.
  use commits <- result.map(count_commits(
    git,
    repository,
    returned.tip,
    sent.state.tip,
  ))
  Returned(ref:, tip: returned.tip, creation:, commits:)
}

/// How many commits `tip` has that `sent` does not, which for a bundle thin
/// against `sent` is the number the child made.
fn count_commits(
  git: Git,
  repository: String,
  tip: String,
  sent: String,
) -> Result(Int, String) {
  use text <- result.try(
    git_ok(git, repository, [], ["rev-list", "--count", tip, "^" <> sent]),
  )
  string.trim(text)
  |> int.parse
  |> result.replace_error("Git did not count the child's commits")
}

/// Requires a returned state to be thin against exactly the state that was sent:
/// the description names the sent tip as its base, and the bundle's header lists
/// that commit and no other as a prerequisite. A merge that pulled in older
/// history, or a history rewritten below the sent tip, lists another boundary and
/// is refused, because the parent was asked to supply only what it sent.
fn thin_against(
  sent: State,
  returned: State,
  bytes: BitArray,
) -> Result(Nil, String) {
  use <- bool.guard(
    when: returned.base != Some(sent.tip),
    return: Error(
      "the returned state is not thin against the state that was sent",
    ),
  )
  use header <- result.try(state_object.parse_header(bytes))

  // The list must be exactly the sent tip; one entry more is a request for
  // history the parent was never asked to supply.
  case header.prerequisites == [sent.tip] {
    True -> Ok(Nil)
    False ->
      Error(
        "the returned bundle needs commits other than the state that was sent",
      )
  }
}

/// Makes sure the repository holds the sent tip. A clean state's tip is a commit
/// the repository had, and nothing is read. A dirty state's tip is a snapshot
/// commit that was only ever in the bundle, so the sent bundle is unpacked, which
/// writes its objects and no ref.
fn hold_sent(git: Git, repository: String, sent: Sent) -> Result(Nil, String) {
  use held <- result.try(
    git_run(git, repository, [], [
      "cat-file",
      "-e",
      sent.state.tip <> "^{commit}",
    ]),
  )

  // Git exits zero when the commit is there, which is all that is asked.
  case held.code {
    0 -> Ok(Nil)
    _ -> {
      use #(_state, _bytes) <- result.try(verified(sent.bundle, sent.state))
      git_ok_with(
        git,
        repository,
        [repository <> "/.git"],
        worktree_git.run_reading_store,
        ["bundle", "unbundle", sent.bundle],
      )
      |> result.replace(Nil)
    }
  }
}

/// Unpacks the returned bundle and names its tip. Nothing is named until the walk
/// from the tip finds every object. A ref another apply of the same return made
/// in the meantime is the replay it is: the zero old value makes Git refuse, and
/// the ref is read again.
fn create_child_ref(
  git: Git,
  repository: String,
  bundle: String,
  returned: State,
  sent_tip: String,
  ref: String,
) -> Result(Creation, String) {
  let writable = [repository <> "/.git"]
  use _ <- result.try(
    git_ok_with(git, repository, writable, worktree_git.run_reading_store, [
      "bundle",
      "unbundle",
      bundle,
    ]),
  )
  use _ <- result.try(
    git_ok(git, repository, [], [
      "rev-list", "--objects", "--quiet", returned.tip, "--not", "--all",
    ]),
  )
  use Nil <- result.try(descends_from(git, repository, sent_tip, returned.tip))
  let made =
    git_ok(git, repository, writable, [
      "update-ref",
      ref,
      returned.tip,
      string.repeat("0", string.length(returned.tip)),
    ])

  // A failed update is either a lost race to the same ref or a real refusal.
  case made {
    Ok(_) -> Ok(Created)
    Error(reason) -> {
      use again <- result.try(current_value(git, repository, ref))

      // Another apply that got there first named the same tip.
      case again {
        Some(oid) if oid == returned.tip -> Ok(AlreadyThere)
        Some(_) | None -> Error(reason)
      }
    }
  }
}

/// Requires the returned tip to descend from the sent tip. The header says what
/// the bundle needs and not what its tip is built on, so a bundle that lists the
/// sent tip as its prerequisite and carries a tip of unrelated history passes every
/// check made before the unpack. Git answers by exit code, and anything but zero
/// refuses with one constant reason, before any ref is written.
fn descends_from(
  git: Git,
  repository: String,
  sent_tip: String,
  tip: String,
) -> Result(Nil, String) {
  use output <- result.try(
    git_run(git, repository, [], [
      "merge-base",
      "--is-ancestor",
      sent_tip,
      tip,
    ]),
  )

  // Zero is the only yes.
  case output.code {
    0 -> Ok(Nil)
    _ -> Error("the returned commits are not built on the state that was sent")
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
