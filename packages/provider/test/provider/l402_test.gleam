//// The two L402 challenge dialects and the BOLT11 amount prefix.
////
//// Everything here is pure: a list of headers and a body string in, a
//// `Challenge` or a reason out. The amount cases are the ones worth
//// reading twice, because they are the only arithmetic in the package
//// that decides how much money moves.

import gleam/option.{None, Some}
import provider/l402

const header_challenge = "L402 macaroon=\"AGIAJEemVQ\", invoice=\"lnbc2500u1pvjluez\""

// --- the JSON body dialect ------------------------------------------------

pub fn json_body_challenge_parses_test() {
  let headers = [#("content-type", "application/json; charset=utf-8")]
  let body =
    "{\"invoice\":\"lnbc1pvjluez\",\"macaroon\":\"AGIAJEemVQ\","
    <> "\"amount_sat\":42,\"challenge_id\":\"c-7\",\"route_id\":\"r-9\"}"

  assert l402.parse(headers, body)
    == Ok(l402.Challenge(
      macaroon: "AGIAJEemVQ",
      invoice: "lnbc1pvjluez",
      amount_sat: Some(42),
      challenge_id: "c-7",
      route_id: "r-9",
    ))
}

pub fn json_body_without_macaroon_is_an_error_test() {
  let headers = [#("content-type", "application/json")]
  let assert Error(reason) = l402.parse(headers, "{\"invoice\":\"lnbc1x\"}")
  assert reason == "the 402 body carried no macaroon"
}

pub fn json_body_price_falls_back_to_the_invoice_test() {
  let headers = [#("content-type", "application/json")]
  let body = "{\"invoice\":\"lnbc2500u1pvjluez\",\"macaroon\":\"AGIA\"}"
  let assert Ok(challenge) = l402.parse(headers, body)

  assert challenge.amount_sat == Some(250_000)
  assert challenge.challenge_id == ""
}

pub fn a_body_that_is_not_json_is_an_error_test() {
  let headers = [#("content-type", "application/json")]
  let assert Error(reason) = l402.parse(headers, "<html>nope</html>")
  assert reason == "the 402 body was not the JSON it declared"
}

// --- the header dialect ---------------------------------------------------

pub fn header_challenge_parses_test() {
  let headers = [
    #("www-authenticate", header_challenge),
    #("x-aperture-challenge-id", "c-7"),
    #("x-aperture-route-id", "r-9"),
  ]

  assert l402.parse(headers, "")
    == Ok(l402.Challenge(
      macaroon: "AGIAJEemVQ",
      invoice: "lnbc2500u1pvjluez",
      amount_sat: Some(250_000),
      challenge_id: "c-7",
      route_id: "r-9",
    ))
}

pub fn legacy_lsat_scheme_word_parses_test() {
  let legacy = [
    #("www-authenticate", "LSAT macaroon=\"AGIA\", invoice=\"lnbc1m1x\""),
  ]
  let assert Ok(challenge) = l402.parse(legacy, "")

  assert challenge.macaroon == "AGIA"
  assert challenge.amount_sat == Some(100_000)
}

pub fn stated_header_price_wins_over_the_invoice_test() {
  // The proxy prices the route above the invoice it minted, and the buyer
  // is being asked for the proxy's figure.
  let headers = [
    #("www-authenticate", header_challenge),
    #("x-aperture-price-sat", "300000"),
  ]
  let assert Ok(challenge) = l402.parse(headers, "")

  assert challenge.amount_sat == Some(300_000)
}

pub fn a_challenge_in_another_scheme_is_an_error_test() {
  let headers = [#("www-authenticate", "Bearer realm=\"api\"")]
  let assert Error(reason) = l402.parse(headers, "")
  assert reason == "the response did not carry an L402 challenge"
}

pub fn a_challenge_without_an_invoice_is_an_error_test() {
  let headers = [#("www-authenticate", "L402 macaroon=\"AGIA\"")]
  let assert Error(reason) = l402.parse(headers, "")
  assert reason == "the L402 challenge carried no invoice"
}

pub fn no_challenge_at_all_is_an_error_test() {
  assert l402.parse([], "") == Error("no L402 challenge in the response")
}

// --- the BOLT11 amount prefix ---------------------------------------------

pub fn invoice_amount_reads_each_multiplier_test() {
  assert l402.invoice_amount_sat("lnbc2500u1pvjluez") == Some(250_000)
  assert l402.invoice_amount_sat("lnbc1m1pvjluez") == Some(100_000)
  assert l402.invoice_amount_sat("lnbcrt10n1pvjluez") == Some(1)
  assert l402.invoice_amount_sat("lntb20m1pvjluez") == Some(2_000_000)
  assert l402.invoice_amount_sat("lnbc21pvjluez") == Some(200_000_000)
}

pub fn sub_satoshi_amounts_have_no_price_test() {
  // A trillionth of a bitcoin is a ten-thousandth of a satoshi, and
  // rounding it to a figure nobody agreed to pay would be worse than
  // saying the invoice states no price this package can use.
  assert l402.invoice_amount_sat("lnbc1p1pvjluez") == None
  assert l402.invoice_amount_sat("lnbc5n1pvjluez") == None
}

pub fn an_amountless_invoice_has_no_price_test() {
  assert l402.invoice_amount_sat("lnbc1pvjluez") == None
}

pub fn an_uppercase_invoice_still_reads_its_amount_test() {
  assert l402.invoice_amount_sat("LNBC2500U1PVJLUEZ") == Some(250_000)
}

pub fn an_unknown_prefix_has_no_price_test() {
  assert l402.invoice_amount_sat("xyz2500u1pvjluez") == None
  assert l402.invoice_amount_sat("lnbc2500z1pvjluez") == None
  assert l402.invoice_amount_sat("not-an-invoice") == None
}

// --- the credential -------------------------------------------------------

pub fn authorization_renders_the_credential_test() {
  assert l402.authorization("AGIAJEemVQ", "ab12cd34")
    == "L402 AGIAJEemVQ:ab12cd34"
}
