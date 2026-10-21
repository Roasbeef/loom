//// The `https` origins the web view may be served at besides loopback
//// (protocol-change/052).
////
//// The daemon listens on loopback only. A person on another machine reaches
//// the page through a TLS-terminating proxy on the daemon's own host, such as
//// Tailscale Serve, which forwards to the loopback listener and passes the
//// browser's `Host` and `Origin` through. The daemon cannot tell such a
//// proxy's request from one any local process wrote, so it never reads a
//// forwarded header. It admits a non-loopback `Host` only when the owner
//// listed that exact origin in `[daemon] ui_origins`, read once at startup.
////
//// This module owns the list's grammar. An entry is a whole origin and
//// nothing more: the `https` scheme, a host, an optional port, and no user
//// information, path, query or fragment. A bad entry refuses the daemon's
//// start and names the entry, so a typo never leaves a page unreachable in a
//// way the owner has to discover from a browser. The parsed `Origin` is
//// opaque and normalized the way a browser writes `Origin` and `Host`: the
//// host lowercased and the default port 443 dropped. Every comparison the
//// view makes is then an exact string comparison against that form.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tom

/// One listed origin, normalized. It is built only by `parse`, so a value of
/// this type is always an `https` origin with a valid, lowercase,
/// non-loopback host and no default port.
pub opaque type Origin {
  Origin(
    /// The host, lowercased: a DNS name, an IPv4 literal, or a bracketed IPv6
    /// literal.
    host: String,
    /// The port when it is not 443, the default a browser leaves out.
    port: Option(Int),
  )
}

/// The `[daemon]` key the list is read from.
pub const key = "ui_origins"

/// The most entries the list may hold. A deployment names one proxy origin,
/// or a few; the bound keeps the per-request scan over the list short.
pub const max_origins = 16

/// Parses one entry of `[daemon] ui_origins`.
///
/// The scheme must be `https`: the page's cookies are `Secure` on a listed
/// origin, and an `http` origin on another host would carry tickets and
/// cookies across the network in clear text. The host must not be a
/// loopback name, which the view admits without a list. A single trailing
/// `/` is accepted and dropped, because that is how a browser's address bar
/// shows an origin.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(origin) = ui_origin.parse("https://Box.tail0a99b.ts.net:8443/")
/// assert ui_origin.to_string(origin) == "https://box.tail0a99b.ts.net:8443"
/// ```
///
/// ```gleam
/// assert ui_origin.parse("http://box.example") |> result.is_error
/// ```
pub fn parse(entry: String) -> Result(Origin, String) {
  let lowered = string.lowercase(entry)
  let parsed = case lowered {
    "https://" <> rest -> authority(rest)
    "http://" <> _ ->
      Error("must use https; the proxy terminates TLS for the view")
    _ -> Error("is not an origin of the form https://host[:port]")
  }
  result.map_error(parsed, fn(reason) {
    key <> " entry \"" <> entry <> "\" " <> reason
  })
}

// The part after `https://`: one optional trailing slash is dropped, and
// anything that would make the entry more than an origin is refused before
// the host and port are read.
fn authority(rest: String) -> Result(Origin, String) {
  let rest = case string.ends_with(rest, "/") {
    True -> string.drop_end(rest, 1)
    False -> rest
  }
  let extra =
    list.find(["/", "?", "#", "@", "\\", " ", "%"], fn(mark) {
      string.contains(rest, mark)
    })
  case extra, rest {
    Ok(_), _ -> Error("must have no user information, path or query")
    Error(Nil), "" -> Error("names no host")
    Error(Nil), _ -> host_and_port(rest)
  }
}

// Splits the host from the port, then checks each.
fn host_and_port(rest: String) -> Result(Origin, String) {
  use #(host, suffix) <- result.try(
    split_host(rest) |> result.replace_error("has an unclosed IPv6 bracket"),
  )
  use Nil <- result.try(case valid_host(host) {
    True -> Ok(Nil)
    False -> Error("has an invalid host")
  })
  use port <- result.try(
    port_of(suffix) |> result.replace_error("has an invalid port"),
  )
  case loopback(host) {
    True -> Error("names a loopback host, which the view admits without a list")
    False -> Ok(Origin(host:, port:))
  }
}

