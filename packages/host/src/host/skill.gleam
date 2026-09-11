//// Loads the operator's Markdown skills as bounded, immutable documents.
////
//// Discovery resolves directory and file identities before claiming names, so
//// two tool-specific directories pointing at the same library contribute one
//// catalogue. The first distinct file claiming a name wins; later collisions
//// are reported rather than making filesystem enumeration order authoritative.
//// Skill bodies are data. Loading a document never evaluates shell snippets or
//// grants the permissions named by another harness's frontmatter.

import filepath
import glaml
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/set.{type Set}
import gleam/string
import host/bootstrap

/// Whether an operator can select this skill with a slash command.
pub type UserInvocation {
  /// Include the skill in the operator's command catalogue.
  UserInvocable

  /// Retain the skill for model selection without offering a slash command.
  HiddenFromCommands
}

/// Whether the model may choose a skill without an explicit invocation.
pub type ModelInvocation {
  /// Describe the skill to the model for relevance-based selection.
  ModelSelectable

  /// Load the skill only when the operator explicitly invokes it.
  ExplicitOnly
}

/// One validated document, captured with the metadata that advertised it.
pub type Skill {
  Skill(
    /// The validated command name, without its leading slash.
    name: String,
    /// The short description used to decide whether this skill applies.
    description: String,
    /// Optional guidance shown beside the command's arguments.
    argument_hint: String,
    /// Whether the command palette may offer this skill.
    user_invocation: UserInvocation,
    /// Whether the model may select this skill automatically.
    model_invocation: ModelInvocation,
    /// The canonical document path, also locating its relative resources.
    path: String,
    /// Markdown after the frontmatter, preserved without evaluation.
    body: String,
    /// The complete source, disclosed only when this skill is activated.
    document: String,
  )
}

/// A completed discovery, with one document per name and visible refusals.
pub opaque type Catalogue {
  Catalogue(skills: List(Skill), warnings: List(String))
}

/// The largest skill document retained by one discovery.
pub const max_file_bytes = 65_536

/// Bounds how many directory entries discovery examines at one location.
pub const max_directory_entries = 256

/// Bounds the expanded instruction and substituted arguments together.
pub const max_expanded_bytes = 262_144

/// Returns the supported user locations in precedence order.
///
/// The singular and capitalized spellings are compatibility locations. Realpath
/// deduplication makes them free aliases on machines where they name the same
/// directory as a primary location.
///
/// ## Examples
///
/// ```gleam
/// assert skill.directories(None) == []
/// ```
pub fn directories(home: Option(String)) -> List(String) {
  case home {
    None -> []
    Some(home) ->
      list.map(
        [".agents/skills", ".agents/skill", ".claude/skills", ".Claude/skills"],
        fn(relative) { home <> "/" <> relative },
      )
  }
}

/// Creates a catalogue without accessing the operator's filesystem.
///
/// ## Examples
///
/// ```gleam
/// assert skill.entries(skill.empty()) == []
/// ```
pub fn empty() -> Catalogue {
  Catalogue([], [])
}

/// Returns the name-sorted documents captured by discovery.
///
/// ## Examples
///
/// ```gleam
/// assert skill.entries(skill.empty()) == []
/// ```
pub fn entries(catalogue: Catalogue) -> List(Skill) {
  catalogue.skills
}

/// Returns discovery refusals, in the order the locations were examined.
///
/// Missing optional locations are quiet; malformed documents are not.
///
/// ## Examples
///
/// ```gleam
/// assert skill.warnings(skill.empty()) == []
/// ```
pub fn warnings(catalogue: Catalogue) -> List(String) {
  catalogue.warnings
}

type Discovery {
  Discovery(
    directories: Set(String),
    files: Set(String),
    names: Dict(String, Skill),
    warnings: List(String),
  )
}

