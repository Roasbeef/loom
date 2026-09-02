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
