//// A node's store of captured repository states, addressed by hash
//// (protocol-change/107, "What it costs").
////
//// Capture leaves a bundle in a private stage that its caller must delete once
//// native custody has drained. A state that has to outlive the stage, because a
//// peer has not fetched it yet or a receiver has not applied it, moves here.
//// The store is a directory, `<state root>/states`, holding two files for each
//// state: `<hash>.bundle`, the bytes, and `<hash>.json`, the description that
//// `state_object.encode` writes. The record is written last, so a state exists
//// exactly when its record does.
////
//// The store is the only bound on the disk this feature uses.
//// `repository_snapshot` checks free space before a capture, which is an
//// observation and not a reservation, so every admission is checked against the
//// store's own limits instead: one bundle may not exceed `size_limit`, and the
//// bytes of everything in the directory, orphans and half-written files
//// included, may not exceed `total_cap`. A bundle that does not fit is refused
//// with a reason. Nothing is evicted to make room, because an entry that has
//// not expired may be the one a peer is fetching. Entries older than `retain_s`
//// are removed by `sweep`, which every admission runs first.
////
//// ## What may be relied on
////
//// A write is a temporary file renamed into place, so a reader sees a whole
//// file or none. A rename is not a flush to disk, so after a crash a file may
//// be short, and every `get` therefore reads the whole bundle and compares its
//// size and SHA-256 with the record before returning its path. A damaged entry
//// is an error, and a `put` of the same bytes replaces it. The store has no
//// lock. One process owns a directory and serializes its calls, as the other
//// stores under the state root are owned by one actor each.
////
//// ## Flow
////
//// `open` → `put` → `get` → `sweep`
////
//// 1. `open` creates the private directory and refuses limits that cannot hold
////    one bundle.
//// 2. `put` hashes a bundle, returns the existing entry when the same bytes are
////    held, and otherwise sweeps, checks the cap, and writes the bundle and then
////    the record with `write_atomic`.
//// 3. `get` answers the entry's path only after it has verified the stored
////    bytes against the record.
//// 4. `sweep` removes records and their bundles past the retention, and any
////    stray file past it, using the file's modification time.

import client/internal/ffi_os
import client/state_object.{type Dirtiness, type State}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import host/bootstrap
import simplifile

/// What a store admits and how long it keeps it.
pub type Limits {
  Limits(
    /// The largest bundle, in bytes.
    size_limit: Int,
    /// The most bytes the directory may hold in all, every file counted.
    total_cap: Int,
    /// How long an entry is kept, in seconds from the time it was written.
    retain_s: Int,
  )
}

/// The limits a node uses unless it sets its own: the protocol's 256 MiB for one
/// bundle, four of them for the directory, and the seven days that a delegate
/// session is kept (`[spawners]` `retain_s`), so a state a child's result names
/// outlives the session that names it.
pub const default_limits =
  Limits(size_limit: 268_435_456, total_cap: 1_073_741_824, retain_s: 604_800)

/// An open store. It is the directory and the limits it was opened with.
pub opaque type Store {
  Store(directory: String, limits: Limits)
}

/// A state the store holds and has verified.
pub type Held {
  Held(
    /// The description recorded when the state was admitted.
    state: State,
    /// The bundle file. It was whole when `get` returned, and a caller that
    /// reads it later reads it through the sandbox and verifies it again.
    path: String,
  )
}

/// The directory a node keeps its states in: `<state root>/states`.
///
/// ## Examples
///
/// ```gleam
/// assert state_store.directory("/s") == "/s/states"
/// ```
pub fn directory(state_root: String) -> String {
  state_root <> "/states"
}

/// Opens the store at a directory, creating it private. The limits must allow
/// at least one bundle of `size_limit` bytes and keep entries for a positive
/// time.
///
/// ## Examples
///
/// ```gleam
/// // state_store.open(state_store.directory(state_root), state_store.default_limits)
/// ```
pub fn open(directory: String, limits: Limits) -> Result(Store, String) {
  use <- bool.guard(
    when: limits.size_limit < 1
      || limits.total_cap < limits.size_limit
      || limits.retain_s < 1,
    return: Error("the state store limits cannot hold a bundle"),
  )
  use Nil <- result.try(bootstrap.ensure_private_directory(directory))
  Ok(Store(directory:, limits:))
}

