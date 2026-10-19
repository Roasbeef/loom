//// The loopback address the daemon's listener binds, from `--bind` or from
//// `[daemon] bind` in the startup configuration file.
////
//// The daemon serves cleartext HTTP and WebSockets, so it listens on loopback
//// only. A person on another machine reaches it through a TLS-terminating
//// proxy on the same host (`client/daemon/ui_origin`), never through a public
//// listener. This module owns the one grammar both sources are read with:
//// `127.0.0.1:port` or `[::1]:port`, with a port from 0 to 65535, where 0 asks
//// the kernel for an ephemeral port. Any other host is refused rather than
//// rewritten, so a typo never leaves a daemon listening somewhere its owner
//// did not intend.
////
//// Two readers share the parse. `client/daemon/main` reads the flag and then,
//// when no flag was given, the file, once at startup; `client/daemon/limits`
//// validates the `[daemon]` table for startup and for a session's catalogue
//// alike. A bad value is therefore refused with the same words whichever
//// reader sees it first. The address is never reread: a changed `bind`
//// takes effect only when the daemon restarts.

import gleam/dict.{type Dict}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tom

/// A loopback address the listener may bind. A value built by `parse` always
/// names one of the two loopback literals and a port in 0..65535.
pub type Address {
  Address(
    /// The host as `mist` binds it: `127.0.0.1`, or `::1` without brackets.
    host: String,
    /// The TCP port. Zero requests an ephemeral port, which the daemon then
    /// publishes in its endpoint record for clients to find.
    port: Int,
  )
}

/// The `[daemon]` key the address is read from.
pub const key = "bind"

/// The address used when neither `--bind` nor `[daemon] bind` names one:
/// IPv4 loopback on an ephemeral port.
pub const default = Address("127.0.0.1", 0)

/// Parses one address. `source` names where the value came from, such as
/// `--bind` or `daemon.bind`, and opens every error message so the owner can
/// tell which of the two to fix.
///
/// ## Examples
///
/// ```gleam
/// assert listen_address.parse("[::1]:4100", from: "--bind")
///   == Ok(listen_address.Address("::1", 4100))
/// ```
///
/// ```gleam
/// assert listen_address.parse("0.0.0.0:9000", from: "daemon.bind")
///   |> result.is_error
/// ```
pub fn parse(value: String, from source: String) -> Result(Address, String) {
  use #(host, port) <- result.try(case string.split(value, ":") {
    ["127.0.0.1", port] -> Ok(#("127.0.0.1", port))
    ["[", "", "1]", port] -> Ok(#("::1", port))
    _ ->
      Error(
        source
        <> " \""
        <> value
        <> "\" is not loopback; use 127.0.0.1:port or [::1]:port",
      )
  })
  use port <- result.try(
    int.parse(port)
    |> result.map_error(fn(_) {
      source <> " port \"" <> port <> "\" is not a number"
    }),
  )
  case port >= 0 && port <= 65_535 {
    True -> Ok(Address(host:, port:))
    False ->
      Error(source <> " port " <> int.to_string(port) <> " is outside 0..65535")
  }
}

/// Reads `[daemon] bind` from a parsed configuration document. An absent key
/// or table is `None`, which leaves the choice to `--bind` or the default.
///
/// ## Examples
///
/// ```gleam
/// assert listen_address.from_document(dict.new()) == Ok(None)
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(Option(Address), String) {
  case dict.get(document, "daemon") {
    Ok(tom.Table(fields)) -> from_fields(fields)
    Ok(_) | Error(Nil) -> Ok(None)
  }
}

/// `from_document` over the `[daemon]` table's own fields, which is what
/// `client/daemon/limits` validates the table with.
///
/// ## Examples
///
/// ```gleam
/// assert listen_address.from_fields(dict.new()) == Ok(None)
/// ```
pub fn from_fields(
  fields: Dict(String, tom.Toml),
) -> Result(Option(Address), String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok(None)
    Ok(tom.String(value)) ->
      parse(value, from: "daemon." <> key) |> result.map(Some)
    Ok(_) ->
      Error(
        "daemon."
        <> key
        <> " must be a string such as \"127.0.0.1:4100\" or \"[::1]:4100\"",
      )
  }
}
