//// The composer's decisions as functions of plain values: the table it
//// decodes, which rows a draft lists, what a key does, how the highlight
//// moves and is kept in view, and how a returned prompt is claimed once and
//// joined to a draft.
////
//// `web_client/composer` is the element: it reads the page, sends these
//// functions what it read, and does what they say. This module imports neither
//// Lustre nor the DOM binding, so its tests run without a page and without
//// the browser's runtime (`docs/lustre.md`).

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// What choosing a row leaves the operator to do.
pub type Then {
  /// The command is whole: nothing more is typed for it.
  Complete

  /// The command takes an argument, so a space follows it in the editor.
  Continues
}

/// One row of the list.
pub type Entry {
  Entry(
    /// The slash-prefixed text written into the editor.
    command: String,
    /// What the command does, in a few words.
    hint: String,
    /// Whether an argument follows it.
    then: Then,
  )
}

/// Whether the list is offered for the draft as it stands.
pub type Palette {
  /// The list is offered when the draft has matches.
  Listing

  /// The operator closed it, or took a row that needs nothing more, and it
  /// stays closed until the next thing typed.
  Closed
}

/// What the element knows of the prompts the daemon has handed back, which
/// the server numbers from one in the order they came.
pub type Returns {
  /// The server has not yet said how many there are.
  Unseen

  /// The server has said. Every return numbered up to `taken` is the
  /// business of an editor before this one, or has been put in this one: the
  /// first count this element heard, and after it the highest count it has
  /// acted on.
  Seen(taken: Int)
}

/// What a count from the server asks of the editor.
pub type Taking {
  /// No return is new.
  Nothing

  /// The returns numbered above `after` and up to `up_to` are new, and each
  /// is to be put in the editor once.
  Take(after: Int, up_to: Int)
}

/// Which way an arrow key moves the highlight.
pub type Direction {
  Up
  Down
}

/// The table a `commands` attribute holds, or no table when the attribute is
/// not one: the element then offers no list, and the editor works as it did.
///
/// ## Examples
///
/// ```gleam
/// assert composer_rule.entries("[{\"c\":\"/compact\",\"d\":\"shrink\",\"a\":false}]")
///   == [composer_rule.Entry("/compact", "shrink", composer_rule.Complete)]
/// assert composer_rule.entries("not json") == []
/// ```
pub fn entries(attribute: String) -> List(Entry) {
  json.parse(attribute, decode.list(entry()))
  |> result.unwrap([])
}

fn entry() -> decode.Decoder(Entry) {
  use command <- decode.field("c", decode.string)
  use hint <- decode.field("d", decode.string)
  use takes_argument <- decode.field("a", decode.bool)
  let then = case takes_argument {
    True -> Continues
    False -> Complete
  }
  decode.success(Entry(command:, hint:, then:))
}

/// The rows to offer for `draft`, in the table's order.
///
/// A draft that begins, past leading space, with a command that has a closed
/// argument vocabulary and a space (`/effort `) lists that command's rows
/// that start with what follows the space. Any other draft lists the
/// one-word commands it is a prefix of, when it is one word starting with
/// `/`; the draft's trailing space does not count, as in the terminal.
/// A row with a space in it is an argument row, and its head is the text
/// before the space.
///
/// ## Examples
///
/// ```gleam
/// // composer_rule.matching(table, "/co")  lists /compact and /context
/// // composer_rule.matching(table, "/effort lo")  lists /effort low
/// // composer_rule.matching(table, "hello")  lists nothing
/// ```
pub fn matching(entries: List(Entry), draft: String) -> List(Entry) {
  let lead = string.trim_start(draft)
  case list.find(heads(entries), fn(head) { string.starts_with(lead, head) }) {
    Ok(head) -> {
      let partial = string.trim(string.drop_start(lead, string.length(head)))
      list.filter(entries, fn(row) {
        string.starts_with(row.command, head <> partial)
      })
    }
    Error(Nil) -> {
      let word = string.trim(lead)
      case string.starts_with(word, "/"), string.contains(word, " ") {
        True, False ->
          list.filter(entries, fn(row) {
            !string.contains(row.command, " ")
            && string.starts_with(row.command, word)
          })
        _, _ -> []
      }
    }
  }
}

// The words that take a closed vocabulary, each with the space that follows
// it: the text before the first space of every argument row.
fn heads(entries: List(Entry)) -> List(String) {
  list.filter_map(entries, fn(row) {
    case string.split_once(row.command, " ") {
      Ok(#(head, _)) -> Ok(head <> " ")
      Error(Nil) -> Error(Nil)
    }
  })
  |> list.unique
}

/// What a count of returned prompts, as the server states it, changes. The
/// first count heard is the baseline and asks for nothing; a count above
/// everything acted on so far asks for the prompts between the two; any other
/// count, including one that falls, asks for nothing and leaves what was
/// acted on as it was.
///
/// ## Examples
///
/// ```gleam
/// assert composer_rule.hear(composer_rule.Unseen, 2)
///   == #(composer_rule.Seen(2), composer_rule.Nothing)
/// assert composer_rule.hear(composer_rule.Seen(2), 3)
///   == #(composer_rule.Seen(3), composer_rule.Take(after: 2, up_to: 3))
/// assert composer_rule.hear(composer_rule.Seen(3), 1)
///   == #(composer_rule.Seen(3), composer_rule.Nothing)
/// ```
pub fn hear(returns: Returns, count: Int) -> #(Returns, Taking) {
  case returns {
    Unseen -> #(Seen(taken: count), Nothing)
    Seen(taken:) if count > taken -> #(
      Seen(taken: count),
      Take(after: taken, up_to: count),
    )
    Seen(taken:) -> #(Seen(taken:), Nothing)
  }
}

