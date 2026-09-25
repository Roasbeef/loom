import core/json.{type JsonValue}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lsp/protocol
import lsp/query
import lsp/range.{Position, Range, TextEdit}
import mcp/jsonrpc

// The payloads below are literal answers from `gleam lsp` 1.18.1 and
// `gopls` v0.23.0, captured over stdio on 2026-09-25 against a two-module
// Gleam project and a one-file Go module (the ADR-013 measurement
// set-up), with only the absolute project path shortened.

fn parse(text: String) -> JsonValue {
  let assert Ok(value) = json.parse(text) as "fixture is valid JSON"
  value
}

fn at(line: Int, character: Int) -> range.Position {
  Position(line:, character:)
}

fn span(a: Int, b: Int, c: Int, d: Int) -> range.Range {
  Range(start: at(a, b), end: at(c, d))
}

// --- initialize -------------------------------------------------------------

const gleam_initialize = "{\"capabilities\": {\"codeActionProvider\": true, \"completionProvider\": {\"triggerCharacters\": [\".\"]}, \"definitionProvider\": true, \"documentFormattingProvider\": true, \"documentHighlightProvider\": true, \"documentSymbolProvider\": true, \"foldingRangeProvider\": true, \"hoverProvider\": true, \"referencesProvider\": true, \"renameProvider\": {\"prepareProvider\": true}, \"signatureHelpProvider\": {\"triggerCharacters\": [\"(\", \",\", \":\"]}, \"textDocumentSync\": {\"change\": 1, \"openClose\": true, \"save\": {\"includeText\": false}}, \"typeDefinitionProvider\": true, \"workspace\": {\"fileOperations\": {\"willRename\": {\"filters\": [{\"pattern\": {\"glob\": \"**/*.gleam\", \"matches\": \"file\"}, \"scheme\": \"file\"}]}}}}}"

const gopls_initialize = "{\"capabilities\": {\"textDocumentSync\": {\"openClose\": true, \"change\": 2, \"save\": {}}, \"completionProvider\": {\"triggerCharacters\": [\".\"]}, \"hoverProvider\": true, \"definitionProvider\": true, \"typeDefinitionProvider\": true, \"implementationProvider\": true, \"referencesProvider\": true, \"documentHighlightProvider\": true, \"documentSymbolProvider\": true, \"codeActionProvider\": true, \"codeLensProvider\": {}, \"workspaceSymbolProvider\": true, \"renameProvider\": {\"prepareProvider\": true}, \"callHierarchyProvider\": true, \"typeHierarchyProvider\": true, \"workspace\": {\"workspaceFolders\": {\"supported\": true, \"changeNotifications\": \"workspace/didChangeWorkspaceFolders\"}}}, \"serverInfo\": {\"name\": \"gopls\", \"version\": \"{\\\"GoVersion\\\":\\\"go1.26.8\\\"}\"}}"

pub fn gleam_initialize_result_test() {
  let assert Ok(result) =
    protocol.decode_initialize_result(parse(gleam_initialize))
    as "gleam's initialize result decodes"
  assert result.capabilities
    == protocol.ServerCapabilities(
      definition: protocol.Provided,
      references: protocol.Provided,
      hover: protocol.Provided,
      document_symbol: protocol.Provided,
      rename: protocol.RenameWithPrepare,
      call_hierarchy: protocol.NotProvided,
      sync: protocol.SyncFull,
      open_close: protocol.OpenCloseNotified,
      position_encoding: None,
    )
  assert result.server_name == None
  assert protocol.supports(result.capabilities, protocol.CallHierarchyFeature)
    == protocol.NotProvided
}

pub fn gopls_initialize_result_test() {
  let assert Ok(result) =
    protocol.decode_initialize_result(parse(gopls_initialize))
    as "gopls's initialize result decodes"
  assert result.capabilities.call_hierarchy == protocol.Provided
  assert result.capabilities.sync == protocol.SyncIncremental
  assert result.capabilities.rename == protocol.RenameWithPrepare
  assert result.server_name == Some("gopls")
  assert result.server_version == Some("{\"GoVersion\":\"go1.26.8\"}")
}

