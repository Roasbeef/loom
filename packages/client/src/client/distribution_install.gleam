//// Installing one node's bundle on the machine that will run it.
////
//// `loom distribution install BUNDLE` is the only step an operator runs on a
//// node. It reads the bundle, which `distribution_bundle.decode` has already
//// proved to be well formed, and it puts the node in its role: the CA, the
//// certificate and the key in a private directory, the cookie at
//// `$HOME/.erlang.cookie`, the `[distribution]` and role tables into the
//// daemon's `loom.toml`, and the options file the VM is booted with.
////
//// ## Plan first, write second
////
//// Every refusal is decided before the first byte is written. The install
//// reads what is already on the machine, works out for each of the six
//// destinations whether it is absent, identical or different, and stops with
//// a reason if something different would be replaced without `--force`. Only
//// when the whole plan is acceptable does it write, and it writes the
//// credentials before the configuration that names them. A refused install
//// therefore leaves the machine as it found it.
////
//// ## Idempotence
////
//// A second run with the same bundle finds every destination identical and
//// writes nothing. The one destination that can be shared with other work is
//// `loom.toml`, and the merge treats it as the operator's file. It appends the
//// tables the bundle owns and leaves every other line and table alone. A
//// table that already exists with different values is a conflict, and
//// `--force` replaces exactly the sections the bundle owns, no others.
////
//// ## The cookie
////
//// Erlang reads one cookie from `$HOME/.erlang.cookie` for every distributed
//// node a user starts, so replacing it affects more than this daemon. A
//// different cookie already there is refused, with that reason, unless
//// `--force`. The operator can also give the daemon a dedicated `--home`.

import client/distribution.{CredentialFiles}
import client/distribution_bundle.{type Bundle, type Table}
import client/distribution_provision.{
  type Overwrite, RefuseExisting, ReplaceExisting,
}
import client/executors
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import tom

/// What the caller chose.
pub type Options {
  Options(
    /// The home directory whose `.erlang.cookie` the daemon will read. Absolute.
    home: String,
    /// The `loom.toml` to merge into. Absolute. Its default is
    /// `<home>/.loom/loom.toml`, where the daemon looks.
    config: String,
    /// Whether a different existing file may be replaced.
    overwrite: Overwrite,
  )
}

/// What happened to one destination.
pub type Outcome {
  /// The file did not exist and was created.
  Created

  /// The file already held exactly this content, and was left alone.
  Unchanged

  /// A different file was replaced, because `--force` allowed it.
  Replaced

  /// The tables the bundle owns were added to a configuration file that
  /// already held other content, which was left as it was.
  Merged
}

/// One destination and its outcome.
pub type Step {
  Step(
    /// What the file is, in a few words.
    what: String,
    /// Where it is.
    path: String,
    /// What was done.
    outcome: Outcome,
  )
}

/// The result of an install: what happened, and how to start the daemon.
pub type Installed {
  Installed(
    /// The node installed.
    bundle: Bundle,
    /// One step per destination, in the order they were written.
    steps: List(Step),
    /// The shell command that starts the daemon with the options file.
    start: String,
  )
}

/// The default directory for a bundle with no `bundle_dir`: below the daemon's
/// state root, which is where it looks for `loom.toml` too.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_install.default_directory("/home/me") == "/home/me/.loom/distribution"
/// ```
pub fn default_directory(home: String) -> String {
  home <> "/.loom/distribution"
}

/// The default `loom.toml`: the daemon's `--config` default when that file
/// exists.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_install.default_config("/home/me") == "/home/me/.loom/loom.toml"
/// ```
pub fn default_config(home: String) -> String {
  home <> "/.loom/loom.toml"
}

