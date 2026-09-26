//// The install record: the approval, written down.
////
//// `client/catalog` makes the operator's trust decision by *implication*
//// — an operator editing `loom.toml` and restarting the server is the
//// decision. An extension is code, from somebody else's repository, so
//// the same posture with one difference the design note names: the
//// approval is recorded rather than implied. This module is that record.
////
//// # What a record is for
////
//// Two jobs, and the second is the one that shapes the type.
////
//// 1. **It says an operator approved this.** Who, when, from where, at
////    which revision. `loom.toml` gains nothing per extension, so this
////    file is the only place the approval exists.
//// 2. **It says what was approved.** The tree digest, the manifest hash,
////    the allowlist the source was vetted against, and the net policy the
////    broker will compose from. Every later load re-derives all four from
////    what is on disk and refuses the extension when they disagree, so an
////    install is content-addressed from the moment it is written —
////    whatever the remote does afterwards, and whatever edits the
////    directory later. A profile extension (ADR-014 §3) has no allowlist,
////    artifact or net policy to approve; what it has instead is the
////    language profiles themselves, kept in full beside the tier.
////
//// The allowlist and the net policy are *stored* rather than recomputed
//// because they are the terms of the approval. Recomputing them at load
//// would mean an operator's yes silently followed the harness's current
//// idea of the seam; storing them means a widened seam shows up as a
//// record that no longer matches, which is a question rather than a
//// change made on somebody's behalf.
////
//// # Secrets are names here too
////
//// The record carries the *names* of the environment variables the
//// manifest's secret bindings point at, never their values. Same rule as
//// `api_key_env`, one layer further out: the value lives in the server's
//// environment and appears in no file at all.
////
//// # The layout, and why staging exists
////
//// ```
//// <root>/<name>/install.json     the record
//// <root>/<name>/src/…            the vetted tree, byte for byte
//// <root>/<name>/artifact/        the compiled beam set (jailed tier only)
//// <root>/.staging/<random>/      where an install happens
//// ```
////
//// An install writes into staging and renames into place *after* the
//// record exists, so a directory under `<root>/<name>` is either a
//// complete install or absent. Every failure removes its staging
//// directory; a rename is the one step that is not undoable, and it is
//// last.

import client/extension/manifest.{type Manifest, type Tier}
import client/extension/source.{type Source}
import client/lsp/profile.{type LspServer}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp

/// The file an install record is written to, inside an extension's own
/// directory.
pub const record_file = "install.json"

/// The directory an extension's vetted source is kept in.
pub const source_directory = "src"

/// The directory an extension's compiled beam set is kept in.
pub const artifact_directory = "artifact"

/// The directory installs are staged in, beneath the root.
pub const staging_directory = ".staging"

/// The record format's own version. Bumped when the shape changes, so a
/// record written by an older server is refused by name rather than
/// half-decoded.
///
/// Version 2 added `hooks`. A version-1 record is refused rather than
/// read with an empty hook list, because the approval a record carries
/// is "what was approved", and a record written before hooks existed
/// cannot say whether the operator approved any — the honest answer is
/// to ask them again. The cost is one `loom ext install` per installed
/// extension, and extensions have shipped in exactly one phase.
///
/// Version 3 added `tier` and `lsp` (ADR-014 §3). A version-2 record is
/// still read, as `legacy_format_version`, and the reasoning that refused
/// version 1 is what admits it: a format-2 record cannot hold a profile,
/// so reading it as a jailed extension with none loses nothing the
/// operator approved and forces no reinstall.
pub const format_version = 3

/// The one older format this build still reads: a jailed extension's
/// record from before profiles existed.
pub const legacy_format_version = 2

/// The revision a local path records: it has none, and saying so is a
/// fact about the install rather than a missing value.
pub const local_revision = "local"

/// The revision a fetched archive records when it carried no commit and
/// the operator named none. The URL is then the whole of the pin, which
/// is worth reading differently from `local`.
pub const unpinned_revision = "unpinned"

