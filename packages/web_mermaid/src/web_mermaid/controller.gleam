//// Pure state machine for the isolated Mermaid frame.
////
//// The runtime owns DOM parsing and vendor invocation; this module validates
//// incoming data and orders completions so stale work cannot publish.

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// The only renderer themes accepted over the frame protocol.
pub type Theme {
  /// The dark Mermaid palette.
  Dark

  /// Mermaid's built-in default (light) palette.
  Light
}

/// One bounded render request.
pub type Request {
  /// Source remains an opaque string; the frame never echoes it to the parent.
  /// Theme and revision bind the fixed renderer configuration and ordering.
  Request(source: String, theme: Theme, revision: Int)
}

/// The vendor stage currently in flight.
pub type Stage {
  /// Mermaid is producing markup for the active request.
  Drawing

  /// The produced markup is being parsed and checked before installation.
  Checking
}

/// Serialized work, with at most one replaceable waiting request.
pub type Phase {
  /// No vendor request is currently in flight.
  Idle

  /// `stage` and `request` are the single non-cancellable active operation;
  /// `queued` retains only the most recently accepted successor.
  Busy(stage: Stage, request: Request, queued: option.Option(Request))
}

/// Controller state owned by the iframe runtime.
pub type Model {
  /// `latest` is the highest accepted revision. `shown` is valid only while
  /// it equals `latest`; width suppresses duplicate resize measurements.
  Model(latest: Int, phase: Phase, shown: option.Option(Int), width: Float)
}

/// Events delivered by the parent, vendor bridge, or resize observer.
pub type Msg {
  /// A validated request from the parent.
  Requested(request: Request)

  /// A policy-bearing request that is refused but advances the revision.
  Refused(revision: Int)

  /// Vendor completion; success carries SVG only inside the isolated frame.
  Rendered(revision: Int, result: Result(String, Nil))

  /// DOM validation and installation completion with measured height.
  Published(revision: Int, result: Result(Float, Nil))

  /// A new document width from ResizeObserver.
  Resized(width: Float)

  /// A fresh height for the currently shown revision.
  Measured(revision: Int, height: Float)
}

/// A fixed-shape message sent to the parent.
pub type Reply {
  /// The frame has initialized and can receive requests.
  Ready

  /// A successful render and its bounded integer height.
  RenderedReply(revision: Int, height: Int)

  /// A fixed failure status without source, SVG, or vendor diagnostics.
  FailedReply(revision: Int)
}

/// Work that the thin browser adapter must perform.
pub type Effect {
  /// Clear old display and invoke Mermaid for one request.
  Begin(request: Request)

  /// Validate and install one SVG only after freshness was established.
  Inspect(revision: Int, svg: String)

  /// Remove the current displayed diagram.
  Clear

  /// Send the fixed JSON reply to the exact parent window.
  ReplyToParent(reply: Reply)

  /// Measure the installed SVG for a still-current revision.
  Measure(revision: Int)
}

/// Result of validating a raw parent payload.
pub type Input {
  /// A valid request with bounded source, revision and fixed theme.
  Accepted(request: Request)

  /// A valid revision whose source contains a forbidden directive.
  Forbidden(revision: Int)

  /// Malformed, unsupported, or oversized payloads do not advance state.
  Ignored
}

/// One element attribute passed to the SVG validator.
pub type Attribute {
  /// Attribute names and values are obtained from the parsed DOM, not markup
  /// substring matching.
  Attribute(name: String, value: String)
}

/// One node in a pre-parsed SVG element tree.
pub type Node {
  /// Element local name and all attributes relevant to navigation checks.
  Node(name: String, attributes: List(Attribute))
}

/// Initializes the controller with no accepted or displayed revision.
///
/// ## Examples
/// ```gleam
/// assert new().latest == 0
/// ```
pub fn new() -> Model {
  Model(latest: 0, phase: Idle, shown: None, width: 0.0)
}

/// Parses and validates a protocol JSON string without throwing.
///
/// ## Examples
/// ```gleam
/// assert input("null") == Ignored
/// ```
pub fn input(text: String) -> Input {
  json.parse(text, request_decoder())
  |> result.map(classify_request)
  |> result.unwrap(Ignored)
}

fn classify_request(request: Request) -> Input {
  case
    safe_revision(request.revision)
    && utf16_length(request.source) <= max_source
  {
    False -> Ignored
    True ->
      case forbidden_source(request.source) {
        True -> Forbidden(request.revision)
        False -> Accepted(request)
      }
  }
}

