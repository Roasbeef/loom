//// The shared access grammar, the replies it re-encodes, and the two
//// programs' agreement on both (protocol-change/053).
////
//// Nothing here opens a connection. The exchange itself is driven against a
//// real daemon listener in `client/daemon_access_test`; these tests hold the
//// pure parts: what a command line becomes, what a reply is allowed to print,
//// and which refusals happen before any socket exists.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/string
import host/access
import host/bootstrap
import simplifile

const session = "0198c0de-0000-7000-8000-000000000001"

fn hex(char: String) -> String {
  string.repeat(char, 64)
}

fn envelope(arguments: List(String), program: access.Program) -> String {
  let assert Ok(request) = access.parse(arguments, program)
    as "the command line parses"
  access.envelope(request, "epoch-1")
}

fn refusal(arguments: List(String), program: access.Program) -> String {
  let assert Error(reason) = access.parse(arguments, program)
    as "the command line is refused"
  reason
}

pub fn every_command_becomes_the_request_the_daemon_decodes_test() {
  assert envelope(["rotate", "alice", "--ttl", "30m"], access.Loomd)
    == "{\"v\":2,\"id\":1,\"cmd\":\"credentials.rotate\",\"body\":{\"principal_id\":\"alice\",\"epoch\":\"epoch-1\",\"claim_ttl_ms\":1800000}}"
  assert envelope(["revoke-credentials", "alice"], access.Loomd)
    == "{\"v\":2,\"id\":1,\"cmd\":\"credentials.revoke\",\"body\":{\"principal_id\":\"alice\",\"epoch\":\"epoch-1\"}}"
  assert envelope(["revoke", session, "alice"], access.Loomd)
    == "{\"v\":2,\"id\":1,\"cmd\":\"sessions.revoke\",\"body\":{\"principal_id\":\"alice\",\"epoch\":\"epoch-1\",\"session_id\":\""
    <> session
    <> "\"}}"
  assert envelope(
      ["isolate", session, "--share-existing-transcript"],
      access.Loomd,
    )
    == "{\"v\":2,\"id\":1,\"cmd\":\"sessions.isolate\",\"body\":{\"epoch\":\"epoch-1\",\"session_id\":\""
    <> session
    <> "\",\"transcript\":\"share_existing\"}}"
  assert envelope(
      ["rotate", "alice", "--credential-digest", hex("a")],
      access.Loom,
    )
    == "{\"v\":2,\"id\":1,\"cmd\":\"credentials.rotate\",\"body\":{\"principal_id\":\"alice\",\"epoch\":\"epoch-1\",\"credential_digest\":\""
    <> hex("a")
    <> "\"}}"
}

pub fn listings_carry_a_cursor_and_no_epoch_test() {
  assert envelope(["list"], access.Loom)
    == "{\"v\":2,\"id\":1,\"cmd\":\"principals.list\",\"body\":{}}"
  assert envelope(["list", "--after", "alice"], access.Loom)
    == "{\"v\":2,\"id\":1,\"cmd\":\"principals.list\",\"body\":{\"after\":\"alice\"}}"
  assert envelope(["show", "alice"], access.Loom)
    == "{\"v\":2,\"id\":1,\"cmd\":\"principals.memberships\",\"body\":{\"principal_id\":\"alice\"}}"
  assert envelope(["show", "alice", "--after", session], access.Loom)
    == "{\"v\":2,\"id\":1,\"cmd\":\"principals.memberships\",\"body\":{\"principal_id\":\"alice\",\"after\":\""
    <> session
    <> "\"}}"
}

pub fn both_programs_parse_every_local_command_to_the_same_request_test() {
  let commands = [
    ["list"],
    ["list", "--after", "alice"],
    ["show", "alice"],
    ["show", "alice", "--after", session],
    ["invite", session, "alice", "operator", "Alice"],
    ["invite", session, "alice", "observer", "Alice", "--ttl", "7d"],
    [
      "invite", session, "alice", "observer", "Alice", "--claim-addr",
      "wss://loom.example.com/v2/control",
    ],
    [
      "invite",
      session,
      "alice",
      "observer",
      "Alice",
      "--credential-digest",
      hex("b"),
    ],
    ["set-role", session, "alice", "operator"],
    ["revoke", session, "alice"],
    ["rotate", "alice"],
    ["revoke-credentials", "alice"],
    ["signins", "alice"],
    ["signins", "alice", "--after", "0123456789abcdef"],
    ["revoke-login", "alice", "0123456789abcdef"],
    ["isolate", session, "--share-existing-transcript"],
  ]
  list.each(commands, fn(arguments) {
    assert access.parse(arguments, access.Loomd)
      == access.parse(arguments, access.Loom)
    assert access.parse(["--state-dir", "/x", ..arguments], access.Loomd)
      == access.parse(["--state-dir", "/x", ..arguments], access.Loom)
  })
}