/// Validates the bundle text and installs it. Nothing is written unless the
/// whole plan is acceptable.
///
/// ## Examples
///
/// ```gleam
/// distribution_install.install(text, Options(home:, config:, overwrite: RefuseExisting))
/// ```
pub fn install(text: String, options: Options) -> Result(Installed, String) {
  use bundle <- result.try(distribution_bundle.decode(text))
  let directory =
    option.lazy_unwrap(bundle.bundle_dir, fn() {
      default_directory(options.home)
    })
  let files =
    CredentialFiles(
      ca: directory <> "/ca.pem",
      certificate: directory <> "/cert.pem",
      key: directory <> "/key.pem",
      cookie: options.home <> "/.erlang.cookie",
    )
  let optfile = directory <> "/dist.options"

  // The configuration is merged first because the options file is generated
  // from the merged result, not from the bundle: the daemon reads the file, so
  // the file is what the options must agree with.
  use existing <- result.try(read_config(options.config))
  let tables = distribution_bundle.config_tables(bundle, files)
  use merged <- result.try(merge(
    existing,
    tables,
    options.overwrite,
    options.config,
  ))
  use config <- result.try(accepted(merged, tables, options.config))
  let wanted = [
    Wanted("CA certificate", files.ca, bundle.ca),
    Wanted("node certificate", files.certificate, bundle.certificate),
    Wanted("node key", files.key, bundle.key),
    Wanted("TLS options", optfile, distribution.tls_options(config)),
  ]
  use steps <- result.try(list.try_map(wanted, plan(_, options.overwrite)))
  use cookie <- result.try(plan_cookie(
    files.cookie,
    bundle.cookie,
    options.overwrite,
  ))

  // Everything is acceptable. The directories come first, then the credentials,
  // then the cookie, and last the configuration that names them all.
  use Nil <- result.try(bootstrap.ensure_private_directory(directory))
  use Nil <- result.try(
    simplifile.create_directory_all(options.home)
    |> result.map_error(describe(options.home, _)),
  )
  use Nil <- result.try(list.try_each(steps, apply))
  use Nil <- result.try(apply(cookie))
  use config_step <- result.try(write_config(options.config, existing, merged))
  Ok(Installed(
    bundle:,
    steps: list.flatten([
      steps |> list.map(fn(planned) { planned.step }),
      [cookie.step, config_step],
    ]),
    start: start_command(options, optfile),
  ))
}

// --- what is already on the machine -----------------------------------------

// One destination with the exact bytes it should hold. Every destination is
// written through the private writer, because the key, the cookie and the
// options file are private and the rest are no worse for it.
type Wanted {
  Wanted(what: String, path: String, content: String)
}

// A destination whose fate is decided: the step to report and the content to
// write, or nothing to write when it was already right.
type Planned {
  Planned(step: Step, write: Option(String))
}

fn plan(wanted: Wanted, overwrite: Overwrite) -> Result(Planned, String) {
  use found <- result.try(read_existing(wanted.path))
  case found {
    None -> Ok(planned(wanted, Created, Some(wanted.content)))
    Some(content) if content == wanted.content ->
      Ok(planned(wanted, Unchanged, None))
    Some(_) ->
      case overwrite {
        ReplaceExisting -> Ok(planned(wanted, Replaced, Some(wanted.content)))
        RefuseExisting ->
          Error(
            wanted.path
            <> " already exists with different contents; pass --force to "
            <> "replace the "
            <> wanted.what,
          )
      }
  }
}

fn planned(wanted: Wanted, outcome: Outcome, write: Option(String)) -> Planned {
  Planned(step: Step(what: wanted.what, path: wanted.path, outcome:), write:)
}

// The cookie gets its own reason, because the file is shared with every other
// distributed node this user starts.
fn plan_cookie(
  path: String,
  cookie: String,
  overwrite: Overwrite,
) -> Result(Planned, String) {
  let wanted = Wanted("cookie", path, cookie)
  use found <- result.try(read_existing(path))
  case found, overwrite {
    Some(content), RefuseExisting if content != cookie ->
      Error(
        path
        <> " already holds a different cookie. Erlang reads that one file for "
        <> "every distributed node this user starts, so replacing it would "
        <> "break any other distribution here. Pass --force to replace it, or "
        <> "give the daemon its own home with --home DIR",
      )
    _, _ -> plan(wanted, overwrite)
  }
}

