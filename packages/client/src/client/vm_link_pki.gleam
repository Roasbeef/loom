//// The credentials of the untrusted link, minted once and kept on the host.
////
//// `loom vm up --link untrusted` needs three sets of keys. One authority and
//// one orchestrator leaf serve every guest of a vm home, because the daemon has
//// one `[executor_link]` table. Each guest has a leaf of its own, so the
//// daemon's pin for one guest is useless against another. The authority's key
//// is kept beside the authority: with a pin on both sides, a leaf it signs is
//// accepted only when its pin is also configured, so the key buys an attacker
//// nothing and lets a later guest be issued without a new authority.
////
//// ```text
//// <vm home>/link/ca.pem ca.key orchestrator.pem orchestrator.key
//// <vm home>/<name>/link-credentials/executor.pem executor.key
//// ```
////
//// Every file is mode 0600 in a 0700 directory, and every directory appears
//// whole. A directory is built beside its final name as `<directory>.minting`
//// and renamed into place, so a credentials directory a later `up` finds is
//// complete: an interrupted run leaves only a `.minting` directory, which the
//// next run removes and builds again. Nothing here edits a file in place.
////
//// The certificates are made with the helpers `loom distribution provision`
//// uses (`client/internal/ffi_pki`), so this module adds no foreign code.
//// A leaf carries no host name that matters: the link checks the chain and the
//// pin, and never the name.

import client/internal/ffi_pki
import client/vm_link.{type LinkFiles, LinkFiles}
import gleam/list
import gleam/result
import host/bootstrap
import simplifile

/// The orchestrator's side of the link under a vm home.
pub type Home {
  Home(
    /// The three files `[executor_link]` names.
    files: LinkFiles,
    /// The authority's key, which issues each guest's leaf.
    ca_key: String,
    /// The pin of the orchestrator's leaf, which every guest admits.
    pin: String,
  )
}

/// One guest's leaf, read from its directory.
pub type Leaf {
  Leaf(
    /// The leaf certificate in PEM.
    certificate: String,
    /// The leaf's private key in PEM, the one secret the guest holds.
    key: String,
    /// The pin of the certificate, written into the guest's row.
    pin: String,
  )
}

const ca_file = "ca.pem"

const ca_key_file = "ca.key"

const orchestrator_file = "orchestrator.pem"

const orchestrator_key_file = "orchestrator.key"

const executor_file = "executor.pem"

const executor_key_file = "executor.key"

const minting = ".minting"

/// Where the link's files are under a vm home, without reading or making
/// any. `rm` uses it to name the tables it removes.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link_pki.files_of("/h/vm").ca == "/h/vm/link/ca.pem"
/// ```
pub fn files_of(vm_home: String) -> LinkFiles {
  let directory = vm_home <> "/" <> vm_link.credentials_dir
  LinkFiles(
    ca: directory <> "/" <> ca_file,
    certificate: directory <> "/" <> orchestrator_file,
    key: directory <> "/" <> orchestrator_key_file,
  )
}

/// The authority and the orchestrator's leaf of a vm home, made on the first
/// call and read on every later one. A `link` directory that is missing a file
/// is refused, not repaired, because it was made whole and something removed
/// part of it.
///
/// ## Examples
///
/// ```gleam
/// // vm_link_pki.ensure_home("/h/vm")
/// ```
pub fn ensure_home(vm_home: String) -> Result(Home, String) {
  let directory = vm_home <> "/" <> vm_link.credentials_dir

  // The directory either exists whole or does not exist.
  case bootstrap.path_exists(directory) {
    True -> read_home(vm_home)
    False -> {
      use Nil <- result.try(mint_home(directory))
      read_home(vm_home)
    }
  }
}

/// Mints the authority and the orchestrator's leaf in `link.minting` and
/// renames it to `directory`.
fn mint_home(directory: String) -> Result(Nil, String) {
  let #(ca, ca_key) = ffi_pki.authority("loom vm link authority")
  use #(certificate, key) <- result.try(
    ffi_pki.issue(ca, ca_key, "loom vm orchestrator", names)
    |> result.replace_error("the authority could not issue a certificate"),
  )
  publish(directory, [
    #(ca_file, ca),
    #(ca_key_file, ca_key),
    #(orchestrator_file, certificate),
    #(orchestrator_key_file, key),
  ])
}

/// The names a leaf carries. The link does not check them.
const names = ["localhost", "127.0.0.1"]

