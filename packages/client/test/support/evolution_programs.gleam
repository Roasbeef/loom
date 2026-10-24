//// The `code_mode` programs a scripted model submits to drive governed
//// evolution, and the reading of their results.
////
//// Evolution has no direct tools, so every acceptance step that used to be a
//// tool call is a program importing `cap/evolution`. The sources here are
//// the real thing: they are vetted, compiled in the hermetic build and run
//// in a jailed satellite, and each capability call reaches the session's
//// real catalogue. Only the model that would have written them is scripted.
////
//// A program's result text is its returned value rendered as JSON, then a
//// newline, then the sandbox line. `result_value` reads the first line.

import core/json
import gleam/list
import gleam/string
import support/provider_http as peer

/// The tool every evolution step now goes through.
pub const tool_name = "code_mode"

/// The arguments of one `code_mode` call that submits `source` inline.
///
/// ## Examples
///
/// `arguments("pub fn main() { ... }")` is the object the tool decodes.
pub fn arguments(source: String) -> json.JsonValue {
  json.Object([#("program", json.String(source))])
}

/// A Gleam string literal for `text`. JSON's string syntax is Gleam's for
/// every character the fixtures use, so the encoder is the escaper.
///
/// ## Examples
///
/// `literal("a\"b")` is `"\"a\\\"b\""`.
pub fn literal(text: String) -> String {
  json.to_string(json.String(text))
}

/// A program that captures `directory` as a candidate and then runs its
/// author tests, returning the test result, which names the candidate and
/// carries the retained evidence.
///
/// ## Examples
///
/// `propose_and_test("v1", "echo", "extension", "evolution_check", ...)`.
pub fn propose_and_test(
  directory directory: String,
  name name: String,
  kind kind: String,
  test_entry test_entry: String,
  description description: String,
  schema schema: String,
) -> String {
  let constructor = case kind {
    "program" -> "evolution.Program"
    "prompt" -> "evolution.Prompt"
    _ -> "evolution.Extension"
  }
  string.join(
    [
      "import cap/evolution",
      "import cap/report",
      "import gleam/option.{Some}",
      "import gleam/result",
      "",
      "pub fn main() -> report.Outcome {",
      "  case run() {",
      "    Ok(evidence) -> report.value(evidence)",
      "    Error(reason) -> report.failure(reason)",
      "  }",
      "}",
      "",
      "fn run() -> Result(report.Value, String) {",
      "  let proposal =",
      "    evolution.Proposal(",
      "      ..evolution.proposal("
        <> literal(directory)
        <> ", "
        <> literal(name)
        <> ", "
        <> constructor
        <> "),",
      "      test_entry: Some(" <> literal(test_entry) <> "),",
      "      description: Some(" <> literal(description) <> "),",
      "      input_schema: Some(" <> literal(schema) <> "),",
      "    )",
      "  use proposed <- result.try(",
      "    evolution.propose(proposal) |> result.map_error(evolution.error_text),",
      "  )",
      "  use id <- result.try(",
      "    report.field(proposed, \"candidate_id\")",
      "    |> result.try(report.as_string)",
      "    |> result.replace_error(\"propose returned no candidate_id\"),",
      "  )",
      "  evolution.test_candidate(id) |> result.map_error(evolution.error_text)",
      "}",
      "",
    ],
    "\n",
  )
}

/// A program that discovers what the operator selected and calls the first
/// callable it finds with `{"say": say}`, returning the whole `active` list
/// and the invocation result. This is the discover-then-call sequence a model
/// writes once and a direct-tool model needed two round trips for.
///
/// ## Examples
///
/// `catalogue_and_invoke("fresh")` returns `{"active":[..],"invoked":..}`.
pub fn catalogue_and_invoke(say: String) -> String {
  string.join(
    [
      "import cap/evolution",
      "import cap/report",
      "import gleam/list",
      "import gleam/result",
      "",
      "pub fn main() -> report.Outcome {",
      "  case run() {",
      "    Ok(value) -> report.value(value)",
      "    Error(reason) -> report.failure(reason)",
      "  }",
      "}",
      "",
      "fn text(entry: report.Value, key: String) -> Result(String, String) {",
      "  report.field(entry, key)",
      "  |> result.try(report.as_string)",
      "  |> result.replace_error(\"the catalogue entry has no \" <> key)",
      "}",
      "",
      "fn run() -> Result(report.Value, String) {",
      "  use catalogue <- result.try(",
      "    evolution.catalogue(0, 0, 8) |> result.map_error(evolution.error_text),",
      "  )",
      "  use active <- result.try(",
      "    report.field(catalogue, \"active\")",
      "    |> result.try(report.as_list)",
      "    |> result.replace_error(\"the catalogue has no active list\"),",
      "  )",
      "  use entry <- result.try(",
      "    list.first(active) |> result.replace_error(\"nothing is selected\"),",
      "  )",
      "  use id <- result.try(text(entry, \"candidate_id\"))",
      "  use name <- result.try(text(entry, \"name\"))",
      "  use generation <- result.try(",
      "    report.field(entry, \"generation\")",
      "    |> result.try(report.as_int)",
      "    |> result.replace_error(\"the catalogue entry has no generation\"),",
      "  )",
      "  use invoked <- result.try(",
      "    evolution.invoke(",
      "      id,",
      "      generation,",
      "      name,",
      "      report.object([#(\"say\", report.string("
        <> literal(say)
        <> "))]),",
      "    )",
      "    |> result.map_error(evolution.error_text),",
      "  )",
      "  Ok(report.object([#(\"active\", report.list(active)), #(\"invoked\", invoked)]))",
      "}",
      "",
    ],
    "\n",
  )
}

/// A program that returns the catalogue and nothing else.
///
/// ## Examples
///
/// `catalogue_only()` returns the first page of the catalogue.
pub fn catalogue_only() -> String {
  string.join(
    [
      "import cap/evolution",
      "import cap/report",
      "",
      "pub fn main() -> report.Outcome {",
      "  case evolution.catalogue(0, 0, 8) {",
      "    Ok(catalogue) -> report.value(catalogue)",
      "    Error(error) -> report.failure(evolution.error_text(error))",
      "  }",
      "}",
      "",
    ],
    "\n",
  )
}

/// A program that reads the session's own bounded transcript excerpts.
///
/// ## Examples
///
/// `trace(8)` returns up to eight excerpts for the actual model.
pub fn trace(limit: Int) -> String {
  string.join(
    [
      "import cap/evolution",
      "import cap/report",
      "",
      "pub fn main() -> report.Outcome {",
      "  case evolution.trace(" <> string.inspect(limit) <> ") {",
      "    Ok(brief) -> report.value(brief)",
      "    Error(error) -> report.failure(evolution.error_text(error))",
      "  }",
      "}",
      "",
    ],
    "\n",
  )
}

/// The value the latest tool result in `requests` returned, parsed from the
/// first line of its text. Asserts the result succeeded, so a refusal or a
/// compile failure stops the script where it happened.
///
/// ## Examples
///
/// `result_value(requests)` is the program's returned JSON.
pub fn result_value(requests: List(peer.ObservedRequest)) -> json.JsonValue {
  let assert Ok(request) = list.last(requests)
    as "a computed answer receives the actual request it is answering"
  let assert peer.SuccessfulToolResult(_, text) = request.latest
    as "the program must complete before this script can advance"
  let assert Ok(value) = json.parse(first_line(text))
    as "a program returns its value as one JSON document"
  value
}

/// The text of the first line, which is the program's rendered value.
///
/// ## Examples
///
/// `first_line("{}\nsandbox: ok")` is `"{}"`.
pub fn first_line(text: String) -> String {
  case string.split_once(text, "\n") {
    Ok(#(line, _)) -> line
    Error(Nil) -> text
  }
}