pub fn only_loom_reaches_a_remote_daemon_and_only_with_both_options_test() {
  let remote = [
    "--addr", "wss://loom.example.com/v2/control", "--token-file", "/t", "list",
  ]
  let assert Ok(_) = access.parse(remote, access.Loom)
    as "loom access takes a remote address and its token file"
  assert string.contains(refusal(remote, access.Loomd), "loom access --addr")
  assert string.contains(
    refusal(
      ["--addr", "wss://loom.example.com/v2/control", "list"],
      access.Loom,
    ),
    "go together",
  )
  assert string.contains(
    refusal(["--token-file", "/t", "list"], access.Loom),
    "go together",
  )
  assert string.contains(
    refusal(
      [
        "--state-dir", "/s", "--addr", "wss://loom.example.com/v2/control",
        "--token-file", "/t", "list",
      ],
      access.Loom,
    ),
    "go together",
  )
}

pub fn a_remote_address_keeps_the_owner_token_off_cleartext_hops_test() {
  let insecure = [
    "--addr", "ws://loom.example.com/v2/control", "--token-file", "/t", "list",
  ]
  assert string.contains(refusal(insecure, access.Loom), "requires TLS")
  let wrong_path = [
    "--addr", "wss://loom.example.com/v2/claim", "--token-file", "/t", "list",
  ]
  let assert Error(_) = access.parse(wrong_path, access.Loom)
  let loopback = [
    "--addr", "ws://127.0.0.1:4000/v2/control", "--token-file", "/t", "list",
  ]
  let assert Ok(_) = access.parse(loopback, access.Loom)
    as "a literal loopback address may use ws"
}

pub fn arguments_are_checked_before_any_connection_is_made_test() {
  let usage = access.usage(access.Loomd)
  assert refusal([], access.Loomd) == usage
  assert refusal(["frobnicate"], access.Loomd) == usage
  assert refusal(["list", "extra"], access.Loomd)
    == "expected only --after CURSOR"
  assert string.contains(
    refusal(["show", "alice", "--after", "not-a-session"], access.Loom),
    "session ID",
  )
  assert string.contains(
    refusal(["list", "--after", "bad id"], access.Loom),
    "principal ID",
  )
  assert string.contains(
    refusal(["show", "bad id"], access.Loom),
    "principal ID",
  )
  assert string.contains(
    refusal(["invite", "nope", "alice", "operator", "Alice"], access.Loom),
    "session ID",
  )
  assert string.contains(
    refusal(["invite", session, "alice", "owner", "Alice"], access.Loom),
    "operator or observer",
  )
  assert string.contains(
    refusal(["set-role", session, "alice", "admin"], access.Loom),
    "operator or observer",
  )
  assert string.contains(
    refusal(["rotate", "a b"], access.Loom),
    "principal ID",
  )
  assert string.contains(
    refusal(["rotate", "alice", "--ttl", "1m"], access.Loom),
    "between 5 minutes and 7 days",
  )
  assert string.contains(
    refusal(["rotate", "alice", "--credential-digest", "abc"], access.Loom),
    "64 lowercase hex",
  )
  assert string.contains(
    refusal(
      ["rotate", "alice", "--credential-digest", hex("a"), "--ttl", "1h"],
      access.Loom,
    ),
    "cannot be combined",
  )
  assert string.contains(
    refusal(
      ["rotate", "alice", "--claim-addr", "ws://loom.example.com/v2/control"],
      access.Loom,
    ),
    "requires TLS",
  )
}

