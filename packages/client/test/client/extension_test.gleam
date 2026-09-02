//// The install pipeline, layer by layer: the manifest decoder, package
//// vetting, the install record, the staging discipline, and discovery.
////
//// Every hostile fixture differs from `hello` in exactly one way, so a
//// test here says *which* rule caught it rather than that something did —
//// and every refusal is asserted to name the file or the key, because a
//// refusal an author cannot act on is not much better than no refusal.
////
//// The compile step is feature-detected, the way
//// `packages/codemode/test/codemode/e2e_test.gleam` detects its jail:
//// without a sandbox helper, a toolchain and a prepared seed it prints a
//// skip reason and passes, so `make check` stays fast and hermetic; with
//// them it really builds an extension inside a network-off jail. Every
//// other test injects a fake build, so the pipeline's own discipline —
//// staging, the record, the rename, the digest — is proved on every run.

import broker/exec
import client/extension/archive
import client/extension/cli
import client/extension/install
import client/extension/installed
import client/extension/manifest
import client/extension/record
import client/extension/source
import client/internal/ffi_os
import client/serve
import codemode/build
import codemode/compile
import codemode/enforcement
import codemode/vet/package
import codemode/vet/policy as vet_policy
import core/clock
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support/extensions

const at_ms = 1_700_000_000_000

// --- the manifest decoder -------------------------------------------------

pub fn a_well_formed_manifest_decodes_test() {
  let assert Ok(decoded) = decode(extensions.hello())
    as "the working fixture's manifest must decode"
  assert decoded.name == "hello"
  assert decoded.tier == manifest.Jailed
  assert list.map(decoded.tools, fn(tool) { tool.name }) == ["hello"]
  assert decoded.net == manifest.no_net()
}

/// A tier with no loader is refused naming the tier, not installed and
/// quietly ignored. Phase 4 is what makes `harness` real.
pub fn an_unknown_tier_is_refused_test() {
  let assert Error(reason) = decode(extensions.hostile_tier())
    as "tier = \"harness\" has no loader in phase 1"
  assert string.contains(reason, "harness")
  assert string.contains(reason, "jailed")
}

pub fn an_unknown_key_is_refused_test() {
  let assert Error(reason) = decode(extensions.hostile_key())
    as "an unknown manifest key must be an error"
  assert string.contains(reason, "author")
}

/// A binding for a host the policy does not reach is a contradiction: the
/// key could only ever be sent somewhere the allowlist forbids.
pub fn a_secret_outside_the_allowlist_is_refused_test() {
  let assert Error(reason) = decode(extensions.hostile_secret_host())
    as "a secret for an unlisted host must be refused"
  assert string.contains(reason, "evil.example.net")
  assert string.contains(reason, "hosts")
}

pub fn the_client_table_is_refused_test() {
  let assert Error(reason) =
    decode(
      with(extensions.hello(), "extension.toml", fn(text) {
        text <> "\n[client]\ncommand = \"hello\"\n"
      }),
    )
    as "the [client] table is reserved for a later ruling"
  assert string.contains(reason, "client")
}

pub fn a_bad_name_is_refused_test() {
  let assert Error(reason) =
    decode(
      with(extensions.hello(), "extension.toml", fn(text) {
        string.replace(text, "name = \"hello\"", "name = \"Hello-World\"")
      }),
    )
    as "an extension name is [a-z][a-z0-9_]*"
  assert string.contains(reason, "Hello-World")
}

pub fn a_schema_outside_schema_is_refused_test() {
  let assert Error(reason) =
    decode(
      with(extensions.hello(), "extension.toml", fn(text) {
        string.replace(text, "\"schema/hello.json\"", "\"../etc/passwd\"")
      }),
    )
    as "parameters must name a path under schema/"
  assert string.contains(reason, "schema/")
}

pub fn a_missing_schema_is_refused_test() {
  let assert Error(reason) =
    decode(
      list.filter(extensions.hello(), fn(file) { file.0 != "schema/hello.json" }),
    )
    as "parameters must name a file the tree holds"
  assert string.contains(reason, "schema/hello.json")
}

pub fn an_unparseable_schema_is_refused_test() {
  let assert Error(reason) =
    decode(
      with(extensions.hello(), "schema/hello.json", fn(_text) { "{ not json" }),
    )
    as "a schema the provider would reject must not install"
  assert string.contains(reason, "JSON")
}

pub fn an_entry_naming_no_module_is_refused_test() {
  let assert Error(reason) =
    decode(
      with(extensions.hello(), "extension.toml", fn(text) {
        string.replace(
          text,
          "entry = \"hello/tool\"",
          "entry = \"hello/absent\"",
        )
      }),
    )
    as "entry must name a module src/ holds"
  assert string.contains(reason, "hello/absent")
}

