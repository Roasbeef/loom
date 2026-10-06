//// Which language server owns a path, whether the server may be asked
//// about it, and how the model's words become the server's positions and
//// back (ADR-015 §§3 and 5).
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
//// its arguments, so the rules are tested without a server; the four
//// functions that read the disk (`owner`, `admit`, `read_text`,
//// `workspace_real`) say so, and read through `tools/fs`, the same
//// resolution the fs tools trust.
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
//// produce an answer about nothing (ADR-015 §3, "Containment"). The server
//// is then addressed only by real paths: the real root is its `rootUri`,
//// and the real file is what every request names.
////
//// # The same rule, turned around
////
//// `owner` keeps the model from asking about a file the jail hides;
//// `admit` keeps a server from making the harness read one. A server names
//// paths in every answer, and the harness reads outside every jail, so a
//// server-named path is read only once `admit` has placed its real
//// location under the server's root and under no protected path.
////
//// # Naming a symbol: the qualifier narrows definitions, never hits
////
//// The model writes a symbol as one string, and a language spells a
//// qualified name its own way, so `split_symbol` cuts it on the server's
//// `qualifier_separators` (`.` by default, `::` for a server that says so).
//// The last segment is the *identifier*, the thing searched for. The
//// segments before it are the *qualifier*, and they are re-joined with `/`
//// whatever the separator was, so `util::greet` and `util.greet` both
//// qualify with `util`. That is deliberate: a qualifier is matched against
//// a file tree, and `/` is the one separator every file tree shares, which
//// is also why `/` can never be a separator itself. `pkg/mod.name` therefore
//// reads as identifier `name` in qualifier `pkg/mod`, a path.
////
//// A qualifier is then used in two places, both of which only *remove*
//// candidates. `named` keeps an outline entry whose parent chain ends with
//// the qualifier (a type: `Server.handle`) or whose file satisfies it (a
//// module). `satisfies` is the file test: the path under the project root,
//// with and without its extension, must end with the qualifier on a segment
//// boundary, so `probe` matches `src/probe.gleam` and `util/util.go`, and
//// `prob` matches neither. The manager applies it to definitions found, not
//// to search hits, because `probe.greet` is written at call sites in files
//// that are not `probe`.
////
//// `module_case` says how a language names a module's file from the module's
//// name. Under `AsWritten` the qualifier meets the file tree verbatim. Under
//// `Snake` (Elixir, Ruby) `cased` first converts each `/`-segment from
//// CamelCase, so `MyApp/Accounts` finds `my_app/accounts.ex`. Only the file
//// test is cased: a parent chain in an outline is the server's own spelling
//// of a type and is compared as written.
////
//// ## Flow
////
//// The file has two halves, in the order a question uses them. The first
//// half decides whether a server may be asked, and the second turns words
//// into positions and positions into text.
////
//// ```text
//// owner → extension_of → workspace_real → marked_root → real
////       → Owned | Unowned                       (may we ask?)
//// admit → Ok(real path) | Error(reason)         (may the harness read it?)
//// split_symbol → segments                       (what did the model name?)
//// named → flatten → walk → satisfies → cased → snake
//// container → flatten → holds → compare         (what contains this?)
//// site | outline → entry → display, read_text   (show it)
//// ```