/// Admits a bundle file and answers the state that names it.
///
/// The bundle is read once, bounded by `size_limit`, and its hash becomes its
/// name. Bytes that are already held, whole, are not written again and the
/// existing record is answered, which is what lets a sender skip a state the
/// receiver finished. Otherwise expired entries are swept, the cap is checked
/// against what remains, and the bundle and then the record are written. A bundle
/// over `size_limit` or one that does not fit under `total_cap` is an `Error`
/// that says so, and nothing is written. `now_s` is the time in Unix seconds and
/// is only used to decide which entries have expired.
///
/// `tip`, `base` and `dirty` come from the capture that made the bundle. The
/// store does not read the bundle to learn them; a receiver compares them with
/// the bundle's header in `state_object.verify_bundle` before it applies.
///
/// ## Examples
///
/// ```gleam
/// // state_store.put(store, snapshot.bundle, tip: snapshot.commit, base: snapshot.base, dirty: snapshot.dirty, now_s: now)
/// ```
pub fn put(
  store: Store,
  bundle: String,
  tip tip: String,
  base base: Option(String),
  dirty dirty: Dirtiness,
  now_s now_s: Int,
) -> Result(State, String) {
  use bytes <- result.try(read_bundle(store, bundle))
  use state <- result.try(
    state_object.validate(state_object.State(
      hash: state_object.hash_of(bytes),
      size: bit_array.byte_size(bytes),
      tip:,
      base:,
      dirty:,
    )),
  )

  // Bytes already held and whole are answered from the existing record.
  case get(store, state.hash) {
    Ok(Some(held)) -> Ok(held.state)
    Ok(None) | Error(_) -> admit(store, bytes, state, now_s)
  }
}

/// Writes a new entry once the sweep has made room, or refuses it.
///
/// A damaged entry of the same hash is not an obstacle: its files are replaced
/// by the renames below.
fn admit(
  store: Store,
  bytes: BitArray,
  state: State,
  now_s: Int,
) -> Result(State, String) {
  let limits = store.limits
  use _removed <- result.try(sweep(store, now_s))
  use held <- result.try(usage(store))

  // The cap counts every file in the directory, so strays cannot widen it.
  use <- bool.lazy_guard(
    when: held + state.size > limits.total_cap,
    return: fn() {
      Error(
        "the state store holds "
        <> int.to_string(held)
        <> " of its "
        <> int.to_string(limits.total_cap)
        <> " byte cap, so a bundle of "
        <> int.to_string(state.size)
        <> " bytes does not fit",
      )
    },
  )

  // The record is the commit point. A crash before it leaves a bundle that no
  // record names, which `sweep` removes when it expires.
  use Nil <- result.try(write_atomic(bundle_path(store, state.hash), bytes))
  use Nil <- result.map(write_atomic(
    record_path(store, state.hash),
    bit_array.from_string(state_object.encode(state)),
  ))
  state
}

/// Looks a state up by hash and verifies it.
///
/// `Ok(None)` means no record exists. An `Error` means the hash is not a hash,
/// or a record exists and its bundle is missing, is not the recorded size or
/// does not hash to the recorded value. The whole bundle is read to decide, so
/// a caller pays for the check at each lookup and never trusts a file that a
/// crash or another writer changed.
///
/// ## Examples
///
/// ```gleam
/// assert state_store.get(store, "../x") == Error("not a state hash")
/// ```
pub fn get(store: Store, hash: String) -> Result(Option(Held), String) {
  use <- bool.guard(
    when: !state_object.is_hash(hash),
    return: Error("not a state hash"),
  )

  // No record is an absence. A record is a claim the bundle must bear out.
  case simplifile.read(record_path(store, hash)) {
    Error(simplifile.Enoent) -> Ok(None)
    Error(error) ->
      Error(
        "the state record cannot be read: " <> simplifile.describe_error(error),
      )
    Ok(text) -> result.map(verified(store, hash, text), Some)
  }
}