pub fn a_bad_env_name_is_refused_test() {
  let assert Error(reason) =
    decode(
      with(extensions.hostile_secret_host(), "extension.toml", fn(text) {
        text
        |> string.replace("evil.example.net", "api.example.com")
        |> string.replace("EXAMPLE_API_KEY", "example-api-key")
      }),
    )
    as "a secret's env is an environment variable name"
  assert string.contains(reason, "example-api-key")
}

pub fn a_hook_decodes_and_a_bad_event_does_not_test() {
  let good =
    with(extensions.hello(), "extension.toml", fn(text) {
      text <> "\n[[hook]]\nevent = \"tool_call\"\nentry = \"hello/tool\"\n"
    })
  let assert Ok(decoded) = decode(good) as "the hook vocabulary is fixed"
  assert list.map(decoded.hooks, fn(hook) { hook.event }) == ["tool_call"]

  let assert Error(reason) =
    decode(
      with(extensions.hello(), "extension.toml", fn(text) {
        text <> "\n[[hook]]\nevent = \"on_vibes\"\nentry = \"hello/tool\"\n"
      }),
    )
    as "an event outside the vocabulary must be refused"
  assert string.contains(reason, "on_vibes")
}

// --- package vetting ------------------------------------------------------

/// Every vetting refusal names its file. That is the whole reason the
/// result is a list of pairs: an extension is somebody else's repository,
/// and a refusal without a path is a bug report nobody can act on.
pub fn every_vetting_refusal_names_its_file_test() {
  assert refused_file(extensions.hostile_ffi()) == "src/hello/tool.gleam"
  assert refused_file(extensions.hostile_import()) == "src/hello/tool.gleam"
  assert refused_file(extensions.hostile_erl()) == "src/hello/nif.erl"
  assert refused_file(extensions.hostile_dep()) == "gleam.toml"
}

pub fn the_working_fixture_vets_test() {
  assert vets(extensions.hello())
}

// --- the record -----------------------------------------------------------

pub fn a_record_round_trips_test() {
  let written = sample_record()
  let assert Ok(read) = record.decode(encoded(written))
    as "a record this server wrote must decode"
  assert read == written
}

pub fn a_record_from_another_format_is_refused_test() {
  let assert Error(reason) =
    record.current(record.Record(..sample_record(), format: 99))
    as "a record from a different server must be refused by name"
  assert string.contains(reason, "99")
}

pub fn a_truncated_record_is_refused_test() {
  let assert Error(reason) = record.decode("{\"name\":")
    as "a truncated record is corruption, not a partial decode"
  assert string.length(reason) > 0
}

pub fn a_record_carries_no_secret_values_test() {
  // The names, never the values: the rule `api_key_env` set, one layer
  // out. Asserted as an equality over the terms so a field added later
  // cannot smuggle one in unnoticed.
  let net =
    manifest.Net(
      hosts: ["api.example.com"],
      methods: ["GET"],
      max_response_bytes: 1024,
      requests_per_call: 2,
      secrets: [
        manifest.Secret(
          env: "EXAMPLE_API_KEY",
          host: "api.example.com",
          header: "X-Token",
        ),
      ],
    )
  assert record.terms(net).secret_env == ["EXAMPLE_API_KEY"]
}

pub fn the_root_is_a_value_test() {
  assert record.path(record.root_for("/home/o")) == "/home/o/.loom/extensions"
  assert record.file(record.root_at("/x"), "w") == "/x/w/install.json"
  assert record.sources(record.root_at("/x"), "w") == "/x/w/src"
}

// --- sources --------------------------------------------------------------

pub fn a_git_source_is_refused_test() {
  let assert Error(reason) = source.parse("git://example.com/w.git")
    as "there is no git client, deliberately"
  assert string.contains(reason, "git")

  let assert Error(file_reason) = source.parse("file:///etc")
    as "file:// is refused by the decoder"
  assert string.contains(file_reason, "file")
}

pub fn a_github_source_resolves_to_an_archive_test() {
  let assert Ok(parsed) = source.parse("https://github.com/o/r")
    as "a GitHub URL is a source"
  assert parsed == source.GitHub(owner: "o", repo: "r")
  assert source.archive_url(parsed, Some("v1"))
    == Ok("https://codeload.github.com/o/r/tar.gz/v1")
}

pub fn a_url_with_credentials_is_refused_test() {
  let assert Error(reason) =
    source.parse("https://user:pass@example.com/w.tar.gz")
    as "a URL whose host two readers could disagree about is refused"
  assert string.contains(reason, "host")
}

// --- the pipeline, with the build faked -----------------------------------

