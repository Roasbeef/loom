//// What a provider says about one subscription seat's remaining allowance.
////
//// An operator who holds several plan seats wants to know, per seat, whether
//// the allowance is spent, which windows are filling and when they reset. This
//// module is the pure half of that question: it decodes the seats an operator
//// supplies, builds the one or two read-only requests that ask a provider about
//// a seat, decodes the answers into a `Reading`, and turns a reading into the
//// events the account pool's ledger (`provider/pool`) already takes. It opens
//// no socket and reads no clock; `client/seat_usage_cli` supplies both. The
//// design is `docs/design-notes/account-pool.md`, section 3.
////
//// ## What each provider is asked
////
//// Only mechanisms the design note classes as documented or observable are
//// used, and nothing sends a model request.
////
//// - **Codex (ChatGPT plan).** `GET https://chatgpt.com/backend-api/wham/usage`
////   with the seat's bearer. The Codex CLI builds that URL in
////   `codex-rs/backend-client/src/client/rate_limit_resets.rs`
////   (`rate_limit_status_url`, lines 128 to 133, with the `/backend-api`
////   suffix added in `codex-rs/backend-client/src/client.rs` lines 254 to 259)
////   and sends only a bearer, a user agent and, when it knows one, a
////   `chatgpt-account-id` header (`client.rs` lines 379 to 402,
////   `codex-rs/model-provider/src/bearer_auth_provider.rs` lines 35 to 51). The
////   account header is optional in the CLI, so this module sends none. The
////   payload is `RateLimitStatusPayload`
////   (`codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_payload.rs`
////   lines 15 to 54), `RateLimitStatusDetails` (`rate_limit_status_details.rs`
////   lines 15 to 35), `RateLimitWindowSnapshot`
////   (`rate_limit_window_snapshot.rs` lines 13 to 23) and
////   `AdditionalRateLimitDetails` with the `normal_model_slug` field the CLI
////   adds in `codex-rs/backend-client/src/types.rs` lines 55 to 75. All read at
////   `openai/codex` commit `1b7c0252586f3701493bb7c9331290c06346b842`.
//// - **Codex model listing**, for `--model` only: `GET
////   https://api.openai.com/v1/models`, which OpenAI documents for the signed-in
////   account at
////   `https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference`
////   (entries carry `slug` and `visibility`) and which loom already calls
////   (`client/codex/profile.model_catalogue`). The page does not say that an
////   unlisted model cannot be used, so absence is `unknown`, not `no`.
//// - **Claude plan.** `GET https://api.anthropic.com/api/oauth/usage` with a
////   bearer and `anthropic-beta: oauth-2025-04-20`. No first-party source
////   names this URL: the Claude Code client that issues it ships as a compiled
////   binary, and the open-source adapter only reaches it through the SDK's
////   `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET`
////   (`agentclientprotocol/claude-agent-acp` commit
////   `c331e178a5df47448be1a3ed2f71270c3aad2433`, `src/v1/acp-agent.ts` line 563).
////   The URL and header come from third-party clients that call it
////   (`https://docs.rs/crate/cship/1.7.1/source/src/usage_limits.rs`); the
////   response shape is corroborated first-party by the SDK's
////   `SDKControlGetUsageResponse` in `@anthropic-ai/claude-agent-sdk` 0.3.322,
////   `sdk.d.ts` lines 4442 to 4540, which says the windows come "from the
////   claude.ai usage endpoint": `five_hour`, `seven_day`, `seven_day_opus`,
////   `seven_day_sonnet`, `seven_day_oauth_apps`, each `utilization` (0 to 100)
////   and `resets_at` (ISO 8601), either of which may be null. The SDK marks the
////   call experimental and says the profile scope may be missing; a long-lived
////   inference-only token is therefore expected to be refused, which is
////   reported as a failed read, not guessed around.
////
//// ## What stays unknown
////
//// Whether a given seat may use a named model is documented nowhere read, so
//// `ModelUnknown` is the ordinary answer. `ModelUnavailable` is returned only
//// when the provider itself reports that the model's own allowance is spent:
//// a Codex `additional_rate_limits` entry whose `normal_model_slug` is the
//// model and whose limit is reached, or a full Claude per-family window. The
//// Claude usage payload names no plan, so `plan` is absent for Claude.
////
//// ## Secrets
////
//// A seat's token is decoded straight into `Token`, an opaque closure. A
//// closure is used because `string.inspect` prints a record's fields but only
//// the shape of a function, so debug formatting of a `Seat` cannot show the
//// token. `reveal` is called once, when a request is built. A `Reading` and a
//// `Report` carry no token, and every refusal is a closed reason code, never
//// text taken from a line, a response body or a transport diagnostic.
////
//// ## Flow
////
//// `parse_seats` turns raw input lines into seats or a `LineRefusal`;
//// `usage_request` and `models_request` build the requests; `read_usage` and
//// `answer_model` turn bodies into a `Reading`; `failure_from_fetch` and
//// `failure_code` name a failed read; `to_pool_events` maps a report onto the
//// pool.

