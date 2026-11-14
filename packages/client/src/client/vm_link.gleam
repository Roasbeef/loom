//// The decisions behind `loom vm up --link untrusted`, with no effect in them.
////
//// A guest reached over the untrusted link (protocol-change/109) is not a
//// distribution peer. The host daemon dials the guest's executor listener over
//// TLS on a loopback port that `loom-vm run --forward` maps into the guest, and
//// both sides pin the other's leaf certificate. So the guest needs no cookie,
//// no `[distribution]` table, no ledger and no epmd entry, and the host
//// daemon's configuration gains one `[executor_link]` table and one
//// `[executors.<name>]` row per guest.
////
//// `client/vm_cli` does the work and `client/vm_link_pki` mints the
//// certificates. This module decides everything that needs neither: which link
//// a guest has, which loopback port its row names, what the host's `loom.toml`
//// gains and loses, and what is staged into the guest's root.
////
//// ## Flow
////
//// - `settle` picks the guest's link from its record, the traces of a first run and the
////   `--link` flag, and refuses to change it.
//// - `port_step` decides whether the recorded loopback port is kept or a new
////   one is reserved.
//// - `install` merges `[executor_link]` and the guest's row into the host's
////   configuration, and `uninstall` takes them out again.
//// - `guest_config` and `staging` are what the guest's root holds: a listener
////   that admits the orchestrator's pin, three credential files, and no cookie.
//// - `daemon_need` decides whether the default daemon is asked to reload, and
////   `reload_result` and `reload_report` turn its answer into the lines to print
////   and the question of whether the old stop-or-name path still runs.
//// - `daemon_lines` and `status_lines` word what a developer is told.
////
//// ## Two rules for the host's `loom.toml`
////
//// A table the file already has is never replaced by one that differs: that is
//// the posture of `loom distribution install`, and it is what keeps the owner's
//// own `[executor_link]` and rows. The one exception is the guest's own row
//// moving to another port. Its pin names the guest's leaf, which only this
//// guest's directory holds, so a row with that pin and another address is the
//// row an earlier `up` wrote, and `up` writes the new address over it.
////
//// The merge reads and writes tables and nothing else, so a `[distribution]`
//// table and every trusted row beside them are exactly as they were. A
//// configuration that holds a ledger deployment takes the new rows as written,
//// because the ledger derives its rows beside the written ones
//// (`client/ledger_rows.executor_roster`) and an untrusted row names no node.

import client/distribution.{type CredentialFiles}
import client/distribution_bundle
import client/distribution_install
import client/executor_reload
import client/internal/ffi_pki
import client/vm_spec.{
  type DaemonOutcome, type LinkKind, Distribution, Untrusted,
}
import core/json as core_json
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tom

/// The file in a guest's directory that records its link kind. It is written by
/// the host and read by the host, never staged into the guest.
pub const kind_file = "link"

/// The file in a guest's directory that records the host loopback port its
/// row names, so every boot of the guest uses the same address.
pub const port_file = "link-port"

/// The directory of a guest that holds the guest's own leaf and key. It is not
/// called `link`, because the guest's `link` record is a file of that name.
pub const guest_credentials_dir = "link-credentials"

// --- which link a guest has ------------------------------------------------------

/// The text of a guest's `link` record.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.encode_kind(vm_spec.Untrusted) == "untrusted\n"
/// ```
pub fn encode_kind(kind: LinkKind) -> String {
  case kind {
    Distribution -> "distribution\n"
    Untrusted -> "untrusted\n"
  }
}

/// Reads the `link` record. A guest with no record is a distribution guest,
/// which is what every guest made before the record existed is, so those guests
/// are unchanged. Text that names neither kind is an error, never a default: a
/// record that cannot be read must not turn an untrusted guest into a trusted
/// one.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.decode_kind(None) == Ok(vm_spec.Distribution)
/// assert vm_link.decode_kind(Some("untrusted\n")) == Ok(vm_spec.Untrusted)
/// ```
pub fn decode_kind(record: Option(String)) -> Result(LinkKind, String) {
  case record {
    None -> Ok(Distribution)
    Some(text) ->
      case string.trim(text) {
        "distribution" -> Ok(Distribution)
        "untrusted" -> Ok(Untrusted)
        other ->
          Error(
            "the link record says "
            <> string.inspect(string.slice(other, 0, 40))
            <> ", not distribution or untrusted",
          )
      }
  }
}

/// What a guest's directory holds that a first `up` leaves before it records a
/// link: the bundles a distribution `up` writes, or the leaf an untrusted `up`
/// mints. Either says which link the guest was started with even when the run
/// stopped before it wrote the `link` record.
pub type Traces {
  /// Neither: the guest is new.
  NoTraces

  /// The `deploy/` directory of a distribution guest.
  DeployTrace

  /// The `link-credentials/` directory of an untrusted guest.
  LeafTrace
}