/// The whole pipeline over a local path, with a fetcher that must never
/// be called: a local source is copied, not fetched, and a pipeline that
/// reached the network for one would be reaching it for every install.
pub fn a_local_install_never_fetches_test() {
  let #(root, done) = installed_hello("local-install")
  assert done.record.name == "hello"
  assert done.record.revision == record.local_revision
  assert done.record.tools == ["hello"]
  assert done.record.approved_at == record.instant(at_ms)
  assert done.directory == record.directory(root, "hello")
  assert exists(record.file(root, "hello"))
  assert exists(record.sources(root, "hello") <> "/src/hello/tool.gleam")

  // The build root is scaffolding and does not survive the promotion:
  // what is kept is exactly what the record describes.
  assert !exists(record.directory(root, "hello") <> "/build")
}

/// A URL source is refused naming the layer, because the fetch is not
/// wired in this build. The refusal is the honest answer; a silent
/// fallback to something less policed would not be.
pub fn a_url_install_is_refused_by_the_fetch_layer_test() {
  let root = fresh_root("url-install")
  let assert Error(failure) =
    install.run(
      config(root, fn(_url, _max) { Error("no route") }),
      source.ArchiveUrl(url: "https://example.com/w.tar.gz"),
      rev: None,
    )
    as "a URL source cannot be installed without a fetch"
  assert string.starts_with(install.describe(failure), "fetch:")
}

/// The fetch path, with the network faked one layer above the client: a
/// fetcher that hands back a real gzipped tar of the working fixture, and
/// the same extractor a live fetch would have fed. What is being proved
/// is that the pipeline reaches the archive at all — the extractor's own
/// refusals live beside it in `client/extension/archive_test`.
pub fn an_archive_install_extracts_and_records_test() {
  let root = fresh_root("archive-install")
  let bytes = extensions.tarball("hello-main", extensions.hello())
  let assert Ok(done) =
    install.run(
      config(root, fn(_url, _max) { Ok(bytes) }),
      source.ArchiveUrl(url: "https://example.com/hello.tar.gz"),
      rev: None,
    )
    as "a fetched archive must install"
  assert done.record.name == "hello"

  // The archive named no commit and the URL already names one tree, so
  // the URL is the whole of the pin — which reads differently from a
  // local path, which has no revision to have.
  assert done.record.revision == record.unpinned_revision
  assert exists(record.sources(root, "hello") <> "/src/hello/tool.gleam")
  let assert [installed.Ready(..)] = installed.discover(root)
    as "an archive install must discover"
}

/// A fetch that fails is a `Fetch` failure and nothing else: the layer
/// naming is what makes the difference between "the host was down" and
/// "your extension is broken" legible to whoever reads it.
pub fn a_failed_fetch_names_the_fetch_layer_test() {
  let root = fresh_root("archive-refused")
  let assert Error(failure) =
    install.run(
      config(root, fn(_url, _max) { Error("no route to host") }),
      source.ArchiveUrl(url: "https://example.com/hello.tar.gz"),
      rev: None,
    )
    as "a fetch that fails must refuse the install"
  assert install.describe(failure) == "fetch: no route to host"
  assert !exists(record.directory(root, "hello"))
}

pub fn a_hostile_fixture_is_refused_by_its_own_layer_test() {
  assert layer_of(extensions.hostile_ffi(), "ffi") == "vetting"
  assert layer_of(extensions.hostile_import(), "import") == "vetting"
  // Still a refusal rather than a prune: Gleam compiles a native module
  // found under `src/` and links it into the artifact.
  assert layer_of(extensions.hostile_erl(), "erl") == "vetting"
  assert layer_of(extensions.hostile_dep(), "dep") == "vetting"
  assert layer_of(extensions.hostile_tier(), "tier") == "manifest"
  assert layer_of(extensions.hostile_key(), "key") == "manifest"
  assert layer_of(extensions.hostile_secret_host(), "secret") == "manifest"
}

/// Nothing is left behind. The staging directory is removed on every path
/// out but the last, and the extension's own directory is never created
/// until the record inside it exists.
/// A failure *after* the staging directory exists is the one that
/// matters: vetting refuses before anything is written, so the removal
/// has to be proved against a layer that runs later. A build that refuses
/// is that layer.
pub fn a_failed_build_leaves_no_staging_test() {
  let root = fresh_root("failed-build")
  let tree =
    extensions.materialise(
      extensions.hello(),
      extensions.scratch("failed-build-src"),
    )
  let assert Error(failure) =
    install.run(
      install.Config(..config(root, never_fetch), build: refusing_build),
      source.LocalPath(path: tree),
      rev: None,
    )
    as "a build that refuses must refuse the install"
  assert string.starts_with(install.describe(failure), "compile:")
  assert staging_entries(root) == []
  assert !exists(record.directory(root, "hello"))
}

