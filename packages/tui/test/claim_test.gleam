//// `loom claim` and `loom enroll` without a daemon: arguments, the invitee's
//// private files, and the bearer launch's refusal of claim-shaped values.
//// The exchange with a real daemon is exercised by the client package's
//// `daemon_claim_test`, which can start one.

import core/json
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import host/claim as token
import simplifile
import tui
import tui/claim

// A private scratch state directory, unique per call.
fn state(name: String) -> String {
  let directory =
    "build/claim-test-"
    <> name
    <> "-"
    <> int.to_string(bootstrap.monotonic_time_ms())
  let _ = simplifile.delete(directory)
  let assert Ok(absolute) = bootstrap.absolute_path(directory)
    as "the scratch directory has an absolute path"
  absolute
}

fn mode(path: String) -> Int {
  let assert Ok(info) = simplifile.link_info(path) as "the path exists"
  simplifile.file_info_permissions_octal(info)
}

fn remote(directory: String) -> claim.Remote {
  let assert Ok(remote) =
    claim.remote(claim.Options("ws://127.0.0.1:9/v2/control", "", directory, ""))
    as "a loopback remote is prepared"
  remote
}

fn read(path: String) -> String {
  let assert Ok(text) = simplifile.read(path) as "the file is readable"
  text
}

