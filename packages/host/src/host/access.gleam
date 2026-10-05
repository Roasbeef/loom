//// The owner's access commands, shared by `loomd access` and `loom access`
//// (protocol-change/053).
////
//// Both binaries call this module, so a command's grammar, its request, and
//// the lines it prints are one implementation. The grammar is a few
//// positional words in front of one control command. Nothing here starts a
//// daemon or opens a conversation, and nothing here halts the VM: `run`
//// prints and returns an `Outcome`, and each binary turns that into an exit
//// status.
////
//// A command reaches the daemon over the owner's control connection, which
//// is one of two targets. `Local` is the daemon on this host, discovered from
//// its private endpoint record and `owner.token` in the state directory.
//// `Remote` is any daemon reachable over `wss`, with the owner token read from
//// a private file. Remote mode adds no authority: the daemon already
//// authenticates the owner token on any control connection, and remote mode
//// only works if the owner has copied that token to this machine.
////
//// A mutation's outcome is unknown once its request has been sent and no
//// reply has come back. The caller keeps the principal ID it chose and
//// recovers by explicit rotation; nothing retries. A reply is re-encoded from
//// checked fields rather than echoed, so a daemon that answered with a
//// `bearer`, or any other field, could not get it printed. A claim token is
//// printed only for an invitation or rotation that asked for one, and never
//// with a bearer.
////
//// The daemon's own decoder is not available here, since `host` cannot import
//// it. The grammar checks what it can name before a connection is made
//// (identifiers, roles, session IDs, lifetimes, addresses) and leaves the rest
//// to the daemon, which answers `bad_request`.
////
//// ## Flow
////
//// `run` → `run_on` → `parse` → `execute` → `transact_over` → `transact` → `success` → `member_success`
////
//// 1. `run` is `run_on` over the process terminal; a caller with its own
////    output passes a `Console` to `run_on` directly.
//// 2. `run_on` parses first, with `parse_target` for the connection options
////    and `parse_command` for the positional words, then lets the daemon's
////    own checker validate the encoded `envelope` before anything connects.
//// 3. `announce` prints the identity a mutation names, and `execute` picks the
////    target: `Local` goes through `discover`, `Remote` through
////    `read_owner_token`.
//// 4. `transact_over` opens the control connection and `transact` runs the
////    whole conversation: `verify_hello` pins the daemon epoch, `envelope`
////    encodes the one request, and `receive_reply` reads exactly one answer.
//// 5. A refusal becomes `refusal_code`; a matching reply goes to `success`,
////    which re-encodes checked fields only, through `member_success`,
////    `principal_lines` or `membership_lines`.
//// 6. `run_on` prints those lines and returns an `Outcome`; a failure after
////    the send carries `unknown_outcome` so a mutation is never retried.

import core/ids
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import host/claim
import host/endpoint
import host/websocket

/// Which binary is running the command, since the two differ in what they
/// accept and in the name they print.
pub type Program {
  /// `loomd access`: the daemon's own host only, through its state directory.
  Loomd

  /// `loom access`: locally, or against a remote daemon with `--addr` and
  /// `--token-file`.
  Loom
}

/// How a command finished, for the caller to turn into an exit status.
pub type Outcome {
  /// The daemon answered and the reply was printed.
  Succeeded

  /// The command was refused, malformed, or has an unknown outcome. The
  /// reason was printed to standard error.
  Failed
}

/// The largest control frame this side accepts, matching the daemon's.
const max_reply_bytes = 65_536

