//// Which build of Loom is running, for a client and a daemon to compare.
////
//// An update installs a new tree beside the old one while a daemon rooted in
//// the old tree keeps running (issue #392). Nothing on the wire said which
//// build either side was before this module, so a freshly installed client
//// attached to a stale daemon silently and the operator only found out when a
//// frame the new client sent was refused or rendered wrong.
////
//// The identity is two strings — the release version and the git commit the
//// tree was built from — and it travels three ways from here: into the
//// launcher's environment (below), into the daemon's control-plane `hello`,
//// and into the private endpoint record. Every reader reports a mismatch
//// rather than refusing one, because the whole point is to be *told* the
//// daemon is old while still being able to attach to it.
////
//// **The value is ambient, so it is read, not computed.** Both halves know
//// their own identity because the thing that started them exported it, not
//// because either can introspect a release tree it may have inherited stale.
//// A checkout that exports nothing reads `dev`/`unknown`, which is honest: a
//// tree built ad hoc has no release version and no reproducible commit to
//// claim.

import envoy
import gleam/option.{type Option, None, Some}

/// The version a tree built outside any release reports.
///
/// A contributor running `gleam run` or `make run-server` set no
/// `LOOM_BUILD_VERSION`, and a value invented here would be a version the tree
/// never had. It is a distinct word so a mismatch against a real release is
/// legible in a diagnostic rather than reading as a plausible old number.
pub const development_version = "dev"

/// The commit a tree with no recorded revision reports.
///
/// The mirror of `development_version` for the commit half: a tarball unpacked
/// by hand carries no `git` metadata, and `unknown` says so instead of naming
/// a commit that is not the one running.
pub const unknown_commit = "unknown"

/// A running build's identity, as two comparison strings.
///
/// Both halves are short, opaque and compared for equality only; nothing here
/// parses a version or orders two of them. The question this answers is "are
/// these the same build", and the answer is a string comparison, not a
/// semver comparison — a build that is merely *older* is not something either
/// side can establish from these two strings, and pretending otherwise would
/// be a claim neither side can back.
pub type Identity {
  Identity(
    /// The release version, e.g. `0.1.0`; `development_version` outside a release.
    version: String,
    /// The git commit the tree was built from; `unknown_commit` when absent.
    commit: String,
  )
}

/// The environment variable a launcher exports with the release version.
pub const version_variable = "LOOM_BUILD_VERSION"

/// The environment variable a launcher exports with the build commit.
pub const commit_variable = "LOOM_BUILD_COMMIT"

/// Reads this process's build identity from the environment.
///
/// Set by whichever launcher started this process — the generated
/// `bin/loomd`, the generated `bin/loom`, or a `make run-*` target. Absence is
/// not an error: the defaults above are what a tree built with no release
/// metadata honestly is. An empty value is treated as absent, because
/// `LOOM_BUILD_VERSION=` exports an empty string rather than nothing and an
/// empty version is not one a daemon should report as its own.
///
/// ## Examples
///
/// ```gleam
/// // build_identity.current()
/// // -> Identity("0.1.0", "4c266dde")
/// ```
pub fn current() -> Identity {
  Identity(
    version: variable(version_variable, development_version),
    commit: variable(commit_variable, unknown_commit),
  )
}

fn variable(name: String, absent: String) -> String {
  case envoy.get(name) {
    Ok(value) if value != "" -> value
    Ok(_) | Error(Nil) -> absent
  }
}

/// Whether two identities name the same build.
///
/// Equality of both halves, and deliberately not "is the daemon older": the
/// two strings carry no order. A caller reporting a mismatch says the two
/// differ and names both, which is the whole of what an attach can honestly
/// say about a client and a daemon that were built differently.
///
/// ## Examples
///
/// ```gleam
/// let assert False = build_identity.matches(Identity("0.1.0", "aaaa"), Identity("0.2.0", "bbbb"))
/// ```
pub fn matches(left: Identity, right: Identity) -> Bool {
  left.version == right.version && left.commit == right.commit
}

/// A short human label for a diagnostic: `0.1.0 (4c266dde)`.
///
/// One rendering used by every report, so a client-versus-daemon line reads
/// the same wherever it is produced. The commit is bracketed because it is the
/// disambiguator — two builds can share a version during development — and the
/// bracket is what makes that visible rather than a second bare version.
///
/// ## Examples
///
/// ```gleam
/// assert build_identity.describe(Identity("0.1.0", "4c266dde")) == "0.1.0 (4c266dde)"
/// ```
pub fn describe(identity: Identity) -> String {
  identity.version <> " (" <> identity.commit <> ")"
}

/// An identity parsed from a wire body, or `None` when it is absent.
///
/// The hello and the endpoint record both carry the two fields as plain
/// strings. Both shapes are read for a *report*, never a decision, so a body
/// that predates these fields — an older daemon, a record written by an older
/// install — answers `None` rather than failing the whole frame. That is the
/// backwards-compatibility property the version comparison rests on: a new
/// client must still attach to an old daemon and *say* it is old, which it
/// cannot do if the old daemon's frame is refused for missing a field.
///
/// ## Examples
///
/// ```gleam
/// assert build_identity.from_fields("0.1.0", "4c266dde") == Some(Identity("0.1.0", "4c266dde"))
/// assert build_identity.from_fields("", "") == None
/// ```
pub fn from_fields(version: String, commit: String) -> Option(Identity) {
  case version, commit {
    "", _ | _, "" -> None
    _, _ -> Some(Identity(version, commit))
  }
}
