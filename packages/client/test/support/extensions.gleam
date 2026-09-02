//// Fixture extensions: one that installs and seven that must not.
////
//// # Why these are strings rather than a directory of files
////
//// Gleam compiles **every** `.gleam` file under `test/`, at any depth, as
//// a module of the package's test target. A fixture extension checked in
//// as a real package tree would therefore be compiled as part of
//// `packages/client`'s own tests — against `packages/client`'s dependency
//// table, which has no `ext` — and the whole suite would fail to build
//// before a single test ran. The `hostile_*` fixtures are worse: they
//// exist precisely because they do not compile.
////
//// So the trees live here as `#(path, contents)` and `materialise` writes
//// one into a scratch directory per test. That is the same reason
//// `docs/examples/stale_symbol_sweep.gleam` lives outside every package
//// (see the `LOOSE_GLEAM` note in the Makefile): a Gleam file inside a
//// package is a module of it, whatever the directory is called.
////
//// # What each fixture is for
////
//// `hello` is the one that works, and everything else is one refusal:
////
//// | fixture | refused by | because |
//// |---|---|---|
//// | `hostile_ffi` | vetting | an `@external` is a foreign interface |
//// | `hostile_import` | vetting | `gleam/erlang/process` is off every seam |
//// | `hostile_erl` | vetting (layout) | an `.erl` under `src/` is compiled and linked |
//// | `hostile_dep` | vetting (project) | `simplifile` is not in the jail |
//// | `hostile_tier` | manifest | `tier = "harness"` has no loader |
//// | `hostile_key` | manifest | an unknown key is an error |
//// | `hostile_secret_host` | manifest | a secret for a host outside the allowlist |
////
//// Each hostile fixture differs from `hello` in exactly one way, so a test
//// that passes says which rule caught it rather than that something did.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import provider/secret
import simplifile

/// The working extension: one tool that echoes its `say` argument.
pub fn hello() -> List(#(String, String)) {
  [
    #("extension.toml", hello_manifest()),
    #("gleam.toml", hello_project()),
    #("README.md", "# hello\n\nEchoes an argument back.\n"),
    #("schema/hello.json", hello_schema()),
    #("src/hello/tool.gleam", hello_tool()),
  ]
}

/// The egress fixture: one tool that fetches a URL through the broker and
/// reports what came back, once per requested attempt.
///
/// Parameterised by the origin the end-to-end started, because
/// `[net].hosts` is an exact `host:port` and the port is ephemeral. The
/// secret binding is the fixture's own: an environment variable the test
/// sets, bound to a header the origin records having seen. Nothing in the
/// tool's source names either — it sets no headers at all — which is the
/// property the end-to-end exists to prove.
///
/// ## Examples
///
/// ```gleam
/// let files = extensions.fetcher(origin: "localhost:8443", per_call: 2)
/// ```
///
pub fn fetcher(
  origin origin: String,
  per_call per_call: Int,
) -> List(#(String, String)) {
  [
    #("extension.toml", fetcher_manifest(origin, per_call)),
    #("gleam.toml", fetcher_project()),
    #("schema/fetcher.json", fetcher_schema()),
    #("src/fetcher/tool.gleam", fetcher_tool()),
  ]
}

/// The environment variable the `fetcher` fixture's secret binding names.
/// A *name*: the value is set by the end-to-end and never appears in the
/// manifest, the record, or any file the fixture writes.
pub const fetcher_env = "LOOM_FIXTURE_TOKEN"

/// The header the broker injects the bound value into.
pub const fetcher_header = "X-Fixture-Token"

/// An extension whose source declares an `@external`.
pub fn hostile_ffi() -> List(#(String, String)) {
  replace(
    named(hello(), "hostile_ffi"),
    "src/hello/tool.gleam",
    "@external(erlang, \"os\", \"cmd\")\npub fn run(command: String) -> String\n",
  )
}

/// An extension whose source imports a module on no seam.
pub fn hostile_import() -> List(#(String, String)) {
  replace(
    named(hello(), "hostile_import"),
    "src/hello/tool.gleam",
    "import gleam/erlang/process\n\npub fn run() -> process.Pid {\n"
      <> "  process.self()\n}\n",
  )
}

/// An extension carrying a native module under `src/`.
pub fn hostile_erl() -> List(#(String, String)) {
  [
    #("src/hello/nif.erl", "-module(nif).\n-export([go/0]).\ngo() -> ok.\n"),
    ..named(hello(), "hostile_erl")
  ]
}

