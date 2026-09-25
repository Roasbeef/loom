//// The profile tier (ADR-014 §3), end to end through the extension
//// pipeline: the manifest's two tiers and every refusal that keeps them
//// apart, the `[[check]]` decoder, an install that never vets and never
//// builds, record format 3 and the format-2 records it still reads, and a
//// load that re-derives the approved profiles.
////
//// Every install here uses a fetcher and a build seam that fail the test
//// if they are called at all. A profile extension runs nothing, so the
//// property worth proving is not that the fakes were well behaved but that
//// the pipeline never reached for them.

import client/extension/archive
import client/extension/cli
import client/extension/install
import client/extension/installed
import client/extension/manifest
import client/extension/record
import client/extension/source
import client/lsp/profile
import codemode/compile
import core/clock
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support/extensions
import tom

const at_ms = 1_700_000_000_000

// --- the manifest: the profile tier ----------------------------------------

pub fn a_profile_manifest_decodes_test() {
  let assert Ok(decoded) = decode(extensions.profile_go())
    as "the profile fixture's manifest must decode"
  assert decoded.tier == manifest.Profile
  assert decoded.tools == []
  assert decoded.hooks == []
  assert decoded.net == manifest.no_net()
  assert list.map(decoded.lsp, fn(server) { server.name }) == ["go"]
  let assert [go] = decoded.lsp as "one [lsp.go] table"
  assert go.command == ["gopls"]
  assert go.writable
    == [profile.CachePath("go-build"), profile.CachePath("gopls")]
  assert go.hint == Some("Qualify as package.Name")
  assert decoded.checks
    == [
      manifest.Check(
        server: "go",
        fixture: "fixture",
        query: manifest.Definition,
        symbol: "util.Greet",
        path: None,
        line: None,
        expect: [manifest.Site(path: "util/util.go", line: 3)],
      ),
    ]
}

/// The mutation this pins: a profile decoder that let `[[tool]]` through
/// would install a tool nothing ever registers.
pub fn a_profile_refuses_a_tool_test() {
  let assert Error(reason) =
    decode_profile(
      extensions.profile_manifest()
      <> "\n[[tool]]\nname = \"t\"\ndescription = \"d\"\n"
      <> "prompt_snippet = \"t\"\nparameters = \"schema/t.json\"\n"
      <> "entry = \"t/tool\"\ntimeout_ms = 1000\n",
    )
    as "a profile extension runs no code"
  assert reason == "a profile extension runs no code; [[tool]] is not allowed"
}

pub fn a_profile_refuses_a_hook_test() {
  let assert Error(reason) =
    decode_profile(
      extensions.profile_manifest()
      <> "\n[[hook]]\nevent = \"tool_call\"\nentry = \"t/hook\"\n",
    )
    as "a profile extension subscribes to nothing"
  assert reason == "a profile extension runs no code; [[hook]] is not allowed"
}

pub fn a_profile_refuses_a_net_table_test() {
  let assert Error(reason) =
    decode_profile(
      extensions.profile_manifest()
      <> "\n[net]\nhosts = [\"example.com\"]\nmethods = [\"GET\"]\n"
      <> "max_response_bytes = 1024\nrequests_per_call = 1\n",
    )
    as "a profile extension reaches no host"
  assert reason == "a profile extension runs no code; [net] is not allowed"
}

pub fn a_profile_needs_a_server_test() {
  let header = profile_header()
  let assert Error(absent) = decode_profile(header)
    as "a profile with no [lsp] table ships nothing"
  assert absent == "a profile extension declares at least one [lsp.<name>]"
  let assert Error(empty) = decode_profile(header <> "\n[lsp]\n")
    as "an empty [lsp] table ships nothing either"
  assert empty == absent
  let assert Error(scalar) = decode_profile("lsp = 3\n" <> header)
    as "[lsp] must be a table"
  assert scalar == "lsp must be a table of [lsp.<name>] entries"
}