pub fn provider_shapes_test() {
  let decode = fn(fields) {
    let assert Ok(result) =
      protocol.decode_initialize_result(
        json.Object([#("capabilities", json.Object(fields))]),
      )
      as "capabilities decode"
    result.capabilities
  }
  let empty = decode([])
  assert empty.hover == protocol.NotProvided
  assert empty.rename == protocol.NoRename
  assert empty.sync == protocol.SyncNone
  assert empty.open_close == protocol.OpenCloseSilent

  let shaped =
    decode([
      #("hoverProvider", json.Object([])),
      #("definitionProvider", json.Bool(False)),
      #("renameProvider", json.Bool(True)),
      #("textDocumentSync", json.Int(1)),
      #("positionEncoding", json.String("utf-8")),
    ])
  assert shaped.hover == protocol.Provided
  assert shaped.definition == protocol.NotProvided
  assert shaped.rename == protocol.RenameOnly
  assert protocol.supports(shaped, protocol.RenameFeature) == protocol.Provided
  assert protocol.supports(shaped, protocol.PrepareRenameFeature)
    == protocol.NotProvided
  assert shaped.sync == protocol.SyncFull
  assert shaped.open_close == protocol.OpenCloseNotified
  assert shaped.position_encoding == Some("utf-8")
}

pub fn a_provider_of_the_wrong_type_is_refused_test() {
  let value =
    json.Object([
      #("capabilities", json.Object([#("hoverProvider", json.String("yes"))])),
    ])
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_initialize_result(value)
    as "a string provider is a lie"
}

pub fn initialize_request_declares_the_minimal_client_test() {
  let folder = protocol.WorkspaceFolder("file:///work", "work")
  let request =
    protocol.initialize_request(jsonrpc.IdInt(1), "file:///work", [folder])
  assert json.to_string(request)
    == "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{"
    <> "\"processId\":null,\"rootUri\":\"file:///work\","
    <> "\"workspaceFolders\":[{\"uri\":\"file:///work\",\"name\":\"work\"}],"
    <> "\"capabilities\":{"
    <> "\"general\":{\"positionEncodings\":[\"utf-16\"]},"
    <> "\"textDocument\":{\"publishDiagnostics\":{\"versionSupport\":true},"
    <> "\"documentSymbol\":{\"hierarchicalDocumentSymbolSupport\":true},"
    <> "\"rename\":{\"prepareSupport\":true}},"
    <> "\"workspace\":{\"workspaceEdit\":{\"documentChanges\":true,"
    <> "\"resourceOperations\":[]},\"applyEdit\":false},"
    <> "\"window\":{\"workDoneProgress\":true}}}}"
}

pub fn lifecycle_and_sync_builders_test() {
  assert json.to_string(protocol.initialized())
    == "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}"
  assert json.to_string(protocol.shutdown_request(jsonrpc.IdInt(9)))
    == "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"shutdown\"}"
  assert json.to_string(protocol.exit())
    == "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"
  assert json.to_string(protocol.did_open("file:///a.go", "go", 1, "x"))
    == "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":"
    <> "{\"textDocument\":{\"uri\":\"file:///a.go\",\"languageId\":\"go\","
    <> "\"version\":1,\"text\":\"x\"}}}"
  assert json.to_string(protocol.did_change("file:///a.go", 2, "y"))
    == "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":"
    <> "{\"textDocument\":{\"uri\":\"file:///a.go\",\"version\":2},"
    <> "\"contentChanges\":[{\"text\":\"y\"}]}}"
  assert json.to_string(protocol.did_close("file:///a.go"))
    == "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":"
    <> "{\"textDocument\":{\"uri\":\"file:///a.go\"}}}"
  assert json.to_string(protocol.cancel_request(jsonrpc.IdInt(4)))
    == "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":4}}"
}

pub fn query_builders_test() {
  let uri = "file:///a.go"
  let position = "\"position\":{\"line\":3,\"character\":8}"
  let document = "\"textDocument\":{\"uri\":\"file:///a.go\"}"
  let head = fn(id, method) {
    "{\"jsonrpc\":\"2.0\",\"id\":"
    <> id
    <> ",\"method\":\""
    <> method
    <> "\",\"params\":{"
  }
  assert json.to_string(protocol.definition_request(
      jsonrpc.IdInt(2),
      uri,
      at(3, 8),
    ))
    == head("2", "textDocument/definition")
    <> document
    <> ","
    <> position
    <> "}}"
  assert json.to_string(protocol.references_request(
      jsonrpc.IdInt(7),
      uri,
      at(3, 8),
    ))
    == head("7", "textDocument/references")
    <> document
    <> ","
    <> position
    <> ",\"context\":{\"includeDeclaration\":true}}}"
  assert json.to_string(protocol.hover_request(jsonrpc.IdInt(3), uri, at(3, 8)))
    == head("3", "textDocument/hover") <> document <> "," <> position <> "}}"
  assert json.to_string(protocol.document_symbol_request(jsonrpc.IdInt(4), uri))
    == head("4", "textDocument/documentSymbol") <> document <> "}}"
  assert json.to_string(protocol.prepare_rename_request(
      jsonrpc.IdInt(5),
      uri,
      at(3, 8),
    ))
    == head("5", "textDocument/prepareRename")
    <> document
    <> ","
    <> position
    <> "}}"
  assert json.to_string(protocol.rename_request(
      jsonrpc.IdInt(6),
      uri,
      at(3, 8),
      "salute",
    ))
    == head("6", "textDocument/rename")
    <> document
    <> ","
    <> position
    <> ",\"newName\":\"salute\"}}"
  assert json.to_string(protocol.prepare_call_hierarchy_request(
      jsonrpc.IdInt(8),
      uri,
      at(3, 8),
    ))
    == head("8", "textDocument/prepareCallHierarchy")
    <> document
    <> ","
    <> position
    <> "}}"
}