fn refusing_build(_root: String) -> compile.Built {
  compile.Built(
    result: Error(compile.BuildRejected(diagnostics: "type error")),
    enforcement: enforcement.Unreported("the build was faked"),
  )
}

pub fn a_refused_install_leaves_no_staging_test() {
  let root = fresh_root("refused-staging")
  let tree =
    extensions.materialise(
      extensions.hostile_ffi(),
      extensions.scratch("refused-staging-src"),
    )
  let assert Error(_failure) =
    install.run(
      config(root, never_fetch),
      source.LocalPath(path: tree),
      rev: None,
    )
    as "an @external must refuse the install"
  assert staging_entries(root) == []
  assert !exists(record.directory(root, "hostile_ffi"))
}

pub fn a_hook_is_refused_until_phase_three_test() {
  let root = fresh_root("hooked")
  let tree =
    extensions.materialise(
      with(extensions.hello(), "extension.toml", fn(text) {
        text <> "\n[[hook]]\nevent = \"tool_call\"\nentry = \"hello/tool\"\n"
      }),
      extensions.scratch("hooked-src"),
    )
  let assert Error(failure) =
    install.run(
      config(root, never_fetch),
      source.LocalPath(path: tree),
      rev: None,
    )
    as "an extension with a hook installs in phase 3, not phase 1"
  assert string.contains(install.describe(failure), "phase 3")
}

pub fn a_second_install_of_the_same_name_is_refused_test() {
  let #(root, _done) = installed_hello("twice")
  let tree =
    extensions.materialise(extensions.hello(), extensions.scratch("twice-src2"))
  let assert Error(failure) =
    install.run(
      config(root, never_fetch),
      source.LocalPath(path: tree),
      rev: None,
    )
    as "replacing an install is remove-then-install"
  assert string.contains(install.describe(failure), "already installed")
}

pub fn a_named_revision_is_recorded_test() {
  let root = fresh_root("revision")
  let tree =
    extensions.materialise(
      extensions.hello(),
      extensions.scratch("revision-src"),
    )
  let assert Ok(done) =
    install.run(
      config(root, never_fetch),
      source.LocalPath(path: tree),
      rev: Some("v9"),
    )
    as "an operator's --rev is what the record pins"
  assert done.record.revision == "v9"
}

// --- discovery ------------------------------------------------------------

pub fn discovery_finds_the_install_test() {
  let #(root, done) = installed_hello("discovery")
  let assert [installed.Ready(record: found, manifest: decoded, artifact:)] =
    installed.discover(root)
    as "a complete install must be discoverable"
  assert found == done.record
  assert list.map(decoded.tools, fn(tool) { tool.name }) == ["hello"]
  assert string.ends_with(artifact, record.artifact_directory)
}

/// One byte under `src/` and the extension is refused. This is what makes
/// an install content-addressed from the moment it is written: the
/// approval was for a tree, not for a directory name.
pub fn a_tampered_source_is_refused_test() {
  let #(root, _done) = installed_hello("tampered")
  let path = record.sources(root, "hello") <> "/src/hello/tool.gleam"
  let assert Ok(before) = simplifile.read(from: path)
    as "the installed source must be readable"
  let assert Ok(Nil) = simplifile.write(to: path, contents: before <> "\n")
    as "the test must be able to tamper with it"

  let assert installed.Refused(name:, reason:) = installed.one(root, "hello")
    as "a changed tree must refuse the extension"
  assert name == "hello"
  assert string.contains(reason, "no longer matches")
}

pub fn a_record_naming_another_extension_is_refused_test() {
  let #(root, _done) = installed_hello("misnamed")
  let path = record.file(root, "hello")
  let assert Ok(text) = simplifile.read(from: path)
    as "the record must be readable"
  let assert Ok(Nil) =
    simplifile.write(
      to: path,
      contents: string.replace(text, "\"name\":\"hello\"", "\"name\":\"other\""),
    )
    as "the test must be able to rewrite it"
  let assert installed.Refused(reason:, ..) = installed.one(root, "hello")
    as "a record that was moved must not stand in for another approval"
  assert string.contains(reason, "other")
}