/// Discovers direct child directories containing a regular `SKILL.md`.
///
/// Reads use the host's existing byte and entry bounds. A bad file refuses
/// only its own entry. Keeping the body with its metadata means later edits
/// cannot change what a selected, already-loaded command invokes.
///
/// ## Examples
///
/// ```gleam
/// assert skill.entries(skill.discover([])) == []
/// ```
pub fn discover(locations: List(String)) -> Catalogue {
  let initial = Discovery(set.new(), set.new(), dict.new(), [])
  let discovered = list.fold(locations, initial, discover_directory)
  Catalogue(
    dict.values(discovered.names)
      |> list.sort(fn(first, second) { string.compare(first.name, second.name) }),
    list.reverse(discovered.warnings),
  )
}

fn discover_directory(state: Discovery, location: String) -> Discovery {
  use <- bool.guard(when: !bootstrap.path_exists(location), return: state)

  case bootstrap.canonical_directory(location) {
    Error(reason) -> refused(state, location, reason)
    Ok(directory) -> discover_resolved_directory(state, directory)
  }
}

fn discover_resolved_directory(
  state: Discovery,
  directory: String,
) -> Discovery {
  use <- bool.guard(
    when: set.contains(state.directories, directory),
    return: state,
  )
  let state =
    Discovery(..state, directories: set.insert(state.directories, directory))

  case bootstrap.list_directory_bounded(directory, max_directory_entries) {
    Error(reason) -> refused(state, directory, reason)
    Ok(children) ->
      children
      |> list.sort(string.compare)
      |> list.fold(state, fn(state, child) {
        discover_file(state, directory <> "/" <> child <> "/SKILL.md")
      })
  }
}

fn discover_file(state: Discovery, path: String) -> Discovery {
  use <- bool.guard(when: !bootstrap.path_exists(path), return: state)

  case bootstrap.canonical_path(path) {
    Error(reason) -> refused(state, path, reason)
    Ok(path) -> discover_resolved_file(state, path)
  }
}

fn discover_resolved_file(state: Discovery, path: String) -> Discovery {
  use <- bool.guard(when: set.contains(state.files, path), return: state)
  let state = Discovery(..state, files: set.insert(state.files, path))

  case read(path) {
    Error(reason) -> refused(state, path, reason)
    Ok(skill) ->
      case dict.get(state.names, skill.name) {
        Error(Nil) ->
          Discovery(..state, names: dict.insert(state.names, skill.name, skill))
        Ok(first) ->
          refused(
            state,
            path,
            "duplicate skill "
              <> skill.name
              <> "; already loaded from "
              <> first.path,
          )
      }
  }
}

fn refused(state: Discovery, path: String, reason: String) -> Discovery {
  Discovery(..state, warnings: [path <> ": " <> reason, ..state.warnings])
}

fn read(path: String) -> Result(Skill, String) {
  use bytes <- result.try(bootstrap.read_bounded(path, max_file_bytes))
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("skill document is not UTF-8"),
  )
  parse(path, text)
}