// --- locations --------------------------------------------------------------

// `gleam lsp` answers a definition with one bare `Location`.
pub fn gleam_definition_is_a_bare_location_test() {
  let value =
    parse(
      "{\"range\": {\"end\": {\"character\": 36, \"line\": 3}, \"start\": {\"character\": 0, \"line\": 3}}, \"uri\": \"file:///gp/src/gp.gleam\"}",
    )
  assert protocol.decode_locations(value)
    == Ok([protocol.Location("file:///gp/src/gp.gleam", span(3, 0, 3, 36))])
}

// `gopls` answers a definition with a `Location[]`.
pub fn gopls_definition_is_a_location_list_test() {
  let value =
    parse(
      "[{\"uri\": \"file:///go/main.go\", \"range\": {\"start\": {\"line\": 3, \"character\": 5}, \"end\": {\"line\": 3, \"character\": 10}}}]",
    )
  assert protocol.decode_locations(value)
    == Ok([protocol.Location("file:///go/main.go", span(3, 5, 3, 10))])
}

pub fn gleam_references_test() {
  let value =
    parse(
      "[{\"range\": {\"end\": {\"character\": 12, \"line\": 3}, \"start\": {\"character\": 7, \"line\": 3}}, \"uri\": \"file:///gp/src/gp.gleam\"}, {\"range\": {\"end\": {\"character\": 7, \"line\": 8}, \"start\": {\"character\": 2, \"line\": 8}}, \"uri\": \"file:///gp/src/gp.gleam\"}]",
    )
  assert protocol.decode_locations(value)
    == Ok([
      protocol.Location("file:///gp/src/gp.gleam", span(3, 7, 3, 12)),
      protocol.Location("file:///gp/src/gp.gleam", span(8, 2, 8, 7)),
    ])
}

pub fn a_location_link_becomes_its_target_selection_test() {
  let value =
    parse(
      "[{\"originSelectionRange\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 1}}, \"targetUri\": \"file:///b.rs\", \"targetRange\": {\"start\": {\"line\": 4, \"character\": 0}, \"end\": {\"line\": 9, \"character\": 1}}, \"targetSelectionRange\": {\"start\": {\"line\": 4, \"character\": 3}, \"end\": {\"line\": 4, \"character\": 8}}}]",
    )
  assert protocol.decode_locations(value)
    == Ok([protocol.Location("file:///b.rs", span(4, 3, 4, 8))])
}

pub fn a_null_definition_is_no_locations_test() {
  assert protocol.decode_locations(json.Null) == Ok([])
}

pub fn a_lying_location_fails_the_whole_list_naming_it_test() {
  let value =
    parse(
      "[{\"uri\": \"file:///a\", \"range\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 1}}}, {\"uri\": \"file:///a\", \"range\": {\"start\": {\"line\": -1, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 1}}}]",
    )
  let assert Error(protocol.BadResult(reason)) =
    protocol.decode_locations(value)
    as "a negative line is refused"
  assert string.contains(reason, "locations[1]")
}

// --- hover ------------------------------------------------------------------

pub fn gleam_hover_is_a_plain_string_test() {
  let value =
    parse(
      "{\"contents\": \"```gleam\\nfn(String) -> String\\n```\\n Says hello.\", \"range\": {\"end\": {\"character\": 36, \"line\": 3}, \"start\": {\"character\": 0, \"line\": 3}}}",
    )
  assert protocol.decode_hover(value)
    == Ok(
      Some(protocol.HoverResult(
        "```gleam\nfn(String) -> String\n```\n Says hello.",
        Some(span(3, 0, 3, 36)),
      )),
    )
}

pub fn gopls_hover_is_markup_content_test() {
  let value =
    parse(
      "{\"contents\": {\"kind\": \"markdown\", \"value\": \"```go\\nfunc Greet(name string) string\\n```\\n\\nGreet says hello.\"}, \"range\": {\"start\": {\"line\": 3, \"character\": 5}, \"end\": {\"line\": 3, \"character\": 10}}}",
    )
  let assert Ok(Some(hover)) = protocol.decode_hover(value)
    as "markup content decodes"
  assert hover.contents
    == "```go\nfunc Greet(name string) string\n```\n\nGreet says hello."
}

pub fn a_marked_string_with_a_language_is_fenced_test() {
  let value =
    parse("{\"contents\": {\"language\": \"rust\", \"value\": \"fn f()\"}}")
  assert protocol.decode_hover(value)
    == Ok(Some(protocol.HoverResult("```rust\nfn f()\n```", None)))
}

pub fn a_list_of_marked_strings_is_joined_test() {
  let value =
    parse(
      "{\"contents\": [{\"language\": \"c\", \"value\": \"int f()\"}, \"\", \"Docs.\"]}",
    )
  assert protocol.decode_hover(value)
    == Ok(Some(protocol.HoverResult("```c\nint f()\n```\n\nDocs.", None)))
}