/// One decoder for both files: the refusal a bad table earns in a
/// manifest is, word for word, the one `loom.toml` gives.
pub fn a_bad_profile_is_refused_as_loom_toml_refuses_it_test() {
  let table =
    "[go]\ncommand = \"gopls serve\"\nextensions = [\".go\"]\n"
    <> "root_markers = [\"go.mod\"]\n"
  let assert Ok(tables) = tom.parse(table) as "the table parses"
  let assert Error(expected) = profile.decode_servers(tables)
    as "a shell-string command is refused by the shared decoder"
  let assert Error(reason) =
    decode_profile(profile_header() <> "\n[lsp.go]\n" <> strip_head(table))
    as "the manifest refuses it too"
  assert reason == expected
  assert string.contains(reason, "lsp.go.command is a string")
}

pub fn a_profile_refuses_two_servers_claiming_one_extension_test() {
  let assert Error(reason) =
    decode_profile(
      extensions.profile_manifest()
      <> "\n[lsp.other]\ncommand = [\"other\"]\nextensions = [\".go\"]\n"
      <> "root_markers = [\"go.mod\"]\n",
    )
    as "one extension has one owner, in a manifest as in loom.toml"
  assert string.contains(reason, "both claim .go")
}

// --- the manifest: the jailed tier -----------------------------------------

pub fn a_jailed_extension_refuses_a_profile_test() {
  let assert Error(reason) =
    decode(
      with(extensions.hello(), "extension.toml", fn(text) {
        text
        <> "\n[lsp.go]\ncommand = [\"gopls\"]\nextensions = [\".go\"]\n"
        <> "root_markers = [\"go.mod\"]\n"
      }),
    )
    as "a jailed extension carries no language profile"
  assert string.contains(reason, "[lsp]")
  assert string.contains(reason, "tier = \"profile\"")
}

pub fn a_jailed_extension_refuses_a_check_test() {
  let assert Error(reason) =
    decode(
      with(extensions.hello(), "extension.toml", fn(text) {
        text
        <> "\n[[check]]\nserver = \"go\"\nquery = \"definition\"\n"
        <> "symbol = \"x\"\nexpect = [\"a.go:1\"]\n"
      }),
    )
    as "a jailed extension has no profile to check"
  assert string.contains(reason, "[[check]]")
  assert string.contains(reason, "tier = \"profile\"")
}

pub fn a_jailed_extension_still_needs_a_tool_test() {
  let assert Error(reason) =
    decode([
      #(
        "extension.toml",
        "[extension]\nname = \"bare\"\nversion = \"0.1.0\"\n"
          <> "description = \"d\"\nlicense = \"MIT\"\ntier = \"jailed\"\n",
      ),
    ])
    as "a jailed extension registers at least one tool"
  assert reason == "an extension registers at least one [[tool]]"
}

pub fn an_unknown_tier_names_both_tiers_test() {
  let assert Error(reason) =
    decode_profile(string.replace(
      profile_header(),
      "tier = \"profile\"",
      "tier = \"data\"",
    ))
    as "an unknown tier is refused naming what is installable"
  assert string.contains(reason, "\"data\"")
  assert string.contains(reason, "\"jailed\" and \"profile\"")
}

pub fn the_declared_tier_is_read_alone_test() {
  assert manifest.declared_tier(extensions.profile_manifest())
    == Ok(manifest.Profile)
  assert manifest.declared_tier(extensions.named_manifest("w"))
    == Ok(manifest.Jailed)
  let assert Error(_) = manifest.declared_tier("not = [toml")
    as "text that does not parse names no tier"
}

// --- the manifest: [[check]] ------------------------------------------------

pub fn a_full_check_decodes_test() {
  let assert Ok(decoded) =
    decode_checks(
      "server = \"go\"\nfixture = \"fixture/util\"\nquery = \"references\"\n"
      <> "symbol = \"Greet\"\npath = \"util.go\"\nline = 3\n"
      <> "expect = [\"util.go:3\", \"a/b.go:10\"]\n",
    )
    as "every key a check takes"
  assert decoded.checks
    == [
      manifest.Check(
        server: "go",
        fixture: "fixture/util",
        query: manifest.References,
        symbol: "Greet",
        path: Some("util.go"),
        line: Some(3),
        expect: [
          manifest.Site(path: "util.go", line: 3),
          manifest.Site(path: "a/b.go", line: 10),
        ],
      ),
    ]
}

