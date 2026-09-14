//// The L402 challenge a paywalled HTTP endpoint answers a request with,
//// and the credential a buyer sends back once it has paid.
////
//// This boundary exists because a priced endpoint says "402 Payment
//// Required" in two different dialects and the rest of the package must
//// not learn either of them. An aperture-style proxy either serves a JSON
//// body carrying `invoice`, `macaroon`, `amount_sat`, `challenge_id` and
//// `route_id`, or it puts the same facts in headers — a
//// `WWW-Authenticate: L402 macaroon="…", invoice="…"` line beside
//// `X-Aperture-Challenge-Id`, `X-Aperture-Route-Id` and
//// `X-Aperture-Price-Sat`. Older proxies spell the scheme word `LSAT`.
//// Both shapes mean the same thing, so both parse into one `Challenge`
//// and the adapters, the gateway and the paywall see only that.
////
//// The module is pure: no process, no FFI, no clock. It is a function
//// from the bytes of one response to a value, which is what makes the
//// amount arithmetic and the two dialects property-testable without a
//// transport. It also decodes no more of the Lightning wire than it
//// needs: the BOLT11 invoice is carried verbatim for the payer, and only
//// its human-readable prefix is read, to recover a price the proxy did
//// not state outright. Nothing here verifies a macaroon or a payment;
//// settling is the paywall's job (`provider/paywall`).

import core/json
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// One bitcoin, in satoshis. Every amount the human-readable part can
// carry is a rational fraction of this, which is why the arithmetic below
// is integer division rather than floating point: a price is exact or it
// is not a price.
const satoshis_per_bitcoin = 100_000_000

/// One L402 challenge, exactly as a 402 response carried it.
///
/// Constructor invariants: `macaroon` and `invoice` are the verbatim
/// strings the proxy sent, because the macaroon travels back byte-identical
/// in the credential and the invoice is paid by a wallet that parses it
/// itself; `amount_sat` is the price the proxy stated, otherwise the
/// amount encoded in the invoice, otherwise `None` for an invoice that
/// leaves the amount to the payer; `challenge_id` and `route_id` are `""`
/// when the proxy sent neither, since they are proxy-side correlation
/// labels rather than anything this package decides with.
pub type Challenge {
  Challenge(
    /// The macaroon, verbatim, as it must be echoed in the credential.
    macaroon: String,
    /// The BOLT11 payment request, verbatim, for the wallet to pay.
    invoice: String,
    /// The price in satoshis, when the proxy or the invoice states one.
    amount_sat: Option(Int),
    /// The proxy's correlation id for this challenge, or `""`.
    challenge_id: String,
    /// The proxy's route id for this challenge, or `""`.
    route_id: String,
  )
}