pub fn a_null_hover_is_nothing_to_say_test() {
  assert protocol.decode_hover(json.Null) == Ok(None)
}

pub fn a_hover_without_contents_is_refused_test() {
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_hover(json.Object([]))
    as "contents is required"
}

// --- document symbols -------------------------------------------------------

pub fn gleam_document_symbols_are_hierarchical_test() {
  let value =
    parse(
      "[{\"detail\": \"fn(String) -> String\", \"kind\": 12, \"name\": \"greet\", \"range\": {\"end\": {\"character\": 1, \"line\": 5}, \"start\": {\"character\": 0, \"line\": 2}}, \"selectionRange\": {\"end\": {\"character\": 12, \"line\": 3}, \"start\": {\"character\": 7, \"line\": 3}}}, {\"detail\": \"fn() -> String\", \"kind\": 12, \"name\": \"main\", \"range\": {\"end\": {\"character\": 1, \"line\": 9}, \"start\": {\"character\": 0, \"line\": 7}}, \"selectionRange\": {\"end\": {\"character\": 11, \"line\": 7}, \"start\": {\"character\": 7, \"line\": 7}}}]",
    )
  assert protocol.decode_document_symbols(value)
    == Ok(
      protocol.Hierarchical([
        protocol.DocumentSymbol(
          name: "greet",
          kind: 12,
          detail: Some("fn(String) -> String"),
          range: span(2, 0, 5, 1),
          selection_range: span(3, 7, 3, 12),
          children: [],
        ),
        protocol.DocumentSymbol(
          name: "main",
          kind: 12,
          detail: Some("fn() -> String"),
          range: span(7, 0, 9, 1),
          selection_range: span(7, 7, 7, 11),
          children: [],
        ),
      ]),
    )
}

pub fn nested_document_symbols_keep_their_children_test() {
  let value =
    parse(
      "[{\"name\": \"T\", \"kind\": 23, \"range\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 3, \"character\": 1}}, \"selectionRange\": {\"start\": {\"line\": 0, \"character\": 5}, \"end\": {\"line\": 0, \"character\": 6}}, \"children\": [{\"name\": \"x\", \"kind\": 8, \"range\": {\"start\": {\"line\": 1, \"character\": 1}, \"end\": {\"line\": 1, \"character\": 6}}, \"selectionRange\": {\"start\": {\"line\": 1, \"character\": 1}, \"end\": {\"line\": 1, \"character\": 2}}}]}]",
    )
  let assert Ok(protocol.Hierarchical([parent])) =
    protocol.decode_document_symbols(value)
    as "one top-level symbol"
  let assert [child] = parent.children as "one child"
  assert child.name == "x"
  assert protocol.symbol_kind_name(parent.kind) == "struct"
  assert protocol.symbol_kind_name(child.kind) == "field"
}

// `gopls`'s flat `SymbolInformation[]` shape, as it answers a client that
// does not declare hierarchical support.
pub fn gopls_flat_symbol_information_test() {
  let value =
    parse(
      "[{\"name\": \"Greet\", \"kind\": 12, \"location\": {\"uri\": \"file:///go/main.go\", \"range\": {\"start\": {\"line\": 3, \"character\": 0}, \"end\": {\"line\": 3, \"character\": 52}}}}, {\"name\": \"wrap\", \"kind\": 12, \"location\": {\"uri\": \"file:///go/main.go\", \"range\": {\"start\": {\"line\": 5, \"character\": 0}, \"end\": {\"line\": 5, \"character\": 51}}}, \"containerName\": \"main\"}]",
    )
  assert protocol.decode_document_symbols(value)
    == Ok(
      protocol.Flat([
        protocol.SymbolInformation(
          name: "Greet",
          kind: 12,
          location: protocol.Location("file:///go/main.go", span(3, 0, 3, 52)),
          container_name: None,
        ),
        protocol.SymbolInformation(
          name: "wrap",
          kind: 12,
          location: protocol.Location("file:///go/main.go", span(5, 0, 5, 51)),
          container_name: Some("main"),
        ),
      ]),
    )
}

pub fn a_mixed_symbol_list_is_refused_test() {
  let value =
    parse(
      "[{\"name\": \"a\", \"kind\": 12, \"location\": {\"uri\": \"file:///a\", \"range\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 1}}}}, {\"name\": \"b\", \"kind\": 12, \"range\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 1}}, \"selectionRange\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 1}}}]",
    )
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_document_symbols(value)
    as "the second entry is not flat"
}

pub fn empty_and_null_outlines_are_empty_test() {
  assert protocol.decode_document_symbols(json.Array([]))
    == Ok(protocol.Hierarchical([]))
  assert protocol.decode_document_symbols(json.Null)
    == Ok(protocol.Hierarchical([]))
}

// --- workspace edits --------------------------------------------------------