/// Reads the home's files and the orchestrator's pin.
fn read_home(vm_home: String) -> Result(Home, String) {
  let files = files_of(vm_home)
  let directory = vm_home <> "/" <> vm_link.credentials_dir
  use certificate <- result.try(read(files.certificate))
  use pin <- result.try(
    vm_link.pin_of(certificate)
    |> result.map_error(fn(reason) { files.certificate <> ": " <> reason }),
  )

  // The authority must be there for a later guest to be issued a leaf, and
  // its absence names the directory to remove.
  use Nil <- result.try(
    list.try_each(
      [files.ca, files.key, directory <> "/" <> ca_key_file],
      fn(path) { present(path, directory) },
    ),
  )
  Ok(Home(files:, ca_key: directory <> "/" <> ca_key_file, pin:))
}

/// The guest's leaf, made on the first call for the guest directory and read on
/// every later one, so a resume and `--fresh` keep the pin the daemon's row
/// holds.
///
/// ## Examples
///
/// ```gleam
/// // vm_link_pki.ensure_leaf(home, "/h/vm/dev")
/// ```
pub fn ensure_leaf(
  home: Home,
  guest_directory: String,
) -> Result(Leaf, String) {
  let directory = guest_directory <> "/" <> vm_link.guest_credentials_dir

  // The directory either exists whole or does not exist.
  case bootstrap.path_exists(directory) {
    True -> read_leaf(directory)
    False -> {
      use Nil <- result.try(mint_leaf(home, directory))
      read_leaf(directory)
    }
  }
}

/// Issues the guest's leaf under the home's authority and renames it into
/// place.
fn mint_leaf(home: Home, directory: String) -> Result(Nil, String) {
  use ca <- result.try(read(home.files.ca))
  use ca_key <- result.try(read(home.ca_key))
  use #(certificate, key) <- result.try(
    ffi_pki.issue(ca, ca_key, "loom vm guest", names)
    |> result.replace_error("the authority could not issue a certificate"),
  )
  publish(directory, [#(executor_file, certificate), #(executor_key_file, key)])
}

/// Reads a guest's leaf and its pin.
fn read_leaf(directory: String) -> Result(Leaf, String) {
  use certificate <- result.try(read(directory <> "/" <> executor_file))
  use key <- result.try(read(directory <> "/" <> executor_key_file))
  use pin <- result.try(
    vm_link.pin_of(certificate)
    |> result.map_error(fn(reason) { directory <> ": " <> reason }),
  )
  Ok(Leaf(certificate:, key:, pin:))
}

/// Writes `entries` into `directory.minting`, each file private, and renames
/// the directory to `directory`. A rename that finds the directory already
/// there lost a race to another `up`, whose whole directory is the one used.
fn publish(
  directory: String,
  entries: List(#(String, String)),
) -> Result(Nil, String) {
  let building = directory <> minting
  use Nil <- result.try(clear(building))
  use Nil <- result.try(bootstrap.ensure_private_directory(building))
  use Nil <- result.try(
    list.try_each(entries, fn(entry) {
      bootstrap.atomic_write_private(building <> "/" <> entry.0, entry.1)
      |> result.map_error(fn(reason) {
        building <> "/" <> entry.0 <> " is unwritable: " <> reason
      })
    }),
  )

  // The rename is the one step that makes the directory appear.
  case simplifile.rename(building, directory) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> lost_race(directory, error)
  }
}

/// Removes what an interrupted run left in `building`. It is half a directory
/// and is never kept.
fn clear(building: String) -> Result(Nil, String) {
  // A directory that is not there is already clear.
  case simplifile.delete(building) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(
        building <> " cannot be removed: " <> simplifile.describe_error(error),
      )
  }
}

/// A rename that failed because the directory is already there lost a race to
/// another `up`, whose whole directory is the one used.
fn lost_race(
  directory: String,
  error: simplifile.FileError,
) -> Result(Nil, String) {
  // The winner's directory is whole by the same rule, so it stands.
  case bootstrap.path_exists(directory) {
    True -> Ok(Nil)
    False ->
      Error(
        directory <> " cannot be made: " <> simplifile.describe_error(error),
      )
  }
}

/// Reads one text file, naming it when it cannot be read.
fn read(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(error) {
    path <> " is unreadable: " <> simplifile.describe_error(error)
  })
}

/// Checks that a file of a directory that must be whole is there.
fn present(path: String, directory: String) -> Result(Nil, String) {
  case bootstrap.path_exists(path) {
    True -> Ok(Nil)
    False ->
      Error(
        path
        <> " is missing, so "
        <> directory
        <> " is not whole. Remove the directory and its row in the daemon's "
        <> "configuration, and run `loom vm up` again.",
      )
  }
}
