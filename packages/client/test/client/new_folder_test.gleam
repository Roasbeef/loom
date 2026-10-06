//// Which typed paths may start a session (protocol-change/074), against a real
//// filesystem: the canonical form is judged, so a link or a `..` cannot lead out
//// of the home directory, and a folder the owner cannot use is refused.

import client/daemon/new_folder
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import support/extensions
import web_view/creations

// A canonical, empty directory standing for the owner's home, with a project
// folder and a nested one inside it.
fn owners_home(name: String) -> String {
  let assert Ok(home) = bootstrap.canonical_directory(extensions.scratch(name))
    as "the scratch directory resolves"
  let assert Ok(Nil) = simplifile.create_directory_all(home <> "/code/app")
    as "the project folders are made"
  home
}

pub fn a_folder_inside_home_is_accepted_in_canonical_form_test() {
  let home = owners_home("folder-accepted")
  assert new_folder.check_in("~/code/app", home) == Ok(home <> "/code/app")
  assert new_folder.check_in("~/code", home) == Ok(home <> "/code")
  assert new_folder.check_in(home <> "/code/app", home)
    == Ok(home <> "/code/app")
  assert new_folder.check_in("  ~/code/app/  ", home) == Ok(home <> "/code/app")

  // A `..` that stays inside is folded away, and a link that stays inside is
  // followed, so the session is made in the folder the path really names.
  assert new_folder.check_in("~/code/../code/app", home)
    == Ok(home <> "/code/app")
  let assert Ok(Nil) =
    simplifile.create_symlink(home <> "/code/app", home <> "/shortcut")
    as "a link inside home"
  assert new_folder.check_in("~/shortcut", home) == Ok(home <> "/code/app")
}

pub fn the_home_directory_itself_and_what_is_outside_it_are_refused_test() {
  let home = owners_home("folder-outside")
  let assert Ok(sibling) =
    bootstrap.canonical_directory(extensions.scratch("folder-outside-sibling"))
    as "a folder beside home"
  assert new_folder.check_in("~", home) == Error(creations.OutsideHome)
  assert new_folder.check_in("~/", home) == Error(creations.OutsideHome)
  assert new_folder.check_in(home, home) == Error(creations.OutsideHome)
  assert new_folder.check_in(sibling, home) == Error(creations.OutsideHome)
  assert new_folder.check_in("/", home) == Error(creations.OutsideHome)
  assert new_folder.check_in("~/..", home) == Error(creations.OutsideHome)
  assert new_folder.check_in("~/code/../..", home)
    == Error(creations.OutsideHome)

  // A folder whose name only begins like home's is not inside it.
  let assert Ok(Nil) = simplifile.create_directory_all(home <> "2/x")
    as "a folder named like home"
  assert new_folder.check_in(home <> "2/x", home)
    == Error(creations.OutsideHome)
  let _ = simplifile.delete(home <> "2")
}

// A link that leaves home is judged by where it ends, however it is spelled.
pub fn a_link_or_a_dot_dot_cannot_leave_home_test() {
  let home = owners_home("folder-links")
  let assert Ok(outside) =
    bootstrap.canonical_directory(extensions.scratch("folder-links-outside"))
    as "a folder outside home"
  let assert Ok(Nil) = simplifile.create_directory_all(outside <> "/deep")
    as "a nested folder outside"
  let assert Ok(Nil) = simplifile.create_symlink(outside, home <> "/escape")
    as "a link to the outside"
  assert new_folder.check_in("~/escape", home) == Error(creations.OutsideHome)
  assert new_folder.check_in("~/escape/deep", home)
    == Error(creations.OutsideHome)
  assert new_folder.check_in("~/code/app/../../escape/deep", home)
    == Error(creations.OutsideHome)

  // A link inside home that points at a hidden folder lands in it.
  let assert Ok(Nil) = simplifile.create_directory_all(home <> "/.secrets")
    as "a hidden folder"
  let assert Ok(Nil) =
    simplifile.create_symlink(home <> "/.secrets", home <> "/innocent")
    as "a link to it"
  assert new_folder.check_in("~/innocent", home) == Error(creations.OutsideHome)
}