import client/codex/credentials
import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import provider/http
import provider/pool

/// The most seats one run reads.
pub const max_seats = 256

/// The longest input line accepted, in bytes.
pub const max_line_bytes = 8192

/// The longest token accepted, in bytes.
pub const max_token_bytes = 4096

/// Which provider issued a seat.
pub type Provider {
  /// A Claude Pro or Max plan seat.
  Claude

  /// A ChatGPT plan seat used through Codex.
  Codex
}

/// A seat's bearer, held where debug formatting cannot print it.
///
/// Constructor invariants: the closure returns a nonempty string of printable
/// ASCII with no space; the only reader is `reveal`.
pub opaque type Token {
  Token(reveal: fn() -> String)
}

/// One seat the operator supplied.
pub type Seat {
  Seat(
    /// The operator's name for the seat: 1 to 64 ASCII letters, digits,
    /// underscores or hyphens, so it cannot spell an email address or hold a
    /// token by accident.
    label: String,
    /// The provider that issued the seat.
    provider: Provider,
    /// The seat's bearer.
    token: Token,
  )
}

/// One raw line of input as the reader saw it.
pub type RawLine {
  /// A line of valid UTF-8 within the length bound.
  Raw(String)

  /// A line over `max_line_bytes`, discarded unread.
  Oversized

  /// A line that is not valid UTF-8.
  NotText
}

/// Why one input line was refused. A closed set, so no reason can carry the
/// line's text.
pub type Reason {
  /// The line is not JSON.
  MalformedJson

  /// The line is JSON but not an object.
  NotAnObject

  /// The object has a key other than `label`, `provider` and `token`.
  UnknownKey

  /// A required key is missing or has the wrong type.
  MissingField

  /// The label is not 1 to 64 ASCII letters, digits, underscores or hyphens.
  InvalidLabel

  /// The provider is neither `claude` nor `codex`.
  InvalidProvider

  /// The token is empty, too long, or holds a space or control character.
  InvalidToken

  /// The line exceeds `max_line_bytes`.
  LineTooLong

  /// The line is not UTF-8.
  InvalidUtf8

  /// An earlier line already used this label.
  DuplicateLabel

  /// More than `max_seats` seats were supplied.
  TooManySeats

  /// No seat was supplied.
  NoSeats
}

/// A refused line: where it was and why, with the label only when one was read
/// and is itself a valid label.
pub type LineRefusal {
  LineRefusal(line: Int, label: Option(String), reason: Reason)
}

/// One window of a provider's allowance gauge.
pub type Window {
  Window(
    /// The provider's name for the window, such as `five_hour` or `primary`.
    name: String,
    /// The share of the window used, from 0.0 to 1.0.
    used_fraction: Float,
    /// When the window resets, in milliseconds since the Unix epoch, if the
    /// provider said.
    resets_at_ms: Option(Int),
    /// The window's length in seconds, if the provider said.
    span_seconds: Option(Int),
  )
}

/// Whether a seat can still be used, as far as the provider says.
pub type State {
  /// No window is full and the provider does not report a limit reached.
  Available

  /// The provider reports the seat's allowance spent.
  Exhausted

  /// The reading does not establish either; `reason` says why.
  Unknown(reason: String)
}

/// Whether a named model is available to a seat.
pub type ModelAnswer {
  /// The provider lists the model for the seat.
  ModelAvailable

  /// The provider reports the model's own allowance spent.
  ModelUnavailable(reason: String)

  /// Nothing read establishes either.
  ModelUnknown(reason: String)
}