/// The text of the returned prompts a `Take` asks for, oldest first, given
/// every numbered prompt the page holds. A prompt outside the range, and one
/// whose number is not above `after`, is left where it is.
///
/// ## Examples
///
/// ```gleam
/// assert composer_rule.taken([#(3, "c"), #(1, "a"), #(2, "b")], 1, 3)
///   == ["b", "c"]
/// ```
pub fn taken(
  held: List(#(Int, String)),
  after: Int,
  up_to: Int,
) -> List(String) {
  held
  |> list.filter(fn(prompt) { prompt.0 > after && prompt.0 <= up_to })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.map(fn(prompt) { prompt.1 })
}

/// The editor's draft after a returned prompt is put in it. An editor with
/// nothing in it takes the prompt as its draft. One the operator has typed in
/// keeps that and takes the prompt below it after a blank line, as the
/// terminal does: both are theirs, and neither may be lost.
///
/// ## Examples
///
/// ```gleam
/// assert composer_rule.joined("  ", "again") == "again"
/// assert composer_rule.joined("draft", "again") == "draft\n\nagain"
/// ```
pub fn joined(draft: String, returned: String) -> String {
  case string.trim(draft) {
    "" -> returned
    _ -> draft <> "\n\n" <> returned
  }
}

/// Where to scroll the completion list, in pixels from its top, so the row
/// that starts `row_top` from the list's top edge and is `row_height` tall
/// is inside a view `viewport` tall, given the list is scrolled `scrolled`
/// now. A row already inside leaves the list where it is; one above is
/// brought to the top edge and one below to the bottom edge.
///
/// ## Examples
///
/// ```gleam
/// assert composer_rule.revealed(30.0, 20.0, 0.0, 100.0) == 0.0
/// assert composer_rule.revealed(10.0, 20.0, 40.0, 100.0) == 10.0
/// assert composer_rule.revealed(160.0, 20.0, 40.0, 100.0) == 80.0
/// ```
pub fn revealed(
  row_top: Float,
  row_height: Float,
  scrolled: Float,
  viewport: Float,
) -> Float {
  let bottom = row_top +. row_height
  case row_top <. scrolled, bottom >. scrolled +. viewport {
    True, _ -> row_top
    False, True -> bottom -. viewport
    False, False -> scrolled
  }
}

/// The highlighted row after an arrow key: it wraps at either end, and an
/// empty list holds it at the top.
///
/// ## Examples
///
/// ```gleam
/// assert composer_rule.moved(0, 3, composer_rule.Up) == 2
/// assert composer_rule.moved(2, 3, composer_rule.Down) == 0
/// ```
pub fn moved(selected: Int, count: Int, direction: Direction) -> Int {
  case count <= 0, direction {
    True, _ -> 0
    False, Down if selected >= count - 1 -> 0
    False, Down -> selected + 1
    False, Up if selected <= 0 -> count - 1
    False, Up -> selected - 1
  }
}

/// The modifiers held with a key, reduced to what the element reacts to.
pub type Chord {
  /// No modifier.
  Bare

  /// Command or Control, without Alt: the chord that sends.
  Sending

  /// Shift or Alt, or some other combination, which are the browser's.
  Other
}

/// Where a key stands in the browser's own handling of it.
pub type Phase {
  /// A fresh press.
  Fresh

  /// A key held down, repeating.
  Repeating

  /// A key pressed while an input method composes text, which is the input
  /// method's.
  Composing
}

/// What the element is to do for a key.
pub type Action {
  /// Send the draft.
  Send

  /// Do nothing: a chord held down after it already sent.
  Hold

  /// Move the highlight.
  Move(direction: Direction)

  /// Take the highlighted row.
  Accept

  /// Close the list.
  Dismiss
}

/// What a key does in the editor.
pub type Response {
  /// The element takes the key: it does this, and the browser's own action
  /// for the key is cancelled.
  Consumed(action: Action)

  /// The element notes the key and the browser acts on it as well.
  Observed(action: Action)
}

/// What the element does with a key, or `None` when the key is the browser's.
///
/// Command or Control with Enter sends the draft, and a held chord sends
/// once. With the list showing, Tab and Enter take a row, the arrows move and
/// Escape closes. Every other key, including Enter, is the browser's.
///
/// ## Examples
///
/// ```gleam
/// assert composer_rule.intent("Enter", composer_rule.Sending, composer_rule.Fresh, composer_rule.Closed)
///   == Some(composer_rule.Consumed(composer_rule.Send))
/// assert composer_rule.intent("Enter", composer_rule.Bare, composer_rule.Fresh, composer_rule.Closed)
///   == None
/// ```
pub fn intent(
  key: String,
  chord: Chord,
  phase: Phase,
  palette: Palette,
) -> Option(Response) {
  case phase, chord, key, palette {
    Composing, _, _, _ -> None

    // Cancelling the default matters: in a textarea, Control with Enter
    // inserts a newline in some browsers.
    Fresh, Sending, "Enter", _ -> Some(Consumed(Send))
    Repeating, Sending, "Enter", _ -> Some(Consumed(Hold))

    // These apply only while the list is showing. With it closed, Enter is a
    // newline and Tab moves focus on, as they are anywhere else.
    _, Bare, "ArrowDown", Listing -> Some(Consumed(Move(Down)))
    _, Bare, "ArrowUp", Listing -> Some(Consumed(Move(Up)))
    Fresh, Bare, "Tab", Listing | Fresh, Bare, "Enter", Listing ->
      Some(Consumed(Accept))
    _, Bare, "Escape", Listing -> Some(Observed(Dismiss))
    _, _, _, _ -> None
  }
}