// `gleam lsp` answers a rename with the `changes` map.
pub fn gleam_rename_is_a_changes_map_test() {
  let value =
    parse(
      "{\"changes\": {\"file:///gp/src/gp.gleam\": [{\"newText\": \"salute\", \"range\": {\"end\": {\"character\": 12, \"line\": 3}, \"start\": {\"character\": 7, \"line\": 3}}}, {\"newText\": \"salute\", \"range\": {\"end\": {\"character\": 7, \"line\": 8}, \"start\": {\"character\": 2, \"line\": 8}}}]}}",
    )
  assert protocol.decode_workspace_edit(value)
    == Ok(
      protocol.WorkspaceEdit([
        protocol.DocumentEdits(
          uri: "file:///gp/src/gp.gleam",
          version: None,
          edits: [
            TextEdit(span(3, 7, 3, 12), "salute"),
            TextEdit(span(8, 2, 8, 7), "salute"),
          ],
        ),
      ]),
    )
}

// `gopls` answers with versioned `documentChanges`.
pub fn gopls_rename_is_document_changes_test() {
  let value =
    parse(
      "{\"documentChanges\": [{\"textDocument\": {\"version\": 1, \"uri\": \"file:///go/main.go\"}, \"edits\": [{\"range\": {\"start\": {\"line\": 2, \"character\": 3}, \"end\": {\"line\": 2, \"character\": 8}}, \"newText\": \"salute\"}, {\"range\": {\"start\": {\"line\": 3, \"character\": 5}, \"end\": {\"line\": 3, \"character\": 10}}, \"newText\": \"salute\"}, {\"range\": {\"start\": {\"line\": 7, \"character\": 18}, \"end\": {\"line\": 7, \"character\": 23}}, \"newText\": \"salute\"}]}]}",
    )
  assert protocol.decode_workspace_edit(value)
    == Ok(
      protocol.WorkspaceEdit([
        protocol.DocumentEdits(
          uri: "file:///go/main.go",
          version: Some(1),
          edits: [
            TextEdit(span(2, 3, 2, 8), "salute"),
            TextEdit(span(3, 5, 3, 10), "salute"),
            TextEdit(span(7, 18, 7, 23), "salute"),
          ],
        ),
      ]),
    )
}

pub fn document_changes_win_over_changes_test() {
  let value =
    parse(
      "{\"changes\": {\"file:///x\": []}, \"documentChanges\": [{\"textDocument\": {\"version\": null, \"uri\": \"file:///y\"}, \"edits\": [{\"range\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 1}}, \"newText\": \"z\", \"annotationId\": \"a\"}]}]}",
    )
  assert protocol.decode_workspace_edit(value)
    == Ok(
      protocol.WorkspaceEdit([
        protocol.DocumentEdits(uri: "file:///y", version: None, edits: [
          TextEdit(span(0, 0, 0, 1), "z"),
        ]),
      ]),
    )
}

// A file rename inside a rename answer — what a Go server may send when a
// package is renamed — refuses the whole edit, naming the operation.
pub fn a_resource_operation_refuses_the_whole_edit_test() {
  let value =
    parse(
      "{\"documentChanges\": [{\"textDocument\": {\"version\": 1, \"uri\": \"file:///a.go\"}, \"edits\": []}, {\"kind\": \"rename\", \"oldUri\": \"file:///a.go\", \"newUri\": \"file:///b.go\"}]}",
    )
  assert protocol.decode_workspace_edit(value)
    == Error(protocol.ResourceOperationRefused("rename", "file:///a.go"))
}

pub fn create_and_delete_are_refused_too_test() {
  let create =
    parse(
      "{\"documentChanges\": [{\"kind\": \"create\", \"uri\": \"file:///n\"}]}",
    )
  assert protocol.decode_workspace_edit(create)
    == Error(protocol.ResourceOperationRefused("create", "file:///n"))
  let delete =
    parse(
      "{\"documentChanges\": [{\"kind\": \"delete\", \"uri\": \"file:///d\"}]}",
    )
  assert protocol.decode_workspace_edit(delete)
    == Error(protocol.ResourceOperationRefused("delete", "file:///d"))
}

pub fn a_null_rename_is_an_empty_edit_test() {
  assert protocol.decode_workspace_edit(json.Null)
    == Ok(protocol.WorkspaceEdit([]))
}

pub fn a_malformed_edit_is_malformed_not_refused_test() {
  let value = parse("{\"changes\": {\"file:///a\": [{\"newText\": 1}]}}")
  let assert Error(protocol.EditMalformed(_)) =
    protocol.decode_workspace_edit(value)
    as "newText must be a string"
}

// --- prepare rename ---------------------------------------------------------

pub fn gleam_prepare_rename_is_a_bare_range_test() {
  let value =
    parse(
      "{\"end\": {\"character\": 12, \"line\": 3}, \"start\": {\"character\": 7, \"line\": 3}}",
    )
  assert protocol.decode_prepare_rename(value)
    == Ok(protocol.CanRename(span(3, 7, 3, 12), None))
}