/// What the provider said about a seat.
pub type Reading {
  Reading(
    /// The plan or tier the provider named, if it did.
    plan: Option(String),
    /// Every window the provider reported with a usable reading.
    windows: List(Window),
    /// The seat's standing.
    state: State,
    /// The answer for `--model`, when a model was asked about.
    model: Option(ModelAnswer),
  )
}

/// Why a seat could not be read. A closed set of codes with no provider text.
pub type Failure {
  /// The provider answered with a status other than 200.
  HttpStatus(Int)

  /// The seat did not answer within its timeout.
  TimedOut

  /// The request could not be completed.
  TransportFailed

  /// The response exceeded the body bound.
  TooLarge

  /// The response was not a decodable usage document.
  Malformed

  /// The read was cancelled or its worker failed.
  Cancelled
}

/// One seat's result, carrying the label and provider but never the token.
pub type Report {
  Report(
    /// The seat's label.
    label: String,
    /// The seat's provider.
    provider: Provider,
    /// The reading, or why there is none.
    outcome: Result(Reading, Failure),
  )
}

// --- Seats -------------------------------------------------------------------

/// Decodes numbered raw lines into seats. Blank lines are skipped but counted.
/// The first refusal ends the run, so no request is made for a partly valid
/// input.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok([seat]) =
///   seat_usage.parse_seats([
///     #(1, seat_usage.Raw("{\"label\":\"a\",\"provider\":\"codex\",\"token\":\"t\"}")),
///   ])
/// assert seat.label == "a"
/// assert seat_usage.parse_seats([]) ==
///   Error(seat_usage.LineRefusal(0, option.None, seat_usage.NoSeats))
/// ```
pub fn parse_seats(
  lines: List(#(Int, RawLine)),
) -> Result(List(Seat), LineRefusal) {
  use seats <- result.try(parse_lines(lines, []))

  // An empty input is refused here, so a run always has a seat to read.
  case seats {
    [] -> Error(LineRefusal(0, None, NoSeats))
    [_, ..] -> Ok(list.reverse(seats))
  }
}

/// Folds lines into seats, newest first, refusing duplicates and overflow.
fn parse_lines(
  lines: List(#(Int, RawLine)),
  seats: List(Seat),
) -> Result(List(Seat), LineRefusal) {
  // Each line either ends the fold, is skipped as blank, or adds a seat.
  case lines {
    [] -> Ok(seats)
    [#(number, line), ..rest] -> {
      use parsed <- result.try(parse_line(number, line))

      // A blank line yields no seat; a real one is checked against what is held.
      case parsed {
        None -> parse_lines(rest, seats)
        Some(seat) -> {
          use Nil <- result.try(admit(number, seat, seats))
          parse_lines(rest, [seat, ..seats])
        }
      }
    }
  }
}

/// Refuses a seat that repeats a label or exceeds the seat bound.
fn admit(
  number: Int,
  seat: Seat,
  seats: List(Seat),
) -> Result(Nil, LineRefusal) {
  let duplicate = list.any(seats, fn(held) { held.label == seat.label })

  // A repeated label and an overfull run are refused, in that order.
  case duplicate, list.length(seats) >= max_seats {
    True, _ -> Error(LineRefusal(number, Some(seat.label), DuplicateLabel))
    False, True -> Error(LineRefusal(number, Some(seat.label), TooManySeats))
    False, False -> Ok(Nil)
  }
}

/// Decodes one raw line; a blank line is `Ok(None)`.
fn parse_line(number: Int, line: RawLine) -> Result(Option(Seat), LineRefusal) {
  case line {
    Oversized -> Error(LineRefusal(number, None, LineTooLong))
    NotText -> Error(LineRefusal(number, None, InvalidUtf8))
    Raw(text) ->
      case string.trim(text) {
        "" -> Ok(None)
        _ -> parse_seat(number, text) |> result.map(Some)
      }
  }
}

/// Decodes one nonblank line into a seat.
///
/// ## Examples
///
/// ```gleam
/// let line = "{\"label\":\"a\",\"provider\":\"claude\",\"token\":\"t\"}"
/// let assert Ok(seat) = seat_usage.parse_seat(1, line)
/// assert seat.provider == seat_usage.Claude
/// let assert Error(refusal) = seat_usage.parse_seat(2, "{\"label\":\"a\"}")
/// assert refusal.reason == seat_usage.MissingField
/// ```
pub fn parse_seat(number: Int, text: String) -> Result(Seat, LineRefusal) {
  use fields <- result.try(
    object_fields(text)
    |> result.map_error(fn(reason) { LineRefusal(number, None, reason) }),
  )
  let label = readable_label(fields)

  check_keys(fields)
  |> result.try(fn(_) { decode_seat(fields) })
  |> result.map_error(fn(reason) { LineRefusal(number, label, reason) })
}

/// Parses a line as a JSON object.
fn object_fields(
  text: String,
) -> Result(dict.Dict(String, decode.Dynamic), Reason) {
  json.parse(text, decode.dict(decode.string, decode.dynamic))
  |> result.map_error(fn(error) {
    case error {
      json.UnableToDecode(_) -> NotAnObject
      json.UnexpectedEndOfInput
      | json.UnexpectedByte(_)
      | json.UnexpectedSequence(_) -> MalformedJson
    }
  })
}

/// Refuses an object with a key beyond the three a seat line carries.
fn check_keys(
  fields: dict.Dict(String, decode.Dynamic),
) -> Result(Nil, Reason) {
  case list.all(dict.keys(fields), known_key) {
    True -> Ok(Nil)
    False -> Error(UnknownKey)
  }
}

/// The three keys a seat line may carry.
fn known_key(key: String) -> Bool {
  key == "label" || key == "provider" || key == "token"
}

/// The line's label when it is a string and a valid label, so a refusal never
/// echoes text that is not one.
fn readable_label(fields: dict.Dict(String, decode.Dynamic)) -> Option(String) {
  string_field(fields, "label")
  |> result.try(fn(label) {
    credentials.valid_profile(label)
    |> result.replace(label)
    |> result.replace_error(Nil)
  })
  |> option.from_result
}

/// A string-valued field.
fn string_field(
  fields: dict.Dict(String, decode.Dynamic),
  key: String,
) -> Result(String, Nil) {
  use value <- result.try(dict.get(fields, key))
  decode.run(value, decode.string) |> result.replace_error(Nil)
}

/// Builds a seat from the three fields.
fn decode_seat(
  fields: dict.Dict(String, decode.Dynamic),
) -> Result(Seat, Reason) {
  let missing = fn(_) { MissingField }
  use label <- result.try(
    string_field(fields, "label") |> result.map_error(missing),
  )
  use provider_name <- result.try(
    string_field(fields, "provider") |> result.map_error(missing),
  )
  use token <- result.try(
    string_field(fields, "token") |> result.map_error(missing),
  )
  use Nil <- result.try(
    credentials.valid_profile(label) |> result.replace_error(InvalidLabel),
  )
  use provider <- result.try(provider_of(provider_name))
  use Nil <- result.try(check_token(token))

  Ok(Seat(label:, provider:, token: Token(reveal: fn() { token })))
}

/// Names a provider from its input spelling.
fn provider_of(name: String) -> Result(Provider, Reason) {
  case name {
    "claude" -> Ok(Claude)
    "codex" -> Ok(Codex)
    _ -> Error(InvalidProvider)
  }
}

/// A token is printable ASCII with no space, so it is safe in a header and
/// cannot smuggle a second header line.
fn check_token(token: String) -> Result(Nil, Reason) {
  let printable =
    list.all(string.to_utf_codepoints(token), fn(point) {
      let code = string.utf_codepoint_to_int(point)
      code > 32 && code < 127
    })

  // A token is usable only when it is nonempty, bounded and printable.
  case token != "" && string.byte_size(token) <= max_token_bytes && printable {
    True -> Ok(Nil)
    False -> Error(InvalidToken)
  }
}

/// The text of a refusal: the line number, the label when one was read, and a
/// fixed reason. Nothing from the line itself.
///
/// ## Examples
///
/// ```gleam
/// let refusal = seat_usage.LineRefusal(3, option.Some("seat-a"), seat_usage.UnknownKey)
/// assert seat_usage.refusal_text(refusal)
///   == "line 3 (seat-a): unknown key"
/// ```
pub fn refusal_text(refusal: LineRefusal) -> String {
  // Line zero means the whole input, not a line.
  let place = case refusal.line, refusal.label {
    0, _ -> "input"
    line, None -> "line " <> int.to_string(line)
    line, Some(label) -> "line " <> int.to_string(line) <> " (" <> label <> ")"
  }

  place <> ": " <> reason_text(refusal.reason)
}

/// The fixed wording of a reason.
fn reason_text(reason: Reason) -> String {
  case reason {
    MalformedJson -> "not valid JSON"
    NotAnObject -> "not a JSON object"
    UnknownKey -> "unknown key"
    MissingField -> "a required field is missing or not a string"
    InvalidLabel -> "invalid label"
    InvalidProvider -> "provider must be claude or codex"
    InvalidToken -> "invalid token"
    LineTooLong -> "line too long"
    InvalidUtf8 -> "line is not UTF-8"
    DuplicateLabel -> "duplicate label"
    TooManySeats -> "too many seats"
    NoSeats -> "no seats supplied"
  }
}

/// The provider's name as it appears in input and output.
///
/// ## Examples
///
/// ```gleam
/// assert seat_usage.provider_name(seat_usage.Codex) == "codex"
/// ```
pub fn provider_name(provider: Provider) -> String {
  case provider {
    Claude -> "claude"
    Codex -> "codex"
  }
}

// --- Requests ----------------------------------------------------------------

/// The one read-only request that asks the provider about a seat's allowance.
/// This is the only place a token is revealed.
///
/// ## Examples
///
/// ```gleam
/// let request = seat_usage.usage_request(seat)
/// assert request.method == "GET"
/// ```
pub fn usage_request(seat: Seat) -> http.HttpRequest {
  let bearer = #("authorization", "Bearer " <> seat.token.reveal())
  let common = [bearer, #("accept", "application/json")]

  // Each provider has its own endpoint and, for Claude, a beta header.
  case seat.provider {
    Codex ->
      http.HttpRequest(
        "GET",
        "https://chatgpt.com/backend-api/wham/usage",
        [#("user-agent", "loom-seat-usage"), ..common],
        "",
      )
    Claude ->
      http.HttpRequest(
        "GET",
        "https://api.anthropic.com/api/oauth/usage",
        [
          #("user-agent", "loom-seat-usage"),
          #("anthropic-beta", "oauth-2025-04-20"),
          ..common
        ],
        "",
      )
  }
}

/// The model-listing request for a seat, where the provider documents one.
/// Claude has none, so it is `None`.
///
/// ## Examples
///
/// ```gleam
/// assert seat_usage.models_request(claude_seat) == option.None
/// ```
pub fn models_request(seat: Seat) -> Option(http.HttpRequest) {
  case seat.provider {
    Claude -> None
    Codex ->
      Some(http.HttpRequest(
        "GET",
        "https://api.openai.com/v1/models",
        [
          #("authorization", "Bearer " <> seat.token.reveal()),
          #("accept", "application/json"),
          #("user-agent", "loom-seat-usage"),
        ],
        "",
      ))
  }
}

// --- Failures ----------------------------------------------------------------

/// Names a failed fetch from the transport's error code. The code is one of a
/// closed set (`client/codex/network`), and anything else is `TransportFailed`.
///
/// ## Examples
///
/// ```gleam
/// assert seat_usage.failure_from_fetch("request_timed_out")
///   == seat_usage.TimedOut
/// ```
pub fn failure_from_fetch(code: String) -> Failure {
  case code {
    "request_timed_out" -> TimedOut
    "response_too_large" -> TooLarge
    "invalid_http_response" -> Malformed
    "request_cancelled" -> Cancelled
    _ -> TransportFailed
  }
}

/// The stable code printed for a failure.
///
/// ## Examples
///
/// ```gleam
/// assert seat_usage.failure_code(seat_usage.HttpStatus(403)) == "http_403"
/// ```
pub fn failure_code(failure: Failure) -> String {
  case failure {
    HttpStatus(status) -> "http_" <> int.to_string(status)
    TimedOut -> "timeout"
    TransportFailed -> "transport_failed"
    TooLarge -> "response_too_large"
    Malformed -> "malformed_response"
    Cancelled -> "cancelled"
  }
}

// --- Decoding readings -------------------------------------------------------

/// Decodes a usage response into a reading. `model` is the `--model` name,
/// when one was asked about; Codex answers it here only when the usage payload
/// itself says the model's allowance is spent, and the model listing decides
/// the rest through `answer_model`.
///
/// ## Examples
///
/// ```gleam
/// let body = "{\"plan_type\":\"pro\",\"rate_limit\":{\"allowed\":true,\"limit_reached\":false}}"
/// let assert Ok(reading) = seat_usage.read_usage(seat_usage.Codex, body, option.None, 0)
/// assert reading.plan == option.Some("pro")
/// ```
pub fn read_usage(
  provider: Provider,
  body: String,
  model: Option(String),
  now_ms: Int,
) -> Result(Reading, Failure) {
  case provider {
    Codex -> codex_usage(body, model)
    Claude -> claude_usage(body, model, now_ms)
  }
}

/// A number the provider may send as an integer or a float.
fn number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.map(decode.int, int.to_float)])
}

/// The share of a window used, from a percentage and clamped to 0.0 to 1.0.
fn fraction(percent: Float) -> Float {
  float.clamp(percent /. 100.0, 0.0, 1.0)
}

/// One Codex window snapshot, for a name.
fn codex_window(name: String) -> decode.Decoder(Window) {
  use percent <- decode.field("used_percent", number())
  use span <- decode.optional_field(
    "limit_window_seconds",
    None,
    decode.optional(decode.int),
  )
  use reset <- decode.optional_field(
    "reset_at",
    None,
    decode.optional(decode.int),
  )

  decode.success(Window(
    name:,
    used_fraction: fraction(percent),
    resets_at_ms: option.map(reset, fn(seconds) { seconds * 1000 }),
    span_seconds: span,
  ))
}

/// Codex's `RateLimitStatusDetails`: the flags and up to two windows.
type CodexLimit {
  CodexLimit(status: LimitStatus, windows: List(Window))
}

/// Whether Codex reports a limit open or spent: spent when `allowed` is false
/// or `limit_reached` is true.
type LimitStatus {
  LimitOpen
  LimitSpent
}

/// Decodes `RateLimitStatusDetails`.
fn codex_limit() -> decode.Decoder(CodexLimit) {
  use allowed <- decode.field("allowed", decode.bool)
  use reached <- decode.field("limit_reached", decode.bool)
  use primary <- decode.optional_field(
    "primary_window",
    None,
    decode.optional(codex_window("primary")),
  )
  use secondary <- decode.optional_field(
    "secondary_window",
    None,
    decode.optional(codex_window("secondary")),
  )

  // Codex reports a limit spent when it is not allowed or says it was reached.
  let status = case allowed, reached {
    True, False -> LimitOpen
    False, _ | _, True -> LimitSpent
  }

  decode.success(CodexLimit(
    status:,
    windows: option.values([primary, secondary]),
  ))
}

/// One `additional_rate_limits` entry: the model it meters, if named, and its
/// limit.
type CodexExtra {
  CodexExtra(model: Option(String), limit: Option(CodexLimit))
}

/// Decodes an `AdditionalRateLimitDetails` with the CLI's extra field.
fn codex_extra() -> decode.Decoder(CodexExtra) {
  use model <- decode.optional_field(
    "normal_model_slug",
    None,
    decode.optional(decode.string),
  )
  use limit <- decode.optional_field(
    "rate_limit",
    None,
    decode.optional(codex_limit()),
  )

  decode.success(CodexExtra(model:, limit:))
}

/// Decodes a Codex usage payload.
fn codex_usage(
  body: String,
  model: Option(String),
) -> Result(Reading, Failure) {
  let decoder = {
    use plan <- decode.optional_field(
      "plan_type",
      None,
      decode.optional(decode.string),
    )
    use limit <- decode.optional_field(
      "rate_limit",
      None,
      decode.optional(codex_limit()),
    )
    use extras <- decode.optional_field(
      "additional_rate_limits",
      None,
      decode.optional(decode.list(codex_extra())),
    )

    decode.success(#(plan, limit, option.unwrap(extras, [])))
  }
  use #(plan, limit, extras) <- result.try(
    json.parse(body, decoder) |> result.replace_error(Malformed),
  )

  // A payload with no limit object establishes nothing; a refused or full limit is spent.
  let #(state, windows) = case limit {
    None -> #(Unknown("the payload has no rate_limit"), [])
    Some(CodexLimit(status: LimitSpent, windows:)) -> #(Exhausted, windows)
    Some(CodexLimit(status: LimitOpen, windows:)) -> #(Available, windows)
  }

  Ok(Reading(plan:, windows:, state:, model: codex_model(extras, model)))
}