/// Parses a 402 response into a challenge.
///
/// Header names are expected lowercase, as the transport normalizes them.
/// The dialect is chosen by `content-type`: a type containing
/// `application/json` means the body carries the challenge, and anything
/// else means the headers do. The two are not tried in turn, because a
/// proxy that states its content type has told us which of them is
/// authoritative, and a body that contradicts its own type is a proxy we
/// do not speak.
///
/// The error is a short reason for the caller's log, never the partial
/// challenge: a response missing either half is not payable, so there is
/// nothing to carry forward.
///
/// ## Examples
///
/// ```gleam
/// let headers = [
///   #("www-authenticate", "L402 macaroon=\"AGIA\", invoice=\"lnbc1m1x\""),
/// ]
/// let assert Ok(challenge) = l402.parse(headers, "")
/// assert challenge.macaroon == "AGIA"
/// ```
///
/// ```gleam
/// assert l402.parse([], "") == Error("no L402 challenge in the response")
/// ```
///
pub fn parse(
  headers: List(#(String, String)),
  body: String,
) -> Result(Challenge, String) {
  case is_json_response(headers) {
    True -> parse_body(body)
    False -> parse_headers(headers)
  }
}

/// The value of the `Authorization` header that pays for a request: the
/// scheme word, the macaroon as the challenge sent it, a colon, and the
/// payment preimage in hexadecimal.
///
/// The preimage is the proof of payment, so this string is a bearer
/// credential for as long as the macaroon's caveats permit. Treat it the
/// way the gateway treats an API key: one outbound header, scrubbed out
/// of any error that might have reflected it.
///
/// ## Examples
///
/// ```gleam
/// assert l402.authorization("AGIA", "ab12") == "L402 AGIA:ab12"
/// ```
///
pub fn authorization(macaroon: String, preimage_hex: String) -> String {
  "L402 " <> macaroon <> ":" <> preimage_hex
}

/// The amount a BOLT11 invoice encodes in its human-readable part, in
/// whole satoshis.
///
/// The human-readable part is everything before the last `1` in the
/// invoice — the bech32 separator, which cannot appear in the data part —
/// and consists of a network prefix (`lnbc`, `lntb`, `lntbs`, `lnbcrt`)
/// followed by an optional amount: a decimal figure and an optional
/// multiplier letter, `m`, `u`, `n` or `p` for a thousandth, a millionth,
/// a billionth or a trillionth of one bitcoin. The figure with no letter
/// is a whole number of bitcoin.
///
/// `None` covers three separate facts, all of which mean the same thing
/// to a caller: the invoice names no amount and leaves it to the payer,
/// the amount is a fraction of a satoshi and so cannot be a price here,
/// or the prefix is not one this function recognizes. The arithmetic is
/// integer throughout, so a sub-satoshi amount is rejected rather than
/// rounded into a figure nobody agreed to pay.
///
/// ## Examples
///
/// ```gleam
/// assert l402.invoice_amount_sat("lnbc2500u1pvjluezabc") == option.Some(250_000)
/// ```
///
/// ```gleam
/// assert l402.invoice_amount_sat("lnbc1pvjluezabc") == option.None
/// ```
///
pub fn invoice_amount_sat(invoice: String) -> Option(Int) {
  let lowered = string.lowercase(invoice)

  // The data part never contains a `1`, so the last one separates it from
  // the human-readable part. An invoice with no separator at all is not
  // bech32 and carries no amount we can read.
  use human_readable <- option.then(human_readable_part(lowered))

  // The prefix is matched longest first: `lnbcrt` is a prefix of nothing,
  // but `lnbc` is a prefix of `lnbcrt`, so testing `lnbc` first would read
  // a regtest invoice's `rt` as the start of its amount.
  use amount <- option.then(strip_network_prefix(human_readable))

  amount_to_sat(amount)
}

// The human-readable part: everything before the bech32 separator, which
// is the last `1` in the string. Splitting on every `1` and dropping the
// final piece is how the *last* one is found without scanning backwards;
// rejoining the rest restores any `1` that belonged to the amount.
fn human_readable_part(invoice: String) -> Option(String) {
  case list.reverse(string.split(invoice, "1")) {
    // No separator at all, so this is not a bech32 string.
    [] -> None
    [_whole] -> None

    [_data, ..head_reversed] ->
      head_reversed
      |> list.reverse
      |> string.join("1")
      |> Some
  }
}

// The amount field of a human-readable part, with its network prefix
// removed. `Error` for a prefix this function does not know, which is how
// an invoice for some other protocol declines to be priced.
fn strip_network_prefix(human_readable: String) -> Option(String) {
  let prefixes = ["lnbcrt", "lntbs", "lnbc", "lntb"]
  let matched =
    list.find_map(prefixes, fn(prefix) {
      case string.starts_with(human_readable, prefix) {
        True -> Ok(string.drop_start(human_readable, string.length(prefix)))
        False -> Error(Nil)
      }
    })
  option.from_result(matched)
}

// A figure and an optional multiplier letter, in satoshis. The empty
// string is the amountless invoice, which is a legitimate BOLT11 form and
// not an error, and is answered before `int.parse` ever sees it.
fn amount_to_sat(amount: String) -> Option(Int) {
  use <- bool.guard(when: amount == "", return: None)
  let #(figure, divisor) = split_multiplier(amount)
  use digits <- option.then(option.from_result(int.parse(figure)))

  // Satoshis are the smallest unit anything downstream can pay, so an
  // amount that does not land on a whole one is reported as no amount at
  // all rather than silently rounded up or down.
  let scaled = digits * satoshis_per_bitcoin
  case scaled % divisor {
    0 -> Some(scaled / divisor)
    _remainder -> None
  }
}

// The figure and the divisor that turns whole bitcoin into the
// multiplier's unit, so the conversion above stays in integers. A
// trailing character that is neither a multiplier nor a digit is left on
// the figure, where `int.parse` rejects it — which is the right answer
// for a prefix this function does not understand.
fn split_multiplier(amount: String) -> #(String, Int) {
  let figure = string.drop_end(amount, 1)
  case string.slice(amount, string.length(amount) - 1, 1) {
    "m" -> #(figure, 1000)
    "u" -> #(figure, 1_000_000)
    "n" -> #(figure, 1_000_000_000)
    "p" -> #(figure, 1_000_000_000_000)
    _no_multiplier -> #(amount, 1)
  }
}

