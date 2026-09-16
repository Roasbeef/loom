import client/directories
import core/clock
import core/json
import core/register
import core/tx
import gleam/option.{None}
import gleam/result
import session/session
import simplifile
import storage/storage
import tools/directory_access

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
