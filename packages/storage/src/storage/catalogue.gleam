//// Durable daemon registrations, separate from every conversation database.
////
//// The daemon's catalogue owner serializes these calls while holding the state
//// directory's lifetime lock. Opening this connection and listing records never
//// opens a session, acquires its writer lease, or starts recovered work. Creation
//// first reserves an identity and path; completion records that initialization
//// succeeded. A retry with the same request key returns the original reservation.
////
//// This module owns SQLite transactions and total row decoding. The daemon owns
//// path canonicalization, authorization, capacity and runtime liveness. A saved
//// record is not evidence of a resident runtime. Reserved records survive a crash
//// so reconciliation can check the original file instead of creating another.
////
//// ## Flow
////
//// `open` → `reserve` → `confirm` → `get` → `rename` → `seed_subtitle` → `page`
////
//// 1. `open` configures one connection and `initialize_schema` creates the
////    tables or applies the migrations a version lacks, in one transaction.
//// 2. `reserve` records a creation's identity and path before its file exists,
////    and `confirm` marks the file verified.
//// 3. `get` and `page` read the creation record with its display layers (the
////    name override and the subtitle), and neither opens a conversation file.
////    `decode_workspace` requires canonical binding JSON and SQL key agreement.
//// 4. `rename` writes the display-name override after `display_name` accepts it.
//// 5. `seed_subtitle` reduces a first prompt with `subtitle_from_prompt` and
////    writes the result once.
//// 6. `delete` removes a registration and every row that refers to it.
//// 7. `remember_folder`, `recent_folders` and `forget_folder` keep the short list
////    of folders the owner recently started a session in, which belongs to no
////    session and so outlives every one.

import core/ids
import core/json
import core/workspace
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import sqlight
import storage/catalogue_archives_schema
import storage/catalogue_claims_schema
import storage/catalogue_credential_kinds_schema
import storage/catalogue_logins_schema
import storage/catalogue_names_schema
import storage/catalogue_profiles_schema
import storage/catalogue_recent_folders_schema
import storage/catalogue_subtitles_schema
import storage/catalogue_workspace_bindings_schema
import storage/sql
import storage/sql_schema
import storage/sqlite_policy

/// Metadata initialization, independent of runtime residency.
pub type State {
  /// The creation request owns this identity and path but may not have a file.
  Reserved

  /// The file's canonical identity has been verified by the daemon.
  Saved
}

/// Visibility is independent of file initialization and runtime residency.
pub type Visibility {
  /// Included in ordinary listings and eligible for explicit admission.
  Active

  /// Preserved for the owner to restore, with execution admission disabled.
  Archived
}

/// A registration contains no provider credentials or conversation contents.
pub type Registration {
  Registration(
    /// The canonical conversation identity, also reserved before file creation.
    id: String,
    /// The host-validated canonical database path.
    path: String,
    /// Resolved workspace identity and retained authority, never an endpoint.
    workspace: workspace.Binding,
    /// A display label, never a routing or authorization identity.
    name: String,
    /// The host configuration reference, not its secret values.
    configuration: String,
    /// The model profile the session was created under, by name, or `None`
    /// for the configuration's default roles. It is part of the immutable
    /// creation request, so a retry compares it, and it is a name rather than
    /// the roles it resolved to: the daemon resolves it again each time the
    /// session opens (protocol-change/076).
    profile: Option(String),
    /// Creation time in Unix milliseconds.
    created_at: Int,
    /// The immutable creation request key.
    request_key: String,
    /// Whether database initialization has been confirmed.
    state: State,
    /// The first line of the owner's first prompt, cut to `subtitle_limit`
    /// characters and written once (`seed_subtitle`). A display aid layered
    /// over the creation record like the name override, so a reservation
    /// retry never compares it: only `get` and the pages carry it.
    subtitle: Option(String),
  )
}

/// An open metadata connection, owned by the daemon's catalogue lifetime.
pub opaque type Catalogue {
  Catalogue(connection: sqlight.Connection)
}

/// Catalogue failures never authorize modifying the conversation file.
pub type Error {
  /// An unsupported or unrelated database was supplied as the catalogue.
  Unsupported

  /// Input metadata or a persisted record failed validation.
  Invalid(reason: String)

  /// A unique key conflicts, or a default selects another workspace's session.
  Conflict

  /// No registration has this identity.
  Missing

  /// SQLite could not complete the operation.
  Database(reason: String)
}

/// A bounded page and the revision against which it was read.
pub type Page {
  Page(
    /// Changes to durable registrations increment this revision.
    revision: Int,
    /// At most `page_limit` records, sorted by canonical identity.
    records: List(Registration),
  )
}

/// The largest list response; callers continue after the last returned ID.
pub const page_limit = 100

/// The most characters a subtitle holds.
pub const subtitle_limit = 60

/// Opens only the metadata database, initializing an empty file or refusing it.
///
/// The parent directory must already be private and protected from model writes.
/// The caller holds the daemon lifetime lock until this connection is closed.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.open(state_root <> "/catalogue.db")
/// ```
pub fn open(path: String) -> Result(Catalogue, Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(sql_error),
  )
  case initialize(connection) {
    Ok(Nil) -> Ok(Catalogue(connection))
    Error(error) -> {
      let _closed = sqlight.close(connection)
      Error(error)
    }
  }
}

fn initialize(connection: sqlight.Connection) -> Result(Nil, Error) {
  let defaults = sqlite_policy.defaults()
  let options =
    sqlite_policy.Options(..defaults, foreign_keys: sqlite_policy.Enabled)
  use Nil <- result.try(
    sqlite_policy.configure_connection(connection, options)
    |> result.map_error(sql_error),
  )
  use Nil <- result.try(initialize_schema(connection))
  sqlite_policy.configure_database(connection, options)
  |> result.map_error(sql_error)
}

