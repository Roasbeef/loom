//// Round trips for `cap/lsp`: the exact arguments each stub puts on the
//// wire, the decoding of every answer shape, the `unresolved` answers,
//// and the refusal-code mapping.
////
//// The answer maps below are spelled exactly as
//// `codemode/test/codemode/lsp_test.gleam` asserts the router renders
//// them. `cap` and `codemode` share no dependency, so neither suite can
//// import the other's half; each pins the same literals, and a key renamed
//// on one side only fails one of the two.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/lsp
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}

// --- helpers ------------------------------------------------------------

fn map(entries: List(#(String, MsgPackValue))) -> MsgPackValue {
  wire.args(entries)
}

fn text(value: String) -> MsgPackValue {
  msgpack.StringValue(value)
}

fn number(value: Int) -> MsgPackValue {
  msgpack.IntValue(value)
}

fn array(values: List(MsgPackValue)) -> MsgPackValue {
  msgpack.ArrayValue(values)
}

// A fake channel answering every call with `reply`, handing back a reader
// for the capability name and arguments it was given.
fn answering(
  reply: MsgPackValue,
) -> fn() -> Result(#(String, MsgPackValue), Nil) {
  let sent = process.new_subject()
  dispatch.install(
    channel.Channel(call: fn(cap, args, _deadline) {
      process.send(sent, #(cap, args))
      Ok(reply)
    }),
  )
  fn() { process.receive(sent, 100) }
}

fn refusing(error: channel.CallError) -> Nil {
  dispatch.install(
    channel.Channel(call: fn(_cap, _args, _deadline) { Error(error) }),
  )
}

const anchor = "0badc0de"

fn site_map(line: Int) -> MsgPackValue {
  map([
    #("path", text("src/app.gleam")),
    #("line", number(line)),
    #("column", number(8)),
    #("text", text("pub fn greet() {")),
    #("anchor", text(anchor)),
  ])
}

fn site(line: Int) -> lsp.Site {
  lsp.Site(
    path: "src/app.gleam",
    line:,
    column: 8,
    text: "pub fn greet() {",
    anchor:,
  )
}

fn query_fields() -> List(#(String, MsgPackValue)) {
  [
    #("symbol", text("util.greet")),
    #("path", text("src/app.gleam")),
    #("line", msgpack.NilValue),
  ]
}

fn query() -> lsp.Query {
  lsp.symbol("util.greet") |> lsp.in("src/app.gleam")
}

// --- the query on the wire ------------------------------------------------------

pub fn a_bare_symbol_sends_nil_narrowing_test() {
  let take = answering(map([#("sites", array([])), #("total", number(0))]))
  let _answer = lsp.definition(lsp.symbol("greet"))
  assert take()
    == Ok(#(
      "lsp.definition",
      map([
        #("symbol", text("greet")),
        #("path", msgpack.NilValue),
        #("line", msgpack.NilValue),
      ]),
    ))
}

pub fn a_narrowed_symbol_sends_path_and_line_test() {
  let take = answering(map([#("references", array([])), #("total", number(0))]))
  let _answer =
    lsp.references(
      lsp.symbol("greet") |> lsp.in("src/app.gleam") |> lsp.at_line(12),
    )
  assert take()
    == Ok(#(
      "lsp.references",
      map([
        #("symbol", text("greet")),
        #("path", text("src/app.gleam")),
        #("line", number(12)),
      ]),
    ))
}

// --- every answer shape decodes ----------------------------------------------------

pub fn definition_decodes_found_sites_test() {
  let _take =
    answering(map([#("sites", array([site_map(3)])), #("total", number(1))]))
  assert lsp.definition(query()) == Ok(lsp.Found(items: [site(3)], total: 1))
}

pub fn references_decode_with_containers_test() {
  let _take =
    answering(
      map([
        #(
          "references",
          array([
            map([#("site", site_map(3)), #("container", msgpack.NilValue)]),
            map([#("site", site_map(9)), #("container", text("Server.handle"))]),
          ]),
        ),
        #("total", number(2)),
      ]),
    )
  assert lsp.references(query())
    == Ok(lsp.Found(
      items: [
        lsp.Reference(site: site(3), container: None),
        lsp.Reference(site: site(9), container: Some("Server.handle")),
      ],
      total: 2,
    ))
}

pub fn a_capped_answer_keeps_its_total_test() {
  let _take =
    answering(map([#("sites", array([site_map(1)])), #("total", number(250))]))
  let assert Ok(found) = lsp.definition(query())
  assert found.total == 250
}

pub fn hover_decodes_contents_test() {
  let _take = answering(map([#("contents", text("fn() -> String"))]))
  assert lsp.hover(query()) == Ok("fn() -> String")
}

pub fn outline_decodes_nested_symbols_test() {
  let take =
    answering(
      map([
        #(
          "symbols",
          array([
            map([
              #("name", text("Server")),
              #("kind", text("type")),
              #("detail", msgpack.NilValue),
              #("site", site_map(1)),
              #(
                "children",
                array([
                  map([
                    #("name", text("handle")),
                    #("kind", text("function")),
                    #("detail", text("fn(Msg) -> Nil")),
                    #("site", site_map(2)),
                    #("children", array([])),
                  ]),
                ]),
              ),
            ]),
          ]),
        ),
      ]),
    )
  assert lsp.outline("src/app.gleam")
    == Ok([
      lsp.Symbol(
        name: "Server",
        kind: "type",
        detail: None,
        site: site(1),
        children: [
          lsp.Symbol(
            name: "handle",
            kind: "function",
            detail: Some("fn(Msg) -> Nil"),
            site: site(2),
            children: [],
          ),
        ],
      ),
    ])
  assert take() == Ok(#("lsp.outline", map([#("path", text("src/app.gleam"))])))
}

pub fn calls_send_direction_and_decode_edges_test() {
  let take =
    answering(
      map([
        #(
          "calls",
          array([
            map([
              #("name", text("main")),
              #("site", site_map(20)),
              #("at", array([site_map(22)])),
            ]),
          ]),
        ),
      ]),
    )
  assert lsp.calls(query(), lsp.Outgoing)
    == Ok([lsp.Call(name: "main", site: site(20), at: [site(22)])])
  assert take()
    == Ok(#(
      "lsp.calls",
      map(list.append(query_fields(), [#("direction", text("outgoing"))])),
    ))
}

pub fn diagnostics_decode_unsettled_with_severity_test() {
  let take =
    answering(
      map([
        #("state", text("unsettled")),
        #(
          "diagnostics",
          array([
            map([
              #("site", site_map(4)),
              #("severity", text("warning")),
              #("message", text("unused")),
            ]),
          ]),
        ),
      ]),
    )
  assert lsp.diagnostics(None)
    == Ok(
      lsp.Unsettled(seen: [
        lsp.Diagnostic(
          site: site(4),
          severity: lsp.SeverityWarning,
          message: "unused",
        ),
      ]),
    )
  assert take() == Ok(#("lsp.diagnostics", map([#("path", msgpack.NilValue)])))
}

pub fn clean_settled_diagnostics_decode_test() {
  let _take =
    answering(map([#("state", text("settled")), #("diagnostics", array([]))]))
  assert lsp.diagnostics(Some("src/app.gleam")) == Ok(lsp.Settled([]))
}

pub fn rename_preview_sends_mode_and_decodes_changes_test() {
  let take =
    answering(
      map([
        #("mode", text("preview")),
        #(
          "files",
          array([
            map([
              #("path", text("src/app.gleam")),
              #("edits", number(2)),
              #(
                "changes",
                array([
                  map([
                    #("line", number(2)),
                    #("before", text("pub fn greet() {")),
                    #("after", text("pub fn hello() {")),
                  ]),
                ]),
              ),
            ]),
          ]),
        ),
      ]),
    )
  assert lsp.rename(query(), "hello", lsp.Preview)
    == Ok(
      lsp.Previewed(files: [
        lsp.PlannedFile(path: "src/app.gleam", edits: 2, changes: [
          lsp.LineChange(
            line: 2,
            before: "pub fn greet() {",
            after: "pub fn hello() {",
          ),
        ]),
      ]),
    )
  assert take()
    == Ok(#(
      "lsp.rename",
      map(
        list.append(query_fields(), [
          #("new_name", text("hello")),
          #("mode", text("preview")),
        ]),
      ),
    ))
}

pub fn rename_apply_decodes_every_landing_test() {
  let take =
    answering(
      map([
        #("mode", text("apply")),
        #(
          "files",
          array([
            map([
              #("outcome", text("landed")),
              #("path", text("src/app.gleam")),
              #("edits", number(2)),
            ]),
            map([
              #("outcome", text("rejected")),
              #("path", text("src/b.gleam")),
              #("reason", text("stale")),
            ]),
            map([
              #("outcome", text("not_attempted")),
              #("path", text("src/c.gleam")),
            ]),
          ]),
        ),
        #(
          "diagnostics",
          map([#("state", text("settled")), #("diagnostics", array([]))]),
        ),
      ]),
    )
  assert lsp.rename(query(), "hello", lsp.Apply)
    == Ok(lsp.Applied(
      files: [
        lsp.Landed(path: "src/app.gleam", edits: 2),
        lsp.Rejected(path: "src/b.gleam", reason: "stale"),
        lsp.NotAttempted(path: "src/c.gleam"),
      ],
      diagnostics: lsp.Settled([]),
    ))
  let assert Ok(#(_cap, args)) = take()
  assert wire.string_field(args, "mode") == Ok("apply")
}

// --- unresolved answers ------------------------------------------------------------------

pub fn not_found_decodes_test() {
  let _take =
    answering(
      map([#("unresolved", text("not_found")), #("symbol", text("util.greet"))]),
    )
  assert lsp.references(query()) == Error(lsp.NotFound(symbol: "util.greet"))
}

pub fn ambiguous_decodes_candidates_test() {
  let _take =
    answering(
      map([
        #("unresolved", text("ambiguous")),
        #("candidates", array([site_map(3), site_map(7)])),
      ]),
    )
  assert lsp.definition(query())
    == Error(lsp.Ambiguous(candidates: [site(3), site(7)]))
}

pub fn unsupported_decodes_server_and_request_test() {
  let _take =
    answering(
      map([
        #("unresolved", text("unsupported")),
        #("server", text("gleam")),
        #("request", text("textDocument/prepareCallHierarchy")),
      ]),
    )
  assert lsp.calls(query(), lsp.Incoming)
    == Error(lsp.Unsupported(
      server: "gleam",
      request: "textDocument/prepareCallHierarchy",
    ))
}

// --- refusals and bad shapes ----------------------------------------------------------------

pub fn refusal_codes_map_to_variants_test() {
  refusing(channel.Denied(code: "no_server", message: "no server owns x"))
  assert lsp.hover(query()) == Error(lsp.NoServer(reason: "no server owns x"))

  refusing(channel.Denied(code: "server_refused", message: "unexported"))
  assert lsp.hover(query()) == Error(lsp.Refused(message: "unexported"))

  refusing(channel.Denied(code: "server_unavailable", message: "deadline"))
  assert lsp.hover(query()) == Error(lsp.LspUnavailable(reason: "deadline"))

  refusing(channel.Denied(code: "invalid_argument", message: "line"))
  assert lsp.hover(query())
    == Error(lsp.LspDenied(code: "invalid_argument", message: "line"))

  refusing(channel.Unreachable("closed"))
  assert lsp.hover(query()) == Error(lsp.LspUnavailable(reason: "closed"))
}

pub fn the_bound_is_the_router_bound_test() {
  assert lsp.max_items == 200
}

pub fn an_unknown_severity_is_unavailable_test() {
  let _take =
    answering(
      map([
        #("state", text("settled")),
        #(
          "diagnostics",
          array([
            map([
              #("site", site_map(1)),
              #("severity", text("fatal")),
              #("message", text("x")),
            ]),
          ]),
        ),
      ]),
    )
  assert lsp.diagnostics(None)
    == Error(lsp.LspUnavailable(
      "bad lsp.diagnostics result: unknown severity fatal",
    ))
}

pub fn an_unknown_unresolved_tag_is_unavailable_test() {
  let _take = answering(map([#("unresolved", text("vanished"))]))
  assert lsp.hover(query())
    == Error(lsp.LspUnavailable(
      "bad lsp.hover result: unknown unresolved tag vanished",
    ))
}

pub fn a_site_without_its_anchor_is_unavailable_test() {
  let _take =
    answering(
      map([
        #(
          "sites",
          array([
            map([
              #("path", text("a")),
              #("line", number(1)),
              #("column", number(1)),
              #("text", text("x")),
            ]),
          ]),
        ),
        #("total", number(1)),
      ]),
    )
  assert lsp.definition(query())
    == Error(lsp.LspUnavailable(
      "bad lsp.definition result: missing field anchor",
    ))
}
