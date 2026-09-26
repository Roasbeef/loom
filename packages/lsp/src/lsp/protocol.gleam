//// The Language Server Protocol messages the harness sends and consumes,
//// and nothing more, as total codecs over `core/json.JsonValue`.
////
//// # Why the surface is this small
////
//// The harness asks a language server seven kinds of question —
//// definition, references, hover, a file's outline, rename (with its
//// prepare step), and one level of call hierarchy — keeps the server's
//// view of open documents honest with full-text sync, and listens for
//// diagnostics (ADR-013 §§3–6). Every structure here is one of those, the
//// handshake around them, or an answer to a request the server sends us.
//// Completion, code actions, formatting, `workspace/symbol` and
//// incremental sync are absent on purpose: each would be surface a server
//// could push data through, for a feature no tool uses.
////
//// # The posture
////
//// It is `mcp/protocol`'s: builders return the whole JSON-RPC message,
//// ready for `lsp/framing.frame`, and decoders take the raw `result` or
//// `params` value `mcp/jsonrpc` already extracted. Required discriminators
//// are strict and unknown extra fields are ignored. Every decoder is
//// total, so a lying server settles as a `ProtocolFault` value and never a
//// crash. Where the protocol allows several shapes for one answer — and
//// servers use them all; ADR-013's measurements and this module's tests
//// carry both `gleam lsp`'s and `gopls`'s — each shape is decoded into one
//// type, so nothing above this module ever branches on a server's
//// dialect.
////
//// Positions are the protocol's own UTF-16 coordinates (`lsp/range`).
//// They are carried here untouched; converting them against document text
//// is `lsp/text`'s job, done once, never here.
////
//// # What this module decides rather than decodes
////
//// Three answers are policy, and they are here so the actor that sends
//// them has nothing to decide:
////
//// - a server's `workspace/applyEdit` is answered `applied: false`,
////   because edits land only through the hashline path (ADR-013 §4);
//// - a `WorkspaceEdit` carrying a create, rename or delete of a file is
////   refused as a value rather than silently dropped, for the same reason;
//// - a diagnostic with no severity is read as an error (see
////   `decode_publish_diagnostics`).

import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lsp/query.{
  type Severity, SeverityError, SeverityHint, SeverityInformation,
  SeverityWarning,
}
import lsp/range.{type Position, type Range, type TextEdit, Position, Range}
import mcp/jsonrpc.{type Id, type RpcError, RpcError}

/// Why a well-formed JSON-RPC payload failed to decode as the LSP shape it
/// was supposed to carry. Plain data, never a crash.
pub type ProtocolFault {
  /// The payload is not the shape the method promises. `reason` names the
  /// field, and inside a list the index, that broke it.
  BadResult(reason: String)
}

// --- capabilities -----------------------------------------------------------

/// Whether a server advertised one request. The protocol lets a provider
/// be `true`, an options object, or absent or `false`; the first two are
/// `Provided`, the last two `NotProvided`.
///
/// Gating on this is not courtesy. A measured server left an unadvertised
/// request unanswered for as long as it was watched (ADR-013), so a
/// request whose provider is `NotProvided` is never sent.
pub type Provided {
  /// The server will answer this request.
  Provided

  /// The server did not advertise this request; do not send it.
  NotProvided
}

/// What a server advertised about rename.
pub type RenameSupport {
  /// No `renameProvider`.
  NoRename

  /// `rename` is served but `prepareRename` is not.
  RenameOnly

  /// Both `rename` and `prepareRename` are served
  /// (`renameProvider: {prepareProvider: true}`).
  RenameWithPrepare
}

/// How a server wants document edits synchronised
/// (`TextDocumentSyncKind`).
pub type SyncKind {
  /// Kind 0: the server wants no content changes.
  SyncNone

  /// Kind 1: every change sends the whole document. This is the only
  /// kind the harness sends, whatever the server prefers; a full-text
  /// change is legal under both non-zero kinds.
  SyncFull

  /// Kind 2: the server accepts incremental changes.
  SyncIncremental
}

/// Whether a server wants `didOpen` and `didClose` notifications.
pub type OpenClose {
  /// The server tracks open documents and wants to be told.
  OpenCloseNotified

  /// The server did not ask for open and close notifications.
  OpenCloseSilent
}

/// The subset of `ServerCapabilities` the harness acts on. Everything
/// else a server advertises is ignored, which is what keeps completion,
/// code actions and the rest out of reach.
pub type ServerCapabilities {
  ServerCapabilities(
    /// `definitionProvider`.
    definition: Provided,
    /// `referencesProvider`.
    references: Provided,
    /// `hoverProvider`.
    hover: Provided,
    /// `documentSymbolProvider`. Also the settlement barrier (ADR-013 §3),
    /// so a server without it can never report settled diagnostics.
    document_symbol: Provided,
    /// `renameProvider`, with its `prepareProvider`.
    rename: RenameSupport,
    /// `callHierarchyProvider`: `prepareCallHierarchy` and both
    /// directions of calls.
    call_hierarchy: Provided,
    /// `textDocumentSync`'s change kind. The numeric shorthand and the
    /// object's `change` both land here; absent is `SyncNone`.
    sync: SyncKind,
    /// `textDocumentSync`'s `openClose`. The numeric shorthand implies
    /// `OpenCloseNotified` for kinds 1 and 2, as editors read it.
    open_close: OpenClose,
    /// `positionEncoding`, verbatim, when the server chose one. Absent
    /// means UTF-16, which is the only encoding the harness offers; any
    /// other value is the caller's to refuse.
    position_encoding: Option(String),
  )
}

/// A decoded `initialize` result.
pub type InitializeResult {
  InitializeResult(
    capabilities: ServerCapabilities,
    /// `serverInfo.name`, when sent.
    server_name: Option(String),
    /// `serverInfo.version`, when sent. Carried verbatim: `gopls` puts a
    /// whole JSON document here.
    server_version: Option(String),
  )
}

/// One request the harness may want to send, for gating against
/// `ServerCapabilities`.
pub type Feature {
  /// `textDocument/definition`.
  DefinitionFeature

  /// `textDocument/references`.
  ReferencesFeature

  /// `textDocument/hover`.
  HoverFeature

  /// `textDocument/documentSymbol`.
  DocumentSymbolFeature

  /// `textDocument/rename`.
  RenameFeature

  /// `textDocument/prepareRename`.
  PrepareRenameFeature

  /// `textDocument/prepareCallHierarchy` and both call directions.
  CallHierarchyFeature
}

/// Whether `capabilities` advertises `feature`. The one gate every
/// request passes before it is sent.
///
/// ## Examples
///
/// ```gleam
/// // A server whose renameProvider is `true` serves rename but not prepare:
/// // protocol.supports(capabilities, protocol.RenameFeature) -> protocol.Provided
/// // protocol.supports(capabilities, protocol.PrepareRenameFeature) -> protocol.NotProvided
/// ```
///
pub fn supports(
  capabilities: ServerCapabilities,
  feature: Feature,
) -> Provided {
  case feature {
    DefinitionFeature -> capabilities.definition
    ReferencesFeature -> capabilities.references
    HoverFeature -> capabilities.hover
    DocumentSymbolFeature -> capabilities.document_symbol
    CallHierarchyFeature -> capabilities.call_hierarchy
    RenameFeature ->
      case capabilities.rename {
        NoRename -> NotProvided
        RenameOnly | RenameWithPrepare -> Provided
      }
    PrepareRenameFeature ->
      case capabilities.rename {
        NoRename | RenameOnly -> NotProvided
        RenameWithPrepare -> Provided
      }
  }
}

/// Decodes an `initialize` result.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(result) =
///   protocol.decode_initialize_result(json.Object([
///     #("capabilities", json.Object([#("hoverProvider", json.Bool(True))])),
///   ]))
/// assert result.capabilities.hover == protocol.Provided
/// ```
///
pub fn decode_initialize_result(
  value: JsonValue,
) -> Result(InitializeResult, ProtocolFault) {
  use fields <- result.try(object_fields(value, "an initialize result object"))
  use capabilities <- result.try(case list.key_find(fields, "capabilities") {
    Ok(capabilities) -> decode_capabilities(capabilities)
    Error(Nil) -> Error(BadResult(reason: "capabilities is required"))
  })
  use #(server_name, server_version) <- result.try(
    case list.key_find(fields, "serverInfo") {
      Error(Nil) -> Ok(#(None, None))
      Ok(info) -> decode_server_info(info)
    },
  )
  Ok(InitializeResult(capabilities:, server_name:, server_version:))
}