/// The link a guest has after this command: the one it was made with, or the
/// one `--link` asks for when it is new.
///
/// A guest keeps its link for life. A guest with a `link` record has that
/// kind; one with distribution bundles and no record is a distribution guest,
/// and one with a minted leaf is an untrusted guest; one with neither is new
/// and takes the flag, defaulting to distribution. A flag that names the other kind is refused, because the guest's root, its row
/// and its credentials all belong to one kind, and `--fresh` replaces the root
/// and the disk but not the host's configuration.
///
/// ## Examples
///
/// ```gleam
/// let new = vm_link.settle("dev", None, vm_link.NoTraces, Some(vm_spec.Untrusted))
/// assert new == Ok(vm_spec.Untrusted)
/// ```
pub fn settle(
  name: String,
  record: Option(String),
  traces: Traces,
  requested: Option(LinkKind),
) -> Result(LinkKind, String) {
  use made <- result.try(made_with(record, traces))

  // A new guest takes the flag; an existing one keeps what it has.
  case made, requested {
    None, None -> Ok(Distribution)
    None, Some(asked) -> Ok(asked)
    Some(kind), None -> Ok(kind)
    Some(kind), Some(asked) if kind == asked -> Ok(kind)
    Some(kind), Some(asked) -> Error(mixed_refusal(name, kind, asked))
  }
}

/// The kind a guest was made with, or none when it is new.
fn made_with(
  record: Option(String),
  traces: Traces,
) -> Result(Option(LinkKind), String) {
  // A record decides. Without one, the traces of a first run say which link it
  // was, so a flagless `up` after an interrupted untrusted one resumes it as
  // untrusted and never as a distribution guest.
  case record, traces {
    Some(_), _ -> decode_kind(record) |> result.map(Some)
    None, DeployTrace -> Ok(Some(Distribution))
    None, LeafTrace -> Ok(Some(Untrusted))
    None, NoTraces -> Ok(None)
  }
}

/// The refusal for a guest asked to change its link.
fn mixed_refusal(name: String, made: LinkKind, asked: LinkKind) -> String {
  "the guest "
  <> name
  <> " was made with the "
  <> kind_word(made)
  <> " link and keeps it, even under `--fresh`, which replaces the root and the "
  <> "disk and leaves the daemon's configuration as it is. Remove it with "
  <> "`loom vm rm --name "
  <> name
  <> " --yes` and run `loom vm up --link "
  <> kind_word(asked)
  <> "` again."
}

/// The word `--link` and `status` use for a kind.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.kind_word(vm_spec.Untrusted) == "untrusted"
/// ```
pub fn kind_word(kind: LinkKind) -> String {
  case kind {
    Distribution -> "distribution"
    Untrusted -> "untrusted"
  }
}

// --- the loopback port -------------------------------------------------------------

/// The text of a guest's `link-port` record.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.encode_port(41_000) == "41000\n"
/// ```
pub fn encode_port(port: Int) -> String {
  int.to_string(port) <> "\n"
}

/// Reads the `link-port` record: one canonical decimal port in 1 to 65535.
/// Anything else is an error, which `up` treats as no record and replaces.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.decode_port("41000\n") == Ok(41_000)
/// assert result.is_error(vm_link.decode_port("0041000"))
/// ```
pub fn decode_port(text: String) -> Result(Int, String) {
  let written = string.trim(text)

  let parsed = int.parse(written)

  // A port is in range, and its canonical spelling is the check that rejects a
  // sign or a leading zero, which `int.parse` reads and a person would not
  // mean.
  case parsed {
    Ok(port) if port >= 1 && port <= 65_535 ->
      // The spelling decides it: only the canonical one is a record.
      case int.to_string(port) == written {
        True -> Ok(port)
        False -> Error(not_a_port)
      }
    _ -> Error(not_a_port)
  }
}

const not_a_port = "the link-port record is not a TCP port"

/// What a probe of the recorded loopback port found.
pub type Availability {
  /// Nothing listens on it.
  Free

  /// Something listens on it.
  InUse
}

/// What `up` knows about the guest's port before it boots.
pub type Seen {
  /// No usable record: a first `up`, or a record that could not be read.
  NotRecorded

  /// The recorded port, and what a probe of it found.
  Recorded(port: Int, availability: Availability)
}

/// What `up` does about the guest's port.
pub type PortStep {
  /// Boot on the recorded port, so the row in the daemon's file stays right.
  Keep(port: Int)

  /// Reserve a port, record it and write it into the guest's row.
  Reserve
}