pub fn gopls_prepare_rename_carries_a_placeholder_test() {
  let value =
    parse(
      "{\"range\": {\"start\": {\"line\": 3, \"character\": 5}, \"end\": {\"line\": 3, \"character\": 10}}, \"placeholder\": \"Greet\"}",
    )
  assert protocol.decode_prepare_rename(value)
    == Ok(protocol.CanRename(span(3, 5, 3, 10), Some("Greet")))
}

pub fn prepare_rename_default_and_null_test() {
  assert protocol.decode_prepare_rename(parse("{\"defaultBehavior\": true}"))
    == Ok(protocol.CanRenameDefault)
  assert protocol.decode_prepare_rename(parse("{\"defaultBehavior\": false}"))
    == Ok(protocol.CannotRename)
  assert protocol.decode_prepare_rename(json.Null) == Ok(protocol.CannotRename)
  let assert Error(protocol.BadResult(_)) =
    protocol.decode_prepare_rename(json.Object([]))
    as "an empty object is none of the shapes"
}

// --- call hierarchy ---------------------------------------------------------

const gopls_greet_item = "{\"name\": \"Greet\", \"kind\": 12, \"detail\": \"example.com/m • main.go\", \"uri\": \"file:///go/main.go\", \"range\": {\"start\": {\"line\": 3, \"character\": 5}, \"end\": {\"line\": 3, \"character\": 10}}, \"selectionRange\": {\"start\": {\"line\": 3, \"character\": 5}, \"end\": {\"line\": 3, \"character\": 10}}, \"data\": {\"opaque\": [1, 2]}}"

pub fn gopls_prepare_call_hierarchy_test() {
  let raw = parse(gopls_greet_item)
  assert protocol.decode_call_hierarchy_items(json.Array([raw]))
    == Ok([
      protocol.CallHierarchyItem(
        name: "Greet",
        kind: 12,
        detail: Some("example.com/m • main.go"),
        uri: "file:///go/main.go",
        range: span(3, 5, 3, 10),
        selection_range: span(3, 5, 3, 10),
        raw:,
      ),
    ])
}

// The follow-up requests send the item back byte for byte, `data`
// included, because that field is the server's own state.
pub fn call_requests_echo_the_item_verbatim_test() {
  let raw = parse(gopls_greet_item)
  let assert Ok([item]) =
    protocol.decode_call_hierarchy_items(json.Array([raw]))
    as "one item"
  assert json.to_string(protocol.incoming_calls_request(jsonrpc.IdInt(9), item))
    == "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"callHierarchy/incomingCalls\","
    <> "\"params\":{\"item\":"
    <> json.to_string(raw)
    <> "}}"
  assert json.to_string(protocol.outgoing_calls_request(jsonrpc.IdInt(10), item))
    == "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"callHierarchy/outgoingCalls\","
    <> "\"params\":{\"item\":"
    <> json.to_string(raw)
    <> "}}"
}

pub fn gopls_incoming_and_outgoing_calls_test() {
  let incoming =
    parse(
      "[{\"from\": {\"name\": \"main\", \"kind\": 12, \"detail\": \"example.com/m • main.go\", \"uri\": \"file:///go/main.go\", \"range\": {\"start\": {\"line\": 7, \"character\": 5}, \"end\": {\"line\": 7, \"character\": 9}}, \"selectionRange\": {\"start\": {\"line\": 7, \"character\": 5}, \"end\": {\"line\": 7, \"character\": 9}}}, \"fromRanges\": [{\"start\": {\"line\": 7, \"character\": 18}, \"end\": {\"line\": 7, \"character\": 23}}]}]",
    )
  let assert Ok([call]) = protocol.decode_incoming_calls(incoming)
    as "one caller"
  assert call.from.name == "main"
  assert call.from_ranges == [span(7, 18, 7, 23)]

  let outgoing =
    parse(
      "[{\"to\": {\"name\": \"wrap\", \"kind\": 12, \"detail\": \"example.com/m • main.go\", \"uri\": \"file:///go/main.go\", \"range\": {\"start\": {\"line\": 5, \"character\": 5}, \"end\": {\"line\": 5, \"character\": 9}}, \"selectionRange\": {\"start\": {\"line\": 5, \"character\": 5}, \"end\": {\"line\": 5, \"character\": 9}}}, \"fromRanges\": [{\"start\": {\"line\": 3, \"character\": 40}, \"end\": {\"line\": 3, \"character\": 44}}]}]",
    )
  let assert Ok([call]) = protocol.decode_outgoing_calls(outgoing)
    as "one callee"
  assert call.to.name == "wrap"
  assert call.from_ranges == [span(3, 40, 3, 44)]
  assert protocol.decode_outgoing_calls(json.Null) == Ok([])
}

// --- diagnostics and notifications ------------------------------------------

