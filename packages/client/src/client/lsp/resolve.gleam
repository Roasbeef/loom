//// Which language server owns a path, whether the server may be asked
//// about it, and how the model's words become the server's positions and
//// back (ADR-013 §§3 and 5).
////
//// # Why this is its own module
////
//// The manager (`client/lsp/manager`) is a process story: one server per
//// session, a start that many callers wait on, a restart after death.
//// What this module holds is the part of the door that is *judgement*
//// rather than process: ownership and containment, splitting a qualified
//// symbol, finding a name in an outline, naming the symbol that contains a
//// reference, and turning the server's absolute paths into the
//// workspace-relative ones `fs_read` prints. Almost all of it is pure over
//// its arguments, so the rules are tested without a server; the three
//// functions that read the disk (`owner`, `read_text`, `workspace_real`)
//// say so, and read through `tools/fs`, the same resolution the fs tools
//// trust.
////
//// # Ownership and containment, in the order they are decided
////
//// A path is owned by the configured server whose `extensions` hold its
//// extension (the catalogue guarantees at most one). Its project root is
//// the nearest ancestor, at or below the workspace root, that holds one of
//// that server's `root_markers`; the walk is lexical, over the path as the
//// model wrote it. Then the path's *real* location — every symlink
//// resolved by `tools/fs.resolve_real` — must lie under the root's real
//// location. bwrap binds the root at its own path, so a symlink leading out
//// of it names a file the jailed server cannot read, and asking it would
//// produce an answer about nothing (ADR-013 §3, "Containment"). The server
//// is then addressed only by real paths: the real root is its `rootUri`,
//// and the real file is what every request names.

import broker/policy
import client/catalog.{type LspServer}
import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import lsp/protocol.{type DocumentSymbol, type DocumentSymbols}
import lsp/query.{type Site, type SymbolEntry, Site, SymbolEntry}
import lsp/range.{type Position, type Range}
import lsp/text
import simplifile
import tools/fs

// --- identity and ownership ---------------------------------------------------

/// One language server as the manager runs it: the configured table and
/// the project root it serves. Two identities are the same server exactly
/// when their names and roots agree, which is what `same` compares; the
/// session runs at most one at a time (ADR-013 §1).
pub type Identity {
  Identity(
    /// The `[lsp.<name>]` table.
    server: LspServer,
    /// The project root, absolute and fully resolved.
    root: String,
  )
}

/// A path the manager may ask a server about: its owner, and the path's
/// real location under that owner's root.
pub type Owned {
  Owned(
    /// The server and root that own the path.
    identity: Identity,
    /// The path with every symlink resolved; always under
    /// `identity.root`.
    path: String,
  )
}

/// Why no server may be asked about a path. The reason is worded for the
/// model: it names what was missing, or where the path really leads.
pub type Unowned {
  /// No configured server lists the path's extension. The cheap answer an
  /// edit of a Markdown file gets, and the one `after_write` stays silent
  /// on.
  NoOwner(reason: String)

  /// A server owns the extension, but the path cannot be served: it has no
  /// project root inside the workspace, it does not resolve, or its real
  /// location is outside the root the server would be jailed with.
  Refused(reason: String)
}

/// Whether two identities name the same running server.
///
/// ## Examples
///
/// ```gleam
/// // resolve.same(Identity(gleam, "/w/a"), Identity(gleam, "/w/a")) == True
/// ```
///
pub fn same(a: Identity, b: Identity) -> Bool {
  a.server.name == b.server.name && a.root == b.root
}