// Journal configuration follows schema validation, so an unrelated file is
// refused before any persistent tuning can change its header.
//
// Each version after the first adds one migration schema, and an older
// catalogue applies every schema it lacks in one transaction, so a crash
// part-way through a migration leaves the previous version intact rather
// than a catalogue that claims a version whose tables are missing.
fn initialize_schema(connection: sqlight.Connection) -> Result(Nil, Error) {
  use found <- result.try(number(connection, "PRAGMA application_id"))
  use version <- result.try(number(connection, "PRAGMA user_version"))
  case found, version {
    1_281_253_197, found_version if found_version == current_version -> {
      use _revision <- result.try(revision(Catalogue(connection)))
      Ok(Nil)
    }
    1_281_253_197, found_version
      if found_version >= 1 && found_version < current_version
    -> {
      use _revision <- result.try(revision(Catalogue(connection)))
      transaction(connection, fn() {
        use Nil <- result.try(case version {
          8 -> migrate_version_eight(connection)
          _ -> migrations_after(connection, version)
        })
        execute(connection, user_version_pragma())
      })
    }
    0, 0 -> {
      use tables <- result.try(number(connection, "PRAGMA schema_version"))
      case tables {
        0 ->
          transaction(connection, fn() {
            use Nil <- result.try(execute(connection, sql_schema.schema))
            use Nil <- result.try(migrations_after(connection, 1))
            use Nil <- result.try(statement(
              Catalogue(connection),
              sql.initialize_catalogue_revision(),
            ))
            execute(
              connection,
              "PRAGMA application_id=1281253197; " <> user_version_pragma(),
            )
          })
        _ -> Error(Unsupported)
      }
    }
    _, _ -> Error(Unsupported)
  }
}

/// The `user_version` this build writes and accepts, which is the highest
/// version in `migrations`. A change that adds a migration and forgets to
/// raise this fails `migrations_end_at_the_current_version_test` rather than
/// leaving a catalogue that claims a version whose migration never ran.
@internal
pub const current_version = 10

/// The migration schemas in version order, each applied to a catalogue that
/// lacks its version.
@internal
pub fn migrations() -> List(#(Int, String)) {
  [
    #(2, catalogue_names_schema.schema),
    #(3, catalogue_archives_schema.schema),
    #(4, catalogue_claims_schema.schema),
    #(5, catalogue_subtitles_schema.schema),
    #(6, catalogue_credential_kinds_schema.schema),
    #(7, catalogue_logins_schema.schema),
    #(8, catalogue_recent_folders_schema.schema),
    #(9, catalogue_profiles_schema.schema),
    #(10, catalogue_workspace_bindings_schema.schema),
  ]
}

// Main and the pre-integration branch both used version eight for different
// additions. Inspect their actual schema inside the migration transaction, so
// neither layout can skip its missing addition or rerun an existing ALTER.
// A mixed or absent layout is not one either branch wrote and is refused.
fn migrate_version_eight(connection: sqlight.Connection) -> Result(Nil, Error) {
  use folders <- result.try(number(
    connection,
    "SELECT COUNT(*) FROM sqlite_schema WHERE name='catalogue_recent_folders'",
  ))
  use bindings <- result.try(number(
    connection,
    "SELECT COUNT(*) FROM pragma_table_info('catalogue_sessions') WHERE name='workspace_binding'",
  ))
  case folders, bindings {
    1, 0 -> execute(connection, catalogue_workspace_bindings_schema.schema)
    0, 1 -> execute(connection, catalogue_recent_folders_schema.schema)
    _, _ -> Error(Unsupported)
  }
}

fn user_version_pragma() -> String {
  "PRAGMA user_version=" <> int.to_string(current_version)
}

// The schemas a catalogue at `version` lacks, applied in version order. A
// fresh catalogue is version one once `sql_schema` is in place, so creation
// and migration run the same list and cannot drift apart.
fn migrations_after(
  connection: sqlight.Connection,
  version: Int,
) -> Result(Nil, Error) {
  migrations()
  |> list.filter(fn(migration) { migration.0 > version })
  |> list.try_each(fn(migration) { execute(connection, migration.1) })
}

/// Reserves a creation exactly once without touching its conversation file.
///
/// Retrying the same key and metadata returns the stored record, including a
/// completed state. A conflicting key or a second identity for one path fails.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.reserve(catalogue, record)
/// ```
pub fn reserve(
  catalogue: Catalogue,
  record: Registration,
) -> Result(Registration, Error) {
  transaction(catalogue.connection, fn() {
    reserve_in_transaction(catalogue, record)
  })
}

/// Reserves metadata inside the caller's existing immediate transaction.
///
/// Domain creation uses this seam so a registration and its mapping commit
/// together. It must never be called outside an enclosing catalogue transaction.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.atomic(store, fn() { catalogue.reserve_in_transaction(store, record) })
/// ```
@internal
pub fn reserve_in_transaction(
  catalogue: Catalogue,
  record: Registration,
) -> Result(Registration, Error) {
  use Nil <- result.try(validate(record))
  use existing <- result.try(find(catalogue, "", record.request_key, ""))
  reserve_record(catalogue, record, existing)
}

fn reserve_record(
  catalogue: Catalogue,
  record: Registration,
  existing: List(Registration),
) {
  case existing {
    [old] -> {
      case
        Registration(..old, state: Reserved)
        == Registration(..record, state: Reserved)
      {
        True -> Ok(old)
        False -> Error(Conflict)
      }
    }
    [] -> {
      use conflicts <- result.try(find(catalogue, record.id, "", record.path))
      case conflicts {
        [] -> insert(catalogue, Registration(..record, state: Reserved))
        [_, ..] -> Error(Conflict)
      }
    }
    [_, _, ..] -> Error(Invalid("duplicate creation key"))
  }
}