pub fn usage_names_the_program_and_the_whole_grammar_test() {
  let loomd = access.usage(access.Loomd)
  let loom = access.usage(access.Loom)
  assert string.starts_with(loomd, "usage: loomd access [--state-dir PATH] ")
  assert string.starts_with(
    loom,
    "usage: loom access [--state-dir PATH | --addr URL --token-file PATH] ",
  )
  list.each(
    [
      "list [--after PRINCIPAL]", "show PRINCIPAL [--after SESSION]",
      "invite SESSION PRINCIPAL ROLE NAME", "set-role", "revoke SESSION",
      "rotate PRINCIPAL", "revoke-credentials", "isolate SESSION",
      "signins PRINCIPAL [--after FINGERPRINT]",
      "revoke-login PRINCIPAL FINGERPRINT",
    ],
    fn(word) {
      assert string.contains(loomd, word)
      assert string.contains(loom, word)
    },
  )
}

fn listing_request() {
  let assert Ok(request) = access.parse(["list"], access.Loom) as "list parses"
  request
}

fn object(fields: List(#(String, JsonValue))) -> JsonValue {
  json.Object(fields)
}

fn row(id: String, credential: JsonValue) -> JsonValue {
  object([
    #("principal_id", json.String(id)),
    #("name", json.String("Name of " <> id)),
    #("kind", json.String("member")),
    #("credential", credential),
  ])
}

fn active(fingerprint: String) -> JsonValue {
  object([
    #("state", json.String("active")),
    #("fingerprint", json.String(fingerprint)),
  ])
}

fn lines(body: JsonValue) -> Result(List(String), String) {
  access.success(body, "ws://127.0.0.1:1/v2/control", listing_request())
  |> result_map_strings
}

fn result_map_strings(found: Result(List(JsonValue), String)) {
  case found {
    Ok(values) -> Ok(list.map(values, json.to_string))
    Error(reason) -> Error(reason)
  }
}

pub fn a_listing_prints_one_line_per_principal_then_the_cursor_test() {
  let body =
    object([
      #(
        "principals",
        json.Array([
          row("alice", active(string.repeat("a", 16))),
          row(
            "bob",
            object([
              #("state", json.String("claim_open")),
              #("expires_in_ms", json.Int(1000)),
            ]),
          ),
          row("carol", object([#("state", json.String("claim_expired"))])),
          row("dan", object([#("state", json.String("none"))])),
        ]),
      ),
      #("next", json.String("dan")),
    ])
  let assert Ok(printed) = lines(body) as "a well-formed page prints"
  assert printed
    == [
      "{\"principal_id\":\"alice\",\"name\":\"Name of alice\",\"kind\":\"member\",\"credential\":{\"state\":\"active\",\"fingerprint\":\"aaaaaaaaaaaaaaaa\"}}",
      "{\"principal_id\":\"bob\",\"name\":\"Name of bob\",\"kind\":\"member\",\"credential\":{\"state\":\"claim_open\",\"expires_in_ms\":1000}}",
      "{\"principal_id\":\"carol\",\"name\":\"Name of carol\",\"kind\":\"member\",\"credential\":{\"state\":\"claim_expired\"}}",
      "{\"principal_id\":\"dan\",\"name\":\"Name of dan\",\"kind\":\"member\",\"credential\":{\"state\":\"none\"}}",
      "{\"next\":\"dan\"}",
    ]
}

pub fn a_claimed_credential_shows_when_its_claim_was_redeemed_test() {
  let claimed =
    object([
      #("state", json.String("active")),
      #("fingerprint", json.String(string.repeat("c", 16))),
      #("claimed_at_ms", json.Int(1_700_000_000_000)),
    ])
  let body = object([#("principals", json.Array([row("alice", claimed)]))])
  let assert Ok([printed]) = lines(body) as "the page prints"
  assert string.contains(printed, "\"claimed_at_ms\":1700000000000")
}

pub fn a_listing_reply_cannot_smuggle_a_secret_into_the_output_test() {
  let full_credential = hex("d")
  let claim = "loomclaim_" <> hex("e")

  // A daemon that put a whole credential where the fingerprint goes is
  // refused, not printed.
  let long_fingerprint =
    object([
      #("principals", json.Array([row("alice", active(full_credential))])),
    ])
  let assert Error(_) = lines(long_fingerprint)
    as "a 64-character fingerprint is not a fingerprint"

  // Extra fields the daemon adds are dropped, whatever they hold.
  let extra =
    object([
      #(
        "principals",
        json.Array([
          object([
            #("principal_id", json.String("alice")),
            #("name", json.String("Alice")),
            #("kind", json.String("member")),
            #("bearer", json.String(full_credential)),
            #("claim", json.String(claim)),
            #(
              "credential",
              object([
                #("state", json.String("active")),
                #("fingerprint", json.String(string.repeat("f", 16))),
                #("token", json.String(full_credential)),
              ]),
            ),
          ]),
        ]),
      ),
      #("bearer", json.String(full_credential)),
    ])
  let assert Ok(printed) = lines(extra) as "extra fields do not fail the page"
  let text = string.join(printed, "\n")
  assert !string.contains(text, full_credential)
  assert !string.contains(text, "loomclaim_")
  assert !string.contains(text, "bearer")
}

pub fn a_malformed_row_fails_the_whole_page_test() {
  let good = row("alice", active(string.repeat("a", 16)))
  let unknown_state = row("bob", object([#("state", json.String("mystery"))]))
  let bad_id = row("bad id", object([#("state", json.String("none"))]))
  let negative =
    row(
      "carol",
      object([
        #("state", json.String("claim_open")),
        #("expires_in_ms", json.Int(-1)),
      ]),
    )
  list.each([unknown_state, bad_id, negative], fn(bad) {
    let assert Error(_) =
      lines(object([#("principals", json.Array([good, bad]))]))
      as "a listing with one bad row prints nothing"
    Nil
  })
  let assert Error(_) = lines(object([#("principals", json.String("x"))]))
  let assert Error(_) = lines(object([]))
  let assert Error(_) =
    lines(object([#("principals", json.Array([])), #("next", json.String(""))]))
  let assert Ok([]) = lines(object([#("principals", json.Array([]))]))
    as "an empty page is an empty listing"
}

pub fn a_membership_listing_must_name_the_principal_asked_for_test() {
  let assert Ok(request) = access.parse(["show", "alice"], access.Loom)
  let membership =
    object([
      #("session_id", json.String(session)),
      #("name", json.String("Session")),
      #("role", json.String("operator")),
    ])
  let body = fn(principal) {
    object([
      #("principal_id", json.String(principal)),
      #("memberships", json.Array([membership])),
    ])
  }
  let assert Ok([printed]) =
    access.success(body("alice"), "ws://127.0.0.1:1/v2/control", request)
    |> result_map_strings
    as "the reply for the principal asked for prints"
  assert printed
    == "{\"session_id\":\""
    <> session
    <> "\",\"name\":\"Session\",\"role\":\"operator\"}"
  let assert Error(_) =
    access.success(body("bob"), "ws://127.0.0.1:1/v2/control", request)
    as "a reply about another principal is refused"
  Nil
}

pub fn an_invitation_prints_a_claim_and_a_command_that_names_no_token_test() {
  let token = "loomclaim_" <> hex("1")
  let assert Ok(request) =
    access.parse(
      [
        "invite", session, "alice", "operator", "Alice", "--claim-addr",
        "wss://loom.example.com/v2/control",
      ],
      access.Loom,
    )
  let body =
    object([
      #("principal_id", json.String("alice")),
      #("name", json.String("Alice")),
      #("claim", json.String(token)),
      #("expires_in_ms", json.Int(86_400_000)),
      #("bearer", json.String(hex("2"))),
    ])
  let assert Ok([printed]) =
    access.success(body, "ws://127.0.0.1:1/v2/control", request)
    |> result_map_strings
    as "the invitation prints"
  assert !string.contains(printed, "bearer")
  assert !string.contains(printed, hex("2"))
  assert string.contains(printed, "\"claim\":\"" <> token <> "\"")
  assert string.contains(
    printed,
    "\"claim_command\":\"loom claim --addr wss://loom.example.com/v2/control\"",
  )
  assert !string.contains(
    string.replace(printed, "\"claim\":\"" <> token <> "\"", ""),
    token,
  )
}

pub fn a_digest_enrollment_prints_no_claim_even_if_the_daemon_sent_one_test() {
  let assert Ok(request) =
    access.parse(
      ["rotate", "alice", "--credential-digest", hex("a")],
      access.Loom,
    )
  let body =
    object([
      #("principal_id", json.String("alice")),
      #("name", json.String("Alice")),
      #("claim", json.String("loomclaim_" <> hex("1"))),
      #("expires_in_ms", json.Int(1)),
    ])
  let assert Ok([printed]) =
    access.success(body, "ws://127.0.0.1:1/v2/control", request)
    |> result_map_strings
    as "the enrollment prints"
  assert printed == "{\"principal_id\":\"alice\",\"name\":\"Alice\"}"
}

fn scratch() -> String {
  let assert Ok(path) =
    bootstrap.absolute_path(
      "build/host-access-"
      <> int.to_string(bootstrap.system_time_ms())
      <> "-"
      <> int.to_string(int.random(1_000_000_000)),
    )
    as "the fixture has an absolute path"
  assert bootstrap.ensure_private_directory(path) == Ok(Nil)
  path
}

fn remote_list(token_file: String) {
  let assert Ok(request) =
    access.parse(
      [
        "--addr", "wss://loom.example.com/v2/control", "--token-file",
        token_file, "list",
      ],
      access.Loom,
    )
  request
}

pub fn the_owner_token_file_is_read_as_a_private_bounded_credential_test() {
  let root = scratch()

  // A file other users can read is refused before any connection is made.
  let open = root <> "/open"
  assert bootstrap.atomic_write_private(open, hex("a")) == Ok(Nil)
  let assert Ok(Nil) = simplifile.set_permissions_octal(open, 0o644)
    as "the fixture loosens its mode"
  let assert Error(refused) = access.execute(remote_list(open))
    as "a group-readable token file is refused"
  assert !string.contains(refused, hex("a"))

  // A claim token in the file is named as such and never echoed.
  let claim = root <> "/claim"
  let token = "loomclaim_" <> hex("b")
  assert bootstrap.atomic_write_private(claim, token) == Ok(Nil)
  let assert Error(named) = access.execute(remote_list(claim))
    as "a claim token is not the owner credential"
  assert string.contains(named, "claim token")
  assert !string.contains(named, token)

  // Anything else that is not a credential is refused without its content.
  let junk = root <> "/junk"
  assert bootstrap.atomic_write_private(junk, "not a credential\n") == Ok(Nil)
  let assert Error(invalid) = access.execute(remote_list(junk))
    as "a non-credential file is refused"
  assert !string.contains(invalid, "not a credential")

  let assert Error(_) = access.execute(remote_list(root <> "/missing"))
  assert simplifile.delete(root) == Ok(Nil)
}

// The listing checks are what `loom access list` and `show` print through and
// what the terminal's `/access` overlay accepts, so both surfaces refuse the
// same replies.
pub fn the_public_listing_checks_accept_and_refuse_what_the_commands_do_test() {
  let assert Ok(page) =
    json.parse(
      "{\"principals\":[{\"principal_id\":\"alice\",\"name\":\"Alice\",\"kind\":\"member\",\"credential\":{\"state\":\"none\"}}],\"next\":\"alice\"}",
    )
  let assert Ok([row, next]) = access.principal_lines(page)
  assert json.to_string(row)
    == "{\"principal_id\":\"alice\",\"name\":\"Alice\",\"kind\":\"member\",\"credential\":{\"state\":\"none\"}}"
  assert json.to_string(next) == "{\"next\":\"alice\"}"

  let assert Ok(memberships) =
    json.parse(
      "{\"principal_id\":\"alice\",\"memberships\":[{\"session_id\":\""
      <> session
      <> "\",\"name\":\"Review\",\"role\":\"observer\"}]}",
    )
  let assert Ok([_]) = access.membership_lines(memberships, "alice")
  let assert Error(_) = access.membership_lines(memberships, "bob")
    as "a reply for another principal is refused"
}

pub fn the_lines_the_overlay_shows_parse_in_the_shared_grammar_test() {
  let assert Ok(_) = access.parse(["rotate", "alice"], access.Loom)
  assert access.rotate_line("alice") == "loom access rotate alice"
  assert access.invite_line("")
    == "loom access invite SESSION PRINCIPAL ROLE NAME"
  assert access.invite_line(session)
    == "loom access invite " <> session <> " PRINCIPAL ROLE NAME"
  let assert Ok(_) =
    access.parse(["invite", session, "carol", "observer", "Carol"], access.Loom)
}

// Protocol-change/065, PR 8. A principal's browser logins are listed and ended
// from a terminal: the listing carries a cursor and no epoch, as every listing
// does, and a revocation names the principal and the fingerprint and is fenced
// by the epoch.
pub fn the_login_commands_become_the_requests_the_daemon_decodes_test() {
  assert envelope(["signins", "alice"], access.Loom)
    == "{\"v\":2,\"id\":1,\"cmd\":\"credentials.signins\",\"body\":{\"principal_id\":\"alice\"}}"
  assert envelope(
      ["signins", "alice", "--after", "0123456789abcdef"],
      access.Loom,
    )
    == "{\"v\":2,\"id\":1,\"cmd\":\"credentials.signins\",\"body\":{\"principal_id\":\"alice\",\"after\":\"0123456789abcdef\"}}"
  assert envelope(["revoke-login", "alice", "0123456789abcdef"], access.Loom)
    == "{\"v\":2,\"id\":1,\"cmd\":\"credentials.revoke_login\",\"body\":{\"principal_id\":\"alice\",\"epoch\":\"epoch-1\",\"fingerprint\":\"0123456789abcdef\"}}"
}

// A fingerprint is checked before any connection is made, so a typo is named
// and a longer value, which could be a credential, is never sent.
pub fn a_malformed_fingerprint_is_refused_before_a_connection_test() {
  let usage = access.usage(access.Loom)
  assert refusal(["revoke-login", "alice", "short"], access.Loom) != ""
  assert refusal(["revoke-login", "alice", hex("a")], access.Loom) != ""
  assert refusal(["revoke-login", "alice", "0123456789ABCDEF"], access.Loom)
    != ""
  assert refusal(["revoke-login", "alice"], access.Loom) == usage
  assert refusal(["signins"], access.Loom) == usage
  assert refusal(["signins", "alice", "--after", "alice"], access.Loom) != ""
  assert refusal(["signins", "alice", "--after"], access.Loom) != ""
}

// The sign-in listing is re-encoded from checked fields: a row keeps a
// 16-digit fingerprint and non-negative times, and anything else the daemon
// sent is dropped or refuses the reply.
pub fn the_signin_check_accepts_a_row_and_refuses_what_is_not_one_test() {
  let assert Ok(page) =
    json.parse(
      "{\"principal_id\":\"alice\",\"signins\":[{\"fingerprint\":\"0123456789abcdef\",\"issued_at_ms\":5,\"last_resumed_ms\":7,\"expires_at_ms\":9,\"issued_by\":\"fedcba9876543210\",\"token\":\"loomb1:x\"}],\"next\":\"0123456789abcdef\"}",
    )
  let assert Ok([row, next]) = access.signin_lines(page, "alice")
  assert json.to_string(row)
    == "{\"fingerprint\":\"0123456789abcdef\",\"issued_at_ms\":5,\"last_resumed_ms\":7,\"expires_at_ms\":9,\"issued_by\":\"fedcba9876543210\"}"
  assert json.to_string(next) == "{\"next\":\"0123456789abcdef\"}"

  // A reply for another principal, and a row that is not one, are refused.
  let assert Error(_) = access.signin_lines(page, "bob")
  let refused = fn(row: String) {
    let assert Ok(body) =
      json.parse("{\"principal_id\":\"alice\",\"signins\":[" <> row <> "]}")
    let assert Error(_) = access.signin_lines(body, "alice")
    Nil
  }
  refused("{\"fingerprint\":\"short\",\"issued_at_ms\":5}")
  refused("{\"fingerprint\":\"" <> hex("a") <> "\",\"issued_at_ms\":5}")
  refused("{\"fingerprint\":\"0123456789abcdef\"}")
  refused("{\"fingerprint\":\"0123456789abcdef\",\"issued_at_ms\":-1}")
  refused(
    "{\"fingerprint\":\"0123456789abcdef\",\"issued_at_ms\":1,\"issued_by\":\"x\"}",
  )
  refused(
    "{\"fingerprint\":\"0123456789abcdef\",\"issued_at_ms\":1,\"expires_at_ms\":\"later\"}",
  )
}

// A principal's row gains a login count beside its credential, and a daemon
// that predates the field sends none.
pub fn the_listing_row_keeps_the_login_count_when_the_daemon_sends_one_test() {
  let with =
    "{\"principals\":[{\"principal_id\":\"alice\",\"name\":\"Alice\",\"kind\":\"member\",\"credential\":{\"state\":\"none\"},\"logins\":2}]}"
  let assert Ok(page) = json.parse(with)
  let assert Ok([row]) = access.principal_lines(page)
  assert json.to_string(row)
    == "{\"principal_id\":\"alice\",\"name\":\"Alice\",\"kind\":\"member\",\"credential\":{\"state\":\"none\"},\"logins\":2}"
  let assert Ok(bad) =
    json.parse(string.replace(with, "\"logins\":2", "\"logins\":-1"))
  let assert Error(_) = access.principal_lines(bad)
}