/// The one that could have deleted a home directory. `record.directory`
/// joins the operator's word to the root, so an unchecked `..` names the
/// `.loom` directory itself and `simplifile.delete` takes it. The gate is
/// the manifest's own name grammar, which admits no `.` and no `/`.
pub fn a_traversing_name_is_refused_test() {
  let #(root, _done) = installed_hello("traversal")
  let home = home_of(root)
  let dotloom = home <> "/.loom"

  list.each(["..", ".staging", "a/b", ".", "hello/../.."], fn(name) {
    let assert Error(reason) = installed.remove(root, name)
      as "a name outside the grammar must never reach a delete"
    assert string.contains(reason, "not an extension name")

    let assert installed.Refused(reason: verified, ..) =
      installed.one(root, name)
      as "and must never reach a read either"
    assert string.contains(verified, "not an extension name")

    let assert Error(from_cli) = cli.dispatch(["remove", name, "--home", home])
      as "the CLI refuses it as a usage error"
    assert string.contains(from_cli, "not an extension name")
  })

  // The point of all of that, asserted directly.
  assert exists(dotloom)
  assert exists(record.directory(root, "hello"))
}

/// A staging directory left by a crash is not an extension, and listing
/// must not report it as a refused one.
pub fn discovery_ignores_the_staging_directory_test() {
  let #(root, _done) = installed_hello("staging-listed")
  let assert Ok(Nil) =
    simplifile.create_directory_all(
      record.path(root) <> "/" <> record.staging_directory <> "/abc",
    )
    as "the test must be able to leave staging behind"
  let assert [installed.Ready(..)] = installed.discover(root)
    as "only the installed extension is an extension"
}

/// Re-vetting the source says nothing about the bytes that run. A
/// dispatch loads the artifact, so the artifact is checked too.
pub fn a_tampered_artifact_is_refused_test() {
  let #(root, _done) = installed_hello("artifact-swap")
  let beam =
    record.artifact_at(root, "hello") <> "/" <> compile.entry_module <> ".beam"
  let assert Ok(Nil) = simplifile.write(to: beam, contents: "FOR2")
    as "the test must be able to swap a beam"
  let assert installed.Refused(reason:, ..) = installed.one(root, "hello")
    as "a swapped artifact must refuse the extension"
  assert string.contains(reason, "artifact no longer matches")
}

pub fn a_missing_entry_beam_is_refused_test() {
  let #(root, _done) = installed_hello("artifact-gone")
  let assert Ok(Nil) =
    simplifile.delete(
      record.artifact_at(root, "hello")
      <> "/"
      <> compile.entry_module
      <> ".beam",
    )
    as "the test must be able to delete a beam"
  let assert installed.Refused(reason:, ..) = installed.one(root, "hello")
    as "an artifact with nothing to run must refuse the extension"
  assert string.contains(reason, compile.entry_module)
}

/// A real Gleam repository installs. It carries tests, a `.gitignore`, a
/// CI workflow, `manifest.toml`, docs and a `build/` directory, and none
/// of that is part of what an operator approves — so all of it is pruned
/// before anything else happens, rather than refusing every repository
/// there is.
pub fn a_repository_installs_and_only_its_extension_is_kept_test() {
  let root = fresh_root("repository")
  let tree =
    extensions.materialise(
      extensions.repository(),
      extensions.scratch("repository-src"),
    )

  // A binary under `docs/` is pruned, not refused: the UTF-8 rule applies
  // to installed files, and a screenshot in a repository is not one.
  let assert Ok(Nil) =
    simplifile.write_bits(to: tree <> "/docs/screenshot.png", bits: <<0xFF>>)
    as "the test must be able to plant a binary outside the installed tree"

  let assert Ok(done) =
    install.run(
      config(root, never_fetch),
      source.LocalPath(path: tree),
      rev: None,
    )
    as "a real repository must install"

  // Exactly the extension's own tree is on disk, and nothing else.
  let assert Ok(staged) =
    archive.from_directory(
      record.sources(root, "hello"),
      archive.default_caps(),
    )
    as "the staged source must be readable"
  assert list.sort(
      list.map(staged.files, fn(file) { file.path }),
      string.compare,
    )
    == extensions.installed_paths()

  // And the recorded digest describes that tree, so a re-verify compares
  // like with like rather than re-deriving the prune and hoping.
  assert done.record.tree_digest == archive.digest(staged)
  let assert [installed.Ready(..)] = installed.discover(root)
    as "a pruned install must verify against its own digest"
}

/// A file that is not text is refused rather than dropped. Dropped, it
/// would be staged under the installed extension's `src/` having passed
/// no rule at all — neither vetted nor refused.
pub fn a_binary_file_refuses_the_install_test() {
  let root = fresh_root("binary-file")
  let tree =
    extensions.materialise(extensions.hello(), extensions.scratch("binary-src"))

  // A lone 0xFF byte is not valid UTF-8 in any position. Under `schema/`,
  // which *is* installed — a non-`.gleam` file under `src/` is refused a
  // step earlier, by the rule that it would be compiled.
  let assert Ok(Nil) =
    simplifile.write_bits(to: tree <> "/schema/blob.json", bits: <<0xFF>>)
    as "the test must be able to plant a non-text file"
  let assert Error(failure) =
    install.run(
      config(root, never_fetch),
      source.LocalPath(path: tree),
      rev: None,
    )
    as "a non-text file must refuse the install"
  assert string.starts_with(install.describe(failure), "extract:")
  assert string.contains(install.describe(failure), "schema/blob.json")
  assert !exists(record.directory(root, "hello"))
}

