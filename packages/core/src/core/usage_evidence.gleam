//// Evidence behind token counts and dollar estimates.
////
//// Numeric zero does not establish that a provider consumed nothing. `none`
//// is the local identity before dispatch; `unknown`, `reported` and `partial`
//// describe remote observations. `with_price` records the basis of an estimate
//// without inventing subscription credits. `add` retains missing observations
//// when requests or fallback attempts are aggregated.
////
//// The types make the impossible claims unrepresentable. Only a remote
//// observation has a billing arrangement, so the local identity cannot be
//// mistaken for missing remote usage. Only reported tokens have a cost, so an
//// unknown observation cannot carry a rate basis. The stored form still
//// writes the local identity as a billing and as a cost, and `decode`
//// refuses any combination of those fields that the types cannot express.

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// How completely a reported observation accounts for the quantity it
/// describes. Having no observation at all is `Unreported`, not a coverage.
pub type Coverage {
  /// Some observation exists, but one or more parts remain unreported.
  Partial

  /// Every contributing observation has the required partition information.
  Complete
}

/// The arrangement under which a remote observation was produced.
pub type Billing {
  /// Ordinary provider API usage.
  Api

  /// Usage charged to a ChatGPT plan, with no inferred credit conversion.
  ChatGptPlan

  /// A provider arrangement whose billing scope is unknown here, or
  /// observations from more than one arrangement. Readers treat both the
  /// same way, so the type does not tell them apart.
  Other
}

/// The source of rates used for a dollar estimate.
pub type PriceBasis {
  /// Configured rates for an ordinary API request.
  ApiRates

  /// API rates used only as a reference for ChatGPT plan inference.
  ChatGptReferenceRates

  /// Estimates whose rates have more than one basis.
  MixedRates
}

/// Whether reported tokens have a dollar estimate.
pub type Cost {
  /// Pricing is unavailable; this carries no invented rate basis.
  Unpriced

  /// A dollar estimate, with coverage independent from token coverage.
  Priced(
    /// Whether rates were available for every contributing observation.
    coverage: Coverage,
    /// The kind of rate card, never an estimate of plan credits.
    basis: PriceBasis,
  )
}

/// What a remote attempt reported about its token usage.
pub type Tokens {
  /// No usable observation was reported, so there is nothing to price.
  Unreported

  /// A token partition with its coverage and the estimate made from it.
  Reported(coverage: Coverage, cost: Cost)
}

/// Token coverage, billing scope and cost evidence for one observation.
pub type Evidence {
  /// No provider was contacted: the local addition identity, which has no
  /// billing arrangement and no provider expense.
  NoProvider

  /// A remote observation under a named billing arrangement.
  Remote(billing: Billing, tokens: Tokens)
}

/// Establishes that no provider work has occurred.
///
/// ## Examples
///
/// ```gleam
/// assert usage_evidence.none() == usage_evidence.NoProvider
/// ```
pub fn none() -> Evidence {
  NoProvider
}

/// Marks a remote attempt whose usage was not reported.
///
/// ## Examples
///
/// ```gleam
/// assert usage_evidence.unknown(usage_evidence.Api)
///   == usage_evidence.Remote(usage_evidence.Api, usage_evidence.Unreported)
/// ```
pub fn unknown(billing: Billing) -> Evidence {
  Remote(billing, Unreported)
}

/// Marks a complete remote token partition, before pricing is applied.
///
/// ## Examples
///
/// ```gleam
/// assert usage_evidence.reported(usage_evidence.Api)
///   == usage_evidence.Remote(
///     usage_evidence.Api,
///     usage_evidence.Reported(usage_evidence.Complete, usage_evidence.Unpriced),
///   )
/// ```
pub fn reported(billing: Billing) -> Evidence {
  Remote(billing, Reported(Complete, Unpriced))
}

