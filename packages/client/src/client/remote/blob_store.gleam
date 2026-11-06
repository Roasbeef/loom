//// The files of an executor's placed blobs (protocol-change/110).
////
//// A blob an orchestrator places on an untrusted executor arrives in pieces and
//// is kept in one directory, `<state root>/placed-blobs`, under its digest:
//// `<digest>.part` while its pieces arrive and `<digest>.blob` once the whole of
//// it was hashed and matched its description. A blob exists, by name, only after
//// that check. There is no record beside it, because a blob has no description
//// beyond its digest and its size, and the size is the file's.
////
//// This module keeps the files and enforces the directory's own bounds:
//// `size_limit` for one blob and `total_cap` for every file in the directory,
//// half-written ones included. It decides nothing about who may place what;
//// `client/remote/blob_service` owns the directory, serializes its calls, and
//// adds the per-binding and per-orchestrator bounds.
////
//// ## What may be relied on
////
//// A finished blob is a half-written file renamed into place after its bytes
//// were checked. A rename is not a flush, so after a crash a `.blob` can be
//// short, and `verify` hashes a finished file again; the service runs it before
//// it first hands a blob to a plane. Nothing is evicted to make room. `sweep`
//// removes finished blobs older than `retain_s` that the caller does not name as
//// kept, and half-written files that have not grown for `part_retain_s`.
////
//// ## Flow
////
//// `open` → `staged_bytes` → `append` → `finish` → `verify` → `sweep`

import client/remote/blob_transfer.{type Blob}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

/// What a store admits and how long it keeps it.
pub type Limits {
  Limits(
    /// The largest blob, in bytes.
    size_limit: Int,
    /// The most bytes the directory may hold, every file counted.
    total_cap: Int,
    /// How long a finished blob nobody claims is kept, in seconds from when it
    /// was finished.
    retain_s: Int,
  )
}

/// A gibibyte for one blob, which holds a proof's module cache; eight of them
/// for the directory; and a day for a blob no session claims, so a second job
/// over the same commit finds its archives.
pub const default_limits =
  Limits(size_limit: 1_073_741_824, total_cap: 8_589_934_592, retain_s: 86_400)

/// How long a half-written file is kept after its last piece, in seconds. A
/// placement that resumes does so in minutes, and every piece renews the time.
pub const part_retain_s = 3600

/// An open store: the directory and its limits.
pub opaque type Store {
  Store(directory: String, limits: Limits)
}

/// Why a write was not made.
pub type Staging {
  /// The bytes or the claim about them are wrong, or they do not fit. Sending
  /// them again cannot cure it.
  Rejected(reason: String)

  /// The directory could not be read or written; the same piece may succeed
  /// later.
  Faulted(reason: String)
}

/// A regular file of the store.
type File {
  File(name: String, size: Int, modified_s: Int)
}

/// What a file's name says it is.
type Kind {
  /// `<digest>.blob`, a checked blob.
  Finished(digest: String)

  /// `<digest>.part`, a blob still arriving.
  Arriving(digest: String)

  /// Anything else.
  Other
}

/// The directory an executor keeps placed blobs in: `<state root>/placed-blobs`.
///
/// ## Examples
///
/// ```gleam
/// assert blob_store.directory("/s") == "/s/placed-blobs"
/// ```
pub fn directory(state_root: String) -> String {
  state_root <> "/placed-blobs"
}

/// Creates the directory, private to this user, and opens it. Limits that
/// cannot hold one blob are refused.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(store) = blob_store.open(blob_store.directory(root), blob_store.default_limits)
/// ```
pub fn open(directory: String, limits: Limits) -> Result(Store, String) {
  use <- bool.guard(
    when: limits.size_limit < 1 || limits.total_cap < limits.size_limit,
    return: Error("the blob store's limits cannot hold one blob"),
  )
  use Nil <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(fn(error) {
      "the blob store cannot be made: " <> simplifile.describe_error(error)
    }),
  )
  use Nil <- result.try(
    simplifile.set_permissions_octal(directory, 0o700)
    |> result.map_error(fn(error) {
      "the blob store cannot be made private: "
      <> simplifile.describe_error(error)
    }),
  )
  Ok(Store(directory:, limits:))
}

/// The limits the store was opened with.
///
/// ## Examples
///
/// ```gleam
/// // blob_store.limits(store).size_limit
/// ```
pub fn limits(store: Store) -> Limits {
  store.limits
}

/// The path of a finished blob. The digest must have passed
/// `blob_transfer.is_digest`, which every caller checks first.
///
/// ## Examples
///
/// ```gleam
/// // blob_store.path(store, digest)
/// ```
pub fn path(store: Store, digest: String) -> String {
  store.directory <> "/" <> digest <> ".blob"
}