/// Finds the server that owns `path` and checks that it may be asked.
///
/// `path` may be absolute or workspace-relative; the tools' write observer
/// passes resolved absolute paths and a rename passes the workspace path
/// it wrote, and both land here. Reads the disk: the marker search stats
/// ancestors, and containment resolves symlinks.
///
/// ## Examples
///
/// ```gleam
/// // resolve.owner([gleam], "/work", "app/src/app.gleam")
/// // == Ok(Owned(Identity(gleam, "/work/app"), "/work/app/src/app.gleam"))
/// ```
///
pub fn owner(
  servers: List(LspServer),
  workspace: String,
  path: String,
) -> Result(Owned, Unowned) {
  let extension = extension_of(path)
  use server <- result.try(
    list.find(servers, fn(server) {
      list.contains(server.extensions, extension)
    })
    |> result.map_error(fn(_nil) {
      NoOwner(reason: "no configured language server owns " <> path)
    }),
  )
  use lexical <- result.try(
    fs.resolve_path(workspace:, path:)
    |> result.map_error(fn(_escapes) {
      Refused(reason: path <> " is outside the workspace")
    }),
  )
  let workspace = fs.resolve_path(workspace:, path: workspace)
  let top = result.unwrap(workspace, lexical)
  use root <- result.try(
    marked_root(filepath.directory_name(lexical), top, server.root_markers)
    |> result.map_error(fn(_nil) {
      Refused(
        reason: "no "
        <> string.join(server.root_markers, " or ")
        <> " above "
        <> path
        <> " inside the workspace, so lsp."
        <> server.name
        <> " has no project root for it",
      )
    }),
  )
  use real_root <- result.try(real(top, root))
  use real_path <- result.try(real(top, lexical))

  // The containment rule is the whole reason for resolving: the jail binds
  // the root at its own path, so a file whose real location is elsewhere
  // is a file the server cannot see.
  case policy.covers(root: real_root, path: real_path) {
    True -> Ok(Owned(Identity(server:, root: real_root), real_path))
    False ->
      Error(Refused(
        reason: path
        <> " resolves to "
        <> real_path
        <> ", outside the server's root "
        <> real_root
        <> "; lsp."
        <> server.name
        <> " runs jailed to that root and cannot read it",
      ))
  }
}

fn real(workspace: String, path: String) -> Result(String, Unowned) {
  fs.resolve_real(filesystem: fs.real_filesystem(), workspace:, path:)
  |> result.map_error(fn(error) {
    case error {
      fs.EscapesWorkspace(path: _) ->
        Refused(reason: path <> " resolves outside the workspace")
      fs.Unresolvable(path: _, reason:) ->
        Refused(reason: path <> " does not resolve: " <> reason)
      fs.EmptyPath -> Refused(reason: "an empty path names no file")
      fs.ProtectedPath(path: _, protected: _)
      | fs.ProtectionMisconfigured(path: _, protected: _) ->
        Refused(reason: path <> " is protected")
    }
  })
}

// The nearest directory from `directory` up to and including `top` that
// holds a marker file. A marker above the workspace does not count: the
// session base reaches the workspace, and a root above it is one the jail
// would refuse to grant anyway.
fn marked_root(
  directory: String,
  top: String,
  markers: List(String),
) -> Result(String, Nil) {
  let marked =
    list.any(markers, fn(marker) {
      simplifile.is_file(directory <> "/" <> marker) == Ok(True)
    })
  case marked, directory == top || !policy.covers(root: top, path: directory) {
    True, _ -> Ok(directory)
    False, True -> Error(Nil)
    False, False ->
      marked_root(filepath.directory_name(directory), top, markers)
  }
}

/// The extension of a path's last segment, lowercased, with its dot: the
/// form `LspServer.extensions` holds. A name with no dot has none.
///
/// ## Examples
///
/// ```gleam
/// assert resolve.extension_of("src/App.Gleam") == ".gleam"
/// assert resolve.extension_of("Makefile") == ""
/// ```
///
pub fn extension_of(path: String) -> String {
  case filepath.extension(filepath.base_name(path)) {
    Ok(extension) -> "." <> string.lowercase(extension)
    Error(Nil) -> ""
  }
}

/// The workspace root with every symlink resolved, so a server's real
/// paths can be shown relative to it. Falls back to the root as written.
///
/// ## Examples
///
/// ```gleam
/// // resolve.workspace_real("/work") == "/work"
/// ```
///
pub fn workspace_real(workspace: String) -> String {
  fs.resolve_real(filesystem: fs.real_filesystem(), workspace:, path: workspace)
  |> result.unwrap(workspace)
}

/// A server's absolute path as the harness shows it: relative to the
/// workspace when inside it (checked against both its real and its written
/// form), absolute otherwise, as `query.Site.path` promises.
///
/// ## Examples
///
/// ```gleam
/// assert resolve.display(["/work"], "/work/src/a.gleam") == "src/a.gleam"
/// assert resolve.display(["/work"], "/usr/lib/go/fmt.go") == "/usr/lib/go/fmt.go"
/// ```
///
pub fn display(workspaces: List(String), path: String) -> String {
  let inside =
    list.find_map(workspaces, fn(workspace) {
      string.split_once(path, workspace <> "/")
      |> result.try(fn(split) {
        case split {
          #("", rest) -> Ok(rest)
          #(_, _) -> Error(Nil)
        }
      })
    })
  result.unwrap(inside, path)
}

