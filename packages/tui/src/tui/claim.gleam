//// `loom claim` and `loom enroll`: the invitee's half of protocol-change/053.
////
//// An owner who invites a member receives a single-use claim token and sends
//// it, with a `loom claim --addr …` line, over a channel outside Loom. The
//// invitee runs that line and supplies the token on standard input. This
//// module then draws a fresh credential locally, writes it to a private file,
//// and sends the daemon only the credential's SHA-256 digest. No secret comes
//// back: the daemon binds the digest to the claim, once, and the claim is
//// spent. The token and the credential are never printed, logged or written
//// anywhere but the files named below.
////
//// Files live under `<state-dir>/remotes/<label>/`, a directory forced to mode
//// `0700` that must be a real directory this user owns:
////
//// - `credential` holds the bearer, mode `0600`, written before any
////   connection.
//// - `claim` holds the digest of the claim token that `credential` was drawn
////   for, mode `0600`, written right after it.
//// - `remote.json` records a finished claim or an enrollment, mode `0600`.
////
//// Writing the credential before connecting is what makes an unknown outcome
//// recoverable. If the daemon's reply is lost, the claim may already be bound
//// to this credential; a rerun with the same token finds a `claim` file naming
//// that token's digest, reuses the credential, and the daemon answers the
//// same success again. A credential left by any other token is replaced,
//// never reused, so a credential drawn for a refused or rotated claim cannot
//// be bound to a new one. A definite refusal (`not_found`, `expired`,
//// `conflict`) deletes both files, which authenticate nothing.
////
//// `loom enroll` is the other form, enrollment by digest: it draws and stores
//// a credential, opens no connection, and prints the digest for the invitee to
//// send the owner, who invites with `--credential-digest`.

import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import host/bootstrap
import host/claim
import host/websocket
import simplifile
import tui/internal/ffi_terminal

/// Where one remote daemon's files live, and the address they belong to.
pub type Remote {
  Remote(
    /// The control address, already checked by `claim.remote_address`.
    address: String,
    /// The directory name under `remotes/`, the host by default.
    label: String,
    /// The absolute, private `<state-dir>/remotes/<label>` directory.
    directory: String,
  )
}

/// What `loom claim` and `loom enroll` were asked to do.
pub type Options {
  Options(
    /// The remote control address from `--addr`.
    address: String,
    /// `--label`, or empty for the default.
    label: String,
    /// `--state-dir`, or empty for `$HOME/.loom`.
    state_directory: String,
  )
}

/// One session membership the daemon reported for the claimed member.
pub type Membership {
  Membership(session_id: String, role: String)
}

/// A bound claim, as the daemon reported it and this client checked it.
pub type Claimed {
  Claimed(
    /// The stable member identity.
    principal_id: String,
    /// The member's display name.
    name: String,
    /// The first 16 hex characters of this credential's digest, which the
    /// owner compares with the invitee out of band.
    fingerprint: String,
    /// At most 16 memberships, in session-ID order.
    sessions: List(Membership),
  )
}

/// Why a claim or an enrollment did not finish. None carries a secret.
pub type Failure {
  /// Refused before any connection: a bad argument, address, token, label,
  /// or a remote that already holds a finished claim.
  Invalid(reason: String)

  /// The daemon refused the claim with `not_found`, `expired` or `conflict`.
  /// The credential and claim files were deleted.
  Refused(code: String)

  /// The outcome is unknown or the refusal is not final; the credential is
  /// kept, and rerunning the same command completes or refuses the claim.
  Unknown(reason: String)
}

