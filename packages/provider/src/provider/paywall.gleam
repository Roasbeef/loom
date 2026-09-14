//// The injected effect that turns an L402 challenge into a credential.
////
//// This boundary exists so the gateway can pay for a request without
//// knowing what paying means. Settling a challenge is a Lightning payment
//// — a wallet, a route, a preimage — and none of that belongs in a
//// package whose job is to speak three HTTP dialects. The gateway holds a
//// `Paywall` the way it holds a `Transport`, a `SecretStore` and a
//// `Clock`: two injected functions, with the real implementation supplied
//// by whoever assembled the gateway and a declining default when nobody
//// did.
////
//// The two functions divide the work by when they run. `credential` runs
//// before every attempt on a paywalled entry and answers with a token the
//// paywall has already settled, so a session that has paid once does not
//// provoke a fresh 402 on every turn. `settle` runs only after a 402 has
//// actually arrived, and is the one that spends money. Keeping the cache
//// behind `credential` rather than inside the gateway is deliberate: the
//// paywall knows when a macaroon's caveats expire and the gateway does
//// not, so a gateway-side cache could only guess.
////
//// Neither function is given a process or a deadline here. `settle` is
//// called from the gateway's own pump process and blocks it, which is the
//// same arrangement `secret.lookup` already has; a paywall that can take
//// arbitrarily long owes its own bound.

import gleam/option.{type Option, None}
import provider/l402.{type Challenge}

/// How a gateway pays for a priced request.
///
/// Constructor invariants: both functions take the provider's registry
/// name as their first argument, so one paywall can serve a gateway with
/// several paywalled entries without conflating their credentials;
/// `credential` returns the full `Authorization` header value, not a bare
/// macaroon, and `settle` returns the same shape — in both cases exactly
/// what `l402.authorization` builds. `settle`'s `Error` is the paywall's
/// own text explaining why it declined, and reaches the caller in-band as
/// `stream.PaymentDeclined`, so it must name a reason a human can act on
/// and must not carry a preimage or a macaroon.
pub type Paywall {
  Paywall(
    /// The token already settled for this provider, if any.
    credential: fn(String) -> Option(String),
    /// Pays one challenge, returning the credential or a reason.
    settle: fn(String, Challenge) -> Result(String, String),
  )
}

/// The default paywall: it holds no credential and declines every
/// challenge.
///
/// This is what `gateway.new` installs, so an entry configured with
/// `gateway.L402` fails in band with a legible reason rather than hanging,
/// crashing, or silently sending an unauthenticated request forever. The
/// extension that settles challenges for real is a later work package;
/// until it is wired, declining is the honest answer.
///
/// ## Examples
///
/// ```gleam
/// let wall = paywall.none()
/// assert wall.credential("proxy") == option.None
/// ```
///
/// ```gleam
/// let challenge = l402.Challenge("AGIA", "lnbc1m1x", option.None, "", "")
/// let assert Error(reason) = paywall.none().settle("proxy", challenge)
/// assert reason == "no paywall is wired for this gateway"
/// ```
///
pub fn none() -> Paywall {
  Paywall(credential: fn(_provider) { None }, settle: fn(_provider, _challenge) {
    Error("no paywall is wired for this gateway")
  })
}
