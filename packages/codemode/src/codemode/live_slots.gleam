//// Two reusable authored namespaces bound BEAM atoms and loaded generations.
//// Only import tokens are rewritten. Source strings and comments containing
//// import-like text remain data; the compiler receives a namespaced package
//// derived exclusively from the existing vetted source envelope.

import codemode/vet
import codemode/vet/package
import gleam/list
import gleam/string
import glexer
import glexer/token

/// The two implementation namespaces reused after safe code retirement.
pub type Slot {
  /// The first implementation namespace.
  First

  /// The second implementation namespace.
  Second
}

/// Names an authored module within one bounded implementation slot.
///
/// ## Examples
///
/// ```gleam
/// assert live_slots.module(First, "counter/tool") == "loom_live_a/counter/tool"
/// ```
///
pub fn module(slot: Slot, name: String) -> String {
  prefix(slot) <> "/" <> name
}

fn prefix(slot: Slot) -> String {
  case slot {
    First -> "loom_live_a"
    Second -> "loom_live_b"
  }
}

/// Rewrites the admitted package's authored module paths and imports.
///
/// The module set remains exactly the vetted set. Trusted runtime modules
/// retain their original names and can never be supplied by this operation.
///
/// ## Examples
///
/// ```gleam
/// // live_slots.sources(vetted, First)
/// ```
///
pub fn sources(
  vetted: package.VettedPackage,
  slot: Slot,
) -> List(#(String, String)) {
  let names = package.module_names(vetted)
  list.map(package.modules(vetted), fn(source) {
    #(module(slot, source.0), rewrite(vet.vetted_source(source.1), names, slot))
  })
}

/// Rewrites only imported authored names in a previously vetted source.
///
/// ## Examples
///
/// ```gleam
/// assert live_slots.rewrite("import counter/tool", ["counter/tool"], First)
///   == "import loom_live_a/counter/tool"
/// ```
///
pub fn rewrite(source: String, authored: List(String), slot: Slot) -> String {
  let imports =
    glexer.new(source)
    |> glexer.discard_whitespace
    |> glexer.discard_comments
    |> glexer.lex
    |> import_offsets(authored, [])
  glexer.new(source)
  |> glexer.lex
  |> list.map(fn(item) {
    let #(value, position) = item
    case list.contains(imports, position.byte_offset) {
      True -> prefix(slot) <> "/" <> token.to_source(value)
      False -> token.to_source(value)
    }
  })
  |> string.join("")
}

fn import_offsets(
  tokens: List(#(token.Token, glexer.Position)),
  authored: List(String),
  offsets: List(Int),
) -> List(Int) {
  case tokens {
    [#(token.Import, _), #(token.Name(first), at), ..rest] -> {
      let #(segments, tail) = path(rest, [first])
      let name = string.join(list.reverse(segments), "/")
      let offsets = case list.contains(authored, name) {
        True -> [at.byte_offset, ..offsets]
        False -> offsets
      }
      import_offsets(tail, authored, offsets)
    }
    [_, ..rest] -> import_offsets(rest, authored, offsets)
    [] -> offsets
  }
}

fn path(
  tokens: List(#(token.Token, glexer.Position)),
  segments: List(String),
) -> #(List(String), List(#(token.Token, glexer.Position))) {
  case tokens {
    [#(token.Slash, _), #(token.Name(segment), _), ..rest] ->
      path(rest, [segment, ..segments])
    _ -> #(segments, tokens)
  }
}
