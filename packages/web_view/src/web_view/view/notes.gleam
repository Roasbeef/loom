//// The field index and reader share one fixed, read-only event region inside
//// the Strands pane. Values and keys are text nodes; the row keys and marks
//// are numeric positions assigned from the supplied board, never cell names.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/notes_view
import web_view/markdown_view
import web_view/notes

/// Draws one strand's index and reader without changing the surrounding shell.
/// The index remains mounted while detail is open, preserving browser scroll.
///
/// ## Examples
///
/// ```gleam
/// // notes.view(state, "main", press, search)
/// ```
pub fn view(
  state: notes.State,
  strand: String,
  press: fn(notes.Press) -> message,
  search: fn(String) -> message,
) -> Element(message) {
  let opened = notes.selected(state)
  let mode = case opened {
    Ok(_) -> "detail"
    Error(Nil) -> "index"
  }
  html.section(
    [
      attribute.class("pane pane-notes strand-notes"),
      attribute.aria_label("Notes"),
    ],
    [
      html.div([attribute.class("notes-heading")], [
        html.div([], [
          html.h3([attribute.class("notes-label")], [html.text("Notes")]),
          html.p([attribute.class("notes-scope")], [html.text(strand)]),
        ]),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("notes-refresh"),
            attribute.disabled(
              state.read == notes.Queued || state.read == notes.Waiting,
            ),
            event.on_click(press(notes.Refresh)),
          ],
          [html.text("Refresh")],
        ),
      ]),
      html.p([attribute.class("notes-status"), attribute.role("status")], [
        html.text(status(state)),
      ]),
      html.div(
        [attribute.class("notes-index"), attribute.hidden(mode == "detail")],
        [
          html.input([
            attribute.type_("search"),
            attribute.class("notes-search"),
            attribute.aria_label("Search available note keys and content"),
            attribute.placeholder("Search available notes…"),
            attribute.value(state.query),
            attribute.maxlength(256),
            event.on_input(search),
          ]),
          index(state, press),
        ],
      ),
      case opened {
        Ok(note) -> reader(state, note, press)
        Error(Nil) -> element.none()
      },
      element.element("loom-notes", [attribute.attribute("mode", mode)], []),
    ],
  )
}

fn status(state: notes.State) -> String {
  let progress = case state.read {
    notes.Unread -> "Read this strand’s notes with Refresh."
    notes.Queued | notes.Waiting -> "Reading notes…"
    notes.Unavailable -> "Notes unavailable. Try Refresh again."
    notes.Ready -> ""
  }
  let snapshot = case state.board {
    None -> ""
    Some(board) -> {
      let shown = list.length(board.notes)
      let omitted = board.total - shown
      int.to_string(shown)
      <> " of "
      <> int.to_string(board.total)
      <> " notes · snapshot rev "
      <> int.to_string(board.as_of)
      <> case omitted > 0 {
        True ->
          ". "
          <> int.to_string(omitted)
          <> " omitted; search covers available notes only."
        False -> "."
      }
    }
  }
  string.join(list.filter([progress, snapshot], fn(text) { text != "" }), " ")
}

fn index(
  state: notes.State,
  press: fn(notes.Press) -> message,
) -> Element(message) {
  case state.board, notes.rows(state) {
    None, _ -> element.none()
    Some(board), [] ->
      html.p([attribute.class("pane-empty")], [
        html.text(case board.notes {
          [] -> "No notes in this snapshot."
          [_, ..] -> "No matching available notes."
        }),
      ])
    Some(_), matches -> {
      keyed.ul(
        [attribute.class("notes-list")],
        matches
          |> list.map(fn(note) {
            let number =
              dict.get(state.keys, note.key)
              |> result.unwrap(0)
              |> int.to_string
            #(
              number,
              html.li([], [
                html.button(
                  [
                    attribute.type_("button"),
                    attribute.class("notes-row"),
                    attribute.attribute("data-note-row", number),
                    event.on_click(press(notes.Open(note.key))),
                  ],
                  [
                    html.span([attribute.class("notes-key")], [
                      html.text(note.key),
                    ]),
                    html.span(
                      [
                        attribute.class("notes-row-chevron"),
                        attribute.aria_hidden(True),
                      ],
                      [html.text("›")],
                    ),
                    metadata(note),
                    preview(presentation(state, note).preview, note.extent),
                  ],
                ),
              ]),
            )
          }),
      )
    }
  }
}

// Complete previews reuse the existing inline renderer. The leaf memo keeps
// stream arrivals from reparsing unchanged text; excerpts remain literal.
fn preview(text: String, extent: notes_view.Extent) -> Element(message) {
  use <- element.memo([element.ref(text), element.ref(extent)])
  html.span([attribute.class("notes-preview")], case extent {
    notes_view.Complete -> markdown_view.line(text, 220)
    notes_view.Excerpt -> [html.text(text)]
  })
}

fn metadata(note: notes_view.Note) -> Element(message) {
  html.span([attribute.class("notes-meta")], [
    html.text(
      "cell rev "
      <> int.to_string(note.seq)
      <> " · "
      <> case note.extent {
        notes_view.Complete -> "complete"
        notes_view.Excerpt -> "excerpt"
      },
    ),
  ])
}

fn reader(
  state: notes.State,
  note: notes_view.Note,
  press: fn(notes.Press) -> message,
) -> Element(message) {
  let projection = presentation(state, note)
  let projected = projection.representation == notes.Structured
  html.div([attribute.class("notes-reader")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("notes-back"),
        event.on_click(press(notes.Back)),
      ],
      [html.text("← All notes")],
    ),
    html.h4([attribute.class("notes-reader-key")], [html.text(note.key)]),
    metadata(note),
    case note.extent {
      notes_view.Complete -> element.none()
      notes_view.Excerpt ->
        html.p([attribute.class("notes-excerpt")], [
          html.text(
            "Excerpt only. This bounded snapshot does not contain the rest of the value.",
          ),
        ])
    },
    case projected {
      False -> element.none()
      True ->
        html.div(
          [
            attribute.class("notes-modes"),
            attribute.role("group"),
            attribute.aria_label("Note representation"),
          ],
          [
            mode_button(
              "Readable",
              state.mode,
              notes.Readable,
              press(notes.ShowReadable),
            ),
            mode_button(
              "Raw value",
              state.mode,
              notes.Raw,
              press(notes.ShowRaw),
            ),
          ],
        )
    },
    case state.mode, projected {
      notes.Readable, True ->
        html.div(
          [attribute.class("notes-readable markdown")],
          markdown_view.blocks(projection.readable),
        )
      notes.Raw, _ | notes.Readable, False ->
        html.pre([attribute.class("notes-raw")], [html.text(note.text)])
    },
  ])
}

fn mode_button(
  label: String,
  current: notes.Mode,
  requested: notes.Mode,
  message: message,
) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.aria_pressed(case current == requested {
        True -> "true"
        False -> "false"
      }),
      event.on_click(message),
    ],
    [html.text(label)],
  )
}

// Projection belongs to snapshot adoption; a missing fixture cache stays literal.
fn presentation(
  state: notes.State,
  note: notes_view.Note,
) -> notes.Presentation {
  dict.get(state.presentations, note.key)
  |> result.unwrap(notes.Presentation(
    string.slice(note.text, 0, 220),
    [],
    notes.Literal,
  ))
}
