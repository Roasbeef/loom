//// ADR-014 §4's precedence, driven with values: which servers a session
//// runs when `loom.toml` and installed profile extensions both name some,
//// and which installed profiles are refused. Also the profile's JSON form,
//// which an install record keeps.
////
//// Each test names the rule it pins. Two of them are mutation targets: a
//// first-wins resolution in place of refusing both sides, and an installed
//// profile allowed to replace a `loom.toml` table.

import client/lsp/profile.{type LspServer}
import client/lsp/profiles
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- precedence ---------------------------------------------------------------

pub fn configured_servers_alone_come_back_sorted_test() {
  let go = server("go", [".go"], "gopls")
  let gleam = server("gleam", [".gleam"], "gleam")
  assert profiles.effective_lsp_servers(configured: [go, gleam], installed: [])
    == #([gleam, go], [])
}

pub fn a_non_conflicting_profile_joins_the_session_test() {
  let gleam = server("gleam", [".gleam"], "gleam")
  let go = server("go", [".go"], "gopls")
  let rust = server("rust", [".rs"], "rust-analyzer")
  assert profiles.effective_lsp_servers(configured: [gleam], installed: [
      #("lsp_rust", rust),
      #("lsp_go", go),
    ])
    == #([gleam, go, rust], [])
}

/// The operator's table replaces the installed profile whole: nothing of
/// the installed one survives, not even a field the table left at its
/// default. And replacement is not a refusal.
pub fn a_loom_toml_table_replaces_a_profile_whole_test() {
  let mine = server("go", [".go"], "/opt/gopls")
  let theirs =
    profile.LspServer(
      ..server("go", [".go", ".mod"], "gopls"),
      env: ["GOFLAGS"],
      hint: Some("Qualify as package.Name"),
    )
  assert profiles.effective_lsp_servers(configured: [mine], installed: [
      #("lsp_go", theirs),
    ])
    == #([mine], [])
}

/// The mutation this pins: letting the installed profile win would start
/// the extension's binary for every `.go` file. The operator's table is
/// never the refused side.
pub fn a_profile_claiming_a_configured_extension_is_refused_test() {
  let mine = server("go", [".go"], "/opt/gopls")
  let theirs = server("golang", [".go"], "gopls")
  assert profiles.effective_lsp_servers(configured: [mine], installed: [
      #("lsp_go", theirs),
    ])
    == #([mine], [
      profiles.Refusal(
        extension: "lsp_go",
        server: "golang",
        other: profiles.Configured("go"),
        conflict: profiles.SameFileExtension(".go"),
      ),
    ])
}

/// Two installed profiles of one name: both are refused, each naming the
/// other. The mutation this pins is first-wins.
pub fn two_profiles_sharing_a_name_are_both_refused_test() {
  let a = server("go", [".go"], "gopls")
  let b = server("go", [".golang"], "other-gopls")
  let #(servers, refusals) =
    profiles.effective_lsp_servers(configured: [], installed: [
      #("lsp_a", a),
      #("lsp_b", b),
    ])
  assert servers == []
  assert refusals
    == [
      profiles.Refusal(
        extension: "lsp_a",
        server: "go",
        other: profiles.Installed(extension: "lsp_b", server: "go"),
        conflict: profiles.SameServer,
      ),
      profiles.Refusal(
        extension: "lsp_b",
        server: "go",
        other: profiles.Installed(extension: "lsp_a", server: "go"),
        conflict: profiles.SameServer,
      ),
    ]
}

pub fn two_profiles_sharing_an_extension_are_both_refused_test() {
  let a = server("go", [".go"], "gopls")
  let b = server("golang", [".mod", ".go"], "other")
  let rust = server("rust", [".rs"], "rust-analyzer")
  let #(servers, refusals) =
    profiles.effective_lsp_servers(configured: [], installed: [
      #("lsp_b", b),
      #("lsp_rust", rust),
      #("lsp_a", a),
    ])
  assert servers == [rust]
  assert refusals
    == [
      profiles.Refusal(
        extension: "lsp_a",
        server: "go",
        other: profiles.Installed(extension: "lsp_b", server: "golang"),
        conflict: profiles.SameFileExtension(".go"),
      ),
      profiles.Refusal(
        extension: "lsp_b",
        server: "golang",
        other: profiles.Installed(extension: "lsp_a", server: "go"),
        conflict: profiles.SameFileExtension(".go"),
      ),
    ]
}

