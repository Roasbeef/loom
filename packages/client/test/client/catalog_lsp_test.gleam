//// The `[lsp.<name>]` tables of `loom.toml`: a language server is
//// configured, never discovered, and its table is the whole of what its
//// jail will grant beyond the project. So these tests hold the parser to
//// the refusals that keep that grant honest — an argv and never a shell
//// string, one owner per extension, absolute or `~/` roots only — as well
//// as to the exact records the documented examples parse to.

import client/catalog
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile

// The smallest catalogue `parse` accepts, so every test below exercises
// exactly the `[lsp.<name>]` tables it appends.
const minimal = "
[models.one]
dialect = \"anthropic\"
api_key_env = \"KEY\"
model_id = \"m-1\"
context_window = 1000
max_output_tokens = 100

[roles]
main = [\"one\"]
"

// The two servers the documentation shows, verbatim: `gleam lsp`, which
// writes its manifest and `build/` into the project, and `gopls`, which
// writes nothing there but needs the module cache and the build cache.
const documented = "
[lsp.gleam]
command = [\"gleam\", \"lsp\"]
extensions = [\".gleam\"]
root_markers = [\"gleam.toml\"]
project = \"writable\"

[lsp.go]
command = [\"gopls\"]
extensions = [\".go\"]
root_markers = [\"go.mod\"]
readable = [\"~/go/pkg/mod\"]
writable = [\"~/.cache/go-build\"]
env = [\"GOFLAGS\"]
"

fn with_lsp(tables: String) -> String {
  minimal <> tables
}

// One `[lsp.x]` table holding the three required keys plus `extra`, so a
// test names only the line it is about.
fn one_server(extra: String) -> String {
  with_lsp(
    "\n[lsp.x]\ncommand = [\"x\"]\nextensions = [\".x\"]\n"
    <> "root_markers = [\"x.toml\"]\n"
    <> extra
    <> "\n",
  )
}

fn refusal(text: String) -> String {
  let assert Error(reason) = catalog.parse(text)
    as "the catalogue was expected to be refused"
  reason
}

pub fn absent_lsp_table_parses_to_no_servers_test() {
  let assert Ok(parsed) = catalog.parse(minimal)
  assert parsed.lsp_servers == []
}

pub fn documented_servers_parse_to_exact_records_test() {
  let assert Ok(parsed) = catalog.parse(with_lsp(documented))
  assert parsed.lsp_servers
    == [
      catalog.LspServer(
        name: "gleam",
        command: ["gleam", "lsp"],
        extensions: [".gleam"],
        root_markers: ["gleam.toml"],
        project: catalog.ProjectWritable,
        readable: [],
        writable: [],
        env: [],
      ),
      catalog.LspServer(
        name: "go",
        command: ["gopls"],
        extensions: [".go"],
        root_markers: ["go.mod"],
        project: catalog.ProjectReadOnly,
        readable: [catalog.HomePath("go/pkg/mod")],
        writable: [catalog.HomePath(".cache/go-build")],
        env: ["GOFLAGS"],
      ),
    ]
}

// The committed example is the operator's template, so its servers must
// parse as the documentation says they do.
pub fn example_carries_both_documented_servers_test() {
  let assert Ok(text) = simplifile.read("../../docs/examples/loom.toml")
    as "the committed example catalogue must be readable"
  let assert Ok(parsed) = catalog.parse(text)
    as "the committed example catalogue must parse"
  let assert Ok(expected) = catalog.parse(with_lsp(documented))
  assert parsed.lsp_servers == expected.lsp_servers
}

// A bare key must precede every table header, or TOML files it under the
// last one; so this document leads with it.
pub fn lsp_must_be_a_table_test() {
  assert refusal("lsp = 3\n" <> minimal)
    == "lsp must be a table of [lsp.<name>] entries"
}

pub fn a_shell_string_command_is_refused_test() {
  let text =
    with_lsp(
      "\n[lsp.x]\ncommand = \"gopls serve\"\nextensions = [\".x\"]\n"
      <> "root_markers = [\"x.toml\"]\n",
    )
  let assert "lsp.x.command is a string; write the argv as an array" <> _rest =
    refusal(text)
}

pub fn an_empty_command_is_refused_test() {
  let text =
    with_lsp(
      "\n[lsp.x]\ncommand = []\nextensions = [\".x\"]\n"
      <> "root_markers = [\"x.toml\"]\n",
    )
  assert refusal(text) == "lsp.x.command must name at least the executable"
}

pub fn a_missing_command_is_refused_test() {
  let text =
    with_lsp("\n[lsp.x]\nextensions = [\".x\"]\nroot_markers = [\"x.toml\"]\n")
  assert refusal(text) == "lsp.x.command is required"
}

// The defining rule of the table set: one extension, one owner. The
// refusal names both servers, in name order, so an operator knows which
// two tables to reconcile.
pub fn two_servers_claiming_one_extension_are_refused_test() {
  let text =
    with_lsp(
      "\n[lsp.gopls]\ncommand = [\"gopls\"]\nextensions = [\".go\"]\n"
      <> "root_markers = [\"go.mod\"]\n"
      <> "\n[lsp.another]\ncommand = [\"other\"]\n"
      <> "extensions = [\".txt\", \".go\"]\nroot_markers = [\"go.mod\"]\n",
    )
  assert refusal(text)
    == "lsp.another and lsp.gopls both claim .go; one extension has exactly"
    <> " one owning server, so drop it from one of them"
}

pub fn extension_ownership_ignores_case_test() {
  let text =
    with_lsp(
      "\n[lsp.a]\ncommand = [\"a\"]\nextensions = [\".GO\"]\n"
      <> "root_markers = [\"go.mod\"]\n"
      <> "\n[lsp.b]\ncommand = [\"b\"]\nextensions = [\".go\"]\n"
      <> "root_markers = [\"go.mod\"]\n",
    )
  let assert "lsp.a and lsp.b both claim .go" <> _rest = refusal(text)
}

pub fn extensions_are_stored_lowercase_test() {
  let text =
    with_lsp(
      "\n[lsp.x]\ncommand = [\"x\"]\nextensions = [\".GLEAM\"]\n"
      <> "root_markers = [\"gleam.toml\"]\n",
    )
  let assert Ok(parsed) = catalog.parse(text)
  let assert [server] = parsed.lsp_servers
  assert server.extensions == [".gleam"]
}

pub fn an_extension_repeated_in_one_server_is_refused_test() {
  let text =
    with_lsp(
      "\n[lsp.x]\ncommand = [\"x\"]\nextensions = [\".go\", \".Go\"]\n"
      <> "root_markers = [\"go.mod\"]\n",
    )
  assert refusal(text) == "lsp.x.extensions lists .go more than once"
}

pub fn an_extension_without_a_dot_is_refused_test() {
  let text =
    with_lsp(
      "\n[lsp.x]\ncommand = [\"x\"]\nextensions = [\"go\"]\n"
      <> "root_markers = [\"go.mod\"]\n",
    )
  assert refusal(text)
    == "lsp.x.extensions entry \"go\" must begin with a dot, as \".go\" does"
}

pub fn a_bare_dot_extension_is_refused_test() {
  let text =
    with_lsp(
      "\n[lsp.x]\ncommand = [\"x\"]\nextensions = [\".\"]\n"
      <> "root_markers = [\"go.mod\"]\n",
    )
  assert refusal(text) == "lsp.x.extensions entry \".\" names no extension"
}

pub fn extensions_and_root_markers_are_required_and_non_empty_test() {
  let no_extensions =
    with_lsp("\n[lsp.x]\ncommand = [\"x\"]\nroot_markers = [\"go.mod\"]\n")
  assert refusal(no_extensions) == "lsp.x.extensions is required"

  let empty_extensions =
    with_lsp(
      "\n[lsp.x]\ncommand = [\"x\"]\nextensions = []\n"
      <> "root_markers = [\"go.mod\"]\n",
    )
  assert refusal(empty_extensions)
    == "lsp.x.extensions must list at least one entry"

  let no_markers =
    with_lsp("\n[lsp.x]\ncommand = [\"x\"]\nextensions = [\".go\"]\n")
  assert refusal(no_markers) == "lsp.x.root_markers is required"

  let empty_markers =
    with_lsp(
      "\n[lsp.x]\ncommand = [\"x\"]\nextensions = [\".go\"]\n"
      <> "root_markers = []\n",
    )
  assert refusal(empty_markers)
    == "lsp.x.root_markers must list at least one entry"
}

pub fn a_root_marker_must_be_a_bare_file_name_test() {
  let text =
    with_lsp(
      "\n[lsp.x]\ncommand = [\"x\"]\nextensions = [\".go\"]\n"
      <> "root_markers = [\"src/go.mod\"]\n",
    )
  assert refusal(text)
    == "lsp.x.root_markers entry \"src/go.mod\" must be a bare file name, not a path"
}

pub fn project_defaults_to_read_only_test() {
  let assert Ok(parsed) = catalog.parse(one_server(""))
  let assert [server] = parsed.lsp_servers
  assert server.project == catalog.ProjectReadOnly
  assert server.readable == []
  assert server.writable == []
  assert server.env == []
}

pub fn an_unknown_project_word_is_refused_test() {
  assert refusal(one_server("project = \"rw\""))
    == "lsp.x.project must be \"read-only\" or \"writable\", got \"rw\""
}

pub fn a_relative_root_is_refused_test() {
  assert refusal(one_server("readable = [\"go/pkg/mod\"]"))
    == "lsp.x.readable entry \"go/pkg/mod\" must be an absolute path or begin with ~/"
}

pub fn a_tilde_user_root_is_refused_test() {
  let assert "lsp.x.writable entry \"~other/cache\" must be an absolute path" <> _rest =
    refusal(one_server("writable = [\"~other/cache\"]"))
}

pub fn the_whole_home_directory_is_refused_test() {
  let assert "lsp.x.readable entry \"~/\" names the whole home directory" <> _rest =
    refusal(one_server("readable = [\"~/\"]"))
}

pub fn a_dot_dot_component_is_refused_test() {
  assert refusal(one_server("readable = [\"/opt/go/../../etc\"]"))
    == "lsp.x.readable entry \"/opt/go/../../etc\" has a .. component; name the directory itself"
  let assert "lsp.x.writable entry \"~/../other\" has a .. component" <> _rest =
    refusal(one_server("writable = [\"~/../other\"]"))
}

pub fn absolute_roots_parse_in_file_order_test() {
  let assert Ok(parsed) =
    catalog.parse(one_server("readable = [\"/opt/b\", \"/opt/a\", \"~/c\"]"))
  let assert [server] = parsed.lsp_servers
  assert server.readable
    == [
      catalog.AbsolutePath("/opt/b"),
      catalog.AbsolutePath("/opt/a"),
      catalog.HomePath("c"),
    ]
}

pub fn a_root_both_readable_and_writable_is_refused_test() {
  let text = one_server("readable = [\"~/cache\"]\nwritable = [\"~/cache\"]")
  assert refusal(text)
    == "lsp.x lists ~/cache as both readable and writable; list it under one of them"
}

pub fn a_repeated_root_is_refused_test() {
  assert refusal(one_server("readable = [\"/opt/a\", \"/opt/a\"]"))
    == "lsp.x.readable lists /opt/a more than once"
}

pub fn env_names_follow_the_shell_grammar_test() {
  let assert Ok(parsed) =
    catalog.parse(one_server("env = [\"GOFLAGS\", \"_X1\"]"))
  let assert [server] = parsed.lsp_servers
  assert server.env == ["GOFLAGS", "_X1"]

  list.each(["goflags", "1GO", "GO-FLAGS", "GO FLAGS", "ＧＯ"], fn(name) {
    let assert "lsp.x.env entry \"" <> rest =
      refusal(one_server("env = [\"" <> name <> "\"]"))
    assert string.ends_with(
      rest,
      "is not an environment variable name ([A-Z_][A-Z0-9_]*)",
    )
  })
}

pub fn a_server_owned_env_name_is_refused_test() {
  let assert "lsp.x.env may not name PATH" <> _rest =
    refusal(one_server("env = [\"PATH\"]"))
}

pub fn a_repeated_env_name_is_refused_test() {
  assert refusal(one_server("env = [\"GOFLAGS\", \"GOFLAGS\"]"))
    == "lsp.x.env lists GOFLAGS more than once"
}

pub fn an_unknown_key_is_refused_test() {
  let assert "unknown key `writeable` in lsp.x" <> _rest =
    refusal(one_server("writeable = [\"/opt/a\"]"))
}

// Server names meet the `[mcp.<name>]` grammar: the legal-segment check
// and every shape the module-name mangler would rewrite.
pub fn server_names_follow_the_mcp_grammar_test() {
  let named = fn(key: String) {
    with_lsp(
      "\n[lsp."
      <> key
      <> "]\ncommand = [\"x\"]\nextensions = [\".x\"]\n"
      <> "root_markers = [\"x.toml\"]\n",
    )
  }
  let assert "lsp.Gopls is not a legal server name" <> _rest =
    refusal(named("Gopls"))
  let assert "lsp.go-pls is not a legal server name" <> _rest =
    refusal(named("\"go-pls\""))
  let assert "lsp.test is a Gleam keyword" <> _rest = refusal(named("test"))
  let assert "lsp.a__b contains a doubled underscore" <> _rest =
    refusal(named("a__b"))
  let assert "lsp.go_ ends with an underscore" <> _rest = refusal(named("go_"))
  let assert "lsp." <> rest = refusal(named(string.repeat("a", 33)))
  assert string.contains(rest, "is longer than 32 characters")
}

pub fn a_home_path_expands_against_the_given_home_test() {
  assert catalog.expand_lsp_path(
      catalog.HomePath("go/pkg/mod"),
      Some("/home/o"),
    )
    == Ok("/home/o/go/pkg/mod")
  assert catalog.expand_lsp_path(
      catalog.HomePath(".cache/go-build"),
      Some("/home/o/"),
    )
    == Ok("/home/o/.cache/go-build")
  assert catalog.expand_lsp_path(catalog.HomePath("x"), Some("/")) == Ok("/x")
}

pub fn an_absolute_path_ignores_home_test() {
  assert catalog.expand_lsp_path(catalog.AbsolutePath("/opt/go"), None)
    == Ok("/opt/go")
}

pub fn a_home_path_without_a_usable_home_is_refused_test() {
  assert catalog.expand_lsp_path(catalog.HomePath("go"), None)
    == Error("~/go cannot be resolved: the harness's HOME is unset")
  assert catalog.expand_lsp_path(catalog.HomePath("go"), Some("relative"))
    == Error(
      "~/go cannot be resolved: the harness's HOME (relative) is not an absolute path",
    )
}