/// Keeps the recorded port unless something else listens on it. The pin makes a
/// stranger on the old port harmless, since the link refuses any leaf but the
/// guest's, but the launcher cannot bind a port that is taken, so a taken port
/// is replaced and the daemon, which reads its rows at start, needs a restart.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.port_step(vm_link.Recorded(41_000, vm_link.Free))
///   == vm_link.Keep(41_000)
/// assert vm_link.port_step(vm_link.Recorded(41_000, vm_link.InUse))
///   == vm_link.Reserve
/// ```
pub fn port_step(seen: Seen) -> PortStep {
  case seen {
    Recorded(port:, availability: Free) -> Keep(port)
    Recorded(availability: InUse, ..) | NotRecorded -> Reserve
  }
}

/// The address a guest's row names for a port.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.address(41_000) == "127.0.0.1:41000"
/// ```
pub fn address(port: Int) -> String {
  "127.0.0.1:" <> int.to_string(port)
}

// --- certificates ------------------------------------------------------------------

/// The pin of a certificate: the SHA-256 of its DER as 64 lower-case
/// hexadecimal digits, which is the form `client/untrusted_config.pin_of`
/// accepts and the link checks the peer against.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(vm_link.pin_of("not a certificate"))
/// ```
pub fn pin_of(certificate: String) -> Result(String, String) {
  ffi_pki.pin(certificate)
  |> result.map(fn(bytes) { string.lowercase(bit_array.base16_encode(bytes)) })
  |> result.replace_error("the certificate is not one PEM certificate")
}

// --- the host's configuration -----------------------------------------------------------

/// The three files `[executor_link]` names, as absolute host paths.
pub type LinkFiles {
  LinkFiles(ca: String, certificate: String, key: String)
}

/// One guest's `[executors.<name>]` row.
pub type Row {
  Row(
    /// The guest's name, which is the executor's name.
    name: String,
    /// The host loopback port the launcher forwards to the guest's listener.
    port: Int,
    /// The pin of the guest's leaf certificate.
    pin: String,
  )
}

/// What `install` did to the text.
pub type Change {
  /// Both tables were already there as wanted.
  Unchanged

  /// A table was added.
  Added

  /// The guest's row named another port and now names this one.
  Moved
}

/// The merged text and what changed in it. A running daemon reads rows only at
/// start, so any change but `Unchanged` is one it has not seen.
pub type Merged {
  Merged(text: String, change: Change)
}

/// The `[executor_link]` table for `files`.
///
/// ## Examples
///
/// ```gleam
/// let files = vm_link.LinkFiles("/l/ca.pem", "/l/o.pem", "/l/o.key")
/// assert string.starts_with(vm_link.link_table(files), "[executor_link]\n")
/// ```
pub fn link_table(files: LinkFiles) -> String {
  "[executor_link]\nca = "
  <> distribution_bundle.toml_string(files.ca)
  <> "\ncertificate = "
  <> distribution_bundle.toml_string(files.certificate)
  <> "\nkey = "
  <> distribution_bundle.toml_string(files.key)
  <> "\n"
}

/// The `[executors.<name>]` table for `row`.
///
/// ## Examples
///
/// ```gleam
/// let text = vm_link.row_table(vm_link.Row("dev", 41_000, pin))
/// assert string.contains(text, "address = \"127.0.0.1:41000\"")
/// ```
pub fn row_table(row: Row) -> String {
  "[executors."
  <> distribution_bundle.toml_key(row.name)
  <> "]\ntrust = \"untrusted\"\naddress = "
  <> distribution_bundle.toml_string(address(row.port))
  <> "\npin = "
  <> distribution_bundle.toml_string(row.pin)
  <> "\n"
}

// What a table the file may already hold is, compared with the one wanted.
type Verdict {
  Missing
  Same
  Movable
  Foreign
}

/// Adds `[executor_link]` and the guest's row to the host's configuration text,
/// refusing any existing table that differs, and answers the new text. `file`
/// names the file in the refusals. Nothing but those two tables is touched.
///
/// ## Examples
///
/// ```gleam
/// let merged = vm_link.install("", files, row, "loom.toml")
/// assert result.map(merged, fn(m) { m.change }) == Ok(vm_link.Added)
/// ```
pub fn install(
  text: String,
  files: LinkFiles,
  row: Row,
  file: String,
) -> Result(Merged, String) {
  use document <- result.try(distribution_install.parse_document(text, file))
  use wanted <- result.try(wanted_values(files, row))
  use verdicts <- result.try(judge(document, wanted, row, file))

  // A moved row is removed first so the new one is appended whole, and each
  // table that is missing or moved is appended once.
  use kept <- result.try(case verdicts.row {
    Movable ->
      distribution_install.without_tables(text, [["executors", row.name]], file)
    _ -> Ok(text)
  })

  let additions =
    list.flatten([
      wanted_when(verdicts.link, link_table(files)),
      wanted_when(verdicts.row, row_table(row)),
    ])
  let merged = append(kept, additions)
  use Nil <- result.try(confirm(merged, wanted, row, file))
  Ok(Merged(text: merged, change: change_of(verdicts)))
}