fn insert(
  catalogue: Catalogue,
  record: Registration,
) -> Result(Registration, Error) {
  // Separate named inserts keep local NULL outside the general parameter
  // adapter, while registered creation retains exact canonical authority.
  let generated = case record.workspace {
    workspace.LocalBinding(path) ->
      sql.insert_registration(
        record.id,
        record.path,
        path,
        record.name,
        record.configuration,
        record.created_at,
        record.request_key,
        option.unwrap(record.profile, ""),
      )
    workspace.Registered(_) ->
      sql.insert_registered_registration(
        record.id,
        record.path,
        workspace.key_string(workspace.binding_key(record.workspace)),
        Some(json.to_string(workspace.encode_binding(record.workspace))),
        record.name,
        record.configuration,
        record.created_at,
        record.request_key,
        option.unwrap(record.profile, ""),
      )
  }
  use Nil <- result.try(statement(catalogue, generated))
  use Nil <- result.try(statement(catalogue, sql.increment_catalogue_revision()))
  Ok(record)
}

/// Confirms that the daemon verified the reserved file's canonical identity.
///
/// A repeated confirmation is a no-op and does not invalidate list cursors.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.confirm(catalogue, session_id)
/// ```
pub fn confirm(
  catalogue: Catalogue,
  id: String,
) -> Result(Registration, Error) {
  transaction(catalogue.connection, fn() {
    use record <- result.try(get(catalogue, id))
    case record.state {
      Saved -> Ok(record)
      Reserved -> {
        use Nil <- result.try(statement(catalogue, sql.confirm_registration(id)))
        use Nil <- result.try(statement(
          catalogue,
          sql.increment_catalogue_revision(),
        ))
        Ok(Registration(..record, state: Saved))
      }
    }
  })
}

/// Looks up metadata without opening the referenced database.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.get(catalogue, session_id)
/// ```
pub fn get(catalogue: Catalogue, id: String) -> Result(Registration, Error) {
  use found <- result.try(find(catalogue, id, "", ""))
  case found {
    [record] -> display_record(catalogue, record)
    [] -> Error(Missing)
    [_, _, ..] -> Error(Invalid("duplicate session identity"))
  }
}

/// Saves a display override without changing the original creation request.
///
/// The label and revision commit atomically. An unchanged label writes nothing.
/// The daemon manager supplies owner authorization before entering this DAL.
/// The name must pass `display_name`, which is stricter than the first version
/// of this command was: a name is drawn beside other text on a page, so it may
/// not hold a zero-width or direction-changing character.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.rename(store, session_id, "review auth")
/// ```
pub fn rename(
  catalogue: Catalogue,
  id: String,
  name: String,
) -> Result(Registration, Error) {
  use Nil <- result.try(display_name(name))
  transaction(catalogue.connection, fn() {
    use record <- result.try(get(catalogue, id))
    case record.name == name {
      True -> Ok(record)
      False -> {
        use Nil <- result.try(statement(
          catalogue,
          sql.set_registration_display_name(id, name),
        ))
        use Nil <- result.try(statement(
          catalogue,
          sql.increment_catalogue_revision(),
        ))
        Ok(Registration(..record, name:))
      }
    }
  })
}

/// Judges a display name about to be written.
///
/// A name is nonblank after trimming, at most 256 UTF-8 bytes, and holds no
/// control character and no zero-width or direction-changing one (`invisible`).
/// Those would reorder the words around the name on a page or leave a name
/// that draws as nothing. Reads are looser, so a name written before this rule
/// still decodes.
///
/// ## Examples
///
/// ```gleam
/// assert catalogue.display_name("review auth") == Ok(Nil)
/// ```
pub fn display_name(name: String) -> Result(Nil, Error) {
  let points =
    list.map(string.to_utf_codepoints(name), string.utf_codepoint_to_int)
  case
    string.trim(name) != ""
    && string.byte_size(name) <= 256
    && list.all(points, fn(value) { !control(value) && !invisible(value) })
  {
    True -> Ok(Nil)
    False ->
      Error(Invalid(
        "display name must be nonblank, at most 256 bytes, and contain no controls or invisible characters",
      ))
  }
}

// The C0 and C1 control ranges and DEL.
fn control(value: Int) -> Bool {
  value < 32 || value == 127 || { value >= 128 && value <= 159 }
}

/// Whether a code point is zero-width or changes text direction: the ones
/// `session_view/text_hygiene` replaces when it draws text. A name or subtitle
/// holding one is refused or has it removed, so neither can reorder the words
/// beside it or draw as nothing.
///
/// ## Examples
///
/// ```gleam
/// assert catalogue.invisible(0x202E)
/// ```
pub fn invisible(value: Int) -> Bool {
  { value >= 0x200B && value <= 0x200F }
  || { value >= 0x202A && value <= 0x202E }
  || { value >= 0x2060 && value <= 0x2069 }
  || value == 0xFEFF
  || value == 0xAD
  || value == 0x61C
  || value == 0x2028
  || value == 0x2029
}

/// Writes the session's subtitle from its first prompt, once.
///
/// The text is reduced by `subtitle_from_prompt`. A prompt that leaves nothing
/// (blank, or only invisible characters) writes nothing, so the next prompt may
/// still seed the subtitle. Once a subtitle exists the call writes nothing and
/// returns the record as it stands, so neither a later prompt nor a retry after
/// a restart can replace it; the check and the write share one transaction. The
/// subtitle and the catalogue revision commit together. The daemon calls this
/// from the session's gateway, which is the only place a human prompt is
/// accepted, so a subtitle is always the owner's or a member's own words and
/// never a session agent's.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.seed_subtitle(store, session_id, "Fix the flaky retry test")
/// ```
pub fn seed_subtitle(
  catalogue: Catalogue,
  id: String,
  prompt: String,
) -> Result(Registration, Error) {
  case subtitle_from_prompt(prompt) {
    None -> get(catalogue, id)
    Some(subtitle) ->
      transaction(catalogue.connection, fn() {
        use record <- result.try(get(catalogue, id))
        case record.subtitle {
          Some(_) -> Ok(record)
          None -> {
            use Nil <- result.try(statement(
              catalogue,
              sql.insert_registration_subtitle(id, subtitle),
            ))
            use Nil <- result.try(statement(
              catalogue,
              sql.increment_catalogue_revision(),
            ))
            Ok(Registration(..record, subtitle: Some(subtitle)))
          }
        }
      })
  }
}

