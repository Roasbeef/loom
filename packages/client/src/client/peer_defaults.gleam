//// The `[peers]` table: whether sessions are linked to each other without a
//// per-pair grant, and whether such a link may wake an idle recipient
//// (protocol-change/077).
////
//// The daemon's owner chooses this once, in the startup configuration, and a
//// running daemon never rereads it, as it never rereads its connection limits
//// (`client/daemon/limits`). A session's own configuration cannot turn the
//// default on for the daemon it runs under, because the value is captured
//// before any session opens. The catalogue parser validates the same table, so
//// a typo is refused wherever the file is read rather than only at startup.
////
//// Both keys default to the safe answer. `default_links = "off"` leaves every
//// link an explicit owner grant, which is what the daemon did before this
//// table existed, and `default_wake = "busy_only"` lets a default link deliver
//// only into a strand that is already running. The module decodes and decides
//// nothing else: `client/peer_mail` owns what a policy admits.

import client/peer_mail.{
  type Policy, BusyOnly, MayWake, NoDefaultLinks, SameOwner,
}
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import tom

/// The policy of a daemon whose configuration has no `[peers]` table.
///
/// ## Examples
///
/// ```gleam
/// assert peer_defaults.off
///   == peer_mail.Policy(peer_mail.NoDefaultLinks, peer_mail.BusyOnly)
/// ```
pub const off = peer_mail.Policy(links: NoDefaultLinks, wake: BusyOnly)

/// Reads the policy from configuration text, for callers that hold no parsed
/// document.
///
/// ## Examples
///
/// ```gleam
/// assert peer_defaults.parse("") == Ok(peer_defaults.off)
/// ```
pub fn parse(text: String) -> Result(Policy, String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "invalid daemon configuration: " <> string.inspect(error)
    }),
  )
  from_document(document)
}

/// Validates the `[peers]` table of a parsed configuration document.
///
/// Omission keeps the default, and so does a table that names only one key.
/// A key it does not know, a value of the wrong type and a word it does not
/// recognise are each refused with the key's full name, so the owner can find
/// the line.
///
/// ## Examples
///
/// ```gleam
/// assert peer_defaults.from_document(dict.new()) == Ok(peer_defaults.off)
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(Policy, String) {
  case dict.get(document, "peers") {
    Error(Nil) -> Ok(off)
    Ok(tom.Table(fields)) -> from_fields(fields)
    Ok(_) -> Error("peers must be a [peers] table")
  }
}

fn from_fields(fields: Dict(String, tom.Toml)) -> Result(Policy, String) {
  use _ <- result.try(
    list.try_map(dict.keys(fields), fn(key) {
      case key {
        "default_links" | "default_wake" -> Ok(Nil)
        _ -> Error("unknown key `" <> key <> "` in [peers]")
      }
    }),
  )
  use links <- result.try(case dict.get(fields, "default_links") {
    Error(Nil) -> Ok(NoDefaultLinks)
    Ok(tom.String("off")) -> Ok(NoDefaultLinks)
    Ok(tom.String("same_owner")) -> Ok(SameOwner)
    Ok(_) -> Error("peers.default_links must be \"off\" or \"same_owner\"")
  })
  use wake <- result.try(case dict.get(fields, "default_wake") {
    Error(Nil) -> Ok(BusyOnly)
    Ok(tom.String("busy_only")) -> Ok(BusyOnly)
    Ok(tom.String("may_wake")) -> Ok(MayWake)
    Ok(_) -> Error("peers.default_wake must be \"busy_only\" or \"may_wake\"")
  })
  Ok(peer_mail.Policy(links:, wake:))
}
