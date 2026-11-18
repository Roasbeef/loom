//// The inbox's review pane: a finished session's changed files, each with its
//// hunks, the finds pinned at their lines, a verdict, a comment for each file
//// and one outbox whose Send carries all of it (the attention inbox,
//// `docs/design-notes/attention-inbox/README.md` section 2.1).
////
//// The pane draws what `web_view/review_pane` holds. The review is the
//// daemon's bounded reading of the worktree (`web_view/review_feed`), and every
//// cut is said plainly: how many files are not shown, how many hunks and lines
//// were left out of a file, how many lines were shortened. Diffs are drawn by
//// `view/diff`, the one drawer the Changes tab uses, so a removed line is red,
//// an added line green and a hunk header sits in a quiet band. A find is drawn
//// at the line it names when a shown hunk holds that line, and otherwise at the
//// top of its file or of the pane (`web_view/review_pin_rule`).
////
//// Everything in a review is text a session or a repository wrote: paths, hunk
//// headers, lines, find text. Each is a text node and nowhere else. No
//// attribute, class, placeholder, label or key carries any of it. A control is
//// named by a fixed word (`comment`, `note`, `closure`), a form is keyed by the
//// open count and its position in the review and never by a path, and the
//// handlers close over the path and the find's identifier on the server, which
//// the browser never names. The classes are complete literals.
////
//// A page that may act is handed `Acting`, the messages its controls send. A
//// page that may only read, a member's, is handed none, and the pane draws the
//// files, hunks and finds with no verdict, no form, no outbox and no Send. An
//// observer's page is handed no review at all, so it never reaches this module
//// (`web_view/home`).
////
//// ## Flow
////
//// `pane` → `body` → `file` → `hunk` / `find_card` → `outbox`
////
//// 1. `pane` says why there is no review yet, or draws `body`.
//// 2. `body` draws the stat, the finds placed at no file, the verdict and the
////    files, then the outbox.
//// 3. `file` is one `<details>`: its finds, its hunks and its comment form.
//// 4. `hunk` draws one hunk's lines and the finds anchored under them.
//// 5. `outbox` lists what is staged and the Send that delivers it.

import core/attention.{type Closure}
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/diff_view
import web_view/attention_feed
import web_view/review_feed.{type File, type Hunk, type Review}
import web_view/review_outbox_rule
import web_view/review_pane.{type State}
import web_view/review_pin_rule
import web_view/review_stage_rule.{type Verdict}
import web_view/view/diff

/// The messages a page that may act sends from the pane.
pub type Acting(message) {
  Acting(
    /// A verdict was chosen.
    verdict: fn(Verdict) -> message,
    /// A file's comment form was submitted: the file's path, which the server
    /// drew into the handler, and the text.
    comment: fn(String, String) -> message,
    /// A find's form was submitted: its identifier, the way it is closed and the
    /// owner's note.
    find: fn(String, Closure, String) -> message,
    /// Take back everything staged.
    unstage: message,
    /// Send what is staged.
    send: message,
  )
}

/// What the pane draws from.
pub type Offer(message) {
  Offer(
    /// The open review's state.
    state: State,
    /// The session's open finds, as the attention feed read them.
    finds: List(attention_feed.Find),
    /// How many reviews have been opened, which keys the forms so each open
    /// starts empty.
    presses: Int,
    /// The messages of the controls, or nothing for a page that may only read.
    acting: Option(Acting(message)),
  )
}

/// The review pane for the open session.
///
/// ## Examples
///
/// ```gleam
/// // review_thread.pane(review_thread.Offer(state:, finds: [], presses: 1, acting: None))
/// ```
pub fn pane(offer: Offer(message)) -> Element(message) {
  html.section([attribute.class("inbox-section review")], [
    html.h4([attribute.class("inbox-label")], [html.text("Changes to review")]),
    case offer.state.loaded {
      review_pane.Reading ->
        html.p([attribute.class("inbox-hold")], [
          html.text("Reading the worktree…"),
        ])
      review_pane.Unavailable(words:) ->
        html.p([attribute.class("inbox-hold"), attribute.role("status")], [
          html.text(words),
        ])
      review_pane.Read(review:) -> body(review, offer)
    },
  ])
}