pub fn hidden_folders_are_refused_wherever_they_are_test() {
  let home = owners_home("folder-hidden")
  let assert Ok(Nil) = simplifile.create_directory_all(home <> "/.ssh")
    as "a hidden folder"
  let assert Ok(Nil) =
    simplifile.create_directory_all(home <> "/code/.git/hooks")
    as "a hidden folder below a project"
  assert new_folder.check_in("~/.ssh", home) == Error(creations.OutsideHome)
  assert new_folder.check_in("~/code/.git", home)
    == Error(creations.OutsideHome)
  assert new_folder.check_in("~/code/.git/hooks", home)
    == Error(creations.OutsideHome)

  // A dot inside a name does not make a folder hidden; only a name that begins
  // with one does.
  let assert Ok(Nil) = simplifile.create_directory_all(home <> "/v1.2/app.d")
    as "dots inside names"
  assert new_folder.check_in("~/v1.2/app.d", home) == Ok(home <> "/v1.2/app.d")
}

pub fn a_path_that_is_not_a_folder_is_refused_test() {
  let home = owners_home("folder-missing")
  let assert Ok(Nil) = simplifile.write(home <> "/notes.txt", "hello")
    as "a file"
  assert new_folder.check_in("~/missing", home) == Error(creations.NotAFolder)
  assert new_folder.check_in("~/code/missing/deeper", home)
    == Error(creations.NotAFolder)
  assert new_folder.check_in("~/notes.txt", home) == Error(creations.NotAFolder)
  assert new_folder.check_in("~/notes.txt/x", home)
    == Error(creations.NotAFolder)

  // A link whose target is gone is not a folder either.
  let assert Ok(Nil) =
    simplifile.create_symlink(home <> "/gone", home <> "/dangling")
    as "a dangling link"
  assert new_folder.check_in("~/dangling", home) == Error(creations.NotAFolder)
}

pub fn text_that_cannot_name_a_folder_is_refused_test() {
  let home = owners_home("folder-text")
  assert new_folder.check_in("", home) == Error(creations.NotAFolder)
  assert new_folder.check_in("   ", home) == Error(creations.NotAFolder)
  assert new_folder.check_in("code/app", home) == Error(creations.NotAFolder)
  assert new_folder.check_in("./code", home) == Error(creations.NotAFolder)
  assert new_folder.check_in("~code", home) == Error(creations.NotAFolder)
  assert new_folder.check_in("~root/code", home) == Error(creations.NotAFolder)
  assert new_folder.check_in("~/code\n/app", home)
    == Error(creations.NotAFolder)
  assert new_folder.check_in("~/code\u{202e}/app", home)
    == Error(creations.NotAFolder)
  assert new_folder.check_in("~/" <> string.repeat("a", 5000), home)
    == Error(creations.NotAFolder)
}

// The owner must be able to read, write and search the folder: one they cannot
// write is not a place for a session to work in.
pub fn a_folder_the_owner_cannot_write_is_refused_test() {
  let home = owners_home("folder-readonly")
  let assert Ok(Nil) = simplifile.create_directory_all(home <> "/locked")
    as "a folder"
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(home <> "/locked", 0o500)
    as "made read-only"
  let refused = new_folder.check_in("~/locked", home)
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(home <> "/locked", 0o700)
    as "restored"
  assert refused == Error(creations.NotAFolder)
  assert new_folder.check_in("~/locked", home) == Ok(home <> "/locked")
}

// The daemon's own home is read from the environment and is canonical.
pub fn the_daemons_home_is_canonical_test() {
  let assert Ok(home) = new_folder.home() as "the test runs with a HOME"
  assert bootstrap.canonical_directory(home) == Ok(home)
  assert result.is_ok(bootstrap.getenv("HOME"))
}