/// Parses Agent Skills frontmatter through the YAML library.
///
/// Plain, quoted, folded and literal descriptions are accepted. Unknown
/// frontmatter fields remain inert: they neither execute a command nor widen
/// tool access. Invalid supported fields refuse the document with a reason.
///
/// ## Examples
///
/// ```gleam
/// let document = "---\nname: explain\ndescription: Explain code\n---\nBe clear.\n"
/// let assert Ok(loaded) = skill.parse("/skills/explain/SKILL.md", document)
/// assert loaded.name == "explain"
/// assert loaded.body == "Be clear.\n"
/// ```
@internal
pub fn parse(path: String, text: String) -> Result(Skill, String) {
  use <- bool.guard(
    when: string.byte_size(text) > max_file_bytes,
    return: Error("skill document exceeds the byte limit"),
  )
  use #(first, remaining) <- result.try(next_line(text))
  use <- bool.guard(
    when: string.trim(first) != "---",
    return: Error("skill document must start with YAML frontmatter"),
  )
  use #(header, body) <- result.try(frontmatter(remaining, []))
  use fields <- result.try(parse_fields(header))
  use name <- result.try(required(fields, "name"))
  use description <- result.try(required(fields, "description"))
  use Nil <- result.try(validate_name(name))
  use <- bool.guard(
    when: filepath.base_name(filepath.directory_name(path)) != name,
    return: Error("skill name must match its parent directory"),
  )
  use <- bool.guard(
    when: list.length(string.to_utf_codepoints(description)) > 1024,
    return: Error("skill description exceeds 1024 characters"),
  )
  use Nil <- result.try(validate_optional_fields(fields))
  use argument_hint <- result.try(optional_text(fields, "argument-hint"))
  use <- bool.guard(
    when: string.byte_size(argument_hint) > 512,
    return: Error("skill argument hint exceeds 512 bytes"),
  )
  use user_invocation <- result.try(user_invocation(fields))
  use model_invocation <- result.try(model_invocation(fields))
  Ok(Skill(
    name:,
    description:,
    argument_hint:,
    user_invocation:,
    model_invocation:,
    path:,
    body:,
    document: text,
  ))
}

fn next_line(text: String) -> Result(#(String, String), String) {
  string.split_once(text, "\n")
  |> result.replace_error("skill frontmatter is not terminated")
}