/// The model answer the usage payload alone can give: unavailable when an
/// entry metering exactly this model reports its limit reached, otherwise
/// nothing yet.
fn codex_model(
  extras: List(CodexExtra),
  model: Option(String),
) -> Option(ModelAnswer) {
  use name <- option.then(model)
  let spent =
    list.any(extras, fn(extra) {
      case extra.model, extra.limit {
        Some(slug), Some(limit) -> slug == name && limit.status == LimitSpent
        _, _ -> False
      }
    })

  // Only an entry that meters this model and reports it spent answers here.
  case spent {
    True ->
      Some(ModelUnavailable(
        "the provider reports this model's own limit reached",
      ))
    False -> None
  }
}

/// One Claude window, named, or `None` when it is absent or has no reading.
fn claude_window(name: String) -> decode.Decoder(Option(Window)) {
  use percent <- decode.optional_field(
    "utilization",
    None,
    decode.optional(number()),
  )
  use reset <- decode.optional_field(
    "resets_at",
    None,
    decode.optional(decode.string),
  )

  decode.success(
    option.map(percent, fn(percent) {
      Window(
        name:,
        used_fraction: fraction(percent),
        resets_at_ms: option.then(reset, rfc3339_ms),
        span_seconds: None,
      )
    }),
  )
}