/// The stat, the finds that name no shown file, the verdict, the files and the
/// outbox.
fn body(review: Review, offer: Offer(message)) -> Element(message) {
  let pins =
    list.map(offer.finds, fn(find) {
      review_pin_rule.Pin(id: find.id, path: find.path, line: find.line)
    })
  let placed = review_pin_rule.place(review.files, pins)

  html.div([attribute.class("review-body")], [
    stat(review),
    case placed.unplaced {
      [] -> element.none()
      ids ->
        html.div(
          [attribute.class("review-finds")],
          list.filter_map(ids, fn(id) { find_of(id, offer) }),
        )
    },
    verdict_control(offer),
    case review.files {
      [] -> element.none()
      files ->
        keyed.ul(
          [attribute.class("review-files")],
          list.index_map(list.zip(files, placed.files), fn(entry, index) {
            let #(each, file_pins) = entry
            let key = key_of(offer, "file", index)

            #(key, html.li([], [file(each, file_pins, index, offer)]))
          }),
        )
    },
    outbox(offer),
  ])
}

/// The count line and every statement of what was not shown.
fn stat(review: Review) -> Element(message) {
  html.div([attribute.class("review-stat")], [
    html.p([], [
      html.text(
        int.to_string(review.stat.files)
        <> plural(review.stat.files, " file", " files")
        <> " · +"
        <> int.to_string(review.stat.added)
        <> " −"
        <> int.to_string(review.stat.removed),
      ),
    ]),
    case review.repository {
      review_feed.Unborn ->
        notice("The repository has no commit yet, so every file is new.")
      review_feed.Head | review_feed.NotRepository -> element.none()
    },
    case review.omitted {
      0 -> element.none()
      left ->
        notice(
          int.to_string(left) <> plural(left, " file", " files") <> " not shown",
        )
    },
    case review.extent {
      review_feed.Cut ->
        notice(
          "Part of this diff was cut to fit, so its counts are lower bounds. Committed work is not shown.",
        )
      review_feed.Whole ->
        notice("Committed work is not shown, only the files changed now.")
    },
  ])
}

/// One file: a summary line, then its finds, hunks and comment form.
fn file(
  each: File,
  pins: review_pin_rule.FilePins,
  index: Int,
  offer: Offer(message),
) -> Element(message) {
  html.details([attribute.class("review-file")], [
    html.summary([attribute.class("review-file-head")], [
      html.span([attribute.class("review-path")], [html.text(each.path)]),
      html.span([attribute.class("review-change")], [
        html.text(change_words(each) <> counts(each)),
      ]),
      staged_mark(each.path, pins, offer),
    ]),
    case review_pin_rule.loose(pins) {
      [] -> element.none()
      ids ->
        html.div(
          [attribute.class("review-finds")],
          list.filter_map(ids, fn(id) { find_of(id, offer) }),
        )
    },
    content(each, pins, offer),
    comment_form(each.path, index, offer),
  ])
}

/// The file's body by what the observation could say of it.
fn content(
  each: File,
  pins: review_pin_rule.FilePins,
  offer: Offer(message),
) -> Element(message) {
  case each.content {
    review_feed.Binary -> notice("Binary file: named, with no hunks.")
    review_feed.NoNetChange -> notice("Touched, and its content is the same.")
    review_feed.MetadataOnly ->
      notice("Its mode or other metadata changed, with no text to show.")
    review_feed.Text ->
      html.div(
        [attribute.class("review-hunks")],
        list.append(
          list.index_map(each.hunks, fn(each_hunk, number) {
            hunk(each_hunk, number, pins, offer)
          }),
          [
            case each.hunks_omitted {
              0 -> element.none()
              left ->
                notice(
                  int.to_string(left)
                  <> plural(left, " more hunk", " more hunks")
                  <> " not shown",
                )
            },
            case each.extent {
              review_feed.Cut ->
                notice(
                  "This file's patch was cut, so its counts are lower bounds.",
                )
              review_feed.Whole -> element.none()
            },
          ],
        ),
      )
  }
}

/// One hunk: its header and lines in the shared diff drawer, a find under each
/// line it is anchored to, and what was left out of it.
fn hunk(
  each: Hunk,
  number: Int,
  pins: review_pin_rule.FilePins,
  offer: Offer(message),
) -> Element(message) {
  let header =
    diff_view.Line(
      kind: diff_view.Hunk,
      old: None,
      new: None,
      text: each.header,
    )

  html.div([attribute.class("review-hunk")], [
    diff.view_with([header, ..each.lines], each.omitted, fn(index, _line) {
      // The header is not one of the hunk's lines, so the lines count from one.
      review_pin_rule.at_line(pins, number, index - 1)
      |> list.filter_map(fn(id) { find_of(id, offer) })
    }),
    case each.shortened {
      0 -> element.none()
      cut ->
        notice(
          int.to_string(cut)
          <> plural(cut, " line", " lines")
          <> " shortened to "
          <> int.to_string(review_feed.max_line_bytes)
          <> " bytes",
        )
    },
  ])
}