/// The extensions root: `<home>/.loom/extensions`.
///
/// A value rather than an environment read inside the pipeline, for the
/// reason `Settings.home` is a field rather than a `getenv` inside the
/// prompt render: a pipeline that read `HOME` itself would be untestable
/// and would answer differently depending on who ran it.
pub opaque type Root {
  Root(path: String)
}

/// The net policy a record remembers, with the secret *names* and no
/// values.
pub type NetTerms {
  NetTerms(
    hosts: List(String),
    methods: List(String),
    max_response_bytes: Int,
    requests_per_call: Int,
    secret_env: List(String),
  )
}

/// One installed extension, as recorded at install.
pub type Record {
  Record(
    /// The record format's version: `format_version` for a record this
    /// build wrote, `legacy_format_version` for one read from before
    /// profiles.
    format: Int,
    /// Which tier was approved. `Jailed` for a format-2 record.
    tier: Tier,
    /// The extension's name, which is also its directory.
    name: String,
    /// The version its manifest declared.
    version: String,
    /// The source exactly as the operator gave it.
    source: String,
    /// The revision that was resolved: an archive's commit, the `--rev`,
    /// or `local`.
    revision: String,
    /// A content address over the extracted tree.
    tree_digest: String,
    /// A content address over the compiled artifact. Empty for a
    /// profile extension, which compiles nothing.
    manifest_hash: String,
    /// The module names the source was vetted against. Empty for a
    /// profile extension, which is not vetted.
    allowlist: List(String),
    /// The net policy the source was approved with.
    net: NetTerms,
    /// The tools the manifest registers.
    tools: List(String),
    /// The hooks the manifest registers, as `#(event, entry)` in the
    /// manifest's own order. Stored for the reason the allowlist is: a
    /// hook is authority over the harness's own timeline, so the events
    /// an operator approved are part of the approval rather than
    /// something re-read from a file that may have changed.
    hooks: List(#(String, String)),
    /// The language profiles a profile extension ships, in full and in
    /// the manifest's (name) order. Stored for the reason the hooks are:
    /// a profile names a binary the harness runs in a jail and the roots
    /// that jail grants, so the grant is part of the approval rather than
    /// something re-read from a file that may have changed. Empty for a
    /// jailed extension and for a format-2 record.
    lsp: List(LspServer),
    /// When the approval happened, RFC3339 UTC.
    approved_at: String,
    /// Who approved it: the `USER` environment, or `unknown`.
    approved_by: String,
    /// The directory holding the compiled beam set. Empty for a profile
    /// extension, which has none.
    artifact: String,
  )
}

/// Builds the extensions root under a home directory.
///
/// ## Examples
///
/// ```gleam
/// assert record.path(record.root_for("/home/o")) == "/home/o/.loom/extensions"
/// ```
///
pub fn root_for(home: String) -> Root {
  Root(path: trim(home) <> "/.loom/extensions")
}

/// Builds a root at an exact path, for a `--home` override and for tests.
///
/// ## Examples
///
/// ```gleam
/// assert record.path(record.root_at("/tmp/x")) == "/tmp/x"
/// ```
///
pub fn root_at(path: String) -> Root {
  Root(path: trim(path))
}

/// The root's own directory.
///
/// ## Examples
///
/// ```gleam
/// assert record.path(record.root_at("/x")) == "/x"
/// ```
///
pub fn path(root: Root) -> String {
  root.path
}

/// Where one extension lives.
///
/// ## Examples
///
/// ```gleam
/// assert record.directory(record.root_at("/x"), "w") == "/x/w"
/// ```
///
pub fn directory(root: Root, name: String) -> String {
  root.path <> "/" <> name
}

/// Where one extension's record file lives.
///
/// ## Examples
///
/// ```gleam
/// assert record.file(record.root_at("/x"), "w") == "/x/w/install.json"
/// ```
///
pub fn file(root: Root, name: String) -> String {
  directory(root, name) <> "/" <> record_file
}

/// Where one extension's compiled beam set lives.
///
/// A function rather than a field read off the record, because the record
/// stores the directory's *name* and a caller needs its path — and the
/// path is a fact about the root, which the record does not carry.
///
/// ## Examples
///
/// ```gleam
/// assert record.artifact_at(record.root_at("/x"), "w") == "/x/w/artifact"
/// ```
///
pub fn artifact_at(root: Root, name: String) -> String {
  directory(root, name) <> "/" <> artifact_directory
}

/// Where one extension's vetted source lives.
///
/// ## Examples
///
/// ```gleam
/// assert record.sources(record.root_at("/x"), "w") == "/x/w/src"
/// ```
///
pub fn sources(root: Root, name: String) -> String {
  directory(root, name) <> "/" <> source_directory
}

/// Where an install stages before it is renamed into place.
///
/// ## Examples
///
/// ```gleam
/// assert record.staging(record.root_at("/x"), "7f") == "/x/.staging/7f"
/// ```
///
pub fn staging(root: Root, token: String) -> String {
  root.path <> "/" <> staging_directory <> "/" <> token
}

/// The net terms a manifest's policy amounts to, with the secret values
/// left where they are.
///
/// ## Examples
///
/// ```gleam
/// assert record.terms(manifest.no_net()).secret_env == []
/// ```
///
pub fn terms(net: manifest.Net) -> NetTerms {
  NetTerms(
    hosts: net.hosts,
    methods: net.methods,
    max_response_bytes: net.max_response_bytes,
    requests_per_call: net.requests_per_call,
    secret_env: list.map(net.secrets, fn(secret) { secret.env }),
  )
}

/// Builds the record an install writes last.
///
/// ## Examples
///
/// ```gleam
/// let written = record.for_install(decoded, from:, revision:, …)
/// assert written.format == record.format_version
/// ```
///
pub fn for_install(
  decoded: Manifest,
  from from: Source,
  revision revision: String,
  tree_digest tree_digest: String,
  manifest_hash manifest_hash: String,
  allowlist allowlist: List(String),
  approved_at approved_at: Int,
  approved_by approved_by: String,
  artifact artifact: String,
) -> Record {
  Record(
    format: format_version,
    tier: decoded.tier,
    name: decoded.name,
    version: decoded.version,
    source: source.describe(from),
    revision:,
    tree_digest:,
    manifest_hash:,
    allowlist:,
    net: terms(decoded.net),
    tools: list.map(decoded.tools, fn(tool) { tool.name }),
    hooks: list.map(decoded.hooks, fn(hook) { #(hook.event, hook.entry) }),
    lsp: decoded.lsp,
    approved_at: instant(approved_at),
    approved_by:,
    artifact:,
  )
}

/// Renders a record as the JSON written to `install.json`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(read) = record.decode(json.to_string(record.encode(written)))
/// assert read == written
/// ```
///
pub fn encode(written: Record) -> Json {
  json.object([
    #("format", json.int(written.format)),
    #("tier", json.string(tier_text(written.tier))),
    #("name", json.string(written.name)),
    #("version", json.string(written.version)),
    #("source", json.string(written.source)),
    #("revision", json.string(written.revision)),
    #("tree_digest", json.string(written.tree_digest)),
    #("manifest_hash", json.string(written.manifest_hash)),
    #("allowlist", json.array(written.allowlist, json.string)),
    #("net", encode_terms(written.net)),
    #("tools", json.array(written.tools, json.string)),
    #("hooks", json.array(written.hooks, encode_hook)),
    #("lsp", json.array(written.lsp, profile.encode_server)),
    #("approved_at", json.string(written.approved_at)),
    #("approved_by", json.string(written.approved_by)),
    #("artifact", json.string(written.artifact)),
  ])
}

// The manifest's own words for the tier, so a record reads the way the
// `extension.toml` it approved does.
fn tier_text(tier: Tier) -> String {
  case tier {
    manifest.Jailed -> manifest.jailed_tier
    manifest.Profile -> manifest.profile_tier
  }
}

fn encode_hook(hook: #(String, String)) -> Json {
  json.object([
    #("event", json.string(hook.0)),
    #("entry", json.string(hook.1)),
  ])
}

fn encode_terms(net: NetTerms) -> Json {
  json.object([
    #("hosts", json.array(net.hosts, json.string)),
    #("methods", json.array(net.methods, json.string)),
    #("max_response_bytes", json.int(net.max_response_bytes)),
    #("requests_per_call", json.int(net.requests_per_call)),
    #("secret_env", json.array(net.secret_env, json.string)),
  ])
}

/// Reads a record back, totally.
///
/// A record is a durability boundary: it is written by one server run and
/// read by every later one, so a missing field, a wrong type, or a format
/// version this build does not know is a refusal naming what it found —
/// never a partial decode and never a crash.
///
/// ## Examples
///
/// ```gleam
/// assert record.decode("{}") == Error("the install record has no name")
/// ```
///
pub fn decode(text: String) -> Result(Record, String) {
  json.parse(from: text, using: decoder())
  |> result.map_error(describe_decode_error)
}

fn decoder() -> Decoder(Record) {
  use format <- decode.field("format", decode.int)
  use #(tier, lsp) <- decode.then(profile_fields(format))
  use name <- decode.field("name", decode.string)
  use version <- decode.field("version", decode.string)
  use source <- decode.field("source", decode.string)
  use revision <- decode.field("revision", decode.string)
  use tree_digest <- decode.field("tree_digest", decode.string)
  use manifest_hash <- decode.field("manifest_hash", decode.string)
  use allowlist <- decode.field("allowlist", decode.list(decode.string))
  use net <- decode.field("net", terms_decoder())
  use tools <- decode.field("tools", decode.list(decode.string))
  use hooks <- decode.field("hooks", decode.list(hook_decoder()))
  use approved_at <- decode.field("approved_at", decode.string)
  use approved_by <- decode.field("approved_by", decode.string)
  use artifact <- decode.field("artifact", decode.string)
  decode.success(Record(
    format:,
    tier:,
    name:,
    version:,
    source:,
    revision:,
    tree_digest:,
    manifest_hash:,
    allowlist:,
    net:,
    tools:,
    hooks:,
    lsp:,
    approved_at:,
    approved_by:,
    artifact:,
  ))
}

// The two fields format 3 added. A format-2 record has neither and is a
// jailed extension with no profiles, which is exactly what it could have
// held; every later format carries both, and a record missing them is a
// decode failure naming the field.
fn profile_fields(format: Int) -> Decoder(#(Tier, List(LspServer))) {
  case format == legacy_format_version {
    True -> decode.success(#(manifest.Jailed, []))
    False -> {
      use tier <- decode.field("tier", tier_decoder())
      use lsp <- decode.field("lsp", decode.list(profile.server_decoder()))
      decode.success(#(tier, lsp))
    }
  }
}

fn tier_decoder() -> Decoder(Tier) {
  use written <- decode.then(decode.string)
  case written {
    "jailed" -> decode.success(manifest.Jailed)
    "profile" -> decode.success(manifest.Profile)
    _other -> decode.failure(manifest.Jailed, "jailed or profile")
  }
}

fn hook_decoder() -> Decoder(#(String, String)) {
  use event <- decode.field("event", decode.string)
  use entry <- decode.field("entry", decode.string)
  decode.success(#(event, entry))
}

fn terms_decoder() -> Decoder(NetTerms) {
  use hosts <- decode.field("hosts", decode.list(decode.string))
  use methods <- decode.field("methods", decode.list(decode.string))
  use max_response_bytes <- decode.field("max_response_bytes", decode.int)
  use requests_per_call <- decode.field("requests_per_call", decode.int)
  use secret_env <- decode.field("secret_env", decode.list(decode.string))
  decode.success(NetTerms(
    hosts:,
    methods:,
    max_response_bytes:,
    requests_per_call:,
    secret_env:,
  ))
}

/// Reads a record this build knows how to read, or says which of the two
/// things went wrong.
///
/// The version is decoded *first*, on its own, and that ordering is the
/// whole of this function. A record written by an older server is
/// missing whatever fields this build added, so the full decoder
/// reaches it before the version check does and reports the missing
/// field — "the install record does not decode: expected List at
/// .hooks" — when the fact an operator needs is "this record is format
/// 1 and this server reads 2 or 3, so reinstall it". Same two failures as
/// `decode` then `current`, in the order that names the right one.
///
/// ## Examples
///
/// ```gleam
/// assert record.readable("{\"format\": 1}")
///   == Error("the install record is format 1; this server reads 2 or 3")
/// ```
///
pub fn readable(text: String) -> Result(Record, String) {
  use Nil <- result.try(
    json.parse(from: text, using: version_decoder())
    |> result.map_error(describe_decode_error)
    |> result.try(known_format),
  )
  decode(text)
}

// The version and nothing else, so a record whose *other* fields this
// build cannot read still answers the version question.
fn version_decoder() -> Decoder(Int) {
  use format <- decode.field("format", decode.int)
  decode.success(format)
}

fn known_format(format: Int) -> Result(Nil, String) {
  case is_known_format(format) {
    True -> Ok(Nil)
    False -> Error(skewed(format))
  }
}

fn is_known_format(format: Int) -> Bool {
  format == format_version || format == legacy_format_version
}

fn skewed(format: Int) -> String {
  "the install record is format "
  <> int.to_string(format)
  <> "; this server reads "
  <> int.to_string(legacy_format_version)
  <> " or "
  <> int.to_string(format_version)
}

/// Refuses a record this build does not know how to read.
///
/// Separate from `decode` because the two failures are different facts:
/// "this file is not a record" is corruption, and "this record was
/// written by a different server" is a version skew an operator fixes by
/// reinstalling.
///
/// ## Examples
///
/// ```gleam
/// assert record.current(Record(..written, format: 99))
///   == Error("the install record is format 99; this server reads 2 or 3")
/// ```
///
pub fn current(written: Record) -> Result(Record, String) {
  case is_known_format(written.format) {
    True -> Ok(written)
    False -> Error(skewed(written.format))
  }
}

/// Renders a Unix-millisecond instant as RFC3339 UTC, the vocabulary the
/// rest of the server already writes times in (`client/schedule`).
///
/// ## Examples
///
/// ```gleam
/// assert record.instant(0) == "1970-01-01T00:00:00Z"
/// ```
///
pub fn instant(at_ms: Int) -> String {
  timestamp.from_unix_seconds(at_ms / 1000)
  |> timestamp.to_rfc3339(duration.seconds(0))
}

fn describe_decode_error(error: json.DecodeError) -> String {
  case error {
    json.UnableToDecode(errors) ->
      "the install record does not decode: "
      <> string.join(fields(errors), ", ")
    json.UnexpectedEndOfInput -> "the install record is truncated"
    json.UnexpectedByte(byte) ->
      "the install record has an unexpected byte " <> byte
    json.UnexpectedSequence(text) ->
      "the install record has an unexpected sequence " <> text
  }
}

fn fields(errors: List(decode.DecodeError)) -> List(String) {
  list.map(errors, fn(error) {
    let decode.DecodeError(expected:, found:, path:) = error
    "expected "
    <> expected
    <> " but found "
    <> found
    <> " at ."
    <> string.join(path, ".")
  })
}

// Drops trailing slashes so `--home /x/` and `--home /x` name one root.
// The length test is against the bound rather than the whole string: a
// path that is only "/" keeps its slash, and nothing else needs counting.
fn trim(path: String) -> String {
  case string.ends_with(path, "/") && string.drop_start(path, 1) != "" {
    True -> trim(string.drop_end(path, 1))
    False -> path
  }
}
