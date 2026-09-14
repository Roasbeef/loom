//// The injected effect that turns an HTTP authentication challenge into
//// the headers to retry with.
////
//// This boundary exists so the gateway can satisfy a challenge without
//// knowing what satisfying one means. A provider that answers 401, 402 or
//// 407 is asking for something the harness has no vocabulary for — a
//// token bought from a vending machine, a coin spent on a wire the
//// harness does not speak, a signature over the request — and none of
//// that belongs in a package whose job is to speak three HTTP dialects. The gateway holds a `Challenger` the way
//// it holds a `Transport`, a `SecretStore` and a `Clock`: two injected
//// functions, with the real implementation supplied by whoever assembled
//// the gateway and a declining default when nobody did.
////
//// Nothing here parses a challenge. The status, the response headers and
//// the body travel verbatim to whoever answers, because the grammar of a
//// challenge belongs to the scheme rather than to the harness, and a
//// harness that learned one scheme would have to learn the next one too.
//// What comes back is equally opaque: a list of headers to send, which
//// the adapter renders after its own.
////
//// The two functions divide the work by when they run. `headers` is
//// asked before *every* attempt on an extension-authenticated entry, and
//// whatever it answers is what is sent; nothing is remembered on this
//// side, so a provider asked twice is asked of the challenger twice.
//// `answer` runs only after a challenge has actually arrived, and is the
//// one that may spend something.
////
//// That the harness holds no cache is the ruling rather than an
//// omission. Whoever satisfies a challenge is the only party that knows
//// what it bought, which entry and model it bought it for, and when it
//// stops being worth anything; a copy kept here could only guess at all
//// three, and would go on presenting a dead credential after the
//// answerer had already replaced it. So `headers` takes the provider and
//// the model — a proxy that prices per model hands out a token per model
//// — and the answerer decides on every call.
////
//// Neither function is given a process or a deadline here. `answer` is
//// called from the gateway's own pump process and blocks it, which is the
//// same arrangement `secret.lookup` already has; an answerer that can
//// take arbitrarily long owes its own bound.

import gleam/option.{type Option, None}

/// One HTTP authentication challenge, exactly as the response carried it.
///
/// Constructor invariants: `status` is 401, 402 or 407 — the three HTTP
/// statuses that mean "authenticate and try again"; `headers` are the
/// response headers with lowercase names, as the transport normalizes
/// them; `body` is the response body bounded to the adapter's error-body
/// budget, and is `""` when the response carried none. Nothing in this
/// package interprets any of the three.
pub type Challenge {
  Challenge(
    /// The HTTP status the provider challenged with.
    status: Int,
    /// The response headers, lowercase-named, verbatim.
    headers: List(#(String, String)),
    /// The response body, verbatim within the byte budget.
    body: String,
  )
}

/// How a gateway answers a challenge from a provider.
///
/// Constructor invariants: both functions take the provider's registry
/// name as their first argument, so one challenger can serve a gateway
/// with several challenged entries without conflating their credentials,
/// and `headers` takes the target's model beside it for the same reason
/// one step down; both return complete header pairs, ready to send, with
/// lowercase names. `answer`'s `Error` is the answerer's own text explaining why it
/// declined, and reaches the caller in-band as
/// `stream.ChallengeUnanswered`, so it must name a reason a human can act
/// on and must not carry any part of the credential it failed to obtain.
pub type Challenger {
  Challenger(
    /// The headers to send on the next attempt against this provider
    /// and model, asked before every one of them. `None` is "send
    /// none", which is how an unauthenticated request provokes the
    /// endpoint into stating its terms.
    headers: fn(String, String) -> Option(List(#(String, String))),
    /// Answers one challenge: the headers to retry with, or a reason.
    answer: fn(String, Challenge) -> Result(List(#(String, String)), String),
  )
}

/// The default challenger: it holds no headers and answers nothing.
///
/// This is what `gateway.new` installs, so an entry configured with
/// `gateway.Extension` fails in band with a legible reason rather than
/// hanging, crashing, or silently sending an unauthenticated request
/// forever. The extension that answers challenges for real is wired by
/// the harness that loaded it; until it is, declining is the honest
/// answer.
///
/// ## Examples
///
/// ```gleam
/// let seam = challenger.none()
/// assert seam.headers("proxy", "model-a") == option.None
/// ```
///
/// ```gleam
/// let challenge = challenger.Challenge(402, [], "")
/// let assert Error(reason) = challenger.none().answer("proxy", challenge)
/// assert reason == "no challenger is wired for this gateway"
/// ```
///
pub fn none() -> Challenger {
  Challenger(
    headers: fn(_provider, _model_id) { None },
    answer: fn(_provider, _challenge) {
      Error("no challenger is wired for this gateway")
    },
  )
}
