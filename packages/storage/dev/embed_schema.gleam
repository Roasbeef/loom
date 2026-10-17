//// Embeds the hand-written SQL schemas into Gleam modules, and says in which
//// order a scratch database must load them.
////
//// Run from `packages/storage`:
////
//// ```text
//// gleam run -m embed_schema              write src/storage/<name>_schema.gleam
//// gleam run -m embed_schema load-order   print the DDL files, one per line
//// ```
////
//// `scripts/gen-sql.sh` is the only caller. It runs both commands: the first
//// regenerates the embedded schemas, the second tells it which `sql/*.sql`
//// files to feed to `sqlite3` before parrot reads the database.
////
//// ## Why the schemas are embedded
////
//// The `.sql` files under `sql/` are the source of truth, and the runtime
//// needs the same text to create its databases. Reading the file at startup
//// would make a release depend on a source tree it does not ship, so each file
//// is copied into a module holding a single `pub const schema`. The module is
//// generated, committed, and never edited by hand.
////
//// ## How work moves through this module
////
//// 1. `schema_stems` lists `sql/` and reduces each file to its stem
////    (`catalogue_names`). Every `.sql` file there is a schema, so a new file
////    needs no registration.
//// 2. `embed` reads one file, refuses anything that is not ASCII, escapes it
////    as a Gleam string literal, and writes `src/storage/<stem>_schema.gleam`.
//// 3. `load_order` arranges the stems for the scratch database: the base
////    schema, the catalogue migrations in version order, the session schema,
////    and then whatever remains by name.
////
//// ## Two constraints this module enforces
////
//// Parrot slices the schema by byte offset, so one multi-byte character
//// shifts every later offset and silently corrupts the generated queries. The
//// embedder therefore rejects non-ASCII input and names the line.
////
//// Catalogue versions after the first ALTER tables that earlier versions
//// created, so loading them in alphabetical order fails. The order is not
//// written down here a second time. `storage/catalogue.migrations` already
//// lists the schemas in version order, and `migration_stems` reads that list
//// back out of the source.
////
//// ## Why a failure panics
////
//// A generator must exit non-zero when it fails, and Gleam's standard library
//// has no process exit. Calling `halt` needs an `@external`, which generators
//// do not use. `main` therefore turns a `Failure` into a `panic` carrying its
//// description, which is the one place this module crashes on purpose.

import argv
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile.{type FileError}

/// Where the hand-written schemas live, relative to `packages/storage`.
const schema_directory = "sql"

/// Where the embedded modules are written.
const output_directory = "src/storage"

/// The module whose `migrations()` fixes the catalogue's version order.
const catalogue_source = "src/storage/catalogue.gleam"

/// The widest line `gleam format` keeps on one line.
const format_width = 80

/// Everything that can stop the generator, each with enough context to act on.
pub type Failure {
  /// A directory could not be listed.
  CouldNotList(path: String, reason: FileError)

  /// A schema or the catalogue source could not be read.
  CouldNotRead(path: String, reason: FileError)

  /// An embedded module could not be written.
  CouldNotWrite(path: String, reason: FileError)

  /// A schema holds a character outside ASCII. Parrot's offsets count bytes,
  /// so the file must be fixed rather than embedded.
  NotAscii(path: String, line: Int, character: String)

  /// The load order names a schema file that is not in `sql/`.
  MissingSchema(stem: String)

  /// The command line named something this program does not do.
  UnknownCommand(arguments: List(String))
}

/// Runs the command named on the command line, and panics if it fails.
///
/// With no argument it embeds every schema. With `load-order` it prints the
/// DDL files in the order a scratch database must load them.
pub fn main() -> Nil {
  let outcome = case argv.load().arguments {
    [] -> embed_all()
    ["load-order"] -> print_load_order()
    arguments -> Error(UnknownCommand(arguments))
  }

  case outcome {
    Ok(Nil) -> Nil

    // The process exit status is the only channel `gen-sql.sh` reads, and a
    // panic is the one way to set it without an `@external`.
    Error(failure) -> panic as { "embed_schema: " <> describe(failure) }
  }
}