pub fn a_check_is_refused_by_name_test() {
  let base = "query = \"definition\"\nsymbol = \"x\"\nexpect = [\"a.go:1\"]\n"
  let refused = fn(fields) {
    let assert Error(reason) = decode_checks(fields)
      as "every one of these checks is malformed"
    reason
  }

  // The server must be one of this manifest's own.
  assert refused("server = \"rust\"\n" <> base)
    == "[[check]] 1.server names rust, which is not one of this manifest's"
    <> " [lsp] servers (go)"

  // The fixture must hold a file, and be a path inside the tree.
  assert string.contains(
    refused("server = \"go\"\nfixture = \"absent\"\n" <> base),
    "[[check]] 1.fixture names absent, which holds no file",
  )
  assert string.contains(
    refused("server = \"go\"\nfixture = \"../fixture\"\n" <> base),
    "which has an empty, . or .. component",
  )
  assert string.contains(
    refused("server = \"go\"\nfixture = \"/etc\"\n" <> base),
    "which is absolute",
  )

  // A line needs a path, and counts from one.
  assert refused("server = \"go\"\nline = 3\n" <> base)
    == "[[check]] 1.line needs a path: a line is a position in one file"
  assert string.contains(
    refused("server = \"go\"\npath = \"a.go\"\nline = 0\n" <> base),
    "lines count from 1",
  )

  // The query is one of two.
  assert string.contains(
    refused(
      "server = \"go\"\nquery = \"hover\"\nsymbol = \"x\"\n"
      <> "expect = [\"a.go:1\"]\n",
    ),
    "\"definition\" or \"references\"",
  )

  // An unknown key is refused, as everywhere in the manifest.
  assert string.contains(
    refused("server = \"go\"\ntimeout = 3\n" <> base),
    "[[check]] 1 does not take timeout",
  )
}

pub fn an_expectation_is_refused_by_name_test() {
  let with_expect = fn(expect) {
    let assert Error(reason) =
      decode_checks(
        "server = \"go\"\nquery = \"definition\"\nsymbol = \"x\"\n"
        <> "expect = "
        <> expect
        <> "\n",
      )
      as "every one of these expectations is malformed"
    reason
  }
  assert with_expect("[]")
    == "[[check]] 1.expect must list at least one path:line site"
  assert string.contains(with_expect("[\"util.go\"]"), "is not a path:line")
  assert string.contains(with_expect("[\"util.go:x\"]"), "is not a path:line")
  assert string.contains(with_expect("[\"util.go:0\"]"), "a line below 1")
  assert string.contains(with_expect("[\"../x.go:1\"]"), ".. component")
  assert string.contains(with_expect("[\"/x.go:1\"]"), "which is absolute")
}

// --- the install -------------------------------------------------------------

/// The mutation this pins is the one the whole tier exists for: a profile
/// install that reached for the compiler would need a toolchain it never
/// uses. `never_build` fails the test if the seam is called.
pub fn a_profile_installs_without_vetting_or_building_test() {
  let #(root, done) = installed_profile("profile-install")
  assert done.record.tier == manifest.Profile
  assert done.record.format == record.format_version
  assert done.record.lsp == done.manifest.lsp
  assert done.record.tools == []
  assert done.record.hooks == []
  assert done.record.allowlist == []
  assert done.record.manifest_hash == ""
  assert done.record.artifact == ""

  // No artifact directory, and the source is the pruned tree: the stray
  // `.gleam` file and the docs never land.
  assert !exists(record.artifact_at(root, "lsp_go"))
  let assert Ok(tree) =
    archive.from_directory(
      record.sources(root, "lsp_go"),
      archive.default_caps(),
    )
    as "the installed tree must be readable"
  assert list.map(tree.files, fn(file) { file.path })
    == extensions.profile_paths()
  assert archive.digest(tree) == done.record.tree_digest
}