/// Applies one event and returns updated state with browser effects.
///
/// ## Examples
/// ```gleam
/// let #(model, _) = update(new(), Resized(100.0))
/// assert model.width == 100.0
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, List(Effect)) {
  case message {
    Requested(request) ->
      case request.revision > model.latest {
        True -> accept(model, request)
        False -> #(model, [])
      }
    Refused(revision) ->
      case revision > model.latest {
        False -> #(model, [])
        True -> {
          let phase = case model.phase {
            Idle -> Idle
            Busy(stage:, request:, ..) -> Busy(stage:, request:, queued: None)
          }
          #(Model(latest: revision, phase:, shown: None, width: model.width), [
            Clear,
            ReplyToParent(FailedReply(revision)),
          ])
        }
      }
    Rendered(revision, result) -> rendered(model, revision, result)
    Published(revision, result) -> published(model, revision, result)
    Resized(width) ->
      case width != model.width, model.shown {
        False, _ -> #(model, [])
        True, Some(revision) if revision == model.latest -> #(
          Model(..model, width:),
          [Measure(revision)],
        )
        True, Some(_) | True, None -> #(Model(..model, width:), [])
      }
    Measured(revision, height) ->
      case model.shown == Some(revision) && revision == model.latest {
        True -> #(model, [
          ReplyToParent(RenderedReply(
            revision,
            clamp_height(float.round(float.ceiling(height))),
          )),
        ])
        False -> #(model, [])
      }
  }
}

/// Produces the fixed renderer configuration; source cannot influence it.
///
/// The layout is pinned to dagre. Mermaid 12 otherwise lays flowcharts out
/// with ELK, whose browserified bundle calls a CommonJS `require` that the
/// frame's IIFE build does not define, so every flowchart failed to render.
/// Configuration and frontmatter directives are refused, so no source can
/// select ELK again.
///
/// ## Examples
/// ```gleam
/// assert string.contains(configuration(Light), "\"theme\":\"default\"")
/// ```
pub fn configuration(theme: Theme) -> String {
  let theme_name = case theme {
    Dark -> "dark"
    Light -> "default"
  }
  json.object([
    #("startOnLoad", json.bool(False)),
    #("securityLevel", json.string("strict")),
    #("suppressErrorRendering", json.bool(True)),
    #("maxTextSize", json.int(max_source)),
    #("maxEdges", json.int(max_edges)),
    #("htmlLabels", json.bool(False)),
    #("theme", json.string(theme_name)),
    #("layout", json.string("dagre")),
    #("flowchart", json.object([#("htmlLabels", json.bool(False))])),
  ])
  |> json.to_string
}

/// The CSS colour scheme matching a theme, so the frame's canvas agrees
/// with the parent page's and the browser paints no opaque backdrop.
///
/// ## Examples
/// ```gleam
/// assert color_scheme(Light) == "light"
/// ```
pub fn color_scheme(theme: Theme) -> String {
  case theme {
    Dark -> "dark"
    Light -> "light"
  }
}

