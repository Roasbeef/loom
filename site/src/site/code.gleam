//// A code sample with a language label, coloured tokens and a copy button.
////
//// Every command and program on the site goes through this one component,
//// so every sample can be copied. The button copies the source as written,
//// except that a shell sample whose lines start with a `$ ` prompt copies
//// only the commands: pasting a prompt into a shell is never what a reader
//// wants. Colouring is cosmetic and lives in `site/highlight`.

import gleam/list
import gleam/option.{type Option, Some}
import gleam/string
import lustre/attribute.{attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import site/highlight
import site/msg.{type Msg}

/// A sample. `id` names it on the page, so that its button can say "Copied".
/// `copied` is the id of the sample that was copied most recently, if its
/// label is still up.
pub fn view(
  id: String,
  lang: String,
  source: String,
  copied: Option(String),
) -> Element(Msg) {
  let done = copied == Some(id)
  html.figure([attribute.class("code")], [
    html.figcaption([], [
      html.span([attribute.class("code-lang")], [element.text(label_for(lang))]),
      html.button(
        [
          attribute.class(case done {
            True -> "copy is-done"
            False -> "copy"
          }),
          attribute.type_("button"),
          attribute("aria-label", "Copy the " <> label_for(lang) <> " sample"),
          event.on_click(msg.CopyText(id, copyable(lang, source))),
        ],
        [
          element.text(case done {
            True -> "Copied"
            False -> "Copy"
          }),
        ],
      ),
      html.span(
        [
          attribute.class("visually-hidden"),
          attribute("role", "status"),
        ],
        [
          element.text(case done {
            True -> "Copied to the clipboard"
            False -> ""
          }),
        ],
      ),
    ]),
    html.pre([attribute.tabindex(0), attribute("data-lang", lang)], [
      html.code(
        [],
        list.map(string.split(source, "\n"), fn(line) {
          html.span(
            [attribute.class("code-line")],
            list.map(highlight.line(lang, line), token),
          )
        }),
      ),
    ]),
  ])
}

fn token(item: highlight.Token) -> Element(Msg) {
  case item.kind {
    highlight.Plain -> element.text(item.text)
    kind ->
      html.span([attribute.class(token_class(kind))], [element.text(item.text)])
  }
}

fn token_class(kind: highlight.Kind) -> String {
  case kind {
    highlight.Plain -> "t-plain"
    highlight.Comment -> "t-comment"
    highlight.Str -> "t-str"
    highlight.Keyword -> "t-kw"
    highlight.Prompt -> "t-prompt"
    highlight.Key -> "t-key"
    highlight.Header -> "t-header"
  }
}

/// The label a sample shows for its language.
pub fn label_for(lang: String) -> String {
  case lang {
    "" -> "text"
    "sh" -> "shell"
    other -> other
  }
}

/// The text the copy button puts on the clipboard. For a shell sample with
/// prompts it is the commands alone.
///
/// ## Examples
///
/// ```gleam
/// assert copyable("sh", "$ make install\nbuilt") == "make install"
/// ```
pub fn copyable(lang: String, source: String) -> String {
  let lines = string.split(source, "\n")
  let prompted = list.any(lines, fn(line) { string.starts_with(line, "$ ") })
  case lang == "sh" && prompted {
    True ->
      lines
      |> list.filter(fn(line) { string.starts_with(line, "$ ") })
      |> list.map(fn(line) { string.drop_start(line, 2) })
      |> string.join("\n")
    False -> source
  }
}