// The two tables as the daemon's parser reads them, which is what an existing
// table is compared with.
type Wanted {
  Wanted(link: tom.Toml, row: tom.Toml)
}

/// The values of the two tables that `files` and `row` define.
fn wanted_values(files: LinkFiles, row: Row) -> Result(Wanted, String) {
  use link <- result.try(table_value(link_table(files), ["executor_link"]))
  use row_value <- result.map(
    table_value(row_table(row), [
      "executors",
      row.name,
    ]),
  )
  Wanted(link:, row: row_value)
}

// How each wanted table compares with the one the file holds.
type Verdicts {
  Verdicts(link: Verdict, row: Verdict)
}

/// Compares the file's tables with the wanted ones, and refuses a table that
/// differs where only the guest's own row may move.
fn judge(
  document: dict.Dict(String, tom.Toml),
  wanted: Wanted,
  row: Row,
  file: String,
) -> Result(Verdicts, String) {
  let link =
    verdict(
      distribution_install.lookup(document, ["executor_link"]),
      wanted.link,
      Foreign,
    )
  let found =
    verdict(
      distribution_install.lookup(document, ["executors", row.name]),
      wanted.row,
      Movable,
    )

  // A table that is foreign is the user's, and replacing it is never the
  // command's to do.
  case link, found {
    Foreign, _ -> Error(link_refusal(file))
    _, Foreign -> Error(row_refusal(file, row))
    _, _ -> Ok(Verdicts(link:, row: found))
  }
}

/// How an existing table compares with the wanted one. `movable_to` is what a
/// table that differs only in its address is: the guest's own row moves, and the
/// link table never does.
fn verdict(
  found: Result(tom.Toml, Nil),
  wanted: tom.Toml,
  movable_to: Verdict,
) -> Verdict {
  // Only a table that is equal, or equal but for the address, is the one an
  // earlier `up` wrote.
  case found, wanted {
    Error(Nil), _ -> Missing
    Ok(existing), _ if existing == wanted -> Same
    Ok(tom.Table(existing)), tom.Table(expected) ->
      case
        dict.delete(existing, "address") == dict.delete(expected, "address")
      {
        True -> movable_to
        False -> Foreign
      }
    Ok(_), _ -> Foreign
  }
}

/// The refusal for an `[executor_link]` that names other files.
fn link_refusal(file: String) -> String {
  file
  <> " already has an [executor_link] table that names files other than "
  <> "this vm home's link credentials. A daemon has one [executor_link] table, "
  <> "so a guest made here cannot share another authority's: its certificate "
  <> "would not chain to that authority, and `loom vm up --link untrusted` "
  <> "never replaces the table. Give `--config` another file for this guest, "
  <> "or remove the table from this one if nothing else uses it."
}

/// The refusal for a guest's row that is not the one an earlier `up` wrote.
fn row_refusal(file: String, row: Row) -> String {
  file
  <> " already has [executors."
  <> row.name
  <> "] with other values. `loom vm up --link untrusted` never replaces it. "
  <> "If an earlier guest wrote it, `loom vm rm --name "
  <> row.name
  <> " --yes` removes it; otherwise remove it from the file, or give "
  <> "`--config` another file. Its address for this guest is "
  <> address(row.port)
  <> "."
}

/// The table text to append when the verdict says it is not already there.
fn wanted_when(found: Verdict, text: String) -> List(String) {
  case found {
    Missing | Movable -> [text]
    Same | Foreign -> []
  }
}

/// The change the two verdicts add up to.
fn change_of(verdicts: Verdicts) -> Change {
  // A moved row is the one change that gives an existing row a new address.
  case verdicts.link, verdicts.row {
    _, Movable -> Moved
    Missing, _ | _, Missing -> Added
    _, _ -> Unchanged
  }
}

/// Reads the result back: both tables are in the merged text exactly as
/// wanted, so a spelling the line-based edit could not reach (a dotted key at
/// the top of the file) is refused, not left to disagree with the daemon.
fn confirm(
  merged: String,
  wanted: Wanted,
  row: Row,
  file: String,
) -> Result(Nil, String) {
  use document <- result.try(distribution_install.parse_document(merged, file))
  let tables = [
    #(["executor_link"], wanted.link),
    #(["executors", row.name], wanted.row),
  ]

  // Each wanted table must be found, and be equal.
  list.try_each(tables, fn(entry) {
    case distribution_install.lookup(document, entry.0) {
      Ok(found) if found == entry.1 -> Ok(Nil)
      _ ->
        Error(
          file
          <> " could not be rewritten for ["
          <> string.join(entry.0, ".")
          <> "]; remove it by hand and run `loom vm up` again",
        )
    }
  })
}

