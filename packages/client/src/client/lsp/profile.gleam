//// A language profile: one `[lsp.<name>]` table, decoded (ADR-014 §§1–2).
////
//// # Why this is its own module
////
//// A language server is described by data, and the same data may reach the
//// harness from two places: an operator's `loom.toml` and, later, an
//// extension manifest. If each place decoded the table for itself, the two
//// would drift into accepting different things, and a profile copied from
//// an extension into `loom.toml` could stop meaning what it meant there.
//// So there is one decoder, and it lives here rather than in
//// `client/catalog`: `catalog` hands it the `[lsp]` table's entries, and
//// so will whatever decodes a manifest.
////
//// The module is pure. It reads no file and no environment and holds no
//// external. Two facts a profile depends on are the daemon's own, its
//// `HOME` and its per-user cache directory, and both arrive as `Places`
//// from `client/serve`, which is where the environment is read.
////
//// # What a profile carries
////
//// The table is the language server's whole authority. Its `readable` and
//// `writable` roots are what the jail adds beyond the project, so they are
//// operator-written and never model-supplied, a relative path or a `..`
//// component is refused, and each extension has exactly one owning server
//// (`claim_extensions`). Four optional keys carry what a language spells
//// differently: the `languageId` a document is opened with, the separators
//// a qualified symbol is split on, how a qualifier's segments meet
//// directory names, and a one-line hint for the model. Each key's default
//// is exactly what ADR-013 shipped before the key existed, so a table
//// written for that release means what it meant.
////
//// # How a table is decoded
////
//// Decoding is total and strict. Every refusal is a worded `Error` naming
//// `lsp.<name>.<key>`, the line an operator would edit, and an unknown key
//// is refused rather than ignored, because a typo silently dropped here is
//// a server whose jail lacks a root with nothing to say why. Paths stay
//// as written (`~/rest`, `<cache>/rest`) so that decoding is a function of
//// the text alone; `expand_path` resolves them against `Places` once the
//// daemon knows where it is.

import codemode/vet/policy as vet_policy
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tom

// --- the types -------------------------------------------------------------

/// Whether a language server may write into the project it serves.
///
/// Two variants rather than a `Bool` because the question has a domain
/// answer an operator states in words (`project = "read-only"` or
/// `"writable"`), and the jail built from it later reads the variant at
/// its case arm. The distinction is measured, not assumed: `gleam lsp`
/// writes `manifest.toml` and `build/` into the project it analyses,
/// while `gopls` writes nothing there.
pub type ProjectAccess {
  /// The server reads the project and writes nothing into it. The
  /// default, because a server that needs more has to be named as such.
  ProjectReadOnly

  /// The server writes into the project, as `gleam lsp` does when it
  /// builds the dependency manifest and the `build/` tree.
  ProjectWritable
}

/// One operator-supplied extra root a jailed language server needs, as
/// the file wrote it.
///
/// A `~/` or `<cache>/` path is kept unexpanded here so that decoding
/// stays a pure function of the file's text. `expand_path` turns it into
/// a host path once the caller supplies the harness's own `Places`.
pub type LspPath {
  /// An absolute host path, starting with `/`.
  AbsolutePath(path: String)

  /// A path under the operator's home directory, written `~/<rest>`;
  /// `rest` is non-empty and carries no leading slash.
  HomePath(rest: String)

  /// A path under the daemon's per-user cache directory, written
  /// `<cache>/<rest>`; `rest` is non-empty and carries no leading slash.
  /// Which directory that is depends on the platform (`cache_place`),
  /// which is why a profile names it this way rather than as a `~/` path
  /// that is right on one platform only.
  CachePath(rest: String)
}

/// How a qualifier's segments are compared with directory and file names.
///
/// Gleam, Go and Python lay a module out on disk under the name code
/// spells it with, so the comparison is verbatim. Elixir and Ruby spell a
/// module `MyApp.Accounts` and keep it in `my_app/accounts.ex`, so a
/// qualifier has to be mapped before it can meet the path.
pub type ModuleCase {
  /// Segments are compared as written. The default, and what ADR-013
  /// shipped.
  AsWritten

  /// Each segment is mapped from CamelCase to snake_case first:
  /// `MyApp` is `my_app`, `HTTPServer` is `http_server`, and a segment
  /// already in snake_case is unchanged.
  Snake
}

