//// A model-authored executable skill exercises JSON input and a real cap process.
//// The retained source has no entrypoint until the native current-caller adapter
//// supplies fresh JSON. Its author check and every invocation execute the broker's
//// real jailed process path rather than returning a precomputed fixture result.

import core/json
import gleam/string

/// Returns the exact immutable fresh-input contract for this skill.
///
/// ## Examples
///
/// `schema()` requires the current invocation's `say` string.
pub fn schema() -> json.JsonValue {
  json.Object([
    #("type", json.String("object")),
    #(
      "properties",
      json.Object([
        #("say", json.Object([#("type", json.String("string"))])),
      ]),
    ),
    #("required", json.Array([json.String("say")])),
    #("additionalProperties", json.Bool(False)),
  ])
}

/// Returns the bounded source the scripted provider writes through `fs_write`.
///
/// ## Examples
///
/// `source()` defines `run(input: String)` and candidate-owned `author_checks()`.
pub fn source() -> String {
  "//// This immutable skill decodes each fresh input before a brokered process.\n"
  <> "import cap/proc\nimport cap/report\nimport gleam/dynamic/decode\n"
  <> "import gleam/json\nimport gleam/string\n\n"
  <> "/// Decodes fresh JSON without granting or retaining caller authority.\n"
  <> "pub fn run(input: String) -> report.Outcome {\n"
  <> "  let decoder = {\n    use say <- decode.field(\"say\", decode.string)\n"
  <> "    decode.success(say)\n  }\n\n"
  <> "  case json.parse(input, decoder) {\n"
  <> "    Error(_) -> report.failure(\"invalid fresh skill input\")\n"
  <> "    Ok(say) -> native_echo(say)\n  }\n}\n\n"
  <> "/// Checks the retained decoder and a real jailed process.\n"
  <> "pub fn author_checks() -> report.Outcome {\n"
  <> "  let observed = run(\"{\\\"say\\\":\\\"author-test\\\"}\")\n"
  <> "  case observed == report.text(\"skill-v1:author-test\") {\n"
  <> "    True -> report.text(\"immutable skill checked\")\n"
  <> "    False -> report.failure(\"skill check did not execute the expected process\")\n"
  <> "  }\n}\n\n"
  <> "fn native_echo(say: String) -> report.Outcome {\n"
  <> "  case proc.run(proc.command([\"/bin/echo\", \"skill-v1:\" <> say])) {\n"
  <> "    Ok(output) if output.exit_code == 0 -> report.text(string.trim(output.stdout))\n"
  <> "    Ok(_) -> report.failure(\"native process failed\")\n"
  <> "    Error(_) -> report.failure(\"native process unavailable\")\n  }\n}\n"
}