// A bracketed IPv6 literal carries colons of its own, so its port is whatever
// follows the closing bracket. Any other host ends at its first colon.
fn split_host(rest: String) -> Result(#(String, String), Nil) {
  case string.starts_with(rest, "[") {
    True ->
      string.split_once(rest, "]")
      |> result.map(fn(parts) { #(parts.0 <> "]", parts.1) })
    False ->
      case string.split_once(rest, ":") {
        Ok(#(name, port)) -> Ok(#(name, ":" <> port))
        Error(Nil) -> Ok(#(rest, ""))
      }
  }
}

// A host is a bracketed IPv6 literal of hexadecimal digits, colons and dots,
// or a DNS name or IPv4 literal: dot-separated labels of letters, digits and
// hyphens, none empty and none starting or ending with a hyphen.
fn valid_host(host: String) -> Bool {
  case host {
    "[" <> inner ->
      case string.ends_with(inner, "]") {
        False -> False
        True -> {
          let inner = string.drop_end(inner, 1)
          inner != "" && only(inner, "0123456789abcdef:.")
        }
      }
    _ ->
      string.byte_size(host) <= 253
      && list.all(string.split(host, "."), valid_label)
  }
}

fn valid_label(label: String) -> Bool {
  label != ""
  && string.byte_size(label) <= 63
  && only(label, "abcdefghijklmnopqrstuvwxyz0123456789-")
  && !string.starts_with(label, "-")
  && !string.ends_with(label, "-")
}

fn only(text: String, allowed: String) -> Bool {
  list.all(string.to_graphemes(text), fn(character) {
    string.contains(allowed, character)
  })
}

// The port after the host: none, or one to five digits naming 1 to 65535.
// Port 443 is the `https` default, which a browser leaves out of `Origin`
// and `Host`, so it is stored as no port at all. The digits are checked
// before `int.parse`, which would accept a sign.
fn port_of(suffix: String) -> Result(Option(Int), Nil) {
  case suffix {
    "" -> Ok(None)
    ":" <> digits -> {
      use Nil <- result.try(
        case
          digits != ""
          && string.drop_start(digits, 5) == ""
          && only(digits, "0123456789")
        {
          True -> Ok(Nil)
          False -> Error(Nil)
        },
      )
      use port <- result.try(int.parse(digits))
      case port {
        443 -> Ok(None)
        _ if port >= 1 && port <= 65_535 -> Ok(Some(port))
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

// The names the view admits as loopback (`ui_http.loopback_host`): three
// literals and everything under `.localhost`.
// Listing one would change nothing, so it is refused as a likely mistake.
fn loopback(host: String) -> Bool {
  host == "localhost"
  || host == "127.0.0.1"
  || host == "[::1]"
  || string.ends_with(host, ".localhost")
}

/// The origin as a browser writes it in `Origin`: `https://`, the host, and
/// the port when it is not 443.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(origin) = ui_origin.parse("https://box.example:443")
/// assert ui_origin.to_string(origin) == "https://box.example"
/// ```
pub fn to_string(origin: Origin) -> String {
  "https://" <> authority_of(origin)
}

/// The host and port as a browser writes them in `Host`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(origin) = ui_origin.parse("https://box.example:8443")
/// assert ui_origin.host(origin) == "box.example:8443"
/// ```
pub fn host(origin: Origin) -> String {
  authority_of(origin)
}

fn authority_of(origin: Origin) -> String {
  case origin.port {
    None -> origin.host
    Some(port) -> origin.host <> ":" <> int.to_string(port)
  }
}

/// Whether a request's `Host` header names this origin. The header is read
/// with the grammar `parse` reads an entry with, so the two sides share one
/// normalization (letter case, the default port 443) and the parsed values
/// are then compared exactly. A different port, a trailing dot, a second
/// port, or any other spelling is refused. A `/` is refused before parsing,
/// since `parse` accepts one trailing slash and a `Host` carries none.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(origin) = ui_origin.parse("https://box.example:8443")
/// assert ui_origin.names_host(origin, "BOX.example:8443")
/// assert !ui_origin.names_host(origin, "box.example:9443")
/// ```
pub fn names_host(origin: Origin, header: String) -> Bool {
  !string.contains(header, "/") && parse("https://" <> header) == Ok(origin)
}

/// Reads `[daemon] ui_origins` from a parsed configuration document: an
/// array of strings, each an origin `parse` accepts, at most `max_origins`
/// of them. An absent key or table is the empty list. A repeated origin is
/// kept once.
///
/// ## Examples
///
/// ```gleam
/// assert ui_origin.from_document(dict.new()) == Ok([])
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(List(Origin), String) {
  case dict.get(document, "daemon") {
    Ok(tom.Table(fields)) -> from_fields(fields)
    Ok(_) | Error(Nil) -> Ok([])
  }
}

/// `from_document` over the `[daemon]` table's own fields, which is what
/// `client/daemon/limits` validates the table with.
///
/// ## Examples
///
/// ```gleam
/// assert ui_origin.from_fields(dict.new()) == Ok([])
/// ```
pub fn from_fields(
  fields: Dict(String, tom.Toml),
) -> Result(List(Origin), String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok([])
    Ok(tom.Array(items)) -> entries(items)
    Ok(_) -> Error("daemon." <> key <> " must be an array of strings")
  }
}

fn entries(items: List(tom.Toml)) -> Result(List(Origin), String) {
  use Nil <- result.try(case list.drop(items, max_origins) == [] {
    True -> Ok(Nil)
    False ->
      Error(
        "daemon."
        <> key
        <> " lists more than "
        <> int.to_string(max_origins)
        <> " origins",
      )
  })
  list.try_map(items, fn(item) {
    case item {
      tom.String(entry) -> parse(entry)
      _ -> Error("daemon." <> key <> " entries must be strings")
    }
  })
  |> result.map(list.unique)
}
