import broker/policy
import client/directories
import client/gateway_test
import core/clock
import core/ids
import core/json
import core/register
import core/tx
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/result
import runtime/api
import session/session
import simplifile
import storage/storage
import tools/directory_access

/// The compatibility supplier remains lazy through validation and readback.
///
/// ## Examples
///
/// ```gleam
/// // Invalid paths never ask the host for its runtime.
/// ```
pub fn admin_preserves_lazy_runtime_acquisition_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "the test workspace must be known"
  let assert Ok(opened) = session.open_memory(clock.fixed(1000))
    as "the lazy admin session must open"
  let calls = process.new_subject()
  let admin =
    directories.admin(
      opened,
      fn() {
        process.send(calls, Nil)
        Error(Nil)
      },
      here,
      policy.workspace_default(here),
    )
  assert admin.read() == Ok(json.Array([]))
  assert result.is_error(admin.add(
    json.Object([
      #("path", json.String(here <> "/missing-directory-capture-fixture")),
      #("access", json.String("read")),
    ]),
    None,
  ))
  assert process.receive(calls, within: 0) == Error(Nil)

  // A valid filesystem request acquires exactly once, then preserves the
  // compatibility supplier's unavailable refusal rather than caching it.
  assert admin.add(
      json.Object([
        #("path", json.String(here)),
        #("access", json.String("read")),
      ]),
      None,
    )
    == Error("session is unavailable")
  assert process.receive(calls, within: 1000) == Ok(Nil)
  assert process.receive(calls, within: 0) == Error(Nil)
  assert session.close(opened) == Ok(Nil)
}

/// The projected production door commits additions and returns durable views.
///
/// ## Examples
///
/// ```gleam
/// // A read grant upgrades to write without adding another directory.
/// ```
pub fn projected_admin_commits_and_upgrades_directory_access_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "the granted workspace must exist"
  let id = ids.mint_session(ids.generator(clock.fixed(1000), 642)).0
  let harness = gateway_test.reserved_fixture(id)
  let facts = api.fact_handle(harness.runtime)
  let admin =
    directories.admin_with_facts(
      harness.runtime.session,
      fn() { Ok(facts) },
      here,
      policy.workspace_default(here),
    )
  let request = fn(mode) {
    json.Object([
      #("path", json.String(here)),
      #("access", json.String(mode)),
    ])
  }
  let expected = fn(mode) { json.Array([request(mode)]) }
  assert admin.add(request("read"), None) == Ok(expected("read"))
  assert admin.add(request("write"), None) == Ok(expected("write"))
  assert admin.read() == Ok(expected("write"))
  let assert Ok(Some(cell)) = api.fact_cell(harness.runtime, directories.key)
    as "the projected door must commit through the real writer"
  assert cell.value
    == json.Object([
      #("directories", expected("write")),
      #("origin", json.Null),
    ])
  assert api.close(harness.runtime) == Ok(Nil)
}

pub fn directory_fact_survives_sqlite_close_and_reopen_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "the test directory must be known"
  let root = here <> "/build/directory-durability"
  let _cleared = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/shared")
    as "the granted directory must exist"
  let path = root <> "/session.db"
  let time = clock.fixed(at: 1000)
  let assert Ok(opened) =
    session.open_sqlite(
      path:,
      owner: "directory-test",
      lease_ttl_ms: 30_000,
      clock: time,
    )
    as "the session must open"
  let access = directory_access.Access([root <> "/shared"], [root <> "/shared"])
  let value =
    json.Object([
      #("directories", directories.encode(access)),
      #("origin", json.Null),
    ])
  let assert Ok(_) =
    storage.commit(
      opened.store,
      tx.Tx(
        [
          tx.SetRegister(
            register.FactCustom,
            directories.key,
            register.value(value),
          ),
        ],
        [tx.Expect(register.FactCustom, directories.key, None)],
      ),
    )
    as "the directory fact must be committed"
  let assert Ok(Nil) = session.close(opened) as "the first session must close"
  let assert Ok(reopened) =
    session.open_sqlite(
      path:,
      owner: "directory-reopened",
      lease_ttl_ms: 30_000,
      clock: time,
    )
    as "the same session must reopen"
  assert directories.read(reopened) == Ok(access)
  let assert Ok(Nil) = session.close(reopened)
    as "the reopened session must close"
}

pub fn corrupt_directory_authority_is_refused_test() {
  assert result.is_error(directories.decode(json.Object([])))
  let bad =
    json.Object([
      #(
        "directories",
        json.Array([
          json.Object([
            #("path", json.String("/work/../secret")),
            #("access", json.String("write")),
          ]),
        ]),
      ),
    ])
  assert result.is_error(directories.decode(bad))
  let unknown =
    json.Object([
      #(
        "directories",
        json.Array([
          json.Object([
            #("path", json.String("/work")),
            #("access", json.String("everything")),
          ]),
        ]),
      ),
    ])
  assert result.is_error(directories.decode(unknown))
}

pub fn stored_directory_cannot_be_retargeted_through_a_symlink_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "the test directory must be known"
  let root = here <> "/build/directory-retarget"
  let _cleared = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/other")
    as "the target must exist"
  let assert Ok(Nil) =
    simplifile.create_symlink(root <> "/other", root <> "/granted")
    as "the retargeted link must exist"
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 1000))
    as "the session must open"
  let value =
    json.Object([
      #(
        "directories",
        directories.encode(directory_access.Access([root <> "/granted"], [])),
      ),
    ])
  let assert Ok(_) =
    storage.commit(
      opened.store,
      tx.Tx(
        [
          tx.SetRegister(
            register.FactCustom,
            directories.key,
            register.value(value),
          ),
        ],
        [],
      ),
    )
    as "the formerly canonical grant must be present"
  assert result.is_error(directories.read(opened))
  let assert Ok(Nil) = session.close(opened) as "the session must close"
}

fn addition_root(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test workspace must be known"
  let root = here <> "/build/directories-" <> name
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/lib")
    as "the addition's parent must exist"
  root
}

/// Resolving an addition is the half of `add-dir` which needs the files: it
/// takes a relative request against the workspace and answers the
/// canonical path to record, without touching a session.
pub fn an_addition_resolves_against_the_workspace_filesystem_test() {
  let root = addition_root("resolves")
  let resolved = directories.resolve_addition(root, [], "lib", "read")
  assert result.is_ok(resolved)
  assert resolved
    == directories.resolve_addition(root, [], root <> "/lib", "read")
}

/// A request that names no directory is refused in the words the gateway
/// has always used, and a writable addition may not reach a protected path.
pub fn an_addition_refuses_a_missing_file_or_protected_path_test() {
  let root = addition_root("refuses")
  let assert Ok(Nil) = simplifile.write(root <> "/file.txt", "text")
    as "a file is not a directory"
  assert directories.resolve_addition(root, [], "nothing", "read")
    == Error("add-dir requires an existing directory")
  assert directories.resolve_addition(root, [], "file.txt", "read")
    == Error("add-dir requires an existing directory")
  assert directories.resolve_addition(root, [root <> "/lib"], "lib", "write")
    == Error("directory could not be resolved or is protected")
}
