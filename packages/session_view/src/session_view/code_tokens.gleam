//// The token classes of a line of source, shared by the terminal and the web
//// view.
////
//// A code block in a transcript keeps the model's bytes and only gives each
//// kind of token a class, so a reader can scan a program faster than plain
//// monospace allows. This is presentation, not parsing: the compiler stays
//// the only authority on whether a program is valid, and nothing here
//// rejects a line. Every input produces tokens, and the text of the tokens,
//// joined in order, is always the input line unchanged.
////
//// The scanner works on one line at a time, because both hosts draw a block
//// a line at a time (the terminal wraps rows, the web view keeps a streamed
//// block's finished lines out of its diff). The price is that a construct
//// spanning lines, a block comment or a string with a raw newline, is not
//// followed across the break: each line is classified on its own, and a
//// continuation line is read as ordinary code. Gleam has no block comments
//// and its multi-line strings are rare in a program a model writes, so the
//// two hosts agree on what they draw without carrying a state between
//// lines.
////
//// The module lives in `session_view` so both hosts share one scanner and
//// it holds no `@external`, which keeps the package portable (lint R6). Each
//// host owns the mapping from a `CodeKind` to its own look: a terminal style
//// in `tui/markdown`, a stylesheet class in `web_view/code_view`.
////
//// ## Flow
////
//// - `line` picks the scanner for a fence's language tag.
//// - `gleam_line` and `python_line` give `scanned_parts` the language's
////   `Rules`; it walks a line's graphemes, handing quotes to `quoted_text`,
////   runs of spaces to `take_code_characters`, words to
////   `take_identifier_characters` and `word_kind`, and digits to
////   `take_number_characters`.
//// - `diff_kind` classifies a whole line of a diff fence.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A run of a line's text and the class of token it is.
pub type CodePart {
  CodePart(
    /// The bytes of the run, exactly as the line had them.
    text: String,
    /// What the run is.
    kind: CodeKind,
  )
}

/// The class of a run of source.
pub type CodeKind {
  /// Anything with no class of its own: an identifier, a space, an operator
  /// the scanner leaves alone.
  CodePlain

  /// A reserved word of the language.
  CodeKeyword

  /// A word that opens with a capital: a type or a constructor.
  CodeType

  /// A string literal, quotes included. One with no closing quote runs to the
  /// end of the line.
  CodeString

  /// A run of digits, with the `_` separators a Gleam number may carry.
  CodeNumber

  /// A `//` comment, to the end of the line.
  CodeComment

  /// One character of punctuation or an operator.
  CodePunctuation

  /// A line a diff adds.
  CodeAdded

  /// A line a diff removes.
  CodeRemoved

  /// A diff's file header or hunk header.
  CodeDiffMeta
}

// What one character begins, which decides the run that is taken from it.
type CodeCharacter {
  SpaceCharacter
  IdentifierCharacter
  NumberCharacter
  QuoteCharacter
  PunctuationCharacter
}

/// The tokens of one line of a fence tagged `language`.
///
/// A `gleam` tag is scanned as Gleam, a `python` (or `py`) tag as Python, and
/// a `diff` tag classifies the whole line by its first characters. Any other
/// tag, or none, is one plain run:
/// the scanner does not guess at a language it has no rules for, and a
/// guess wrong in colour is worse than none. The tag is compared without
/// case and without surrounding space, and is never used for anything but
/// this choice.
///
/// ## Examples
///
/// ```gleam
/// assert code_tokens.line(Some("gleam"), "let x = 1")
///   == [
///     code_tokens.CodePart("let", code_tokens.CodeKeyword),
///     code_tokens.CodePart(" ", code_tokens.CodePlain),
///     code_tokens.CodePart("x", code_tokens.CodePlain),
///     code_tokens.CodePart(" ", code_tokens.CodePlain),
///     code_tokens.CodePart("=", code_tokens.CodePunctuation),
///     code_tokens.CodePart(" ", code_tokens.CodePlain),
///     code_tokens.CodePart("1", code_tokens.CodeNumber),
///   ]
/// assert code_tokens.line(Some("rust"), "fn main()")
///   == [code_tokens.CodePart("fn main()", code_tokens.CodePlain)]
/// ```
pub fn line(language: Option(String), text: String) -> List(CodePart) {
  case language {
    Some(name) ->
      case string.lowercase(string.trim(name)) {
        "gleam" -> gleam_line(text)
        "python" | "py" -> python_line(text)
        "diff" -> [CodePart(text, diff_kind(text))]
        _ -> [CodePart(text, CodePlain)]
      }
    None -> [CodePart(text, CodePlain)]
  }
}