/// An extension whose `gleam.toml` names a dependency the jail does not
/// provide.
pub fn hostile_dep() -> List(#(String, String)) {
  replace(
    named(hello(), "hostile_dep"),
    "gleam.toml",
    "name = \"hostile_dep\"\nversion = \"0.1.0\"\ngleam = \">= 1.18.0\"\n\n"
      <> "[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n"
      <> "simplifile = \">= 2.0.0 and < 3.0.0\"\n",
  )
}

/// An extension asking for the harness-resident tier.
pub fn hostile_tier() -> List(#(String, String)) {
  replace(
    named(hello(), "hostile_tier"),
    "extension.toml",
    string.replace(
      named_manifest("hostile_tier"),
      "tier = \"jailed\"",
      "tier = \"harness\"",
    ),
  )
}

/// An extension whose manifest sets a key the decoder does not take.
pub fn hostile_key() -> List(#(String, String)) {
  replace(
    named(hello(), "hostile_key"),
    "extension.toml",
    string.replace(
      named_manifest("hostile_key"),
      "tier = \"jailed\"",
      "tier = \"jailed\"\nauthor = \"nobody\"",
    ),
  )
}

/// An extension binding a secret to a host its own allowlist omits.
pub fn hostile_secret_host() -> List(#(String, String)) {
  replace(
    named(hello(), "hostile_secret_host"),
    "extension.toml",
    named_manifest("hostile_secret_host")
      <> "\n[net]\nhosts = [\"api.example.com\"]\nmethods = [\"GET\"]\n"
      <> "max_response_bytes = 1048576\nrequests_per_call = 4\n\n"
      <> "[[net.secret]]\nenv = \"EXAMPLE_API_KEY\"\n"
      <> "host = \"evil.example.net\"\nheader = \"X-Token\"\n",
  )
}

/// The working extension as a real repository carries it: tests, a
/// `.gitignore`, a CI workflow, Gleam's own resolved `manifest.toml`,
/// documentation with a binary in it, and a `build/` directory.
///
/// None of that is installed, and none of it may refuse the install —
/// which is the whole point of the fixture: `git archive` of any real
/// Gleam repository looks like this.
///
/// ## Examples
///
/// ```gleam
/// let dir = extensions.materialise(extensions.repository(), scratch)
/// ```
///
pub fn repository() -> List(#(String, String)) {
  list.append(hello(), [
    #("test/hello_test.gleam", "import simplifile\npub fn main() { 1 }\n"),
    #(".gitignore", "build\n*.beam\n"),
    #(".github/workflows/ci.yml", "on: push\njobs: {}\n"),
    #("manifest.toml", "packages = []\n\n[requirements]\n"),
    #("docs/design.md", "# design\n"),
    #("Makefile", "all:\n\t@echo hi\n"),
    #("build/dev/erlang/hello/ebin/hello.app", "{application, hello, []}.\n"),
  ])
}

/// The paths `repository` carries that an install keeps, sorted. What the
/// record's digest must describe.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(extensions.installed_paths(), "extension.toml")
/// ```
///
pub fn installed_paths() -> List(String) {
  hello()
  |> list.map(fn(file) { file.0 })
  |> list.sort(string.compare)
}

