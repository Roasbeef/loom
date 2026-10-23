//// gopls names a method in a file's outline with its receiver, as one
//// top-level entry: `(*MultiAuthenticator).AcceptForScheme`. A target
//// naming only the method, or the method under a package, receiver or
//// either spelled as code reads it, has to find that entry, and two
//// receivers sharing a method name have to stay two entries.

import client/lsp/profile
import client/lsp/resolve
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import lsp/protocol
import lsp/range

fn entry(name: String, line: Int) -> protocol.DocumentSymbol {
  protocol.DocumentSymbol(
    name:,
    kind: 6,
    detail: None,
    range: range.Range(range.Position(line, 0), range.Position(line + 3, 1)),
    selection_range: range.Range(
      range.Position(line, 20),
      range.Position(line, 35),
    ),
    children: [],
  )
}

fn outline() -> protocol.DocumentSymbols {
  protocol.Hierarchical([
    entry("MultiAuthenticator", 10),
    entry("(*MultiAuthenticator).AcceptForScheme", 69),
    entry("(Mux).Serve", 80),
    entry("(*Mux).Close", 90),
    entry("(*Pool).Close", 100),
    entry("Helper", 120),
  ])
}

fn found(identifier: String, qualifier: option.Option(String)) -> List(Int) {
  resolve.named(
    outline(),
    identifier,
    qualifier,
    profile.AsWritten,
    root: "/w",
    path: "/w/auth/multi_authenticator.go",
    methods: resolve.ReceiverNames,
  )
  |> list_lines
  |> list.sort(int.compare)
}

