//// gopls names a method in a file's outline with its receiver, as one
//// top-level entry: `(*MultiAuthenticator).AcceptForScheme`. A target
//// naming only the method, or the method under a package, receiver or
//// either spelled as code reads it, has to find that entry, and two
//// receivers sharing a method name have to stay two entries.

import codemode/lsp_host/profile
import codemode/lsp_host/resolve
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
