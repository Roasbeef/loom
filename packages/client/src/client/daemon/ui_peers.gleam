//// An owner's page reading and changing peer links (protocol-change/077).
////
//// The page asks by value (`web_view/peer_links.Request`) and this module
//// runs the request with the same functions the control commands
//// `peers.inspect`, `peers.link` and `peers.unlink` run (`client/peers`), so
//// the page and `loomd peer` cannot disagree about what a link is. It decides
//// nothing about authority: `ui_socket.peer_links_for` has already checked
//// that the page is open and that its credential is still the daemon's
//// owner's before it calls `run`, and every call here names the page's own
//// session, which comes from the attachment and never from the request.
////
//// A request names strands and other sessions as text, so each is judged
//// before it reaches a command: a session must be a canonical identity and a
//// strand a short string without control characters. A refusal from the
//// commands is mapped to one of the page's fixed reasons, so no text a session
//// or the daemon wrote reaches a browser.
////
//// Nothing here starts a session. A link or an unlink needs both ends
//// resident, and a session that is saved is refused with `NotRunning`, which
//// tells the owner to open it. Reading is the exception for the other end of a
//// link: a row whose session is not running is still listed, with no wake
//// permission, because the owner may want to remove it.

import client/peer_mail
import client/peers
import core/ids
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import web_view/peer_links.{
  type Answer, type Board, type Edge, type Reason, type Request, type Row, Board,
  Declined,
}

/// The most links a single unlink removes: both directions of one pair. A
/// request naming more is truncated, not refused, since the page only ever
/// builds one or two.
const edge_limit = 2

/// The room a read's reply has in the control frame, which the daemon pages
/// inspection against.
const read_budget = 59_000

/// Runs one request for the page's session.
///
/// ## Examples
///
/// ```gleam
/// // ui_peers.run(directory, session_id, peer_links.Read("main"))
/// ```
pub fn run(
  directory: peers.Directory,
  session_id: String,
  request: Request,
) -> Answer {
  // This branch resolves request before the operation continues.
  case request {
    peer_links.Read(strand:) -> read(directory, session_id, strand)
    peer_links.Link(strand:, session:, target:, wake:, reverse:) ->
      link(directory, session_id, strand, session, target, wake, reverse)
    peer_links.Unlink(strand:, edges:) ->
      unlink(directory, session_id, strand, list.take(edges, edge_limit))
  }
}

/// Reads and constructs the link board for a strand from the directory inspection API.
fn read(
  directory: peers.Directory,
  session_id: String,
  strand: String,
) -> Answer {
  let outcome = {
    use own <- result.try(directory.resolve(session_id) |> peer_mail.plain)
    use metadata <- result.try(directory.describe(session_id))
    use inspected <- result.try(peers.inspect(
      peers.Wiring(own, metadata, Some(directory)),
      strand,
      None,
      read_budget,
    ))
    board_of(strand, inspected)
  }

  // Translate inspection outcome into a listed board or declined response.
  case outcome {
    Ok(board) -> peer_links.Listed(board)
    Error(reason) -> Declined(reason_of(reason))
  }
}

/// Establishes peer link relationships between two sessions in one or both directions.
fn link(
  directory: peers.Directory,
  session_id: String,
  strand: String,
  session: String,
  target: String,
  wake: peer_links.Wake,
  reverse: peer_links.Reverse,
) -> Answer {
  let outcome = {
    use Nil <- result.try(strand_ok(strand) |> result.replace_error("invalid"))
    use Nil <- result.try(
      strand_ok(target) |> result.replace_error("invalid strand"),
    )

    // Prevent linking a session to itself.
    use Nil <- result.try(case session == session_id {
      True -> Error("same session")
      False -> Ok(Nil)
    })

    use Nil <- result.try(
      ids.parse_session_id(session)
      |> result.replace(Nil)
      |> result.replace_error(peers.not_running),
    )
    use own <- result.try(
      directory.resolve(session_id) |> result.replace_error(peers.not_running),
    )
    use other <- result.try(
      directory.resolve(session) |> result.replace_error(peers.not_running),
    )

    // Map wake configuration to peer mail permission flag.
    let permission = case wake {
      peer_links.BusyOnly -> peer_mail.BusyOnly
      peer_links.MayWake -> peer_mail.MayWake
    }

    use _ <- result.try(peers.link(own, other, strand, target, permission))

    // This branch resolves reverse before the operation continues.
    Ok(case reverse {
      peer_links.OneWay -> peer_links.Complete
      peer_links.BothWays ->
        // This branch resolves peers link other own target strand permission before the operation continues.
        case peers.link(other, own, target, strand, permission) {
          Ok(_) -> peer_links.Complete
          Error(_) -> peer_links.Partial
        }
    })
  }

  // Wrap link outcome into a changed answer or declined failure.
  case outcome {
    Ok(done) -> peer_links.Changed(done)
    Error(reason) -> Declined(reason_of(reason))
  }
}

