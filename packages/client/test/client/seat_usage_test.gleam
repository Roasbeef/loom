//// The pure half of the seat gauge: seat lines, usage decoders and the pool
//// mapping. Every response body is built from the field shapes in the sources
//// `client/seat_usage` cites; nothing here reaches a provider.

import client/seat_usage.{
  Available, Claude, Codex, Exhausted, ModelAvailable, ModelUnavailable,
  ModelUnknown, Raw, Unknown,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/pool

const now_ms = 1_794_355_200_000

const line_ok =
  "{\"label\":\"seat-a\",\"provider\":\"codex\",\"token\":\"tok-1\"}"

fn refusal(lines: List(seat_usage.RawLine)) -> seat_usage.LineRefusal {
  let numbered = numbered(lines, 1, [])
  let assert Error(found) = seat_usage.parse_seats(numbered)
    as "The input must be refused."
  found
}

fn numbered(
  lines: List(seat_usage.RawLine),
  from: Int,
  acc: List(#(Int, seat_usage.RawLine)),
) -> List(#(Int, seat_usage.RawLine)) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] -> numbered(rest, from + 1, [#(from, line), ..acc])
  }
}

pub fn seat_lines_decode_test() {
  let assert Ok([seat]) = seat_usage.parse_seats([#(1, Raw(line_ok))])
  assert seat.label == "seat-a"
  assert seat.provider == Codex
  let assert Ok([_, _]) =
    seat_usage.parse_seats([
      #(1, Raw(line_ok)),
      #(2, Raw("   ")),
      #(
        3,
        Raw(
          "{\"label\":\"seat-b\",\"provider\":\"claude\",\"token\":\"tok-2\"}",
        ),
      ),
    ])
}

pub fn refusals_name_the_line_and_never_its_text_test() {
  // Unknown key: the label was readable, the key's name is never printed.
  let unknown =
    refusal([
      Raw(
        "{\"label\":\"seat-a\",\"provider\":\"codex\",\"token\":\"SECRET-TOKEN\",\"extra\":1}",
      ),
    ])
  assert unknown.line == 1
  assert unknown.label == Some("seat-a")
  assert unknown.reason == seat_usage.UnknownKey

  let malformed = refusal([Raw(line_ok), Raw("{\"label\": SECRET-TOKEN")])
  assert malformed.line == 2
  assert malformed.label == None
  assert malformed.reason == seat_usage.MalformedJson
  assert !string.contains(seat_usage.refusal_text(malformed), "SECRET")

  assert refusal([Raw("[1]")]).reason == seat_usage.NotAnObject
  assert refusal([Raw("{\"label\":\"a\"}")]).reason == seat_usage.MissingField
  assert refusal([
      Raw("{\"label\":\"a b\",\"provider\":\"codex\",\"token\":\"t\"}"),
    ]).reason
    == seat_usage.InvalidLabel
  assert refusal([
      Raw("{\"label\":\"a\",\"provider\":\"gemini\",\"token\":\"t\"}"),
    ]).reason
    == seat_usage.InvalidProvider
  assert refusal([
      Raw("{\"label\":\"a\",\"provider\":\"codex\",\"token\":\"t t\"}"),
    ]).reason
    == seat_usage.InvalidToken
  assert refusal([seat_usage.Oversized]).reason == seat_usage.LineTooLong
  assert refusal([seat_usage.NotText]).reason == seat_usage.InvalidUtf8
  assert refusal([Raw(line_ok), Raw(line_ok)]).reason
    == seat_usage.DuplicateLabel
  assert refusal([]).reason == seat_usage.NoSeats
}

pub fn a_label_that_is_not_a_label_is_not_echoed_test() {
  // An operator who pastes a token into the label field must not see it again.
  let found =
    refusal([
      Raw(
        "{\"label\":\"sk-ant-oat01 secret\",\"provider\":\"x\",\"token\":\"t\"}",
      ),
    ])
  assert found.label == None
  assert !string.contains(seat_usage.refusal_text(found), "secret")
}

pub fn a_seat_does_not_print_its_token_test() {
  let assert Ok([seat]) =
    seat_usage.parse_seats([
      #(
        1,
        Raw(
          "{\"label\":\"a\",\"provider\":\"claude\",\"token\":\"KNOWN-TOKEN\"}",
        ),
      ),
    ])
  assert !string.contains(string.inspect(seat), "KNOWN-TOKEN")
  assert !string.contains(
    string.inspect(seat_usage.Report("a", Claude, Error(seat_usage.TimedOut))),
    "KNOWN",
  )
  assert seat_usage.usage_request(seat).url
    == "https://api.anthropic.com/api/oauth/usage"
}

const codex_open =
  "{\"plan_type\":\"plus\",\"rate_limit\":{\"allowed\":true,\"limit_reached\":false,\"primary_window\":{\"used_percent\":42,\"limit_window_seconds\":18000,\"reset_after_seconds\":100,\"reset_at\":1794434400},\"secondary_window\":{\"used_percent\":10.5,\"limit_window_seconds\":604800,\"reset_after_seconds\":9,\"reset_at\":1794700800}},\"credits\":null,\"future_field\":[1,2]}"

const codex_spent =
  "{\"plan_type\":\"pro\",\"rate_limit\":{\"allowed\":false,\"limit_reached\":true,\"primary_window\":{\"used_percent\":100,\"limit_window_seconds\":18000,\"reset_after_seconds\":100,\"reset_at\":1794434400},\"secondary_window\":null},\"additional_rate_limits\":[{\"limit_name\":\"gpt-x limit\",\"metered_feature\":\"codex_x\",\"normal_model_slug\":\"gpt-x\",\"rate_limit\":{\"allowed\":false,\"limit_reached\":true}}]}"

pub fn codex_usage_decodes_test() {
  let assert Ok(reading) =
    seat_usage.read_usage(Codex, codex_open, None, now_ms)
  assert reading.plan == Some("plus")
  assert reading.state == Available
  assert reading.model == None
  let assert [primary, secondary] = reading.windows
  assert primary.name == "primary"
  assert primary.used_fraction == 0.42
  assert primary.resets_at_ms == Some(1_794_434_400_000)
  assert primary.span_seconds == Some(18_000)
  assert secondary.used_fraction == 0.105
}

pub fn codex_exhausted_and_model_limit_test() {
  let assert Ok(reading) =
    seat_usage.read_usage(Codex, codex_spent, Some("gpt-x"), now_ms)
  assert reading.state == Exhausted
  let assert Some(ModelUnavailable(_)) = reading.model

  // A different model is not answered by the usage payload.
  let assert Ok(other) =
    seat_usage.read_usage(Codex, codex_spent, Some("gpt-y"), now_ms)
  assert other.model == None
}

pub fn codex_without_a_limit_is_unknown_test() {
  let assert Ok(reading) =
    seat_usage.read_usage(Codex, "{\"plan_type\":\"free\"}", None, now_ms)
  assert reading.state == Unknown("the payload has no rate_limit")
  assert reading.windows == []
}

pub fn malformed_bodies_are_refused_test() {
  assert seat_usage.read_usage(Codex, "not json", None, now_ms)
    == Error(seat_usage.Malformed)
  assert seat_usage.read_usage(
      Codex,
      "{\"rate_limit\":{\"allowed\":\"yes\",\"limit_reached\":false}}",
      None,
      now_ms,
    )
    == Error(seat_usage.Malformed)
  assert seat_usage.read_usage(Claude, "[]", None, now_ms)
    == Error(seat_usage.Malformed)
}

const claude_open =
  "{\"five_hour\":{\"utilization\":40.0,\"resets_at\":\"2026-11-11T22:00:00.000000+00:00\"},\"seven_day\":{\"utilization\":35,\"resets_at\":\"2026-11-15T00:00:00Z\"},\"seven_day_opus\":null,\"seven_day_sonnet\":{\"utilization\":null,\"resets_at\":null},\"extra_usage\":{\"is_enabled\":false}}"

const claude_spent =
  "{\"five_hour\":{\"utilization\":100,\"resets_at\":\"2026-11-11T22:00:00Z\"},\"seven_day\":{\"utilization\":50,\"resets_at\":\"2026-11-15T00:00:00Z\"},\"seven_day_opus\":{\"utilization\":100,\"resets_at\":\"2026-11-15T00:00:00Z\"}}"

pub fn claude_usage_decodes_test() {
  let assert Ok(reading) =
    seat_usage.read_usage(Claude, claude_open, None, now_ms)
  assert reading.plan == None
  assert reading.state == Available
  let assert [five, seven] = reading.windows
  assert five.name == "five_hour"
  assert five.used_fraction == 0.4
  assert five.resets_at_ms == Some(1_794_434_400_000)
  assert seven.resets_at_ms == Some(1_794_700_800_000)
}

pub fn claude_models_are_answered_only_from_a_full_family_window_test() {
  let assert Ok(spent) =
    seat_usage.read_usage(Claude, claude_spent, Some("claude-opus-4-8"), now_ms)
  assert spent.state == Exhausted
  let assert Some(ModelUnavailable(_)) = spent.model

  let assert Ok(open) =
    seat_usage.read_usage(Claude, claude_open, Some("claude-opus-4-8"), now_ms)
  let assert Some(ModelUnknown(_)) = open.model

  let assert Ok(other) =
    seat_usage.read_usage(Claude, claude_open, Some("haiku"), now_ms)
  let assert Some(ModelUnknown(_)) = other.model
}

pub fn claude_with_no_readings_is_unknown_test() {
  let assert Ok(reading) = seat_usage.read_usage(Claude, "{}", None, now_ms)
  assert reading.windows == []
  let assert Unknown(_) = reading.state
}

pub fn the_model_listing_answers_yes_or_unknown_never_no_test() {
  let assert Ok(base) = seat_usage.read_usage(Codex, codex_open, None, now_ms)
  let listing =
    Ok(
      "{\"models\":[{\"slug\":\"gpt-x\",\"visibility\":\"list\"},{\"slug\":\"gpt-h\",\"visibility\":\"hide\"}]}",
    )

  assert seat_usage.answer_model(base, "gpt-x", listing).model
    == Some(ModelAvailable)
  let assert Some(ModelUnknown(_)) =
    seat_usage.answer_model(base, "gpt-h", listing).model
  let assert Some(ModelUnknown(_)) =
    seat_usage.answer_model(base, "absent", listing).model
  let assert Some(ModelUnknown(_)) =
    seat_usage.answer_model(base, "gpt-x", Error(seat_usage.TimedOut)).model
  let assert Some(ModelUnknown(_)) =
    seat_usage.answer_model(base, "gpt-x", Ok("{}")).model

  // An answer the usage payload already gave is kept.
  let assert Ok(spent) =
    seat_usage.read_usage(Codex, codex_spent, Some("gpt-x"), now_ms)
  let assert Some(ModelUnavailable(_)) =
    seat_usage.answer_model(spent, "gpt-x", listing).model
}

pub fn fetch_failures_get_stable_codes_test() {
  assert seat_usage.failure_code(seat_usage.failure_from_fetch(
      "request_timed_out",
    ))
    == "timeout"
  assert seat_usage.failure_code(seat_usage.failure_from_fetch(
      "response_too_large",
    ))
    == "response_too_large"
  assert seat_usage.failure_code(seat_usage.failure_from_fetch("anything else"))
    == "transport_failed"
  assert seat_usage.failure_code(seat_usage.HttpStatus(429)) == "http_429"
}

fn report(body: String, provider: seat_usage.Provider) -> seat_usage.Report {
  let assert Ok(reading) = seat_usage.read_usage(provider, body, None, now_ms)
  seat_usage.Report("seat-a", provider, Ok(reading))
}

pub fn an_available_seat_is_a_gauge_reading_test() {
  assert seat_usage.to_pool_events(report(codex_open, Codex), now_ms)
    == [
      pool.Observed("seat-a", now_ms, [
        pool.Window(42, 1_794_434_400_000),
        pool.Window(11, 1_794_700_800_000),
      ]),
    ]
}

pub fn an_exhausted_seat_is_a_usage_limit_refusal_with_its_reset_test() {
  let events = seat_usage.to_pool_events(report(claude_spent, Claude), now_ms)
  let assert [pool.Refused("seat-a", _, refusal), pool.Observed(..)] = events
  assert refusal == pool.UsageLimit(Some(1_794_700_800_000))

  // The events drive the real ledger: the seat rests until the later reset.
  let assert Ok(ledger) = pool.new(["seat-a", "seat-b"], 600_000)
  let ledger = list_fold(events, ledger)
  let #(_, effects) = pool.step(ledger, pool.Pick(now_ms + 1))
  assert effects == [pool.Chose("seat-b")]
}

fn list_fold(events: List(pool.Event), ledger: pool.Pool) -> pool.Pool {
  case events {
    [] -> ledger
    [event, ..rest] -> {
      let #(next, _) = pool.step(ledger, event)
      list_fold(rest, next)
    }
  }
}

pub fn an_exhausted_seat_with_no_reset_leaves_the_hold_to_the_ledger_test() {
  let body =
    "{\"rate_limit\":{\"allowed\":false,\"limit_reached\":true,\"primary_window\":{\"used_percent\":100}}}"
  let events = seat_usage.to_pool_events(report(body, Codex), now_ms)
  let assert [pool.Refused(_, _, refusal), ..] = events
  assert refusal == pool.UsageLimit(None)
}

pub fn unknown_and_failed_seats_say_nothing_to_the_pool_test() {
  assert seat_usage.to_pool_events(
      seat_usage.Report("a", Codex, Error(seat_usage.HttpStatus(401))),
      now_ms,
    )
    == []
  assert seat_usage.to_pool_events(
      report("{\"plan_type\":\"x\"}", Codex),
      now_ms,
    )
    == []
}
