//// Constant-space accounting for one provider request.
////
//// A fallback walk may spend tokens before its final attempt. `append` adds
//// each attempt once, retaining only an aggregate and the last observation.
//// A provider's repeated usage snapshots replace that attempt's observation
//// before append; this module never receives those snapshots as new attempts.
////
//// The assistant message keeps final-response usage for context estimation.
//// The ledger keeps `total`, while `details` and `decode_row` carry the final
//// observation separately through the existing durable details field, next to
//// whatever other fields the row's owner records there.

import core/codec
import core/corruption.{type CorruptionReport}
import core/entry
import core/json.{type JsonValue}
import core/message.{type Usage}
import core/usage_evidence
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The versioned ledger-details field owned by request accounting.
pub const namespace = "loom.request-accounting.v1"

/// One bounded request report, independent from the final assistant message.
pub opaque type RequestAccounting {
  /// No provider attempt has begun. This is the identity for `combine`.
  NoAttempts

  /// At least one attempt was appended. The aggregate and last observation
  /// are retained without an attempt list.
  Attempts(
    /// The sum of the observations actually retained by the request owner.
    total: Usage,
    /// The final attempt's observation, kept separate for context estimation.
    last: Usage,
    /// The number of distinct attempts appended by their owner, at least one.
    count: Int,
  )
}

/// Creates the identity before any provider attempt has begun.
///
/// ## Examples
///
/// ```gleam
/// assert accounting.attempts(accounting.empty()) == 0
/// ```
pub fn empty() -> RequestAccounting {
  NoAttempts
}

/// Records one attempt, including an unknown or explicitly zero observation.
///
/// ## Examples
///
/// ```gleam
/// assert accounting.last(accounting.from_usage(usage)) == Some(usage)
/// ```
pub fn from_usage(usage: Usage) -> RequestAccounting {
  Attempts(total: usage, last: usage, count: 1)
}

/// Adds exactly one completed attempt and replaces the final observation.
///
/// ## Examples
///
/// ```gleam
/// assert accounting.total(accounting.append(accounting.empty(), usage)) == usage
/// ```
pub fn append(report: RequestAccounting, usage: Usage) -> RequestAccounting {
  case report {
    NoAttempts -> from_usage(usage)
    Attempts(total:, count:, ..) ->
      Attempts(total: add_usage(total, usage), last: usage, count: count + 1)
  }
}

/// Combines disjoint request reports, taking the final observation from right.
/// The caller owns the guarantee that the two reports share no attempt.
///
/// ## Examples
///
/// ```gleam
/// let report = accounting.from_usage(usage)
/// assert accounting.combine(report, accounting.empty()) == report
/// ```
pub fn combine(
  left: RequestAccounting,
  right: RequestAccounting,
) -> RequestAccounting {
  case left, right {
    _, NoAttempts -> left
    NoAttempts, Attempts(..) -> right
    Attempts(total: left_total, count: left_count, ..),
      Attempts(total: right_total, last:, count: right_count)
    ->
      Attempts(
        total: add_usage(left_total, right_total),
        last:,
        count: left_count + right_count,
      )
  }
}

/// Reads all retained attempt usage without changing the final observation.
///
/// ## Examples
///
/// ```gleam
/// assert accounting.total(accounting.empty()) == accounting.zero_usage()
/// ```
pub fn total(report: RequestAccounting) -> Usage {
  case report {
    NoAttempts -> zero_usage()
    Attempts(total:, ..) -> total
  }
}

/// Reads the full final attempt, retaining billing and failure uncertainty.
/// Context and cache readers additionally select through `observed_usage`.
///
/// ## Examples
///
/// ```gleam
/// assert accounting.last(accounting.empty()) == None
/// ```
pub fn last(report: RequestAccounting) -> Option(Usage) {
  case report {
    NoAttempts -> None
    Attempts(last:, ..) -> Some(last)
  }
}

/// Selects usage that can measure context, cache behavior, or output rate.
/// An unknown all-zero snapshot establishes no token measurement. Reported
/// complete or partial zero remains observable, and historical unknown usage
/// with retained counters still supplies its original measurement.
///
/// ## Examples
///
/// ```gleam
/// let missing = message.Usage(..accounting.zero_usage(),
///   evidence: usage_evidence.unknown(usage_evidence.Api))
/// assert accounting.observed_usage(missing) == None
/// assert accounting.observed_usage(accounting.zero_usage())
///   == Some(accounting.zero_usage())
/// ```
pub fn observed_usage(usage: Usage) -> Option(Usage) {
  let unreported = case usage.evidence {
    usage_evidence.Remote(_, usage_evidence.Unreported) -> True
    usage_evidence.NoProvider
    | usage_evidence.Remote(_, usage_evidence.Reported(..)) -> False
  }
  case
    unreported
    && usage.input == 0
    && usage.output == 0
    && usage.cache_read == 0
    && usage.cache_write == 0
    && usage.total_tokens == 0
  {
    True -> None
    False -> Some(usage)
  }
}

