//// The language-server router: what an `lsp.*` frame becomes, which door
//// closure it reaches, and the exact msgpack shape the answer comes back
//// in.
////
//// These drive `lsp.routing` against a scripted door, because what is
//// worth proving here is carriage: the resolution, the sync and the
//// server are the door's, and are tested where the door is built.
////
//// The answer shapes are asserted as whole maps, key by key, rather than
//// round-tripped through `cap/lsp`: `codemode` deliberately does not
//// depend on `cap` (its CLAUDE.md says why), so each end pins its half.
//// `cap/test/cap/lsp_test.gleam` decodes the same literal maps these
//// assertions spell, so a key renamed on one side and not the other
//// fails one of the two suites.

import broker/budget
import broker/exec
import broker/framing.{type CapOutcome}
import broker/policy
import codemode/identity.{type PhaseIdentity}
import codemode/lsp
import codemode/satellite
import core/clock
import core/ids
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lsp/query
import tools/hashline
import tools/lsp as tools_lsp

const t = 1_700_000_000_000

// --- the scripted door ------------------------------------------------------------

// What the door was asked, in the terms the arm decoded. One variant per
// closure, so an arm wired to the wrong closure is a different variant
// in the recording rather than a coincidentally equal answer.
type Seen {
  DefinitionAsked(query: query.SymbolQuery)
  ReferencesAsked(query: query.SymbolQuery)
  HoverAsked(query: query.SymbolQuery)
  OutlineAsked(path: String)
  CallsAsked(query: query.SymbolQuery, direction: query.CallDirection)
  DiagnosticsAsked(path: option.Option(String))
  PrepareAsked(query: query.SymbolQuery, new_name: String)
  ApplyAsked(query: query.SymbolQuery, new_name: String)
}

fn recorder() -> Subject(Seen) {
  process.new_subject()
}

fn drain(seen: Subject(Seen)) -> List(Seen) {
  case process.receive(seen, within: 0) {
    Error(Nil) -> []
    Ok(one) -> [one, ..drain(seen)]
  }
}

fn site(line: Int) -> query.Site {
  query.Site(path: "src/app.gleam", line:, column: 8, text: "pub fn greet() {")
}

fn served(value: a) -> Result(query.Served(a), query.QueryError) {
  Ok(query.Served(value:, warmth: query.Warm))
}

// A door whose every closure succeeds with a fixed answer and records
// what it was asked.
fn answering(seen: Subject(Seen)) -> lsp.Seam {
  lsp.Seam(
    door: query.Door(
      definition: fn(asked) {
        process.send(seen, DefinitionAsked(asked))
        served([site(3)])
      },
      references: fn(asked) {
        process.send(seen, ReferencesAsked(asked))
        served([
          query.Reference(site: site(3), container: None),
          query.Reference(site: site(9), container: Some("Server.handle")),
        ])
      },
      hover: fn(asked) {
        process.send(seen, HoverAsked(asked))
        served(query.Hover(site: site(3), contents: "fn() -> String"))
      },
      outline: fn(path) {
        process.send(seen, OutlineAsked(path))
        served([
          query.SymbolEntry(
            name: "Server",
            kind: "type",
            detail: None,
            site: site(1),
            children: [
              query.SymbolEntry(
                name: "handle",
                kind: "function",
                detail: Some("fn(Msg) -> Nil"),
                site: site(2),
                children: [],
              ),
            ],
          ),
        ])
      },
      calls: fn(asked, direction) {
        process.send(seen, CallsAsked(asked, direction))
        served([query.Call(name: "main", site: site(20), at: [site(22)])])
      },
      diagnostics: fn(path) {
        process.send(seen, DiagnosticsAsked(path))
        served(
          query.Unsettled(seen: [
            query.Diagnostic(
              site: site(4),
              severity: query.SeverityWarning,
              message: "unused",
            ),
          ]),
        )
      },
      prepare_rename: fn(asked, new_name) {
        process.send(seen, PrepareAsked(asked, new_name))
        served([
          query.FileEdit(
            path: "src/app.gleam",
            base: "import x\npub fn greet() {\n  greet()\n}\n",
            edited: "import x\npub fn hello() {\n  hello()\n}\n",
            edits: 2,
          ),
        ])
      },
      after_write: fn(_path) { None },
    ),
    rename: fn(asked, new_name) {
      process.send(seen, ApplyAsked(asked, new_name))
      served(query.RenameReport(
        files: [
          query.Landed(path: "src/app.gleam", edits: 2),
          query.Rejected(path: "src/b.gleam", reason: "stale"),
          query.NotAttempted(path: "src/c.gleam"),
        ],
        diagnostics: query.Settled(diagnostics: []),
      ))
    },
  )
}