/// Checks a record against the bundle it names: the record must decode, name
/// this hash, and have a bundle of the recorded size that hashes to it.
fn verified(store: Store, hash: String, text: String) -> Result(Held, String) {
  use state <- result.try(state_object.decode(text))
  use <- bool.guard(
    when: state.hash != hash,
    return: Error("the state record names another hash"),
  )
  let path = bundle_path(store, hash)
  use bytes <- result.try(
    bootstrap.read_bounded(path, store.limits.size_limit)
    |> result.map_error(fn(reason) {
      "the stored bundle cannot be read: " <> reason
    }),
  )

  // A crash can leave a renamed file short, so size and hash are both read.
  use <- bool.guard(
    when: state_object.hash_of(bytes) != hash
      || bit_array.byte_size(bytes) != state.size,
    return: Error("the stored bundle does not match its hash or its size"),
  )
  Ok(Held(state:, path:))
}

/// Removes what has outlived the retention and answers how many entries went.
/// A state counts once, for its record and its bundle together, and a stray file
/// counts once.
///
/// A record decides for its bundle: both go together, the record first, so a
/// crash between them leaves an orphan bundle and never a record without bytes.
/// A bundle with no record, a temporary file and any other file are judged by
/// their own modification times, which keeps a write in progress and removes
/// what a crashed one left.
///
/// ## Examples
///
/// ```gleam
/// // state_store.sweep(store, now_s)
/// ```
pub fn sweep(store: Store, now_s: Int) -> Result(Int, String) {
  use files <- result.try(files_of(store))
  let retain_s = store.limits.retain_s

  list.try_fold(plan_sweep(files, now_s, retain_s), 0, fn(removed, names) {
    use Nil <- result.map(list.try_each(names, remove(store, _)))
    removed + 1
  })
}

/// Decides what a sweep removes, as one list of file names for each entry, in
/// the order they are to go. It reads no file, so the rule is the same on a
/// directory of any size and is tested with names and times alone.
fn plan_sweep(
  files: List(File),
  now_s: Int,
  retain_s: Int,
) -> List(List(String)) {
  let recorded =
    list.filter_map(files, fn(file) {
      case kind_of(file.name) {
        Record(hash) -> Ok(hash)
        Bundle(_) | Other -> Error(Nil)
      }
    })
    |> set.from_list

  list.filter_map(files, fn(file) {
    use <- bool.guard(
      when: !expired(file.modified_s, now_s, retain_s),
      return: Error(Nil),
    )

    // A record's age decides for its bundle, which goes after it. A bundle
    // that has a record is left to that record, and one without is an orphan
    // judged by its own age, like a temporary or a foreign file.
    case kind_of(file.name) {
      Record(hash) -> Ok([file.name, hash <> ".bundle"])
      Bundle(hash) ->
        case set.contains(recorded, hash) {
          True -> Error(Nil)
          False -> Ok([file.name])
        }
      Other -> Ok([file.name])
    }
  })
}

/// Whether an entry written at `modified_s` is past retention at `now_s`. An
/// entry exactly `retain_s` old is kept.
///
/// ## Examples
///
/// ```gleam
/// assert !state_store.expired(100, 160, 60)
/// assert state_store.expired(100, 161, 60)
/// ```
pub fn expired(modified_s: Int, now_s: Int, retain_s: Int) -> Bool {
  now_s - modified_s > retain_s
}

/// The bytes of every file in the directory, which is what the cap limits.
///
/// ## Examples
///
/// ```gleam
/// // state_store.usage(store)
/// ```
pub fn usage(store: Store) -> Result(Int, String) {
  use files <- result.map(files_of(store))
  list.fold(files, 0, fn(total, file) { total + file.size })
}

// --- files ----------------------------------------------------------------------

/// A regular file in the store's directory.
type File {
  File(name: String, size: Int, modified_s: Int)
}

/// What a file's name says it is.
type Kind {
  /// `<hash>.json`, the description of a state.
  Record(hash: String)

  /// `<hash>.bundle`, a state's bytes.
  Bundle(hash: String)

  /// Anything else: a temporary file, or a file that is not the store's.
  Other
}