/// The subtitle a prompt's text stands for, or `None` when it has none.
///
/// It is the first nonblank line, with each run of whitespace collapsed to one
/// space and every control, zero-width and direction-changing character
/// removed, cut to `subtitle_limit` characters. A line that is too long is cut
/// at the last word boundary that fits and marked with an ellipsis, which
/// counts toward the limit; a single word longer than the limit is cut where it
/// reaches it.
///
/// ## Examples
///
/// ```gleam
/// assert catalogue.subtitle_from_prompt("  fix   the\ttest\nthen ship")
///   == Some("fix the test")
/// ```
pub fn subtitle_from_prompt(prompt: String) -> Option(String) {
  let lines =
    prompt
    |> string.replace("\r\n", "\n")
    |> string.replace("\r", "\n")
    |> string.split("\n")
    |> list.map(collapse)
  case list.find(lines, fn(line) { line != "" }) {
    Ok(line) -> Some(fit_subtitle(line))
    Error(Nil) -> None
  }
}

// One line with whitespace runs reduced to a single space and unprintable code
// points dropped, trimmed at both ends.
fn collapse(line: String) -> String {
  line
  |> string.to_utf_codepoints
  |> list.filter_map(fn(point) {
    let value = string.utf_codepoint_to_int(point)
    case value {
      9 | 32 | 0xA0 | 0x3000 -> Ok(" ")
      _ ->
        case control(value) || invisible(value) {
          True -> Error(Nil)
          False -> Ok(string.from_utf_codepoints([point]))
        }
    }
  })
  |> string.concat
  |> string.split(" ")
  |> list.filter(fn(word) { word != "" })
  |> string.join(" ")
}

fn fit_subtitle(line: String) -> String {
  case code_points(line) <= subtitle_limit {
    True -> line
    False -> {
      let kept = take_points(string.to_graphemes(line), subtitle_limit - 1, [])
      let rest = string.drop_start(line, string.length(kept))

      // The limit may fall exactly between two words, in which case nothing
      // is backed out. Inside a word the last, partial word is dropped, unless
      // it is the only one, which is cut where it reaches the limit.
      let cut = case string.starts_with(rest, " "), string.contains(kept, " ") {
        True, _ | False, False -> kept
        False, True -> without_last_word(kept)
      }
      string.trim_end(cut) <> "…"
    }
  }
}

fn without_last_word(text: String) -> String {
  text
  |> string.split(" ")
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.join(" ")
}

// The longest run of whole graphemes holding at most `room` code points, so a
// cut never splits a character a reader sees as one.
fn take_points(
  graphemes: List(String),
  room: Int,
  kept: List(String),
) -> String {
  case graphemes {
    [] -> string.concat(list.reverse(kept))
    [next, ..rest] -> {
      let used = code_points(next)
      case used <= room {
        True -> take_points(rest, room - used, [next, ..kept])
        False -> string.concat(list.reverse(kept))
      }
    }
  }
}

fn code_points(text: String) -> Int {
  list.length(string.to_utf_codepoints(text))
}

// A stored subtitle decodes only when it still satisfies what `seed_subtitle`
// writes. One that does not (written by a later version, or damaged) reads as
// absent rather than failing the listing it appears in.
fn stored_subtitle(subtitle: String) -> Option(String) {
  case
    subtitle != ""
    && code_points(subtitle) <= subtitle_limit
    && list.all(string.to_utf_codepoints(subtitle), fn(point) {
      let value = string.utf_codepoint_to_int(point)
      !control(value) && !invisible(value)
    })
  {
    True -> Some(subtitle)
    False -> None
  }
}

// Display reads layer mutable labels over immutable creation metadata. This
// helper must not enter find/by_request_key, which prove retry equality.
fn display_record(catalogue: Catalogue, record: Registration) {
  use names <- result.try(query(
    catalogue,
    sql.registration_display_name(record.id),
  ))
  use subtitles <- result.try(query(
    catalogue,
    sql.registration_subtitle(record.id),
  ))
  use named <- result.try(case names {
    [] -> Ok(record)
    [name] -> Ok(Registration(..record, name: name.name))
    [_, _, ..] -> Error(Invalid("duplicate session display name"))
  })
  case subtitles {
    [] -> Ok(named)
    [found] ->
      Ok(Registration(..named, subtitle: stored_subtitle(found.subtitle)))
    [_, _, ..] -> Error(Invalid("duplicate session subtitle"))
  }
}

/// Recovers the original reservation before a creation retry mints anything.
///
/// The daemon compares caller-supplied metadata with this record, then reuses
/// its identity, path and creation time. `Missing` alone permits a fresh
/// reservation; a decode or database error must not trigger another creation.
/// This lookup never opens the registered conversation file.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.by_request_key(catalogue, request_key)
/// ```
pub fn by_request_key(
  catalogue: Catalogue,
  request_key: String,
) -> Result(Registration, Error) {
  use found <- result.try(find(catalogue, "", request_key, ""))
  case found {
    [record] -> Ok(record)
    [] -> Error(Missing)
    [_, _, ..] -> Error(Invalid("duplicate creation key"))
  }
}