/// Joins the additions to the kept text with a blank line between tables.
fn append(kept: String, additions: List(String)) -> String {
  let body = string.join(additions, "\n")

  // An empty file takes the tables as they are, and nothing to add changes
  // nothing.
  case string.trim(kept), additions {
    _, [] -> kept
    "", _ -> body
    _, _ -> string.trim_end(kept) <> "\n\n" <> body
  }
}

/// Whether other guests still need `[executor_link]` and the vm home's
/// `link` directory.
pub type Remaining {
  /// Another untrusted guest remains.
  OthersRemain

  /// The guest being removed is the last untrusted one.
  LastLinked
}

/// Whether any of the other guests' links is untrusted.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.remaining([vm_spec.Distribution]) == vm_link.LastLinked
/// assert vm_link.remaining([vm_spec.Untrusted]) == vm_link.OthersRemain
/// ```
pub fn remaining(others: List(LinkKind)) -> Remaining {
  case list.any(others, fn(kind) { kind == Untrusted }) {
    True -> OthersRemain
    False -> LastLinked
  }
}

/// Whether `[executor_link]` is still in the text after a removal.
pub type LinkTable {
  /// It is, because another untrusted row needs it or it is not the one `up`
  /// wrote, so the credentials it names must stay.
  LinkTableKept

  /// It is not, either removed or never there, so nothing names the
  /// credentials any more.
  LinkTableGone
}

/// What `uninstall` took out.
pub type Removal {
  Removal(
    /// The text without the tables.
    text: String,
    /// The tables that went, each as its path.
    removed: List(List(String)),
    /// Whether the link table is still in the text.
    table: LinkTable,
    /// A line for each table that was left because it is not the guest's.
    left: List(String),
  )
}

/// Takes the guest's row out of the configuration text, and `[executor_link]`
/// with it when this was the last untrusted guest and no other untrusted row
/// needs it. A table that is not the one `up` wrote is left alone: a row of
/// that name with another pin than the guest's `pin`, which is a row the user
/// wrote, or a link table that names other files, belongs to the user. Lines
/// between the guest's tables and the next table are kept with it, as is every
/// other line.
///
/// ## Examples
///
/// ```gleam
/// let out = vm_link.uninstall(text, row, vm_link.LastLinked, files, "loom.toml")
/// ```
pub fn uninstall(
  text: String,
  row: Row,
  remaining: Remaining,
  files: LinkFiles,
  file: String,
) -> Result(Removal, String) {
  use document <- result.try(distribution_install.parse_document(text, file))
  use link <- result.try(table_value(link_table(files), ["executor_link"]))
  let name = row.name
  let found = distribution_install.lookup(document, ["executors", name])

  // The guest's row goes only when it is an untrusted one with the guest's own
  // pin, which is what an earlier `up` wrote; a row of the same name that
  // anything else wrote is the user's.
  let #(row_goes, left) = case is_guests(found, row.pin) {
    True -> #([["executors", name]], [])
    False ->
      case found {
        Ok(_) -> #([], [
          "[executors."
          <> name
          <> "]: its pin is not this guest's, so it is not the row `up` wrote",
        ])
        Error(Nil) -> #([], [])
      }
  }

  // Others count the untrusted rows besides the one that goes: a row a person
  // wrote by hand keeps `[executor_link]` for itself.
  let others =
    list.filter(untrusted_rows(document), fn(other) {
      row_goes == [] || other != name
    })
  let link_goes =
    remaining == LastLinked
    && others == []
    && distribution_install.lookup(document, ["executor_link"]) == Ok(link)

  // The link table follows the last guest only when it is the one `up` wrote.
  let tables = case link_goes {
    True -> list.append(row_goes, [["executor_link"]])
    False -> row_goes
  }

  use kept <- result.try(distribution_install.without_tables(text, tables, file))
  use after <- result.map(distribution_install.parse_document(kept, file))
  Removal(
    text: kept,
    removed: tables,
    table: case dict.has_key(after, "executor_link") {
      True -> LinkTableKept
      False -> LinkTableGone
    },
    left:,
  )
}

/// Whether a table that may be absent is the guest's own row: untrusted, with
/// the guest's pin.
fn is_guests(found: Result(tom.Toml, Nil), pin: String) -> Bool {
  // The pin names the guest's leaf, which only this guest's directory holds.
  case found {
    Ok(tom.Table(fields)) ->
      is_untrusted(found) && dict.get(fields, "pin") == Ok(tom.String(pin))
    Ok(_) | Error(Nil) -> False
  }
}

/// Whether a table that may be absent says it is untrusted.
fn is_untrusted(found: Result(tom.Toml, Nil)) -> Bool {
  // Only a table with `trust = "untrusted"` is an untrusted row.
  case found {
    Ok(tom.Table(fields)) ->
      dict.get(fields, "trust") == Ok(tom.String("untrusted"))
    Ok(_) | Error(Nil) -> False
  }
}