// `gleam lsp` publishes with no `version`.
pub fn gleam_publish_diagnostics_has_no_version_test() {
  let params =
    parse(
      "{\"diagnostics\": [{\"message\": \"Syntax error\\n\\nI was not expecting this.\", \"range\": {\"end\": {\"character\": 6, \"line\": 11}, \"start\": {\"character\": 0, \"line\": 11}}, \"severity\": 1}], \"uri\": \"file:///gp/src/gp.gleam\"}",
    )
  assert protocol.classify_notification(
      "textDocument/publishDiagnostics",
      Some(params),
    )
    == Ok(
      protocol.Published(
        protocol.PublishDiagnostics(
          uri: "file:///gp/src/gp.gleam",
          version: None,
          diagnostics: [
            protocol.ServerDiagnostic(
              range: span(11, 0, 11, 6),
              severity: query.SeverityError,
              message: "Syntax error\n\nI was not expecting this.",
              source: None,
            ),
          ],
        ),
      ),
    )
}

// `gopls` publishes versioned, including a versioned empty list for a file
// that stayed clean.
pub fn gopls_publish_diagnostics_is_versioned_test() {
  let clean =
    parse(
      "{\"uri\": \"file:///go/main.go\", \"version\": 1, \"diagnostics\": []}",
    )
  assert protocol.decode_publish_diagnostics(clean)
    == Ok(protocol.PublishDiagnostics("file:///go/main.go", Some(1), []))

  let broken =
    parse(
      "{\"uri\": \"file:///go/main.go\", \"version\": 2, \"diagnostics\": [{\"range\": {\"start\": {\"line\": 9, \"character\": 0}, \"end\": {\"line\": 9, \"character\": 0}}, \"severity\": 1, \"source\": \"syntax\", \"message\": \"expected declaration, found broken\"}]}",
    )
  let assert Ok(published) = protocol.decode_publish_diagnostics(broken)
    as "gopls's broken publication decodes"
  assert published.version == Some(2)
  let assert [diagnostic] = published.diagnostics as "one diagnostic"
  assert diagnostic.source == Some("syntax")
}