// A stated price only counts when it is positive. Aperture's own client
// treats `stated <= 0` as unstated, and it is the right reading in both
// directions: a proxy has no way to spell "free" in a 402 it is minting
// an invoice for, so a zero is a field it did not fill rather than a
// price it set, and honouring it would report a payable request as
// costing nothing. Falling through to the invoice's own amount reports
// what the buyer will actually be asked for.
fn positive_price(amount: Int) -> Option(Int) {
  case amount > 0 {
    True -> Some(amount)
    False -> None
  }
}

// --- the two challenge dialects -------------------------------------------

// Whether the proxy declared a JSON body. A `content-type` carries
// parameters after the type, so this is a containment test rather than an
// equality one.
fn is_json_response(headers: List(#(String, String))) -> Bool {
  case list.key_find(headers, "content-type") {
    Ok(value) -> string.contains(string.lowercase(value), "application/json")
    Error(Nil) -> False
  }
}

// The JSON dialect: one object carrying the whole challenge.
fn parse_body(body: String) -> Result(Challenge, String) {
  use document <- result.try(
    json.parse(body)
    |> result.replace_error("the 402 body was not the JSON it declared"),
  )
  use macaroon <- result.try(string_field(document, "macaroon"))
  use invoice <- result.try(string_field(document, "invoice"))

  // The stated price wins over the invoice's own, because a proxy may
  // price a route above the invoice it mints for it and the buyer is
  // being asked for the former. A price of zero or below is not one of
  // those cases; see `positive_price`.
  let stated = case int_field(document, "amount_sat") {
    Ok(amount) -> positive_price(amount)
    Error(Nil) -> None
  }

  Ok(Challenge(
    macaroon:,
    invoice:,
    amount_sat: option.lazy_or(stated, fn() { invoice_amount_sat(invoice) }),
    challenge_id: string_field_or(document, "challenge_id"),
    route_id: string_field_or(document, "route_id"),
  ))
}

// The header dialect: a `www-authenticate` challenge line, plus the
// proxy's own correlation headers beside it.
fn parse_headers(
  headers: List(#(String, String)),
) -> Result(Challenge, String) {
  use line <- result.try(
    list.key_find(headers, "www-authenticate")
    |> result.replace_error("no L402 challenge in the response"),
  )
  use parameters <- result.try(challenge_parameters(line))
  use macaroon <- result.try(
    list.key_find(parameters, "macaroon")
    |> result.replace_error("the L402 challenge carried no macaroon"),
  )
  use invoice <- result.try(
    list.key_find(parameters, "invoice")
    |> result.replace_error("the L402 challenge carried no invoice"),
  )

  // The price header is advisory: a proxy that omits it has still priced
  // the request inside the invoice it minted, and one that sends a
  // non-positive figure has said nothing (see `positive_price`).
  let stated =
    list.key_find(headers, "x-aperture-price-sat")
    |> result.try(int.parse)
    |> option.from_result
    |> option.then(positive_price)

  Ok(Challenge(
    macaroon:,
    invoice:,
    amount_sat: option.lazy_or(stated, fn() { invoice_amount_sat(invoice) }),
    challenge_id: header_or(headers, "x-aperture-challenge-id"),
    route_id: header_or(headers, "x-aperture-route-id"),
  ))
}

// The parameters of an `L402` (or legacy `LSAT`) challenge line, as
// `key` to unquoted `value` pairs. A line naming some other scheme is
// rejected here rather than parsed as if it were ours.
fn challenge_parameters(
  line: String,
) -> Result(List(#(String, String)), String) {
  let trimmed = string.trim(line)
  use rest <- result.try(strip_scheme(trimmed))

  string.split(rest, ",")
  |> list.filter_map(parameter)
  |> Ok
}

// The challenge line with its scheme word removed. Both spellings are
// accepted: `LSAT` is what proxies predating the rename still send, and
// the body of the challenge is identical under either name.
fn strip_scheme(line: String) -> Result(String, String) {
  let scheme = string.lowercase(string.slice(line, 0, 5))
  case scheme {
    "l402 " -> Ok(string.drop_start(line, 5))
    "lsat " -> Ok(string.drop_start(line, 5))
    _other -> Error("the response did not carry an L402 challenge")
  }
}

// One `key="value"` parameter. Whitespace around it is dropped and the
// quotes, which are mandatory in practice but not worth failing over, are
// stripped when present.
fn parameter(text: String) -> Result(#(String, String), Nil) {
  case string.split_once(string.trim(text), "=") {
    Ok(#(name, value)) -> {
      let name = string.lowercase(string.trim(name))
      let value = unquote(string.trim(value))
      Ok(#(name, value))
    }
    Error(Nil) -> Error(Nil)
  }
}

fn unquote(value: String) -> String {
  case string.starts_with(value, "\"") && string.ends_with(value, "\"") {
    True -> string.slice(value, 1, string.length(value) - 2)
    False -> value
  }
}

fn header_or(headers: List(#(String, String)), name: String) -> String {
  case list.key_find(headers, name) {
    Ok(value) -> value
    Error(Nil) -> ""
  }
}

// --- JSON field lookups ---------------------------------------------------

// A required string field, with the reason a caller logs when it is
// missing. The two dialects differ, but "no macaroon" means the same
// thing in both.
fn string_field(
  document: json.JsonValue,
  name: String,
) -> Result(String, String) {
  field(document, name)
  |> result.try(string_value)
  |> result.map_error(fn(_absent) { "the 402 body carried no " <> name })
}

fn string_field_or(document: json.JsonValue, name: String) -> String {
  field(document, name)
  |> result.try(string_value)
  |> result.unwrap(or: "")
}

fn int_field(document: json.JsonValue, name: String) -> Result(Int, Nil) {
  field(document, name)
  |> result.try(int_value)
}

fn field(
  document: json.JsonValue,
  name: String,
) -> Result(json.JsonValue, Nil) {
  case document {
    json.Object(fields:) -> list.key_find(fields, name)

    // A 402 body that is not an object carries no fields to read; the
    // caller reports the missing field rather than the wrong shape,
    // because either way the response is not payable.
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error(Nil)
  }
}

fn string_value(value: json.JsonValue) -> Result(String, Nil) {
  case value {
    json.String(value:) -> Ok(value)

    json.Object(..)
    | json.Array(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error(Nil)
  }
}

fn int_value(value: json.JsonValue) -> Result(Int, Nil) {
  case value {
    json.Int(value:) -> Ok(value)

    json.Object(..)
    | json.Array(..)
    | json.String(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error(Nil)
  }
}