/// Marks a snapshot or a remote observation with an incomplete partition.
///
/// ## Examples
///
/// ```gleam
/// assert usage_evidence.partial(usage_evidence.Api)
///   == usage_evidence.Remote(
///     usage_evidence.Api,
///     usage_evidence.Reported(usage_evidence.Partial, usage_evidence.Unpriced),
///   )
/// ```
pub fn partial(billing: Billing) -> Evidence {
  Remote(billing, Reported(Partial, Unpriced))
}

/// Applies configured rates without inventing usage that was not reported.
/// Explicit zero rates still establish an estimate; missing rates do not.
/// The estimate covers exactly the tokens that were reported.
///
/// ## Examples
///
/// ```gleam
/// let evidence = usage_evidence.reported(usage_evidence.Api)
/// assert usage_evidence.with_price(evidence, usage_evidence.ApiRates)
///   == usage_evidence.Remote(
///     usage_evidence.Api,
///     usage_evidence.Reported(
///       usage_evidence.Complete,
///       usage_evidence.Priced(usage_evidence.Complete, usage_evidence.ApiRates),
///     ),
///   )
/// ```
pub fn with_price(evidence: Evidence, basis: PriceBasis) -> Evidence {
  case evidence {
    Remote(billing, Reported(coverage, _)) ->
      Remote(billing, Reported(coverage, Priced(coverage, basis)))
    NoProvider | Remote(_, Unreported) -> evidence
  }
}

/// A complete remote token partition priced at configured API rates, under
/// an unspecified billing arrangement. Synthetic records, demos and fixtures
/// use it when they need a settled response with a complete estimate.
///
/// ## Examples
///
/// ```gleam
/// assert usage_evidence.priced_api()
///   == usage_evidence.with_price(
///     usage_evidence.reported(usage_evidence.Other),
///     usage_evidence.ApiRates,
///   )
/// ```
pub fn priced_api() -> Evidence {
  with_price(reported(Other), ApiRates)
}

/// Adds two observations, retaining incomplete token and price evidence.
/// The local no-provider value is an identity rather than a missing attempt.
///
/// ## Examples
///
/// ```gleam
/// let evidence = usage_evidence.reported(usage_evidence.Api)
/// assert usage_evidence.add(usage_evidence.none(), evidence) == evidence
/// ```
pub fn add(left: Evidence, right: Evidence) -> Evidence {
  case left, right {
    NoProvider, _ -> right
    _, NoProvider -> left
    Remote(left_billing, left_tokens), Remote(right_billing, right_tokens) ->
      Remote(
        case left_billing == right_billing {
          True -> left_billing
          False -> Other
        },
        combine_tokens(left_tokens, right_tokens),
      )
  }
}

/// Encodes the evidence independently of numeric usage fields. The local
/// identity is written as complete tokens with a no-provider billing and a
/// no-expense cost, the form earlier builds stored.
///
/// ## Examples
///
/// ```gleam
/// let evidence = usage_evidence.none()
/// assert usage_evidence.decode(usage_evidence.encode(evidence)) == Ok(evidence)
/// ```
pub fn encode(evidence: Evidence) -> JsonValue {
  let #(tokens, billing, cost) = case evidence {
    NoProvider -> #("complete", "no-provider", encode_kind("no-expense"))
    Remote(billing, Unreported) -> #(
      "unknown",
      billing_name(billing),
      encode_kind("unavailable"),
    )
    Remote(billing, Reported(coverage, cost)) -> #(
      coverage_name(coverage),
      billing_name(billing),
      encode_cost(cost),
    )
  }
  json.Object([
    #("version", json.Int(1)),
    #("tokens", json.String(tokens)),
    #("billing", json.String(billing)),
    #("cost", cost),
  ])
}

/// Decodes exactly the supported evidence shape, refusing malformed claims.
/// Unknown coverage cannot carry an estimate, and no expense belongs only to
/// the complete local no-provider identity.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = usage_evidence.decode(json.Null)
/// ```
pub fn decode(value: JsonValue) -> Result(Evidence, CorruptionReport) {
  use fields <- result.try(
    exact_fields(value, ["version", "tokens", "billing", "cost"]),
  )
  use version <- result.try(field(fields, "version"))
  use <- bool.lazy_guard(version != json.Int(1), fn() {
    invalid("version", "1")
  })
  use tokens <- result.try(field(fields, "tokens"))
  use tokens <- result.try(decode_tokens(tokens))
  use billing <- result.try(field(fields, "billing"))
  use billing <- result.try(decode_billing(billing))
  use cost <- result.try(field(fields, "cost"))
  use cost <- result.try(decode_cost(cost))
  assemble(tokens, billing, cost)
}