/// The size of a finished blob, or `Error(Nil)` when there is none by that name.
///
/// ## Examples
///
/// ```gleam
/// // blob_store.finished(store, digest) == Ok(4096)
/// ```
pub fn finished(store: Store, digest: String) -> Result(Int, Nil) {
  use <- bool.guard(when: !blob_transfer.is_digest(digest), return: Error(Nil))

  // Only a regular file is a blob; a missing name or anything else is none.
  case simplifile.link_info(path(store, digest)) {
    Ok(info) ->
      case simplifile.file_info_type(info) {
        simplifile.File -> Ok(info.size)
        simplifile.Directory | simplifile.Symlink | simplifile.Other ->
          Error(Nil)
      }
    Error(_absent) -> Error(Nil)
  }
}

/// How many bytes of a blob the store holds in its half-written file, zero when
/// it holds none.
///
/// ## Examples
///
/// ```gleam
/// // blob_store.staged_bytes(store, digest) == Ok(0)
/// ```
pub fn staged_bytes(store: Store, digest: String) -> Result(Int, String) {
  use <- bool.guard(
    when: !blob_transfer.is_digest(digest),
    return: Error("not a blob digest"),
  )

  // A missing file is no bytes held; any other failure is not a count.
  case simplifile.file_info(part_path(store, digest)) {
    Ok(info) -> Ok(info.size)
    Error(simplifile.Enoent) -> Ok(0)
    Error(error) ->
      Error(
        "the staged blob cannot be inspected: "
        <> simplifile.describe_error(error),
      )
  }
}

/// Appends the next piece of a blob to its half-written file and answers the
/// bytes now held.
///
/// The caller has compared the piece's offset with `staged_bytes`, so the piece
/// goes at the end. The first piece of a blob is its admission: the size must be
/// within `size_limit`, and the directory is swept first, keeping `kept`. Every
/// piece is checked against `total_cap`, because transfers in flight share the
/// directory, and a piece that does not fit removes the half-written file so its
/// bytes do not hold the room the refusal says is missing.
///
/// ## Examples
///
/// ```gleam
/// // blob_store.append(store, blob, bytes, now_s, kept)
/// ```
pub fn append(
  store: Store,
  blob: Blob,
  bytes: BitArray,
  now_s: Int,
  kept: Set(String),
) -> Result(Int, Staging) {
  let length = bit_array.byte_size(bytes)
  use blob <- result.try(
    blob_transfer.valid(blob) |> result.map_error(Rejected),
  )
  use <- bool.lazy_guard(
    when: blob.size > store.limits.size_limit,
    return: fn() { Error(Rejected(over_size(store, blob))) },
  )
  use held <- result.try(
    staged_bytes(store, blob.digest) |> result.map_error(Faulted),
  )
  use <- bool.guard(
    when: length < 1 || held + length > blob.size,
    return: Error(Rejected("the piece does not fit the declared size")),
  )

  // The first piece sweeps; later pieces only count.
  use _removed <- result.try(case held {
    0 -> sweep(store, now_s, kept) |> result.map_error(Faulted)
    _ -> Ok(0)
  })

  use used <- result.try(usage(store) |> result.map_error(Faulted))
  use <- bool.lazy_guard(
    when: used + length > store.limits.total_cap,
    return: fn() {
      discard(store, blob.digest)
      Error(Rejected(
        "the blob store holds "
        <> int.to_string(used)
        <> " of its "
        <> int.to_string(store.limits.total_cap)
        <> " byte cap, so a piece of "
        <> int.to_string(length)
        <> " bytes does not fit",
      ))
    },
  )

  written(store, blob, bytes, held)
}

/// Writes a piece: the first begins the file, every later one extends it.
fn written(
  store: Store,
  blob: Blob,
  bytes: BitArray,
  held: Int,
) -> Result(Int, Staging) {
  let part = part_path(store, blob.digest)

  // Only the first piece may create the file.
  let wrote = case held {
    0 -> simplifile.write_bits(part, bytes)
    _ -> simplifile.append_bits(part, bytes)
  }

  wrote
  |> result.map(fn(_wrote) { held + bit_array.byte_size(bytes) })
  |> result.map_error(fn(error) {
    Faulted("the blob store cannot write: " <> simplifile.describe_error(error))
  })
}

/// Makes a fully received blob a finished one, or refuses it.
///
/// The half-written file is hashed in pieces and its size and digest compared
/// with the description. A mismatch removes it and stores nothing. A match
/// renames it to the finished name, so a finished name always holds checked
/// bytes.
///
/// ## Examples
///
/// ```gleam
/// // blob_store.finish(store, blob)
/// ```
pub fn finish(store: Store, blob: Blob) -> Result(Nil, Staging) {
  let part = part_path(store, blob.digest)
  use held <- result.try(
    staged_bytes(store, blob.digest) |> result.map_error(Faulted),
  )

  // Only a file of the declared size is worth hashing.
  let digest = case held == blob.size {
    True -> blob_transfer.hash_file(part, blob.size)
    False -> Error("the staged blob is not the declared size")
  }

  // The comparison is the whole of the refusal: nothing but matching bytes is
  // ever renamed to a finished name.
  case digest {
    Ok(found) if found == blob.digest ->
      simplifile.rename(part, path(store, blob.digest))
      |> result.map_error(fn(error) {
        Faulted(
          "the blob store cannot place the blob: "
          <> simplifile.describe_error(error),
        )
      })
    Ok(_other) | Error(_) -> {
      discard(store, blob.digest)
      Error(Rejected("the received blob does not match its digest or its size"))
    }
  }
}

