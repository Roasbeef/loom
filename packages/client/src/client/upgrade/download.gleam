//// Fixed-origin release acquisition uses verified TLS and one-fragment credit.
//// The existing weft managed owner owns transport cancellation and drain; this
//// module owns only redirect policy and bounded response accumulation.

import client/internal/ffi_upgrade as native
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/uri
import weft

/// Fetch a bounded resource with one deadline across verified HTTPS redirects.
/// ## Examples
/// `fetch("https://github.com/path", 65536)` refuses oversized responses.
pub fn fetch(url: String, limit: Int) -> Result(BitArray, String) {
  case
    weft.new_prepared([
      weft.managed(fn(ledger) { follow(url, limit, 5, ledger) }),
    ])
    |> weft.deadline(60_000)
    |> weft.cancel_grace(5000)
    |> weft.start
  {
    [weft.Completed(value:, ..)] -> Ok(value)
    [weft.Failed(error:, ..)] -> Error(error)
    _ ->
      Error("reviewed release download failed or exceeded its bounded deadline")
  }
}

fn follow(url, limit, remaining, ledger) {
  use parsed <- result.try(
    uri.parse(url) |> result.replace_error("invalid release URL"),
  )
  use host <- result.try(
    case
      parsed.scheme,
      parsed.host,
      parsed.userinfo,
      parsed.fragment,
      parsed.port
    {
      Some("https"), Some(host), None, None, None -> Ok(host)
      Some("https"), Some(host), None, None, Some(443) -> Ok(host)
      _, _, _, _, _ ->
        Error("release transport requires verified HTTPS on port 443")
    },
  )
  use connection <- result.try(native.open(host, 443))
  let response = case
    weft.adopt(ledger, connection, fn() { native.close(connection) })
  {
    weft.Adopted -> request(connection, parsed, limit)
    weft.Refused -> Error("release download cancelled before admission")
  }
  native.close(connection)
  use response <- result.try(response)
  case response {
    Body(bytes) -> Ok(bytes)
    Redirect(location) -> {
      use <- bool.guard(remaining <= 0, Error("too many release redirects"))
      use relative <- result.try(
        uri.parse(location) |> result.replace_error("invalid release redirect"),
      )
      use next <- result.try(
        uri.merge(parsed, relative)
        |> result.replace_error("invalid release redirect target"),
      )
      follow(uri.to_string(next), limit, remaining - 1, ledger)
    }
  }
}

type Response {
  Body(BitArray)
  Redirect(String)
}

fn request(connection, parsed: uri.Uri, limit) {
  let path = case parsed.path {
    "" -> "/"
    other -> other
  }
  let path = case parsed.query {
    None -> path
    Some(query) -> path <> "?" <> query
  }
  use stream <- result.try(native.request(connection, path))
  use #(completion, code, fields) <- result.try(headers(connection, stream, 8))
  case code {
    200 -> body(connection, stream, completion, limit, []) |> result.map(Body)
    301 | 302 | 303 | 307 | 308 ->
      list.key_find(fields, "location")
      |> result.replace_error("release redirect lacks Location")
      |> result.map(Redirect)
    _ -> Error("reviewed release asset is unavailable")
  }
}

fn headers(connection, stream, remaining) {
  use <- bool.guard(
    remaining <= 0,
    Error("too many informational release responses"),
  )
  use event <- result.try(native.receive(connection, stream))
  case event {
    native.Headers(completion, code, fields) -> Ok(#(completion, code, fields))
    native.Inform -> headers(connection, stream, remaining - 1)
    native.Data(..) | native.Trailers ->
      Error("release body preceded response metadata")
  }
}

fn body(connection, stream, completion, remaining, chunks) {
  case completion {
    native.Finished -> Ok(bit_array.concat(list.reverse(chunks)))
    native.More -> {
      use event <- result.try(native.receive(connection, stream))
      case event {
        native.Data(completion, bytes) -> {
          use <- bool.guard(
            bit_array.byte_size(bytes) > remaining,
            Error("reviewed release exceeds its artifact byte bound"),
          )
          native.credit(connection, stream)
          body(
            connection,
            stream,
            completion,
            remaining - bit_array.byte_size(bytes),
            [bytes, ..chunks],
          )
        }
        native.Trailers -> Ok(bit_array.concat(list.reverse(chunks)))
        native.Headers(..) | native.Inform ->
          Error("unexpected release response metadata")
      }
    }
  }
}