pub fn the_install_prints_what_was_approved_test() {
  let #(_root, done) = installed_profile("profile-lines")
  let lines = cli.installed_lines(done)
  let printed = string.join(lines, "\n")
  assert list.first(lines) == Ok("installed lsp_go 0.1.0 at local")
  assert string.contains(printed, "lsp.go")
  assert string.contains(printed, "command:    \"gopls\"")
  assert string.contains(printed, "extensions: .go")
  assert string.contains(printed, "project:    read-only")
  assert string.contains(printed, "readable:   ~/go/pkg/mod")
  assert string.contains(printed, "writable:   <cache>/go-build, <cache>/gopls")
  assert string.contains(printed, "env:        GOFLAGS")
  assert string.contains(printed, "hint:       \"Qualify as package.Name\"")
  assert !string.contains(printed, "jail:")
}

/// The CLI's own proof that a profile needs no toolchain: the helper and
/// the seed it is pointed at do not exist, so any attempt to start a build
/// plane would refuse the install.
pub fn the_cli_installs_a_profile_with_no_toolchain_test() {
  let home = extensions.scratch("profile-cli")
  let tree =
    extensions.materialise(
      extensions.profile_go(),
      extensions.scratch("profile-cli-src"),
    )
  let assert Ok(lines) =
    cli.dispatch([
      "install", tree, "--home", home, "--helper", "/nonexistent/helper",
      "--codemode-seed", "/nonexistent/seed",
    ])
    as "a profile installs where no build plane could start"
  assert list.first(lines) == Ok("installed lsp_go 0.1.0 at local")
  assert cli.dispatch(["list", "--home", home])
    == Ok(["lsp_go  0.1.0  local  lsp: go (.go)"])
  let assert Ok([_summary, "ok"]) =
    cli.dispatch(["verify", "lsp_go", "--home", home])
    as "a fresh profile install verifies"
}

// --- the record --------------------------------------------------------------

pub fn a_profile_record_round_trips_test() {
  let #(_root, done) = installed_profile("profile-record")
  let text = json.to_string(record.encode(done.record))
  assert record.readable(text) == Ok(done.record)
  assert record.format_version == 3
}

/// A format-2 record was written before profiles existed, so it can only
/// be a jailed extension with none, and is read as exactly that.
pub fn a_format_two_record_reads_as_jailed_test() {
  let assert Ok(read) = record.readable(format_two_record())
    as "a format-2 record is still read"
  assert read.format == record.legacy_format_version
  assert read.tier == manifest.Jailed
  assert read.lsp == []
  assert read.tools == ["hello"]
  assert record.current(read) == Ok(read)
}

pub fn every_other_format_is_refused_test() {
  assert record.readable("{\"format\": 1}")
    == Error("the install record is format 1; this server reads 2 or 3")
  assert record.readable("{\"format\": 4}")
    == Error("the install record is format 4; this server reads 2 or 3")
}

pub fn a_format_three_record_needs_its_profiles_test() {
  let without =
    string.replace(format_two_record(), "\"format\":2", "\"format\":3")
  let assert Error(reason) = record.readable(without)
    as "a format-3 record missing tier and lsp is corrupt"
  assert string.contains(reason, "tier")
}

pub fn a_recorded_profile_with_a_bad_root_is_refused_test() {
  let #(_root, done) = installed_profile("profile-bad-root")
  let text =
    json.to_string(record.encode(done.record))
    |> string.replace("~/go/pkg/mod", "go/pkg/mod")
  let assert Error(_reason) = record.readable(text)
    as "a relative root cannot be a recorded grant"
}

// --- the load ----------------------------------------------------------------