pub fn claim_arguments_take_an_optional_token_test() {
  let assert Ok(#(options, None)) =
    claim.parse_claim(["--addr", "wss://h/v2/control"])
    as "the token is optional"
  assert options.address == "wss://h/v2/control"
  let assert Ok(#(_, Some("loomclaim_x"))) =
    claim.parse_claim(["--addr", "wss://h/v2/control", "loomclaim_x"])
    as "the token may be given as the one positional word"
  let assert Error(_) = claim.parse_claim(["loomclaim_x"])
    as "--addr is required"
  let assert Error(_) =
    claim.parse_claim(["--addr", "wss://h/v2/control", "a", "b"])
    as "one token at most"
  let assert Error(_) =
    claim.parse_enroll(["--addr", "wss://h/v2/control", "x"])
    as "enroll takes no positional word"
}

pub fn claim_takes_an_optional_display_name_test() {
  let assert Ok(#(options, Some("loomclaim_x"))) =
    claim.parse_claim([
      "--addr",
      "wss://h/v2/control",
      "--name",
      "Alex Doe",
      "loomclaim_x",
    ])
    as "--name takes one value and the token stays positional"
  assert options.name == "Alex Doe"
  let assert Ok(#(unnamed, None)) =
    claim.parse_claim(["--addr", "wss://h/v2/control"])
  assert unnamed.name == ""
  let assert Error(claim.Invalid(_)) =
    claim.parse_claim(["--addr", "wss://h/v2/control", "--name"])
    as "--name needs a value"
  let assert Error(claim.Invalid(_)) =
    claim.parse_claim(["--addr", "wss://h/v2/control", "--name", ""])
    as "an empty name is refused, not read as none"
  let assert Error(claim.Invalid(_)) =
    claim.parse_claim([
      "--addr",
      "wss://h/v2/control",
      "--name",
      "A",
      "--name",
      "B",
    ])
    as "--name is given once"
  let assert Error(claim.Invalid(_)) =
    claim.parse_enroll(["--addr", "wss://h/v2/control", "--name", "Alex"])
    as "enroll draws no name"
}

pub fn remote_refuses_cleartext_to_another_host_and_escaping_labels_test() {
  let directory = state("address")
  let assert Error(_) =
    claim.remote(claim.Options(
      "ws://loom.example.com/v2/control",
      "",
      directory,
      "",
    ))
    as "ws:// to a non-loopback host is refused"
  let assert Error(_) =
    claim.remote(claim.Options("wss://h/v2/control", "../escape", directory, ""))
    as "a label cannot climb out of remotes/"
  let assert Error(_) =
    claim.remote(claim.Options("wss://h/v2/control", ".hidden", directory, ""))
    as "a label cannot be hidden"
  let assert Ok(named) =
    claim.remote(claim.Options(
      "wss://loom.example.com/v2/control",
      "",
      directory,
      "",
    ))
    as "a TLS remote gets the host as its label"
  assert named.label == "loom.example.com"
  let assert Ok(ported) =
    claim.remote(claim.Options(
      "wss://loom.example.com:8443/v2/control",
      "",
      directory,
      "",
    ))
    as "a port other than 443 is part of the label"
  assert ported.label == "loom.example.com:8443"
  let _ = simplifile.delete(directory)
}

pub fn claim_files_are_private_and_written_before_any_connection_test() {
  let directory = state("modes")
  let remote = remote(directory)
  let issued = token.mint_token(fn(count) { <<7:size(count)-unit(8)>> })

  // Nothing listens on port 9, so the exchange cannot happen. The files must
  // already exist when it fails: that ordering is what lets a rerun complete
  // a claim whose reply was lost.
  let assert Error(claim.Unknown(_)) = claim.redeem(remote, issued, "")
    as "an unreachable daemon is an unknown outcome"
  assert mode(remote.directory) == 0o700
  assert mode(directory <> "/remotes") == 0o700
  assert mode(directory) == 0o700
  assert mode(claim.credential_path(remote)) == 0o600
  assert mode(claim.claim_path(remote)) == 0o600
  let credential = read(claim.credential_path(remote))
  assert token.is_hex_256(credential)
  assert read(claim.claim_path(remote)) == token.digest(issued)
  assert simplifile.is_file(claim.record_path(remote)) == Ok(False)
  let _ = simplifile.delete(directory)
}

pub fn stored_credential_is_reused_only_for_the_same_claim_test() {
  let directory = state("reuse")
  let remote = remote(directory)
  let first = token.mint_token(fn(count) { <<1:size(count)-unit(8)>> })
  let second = token.mint_token(fn(count) { <<2:size(count)-unit(8)>> })
  let assert Ok(credential) = claim.prepare(remote, first)
    as "the first claim draws a credential"
  assert claim.prepare(remote, first) == Ok(credential)

  // A credential drawn for another claim is replaced, never bound to this one.
  let assert Ok(replaced) = claim.prepare(remote, second)
    as "another claim draws afresh"
  assert replaced != credential
  assert read(claim.claim_path(remote)) == token.digest(second)

  // A credential file other users can read is not reused either.
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(claim.credential_path(remote), 0o644)
  let assert Ok(redrawn) = claim.prepare(remote, second)
    as "an exposed credential is replaced"
  assert redrawn != replaced
  assert mode(claim.credential_path(remote)) == 0o600
  let _ = simplifile.delete(directory)
}

pub fn claim_refuses_a_bearer_shaped_token_and_a_finished_remote_test() {
  let directory = state("refusals")
  let remote = remote(directory)
  let assert Error(claim.Invalid(_)) =
    claim.redeem(remote, string.repeat("a", 64), "")
    as "a bearer is not a claim"
  let assert Error(claim.Invalid(_)) =
    claim.redeem(remote, "loomclaim_short", "")
    as "a truncated claim is refused"
  assert simplifile.is_file(claim.credential_path(remote)) == Ok(False)

  // A finished claim lives in remote.json; a second claim would overwrite
  // the credential it bound.
  let assert Ok(Nil) =
    simplifile.write(claim.record_path(remote), "{\"addr\":\"x\"}")
  let issued = token.mint_token(fn(count) { <<3:size(count)-unit(8)>> })
  let assert Error(claim.Invalid(_)) = claim.redeem(remote, issued, "")
    as "a finished remote is refused"
  assert simplifile.is_file(claim.credential_path(remote)) == Ok(False)
  let _ = simplifile.delete(directory)
}

pub fn enroll_stores_a_credential_and_prints_only_its_digest_test() {
  let directory = state("enroll")
  let remote = remote(directory)
  let assert Ok(printed) = claim.enroll(remote) as "enrollment succeeds"
  let credential = read(claim.credential_path(remote))
  let digest = token.digest(credential)
  let text = json.to_string(printed)
  assert string.contains(text, digest)
  assert string.contains(text, string.slice(digest, 0, 16))
  assert !string.contains(text, credential)
  assert mode(claim.credential_path(remote)) == 0o600
  assert mode(claim.record_path(remote)) == 0o600
  let assert Error(claim.Invalid(_)) = claim.enroll(remote)
    as "a second enrollment for one label is refused"
  let _ = simplifile.delete(directory)
}

pub fn launch_refuses_claim_shaped_tokens_and_readable_token_files_test() {
  let issued = token.mint_token(fn(count) { <<4:size(count)-unit(8)>> })
  let assert Error(reason) = tui.launch_token(["--token", issued])
    as "a claim is not a bearer"
  assert !string.contains(reason, issued)

  let directory = state("launch")
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let file = directory <> "/token"
  let assert Ok(Nil) = bootstrap.atomic_write_private(file, issued)
  let assert Error(reason) = tui.launch_token(["--token-file", file])
    as "a claim in a token file is refused"
  assert !string.contains(reason, issued)

  // A bearer in a private file is accepted; the same file readable by the
  // group is refused before it is read.
  let bearer = string.repeat("b", 64)
  let assert Ok(Nil) = bootstrap.atomic_write_private(file, bearer <> "\n")
  assert tui.launch_token(["--token-file", file]) == Ok(bearer)
  let assert Ok(Nil) = simplifile.set_permissions_octal(file, 0o640)
  let assert Error(reason) = tui.launch_token(["--token-file", file])
    as "a group-readable token file is refused"
  assert !string.contains(reason, bearer)
  assert tui.launch_token(["--token", bearer]) == Ok(bearer)
  let _ = simplifile.delete(directory)
}

// Protocol-change/065, PR 8. A browser login is a cookie and not a credential a
// terminal presents, so `--token` and `--token-file` name it as such and never
// echo it. This is a courtesy to the person and not a defence: the daemon refuses
// every string that is not a 64-digit bearer.
pub fn launch_refuses_a_browser_login_and_never_echoes_it_test() {
  let login =
    "loomb1:" <> string.repeat("0", 32) <> ":p=owner:" <> string.repeat("a", 64)
  let assert Error(reason) = tui.launch_token(["--token", login])
    as "a login is not a bearer"
  assert string.contains(reason, "browser login")
  assert !string.contains(reason, login)

  let directory = state("login-launch")
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let file = directory <> "/token"
  let assert Ok(Nil) = bootstrap.atomic_write_private(file, login)
  let assert Error(reason) = tui.launch_token(["--token-file", file])
    as "a login in a token file is refused"
  assert !string.contains(reason, login)

  // A short value of the same shape is named for what it is.
  let short = "loomb1:x"
  let assert Ok(Nil) = bootstrap.atomic_write_private(file, short)
  let assert Error(named) = tui.launch_token(["--token-file", file])
    as "a login-shaped file is refused"
  assert string.contains(named, "browser login")
  let _ = simplifile.delete(directory)
}