fn decode_server_info(
  value: JsonValue,
) -> Result(#(Option(String), Option(String)), ProtocolFault) {
  use fields <- result.try(object_fields(value, "serverInfo must be an object"))
  use name <- result.try(required_string(fields, "serverInfo.name", "name"))
  use version <- result.try(optional_string(fields, "version"))
  Ok(#(Some(name), version))
}

fn decode_capabilities(
  value: JsonValue,
) -> Result(ServerCapabilities, ProtocolFault) {
  use fields <- result.try(object_fields(
    value,
    "capabilities must be an object",
  ))
  use definition <- result.try(provider(fields, "definitionProvider"))
  use references <- result.try(provider(fields, "referencesProvider"))
  use hover <- result.try(provider(fields, "hoverProvider"))
  use document_symbol <- result.try(provider(fields, "documentSymbolProvider"))
  use call_hierarchy <- result.try(provider(fields, "callHierarchyProvider"))
  use rename <- result.try(rename_support(fields))
  use #(sync, open_close) <- result.try(text_document_sync(fields))
  use position_encoding <- result.try(optional_string(
    fields,
    "positionEncoding",
  ))
  Ok(ServerCapabilities(
    definition:,
    references:,
    hover:,
    document_symbol:,
    rename:,
    call_hierarchy:,
    sync:,
    open_close:,
    position_encoding:,
  ))
}

// `true` or any options object advertises; absent, `false` or `null` does
// not. `null` is not in the schema, but reading it as "not provided" is the
// conservative answer — the request is simply never sent.
fn provider(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Provided, ProtocolFault) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(NotProvided)
    Ok(json.Null) -> Ok(NotProvided)
    Ok(json.Bool(False)) -> Ok(NotProvided)
    Ok(json.Bool(True)) -> Ok(Provided)
    Ok(json.Object(_)) -> Ok(Provided)
    Ok(json.Array(_))
    | Ok(json.String(_))
    | Ok(json.Int(_))
    | Ok(json.Float(_)) ->
      Error(BadResult(reason: key <> " must be a boolean or an object"))
  }
}

