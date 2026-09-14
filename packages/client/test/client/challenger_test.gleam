//// The harness's credential seam, driven with a real hook bus over fake
//// invokers.
////
//// The bus is the genuine one because the property under test is a
//// composition — the gateway's pre-request question becomes a
//// `provider_request` hook, its challenge becomes a `provider_challenge`
//// hook, and the headers each answers with are what the gateway is
//// handed. A stubbed bus would let the composition be asserted against
//// itself.
////
//// The one thing counted rather than composed is how often the
//// extension is asked, and that is the ruling under test: the harness
//// holds no credential, so every attempt is a question and an answer to
//// a challenge is not written down anywhere on this side.

import client/challenger
import client/extension/hooks
import core/clock
import core/msgpack
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleeunit
import provider/challenger as provider_challenger
import telemetry/log

pub fn main() -> Nil {
  gleeunit.main()
}

// The headers a challenge is answered with, in one place so a test that
// asserts on the answer and a test that asserts on what was sent cannot
// drift apart.
const answered = [#("authorization", "Scheme token")]

// The headers a `provider_request` hook supplies, distinct from
// `answered` so a test can tell which of the two hooks a value came
// from.
const supplied = [#("authorization", "Scheme recalled")]

pub fn the_pre_request_headers_come_from_the_bus_test() {
  let seam = seam_over([holding()])

  // The extension holds a credential and says so; the harness sends what
  // it was told and has nothing of its own to consult.
  assert seam.headers("proxy", "model-a") == Some(supplied)
}

pub fn an_extension_holding_nothing_sends_no_headers_test() {
  let seam = seam_over([holding_nothing()])

  // An empty answer and no answer are one fact to the gateway: there is
  // nothing to add to the adapter's own headers, and the provider will
  // state its terms in the challenge that follows.
  assert seam.headers("proxy", "model-a") == None
}

pub fn an_unattached_slot_supplies_no_headers_test() {
  let assert Ok(slot) = challenger.slot() as "the slot starts"
  let seam = challenger.seam(slot, clock.fixed(0))

  // The slot was never filled, which is what a session with no installed
  // extension looks like. A request with no credential is an ordinary
  // request, so this is `None` rather than a failure.
  assert seam.headers("proxy", "model-a") == None
}

pub fn an_answered_challenge_is_not_remembered_here_test() {
  let asked = process.new_subject()
  let seam = seam_over([holding_and_answering(asked)])

  assert seam.answer("proxy", challenge()) == Ok(answered)

  // The answer was returned and nothing was kept: the next attempt is
  // another question to the extension, which is the half of the seam
  // that owns the durable copy. Two asks rather than one cache hit is
  // the observable form of that ruling.
  assert seam.headers("proxy", "model-a") == Some(supplied)
  assert seam.headers("proxy", "model-a") == Some(supplied)
  assert process.receive(asked, within: 100) == Ok(Nil)
  assert process.receive(asked, within: 100) == Ok(Nil)
  assert process.receive(asked, within: 100) == Error(Nil)
}

pub fn a_session_with_no_bus_declines_test() {
  let assert Ok(slot) = challenger.slot() as "the slot starts"
  let seam = challenger.seam(slot, clock.fixed(0))

  // The reason is worded for an operator reading a failed request,
  // because that is where it lands.
  assert seam.answer("proxy", challenge())
    == Error(challenger.no_extension_reason)
}

pub fn a_declining_extension_reaches_the_gateway_in_its_own_words_test() {
  let seam = seam_over([declining("the daily ceiling is spent")])
  assert seam.answer("proxy", challenge())
    == Error("the daily ceiling is spent")
}

// --- fixtures -------------------------------------------------------------

// A seam over a started bus already attached to its slot, which is the
// state a session reaches the instant `with_extension_hooks` runs.
fn seam_over(
  extensions: List(hooks.Extension),
) -> provider_challenger.Challenger {
  let assert Ok(bus) = hooks.start(extensions, log.discard())
    as "the bus must start"
  let assert Ok(slot) = challenger.slot() as "the slot starts"
  challenger.attach(slot, bus)
  challenger.seam(slot, clock.fixed(0))
}

// An extension that recalls a credential on every request.
fn holding() -> hooks.Extension {
  both("wallet", supplying(), fn() { Nil })
}

// An extension that holds nothing yet, which is what a wallet answers
// before it has paid for anything.
fn holding_nothing() -> hooks.Extension {
  both("wallet", "{\"headers\":[]}", fn() { Nil })
}

// An extension that answers both halves, and reports each request it is
// asked about so a test can count them.
fn holding_and_answering(asked: Subject(Nil)) -> hooks.Extension {
  both("wallet", supplying(), fn() { process.send(asked, Nil) })
}

fn declining(reason: String) -> hooks.Extension {
  both("wallet", supplying(), fn() { Nil })
  |> refusing(reason)
}

fn supplying() -> String {
  "{\"headers\":[[\"authorization\",\"Scheme recalled\"]]}"
}

// One extension subscribed to both halves of the seam, answering each
// with the document its event calls for. The `note` runs on every
// `provider_request`, which is how a test counts the asks the harness
// makes.
fn both(
  name: String,
  request_answer: String,
  note: fn() -> Nil,
) -> hooks.Extension {
  hooks.Extension(
    name:,
    hooks: [
      hooks.Subscription(
        event: "provider_request",
        deadline_ms: hooks.deadline_ms,
      ),
      hooks.Subscription(
        event: "provider_challenge",
        deadline_ms: hooks.deadline_ms,
      ),
    ],
    invoke: fn(_extension, event, _args, _deadline) {
      case event {
        "provider_request" -> {
          note()
          Ok(msgpack.StringValue(request_answer))
        }

        _other ->
          Ok(msgpack.StringValue(
            "{\"answer\":\"retry\","
            <> "\"headers\":[[\"authorization\",\"Scheme token\"]]}",
          ))
      }
    },
  )
}

// The same extension with its challenge half turned into a decline.
fn refusing(extension: hooks.Extension, reason: String) -> hooks.Extension {
  let inner = extension.invoke
  hooks.Extension(..extension, invoke: fn(name, event, args, deadline) {
    case event {
      "provider_challenge" ->
        Ok(msgpack.StringValue(
          "{\"answer\":\"declined\",\"reason\":\"" <> reason <> "\"}",
        ))

      _other -> inner(name, event, args, deadline)
    }
  })
}

// A challenge whose header is distinctive, so an assertion about what
// the extension was handed is an assertion about real content.
fn challenge() -> provider_challenger.Challenge {
  provider_challenger.Challenge(
    status: 402,
    headers: [#("www-authenticate", "Scheme realm=\"proxy\"")],
    body: "",
  )
}
