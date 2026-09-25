//// The `[lsp.<name>]` tables of `loom.toml`: a language server is
//// configured, never discovered, and its table is the whole of what its
//// jail will grant beyond the project. So these tests hold the parser to
//// the refusals that keep that grant honest — an argv and never a shell
//// string, one owner per extension, absolute or `~/` roots only — as well
//// as to the exact records the documented examples parse to.

import client/catalog
import client/lsp/profile
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import tom

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
hint = \"Qualify a name with its module as imported: probe.greet, or pkg/mod.name for a nested module\"

[lsp.go]
command = [\"gopls\"]
extensions = [\".go\"]
root_markers = [\"go.mod\"]
readable = [\"~/go/pkg/mod\"]
writable = [\"<cache>/go-build\"]
env = [\"GOFLAGS\", \"XDG_CACHE_HOME\"]
hint = \"Qualify a name with its package name as imported: util.Greet\"
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
      profile.LspServer(
        name: "gleam",
        command: ["gleam", "lsp"],
        extensions: [".gleam"],
        root_markers: ["gleam.toml"],
        project: profile.ProjectWritable,
        readable: [],
        writable: [],
        env: [],
        language_id: "gleam",
        qualifier_separators: ["."],
        module_case: profile.AsWritten,
        hint: Some(
          "Qualify a name with its module as imported: probe.greet, or"
          <> " pkg/mod.name for a nested module",
        ),
      ),
      profile.LspServer(
        name: "go",
        command: ["gopls"],
        extensions: [".go"],
        root_markers: ["go.mod"],
        project: profile.ProjectReadOnly,
        readable: [profile.HomePath("go/pkg/mod")],
        writable: [profile.CachePath("go-build")],
        env: ["GOFLAGS", "XDG_CACHE_HOME"],
        language_id: "go",
        qualifier_separators: ["."],
        module_case: profile.AsWritten,
        hint: Some(
          "Qualify a name with its package name as imported: util.Greet",
        ),
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
  assert server.project == profile.ProjectReadOnly
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
    == "lsp.x.readable entry \"go/pkg/mod\" must be an absolute path or begin with ~/ or <cache>/"
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
      profile.AbsolutePath("/opt/b"),
      profile.AbsolutePath("/opt/a"),
      profile.HomePath("c"),
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

// --- expanding a root --------------------------------------------------------

fn home(path: String) -> profile.Places {
  profile.Places(home: Some(path), cache: None)
}

pub fn a_home_path_expands_against_the_given_home_test() {
  assert profile.expand_path(profile.HomePath("go/pkg/mod"), home("/home/o"))
    == Ok("/home/o/go/pkg/mod")
  assert profile.expand_path(
      profile.HomePath(".cache/go-build"),
      home("/home/o/"),
    )
    == Ok("/home/o/.cache/go-build")
  assert profile.expand_path(profile.HomePath("x"), home("/")) == Ok("/x")
}

pub fn an_absolute_path_ignores_both_places_test() {
  assert profile.expand_path(
      profile.AbsolutePath("/opt/go"),
      profile.Places(home: None, cache: None),
    )
    == Ok("/opt/go")
}

pub fn a_home_path_without_a_usable_home_is_refused_test() {
  assert profile.expand_path(
      profile.HomePath("go"),
      profile.Places(home: None, cache: Some("/c")),
    )
    == Error("~/go cannot be resolved: the harness's HOME is unset")
  assert profile.expand_path(profile.HomePath("go"), home("relative"))
    == Error(
      "~/go cannot be resolved: the harness's HOME (relative) is not an absolute path",
    )
}

pub fn a_cache_path_expands_against_the_cache_place_test() {
  let places = profile.Places(home: Some("/home/o"), cache: Some("/var/c/"))
  assert profile.expand_path(profile.CachePath("gopls"), places)
    == Ok("/var/c/gopls")
}

// `<cache>/` with no cache directory is refused as `~/` with no home is,
// never resolved against the working directory.
pub fn a_cache_path_without_a_usable_cache_is_refused_test() {
  assert profile.expand_path(profile.CachePath("gopls"), home("/home/o"))
    == Error(
      "<cache>/gopls cannot be resolved: the harness's cache directory is"
      <> " unknown, because HOME is unset",
    )
  assert profile.expand_path(
      profile.CachePath("gopls"),
      profile.Places(home: None, cache: Some("cache")),
    )
    == Error(
      "<cache>/gopls cannot be resolved: the harness's cache directory"
      <> " (cache) is not an absolute path",
    )
}

// Both platform branches, with the environment passed in: macOS ignores
// XDG_CACHE_HOME, which its Go tools do not read either.
pub fn the_cache_place_on_macos_is_library_caches_test() {
  assert profile.cache_place("darwin", Some("/Users/o"), None)
    == Some("/Users/o/Library/Caches")
  assert profile.cache_place("darwin", Some("/Users/o/"), Some("/xdg"))
    == Some("/Users/o/Library/Caches")
  assert profile.cache_place("darwin", None, Some("/xdg")) == None
}

// Elsewhere an absolute XDG_CACHE_HOME wins, a relative one is ignored as
// the XDG specification says it must be, and ~/.cache is the fallback.
pub fn the_cache_place_elsewhere_follows_xdg_test() {
  assert profile.cache_place("linux", Some("/home/o"), Some("/srv/cache"))
    == Some("/srv/cache")
  assert profile.cache_place("linux", Some("/home/o"), Some("rel/cache"))
    == Some("/home/o/.cache")
  assert profile.cache_place("linux", Some("/home/o/"), None)
    == Some("/home/o/.cache")
  assert profile.cache_place("freebsd", None, Some("/srv/cache"))
    == Some("/srv/cache")
  assert profile.cache_place("linux", None, None) == None
}

// --- <cache>/ roots ------------------------------------------------------------

pub fn a_cache_root_parses_unexpanded_test() {
  let assert Ok(parsed) =
    catalog.parse(one_server("writable = [\"<cache>/gopls\", \"~/gopls\"]"))
  let assert [server] = parsed.lsp_servers
  assert server.writable
    == [profile.CachePath("gopls"), profile.HomePath("gopls")]
}

pub fn a_cache_root_meets_the_home_root_rules_test() {
  let assert "lsp.x.writable entry \"<cache>/\" names the whole cache directory" <> _rest =
    refusal(one_server("writable = [\"<cache>/\"]"))
  assert refusal(one_server("writable = [\"<cache>//gopls\"]"))
    == "lsp.x.writable entry \"<cache>//gopls\" has a doubled slash after <cache>"
  let assert "lsp.x.readable entry \"<cache>/../x\" has a .. component" <> _rest =
    refusal(one_server("readable = [\"<cache>/../x\"]"))
  let assert "lsp.x.readable entry \"<cache>\" must be an absolute path" <> _rest =
    refusal(one_server("readable = [\"<cache>\"]"))
  assert refusal(one_server(
      "readable = [\"<cache>/a\"]\nwritable = [\"<cache>/a\"]",
    ))
    == "lsp.x lists <cache>/a as both readable and writable; list it under one of them"
}

// --- the profile keys ----------------------------------------------------------

// A table naming none of the four keys decodes to exactly what ADR-013
// shipped: the first extension as the id, `.` as the one separator,
// qualifiers compared as written, and no hint.
pub fn the_profile_keys_default_to_the_old_behaviour_test() {
  let text =
    with_lsp(
      "\n[lsp.x]\ncommand = [\"x\"]\nextensions = [\".ts\", \".tsx\"]\n"
      <> "root_markers = [\"x.toml\"]\n",
    )
  let assert Ok(parsed) = catalog.parse(text)
  let assert [server] = parsed.lsp_servers
  assert server.language_id == "ts"
  assert server.qualifier_separators == ["."]
  assert server.module_case == profile.AsWritten
  assert server.hint == None
}

pub fn every_profile_key_is_accepted_test() {
  let assert Ok(parsed) =
    catalog.parse(one_server(
      "language_id = \"typescript\"\n"
      <> "qualifier_separators = [\"::\", \".\"]\n"
      <> "module_case = \"snake\"\n"
      <> "hint = \"Qualify as module::name, without crate::\"",
    ))
  let assert [server] = parsed.lsp_servers
  assert server.language_id == "typescript"
  assert server.qualifier_separators == ["::", "."]
  assert server.module_case == profile.Snake
  assert server.hint == Some("Qualify as module::name, without crate::")

  let assert Ok(parsed) =
    catalog.parse(one_server("module_case = \"as-written\""))
  let assert [server] = parsed.lsp_servers
  assert server.module_case == profile.AsWritten
}

pub fn a_language_id_follows_its_grammar_test() {
  list.each(["c++", "objective-c", "a.b_c", "9p"], fn(id) {
    let assert Ok(parsed) =
      catalog.parse(one_server("language_id = \"" <> id <> "\""))
    let assert [server] = parsed.lsp_servers
    assert server.language_id == id
  })
  list.each(["TypeScript", "-ts", "", "type script", "ｔｓ", "+x"], fn(id) {
    assert refusal(one_server("language_id = \"" <> id <> "\""))
      == "lsp.x.language_id \""
      <> id
      <> "\" is not a language id ([a-z0-9][a-z0-9+._-]*)"
  })
}

pub fn a_language_id_is_at_most_forty_characters_test() {
  let forty = string.repeat("a", 40)
  let assert Ok(parsed) =
    catalog.parse(one_server("language_id = \"" <> forty <> "\""))
  let assert [server] = parsed.lsp_servers
  assert server.language_id == forty
  assert refusal(one_server("language_id = \"" <> forty <> "a\""))
    == "lsp.x.language_id is longer than 40 characters"
}

pub fn a_language_id_must_be_a_string_test() {
  assert refusal(one_server("language_id = 3"))
    == "lsp.x.language_id must be a string"
}

pub fn qualifier_separators_are_checked_one_by_one_test() {
  assert refusal(one_server("qualifier_separators = [\"/\"]"))
    == "lsp.x.qualifier_separators may not list \"/\": a slash inside a"
    <> " qualifier already names a path (pkg/mod.name)"
  assert refusal(one_server("qualifier_separators = [\": :\"]"))
    == "lsp.x.qualifier_separators entry \": :\" may not hold whitespace"
  assert refusal(one_server("qualifier_separators = [\"\\t\"]"))
    == "lsp.x.qualifier_separators entry \"\t\" may not hold whitespace"
  assert refusal(one_server("qualifier_separators = [\"\"]"))
    == "lsp.x.qualifier_separators entries must be non-empty"
  assert refusal(one_server("qualifier_separators = [\"::\", \"::\"]"))
    == "lsp.x.qualifier_separators lists :: more than once"
  assert refusal(one_server("qualifier_separators = []"))
    == "lsp.x.qualifier_separators must list at least one separator"
  assert refusal(one_server("qualifier_separators = \"::\""))
    == "lsp.x.qualifier_separators must be an array of separators such as \"::\""
}

pub fn an_unknown_module_case_is_refused_test() {
  assert refusal(one_server("module_case = \"camel\""))
    == "lsp.x.module_case must be \"as-written\" or \"snake\", got \"camel\""
  assert refusal(one_server("module_case = true"))
    == "lsp.x.module_case must be a string"
}

pub fn a_hint_is_one_short_printable_line_test() {
  assert refusal(one_server("hint = \"one\\ntwo\""))
    == "lsp.x.hint must be one line, with no line break"
  assert refusal(one_server("hint = \"one\\rtwo\""))
    == "lsp.x.hint must be one line, with no line break"
  assert refusal(one_server("hint = \"tab\\there\""))
    == "lsp.x.hint may not hold a control character"
  assert refusal(one_server("hint = \"escape\\e[0m\""))
    == "lsp.x.hint may not hold a control character"

  // TOML has no escape for these two, so they are written raw: a BEL
  // (C0) and a NEL (C1), which is a line break in some renderings.
  assert refusal(one_server("hint = \"bell\u{0007}\""))
    == "lsp.x.hint may not hold a control character"
  assert refusal(one_server("hint = \"c1\u{0085}\""))
    == "lsp.x.hint may not hold a control character"
  assert refusal(one_server("hint = \"del\u{007F}\""))
    == "lsp.x.hint may not hold a control character"
  assert refusal(one_server("hint = \"\"")) == "lsp.x.hint must be non-empty"
  assert refusal(one_server("hint = 1")) == "lsp.x.hint must be a string"
}

// The bound is in bytes, the unit the cached prefix is paid in, so a
// multi-byte character counts for what it costs.
pub fn a_hint_is_at_most_two_hundred_bytes_test() {
  let two_hundred = string.repeat("a", 200)
  let assert Ok(parsed) =
    catalog.parse(one_server("hint = \"" <> two_hundred <> "\""))
  let assert [server] = parsed.lsp_servers
  assert server.hint == Some(two_hundred)
  assert refusal(one_server("hint = \"" <> two_hundred <> "a\""))
    == "lsp.x.hint is longer than 200 bytes"
  assert refusal(one_server("hint = \"" <> string.repeat("é", 101) <> "\""))
    == "lsp.x.hint is longer than 200 bytes"
}

pub fn the_profile_keys_are_known_keys_test() {
  let assert "unknown key `languageId` in lsp.x (allowed: " <> allowed =
    refusal(one_server("languageId = \"ts\""))
  list.each(
    ["language_id", "qualifier_separators", "module_case", "hint"],
    fn(key) {
      assert string.contains(allowed, key)
    },
  )
}

// --- the decoder alone ---------------------------------------------------------

// The decoder an extension manifest will share takes the `[lsp]` table's
// entries directly, and judges ownership across them itself.
pub fn the_decoder_decodes_a_table_set_directly_test() {
  let assert Ok(document) = tom.parse(documented)
  let assert Ok(tom.Table(entries)) = dict.get(document, "lsp")
    as "the documented servers are one [lsp] table"
  let assert Ok(servers) = profile.decode_servers(entries)
  assert list.map(servers, fn(server) { server.name }) == ["gleam", "go"]

  let assert Ok(gleam_table) = dict.get(entries, "gleam")
  let assert Ok(gleam) = profile.decode_server("gleam", gleam_table)
  assert gleam.language_id == "gleam"
  let assert Error(_) = profile.claim_extensions([#(".gleam", "other")], gleam)
    as "an extension another server holds is refused"
}