pub fn discovery_loads_a_profile_test() {
  let #(root, done) = installed_profile("profile-discover")
  let assert [installed.Ready(record: written, manifest: decoded, artifact:)] =
    installed.discover(root)
    as "the profile extension loads"
  assert written == done.record
  assert decoded.tier == manifest.Profile
  assert artifact == ""
}

/// An edited manifest is caught by the digest first, which is the refusal
/// this test asserts.
pub fn an_edited_profile_is_refused_on_the_digest_test() {
  let #(root, _done) = installed_profile("profile-edit-manifest")
  edit(record.sources(root, "lsp_go") <> "/extension.toml", fn(text) {
    string.replace(text, "command = [\"gopls\"]", "command = [\"sh\"]")
  })
  assert refusal(root) == digest_refusal
}

/// An edited record, by contrast, passes the digest (the tree did not
/// move) and is caught by the profile comparison. The mutation this pins:
/// a load that skipped the comparison would start the record's `sh`.
pub fn an_edited_record_is_refused_on_the_profiles_test() {
  let #(root, _done) = installed_profile("profile-edit-record")
  edit(record.file(root, "lsp_go"), fn(text) {
    string.replace(text, "[\"gopls\"]", "[\"sh\"]")
  })
  assert refusal(root) == profile_refusal
}

/// Both edited, with the record's digest rewritten to match the edited
/// tree: the digest passes, and the profiles still do not match the
/// approval.
pub fn a_tree_and_digest_edited_together_are_refused_on_the_profiles_test() {
  let #(root, done) = installed_profile("profile-edit-both")
  edit(record.sources(root, "lsp_go") <> "/extension.toml", fn(text) {
    string.replace(text, "command = [\"gopls\"]", "command = [\"sh\"]")
  })
  let assert Ok(tree) =
    archive.from_directory(
      record.sources(root, "lsp_go"),
      archive.default_caps(),
    )
    as "the edited tree must be readable"
  edit(record.file(root, "lsp_go"), fn(text) {
    string.replace(text, done.record.tree_digest, archive.digest(tree))
  })
  assert refusal(root) == profile_refusal
}

/// A record cannot talk a tree out of its tier's checks: flipping a
/// profile's record to `jailed` is refused before any tier-specific check
/// runs. The other direction, which is the one that would skip vetting,
/// is `extension_test`'s `a_jailed_record_claiming_the_profile_tier_...`.
pub fn a_record_naming_the_wrong_tier_is_refused_test() {
  let #(root, _done) = installed_profile("profile-flip")
  edit(record.file(root, "lsp_go"), fn(text) {
    string.replace(text, "\"tier\":\"profile\"", "\"tier\":\"jailed\"")
  })
  assert refusal(root) == tier_refusal
}

// --- the summary -------------------------------------------------------------

pub fn a_profile_summary_names_its_servers_test() {
  let #(root, _done) = installed_profile("profile-summary")
  let assert [found] = installed.discover(root) as "one install"
  assert installed.summarise(found) == "lsp_go  0.1.0  local  lsp: go (.go)"

  let assert installed.Ready(record: written, manifest: decoded, artifact:) =
    found
    as "the install loads"
  let assert [go] = decoded.lsp as "one server"
  let rust =
    profile.LspServer(..go, name: "rust", extensions: [".rs"], command: [
      "rust-analyzer",
    ])
  let two = manifest.Manifest(..decoded, lsp: [go, rust])
  assert installed.summarise(installed.Ready(
      record: written,
      manifest: two,
      artifact:,
    ))
    == "lsp_go  0.1.0  local  lsp: go (.go), rust (.rs)"
}

// --- helpers -----------------------------------------------------------------

const digest_refusal = "the installed source no longer matches the install record; reinstall it to approve what is there now"

const profile_refusal = "the manifest's language profiles no longer match the install record; reinstall it to approve what is there now"

const tier_refusal = "the manifest's tier no longer matches the install record; reinstall it to approve what is there now"