/// Encodes only fixed parent protocol response fields.
///
/// ## Examples
/// ```gleam
/// assert reply_json(Ready) == "{\"kind\":\"ready\"}"
/// ```
pub fn reply_json(reply: Reply) -> String {
  case reply {
    Ready -> json.object([#("kind", json.string("ready"))])
    RenderedReply(revision, height) ->
      json.object([
        #("kind", json.string("rendered")),
        #("revision", json.int(revision)),
        #("height", json.int(height)),
      ])
    FailedReply(revision) ->
      json.object([
        #("kind", json.string("failed")),
        #("revision", json.int(revision)),
      ])
  }
  |> json.to_string
}

/// Checks the root-first SVG tree against embedded content and navigation.
///
/// ## Examples
/// ```gleam
/// assert safe_svg([Node("svg", [])])
/// ```
pub fn safe_svg(nodes: List(Node)) -> Bool {
  case nodes {
    [] -> False
    [Node(name, attributes), ..rest] ->
      name == "svg"
      && safe_node(Node(name, attributes))
      && list.all(rest, safe_node)
  }
}

/// Maximum UTF-16 source units accepted.
pub const max_source = 32_000

/// Maximum Mermaid graph edges.
pub const max_edges = 250

/// Minimum published frame height.
pub const min_height = 120

/// Maximum published frame height.
pub const max_height = 2000

fn safe_node(node: Node) -> Bool {
  let Node(name, attributes) = node
  let forbidden =
    list.contains(
      ["parsererror", "a", "foreignObject", "script", "image"],
      name,
    )
  case forbidden {
    True -> False
    False ->
      list.all(attributes, fn(attribute) {
        let Attribute(name, value) = attribute
        case name == "href" || string.ends_with(name, ":href") {
          True -> string.starts_with(value, "#")
          False -> True
        }
      })
  }
}

fn request_decoder() -> decode.Decoder(Request) {
  use source <- decode.field("source", decode.string)
  use theme <- decode.field("theme", decode.string)
  use revision <- decode.field("revision", decode.int)
  use theme <- decode.then(case theme {
    "dark" -> decode.success(Dark)
    "default" -> decode.success(Light)
    _ -> decode.failure(Light, expected: "theme")
  })
  decode.success(Request(source:, theme:, revision:))
}

fn safe_revision(revision: Int) -> Bool {
  revision > 0 && revision <= 9_007_199_254_740_991
}

fn utf16_length(source: String) -> Int {
  source
  |> string.to_utf_codepoints
  |> list.fold(0, fn(total, point) {
    case string.utf_codepoint_to_int(point) > 65_535 {
      True -> total + 2
      False -> total + 1
    }
  })
}

// Mermaid uses ECMAScript whitespace and line boundaries, which differ from
// Gleam's Unicode trim rules. Match its parser before accepting source.
fn forbidden_source(source: String) -> Bool {
  let lines =
    source
    |> string.replace("\r\n", "\n")
    |> string.replace("\r", "\n")
    |> string.replace("\u{2028}", "\n")
    |> string.replace("\u{2029}", "\n")
    |> string.split("\n")
  string.contains(source, "%%{") || forbidden_lines(lines)
}

fn forbidden_lines(lines: List(String)) -> Bool {
  case lines {
    [] -> False
    [line, ..rest] -> {
      let trimmed = ecma_trim(line)
      let forbidden =
        trimmed == "---"
        || click_directive(trimmed)
        || {
          trimmed == "click"
          && list.any(rest, fn(line) { ecma_trim(line) != "" })
        }

      // Keep the bounded source scan tail-recursive even for one line per byte.
      case forbidden {
        True -> True
        False -> forbidden_lines(rest)
      }
    }
  }
}

fn click_directive(line: String) -> Bool {
  case string.starts_with(line, "click") {
    False -> False
    True -> {
      let arguments = string.drop_start(line, 5)
      case string.to_utf_codepoints(arguments) {
        [] -> False
        [first, ..] -> ecma_space(first) && ecma_trim(arguments) != ""
      }
    }
  }
}

fn ecma_trim(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.drop_while(ecma_space)
  |> list.reverse
  |> list.drop_while(ecma_space)
  |> list.reverse
  |> string.from_utf_codepoints
}

fn ecma_space(point: UtfCodepoint) -> Bool {
  let code = string.utf_codepoint_to_int(point)
  { code >= 9 && code <= 13 }
  || { code >= 8192 && code <= 8202 }
  || list.contains(
    [32, 160, 5760, 8232, 8233, 8239, 8287, 12_288, 65_279],
    code,
  )
}

fn accept(model: Model, request: Request) -> #(Model, List(Effect)) {
  let base = Model(..model, latest: request.revision, shown: None)
  case model.phase {
    Idle -> #(Model(..base, phase: Busy(Drawing, request, None)), [
      Clear,
      Begin(request),
    ])
    Busy(stage, active, _) -> #(
      Model(..base, phase: Busy(stage, active, Some(request))),
      [Clear],
    )
  }
}

fn rendered(
  model: Model,
  revision: Int,
  result: Result(String, Nil),
) -> #(Model, List(Effect)) {
  case model.phase {
    Busy(Drawing, request, queued) ->
      case request.revision == revision, revision == model.latest, result {
        False, _, _ -> #(model, [])
        True, True, Ok(svg) -> #(
          Model(..model, phase: Busy(Checking, request, queued)),
          [Inspect(revision, svg)],
        )
        True, True, Error(_) ->
          retire(model, queued, [Clear, ReplyToParent(FailedReply(revision))])
        True, False, _ -> retire(model, queued, [])
      }
    _ -> #(model, [])
  }
}

fn published(
  model: Model,
  revision: Int,
  result: Result(Float, Nil),
) -> #(Model, List(Effect)) {
  case model.phase {
    Busy(Checking, request, queued) ->
      case request.revision == revision, revision == model.latest, result {
        False, _, _ -> #(model, [])
        True, True, Ok(height) ->
          retire(Model(..model, shown: Some(revision)), queued, [
            ReplyToParent(RenderedReply(
              revision,
              clamp_height(float.round(float.ceiling(height))),
            )),
          ])
        True, True, Error(_) ->
          retire(model, queued, [Clear, ReplyToParent(FailedReply(revision))])
        True, False, _ -> retire(model, queued, [])
      }
    _ -> #(model, [])
  }
}

fn retire(
  model: Model,
  queued: option.Option(Request),
  effects: List(Effect),
) -> #(Model, List(Effect)) {
  case queued {
    Some(request) ->
      case request.revision == model.latest {
        True -> #(
          Model(..model, phase: Busy(Drawing, request, None), shown: None),
          list.append(effects, [Begin(request)]),
        )
        False -> #(Model(..model, phase: Idle), effects)
      }
    None -> #(Model(..model, phase: Idle), effects)
  }
}

fn clamp_height(height: Int) -> Int {
  int.clamp(height, min_height, max_height)
}