/// Milliseconds since the epoch for an RFC 3339 time, or `None`.
fn rfc3339_ms(text: String) -> Option(Int) {
  timestamp.parse_rfc3339(text)
  |> result.map(fn(time) {
    let #(seconds, _nanos) = timestamp.to_unix_seconds_and_nanoseconds(time)
    seconds * 1000
  })
  |> option.from_result
}

/// The Claude window names the usage payload may carry, in display order.
const claude_windows = [
  "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet",
  "seven_day_oauth_apps",
]

/// Decodes a Claude usage payload.
fn claude_usage(
  body: String,
  model: Option(String),
  now_ms: Int,
) -> Result(Reading, Failure) {
  let decoder =
    list.fold(claude_windows, decode.success([]), fn(collected, name) {
      use windows <- decode.then(collected)
      use window <- decode.optional_field(
        name,
        None,
        decode.optional(claude_window(name)),
      )

      decode.success(case option.flatten(window) {
        Some(window) -> [window, ..windows]
        None -> windows
      })
    })
  use found <- result.try(
    json.parse(body, decoder) |> result.replace_error(Malformed),
  )
  let windows = list.reverse(found)

  // A run of windows with no reading establishes nothing; any full window is spent.
  let state = case windows {
    [] -> Unknown("the payload has no window with a reading")
    [_, ..] ->
      case list.any(windows, fn(window) { full(window, now_ms) }) {
        True -> Exhausted
        False -> Available
      }
  }

  Ok(Reading(
    plan: None,
    windows:,
    state:,
    model: option.map(model, fn(name) { claude_model(name, windows, now_ms) }),
  ))
}

