//// Finding the sealed authority key of the deployment an installed daemon
//// belongs to.
////
//// `provision` seals the authority key under `<home>/.loom/authority/<id>`,
//// where `home` is its `--home` and `id` is the deployment id. `attach-file`,
//// `enroll`, `renew` and `revoke` look under their own home, which is `$HOME`
//// unless `--home` says otherwise, so an operator who provisioned with
//// `--home /X` and later forgets the flag gets a bare "no key" error.
////
//// Two facts on the daemon's machine close that gap without secrets. The
//// installed ledger names the deployment id in its genesis entry, and the id
//// is public. And `provision` may leave an `authority-home` file, one line
//// holding the home it sealed under, which `install` copies beside the ledger.
//// The hint is a path and nothing else, and a caller uses it only when the
//// directory it names really holds a sealed key for the id.
////
//// ## Flow
////
//// 1. `write_hint` records the home next to the files the provision command writes.
//// 2. `copy_hint` carries it beside the installed ledger.
//// 3. `installed_deployment` reads the id from that ledger, without writing.
//// 4. `hinted_home` reads the recorded home back.
//// 5. `explain` words the error that names the id, the directory and the flags.

import client/distribution_bundle
import client/membership_ledger
import client/membership_signing
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import simplifile

/// The file name of the hint, in the provision output and beside the ledger.
pub const hint_file = "authority-home"

/// Records `home` as the place the key was sealed, in `directory`.
///
/// ## Examples
///
/// ```gleam
/// authority_home.write_hint("out", "/srv/ops")
/// ```
pub fn write_hint(directory: String, home: String) -> Result(Nil, String) {
  let path = directory <> "/" <> hint_file
  bootstrap.atomic_write_private(path, home <> "\n")
  |> result.map_error(fn(reason) { path <> " is unwritable: " <> reason })
}

/// Copies a hint found in `from` to `into`, if there is one. A missing hint is
/// not an error, since a bundle is often copied alone.
///
/// ## Examples
///
/// ```gleam
/// authority_home.copy_hint("bundles", "/home/me/.loom/distribution")
/// ```
pub fn copy_hint(from: String, into: String) -> Result(Nil, String) {
  case simplifile.read(from <> "/" <> hint_file) {
    Error(_) -> Ok(Nil)
    Ok(text) -> write_hint(into, string.trim(text))
  }
}

/// The home recorded in `directory`, if the hint is there and is absolute.
///
/// ## Examples
///
/// ```gleam
/// authority_home.hinted_home("/home/me/.loom/distribution")
/// // -> Ok("/srv/ops")
/// ```
pub fn hinted_home(directory: String) -> Result(String, Nil) {
  use text <- result.try(
    simplifile.read(directory <> "/" <> hint_file) |> result.replace_error(Nil),
  )

  // Accept only a trimmed absolute home path from the installation hint.
  case string.trim(text) {
    "/" <> _ as home -> Ok(home)
    _ -> Error(Nil)
  }
}

/// The deployment id the ledger installed in `directory` names, read without
/// changing any file. The ledger is checked against the CA beside it, so a
/// damaged file yields nothing rather than a wrong id.
///
/// ## Examples
///
/// ```gleam
/// authority_home.installed_deployment("/home/me/.loom/distribution")
/// // -> Ok("3f9c...")
/// ```
pub fn installed_deployment(directory: String) -> Result(String, Nil) {
  use ca <- result.try(
    simplifile.read(directory <> "/ca.pem") |> result.replace_error(Nil),
  )
  use verifier <- result.try(
    membership_signing.verifier(ca) |> result.replace_error(Nil),
  )
  use text <- result.try(
    simplifile.read(directory <> "/" <> distribution_bundle.ledger_file)
    |> result.replace_error(Nil),
  )
  let lines =
    string.split(text, "\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
    |> list.map(bit_array.from_string)
  membership_ledger.replay(lines, verifier)
  |> result.map(membership_ledger.deployment)
  |> result.replace_error(Nil)
}

/// The sentence appended to a no-key error: the deployment, where its key is
/// sealed, and the flags that reach it.
///
/// ## Examples
///
/// ```gleam
/// authority_home.explain("3f9c", "/home/me")
/// ```
pub fn explain(deployment: String, home: String) -> String {
  ". This host's installed ledger names deployment "
  <> deployment
  <> ", whose key is sealed at <home>/.loom/authority/"
  <> deployment
  <> " under the machine and --home that ran `provision` (tried "
  <> home
  <> "); pass --home DIR and --passphrase-file PATH"
}