/// Adds a real process read of another session's native protected artifact.
/// A masked directory child is absent on Linux and denied on Darwin; both
/// outcomes must name the existing target and return none of its source bytes.
/// The test caller grants the entire state root before applying its native mask.
///
/// ## Examples
///
/// `source_with_protected(path, public_path)` checks a readable control first.
pub fn source_with_protected(path: String, public_path: String) -> String {
  let literal = json.to_string(json.String(path))
  let public_literal = json.to_string(json.String(public_path))
  string.replace(
    source(),
    "    Ok(say) -> native_echo(say)",
    "    Ok(\"probe-protected-source\") -> protected_read()\n"
      <> "    Ok(say) -> native_echo(say)",
  )
  <> "\nfn protected_read() -> report.Outcome {\n"
  <> "  case proc.run(proc.command([\"/bin/cat\", "
  <> public_literal
  <> "])) {\n"
  <> "    Ok(output) if output.exit_code == 0 && output.stdout == \"public readable control\\n\" -> protected_target()\n"
  <> "    Ok(output) -> report.text(\"public control failed: \" <> output.stderr <> output.stdout)\n"
  <> "    Error(proc.ProcDenied(code, reason)) -> report.text(\"public control denied: \" <> code <> \" \" <> reason)\n"
  <> "    Error(proc.SpawnFailed(reason)) -> report.text(\"public control spawn failed: \" <> reason)\n"
  <> "    Error(proc.ProcUnavailable(reason)) -> report.text(\"public control unavailable: \" <> reason)\n"
  <> "  }\n}\n\nfn protected_target() -> report.Outcome {\n"
  <> "  let path = "
  <> literal
  <> "\n\n"
  <> "  case proc.run(proc.command([\"/bin/cat\", path])) {\n"
  <> "    Ok(output) -> {\n"
  <> "      let hidden = string.contains(output.stderr, path <> \": Permission denied\")\n"
  <> "        || string.contains(output.stderr, path <> \": Operation not permitted\")\n"
  <> "        || string.contains(output.stderr, path <> \": No such file or directory\")\n"
  <> "      case output.exit_code == 1 && output.stdout == \"\" && hidden {\n"
  <> "        True -> report.text(\"protected source hidden\")\n"
  <> "        False -> report.text(\"protected target diagnostic: stdout=\" <> output.stdout <> \" stderr=\" <> output.stderr)\n"
  <> "      }\n    }\n"
  <> "    Error(proc.ProcDenied(code, reason)) -> report.text(\"protected native refusal: \" <> code <> \" \" <> reason)\n"
  <> "    Error(proc.SpawnFailed(reason)) -> report.text(\"protected spawn refusal: \" <> reason)\n"
  <> "    Error(proc.ProcUnavailable(reason)) -> report.failure(\"protected probe unavailable: \" <> reason)\n"
  <> "  }\n}\n"
}

/// Adds a target whose accessibility changes only with the calling session.
/// The same retained source proves readable bytes in the author and an exact
/// named OS denial with no bytes in a second caller. Both first execute a public
/// control, so neither a broken process runner nor a generic refusal can pass.
///
/// ## Examples
///
/// `source_with_caller_policy(native_secret, public, caller_secret)` compares callers.
pub fn source_with_caller_policy(
  protected: String,
  public: String,
  caller_target: String,
) -> String {
  let target = json.to_string(json.String(caller_target))
  let public_literal = json.to_string(json.String(public))
  string.replace(
    source_with_protected(protected, public),
    "    Ok(say) -> native_echo(say)",
    "    Ok(\"probe-caller-policy\") -> caller_policy_read()\n"
      <> "    Ok(say) -> native_echo(say)",
  )
  <> "\nfn caller_policy_read() -> report.Outcome {\n"
  <> "  case proc.run(proc.command([\"/bin/cat\", "
  <> public_literal
  <> "])) {\n"
  <> "    Ok(output) if output.exit_code == 0 && output.stdout == \"public readable control\\n\" -> caller_policy_target()\n"
  <> "    Ok(_) -> report.failure(\"caller public control did not read its expected bytes\")\n"
  <> "    Error(_) -> report.failure(\"caller public control did not execute\")\n"
  <> "  }\n}\n\nfn caller_policy_target() -> report.Outcome {\n"
  <> "  let path = "
  <> target
  <> "\n\n"
  <> "  case proc.run(proc.command([\"/bin/cat\", path])) {\n"
  <> "    Ok(output) if output.exit_code == 0 && output.stdout == \"caller policy readable bytes\\n\" -> report.text(output.stdout)\n"
  <> "    Ok(output) -> {\n"
  <> "      let named_denial = string.contains(output.stderr, path <> \": Permission denied\")\n"
  <> "        || string.contains(output.stderr, path <> \": Operation not permitted\")\n"
  <> "        || string.contains(output.stderr, path <> \": No such file or directory\")\n"
  <> "      case output.exit_code == 1 && output.stdout == \"\" && named_denial {\n"
  <> "        True -> report.text(\"caller policy target hidden\")\n"
  <> "        False -> report.failure(\"caller policy target had an unexpected result\")\n"
  <> "      }\n    }\n"
  <> "    Error(_) -> report.failure(\"caller policy target did not reach the OS read\")\n"
  <> "  }\n}\n"
}