/// Hashes a finished blob again and compares it with its digest, for the first
/// time a plane is handed it after a restart. A blob that fails is removed.
///
/// ## Examples
///
/// ```gleam
/// // blob_store.verify(store, digest)
/// ```
pub fn verify(store: Store, digest: String) -> Result(Int, String) {
  use size <- result.try(
    finished(store, digest)
    |> result.replace_error("the executor holds no such blob"),
  )
  let found = blob_transfer.hash_file(path(store, digest), size)

  // A finished blob that no longer matches was damaged after it was placed, and
  // is removed so the orchestrator's next placement sends it again.
  case found {
    Ok(found) if found == digest -> Ok(size)
    Ok(_other) | Error(_) -> {
      let _removed = simplifile.delete(path(store, digest))
      Error("the held blob no longer matches its digest")
    }
  }
}

/// Removes a blob's half-written file. A missing file is not an error.
///
/// ## Examples
///
/// ```gleam
/// // blob_store.discard(store, digest)
/// ```
pub fn discard(store: Store, digest: String) -> Nil {
  // Only a digest names a file, so a peer's text is never a path.
  case blob_transfer.is_digest(digest) {
    True -> {
      let _removed = simplifile.delete(part_path(store, digest))
      Nil
    }
    False -> Nil
  }
}

/// The bytes of every regular file in the directory.
///
/// ## Examples
///
/// ```gleam
/// // blob_store.usage(store) == Ok(0)
/// ```
pub fn usage(store: Store) -> Result(Int, String) {
  use files <- result.map(files_of(store))
  list.fold(files, 0, fn(total, file) { total + file.size })
}

/// Removes finished blobs older than `retain_s` whose digest is not in `kept`,
/// half-written files that have not grown for `part_retain_s`, and stray files
/// older than `retain_s`. Answers how many files it removed.
///
/// ## Examples
///
/// ```gleam
/// // blob_store.sweep(store, now_s, set.new())
/// ```
pub fn sweep(
  store: Store,
  now_s: Int,
  kept: Set(String),
) -> Result(Int, String) {
  use files <- result.try(files_of(store))
  let part_retain = int.min(part_retain_s, store.limits.retain_s)
  let doomed =
    list.filter(files, fn(file) {
      let age = now_s - file.modified_s

      // A claimed blob is never swept; anything else goes by its age.
      case kind_of(file.name) {
        Finished(digest:) ->
          !set.contains(kept, digest) && age > store.limits.retain_s
        Arriving(..) -> age > part_retain
        Other -> age > store.limits.retain_s
      }
    })

  list.try_each(doomed, fn(file) { remove(store, file.name) })
  |> result.replace(list.length(doomed))
}

/// The refusal for a blob over the size limit.
fn over_size(store: Store, blob: Blob) -> String {
  "the blob is "
  <> int.to_string(blob.size)
  <> " bytes, over the "
  <> int.to_string(store.limits.size_limit)
  <> " this executor keeps"
}

/// Classifies a file name; only a digest makes a name a blob's.
fn kind_of(name: String) -> Kind {
  let stem = string.drop_end(name, 5)
  let digest = blob_transfer.is_digest(stem)

  // The suffix and a digest stem together make a blob's file.
  case string.ends_with(name, ".blob"), string.ends_with(name, ".part") {
    True, _ if digest -> Finished(stem)
    _, True if digest -> Arriving(stem)
    _, _ -> Other
  }
}

/// The directory's regular files with their sizes and times. A subdirectory or
/// a link is neither counted nor touched: the store only makes regular files.
fn files_of(store: Store) -> Result(List(File), String) {
  use names <- result.try(
    simplifile.read_directory(store.directory)
    |> result.map_error(fn(error) {
      "the blob store cannot be listed: " <> simplifile.describe_error(error)
    }),
  )
  list.try_map(names, fn(name) {
    simplifile.link_info(store.directory <> "/" <> name)
    |> result.map_error(fn(error) {
      "the blob store entry cannot be read: "
      <> simplifile.describe_error(error)
    })
    |> result.map(fn(info) {
      // Only a regular file is the store's.
      case simplifile.file_info_type(info) {
        simplifile.File ->
          Ok(File(name:, size: info.size, modified_s: info.mtime_seconds))
        simplifile.Directory | simplifile.Symlink | simplifile.Other ->
          Error(Nil)
      }
    })
  })
  |> result.map(list.filter_map(_, fn(entry) { entry }))
}

/// Deletes one file of the store, a missing one counting as deleted.
fn remove(store: Store, name: String) -> Result(Nil, String) {
  case simplifile.delete(store.directory <> "/" <> name) {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(
        "the blob store cannot remove: " <> simplifile.describe_error(error),
      )
  }
}

/// The half-written file of a blob still arriving.
fn part_path(store: Store, digest: String) -> String {
  store.directory <> "/" <> digest <> ".part"
}