/// The install says what the kernel enforced on the jail that built the
/// artifact, and a build that reported nothing says so.
pub fn an_install_carries_its_enforcement_report_test() {
  let #(_root, done) = installed_hello("enforcement")
  assert done.enforcement == enforcement.Unreported("the build was faked")
  assert string.contains(
    install.enforcement_line(done.enforcement),
    "NO enforcement report",
  )
}

/// A relative `--home` is resolved, because `install` runs from the
/// working directory and the other verbs do not: taken as typed, an
/// extension would install into one directory and be invisible from
/// another a moment later.
pub fn a_relative_home_resolves_test() {
  let #(root, _done) = installed_hello("relative-home")
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory must be readable"
  let relative = relative_to(here, home_of(root))
  let assert Ok(listed) = cli.dispatch(["list", "--home", relative])
    as "a relative --home must find the same root"
  assert list.any(listed, fn(line) { string.contains(line, "hello") })
}

// `..`-hopping from `here` to `there`, which is what a shell would have
// done had the operator typed a relative path.
fn relative_to(here: String, there: String) -> String {
  let depth =
    list.length(list.filter(string.split(here, "/"), fn(p) { p != "" }))
  string.join(list.repeat("..", depth), "/") <> there
}

pub fn remove_takes_the_whole_install_test() {
  let #(root, _done) = installed_hello("removal")
  assert installed.remove(root, "hello") == Ok(Nil)
  assert !exists(record.directory(root, "hello"))
  assert installed.discover(root) == []

  let assert Error(reason) = installed.remove(root, "hello")
    as "removing what is not there is an error, not a no-op"
  assert string.contains(reason, "not installed")
}

// --- the CLI --------------------------------------------------------------

pub fn the_cli_lists_and_removes_test() {
  let #(root, _done) = installed_hello("cli")
  let home = home_of(root)
  let assert Ok(listed) = cli.dispatch(["list", "--home", home])
    as "list must read the root"
  assert list.any(listed, fn(line) { string.contains(line, "hello") })

  let assert Ok(verified) = cli.dispatch(["verify", "hello", "--home", home])
    as "a complete install must verify"
  assert list.contains(verified, "ok")

  assert cli.dispatch(["remove", "hello", "--home", home])
    == Ok(["removed hello"])
}

pub fn the_cli_refuses_what_it_does_not_understand_test() {
  let assert Error(unknown) = cli.dispatch(["frobnicate"])
    as "an unknown verb is a usage error"
  assert string.contains(unknown, "frobnicate")

  let assert Error(flag) = cli.dispatch(["list", "--nope"])
    as "an unknown flag is a usage error"
  assert string.contains(flag, "--nope")

  let assert Error(missing) = cli.dispatch(["remove", "--home", "/x"])
    as "remove needs a name"
  assert string.contains(missing, "required")
}

pub fn verify_refuses_a_tampered_install_test() {
  let #(root, _done) = installed_hello("cli-verify")
  let path = record.sources(root, "hello") <> "/src/hello/tool.gleam"
  let assert Ok(Nil) =
    simplifile.write(to: path, contents: "pub fn x() { 1 }\n")
    as "the test must be able to tamper with it"
  let assert Error(reason) =
    cli.dispatch(["verify", "hello", "--home", home_of(root)])
    as "verify answers no for an extension that would not load"
  assert string.contains(reason, "hello")
}

// --- the generated entry --------------------------------------------------

/// The aliases are positional, so two tools whose entry modules share a
/// last segment cannot collide — a collision would surface as a confusing
/// compile error inside generated code.
pub fn the_generated_entry_aliases_positionally_test() {
  let source =
    install.entry_source([
      tool("first", "a/tool"),
      tool("second", "b/tool"),
    ])
  assert string.contains(source, "import a/tool as ext_entry_0")
  assert string.contains(source, "import b/tool as ext_entry_1")
  assert string.contains(source, "#(\"first\", ext_entry_0.run)")
  assert string.contains(source, "#(\"second\", ext_entry_1.run)")
  assert string.contains(source, "runtime.serve([")
}

// --- the real jailed build, feature-detected ------------------------------