/// The names of the `[executors.<name>]` rows whose trust is untrusted.
fn untrusted_rows(document: dict.Dict(String, tom.Toml)) -> List(String) {
  // A file with no `[executors]` table has no row of either kind.
  case dict.get(document, "executors") {
    Ok(tom.Table(rows)) ->
      dict.to_list(rows)
      |> list.filter(fn(entry) { is_untrusted(Ok(entry.1)) })
      |> list.map(fn(entry) { entry.0 })
    Ok(_) | Error(Nil) -> []
  }
}

/// The value a table's own text defines at `path`.
fn table_value(text: String, path: List(String)) -> Result(tom.Toml, String) {
  use document <- result.try(distribution_install.parse_document(
    text,
    "the table",
  ))
  distribution_install.lookup(document, path)
  |> result.replace_error("the table text is not a table")
}

// --- the guest's root ----------------------------------------------------------------

/// The executor's `[executor_listener]` table: it listens on the guest port on
/// every interface, so the forward reaches it, presents the guest's leaf, and
/// admits only the orchestrator whose pin is `orchestrator`. A process in the
/// guest that connects without the orchestrator's key fails the handshake.
///
/// ## Examples
///
/// ```gleam
/// let text = vm_link.listener_table(vm_spec.guest_files(), pin)
/// assert string.contains(text, "listen = \"0.0.0.0:4370\"")
/// ```
pub fn listener_table(files: CredentialFiles, orchestrator: String) -> String {
  "[executor_listener]\nlisten = "
  <> distribution_bundle.toml_string(
    "0.0.0.0:" <> int.to_string(vm_spec.guest_port),
  )
  <> "\nca = "
  <> distribution_bundle.toml_string(files.ca)
  <> "\ncertificate = "
  <> distribution_bundle.toml_string(files.certificate)
  <> "\nkey = "
  <> distribution_bundle.toml_string(files.key)
  <> "\norchestrators = ["
  <> distribution_bundle.toml_string(orchestrator)
  <> "]\n"
}

/// The executor's `loom.toml` for the untrusted link: the listener, and the
/// model, workspace and tools tables every guest has. It has no `[distribution]`
/// table, which the daemon would refuse beside the listener.
///
/// ## Examples
///
/// ```gleam
/// let text = vm_link.guest_config(vm_spec.guest_files(), pin, ["proj"], vm_spec.GitHubOff, [])
/// assert !string.contains(text, "[distribution]")
/// ```
pub fn guest_config(
  files: CredentialFiles,
  orchestrator: String,
  workspaces: List(String),
  github: vm_spec.GitHubAccess,
  allow: List(String),
) -> String {
  vm_spec.guest_config_with(
    [listener_table(files, orchestrator)],
    workspaces,
    github,
    allow,
  )
}

/// A file staged into the guest's root: its guest path and its contents.
pub type Staged {
  Staged(path: String, contents: String)
}

/// The files `up` stages for an untrusted guest: the authority's certificate,
/// the guest's leaf and key, and the configuration. There is no cookie and no
/// ledger, and the key is the one secret the guest holds.
///
/// ## Examples
///
/// ```gleam
/// let staged = vm_link.staging(vm_spec.guest_files(), ca, cert, key, config)
/// assert list.length(staged) == 4
/// ```
pub fn staging(
  files: CredentialFiles,
  ca: String,
  certificate: String,
  key: String,
  config: String,
) -> List(Staged) {
  [
    Staged(files.ca, ca),
    Staged(files.certificate, certificate),
    Staged(files.key, key),
    Staged(vm_spec.node_dir <> "/loom.toml", config),
  ]
}

// --- whether the daemon has read the guest's row ---------------------------------------

/// Whether the guest's row is one this command wrote or one an earlier command
/// left standing.
pub type Rows {
  /// The command added the row or moved its port, so a daemon that was running
  /// before it cannot have read it.
  RowChanged

  /// The row was already as the guest needs it.
  RowStanding
}

/// What the default daemon said when asked for its deployment.
pub type DaemonSaw {
  /// No daemon runs.
  SawNoDaemon

  /// A daemon runs and its answer did not say which executors it holds.
  SawUnanswered

  /// A daemon answered with the names of the executor rows it holds.
  SawExecutors(names: List(String))
}

/// Whether the default daemon is asked to reread its configuration to reach
/// the guest.
pub type DaemonNeed {
  /// A daemon runs and has not read the guest's row, or this command changed
  /// it.
  MustReload

  /// No daemon runs, or the daemon already holds the row as the file has it.
  NeedsNothing
}

