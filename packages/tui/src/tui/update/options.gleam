//// Update choices are parsed without filesystem, network or daemon effects.
//// Named variants make check-only, installation and restart intent explicit.

import gleam/bool
import gleam/result
import gleam/string
import tui/update/manifest

/// The release identity requested by the operator.
pub type Selection {
  /// GitHub's latest published stable release.
  Latest

  /// An exact published release tag.
  Tag(
    /// Exact basename-safe release tag.
    value: String,
  )

  /// A source commit resolved to a published commit-addressed build.
  Commit(
    /// Lowercase hexadecimal commit prefix or full SHA.
    value: String,
  )
}

/// Side effects the command may perform.
pub type Action {
  /// Verify metadata and report the selection without installing.
  Check

  /// Install and gracefully restart the shared daemon.
  Update

  /// Install complete trees while leaving daemon lifecycle to the operator.
  InstallOnly
}

/// Authentication policy for the manifest itself.
pub type Signature {
  /// An absent signature is allowed; a present signature must verify.
  Optional

  /// A valid signature from the supplied local keyring is mandatory.
  Required
}

/// Validated CLI choices, before environmental defaults are resolved.
pub type Options {
  Options(
    /// Requested release identity.
    selection: Selection,
    /// Allowed installation and lifecycle effects.
    action: Action,
    /// Optional offline distribution directory.
    from: String,
    /// Explicit installation prefix, or the installed wrapper's prefix.
    prefix: String,
    /// Client shape, or the shape recorded by the installed wrapper.
    client: String,
    /// Explicit shared daemon state directory.
    state: String,
    /// Explicit daemon catalogue path.
    config: String,
    /// Signature presence requirement.
    signature: Signature,
    /// Operator-supplied local OpenPGP verification keyring.
    keyring: String,
    /// Explicit HTTPS manifest URL on an operator-selected mirror.
    mirror: String,
  )
}

/// Parses a command without consulting or mutating external state.
///
/// ## Examples
///
/// ```gleam
/// // options.parse(["--commit", "abcdef123456", "--install-only"])
/// ```
pub fn parse(arguments: List(String)) -> Result(Options, String) {
  parse_more(
    arguments,
    Options(Latest, Update, "", "", "", "", "", Optional, "", ""),
  )
}

fn parse_more(arguments, options: Options) {
  case arguments {
    [] -> Ok(options)
    ["--manifest-url", mirror, ..rest] ->
      parse_more(rest, Options(..options, mirror: mirror))
    ["--check", ..rest] -> action(rest, options, Check)
    ["--install-only", ..rest] -> action(rest, options, InstallOnly)
    ["--require-signature", ..rest] ->
      parse_more(rest, Options(..options, signature: Required))
    ["--from", directory, ..rest] ->
      parse_more(rest, Options(..options, from: directory))
    ["--prefix", prefix, ..rest] ->
      parse_more(rest, Options(..options, prefix: prefix))
    ["--state-dir", state, ..rest] ->
      parse_more(rest, Options(..options, state: state))
    ["--config", config, ..rest] ->
      parse_more(rest, Options(..options, config: config))
    ["--keyring", keyring, ..rest] ->
      parse_more(rest, Options(..options, keyring: keyring))
    ["--client", client, ..rest] -> {
      use <- bool.guard(
        client != "bundled" && client != "slim",
        Error("--client must be bundled or slim"),
      )
      parse_more(rest, Options(..options, client: client))
    }
    ["--version", tag, ..rest] -> select(rest, options, Tag(tag))
    ["--commit", commit, ..rest] -> select(rest, options, Commit(commit))
    [value, ..rest] -> {
      use <- bool.guard(
        string.starts_with(value, "-"),
        Error("unknown or incomplete update option: " <> value),
      )
      let selection = case valid_commit(value) {
        True -> Commit(value)
        False -> Tag(value)
      }
      select(rest, options, selection)
    }
  }
}

fn select(rest, options: Options, selection) {
  use <- bool.guard(
    options.selection != Latest,
    Error("select only one release tag or commit"),
  )
  use Nil <- result.try(case selection {
    Latest -> Ok(Nil)
    Tag(tag) ->
      case manifest.basename(tag) {
        True -> Ok(Nil)
        False -> Error("invalid release tag")
      }
    Commit(commit) ->
      case valid_commit(commit) {
        True -> Ok(Nil)
        False ->
          Error("commit must be 7 to 40 lowercase hexadecimal characters")
      }
  })
  parse_more(rest, Options(..options, selection: selection))
}

fn valid_commit(value) {
  let width = string.length(value)
  width >= 7 && width <= 40 && manifest.hexadecimal(value, width)
}

/// Describes updater selection, verification and lifecycle behavior.
///
/// ## Examples
///
/// ```gleam
/// options.usage()
/// ```
pub fn usage() -> String {
  "Usage: loom update [TAG | COMMIT] [options]\n\n"
  <> "With no selection, uses the latest stable GitHub release.\n"
  <> "Commits require a published commit-<full-sha> release.\n\n"
  <> "  --version TAG          Select an exact release tag\n"
  <> "  --commit SHA           Select a published source commit\n"
  <> "  --check                Verify metadata without installing\n"
  <> "  --install-only         Install without restarting the daemon\n"
  <> "  --prefix DIR           Override the installation prefix\n"
  <> "  --client bundled|slim  Override the installed client shape\n"
  <> "  --state-dir DIR        Select the shared daemon state\n"
  <> "  --config FILE          Select the daemon catalogue\n"
  <> "  --keyring FILE         Trust this local OpenPGP keyring\n"
  <> "  --require-signature    Refuse unsigned manifests\n"
  <> "  --manifest-url URL     Select an HTTPS mirror manifest\n"
  <> "  --from DIR             Use a local distribution directory\n\n"
  <> "Archives are always checked against their manifest hashes.\n"
  <> "Unsigned manifests are allowed unless signatures are required.\n"
  <> "An invalid present signature is always refused.\n"
  <> "Update installs immutable trees, requests graceful shutdown, waits\n"
  <> "up to "
  <> "90"
  <> " seconds for retirement, then checks the new daemon."
}

fn action(rest, options: Options, action) {
  use <- bool.guard(
    options.action != Update && options.action != action,
    Error("--check and --install-only cannot be combined"),
  )
  parse_more(rest, Options(..options, action: action))
}
