//// The two tables of the untrusted executor link (protocol-change/109):
//// `[executor_link]` on an orchestrator that names an untrusted executor, and
//// `[executor_listener]` on the executor that serves it.
////
//// An untrusted executor's row in `[executors.<name>]` says where to dial and
//// which leaf to expect (`client/executors`). This module holds the rest: the
//// orchestrator's own certificate for that link, and on the executor the
//// listener and the pins of the orchestrators it admits. The daemon reads both
//// once, at start, beside `[distribution]`, and never rereads them.
////
//// The point of the mode is that an untrusted executor is never an Erlang
//// peer, so a document with `[executor_listener]` and `[distribution]` is
//// refused rather than left to start both.
////
//// ## Flow
////
//// `from_document` → `link_of` → `listener_of` → `host_port` → `pin_of`

import client/internal/ffi_tls_stream
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tom

/// The untrusted link's configuration on one daemon.
pub type Settings {
  Settings(
    /// `[executor_link]`: the orchestrator's credentials for every untrusted
    /// executor it dials.
    link: Option(ffi_tls_stream.Credentials),
    /// `[executor_listener]`: the executor's listener.
    listener: Option(Listener),
  )
}

/// An untrusted executor's listener.
pub type Listener {
  Listener(
    /// The interface, an IP literal, or `""` for every one.
    address: String,
    /// The port.
    port: Int,
    /// The executor's credentials.
    credentials: ffi_tls_stream.Credentials,
    /// The pins of the orchestrators that may connect, each 32 bytes.
    orchestrators: List(BitArray),
  )
}

/// Neither table.
pub const none = Settings(link: None, listener: None)

/// The most orchestrators one listener admits, as distribution admits peers.
pub const max_orchestrators = 32

/// Reads both tables of a parsed configuration document. A document with
/// `[executor_listener]` and `[distribution]` is refused.
///
/// ## Examples
///
/// ```gleam
/// assert untrusted_config.from_document(dict.new()) == Ok(untrusted_config.none)
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(Settings, String) {
  use link <- result.try(link_of(document))
  use listener <- result.try(listener_of(document))

  // An untrusted executor must never be a distribution peer.
  case listener, dict.has_key(document, "distribution") {
    Some(_listener), True ->
      Error(
        "[executor_listener] and [distribution] cannot share a configuration: "
        <> "an untrusted executor is never a distribution peer",
      )
    _, _ -> Ok(Settings(link:, listener:))
  }
}

/// The `[executor_link]` table: `ca`, `certificate` and `key`.
fn link_of(
  document: Dict(String, tom.Toml),
) -> Result(Option(ffi_tls_stream.Credentials), String) {
  // An absent table is an orchestrator that names no untrusted executor.
  case dict.get(document, "executor_link") {
    Error(Nil) -> Ok(None)
    Ok(tom.Table(fields)) -> {
      use Nil <- result.try(known_keys(
        dict.keys(fields),
        ["ca", "certificate", "key"],
        "executor_link",
      ))
      use credentials <- result.map(credentials_of(fields, "executor_link"))
      Some(credentials)
    }
    Ok(_other) -> Error("executor_link must be a table")
  }
}

/// The `[executor_listener]` table: `listen`, the credentials and
/// `orchestrators`.
fn listener_of(
  document: Dict(String, tom.Toml),
) -> Result(Option(Listener), String) {
  // An absent table is a daemon that serves no untrusted link.
  case dict.get(document, "executor_listener") {
    Error(Nil) -> Ok(None)
    Ok(tom.Table(fields)) -> {
      let place = "executor_listener"
      use Nil <- result.try(known_keys(
        dict.keys(fields),
        ["listen", "ca", "certificate", "key", "orchestrators"],
        place,
      ))
      use listen <- result.try(string_key(fields, place, "listen"))
      use #(address, port) <- result.try(listen_of(listen))
      use credentials <- result.try(credentials_of(fields, place))
      use orchestrators <- result.map(orchestrators_of(fields))
      Some(Listener(address:, port:, credentials:, orchestrators:))
    }
    Ok(_other) -> Error("executor_listener must be a table")
  }
}