// `renameProvider` is `boolean | RenameOptions`; only the object form can
// carry `prepareProvider`.
fn rename_support(
  fields: List(#(String, JsonValue)),
) -> Result(RenameSupport, ProtocolFault) {
  use advertised <- result.try(provider(fields, "renameProvider"))
  case advertised, list.key_find(fields, "renameProvider") {
    NotProvided, _ -> Ok(NoRename)
    Provided, Ok(json.Object(options)) -> {
      use prepare <- result.try(defaulted_bool(options, "prepareProvider"))
      case prepare {
        True -> Ok(RenameWithPrepare)
        False -> Ok(RenameOnly)
      }
    }
    Provided, _ -> Ok(RenameOnly)
  }
}

// `textDocumentSync` is a bare `TextDocumentSyncKind` number or a
// `TextDocumentSyncOptions` object. The bare number predates the object,
// and editors read a non-zero one as also asking for open and close.
fn text_document_sync(
  fields: List(#(String, JsonValue)),
) -> Result(#(SyncKind, OpenClose), ProtocolFault) {
  case list.key_find(fields, "textDocumentSync") {
    Error(Nil) -> Ok(#(SyncNone, OpenCloseSilent))
    Ok(json.Null) -> Ok(#(SyncNone, OpenCloseSilent))
    Ok(json.Int(kind)) -> {
      use kind <- result.try(sync_kind(kind))
      case kind {
        SyncNone -> Ok(#(SyncNone, OpenCloseSilent))
        SyncFull | SyncIncremental -> Ok(#(kind, OpenCloseNotified))
      }
    }
    Ok(json.Object(options)) -> {
      use open_close <- result.try(defaulted_bool(options, "openClose"))
      use kind <- result.try(case list.key_find(options, "change") {
        Error(Nil) -> Ok(SyncNone)
        Ok(json.Int(kind)) -> sync_kind(kind)
        Ok(_) ->
          Error(BadResult(reason: "textDocumentSync.change must be an integer"))
      })
      case open_close {
        True -> Ok(#(kind, OpenCloseNotified))
        False -> Ok(#(kind, OpenCloseSilent))
      }
    }
    Ok(_) ->
      Error(BadResult(reason: "textDocumentSync must be an integer or object"))
  }
}

fn sync_kind(kind: Int) -> Result(SyncKind, ProtocolFault) {
  case kind {
    0 -> Ok(SyncNone)
    1 -> Ok(SyncFull)
    2 -> Ok(SyncIncremental)
    _ ->
      Error(BadResult(
        reason: "unknown text document sync kind " <> int.to_string(kind),
      ))
  }
}

// --- lifecycle and synchronisation builders ---------------------------------

/// One workspace folder, as `initialize` and `workspace/workspaceFolders`
/// carry it.
pub type WorkspaceFolder {
  WorkspaceFolder(
    /// A `file://` URI, as `path_to_uri` renders it.
    uri: String,
    /// A display name; servers use it only in messages.
    name: String,
  )
}

/// The `initialize` request. `processId` is `null` — the server runs in a
/// jail with its own pid namespace, so the harness's pid would name
/// nothing it can watch — and the client capabilities are the minimum the
/// harness consumes:
///
/// - `general.positionEncodings: ["utf-16"]`: the protocol's default and
///   the only encoding `lsp/text` converts from;
/// - `publishDiagnostics.versionSupport`: a versioned publication is half
///   of ADR-013 §3's settlement rule;
/// - `documentSymbol.hierarchicalDocumentSymbolSupport` and
///   `rename.prepareSupport`: the richer answer where a server has one;
/// - `workspace.workspaceEdit.documentChanges` with `resourceOperations`
///   empty: versioned per-file edits are welcome, and file creation,
///   renaming and deletion are declared unsupported (they would be
///   refused anyway);
/// - `workspace.applyEdit: false`: the server may not ask us to write;
/// - `window.workDoneProgress: true`: the server may report the work it
///   has not finished — a project still loading — as `$/progress`, which
///   is how the client learns it is not ready to answer. A server that
///   answers while it is loading answers with empty results rather than
///   errors (measured on `rust-analyzer`), so its readiness is the only
///   thing that tells an empty answer from a true one.
///
/// ## Examples
///
/// ```gleam
/// let root = "file:///work"
/// protocol.initialize_request(jsonrpc.IdInt(1), root, [protocol.WorkspaceFolder(root, "work")])
/// // -> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}
/// ```
///
pub fn initialize_request(
  id: Id,
  root_uri: String,
  folders: List(WorkspaceFolder),
) -> JsonValue {
  let capabilities =
    json.Object([
      #(
        "general",
        json.Object([
          #("positionEncodings", json.Array([json.String("utf-16")])),
        ]),
      ),
      #(
        "textDocument",
        json.Object([
          #(
            "publishDiagnostics",
            json.Object([#("versionSupport", json.Bool(True))]),
          ),
          #(
            "documentSymbol",
            json.Object([
              #("hierarchicalDocumentSymbolSupport", json.Bool(True)),
            ]),
          ),
          #("rename", json.Object([#("prepareSupport", json.Bool(True))])),
        ]),
      ),
      #(
        "workspace",
        json.Object([
          #(
            "workspaceEdit",
            json.Object([
              #("documentChanges", json.Bool(True)),
              #("resourceOperations", json.Array([])),
            ]),
          ),
          #("applyEdit", json.Bool(False)),
        ]),
      ),
      #("window", json.Object([#("workDoneProgress", json.Bool(True))])),
    ])
  let params =
    json.Object([
      #("processId", json.Null),
      #("rootUri", json.String(root_uri)),
      #("workspaceFolders", encode_folders(folders)),
      #("capabilities", capabilities),
    ])
  jsonrpc.request(id, "initialize", Some(params))
}

fn encode_folders(folders: List(WorkspaceFolder)) -> JsonValue {
  json.Array(
    list.map(folders, fn(folder) {
      json.Object([
        #("uri", json.String(folder.uri)),
        #("name", json.String(folder.name)),
      ])
    }),
  )
}

/// The `initialized` notification, sent once the `initialize` result has
/// been read. Its params are an empty object, which the protocol requires
/// rather than permits.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(protocol.initialized())
///   == "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}"
/// ```
///
pub fn initialized() -> JsonValue {
  jsonrpc.notification("initialized", Some(json.Object([])))
}

/// The `shutdown` request: the first of ADR-013 §1's three stop steps.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(protocol.shutdown_request(jsonrpc.IdInt(9)))
///   == "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"shutdown\"}"
/// ```
///
pub fn shutdown_request(id: Id) -> JsonValue {
  jsonrpc.request(id, "shutdown", None)
}

/// The `exit` notification, sent after `shutdown` has answered.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(protocol.exit())
///   == "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}"
/// ```
///
pub fn exit() -> JsonValue {
  jsonrpc.notification("exit", None)
}

/// `textDocument/didOpen`, carrying the whole text the harness read.
///
/// ## Examples
///
/// ```gleam
/// protocol.did_open("file:///work/a.gleam", "gleam", 1, "pub fn a() { 1 }\n")
/// // -> {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{...}}}
/// ```
///
pub fn did_open(
  uri: String,
  language_id: String,
  version: Int,
  text: String,
) -> JsonValue {
  let document =
    json.Object([
      #("uri", json.String(uri)),
      #("languageId", json.String(language_id)),
      #("version", json.Int(version)),
      #("text", json.String(text)),
    ])
  jsonrpc.notification(
    "textDocument/didOpen",
    Some(json.Object([#("textDocument", document)])),
  )
}

/// `textDocument/didChange` carrying the document's whole new text as one
/// range-less content change: full-text sync, which is legal whatever
/// kind the server advertised and makes the text the harness last sent
/// the server's exact view (ADR-013 §4's rename base). `version` must
/// increase with every change to the same document.
///
/// ## Examples
///
/// ```gleam
/// protocol.did_change("file:///work/a.gleam", 2, "pub fn a() { 2 }\n")
/// // -> {..."params":{"textDocument":{"uri":...,"version":2},"contentChanges":[{"text":...}]}}
/// ```
///
pub fn did_change(uri: String, version: Int, text: String) -> JsonValue {
  let document =
    json.Object([#("uri", json.String(uri)), #("version", json.Int(version))])
  let changes = json.Array([json.Object([#("text", json.String(text))])])
  jsonrpc.notification(
    "textDocument/didChange",
    Some(
      json.Object([#("textDocument", document), #("contentChanges", changes)]),
    ),
  )
}

/// `textDocument/didClose`: the server stops holding the document and
/// reads it from disk again when it needs it.
///
/// ## Examples
///
/// ```gleam
/// protocol.did_close("file:///work/a.gleam")
/// // -> {..."method":"textDocument/didClose","params":{"textDocument":{"uri":...}}}
/// ```
///
pub fn did_close(uri: String) -> JsonValue {
  jsonrpc.notification(
    "textDocument/didClose",
    Some(json.Object([#("textDocument", document_id(uri))])),
  )
}

/// `$/cancelRequest` for a request the harness gave up on, so a server
/// that honours it stops computing an answer nobody will read.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(protocol.cancel_request(jsonrpc.IdInt(4)))
///   == "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":4}}"
/// ```
///
pub fn cancel_request(id: Id) -> JsonValue {
  let id = case id {
    jsonrpc.IdInt(value:) -> json.Int(value)
    jsonrpc.IdString(value:) -> json.String(value)
  }
  jsonrpc.notification("$/cancelRequest", Some(json.Object([#("id", id)])))
}

// --- query builders ---------------------------------------------------------

/// `textDocument/definition` at a position.
///
/// ## Examples
///
/// ```gleam
/// protocol.definition_request(jsonrpc.IdInt(2), uri, range.Position(3, 8))
/// // -> {..."method":"textDocument/definition","params":{"textDocument":{"uri":...},"position":{"line":3,"character":8}}}
/// ```
///
pub fn definition_request(id: Id, uri: String, at: Position) -> JsonValue {
  position_request(id, "textDocument/definition", uri, at, [])
}

/// `textDocument/references` at a position, with the declaration
/// included: the model asked where a symbol is used, and the definition
/// site is one of the places an edit may need to reach.
///
/// ## Examples
///
/// ```gleam
/// protocol.references_request(jsonrpc.IdInt(7), uri, range.Position(3, 8))
/// // -> {...,"params":{...,"context":{"includeDeclaration":true}}}
/// ```
///
pub fn references_request(id: Id, uri: String, at: Position) -> JsonValue {
  let context = json.Object([#("includeDeclaration", json.Bool(True))])
  position_request(id, "textDocument/references", uri, at, [
    #("context", context),
  ])
}

/// `textDocument/hover` at a position.
///
/// ## Examples
///
/// ```gleam
/// protocol.hover_request(jsonrpc.IdInt(3), uri, range.Position(3, 8))
/// // -> {..."method":"textDocument/hover",...}
/// ```
///
pub fn hover_request(id: Id, uri: String, at: Position) -> JsonValue {
  position_request(id, "textDocument/hover", uri, at, [])
}

/// `textDocument/documentSymbol` for a whole document: a file's outline,
/// and the settlement barrier of ADR-013 §3.
///
/// ## Examples
///
/// ```gleam
/// protocol.document_symbol_request(jsonrpc.IdInt(4), uri)
/// // -> {..."method":"textDocument/documentSymbol","params":{"textDocument":{"uri":...}}}
/// ```
///
pub fn document_symbol_request(id: Id, uri: String) -> JsonValue {
  jsonrpc.request(
    id,
    "textDocument/documentSymbol",
    Some(json.Object([#("textDocument", document_id(uri))])),
  )
}

/// `textDocument/prepareRename` at a position.
///
/// ## Examples
///
/// ```gleam
/// protocol.prepare_rename_request(jsonrpc.IdInt(5), uri, range.Position(3, 8))
/// // -> {..."method":"textDocument/prepareRename",...}
/// ```
///
pub fn prepare_rename_request(id: Id, uri: String, at: Position) -> JsonValue {
  position_request(id, "textDocument/prepareRename", uri, at, [])
}

/// `textDocument/rename` at a position. The server answers with a
/// `WorkspaceEdit` and writes nothing; see `decode_workspace_edit`.
///
/// ## Examples
///
/// ```gleam
/// protocol.rename_request(jsonrpc.IdInt(6), uri, range.Position(3, 8), "salute")
/// // -> {...,"params":{...,"newName":"salute"}}
/// ```
///
pub fn rename_request(
  id: Id,
  uri: String,
  at: Position,
  new_name: String,
) -> JsonValue {
  position_request(id, "textDocument/rename", uri, at, [
    #("newName", json.String(new_name)),
  ])
}

/// `textDocument/prepareCallHierarchy` at a position: the item the two
/// call requests then walk from.
///
/// ## Examples
///
/// ```gleam
/// protocol.prepare_call_hierarchy_request(jsonrpc.IdInt(8), uri, range.Position(3, 6))
/// // -> {..."method":"textDocument/prepareCallHierarchy",...}
/// ```
///
pub fn prepare_call_hierarchy_request(
  id: Id,
  uri: String,
  at: Position,
) -> JsonValue {
  position_request(id, "textDocument/prepareCallHierarchy", uri, at, [])
}

/// `callHierarchy/incomingCalls` for an item the server returned. The
/// item travels back exactly as the server sent it, `data` included.
///
/// ## Examples
///
/// ```gleam
/// protocol.incoming_calls_request(jsonrpc.IdInt(9), item)
/// // -> {..."method":"callHierarchy/incomingCalls","params":{"item":{...}}}
/// ```
///
pub fn incoming_calls_request(id: Id, item: CallHierarchyItem) -> JsonValue {
  jsonrpc.request(
    id,
    "callHierarchy/incomingCalls",
    Some(json.Object([#("item", item.raw)])),
  )
}

/// `callHierarchy/outgoingCalls` for an item the server returned. The
/// item travels back exactly as the server sent it, `data` included.
///
/// ## Examples
///
/// ```gleam
/// protocol.outgoing_calls_request(jsonrpc.IdInt(10), item)
/// // -> {..."method":"callHierarchy/outgoingCalls","params":{"item":{...}}}
/// ```
///
pub fn outgoing_calls_request(id: Id, item: CallHierarchyItem) -> JsonValue {
  jsonrpc.request(
    id,
    "callHierarchy/outgoingCalls",
    Some(json.Object([#("item", item.raw)])),
  )
}

fn position_request(
  id: Id,
  method: String,
  uri: String,
  at: Position,
  extra: List(#(String, JsonValue)),
) -> JsonValue {
  let params = [
    #("textDocument", document_id(uri)),
    #("position", encode_position(at)),
    ..extra
  ]
  jsonrpc.request(id, method, Some(json.Object(params)))
}

fn document_id(uri: String) -> JsonValue {
  json.Object([#("uri", json.String(uri))])
}

fn encode_position(at: Position) -> JsonValue {
  json.Object([
    #("line", json.Int(at.line)),
    #("character", json.Int(at.character)),
  ])
}

// --- locations --------------------------------------------------------------

/// A place in a document, in the server's coordinates.
pub type Location {
  Location(uri: String, range: Range)
}

/// Decodes a `definition` or `references` answer into a flat list. The
/// protocol allows `null`, one `Location`, a `Location[]` or a
/// `LocationLink[]`, and the measured servers use two of them (`gleam lsp`
/// answers a definition with a bare `Location`, `gopls` with a list). A
/// `LocationLink` becomes its `targetUri` and `targetSelectionRange`: the
/// name at the target, which is what a `Location` from another server
/// would have pointed at.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.decode_locations(json.Null) == Ok([])
/// ```
///
pub fn decode_locations(
  value: JsonValue,
) -> Result(List(Location), ProtocolFault) {
  case value {
    json.Null -> Ok([])
    json.Object(_) -> {
      use location <- result.try(decode_location_like(value, "location"))
      Ok([location])
    }
    json.Array(items) ->
      indexed_map(items, "locations", fn(item, at) {
        decode_location_like(item, at)
      })
    json.String(_) | json.Int(_) | json.Float(_) | json.Bool(_) ->
      Error(BadResult(reason: "locations must be null, an object or a list"))
  }
}

// A `Location` has `uri`; a `LocationLink` has `targetUri`. Deciding by
// that one field rather than by position in a list is what lets a server
// mix them, which nothing in the protocol forbids.
fn decode_location_like(
  value: JsonValue,
  at: String,
) -> Result(Location, ProtocolFault) {
  use fields <- result.try(object_fields(value, at <> " must be an object"))
  case list.key_find(fields, "targetUri") {
    Ok(_) -> {
      use uri <- result.try(required_string(fields, at, "targetUri"))
      use range <- result.try(required_range(fields, at, "targetSelectionRange"))
      Ok(Location(uri:, range:))
    }
    Error(Nil) -> decode_location(fields, at)
  }
}

fn decode_location(
  fields: List(#(String, JsonValue)),
  at: String,
) -> Result(Location, ProtocolFault) {
  use uri <- result.try(required_string(fields, at, "uri"))
  use range <- result.try(required_range(fields, at, "range"))
  Ok(Location(uri:, range:))
}

// --- hover ------------------------------------------------------------------

/// A hover answer, its contents flattened to one string.
pub type HoverResult {
  HoverResult(
    /// The contents as markdown-ish text: a plain string or a
    /// `MarkupContent` value verbatim, a `MarkedString` with a language
    /// as a fenced code block, and a list joined by blank lines.
    contents: String,
    /// The span the hover describes, when the server sent one.
    range: Option(Range),
  )
}

/// Decodes a hover answer. `null` — nothing to say at that position — is
/// `None`. `contents` may be a string (`gleam lsp`), a `MarkupContent`
/// `{kind, value}` (`gopls`), a `MarkedString` `{language, value}`, or a
/// list of strings and `MarkedString`s; all four reach the caller as one
/// string, because the model reads text and the dialect is noise.
///
/// ## Examples
///
/// ```gleam
/// let hover = json.Object([#("contents", json.String("fn() -> Nil"))])
/// assert protocol.decode_hover(hover)
///   == Ok(Some(protocol.HoverResult("fn() -> Nil", None)))
/// ```
///
pub fn decode_hover(
  value: JsonValue,
) -> Result(Option(HoverResult), ProtocolFault) {
  use <- bool.guard(when: value == json.Null, return: Ok(None))
  use fields <- result.try(object_fields(value, "a hover result object"))
  use contents <- result.try(case list.key_find(fields, "contents") {
    Ok(contents) -> hover_contents(contents)
    Error(Nil) -> Error(BadResult(reason: "hover contents is required"))
  })
  use range <- result.try(optional_range(fields, "hover", "range"))
  Ok(Some(HoverResult(contents:, range:)))
}

fn hover_contents(value: JsonValue) -> Result(String, ProtocolFault) {
  case value {
    json.String(text) -> Ok(text)
    json.Object(fields) -> marked(fields)
    json.Array(items) -> {
      use parts <- result.try(
        indexed_map(items, "hover contents", fn(item, at) {
          case item {
            json.String(text) -> Ok(text)
            json.Object(fields) -> marked(fields)
            json.Array(_)
            | json.Int(_)
            | json.Float(_)
            | json.Bool(_)
            | json.Null ->
              Error(BadResult(reason: at <> " must be a string or an object"))
          }
        }),
      )
      Ok(string.join(list.filter(parts, fn(part) { part != "" }), "\n\n"))
    }
    json.Int(_) | json.Float(_) | json.Bool(_) | json.Null ->
      Error(BadResult(reason: "hover contents must be a string, object or list"))
  }
}

// `MarkupContent` carries `kind`; a `MarkedString` object carries
// `language`. Both carry `value`. Only the second needs dressing: its
// language is metadata a model would otherwise lose.
fn marked(fields: List(#(String, JsonValue))) -> Result(String, ProtocolFault) {
  use text <- result.try(required_string(fields, "hover contents", "value"))
  use language <- result.try(optional_string(fields, "language"))
  case language {
    Some(language) -> Ok("```" <> language <> "\n" <> text <> "\n```")
    None -> Ok(text)
  }
}

// --- document symbols -------------------------------------------------------

/// One entry of a hierarchical outline (`DocumentSymbol`).
pub type DocumentSymbol {
  DocumentSymbol(
    name: String,
    /// The raw `SymbolKind` integer; `symbol_kind_name` renders it.
    kind: Int,
    /// E.g. a function's signature, when the server sends one.
    detail: Option(String),
    /// The whole construct, comments and body included.
    range: Range,
    /// The name itself: the position to ask further questions at.
    selection_range: Range,
    children: List(DocumentSymbol),
  )
}

/// One entry of a flat outline (`SymbolInformation`).
pub type SymbolInformation {
  SymbolInformation(
    name: String,
    /// The raw `SymbolKind` integer; `symbol_kind_name` renders it.
    kind: Int,
    location: Location,
    /// The enclosing symbol's name, which is all the nesting a flat
    /// answer carries.
    container_name: Option(String),
  )
}

/// A `documentSymbol` answer, in whichever of its two shapes the server
/// chose.
pub type DocumentSymbols {
  /// `DocumentSymbol[]`, nested. What both measured servers send when the
  /// client declares hierarchical support, as `initialize_request` does.
  /// An empty or `null` answer is an empty `Hierarchical`.
  Hierarchical(symbols: List(DocumentSymbol))

  /// `SymbolInformation[]`, flat, each entry with its own location.
  Flat(symbols: List(SymbolInformation))
}

/// Decodes a `documentSymbol` answer. The shape is decided by the first
/// entry — a `location` field makes it flat — and every later entry must
/// agree, because the protocol types the answer as one array or the
/// other, never a mixture.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.decode_document_symbols(json.Array([]))
///   == Ok(protocol.Hierarchical([]))
/// ```
///
pub fn decode_document_symbols(
  value: JsonValue,
) -> Result(DocumentSymbols, ProtocolFault) {
  case value {
    json.Null -> Ok(Hierarchical([]))
    json.Array([]) -> Ok(Hierarchical([]))
    json.Array([json.Object(first), ..] as items) ->
      case list.key_find(first, "location") {
        Ok(_) -> {
          use symbols <- result.try(indexed_map(
            items,
            "symbols",
            decode_symbol_information,
          ))
          Ok(Flat(symbols))
        }
        Error(Nil) -> {
          use symbols <- result.try(decode_document_symbol_list(
            items,
            "symbols",
          ))
          Ok(Hierarchical(symbols))
        }
      }
    json.Array(_) -> Error(BadResult(reason: "symbols[0] must be an object"))
    json.Object(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_) ->
      Error(BadResult(reason: "document symbols must be a list or null"))
  }
}

fn decode_document_symbol_list(
  items: List(JsonValue),
  at: String,
) -> Result(List(DocumentSymbol), ProtocolFault) {
  indexed_map(items, at, decode_document_symbol)
}

// Recursion here is bounded by `core/json.max_depth`: the parser refuses a
// document nested deeper than that before any decoder sees it.
fn decode_document_symbol(
  value: JsonValue,
  at: String,
) -> Result(DocumentSymbol, ProtocolFault) {
  use fields <- result.try(object_fields(value, at <> " must be an object"))
  use name <- result.try(required_string(fields, at, "name"))
  use kind <- result.try(required_int(fields, at, "kind"))
  use detail <- result.try(optional_string(fields, "detail"))
  use range <- result.try(required_range(fields, at, "range"))
  use selection_range <- result.try(required_range(fields, at, "selectionRange"))
  use children <- result.try(case list.key_find(fields, "children") {
    Error(Nil) | Ok(json.Null) -> Ok([])
    Ok(json.Array(items)) ->
      decode_document_symbol_list(items, at <> ".children")
    Ok(_) -> Error(BadResult(reason: at <> ".children must be a list"))
  })
  Ok(DocumentSymbol(name:, kind:, detail:, range:, selection_range:, children:))
}

fn decode_symbol_information(
  value: JsonValue,
  at: String,
) -> Result(SymbolInformation, ProtocolFault) {
  use fields <- result.try(object_fields(value, at <> " must be an object"))
  use name <- result.try(required_string(fields, at, "name"))
  use kind <- result.try(required_int(fields, at, "kind"))
  use location <- result.try(case list.key_find(fields, "location") {
    Ok(json.Object(location)) -> decode_location(location, at <> ".location")
    Ok(_) | Error(Nil) ->
      Error(BadResult(reason: at <> ".location must be an object"))
  })
  use container_name <- result.try(optional_string(fields, "containerName"))
  Ok(SymbolInformation(name:, kind:, location:, container_name:))
}

/// Renders an LSP `SymbolKind` as the lowercase word `lsp/query.SymbolEntry`
/// carries, so no raw integer ever reaches a model. An integer outside
/// the protocol's 1–26 renders as `symbol`: a newer server's new kind is
/// still a symbol, and refusing a whole outline over it would be worse.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.symbol_kind_name(12) == "function"
/// ```
///
/// ```gleam
/// assert protocol.symbol_kind_name(99) == "symbol"
/// ```
///
pub fn symbol_kind_name(kind: Int) -> String {
  case kind {
    1 -> "file"
    2 -> "module"
    3 -> "namespace"
    4 -> "package"
    5 -> "class"
    6 -> "method"
    7 -> "property"
    8 -> "field"
    9 -> "constructor"
    10 -> "enum"
    11 -> "interface"
    12 -> "function"
    13 -> "variable"
    14 -> "constant"
    15 -> "string"
    16 -> "number"
    17 -> "boolean"
    18 -> "array"
    19 -> "object"
    20 -> "key"
    21 -> "null"
    22 -> "enum member"
    23 -> "struct"
    24 -> "event"
    25 -> "operator"
    26 -> "type parameter"
    _ -> "symbol"
  }
}

// --- workspace edits --------------------------------------------------------

/// Every edit a `WorkspaceEdit` asks for in one document.
pub type DocumentEdits {
  DocumentEdits(
    uri: String,
    /// The document version the edits were computed against, when the
    /// server stated one (`documentChanges` with a non-null version). The
    /// harness's own concurrency check is the hashline digest of the base
    /// text, so this is carried for reporting, not trusted.
    version: Option(Int),
    /// In the server's order. Ranges refer to the document before any of
    /// them is applied.
    edits: List(TextEdit),
  )
}

/// A decoded `WorkspaceEdit`: text edits only. A URI may appear in more
/// than one entry when the server split its edits that way; the caller
/// that applies them groups by URI.
pub type WorkspaceEdit {
  WorkspaceEdit(documents: List(DocumentEdits))
}

/// Why a `WorkspaceEdit` was not accepted.
pub type WorkspaceEditFault {
  /// The edit is not a well-formed `WorkspaceEdit`.
  EditMalformed(fault: ProtocolFault)

  /// The edit asks to create, rename or delete a file. Edits land only
  /// through the hashline path, which edits existing files (ADR-013 §4),
  /// so the whole rename is refused, naming the operation, rather than
  /// landing its text edits without the file operation they depend on.
  ResourceOperationRefused(kind: String, uri: String)
}

/// Decodes a rename answer. `documentChanges` is preferred when present,
/// as the protocol directs for a client that declared support for it;
/// otherwise the `changes` map is read. `null` means no change is needed
/// and is an empty edit. A resource operation anywhere in
/// `documentChanges` refuses the whole edit.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.decode_workspace_edit(json.Null)
///   == Ok(protocol.WorkspaceEdit([]))
/// ```
///
pub fn decode_workspace_edit(
  value: JsonValue,
) -> Result(WorkspaceEdit, WorkspaceEditFault) {
  use <- bool.guard(when: value == json.Null, return: Ok(WorkspaceEdit([])))
  use fields <- result.try(
    object_fields(value, "a workspace edit object")
    |> result.map_error(EditMalformed),
  )
  case list.key_find(fields, "documentChanges") {
    Ok(json.Array(changes)) -> {
      use documents <- result.try(document_changes(changes, 0, []))
      Ok(WorkspaceEdit(documents:))
    }
    Ok(_) -> malformed_edit("documentChanges must be a list")
    Error(Nil) ->
      case list.key_find(fields, "changes") {
        Error(Nil) -> Ok(WorkspaceEdit([]))
        Ok(json.Object(by_uri)) -> {
          use documents <- result.try(
            changes_map(by_uri)
            |> result.map_error(EditMalformed),
          )
          Ok(WorkspaceEdit(documents:))
        }
        Ok(_) -> malformed_edit("changes must be an object")
      }
  }
}

fn malformed_edit(reason: String) -> Result(a, WorkspaceEditFault) {
  Error(EditMalformed(BadResult(reason:)))
}

fn changes_map(
  by_uri: List(#(String, JsonValue)),
) -> Result(List(DocumentEdits), ProtocolFault) {
  list.try_map(by_uri, fn(entry) {
    let #(uri, edits) = entry
    use edits <- result.try(text_edits(edits, "changes[" <> uri <> "]"))
    Ok(DocumentEdits(uri:, version: None, edits:))
  })
}

// Each entry is a `TextDocumentEdit` or a resource operation; the latter
// carries a string `kind`. It is refused on sight, before any later entry
// is read, so the refusal names the first file operation in the edit.
fn document_changes(
  changes: List(JsonValue),
  index: Int,
  done: List(DocumentEdits),
) -> Result(List(DocumentEdits), WorkspaceEditFault) {
  case changes {
    [] -> Ok(list.reverse(done))
    [change, ..rest] -> {
      let at = "documentChanges[" <> int.to_string(index) <> "]"
      use fields <- result.try(
        object_fields(change, at <> " must be an object")
        |> result.map_error(EditMalformed),
      )
      use Nil <- result.try(refuse_resource_operation(fields))
      use document <- result.try(
        text_document_edit(fields, at) |> result.map_error(EditMalformed),
      )
      document_changes(rest, index + 1, [document, ..done])
    }
  }
}

fn refuse_resource_operation(
  fields: List(#(String, JsonValue)),
) -> Result(Nil, WorkspaceEditFault) {
  case list.key_find(fields, "kind") {
    Error(Nil) -> Ok(Nil)
    Ok(kind) -> {
      // A non-string kind is still a resource operation's shape; its JSON
      // text names it well enough for the refusal.
      let kind = case kind {
        json.String(kind) -> kind
        json.Object(_)
        | json.Array(_)
        | json.Int(_)
        | json.Float(_)
        | json.Bool(_)
        | json.Null -> json.to_string(kind)
      }
      let uri =
        list.find_map(["uri", "oldUri"], fn(key) {
          case list.key_find(fields, key) {
            Ok(json.String(uri)) -> Ok(uri)
            Ok(_) | Error(Nil) -> Error(Nil)
          }
        })
        |> result.unwrap("")
      Error(ResourceOperationRefused(kind:, uri:))
    }
  }
}

fn text_document_edit(
  fields: List(#(String, JsonValue)),
  at: String,
) -> Result(DocumentEdits, ProtocolFault) {
  use document <- result.try(case list.key_find(fields, "textDocument") {
    Ok(json.Object(document)) -> Ok(document)
    Ok(_) | Error(Nil) ->
      Error(BadResult(reason: at <> ".textDocument must be an object"))
  })
  use uri <- result.try(required_string(document, at <> ".textDocument", "uri"))
  use version <- result.try(case list.key_find(document, "version") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Int(version)) -> Ok(Some(version))
    Ok(_) ->
      Error(BadResult(reason: at <> ".textDocument.version must be an integer"))
  })
  use edits <- result.try(case list.key_find(fields, "edits") {
    Ok(edits) -> text_edits(edits, at <> ".edits")
    Error(Nil) -> Error(BadResult(reason: at <> ".edits is required"))
  })
  Ok(DocumentEdits(uri:, version:, edits:))
}

// `TextEdit` and `AnnotatedTextEdit` share `range` and `newText`; the
// annotation id is ignored, since the harness confirms nothing per edit.
fn text_edits(
  value: JsonValue,
  at: String,
) -> Result(List(TextEdit), ProtocolFault) {
  case value {
    json.Array(items) ->
      indexed_map(items, at, fn(item, at) {
        use fields <- result.try(object_fields(item, at <> " must be an object"))
        use range <- result.try(required_range(fields, at, "range"))
        use new_text <- result.try(required_string(fields, at, "newText"))
        Ok(range.TextEdit(range:, new_text:))
      })
    json.Object(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(BadResult(reason: at <> " must be a list"))
  }
}

// --- prepare rename ---------------------------------------------------------

/// A `prepareRename` answer.
pub type PrepareRename {
  /// Renaming here is valid and would replace `range`. `placeholder`
  /// is the server's suggested current name, when it sent one.
  CanRename(range: Range, placeholder: Option(String))

  /// Renaming here is valid; the server leaves the range to the client's
  /// own word rules (`{defaultBehavior: true}`).
  CanRenameDefault

  /// Renaming is not valid at this position: a `null` answer, or
  /// `{defaultBehavior: false}`.
  CannotRename
}

/// Decodes a `prepareRename` answer: a bare `Range` (`gleam lsp`),
/// `{range, placeholder}` (`gopls`), `{defaultBehavior}`, or `null`.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.decode_prepare_rename(json.Null) == Ok(protocol.CannotRename)
/// ```
///
pub fn decode_prepare_rename(
  value: JsonValue,
) -> Result(PrepareRename, ProtocolFault) {
  use <- bool.guard(when: value == json.Null, return: Ok(CannotRename))
  use fields <- result.try(object_fields(value, "a prepare rename result"))
  case
    list.key_find(fields, "start"),
    list.key_find(fields, "range"),
    list.key_find(fields, "defaultBehavior")
  {
    Ok(_), _, _ -> {
      use range <- result.try(decode_range(value, "prepare rename"))
      Ok(CanRename(range:, placeholder: None))
    }
    Error(Nil), Ok(_), _ -> {
      use range <- result.try(required_range(fields, "prepare rename", "range"))
      use placeholder <- result.try(optional_string(fields, "placeholder"))
      Ok(CanRename(range:, placeholder:))
    }
    Error(Nil), Error(Nil), Ok(json.Bool(True)) -> Ok(CanRenameDefault)
    Error(Nil), Error(Nil), Ok(json.Bool(False)) -> Ok(CannotRename)
    Error(Nil), Error(Nil), Ok(_) ->
      Error(BadResult(reason: "defaultBehavior must be a boolean"))
    Error(Nil), Error(Nil), Error(Nil) ->
      Error(BadResult(
        reason: "a prepare rename result must be a range, carry one, or carry defaultBehavior",
      ))
  }
}

// --- call hierarchy ---------------------------------------------------------

/// A `CallHierarchyItem`: one function-like symbol a call-hierarchy walk
/// starts from or reaches.
pub type CallHierarchyItem {
  CallHierarchyItem(
    name: String,
    /// The raw `SymbolKind` integer; `symbol_kind_name` renders it.
    kind: Int,
    detail: Option(String),
    uri: String,
    /// The whole construct.
    range: Range,
    /// The name: where the symbol is defined, for a `path:line` answer.
    selection_range: Range,
    /// The item exactly as the server sent it. The protocol requires the
    /// follow-up requests to send the item back, and its `data` field is
    /// the server's own opaque state, so it is echoed rather than
    /// re-encoded from the fields above.
    raw: JsonValue,
  )
}

/// One caller found by `callHierarchy/incomingCalls`.
pub type IncomingCall {
  IncomingCall(
    /// The calling symbol.
    from: CallHierarchyItem,
    /// Where, inside `from`, the calls appear.
    from_ranges: List(Range),
  )
}

/// One callee found by `callHierarchy/outgoingCalls`.
pub type OutgoingCall {
  OutgoingCall(
    /// The called symbol.
    to: CallHierarchyItem,
    /// Where, inside the item the walk started from, the calls appear.
    from_ranges: List(Range),
  )
}

/// Decodes a `prepareCallHierarchy` answer; `null` is no items.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.decode_call_hierarchy_items(json.Null) == Ok([])
/// ```
///
pub fn decode_call_hierarchy_items(
  value: JsonValue,
) -> Result(List(CallHierarchyItem), ProtocolFault) {
  nullable_list(value, "call hierarchy items", decode_call_hierarchy_item)
}

/// Decodes a `callHierarchy/incomingCalls` answer; `null` is no calls.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.decode_incoming_calls(json.Array([])) == Ok([])
/// ```
///
pub fn decode_incoming_calls(
  value: JsonValue,
) -> Result(List(IncomingCall), ProtocolFault) {
  nullable_list(value, "incoming calls", fn(item, at) {
    use #(from, from_ranges) <- result.try(call_edge(item, at, "from"))
    Ok(IncomingCall(from:, from_ranges:))
  })
}

/// Decodes a `callHierarchy/outgoingCalls` answer; `null` is no calls.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.decode_outgoing_calls(json.Array([])) == Ok([])
/// ```
///
pub fn decode_outgoing_calls(
  value: JsonValue,
) -> Result(List(OutgoingCall), ProtocolFault) {
  nullable_list(value, "outgoing calls", fn(item, at) {
    use #(to, from_ranges) <- result.try(call_edge(item, at, "to"))
    Ok(OutgoingCall(to:, from_ranges:))
  })
}

fn call_edge(
  value: JsonValue,
  at: String,
  end: String,
) -> Result(#(CallHierarchyItem, List(Range)), ProtocolFault) {
  use fields <- result.try(object_fields(value, at <> " must be an object"))
  use item <- result.try(case list.key_find(fields, end) {
    Ok(item) -> decode_call_hierarchy_item(item, at <> "." <> end)
    Error(Nil) -> Error(BadResult(reason: at <> "." <> end <> " is required"))
  })
  use ranges <- result.try(case list.key_find(fields, "fromRanges") {
    Ok(json.Array(ranges)) ->
      indexed_map(ranges, at <> ".fromRanges", decode_range)
    Ok(_) | Error(Nil) ->
      Error(BadResult(reason: at <> ".fromRanges must be a list"))
  })
  Ok(#(item, ranges))
}

fn decode_call_hierarchy_item(
  value: JsonValue,
  at: String,
) -> Result(CallHierarchyItem, ProtocolFault) {
  use fields <- result.try(object_fields(value, at <> " must be an object"))
  use name <- result.try(required_string(fields, at, "name"))
  use kind <- result.try(required_int(fields, at, "kind"))
  use detail <- result.try(optional_string(fields, "detail"))
  use uri <- result.try(required_string(fields, at, "uri"))
  use range <- result.try(required_range(fields, at, "range"))
  use selection_range <- result.try(required_range(fields, at, "selectionRange"))
  Ok(CallHierarchyItem(
    name:,
    kind:,
    detail:,
    uri:,
    range:,
    selection_range:,
    raw: value,
  ))
}

// --- diagnostics and other server notifications -----------------------------

/// One diagnostic as the server published it, in the server's coordinates.
pub type ServerDiagnostic {
  ServerDiagnostic(
    range: Range,
    severity: Severity,
    message: String,
    /// The producing tool (`gopls` sends e.g. `syntax`), when sent.
    source: Option(String),
  )
}

/// A `textDocument/publishDiagnostics` notification's params. Each
/// publication replaces every earlier one for the same URI; an empty list
/// clears it.
pub type PublishDiagnostics {
  PublishDiagnostics(
    uri: String,
    /// The document version the diagnostics are for. `gopls` sends it;
    /// `gleam lsp` never does, which is why ADR-013 §3's settlement rule
    /// waits on a version only for a server that has ever sent one.
    version: Option(Int),
    diagnostics: List(ServerDiagnostic),
  )
}

/// Decodes `publishDiagnostics` params.
///
/// A diagnostic's `severity` is optional, and when it is omitted the
/// protocol leaves the reading to the client. It is read as an **error**
/// here. The harness shows these to a model after an edit, and the costly
/// mistake is a real problem reported as a hint and passed over; an
/// over-reported one costs a second look. A severity outside 1–4 is not a
/// dialect but a lie, and is refused.
///
/// ## Examples
///
/// ```gleam
/// let params = json.Object([
///   #("uri", json.String("file:///a.gleam")),
///   #("diagnostics", json.Array([])),
/// ])
/// assert protocol.decode_publish_diagnostics(params)
///   == Ok(protocol.PublishDiagnostics("file:///a.gleam", None, []))
/// ```
///
pub fn decode_publish_diagnostics(
  value: JsonValue,
) -> Result(PublishDiagnostics, ProtocolFault) {
  use fields <- result.try(object_fields(value, "publishDiagnostics params"))
  use uri <- result.try(required_string(fields, "publishDiagnostics", "uri"))
  use version <- result.try(case list.key_find(fields, "version") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Int(version)) -> Ok(Some(version))
    Ok(_) -> Error(BadResult(reason: "version must be an integer"))
  })
  use diagnostics <- result.try(case list.key_find(fields, "diagnostics") {
    Ok(json.Array(items)) ->
      indexed_map(items, "diagnostics", decode_diagnostic)
    Ok(_) | Error(Nil) -> Error(BadResult(reason: "diagnostics must be a list"))
  })
  Ok(PublishDiagnostics(uri:, version:, diagnostics:))
}

fn decode_diagnostic(
  value: JsonValue,
  at: String,
) -> Result(ServerDiagnostic, ProtocolFault) {
  use fields <- result.try(object_fields(value, at <> " must be an object"))
  use range <- result.try(required_range(fields, at, "range"))
  use message <- result.try(required_string(fields, at, "message"))
  use source <- result.try(optional_string(fields, "source"))
  use severity <- result.try(case list.key_find(fields, "severity") {
    Error(Nil) | Ok(json.Null) -> Ok(SeverityError)
    Ok(json.Int(1)) -> Ok(SeverityError)
    Ok(json.Int(2)) -> Ok(SeverityWarning)
    Ok(json.Int(3)) -> Ok(SeverityInformation)
    Ok(json.Int(4)) -> Ok(SeverityHint)
    Ok(_) -> Error(BadResult(reason: at <> ".severity must be 1, 2, 3 or 4"))
  })
  Ok(ServerDiagnostic(range:, severity:, message:, source:))
}

/// A work-done progress token, as the server minted it. The protocol
/// allows an integer or a string, so the two are kept apart: `1` and
/// `"1"` are different tokens, and a client that folded them together
/// could let one progress's `end` close another's.
pub type ProgressToken {
  /// A token the server wrote as a JSON integer.
  IntToken(value: Int)

  /// A token the server wrote as a JSON string, such as
  /// `rustAnalyzer/cachePriming`.
  StringToken(value: String)
}

/// One `$/progress` notification about work-done progress, decoded to
/// what the client's readiness needs: which token moved, and for a
/// `begin`, the title a waiting caller is told. A `report`'s percentage
/// and message are dropped; nobody reads them.
pub type WorkDoneProgress {
  /// The work named by `token` started.
  ProgressBegin(
    /// The server's token for this work.
    token: ProgressToken,
    /// The server's short name for the work, such as `Indexing`.
    title: String,
  )

  /// The work named by `token` is still going.
  ProgressReport(
    /// The server's token for this work.
    token: ProgressToken,
  )

  /// The work named by `token` finished.
  ProgressEnd(
    /// The server's token for this work.
    token: ProgressToken,
  )
}

/// A server notification, classified.
pub type ServerNotification {
  /// `textDocument/publishDiagnostics`, decoded.
  Published(diagnostics: PublishDiagnostics)

  /// `$/progress` carrying work-done progress, decoded. The client tracks
  /// the active tokens so a query waits until the server is ready.
  Progressed(progress: WorkDoneProgress)

  /// `window/logMessage` or `window/showMessage`: known, and deliberately
  /// not acted on. Their text is the server's to say and nobody's to
  /// read; stderr's ring is the restart message's source.
  Ignored(method: String)

  /// Any other notification. Also dropped, but distinguishable from the
  /// known ones for a caller that wants to count the unexpected.
  Unrecognised(method: String)
}

/// Classifies a server notification, decoding the two the harness acts
/// on. A malformed `publishDiagnostics` or `$/progress` is a fault, which
/// the caller may log and drop; it never poisons the transport, since the
/// envelope around it was well-formed.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.classify_notification("window/logMessage", None)
///   == Ok(protocol.Ignored("window/logMessage"))
/// ```
///
pub fn classify_notification(
  method: String,
  params: Option(JsonValue),
) -> Result(ServerNotification, ProtocolFault) {
  case method {
    "textDocument/publishDiagnostics" -> {
      use diagnostics <- result.try(
        decode_publish_diagnostics(option.unwrap(params, json.Null)),
      )
      Ok(Published(diagnostics:))
    }
    "$/progress" -> {
      use progress <- result.try(
        decode_work_done_progress(option.unwrap(params, json.Null)),
      )
      Ok(Progressed(progress:))
    }
    "window/logMessage" | "window/showMessage" -> Ok(Ignored(method:))
    _ -> Ok(Unrecognised(method:))
  }
}

/// Decodes the params of a `$/progress` notification as work-done
/// progress: `{token, value: {kind, ...}}`, where `kind` is `begin`
/// (with a required `title`), `report` or `end`. Anything else — a
/// partial-result stream, which this client never asks for, or a value
/// with no known `kind` — is a fault, not a guess.
///
/// ## Examples
///
/// ```gleam
/// // {"token": "load", "value": {"kind": "begin", "title": "Loading"}}
/// // -> Ok(protocol.ProgressBegin(protocol.StringToken("load"), "Loading"))
/// ```
///
pub fn decode_work_done_progress(
  value: JsonValue,
) -> Result(WorkDoneProgress, ProtocolFault) {
  use fields <- result.try(object_fields(value, "progress params"))
  use token <- result.try(case list.key_find(fields, "token") {
    Ok(json.Int(number)) -> Ok(IntToken(value: number))
    Ok(json.String(text)) -> Ok(StringToken(value: text))
    Ok(_) | Error(Nil) ->
      Error(BadResult(reason: "progress.token must be an integer or a string"))
  })
  use progress <- result.try(case list.key_find(fields, "value") {
    Ok(progress) -> object_fields(progress, "progress.value must be an object")
    Error(Nil) -> Error(BadResult(reason: "progress.value is required"))
  })

  // `kind` is what makes a progress value work-done progress; its absence
  // is the protocol's partial-result shape, which this client never
  // requested.
  use kind <- result.try(required_string(progress, "progress.value", "kind"))
  case kind {
    "begin" -> {
      use title <- result.try(required_string(
        progress,
        "progress.value",
        "title",
      ))
      Ok(ProgressBegin(token:, title:))
    }
    "report" -> Ok(ProgressReport(token:))
    "end" -> Ok(ProgressEnd(token:))
    _ ->
      Error(BadResult(
        reason: "progress.value.kind must be begin, report or end",
      ))
  }
}

// --- server requests --------------------------------------------------------

/// JSON-RPC's method-not-found code, the answer to every server request
/// this module does not name.
pub const method_not_found_code = -32_601

/// JSON-RPC's invalid-params code.
pub const invalid_params_code = -32_602

/// The answer to a request the server sent us, as the `result` value or
/// the error to send back with `mcp/jsonrpc.response` or
/// `mcp/jsonrpc.error_response`. Pure, so the actor only sends what this
/// returns.
///
/// - `workspace/configuration`: one `null` per requested item. Servers
///   are configured by their `[lsp.<name>]` table and command line, never
///   by settings pushed at runtime.
/// - `window/workDoneProgress/create`, `client/registerCapability`,
///   `client/unregisterCapability`: `null`, which accepts. A created
///   token is tracked when its `begin` arrives, and a dynamic registration
///   changes nothing, because requests are gated on the capabilities
///   `initialize` returned.
/// - `workspace/workspaceFolders`: the folders the server was started
///   with.
/// - `workspace/applyEdit`: `{applied: false}` with a reason. The server
///   never writes; edits land only through the hashline path (ADR-013 §4).
/// - anything else: method-not-found.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.answer_server_request("window/workDoneProgress/create", None, [])
///   == Ok(json.Null)
/// ```
///
pub fn answer_server_request(
  method: String,
  params: Option(JsonValue),
  folders: List(WorkspaceFolder),
) -> Result(JsonValue, RpcError) {
  case method {
    "workspace/configuration" -> configuration_answer(params)
    "window/workDoneProgress/create"
    | "client/registerCapability"
    | "client/unregisterCapability" -> Ok(json.Null)
    "workspace/workspaceFolders" -> Ok(encode_folders(folders))
    "workspace/applyEdit" ->
      Ok(
        json.Object([
          #("applied", json.Bool(False)),
          #(
            "failureReason",
            json.String(
              "this client applies edits only through its own checked write path",
            ),
          ),
        ]),
      )
    _ ->
      Error(RpcError(
        code: method_not_found_code,
        message: "method not found: " <> method,
        data: None,
      ))
  }
}

fn configuration_answer(
  params: Option(JsonValue),
) -> Result(JsonValue, RpcError) {
  case params {
    Some(json.Object(fields)) ->
      case list.key_find(fields, "items") {
        Ok(json.Array(items)) ->
          Ok(json.Array(list.map(items, fn(_) { json.Null })))
        Ok(_) | Error(Nil) -> invalid_params("items must be a list")
      }
    Some(_) | None -> invalid_params("params must be an object")
  }
}

fn invalid_params(reason: String) -> Result(JsonValue, RpcError) {
  Error(RpcError(code: invalid_params_code, message: reason, data: None))
}

// --- file URIs --------------------------------------------------------------

/// Why a path or a URI did not convert.
pub type UriFault {
  /// A path handed to `path_to_uri` was not absolute.
  NotAbsolute(path: String)

  /// The URI is not a local `file://` URI with an absolute path: another
  /// scheme, a remote authority, or a query or fragment.
  NotFileUri(uri: String)

  /// A `%` escape was not followed by two hex digits.
  BadEscape(uri: String)

  /// The decoded path is not UTF-8, or it contains a NUL byte, which no
  /// filesystem path can.
  NotAPath(uri: String)
}

/// Renders an absolute path as a `file://` URI. Unreserved characters,
/// `/`, and the sub-delimiters RFC 3986 allows in a path segment are kept;
/// every other byte — space, `%`, `#`, `?`, controls, and each byte of a
/// non-ASCII character's UTF-8 encoding — becomes an uppercase `%XX`
/// escape, so the URI is ASCII and survives any server's parser.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.path_to_uri("/work/my file.gleam")
///   == Ok("file:///work/my%20file.gleam")
/// ```
///
pub fn path_to_uri(path: String) -> Result(String, UriFault) {
  use <- bool.guard(
    when: !string.starts_with(path, "/"),
    return: Error(NotAbsolute(path:)),
  )
  Ok("file://" <> encode_bytes(<<path:utf8>>, []))
}

fn encode_bytes(bytes: BitArray, done: List(String)) -> String {
  case bytes {
    <<byte, rest:bytes>> -> encode_bytes(rest, [encode_byte(byte), ..done])
    _ -> string.concat(list.reverse(done))
  }
}

fn encode_byte(byte: Int) -> String {
  case is_path_safe(byte) {
    True -> ascii(byte)
    False -> "%" <> hex2(byte)
  }
}

// RFC 3986 `pchar` plus `/`, minus `%`: ALPHA, DIGIT, `-._~`, the
// sub-delimiters `!$&'()*+,;=`, and `:@`.
fn is_path_safe(byte: Int) -> Bool {
  { byte >= 0x61 && byte <= 0x7A }
  || { byte >= 0x41 && byte <= 0x5A }
  || { byte >= 0x30 && byte <= 0x39 }
  || list.contains(
    [
      0x2D,
      0x2E,
      0x5F,
      0x7E,
      0x2F,
      0x21,
      0x24,
      0x26,
      0x27,
      0x28,
      0x29,
      0x2A,
      0x2B,
      0x2C,
      0x3B,
      0x3D,
      0x3A,
      0x40,
    ],
    byte,
  )
}

// Only ever called on bytes `is_path_safe` accepted, which are ASCII, so
// the conversion cannot fail; the fallback is the honest empty reading.
fn ascii(byte: Int) -> String {
  bit_array.to_string(<<byte>>) |> result.unwrap("")
}

fn hex2(byte: Int) -> String {
  string.pad_start(int.to_base16(byte), to: 2, with: "0")
}

/// Converts a `file://` URI back to an absolute path, strictly: the
/// authority must be empty or `localhost`, there may be no query or
/// fragment, every `%` must begin a two-hex-digit escape, and the decoded
/// bytes must be UTF-8 with no NUL. A malformed escape is refused rather
/// than passed through, because a path that is not what the server meant
/// is worse than no path.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.uri_to_path("file:///work/caf%C3%A9.gleam")
///   == Ok("/work/café.gleam")
/// ```
///
/// ```gleam
/// assert protocol.uri_to_path("file:///work/%zz")
///   == Error(protocol.BadEscape("file:///work/%zz"))
/// ```
///
pub fn uri_to_path(uri: String) -> Result(String, UriFault) {
  use rest <- result.try(case string.split_once(uri, "://") {
    Ok(#(scheme, rest)) ->
      case string.lowercase(scheme) {
        "file" -> Ok(rest)
        _ -> Error(NotFileUri(uri:))
      }
    Error(Nil) -> Error(NotFileUri(uri:))
  })
  use encoded <- result.try(case rest {
    "/" <> _ -> Ok(rest)
    "localhost/" <> path -> Ok("/" <> path)
    _ -> Error(NotFileUri(uri:))
  })
  use <- bool.guard(
    when: string.contains(encoded, "?") || string.contains(encoded, "#"),
    return: Error(NotFileUri(uri:)),
  )
  use bytes <- result.try(decode_escapes(<<encoded:utf8>>, <<>>, uri))
  use path <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(NotAPath(uri:)),
  )
  case string.contains(path, "\u{0}") {
    True -> Error(NotAPath(uri:))
    False -> Ok(path)
  }
}

fn decode_escapes(
  bytes: BitArray,
  done: BitArray,
  uri: String,
) -> Result(BitArray, UriFault) {
  case bytes {
    <<>> -> Ok(done)
    <<0x25, high, low, rest:bytes>> -> {
      use high <- result.try(hex_digit(high, uri))
      use low <- result.try(hex_digit(low, uri))
      decode_escapes(rest, <<done:bits, { high * 16 + low }>>, uri)
    }
    <<0x25, _:bits>> -> Error(BadEscape(uri:))
    <<byte, rest:bytes>> -> decode_escapes(rest, <<done:bits, byte>>, uri)
    _ -> Error(NotAPath(uri:))
  }
}

fn hex_digit(byte: Int, uri: String) -> Result(Int, UriFault) {
  case byte {
    _ if byte >= 0x30 && byte <= 0x39 -> Ok(byte - 0x30)
    _ if byte >= 0x41 && byte <= 0x46 -> Ok(byte - 0x41 + 10)
    _ if byte >= 0x61 && byte <= 0x66 -> Ok(byte - 0x61 + 10)
    _ -> Error(BadEscape(uri:))
  }
}

// --- shared decoding helpers ------------------------------------------------

// Maps a decoder over a list, naming each element `<at>[<index>]` so a
// fault says which entry of which list broke. One lying entry fails the
// whole list: a server lying about one location is not a server to
// half-trust (the `mcp/protocol` posture).
fn indexed_map(
  items: List(JsonValue),
  at: String,
  decode: fn(JsonValue, String) -> Result(a, ProtocolFault),
) -> Result(List(a), ProtocolFault) {
  list.index_map(items, fn(item, index) { #(item, index) })
  |> list.try_map(fn(pair) {
    let #(item, index) = pair
    decode(item, at <> "[" <> int.to_string(index) <> "]")
  })
}

fn nullable_list(
  value: JsonValue,
  at: String,
  decode: fn(JsonValue, String) -> Result(a, ProtocolFault),
) -> Result(List(a), ProtocolFault) {
  case value {
    json.Null -> Ok([])
    json.Array(items) -> indexed_map(items, at, decode)
    json.Object(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_) -> Error(BadResult(reason: at <> " must be a list or null"))
  }
}

fn object_fields(
  value: JsonValue,
  expected: String,
) -> Result(List(#(String, JsonValue)), ProtocolFault) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(BadResult(reason: expected))
  }
}

fn required_string(
  fields: List(#(String, JsonValue)),
  at: String,
  key: String,
) -> Result(String, ProtocolFault) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Ok(text)
    Ok(_) -> Error(BadResult(reason: at <> "." <> key <> " must be a string"))
    Error(Nil) -> Error(BadResult(reason: at <> "." <> key <> " is required"))
  }
}

fn optional_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Option(String), ProtocolFault) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.String(text)) -> Ok(Some(text))
    Ok(_) -> Error(BadResult(reason: key <> " must be a string"))
  }
}

fn required_int(
  fields: List(#(String, JsonValue)),
  at: String,
  key: String,
) -> Result(Int, ProtocolFault) {
  case list.key_find(fields, key) {
    Ok(json.Int(value)) -> Ok(value)
    Ok(_) -> Error(BadResult(reason: at <> "." <> key <> " must be an integer"))
    Error(Nil) -> Error(BadResult(reason: at <> "." <> key <> " is required"))
  }
}

// Absent reads as `False`, the protocol's stated default for both
// `openClose` and `prepareProvider`; present-and-not-a-boolean is a fault.
fn defaulted_bool(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Bool, ProtocolFault) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(False)
    Ok(json.Bool(value)) -> Ok(value)
    Ok(_) -> Error(BadResult(reason: key <> " must be a boolean"))
  }
}

fn required_range(
  fields: List(#(String, JsonValue)),
  at: String,
  key: String,
) -> Result(Range, ProtocolFault) {
  case list.key_find(fields, key) {
    Ok(value) -> decode_range(value, at <> "." <> key)
    Error(Nil) -> Error(BadResult(reason: at <> "." <> key <> " is required"))
  }
}

fn optional_range(
  fields: List(#(String, JsonValue)),
  at: String,
  key: String,
) -> Result(Option(Range), ProtocolFault) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(value) -> {
      use range <- result.try(decode_range(value, at <> "." <> key))
      Ok(Some(range))
    }
  }
}

fn decode_range(value: JsonValue, at: String) -> Result(Range, ProtocolFault) {
  use fields <- result.try(object_fields(value, at <> " must be a range object"))
  use start <- result.try(position_field(fields, at, "start"))
  use end <- result.try(position_field(fields, at, "end"))
  Ok(Range(start:, end:))
}

// Lines and characters are `uinteger` in the protocol; a negative one is
// refused here so `lsp/text` never has to ask.
fn position_field(
  fields: List(#(String, JsonValue)),
  at: String,
  key: String,
) -> Result(Position, ProtocolFault) {
  let at = at <> "." <> key
  use position <- result.try(case list.key_find(fields, key) {
    Ok(json.Object(position)) -> Ok(position)
    Ok(_) | Error(Nil) -> Error(BadResult(reason: at <> " must be a position"))
  })
  use line <- result.try(required_int(position, at, "line"))
  use character <- result.try(required_int(position, at, "character"))
  case line >= 0 && character >= 0 {
    True -> Ok(Position(line:, character:))
    False -> Error(BadResult(reason: at <> " must not be negative"))
  }
}