/// One configured language server: an `[lsp.<name>]` table.
///
/// Servers are configured, never discovered (ADR-013 §6). Each is the
/// only owner of the file extensions it lists, and is jailed with the
/// project it serves plus exactly the extra roots written here.
///
/// Constructor invariants (guaranteed by `decode_server` and
/// `decode_servers`, owed by any direct construction): `name` follows the
/// `[mcp.<name>]` key grammar (`[a-z][a-z0-9_]*`, no keyword, no doubled
/// or trailing underscore, at most 32 characters) and is unique;
/// `command` is a non-empty argv of non-empty strings; `extensions` is
/// non-empty, each entry lowercase, starting with `.`, listed once, and
/// owned by no other server in the set; `root_markers` is non-empty, each
/// a bare file name listed once; no path in `readable` or `writable`
/// holds a `..` component, none is listed twice, and none appears in
/// both; every `env` name matches `[A-Z_][A-Z0-9_]*`, is listed once, and
/// is none of the names the server owns (`PATH`, `HOME`, `TMPDIR`, ...);
/// `language_id` is non-empty; `qualifier_separators` is non-empty, each
/// entry non-empty, free of whitespace, not `/`, and listed once; `hint`,
/// when present, is one non-empty line of at most 200 bytes with no
/// control character.
pub type LspServer {
  LspServer(
    /// The table key, which names the server in tool output and errors.
    name: String,
    /// The server's argv, executable first. Never a shell string.
    command: List(String),
    /// The file extensions this server answers for, lowercase, each with
    /// its leading dot, in file order.
    extensions: List(String),
    /// File names marking a project root: the nearest ancestor of a file
    /// holding one of these is the root the server is started in.
    root_markers: List(String),
    /// Whether the server may write into that project root.
    project: ProjectAccess,
    /// Extra roots the jailed server may read, in file order.
    readable: List(LspPath),
    /// Extra roots the jailed server may write, in file order.
    writable: List(LspPath),
    /// Host environment variable *names* passed through to the server.
    /// The values are read from the harness's environment when it
    /// spawns, never from this file, the discipline `api_key_env` keeps.
    env: List(String),
    /// The `languageId` every document is opened with. Always filled:
    /// written, it matches `[a-z0-9][a-z0-9+._-]*` in at most 40
    /// characters; omitted, it is the first extension without its dot,
    /// which is right for `gleam` and `go` and wrong for TypeScript
    /// (`typescript`, not `ts`).
    language_id: String,
    /// What a qualified symbol is split on, as written; the resolver
    /// tries the longest first. `["."]` when omitted. `/` is never one,
    /// because it already means a path inside a qualifier (`pkg/mod.name`).
    qualifier_separators: List(String),
    /// How a qualifier's segments meet directory and file names.
    /// `AsWritten` when omitted.
    module_case: ModuleCase,
    /// One line telling the model how this language spells a qualified
    /// name, appended to `lsp_definition`'s description. Operator-approved
    /// text in the model's context, as an extension's tool description
    /// is; `None` adds nothing.
    hint: Option(String),
  )
}

/// Where the two unexpanded path forms resolve: the daemon's own `HOME`
/// and its per-user cache directory, each `None` when the daemon's
/// environment names none.
///
/// Both are the daemon's, never a jailed session's (whose `HOME` is under
/// the workspace) and never anything a model supplies. `client/serve`
/// builds this once, from `home_directory` and `cache_place`.
pub type Places {
  Places(
    /// The directory `~/` names.
    home: Option(String),
    /// The directory `<cache>/` names.
    cache: Option(String),
  )
}

// --- decoding the set ------------------------------------------------------

/// Decodes every `[lsp.<name>]` table: the entries of the `[lsp]` table,
/// keyed by server name.
///
/// The servers come back sorted by name, since a TOML table has no order
/// and everything derived from the set (the tool description's hints, the
/// order a bare-name search visits servers) must be the same on every
/// boot. Each server is decoded alone first; extension ownership is a
/// property of the whole set, so it is judged once every server has been
/// read, in name order, which makes a refusal name the same pair of
/// servers every time.
///
/// ## Examples
///
/// ```gleam
/// assert profile.decode_servers(dict.new()) == Ok([])
/// ```
///
pub fn decode_servers(
  tables: Dict(String, tom.Toml),
) -> Result(List(LspServer), String) {
  use servers <- result.try(
    dict.to_list(tables)
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
    |> list.try_map(fn(entry) { decode_server(entry.0, entry.1) }),
  )
  use _owners <- result.try(list.try_fold(servers, [], claim_extensions))
  Ok(servers)
}

