//// Native HTTPS acquisition writes flow-controlled fragments to a private
//// staging file. Every redirect is validated again, and one weft deadline
//// covers the entire redirect chain, including DNS, TLS and disk writes.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/uri
import simplifile
import tui/internal/ffi_download as native
import tui/update/source
import weft

/// Downloads one HTTPS resource within a byte limit and five-minute deadline.
///
/// Only HTTP 404 is absence. Partial files are removed on failure or absence.
///
/// ## Examples
///
/// `fetch("https://example.com/asset", private_path, 262_144)` stages metadata.
pub fn fetch(url: String, destination: String, limit: Int) {
  let outcomes =
    weft.new_prepared([
      weft.managed(fn(ledger) { follow(url, destination, limit, 5, ledger) }),
    ])
    |> weft.deadline(300_000)
    |> weft.start
  let outcome = case outcomes {
    [weft.Completed(value:, ..)] -> Ok(value)
    [weft.Failed(error:, ..)] -> Error(error)
    [weft.Crashed(..)] -> Error("download transport stopped unexpectedly")
    [weft.Abandoned(..)] | [weft.NeverStarted(..)] ->
      Error("download exceeded its five-minute deadline")
    [weft.DrainProofLost(..)] | [weft.CancellationUnconfirmed(..)] ->
      Error("download transport cleanup was not confirmed")
    [] | [_, _, ..] -> Error("download produced no result")
  }

  // Publication never sees a failed or incomplete download.
  case outcome {
    Ok(source.Present) -> outcome
    Ok(source.Absent) | Error(_) -> {
      let _cleanup = simplifile.delete(destination)
      outcome
    }
  }
}

/// Validates transport identity before opening a socket, including redirects.
///
/// ## Examples
///
/// `validate_url("http://example.com")` refuses an unencrypted download.
pub fn validate_url(url: String) -> Result(uri.Uri, String) {
  use parsed <- result.try(
    uri.parse(url) |> result.replace_error("invalid download URL"),
  )
  case parsed.scheme, parsed.host, parsed.userinfo, parsed.fragment {
    Some("https"), Some(host), None, None if host != "" -> {
      let port = port_number(parsed.port)
      use <- bool.guard(port < 1 || port > 65_535, Error("invalid HTTPS port"))
      Ok(parsed)
    }
    _, _, _, _ ->
      Error("download requires HTTPS without credentials or fragment")
  }
}

fn port_number(port) {
  case port {
    Some(value) -> value
    None -> 443
  }
}

type Response {
  Found
  Missing
  Redirect(location: String)
}

fn follow(url, destination, limit, remaining, ledger) {
  use parsed <- result.try(validate_url(url))
  use host <- result.try(case parsed.host {
    Some(host) -> Ok(host)
    None -> Error("download URL lacks host")
  })
  use connection <- result.try(native.open(host, port_number(parsed.port)))

  // Gun owns its transport. A normal stop runs its termination callback,
  // closing that transport before weft accepts the owner's drain proof.
  let outcome = case
    weft.adopt(ledger, connection, fn() { native.close(connection) })
  {
    weft.Adopted -> request(connection, parsed, destination, limit)
    weft.Refused -> Error("download was cancelled before request admission")
  }
  native.close(connection)
  use response <- result.try(outcome)
  case response {
    Found -> Ok(source.Present)
    Missing -> Ok(source.Absent)
    Redirect(location) -> {
      use <- bool.guard(remaining == 0, Error("too many download redirects"))
      use relative <- result.try(
        uri.parse(location) |> result.replace_error("invalid redirect URL"),
      )
      use next <- result.try(
        uri.merge(parsed, relative)
        |> result.replace_error("cannot resolve redirect URL"),
      )
      follow(uri.to_string(next), destination, limit, remaining - 1, ledger)
    }
  }
}

fn request(connection, parsed: uri.Uri, destination, limit) {
  let path = case parsed.path {
    "" -> "/"
    path -> path
  }
  let path = case parsed.query {
    None -> path
    Some(query) -> path <> "?" <> query
  }
  use stream <- result.try(native.request(connection, path))
  use #(completion, status, fields) <- result.try(headers(connection, stream, 8))
  case status {
    200 -> {
      use Nil <- result.try(
        simplifile.write_bits(destination, <<>>)
        |> result.replace_error("cannot create download staging file"),
      )
      body(connection, stream, completion, destination, limit)
      |> result.map(fn(_) { Found })
    }
    404 -> Ok(Missing)
    301 | 302 | 303 | 307 | 308 ->
      list.key_find(fields, "location")
      |> result.replace_error("download redirect lacks Location")
      |> result.map(Redirect)
    code -> Error("download returned HTTP " <> int.to_string(code))
  }
}

fn headers(connection, stream, remaining) {
  use <- bool.guard(remaining == 0, Error("too many informational responses"))
  use event <- result.try(native.receive(connection, stream))
  case event {
    native.Headers(completion, status, fields) ->
      Ok(#(completion, status, fields))
    native.Inform -> headers(connection, stream, remaining - 1)
    native.Data(..) | native.Trailers -> Error("download body preceded headers")
  }
}

fn body(connection, stream, completion, destination, remaining) {
  case completion {
    native.Finished -> Ok(Nil)
    native.More -> {
      use event <- result.try(native.receive(connection, stream))
      case event {
        native.Data(completion, bytes) -> {
          let size = bit_array.byte_size(bytes)
          use <- bool.guard(
            size > remaining,
            Error("download exceeds byte limit"),
          )
          use Nil <- result.try(
            simplifile.append_bits(destination, bytes)
            |> result.replace_error("cannot write download staging file"),
          )

          // Credit is restored only after this fragment has reached the file.
          native.credit(connection, stream)
          body(connection, stream, completion, destination, remaining - size)
        }
        native.Trailers -> Ok(Nil)
        native.Headers(..) | native.Inform ->
          Error("unexpected download metadata")
      }
    }
  }
}