/// Reads the workspace's durable default without opening its conversation.
///
/// Missing mappings return `Missing`. A dangling mapping or a registration from
/// another workspace is invalid metadata, never a candidate to start. A reserved
/// registration remains reserved; the default does not claim initialization.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.workspace_default(catalogue, workspace)
/// ```
pub fn workspace_default(
  catalogue: Catalogue,
  workspace: workspace.WorkspaceKey,
) -> Result(Registration, Error) {
  snapshot(catalogue.connection, fn() {
    use id <- result.try(default_identity(catalogue, workspace))
    use record <- result.try(
      get(catalogue, id)
      |> result.map_error(fn(error) {
        case error {
          Missing -> Invalid("workspace default refers to a missing session")
          other -> other
        }
      }),
    )
    case workspace.binding_key(record.workspace) == workspace {
      True -> Ok(record)
      False -> Error(Invalid("workspace default refers to another workspace"))
    }
  })
}

/// Selects a registered session in this workspace as its durable default.
///
/// The mapping and revision update commit together. Selecting the current
/// identity writes nothing and leaves pagination revisions unchanged. Neither
/// selection nor validation opens a conversation or changes runtime residency.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.set_workspace_default(catalogue, workspace, session_id)
/// ```
pub fn set_workspace_default(
  catalogue: Catalogue,
  workspace: workspace.WorkspaceKey,
  id: String,
) -> Result(Registration, Error) {
  transaction(catalogue.connection, fn() {
    use record <- result.try(get(catalogue, id))
    use state <- result.try(archive_state(catalogue, id))
    use Nil <- result.try(case state {
      Active -> Ok(Nil)
      Archived -> Error(Conflict)
    })
    use Nil <- result.try(
      case workspace.binding_key(record.workspace) == workspace {
        True -> Ok(Nil)
        False -> Error(Conflict)
      },
    )
    case default_identity(catalogue, workspace) {
      Ok(current) if current == id -> Ok(record)
      Ok(_) | Error(Missing) -> {
        use Nil <- result.try(statement(
          catalogue,
          sql.set_workspace_default(workspace.key_string(workspace), id),
        ))
        use Nil <- result.try(statement(
          catalogue,
          sql.increment_catalogue_revision(),
        ))
        Ok(record)
      }
      Error(error) -> Error(error)
    }
  })
}

/// Reads visibility independently of the immutable creation record.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.visibility(store, session_id)
/// ```
@internal
pub fn visibility(
  catalogue: Catalogue,
  id: String,
) -> Result(Visibility, Error) {
  use _record <- result.try(get(catalogue, id))
  archive_state(catalogue, id)
}

fn archive_state(
  catalogue: Catalogue,
  id: String,
) -> Result(Visibility, Error) {
  use rows <- result.try(query(catalogue, sql.session_archive(id)))
  case rows {
    [] -> Ok(Active)
    [sql.SessionArchive(found)] if found == id -> Ok(Archived)
    _ -> Error(Invalid("invalid archive metadata"))
  }
}

/// Changes visibility and the catalogue revision in one transaction.
///
/// Archiving clears an existing workspace default. Restoring never selects a
/// default or starts a runtime. The caller serializes this write with runtime
/// admission and proves the session holds no slot before entering this seam.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.set_visibility(store, session_id, catalogue.Archived)
/// ```
@internal
pub fn set_visibility(
  catalogue: Catalogue,
  id: String,
  visibility: Visibility,
) -> Result(Registration, Error) {
  transaction(catalogue.connection, fn() {
    use record <- result.try(get(catalogue, id))
    use current <- result.try(archive_state(catalogue, id))
    case current == visibility {
      True -> Ok(record)
      False -> {
        use Nil <- result.try(case visibility {
          Active -> statement(catalogue, sql.restore_session(id))
          Archived -> {
            use Nil <- result.try(statement(
              catalogue,
              sql.delete_session_default(id),
            ))
            statement(catalogue, sql.archive_session(id))
          }
        })
        use Nil <- result.try(statement(
          catalogue,
          sql.increment_catalogue_revision(),
        ))
        Ok(record)
      }
    }
  })
}

/// Removes one registration and every catalogue row that refers to it.
///
/// The registration, its memberships, its display name and subtitle, a workspace default
/// naming it and its domain mapping are removed in one immediate transaction, so no reader can
/// observe a catalogue whose foreign keys point at a session that is half
/// gone. The domain record itself survives: a domain owns distilled memory
/// for a workspace and outlives any one conversation that fed it.
///
/// This never touches the conversation database on disk. The caller unlinks
/// the file after this returns, which is the safe order: a crash between the
/// two leaves an unreferenced file rather than a registration pointing at a
/// file that no longer exists.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.delete(catalogue, session_id)
/// ```
pub fn delete(catalogue: Catalogue, id: String) -> Result(Registration, Error) {
  transaction(catalogue.connection, fn() {
    use record <- result.try(get(catalogue, id))

    // Dependants first: foreign keys are enabled on this connection, so the
    // registration row cannot leave while anything still references it.
    use Nil <- result.try(statement(catalogue, sql.delete_session_default(id)))
    use Nil <- result.try(statement(
      catalogue,
      sql.delete_session_memberships(id),
    ))
    use Nil <- result.try(statement(catalogue, sql.delete_session_domain(id)))
    use Nil <- result.try(statement(catalogue, sql.restore_session(id)))

    // The display name and the subtitle are keyed by session id and nothing
    // else, so each would otherwise outlive the registration and be inherited by a later session
    // that happened to reuse the identity.
    use Nil <- result.try(statement(
      catalogue,
      sql.delete_session_display_name(id),
    ))
    use Nil <- result.try(statement(catalogue, sql.delete_session_subtitle(id)))
    use Nil <- result.try(statement(catalogue, sql.delete_registration(id)))

    // The revision moves so an open listing page is refused rather than
    // silently continuing after a row it already returned has gone.
    use Nil <- result.try(statement(
      catalogue,
      sql.increment_catalogue_revision(),
    ))
    Ok(record)
  })
}