/// The tokens of one line of Gleam. An empty line has no tokens.
///
/// A string with no closing quote is a string to the end of the line, and a
/// backslash inside a string keeps the character after it from closing the
/// string.
///
/// ## Examples
///
/// ```gleam
/// assert code_tokens.gleam_line("Ok(\"a\") // done")
///   == [
///     code_tokens.CodePart("Ok", code_tokens.CodeType),
///     code_tokens.CodePart("(", code_tokens.CodePunctuation),
///     code_tokens.CodePart("\"a\"", code_tokens.CodeString),
///     code_tokens.CodePart(")", code_tokens.CodePunctuation),
///     code_tokens.CodePart(" ", code_tokens.CodePlain),
///     code_tokens.CodePart("// done", code_tokens.CodeComment),
///   ]
/// assert code_tokens.gleam_line("") == []
/// ```
pub fn gleam_line(text: String) -> List(CodePart) {
  scan(text, gleam_rules)
}

/// The tokens of one line of Python: keywords, single and double quoted
/// strings, `#` comments and numbers. It is the same scan as Gleam's with
/// Python's words, and it is as shallow: a triple-quoted string that spans
/// lines is read a line at a time.
///
/// ## Examples
///
/// ```gleam
/// assert code_tokens.python_line("x = 'a' # note")
///   == [
///     code_tokens.CodePart("x", code_tokens.CodePlain),
///     code_tokens.CodePart(" ", code_tokens.CodePlain),
///     code_tokens.CodePart("=", code_tokens.CodePunctuation),
///     code_tokens.CodePart(" ", code_tokens.CodePlain),
///     code_tokens.CodePart("'a'", code_tokens.CodeString),
///     code_tokens.CodePart(" ", code_tokens.CodePlain),
///     code_tokens.CodePart("# note", code_tokens.CodeComment),
///   ]
/// ```
pub fn python_line(text: String) -> List(CodePart) {
  scan(text, python_rules)
}

// What differs between the languages the scanner reads: the characters that
// begin a comment, the characters that open a string, and the reserved words.
type Rules {
  Rules(comment: List(String), quotes: List(String), keywords: List(String))
}

const gleam_rules =
  Rules(
    comment: ["/", "/"],
    quotes: ["\""],
    keywords: [
      "as", "assert", "case", "const", "echo", "fn", "if", "import", "let",
      "opaque", "panic", "pub", "todo", "type", "use",
    ],
  )

const python_rules =
  Rules(
    comment: ["#"],
    quotes: ["\"", "'"],
    keywords: [
      "False", "None", "True", "and", "as", "assert", "async", "await", "break",
      "class", "continue", "def", "del", "elif", "else", "except", "finally",
      "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
      "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    ],
  )

fn scan(text: String, rules: Rules) -> List(CodePart) {
  text
  |> string.to_graphemes
  |> scanned_parts(rules, [])
}

/// The class of a whole line of a `diff` fence: file and hunk headers, added
/// lines, removed lines, and everything else, which is context.
///
/// ## Examples
///
/// ```gleam
/// assert code_tokens.diff_kind("+let x = 1") == code_tokens.CodeAdded
/// assert code_tokens.diff_kind("@@ -1 +1 @@") == code_tokens.CodeDiffMeta
/// assert code_tokens.diff_kind(" context") == code_tokens.CodePlain
/// ```
pub fn diff_kind(line: String) -> CodeKind {
  case line {
    "+++" <> _ | "---" <> _ | "@@" <> _ | "diff " <> _ | "*** " <> _ ->
      CodeDiffMeta
    "+" <> _ -> CodeAdded
    "-" <> _ -> CodeRemoved
    _ -> CodePlain
  }
}

fn scanned_parts(
  characters: List(String),
  rules: Rules,
  accumulated: List(CodePart),
) -> List(CodePart) {
  case characters {
    [] -> list.reverse(accumulated)

    // A comment takes the rest of the line, so nothing after its marker is
    // classified as code.
    [character, ..rest] ->
      case list.take(characters, list.length(rules.comment)) == rules.comment {
        True ->
          list.reverse([
            CodePart(string.concat(characters), CodeComment),
            ..accumulated
          ])
        False -> scanned_character(character, rest, rules, accumulated)
      }
  }
}

// One run that begins with `character`, followed by the scan of what is left.
// The rules decide which characters open a string; every other class is the
// same in both languages.
fn scanned_character(
  character: String,
  rest: List(String),
  rules: Rules,
  accumulated: List(CodePart),
) -> List(CodePart) {
  let class = case list.contains(rules.quotes, character) {
    True -> QuoteCharacter
    False -> code_character(character)
  }
  case class {
    QuoteCharacter -> {
      let #(text, remaining) = quoted_text(rest, character, [character], False)
      scanned_parts(remaining, rules, [
        CodePart(text, CodeString),
        ..accumulated
      ])
    }
    SpaceCharacter -> {
      let #(tail, remaining) = take_code_characters(rest, SpaceCharacter, [])
      let text = string.concat([character, ..tail])
      scanned_parts(remaining, rules, [CodePart(text, CodePlain), ..accumulated])
    }
    IdentifierCharacter -> {
      let #(tail, remaining) = take_identifier_characters(rest, [])
      let text = string.concat([character, ..tail])
      scanned_parts(remaining, rules, [
        CodePart(text, word_kind(text, rules)),
        ..accumulated
      ])
    }
    NumberCharacter -> {
      let #(tail, remaining) = take_number_characters(rest, [])
      let text = string.concat([character, ..tail])
      scanned_parts(remaining, rules, [
        CodePart(text, CodeNumber),
        ..accumulated
      ])
    }
    PunctuationCharacter ->
      scanned_parts(rest, rules, [
        CodePart(character, CodePunctuation),
        ..accumulated
      ])
  }
}

// A grapheme that is one ASCII codepoint is classified by range. Any other
// grapheme, a letter with a combining mark included, is punctuation, which is
// what a membership test over the ASCII alphabets said of it.
fn code_character(character: String) -> CodeCharacter {
  case character {
    " " | "\t" -> SpaceCharacter
    "\"" -> QuoteCharacter
    _ ->
      case string.to_utf_codepoints(character) {
        [codepoint] -> ascii_character(string.utf_codepoint_to_int(codepoint))
        _ -> PunctuationCharacter
      }
  }
}

fn ascii_character(code: Int) -> CodeCharacter {
  case code {
    // `A`-`Z`, `a`-`z`, `_` and `@`.
    code if code >= 65 && code <= 90 -> IdentifierCharacter
    code if code >= 97 && code <= 122 -> IdentifierCharacter
    95 | 64 -> IdentifierCharacter
    code if code >= 48 && code <= 57 -> NumberCharacter
    _ -> PunctuationCharacter
  }
}

fn take_code_characters(
  characters: List(String),
  wanted: CodeCharacter,
  accumulated: List(String),
) -> #(List(String), List(String)) {
  case characters {
    [character, ..rest] ->
      case code_character(character) == wanted {
        True -> take_code_characters(rest, wanted, [character, ..accumulated])
        False -> #(list.reverse(accumulated), characters)
      }
    [] -> #(list.reverse(accumulated), [])
  }
}