/// Reads a file the server holds or names, under the fs tools' large-file
/// guard. The path must already be resolved (`owner`, or a server's own
/// answer, which the jail bounds).
///
/// ## Examples
///
/// ```gleam
/// // resolve.read_text("/work/src/a.gleam") == Ok("pub fn a() { 1 }\n")
/// ```
///
pub fn read_text(path: String) -> Result(String, String) {
  fs.read_text_file(filesystem: fs.real_filesystem(), resolved: path)
  |> result.map_error(fn(error) {
    case error {
      fs.ReadFailed(error: _) -> path <> " could not be read"
      fs.TooLarge(size:, limit: _) ->
        path <> " is too large to read (" <> int.to_string(size) <> " bytes)"
      fs.NotText -> path <> " is not UTF-8 text"
    }
  })
}

// --- symbols -----------------------------------------------------------------

/// A symbol as the model wrote it, split the way code reads it.
pub type Symbol {
  Symbol(
    /// The last dot-separated segment: the identifier searched for.
    identifier: String,
    /// Everything before it with `.` normalised to `/`, when there was
    /// anything: the module path or directory that narrows candidates.
    qualifier: Option(String),
  )
}

/// Splits `probe.greet`, `util.Greet` or `pkg/mod.name` into identifier and
/// qualifier. A symbol with no dot, or one that is all dots (an operator),
/// is its own identifier.
///
/// ## Examples
///
/// ```gleam
/// assert resolve.split_symbol("pkg/mod.name")
///   == resolve.Symbol("name", Some("pkg/mod"))
/// assert resolve.split_symbol("greet") == resolve.Symbol("greet", None)
/// ```
///
pub fn split_symbol(symbol: String) -> Symbol {
  let parts = string.split(symbol, ".")
  let #(before, last) = case list.reverse(parts) {
    [last, ..before] -> #(list.reverse(before), last)
    [] -> #([], symbol)
  }
  case last, before {
    "", _ | _, [] -> Symbol(identifier: symbol, qualifier: None)
    _, _ ->
      Symbol(
        identifier: last,
        qualifier: Some(string.join(before, "/") |> string.replace(".", "/")),
      )
  }
}

/// Whether a definition in `path` satisfies a qualifier: the path without
/// its extension, or its directory, ends with the qualifier on segment
/// boundaries. `root` is stripped first, so `src/probe.gleam` under the
/// root satisfies `probe` and `util/util.go` satisfies `util`.
///
/// ## Examples
///
/// ```gleam
/// assert resolve.satisfies("/w", "/w/src/probe.gleam", "probe")
/// assert !resolve.satisfies("/w", "/w/src/probe.gleam", "other")
/// ```
///
pub fn satisfies(root: String, path: String, qualifier: String) -> Bool {
  let relative = "/" <> display([root], path)
  let module = filepath.strip_extension(relative)
  let directory = filepath.directory_name(relative)
  let wanted = "/" <> qualifier
  string.ends_with(module, wanted) || string.ends_with(directory, wanted)
}