fn read_existing(path: String) -> Result(Option(String), String) {
  case simplifile.read(path) {
    Ok(content) -> Ok(Some(content))
    Error(simplifile.Enoent) -> Ok(None)
    Error(error) ->
      Error(path <> " is unreadable: " <> simplifile.describe_error(error))
  }
}

fn apply(planned: Planned) -> Result(Nil, String) {
  case planned.write {
    None -> Ok(Nil)
    Some(content) ->
      bootstrap.atomic_write_private(planned.step.path, content)
      |> result.map_error(fn(reason) {
        planned.step.path <> " is unwritable: " <> reason
      })
  }
}

fn describe(path: String, error: simplifile.FileError) -> String {
  path <> " is unwritable: " <> simplifile.describe_error(error)
}

// --- the configuration file --------------------------------------------------

fn read_config(path: String) -> Result(String, String) {
  use found <- result.try(read_existing(path))
  Ok(option.unwrap(found, ""))
}

// Appends the tables the bundle owns and leaves the rest of the file as the
// operator wrote it. A table that is already present with equal values is
// skipped, which makes a second run a no-op. A table present with other values
// is a conflict, and `--force` removes exactly its sections before the new
// ones are appended.
fn merge(
  existing: String,
  tables: List(Table),
  overwrite: Overwrite,
  path: String,
) -> Result(String, String) {
  use document <- result.try(parse_document(existing, path))
  use verdicts <- result.try(
    list.try_map(tables, fn(table) {
      use wanted <- result.try(wanted_value(table))
      case lookup(document, table.path) {
        Error(Nil) -> Ok(#(table, Missing))
        Ok(found) if found == wanted -> Ok(#(table, Same))
        Ok(_) -> Ok(#(table, Different))
      }
    }),
  )
  let conflicts =
    list.filter_map(verdicts, fn(verdict) {
      case verdict {
        #(table, Different) -> Ok(table)
        _ -> Error(Nil)
      }
    })
  use Nil <- result.try(case conflicts, overwrite {
    [], _ -> Ok(Nil)
    _, ReplaceExisting -> Ok(Nil)
    [first, ..], RefuseExisting ->
      Error(
        path
        <> " already has ["
        <> string.join(first.path, ".")
        <> "] with different values; pass --force to replace the tables this "
        <> "bundle owns",
      )
  })
  let kept =
    remove_sections(existing, list.map(conflicts, fn(table) { table.path }))
  let additions =
    list.filter_map(verdicts, fn(verdict) {
      case verdict {
        #(_, Same) -> Error(Nil)
        #(table, _) -> Ok(table.text)
      }
    })
  case additions {
    [] -> Ok(existing)
    _ -> Ok(append(kept, additions))
  }
}

type Verdict {
  Missing
  Same
  Different
}

fn append(kept: String, additions: List(String)) -> String {
  let body = string.join(additions, "\n")
  case string.trim(kept) {
    "" -> body
    _ -> string.trim_end(kept) <> "\n\n" <> body
  }
}

fn parse_document(
  text: String,
  path: String,
) -> Result(Dict(String, tom.Toml), String) {
  tom.parse(text)
  |> result.map_error(fn(error) {
    path <> " is not valid TOML: " <> string.inspect(error)
  })
}

// The value a table's own text defines, so a comparison with the file is made
// between two parsed values and not between two spellings.
fn wanted_value(table: Table) -> Result(tom.Toml, String) {
  use document <- result.try(parse_document(table.text, "the bundle"))
  lookup(document, table.path)
  |> result.replace_error("the bundle's table text does not define its table")
}

fn lookup(
  document: Dict(String, tom.Toml),
  path: List(String),
) -> Result(tom.Toml, Nil) {
  case path {
    [] -> Error(Nil)
    [key] -> dict.get(document, key)
    [key, ..rest] ->
      case dict.get(document, key) {
        Ok(tom.Table(inner)) -> lookup(inner, rest)
        _ -> Error(Nil)
      }
  }
}

// Drops the sections whose header names one of the paths, or a table below one
// of them, up to the next header that does not. A line that is not a header
// belongs to the section above it, so comments inside a dropped section go
// with it and comments before the next header stay.
fn remove_sections(text: String, paths: List(List(String))) -> String {
  case paths {
    [] -> text
    _ -> {
      let prefixes =
        list.map(paths, fn(path) {
          string.join(list.map(path, distribution_bundle.toml_key), ".")
        })
      let #(kept, _) =
        list.fold(string.split(text, "\n"), #([], False), fn(state, line) {
          let #(lines, dropping) = state
          let dropping = case header(line) {
            Some(name) -> names_any(name, prefixes)
            None -> dropping
          }
          case dropping {
            True -> #(lines, True)
            False -> #([line, ..lines], False)
          }
        })
      kept |> list.reverse |> string.join("\n")
    }
  }
}

fn names_any(header: String, prefixes: List(String)) -> Bool {
  list.any(prefixes, fn(prefix) {
    header == prefix || string.starts_with(header, prefix <> ".")
  })
}

// The dotted name inside a `[table]` or `[[array]]` header line, or None for
// any other line.
fn header(line: String) -> Option(String) {
  let trimmed = string.trim(line)
  case string.starts_with(trimmed, "[") {
    False -> None
    True -> {
      let opened = string.drop_start(trimmed, 1)
      let inner = case string.starts_with(opened, "[") {
        True -> string.drop_start(opened, 1)
        False -> opened
      }
      case string.split_once(inner, "]") {
        Ok(#(name, _)) -> Some(string.replace(name, " ", ""))
        Error(Nil) -> None
      }
    }
  }
}

// The merged text must parse, must keep every table the bundle does not own,
// and must configure distribution and executors the way the daemon reads them.
// The result is the parsed `[distribution]`, from which the options file is
// generated.
fn accepted(
  merged: String,
  tables: List(Table),
  path: String,
) -> Result(distribution.Config, String) {
  use document <- result.try(parse_document(merged, path))

  // A section the rewrite could not remove, such as a dotted key at the top of
  // the file, would leave the old value in place. Reading the result back is
  // what proves every table now says what the bundle says.
  use Nil <- result.try(
    list.try_each(tables, fn(table) {
      use wanted <- result.try(wanted_value(table))
      case lookup(document, table.path) {
        Ok(found) if found == wanted -> Ok(Nil)
        _ ->
          Error(
            path
            <> " could not be rewritten for ["
            <> string.join(table.path, ".")
            <> "]; remove it by hand and run the install again",
          )
      }
    }),
  )
  use found <- result.try(
    distribution.from_document(document)
    |> result.map_error(fn(reason) { path <> ": " <> reason }),
  )
  use _ <- result.try(
    executors.from_document(document)
    |> result.map_error(fn(reason) { path <> ": " <> reason }),
  )
  case found {
    Some(config) -> Ok(config)
    None -> Error(path <> " has no [distribution] table after the merge")
  }
}

fn write_config(
  path: String,
  existing: String,
  merged: String,
) -> Result(Step, String) {
  let step = fn(outcome) { Step(what: "daemon configuration", path:, outcome:) }
  case merged == existing {
    True -> Ok(step(Unchanged))
    False -> {
      let outcome = case existing {
        "" -> Created
        _ -> Merged
      }
      use Nil <- result.try(
        simplifile.create_directory_all(parent(path))
        |> result.map_error(describe(parent(path), _)),
      )
      simplifile.write(path, merged)
      |> result.map(fn(_) { step(outcome) })
      |> result.map_error(describe(path, _))
    }
  }
}

fn parent(path: String) -> String {
  case list.reverse(string.split(path, "/")) {
    [_, ..rest] ->
      case list.reverse(rest) {
        [""] | [] -> "/"
        parts -> string.join(parts, "/")
      }
    [] -> "/"
  }
}

fn start_command(options: Options, optfile: String) -> String {
  let home = case bootstrap.getenv("HOME") {
    Ok(current) if current == options.home -> ""
    _ -> "HOME=" <> options.home <> " "
  }
  home
  <> "LOOM_DISTRIBUTION_OPTFILE="
  <> optfile
  <> " loomd --config "
  <> options.config
}