// A door whose every closure fails the same way.
fn refusing(error: query.QueryError) -> lsp.Seam {
  lsp.Seam(
    door: query.Door(
      definition: fn(_) { Error(error) },
      references: fn(_) { Error(error) },
      hover: fn(_) { Error(error) },
      outline: fn(_) { Error(error) },
      calls: fn(_, _) { Error(error) },
      diagnostics: fn(_) { Error(error) },
      prepare_rename: fn(_, _) { Error(error) },
      after_write: fn(_) { None },
    ),
    rename: fn(_, _) { Error(error) },
  )
}

// --- routing helpers ------------------------------------------------------------------

const passed_through = "reached_the_inner_router"

fn routed(seam: lsp.Seam) -> satellite.CapRouter {
  lsp.routing(seam, over: fn(request: satellite.CapRequest) {
    Error(satellite.CapDenial(code: passed_through, message: request.cap))
  })
}

fn serviced(seam: lsp.Seam, cap: String, args: MsgPackValue) -> CapOutcome {
  let assert Ok(satellite.ServedHere(serve:)) = routed(seam)(request(cap, args))
    as { "the lsp router must service " <> cap }
  serve()
}

fn refused(
  seam: lsp.Seam,
  cap: String,
  args: MsgPackValue,
) -> satellite.CapDenial {
  let assert Error(denial) = routed(seam)(request(cap, args))
    as { "the lsp router must refuse " <> cap }
  denial
}

fn request(cap: String, args: MsgPackValue) -> satellite.CapRequest {
  satellite.CapRequest(
    cap:,
    args:,
    identity: phase(),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    ordinal: 0,
  )
}

fn phase() -> PhaseIdentity {
  let generator = ids.generator(clock.fixed(at: t), seed: 29)
  let #(op, generator) = ids.mint_op(generator)
  let #(entry, _generator) = ids.mint_entry(generator)
  identity.run_phase(identity.for_execution(
    op_id: op,
    step_id: ids.entry_id_to_string(entry),
    budget: budget.Budget(max_outstanding: 8, deadline_ms: t + 60_000),
  ))
}