// The stored form spells the local identity twice, as a billing and as a
// cost, and spells unreported tokens as a coverage. `None` stands for each of
// those spellings, and only the combinations the types express are accepted.
fn assemble(
  tokens: Option(Coverage),
  billing: Option(Billing),
  cost: Option(Cost),
) -> Result(Evidence, CorruptionReport) {
  case billing, tokens, cost {
    None, Some(Complete), None -> Ok(NoProvider)
    Some(billing), None, Some(Unpriced) -> Ok(Remote(billing, Unreported))
    Some(billing), Some(coverage), Some(Unpriced) ->
      Ok(Remote(billing, Reported(coverage, Unpriced)))

    // An estimate over partial tokens cannot claim every observation was
    // priced, because the unreported part had no rate to apply.
    Some(_), Some(Partial), Some(Priced(Complete, _)) ->
      invalid("cost", "an estimate no more complete than its tokens")
    Some(billing), Some(coverage), Some(Priced(_, _) as cost) ->
      Ok(Remote(billing, Reported(coverage, cost)))
    None, _, _ | Some(_), None, Some(Priced(_, _)) | Some(_), _, None ->
      invalid("evidence", "a consistent observation and estimate")
  }
}

fn combine_tokens(left: Tokens, right: Tokens) -> Tokens {
  case left, right {
    Unreported, Unreported -> Unreported
    Unreported, Reported(_, cost) | Reported(_, cost), Unreported ->
      Reported(Partial, partial_cost(cost))
    Reported(left_coverage, left_cost), Reported(right_coverage, right_cost) ->
      Reported(
        combine_coverage(left_coverage, right_coverage),
        combine_cost(left_cost, right_cost),
      )
  }
}

fn combine_coverage(left: Coverage, right: Coverage) -> Coverage {
  case left, right {
    Complete, Complete -> Complete
    Partial, Partial | Partial, Complete | Complete, Partial -> Partial
  }
}

// An attempt that reported nothing has no rate to apply, so any estimate it
// joins can cover only part of the total.
fn partial_cost(cost: Cost) -> Cost {
  case cost {
    Unpriced -> Unpriced
    Priced(_, basis) -> Priced(Partial, basis)
  }
}

fn combine_cost(left: Cost, right: Cost) -> Cost {
  case left, right {
    Unpriced, Unpriced -> Unpriced
    Unpriced, priced | priced, Unpriced -> partial_cost(priced)
    Priced(left_coverage, left_basis), Priced(right_coverage, right_basis) ->
      Priced(
        combine_coverage(left_coverage, right_coverage),
        case left_basis == right_basis {
          True -> left_basis
          False -> MixedRates
        },
      )
  }
}

fn coverage_name(coverage: Coverage) -> String {
  case coverage {
    Partial -> "partial"
    Complete -> "complete"
  }
}

fn billing_name(billing: Billing) -> String {
  case billing {
    Api -> "api"
    ChatGptPlan -> "chatgpt-plan"
    Other -> "other"
  }
}