/// One find, drawn where it is placed: its kind, its text as untrusted, its
/// place, and, for a page that may act, the form that stages how to close it.
fn find_of(id: String, offer: Offer(message)) -> Result(Element(message), Nil) {
  list.find(offer.finds, fn(find) { find.id == id })
  |> result.map(fn(find) { find_card(find, offer) })
}

/// A find's card.
fn find_card(
  find: attention_feed.Find,
  offer: Offer(message),
) -> Element(message) {
  html.div([attribute.class("review-find")], [
    html.p([attribute.class("inbox-label")], [
      html.text(
        "The agent noticed ("
        <> attention.find_kind_name(find.kind)
        <> "), untrusted text",
      ),
    ]),
    html.p([attribute.class("inbox-message")], [html.text(find.head)]),
    case find.path {
      Some(path) ->
        html.p([attribute.class("inbox-place")], [
          html.text(case find.line {
            Some(line) -> path <> ":" <> int.to_string(line)
            None -> path
          }),
        ])
      None -> element.none()
    },
    find_action(find, offer),
  ])
}

/// What a find offers: the staged action, or the form that stages one, or the
/// words for why there is none.
fn find_action(
  find: attention_feed.Find,
  offer: Offer(message),
) -> Element(message) {
  // A page that may not act draws no form for the find.
  case offer.acting {
    None -> element.none()
    Some(acting) -> {
      let staged =
        list.find(offer.state.staging.finds, fn(action) { action.id == find.id })

      html.div([attribute.class("review-find-action")], [
        case staged {
          Ok(action) ->
            html.p([attribute.class("inbox-mark")], [
              html.text(
                "Staged: close as "
                <> review_outbox_rule.closure_words(action.closure)
                <> case action.standing {
                  review_stage_rule.Applied -> " (applied)"
                  review_stage_rule.Pending -> ""
                },
              ),
            ])
          Error(Nil) -> element.none()
        },
        case dict_get(offer.state, find.id) {
          Some(review_pane.Revision(_)) -> find_form(find.id, acting, offer)
          Some(review_pane.Unread(words:)) ->
            html.p([attribute.class("inbox-hold")], [html.text(words)])
          Some(review_pane.Asking) | None ->
            html.p([attribute.class("inbox-hold")], [
              html.text("Reading the find…"),
            ])
        },
      ])
    }
  }
}

/// The form that stages a find's close: a note and the three ways to close. The
/// button pressed travels with the form as `closure`, which names a fixed word.
fn find_form(
  id: String,
  acting: Acting(message),
  offer: Offer(message),
) -> Element(message) {
  keyed.div([attribute.class("review-form")], [
    #(
      key_of(offer, "find", 0) <> "-" <> id,
      html.form(
        [
          attribute.class("place-composer inbox-form"),
          event.on("submit", find_submitted(id, acting.find))
            |> event.prevent_default,
        ],
        [
          html.textarea(
            [
              attribute.name("note"),
              attribute.class("composer-name"),
              attribute.aria_label("A note for the agent about this find"),
              attribute.placeholder("A note for the agent (optional)"),
              attribute.attribute("rows", "2"),
              attribute.attribute(
                "maxlength",
                int.to_string(review_stage_rule.note_limit),
              ),
            ],
            "",
          ),
          html.div([attribute.class("cbar")], [
            closure_button("Close as Fixed", "fixed"),
            closure_button("Filed", "filed"),
            closure_button("Dismiss", "dismissed"),
          ]),
        ],
      ),
    ),
  ])
}

/// One of the three ways to close, as a submit button that names its way.
fn closure_button(label: String, word: String) -> Element(message) {
  html.button(
    [
      attribute.type_("submit"),
      attribute.name("closure"),
      attribute.value(word),
      attribute.class("place-send"),
    ],
    [html.text(label)],
  )
}

/// The verdict control: three buttons, one pressed when it is staged. A page
/// that may not act has none.
fn verdict_control(offer: Offer(message)) -> Element(message) {
  case offer.acting {
    None -> element.none()
    Some(acting) ->
      html.div(
        [attribute.class("review-verdict cbar"), attribute.role("group")],
        [
          verdict_button("Approve", review_stage_rule.Approve, acting, offer),
          verdict_button(
            "Request changes",
            review_stage_rule.RequestChanges,
            acting,
            offer,
          ),
          verdict_button("Comment", review_stage_rule.Comment, acting, offer),
        ],
      )
  }
}