/// Adds one server's extensions to the owners claimed so far, or refuses
/// the pair of servers that claim one extension between them.
///
/// One extension, one owner. Two servers answering `.go` would leave which
/// one a file reaches to dict order, and a model reading diagnostics from
/// the wrong one has no way to tell. `owners` maps each extension already
/// claimed to the server that claimed it. A server's own list is already
/// free of repeats, so a hit here is always another server. Folded over a
/// list of servers from `[]`, as `decode_servers` does.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(owners) = profile.claim_extensions([], go)
/// // owners == [#(".go", "go")]
/// // profile.claim_extensions(owners, other_go)
/// //   -> Error("lsp.go and lsp.other_go both claim .go; ...")
/// ```
///
pub fn claim_extensions(
  owners: List(#(String, String)),
  server: LspServer,
) -> Result(List(#(String, String)), String) {
  list.try_fold(server.extensions, owners, fn(owners, extension) {
    case list.key_find(owners, extension) {
      Error(Nil) -> Ok([#(extension, server.name), ..owners])
      Ok(owner) ->
        Error(
          "lsp."
          <> owner
          <> " and lsp."
          <> server.name
          <> " both claim "
          <> extension
          <> "; one extension has exactly one owning server, so drop it"
          <> " from one of them",
        )
    }
  })
}

// --- decoding one table ----------------------------------------------------

// Every key a table may hold. Anything else is refused by name.
const table_keys = [
  "command", "extensions", "root_markers", "project", "readable", "writable",
  "env", "language_id", "qualifier_separators", "module_case", "hint",
]

/// Decodes one `[lsp.<name>]` table, `value`, under its key `name`.
///
/// Checks the name, every key, and each value, and fills the four
/// optional profile keys with their defaults. Extension ownership across
/// servers is not judged here, since one table cannot see another; a
/// caller decoding a set folds `claim_extensions` over it, as
/// `decode_servers` does.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(table) = tom.parse("command = [\"gopls\"]\n...")
/// // let assert Ok(go) = profile.decode_server("go", tom.Table(table))
/// // go.language_id == "go"
/// // go.qualifier_separators == ["."]
/// ```
///
pub fn decode_server(
  name: String,
  value: tom.Toml,
) -> Result(LspServer, String) {
  let place = "lsp." <> name
  use Nil <- result.try(server_name(name))
  use fields <- result.try(case value {
    tom.Table(fields) | tom.InlineTable(fields) -> Ok(fields)
    _ -> Error(place <> " must be a table")
  })

  // Unknown keys are refused as `[mcp.<name>]` refuses them. Here it
  // matters more: a typoed `writeable` silently ignored would start a
  // server whose cache writes fail in the jail, and the operator would
  // be told nothing about why.
  use Nil <- result.try(known_keys(dict.keys(fields), table_keys, place))
  use command <- result.try(command(fields, place))
  use extensions <- result.try(extensions(fields, place))
  use root_markers <- result.try(root_markers(fields, place))
  use project <- result.try(project(fields, place))

  // The extra roots are the whole of what the jail grants beyond the
  // project. A root in both lists is two answers to "may the server
  // write here", so it is refused rather than resolved in either
  // direction.
  use readable <- result.try(paths(fields, place, "readable"))
  use writable <- result.try(paths(fields, place, "writable"))
  use Nil <- result.try(disjoint_roots(place, readable, writable))
  use env <- result.try(env(fields, place))

  // The profile keys. Each default is the behaviour ADR-013 shipped
  // before the key existed, so an older table decodes to a server that
  // behaves exactly as it did.
  use language_id <- result.try(language_id(fields, place, extensions))
  use qualifier_separators <- result.try(qualifier_separators(fields, place))
  use module_case <- result.try(module_case(fields, place))
  use hint <- result.try(hint(fields, place))
  Ok(LspServer(
    name:,
    command:,
    extensions:,
    root_markers:,
    project:,
    readable:,
    writable:,
    env:,
    language_id:,
    qualifier_separators:,
    module_case:,
    hint:,
  ))
}

// The `[mcp.<name>]` grammar, held for one reason rather than two: an
// LSP server's name becomes no module, but it is the name the harness
// prints in every tool result and refusal, and one grammar for both
// server tables keeps any key an operator writes valid in either.
// `internal` is not reserved here; that reservation is about the
// `cap/internal` module tree, which an LSP name never enters.
fn server_name(name: String) -> Result(Nil, String) {
  let legal =
    !string.contains(name, "/") && vet_policy.is_legal_module_name(name)
  use Nil <- result.try(case legal {
    True -> Ok(Nil)
    False ->
      Error(
        "lsp."
        <> name
        <> " is not a legal server name: [lsp.<name>] keys follow the"
        <> " [mcp.<name>] grammar, a single lowercase-ASCII identifier"
        <> " segment ([a-z][a-z0-9_]*)",
      )
  })
  case mangling_fault(name) {
    Ok(Nil) -> Ok(Nil)
    Error(what) ->
      Error(
        "lsp."
        <> name
        <> " "
        <> what
        <> ", which the [mcp.<name>] key grammar refuses too; pick another"
        <> " server name",
      )
  }
}

// The Gleam keywords a module segment may not be. The code-mode
// generator's name mangler digests any `[mcp.<name>]` key it has to
// change, so a key it would change becomes cap/mcp/<name>_<8hex> rather
// than the module the catalogue promises; refusing every mangle-altered
// shape keeps that contract provable, and an `[lsp.<name>]` key is held
// to the same shapes so one name is legal in either table.
const gleam_keywords = [
  "as", "assert", "auto", "case", "const", "delegate", "derive", "echo", "else",
  "fn", "if", "implement", "import", "let", "macro", "opaque", "panic", "pub",
  "test", "todo", "type", "use",
]

// The mangler's own bound (`mcp/name`'s `max_length`), past which a name
// is truncated and digested. Restated rather than imported because this
// package does not depend on `mcp`; the tests hold both ends to 32.
const max_mangled_length = 32

/// The shapes the code-mode module-name mangler would rewrite, each as
/// the phrase a refusal completes, or `Ok(Nil)` for a name it leaves
/// alone.
///
/// Shared by both server tables, so an `[lsp.<name>]` key and an
/// `[mcp.<name>]` key meet one grammar: `client/catalog` words its MCP
/// refusal around the same phrase. It lives here rather than there
/// because this module cannot import `catalog`, which imports it.
///
/// ## Examples
///
/// ```gleam
/// assert profile.mangling_fault("gopls") == Ok(Nil)
/// ```
///
/// ```gleam
/// assert profile.mangling_fault("test") == Error("is a Gleam keyword")
/// ```
///
pub fn mangling_fault(name: String) -> Result(Nil, String) {
  case
    list.contains(gleam_keywords, name),
    string.contains(name, "__"),
    string.ends_with(name, "_"),
    // Asks whether the name is longer than the bound without walking a
    // pathological key to its end (lint R5).
    string.drop_start(name, max_mangled_length) != ""
  {
    True, _, _, _ -> Error("is a Gleam keyword")
    _, True, _, _ -> Error("contains a doubled underscore")
    _, _, True, _ -> Error("ends with an underscore")
    _, _, _, True -> Error("is longer than 32 characters")
    False, False, False, False -> Ok(Nil)
  }
}

// The server's argv: a TOML array of non-empty strings, executable
// first, so at least one element. A string `command` is refused by name
// rather than as a mistyped value, because it is the mistake an operator
// copying a shell line makes, and the harness never runs a string through
// a shell: the argv is exec'd as written, element by element.
fn command(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(String), String) {
  use items <- result.try(case dict.get(fields, "command") {
    Ok(tom.Array(items)) -> Ok(items)
    Ok(tom.String(_shell)) ->
      Error(
        place
        <> ".command is a string; write the argv as an array of strings"
        <> " (command = [\"gopls\"]) — a shell string is never run",
      )
    Ok(_other) ->
      Error(place <> ".command must be an array of strings (the argv)")
    Error(Nil) -> Error(place <> ".command is required")
  })
  use argv <- result.try(
    list.try_map(items, fn(item) {
      case item {
        tom.String("") ->
          Error(place <> ".command elements must be non-empty strings")
        tom.String(text) -> Ok(text)
        _other ->
          Error(place <> ".command must be an array of strings (the argv)")
      }
    }),
  )
  case argv {
    [] -> Error(place <> ".command must name at least the executable")
    _some -> Ok(argv)
  }
}

// Extensions are compared lowercased, so `.GO` and `.go` are one
// extension and one owner. Each must carry its leading dot and name
// something after it; a `/` would make it a path rather than a suffix.
fn extensions(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(String), String) {
  let at = place <> ".extensions"
  use written <- result.try(required_strings(
    fields,
    place,
    "extensions",
    "an array of file extensions such as \".go\"",
  ))
  use extensions <- result.try(
    list.try_map(written, fn(extension) { one_extension(at, extension) }),
  )
  use Nil <- result.try(listed_once(at, extensions))
  Ok(extensions)
}

fn one_extension(at: String, written: String) -> Result(String, String) {
  let lowered = string.lowercase(written)
  case lowered, string.contains(lowered, "/") {
    ".", _ -> Error(at <> " entry \".\" names no extension")
    "." <> _suffix, False -> Ok(lowered)
    "." <> _suffix, True ->
      Error(at <> " entry \"" <> written <> "\" must be a suffix, not a path")
    _other, _ ->
      Error(
        at
        <> " entry \""
        <> written
        <> "\" must begin with a dot, as \".go\" does",
      )
  }
}

// A root marker is looked for by name in each ancestor directory, so it
// is a bare file name: a path, `.` or `..` would be looked for somewhere
// other than the ancestor being asked about.
fn root_markers(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(String), String) {
  let at = place <> ".root_markers"
  use markers <- result.try(required_strings(
    fields,
    place,
    "root_markers",
    "an array of file names such as \"go.mod\"",
  ))
  use Nil <- result.try(
    list.try_each(markers, fn(marker) {
      case marker, string.contains(marker, "/") {
        ".", _ | "..", _ ->
          Error(at <> " entry \"" <> marker <> "\" is not a file name")
        _name, True ->
          Error(
            at
            <> " entry \""
            <> marker
            <> "\" must be a bare file name, not a path",
          )
        _name, False -> Ok(Nil)
      }
    }),
  )
  use Nil <- result.try(listed_once(at, markers))
  Ok(markers)
}

// Read-only is the default because a server that writes into the
// project has to be named as one: it is the operator saying the
// project's `build/` may change under the model's feet.
fn project(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(ProjectAccess, String) {
  case optional_string(fields, place, "project") {
    Ok(Ok("read-only")) | Ok(Error(Nil)) -> Ok(ProjectReadOnly)
    Ok(Ok("writable")) -> Ok(ProjectWritable)
    Ok(Ok(other)) ->
      Error(
        place
        <> ".project must be \"read-only\" or \"writable\", got \""
        <> other
        <> "\"",
      )
    Error(message) -> Error(message)
  }
}

// --- the extra roots -------------------------------------------------------

// One `readable` or `writable` list, in file order. Duplicates are
// judged on the text as written, before any `~/` or `<cache>/` is
// expanded, so the refusal quotes the line the operator would edit.
fn paths(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(List(LspPath), String) {
  let at = place <> "." <> key
  use written <- result.try(optional_strings(
    fields,
    place,
    key,
    "an array of absolute, ~/ or <cache>/ paths",
  ))
  use Nil <- result.try(listed_once(at, written))
  list.try_map(written, fn(path) { one_path(at, path) })
}

// A root is absolute, under the operator's home, or under the per-user
// cache, and never relative: a relative root would be judged against
// whatever directory the server happened to start in, which is the
// project the model writes to. A `..` component is refused in every
// form, because the jail compares roots by component and never resolves
// them, so `..` would grant a directory the line does not name.
fn one_path(at: String, written: String) -> Result(LspPath, String) {
  use Nil <- result.try(case list.contains(string.split(written, "/"), "..") {
    True ->
      Error(
        at
        <> " entry \""
        <> written
        <> "\" has a .. component; name the directory itself",
      )
    False -> Ok(Nil)
  })
  case written {
    "/" <> _beneath -> Ok(AbsolutePath(written))
    "~/" <> rest -> beneath_place(at, written, rest, "~", "home", HomePath)
    "<cache>/" <> rest ->
      beneath_place(at, written, rest, "<cache>", "cache", CachePath)
    _relative ->
      Error(
        at
        <> " entry \""
        <> written
        <> "\" must be an absolute path or begin with ~/ or <cache>/",
      )
  }
}

// `~/` or `<cache>/` alone would grant the whole directory — for the home
// that is credentials, shell history and every other project, and for the
// cache every other program's cached state — which no language server
// needs, so it is refused and the operator names the directory the server
// does need. `form` is the prefix as written and `what` names the place in
// the refusal.
fn beneath_place(
  at: String,
  written: String,
  rest: String,
  form: String,
  what: String,
  make: fn(String) -> LspPath,
) -> Result(LspPath, String) {
  case rest {
    "" ->
      Error(
        at
        <> " entry \""
        <> written
        <> "\" names the whole "
        <> what
        <> " directory; name the directory the server needs",
      )
    "/" <> _doubled ->
      Error(
        at <> " entry \"" <> written <> "\" has a doubled slash after " <> form,
      )
    _beneath -> Ok(make(rest))
  }
}

fn disjoint_roots(
  place: String,
  readable: List(LspPath),
  writable: List(LspPath),
) -> Result(Nil, String) {
  list.try_each(writable, fn(path) {
    case list.contains(readable, path) {
      False -> Ok(Nil)
      True ->
        Error(
          place
          <> " lists "
          <> path_text(path)
          <> " as both readable and writable; list it under one of them",
        )
    }
  })
}

// The path as the operator wrote it, for a refusal to quote.
fn path_text(path: LspPath) -> String {
  case path {
    AbsolutePath(path) -> path
    HomePath(rest) -> "~/" <> rest
    CachePath(rest) -> "<cache>/" <> rest
  }
}

// --- the environment names ---------------------------------------------------

// Names only, validated to the portable shell grammar; the values are
// read from the harness's environment when the server spawns, never
// from this file. The names the server owns are refused for the reason
// `[tools] env` refuses them: a language server whose `PATH` came from
// the host would resolve a different toolchain than the one the jail
// was built around.
fn env(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(String), String) {
  let at = place <> ".env"
  use names <- result.try(optional_strings(
    fields,
    place,
    "env",
    "an array of environment variable names",
  ))
  use Nil <- result.try(list.try_each(names, fn(name) { env_name(at, name) }))
  use Nil <- result.try(
    list.try_each(names, fn(name) { not_server_owned(at, name) }),
  )
  use Nil <- result.try(listed_once(at, names))
  Ok(names)
}

const env_name_head = "ABCDEFGHIJKLMNOPQRSTUVWXYZ_"

const env_name_tail = "ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789"

// `[A-Z_][A-Z0-9_]*`, checked a grapheme at a time against the two
// alphabets. A multi-codepoint grapheme is in neither, so a lookalike
// letter is refused rather than normalised into a different name.
fn env_name(at: String, name: String) -> Result(Nil, String) {
  case in_grammar(name, env_name_head, env_name_tail) {
    True -> Ok(Nil)
    False ->
      Error(
        at
        <> " entry \""
        <> name
        <> "\" is not an environment variable name ([A-Z_][A-Z0-9_]*)",
      )
  }
}

// The names `client/serve.session_environment` builds from the
// workspace and the toolchain code mode discovered. They are refused
// here rather than silently ignored downstream: a shell whose `PATH`
// came from this file would resolve a different `gleam` than the one the
// compiler uses, and one whose `HOME` did would source the operator's
// own dotfiles from inside the jail. LOOM_SCRATCH_DIR is filled by the
// helper only after the execution's scratch has been prepared. The Git
// global path selects the identity-only defaults prepared before model work.
const server_owned_names = [
  "PATH",
  "HOME",
  "TMPDIR",
  "LOOM_SCRATCH_DIR",
  "GIT_CONFIG_GLOBAL",
]

/// Refuses an environment name the harness owns in every jailed child:
/// `PATH`, `HOME`, `TMPDIR`, `LOOM_SCRATCH_DIR` and `GIT_CONFIG_GLOBAL`.
/// `place` is the key being decoded, for the refusal to name.
///
/// A profile's `env` and the catalogue's `[tools] env` and `[tools.set]`
/// share this one list, so a name refused in one is refused in all; it
/// lives here because this module cannot import `client/catalog`, which
/// imports it.
///
/// ## Examples
///
/// ```gleam
/// assert profile.not_server_owned("lsp.go.env", "GOFLAGS") == Ok(Nil)
/// ```
///
/// ```gleam
/// let assert Error(_) = profile.not_server_owned("tools.env", "PATH")
/// ```
///
pub fn not_server_owned(place: String, name: String) -> Result(Nil, String) {
  case list.contains(server_owned_names, name) {
    False -> Ok(Nil)
    True ->
      Error(
        place
        <> " may not name "
        <> name
        <> ": PATH, HOME, TMPDIR, LOOM_SCRATCH_DIR and GIT_CONFIG_GLOBAL are owned by the"
        <> " server and jail helper so tools use the selected toolchain,"
        <> " workspace and scratch directory",
      )
  }
}

// --- the profile keys --------------------------------------------------------

const language_id_head = "abcdefghijklmnopqrstuvwxyz0123456789"

const language_id_tail = "abcdefghijklmnopqrstuvwxyz0123456789+._-"

const max_language_id_length = 40

// The `languageId` a document is opened with. The default is the one
// ADR-013 hard-wired, the first extension without its dot, and is not
// held to the grammar: an extension such as `.h++` is a legal suffix
// today, and a table that names none of the new keys must keep the id it
// had. A written id is held to a grammar every id the LSP specification
// lists fits (`typescriptreact`, `objective-cpp`, `shellscript`), so a
// typo that could never be an id is refused rather than sent to a server
// that ignores it.
fn language_id(
  fields: Dict(String, tom.Toml),
  place: String,
  extensions: List(String),
) -> Result(String, String) {
  case optional_string(fields, place, "language_id") {
    Ok(Error(Nil)) -> Ok(default_language_id(extensions))
    Ok(Ok(written)) -> written_language_id(place <> ".language_id", written)
    Error(message) -> Error(message)
  }
}

// The first extension without its dot. `required_strings` has already
// refused an empty `extensions`, so the empty arm is unreachable from a
// decoded table; it answers the empty id rather than crash.
fn default_language_id(extensions: List(String)) -> String {
  case extensions {
    [first, ..] -> string.drop_start(first, 1)
    [] -> ""
  }
}

// The length is judged first so the grammar walk is bounded by it, and
// without walking an oversized value to its end (lint R5).
fn written_language_id(at: String, written: String) -> Result(String, String) {
  use Nil <- result.try(
    case string.drop_start(written, max_language_id_length) {
      "" -> Ok(Nil)
      _longer -> Error(at <> " is longer than 40 characters")
    },
  )
  case in_grammar(written, language_id_head, language_id_tail) {
    True -> Ok(written)
    False ->
      Error(
        at
        <> " \""
        <> written
        <> "\" is not a language id ([a-z0-9][a-z0-9+._-]*)",
      )
  }
}

// The separators a qualified symbol is split on. `/` is refused because
// it already has a meaning inside a qualifier, a path (`pkg/mod.name`),
// and a separator made of whitespace could never be written in a symbol
// the model passes as one word. An empty list is refused rather than
// read as "never split": omitting the key is how a table says it wants
// the default, and a table that wants no qualification at all loses
// nothing by keeping `.`, since a name with no separator in it is its own
// identifier either way.
fn qualifier_separators(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(String), String) {
  case dict.has_key(fields, "qualifier_separators") {
    False -> Ok(["."])
    True -> written_separators(fields, place)
  }
}

fn written_separators(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(String), String) {
  let at = place <> ".qualifier_separators"
  use separators <- result.try(optional_strings(
    fields,
    place,
    "qualifier_separators",
    "an array of separators such as \"::\"",
  ))
  use Nil <- result.try(case separators {
    [] -> Error(at <> " must list at least one separator")
    [_, ..] -> Ok(Nil)
  })
  use Nil <- result.try(
    list.try_each(separators, fn(separator) { one_separator(at, separator) }),
  )
  use Nil <- result.try(listed_once(at, separators))
  Ok(separators)
}

fn one_separator(at: String, separator: String) -> Result(Nil, String) {
  let spaced =
    string.to_graphemes(separator)
    |> list.any(fn(grapheme) { string.trim(grapheme) == "" })
  case separator, spaced {
    "/", _ ->
      Error(
        at
        <> " may not list \"/\": a slash inside a qualifier already names a"
        <> " path (pkg/mod.name)",
      )
    _, True ->
      Error(at <> " entry \"" <> separator <> "\" may not hold whitespace")
    _, False -> Ok(Nil)
  }
}

fn module_case(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(ModuleCase, String) {
  case optional_string(fields, place, "module_case") {
    Ok(Ok("as-written")) | Ok(Error(Nil)) -> Ok(AsWritten)
    Ok(Ok("snake")) -> Ok(Snake)
    Ok(Ok(other)) ->
      Error(
        place
        <> ".module_case must be \"as-written\" or \"snake\", got \""
        <> other
        <> "\"",
      )
    Error(message) -> Error(message)
  }
}

const max_hint_bytes = 200

// The hint is text the model reads inside a tool description, which is
// the cached prefix of every request. One printable line keeps it from
// forging structure there (a line break could start what reads as a new
// paragraph of instructions) and 200 bytes bounds what one server adds to
// every request of every session that configures it (ADR-014, "What it
// costs"). The line break is refused by name before the general control
// check, since it is the one an operator is likely to write.
fn hint(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Option(String), String) {
  let at = place <> ".hint"
  case optional_string(fields, place, "hint") {
    Ok(Error(Nil)) -> Ok(None)
    Ok(Ok("")) -> Error(at <> " must be non-empty")
    Ok(Ok(written)) -> written_hint(at, written)
    Error(message) -> Error(message)
  }
}

fn written_hint(at: String, written: String) -> Result(Option(String), String) {
  let codepoints =
    string.to_utf_codepoints(written) |> list.map(string.utf_codepoint_to_int)
  let broken = list.any(codepoints, fn(code) { code == 0x0A || code == 0x0D })
  let control = list.any(codepoints, is_control)
  case broken, control, string.byte_size(written) > max_hint_bytes {
    True, _, _ -> Error(at <> " must be one line, with no line break")
    False, True, _ -> Error(at <> " may not hold a control character")
    False, False, True -> Error(at <> " is longer than 200 bytes")
    False, False, False -> Ok(Some(written))
  }
}

// C0, DEL and C1: every code point Unicode classes as a control.
fn is_control(code: Int) -> Bool {
  code < 0x20 || { code >= 0x7F && code <= 0x9F }
}

// --- expanding a root --------------------------------------------------------

/// Resolves one configured extra root to the host path a language
/// server's jail binds.
///
/// `places` is the daemon's own, as `client/serve` reads it from its
/// process environment; see `Places`. An `AbsolutePath` ignores it. A
/// `HomePath` with no home, or a `CachePath` with no cache directory, is
/// refused, as is either place when it is not absolute, rather than
/// resolved against the working directory.
///
/// ## Examples
///
/// ```gleam
/// assert profile.expand_path(
///     profile.HomePath("go/pkg/mod"),
///     profile.Places(home: Some("/home/o"), cache: None),
///   )
///   == Ok("/home/o/go/pkg/mod")
/// ```
///
/// ```gleam
/// assert profile.expand_path(
///     profile.CachePath("gopls"),
///     profile.Places(home: None, cache: Some("/home/o/.cache")),
///   )
///   == Ok("/home/o/.cache/gopls")
/// ```
///
pub fn expand_path(path: LspPath, places: Places) -> Result(String, String) {
  case path {
    AbsolutePath(path) -> Ok(path)
    HomePath(rest) ->
      beneath(places.home, "~/" <> rest, rest, "the harness's HOME", "unset")
    CachePath(rest) ->
      beneath(
        places.cache,
        "<cache>/" <> rest,
        rest,
        "the harness's cache directory",
        "unknown, because HOME is unset",
      )
  }
}

// `rest` under `place`, or the refusal naming `written`. `what` names the
// place and `absent` completes "... is" when there is none.
fn beneath(
  place: Option(String),
  written: String,
  rest: String,
  what: String,
  absent: String,
) -> Result(String, String) {
  case place {
    Some("/" <> below) -> Ok(strip_trailing_slash("/" <> below) <> "/" <> rest)
    Some(relative) ->
      Error(
        written
        <> " cannot be resolved: "
        <> what
        <> " ("
        <> relative
        <> ") is not an absolute path",
      )
    None ->
      Error(written <> " cannot be resolved: " <> what <> " is " <> absent)
  }
}

fn strip_trailing_slash(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> strip_trailing_slash(string.drop_end(path, 1))
    False -> path
  }
}

/// The per-user cache directory `<cache>/` names, from the daemon's
/// operating system name (`ffi_os.platform`'s first element), its `HOME`
/// and its `XDG_CACHE_HOME`, or `None` when there is none to name.
///
/// On macOS it is `$HOME/Library/Caches`, which is where `gopls` and
/// `go build` keep their caches there; `XDG_CACHE_HOME` is not consulted,
/// since those tools do not consult it on macOS either. Elsewhere it is
/// `$XDG_CACHE_HOME` when that is set to an absolute path, as the XDG
/// base-directory specification requires of it, and `$HOME/.cache`
/// otherwise. Pure, so both platforms are tested on either;
/// `client/serve` reads the three facts once and passes them in.
///
/// ## Examples
///
/// ```gleam
/// assert profile.cache_place("darwin", Some("/Users/o"), Some("/x"))
///   == Some("/Users/o/Library/Caches")
/// ```
///
/// ```gleam
/// assert profile.cache_place("linux", Some("/home/o"), None)
///   == Some("/home/o/.cache")
/// ```
///
pub fn cache_place(
  os: String,
  home: Option(String),
  xdg_cache_home: Option(String),
) -> Option(String) {
  case os, xdg_cache_home {
    "darwin", _ ->
      option.map(home, fn(home) {
        strip_trailing_slash(home) <> "/Library/Caches"
      })
    _other, Some("/" <> below) -> Some("/" <> below)
    _other, Some(_relative) | _other, None ->
      option.map(home, fn(home) { strip_trailing_slash(home) <> "/.cache" })
  }
}

// --- field helpers -----------------------------------------------------------

// The present keys must all be known ones.
fn known_keys(
  present: List(String),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  case list.find(present, fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in "
        <> place
        <> " (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}

// Ok(Ok(text)) present, Ok(Error(Nil)) absent, Error(message) mistyped.
fn optional_string(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(Result(String, Nil), String) {
  case dict.get(fields, key) {
    Ok(tom.String(text)) -> Ok(Ok(text))
    Ok(_other) -> Error(place <> "." <> key <> " must be a string")
    Error(Nil) -> Ok(Error(Nil))
  }
}

// A TOML array of non-empty strings, `[]` when the key is absent.
// `shape` completes "must be ..." for a value of the wrong type.
fn optional_strings(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
  shape: String,
) -> Result(List(String), String) {
  let at = place <> "." <> key
  use items <- result.try(case dict.get(fields, key) {
    Ok(tom.Array(items)) -> Ok(items)
    Ok(_other) -> Error(at <> " must be " <> shape)
    Error(Nil) -> Ok([])
  })
  list.try_map(items, fn(item) {
    case item {
      tom.String("") -> Error(at <> " entries must be non-empty")
      tom.String(text) -> Ok(text)
      _other -> Error(at <> " must be " <> shape)
    }
  })
}

// `optional_strings` for a key that must be present and list at least
// one entry: a server with no extensions answers for no file, and one
// with no root markers has no project to start in.
fn required_strings(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
  shape: String,
) -> Result(List(String), String) {
  let at = place <> "." <> key
  use Nil <- result.try(case dict.has_key(fields, key) {
    True -> Ok(Nil)
    False -> Error(at <> " is required")
  })
  use values <- result.try(optional_strings(fields, place, key, shape))
  case values {
    [] -> Error(at <> " must list at least one entry")
    _some -> Ok(values)
  }
}

// Each value once, naming the first repeat.
fn listed_once(at: String, values: List(String)) -> Result(Nil, String) {
  list.try_fold(values, [], fn(seen, value) {
    case list.contains(seen, value) {
      True -> Error(at <> " lists " <> value <> " more than once")
      False -> Ok([value, ..seen])
    }
  })
  |> result.replace(Nil)
}

// Whether `text` is one grapheme of `head` followed by any number of
// `tail`, checked a grapheme at a time. A multi-codepoint grapheme is in
// neither alphabet, so a lookalike is refused rather than normalised.
fn in_grammar(text: String, head: String, tail: String) -> Bool {
  case string.to_graphemes(text) {
    [] -> False
    [first, ..rest] ->
      string.contains(head, first)
      && list.all(rest, fn(grapheme) { string.contains(tail, grapheme) })
  }
}