fn map(fields: List(#(String, MsgPackValue))) -> MsgPackValue {
  msgpack.MapValue(
    list.map(fields, fn(field) { #(msgpack.StringValue(field.0), field.1) }),
  )
}

fn text(value: String) -> MsgPackValue {
  msgpack.StringValue(value)
}

fn int(value: Int) -> MsgPackValue {
  msgpack.IntValue(value)
}

fn array(values: List(MsgPackValue)) -> MsgPackValue {
  msgpack.ArrayValue(values)
}

// The query keys `cap/lsp` always writes, for `greet` in one file.
fn query_fields() -> List(#(String, MsgPackValue)) {
  [
    #("symbol", text("util.greet")),
    #("path", text("src/app.gleam")),
    #("line", msgpack.NilValue),
  ]
}

fn asked() -> query.SymbolQuery {
  query.SymbolQuery(
    symbol: "util.greet",
    path: Some("src/app.gleam"),
    line: None,
  )
}

// Valid arguments for each serviced capability, so the walk over
// `serviced_caps` below can drive every name.
fn args_for(cap: String) -> MsgPackValue {
  case cap {
    "lsp.outline" -> map([#("path", text("src/app.gleam"))])
    "lsp.diagnostics" -> map([#("path", msgpack.NilValue)])
    "lsp.calls" -> map([#("direction", text("incoming")), ..query_fields()])
    "lsp.rename" ->
      map([
        #("new_name", text("hello")),
        #("mode", text("preview")),
        ..query_fields()
      ])
    _query_only -> map(query_fields())
  }
}

// The wire form of `site(line)`, spelled literally: the 1-based line as
// given, and the anchor `fs_read` would print for that text.
fn site_map(line: Int) -> MsgPackValue {
  map([
    #("path", text("src/app.gleam")),
    #("line", int(line)),
    #("column", int(8)),
    #("text", text("pub fn greet() {")),
    #("anchor", text(hashline.anchor("pub fn greet() {"))),
  ])
}

fn ok_value(outcome: CapOutcome) -> MsgPackValue {
  let assert framing.CapOk(value:) = outcome
    as "the call must have been answered"
  value
}

// --- every name is served, each by its own closure ---------------------------------------

pub fn every_serviced_cap_is_served_here_test() {
  assert list.length(lsp.serviced_caps) == 7
  list.each(lsp.serviced_caps, fn(cap) {
    let assert Ok(satellite.ServedHere(_)) =
      routed(answering(recorder()))(request(cap, args_for(cap)))
      as { cap <> " must be served here" }
    Nil
  })
}

pub fn each_cap_reaches_its_own_closure_test() {
  let seen = recorder()
  let seam = answering(seen)
  list.each(lsp.serviced_caps, fn(cap) {
    let _outcome = serviced(seam, cap, args_for(cap))
    Nil
  })
  assert drain(seen)
    == [
      DefinitionAsked(asked()),
      ReferencesAsked(asked()),
      HoverAsked(asked()),
      OutlineAsked("src/app.gleam"),
      CallsAsked(asked(), query.Incoming),
      DiagnosticsAsked(None),
      PrepareAsked(asked(), "hello"),
    ]
}

pub fn apply_reaches_the_composed_rename_and_never_prepare_test() {
  let seen = recorder()
  let args =
    map([
      #("new_name", text("hello")),
      #("mode", text("apply")),
      ..query_fields()
    ])
  let _outcome = serviced(answering(seen), "lsp.rename", args)
  assert drain(seen) == [ApplyAsked(asked(), "hello")]
}

pub fn a_non_lsp_cap_falls_through_test() {
  let assert Error(denial) =
    routed(answering(recorder()))(request("fs.read", map([])))
  assert denial == satellite.CapDenial(code: passed_through, message: "fs.read")
}

pub fn a_full_query_decodes_path_and_line_test() {
  let seen = recorder()
  let args =
    map([
      #("symbol", text("greet")),
      #("path", text("src/app.gleam")),
      #("line", int(12)),
    ])
  let _outcome = serviced(answering(seen), "lsp.definition", args)
  assert drain(seen)
    == [
      DefinitionAsked(query.SymbolQuery(
        symbol: "greet",
        path: Some("src/app.gleam"),
        line: Some(12),
      )),
    ]
}

// --- the answers, as whole maps -------------------------------------------------------

pub fn definition_answer_shape_test() {
  let value =
    ok_value(serviced(
      answering(recorder()),
      "lsp.definition",
      args_for("lsp.definition"),
    ))
  assert value == map([#("sites", array([site_map(3)])), #("total", int(1))])
}

pub fn references_answer_shape_test() {
  let value =
    ok_value(serviced(
      answering(recorder()),
      "lsp.references",
      args_for("lsp.references"),
    ))
  assert value
    == map([
      #(
        "references",
        array([
          map([#("site", site_map(3)), #("container", msgpack.NilValue)]),
          map([#("site", site_map(9)), #("container", text("Server.handle"))]),
        ]),
      ),
      #("total", int(2)),
    ])
}

pub fn hover_answer_shape_test() {
  let value =
    ok_value(serviced(answering(recorder()), "lsp.hover", args_for("lsp.hover")))
  assert value == map([#("contents", text("fn() -> String"))])
}

// A program may take more of a hover than the tool shows, but not an
// unbounded amount: the server decides how long it is.
pub fn hover_answer_is_clipped_at_its_bound_test() {
  let silent = refusing(query.Unavailable("unused"))
  let long = string.repeat("documentation line\n", 10_000)
  let seam =
    lsp.Seam(
      ..silent,
      door: query.Door(..silent.door, hover: fn(_) {
        served(query.Hover(site: site(3), contents: long))
      }),
    )
  let clipped = tools_lsp.clip(long, lsp.max_hover_bytes)
  assert ok_value(serviced(seam, "lsp.hover", args_for("lsp.hover")))
    == map([#("contents", text(clipped))])
  assert string.byte_size(clipped) < lsp.max_hover_bytes + 64
  assert string.ends_with(clipped, " more bytes cut]")
}

pub fn outline_answer_shape_test() {
  let value =
    ok_value(serviced(
      answering(recorder()),
      "lsp.outline",
      args_for("lsp.outline"),
    ))
  assert value
    == map([
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
    ])
}

pub fn calls_answer_shape_test() {
  let value =
    ok_value(serviced(answering(recorder()), "lsp.calls", args_for("lsp.calls")))
  assert value
    == map([
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
    ])
}

pub fn diagnostics_answer_shape_test() {
  let value =
    ok_value(serviced(
      answering(recorder()),
      "lsp.diagnostics",
      args_for("lsp.diagnostics"),
    ))
  assert value
    == map([
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
    ])
}

pub fn rename_preview_answer_shape_test() {
  let value =
    ok_value(serviced(
      answering(recorder()),
      "lsp.rename",
      args_for("lsp.rename"),
    ))
  assert value
    == map([
      #("mode", text("preview")),
      #(
        "files",
        array([
          map([
            #("path", text("src/app.gleam")),
            #("edits", int(2)),
            #(
              "changes",
              array([
                map([
                  #("line", int(2)),
                  #("before", text("pub fn greet() {")),
                  #("after", text("pub fn hello() {")),
                ]),
                map([
                  #("line", int(3)),
                  #("before", text("  greet()")),
                  #("after", text("  hello()")),
                ]),
              ]),
            ),
          ]),
        ]),
      ),
    ])
}

pub fn rename_apply_answer_shape_test() {
  let args =
    map([
      #("new_name", text("hello")),
      #("mode", text("apply")),
      ..query_fields()
    ])
  let value = ok_value(serviced(answering(recorder()), "lsp.rename", args))
  assert value
    == map([
      #("mode", text("apply")),
      #(
        "files",
        array([
          map([
            #("outcome", text("landed")),
            #("path", text("src/app.gleam")),
            #("edits", int(2)),
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
    ])
}

pub fn a_long_answer_is_capped_with_its_total_test() {
  let many =
    list.index_map(list.repeat(Nil, 250), fn(_nil, index) { site(index + 1) })
  let seam =
    lsp.Seam(
      ..answering(recorder()),
      door: query.Door(..answering(recorder()).door, definition: fn(_) {
        served(many)
      }),
    )
  let value =
    ok_value(serviced(seam, "lsp.definition", args_for("lsp.definition")))
  let assert msgpack.MapValue([
    #(_sites_key, msgpack.ArrayValue(sites)),
    #(_total_key, total),
  ]) = value
    as "a definition answer is sites then total"
  assert list.length(sites) == lsp.max_items
  assert total == int(250)
}

// --- the preview diff ----------------------------------------------------------------------

pub fn preview_trims_crlf_and_keeps_line_numbers_test() {
  let edit =
    query.FileEdit(
      path: "a.gleam",
      base: "a\r\ngreet\r\nb\r\n",
      edited: "a\r\nhello\r\nb\r\n",
      edits: 1,
    )
  assert lsp.preview([edit])
    == [
      lsp.PlannedFile(path: "a.gleam", edits: 1, changes: [
        lsp.LineChange(line: 2, before: "greet", after: "hello"),
      ]),
    ]
}

pub fn preview_shows_a_line_present_on_one_side_only_test() {
  let edit =
    query.FileEdit(path: "a.gleam", base: "x", edited: "x\ny", edits: 1)
  assert lsp.preview([edit])
    == [
      lsp.PlannedFile(path: "a.gleam", edits: 1, changes: [
        lsp.LineChange(line: 2, before: "", after: "y"),
      ]),
    ]
}

// A server that adds a line: the span between the common prefix and
// suffix is paired line by line, the extra line against an empty one and
// numbered as the edited file numbers it, exactly as `lsp_rename` shows it.
pub fn preview_pairs_a_span_that_grows_test() {
  let edit =
    query.FileEdit(
      path: "a.gleam",
      base: "a\nb\nc\n",
      edited: "a\nX\nY\nc\n",
      edits: 1,
    )
  assert lsp.preview([edit])
    == [
      lsp.PlannedFile(path: "a.gleam", edits: 1, changes: [
        lsp.LineChange(line: 2, before: "b", after: "X"),
        lsp.LineChange(line: 3, before: "", after: "Y"),
      ]),
    ]
}

// --- refusals, on both channels --------------------------------------------------------------

pub fn sentence_errors_are_refusals_with_their_codes_test() {
  let cases = [
    #(
      query.NoServer("no server owns x.txt"),
      "no_server",
      "no server owns x.txt",
    ),
    #(
      query.ServerRefused("would make it unexported"),
      "server_refused",
      "would make it unexported",
    ),
    #(query.Unavailable("deadline"), "server_unavailable", "deadline"),
  ]
  list.each(cases, fn(case_) {
    let #(error, code, message) = case_
    assert serviced(refusing(error), "lsp.hover", args_for("lsp.hover"))
      == framing.CapErr(code:, message:)
  })
}

pub fn not_found_is_an_unresolved_answer_test() {
  let outcome =
    serviced(
      refusing(query.NotFound(asked())),
      "lsp.references",
      args_for("lsp.references"),
    )
  assert ok_value(outcome)
    == map([#("unresolved", text("not_found")), #("symbol", text("util.greet"))])
}

pub fn ambiguous_carries_its_candidates_test() {
  let outcome =
    serviced(
      refusing(query.Ambiguous([site(3), site(7)])),
      "lsp.definition",
      args_for("lsp.definition"),
    )
  assert ok_value(outcome)
    == map([
      #("unresolved", text("ambiguous")),
      #("candidates", array([site_map(3), site_map(7)])),
    ])
}

pub fn unsupported_names_server_and_request_test() {
  let outcome =
    serviced(
      refusing(query.Unsupported(
        server: "gleam",
        request: "textDocument/prepareCallHierarchy",
      )),
      "lsp.calls",
      args_for("lsp.calls"),
    )
  assert ok_value(outcome)
    == map([
      #("unresolved", text("unsupported")),
      #("server", text("gleam")),
      #("request", text("textDocument/prepareCallHierarchy")),
    ])
}

// --- malformed arguments refuse in band, before the door is asked ----------------------------

pub fn malformed_arguments_refuse_in_band_test() {
  let cases = [
    #(
      "lsp.definition",
      map([#("path", msgpack.NilValue), #("line", msgpack.NilValue)]),
    ),
    #(
      "lsp.definition",
      map([
        #("symbol", int(3)),
        #("path", msgpack.NilValue),
        #("line", msgpack.NilValue),
      ]),
    ),
    #(
      "lsp.references",
      map([
        #("symbol", text("greet")),
        #("path", msgpack.NilValue),
        #("line", int(3)),
      ]),
    ),
    #(
      "lsp.hover",
      map([
        #("symbol", text("greet")),
        #("path", text("a.gleam")),
        #("line", int(0)),
      ]),
    ),
    #(
      "lsp.hover",
      map([
        #("symbol", text("greet")),
        #("path", int(1)),
        #("line", msgpack.NilValue),
      ]),
    ),
    #("lsp.calls", map([#("direction", text("sideways")), ..query_fields()])),
    #(
      "lsp.rename",
      map([#("new_name", text("x")), #("mode", text("maybe")), ..query_fields()]),
    ),
    #("lsp.rename", map([#("mode", text("apply")), ..query_fields()])),
    #("lsp.outline", map([#("path", msgpack.NilValue)])),
    #("lsp.diagnostics", map([])),
    #("lsp.definition", text("not a map")),
  ]
  let seen = recorder()
  list.each(cases, fn(case_) {
    let #(cap, args) = case_
    let denial = refused(answering(seen), cap, args)
    assert denial.code == "invalid_argument"
  })
  assert drain(seen) == []
}