/// One verdict button, marked pressed when its verdict is the staged one.
fn verdict_button(
  label: String,
  verdict: Verdict,
  acting: Acting(message),
  offer: Offer(message),
) -> Element(message) {
  let pressed = offer.state.staging.verdict == Some(verdict)

  html.button(
    [
      attribute.type_("button"),
      attribute.class("place-send"),
      attribute.attribute("aria-pressed", case pressed {
        True -> "true"
        False -> "false"
      }),
      event.on_click(acting.verdict(verdict)),
    ],
    [html.text(label)],
  )
}

/// A file's comment form: one box and a button that stages it. The form is
/// keyed by the open count and the file's position, so a reopened review starts
/// empty.
fn comment_form(
  path: String,
  index: Int,
  offer: Offer(message),
) -> Element(message) {
  case offer.acting {
    None -> element.none()
    Some(acting) ->
      keyed.div([attribute.class("review-form")], [
        #(
          key_of(offer, "comment", index),
          html.form(
            [
              attribute.class("place-composer inbox-form"),
              event.on("submit", comment_submitted(path, acting.comment))
                |> event.prevent_default,
            ],
            [
              html.textarea(
                [
                  attribute.name("comment"),
                  attribute.class("composer-name"),
                  attribute.aria_label("Comment on this file"),
                  attribute.placeholder("Comment on this file"),
                  attribute.attribute("rows", "2"),
                  attribute.attribute(
                    "maxlength",
                    int.to_string(review_stage_rule.note_limit),
                  ),
                ],
                "",
              ),
              html.div([attribute.class("cbar")], [
                html.button(
                  [attribute.type_("submit"), attribute.class("place-send")],
                  [html.text("Stage the comment")],
                ),
              ]),
            ],
          ),
        ),
      ])
  }
}

/// The mark on a file's summary line when a comment is staged for it.
fn staged_mark(
  path: String,
  pins: review_pin_rule.FilePins,
  offer: Offer(message),
) -> Element(message) {
  let commented =
    list.any(offer.state.staging.comments, fn(each) { each.path == path })
  let finds = list.length(pins.anchored) + list.length(pins.loose)

  html.span([attribute.class("review-marks")], [
    html.text(
      case finds {
        0 -> ""
        many -> int.to_string(many) <> plural(many, " find", " finds")
      }
      <> case commented, finds {
        True, 0 -> "comment staged"
        True, _ -> " · comment staged"
        False, _ -> ""
      },
    ),
  ])
}

/// The outbox: what is staged, why a stage was refused, what the last Send did
/// and the buttons. A page that may not act draws a line that says so.
fn outbox(offer: Offer(message)) -> Element(message) {
  // A page that may not act draws a line that says so, and no outbox.
  case offer.acting {
    None ->
      html.p([attribute.class("inbox-hold")], [
        html.text("Only the owner's operating page can send a review."),
      ])
    Some(acting) -> {
      let state = offer.state

      // A Send that is out disables the buttons.
      let sending = case state.progress {
        review_pane.Sending(_) -> True
        review_pane.Resting | review_pane.Settled(_) -> False
      }

      html.section([attribute.class("inbox-section inbox-outbox-list")], [
        html.h4([attribute.class("inbox-label")], [html.text("Outbox")]),
        case review_pane.has_staged(state) {
          False ->
            html.p([attribute.class("inbox-hold")], [
              html.text(
                "Nothing is staged. Nothing is sent until you press Send.",
              ),
            ])
          True -> html.ul([], staged_lines(state))
        },
        case state.problem {
          Some(words) ->
            html.p(
              [attribute.class("inbox-standing"), attribute.role("alert")],
              [
                html.text(words),
              ],
            )
          None -> element.none()
        },
        receipt(state),
        html.div([attribute.class("cbar")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("place-send"),
              attribute.disabled(!review_pane.has_staged(state) || sending),
              event.on_click(acting.send),
            ],
            [html.text("Send")],
          ),
          html.button(
            [
              attribute.type_("button"),
              attribute.class("inbox-open"),
              attribute.disabled(!review_pane.has_staged(state) || sending),
              event.on_click(acting.unstage),
            ],
            [html.text("Clear")],
          ),
        ]),
      ])
    }
  }
}