/// Whether a window reads full and has not yet reset.
fn full(window: Window, now_ms: Int) -> Bool {
  window.used_fraction >=. 1.0
  && case window.resets_at_ms {
    Some(reset) -> reset > now_ms
    None -> True
  }
}

/// The Claude answer for a model: unavailable when its family's own window is
/// full, otherwise unknown, because a window shows allowance and not
/// entitlement.
fn claude_model(
  name: String,
  windows: List(Window),
  now_ms: Int,
) -> ModelAnswer {
  let lowered = string.lowercase(name)

  // The model name picks the weekly window its family is metered by.
  let family = case
    string.contains(lowered, "opus"),
    string.contains(lowered, "sonnet")
  {
    True, _ -> Some("seven_day_opus")
    False, True -> Some("seven_day_sonnet")
    False, False -> None
  }

  let spent =
    option.map(family, fn(wanted) {
      list.any(windows, fn(window) {
        window.name == wanted && full(window, now_ms)
      })
    })

  // A full family window is a spent allowance; an open one is not entitlement.
  case spent {
    Some(True) -> ModelUnavailable("the model family's weekly window is full")
    Some(False) ->
      ModelUnknown(
        "a usage window shows allowance, not entitlement to this model",
      )
    None -> ModelUnknown("the usage payload has no window for this model")
  }
}