/// Positions of every outline entry named `identifier`, with the entry's
/// parents joined as `Outer.inner`. A qualifier keeps an entry when its
/// parent chain ends with it, or when the file at `path` under `root`
/// satisfies it (the qualifier named the module rather than a type).
///
/// ## Examples
///
/// ```gleam
/// // resolve.named(symbols, "greet", None, root: "/w", path: "/w/a.gleam")
/// //   == [#("greet", Position(0, 7))]
/// ```
///
pub fn named(
  symbols: DocumentSymbols,
  identifier: String,
  qualifier: Option(String),
  root root: String,
  path path: String,
) -> List(#(String, Position)) {
  flatten(symbols)
  |> list.filter(fn(entry) { entry.name == identifier })
  |> list.filter(fn(entry) {
    case qualifier {
      None -> True
      Some(qualifier) ->
        satisfies(root, path, qualifier)
        || string.ends_with(
          "/" <> string.replace(entry.parents, ".", "/"),
          "/" <> qualifier,
        )
    }
  })
  |> list.map(fn(entry) { #(qualified(entry), entry.at) })
}

// One outline entry with its ancestry spelled out: the unit `named` and
// `container` both reason over, whichever dialect the server answered in.
type Flat {
  Flat(name: String, parents: String, at: Position, span: Range)
}

fn qualified(entry: Flat) -> String {
  case entry.parents {
    "" -> entry.name
    parents -> parents <> "." <> entry.name
  }
}

// A hierarchical outline is walked depth first with each entry's parent
// chain; a flat one already names its container, which is the chain the
// server chose to give.
fn flatten(symbols: DocumentSymbols) -> List(Flat) {
  case symbols {
    protocol.Hierarchical(symbols:) -> walk(symbols, "", [])
    protocol.Flat(symbols:) ->
      list.map(symbols, fn(symbol) {
        Flat(
          name: symbol.name,
          parents: option.unwrap(symbol.container_name, ""),
          at: symbol.location.range.start,
          span: symbol.location.range,
        )
      })
  }
}

fn walk(
  symbols: List(DocumentSymbol),
  parents: String,
  into: List(Flat),
) -> List(Flat) {
  list.fold(symbols, into, fn(into, symbol) {
    let entry =
      Flat(
        name: symbol.name,
        parents:,
        at: symbol.selection_range.start,
        span: symbol.range,
      )
    walk(symbol.children, qualified(entry), [entry, ..into])
  })
}

/// The innermost outline entry whose range holds `at`, qualified by its
/// parents, or `None` at top level. Innermost is the containing entry with
/// the latest start, which for properly nested ranges is the deepest one.
///
/// ## Examples
///
/// ```gleam
/// // resolve.container(symbols, Position(4, 2)) == Some("Server.handle")
/// ```
///
pub fn container(symbols: DocumentSymbols, at: Position) -> Option(String) {
  flatten(symbols)
  |> list.filter(fn(entry) { holds(entry.span, at) })
  |> list.max(fn(a, b) { compare(a.span.start, b.span.start) })
  |> result.map(qualified)
  |> option.from_result
}

fn holds(span: Range, at: Position) -> Bool {
  compare(span.start, at) != order.Gt && compare(at, span.end) != order.Gt
}

/// Orders two server positions in document order.
///
/// ## Examples
///
/// ```gleam
/// assert resolve.compare(Position(1, 0), Position(0, 9)) == order.Gt
/// ```
///
pub fn compare(a: Position, b: Position) -> order.Order {
  case int.compare(a.line, b.line) {
    order.Eq -> int.compare(a.character, b.character)
    other -> other
  }
}

/// A file's outline in the harness's form: every site converted against
/// `content`, the file's text, and shown under `display_path`. A position
/// that does not convert is shown at its raw coordinates, 1-based, rather
/// than dropped: the entry exists even if the server's arithmetic is off.
///
/// ## Examples
///
/// ```gleam
/// // resolve.outline(symbols, text, "src/a.gleam")
/// //   == [SymbolEntry("greet", "function", Some("fn() -> String"), site, [])]
/// ```
///
pub fn outline(
  symbols: DocumentSymbols,
  content: String,
  display_path: String,
) -> List(SymbolEntry) {
  case symbols {
    protocol.Hierarchical(symbols:) ->
      list.map(symbols, entry(_, content, display_path))
    protocol.Flat(symbols:) ->
      list.map(symbols, fn(symbol) {
        SymbolEntry(
          name: symbol.name,
          kind: protocol.symbol_kind_name(symbol.kind),
          detail: symbol.container_name,
          site: site(content, display_path, symbol.location.range.start),
          children: [],
        )
      })
  }
}

fn entry(
  symbol: DocumentSymbol,
  content: String,
  display_path: String,
) -> SymbolEntry {
  SymbolEntry(
    name: symbol.name,
    kind: protocol.symbol_kind_name(symbol.kind),
    detail: symbol.detail,
    site: site(content, display_path, symbol.selection_range.start),
    children: list.map(symbol.children, entry(_, content, display_path)),
  )
}

/// One server position as a `Site` in `content`, or at its raw coordinates
/// with no line text when the text does not hold it (a file changed since
/// the server answered, or one that could not be read).
///
/// ## Examples
///
/// ```gleam
/// assert resolve.site("ab\n", "a.gleam", Position(0, 1))
///   == Site("a.gleam", 1, 2, "ab")
/// ```
///
pub fn site(content: String, display_path: String, at: Position) -> Site {
  text.to_site(content, display_path, at)
  |> result.lazy_unwrap(fn() {
    Site(
      path: display_path,
      line: at.line + 1,
      column: at.character + 1,
      text: "",
    )
  })
}