/// Decides whether the default daemon is asked to run `executors.reload` for
/// an untrusted guest (protocol-change/115). A running daemon is asked when
/// this command changed the guest's row, because no daemon can have read it, or
/// when the row was already there and the daemon does not list the guest: a
/// first `up` whose boot failed after the row was written, and a daemon that
/// started before it. A daemon that does not answer the listing is not claimed
/// to lack a row that was already there. A daemon that is not running reads the
/// file when it starts, so it is never asked.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.daemon_need(vm_link.RowStanding, vm_link.SawExecutors([]), "dev")
///   == vm_link.MustReload
/// ```
pub fn daemon_need(rows: Rows, saw: DaemonSaw, name: String) -> DaemonNeed {
  // Nothing is asked of a daemon that is not there; of one that is, a changed
  // row is unread whatever it says and a standing one is read only if listed.
  case rows, saw {
    _, SawNoDaemon -> NeedsNothing
    RowChanged, SawUnanswered | RowChanged, SawExecutors(_) -> MustReload
    RowStanding, SawExecutors(names) ->
      case list.contains(names, name) {
        True -> NeedsNothing
        False -> MustReload
      }
    RowStanding, SawUnanswered -> NeedsNothing
  }
}

/// What came of asking the daemon to run `executors.reload`.
pub type ReloadResult {
  /// The daemon answered and its reply decoded.
  Answered(reply: executor_reload.Reply)

  /// The daemon does not know the command, which is how a daemon older than
  /// protocol-change/115 answers.
  PredatesReload

  /// The daemon refused the call. `message` is the reason, when the refusal
  /// carried one.
  RefusedReload(code: String, message: Option(String))

  /// No usable answer came: the exchange failed, or the body did not decode.
  NoAnswer(reason: String)
}

/// Whether the old path still has to run: stop a daemon that holds no session,
/// or name the command that stops one that does.
pub type OldPath {
  /// The daemon holds the row, so nothing is stopped.
  OldPathSkipped

  /// The daemon was not made to hold the row, so the stop-or-name path runs.
  OldPathRuns
}

/// What `up` reports about a reload: the lines to print, and whether the old
/// path still runs.
pub type ReloadReport {
  ReloadReport(lines: List(String), old_path: OldPath)
}

/// Classifies what the exchange for `executors.reload` returned. The refusal
/// strings are the ones `host/access` reports: a bare code, or
/// `reload_invalid: ` followed by the daemon's reason.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.reload_result(Error("bad_request")) == vm_link.PredatesReload
/// ```
pub fn reload_result(
  asked: Result(core_json.JsonValue, String),
) -> ReloadResult {
  // A body must decode as a reply before it is believed; a refusal is read
  // from the text the access layer made of it.
  case asked {
    Ok(body) ->
      case executor_reload.decode(body) {
        Ok(reply) -> Answered(reply)
        Error(reason) ->
          NoAnswer("the reply to executors.reload was not readable: " <> reason)
      }
    Error("bad_request") -> PredatesReload
    Error("reload_invalid: " <> reason) ->
      RefusedReload("reload_invalid", Some(reason))
    Error("reload_invalid") -> RefusedReload("reload_invalid", None)
    Error("forbidden") -> RefusedReload("forbidden", None)
    Error("not_found") -> RefusedReload("not_found", None)
    Error("unavailable") -> RefusedReload("unavailable", None)
    Error(reason) -> NoAnswer(reason)
  }
}

/// Words what a reload did, and decides whether the old path still has to run
/// for the guest called `name`.
///
/// Every entry that is not `unchanged` gets a line, whichever guest it names,
/// so a row that changed without this command's doing is seen. The old path
/// runs when the daemon was not made to hold the guest's row: it predates the
/// command, refused it, did not answer, or answered with the guest's entry
/// `failed`, `stopped` or missing. A `stopped` entry after `up` means the
/// daemon found no row for the guest, or took it out, so no link serves it. A
/// refusal's reason is printed before it does.
///
/// ## Examples
///
/// ```gleam
/// let report = vm_link.reload_report("dev", vm_link.PredatesReload)
/// assert report.old_path == vm_link.OldPathRuns
/// ```
pub fn reload_report(name: String, result: ReloadResult) -> ReloadReport {
  case result {
    Answered(reply:) ->
      ReloadReport(
        lines: changed_lines(reply),
        old_path: case own_change(name, reply) {
          Some(executor_reload.Failed) | Some(executor_reload.Stopped) | None ->
            OldPathRuns
          Some(executor_reload.Started)
          | Some(executor_reload.Restarted)
          | Some(executor_reload.Unchanged) -> OldPathSkipped
        },
      )
    PredatesReload -> ReloadReport(lines: [], old_path: OldPathRuns)
    RefusedReload(code:, message:) ->
      ReloadReport(
        lines: [
          "Your daemon refused to reload its executors ("
          <> option.unwrap(message, code)
          <> ").",
        ],
        old_path: OldPathRuns,
      )
    NoAnswer(reason:) ->
      ReloadReport(
        lines: [
          "Your daemon did not answer the request to reload its executors ("
          <> reason
          <> ").",
        ],
        old_path: OldPathRuns,
      )
  }
}