/// Explains a failure in a sentence a developer can act on.
///
/// ## Examples
///
/// ```gleam
/// // embed_schema.describe(MissingSchema("session"))
/// // -> "sql/session.sql is required but missing"
/// ```
pub fn describe(failure: Failure) -> String {
  case failure {
    CouldNotList(path:, reason:) ->
      "cannot list " <> path <> ": " <> simplifile.describe_error(reason)

    CouldNotRead(path:, reason:) ->
      "cannot read " <> path <> ": " <> simplifile.describe_error(reason)

    CouldNotWrite(path:, reason:) ->
      "cannot write " <> path <> ": " <> simplifile.describe_error(reason)

    NotAscii(path:, line:, character:) ->
      path
      <> " line "
      <> string.inspect(line)
      <> " holds the non-ASCII character "
      <> string.inspect(character)
      <> "; parrot corrupts byte offsets on multi-byte text, so use ASCII"

    MissingSchema(stem:) ->
      schema_directory <> "/" <> stem <> ".sql is required but missing"

    UnknownCommand(arguments:) ->
      "unknown arguments "
      <> string.inspect(arguments)
      <> "; expected none, or load-order"
  }
}

/// Embeds every schema file under `sql/`.
fn embed_all() -> Result(Nil, Failure) {
  use stems <- result.try(schema_stems())
  list.try_each(stems, embed)
}

/// Prints each DDL file, one per line, in the order the scratch database loads
/// them.
fn print_load_order() -> Result(Nil, Failure) {
  use stems <- result.try(schema_stems())
  use catalogue <- result.try(read(catalogue_source))
  use ordered <- result.try(load_order(stems, migration_stems(catalogue)))

  ordered
  |> list.map(sql_path)
  |> list.each(io.println)
  |> Ok
}

/// The stem of every `.sql` file in `sql/`, sorted by name.
///
/// Sorting makes the result independent of directory order, which the
/// operating system does not define.
fn schema_stems() -> Result(List(String), Failure) {
  use names <- result.try(
    simplifile.read_directory(schema_directory)
    |> result.map_error(CouldNotList(schema_directory, _)),
  )

  names
  |> list.filter(string.ends_with(_, ".sql"))
  |> list.map(string.drop_end(_, string.length(".sql")))
  |> list.sort(string.compare)
  |> Ok
}

/// Embeds one schema: reads `sql/<stem>.sql` and writes its module.
fn embed(stem: String) -> Result(Nil, Failure) {
  let source = sql_path(stem)
  let destination = module_path(stem)

  use sql <- result.try(read(source))
  use literal <- result.try(string_literal(source, sql))

  simplifile.write(destination, module_source(literal))
  |> result.map_error(CouldNotWrite(destination, _))
}

/// Reads a text file, naming the path if that fails.
fn read(path: String) -> Result(String, Failure) {
  simplifile.read(path)
  |> result.map_error(CouldNotRead(path, _))
}

/// Where a schema's source file lives.
fn sql_path(stem: String) -> String {
  schema_directory <> "/" <> stem <> ".sql"
}

/// Where a schema's embedded module is written.
fn module_path(stem: String) -> String {
  output_directory <> "/" <> module_name(stem) <> ".gleam"
}

/// The module a schema embeds into.
///
/// `schema.sql` is the session store's first schema and has always embedded as
/// `sql_schema`, next to the generated `sql` module. Every other file keeps its
/// stem, so `schema_schema` is the one name this rule must not produce.
///
/// ## Examples
///
/// ```gleam
/// assert embed_schema.module_name("schema") == "sql_schema"
/// assert embed_schema.module_name("session") == "session_schema"
/// ```
pub fn module_name(stem: String) -> String {
  case stem {
    "schema" -> "sql_schema"
    other -> other <> "_schema"
  }
}

/// The text of an embedded module around an already escaped string literal.
///
/// The constant is laid out as `gleam format` would lay it out: on the
/// declaration line when it fits in 80 columns, and on its own indented line
/// otherwise. Producing the formatter's output directly means `make gen-sql`
/// needs no formatting pass over these files.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(embed_schema.module_source("\"x\""), "pub const schema = \"x\"\n")
/// ```
pub fn module_source(literal: String) -> String {
  let one_line = "pub const schema = " <> literal

  let declaration = case string.length(one_line) <= format_width {
    True -> one_line
    False -> "pub const schema =\n  " <> literal
  }

  "//// Generated by packages/storage/dev/embed_schema.gleam. DO NOT EDIT.\n"
  <> "//// The checked-in SQL file is the schema source of truth.\n\n"
  <> "/// The schema used both at runtime and by sqlc during generation.\n"
  <> declaration
  <> "\n"
}