fn decode(files: List(#(String, String))) -> Result(manifest.Manifest, String) {
  let assert Ok(text) = list.key_find(files, "extension.toml")
    as "every fixture carries a manifest"
  manifest.decode(text, surroundings(files))
}

fn surroundings(files: List(#(String, String))) -> manifest.Surroundings {
  manifest.Surroundings(files:, modules: [])
}

// The profile fixture with its manifest replaced.
fn decode_profile(text: String) -> Result(manifest.Manifest, String) {
  decode(with(extensions.profile_go(), "extension.toml", fn(_old) { text }))
}

// The profile fixture's manifest with one `[[check]]` of these fields in
// place of its own.
fn decode_checks(fields: String) -> Result(manifest.Manifest, String) {
  let assert Ok(#(head, _check)) =
    string.split_once(extensions.profile_manifest(), "[[check]]")
    as "the fixture carries one check"
  decode_profile(head <> "[[check]]\n" <> fields)
}

// `[extension]` alone, naming the profile tier.
fn profile_header() -> String {
  let assert Ok(#(head, _rest)) =
    string.split_once(extensions.profile_manifest(), "[lsp.go]")
    as "the fixture carries [lsp.go]"
  head
}

// A TOML snippet's `[go]` header line removed, leaving its keys.
fn strip_head(table: String) -> String {
  string.replace(table, "[go]\n", "")
}

fn with(
  files: List(#(String, String)),
  path: String,
  change: fn(String) -> String,
) -> List(#(String, String)) {
  list.map(files, fn(file) {
    case file.0 == path {
      True -> #(file.0, change(file.1))
      False -> file
    }
  })
}

fn installed_profile(name: String) -> #(record.Root, install.Installed) {
  let root = record.root_for(extensions.scratch(name))
  let tree =
    extensions.materialise(
      extensions.profile_go(),
      extensions.scratch(name <> "-src"),
    )
  let assert Ok(done) =
    install.run(config(root), source.LocalPath(path: tree), rev: None)
    as "the profile fixture must install"
  #(root, done)
}

fn config(root: record.Root) -> install.Config {
  install.Config(
    root:,
    caps: archive.default_caps(),
    fetch: never_fetch,
    build: never_build,
    clock: clock.fixed(at: at_ms),
    entropy: fn() { 7 },
    approved_by: "operator",
  )
}

fn never_fetch(_url: String, _max: Int) -> Result(BitArray, String) {
  panic as "the pipeline fetched a URL while installing a local source"
}

fn never_build(_root: String) -> compile.Built {
  panic as "a profile install called the build seam"
}

fn refusal(root: record.Root) -> String {
  let assert installed.Refused(name: "lsp_go", reason:) =
    installed.one(root, "lsp_go")
    as "the tampered install must be refused"
  reason
}

fn edit(path: String, change: fn(String) -> String) -> Nil {
  let assert Ok(text) = simplifile.read(from: path) as "the file must exist"
  let changed = change(text)
  assert changed != text
  let assert Ok(Nil) = simplifile.write(to: path, contents: changed)
    as "the file must be writable"
  Nil
}

fn exists(path: String) -> Bool {
  case simplifile.is_directory(path) {
    Ok(True) -> True
    Ok(False) | Error(_) -> False
  }
}

// A record as a format-2 server wrote it: no `tier` and no `lsp`.
fn format_two_record() -> String {
  "{\"format\":2,\"name\":\"hello\",\"version\":\"0.1.0\","
  <> "\"source\":\"./hello\",\"revision\":\"local\",\"tree_digest\":\"t\","
  <> "\"manifest_hash\":\"m\",\"allowlist\":[\"cap/ext\"],"
  <> "\"net\":{\"hosts\":[],\"methods\":[],\"max_response_bytes\":0,"
  <> "\"requests_per_call\":0,\"secret_env\":[]},"
  <> "\"tools\":[\"hello\"],\"hooks\":[],"
  <> "\"approved_at\":\"1970-01-01T00:00:00Z\",\"approved_by\":\"o\","
  <> "\"artifact\":\"artifact\"}"
}