fn take_identifier_characters(
  characters: List(String),
  accumulated: List(String),
) -> #(List(String), List(String)) {
  case characters {
    [character, ..rest] ->
      case code_character(character) {
        IdentifierCharacter | NumberCharacter ->
          take_identifier_characters(rest, [character, ..accumulated])
        SpaceCharacter | QuoteCharacter | PunctuationCharacter -> #(
          list.reverse(accumulated),
          characters,
        )
      }
    [] -> #(list.reverse(accumulated), [])
  }
}

fn take_number_characters(
  characters: List(String),
  accumulated: List(String),
) -> #(List(String), List(String)) {
  case characters {
    [character, ..rest] ->
      case code_character(character) {
        NumberCharacter ->
          take_number_characters(rest, [character, ..accumulated])
        IdentifierCharacter if character == "_" ->
          take_number_characters(rest, [character, ..accumulated])
        SpaceCharacter
        | IdentifierCharacter
        | QuoteCharacter
        | PunctuationCharacter -> #(list.reverse(accumulated), characters)
      }
    [] -> #(list.reverse(accumulated), [])
  }
}

// The body of a string after its opening quote. A backslash keeps the next
// character from closing the string, and the end of the line closes it, so
// an unterminated string still returns a run and the scanner never fails.
fn quoted_text(
  characters: List(String),
  quote: String,
  accumulated: List(String),
  escaped: Bool,
) -> #(String, List(String)) {
  case characters, escaped {
    [], _ -> #(string.concat(list.reverse(accumulated)), [])
    [character, ..rest], True ->
      quoted_text(rest, quote, [character, ..accumulated], False)
    ["\\", ..rest], False ->
      quoted_text(rest, quote, ["\\", ..accumulated], True)
    [character, ..rest], False if character == quote -> #(
      string.concat(list.reverse([character, ..accumulated])),
      rest,
    )
    [character, ..rest], False ->
      quoted_text(rest, quote, [character, ..accumulated], False)
  }
}

// A reserved word is a keyword, a word that opens with a capital is a type
// or a constructor, and any other word is plain.
fn word_kind(word: String, rules: Rules) -> CodeKind {
  case list.contains(rules.keywords, word) {
    True -> CodeKeyword
    False ->
      case string.to_graphemes(word) {
        [first, ..] ->
          case string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", first) {
            True -> CodeType
            False -> CodePlain
          }
        [] -> CodePlain
      }
  }
}
