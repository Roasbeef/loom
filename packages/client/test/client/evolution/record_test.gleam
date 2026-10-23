import client/evolution/program
import client/evolution/record
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn candidate() -> record.Candidate {
  record.identified(record.Candidate(
    id: record.placeholder(),
    name: "example",
    kind: record.Extension,
    scope: record.Session("session-a"),
    origin: record.Origin("session-a", "main", "/workspace", None),
    identity: record.Identity("build-v1", "extension-v1", "evaluator-v1"),
    files: [
      #(
        "extension.toml",
        "[extension]\nname=\"example\"\nversion=\"0.1.0\"\ndescription=\"Example\"\nlicense=\"MIT\"\ntier=\"jailed\"\n[[tool]]\nname=\"example\"\ndescription=\"Example\"\nprompt_snippet=\"Use example.\"\nparameters=\"schema/example.json\"\nentry=\"example\"\ntimeout_ms=1000\n",
      ),
      #("schema/example.json", "{}"),
      #("src/example.gleam", "pub fn run() { 1 }"),
      #("test/example_test.gleam", "pub fn main() { 1 }"),
    ],
    test_entry: Some("example_test"),
    description: "Example",
    input_schema: "{}",
  ))
}

pub fn immutable_identity_covers_source_tests_authority_and_build_test() {
  let original = candidate()
  let changed = [
    record.Candidate(..original, files: [
      #("src/example.gleam", "pub fn run() { 2 }"),
    ]),
    record.Candidate(..original, test_entry: Some("other_test")),
    record.Candidate(..original, scope: record.Workspace("/workspace")),
    record.Candidate(
      ..original,
      identity: record.Identity("build-v2", "extension-v1", "evaluator-v1"),
    ),
    record.Candidate(..original, input_schema: "{\"type\":\"string\"}"),
  ]
  list.each(changed, fn(candidate) {
    { record.identified(candidate).id == original.id } |> should.be_false
  })
  record.decode_candidate(record.encode_candidate(original))
  |> should.equal(Ok(original))
  record.decode_candidate(record.encode_candidate(
    record.Candidate(..original, description: "tampered"),
  ))
  |> should.be_error
}

pub fn evidence_identity_covers_verdict_observation_and_evaluator_test() {
  let original =
    record.observed(record.Evidence(
      id: record.evidence_placeholder(),
      candidate_id: candidate().id,
      identity: candidate().identity,
      at_ms: 1000,
      purpose: record.AuthorTests,
      verdict: record.Passed,
      observation: "{\"checks\":1}",
    ))
  record.decode_evidence(record.encode_evidence(original))
  |> should.equal(Ok(original))
  let altered = record.Evidence(..original, observation: "{\"checks\":0}")
  record.decode_evidence(record.encode_evidence(altered)) |> should.be_error
  { record.observed(altered).id == original.id } |> should.be_false
}

pub fn fresh_json_skill_input_is_quoted_as_data_test() {
  let source =
    "import cap/report\npub fn run(input: String) -> report.Outcome { report.ok(report.text(input)) }"
  let payload = "\"})\npub fn injected() { 1 }\n//"
  let generated = program.adapter(source, payload)
  string.contains(generated, "run(\"\\\"})\\n") |> should.be_true
}