pub fn severities_and_the_omitted_default_test() {
  let with = fn(severity) {
    let fields = [
      #("message", json.String("m")),
      #(
        "range",
        parse(
          "{\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 0}}",
        ),
      ),
      ..severity
    ]
    let params =
      json.Object([
        #("uri", json.String("file:///a")),
        #("diagnostics", json.Array([json.Object(fields)])),
      ])
    case protocol.decode_publish_diagnostics(params) {
      Ok(protocol.PublishDiagnostics(diagnostics: [diagnostic], ..)) ->
        Ok(diagnostic.severity)
      Ok(_) -> Error(Nil)
      Error(_) -> Error(Nil)
    }
  }
  assert with([]) == Ok(query.SeverityError)
  assert with([#("severity", json.Int(2))]) == Ok(query.SeverityWarning)
  assert with([#("severity", json.Int(3))]) == Ok(query.SeverityInformation)
  assert with([#("severity", json.Int(4))]) == Ok(query.SeverityHint)
  assert with([#("severity", json.Int(5))]) == Error(Nil)
}

pub fn other_notifications_are_recognised_or_not_test() {
  assert protocol.classify_notification(
      "window/logMessage",
      Some(parse("{\"type\": 3, \"message\": \"x\"}")),
    )
    == Ok(protocol.Ignored("window/logMessage"))
  assert protocol.classify_notification("window/showMessage", None)
    == Ok(protocol.Ignored("window/showMessage"))
  assert protocol.classify_notification("telemetry/event", None)
    == Ok(protocol.Unrecognised("telemetry/event"))
  let assert Error(protocol.BadResult(_)) =
    protocol.classify_notification("textDocument/publishDiagnostics", None)
    as "a publication with no params is malformed"
}

// Work-done progress in each of its three kinds, under both token
// shapes, with the unread fields of a real `rust-analyzer` report left in.
pub fn work_done_progress_decodes_each_kind_test() {
  let progress = fn(text) {
    protocol.classify_notification("$/progress", Some(parse(text)))
  }
  assert progress(
      "{\"token\": \"rustAnalyzer/cachePriming\", \"value\": "
      <> "{\"kind\": \"begin\", \"title\": \"Indexing\", "
      <> "\"cancellable\": false, \"percentage\": 0}}",
    )
    == Ok(
      protocol.Progressed(protocol.ProgressBegin(
        token: protocol.StringToken("rustAnalyzer/cachePriming"),
        title: "Indexing",
      )),
    )
  assert progress(
      "{\"token\": 7, \"value\": {\"kind\": \"report\", "
      <> "\"message\": \"1/4 (core)\", \"percentage\": 25}}",
    )
    == Ok(protocol.Progressed(protocol.ProgressReport(protocol.IntToken(7))))
  assert progress("{\"token\": 7, \"value\": {\"kind\": \"end\"}}")
    == Ok(protocol.Progressed(protocol.ProgressEnd(protocol.IntToken(7))))
}

// A progress the client cannot read is a fault the actor drops, never a
// guess at which token moved.
pub fn malformed_progress_is_a_fault_test() {
  let refused = fn(params) {
    case protocol.classify_notification("$/progress", params) {
      Error(protocol.BadResult(_)) -> True
      Ok(_) -> False
    }
  }
  assert refused(None)
  assert refused(Some(parse("{\"value\": {\"kind\": \"end\"}}")))
  assert refused(
    Some(parse("{\"token\": 1.5, \"value\": {\"kind\": \"end\"}}")),
  )
  assert refused(
    Some(parse("{\"token\": 1, \"value\": {\"kind\": \"begin\"}}")),
  )
  assert refused(
    Some(parse("{\"token\": 1, \"value\": {\"kind\": \"paused\"}}")),
  )

  // A partial-result value carries no `kind`; this client never asked for
  // one.
  assert refused(Some(parse("{\"token\": 1, \"value\": [1, 2]}")))
  assert refused(Some(parse("{\"token\": 1, \"value\": {\"items\": []}}")))
}

// --- server requests --------------------------------------------------------

pub fn server_requests_are_answered_test() {
  let folders = [protocol.WorkspaceFolder("file:///work", "work")]
  let answer = fn(method, params) {
    protocol.answer_server_request(method, params, folders)
  }

  // `gleam lsp` sends this, with a string id, before its first compile.
  assert answer(
      "window/workDoneProgress/create",
      Some(parse("{\"token\": \"downloading-dependencies\"}")),
    )
    == Ok(json.Null)
  assert answer(
      "workspace/configuration",
      Some(parse("{\"items\": [{\"section\": \"gopls\"}, {}]}")),
    )
    == Ok(json.Array([json.Null, json.Null]))
  assert answer("client/registerCapability", Some(json.Object([])))
    == Ok(json.Null)
  assert answer("client/unregisterCapability", Some(json.Object([])))
    == Ok(json.Null)
  assert answer("workspace/workspaceFolders", None)
    == Ok(parse("[{\"uri\": \"file:///work\", \"name\": \"work\"}]"))
}

pub fn apply_edit_is_refused_in_band_test() {
  let assert Ok(json.Object(fields)) =
    protocol.answer_server_request(
      "workspace/applyEdit",
      Some(parse("{\"edit\": {\"changes\": {}}}")),
      [],
    )
    as "applyEdit is answered, not errored"
  assert list.key_find(fields, "applied") == Ok(json.Bool(False))
  let assert Ok(json.String(_)) = list.key_find(fields, "failureReason")
    as "a reason is given"
}

pub fn unknown_server_requests_are_method_not_found_test() {
  let assert Error(error) =
    protocol.answer_server_request("window/showMessageRequest", None, [])
    as "not a method this client serves"
  assert error.code == protocol.method_not_found_code
  let assert Error(error) =
    protocol.answer_server_request("workspace/configuration", None, [])
    as "configuration with no params"
  assert error.code == protocol.invalid_params_code
}

// --- URIs -------------------------------------------------------------------

pub fn uri_round_trips_test() {
  [
    "/work/a.gleam",
    "/work/my file.gleam",
    "/work/café/𝄞.go",
    "/work/100%/a#b?c.rs",
    "/work/a+b@c:d=e,f;g!h$i&j'k(l)m*n~o.txt",
    "/",
  ]
  |> list.each(fn(path) {
    let assert Ok(uri) = protocol.path_to_uri(path) as "absolute paths encode"
    assert string.starts_with(uri, "file:///")
    assert protocol.uri_to_path(uri) == Ok(path)
  })
}

pub fn path_to_uri_escapes_what_it_must_test() {
  assert protocol.path_to_uri("/w/my file.gleam")
    == Ok("file:///w/my%20file.gleam")
  assert protocol.path_to_uri("/w/caf\u{e9}") == Ok("file:///w/caf%C3%A9")
  assert protocol.path_to_uri("/w/a%b#c?d") == Ok("file:///w/a%25b%23c%3Fd")
  assert protocol.path_to_uri("relative/a.gleam")
    == Error(protocol.NotAbsolute("relative/a.gleam"))
}

pub fn uri_to_path_is_strict_test() {
  assert protocol.uri_to_path("file:///w/caf%c3%a9") == Ok("/w/café")
  assert protocol.uri_to_path("file://localhost/w/a") == Ok("/w/a")
  assert protocol.uri_to_path("file:///w/%zz")
    == Error(protocol.BadEscape("file:///w/%zz"))
  assert protocol.uri_to_path("file:///w/%4")
    == Error(protocol.BadEscape("file:///w/%4"))
  assert protocol.uri_to_path("file:///w/%FF")
    == Error(protocol.NotAPath("file:///w/%FF"))
  assert protocol.uri_to_path("file:///w/%00")
    == Error(protocol.NotAPath("file:///w/%00"))
  assert protocol.uri_to_path("https:///w/a")
    == Error(protocol.NotFileUri("https:///w/a"))
  assert protocol.uri_to_path("file://host/w/a")
    == Error(protocol.NotFileUri("file://host/w/a"))
  assert protocol.uri_to_path("file:///w/a?x")
    == Error(protocol.NotFileUri("file:///w/a?x"))
}