fn default_identity(
  catalogue: Catalogue,
  workspace: workspace.WorkspaceKey,
) -> Result(String, Error) {
  use rows <- result.try(query(
    catalogue,
    sql.workspace_default(workspace.key_string(workspace)),
  ))
  case rows {
    [sql.WorkspaceDefault(id)] -> Ok(id)
    [] -> Error(Missing)
    [_, _, ..] -> Error(Invalid("duplicate workspace default"))
  }
}

/// Lists one identity-ordered metadata page from a coherent SQLite snapshot.
///
/// Use an empty `after` for the first page. Restart pagination if a subsequent
/// page has a different revision. No page scan opens conversation databases.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.page(catalogue, after: "")
/// ```
pub fn page(catalogue: Catalogue, after after: String) -> Result(Page, Error) {
  page_for(catalogue, after, Active)
}

/// Lists one bounded owner archive page without opening conversation files.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.archived_page(store, after: "")
/// ```
@internal
pub fn archived_page(
  catalogue: Catalogue,
  after after: String,
) -> Result(Page, Error) {
  page_for(catalogue, after, Archived)
}

fn page_for(
  catalogue: Catalogue,
  after: String,
  visibility: Visibility,
) -> Result(Page, Error) {
  let archived = case visibility {
    Active -> 0
    Archived -> 1
  }
  snapshot(catalogue.connection, fn() {
    use revision <- result.try(revision(catalogue))
    use rows <- result.try(query(
      catalogue,
      sql.registration_page(after, archived),
    ))
    use records <- result.try(
      list.try_map(rows, fn(row) {
        use binding <- result.try(decode_workspace(
          row.workspace,
          row.workspace_binding,
        ))
        decoded(
          Registration(
            id: row.session_id,
            path: row.path,
            workspace: binding,
            name: row.name,
            configuration: row.configuration,
            created_at: row.created_at,
            request_key: row.request_key,
            state: Reserved,
            profile: stored_profile(row.profile),
            subtitle: option.then(row.subtitle, stored_subtitle),
          ),
          row.state,
        )
      }),
    )
    Ok(Page(revision:, records:))
  })
}

fn revision(catalogue: Catalogue) -> Result(Int, Error) {
  use rows <- result.try(query(catalogue, sql.catalogue_revision()))
  case rows {
    [sql.CatalogueRevision(revision)] -> Ok(revision)
    [] | [_, _, ..] -> Error(Invalid("expected one catalogue revision"))
  }
}

/// Lists only registrations with a valid membership for this principal.
///
/// Authorization precedes pagination in SQL, so neither an empty filtered page
/// nor its continuation identity reveals an unrelated registration. This is an
/// internal read capability; the daemon authenticates the credential on each
/// page. The global revision can reveal metadata activity, not hidden identities.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.member_page(store, principal.id, after: "")
/// ```
@internal
pub fn member_page(
  catalogue: Catalogue,
  principal_id: String,
  after after: String,
) -> Result(Page, Error) {
  snapshot(catalogue.connection, fn() {
    use revision <- result.try(revision(catalogue))
    use rows <- result.try(query(
      catalogue,
      sql.member_registration_page(principal_id, after),
    ))
    use records <- result.try(
      list.try_map(rows, fn(row) {
        use binding <- result.try(decode_workspace(
          row.workspace,
          row.workspace_binding,
        ))
        decoded(
          Registration(
            id: row.session_id,
            path: row.path,
            workspace: binding,
            name: row.name,
            configuration: row.configuration,
            created_at: row.created_at,
            request_key: row.request_key,
            state: Reserved,
            profile: stored_profile(row.profile),
            subtitle: option.then(row.subtitle, stored_subtitle),
          ),
          row.state,
        )
      }),
    )
    Ok(Page(revision:, records:))
  })
}

/// The most folders the catalogue remembers. A creation that would make an
/// eleventh forgets the oldest, so the list a page draws stays short and the
/// table cannot grow without bound.
pub const recent_folder_limit = 10

/// Remembers a folder a session was just created in, as the newest.
///
/// A folder already remembered moves to the front instead of appearing twice,
/// and one that falls past `recent_folder_limit` is forgotten. The delete, the
/// insert and the trim commit together, so a reader never sees the folder
/// twice or the list over its bound. The text is the daemon's canonical
/// workspace path; an empty one or one longer than a path may be is refused
/// rather than stored. Recency is the table's sequence, not a clock, so the
/// order survives a restart and a clock that moves backward.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.remember_folder(store, "/Users/o/code/app")
/// ```
pub fn remember_folder(
  catalogue: Catalogue,
  workspace: String,
) -> Result(Nil, Error) {
  case workspace != "" && string.byte_size(workspace) <= 4096 {
    False -> Error(Invalid("recent folder is empty or too long"))
    True ->
      transaction(catalogue.connection, fn() {
        use Nil <- result.try(statement(
          catalogue,
          sql.delete_recent_folder(workspace),
        ))
        use Nil <- result.try(statement(
          catalogue,
          sql.insert_recent_folder(workspace),
        ))
        statement(catalogue, sql.trim_recent_folders(recent_folder_limit))
      })
  }
}

/// One remembered folder: its path, and the identity the table gave it when it
/// was remembered. The identity is the table's sequence, which no later row
/// reuses, so a page that keys its list by it and a press that names it can only
/// reach that entry, or nothing once it is gone or remembered again.
pub type Recent {
  Recent(id: Int, workspace: String)
}

/// The remembered folders, newest first.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.recent_folders(store)
/// ```
pub fn recent_folders(catalogue: Catalogue) -> Result(List(Recent), Error) {
  query(catalogue, sql.recent_folders())
  |> result.map(list.map(_, fn(row) { Recent(row.seq, row.workspace) }))
}

