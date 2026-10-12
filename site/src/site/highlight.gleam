//// Line-level syntax colouring for the code samples on the site.
////
//// It knows just enough of shell, TOML and Gleam to colour comments,
//// strings, keywords and prompts. Colouring is cosmetic: an unknown language
//// renders as plain text, and the copy button copies the source with only
//// its shell prompts removed (`site/code`). The tokenizer is the one the
//// engineer's-site concept used, moved here so every sample on the site
//// shares it.

import gleam/list
import gleam/string

pub type Kind {
  Plain
  Comment
  Str
  Keyword
  Prompt
  Key
  Header
}

pub type Token {
  Token(kind: Kind, text: String)
}

/// Tokenizes one line of source in the given language.
///
/// ## Examples
///
/// ```gleam
/// line("sh", "$ make install # build")
/// // -> [Token(Prompt, "$ "), Token(Plain, "make install "), Token(Comment, "# build")]
/// ```
pub fn line(lang: String, text: String) -> List(Token) {
  case lang {
    "sh" | "bash" -> shell(text)
    "toml" -> toml(text)
    "gleam" -> scan(string.to_graphemes(text), lang, "", [])
    _ -> [Token(Plain, text)]
  }
}

fn shell(text: String) -> List(Token) {
  case text {
    "$ " <> rest -> [
      Token(Prompt, "$ "),
      ..scan(string.to_graphemes(rest), "sh", "", [])
    ]
    _ -> scan(string.to_graphemes(text), "sh", "", [])
  }
}

fn toml(text: String) -> List(Token) {
  let trimmed = string.trim_start(text)
  case string.starts_with(trimmed, "[") {
    True -> toml_header(text)
    False ->
      case string.split_once(text, " = ") {
        Ok(#(key, value)) ->
          case string.contains(key, "\"") || string.starts_with(trimmed, "#") {
            True -> scan(string.to_graphemes(text), "toml", "", [])
            False -> [
              Token(Key, key),
              Token(Plain, " = "),
              ..scan(string.to_graphemes(value), "toml", "", [])
            ]
          }
        Error(_) -> scan(string.to_graphemes(text), "toml", "", [])
      }
  }
}

/// A table header is coloured whole, up to a trailing comment.
fn toml_header(text: String) -> List(Token) {
  case string.split_once(text, " #") {
    Ok(#(header, comment)) -> [
      Token(Header, header),
      Token(Comment, " #" <> comment),
    ]
    Error(_) -> [Token(Header, text)]
  }
}

/// Walks the characters of a line, colouring strings, comments and keywords.
/// `buf` holds the identifier being read.
fn scan(
  chars: List(String),
  lang: String,
  buf: String,
  acc: List(Token),
) -> List(Token) {
  case chars {
    [] -> list.reverse(push_word(acc, lang, buf))
    ["\"", ..rest] -> {
      let #(body, after) = read_string(rest, "\"")
      scan(after, lang, "", [Token(Str, body), ..push_word(acc, lang, buf)])
    }
    ["/", "/", ..rest] if lang == "gleam" ->
      list.reverse([
        Token(Comment, "//" <> string.concat(rest)),
        ..push_word(acc, lang, buf)
      ])
    ["#", ..rest] if lang == "sh" || lang == "toml" ->
      case buf == "" {
        True ->
          list.reverse([Token(Comment, "#" <> string.concat(rest)), ..acc])
        False -> scan(rest, lang, buf <> "#", acc)
      }
    [c, ..rest] ->
      case is_word_char(c) {
        True -> scan(rest, lang, buf <> c, acc)
        False -> scan(rest, lang, "", push(push_word(acc, lang, buf), Plain, c))
      }
  }
}

/// Reads a string literal after its opening quote, keeping the quotes.
fn read_string(chars: List(String), acc: String) -> #(String, List(String)) {
  case chars {
    [] -> #(acc, [])
    ["\\", next, ..rest] -> read_string(rest, acc <> "\\" <> next)
    ["\"", ..rest] -> #(acc <> "\"", rest)
    [c, ..rest] -> read_string(rest, acc <> c)
  }
}

fn push_word(acc: List(Token), lang: String, word: String) -> List(Token) {
  case word {
    "" -> acc
    _ ->
      case is_keyword(lang, word) {
        True -> [Token(Keyword, word), ..acc]
        False -> push(acc, Plain, word)
      }
  }
}

/// Adds text, merging neighbouring plain tokens to keep the DOM small.
fn push(acc: List(Token), kind: Kind, text: String) -> List(Token) {
  case acc {
    [Token(Plain, previous), ..older] if kind == Plain -> [
      Token(Plain, previous <> text),
      ..older
    ]
    _ -> [Token(kind, text), ..acc]
  }
}

fn is_word_char(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    c,
  )
}

fn is_keyword(lang: String, word: String) -> Bool {
  case lang {
    "gleam" ->
      list.contains(
        [
          "import", "pub", "fn", "let", "case", "use", "type", "const", "as",
          "True", "False", "Nil", "Ok", "Error", "assert",
        ],
        word,
      )
    "toml" -> word == "true" || word == "false"
    _ -> False
  }
}