/// Every profile involved is refused, even along a chain: `a` and `b`
/// share `.x`, `b` and `c` share `.y`, so all three are refused, whatever
/// order they were discovered in.
pub fn a_chain_of_conflicts_refuses_every_link_in_any_order_test() {
  let a = server("a", [".x"], "a")
  let b = server("b", [".x", ".y"], "b")
  let c = server("c", [".y"], "c")
  let forward = [#("ext_a", a), #("ext_b", b), #("ext_c", c)]
  let #(servers, refusals) =
    profiles.effective_lsp_servers(configured: [], installed: forward)
  assert servers == []
  assert list.map(refusals, fn(refusal) { refusal.server })
    == ["a", "b", "b", "c"]
  assert profiles.effective_lsp_servers(
      configured: [],
      installed: list.reverse(forward),
    )
    == #(servers, refusals)
}

/// A replaced profile never enters the conflict set, so two installed
/// profiles both named for a server `loom.toml` configures are replaced,
/// not refused against each other.
pub fn replaced_profiles_are_not_judged_test() {
  let mine = server("go", [".go"], "/opt/gopls")
  let a = server("go", [".go"], "gopls")
  let b = server("go", [".go"], "other-gopls")
  assert profiles.effective_lsp_servers(configured: [mine], installed: [
      #("lsp_a", a),
      #("lsp_b", b),
    ])
    == #([mine], [])
}

pub fn a_refusal_reads_for_an_operator_test() {
  assert profiles.describe_claimant(profiles.Configured("go"))
    == "loom.toml [lsp.go]"
  assert profiles.describe_claimant(profiles.Installed("lsp_go", "go"))
    == "extension lsp_go [lsp.go]"
  assert profiles.describe_conflict(profiles.SameServer)
    == "both name the same server"
  assert profiles.describe_conflict(profiles.SameFileExtension(".go"))
    == "both claim .go"
}

// --- the JSON form --------------------------------------------------------------

pub fn a_profile_round_trips_through_json_test() {
  let full =
    profile.LspServer(
      name: "ex",
      command: ["elixir-ls", "--stdio"],
      extensions: [".ex", ".exs"],
      root_markers: ["mix.exs"],
      project: profile.ProjectWritable,
      readable: [profile.AbsolutePath("/opt/elixir"), profile.HomePath(".mix")],
      writable: [profile.CachePath("elixir-ls")],
      env: ["MIX_ENV"],
      language_id: "elixir",
      qualifier_separators: ["."],
      module_case: profile.Snake,
      hint: Some("Qualify as MyApp.Accounts.name"),
    )
  let bare = server("go", [".go"], "gopls")
  assert round_trip(full) == Ok(full)
  assert round_trip(bare) == Ok(bare)
}

pub fn a_malformed_profile_is_refused_test() {
  let text = json.to_string(profile.encode_server(server("go", [".go"], "g")))
  let refused = fn(from, to) {
    let assert Error(_error) =
      json.parse(replace(text, from, to), profile.server_decoder())
      as "every one of these edits makes the profile unreadable"
    Nil
  }
  refused("\"read-only\"", "\"sometimes\"")
  refused("\"as-written\"", "\"camel\"")
  refused("\"command\":[\"g\"]", "\"command\":\"g\"")
}

// --- helpers --------------------------------------------------------------------

fn server(
  name: String,
  extensions: List(String),
  command: String,
) -> LspServer {
  profile.LspServer(
    name:,
    command: [command],
    extensions:,
    root_markers: ["marker"],
    project: profile.ProjectReadOnly,
    readable: [],
    writable: [],
    env: [],
    language_id: name,
    qualifier_separators: ["."],
    module_case: profile.AsWritten,
    hint: None,
  )
}

fn round_trip(server: LspServer) -> Result(LspServer, json.DecodeError) {
  json.parse(
    json.to_string(profile.encode_server(server)),
    profile.server_decoder(),
  )
}

fn replace(text: String, from: String, to: String) -> String {
  let assert Ok(#(before, after)) = string.split_once(text, from)
    as "the encoded profile carries the text being replaced"
  before <> to <> after
}