fn frontmatter(
  text: String,
  reversed: List(String),
) -> Result(#(List(String), String), String) {
  use <- bool.lazy_guard(text == "---" || text == "---\r", fn() {
    Ok(#(list.reverse(reversed), ""))
  })
  use #(line, remaining) <- result.try(next_line(text))
  case line {
    "---" | "---\r" -> Ok(#(list.reverse(reversed), remaining))
    _ -> frontmatter(remaining, [line, ..reversed])
  }
}

fn parse_fields(
  lines: List(String),
) -> Result(Dict(String, glaml.Node), String) {
  use documents <- result.try(
    glaml.parse_string(string.join(lines, "\n"))
    |> result.replace_error("invalid YAML skill frontmatter"),
  )
  use pairs <- result.try(case documents {
    [glaml.Document(glaml.NodeMap(pairs))] -> Ok(pairs)
    _ -> Error("skill frontmatter must be one YAML mapping")
  })
  list.try_fold(pairs, dict.new(), fn(fields, pair) {
    use key <- result.try(case pair.0 {
      glaml.NodeStr(key) -> Ok(key)
      _ -> Error("skill frontmatter keys must be strings")
    })
    use <- bool.lazy_guard(dict.has_key(fields, key), fn() {
      Error("duplicate skill frontmatter field: " <> key)
    })
    Ok(dict.insert(fields, key, pair.1))
  })
}

fn required(
  fields: Dict(String, glaml.Node),
  key: String,
) -> Result(String, String) {
  use value <- result.try(
    dict.get(fields, key)
    |> result.map_error(fn(_) { "missing skill frontmatter field: " <> key }),
  )
  use value <- result.try(text_value(value, key))
  case string.trim(value) {
    "" -> Error("empty skill frontmatter field: " <> key)
    value -> Ok(value)
  }
}

fn text_value(value: glaml.Node, key: String) -> Result(String, String) {
  case value {
    glaml.NodeStr(text) -> Ok(text)
    _ -> Error("skill frontmatter field must be text: " <> key)
  }
}

fn optional_text(
  fields: Dict(String, glaml.Node),
  key: String,
) -> Result(String, String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok("")
    Ok(value) -> text_value(value, key)
  }
}

fn validate_optional_fields(
  fields: Dict(String, glaml.Node),
) -> Result(Nil, String) {
  use _license <- result.try(optional_text(fields, "license"))
  use compatibility <- result.try(optional_text(fields, "compatibility"))
  use <- bool.guard(
    list.length(string.to_utf_codepoints(compatibility)) > 500,
    Error("skill compatibility exceeds 500 characters"),
  )
  case dict.get(fields, "metadata") {
    Error(Nil) -> Ok(Nil)
    Ok(glaml.NodeMap(pairs)) ->
      list.try_fold(pairs, Nil, fn(_, pair) {
        use _key <- result.try(text_value(pair.0, "metadata key"))
        use _value <- result.try(text_value(pair.1, "metadata value"))
        Ok(Nil)
      })
    Ok(_) -> Error("skill metadata must be a string-to-string mapping")
  }
}

fn validate_name(name: String) -> Result(Nil, String) {
  use pattern <- result.try(
    regexp.from_string("^[\\p{L}\\p{N}]+(?:-[\\p{L}\\p{N}]+)*$")
    |> result.replace_error("skill name pattern is unavailable"),
  )
  let valid_characters =
    regexp.check(pattern, name) && string.lowercase(name) == name
  case valid_characters && list.length(string.to_utf_codepoints(name)) <= 64 {
    True -> Ok(Nil)
    False ->
      Error(
        "skill name must be 1-64 lowercase letters, digits or single hyphens",
      )
  }
}

fn user_invocation(
  fields: Dict(String, glaml.Node),
) -> Result(UserInvocation, String) {
  case dict.get(fields, "user-invocable") {
    Error(Nil) | Ok(glaml.NodeBool(True)) -> Ok(UserInvocable)
    Ok(glaml.NodeBool(False)) -> Ok(HiddenFromCommands)
    Ok(_) -> Error("user-invocable must be true or false")
  }
}

fn model_invocation(
  fields: Dict(String, glaml.Node),
) -> Result(ModelInvocation, String) {
  case dict.get(fields, "disable-model-invocation") {
    Error(Nil) | Ok(glaml.NodeBool(False)) -> Ok(ModelSelectable)
    Ok(glaml.NodeBool(True)) -> Ok(ExplicitOnly)
    Ok(_) -> Error("disable-model-invocation must be true or false")
  }
}

/// Looks up a captured skill by name rather than accepting a filesystem path.
///
/// ## Examples
///
/// ```gleam
/// assert skill.lookup(skill.empty(), "missing") == Error("unknown skill: missing")
/// ```
pub fn lookup(catalogue: Catalogue, name: String) -> Result(Skill, String) {
  list.find(catalogue.skills, fn(skill) { skill.name == name })
  |> result.map_error(fn(_) { "unknown skill: " <> name })
}

/// Expands an invocation while keeping its source and arguments attributable.
///
/// Only the literal `$ARGUMENTS` placeholder is substituted. Shell snippets,
/// positional dollar amounts and referenced scripts stay Markdown for the
/// agent to read and act on through its ordinary tools and permissions.
///
/// ## Examples
///
/// ```gleam
/// // skill.expand(loaded, "check the queue")
/// ```
pub fn expand(skill: Skill, arguments: String) -> Result(String, String) {
  let invocation =
    "/"
    <> skill.name
    <> case arguments {
      "" -> ""
      text -> " " <> text
    }
  let prefix =
    invocation
    <> "\n\nSkill instructions from "
    <> string.inspect(skill.path)
    <> ":\n\n"
  let parts = string.split(skill.document, "$ARGUMENTS")
  let body_bytes =
    list.fold(parts, 0, fn(total, part) { total + string.byte_size(part) })
  let expanded_bytes =
    string.byte_size(prefix)
    + body_bytes
    + { list.length(parts) - 1 }
    * string.byte_size(arguments)

  // Measure substitution before joining. Repeated placeholders must not turn
  // individually bounded inputs into an unbounded allocation.
  use <- bool.guard(
    expanded_bytes > max_expanded_bytes,
    Error("expanded skill exceeds 256 KiB"),
  )
  Ok(prefix <> string.join(parts, arguments))
}
