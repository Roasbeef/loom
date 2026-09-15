//// The advisor's queued nudges, drawn beside the composer while the primary
//// is idle.
////
//// A queued nudge has not been delivered to anything. It waits in the
//// advisor's guard cell until the primary stops, and once the turn's one
//// unsolicited delivery is spent it waits for the operator's next prompt,
//// so it is not on any branch and no transcript row describes it.
//// That is why this panel exists and why it is deliberately *not* a
//// transcript row: drawing undelivered advice where delivered messages go
//// would tell the operator the model had already read it.
////
//// It is also why the terminal pulls rather than being pushed. The queue is
//// interesting at exactly one moment — the primary idle, with advice written
//// and nothing yet started to consume it — and that moment is a transition
//// the terminal already observes. A pushed feed would have to say something
//// on every verdict, including the ones that were delivered instead of
//// queued; a pull on the idle edge says something only when there is
//// something waiting.
////
//// The read behind this board never drains the queue. The drain belongs to
//// the primary's run start, and a panel that consumed what it displayed
//// would show the operator advice the model would then never see.

import core/json
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import tui/text_hygiene

/// The strand the advisor advises, and whose next prompt drains the
/// queue this panel shows.
///
/// A copy of `client/advisor.primary`, not an import: the terminal links no
/// server package (`docs/architecture/advisor.md`). The gateway's own tests
/// pin this pair against the server's constants, so a rename on either side
/// fails a test rather than quietly disarming the panel's triggers.
pub const primary_strand = "main"

/// The advisor's own strand, copied for the reason `primary_strand` is. The
/// terminal watches it because a review ending is when a nudge is queued.
pub const advisor_strand = "advisor"

/// How many queued nudges the panel prints before it counts the rest.
///
/// The band sits above the composer, so its height is taken from the
/// conversation. Three rows is the same allowance the reviewer roster makes,
/// and the count line keeps the panel honest about what it left out.
pub const visible_nudges = 3

/// One observation of the nudges waiting to reach the primary.
pub type Board {
  Board(
    /// The strand the queue drains into — the primary the advisor advises,
    /// named by the server rather than chosen by this terminal.
    strand: String,
    /// The server's clock when the queue was observed. Never subtracted from
    /// a terminal clock.
    observed_at_ms: Int,
    /// The queued texts, oldest first, exactly as the advisor wrote them.
    /// Untrusted display data, sanitized on the way to the screen.
    pending: List(String),
    /// How many nudges were waiting, before any row this board omitted.
    total: Int,
  )
}

/// Validates one pending-nudge observation without trusting the server's
/// bounds.
///
/// Every refusal is an `Error`; nothing here can crash a terminal on a
/// malformed board. The row and byte caps are this terminal's own: the
/// server's queue is much smaller today, and a board that outgrew it is a
/// disagreement to refuse rather than a screenful to paint.
///
/// ## Examples
///
/// ```gleam
/// // advisor_pending.decode(board)
/// ```
pub fn decode(value: json.JsonValue) -> Result(Board, String) {
  use <- bool.guard(
    string.byte_size(json.to_string(value)) > 48_000,
    Error("oversized advisor nudge observation"),
  )
  use fields <- result.try(object(value))
  use strand <- result.try(text(fields, "strand"))
  use observed <- result.try(number(fields, "observed_at_ms"))
  use total <- result.try(number(fields, "total"))
  use raw <- result.try(case list.key_find(fields, "pending") {
    Ok(json.Array(rows)) -> Ok(rows)
    _ -> Error("missing advisor nudges")
  })
  use <- bool.guard(list.drop(raw, 64) != [], Error("too many advisor nudges"))
  use pending <- result.try(list.try_map(raw, nudge))

  // `total` counts the queue, so it can exceed the rows a future server
  // omits but can never fall below the rows this one sent. Dropping `total`
  // rows answers that without walking the rest of the list.
  use <- bool.guard(
    strand == "" || total < 0 || list.drop(pending, total) != [],
    Error("inconsistent advisor nudge observation"),
  )

  Ok(Board(strand:, observed_at_ms: observed, pending:, total:))
}

fn nudge(value: json.JsonValue) -> Result(String, String) {
  case value {
    json.String(text) ->
      case string.byte_size(text) > 4096 {
        True -> Error("oversized advisor nudge")
        False -> Ok(text)
      }

    json.Object(..)
    | json.Array(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("an advisor nudge must be text")
  }
}

/// Renders the panel in the advisor's voice, or nothing at all.
///
/// An empty queue draws no rows: the band is taken from the conversation, and
/// "the advisor has nothing to say" is not worth a line. The heading carries
/// the count because the bullets are the whole of the content, which is the
/// same reason the transcript's nudge row counts its bullets.
///
/// ## Examples
///
/// ```gleam
/// assert advisor_pending.lines(advisor_pending.Board("main", 1, [], 0)) == []
/// ```
pub fn lines(board: Board) -> List(String) {
  use <- bool.guard(board.pending == [], [])
  let shown = list.take(board.pending, visible_nudges)
  let rows =
    list.map(shown, fn(text) { "  - " <> text_hygiene.single_line(text) })
  let heading =
    "advisor nudges pending ("
    <> int.to_string(board.total)
    <> ") · held for your next prompt to "
    <> text_hygiene.single_line(board.strand)

  case board.total - list.length(shown) {
    0 -> [heading, ..rows]
    more ->
      list.append([heading, ..rows], [
        "  +" <> int.to_string(more) <> " more waiting",
      ])
  }
}

fn object(
  value: json.JsonValue,
) -> Result(List(#(String, json.JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected advisor nudge object")
  }
}

fn text(fields, name) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error("missing advisor nudge text: " <> name)
  }
}

fn number(fields, name) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Ok(value)
    _ -> Error("invalid advisor nudge number: " <> name)
  }
}