/// Escapes SQL as a Gleam string literal, refusing non-ASCII text.
///
/// `path` is used only to name the file in the error.
///
/// ## Examples
///
/// ```gleam
/// assert embed_schema.string_literal("a.sql", "a\n\"b\"") == Ok("\"a\\n\\\"b\\\"\"")
/// ```
pub fn string_literal(path: String, sql: String) -> Result(String, Failure) {
  use Nil <- result.try(require_ascii(path, sql))

  sql
  |> string.to_utf_codepoints
  |> list.map(escape_codepoint)
  |> string.concat
  |> fn(body) { "\"" <> body <> "\"" }
  |> Ok
}

/// Fails on the first character outside ASCII, reporting its line.
///
/// The check runs before escaping so that the error can name the line, which
/// the flat codepoint stream no longer knows.
fn require_ascii(path: String, sql: String) -> Result(Nil, Failure) {
  let offender =
    sql
    |> string.split("\n")
    |> list.index_map(fn(line, index) { #(index + 1, non_ascii(line)) })
    |> list.find_map(fn(found) {
      case found {
        #(number, Ok(character)) -> Ok(NotAscii(path, number, character))
        #(_, Error(Nil)) -> Error(Nil)
      }
    })

  case offender {
    Ok(failure) -> Error(failure)
    Error(Nil) -> Ok(Nil)
  }
}

/// The first non-ASCII character of a line, if it has one.
fn non_ascii(line: String) -> Result(String, Nil) {
  line
  |> string.to_graphemes
  |> list.find(fn(grapheme) { !is_ascii(grapheme) })
}

/// Whether every codepoint of a string is below 128.
fn is_ascii(text: String) -> Bool {
  text
  |> string.to_utf_codepoints
  |> list.all(fn(codepoint) { string.utf_codepoint_to_int(codepoint) < 128 })
}

/// One codepoint as it appears inside a Gleam string literal.
///
/// Gleam spells the quote, the backslash and the three common whitespace
/// controls with a short escape. Any other control character uses the
/// `\u{...}` form so that it is visible in the source. Everything else is
/// ASCII text and is written as it is.
fn escape_codepoint(codepoint: UtfCodepoint) -> String {
  case string.utf_codepoint_to_int(codepoint) {
    0x22 -> "\\\""
    0x5c -> "\\\\"
    0x0a -> "\\n"
    0x0d -> "\\r"
    0x09 -> "\\t"
    code if code < 0x20 -> "\\u{" <> int.to_base16(code) <> "}"
    _ -> string.from_utf_codepoints([codepoint])
  }
}

/// The catalogue's migration schemas in version order, as file stems.
///
/// This reads `storage/catalogue.migrations` rather than keeping a second
/// list. Each entry there is a line of the form
/// `#(2, catalogue_names_schema.schema),`, and the module name before
/// `_schema.schema` is the file stem.
///
/// ## Examples
///
/// ```gleam
/// assert embed_schema.migration_stems("    #(2, catalogue_names_schema.schema),")
///   == ["catalogue_names"]
/// ```
pub fn migration_stems(source: String) -> List(String) {
  source
  |> string.split("\n")
  |> list.filter_map(migration_stem)
}

/// The stem named by one `#(version, <stem>_schema.schema),` line.
fn migration_stem(line: String) -> Result(String, Nil) {
  let suffix = "_schema.schema),"
  let trimmed = string.trim(line)

  use #(head, rest) <- result.try(string.split_once(trimmed, ", "))

  case string.starts_with(head, "#("), string.ends_with(rest, suffix) {
    True, True -> Ok(string.drop_end(rest, string.length(suffix)))
    True, False | False, True | False, False -> Error(Nil)
  }
}

/// Arranges schema stems in the order a scratch database must load them.
///
/// The rule is: the base schema, then the catalogue migrations in version
/// order, then the session schema, then every remaining file by name. The
/// remaining files are the executor ledger's, which are separate tables that
/// do not alter one another. A stem the rule names but `stems` lacks is an
/// error, since loading would then silently skip a migration.
///
/// ## Examples
///
/// ```gleam
/// assert embed_schema.load_order(
///   ["exec_ledger", "schema", "session", "catalogue_names"],
///   ["catalogue_names"],
/// ) == Ok(["schema", "catalogue_names", "session", "exec_ledger"])
/// ```
pub fn load_order(
  stems: List(String),
  migrations: List(String),
) -> Result(List(String), Failure) {
  let named = list.flatten([["schema"], migrations, ["session"]])

  use Nil <- result.try(
    list.try_each(named, fn(stem) {
      case list.contains(stems, stem) {
        True -> Ok(Nil)
        False -> Error(MissingSchema(stem))
      }
    }),
  )

  let remaining = list.filter(stems, fn(stem) { !list.contains(named, stem) })

  Ok(list.append(named, remaining))
}