/// Completes a reading's model answer from the model listing, when the usage
/// payload did not already answer. `listing` is the listing's response body or
/// the failure that stopped it.
///
/// ## Examples
///
/// ```gleam
/// let listing = Ok("{\"models\":[{\"slug\":\"m\",\"visibility\":\"list\"}]}")
/// let reading = seat_usage.answer_model(reading, "m", listing)
/// assert reading.model == option.Some(seat_usage.ModelAvailable)
/// ```
pub fn answer_model(
  reading: Reading,
  model: String,
  listing: Result(String, Failure),
) -> Reading {
  case reading.model {
    Some(_) -> reading
    None -> Reading(..reading, model: Some(listed(model, listing)))
  }
}

/// Reads a model listing for one model.
fn listed(model: String, listing: Result(String, Failure)) -> ModelAnswer {
  let decoder = {
    use models <- decode.field("models", {
      decode.list({
        use slug <- decode.field("slug", decode.string)
        use visibility <- decode.field("visibility", decode.string)
        decode.success(#(slug, visibility))
      })
    })
    decode.success(models)
  }
  let parsed =
    result.try(listing, fn(body) {
      json.parse(body, decoder) |> result.replace_error(Malformed)
    })

  // A failed listing or a missing entry never becomes a `no`.
  case parsed {
    Error(failure) ->
      ModelUnknown("the model listing failed: " <> failure_code(failure))
    Ok(models) ->
      case list.contains(models, #(model, "list")) {
        True -> ModelAvailable
        False ->
          ModelUnknown(
            "not in the account's listed models; the provider does not say that means unusable",
          )
      }
  }
}

// --- The pool ----------------------------------------------------------------

/// Turns one seat's report into the events the pool's ledger takes.
///
/// A spent seat becomes a usage-limit refusal that names the latest reset among
/// its full windows, or none when the provider named none, so the ledger's own
/// hold applies. Every window with a reset time is also offered as a gauge
/// reading. A seat that could not be read, or whose state is unknown, yields no
/// event: a failed read is not evidence about allowance, and an authorization
/// failure is never inferred from a usage endpoint's refusal.
///
/// ## Examples
///
/// ```gleam
/// let events = seat_usage.to_pool_events(report, 1_000)
/// // [pool.Observed("seat-a", 1_000, [pool.Window(40, 9_000)])]
/// ```
pub fn to_pool_events(report: Report, now_ms: Int) -> List(pool.Event) {
  // A seat that could not be read says nothing to the ledger.
  case report.outcome {
    Error(_) -> []
    Ok(reading) -> {
      let observed =
        pool.Observed(
          report.label,
          now_ms,
          list.filter_map(reading.windows, pool_window),
        )

      // An unknown state says nothing; a spent seat is refused before its gauge is offered.
      case reading.state {
        Unknown(_) -> []
        Available -> [observed]
        Exhausted -> [
          pool.Refused(
            report.label,
            now_ms,
            pool.UsageLimit(latest_full_reset(reading.windows, now_ms)),
          ),
          observed,
        ]
      }
    }
  }
}

/// A window as the ledger sees it; one with no reset time cannot be placed.
fn pool_window(window: Window) -> Result(pool.Window, Nil) {
  use reset <- result.map(option.to_result(window.resets_at_ms, Nil))
  pool.window(float.round(window.used_fraction *. 100.0), reset)
}

/// The latest reset among full windows still in the future.
fn latest_full_reset(windows: List(Window), now_ms: Int) -> Option(Int) {
  list.filter_map(windows, fn(window) {
    case full(window, now_ms), window.resets_at_ms {
      True, Some(reset) if reset > now_ms -> Ok(reset)
      _, _ -> Error(Nil)
    }
  })
  |> list.reduce(int.max)
  |> option.from_result
}
