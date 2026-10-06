//// Authored implementations retain a JSON counter across callback replacement.
//// Every version is compiled from these sources inside the ordinary jail.

import gleam/int
import gleam/list
import gleam/string
import support/evolution

/// Produces the immutable sources for one live callback version.
///
/// ## Examples
///
/// `extension(2)` adds a declared migration contract to the echo fixture.
pub fn extension(version: Int) -> List(#(String, String)) {
  let marker = "version-" <> int.to_string(version)
  evolution.extension(version)
  |> list.map(fn(file) {
    case file {
      #("extension.toml", text) -> #(file.0, text <> contract(version))
      #("src/evolution_echo.gleam", _) -> #(file.0, implementation(marker))
      other -> other
    }
  })
  |> list.append([#("src/evolution_migration.gleam", migration)])
}

/// Produces a compiled migration refusal without changing the message boundary.
///
/// ## Examples
///
/// `refusing(3)` passes author tests but refuses current-state migration.
pub fn refusing(version: Int) -> List(#(String, String)) {
  extension(version)
  |> list.map(fn(file) {
    case file {
      #("src/evolution_migration.gleam", _) -> #(
        file.0,
        "//// Intentional value refusal leaves the old callback serving.\n"
          <> "pub fn migrate(_from: String, _state: String) -> Result(String, String) { Error(\"intentional migration refusal\") }\n",
      )
      other -> other
    }
  })
}

/// Produces a pure nonterminating migration to exercise the bounded task.
///
/// ## Examples
///
/// `timing_out(4)` cannot replace state before its migration deadline.
pub fn timing_out(version: Int) -> List(#(String, String)) {
  extension(version)
  |> list.map(fn(file) {
    case file {
      #("src/evolution_migration.gleam", _) -> #(
        file.0,
        "//// Deliberately never returns, testing trusted migration custody.\n"
          <> "pub fn migrate(_from: String, state: String) -> Result(String, String) { repeat(state) }\n"
          <> "fn repeat(state: String) -> Result(String, String) { case state { \"\" -> repeat(\"x\") _ -> repeat(\"\") } }\n",
      )
      other -> other
    }
  })
}

/// Produces an older state representation that cannot accept current v2 work.
///
/// ## Examples
///
/// `legacy_only(5)` still passes author tests, but declares only v1 migration.
pub fn legacy_only(version: Int) -> List(#(String, String)) {
  extension(version)
  |> list.map(fn(file) {
    case file {
      #("extension.toml", text) -> #(
        file.0,
        text
          |> string.replace(
            "state_version = \"v" <> int.to_string(version) <> "\"",
            "state_version = \"v1\"",
          )
          |> string.replace("accepts = [\"v1\", \"v2\"]", "accepts = [\"v1\"]"),
      )
      other -> other
    }
  })
}

/// Produces a candidate whose authored definition never returns.
///
/// ## Examples
///
/// `definition_timing_out(6)` passes its independent render test but cannot load.
pub fn definition_timing_out(version: Int) -> List(#(String, String)) {
  extension(version)
  |> list.map(fn(file) {
    case file {
      #("src/evolution_echo.gleam", text) -> #(
        file.0,
        text
          |> string.replace(
            "pub fn definition() -> live.Definition { live.Definition(\"0\", handle) }",
            "pub fn definition() -> live.Definition { repeat_definition(0) }\nfn repeat_definition(n: Int) -> live.Definition { case n { 0 -> repeat_definition(1) 1 -> repeat_definition(0) _ -> live.Definition(\"0\", handle) } }",
          ),
      )
      other -> other
    }
  })
}

/// Changes hook subscriptions while keeping the authored module set fixed.
///
/// ## Examples
///
/// `changed_hooks(7)` requires rejection by the live compatibility boundary.
pub fn changed_hooks(version: Int) -> List(#(String, String)) {
  extension(version)
  |> list.map(fn(file) {
    case file {
      #("extension.toml", text) -> #(
        file.0,
        text
          <> "\n[[hook]]\nevent = \"tool_call\"\nentry = \"evolution_echo\"\n",
      )
      other -> other
    }
  })
}

fn contract(version: Int) -> String {
  "\n[live]\nentry = \"evolution_echo\"\nmigration = \"evolution_migration\"\n"
  <> "boundary = \"echo-v1\"\nstate_version = \"v"
  <> int.to_string(version)
  <> "\"\naccepts = [\"v1\", \"v2\"]\npause_ms = 1000\nmax_state_bytes = 4096\n"
}

fn implementation(marker: String) -> String {
  "//// One JSON counter owned by the trusted satellite actor.\n"
  <> "import ext\nimport ext/live\nimport gleam/dynamic/decode\nimport gleam/json\nimport gleam/int\nimport gleam/result\n\n"
  <> "pub fn render(say: String) -> String { \""
  <> marker
  <> ":\" <> say }\n"
  <> "pub fn definition() -> live.Definition { live.Definition(\"0\", handle) }\n"
  <> "fn handle(state: String, asked: live.Asked) -> Result(#(String, live.Answer), String) {\n"
  <> "  use count <- result.try(json.parse(state, decode.int) |> result.replace_error(\"invalid counter\"))\n"
  <> "  use args <- result.try(live.arguments(asked))\n"
  <> "  use say <- result.try(decode.run(args, { use say <- decode.field(\"say\", decode.string) decode.success(say) }) |> result.replace_error(\"invalid argument\"))\n"
  <> "  let next = count + 1\n"
  <> "  Ok(#(int.to_string(next), live.reply(ext.text(render(say) <> \":count=\" <> int.to_string(next)))))\n}\n"
}

const migration =
  "//// Pure total decoding preserves current work in both directions.\n"
  <> "import gleam/dynamic/decode\nimport gleam/json\nimport gleam/int\nimport gleam/result\n\n"
  <> "pub fn migrate(from: String, state: String) -> Result(String, String) {\n"
  <> "  case from {\n    \"v1\" | \"v2\" -> json.parse(state, decode.int) |> result.map(int.to_string) |> result.replace_error(\"invalid counter\")\n"
  <> "    _ -> Error(\"unsupported version\")\n  }\n}\n"
