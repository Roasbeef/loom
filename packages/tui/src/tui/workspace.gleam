//// Repository context for the terminal footer.
////
//// Discovery runs once before the event loop starts. The immutable result is
//// then safe to reuse across frames without polling Git or the filesystem.

import filepath
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import tui/internal/workspace_file

/// The repository root and branch visible to the terminal process.
pub type Context {
  Context(path: String, branch: Option(String))
}

/// Discovers the nearest repository surrounding the current directory.
pub fn discover() -> Context {
  case simplifile.current_directory() {
    Ok(path) -> discover_from(path)
    Error(_) -> Context(path: "workspace unavailable", branch: None)
  }
}

/// Discovers the nearest repository surrounding an explicit directory.
@internal
pub fn discover_from(path: String) -> Context {
  case repository_marker(path) {
    Ok(#(root, marker)) ->
      Context(path: root, branch: read_branch(root, marker))
    Error(Nil) -> Context(path:, branch: None)
  }
}

fn repository_marker(path: String) -> Result(#(String, String), Nil) {
  let marker = filepath.join(path, ".git")
  case simplifile.exists(marker, follow_links: False) {
    Ok(True) -> Ok(#(path, marker))
    Error(_) | Ok(False) -> {
      let parent = filepath.directory_name(path)
      case parent == path || parent == "" {
        True -> Error(Nil)
        False -> repository_marker(parent)
      }
    }
  }
}

fn read_branch(root: String, marker: String) -> Option(String) {
  case git_directory(root, marker) {
    Some(directory) ->
      case read_small_file(filepath.join(directory, "HEAD")) {
        Some(head) -> branch_from_head(head)
        None -> None
      }
    None -> None
  }
}

fn git_directory(root: String, marker: String) -> Option(String) {
  case simplifile.is_directory(marker) {
    Ok(True) -> Some(marker)
    Error(_) | Ok(False) ->
      case read_small_file(marker) {
        Some(contents) -> parse_git_directory(root, contents)
        None -> None
      }
  }
}

fn read_small_file(path: String) -> Option(String) {
  case workspace_file.read_small_regular(path, 4096) {
    Ok(contents) ->
      case bit_array.to_string(contents) {
        Ok(text) -> Some(text)
        Error(Nil) -> None
      }
    Error(Nil) -> None
  }
}

fn parse_git_directory(root: String, contents: String) -> Option(String) {
  let prefix = "gitdir: "
  let directory = string.trim(contents)
  case string.starts_with(directory, prefix) {
    False -> None
    True -> {
      let path = string.drop_start(directory, string.length(prefix))
      Some(resolve_git_directory(root, path))
    }
  }
}

fn resolve_git_directory(root: String, path: String) -> String {
  case filepath.is_absolute(path) {
    True -> path
    False -> filepath.join(root, path)
  }
}

/// Decodes a symbolic or detached Git HEAD for display.
@internal
pub fn branch_from_head(contents: String) -> Option(String) {
  let head = string.trim(contents)
  let prefix = "ref: refs/heads/"
  case head == "", string.starts_with(head, prefix) {
    True, _ -> None
    False, True -> branch_name(string.drop_start(head, string.length(prefix)))
    False, False -> detached_head(head)
  }
}

fn branch_name(name: String) -> Option(String) {
  case
    string.drop_start(name, 128) == ""
    && !string.contains(name, "\n")
    && !string.contains(name, "\r")
  {
    True -> Some(name)
    False -> None
  }
}

fn detached_head(head: String) -> Option(String) {
  case
    { exact_length(head, 40) || exact_length(head, 64) }
    && list.all(string.to_utf_codepoints(head), is_hex)
  {
    True -> Some(string.slice(head, at_index: 0, length: 8))
    False -> None
  }
}

fn exact_length(text: String, length: Int) -> Bool {
  string.drop_start(text, length) == ""
  && string.drop_start(text, length - 1) != ""
}

fn is_hex(codepoint: UtfCodepoint) -> Bool {
  let code = string.utf_codepoint_to_int(codepoint)
  { code >= 0x30 && code <= 0x39 }
  || { code >= 0x61 && code <= 0x66 }
  || { code >= 0x41 && code <= 0x46 }
}

/// Formats the repository path and branch as a compact footer label.
pub fn label(context: Context) -> String {
  let Context(path:, branch:) = context
  path_label(path)
  <> case branch {
    Some(name) -> " (" <> name <> ")"
    None -> ""
  }
}

/// Abbreviates conventional macOS and Linux home directories.
@internal
pub fn path_label(path: String) -> String {
  case filepath.split(path) {
    ["/", "Users", _, ..rest] | ["/", "home", _, ..rest] -> home_path(rest)
    _ -> path
  }
}

fn home_path(segments: List(String)) -> String {
  case segments {
    [] -> "~"
    _ -> "~/" <> string.join(segments, "/")
  }
}