/// Reads the number of observations, never the number of usage snapshots.
///
/// ## Examples
///
/// ```gleam
/// assert accounting.attempts(accounting.from_usage(usage)) == 1
/// ```
pub fn attempts(report: RequestAccounting) -> Int {
  case report {
    NoAttempts -> 0
    Attempts(count:, ..) -> count
  }
}

/// Adds disjoint usage buckets and their evidence in one shared operation.
/// Reasoning is a reported subset of output and is never charged a second time.
/// Optional subset counts sum only their reported observations.
///
/// ## Examples
///
/// ```gleam
/// assert accounting.add_usage(accounting.zero_usage(), usage) == usage
/// ```
pub fn add_usage(left: Usage, right: Usage) -> Usage {
  message.Usage(
    input: left.input + right.input,
    output: left.output + right.output,
    cache_read: left.cache_read + right.cache_read,
    cache_write: left.cache_write + right.cache_write,
    cache_write_1h: add_optional(left.cache_write_1h, right.cache_write_1h),
    reasoning: add_optional(left.reasoning, right.reasoning),
    total_tokens: left.total_tokens + right.total_tokens,
    cost: message.UsageCost(
      input: left.cost.input +. right.cost.input,
      output: left.cost.output +. right.cost.output,
      cache_read: left.cost.cache_read +. right.cost.cache_read,
      cache_write: left.cost.cache_write +. right.cost.cache_write,
      total: left.cost.total +. right.cost.total,
    ),
    evidence: usage_evidence.add(left.evidence, right.evidence),
  )
}

/// Establishes zero consumption before dispatch or for an empty aggregate.
/// Numeric zero after a remote attempt requires that attempt's own evidence.
///
/// ## Examples
///
/// ```gleam
/// assert accounting.zero_usage().evidence == usage_evidence.NoProvider
/// ```
pub fn zero_usage() -> Usage {
  message.Usage(
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 0,
    cost: message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
    evidence: usage_evidence.none(),
  )
}

/// Records a remote attempt whose usage was not reported. Every counter is
/// zero, but the evidence says the zeros are missing observations, so the
/// value never reads as proven no-expense.
///
/// ## Examples
///
/// ```gleam
/// let usage = accounting.unknown_usage(usage_evidence.Api)
/// assert usage.evidence == usage_evidence.unknown(usage_evidence.Api)
/// assert usage != accounting.zero_usage()
/// ```
pub fn unknown_usage(billing: usage_evidence.Billing) -> Usage {
  message.Usage(..zero_usage(), evidence: usage_evidence.unknown(billing))
}

/// Builds the ledger-details object for one request report: the caller's
/// own fields, such as the distillation phase, followed by the versioned
/// accounting namespace carrying the attempt count and final observation.
/// A row written without the namespace reads back as one historical
/// observation, so a caller with nothing else to record passes `[]`.
///
/// ## Examples
///
/// ```gleam
/// let details = accounting.details(accounting.empty(), [])
/// let phased =
///   accounting.details(accounting.empty(), [#("phase", json.String("summary"))])
/// assert details != phased
/// ```
pub fn details(
  report: RequestAccounting,
  extra: List(#(String, JsonValue)),
) -> JsonValue {
  let last = case last(report) {
    None -> json.Null
    Some(usage) -> codec.encode_usage(usage)
  }
  json.Object(
    list.append(extra, [
      #(
        namespace,
        json.Object([
          #("version", json.Int(1)),
          #("attempt_count", json.Int(attempts(report))),
          #("last", last),
        ]),
      ),
    ]),
  )
}