/// The compile step for real: a sandbox helper, a toolchain and a
/// prepared seed, and the extension is built offline inside a
/// network-off jail exactly as a code-mode program is.
///
/// Skipped with a printed reason when the host has none of that, so
/// `make check` stays fast; `make e2e-codemode` prepares the seed and
/// `make binaries` the helper, and there it runs.
/// The eunit test representation, built in Gleam: a constructor with
/// fields compiles to a tagged Erlang tuple, so `Timeout(30, body)` is
/// literally `{timeout, 30, Body}` — what eunit reads back from a
/// zero-arity `*_test_` *generator*. gleeunit runs eunit with
/// `ScaleTimeouts(10)`, applied to a generator's explicit timeout too, so
/// 30 here is 300 seconds. `packages/codemode/test/codemode/e2e_test.gleam`
/// works the arithmetic through; the trap is that a reader who takes the
/// number at face value sets ten times what they meant.
pub type EunitTest {
  Timeout(seconds: Int, body: fn() -> Nil)
}

/// The ceiling on the one test here that runs a real jailed build: the
/// build itself may legitimately spend 180 s plus a settle margin, so a
/// smaller ceiling would substitute an anonymous eunit timeout for
/// Loom's own report of what the build did.
const jailed_test_timeout_seconds = 300

const gleeunit_timeout_scale = 10

pub fn a_real_jailed_build_installs_test_() -> EunitTest {
  Timeout(jailed_test_timeout_seconds / gleeunit_timeout_scale, fn() {
    real_jailed_build()
  })
}

fn real_jailed_build() -> Nil {
  let root = fresh_root("jailed")
  let staging = record.path(root) <> "/.staging"
  let _made = simplifile.create_directory_all(staging)
  case
    serve.start_build_plane(
      helper: repository_helper(),
      seed: None,
      workspace: repository_root(),
      writable: record.path(root),
      tmp_dir: staging,
      // A real wall clock, not the fixture one the rest of this suite
      // uses: the broker turns `deadline - now` into a receive timeout,
      // and a clock three years behind the deadline the install mints
      // produces one Erlang refuses outright.
      clock: clock.from_function(ffi_os.system_time_ms),
    )
  {
    Error(reason) -> io.println("SKIP a_real_jailed_build_installs: " <> reason)
    Ok(plane) -> {
      let tree =
        extensions.materialise(
          extensions.hello(),
          extensions.scratch("jailed-src"),
        )
      let outcome =
        install.run(
          install.Config(
            ..config(root, never_fetch),
            // Best effort, as the code-mode end-to-end demands: the CI gate
            // runners carry a helper that is honest about lacking a layer
            // (no user namespaces on the Linux gate), and a test that asked
            // for the platform's full enforcement there would fail on the
            // runner rather than on the build. The CLI's own default for a
            // real install stays `PlatformEnforcement`.
            build: cli.build_for(plane, exec.BestEffort),
          ),
          source.LocalPath(path: tree),
          rev: None,
        )
      serve.stop_build_plane(plane)
      let assert Ok(done) = outcome
        as "the fixture extension must build inside the jail"
      assert exists(
        done.directory
        <> "/"
        <> record.artifact_directory
        <> "/"
        <> compile.entry_module
        <> ".beam",
      )
      let assert [installed.Ready(..)] = installed.discover(root)
        as "a really-built install must discover"

      // Announce what the kernel actually enforced, the way the code-mode
      // end-to-end does: a green test that says nothing about enforcement
      // invites the reader to assume the strongest thing.
      io.println(
        "extension install e2e: " <> install.enforcement_line(done.enforcement),
      )
      let assert enforcement.Reported(..) = done.enforcement
        as "a build that really ran in a jail must report what it enforced"
      Nil
    }
  }
}

// The helper `make binaries` writes, from the `packages/client` directory
// the test runner starts in. Absent on a host that has not built it,
// which is the skip this suite is feature-detected for.
fn repository_helper() -> option.Option(String) {
  let path = repository_root() <> "/bin/loom-exec"
  case simplifile.is_file(path) {
    Ok(True) -> Some(path)
    _ -> None
  }
}

// --- helpers --------------------------------------------------------------