/// Classifies a file name. Only a well-formed hash makes a name a record or a
/// bundle, so a name never reaches a path through a peer's text.
fn kind_of(name: String) -> Kind {
  case string.ends_with(name, ".json"), string.ends_with(name, ".bundle") {
    True, _ -> hashed(string.drop_end(name, 5), Record)
    _, True -> hashed(string.drop_end(name, 7), Bundle)
    False, False -> Other
  }
}

/// Wraps a name's stem in a kind when it is a hash, and as `Other` when not.
fn hashed(stem: String, kind: fn(String) -> Kind) -> Kind {
  case state_object.is_hash(stem) {
    True -> kind(stem)
    False -> Other
  }
}

/// Lists the regular files of the directory with their sizes and times.
/// Anything else in it, a subdirectory or a link, is not counted and not
/// touched: the store only ever creates regular files.
fn files_of(store: Store) -> Result(List(File), String) {
  use names <- result.try(
    simplifile.read_directory(store.directory)
    |> result.map_error(fn(error) {
      "the state store cannot be listed: " <> simplifile.describe_error(error)
    }),
  )

  list.try_map(names, fn(name) {
    simplifile.link_info(store.directory <> "/" <> name)
    |> result.map_error(fn(error) {
      "the state store entry cannot be read: "
      <> simplifile.describe_error(error)
    })
    |> result.map(file_of(name, _))
  })
  |> result.map(list.filter_map(_, fn(entry) { entry }))
}

/// A regular file's name, size and modification time. Anything else answers
/// `Error(Nil)` so that it is neither counted nor touched.
fn file_of(name: String, info: simplifile.FileInfo) -> Result(File, Nil) {
  case simplifile.file_info_type(info) {
    simplifile.File ->
      Ok(File(name:, size: info.size, modified_s: info.mtime_seconds))
    simplifile.Directory | simplifile.Symlink | simplifile.Other -> Error(Nil)
  }
}

/// Reads a bundle the caller offered, refusing one over the size limit before
/// it is read and again if it grows while being read.
fn read_bundle(store: Store, path: String) -> Result(BitArray, String) {
  let limit = store.limits.size_limit
  use info <- result.try(
    simplifile.file_info(path)
    |> result.map_error(fn(error) {
      "the bundle cannot be inspected: " <> simplifile.describe_error(error)
    }),
  )
  use <- bool.lazy_guard(when: info.size > limit, return: fn() {
    Error(
      "the bundle is "
      <> int.to_string(info.size)
      <> " bytes, over the state size limit of "
      <> int.to_string(limit),
    )
  })

  bootstrap.read_bounded(path, limit)
  |> result.map_error(fn(reason) {
    "the bundle cannot be read within the size limit: " <> reason
  })
}

/// Writes bytes to a temporary name and renames it into place, so a reader sees
/// a whole file or none. The temporary file is removed when either step fails.
fn write_atomic(path: String, bytes: BitArray) -> Result(Nil, String) {
  let temporary =
    path <> ".tmp" <> int.to_string(ffi_os.unique_positive_integer())
  let written = {
    use Nil <- result.try(simplifile.write_bits(temporary, bytes))
    simplifile.rename(temporary, path)
  }

  // Either step failing leaves the target untouched and the temporary behind,
  // which is removed here and not left for the sweep.
  case written {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      let _removed = simplifile.delete(temporary)
      Error(
        "the state store cannot write: " <> simplifile.describe_error(error),
      )
    }
  }
}

/// Deletes one file of the store, counting a file that is already gone as
/// deleted.
fn remove(store: Store, name: String) -> Result(Nil, String) {
  case simplifile.delete(store.directory <> "/" <> name) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(
        "the state store cannot remove: " <> simplifile.describe_error(error),
      )
  }
}

fn bundle_path(store: Store, hash: String) -> String {
  store.directory <> "/" <> hash <> ".bundle"
}

fn record_path(store: Store, hash: String) -> String {
  store.directory <> "/" <> hash <> ".json"
}