/// Unlinks multiple edges from a strand and summarizes execution outcomes.
fn unlink(
  directory: peers.Directory,
  session_id: String,
  strand: String,
  edges: List(Edge),
) -> Answer {
  let results =
    list.map(edges, fn(edge) {
      unlink_edge(directory, session_id, strand, edge)
    })
  let done = list.filter_map(results, fn(each) { each })
  let failures =
    list.filter_map(results, fn(each) {
      // This branch resolves each before the operation continues.
      case each {
        Ok(_) -> Error(Nil)
        Error(reason) -> Ok(reason)
      }
    })

  // Aggregate results to determine whether unlinking succeeded, partially succeeded, or failed.
  case done, failures {
    [], [reason, ..] -> Declined(reason_of(reason))
    [], [] -> Declined(peer_links.Unavailable)
    _, [] ->
      // This branch resolves list contains done peer_links Partial before the operation continues.
      case list.contains(done, peer_links.Partial) {
        True -> peer_links.Changed(peer_links.Partial)
        False -> peer_links.Changed(peer_links.Complete)
      }

    // One direction was removed and another was not: some of it took effect,
    // and repeating the request is safe.
    _, [_, ..] -> peer_links.Changed(peer_links.Partial)
  }
}

/// Removes a single incoming or outgoing peer link edge between sessions.
fn unlink_edge(
  directory: peers.Directory,
  session_id: String,
  strand: String,
  edge: Edge,
) -> Result(peer_links.Outcome, String) {
  use Nil <- result.try(
    strand_ok(edge.strand) |> result.replace_error("invalid strand"),
  )
  use Nil <- result.try(
    ids.parse_session_id(edge.session)
    |> result.replace(Nil)
    |> result.replace_error(peers.not_running),
  )
  use own <- result.try(
    directory.resolve(session_id) |> result.replace_error(peers.not_running),
  )

  // Dispatch unlink call depending on whether edge is Outgoing or Incoming.
  use answer <- result.map(case edge.direction {
    peer_links.Outgoing ->
      peers.unlink_session(directory, own, strand, edge.session, edge.strand)
    peer_links.Incoming -> {
      use sender <- result.try(
        directory.resolve(edge.session)
        |> result.replace_error(peers.not_running),
      )
      peers.unlink_session(directory, sender, edge.strand, session_id, strand)
    }
  })

  // Interpret unlink response JSON to verify if grant revocation was partial or complete.
  case answer {
    json.Object(fields) ->
      // This branch resolves list key_find fields recipient_grant before the operation continues.
      case list.key_find(fields, "recipient_grant") {
        Ok(json.String(_)) -> peer_links.Partial
        _ -> peer_links.Complete
      }

    _ -> peer_links.Complete
  }
}