import broker/policy
import client/lsp/profile.{type LspServer, type ModuleCase}
import filepath
import gleam/bool
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
/// session runs at most one at a time (ADR-015 §1).
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
/// it wrote, and both land here. An absolute path is accepted under the
/// workspace as written or under its real location, since the observer's
/// path is the real one. Reads the disk: the marker search stats
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

  // The fs tools' write observer hands over the path they resolved, every
  // symlink followed, so under a workspace reached through a symlink the
  // written spelling never prefixes it. A path is placed under whichever
  // spelling of the workspace holds it — as written, or real — and the
  // walk to a marker then stays inside that spelling.
  use #(spelling, lexical) <- result.try(
    list.unique([workspace, workspace_real(workspace)])
    |> list.find_map(fn(spelling) {
      fs.resolve_path(workspace: spelling, path:)
      |> result.map(fn(lexical) { #(spelling, lexical) })
      |> result.replace_error(Nil)
    })
    |> result.map_error(fn(_nil) {
      Refused(
        reason: path
        <> " is outside the workspace root "
        <> workspace
        <> ", and lsp."
        <> server.name
        <> " is rooted inside it, so it can answer only about files there; "
        <> "a relative path means the workspace",
      )
    }),
  )
  let top =
    fs.resolve_path(workspace: spelling, path: spelling)
    |> result.unwrap(lexical)
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
  use real_root <- result.try(real(top, root, asked: path))
  use real_path <- result.try(real(top, lexical, asked: path))

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

// A path with every link resolved, below `workspace`, as the `Unowned`
// refusal that says which way it failed. Both `owner` checks use it, once
// for the root and once for the file, so the comparison between them is
// between real locations on both sides. `asked` is the path the model
// wrote: a failure on the root's walk is still about that path, so the
// reason names it and the workspace root it left, never an intermediate
// directory the model did not mention.
fn real(
  workspace: String,
  path: String,
  asked asked: String,
) -> Result(String, Unowned) {
  fs.resolve_real(filesystem: fs.real_filesystem(), workspace:, path:)
  |> result.map_error(fn(error) {
    case error {
      fs.EscapesWorkspace(path: _) ->
        Refused(
          reason: asked
          <> " resolves outside the workspace root "
          <> workspace
          <> " through a symlink, so no language server rooted there can "
          <> "answer about it",
        )
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

/// Reads a file under the fs tools' large-file guard, with no path
/// discipline of its own.
///
/// **Precondition: `path` came out of `owner` or `admit`.** The jail bounds
/// what a server can read, never which paths it can name, and this read
/// runs in the harness, unjailed. A path a server named goes through
/// `admit` first, or a hostile project's server could name a credential
/// file and have the harness read it into a tool result.
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

/// Whether the harness may read a path a language server named: its real
/// location must lie under `root`, the server's real project root, and at
/// or under no entry of `protected`, the session base policy's list.
/// Answers the real path, which is the one to read, or why not.
///
/// This is the gate of ADR-015 §3's containment turned around. `owner`
/// keeps the model from asking a server about a file the jail hides; this
/// keeps a server from making the harness read one. Everything a server
/// answers — a definition, a reference, a call edge, a diagnostic, a
/// rename's `WorkspaceEdit` — names paths, and the harness reads outside
/// every jail. The bound is the root alone, never the server's configured
/// `readable` roots: an operator grants those so the server can resolve a
/// dependency, which is not a grant for the harness to print it. A jump
/// into the standard library is therefore shown at its coordinates, with
/// no line text.
///
/// The check is `tools/fs.resolve_writable`: containment by real path and
/// the protected list, both judged on where the path really leads, and a
/// relative protected entry refusing everything. It is the write
/// boundary's check, reused because it is the same question — may the
/// harness touch this file on the model's behalf — and a second copy is
/// how two enforcement points drift.
///
/// ## Examples
///
/// ```gleam
/// // resolve.admit(root: "/w/app", protected: ["/w/app/.git"], path: "/w/app/src/a.gleam")
/// //   == Ok("/w/app/src/a.gleam")
/// // resolve.admit(root: "/w/app", protected: [], path: "/home/me/.ssh/id")
/// //   -> Error("/home/me/.ssh/id resolves outside the server's root")
/// ```
///
pub fn admit(
  root root: String,
  protected protected: List(String),
  path path: String,
) -> Result(String, String) {
  // A relative path would be joined under the root and pass; a server that
  // names one has named nothing the harness can place.
  use <- bool.lazy_guard(!string.starts_with(path, "/"), fn() {
    Error(path <> " is not an absolute path")
  })
  fs.resolve_writable(
    filesystem: fs.real_filesystem(),
    workspace: root,
    protected:,
    path:,
  )
  |> result.map_error(fn(error) {
    case error {
      fs.EscapesWorkspace(path: _) ->
        path <> " resolves outside the server's root"
      fs.Unresolvable(path: _, reason:) ->
        path <> " does not resolve: " <> reason
      fs.EmptyPath -> "an empty path names no file"
      fs.ProtectedPath(path: _, protected:) ->
        path <> " lies under the protected path " <> protected
      fs.ProtectionMisconfigured(path: _, protected:) ->
        "the session's protected list holds the relative entry " <> protected
    }
  })
}

// --- symbols -----------------------------------------------------------------

/// A symbol as the model wrote it, split the way code reads it.
pub type Symbol {
  Symbol(
    /// The last segment between separators: the identifier searched for.
    identifier: String,
    /// Everything before it, the segments joined with `/`, when there was
    /// anything: the module path, directory or parent type that narrows
    /// candidates.
    qualifier: Option(String),
  )
}

/// Splits a symbol on its server's `qualifier_separators` into identifier
/// and qualifier: `probe.greet`, `util.Greet` or `pkg/mod.name` under the
/// default `["."]`, `util::greet` under `["::"]`.
///
/// The separators are tried longest first at each position, so a server
/// listing both `:` and `::` reads `a::b` as two segments rather than
/// three with an empty one between. The identifier is the last segment,
/// and the qualifier is the segments before it joined with `/`. A `/` the
/// model wrote inside a segment is kept, so it still reads as a path
/// (`pkg/mod.name`), which is why `/` can never be a separator. A symbol
/// with no separator in it, or one ending in a separator (an operator
/// such as `..`, or `a.` mid-typing), is its own identifier.
///
/// ## Examples
///
/// ```gleam
/// assert resolve.split_symbol("pkg/mod.name", ["."])
///   == resolve.Symbol("name", Some("pkg/mod"))
/// ```
///
/// ```gleam
/// assert resolve.split_symbol("util::greet", ["::"])
///   == resolve.Symbol("greet", Some("util"))
/// ```
///
/// ```gleam
/// assert resolve.split_symbol("greet", ["."]) == resolve.Symbol("greet", None)
/// ```
///
pub fn split_symbol(symbol: String, separators: List(String)) -> Symbol {
  let longest_first =
    list.sort(separators, fn(a, b) {
      int.compare(string.byte_size(b), string.byte_size(a))
    })
  let parts = segments(symbol, longest_first, "", [])
  let #(before, last) = case list.reverse(parts) {
    [last, ..before] -> #(list.reverse(before), last)
    [] -> #([], symbol)
  }
  case last, before {
    "", _ | _, [] -> Symbol(identifier: symbol, qualifier: None)
    _, _ -> Symbol(identifier: last, qualifier: Some(string.join(before, "/")))
  }
}

// A plain recursion over the string, one grapheme at a time, in three cases:
// a separator starts here, so the segment so far is closed; an ordinary
// grapheme, which extends the current segment; or the end, which closes the
// last segment and puts the list in reading order.
//
// Walks `rest` once, cutting a segment wherever one of `separators`
// begins. `current` is the segment being read and `done` the segments
// already cut, newest first. The first separator in the list that matches
// wins, which is why the caller sorts them longest first. An empty
// separator would match everywhere and cut nothing, and the profile
// decoder refuses one, but it is skipped here as well so a hand-built
// server cannot loop.
fn segments(
  rest: String,
  separators: List(String),
  current: String,
  done: List(String),
) -> List(String) {
  let cut =
    list.find(separators, fn(separator) {
      separator != "" && string.starts_with(rest, separator)
    })
  case cut, string.pop_grapheme(rest) {
    Ok(separator), _ ->
      segments(
        string.drop_start(rest, string.length(separator)),
        separators,
        "",
        [current, ..done],
      )
    Error(Nil), Ok(#(grapheme, rest)) ->
      segments(rest, separators, current <> grapheme, done)
    Error(Nil), Error(Nil) -> list.reverse([current, ..done])
  }
}

/// A qualifier as it should meet the file tree under a module case: each
/// `/`-separated segment verbatim for `AsWritten`, or mapped from
/// CamelCase to snake_case for `Snake`.
///
/// The snake mapping puts an underscore before an upper-case letter that
/// follows a lower-case letter or a digit, or that begins a new word after
/// a run of capitals (the `S` of `HTTPServer`), then lower-cases the
/// whole. That is how Elixir's and Ruby's conventions name a module's file
/// (`MyApp.Accounts` in `my_app/accounts.ex`), and a segment already in
/// snake_case has no upper-case letter to move.
///
/// ## Examples
///
/// ```gleam
/// assert resolve.cased("MyApp/HTTPServer", profile.Snake)
///   == "my_app/http_server"
/// ```
///
/// ```gleam
/// assert resolve.cased("MyApp", profile.AsWritten) == "MyApp"
/// ```
///
pub fn cased(qualifier: String, module_case: ModuleCase) -> String {
  case module_case {
    profile.AsWritten -> qualifier
    profile.Snake ->
      string.split(qualifier, "/")
      |> list.map(snake)
      |> string.join("/")
  }
}

// One segment in snake_case. Each grapheme is judged with its neighbours,
// since whether a capital starts a word depends on the letter before it
// and, inside a run of capitals, on the letter after it.
fn snake(segment: String) -> String {
  let graphemes = string.to_graphemes(segment)
  let before = ["", ..graphemes]
  let after = list.append(list.drop(graphemes, 1), [""])
  list.zip(before, list.zip(graphemes, after))
  |> list.map(fn(triple) {
    let #(previous, #(grapheme, next)) = triple
    let starts_word =
      is_upper(grapheme)
      && {
        is_lower(previous)
        || is_digit(previous)
        || { is_upper(previous) && is_lower(next) }
      }
    case starts_word {
      True -> "_" <> string.lowercase(grapheme)
      False -> string.lowercase(grapheme)
    }
  })
  |> string.concat
}

fn is_upper(grapheme: String) -> Bool {
  grapheme != "" && string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", grapheme)
}

fn is_lower(grapheme: String) -> Bool {
  grapheme != "" && string.contains("abcdefghijklmnopqrstuvwxyz", grapheme)
}

fn is_digit(grapheme: String) -> Bool {
  grapheme != "" && string.contains("0123456789", grapheme)
}

/// Whether a definition in `path` satisfies a qualifier: the path without
/// its extension, or its directory, ends with the qualifier on segment
/// boundaries, once the qualifier is `cased` for the server's module
/// case. `root` is stripped first, so `src/probe.gleam` under the root
/// satisfies `probe` and `util/util.go` satisfies `util`.
///
/// ## Examples
///
/// ```gleam
/// assert resolve.satisfies("/w", "/w/src/probe.gleam", "probe", profile.AsWritten)
/// assert !resolve.satisfies("/w", "/w/src/probe.gleam", "other", profile.AsWritten)
/// ```
///
/// ```gleam
/// assert resolve.satisfies(
///   "/w",
///   "/w/lib/my_app/accounts.ex",
///   "MyApp/Accounts",
///   profile.Snake,
/// )
/// ```
///
pub fn satisfies(
  root: String,
  path: String,
  qualifier: String,
  module_case: ModuleCase,
) -> Bool {
  let relative = "/" <> display([root], path)
  let module = filepath.strip_extension(relative)
  let directory = filepath.directory_name(relative)
  let wanted = "/" <> cased(qualifier, module_case)
  string.ends_with(module, wanted) || string.ends_with(directory, wanted)
}

/// Whether a server's outline spells a method with its receiver in the
/// entry's own name.
pub type MethodNames {
  /// The entry is `(*T).M` or `T.M`, as gopls writes it.
  ReceiverNames

  /// The entry is the bare name, with any receiver in its parent chain.
  ExactNames
}

/// The method spelling to expect from `server`. Only the Go server is known
/// to name methods with their receiver, so every other server keeps whole-name
/// matching and a dotted name such as Elixir's `MyApp.Server` is never split.
///
/// ## Examples
///
/// ```gleam
/// // resolve.method_names(go_server) == resolve.ReceiverNames
/// ```
///
pub fn method_names(server: LspServer) -> MethodNames {
  case server.language_id {
    "go" -> ReceiverNames
    _other -> ExactNames
  }
}

/// Positions of every outline entry named `identifier`, with the entry's
/// parents joined as `Outer.inner`. A qualifier keeps an entry when its
/// parent chain ends with it, or when the file at `path` under `root`
/// satisfies it (the qualifier named the module rather than a type).
///
/// With `ReceiverNames` (`method_names` says which servers), a method the
/// server spells with its receiver, as gopls does (`(*Server).handle`,
/// `(Server).handle` or `Server.handle` as one top-level entry), is named by
/// its method part too, and its receiver counts as a parent for a qualifier:
/// `handle`, `Server.handle` and `(*Server).handle` all find it. The same
/// method name on two receivers in one file yields two entries, so the caller
/// reports it as ambiguous rather than picking one. With `ExactNames` an
/// entry is matched by its whole name only, as before.
///
/// Only the module match is `cased`. A parent chain is the server's own
/// spelling of a type (`Server.handle` in Elixir is `Server`, not
/// `server`), so it is compared with the qualifier as the model wrote it.
///
/// ## Examples
///
/// ```gleam
/// // resolve.named(symbols, "greet", None, profile.AsWritten, root: "/w", path: "/w/a.gleam")
/// //   == [#("greet", Position(0, 7))]
/// ```
///
pub fn named(
  symbols: DocumentSymbols,
  identifier: String,
  qualifier: Option(String),
  module_case: ModuleCase,
  root root: String,
  path path: String,
  methods methods: MethodNames,
) -> List(#(String, Position)) {
  flatten(symbols)
  |> list.filter(fn(entry) {
    entry.name == identifier
    || { methods == ReceiverNames && method_part(entry.name) == Ok(identifier) }
  })
  |> list.filter(fn(entry) {
    case qualifier {
      None -> True
      Some(qualifier) ->
        satisfies(root, path, qualifier, module_case)
        || string.ends_with(
          "/" <> string.replace(entry.parents, ".", "/"),
          "/" <> qualifier,
        )
        || { methods == ReceiverNames && receiver_named(entry.name, qualifier) }
    }
  })
  |> list.map(fn(entry) { #(qualified(entry), entry.at) })
}

// The receiver and method of an entry the server spelled as one name,
// `(*T).M`, `(T).M` or `T.M`, with the receiver's pointer star and
// parentheses removed. An entry with no dot in its name is not a method
// spelled this way.
fn method_split(name: String) -> Result(#(String, String), Nil) {
  case list.reverse(string.split(name, ".")) {
    [method, ..receiver] if receiver != [] && method != "" ->
      Ok(#(without_pointer(string.join(list.reverse(receiver), ".")), method))
    _ -> Error(Nil)
  }
}

fn without_pointer(receiver: String) -> String {
  receiver
  |> string.replace("(", "")
  |> string.replace(")", "")
  |> string.replace("*", "")
}

fn method_part(name: String) -> Result(String, Nil) {
  result.map(method_split(name), fn(split) { split.1 })
}

// Whether the qualifier the model wrote names this entry's receiver, in any
// of the spellings it may use (`T`, `(*T)`, `pkg.T`, `pkg/T`).
fn receiver_named(name: String, qualifier: String) -> Bool {
  case method_split(name) {
    Error(Nil) -> False
    Ok(#(receiver, _method)) ->
      string.ends_with("/" <> without_pointer(qualifier), "/" <> receiver)
  }
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

// The depth-first walk of one hierarchical level. `parents` is the dotted
// chain down to this level and `into` accumulates entries, so the result
// is newest-first, in the order the fold builds it.
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

// Whether `at` lies in `span`, both ends included, since a reference may
// sit on the first or last character of its container.
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

// One hierarchical outline entry, recursing into its children. The site is
// the entry's name (`selection_range`), not the whole declaration.
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
/// with no line text when there is no text (a file the gate withheld, or
/// one that could not be read) or the text does not hold the position (a
/// file changed since the server answered).
///
/// ## Examples
///
/// ```gleam
/// assert resolve.site("ab\n", "a.gleam", Position(0, 1))
///   == Site("a.gleam", 1, 2, "ab")
/// ```
///
pub fn site(content: String, display_path: String, at: Position) -> Site {
  let raw = fn() {
    Site(
      path: display_path,
      line: at.line + 1,
      column: at.character + 1,
      text: "",
    )
  }

  // No text is the gate's withheld file or an unreadable one, and
  // `to_site` would clamp the server's column into an empty line; the
  // coordinates are the one thing the server said, so they stand as said.
  case content {
    "" -> raw()
    _ -> text.to_site(content, display_path, at) |> result.lazy_unwrap(raw)
  }
}