fn encode_kind(kind: String) -> JsonValue {
  json.Object([#("kind", json.String(kind))])
}

fn encode_cost(cost: Cost) -> JsonValue {
  case cost {
    Unpriced -> encode_kind("unavailable")
    Priced(coverage, basis) ->
      json.Object([
        #("kind", json.String("estimated")),
        #("coverage", json.String(coverage_name(coverage))),
        #("basis", json.String(basis_name(basis))),
      ])
  }
}

fn basis_name(basis: PriceBasis) -> String {
  case basis {
    ApiRates -> "api-rates"
    ChatGptReferenceRates -> "chatgpt-reference-rates"
    MixedRates -> "mixed-rates"
  }
}

// `None` is the stored word for tokens nobody reported.
fn decode_tokens(
  value: JsonValue,
) -> Result(Option(Coverage), CorruptionReport) {
  case value {
    json.String("unknown") -> Ok(None)
    json.String("partial") -> Ok(Some(Partial))
    json.String("complete") -> Ok(Some(Complete))
    _ -> invalid("coverage", "unknown, partial or complete")
  }
}

fn decode_coverage(value: JsonValue) -> Result(Coverage, CorruptionReport) {
  case value {
    json.String("partial") -> Ok(Partial)
    json.String("complete") -> Ok(Complete)
    _ -> invalid("coverage", "partial or complete")
  }
}

// `None` is the stored no-provider arrangement.
fn decode_billing(
  value: JsonValue,
) -> Result(Option(Billing), CorruptionReport) {
  case value {
    json.String("api") -> Ok(Some(Api))
    json.String("chatgpt-plan") -> Ok(Some(ChatGptPlan))
    json.String("other") -> Ok(Some(Other))
    json.String("no-provider") -> Ok(None)

    // Earlier builds wrote a separate `mixed` arrangement that no reader
    // distinguished from `other`; both forms read as the merged value.
    json.String("mixed") -> Ok(Some(Other))
    _ -> invalid("billing", "a supported billing arrangement")
  }
}

// `None` is the stored no-expense cost.
fn decode_cost(value: JsonValue) -> Result(Option(Cost), CorruptionReport) {
  use fields <- result.try(object_fields(value))
  use kind <- result.try(field(fields, "kind"))
  case kind {
    json.String("unavailable") -> {
      use _ <- result.try(exact_fields(value, ["kind"]))
      Ok(Some(Unpriced))
    }
    json.String("no-expense") -> {
      use _ <- result.try(exact_fields(value, ["kind"]))
      Ok(None)
    }
    json.String("estimated") -> {
      use fields <- result.try(
        exact_fields(value, ["kind", "coverage", "basis"]),
      )
      use coverage <- result.try(field(fields, "coverage"))
      use coverage <- result.try(decode_coverage(coverage))
      use basis <- result.try(field(fields, "basis"))
      use basis <- result.try(decode_basis(basis))
      Ok(Some(Priced(coverage, basis)))
    }
    _ -> invalid("cost", "unavailable, no-expense or estimated")
  }
}

fn decode_basis(value: JsonValue) -> Result(PriceBasis, CorruptionReport) {
  case value {
    json.String("api-rates") -> Ok(ApiRates)
    json.String("chatgpt-reference-rates") -> Ok(ChatGptReferenceRates)
    json.String("mixed-rates") -> Ok(MixedRates)
    _ -> invalid("basis", "a supported rate basis")
  }
}

fn exact_fields(
  value: JsonValue,
  expected: List(String),
) -> Result(List(#(String, JsonValue)), CorruptionReport) {
  use fields <- result.try(object_fields(value))
  use <- bool.lazy_guard(
    list.sort(list.map(fields, fn(field) { field.0 }), string.compare)
      != list.sort(expected, string.compare),
    fn() { invalid("fields", "exactly the supported version's fields") },
  )
  Ok(fields)
}

fn object_fields(
  value: JsonValue,
) -> Result(List(#(String, JsonValue)), CorruptionReport) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Null
    | json.Bool(_)
    | json.Int(_)
    | json.Float(_)
    | json.String(_)
    | json.Array(_) -> invalid("value", "an object")
  }
}

fn field(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(JsonValue, CorruptionReport) {
  list.key_find(fields, name)
  |> result.map_error(fn(_) { report(name, "a present field") })
}

fn invalid(subject: String, expected: String) -> Result(a, CorruptionReport) {
  Error(report(subject, expected))
}

fn report(subject: String, expected: String) -> CorruptionReport {
  corruption.report(
    at: "core/usage_evidence.decode",
    on: subject,
    expected:,
    context: "invalid usage evidence",
  )
}