/// The report for the reload `rm` sends after it took a guest's row out of the
/// file. The guest's own entry is `stopped` in a reply, or absent when the
/// daemon never held it, and neither leaves a daemon to restart; only a
/// `failed` entry does. A daemon that predates the command needs nothing from
/// `rm` beyond the notice `rm` has always printed, so it has no lines here.
/// `OldPathRuns` means that notice is still printed.
///
/// ## Examples
///
/// ```gleam
/// let result = vm_link.Answered(executor_reload.Reply([]))
/// assert vm_link.removal_report("dev", result).old_path == vm_link.OldPathSkipped
/// ```
pub fn removal_report(name: String, result: ReloadResult) -> ReloadReport {
  case result {
    Answered(reply:) ->
      ReloadReport(
        lines: changed_lines(reply),
        old_path: case own_change(name, reply) {
          Some(executor_reload.Failed) -> OldPathRuns
          Some(_) | None -> OldPathSkipped
        },
      )
    PredatesReload | RefusedReload(..) | NoAnswer(..) ->
      reload_report(name, result)
  }
}

/// The change the reply names for `name`, if it lists it.
fn own_change(
  name: String,
  reply: executor_reload.Reply,
) -> Option(executor_reload.Change) {
  list.find(reply.executors, fn(entry) { entry.name == name })
  |> result.map(fn(entry) { entry.change })
  |> option.from_result
}

/// One line for every entry of the reply that is not `unchanged`.
fn changed_lines(reply: executor_reload.Reply) -> List(String) {
  list.filter_map(reply.executors, fn(entry) {
    let who = "untrusted executor " <> entry.name

    // Each change that happened is one sentence; an unchanged row is silent.
    case entry.change {
      executor_reload.Unchanged -> Error(Nil)
      executor_reload.Started ->
        Ok("Your daemon started its link to " <> who <> ".")
      executor_reload.Restarted ->
        Ok("Your daemon restarted its link to " <> who <> ".")
      executor_reload.Stopped ->
        Ok("Your daemon stopped its link to " <> who <> ", whose row is gone.")
      executor_reload.Failed ->
        Ok(
          "Your daemon could not bring its link to "
          <> who
          <> " to match the file, and the next reload tries again.",
        )
    }
  })
}

/// The names of the executor rows a daemon's `deployment.status` body lists
/// under `placements.executors`, or none when the body has no such list, which
/// is a daemon that does not answer the read in full.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.listed_executors(core_json.Object([])) == None
/// ```
pub fn listed_executors(body: core_json.JsonValue) -> Option(List(String)) {
  // The list is two objects down; anything else is no answer.
  case body {
    core_json.Object(fields) ->
      case list.key_find(fields, "placements") {
        Ok(core_json.Object(placements)) ->
          case list.key_find(placements, "executors") {
            Ok(core_json.Array(entries)) ->
              Some(list.filter_map(entries, name_of))
            _ -> None
          }
        _ -> None
      }
    _ -> None
  }
}

/// The `name` of one executor entry.
fn name_of(entry: core_json.JsonValue) -> Result(String, Nil) {
  case entry {
    core_json.Object(fields) ->
      case list.key_find(fields, "name") {
        Ok(core_json.String(name)) -> Ok(name)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// --- what the developer is told ------------------------------------------------------

/// The lines `up` ends with about the daemon after it changed the guest's row.
/// What `up` says when a reload could not make the daemon read the row: a
/// daemon that predates the command, refused it, or did not answer reads its
/// rows only at its start, so an idle one was stopped by the same step `up`
/// takes for a newly installed deployment and a busy one is named the command
/// that stops it.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.daemon_lines("dev", vm_spec.NoDaemon) != []
/// ```
pub fn daemon_lines(name: String, outcome: DaemonOutcome) -> List(String) {
  vm_spec.daemon_note_about(
    outcome,
    "the guest's row",
    "It has not read [executors."
      <> name
      <> "], so it must restart to reach the guest.",
    vm_spec.Installed,
  )
}

/// The `status` lines about a guest's link. A guest on the untrusted link has
/// no node name and no epmd entry, so these replace those two lines with the
/// kind, and the address and pin its row holds.
///
/// ## Examples
///
/// ```gleam
/// assert vm_link.status_lines(Some(41_000), Some(pin)) != []
/// ```
pub fn status_lines(port: Option(Int), pin: Option(String)) -> List(String) {
  let where_ =
    option.map(port, address) |> option.unwrap("no port recorded yet")
  let leaf = option.unwrap(pin, "no certificate yet")
  [
    "link:       untrusted, TLS to " <> where_,
    "pin:        " <> leaf,
  ]
}
