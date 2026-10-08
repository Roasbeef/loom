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
//// `open` → `reserve` → `confirm` → `get` → `rename` → `seed_subtitle` →
//// `seed_executor` → `page`
////
//// 1. `open` configures one connection and `initialize_schema` creates the
////    tables or applies the migrations a version lacks, in one transaction.
//// 2. `reserve` records a creation's identity and path before its file exists,
////    and `confirm` marks the file verified.
//// 3. `get` and `page` read the creation record with its display layers (the
////    name override and the subtitle), and neither opens a conversation file.
//// 4. `rename` writes the display-name override after `display_name` accepts it.
//// 5. `seed_subtitle` reduces a first prompt with `subtitle_from_prompt` and
////    writes the result once.
//// 6. `seed_executor` records the executor a pooled session's first attach
////    chose, once.
//// 7. `delete` removes a registration and every row that refers to it.
//// 8. `remember_folder`, `recent_folders` and `forget_folder` keep the short list
////    of folders the owner recently started a session in, which belongs to no
////    session and so outlives every one.
//// 9. `custody` reads who serves a session, and `begin_move`, `finish_move`,
////    `abort_move` and `import_session` are the compare-and-set transitions of
////    a session moving between orchestrators.

import core/ids
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
import storage/catalogue_executors_schema
import storage/catalogue_logins_schema
import storage/catalogue_moves_schema
import storage/catalogue_names_schema
import storage/catalogue_pools_schema
import storage/catalogue_profiles_schema
import storage/catalogue_recent_folders_schema
import storage/catalogue_subtitles_schema
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
    /// The host-validated canonical working directory of a local session. For
    /// a session whose `executor` is set it is instead the name of a workspace
    /// registered on that executor, which is never a path on this host and is
    /// never canonicalized, statted or created here (protocol-change/078).
    workspace: String,
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
    /// The executor the session's workspace is registered on, by its
    /// `[executors.<name>]` key, or the empty string for a session whose
    /// workspace is a path on this host. For a session created with an
    /// executor it is part of the immutable creation request, so a retry
    /// compares it. For a session created in a pool it is empty until the
    /// first successful attach chooses one (`seed_executor`), and a retry then
    /// compares the pool and not the executor (protocol-change/078).
    executor: String,
    /// The `[pools.<name>]` the session was created in, or the empty string
    /// for a session that named none. A pooled session's workspace is a
    /// registered name, as an executor session's is, and the pool is part of
    /// the immutable creation request.
    pool: String,
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

  /// A unique key conflicts, a default selects another workspace's session, or
  /// a move transition is not allowed from the session's custody (another
  /// operation owns it, or it has already moved).
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
        use Nil <- result.try(migrations_after(connection, version))
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
pub const current_version = 12

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
    #(10, catalogue_executors_schema.schema),
    #(11, catalogue_pools_schema.schema),
    #(12, catalogue_moves_schema.schema),
  ]
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
      case requested(old) == requested(record) {
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

// The part of a registration a creation request fixes. The state moves as the
// file is confirmed, and a pooled session's executor is chosen by its first
// attach and not named by the request, so neither is compared.
fn requested(record: Registration) -> Registration {
  case record.pool {
    "" -> Registration(..record, state: Reserved)
    _ -> Registration(..record, state: Reserved, executor: "")
  }
}

fn insert(
  catalogue: Catalogue,
  record: Registration,
) -> Result(Registration, Error) {
  use Nil <- result.try(statement(
    catalogue,
    sql.insert_registration(
      session_id: record.id,
      path: record.path,
      workspace: record.workspace,
      name: record.name,
      configuration: record.configuration,
      created_at: record.created_at,
      request_key: record.request_key,
      profile: option.unwrap(record.profile, ""),
      executor: record.executor,
      pool: record.pool,
    ),
  ))
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

/// Records the executor a pooled session's first attach chose, once.
///
/// A session created in a `[pools.<name>]` has no executor when it is
/// reserved, because the pool picks one when the session first opens. The pick
/// is recorded in the session's own store before the attach (the scope record),
/// and this writes it into the catalogue so that a listing shows it without
/// opening the store. It changes only a registration that has a pool and no
/// executor: a session that named an executor, a session with no pool and a
/// pooled session whose executor is already recorded are returned as they
/// stand, so a repeated or late call cannot move a session. The executor and
/// the catalogue revision commit together.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.seed_executor(store, session_id, "build-box")
/// ```
pub fn seed_executor(
  catalogue: Catalogue,
  id: String,
  executor: String,
) -> Result(Registration, Error) {
  case is_executor_name(executor) {
    False -> Error(Invalid("executor is not an executor name"))
    True ->
      transaction(catalogue.connection, fn() {
        use record <- result.try(get(catalogue, id))
        case record.pool == "" || record.executor != "" {
          True -> Ok(record)
          False -> {
            use Nil <- result.try(statement(
              catalogue,
              sql.seed_registration_executor(executor, id),
            ))
            use Nil <- result.try(statement(
              catalogue,
              sql.increment_catalogue_revision(),
            ))
            Ok(Registration(..record, executor:))
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
  workspace: String,
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
    case record.workspace == workspace {
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
/// A session registered on an executor or in a pool is refused with
/// `Conflict`.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.set_workspace_default(catalogue, workspace, session_id)
/// ```
pub fn set_workspace_default(
  catalogue: Catalogue,
  workspace: String,
  id: String,
) -> Result(Registration, Error) {
  transaction(catalogue.connection, fn() {
    use record <- result.try(get(catalogue, id))
    use state <- result.try(archive_state(catalogue, id))
    use Nil <- result.try(case state {
      Active -> Ok(Nil)
      Archived -> Error(Conflict)
    })

    // A registered workspace name is only unique within its executor, and a
    // default is keyed by the name alone, so a registered session has none.
    use Nil <- result.try(
      case
        record.workspace == workspace
        && record.executor == ""
        && record.pool == ""
      {
        True -> Ok(Nil)
        False -> Error(Conflict)
      },
    )
    case default_identity(catalogue, workspace) {
      Ok(current) if current == id -> Ok(record)
      Ok(_) | Error(Missing) -> {
        use Nil <- result.try(statement(
          catalogue,
          sql.set_workspace_default(workspace, id),
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

/// Who serves a session. It is independent of `State` (whether the file was
/// verified) and of `Visibility` (whether the owner hid the session): a
/// session can be active and moving, or archived and imported. The state is a
/// row in `catalogue_session_moves`, and no row means `Resident`.
///
/// The transitions are compare-and-set on the row, in one immediate
/// transaction each, keyed by the move's `op`. On the side that gives a
/// session up they run `Resident -> Moving -> Moved`, with `Moving ->
/// Resident` for an early abort. On the side that receives it, `Resident ->
/// Imported`. `Moved` has no outgoing transition, so a stale mover or a late
/// message can never bring a session back to a catalogue that handed it over.
pub type Custody {
  /// No move row: this catalogue serves the session and has never moved it.
  Resident

  /// This catalogue is handing the session to the orchestrator `to`, under the
  /// move `op`. The slot is stopped and the session is not admitted until the
  /// move finishes or aborts.
  Moving(op: String, to: String)

  /// This catalogue handed the session to `to`. It is a tombstone: `open`,
  /// `restore` and `delete` answer with the new owner and never run here.
  Moved(op: String, to: String)

  /// The orchestrator `from` handed the session to this catalogue under the
  /// move `op`.
  Imported(op: String, from: String)
}

/// The longest move operation identifier, in bytes. A UUID is 36.
pub const move_op_limit = 64

/// Whether text can identify a move: one to `move_op_limit` bytes drawn from
/// ASCII letters, digits, `-` and `_`. The identifier is minted by the source
/// and travels in file names and messages, so it can hold no separator, space
/// or control.
///
/// ## Examples
///
/// ```gleam
/// assert catalogue.is_move_op("0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9e")
/// assert !catalogue.is_move_op("")
/// assert !catalogue.is_move_op("a b")
/// assert !catalogue.is_move_op("../b")
/// ```
pub fn is_move_op(text: String) -> Bool {
  let size = string.byte_size(text)
  size >= 1
  && size <= move_op_limit
  && list.all(string.to_utf_codepoints(text), fn(codepoint) {
    let code = string.utf_codepoint_to_int(codepoint)
    { code >= 0x30 && code <= 0x39 }
    || { code >= 0x41 && code <= 0x5a }
    || { code >= 0x61 && code <= 0x7a }
    || code == 0x2d
    || code == 0x5f
  })
}

/// Whether text is an orchestrator name: the key of an `[orchestrators.<name>]`
/// table in the configuration. It has the grammar of an executor name, so a
/// peer is named alike in the configuration and in a stored move.
///
/// ## Examples
///
/// ```gleam
/// assert catalogue.is_orchestrator_name("laptop")
/// assert !catalogue.is_orchestrator_name("Laptop")
/// ```
pub fn is_orchestrator_name(text: String) -> Bool {
  is_profile_name(text)
}

/// Reads who serves a session, without opening its conversation file.
///
/// A stored row that does not decode (a state that is not one of the three, an
/// op or a peer outside its grammar) fails the read with `Invalid`. It is never
/// read as `Resident`, because that would let a damaged tombstone open a session
/// the catalogue handed to another orchestrator.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.custody(store, session_id) == Ok(catalogue.Resident)
/// ```
pub fn custody(catalogue: Catalogue, id: String) -> Result(Custody, Error) {
  use _record <- result.try(get(catalogue, id))
  stored_custody(catalogue, id)
}

fn stored_custody(catalogue: Catalogue, id: String) -> Result(Custody, Error) {
  use rows <- result.try(query(catalogue, sql.session_move(id)))
  case rows {
    [] -> Ok(Resident)
    [row] -> decode_custody(row.op, row.peer, row.state)
    [_, _, ..] -> Error(Invalid("duplicate move metadata"))
  }
}

fn decode_custody(
  op: String,
  peer: String,
  state: String,
) -> Result(Custody, Error) {
  case is_move_op(op) && is_orchestrator_name(peer) {
    False -> Error(Invalid("invalid move metadata"))
    True ->
      case state {
        "moving" -> Ok(Moving(op:, to: peer))
        "moved" -> Ok(Moved(op:, to: peer))
        "imported" -> Ok(Imported(op:, from: peer))
        _ -> Error(Invalid("unknown move state"))
      }
  }
}

// A move names a well-formed operation and peer before any row is read, so a
// malformed request is refused the same way whatever the stored custody is.
fn validate_move(op: String, peer: String) -> Result(Nil, Error) {
  case is_move_op(op) && is_orchestrator_name(peer) {
    True -> Ok(Nil)
    False -> Error(Invalid("invalid move operation or peer"))
  }
}

/// Records the intent to hand a session to the orchestrator `to`, under the
/// move `op`: `Resident -> Moving`.
///
/// This is the write-ahead step of a move. The caller commits it in the same
/// turn that stops the session's slot, before any file is cut or any message is
/// sent, so a crash leaves a `Moving` row that a restart resumes and never a
/// copy with no record of why it exists. A repeat of the same op and peer
/// answers the stored custody (`Moving`, or `Moved` once it finished). A
/// session that another op is moving, one that has moved, and one that was
/// imported here are `Conflict`. A malformed op or peer is `Invalid`.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.begin_move(store, session_id, op: "0192f3c1", to: "laptop")
/// // == Ok(catalogue.Moving(op: "0192f3c1", to: "laptop"))
/// ```
pub fn begin_move(
  catalogue: Catalogue,
  id: String,
  op op: String,
  to to: String,
) -> Result(Custody, Error) {
  use Nil <- result.try(validate_move(op, to))
  transaction(catalogue.connection, fn() {
    use current <- result.try(custody(catalogue, id))
    case current {
      Resident -> {
        use Nil <- result.try(insert_move(catalogue, id, op, to, "moving"))
        Ok(Moving(op:, to:))
      }
      Moving(op: held, to: peer)
        | Moved(op: held, to: peer)
        if held == op && peer == to
      -> Ok(current)
      Moving(..) | Moved(..) | Imported(..) -> Error(Conflict)
    }
  })
}

/// Completes a move on the side that gave the session up:
/// `Moving -> Moved`.
///
/// The caller does this only after the receiving orchestrator has confirmed it
/// activated the session. `Moved` has no outgoing transition. A repeat of the
/// same op answers the stored `Moved`. Any other op, a session that is not
/// moving, and one that was imported here are `Conflict`.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.finish_move(store, session_id, op: "0192f3c1")
/// // == Ok(catalogue.Moved(op: "0192f3c1", to: "laptop"))
/// ```
pub fn finish_move(
  catalogue: Catalogue,
  id: String,
  op op: String,
) -> Result(Custody, Error) {
  transaction(catalogue.connection, fn() {
    use current <- result.try(custody(catalogue, id))
    case current {
      Moving(op: held, to: peer) if held == op -> {
        use Nil <- result.try(statement(
          catalogue,
          sql.finish_session_move(id, op),
        ))
        use Nil <- result.try(statement(
          catalogue,
          sql.increment_catalogue_revision(),
        ))
        Ok(Moved(op:, to: peer))
      }
      Moved(op: held, ..) if held == op -> Ok(current)
      Resident | Moving(..) | Moved(..) | Imported(..) -> Error(Conflict)
    }
  })
}

/// Abandons a move before anything reached the receiver: `Moving -> Resident`.
///
/// This is the only way back, and the caller uses it only while nothing exists
/// on the receiving side. Once a copy has been sent the caller abandons only on
/// the receiver's definite refusal, never because it is unreachable. A repeat on
/// a session that is already resident answers `Resident`. A session moving under
/// another op, one that has moved, and one that was imported here are
/// `Conflict`, so an abort that arrives after the move finished cannot undo it.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.abort_move(store, session_id, op: "0192f3c1")
/// // == Ok(catalogue.Resident)
/// ```
pub fn abort_move(
  catalogue: Catalogue,
  id: String,
  op op: String,
) -> Result(Custody, Error) {
  transaction(catalogue.connection, fn() {
    use current <- result.try(custody(catalogue, id))
    case current {
      Resident -> Ok(Resident)
      Moving(op: held, ..) if held == op -> {
        use Nil <- result.try(statement(
          catalogue,
          sql.abort_session_move(id, op),
        ))
        use Nil <- result.try(statement(
          catalogue,
          sql.increment_catalogue_revision(),
        ))
        Ok(Resident)
      }
      Moving(..) | Moved(..) | Imported(..) -> Error(Conflict)
    }
  })
}

/// Records that the orchestrator `from` handed this catalogue a session under
/// the move `op`: `Resident -> Imported`.
///
/// The session's registration must already exist (`reserve`), as a move imports
/// the conversation file beside it. A repeat of the same op and source answers
/// the stored `Imported`, which is what lets the receiver answer a lost
/// activation reply a second time. A session that is moving or has moved, or one
/// imported under another op or from another source, is `Conflict`.
///
/// ## Examples
///
/// ```gleam
/// // catalogue.import_session(store, session_id, op: "0192f3c1", from: "desk")
/// // == Ok(catalogue.Imported(op: "0192f3c1", from: "desk"))
/// ```
pub fn import_session(
  catalogue: Catalogue,
  id: String,
  op op: String,
  from from: String,
) -> Result(Custody, Error) {
  use Nil <- result.try(validate_move(op, from))
  transaction(catalogue.connection, fn() {
    use current <- result.try(custody(catalogue, id))
    case current {
      Resident -> {
        use Nil <- result.try(insert_move(catalogue, id, op, from, "imported"))
        Ok(Imported(op:, from:))
      }
      Imported(op: held, from: source) if held == op && source == from ->
        Ok(current)
      Imported(..) | Moving(..) | Moved(..) -> Error(Conflict)
    }
  })
}

fn insert_move(
  catalogue: Catalogue,
  id: String,
  op: String,
  peer: String,
  state: String,
) -> Result(Nil, Error) {
  use Nil <- result.try(statement(
    catalogue,
    sql.insert_session_move(id, op, peer, state),
  ))
  statement(catalogue, sql.increment_catalogue_revision())
}

/// Removes one registration and every catalogue row that refers to it.
///
/// The registration, its memberships, its display name and subtitle, a workspace default
/// naming it, its domain mapping and the provenance of an import are removed in one immediate transaction, so no reader can
/// observe a catalogue whose foreign keys point at a session that is half
/// gone. The domain record itself survives: a domain owns distilled memory
/// for a workspace and outlives any one conversation that fed it.
///
/// A session that is moving or has moved is `Conflict`: its move row is the only
/// record of who owns it.
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

    // A session in the middle of a move, or one that already moved, is not
    // this catalogue's to delete: the row is the only record of who owns it,
    // and the move's tombstone has no way out. An imported session's row is
    // only provenance, so it leaves with the session.
    use current <- result.try(stored_custody(catalogue, id))
    use Nil <- result.try(case current {
      Moving(..) | Moved(..) -> Error(Conflict)
      Imported(..) -> statement(catalogue, sql.delete_session_move(id))
      Resident -> Ok(Nil)
    })

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
  workspace: String,
) -> Result(String, Error) {
  use rows <- result.try(query(catalogue, sql.workspace_default(workspace)))
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
        decoded(
          Registration(
            id: row.session_id,
            path: row.path,
            workspace: row.workspace,
            name: row.name,
            configuration: row.configuration,
            created_at: row.created_at,
            request_key: row.request_key,
            state: Reserved,
            profile: stored_profile(row.profile),
            executor: row.executor,
            pool: row.pool,
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
        decoded(
          Registration(
            id: row.session_id,
            path: row.path,
            workspace: row.workspace,
            name: row.name,
            configuration: row.configuration,
            created_at: row.created_at,
            request_key: row.request_key,
            state: Reserved,
            profile: stored_profile(row.profile),
            executor: row.executor,
            pool: row.pool,
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
    decoded(
      Registration(
        id: row.session_id,
        path: row.path,
        workspace: row.workspace,
        name: row.name,
        configuration: row.configuration,
        created_at: row.created_at,
        request_key: row.request_key,
        state: Reserved,
        profile: stored_profile(row.profile),
        executor: row.executor,
        pool: row.pool,
        subtitle: None,
      ),
      row.state,
    )
  })
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
  use _id <- result.try(
    ids.parse_session_id(record.id)
    |> result.replace_error(Invalid("invalid canonical session ID")),
  )

  // A local workspace is an absolute path and a registered one is a name, and
  // the two grammars cannot overlap because a name has no `/`. That is what
  // lets every later reader tell them apart from the text alone.
  let placed = case record.executor, record.pool {
    "", "" -> string.starts_with(record.workspace, "/")
    executor, "" ->
      is_executor_name(executor) && is_workspace_name(record.workspace)
    "", pool -> is_pool_name(pool) && is_workspace_name(record.workspace)
    executor, pool ->
      is_executor_name(executor)
      && is_pool_name(pool)
      && is_workspace_name(record.workspace)
  }
  case
    string.starts_with(record.path, "/")
    && placed
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
        "registration needs an absolute database path, a workspace path or an executor's workspace name, a request key and a nonnegative creation time",
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

/// Whether text is an executor name: the key of an `[executors.<name>]` table
/// in the orchestrator's configuration. It has the grammar of a profile name,
/// so a configuration key means the same thing on the wire and in a stored
/// registration (protocol-change/078).
///
/// ## Examples
///
/// ```gleam
/// assert catalogue.is_executor_name("build-box")
/// assert !catalogue.is_executor_name("Build Box")
/// ```
pub fn is_executor_name(text: String) -> Bool {
  is_profile_name(text)
}

/// Whether text is a pool name: the key of a `[pools.<name>]` table in the
/// orchestrator's configuration. It has the grammar of an executor name, so a
/// pool and an executor are named alike on the wire and in a stored
/// registration (protocol-change/078).
///
/// ## Examples
///
/// ```gleam
/// assert catalogue.is_pool_name("linux-builders")
/// assert !catalogue.is_pool_name("Linux Builders")
/// ```
pub fn is_pool_name(text: String) -> Bool {
  is_profile_name(text)
}

/// The longest registered workspace name, in bytes.
pub const workspace_name_limit = 128

/// Whether text is the name of a workspace registered on an executor: one to
/// `workspace_name_limit` bytes with no `/` and no NUL. The executor validates
/// the name against its own `[workspaces.<name>]` table when a scope attaches;
/// the orchestrator only needs a string that cannot be mistaken for, or joined
/// into, a path on its own disk. A name has no `/`, so it can never be an
/// absolute path, which is how a stored workspace tells the two apart.
///
/// ## Examples
///
/// ```gleam
/// assert catalogue.is_workspace_name("loom")
/// assert !catalogue.is_workspace_name("")
/// assert !catalogue.is_workspace_name("/work/loom")
/// assert !catalogue.is_workspace_name("a/b")
/// ```
pub fn is_workspace_name(text: String) -> Bool {
  text != ""
  && string.byte_size(text) <= workspace_name_limit
  && !string.contains(text, "/")
  && !string.contains(text, "\u{0}")
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