/// Writes a fixture tree into `into`, creating directories as needed, and
/// returns the directory it wrote to.
///
/// ## Examples
///
/// ```gleam
/// let dir = extensions.materialise(extensions.hello(), scratch <> "/hello")
/// ```
///
pub fn materialise(files: List(#(String, String)), into: String) -> String {
  let _cleared = simplifile.delete(into)
  list.each(files, fn(file) {
    let path = into <> "/" <> file.0
    let _made = simplifile.create_directory_all(directory_of(path))
    let _written = simplifile.write(to: path, contents: file.1)
    Nil
  })
  into
}

/// A scratch directory under `LOOM_TEST_SCRATCH`, then `HOME`, then the
/// package's own `build/`. Never under `/tmp`, which the jail replaces
/// with its own scratch tmpfs.
///
/// ## Examples
///
/// ```gleam
/// let dir = extensions.scratch("install")
/// ```
///
pub fn scratch(name: String) -> String {
  let base = case env("LOOM_TEST_SCRATCH") {
    Ok(configured) -> configured
    Error(Nil) ->
      case env("HOME") {
        Ok(home) -> home <> "/.loom-exttest"
        Error(Nil) -> "build/exttest"
      }
  }
  let dir = base <> "/" <> name
  let _cleared = simplifile.delete(dir)
  let _made = simplifile.create_directory_all(dir)
  dir
}

/// The `extension.toml` a fixture carries, under a chosen name.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(extensions.named_manifest("w"), "name = \"w\"")
/// ```
///
pub fn named_manifest(name: String) -> String {
  "[extension]\nname = \""
  <> name
  <> "\"\nversion = \"0.1.0\"\n"
  <> "description = \"Echo an argument back.\"\n"
  <> "license = \"MIT\"\ntier = \"jailed\"\n\n"
  <> "[[tool]]\nname = \""
  <> name
  <> "\"\ndescription = \"Echo the say argument back to the model.\"\n"
  <> "prompt_snippet = \""
  <> name
  <> ": echo an argument back\"\n"
  <> "parameters = \"schema/hello.json\"\nentry = \"hello/tool\"\n"
  <> "timeout_ms = 20000\n"
}

// --- the pieces -----------------------------------------------------------

fn hello_manifest() -> String {
  named_manifest("hello")
}

fn hello_project() -> String {
  "name = \"hello\"\nversion = \"0.1.0\"\ngleam = \">= 1.18.0\"\n\n"
  <> "[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n"
  <> "ext = { path = \"../ext\" }\n"
}

fn hello_schema() -> String {
  "{\n  \"type\": \"object\",\n  \"properties\": {\n"
  <> "    \"say\": { \"type\": \"string\" }\n  },\n"
  <> "  \"required\": [\"say\"]\n}\n"
}

fn hello_tool() -> String {
  "import ext
import gleam/dynamic
import gleam/dynamic/decode

pub fn run(
  arguments: dynamic.Dynamic,
  _ctx: ext.Ctx,
) -> Result(ext.Outcome, ext.Refusal) {
  let decoder = {
    use say <- decode.field(\"say\", decode.string)
    decode.success(say)
  }
  case ext.decode_args(arguments, decoder) {
    Ok(say) -> Ok(ext.text(\"hello \" <> say))
    Error(refusal) -> Error(refusal)
  }
}
"
}

// Renames a fixture: the manifest's `[extension].name` and its one tool
// take the new name, so two fixtures can be installed into one root.
fn named(
  files: List(#(String, String)),
  name: String,
) -> List(#(String, String)) {
  replace(files, "extension.toml", named_manifest(name))
}

fn replace(
  files: List(#(String, String)),
  path: String,
  contents: String,
) -> List(#(String, String)) {
  [#(path, contents), ..list.filter(files, fn(file) { file.0 != path })]
}

fn directory_of(path: String) -> String {
  let parts = string.split(path, "/")
  parts
  |> list.take(list.length(parts) - 1)
  |> string.join("/")
}

fn env(name: String) -> Result(String, Nil) {
  secret.lookup(secret.env(), name)
}

// --- the fetcher fixture's pieces ------------------------------------------

fn fetcher_manifest(origin: String, per_call: Int) -> String {
  "[extension]\nname = \"fetcher\"\nversion = \"0.1.0\"\n"
  <> "description = \"Fetch a URL through the broker.\"\n"
  <> "license = \"MIT\"\ntier = \"jailed\"\n\n"
  <> "[[tool]]\nname = \"fetcher\"\n"
  <> "description = \"Fetch a URL and report what came back.\"\n"
  <> "prompt_snippet = \"fetcher: fetch a url through the broker\"\n"
  <> "parameters = \"schema/fetcher.json\"\nentry = \"fetcher/tool\"\n"
  <> "timeout_ms = 60000\n\n"
  <> "[net]\nhosts = [\""
  <> origin
  <> "\"]\nmethods = [\"GET\"]\nmax_response_bytes = 65536\n"
  <> "requests_per_call = "
  <> int.to_string(per_call)
  <> "\n\n[[net.secret]]\nenv = \""
  <> fetcher_env
  <> "\"\nhost = \""
  <> origin
  <> "\"\nheader = \""
  <> fetcher_header
  <> "\"\n"
}

fn fetcher_project() -> String {
  "name = \"fetcher\"\nversion = \"0.1.0\"\ngleam = \">= 1.18.0\"\n\n"
  <> "[dependencies]\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n"
  <> "cap = { path = \"../cap\" }\next = { path = \"../ext\" }\n"
}

fn fetcher_schema() -> String {
  "{\n  \"type\": \"object\",\n  \"properties\": {\n"
  <> "    \"url\": { \"type\": \"string\" },\n"
  <> "    \"times\": { \"type\": \"integer\" }\n  },\n"
  <> "  \"required\": [\"url\", \"times\"]\n}\n"
}

// One line per attempt, naming which of `cap/net`'s three failure kinds
// answered. Every outcome is text rather than a refusal because the
// end-to-end asserts on *all* of the attempts in one reply: a ceiling
// that fires on the third of three has to leave the first two readable.
fn fetcher_tool() -> String {
  "import cap/net
import ext
import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/string

pub fn run(
  arguments: dynamic.Dynamic,
  _ctx: ext.Ctx,
) -> Result(ext.Outcome, ext.Refusal) {
  let decoder = {
    use url <- decode.field(\"url\", decode.string)
    use times <- decode.field(\"times\", decode.int)
    decode.success(#(url, times))
  }
  case ext.decode_args(arguments, decoder) {
    Error(refusal) -> Error(refusal)
    Ok(#(url, times)) -> Ok(ext.text(attempts(url, times)))
  }
}

fn attempts(url: String, times: Int) -> String {
  string.join(list.reverse(collect(url, 1, times, [])), \"\\n\")
}

fn collect(url: String, n: Int, times: Int, found: List(String)) -> List(String) {
  case n > times {
    True -> found
    False ->
      collect(url, n + 1, times, [
        int.to_string(n) <> \" \" <> attempt(url),
        ..found
      ])
  }
}

fn attempt(url: String) -> String {
  case net.fetch(url) {
    Ok(response) ->
      \"ok \" <> int.to_string(response.status) <> \" \" <> text(response.body)
    Error(net.NetDenied(message:)) -> \"denied \" <> message
    Error(net.NetFailed(code:, message:)) ->
      \"failed \" <> code <> \" \" <> message
    Error(net.NetUnavailable(reason:)) -> \"unavailable \" <> reason
  }
}

fn text(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(body) -> body
    Error(Nil) -> \"<not text>\"
  }
}
"
}

// --- a tar writer, for the fetch path -------------------------------------
//
// Only *well formed* archives, which is what makes this a different
// writer from the one in `client/extension/archive_test`: that one exists
// to build the shapes an honest `tar` will not write, and every hostile
// header belongs beside the reader that refuses it. What is wanted here
// is the opposite — one archive a fetch could really have returned — so
// duplicating fifty lines beats importing a test module's private
// vocabulary or widening it into a shared one nobody else needs.

const block = 512

/// A gzipped tar of `files`, under one top-level directory, as a code
/// host's archive endpoint would return it.
///
/// ## Examples
///
/// ```gleam
/// let bytes = extensions.tarball("hello-main", extensions.hello())
/// ```
///
pub fn tarball(root: String, files: List(#(String, String))) -> BitArray {
  let entries =
    list.map(files, fn(file) {
      entry(root <> "/" <> file.0, bit_array.from_string(file.1))
    })
  gzip(
    bit_array.concat(
      list.flatten([[entry(root <> "/", <<>>)], entries, [zeros(block * 2)]]),
    ),
  )
}

// One entry: a checksummed ustar header, the body, and the padding that
// rounds the body up to a whole block. A trailing `/` in the name is what
// makes an entry a directory.
fn entry(name: String, body: BitArray) -> BitArray {
  let size = bit_array.byte_size(body)
  let kind = case string.ends_with(name, "/") {
    True -> "5"
    False -> "0"
  }
  bit_array.concat([header(name, kind, size), body, padding(size)])
}

fn header(name: String, kind: String, size: Int) -> BitArray {
  let unchecked =
    bit_array.concat([
      text_field(name, 100),
      octal_field(0o644, 8),
      octal_field(0, 8),
      octal_field(0, 8),
      octal_field(size, 12),
      octal_field(0, 12),
      <<"        ":utf8>>,
      text_field(kind, 1),
      text_field("", 100),
      <<"ustar":utf8, 0>>,
      <<"00":utf8>>,
      text_field("", 32),
      text_field("", 32),
      octal_field(0, 8),
      octal_field(0, 8),
      text_field("", 155),
      text_field("", 12),
    ])
  patch_checksum(unchecked, sum(unchecked, 0))
}

fn patch_checksum(unchecked: BitArray, value: Int) -> BitArray {
  let assert <<head:bytes-size(148), _blank:bytes-size(8), tail:bits>> =
    unchecked
    as "a tar header is 512 bytes with its checksum at offset 148"
  bit_array.concat([head, octal_field(value, 8), tail])
}

fn sum(bytes: BitArray, total: Int) -> Int {
  case bytes {
    <<value:int-size(8), rest:bits>> -> sum(rest, total + value)
    _empty -> total
  }
}

fn text_field(text: String, width: Int) -> BitArray {
  let bytes = bit_array.from_string(text)
  bit_array.concat([bytes, zeros(width - bit_array.byte_size(bytes))])
}

fn octal_field(value: Int, width: Int) -> BitArray {
  let padded = string.pad_start(int.to_base8(value), width - 1, "0")
  bit_array.concat([bit_array.from_string(padded), <<0>>])
}

fn padding(size: Int) -> BitArray {
  zeros({ { size + block - 1 } / block * block } - size)
}

fn zeros(count: Int) -> BitArray {
  <<0:size(count * 8)>>
}

@external(erlang, "client_test_ffi", "gzip")
fn gzip(bytes: BitArray) -> BitArray
