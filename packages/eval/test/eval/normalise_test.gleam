//// Tests for the replay lane's request normalisation: what makes two
//// requests the same request, and what a divergence summary may say.

import eval/normalise
import gleam/string
import provider/http.{HttpRequest}

fn request(headers: List(#(String, String)), body: String) -> http.HttpRequest {
  HttpRequest(
    method: "POST",
    url: "https://api.example.test/v1/messages?key=query-secret",
    headers:,
    body:,
  )
}

pub fn path_and_date_normalised_test() {
  let one =
    request(
      [],
      "{\"system\":\"work in /tmp/trial-one/a.txt\",\"note\":\"2026-01-02T03:04:05.678Z\"}",
    )
  let other =
    request(
      [],
      "{\"note\":\"2031-12-31 23:59:00+01:00\",\"system\":\"work in /home/x/trial-two/a.txt\"}",
    )

  assert normalise.request_digest(one, "/tmp/trial-one")
    == normalise.request_digest(other, "/home/x/trial-two/")

  assert normalise.text("on 2026-01-02 we ran", "/w") == "on <date> we ran"
  assert normalise.text("v12026-01-02", "/w") == "v12026-01-02"
  assert normalise.text("anything", "") == "anything"
}

pub fn headers_never_digested_test() {
  let body = "{\"model\":\"m\"}"
  let one = request([#("x-api-key", "key-one"), #("x-request-id", "a")], body)
  let two = request([#("x-api-key", "key-two"), #("x-request-id", "b")], body)

  assert normalise.request_digest(one, "/w")
    == normalise.request_digest(two, "/w")
}

pub fn secret_named_keys_are_dropped_test() {
  let one =
    request([], "{\"model\":\"m\",\"api_key\":\"one\",\"max_tokens\":1}")
  let two =
    request([], "{\"model\":\"m\",\"X-Api-Key\":\"two\",\"max_tokens\":1}")
  let different = request([], "{\"model\":\"m\",\"max_tokens\":2}")

  assert normalise.request_digest(one, "/w")
    == normalise.request_digest(two, "/w")
  assert normalise.request_digest(one, "/w")
    != normalise.request_digest(different, "/w")
}

pub fn query_and_key_order_do_not_matter_test() {
  let one = request([], "{\"a\":1,\"b\":[1,2]}")
  let two =
    HttpRequest(
      ..request([], "{\"b\":[1,2],\"a\":1}"),
      url: "https://api.example.test/v1/messages",
    )
  let reordered_array = request([], "{\"a\":1,\"b\":[2,1]}")

  assert normalise.request_digest(one, "/w")
    == normalise.request_digest(two, "/w")
  assert normalise.request_digest(one, "/w")
    != normalise.request_digest(reordered_array, "/w")
}

pub fn non_json_body_digests_its_text_test() {
  let one = request([], "plain text at 2026-01-02")
  let two = request([], "plain text at 2027-02-03")
  let other = request([], "other text at 2026-01-02")

  assert normalise.request_digest(one, "/w")
    == normalise.request_digest(two, "/w")
  assert normalise.request_digest(one, "/w")
    != normalise.request_digest(other, "/w")
}

pub fn summary_names_the_path_and_lengths_only_test() {
  let one =
    normalise.view(request([], "{\"system\":\"be careful\",\"n\":1}"), "/w")
  let two =
    normalise.view(
      request(
        [],
        "{\"system\":\"be careless sk-ant-api03-PLANTEDSECRET\",\"n\":1}",
      ),
      "/w",
    )
  let summary = normalise.summary(one.leaves, two.leaves)

  assert string.contains(summary, "body.system")
  assert string.contains(summary, "expected 12 chars")
  assert !string.contains(summary, "PLANTED")
  assert !string.contains(summary, "careless")
  assert normalise.summary(one.leaves, one.leaves)
    == "no difference in the normalised request"
}

pub fn summary_reports_missing_and_extra_leaves_test() {
  let short = normalise.view(request([], "{\"a\":1}"), "/w")
  let long = normalise.view(request([], "{\"a\":1,\"b\":2}"), "/w")

  assert string.contains(normalise.summary(short.leaves, long.leaves), "body.b")
  assert string.contains(normalise.summary(long.leaves, short.leaves), "body.b")
}
