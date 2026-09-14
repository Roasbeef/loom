//// The harness's payment seam, driven with a real hook bus over fake
//// invokers.
////
//// The bus is the genuine one because the property under test is a
//// composition — a challenge goes out as a hook, a preimage comes back,
//// and the credential the gateway is handed is composed from that
//// preimage and the macaroon the harness kept. A stubbed bus would let
//// the composition be asserted against itself.

import client/extension/hooks
import client/paywall
import core/clock
import core/msgpack
import gleam/option.{None, Some}
import gleeunit
import provider/l402
import provider/paywall as provider_paywall
import telemetry/log

pub fn main() -> Nil {
  gleeunit.main()
}

// A preimage is 64 lowercase hex characters, and every test that needs a
// valid one uses this so a change to the rule has one place to land.
const preimage = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

pub fn a_settled_challenge_is_cached_for_the_next_attempt_test() {
  let seam = seam_over([paying(preimage)])

  // Nothing has been settled, so the gateway's pre-attempt question has
  // no answer and the first request goes out unauthenticated.
  assert seam.credential("proxy") == None

  // The credential is composed here rather than by the extension: the
  // macaroon never crossed the hook, so this is the only side that could
  // have built it.
  assert seam.settle("proxy", challenge()) == Ok("L402 AGIA:" <> preimage)
  assert seam.credential("proxy") == Some("L402 AGIA:" <> preimage)
}

pub fn a_token_is_kept_per_provider_test() {
  let seam = seam_over([paying(preimage)])
  let assert Ok(_token) = seam.settle("proxy", challenge())
    as "the extension pays"

  // One paywalled entry's credential is not another's: the proxies are
  // different endpoints with different macaroons.
  assert seam.credential("other") == None
}

pub fn a_session_with_no_bus_declines_test() {
  let assert Ok(cache) = paywall.start_cache() as "the cache starts"
  let assert Ok(slot) = paywall.slot() as "the slot starts"
  let seam = paywall.seam(cache, slot, clock.fixed(0))

  // The slot was never attached, which is what a session with no
  // installed extension looks like. The reason is worded for an operator
  // reading a failed request, because that is where it lands.
  assert seam.settle("proxy", challenge()) == Error(paywall.no_extension_reason)
}

pub fn a_declining_extension_reaches_the_gateway_in_its_own_words_test() {
  let seam = seam_over([declining("the daily ceiling is spent")])
  assert seam.settle("proxy", challenge())
    == Error("the daily ceiling is spent")

  // A decline settles nothing, so the next attempt must not be handed a
  // credential nobody bought.
  assert seam.credential("proxy") == None
}

// --- fixtures -------------------------------------------------------------

// A seam over a started bus already attached to its slot, which is the
// state a session reaches the instant `with_extension_hooks` runs.
fn seam_over(extensions: List(hooks.Extension)) -> provider_paywall.Paywall {
  let assert Ok(cache) = paywall.start_cache() as "the cache starts"
  let assert Ok(slot) = paywall.slot() as "the slot starts"
  let assert Ok(bus) = hooks.start(extensions, log.discard())
    as "the bus must start"
  paywall.attach(slot, bus)
  paywall.seam(cache, slot, clock.fixed(0))
}

fn paying(hex: String) -> hooks.Extension {
  answering("wallet", "{\"payment\":\"paid\",\"preimage\":\"" <> hex <> "\"}")
}

fn declining(reason: String) -> hooks.Extension {
  answering(
    "wallet",
    "{\"payment\":\"declined\",\"reason\":\"" <> reason <> "\"}",
  )
}

fn answering(name: String, text: String) -> hooks.Extension {
  hooks.Extension(
    name:,
    hooks: [
      hooks.Subscription(
        event: "payment_required",
        deadline_ms: hooks.deadline_ms,
      ),
    ],
    invoke: fn(_extension, _event, _args, _deadline) {
      Ok(msgpack.StringValue(text))
    },
  )
}

// A challenge whose macaroon is distinctive, so an assertion on the
// composed credential is an assertion that the macaroon survived the
// round trip it deliberately did not take.
fn challenge() -> l402.Challenge {
  l402.Challenge(
    macaroon: "AGIA",
    invoice: "lnbc2500u1xyz",
    amount_sat: Some(250_000),
    challenge_id: "chal-1",
    route_id: "route-1",
  )
}