/// A parsed command with no bearer and no inferred target identity.
@internal
pub opaque type Request {
  Request(
    target: Target,
    kind: Kind,
    command: String,
    subject: String,
    body: List(#(String, JsonValue)),
    claim_address: ClaimAddress,
  )
}

// Where the control connection goes.
type Target {
  // The daemon on this host. An empty directory means `$HOME/.loom`.
  Local(directory: String)

  // A daemon reached over `wss`, or `ws` to a literal loopback address, with
  // the owner token in a private file.
  Remote(address: String, token_file: String)
}

// What the reply is expected to hold, which decides how it is checked and
// printed.
type Kind {
  // A member mutation: the reply names the principal and, for an invitation
  // or rotation, carries a claim.
  Member

  // `sessions.isolate`: the reply names the session and its new scope.
  Isolation

  // A peer command: the reply body is returned as the daemon sent it, since
  // the peer client checks it.
  Passthrough

  // `principals.list`.
  PrincipalListing

  // `principals.memberships`.
  MembershipListing

  // `credentials.signins`: one principal's browser logins, listed (protocol-change/065).
  SigninListing

  // `credentials.revoke_login`: one login ended; the reply names the principal
  // and the fingerprint.
  LoginRevocation
}

// Where the printed `claim_command` points the invitee. An invitation or
// rotation that enrolls a digest, and every other command, prints none.
type ClaimAddress {
  NoClaim

  // The control address this command connected to. For a local command that
  // is the daemon's loopback listener, which works only on the daemon's host.
  DiscoveredAddress

  // An address from `--claim-addr`, already checked by `claim.remote_address`.
  GivenAddress(address: String)
}

// How the epoch in the hello frame is judged. A local command discovered the
// epoch from the endpoint record and requires the daemon to match it. A
// remote command has no earlier source, so it uses the epoch the daemon's own
// hello reports for the connection it just authenticated.
type Epoch {
  Expected(epoch: String)
  Announced
}

const commands_usage =
  "list [--after PRINCIPAL] | show PRINCIPAL [--after SESSION] | invite SESSION PRINCIPAL ROLE NAME [--ttl 30m|24h|7d] [--claim-addr URL | --credential-digest HEX] | set-role SESSION PRINCIPAL ROLE | revoke SESSION PRINCIPAL | rotate PRINCIPAL [--ttl 30m|24h|7d] [--claim-addr URL | --credential-digest HEX] | revoke-credentials PRINCIPAL | signins PRINCIPAL [--after FINGERPRINT] | revoke-login PRINCIPAL FINGERPRINT | isolate SESSION --share-existing-transcript"

/// The complete access-command usage for one binary.
///
/// ## Examples
///
/// ```gleam
/// assert string.starts_with(access.usage(access.Loomd), "usage: loomd access")
/// ```
pub fn usage(program: Program) -> String {
  case program {
    Loomd -> "usage: loomd access [--state-dir PATH] " <> commands_usage
    Loom ->
      "usage: loom access [--state-dir PATH | --addr URL --token-file PATH] "
      <> commands_usage
  }
}

/// Where a command's two output streams go. The binaries use `terminal`; a
/// test collects both to compare what two programs print.
pub type Console {
  Console(
    /// One line of standard output, which carries only a successful reply.
    out: fn(String) -> Nil,
    /// One line of standard error, which carries identities, notes and refusals.
    err: fn(String) -> Nil,
  )
}

/// The process's own standard output and standard error.
///
/// ## Examples
///
/// ```gleam
/// access.run_on(access.terminal(), ["list"], access.Loom, fn(_) { Ok(Nil) })
/// ```
pub fn terminal() -> Console {
  Console(out: io.println, err: io.println_error)
}

/// Runs one access command against the process's standard streams: parses it,
/// announces the identity it will change, exchanges it with the daemon, and
/// prints the reply.
///
/// Standard output carries the reply as JSON lines, and only on success.
/// Standard error carries the identity a mutation names before the request is
/// sent, so an operator whose process dies mid-exchange still has the
/// recovery ID, and carries every refusal. `check` is one more validation of
/// the request's envelope that a caller with the daemon's decoder may add; it
/// can only refuse, never change the request.
///
/// ## Examples
///
/// ```gleam
/// // access.run(["rotate", "alice"], access.Loomd, fn(_) { Ok(Nil) })
/// ```
pub fn run(
  arguments: List(String),
  program: Program,
  check: fn(String) -> Result(Nil, String),
) -> Outcome {
  run_on(terminal(), arguments, program, check)
}

/// Runs one access command against a chosen `Console`.
///
/// ## Examples
///
/// ```gleam
/// // access.run_on(console, ["list"], access.Loom, fn(_) { Ok(Nil) })
/// ```
pub fn run_on(
  console: Console,
  arguments: List(String),
  program: Program,
  check: fn(String) -> Result(Nil, String),
) -> Outcome {
  let parsed = {
    use request <- result.try(parse(arguments, program))
    use Nil <- result.try(check(envelope(request, "validation-only")))
    Ok(request)
  }
  case parsed {
    Error(reason) -> {
      console.err(reason)
      Failed
    }
    Ok(request) -> {
      announce(console, request)
      case execute(request) {
        Ok(lines) -> {
          note_loopback_claim(console, request)
          list.each(lines, fn(line) { console.out(json.to_string(line)) })
          Succeeded
        }
        Error(reason) -> {
          console.err("access: " <> reason <> unknown_outcome(request))
          Failed
        }
      }
    }
  }
}

// The identity a mutation names, printed before the request is sent. Reads
// change nothing and name nothing to recover.
fn announce(console: Console, request: Request) -> Nil {
  case request.kind {
    Member | SigninListing | LoginRevocation ->
      console.err("principal recovery ID: " <> request.subject)
    Isolation -> console.err("session ID: " <> request.subject)
    Passthrough | PrincipalListing | MembershipListing -> Nil
  }
}

// A claim command built from the local loopback listener cannot be run by an
// invitee on another machine, so the owner is told before the line is
// printed. A remote command's address is the one the owner reached, or the
// one they gave.
fn note_loopback_claim(console: Console, request: Request) -> Nil {
  case request.target, request.claim_address {
    Local(_), DiscoveredAddress ->
      console.err(
        "claim_command names this daemon's loopback address, which "
        <> "works only on this host; pass --claim-addr wss://HOST/v2/control "
        <> "for an invitee elsewhere. Send the claim and the command "
        <> "outside Loom, never through a Loom session.",
      )
    Local(_), NoClaim | Local(_), GivenAddress(_) | Remote(..), _ -> Nil
  }
}

// Only a mutation can leave an outcome unknown that a retry could repeat.
fn unknown_outcome(request: Request) -> String {
  case request.kind {
    Member | Isolation | LoginRevocation ->
      "; do not retry an unknown mutation automatically"
    Passthrough | PrincipalListing | MembershipListing | SigninListing -> ""
  }
}

/// Parses the bounded positional command without touching daemon state.
///
/// ## Examples
///
/// ```gleam
/// // access.parse(["rotate", "alice"], access.Loomd)
/// ```
@internal
pub fn parse(
  arguments: List(String),
  program: Program,
) -> Result(Request, String) {
  use #(target, rest) <- result.try(parse_target(arguments, program))
  use request <- result.try(parse_command(target, rest, program))
  use Nil <- result.try(case request.kind {
    Member | MembershipListing | SigninListing | LoginRevocation ->
      valid_principal(request.subject)
    Isolation | Passthrough | PrincipalListing -> Ok(Nil)
  })
  Ok(request)
}

// The leading connection options. `--state-dir` selects a local daemon's
// state; `--addr` with `--token-file` selects a remote one, and only `loom`
// accepts that pair.
type Options {
  Options(
    state_dir: Option(String),
    addr: Option(String),
    token: Option(String),
  )
}

fn parse_target(
  arguments: List(String),
  program: Program,
) -> Result(#(Target, List(String)), String) {
  use #(options, rest) <- result.try(gather_target(
    arguments,
    Options(None, None, None),
    program,
  ))
  case options {
    Options(state_dir:, addr: None, token: None) ->
      Ok(#(Local(option.unwrap(state_dir, "")), rest))
    Options(state_dir: None, addr: Some(address), token: Some(token_file)) -> {
      use Nil <- result.try(
        claim.remote_address(address)
        |> result.map_error(fn(reason) { "--addr: " <> reason }),
      )
      Ok(#(Remote(address, token_file), rest))
    }
    Options(..) ->
      Error(
        "--addr and --token-file go together, and neither combines with --state-dir",
      )
  }
}

fn gather_target(
  arguments: List(String),
  found: Options,
  program: Program,
) -> Result(#(Options, List(String)), String) {
  case arguments, program {
    ["--state-dir", value, ..rest], _ if found.state_dir == None ->
      gather_target(rest, Options(..found, state_dir: Some(value)), program)
    ["--addr", value, ..rest], Loom if found.addr == None ->
      gather_target(rest, Options(..found, addr: Some(value)), program)
    ["--token-file", value, ..rest], Loom if found.token == None ->
      gather_target(rest, Options(..found, token: Some(value)), program)
    ["--addr", ..], Loomd | ["--token-file", ..], Loomd ->
      Error(
        "loomd access runs on the daemon's host; use `loom access --addr URL "
        <> "--token-file PATH` for a remote daemon",
      )
    _, _ -> Ok(#(found, arguments))
  }
}

fn parse_command(
  target: Target,
  arguments: List(String),
  program: Program,
) -> Result(Request, String) {
  case arguments {
    ["list", ..options] -> {
      use after <- result.try(after_option(options, valid_principal))
      Ok(Request(
        target,
        PrincipalListing,
        "principals.list",
        "",
        after_field(after),
        NoClaim,
      ))
    }
    ["show", principal, ..options] -> {
      use after <- result.try(after_option(options, session_id))
      Ok(Request(
        target,
        MembershipListing,
        "principals.memberships",
        principal,
        after_field(after),
        NoClaim,
      ))
    }
    ["isolate", session, "--share-existing-transcript"] -> {
      use Nil <- result.try(session_id(session))
      Ok(Request(
        target,
        Isolation,
        "sessions.isolate",
        session,
        [
          #("session_id", json.String(session)),
          #("transcript", json.String("share_existing")),
        ],
        NoClaim,
      ))
    }
    ["invite", session, principal, role, name, ..options] -> {
      use Nil <- result.try(session_id(session))
      use Nil <- result.try(member_role(role))
      use #(fields, address) <- result.try(enrollment_options(options))
      Ok(Request(
        target,
        Member,
        "sessions.invite",
        principal,
        [
          #("session_id", json.String(session)),
          #("role", json.String(role)),
          #("name", json.String(name)),
          ..fields
        ],
        address,
      ))
    }
    ["set-role", session, principal, role] -> {
      use Nil <- result.try(session_id(session))
      use Nil <- result.try(member_role(role))
      Ok(Request(
        target,
        Member,
        "sessions.set_role",
        principal,
        [#("session_id", json.String(session)), #("role", json.String(role))],
        NoClaim,
      ))
    }
    ["revoke", session, principal] -> {
      use Nil <- result.try(session_id(session))
      Ok(Request(
        target,
        Member,
        "sessions.revoke",
        principal,
        [#("session_id", json.String(session))],
        NoClaim,
      ))
    }
    ["rotate", principal, ..options] -> {
      use #(fields, address) <- result.try(enrollment_options(options))
      Ok(Request(
        target,
        Member,
        "credentials.rotate",
        principal,
        fields,
        address,
      ))
    }
    ["revoke-credentials", principal] ->
      Ok(Request(target, Member, "credentials.revoke", principal, [], NoClaim))
    ["signins", principal, ..options] -> {
      use after <- result.try(after_option(options, fingerprint))
      Ok(Request(
        target,
        SigninListing,
        "credentials.signins",
        principal,
        after_field(after),
        NoClaim,
      ))
    }
    ["revoke-login", principal, login] -> {
      use Nil <- result.try(fingerprint(login))
      Ok(Request(
        target,
        LoginRevocation,
        "credentials.revoke_login",
        principal,
        [#("fingerprint", json.String(login))],
        NoClaim,
      ))
    }
    _other -> Error(usage(program))
  }
}

// `--after VALUE`, or nothing. A cursor is checked with the same rule the
// daemon applies to it, so a typo is named before a connection is made.
fn after_option(
  options: List(String),
  check: fn(String) -> Result(Nil, String),
) -> Result(String, String) {
  case options {
    [] -> Ok("")
    ["--after", value] -> result.map(check(value), fn(_) { value })
    _other -> Error("expected only --after CURSOR")
  }
}

fn after_field(after: String) -> List(#(String, JsonValue)) {
  case after {
    "" -> []
    cursor -> [#("after", json.String(cursor))]
  }
}

/// Builds a request the peer commands send through this module's transport,
/// with the reply body returned unchanged for the peer client to check.
///
/// ## Examples
///
/// ```gleam
/// // access.raw_request("", "peers.inspect", source_session, fields)
/// ```
@internal
pub fn raw_request(
  directory: String,
  command: String,
  subject: String,
  fields: List(#(String, JsonValue)),
) -> Request {
  Request(Local(directory), Passthrough, command, subject, fields, NoClaim)
}

// The options an invitation or rotation takes, gathered whole before any
// field is built. `--credential-digest` enrolls the invitee's own credential
// and creates no claim, so it excludes both claim options: a lifetime or an
// address for a claim that will not exist names nothing.
type EnrollmentOptions {
  EnrollmentOptions(ttl: String, address: String, digest: String)
}

fn enrollment_options(
  options: List(String),
) -> Result(#(List(#(String, JsonValue)), ClaimAddress), String) {
  use found <- result.try(gather_options(options, EnrollmentOptions("", "", "")))
  case found {
    EnrollmentOptions(ttl: "", address: "", digest: "") ->
      Ok(#([], DiscoveredAddress))
    EnrollmentOptions(ttl:, address:, digest: "") -> {
      use ttl <- result.try(ttl_field(ttl))
      use address <- result.try(case address {
        "" -> Ok(DiscoveredAddress)
        given ->
          claim.remote_address(given)
          |> result.map(fn(_) { GivenAddress(given) })
          |> result.map_error(fn(reason) { "--claim-addr: " <> reason })
      })
      Ok(#(ttl, address))
    }
    EnrollmentOptions(ttl: "", address: "", digest:) ->
      case claim.is_hex_256(digest) {
        True -> Ok(#([#("credential_digest", json.String(digest))], NoClaim))
        False -> Error("--credential-digest takes 64 lowercase hex characters")
      }
    EnrollmentOptions(..) ->
      Error("--credential-digest cannot be combined with --ttl or --claim-addr")
  }
}

fn gather_options(
  options: List(String),
  found: EnrollmentOptions,
) -> Result(EnrollmentOptions, String) {
  case options {
    [] -> Ok(found)
    ["--ttl", value, ..rest] if found.ttl == "" ->
      gather_options(rest, EnrollmentOptions(..found, ttl: value))
    ["--claim-addr", value, ..rest] if found.address == "" ->
      gather_options(rest, EnrollmentOptions(..found, address: value))
    ["--credential-digest", value, ..rest] if found.digest == "" ->
      gather_options(rest, EnrollmentOptions(..found, digest: value))
    _other -> Error("unrecognized or repeated invitation option")
  }
}

// `--ttl` takes a count of minutes, hours or days. The daemon holds the
// range, 5 minutes to 7 days, and refuses anything outside it; the bound is
// repeated here only so the mistake is named before a connection is made.
fn ttl_field(text: String) -> Result(List(#(String, JsonValue)), String) {
  use <- bool.guard(when: text == "", return: Ok([]))
  let unit = string.slice(text, string.length(text) - 1, 1)
  use count <- result.try(
    int.parse(string.drop_end(text, 1))
    |> result.replace_error("--ttl takes a form such as 30m, 24h or 7d"),
  )
  use multiplier <- result.try(case unit {
    "m" -> Ok(60_000)
    "h" -> Ok(3_600_000)
    "d" -> Ok(86_400_000)
    _other -> Error("--ttl takes a form such as 30m, 24h or 7d")
  })
  let ttl = count * multiplier
  case ttl >= 300_000 && ttl <= 604_800_000 {
    True -> Ok([#("claim_ttl_ms", json.Int(ttl))])
    False -> Error("--ttl must be between 5 minutes and 7 days")
  }
}

fn valid_principal(id: String) -> Result(Nil, String) {
  case
    string.byte_size(id) > 0
    && string.byte_size(id) <= 128
    && list.all(string.to_graphemes(id), fn(char) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.",
        char,
      )
    })
  {
    True -> Ok(Nil)
    False -> Error("principal ID must be 1-128 ASCII identifier bytes")
  }
}

fn session_id(text: String) -> Result(Nil, String) {
  ids.parse_session_id(text)
  |> result.replace(Nil)
  |> result.replace_error("session ID must be a canonical session identity")
}

fn member_role(text: String) -> Result(Nil, String) {
  case text {
    "operator" | "observer" -> Ok(Nil)
    _other -> Error("role must be operator or observer")
  }
}

/// The request as the daemon receives it, for a caller that validates it with
/// the daemon's own decoder before any connection is made.
///
/// ## Examples
///
/// ```gleam
/// // access.envelope(request, "validation-only")
/// ```
@internal
pub fn envelope(request: Request, epoch: String) -> String {
  // A member command names its principal in the body, and a listing of one
  // principal's memberships does too. Listings read and change nothing, so
  // they carry no epoch to fence.
  let identity = case request.kind {
    Member | MembershipListing | SigninListing | LoginRevocation -> [
      #("principal_id", json.String(request.subject)),
    ]
    Isolation | Passthrough | PrincipalListing -> []
  }
  let fenced = case request.kind {
    PrincipalListing | MembershipListing | SigninListing -> request.body
    Member | Isolation | Passthrough | LoginRevocation -> [
      #("epoch", json.String(epoch)),
      ..request.body
    ]
  }
  json.to_string(
    json.Object([
      #("v", json.Int(2)),
      #("id", json.Int(1)),
      #("cmd", json.String(request.command)),
      #("body", json.Object(list.append(identity, fenced))),
    ]),
  )
}

/// Discovers the daemon, exchanges the request, and answers the lines to
/// print. Discovery never starts a daemon.
///
/// ## Examples
///
/// ```gleam
/// // access.execute(request)
/// ```
@internal
pub fn execute(request: Request) -> Result(List(JsonValue), String) {
  case request.target {
    Local(directory) -> {
      use #(address, token, epoch) <- result.try(discover(directory))
      transact_over(address, token, Expected(epoch), request)
    }
    Remote(address:, token_file:) -> {
      use token <- result.try(read_owner_token(token_file))
      transact_over(address, token, Announced, request)
    }
  }
}

/// Discovers the private owner control endpoint. Local discovery failures
/// are reported as such, so a caller does not present them as daemon
/// refusals.
///
/// ## Examples
///
/// ```gleam
/// // access.discover("/private/loom")
/// ```
@internal
pub fn discover(
  directory: String,
) -> Result(#(String, String, String), String) {
  use directory <- result.try(case directory {
    "" ->
      bootstrap.getenv("HOME")
      |> result.map(fn(home) { home <> "/.loom" })
      |> result.replace_error("HOME is unset; pass --state-dir")
    path -> Ok(path)
  })

  // Requiring an existing directory precedes paths(), which also serves launchers.
  use directory <- result.try(
    bootstrap.canonical_directory(directory)
    |> result.replace_error("the daemon state directory does not exist"),
  )
  use paths <- result.try(endpoint.paths(directory))
  use record <- result.try(endpoint.load(paths))
  use #(record, epoch) <- result.try(ready_record(record))
  use address <- result.try(endpoint.address(record))
  use token <- result.try(read_owner_token(paths.token))
  Ok(#(address, token, epoch))
}

fn ready_record(record) {
  case record {
    None | Some(endpoint.Starting(_)) -> Error("no ready local daemon")
    Some(endpoint.Ready(fence, _, _, epoch, _) as record) -> {
      use present <- result.try(endpoint.is_present(fence))
      case present {
        True -> Ok(#(record, epoch))
        False -> Error("the published daemon has exited")
      }
    }
  }
}

// The owner token is read through the bounded private-file rule, which
// refuses a link, another user's file, or one other users can read. A file
// holding a claim token is named as such, since the two are easily confused.
fn read_owner_token(path: String) -> Result(String, String) {
  use bytes <- result.try(bootstrap.read_private_bounded(path, 80))
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("invalid private credential"),
  )
  let token = string.trim(text)
  use <- bool.guard(
    when: claim.is_claim_shaped(token),
    return: Error(
      "that file holds a claim token, not the owner credential; redeem a claim with loom claim",
    ),
  )
  case claim.is_hex_256(token) {
    True -> Ok(token)
    False -> Error("invalid private credential")
  }
}

/// Exchanges one request with an already discovered listener.
///
/// This host/test seam does not discover or start a daemon. The original
/// reader must outlive this call; close is requested on every returned
/// outcome, and reader death independently closes the socket.
///
/// ## Examples
///
/// ```gleam
/// // access.exchange(address, owner_token, epoch, request)
/// ```
@internal
pub fn exchange(
  address: String,
  token: String,
  epoch: String,
  request: Request,
) -> Result(List(JsonValue), String) {
  transact_over(address, token, Expected(epoch), request)
}

fn transact_over(
  address: String,
  token: String,
  epoch: Epoch,
  request: Request,
) -> Result(List(JsonValue), String) {
  let inbox = websocket.new_inbox()
  use socket <- result.try(
    websocket.connect(address, token, inbox)
    |> result.replace_error("control connection failed; request not sent"),
  )
  let outcome = transact(socket, inbox, address, epoch, request)
  websocket.close(socket)
  outcome
}

fn transact(socket, inbox, address, epoch: Epoch, request: Request) {
  use announced <- result.try(
    verify_hello(inbox, epoch)
    |> result.replace_error("control handshake failed; request not sent"),
  )
  websocket.send(socket, envelope(request, announced))

  // Only failures after this one send have an unknown mutation outcome.
  use #(fields, body) <- result.try(
    receive_reply(inbox)
    |> result.replace_error(
      "control response missing or invalid; outcome unknown",
    ),
  )
  case list.key_find(fields, "event") {
    Ok(json.String("error")) -> {
      use body <- result.try(
        object_fields(body)
        |> result.replace_error("invalid refusal reply; outcome unknown"),
      )
      Error(refusal_code(body))
    }
    Ok(json.String(event)) if event == request.command ->
      success(body, address, request)
      |> result.replace_error("invalid successful reply; outcome unknown")
    Ok(_) | Error(Nil) ->
      Error("unexpected administration reply; outcome unknown")
  }
}

// The hello frame names the daemon lifetime. A local command holds the epoch
// it discovered and requires the same; a remote command adopts the one the
// authenticated connection announces.
fn verify_hello(inbox, epoch: Epoch) -> Result(String, String) {
  use hello <- result.try(next_frame(inbox))
  use fields <- result.try(event_fields(hello))
  use Nil <- result.try(equal_field(fields, "event", json.String("hello")))
  use body <- result.try(body_fields(fields))
  use Nil <- result.try(equal_field(body, "protocol", json.Int(2)))
  use announced <- result.try(case list.key_find(body, "epoch") {
    Ok(json.String(text)) if text != "" -> Ok(text)
    Ok(_) | Error(Nil) -> Error("response identity or epoch mismatch")
  })
  case epoch {
    Announced -> Ok(announced)
    Expected(expected) if expected == announced -> Ok(announced)
    Expected(_) -> Error("response identity or epoch mismatch")
  }
}

fn receive_reply(inbox) {
  use reply <- result.try(next_frame(inbox))
  use fields <- result.try(event_fields(reply))
  use Nil <- result.try(equal_field(fields, "reply_to", json.Int(1)))
  use body <- result.try(
    list.key_find(fields, "body")
    |> result.replace_error("missing response body"),
  )
  Ok(#(fields, body))
}

fn next_frame(inbox) {
  use message <- result.try(
    process.receive(inbox, 5000)
    |> result.replace_error("control response timed out"),
  )
  case message {
    websocket.Connected ->
      process.receive(inbox, 5000)
      |> result.replace_error("control response timed out")
      |> result.try(text_frame)
    websocket.Incoming(_) as incoming -> text_frame(incoming)
    websocket.Closed(_) as closed -> text_frame(closed)
    websocket.NetworkFault(_) as fault -> text_frame(fault)
  }
}

fn text_frame(message) {
  case message {
    websocket.Incoming(text) -> Ok(text)
    websocket.Connected | websocket.Closed(_) | websocket.NetworkFault(_) ->
      Error("control connection ended")
  }
}

fn event_fields(text) {
  use Nil <- result.try(case string.byte_size(text) <= max_reply_bytes {
    True -> Ok(Nil)
    False -> Error("oversized control response")
  })
  use value <- result.try(
    json.parse(text) |> result.replace_error("invalid control response"),
  )
  use fields <- result.try(object_fields(value))
  use Nil <- result.try(equal_field(fields, "v", json.Int(2)))
  Ok(fields)
}

fn body_fields(fields) {
  use body <- result.try(
    list.key_find(fields, "body")
    |> result.replace_error("missing response body"),
  )
  object_fields(body)
}

fn object_fields(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    _other -> Error("invalid response object")
  }
}

fn equal_field(fields, key, expected) {
  case list.key_find(fields, key) == Ok(expected) {
    True -> Ok(Nil)
    False -> Error("response identity or epoch mismatch")
  }
}

/// Checks a successful reply body and answers the lines to print.
///
/// Every reply but a peer command's is re-encoded from checked fields, so an
/// extra field the daemon sent is dropped rather than printed.
///
/// ## Examples
///
/// ```gleam
/// // access.success(body, address, request)
/// ```
@internal
pub fn success(
  body: JsonValue,
  address: String,
  request: Request,
) -> Result(List(JsonValue), String) {
  case request.kind {
    Passthrough -> Ok([body])
    Isolation -> {
      use fields <- result.try(object_fields(body))
      use Nil <- result.try(equal_field(
        fields,
        "session_id",
        json.String(request.subject),
      ))
      use Nil <- result.try(equal_field(
        fields,
        "domain_scope",
        json.String("session_only"),
      ))
      Ok([
        json.Object([
          #("session_id", json.String(request.subject)),
          #("domain_scope", json.String("session_only")),
        ]),
      ])
    }
    Member -> {
      use fields <- result.try(object_fields(body))
      use line <- result.map(member_success(fields, address, request))
      [line]
    }
    PrincipalListing -> principal_lines(body)
    MembershipListing -> membership_lines(body, request.subject)
    SigninListing -> signin_lines(body, request.subject)
    LoginRevocation -> {
      use fields <- result.try(object_fields(body))
      use Nil <- result.try(equal_field(
        fields,
        "principal_id",
        json.String(request.subject),
      ))
      use login <- result.try(text_field(fields, "fingerprint"))
      use Nil <- result.try(fingerprint(login))
      Ok([
        json.Object([
          #("principal_id", json.String(request.subject)),
          #("fingerprint", json.String(login)),
        ]),
      ])
    }
  }
}

/// Checks a `credentials.signins` reply body for `principal` and answers its
/// lines, in the shape `principal_lines` answers: one checked row for each
/// browser login, then `{"next": CURSOR}` when another page follows. A row is a
/// 16-digit fingerprint and times, and never a token, so nothing printed could
/// sign a browser in. A reply that names another principal is refused.
///
/// ## Examples
///
/// ```gleam
/// // access.signin_lines(body, "alice")
/// ```
pub fn signin_lines(
  body: JsonValue,
  principal: String,
) -> Result(List(JsonValue), String) {
  use fields <- result.try(object_fields(body))
  use Nil <- result.try(equal_field(
    fields,
    "principal_id",
    json.String(principal),
  ))
  page_lines(fields, "signins", signin_row)
}

/// Checks a `principals.list` reply body and answers its lines: one checked
/// row per principal, then `{"next": CURSOR}` when the daemon says another
/// page follows.
///
/// This is the check `loom access list` prints through, exposed so a caller
/// that draws the listing itself, such as the terminal's `/access` overlay,
/// accepts exactly the rows the command line would print. A row that fails
/// its check fails the whole reply.
///
/// ## Examples
///
/// ```gleam
/// // access.principal_lines(body)
/// ```
pub fn principal_lines(body: JsonValue) -> Result(List(JsonValue), String) {
  use fields <- result.try(object_fields(body))
  page_lines(fields, "principals", listing_row)
}

/// Checks a `principals.memberships` reply body for `principal` and answers
/// its lines, in the shape `principal_lines` answers.
///
/// A reply that names another principal is refused, so a late answer to an
/// earlier request cannot be drawn under the wrong principal.
///
/// ## Examples
///
/// ```gleam
/// // access.membership_lines(body, "alice")
/// ```
pub fn membership_lines(
  body: JsonValue,
  principal: String,
) -> Result(List(JsonValue), String) {
  use fields <- result.try(object_fields(body))
  use Nil <- result.try(equal_field(
    fields,
    "principal_id",
    json.String(principal),
  ))
  page_lines(fields, "memberships", membership_row)
}

/// The `loom access` line that invites a new member to `session`, with
/// placeholders where the owner chooses the new member's identity.
///
/// The owner runs it in a shell. Nothing in Loom's terminal runs it or holds
/// its output, because an invitation prints a claim.
///
/// ## Examples
///
/// ```gleam
/// assert access.invite_line("")
///   == "loom access invite SESSION PRINCIPAL ROLE NAME"
/// ```
pub fn invite_line(session: String) -> String {
  let session = case session {
    "" -> "SESSION"
    id -> id
  }
  "loom access invite " <> session <> " PRINCIPAL ROLE NAME"
}

/// The `loom access` line that rotates `principal`'s credential, which
/// prints a new claim for the owner to send.
///
/// ## Examples
///
/// ```gleam
/// assert access.rotate_line("alice") == "loom access rotate alice"
/// ```
pub fn rotate_line(principal: String) -> String {
  "loom access rotate " <> principal
}

// A member reply is re-encoded from checked fields rather than echoed. A claim
// is printed only when this request asked for one.
fn member_success(fields, address, request: Request) {
  use Nil <- result.try(equal_field(
    fields,
    "principal_id",
    json.String(request.subject),
  ))
  use name <- result.try(case list.key_find(fields, "name") {
    Ok(json.String(name)) -> Ok(name)
    Ok(_) | Error(Nil) -> Error("missing successful member name")
  })
  let identity = [
    #("principal_id", json.String(request.subject)),
    #("name", json.String(name)),
  ]
  case request.command, request.claim_address {
    "sessions.invite", GivenAddress(given)
    | "credentials.rotate", GivenAddress(given)
    -> claimed(fields, identity, given)
    "sessions.invite", DiscoveredAddress
    | "credentials.rotate", DiscoveredAddress
    -> claimed(fields, identity, address)
    "sessions.invite", NoClaim
    | "credentials.rotate", NoClaim
    | "sessions.set_role", _
    | "sessions.revoke", _
    | "credentials.revoke", _
    -> Ok(json.Object(identity))
    _other, _ -> Error("unsupported administration reply")
  }
}

// `claim_command` names the address and never the token, so the invitee's
// shell history and argument vector hold no secret by default.
fn claimed(fields, identity, address: String) {
  use token <- result.try(case list.key_find(fields, "claim") {
    Ok(json.String(token)) -> Ok(token)
    Ok(_) | Error(Nil) -> Error("missing successful claim")
  })
  use Nil <- result.try(claim.validate_token(token))
  use expires_in_ms <- result.try(case list.key_find(fields, "expires_in_ms") {
    Ok(json.Int(value)) if value > 0 -> Ok(value)
    Ok(_) | Error(Nil) -> Error("missing claim lifetime")
  })
  Ok(
    json.Object(
      list.append(identity, [
        #("claim", json.String(token)),
        #("expires_in_ms", json.Int(expires_in_ms)),
        #("claim_command", json.String("loom claim --addr " <> address)),
      ]),
    ),
  )
}

// One line per row, then `{"next": CURSOR}` when the daemon says another page
// follows. A row that fails its check fails the whole reply: printing the rows
// before it would show the owner a partial listing as a complete one.
fn page_lines(
  fields: List(#(String, JsonValue)),
  key: String,
  row: fn(JsonValue) -> Result(JsonValue, String),
) -> Result(List(JsonValue), String) {
  use rows <- result.try(case list.key_find(fields, key) {
    Ok(json.Array(rows)) -> Ok(rows)
    Ok(_) | Error(Nil) -> Error("missing listing rows")
  })
  use lines <- result.try(list.try_map(rows, row))
  case list.key_find(fields, "next") {
    Error(Nil) -> Ok(lines)
    Ok(json.String(cursor)) if cursor != "" ->
      Ok(list.append(lines, [json.Object([#("next", json.String(cursor))])]))
    Ok(_) -> Error("invalid listing continuation")
  }
}

fn listing_row(value: JsonValue) -> Result(JsonValue, String) {
  use fields <- result.try(object_fields(value))
  use id <- result.try(text_field(fields, "principal_id"))
  use Nil <- result.try(valid_principal(id))
  use name <- result.try(text_field(fields, "name"))
  use kind <- result.try(case list.key_find(fields, "kind") {
    Ok(json.String("owner")) -> Ok("owner")
    Ok(json.String("member")) -> Ok("member")
    Ok(_) | Error(Nil) -> Error("invalid principal kind")
  })
  use credential <- result.try(case list.key_find(fields, "credential") {
    Ok(found) -> credential_state(found)
    Error(Nil) -> Error("missing credential state")
  })
  use logins <- result.map(case list.key_find(fields, "logins") {
    Error(Nil) -> Ok([])
    Ok(json.Int(count)) if count >= 0 -> Ok([#("logins", json.Int(count))])
    Ok(_) -> Error("invalid login count")
  })
  json.Object(list.append(
    [
      #("principal_id", json.String(id)),
      #("name", json.String(name)),
      #("kind", json.String(kind)),
      #("credential", credential),
    ],
    logins,
  ))
}

// One browser login, rebuilt from checked fields. The fingerprint and the
// parent's are exactly 16 lowercase hexadecimal digits and the times are
// non-negative integers, so no longer value can ride in a field.
fn signin_row(value: JsonValue) -> Result(JsonValue, String) {
  use fields <- result.try(object_fields(value))
  use login <- result.try(text_field(fields, "fingerprint"))
  use Nil <- result.try(fingerprint(login))
  use issued <- result.try(case list.key_find(fields, "issued_at_ms") {
    Ok(json.Int(at)) if at >= 0 -> Ok(at)
    Ok(_) | Error(Nil) -> Error("invalid sign-in instant")
  })
  use resumed <- result.try(optional_instant(fields, "last_resumed_ms"))
  use expires <- result.try(optional_instant(fields, "expires_at_ms"))
  use parent <- result.map(case list.key_find(fields, "issued_by") {
    Error(Nil) -> Ok([])
    Ok(json.String(from)) ->
      fingerprint(from)
      |> result.map(fn(_) { [#("issued_by", json.String(from))] })
    Ok(_) -> Error("invalid sign-in parent")
  })
  json.Object(
    list.flatten([
      [
        #("fingerprint", json.String(login)),
        #("issued_at_ms", json.Int(issued)),
      ],
      resumed,
      expires,
      parent,
    ]),
  )
}

fn optional_instant(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(List(#(String, JsonValue)), String) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok([])
    Ok(json.Int(at)) if at >= 0 -> Ok([#(key, json.Int(at))])
    Ok(_) -> Error("invalid sign-in instant")
  }
}

// A login's fingerprint: the first sixteen hexadecimal digits of its digest,
// lowercase.
fn fingerprint(value: String) -> Result(Nil, String) {
  case
    string.byte_size(value) == 16 && claim.is_hex_256(string.repeat(value, 4))
  {
    True -> Ok(Nil)
    False -> Error("a fingerprint is 16 lowercase hex characters")
  }
}

// The four states the daemon reports, each rebuilt from checked fields. A
// fingerprint is exactly 16 lowercase hexadecimal characters, which is what
// keeps a full credential from riding in the field.
fn credential_state(value: JsonValue) -> Result(JsonValue, String) {
  use fields <- result.try(object_fields(value))
  use state <- result.try(text_field(fields, "state"))
  case state {
    "active" -> {
      use fingerprint <- result.try(text_field(fields, "fingerprint"))
      use Nil <- result.try(
        case
          string.byte_size(fingerprint) == 16
          && claim.is_hex_256(string.repeat(fingerprint, 4))
        {
          True -> Ok(Nil)
          False -> Error("invalid credential fingerprint")
        },
      )
      use claimed <- result.map(case list.key_find(fields, "claimed_at_ms") {
        Error(Nil) -> Ok([])
        Ok(json.Int(at)) if at >= 0 -> Ok([#("claimed_at_ms", json.Int(at))])
        Ok(_) -> Error("invalid claim instant")
      })
      json.Object(list.append(
        [
          #("state", json.String("active")),
          #("fingerprint", json.String(fingerprint)),
        ],
        claimed,
      ))
    }
    "claim_open" -> {
      use remaining <- result.map(case list.key_find(fields, "expires_in_ms") {
        Ok(json.Int(ms)) if ms >= 0 -> Ok(ms)
        Ok(_) | Error(Nil) -> Error("invalid claim lifetime")
      })
      json.Object([
        #("state", json.String("claim_open")),
        #("expires_in_ms", json.Int(remaining)),
      ])
    }
    "claim_expired" ->
      Ok(json.Object([#("state", json.String("claim_expired"))]))
    "none" -> Ok(json.Object([#("state", json.String("none"))]))
    _other -> Error("unknown credential state")
  }
}

fn membership_row(value: JsonValue) -> Result(JsonValue, String) {
  use fields <- result.try(object_fields(value))
  use session <- result.try(text_field(fields, "session_id"))
  use Nil <- result.try(session_id(session))
  use name <- result.try(text_field(fields, "name"))
  use role <- result.try(case list.key_find(fields, "role") {
    Ok(json.String("operator")) -> Ok("operator")
    Ok(json.String("observer")) -> Ok("observer")
    Ok(_) | Error(Nil) -> Error("invalid membership role")
  })
  Ok(
    json.Object([
      #("session_id", json.String(session)),
      #("name", json.String(name)),
      #("role", json.String(role)),
    ]),
  )
}

fn text_field(fields, key: String) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Ok(text)
    Ok(_) | Error(Nil) -> Error("missing " <> key)
  }
}

fn refusal_code(fields) {
  case list.key_find(fields, "code") {
    Ok(json.String("forbidden")) -> "forbidden"
    Ok(json.String("conflict")) -> "conflict"
    Ok(json.String("not_found")) -> "not_found"
    Ok(json.String("stale_epoch")) -> "stale_epoch"
    Ok(json.String("bad_request")) -> "bad_request"
    Ok(json.String("isolation_required")) ->
      "isolation_required: stop the session and explicitly isolate its existing transcript before sharing"
    Ok(json.String(code)) -> code
    Ok(_) | Error(Nil) -> "administration refused"
  }
}