/// Forgets one remembered folder by its identity. An identity that is not
/// remembered (forgotten already, or remembered again since) is not an error:
/// the list is what the caller asked for either way.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.forget_folder(store, 4)
/// ```
pub fn forget_folder(catalogue: Catalogue, id: Int) -> Result(Nil, Error) {
  statement(catalogue, sql.forget_recent_folder(id))
}

/// Closes the metadata connection without stopping or opening any session.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.close(catalogue)
/// ```
pub fn close(catalogue: Catalogue) -> Result(Nil, Error) {
  sqlight.close(catalogue.connection) |> result.map_error(sql_error)
}

// The three unique keys share a generated row type. Empty arguments exclude
// unused keys because valid registrations cannot contain an empty key or path.
fn find(catalogue: Catalogue, id: String, request_key: String, path: String) {
  use rows <- result.try(query(
    catalogue,
    sql.find_registrations(id, request_key, path),
  ))
  list.try_map(rows, fn(row) {
    use binding <- result.try(decode_workspace(
      row.workspace,
      row.workspace_binding,
    ))
    decoded(
      Registration(
        id: row.session_id,
        path: row.path,
        workspace: binding,
        name: row.name,
        configuration: row.configuration,
        created_at: row.created_at,
        request_key: row.request_key,
        state: Reserved,
        profile: stored_profile(row.profile),
        subtitle: None,
      ),
      row.state,
    )
  })
}

// A stored selector key and its authority payload are redundant deliberately:
// agreement prevents corrupt metadata from selecting another enrolled workspace.
fn decode_workspace(
  key: String,
  payload: Option(String),
) -> Result(workspace.Binding, Error) {
  use identity <- result.try(
    workspace.decode_key(key)
    |> result.replace_error(Invalid("invalid workspace key")),
  )
  case identity, payload {
    workspace.LocalKey(path), None -> Ok(workspace.LocalBinding(path))
    workspace.RegisteredKey(selected), Some(text) -> {
      use Nil <- result.try(case string.byte_size(text) <= 1024 {
        True -> Ok(Nil)
        False -> Error(Invalid("workspace binding exceeds its bound"))
      })
      use value <- result.try(
        json.parse(text)
        |> result.replace_error(Invalid("invalid workspace binding JSON")),
      )
      use binding <- result.try(
        workspace.decode_binding(value)
        |> result.replace_error(Invalid("invalid workspace binding")),
      )
      case binding {
        workspace.Registered(bound) -> {
          let #(retained, _, _) = workspace.binding_fields(bound)
          case
            selected == retained
            && text == json.to_string(workspace.encode_binding(binding))
          {
            True -> Ok(binding)
            False ->
              Error(Invalid(
                "workspace key or canonical text disagrees with binding",
              ))
          }
        }
        workspace.LocalBinding(_) ->
          Error(Invalid("registered key needs registered binding"))
      }
    }
    workspace.LocalKey(_), Some(_) | workspace.RegisteredKey(_), None ->
      Error(Invalid("workspace key disagrees with binding payload"))
  }
}

fn decoded(record: Registration, state: String) -> Result(Registration, Error) {
  use Nil <- result.try(validate(record))
  case state {
    "reserved" -> Ok(record)
    "saved" -> Ok(Registration(..record, state: Saved))
    _ -> Error(Invalid("unknown registration state"))
  }
}

/// Runs a generated internal query on the catalogue's existing connection.
/// The daemon still owns serialization; this creates no second connection.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.query(store, sql.access_owner())
/// ```
@internal
pub fn query(
  catalogue: Catalogue,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) {
  let #(text, params, decoder) = generated
  use arguments <- result.try(list.try_map(params, parameter))
  sqlight.query(
    text,
    on: catalogue.connection,
    with: arguments,
    expecting: decoder,
  )
  |> result.map_error(sql_error)
}