/// The staged items as the lines the outbox lists.
fn staged_lines(state: State) -> List(Element(message)) {
  let staging = state.staging

  list.flatten([
    case staging.verdict {
      Some(verdict) -> [
        html.li([], [
          html.text("Verdict: " <> review_outbox_rule.verdict_words(verdict)),
        ]),
      ]
      None -> []
    },
    list.map(staging.comments, fn(each) {
      html.li([], [html.text("Comment on " <> each.path <> ": " <> each.text)])
    }),
    list.map(staging.finds, fn(action) {
      html.li([], [
        html.text(
          "Close "
          <> action.id
          <> " as "
          <> review_outbox_rule.closure_words(action.closure)
          <> case action.note {
            Some(note) -> ": " <> note
            None -> ""
          }
          <> case action.standing {
            review_stage_rule.Applied -> " (applied)"
            review_stage_rule.Pending -> ""
          },
        ),
      ])
    }),
  ])
}

/// What the Send did, in the daemon's fixed words: each close and the prompt.
fn receipt(state: State) -> Element(message) {
  case state.progress {
    review_pane.Resting -> element.none()
    review_pane.Sending(_) ->
      html.p([attribute.class("inbox-outbox"), attribute.role("status")], [
        html.text("Sending…"),
      ])
    review_pane.Settled(receipt:) ->
      html.ul(
        [attribute.class("inbox-outbox"), attribute.role("status")],
        list.map(review_pane.receipt_lines(receipt), fn(line) {
          html.li([], [html.text(line)])
        }),
      )
  }
}

/// A find form's submit: exactly a `note` and a `closure` that is one of the
/// three words the buttons carry. Any other shape is not the form that was
/// drawn and refuses the event.
fn find_submitted(
  id: String,
  stage: fn(String, Closure, String) -> message,
) -> decode.Decoder(message) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // Only the form that was drawn is read back.
  case closing(fields) {
    Ok(#(note, closure)) -> decode.success(stage(id, closure, note))
    Error(Nil) ->
      decode.failure(stage(id, attention.Fixed, ""), "review find form")
  }
}

/// The note and the way a find form's fields stand for, or a refusal.
///
/// ## Examples
///
/// ```gleam
/// assert review_thread.closing([#("note", "ok"), #("closure", "filed")])
///   == Ok(#("ok", attention.Filed))
/// ```
pub fn closing(
  fields: List(#(String, String)),
) -> Result(#(String, Closure), Nil) {
  case fields {
    [#("note", note), #("closure", "fixed")] -> Ok(#(note, attention.Fixed))
    [#("note", note), #("closure", "filed")] -> Ok(#(note, attention.Filed))
    [#("note", note), #("closure", "dismissed")] ->
      Ok(#(note, attention.Dismissed))
    _ -> Error(Nil)
  }
}

/// A comment form's submit: exactly one `comment` field and nothing else.
fn comment_submitted(
  path: String,
  stage: fn(String, String) -> message,
) -> decode.Decoder(message) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // Only the form that was drawn is read back.
  case fields {
    [#("comment", text)] -> decode.success(stage(path, text))
    _ -> decode.failure(stage(path, ""), "review comment form")
  }
}

/// One field of a submitted form: its name and its value.
fn form_field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

/// A quiet line that says what the page did not show.
fn notice(words: String) -> Element(message) {
  html.p([attribute.class("review-notice")], [html.text(words)])
}

/// The words for what happened to a file.
fn change_words(each: File) -> String {
  case each.change {
    review_feed.Added -> "added"
    review_feed.Modified -> "modified"
    review_feed.Deleted -> "deleted"
  }
}

/// The file's line counts, as far as its patch was read.
fn counts(each: File) -> String {
  " · +" <> int.to_string(each.added) <> " −" <> int.to_string(each.removed)
}

/// The singular for one and the plural for any other count.
fn plural(count: Int, one: String, many: String) -> String {
  case count {
    1 -> one
    _ -> many
  }
}

/// A key for a form: the open count, which control, and its position, so a
/// reopened review draws forms that start empty and a path is never a key.
fn key_of(offer: Offer(message), control: String, index: Int) -> String {
  "review-"
  <> option.unwrap(offer.state.session, "")
  <> "-"
  <> int.to_string(offer.presses)
  <> "-"
  <> control
  <> "-"
  <> int.to_string(index)
}

/// The revision the page holds for a find, if it read one.
fn dict_get(state: State, id: String) -> Option(review_pane.Revision) {
  case dict.get(state.revisions, id) {
    Ok(revision) -> Some(revision)
    Error(Nil) -> None
  }
}