fn decode(files: List(#(String, String))) -> Result(manifest.Manifest, String) {
  let assert Ok(text) = list.key_find(files, "extension.toml")
    as "a fixture carries a manifest"
  manifest.decode(
    text,
    manifest.Surroundings(files:, modules: package.module_names_of(files)),
  )
}

fn vets(files: List(#(String, String))) -> Bool {
  case
    package.vet_package(files, vet_policy.for_seam(vet_policy.ExtensionSeam))
  {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn refused_file(files: List(#(String, String))) -> String {
  let assert Error([#(path, _rejection), ..]) =
    package.vet_package(files, vet_policy.for_seam(vet_policy.ExtensionSeam))
    as "a hostile fixture must be refused"
  path
}

fn with(
  files: List(#(String, String)),
  path: String,
  edit: fn(String) -> String,
) -> List(#(String, String)) {
  let assert Ok(before) = list.key_find(files, path)
    as "the fixture must hold the file being edited"
  [#(path, edit(before)), ..list.filter(files, fn(file) { file.0 != path })]
}

fn tool(name: String, entry: String) -> manifest.Tool {
  manifest.Tool(
    name:,
    description: "d",
    prompt_snippet: "s",
    parameters: "schema/x.json",
    entry:,
    timeout_ms: 1000,
  )
}

fn sample_record() -> record.Record {
  record.Record(
    format: record.format_version,
    name: "hello",
    version: "0.1.0",
    source: "./hello",
    revision: record.local_revision,
    tree_digest: "sha256-abc",
    manifest_hash: "sha256-def",
    allowlist: install.allowlist(),
    net: record.terms(manifest.no_net()),
    tools: ["hello"],
    approved_at: record.instant(at_ms),
    approved_by: "operator",
    artifact: record.artifact_directory,
  )
}

fn encoded(written: record.Record) -> String {
  json.to_string(record.encode(written))
}

// A root under a fresh scratch home, so `--home` and `record.root_for`
// agree and no test reads the operator's own `~/.loom`.
fn fresh_root(name: String) -> record.Root {
  record.root_for(extensions.scratch(name))
}

fn home_of(root: record.Root) -> String {
  string.replace(record.path(root), "/.loom/extensions", "")
}

fn installed_hello(name: String) -> #(record.Root, install.Installed) {
  let root = fresh_root(name)
  let tree =
    extensions.materialise(
      extensions.hello(),
      extensions.scratch(name <> "-src"),
    )
  let assert Ok(done) =
    install.run(
      config(root, never_fetch),
      source.LocalPath(path: tree),
      rev: None,
    )
    as "the working fixture must install"
  #(root, done)
}

fn layer_of(files: List(#(String, String)), name: String) -> String {
  let root = fresh_root("layer-" <> name)
  let tree =
    extensions.materialise(
      files,
      extensions.scratch("layer-" <> name <> "-src"),
    )
  let assert Error(failure) =
    install.run(
      config(root, never_fetch),
      source.LocalPath(path: tree),
      rev: None,
    )
    as "a hostile fixture must be refused"
  let assert Ok(#(layer, _rest)) =
    string.split_once(install.describe(failure), ":")
    as "a failure names its layer first"
  layer
}

fn config(root: record.Root, fetch: install.Fetcher) -> install.Config {
  install.Config(
    root:,
    caps: archive.default_caps(),
    fetch:,
    build: fake_build,
    clock: clock.fixed(at: at_ms),
    entropy: fn() { 4 },
    approved_by: "operator",
  )
}

// A fetcher that fails the test if it is ever called. A local source is
// copied, and a pipeline that reached the network for one would be
// reaching it for every install.
fn never_fetch(_url: String, _max: Int) -> Result(BitArray, String) {
  panic as "the pipeline fetched a URL while installing a local source"
}

// The build seam, faked: a beam directory with one file in it, so the
// pipeline's own discipline is proved without a jail.
//
// The content address is computed the way a real build computes it,
// rather than made up. A fake that reported an address its own output
// does not have would install something discovery then refuses, and the
// whole suite would be exercising a state no real install can reach.
fn fake_build(root: String) -> compile.Built {
  let beam_dir = root <> "/ebin"
  let _made = simplifile.create_directory_all(beam_dir)
  let _written =
    simplifile.write(
      to: beam_dir <> "/" <> compile.entry_module <> ".beam",
      contents: "FOR1",
    )
  let assert Ok(manifest_hash) = build.fingerprint_directory(beam_dir)
    as "the faked beam directory must have a content address"
  compile.Built(
    result: Ok(compile.BuildProducts(beam_dir:, manifest_hash:)),
    enforcement: enforcement.Unreported("the build was faked"),
  )
}

fn exists(path: String) -> Bool {
  case simplifile.is_file(path), simplifile.is_directory(path) {
    Ok(True), _ -> True
    _, Ok(True) -> True
    _, _ -> False
  }
}

fn staging_entries(root: record.Root) -> List(String) {
  case
    simplifile.read_directory(
      at: record.path(root) <> "/" <> record.staging_directory,
    )
  {
    Ok(entries) -> entries
    Error(_absent) -> []
  }
}

// The repository root, from the `packages/client` directory the test
// runner starts in. The jailed build needs a workspace whose base policy
// covers the toolchain.
fn repository_root() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory must be readable"
  here <> "/../.."
}