/// Runs a generated internal statement under the catalogue's current owner.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.statement(store, sql.revoke_access_credential(digest))
/// ```
@internal
pub fn statement(catalogue: Catalogue, generated: #(String, List(dev.Param))) {
  let #(text, params) = generated
  query(catalogue, #(text, params, decode.success(Nil))) |> result.replace(Nil)
}

// These queries bind only non-null strings and integers. Parrot types a
// parameter that assigns a nullable column as `ParamNullable`, as the claim
// binding does; a present value binds as itself, and an absent one is refused
// rather than silently binding NULL, because no catalogue write clears a
// column. A future generator change must add an explicit conversion here.
fn parameter(param: dev.Param) -> Result(sqlight.Value, Error) {
  case param {
    dev.ParamInt(value) -> Ok(sqlight.int(value))
    dev.ParamString(value) -> Ok(sqlight.text(value))
    dev.ParamNullable(Some(value)) -> parameter(value)
    dev.ParamNullable(None)
    | dev.ParamFloat(_)
    | dev.ParamBool(_)
    | dev.ParamBitArray(_)
    | dev.ParamTimestamp(_)
    | dev.ParamDate(_)
    | dev.ParamList(_)
    | dev.ParamDynamic(_) ->
      Error(Invalid("unsupported generated catalogue parameter"))
  }
}

fn validate(record: Registration) -> Result(Nil, Error) {
  use key <- result.try(
    workspace.decode_key(
      workspace.key_string(workspace.binding_key(record.workspace)),
    )
    |> result.replace_error(Invalid("invalid workspace identity")),
  )
  use Nil <- result.try(case key, record.workspace {
    workspace.LocalKey(path), workspace.LocalBinding(found) if path == found ->
      Ok(Nil)
    workspace.RegisteredKey(selected), workspace.Registered(bound) -> {
      let #(retained, _, _) = workspace.binding_fields(bound)
      case selected == retained {
        True -> Ok(Nil)
        False -> Error(Invalid("workspace identity disagrees with binding"))
      }
    }
    workspace.LocalKey(_), workspace.Registered(_)
    | workspace.RegisteredKey(_), workspace.LocalBinding(_)
    -> Error(Invalid("workspace identity disagrees with binding"))
    workspace.LocalKey(_), workspace.LocalBinding(_) ->
      Error(Invalid("workspace identity disagrees with binding"))
  })
  use _id <- result.try(
    ids.parse_session_id(record.id)
    |> result.replace_error(Invalid("invalid canonical session ID")),
  )
  case
    string.starts_with(record.path, "/")
    && record.request_key != ""
    && record.created_at >= 0
  {
    True ->
      case record.profile {
        None -> Ok(Nil)
        Some(name) ->
          case is_profile_name(name) {
            True -> Ok(Nil)
            False ->
              Error(Invalid("registration profile is not a profile name"))
          }
      }
    False ->
      Error(Invalid(
        "registration needs an absolute conversation path, a request key and a nonnegative creation time",
      ))
  }
}

/// The longest profile name, in bytes.
pub const profile_name_limit = 32

/// Whether text is a model profile name: one to `profile_name_limit` characters
/// of lowercase ASCII letters, digits, `_` and `-`, beginning with a letter. It
/// is the one grammar for a `[profiles.<name>]` table key, a `--profile`
/// argument and a stored registration, so the same word means the same thing
/// in the configuration file, on the wire and in the catalogue.
///
/// ## Examples
///
/// ```gleam
/// assert catalogue.is_profile_name("deepseek")
/// assert catalogue.is_profile_name("glm-5_3")
/// assert !catalogue.is_profile_name("")
/// assert !catalogue.is_profile_name("9lives")
/// assert !catalogue.is_profile_name("Deep Seek")
/// ```
pub fn is_profile_name(text: String) -> Bool {
  case string.to_graphemes(text) {
    [first, ..rest] ->
      string.length(text) <= profile_name_limit
      && is_letter(first)
      && list.all(rest, fn(grapheme) {
        is_letter(grapheme)
        || grapheme == "_"
        || grapheme == "-"
        || list.contains(string.to_graphemes("0123456789"), grapheme)
      })
    [] -> False
  }
}

fn is_letter(grapheme: String) -> Bool {
  list.contains(string.to_graphemes("abcdefghijklmnopqrstuvwxyz"), grapheme)
}

// The column's default, the empty string, means no profile. Any other text is
// kept as it was stored and judged by `validate`, so a value that is not a
// profile name fails the read with `Invalid` instead of reading as no profile:
// a session that was created under a profile must not quietly open under the
// default roles because its row was damaged.
fn stored_profile(text: String) -> Option(String) {
  case text {
    "" -> None
    name -> Some(name)
  }
}

fn number(connection: sqlight.Connection, sql: String) -> Result(Int, Error) {
  use values <- result.try(
    sqlight.query(
      sql,
      on: connection,
      with: [],
      expecting: decode.at([0], decode.int),
    )
    |> result.map_error(sql_error),
  )
  case values {
    [value] -> Ok(value)
    [] | [_, _, ..] -> Error(Invalid("expected one catalogue metadata row"))
  }
}

fn transaction(
  connection: sqlight.Connection,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  transact(connection, Write, run)
}

// Generated query cardinality is not transaction intent: writes may return rows.
// Read-only compound reads take a coherent snapshot without reserving the writer.
type Intent {
  Read
  Write
}

fn snapshot(
  connection: sqlight.Connection,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  transact(connection, Read, run)
}

fn transact(
  connection: sqlight.Connection,
  intent: Intent,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  let begin = case intent {
    Read -> "BEGIN DEFERRED"
    Write -> "BEGIN IMMEDIATE"
  }
  use Nil <- result.try(execute(connection, begin))
  let outcome =
    run()
    |> result.try(fn(value) {
      execute(connection, "COMMIT") |> result.replace(value)
    })
  case outcome {
    Ok(value) -> Ok(value)
    Error(error) -> {
      let _rolled_back = execute(connection, "ROLLBACK")
      Error(error)
    }
  }
}

/// Groups internal catalogue changes in one immediate transaction.
///
/// The seam exists because several metadata changes are only meaningful whole:
/// a registration with its domain mapping, an invitation with its credential
/// and first membership. Inside a body, use the in-transaction pieces —
/// `reserve_in_transaction`, `query` and `statement` — never another
/// transactional function from this module.
///
/// Callers must not nest this inside another catalogue transaction, `coherent`
/// included. SQLite has no nested transactions: the inner `BEGIN` fails, and the
/// `ROLLBACK` the inner call then issues aborts the *outer* transaction, so
/// writes the caller believes are staged are discarded and the failure is
/// reported as an unrelated database error. Every call site is checked by hand
/// today; making the nesting unrepresentable means passing the body an opaque
/// in-transaction token, which changes this function's shape and every caller's.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.atomic(store, fn() { rotate_credential_rows(store) })
/// ```
@internal
pub fn atomic(
  catalogue: Catalogue,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  transaction(catalogue.connection, run)
}

/// Groups internal catalogue reads in one deferred transaction.
///
/// This is `atomic`'s read-intent sibling: a compound read answers from one
/// coherent snapshot without reserving the writer. It carries the same
/// no-nesting rule, and for the same reason. Reads that already wrap themselves
/// — `page`, `member_page`, `workspace_default` — must not be called inside it.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.coherent(store, fn() { principal_and_membership(store) })
/// ```
@internal
pub fn coherent(
  catalogue: Catalogue,
  run: fn() -> Result(a, Error),
) -> Result(a, Error) {
  snapshot(catalogue.connection, run)
}

fn execute(connection: sqlight.Connection, sql: String) -> Result(Nil, Error) {
  sqlight.exec(sql, on: connection) |> result.map_error(sql_error)
}

fn sql_error(error: sqlight.Error) -> Error {
  Database(string.inspect(error))
}