/// `listen`: an IP literal and a port, `0.0.0.0:7443` or `[::]:7443`; the
/// unspecified addresses mean every interface.
fn listen_of(listen: String) -> Result(#(String, Int), String) {
  use #(host, port) <- result.try(
    host_port(listen)
    |> result.replace_error(
      "executor_listener.listen must be an IP address and a port, such as 0.0.0.0:7443",
    ),
  )

  // The unspecified addresses are written as every interface.
  case host {
    "0.0.0.0" | "::" -> Ok(#("", port))
    other -> Ok(#(other, port))
  }
}

/// Splits `host:port` at its last colon, with an IPv6 host written in
/// brackets, and requires a host and a TCP port.
///
/// ## Examples
///
/// ```gleam
/// assert untrusted_config.host_port("[::1]:7443") == Ok(#("::1", 7443))
/// ```
pub fn host_port(text: String) -> Result(#(String, Int), Nil) {
  use #(reversed_port, reversed_host) <- result.try(string.split_once(
    string.reverse(text),
    ":",
  ))
  let host = unbracketed(string.reverse(reversed_host))
  use port <- result.try(int.parse(string.reverse(reversed_port)))

  // An empty host, or a port outside the TCP range, names no listener.
  case host != "" && port > 0 && port < 65_536 {
    True -> Ok(#(host, port))
    False -> Error(Nil)
  }
}

/// An IPv6 literal without the brackets a port forces around it.
fn unbracketed(host: String) -> String {
  // Only a host wrapped in both brackets is an IPv6 literal in this form.
  case string.starts_with(host, "["), string.ends_with(host, "]") {
    True, True -> string.drop_start(host, 1) |> string.drop_end(1)
    _, _ -> host
  }
}

/// The three credential paths a table names.
fn credentials_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(ffi_tls_stream.Credentials, String) {
  use ca <- result.try(string_key(fields, place, "ca"))
  use certificate <- result.try(string_key(fields, place, "certificate"))
  use key <- result.map(string_key(fields, place, "key"))
  ffi_tls_stream.Credentials(ca:, certificate:, key:)
}

/// `orchestrators`: between one and `max_orchestrators` distinct pins.
fn orchestrators_of(
  fields: Dict(String, tom.Toml),
) -> Result(List(BitArray), String) {
  let place = "executor_listener.orchestrators"

  // The key is required, and only an array of text holds pins.
  use listed <- result.try(case dict.get(fields, "orchestrators") {
    Ok(tom.Array(items)) -> Ok(items)
    Ok(_other) -> Error(place <> " must be an array of pins")
    Error(Nil) -> Error(place <> " is required")
  })

  use pins <- result.try(
    list.try_map(listed, fn(item) {
      // Each entry is one pin's text.
      case item {
        tom.String(text) -> pin_of(text, place)
        _other -> Error(place <> " must hold strings")
      }
    }),
  )
  let count = list.length(pins)

  // An empty list admits nobody, and a repeated pin is a typo.
  case count >= 1 && count <= max_orchestrators && list.unique(pins) == pins {
    True -> Ok(pins)
    False ->
      Error(
        place
        <> " must name between 1 and "
        <> int.to_string(max_orchestrators)
        <> " distinct pins",
      )
  }
}

/// A pin: 64 lower-case hexadecimal digits, the SHA-256 of a leaf
/// certificate in DER.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = untrusted_config.pin_of("abc", "executor_listener")
/// ```
pub fn pin_of(text: String, place: String) -> Result(BitArray, String) {
  let refused = place <> " pins must be 64 lower-case hexadecimal digits"
  use bytes <- result.try(
    bit_array.base16_decode(string.uppercase(text))
    |> result.replace_error(refused),
  )

  // Upper-case digits decode too, so the text is held to the written form.
  case bit_array.byte_size(bytes) == 32 && string.lowercase(text) == text {
    True -> Ok(bytes)
    False -> Error(refused)
  }
}

/// Refuses a key the table does not know.
fn known_keys(
  keys: List(String),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  list.try_each(keys, fn(key) {
    // A key outside the table's set is a typo the owner should see.
    case list.contains(allowed, key) {
      True -> Ok(Nil)
      False -> Error(place <> "." <> key <> " is not a known key")
    }
  })
}

/// A required string key.
fn string_key(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(String, String) {
  // Only a string answers.
  case dict.get(fields, key) {
    Ok(tom.String(value)) -> Ok(value)
    Ok(_other) -> Error(place <> "." <> key <> " must be a string")
    Error(Nil) -> Error(place <> "." <> key <> " is required")
  }
}