fn list_lines(found: List(#(String, range.Position))) -> List(Int) {
  case found {
    [] -> []
    [#(_name, range.Position(line, _column)), ..rest] -> [
      line,
      ..list_lines(rest)
    ]
  }
}

pub fn a_bare_method_name_finds_the_receiver_spelled_entry_test() {
  assert found("AcceptForScheme", None) == [69]
}

pub fn a_package_qualified_method_finds_it_through_the_file_path_test() {
  assert found("AcceptForScheme", Some("multi_authenticator")) == [69]
}

pub fn a_receiver_qualifier_matches_in_every_spelling_test() {
  assert found("AcceptForScheme", Some("MultiAuthenticator")) == [69]
  assert found("AcceptForScheme", Some("(*MultiAuthenticator)")) == [69]
  assert found("AcceptForScheme", Some("auth/MultiAuthenticator")) == [69]
  assert found("Serve", Some("Mux")) == [80]
}

pub fn a_wrong_receiver_does_not_match_test() {
  assert found("AcceptForScheme", Some("Mux")) == []
}

pub fn one_method_name_on_two_receivers_stays_two_entries_test() {
  assert found("Close", None) == [90, 100]
  assert found("Close", Some("Pool")) == [100]
}

pub fn a_plain_entry_is_still_found_by_its_whole_name_test() {
  assert found("Helper", None) == [120]
  assert found("MultiAuthenticator", None) == [10]
}

pub fn another_servers_dotted_names_keep_whole_name_matching_test() {
  // Under `ExactNames` the same outline does not split `(*Mux).Close`.
  let found =
    resolve.named(
      outline(),
      "Close",
      None,
      profile.AsWritten,
      root: "/w",
      path: "/w/lib/mux.ex",
      methods: resolve.ExactNames,
    )
  assert found == []
}

pub fn same_name_type_and_constructor_coalesce_in_file_test() {
  let record_outline =
    protocol.Hierarchical([
      protocol.DocumentSymbol(
        name: "Participant",
        kind: 5,
        detail: None,
        range: range.Range(range.Position(10, 0), range.Position(14, 1)),
        selection_range: range.Range(
          range.Position(10, 9),
          range.Position(10, 20),
        ),
        children: [
          protocol.DocumentSymbol(
            name: "Participant",
            kind: 9,
            detail: None,
            range: range.Range(range.Position(11, 2), range.Position(13, 3)),
            selection_range: range.Range(
              range.Position(11, 2),
              range.Position(11, 13),
            ),
            children: [],
          ),
        ],
      ),
    ])
  let resolved =
    resolve.in_file(
      record_outline,
      "Participant",
      Some("model"),
      profile.AsWritten,
      root: "/w/packages/tui",
      path: "/w/packages/tui/src/tui/mermaid/model.gleam",
      methods: resolve.ExactNames,
      refine: fn(pos) { pos },
    )
  assert resolved
    == [
      resolve.ResolvedSymbol("Participant", range.Position(10, 9), [
        range.Position(11, 2),
      ]),
    ]
  let explicit_ctor =
    resolve.in_file(
      record_outline,
      "Participant",
      Some("Participant"),
      profile.AsWritten,
      root: "/w/packages/tui",
      path: "/w/packages/tui/src/tui/mermaid/model.gleam",
      methods: resolve.ExactNames,
      refine: fn(pos) { pos },
    )
  assert explicit_ctor
    == [
      resolve.ResolvedSymbol(
        "Participant.Participant",
        range.Position(11, 2),
        [],
      ),
    ]
}

pub fn module_or_alias_qualifier_falls_back_in_named_file_test() {
  let fn_outline = protocol.Hierarchical([entry("check_label", 40)])
  list.each(
    ["packages/tui/src/tui/mermaid/parse", "mermaid_parse", "p"],
    fn(qualifier) {
      let resolved =
        resolve.in_file(
          fn_outline,
          "check_label",
          Some(qualifier),
          profile.AsWritten,
          root: "/w/packages/tui",
          path: "/w/packages/tui/src/tui/mermaid/parse.gleam",
          methods: resolve.ExactNames,
          refine: fn(pos) { pos },
        )
      assert resolved
        == [resolve.ResolvedSymbol("check_label", range.Position(40, 20), [])]
    },
  )
  let wrong_receiver =
    resolve.in_file(
      outline(),
      "AcceptForScheme",
      Some("Mux"),
      profile.AsWritten,
      root: "/w",
      path: "/w/auth/multi_authenticator.go",
      methods: resolve.ReceiverNames,
      refine: fn(pos) { pos },
    )
  assert wrong_receiver == []
}

pub fn top_level_declaration_wins_over_nested_field_of_same_name_test() {
  let mixed_outline =
    protocol.Hierarchical([
      protocol.DocumentSymbol(
        name: "Data",
        kind: 5,
        detail: None,
        range: range.Range(range.Position(1, 0), range.Position(6, 1)),
        selection_range: range.Range(range.Position(1, 5), range.Position(1, 9)),
        children: [
          protocol.DocumentSymbol(
            name: "Data",
            kind: 9,
            detail: None,
            range: range.Range(range.Position(2, 2), range.Position(5, 3)),
            selection_range: range.Range(
              range.Position(2, 2),
              range.Position(2, 6),
            ),
            children: [entry("opened", 3)],
          ),
        ],
      ),
      entry("opened", 50),
    ])
  let top_level =
    resolve.in_file(
      mixed_outline,
      "opened",
      None,
      profile.AsWritten,
      root: "/w",
      path: "/w/src/manager.gleam",
      methods: resolve.ExactNames,
      refine: fn(pos) { pos },
    )
  assert top_level
    == [resolve.ResolvedSymbol("opened", range.Position(50, 20), [])]
  let field_only =
    resolve.in_file(
      mixed_outline,
      "opened",
      Some("Data"),
      profile.AsWritten,
      root: "/w",
      path: "/w/src/manager.gleam",
      methods: resolve.ExactNames,
      refine: fn(pos) { pos },
    )
  assert field_only
    == [resolve.ResolvedSymbol("Data.Data.opened", range.Position(3, 20), [])]
}