/// Verifies that strand identifier contains valid bounded ASCII characters.
fn strand_ok(strand: String) -> Result(Nil, Nil) {
  let controlled =
    string.to_utf_codepoints(strand)
    |> list.any(fn(point) {
      let number = string.utf_codepoint_to_int(point)
      number < 32 || number == 127
    })

  // Validate length and control character constraints.
  case strand != "" && string.byte_size(strand) <= 128 && !controlled {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

/// Translates failure message strings into structured Reason enum variants.
fn reason_of(text: String) -> Reason {
  // This branch resolves the input state before the operation continues.

  // This branch resolves the input state before the operation continues.
  case text {
    "same session" -> peer_links.SameSession
    "invalid" | "invalid strand" -> peer_links.InvalidStrand
    _ ->
      case
        text == peers.not_running || text == peer_mail.not_open_reason,
        string.contains(text, "does not exist"),
        string.contains(text, "64-link")
      {
        True, _, _ -> peer_links.NotRunning
        _, True, _ -> peer_links.MissingStrand
        _, _, True -> peer_links.TooMany
        _, _, _ -> peer_links.Unavailable
      }
  }
}

/// The board `peers.inspect`'s reply stands for, bounded at
/// `peer_links.row_limit` rows. A row whose shape is not the contract's is
/// refused as a whole, so a malformed reply is an unavailable read and never a
/// partial list.
///
/// ## Examples
///
/// ```gleam
/// // ui_peers.board_of("main", inspected)
/// ```
pub fn board_of(strand: String, inspected: JsonValue) -> Result(Board, String) {
  use outgoing <- result.try(array(inspected, "outgoing"))
  use incoming <- result.try(array(inspected, "incoming"))
  use outgoing <- result.try(
    list.try_map(outgoing, fn(row) {
      row_of(row, peer_links.Outgoing, "session", "target_strand")
    }),
  )
  use incoming <- result.try(
    list.try_map(incoming, fn(row) {
      row_of(row, peer_links.Incoming, "source_session", "source_strand")
    }),
  )
  let rows = list.append(outgoing, incoming)

  // Determine whether subsequent rows were omitted based on pagination next token and size limit.
  let omitted = case field(inspected, "next"), list.length(rows) {
    Ok(json.String(_)), _ -> peer_links.Unread
    _, held if held > peer_links.row_limit ->
      peer_links.Cut(held - peer_links.row_limit)
    _, _ -> peer_links.AllShown
  }

  Ok(Board(strand:, rows: list.take(rows, peer_links.row_limit), omitted:))
}

/// Decodes a single peer inspection row into a structured Row record.
fn row_of(
  row: JsonValue,
  direction: peer_links.Direction,
  session_key: String,
  strand_key: String,
) -> Result(Row, String) {
  use session <- result.try(text(row, session_key))
  use strand <- result.try(text(row, strand_key))
  use Nil <- result.try(
    strand_ok(strand) |> result.replace_error("invalid strand"),
  )

  // Extract wake permission setting from inspected JSON row.
  let wake = case field(row, "wake") {
    Ok(json.String("busy_only")) -> Some(peer_links.BusyOnly)
    Ok(json.String("may_wake")) -> Some(peer_links.MayWake)
    _ -> None
  }

  // Extract peer display name from nested metadata.
  let name = case field(row, "metadata") {
    Ok(metadata) -> text(metadata, "name") |> result.unwrap("")
    Error(_) -> ""
  }

  // Determine whether connection basis is default or explicitly granted.
  let basis = case field(row, "default") {
    Ok(json.Bool(True)) -> peer_links.Default
    _ -> peer_links.Granted
  }

  Ok(peer_links.Row(direction:, session:, name:, strand:, wake:, basis:))
}

/// Array keeps this client decision explicit for its callers.
fn array(value: JsonValue, key: String) -> Result(List(JsonValue), String) {
  // This branch resolves field value key before the operation continues.
  case field(value, key) {
    Ok(json.Array(rows)) -> Ok(rows)
    _ -> Error("invalid peer inspection rows")
  }
}

/// Extracts a field value by key from a JSON object.
fn field(value: JsonValue, key: String) -> Result(JsonValue, String) {
  // This branch resolves value before the operation continues.
  case value {
    json.Object(fields) ->
      list.key_find(fields, key)
      |> result.map_error(fn(_) { "missing " <> key })
    _ -> Error("expected object")
  }
}

/// Extracts a text property by key from a JSON object.
fn text(value: JsonValue, key: String) -> Result(String, String) {
  use found <- result.try(field(value, key))

  // Verify that target field value is a JSON string.
  case found {
    json.String(text) -> Ok(text)
    _ -> Error("expected text " <> key)
  }
}