/// Reads accounting from a ledger row without treating absence as no expense.
/// A row without the accounting namespace is one observation of its existing
/// usage, whatever else its details hold. Present metadata is validated,
/// including the empty-report and final-count laws. The row's usage was
/// already decoded by the storage codec, so it is not decoded again here.
///
/// ## Examples
///
/// ```gleam
/// let report = accounting.append(accounting.from_usage(first), second)
/// let stored = entry.UsageRow(..row, usage: accounting.total(report),
///   details: Some(accounting.details(report, [])))
/// assert accounting.decode_row(stored) == Ok(report)
/// assert accounting.decode_row(entry.UsageRow(..row, details: None))
///   == Ok(accounting.from_usage(row.usage))
/// ```
pub fn decode_row(
  row: entry.UsageRow,
) -> Result(RequestAccounting, CorruptionReport) {
  let fields = case row.details {
    Some(json.Object(fields)) -> fields
    None | Some(_) -> []
  }
  case list.filter(fields, fn(field) { field.0 == namespace }) {
    [] -> Ok(from_usage(row.usage))
    [#(_, value)] -> decode_report(value, row.usage)
    [_, _, ..] -> invalid("details", "one accounting namespace")
  }
}

fn add_optional(left: Option(Int), right: Option(Int)) -> Option(Int) {
  case left, right {
    None, None -> None
    Some(value), None | None, Some(value) -> Some(value)
    Some(left), Some(right) -> Some(left + right)
  }
}

// The namespaced value is `{version, attempt_count, last}`. A null `last`
// describes the empty report and a usage object describes at least one
// attempt, so the two shapes are decoded by separate functions.
fn decode_report(
  value: JsonValue,
  total: Usage,
) -> Result(RequestAccounting, CorruptionReport) {
  // Request reports describe consumption. Generic historical adjustment rows
  // remain signed, so this constraint belongs only to the namespaced report.
  use <- bool.lazy_guard(!nonnegative(total), fn() {
    invalid("total", "non-negative request consumption")
  })
  use fields <- result.try(exact_fields(value))
  use version <- result.try(field(fields, "version"))
  use <- bool.lazy_guard(version != json.Int(1), fn() {
    invalid("version", "1")
  })
  use count <- result.try(field(fields, "attempt_count"))
  use count <- result.try(case count {
    json.Int(count) if count >= 0 -> Ok(count)
    json.Int(_)
    | json.Null
    | json.Bool(_)
    | json.Float(_)
    | json.String(_)
    | json.Array(_)
    | json.Object(_) -> invalid("attempt_count", "a non-negative integer")
  })
  use raw_last <- result.try(field(fields, "last"))
  case raw_last {
    json.Null -> decode_empty(total, count)
    json.Object(_) -> decode_attempts(total, raw_last, count)
    json.Bool(_)
    | json.Int(_)
    | json.Float(_)
    | json.String(_)
    | json.Array(_) -> invalid("last", "null or a usage object")
  }
}

// An empty report is the addition identity, so it records no attempts and no
// consumption.
fn decode_empty(
  total: Usage,
  count: Int,
) -> Result(RequestAccounting, CorruptionReport) {
  case count == 0 && total == zero_usage() {
    True -> Ok(NoAttempts)
    False -> invalid("report", "no attempts and zero usage without a final")
  }
}

// Count and final observation must describe the same ownership frontier.
// The aggregate must contain its final observation, never replace it.
fn decode_attempts(
  total: Usage,
  raw_last: JsonValue,
  count: Int,
) -> Result(RequestAccounting, CorruptionReport) {
  use <- bool.lazy_guard(count < 1, fn() {
    invalid("report", "an attempt count for the final observation")
  })
  use last <- result.try(codec.decode_usage(raw_last))
  use <- bool.lazy_guard(!nonnegative(last), fn() {
    invalid("last", "non-negative request consumption")
  })
  use <- bool.lazy_guard(!contains_final(total, last, count), fn() {
    invalid("report", "an aggregate containing its final attempt")
  })
  Ok(Attempts(total:, last:, count:))
}

fn contains_final(total: Usage, last: Usage, count: Int) -> Bool {
  case count {
    1 -> total == last
    _ ->
      total.input >= last.input
      && total.output >= last.output
      && total.cache_read >= last.cache_read
      && total.cache_write >= last.cache_write
      && total.total_tokens >= last.total_tokens
      && total.cost.input >=. last.cost.input
      && total.cost.output >=. last.cost.output
      && total.cost.cache_read >=. last.cost.cache_read
      && total.cost.cache_write >=. last.cost.cache_write
      && total.cost.total >=. last.cost.total
      && usage_evidence.add(total.evidence, last.evidence) == total.evidence
  }
}

fn exact_fields(
  value: JsonValue,
) -> Result(List(#(String, JsonValue)), CorruptionReport) {
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    json.Null
    | json.Bool(_)
    | json.Int(_)
    | json.Float(_)
    | json.String(_)
    | json.Array(_) -> invalid("value", "an object")
  })
  use <- bool.lazy_guard(
    list.sort(list.map(fields, fn(field) { field.0 }), string.compare)
      != ["attempt_count", "last", "version"],
    fn() { invalid("fields", "version, attempt_count and last exactly once") },
  )
  Ok(fields)
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
    at: "core/accounting.decode_row",
    on: subject,
    expected:,
    context: "invalid request accounting",
  )
}

// Adjustments may be signed, but an attempt cannot refund prior consumption.
fn nonnegative(usage: Usage) -> Bool {
  usage.input >= 0
  && usage.output >= 0
  && usage.cache_read >= 0
  && usage.cache_write >= 0
  && usage.total_tokens >= 0
  && option.unwrap(usage.cache_write_1h, 0) >= 0
  && option.unwrap(usage.reasoning, 0) >= 0
  && usage.cost.input >=. 0.0
  && usage.cost.output >=. 0.0
  && usage.cost.cache_read >=. 0.0
  && usage.cost.cache_write >=. 0.0
  && usage.cost.total >=. 0.0
}