/// Runs `loom claim` and exits with its status.
///
/// ## Examples
///
/// ```sh
/// loom claim --addr wss://loom.example.com/v2/control
/// ```
pub fn claim_main(arguments: List(String)) -> Nil {
  let outcome = {
    use #(options, token) <- result.try(parse_claim(arguments))
    use token <- result.try(case token {
      Some(token) -> Ok(token)
      None ->
        ffi_terminal.read_standard_line("claim token: ")
        |> result.map(string.trim)
        |> result.map_error(fn(reason) {
          Invalid("could not read the claim token: " <> reason)
        })
    })

    // A bearer or a mistyped token is refused before any directory is made.
    use Nil <- result.try(
      claim.validate_token(token) |> result.map_error(Invalid),
    )
    use remote <- result.try(remote(options) |> result.map_error(Invalid))
    redeem(remote, token)
    |> result.map(fn(claimed) { #(remote, claimed) })
  }
  case outcome {
    Ok(#(remote, claimed)) -> {
      io.println_error(
        "claimed "
        <> claimed.principal_id
        <> " at "
        <> remote.label
        <> "; credential fingerprint "
        <> claimed.fingerprint,
      )
      io.println(json.to_string(report(remote, claimed)))
      ffi_terminal.halt(0)
    }
    Error(failure) -> {
      io.println_error("loom claim: " <> describe(failure))
      ffi_terminal.halt(1)
    }
  }
}

/// Runs `loom enroll` and exits with its status.
///
/// ## Examples
///
/// ```sh
/// loom enroll --addr wss://loom.example.com/v2/control
/// ```
pub fn enroll_main(arguments: List(String)) -> Nil {
  let outcome = {
    use options <- result.try(parse_enroll(arguments))
    use remote <- result.try(remote(options) |> result.map_error(Invalid))
    enroll(remote)
  }
  case outcome {
    Ok(value) -> {
      io.println_error(
        "send credential_digest to the owner, and confirm its fingerprint "
        <> "with them over a second channel before they invite you",
      )
      io.println(json.to_string(value))
      ffi_terminal.halt(0)
    }
    Error(failure) -> {
      io.println_error("loom enroll: " <> describe(failure))
      ffi_terminal.halt(1)
    }
  }
}

/// The usage both commands share.
pub const usage = "usage: loom claim --addr <wss://host[:port]/v2/control> [--label NAME] [--state-dir PATH] [TOKEN]\n       loom enroll --addr <wss://host[:port]/v2/control> [--label NAME] [--state-dir PATH]\n  claim reads the token from standard input unless it is given, so the\n  token stays out of shell history; ws:// is refused for a non-loopback host"

/// Parses `loom claim`'s arguments. The token is optional and positional.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(#(options, None)) = claim.parse_claim(["--addr", "wss://h/v2/control"])
/// ```
pub fn parse_claim(
  arguments: List(String),
) -> Result(#(Options, Option(String)), Failure) {
  use #(options, positional) <- result.try(
    gather(arguments, Options("", "", ""), []),
  )
  use Nil <- result.try(required_address(options))
  case positional {
    [] -> Ok(#(options, None))
    [token] -> Ok(#(options, Some(token)))
    [_, _, ..] -> Error(Invalid(usage))
  }
}

/// Parses `loom enroll`'s arguments, which take no positional word.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(options) = claim.parse_enroll(["--addr", "wss://h/v2/control"])
/// ```
pub fn parse_enroll(arguments: List(String)) -> Result(Options, Failure) {
  use #(options, positional) <- result.try(
    gather(arguments, Options("", "", ""), []),
  )
  use Nil <- result.try(required_address(options))
  case positional {
    [] -> Ok(options)
    [_, ..] -> Error(Invalid(usage))
  }
}

fn gather(
  arguments: List(String),
  options: Options,
  positional: List(String),
) -> Result(#(Options, List(String)), Failure) {
  case arguments {
    [] -> Ok(#(options, list.reverse(positional)))
    ["--addr", value, ..rest] if options.address == "" ->
      gather(rest, Options(..options, address: value), positional)
    ["--label", value, ..rest] if options.label == "" ->
      gather(rest, Options(..options, label: value), positional)
    ["--state-dir", value, ..rest] if options.state_directory == "" ->
      gather(rest, Options(..options, state_directory: value), positional)
    [word, ..rest] ->
      case string.starts_with(word, "--") {
        True -> Error(Invalid(usage))
        False -> gather(rest, options, [word, ..positional])
      }
  }
}

fn required_address(options: Options) -> Result(Nil, Failure) {
  case options.address {
    "" -> Error(Invalid(usage))
    _given -> Ok(Nil)
  }
}

/// Checks the address and prepares `<state-dir>/remotes/<label>/`, creating
/// or checking each directory with `bootstrap.ensure_private_directory`, which
/// refuses a link or another user's directory and forces mode `0700`.
///
/// ## Examples
///
/// ```gleam
/// // claim.remote(Options("wss://loom.example.com/v2/control", "", ""))
/// ```
pub fn remote(options: Options) -> Result(Remote, String) {
  use Nil <- result.try(claim.remote_address(options.address))
  use label <- result.try(case options.label {
    "" -> default_label(options.address)
    given -> Ok(given)
  })
  use Nil <- result.try(valid_label(label))
  use state <- result.try(case options.state_directory {
    "" ->
      bootstrap.getenv("HOME")
      |> result.map(fn(home) { home <> "/.loom" })
      |> result.replace_error("HOME is unset; pass --state-dir")
    given -> Ok(given)
  })
  use state <- result.try(bootstrap.absolute_path(state))
  let remotes = state <> "/remotes"
  let directory = remotes <> "/" <> label

  // The state directory is the one the local daemon also keeps private, so
  // each level is held to that rule rather than only the last.
  use Nil <- result.try(bootstrap.ensure_private_directory(state))
  use Nil <- result.try(bootstrap.ensure_private_directory(remotes))
  use Nil <- result.try(bootstrap.ensure_private_directory(directory))
  Ok(Remote(options.address, label, directory))
}

// The host, with the port when one is given and it is not 443, so two
// daemons on one host keep separate files.
fn default_label(address: String) -> Result(String, String) {
  use parsed <- result.try(
    uri.parse(address) |> result.replace_error("invalid control address"),
  )
  case parsed.host, parsed.port {
    Some(host), None | Some(host), Some(443) -> Ok(host)
    Some(host), Some(port) -> Ok(host <> ":" <> int.to_string(port))
    None, _ -> Error("the control address names no host")
  }
}

// The label becomes one path component, so it may not climb out of
// `remotes/` or name a hidden or empty entry.
fn valid_label(label: String) -> Result(Nil, String) {
  let allowed =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]"
  case
    label != ""
    && !string.starts_with(label, ".")
    && string.byte_size(label) <= 255
    && list.all(string.to_graphemes(label), fn(char) {
      string.contains(allowed, char)
    })
  {
    True -> Ok(Nil)
    False ->
      Error(
        "--label must be one path component of letters, digits and ._-:[] not starting with a dot",
      )
  }
}

/// The credential file of a remote.
///
/// ## Examples
///
/// ```gleam
/// // claim.credential_path(remote) -> "/home/alice/.loom/remotes/host/credential"
/// ```
pub fn credential_path(remote: Remote) -> String {
  remote.directory <> "/credential"
}

/// The file naming which claim token the stored credential was drawn for.
///
/// ## Examples
///
/// ```gleam
/// // claim.claim_path(remote)
/// ```
pub fn claim_path(remote: Remote) -> String {
  remote.directory <> "/claim"
}

/// The record of a finished claim or enrollment.
///
/// ## Examples
///
/// ```gleam
/// // claim.record_path(remote)
/// ```
pub fn record_path(remote: Remote) -> String {
  remote.directory <> "/remote.json"
}

/// Redeems one claim token for a credential drawn and stored here.
///
/// The steps run in the order the module doc gives: the token's shape and a
/// finished claim are refused first, then the credential is prepared and
/// written, then the connection is made. Only the credential's digest is
/// sent. On success `remote.json` is written.
///
/// ## Examples
///
/// ```gleam
/// // claim.redeem(remote, "loomclaim_…")
/// ```
pub fn redeem(remote: Remote, token: String) -> Result(Claimed, Failure) {
  use Nil <- result.try(
    claim.validate_token(token) |> result.map_error(Invalid),
  )
  use endpoint <- result.try(
    claim.endpoint(remote.address) |> result.map_error(Invalid),
  )
  use Nil <- result.try(unfinished(remote))
  use credential <- result.try(
    prepare(remote, token) |> result.map_error(Invalid),
  )
  let digest = claim.digest(credential)
  case exchange(endpoint, token, digest) {
    Error(failure) -> Error(failure)
    Ok(Answered(claimed)) -> {
      use Nil <- result.try(
        bootstrap.atomic_write_private(
          record_path(remote),
          json.to_string(
            json.Object([
              #("addr", json.String(remote.address)),
              #("principal_id", json.String(claimed.principal_id)),
              #("name", json.String(claimed.name)),
              #("fingerprint", json.String(claimed.fingerprint)),
            ]),
          ),
        )
        |> result.map_error(fn(reason) {
          Unknown(
            "the claim is bound, but remote.json could not be written: "
            <> reason,
          )
        }),
      )
      Ok(claimed)
    }

    // A definite refusal binds nothing, so the files authenticate nothing
    // and are removed; a later claim draws a fresh credential regardless.
    Ok(Final(code)) -> {
      let _ = simplifile.delete(credential_path(remote))
      let _ = simplifile.delete(claim_path(remote))
      Error(Refused(code))
    }
  }
}

// A finished claim lives in `remote.json`; a second claim for the same label
// would overwrite the credential that claim bound.
fn unfinished(remote: Remote) -> Result(Nil, Failure) {
  case simplifile.is_file(record_path(remote)) {
    Ok(False) -> Ok(Nil)
    Ok(True) ->
      Error(Invalid(
        "remote "
        <> remote.label
        <> " already holds a finished claim or enrollment; pass --label to keep another",
      ))
    Error(error) -> Error(Invalid(simplifile.describe_error(error)))
  }
}

/// Returns the credential to present for this token, writing it first.
///
/// A stored credential is reused only when the `claim` file names the digest
/// of this same token; otherwise a fresh credential is drawn and written,
/// then the `claim` file, each with `bootstrap.atomic_write_private` (mode
/// `0600`). Both writes finish before any connection is attempted.
///
/// ## Examples
///
/// ```gleam
/// // claim.prepare(remote, token)
/// ```
pub fn prepare(remote: Remote, token: String) -> Result(String, String) {
  let claim_digest = claim.digest(token)
  case stored(claim_path(remote)), stored(credential_path(remote)) {
    Ok(named), Ok(credential) if named == claim_digest -> Ok(credential)
    _, _ -> {
      let credential = claim.random_credential()
      use Nil <- result.try(bootstrap.atomic_write_private(
        credential_path(remote),
        credential,
      ))
      use Nil <- result.try(bootstrap.atomic_write_private(
        claim_path(remote),
        claim_digest,
      ))
      Ok(credential)
    }
  }
}

// A stored value is 64 lowercase hex characters in a private file; anything
// else, including a file other users can read, is treated as absent.
fn stored(path: String) -> Result(String, Nil) {
  use bytes <- result.try(
    bootstrap.read_private_bounded(path, 64) |> result.replace_error(Nil),
  )
  use text <- result.try(bit_array.to_string(bytes))
  case claim.is_hex_256(text) {
    True -> Ok(text)
    False -> Error(Nil)
  }
}

// The daemon's answer to the one command, once it has been read.
type Answer {
  Answered(Claimed)
  Final(code: String)
}

/// Presents the claim over `/v2/claim` and sends one credential digest.
///
/// A connection that fails before the command is written binds nothing, but
/// the upgrade's refusal cannot be told from an unreachable daemon, so it is
/// reported as unknown and the credential is kept. Only after the command is
/// sent can the daemon's answer be final.
fn exchange(
  endpoint: String,
  token: String,
  digest: String,
) -> Result(Answer, Failure) {
  let inbox = websocket.new_inbox()
  use socket <- result.try(
    websocket.connect(endpoint, token, inbox)
    |> result.replace_error(Unknown(
      "the claim endpoint refused the upgrade or could not be reached; nothing was sent",
    )),
  )
  let outcome = {
    use Nil <- result.try(
      hello(inbox)
      |> result.replace_error(Unknown(
        "the claim endpoint did not greet; nothing was sent",
      )),
    )
    websocket.send(
      socket,
      json.to_string(
        json.Object([
          #("v", json.Int(2)),
          #("id", json.Int(1)),
          #("cmd", json.String("credentials.claim")),
          #("body", json.Object([#("credential_digest", json.String(digest))])),
        ]),
      ),
    )
    answer(inbox, digest)
  }
  websocket.close(socket)
  outcome
}

fn hello(inbox) -> Result(Nil, Nil) {
  use fields <- result.try(next_event(inbox))
  case list.key_find(fields, "event"), list.key_find(fields, "body") {
    Ok(json.String("hello")), Ok(json.Object(body)) ->
      case list.key_find(body, "protocol") {
        Ok(json.Int(2)) -> Ok(Nil)
        Ok(_) | Error(Nil) -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

// Only these three refusals are final: the claim is unknown or void, it
// expired, or it is bound elsewhere. Anything else leaves the credential in
// place for a rerun.
fn answer(inbox, digest: String) -> Result(Answer, Failure) {
  let unknown =
    Unknown(
      "the claim reply was lost or invalid; rerun the same command to complete or refuse it",
    )
  use fields <- result.try(next_event(inbox) |> result.replace_error(unknown))
  use Nil <- result.try(case list.key_find(fields, "reply_to") {
    Ok(json.Int(1)) -> Ok(Nil)
    Ok(_) | Error(Nil) -> Error(unknown)
  })
  case list.key_find(fields, "event"), list.key_find(fields, "body") {
    Ok(json.String("credentials.claim")), Ok(body) ->
      claimed(body, digest)
      |> result.map(Answered)
      |> result.replace_error(unknown)
    Ok(json.String("error")), Ok(json.Object(body)) ->
      case list.key_find(body, "code") {
        Ok(json.String("not_found")) -> Ok(Final("not_found"))
        Ok(json.String("expired")) -> Ok(Final("expired"))
        Ok(json.String("conflict")) -> Ok(Final("conflict"))
        Ok(json.String(code)) ->
          Error(Unknown(
            "the daemon answered " <> code <> "; rerun the same command",
          ))
        Ok(_) | Error(Nil) -> Error(unknown)
      }
    _, _ -> Error(unknown)
  }
}

// The reply is checked, not trusted: the fingerprint must be this
// credential's, so a reply that names another binding is not reported as
// this one's success.
fn claimed(body: JsonValue, digest: String) -> Result(Claimed, Nil) {
  use fields <- result.try(object(body))
  use principal_id <- result.try(text(fields, "principal_id"))
  use name <- result.try(text(fields, "name"))
  use fingerprint <- result.try(text(fields, "fingerprint"))
  use Nil <- result.try(case fingerprint == string.slice(digest, 0, 16) {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use sessions <- result.try(case list.key_find(fields, "sessions") {
    Ok(json.Array(values)) ->
      list.try_map(values, fn(value) {
        use fields <- result.try(object(value))
        use session_id <- result.try(text(fields, "session_id"))
        use role <- result.try(text(fields, "role"))
        case role {
          "operator" | "observer" -> Ok(Membership(session_id, role))
          _other -> Error(Nil)
        }
      })
    Ok(_) | Error(Nil) -> Error(Nil)
  })
  Ok(Claimed(principal_id, name, fingerprint, sessions))
}

fn next_event(inbox) -> Result(List(#(String, JsonValue)), Nil) {
  use message <- result.try(process.receive(inbox, 10_000))
  case message {
    websocket.Connected -> next_event(inbox)
    websocket.Incoming(text) -> {
      use value <- result.try(json.parse(text) |> result.replace_error(Nil))
      use fields <- result.try(object(value))
      case list.key_find(fields, "v") {
        Ok(json.Int(2)) -> Ok(fields)
        Ok(_) | Error(Nil) -> Error(Nil)
      }
    }
    websocket.Closed(_) | websocket.NetworkFault(_) -> Error(Nil)
  }
}

fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), Nil) {
  case value {
    json.Object(fields) -> Ok(fields)
    _other -> Error(Nil)
  }
}

fn text(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, Nil) {
  case list.key_find(fields, key) {
    Ok(json.String(value)) if value != "" -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// The one line `loom claim` prints on success. It names the credential file
/// and never its contents, and gives a launch line for the first session.
///
/// ## Examples
///
/// ```gleam
/// // json.to_string(claim.report(remote, claimed))
/// ```
pub fn report(remote: Remote, claimed: Claimed) -> JsonValue {
  let launch = case claimed.sessions {
    [first, ..] -> [
      #(
        "launch",
        json.String(
          "loom --addr "
          <> remote.address
          <> " --token-file "
          <> credential_path(remote)
          <> " --session "
          <> first.session_id,
        ),
      ),
    ]
    [] -> []
  }
  json.Object([
    #("principal_id", json.String(claimed.principal_id)),
    #("name", json.String(claimed.name)),
    #("fingerprint", json.String(claimed.fingerprint)),
    #("credential_file", json.String(credential_path(remote))),
    #(
      "sessions",
      json.Array(
        list.map(claimed.sessions, fn(membership) {
          json.Object([
            #("session_id", json.String(membership.session_id)),
            #("role", json.String(membership.role)),
          ])
        }),
      ),
    ),
    ..launch
  ])
}

/// Draws and stores a credential for enrollment by digest, opening no
/// connection, and answers the line to print: the digest, its fingerprint,
/// and the credential file. `remote.json` records the address.
///
/// ## Examples
///
/// ```gleam
/// // claim.enroll(remote)
/// ```
pub fn enroll(remote: Remote) -> Result(JsonValue, Failure) {
  use Nil <- result.try(unfinished(remote))
  let credential = claim.random_credential()
  let digest = claim.digest(credential)
  let written = {
    use Nil <- result.try(bootstrap.atomic_write_private(
      credential_path(remote),
      credential,
    ))

    // A `claim` file left by an earlier attempt names a token this
    // credential was not drawn for; removing it keeps a later `loom claim`
    // from reusing an enrolled credential for a claim.
    let _ = simplifile.delete(claim_path(remote))
    bootstrap.atomic_write_private(
      record_path(remote),
      json.to_string(json.Object([#("addr", json.String(remote.address))])),
    )
  }
  use Nil <- result.try(written |> result.map_error(Invalid))
  Ok(
    json.Object([
      #("credential_digest", json.String(digest)),
      #("fingerprint", json.String(string.slice(digest, 0, 16))),
      #("credential_file", json.String(credential_path(remote))),
    ]),
  )
}

/// A failure as one line of text. It names the refusal and never a token,
/// a credential or a digest.
///
/// ## Examples
///
/// ```gleam
/// assert claim.describe(claim.Refused("expired")) != ""
/// ```
pub fn describe(failure: Failure) -> String {
  case failure {
    Invalid(reason) -> reason
    Refused("conflict") ->
      "conflict: this claim is bound to another credential. Ask the owner to "
      <> "compare credential fingerprints with you and rotate the invitation."
    Refused("expired") ->
      "expired: this claim was not redeemed in time; ask the owner to rotate it"
    Refused(code) ->
      code
      <> ": the claim is unknown, revoked or already spent; ask the owner to rotate it"
    Unknown(reason) -> reason
  }
}
