//// The capability wire carries an explicit capture scope and immutable facts.
//// These tests pin the metadata outside the SQLite projection; native query
//// enforcement is tested with the shipped SQLite extension and jailed programs.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/lsp_sql
import core/msgpack as m
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn batch() -> m.MsgPackValue {
  wire.args([
    #("server", m.StringValue("gleam")),
    #("root", m.StringValue("/work")),
    #("generation", m.StringValue("sha256:generation")),
    #("started_ms", m.IntValue(10)),
    #("finished_ms", m.IntValue(20)),
    #("outlined", m.ArrayValue([m.StringValue("/work/src/app.gleam")])),
    #(
      "asked_targets",
      m.ArrayValue([
        wire.args([
          #("symbol", m.StringValue("main")),
          #("path", m.StringValue("/work/src/app.gleam")),
          #("line", m.NilValue),
        ]),
      ]),
    ),
    #("requests", m.IntValue(2)),
    #("withheld", m.IntValue(3)),
    #("facts", m.IntValue(1)),
    #("fact_bytes", m.IntValue(100)),
    #(
      "documents",
      m.ArrayValue([
        m.ArrayValue([
          m.StringValue("/work/src/app.gleam"),
          m.StringValue("sha256:file"),
          m.NilValue,
        ]),
      ]),
    ),
    #("symbols", m.ArrayValue([])),
    #("targets", m.ArrayValue([])),
    #("references", m.ArrayValue([])),
  ])
}

pub fn capture_scope_and_provenance_survive_wire_test() {
  let seen = process.new_subject()
  dispatch.install(
    channel.Channel(call: fn(cap, args, deadline) {
      process.send(seen, #(cap, args, deadline))
      Ok(batch())
    }),
  )
  let plan =
    lsp_sql.Plan("gleam", "/work", ["src/app.gleam"], [
      lsp_sql.Target("main", "src/app.gleam", Some(7)),
    ])
  let assert Ok(observation) = lsp_sql.collect(plan)
    as "a complete capture is decoded"
  let assert Ok(#(cap, args, deadline)) = process.receive(seen, 100)
    as "collection emits exactly one capability call"
  assert cap == "lsp.snapshot"
  assert deadline == 75_000
  assert args
    == wire.args([
      #("server", m.StringValue("gleam")),
      #("root", m.StringValue("/work")),
      #("outlines", m.ArrayValue([m.StringValue("src/app.gleam")])),
      #(
        "targets",
        m.ArrayValue([
          wire.args([
            #("symbol", m.StringValue("main")),
            #("path", m.StringValue("src/app.gleam")),
            #("line", m.IntValue(7)),
          ]),
        ]),
      ),
    ])
  let provenance = lsp_sql.metadata(observation)
  assert provenance.withheld == 3
  assert provenance.generation == "sha256:generation"
  assert provenance.started_ms == 10
  assert provenance.finished_ms == 20
  assert provenance.targets
    == [lsp_sql.Target("main", "/work/src/app.gleam", None)]
  dispatch.reset()
}

pub fn malformed_capture_never_becomes_an_empty_observation_test() {
  dispatch.install(channel.Channel(call: fn(_, _, _) { Ok(m.ArrayValue([])) }))
  let answer = lsp_sql.collect(lsp_sql.Plan("gleam", "/work", [], []))
  let assert Error(lsp_sql.Unavailable(_)) = answer
    as "malformed facts are a wire disagreement"
  dispatch.reset()
}

pub fn host_refusal_retains_its_actionable_code_test() {
  dispatch.install(
    channel.Channel(call: fn(_, _, _) {
      Error(channel.Denied("observation_changed", "document changed"))
    }),
  )
  assert lsp_sql.collect(lsp_sql.Plan("gleam", "/work", [], []))
    == Error(lsp_sql.Changed("document changed"))
  dispatch.reset()
}

pub fn capture_errors_are_typed_and_unknown_policy_is_preserved_test() {
  let cases = [
    #("invalid_scope", lsp_sql.InvalidScope("reason")),
    #("observation_changed", lsp_sql.Changed("reason")),
    #("observation_limit", lsp_sql.LimitExceeded("reason")),
    #("observation_deadline", lsp_sql.DeadlineExceeded),
    #("snapshot_ceiling", lsp_sql.CaptureCeilingReached),
    #("observation_query", lsp_sql.QueryFailed("reason")),
    #("future_policy", lsp_sql.Denied("future_policy", "reason")),
  ]
  list.each(cases, fn(pair) {
    dispatch.install(
      channel.Channel(call: fn(_, _, _) {
        Error(channel.Denied(pair.0, "reason"))
      }),
    )
    assert lsp_sql.collect(lsp_sql.Plan("gleam", "/work", [], []))
      == Error(pair.1)
  })
  dispatch.reset()
}

// The schema text is what a program prints instead of probing sqlite_master,
// so every table and column it lists is run through the native boundary. A
// column the bridge does not create makes the query fail here.
pub fn schema_lists_exactly_the_tables_the_native_boundary_creates_test() {
  dispatch.install(channel.Channel(call: fn(_, _, _) { Ok(batch()) }))
  let assert Ok(observation) =
    lsp_sql.collect(lsp_sql.Plan("gleam", "/work", [], []))
  list.each(string.split(lsp_sql.schema(), "\n"), fn(line) {
    let assert [table, rest] = string.split(line, "(")
    let columns = string.drop_end(rest, 1)
    let assert Ok(answer) =
      lsp_sql.query(
        observation,
        "SELECT " <> columns <> " FROM " <> table,
        [],
        fn(_row) { Ok(Nil) },
      )
    assert list.length(answer.columns)
      == list.length(string.split(columns, ","))
  })
  dispatch.reset()
}

pub fn unknown_tables_are_refused_with_the_table_list_test() {
  dispatch.install(channel.Channel(call: fn(_, _, _) { Ok(batch()) }))
  let assert Ok(observation) =
    lsp_sql.collect(lsp_sql.Plan("gleam", "/work", [], []))
  let ask = fn(sql) {
    lsp_sql.query(observation, sql, [], fn(_row) { Ok(Nil) })
  }
  let assert Error(lsp_sql.InvalidQuery(unknown)) = ask("SELECT * FROM facts")
  assert string.contains(unknown, "no such table: facts")
  assert string.contains(unknown, "documents, symbols, targets, \"references\"")
  let assert Error(lsp_sql.ReadOnlyDenied(denied)) =
    ask("SELECT name FROM sqlite_master")
  assert string.contains(denied, "documents, symbols, targets, \"references\"")
  dispatch.reset()
}

// --- the question-shaped helpers ------------------------------------------
//
// These pin what the wrappers *take off* a caller, not only what they return:
// the wire comparisons prove `collect_seeds` and `collect_files` send exactly
// the request a hand-built `Plan` sent, so convenience cannot change the
// capture behind the caller's back. `query_text`, `query_one` and
// `references` are driven against the shipped SQLite extension, because
// rendering a cell and joining the reference table are the two things that
// cannot be faked without restating the code these helpers exist to remove.

// One target and three references to it, so the join has rows to order. The
// shapes are the bridge's own column lists, which `schema()`
// (`schema_lists_exactly_the_tables_the_native_boundary_creates_test`) holds
// against the native boundary.
fn referenced() -> m.MsgPackValue {
  wire.args([
    #("server", m.StringValue("gleam")),
    #("root", m.StringValue("/work")),
    #("generation", m.StringValue("sha256:generation")),
    #("started_ms", m.IntValue(10)),
    #("finished_ms", m.IntValue(20)),
    #("outlined", m.ArrayValue([m.StringValue("/work/src/app.gleam")])),
    #(
      "asked_targets",
      m.ArrayValue([
        wire.args([
          #("symbol", m.StringValue("main")),
          #("path", m.StringValue("/work/src/app.gleam")),
          #("line", m.NilValue),
        ]),
      ]),
    ),
    #("requests", m.IntValue(4)),
    #("withheld", m.IntValue(0)),
    #("facts", m.IntValue(4)),
    #("fact_bytes", m.IntValue(400)),
    #("documents", m.ArrayValue([])),
    #("symbols", m.ArrayValue([])),
    #(
      "targets",
      m.ArrayValue([
        m.ArrayValue([
          m.IntValue(1),
          m.StringValue("main"),
          m.StringValue("/work/src/app.gleam"),
          m.NilValue,
          m.StringValue("/work/src/app.gleam"),
          m.IntValue(1),
          m.IntValue(4),
          m.StringValue("fn main() {"),
          m.StringValue("a1"),
        ]),
      ]),
    ),
    #(
      "references",
      m.ArrayValue([
        m.ArrayValue([
          m.IntValue(1),
          m.StringValue("/work/src/util.gleam"),
          m.IntValue(12),
          m.IntValue(3),
          m.StringValue("  main()"),
          m.StringValue("c3"),
        ]),
        m.ArrayValue([
          m.IntValue(1),
          m.StringValue("/work/src/app.gleam"),
          m.IntValue(4),
          m.IntValue(7),
          m.StringValue("  main()"),
          m.StringValue("b4"),
        ]),
        m.ArrayValue([
          m.IntValue(1),
          m.StringValue("/work/src/util.gleam"),
          m.IntValue(9),
          m.IntValue(1),
          m.StringValue("fn main() {"),
          m.StringValue("d9"),
        ]),
      ]),
    ),
  ])
}

// Collect `referenced()` through whichever wrapper runs, so a test asserts the
// question and not the capture.
fn referenced_observation(
  ask: fn() -> Result(lsp_sql.Observation, lsp_sql.Error),
) {
  dispatch.install(channel.Channel(call: fn(_, _, _) { Ok(referenced()) }))
  let answer = ask()
  dispatch.reset()
  answer
}

/// A seed built by `target` reaches the wire with its line nil, exactly as a
/// hand-written `Target(.., line: None)` does. This is what lets a caller drop
/// the `option` import the hand-built form needs.
pub fn target_helpers_put_the_same_scope_on_the_wire_test() {
  let seen = process.new_subject()
  dispatch.install(
    channel.Channel(call: fn(cap, args, deadline) {
      process.send(seen, #(cap, args, deadline))
      Ok(batch())
    }),
  )

  // No explicit server or root: both are inferred, so the request carries the
  // empty strings `plan` documents.
  let assert Ok(_) =
    lsp_sql.collect_seeds([], [lsp_sql.target("main", "src/app.gleam")])
  let assert Ok(#(cap, args, deadline)) = process.receive(seen, 100)
  assert cap == "lsp.snapshot"
  assert deadline == 75_000
  assert args
    == wire.args([
      #("server", m.StringValue("")),
      #("root", m.StringValue("")),
      #("outlines", m.ArrayValue([])),
      #(
        "targets",
        m.ArrayValue([
          wire.args([
            #("symbol", m.StringValue("main")),
            #("path", m.StringValue("src/app.gleam")),
            #("line", m.NilValue),
          ]),
        ]),
      ),
    ])
  dispatch.reset()
}

/// `collect_files` is a capture with no reference seeds, so the request it
/// sends carries the outlines and an empty target list.
pub fn collect_files_sends_outlines_and_no_seeds_test() {
  let seen = process.new_subject()
  dispatch.install(
    channel.Channel(call: fn(_cap, args, _deadline) {
      process.send(seen, args)
      Ok(batch())
    }),
  )

  let assert Ok(_) = lsp_sql.collect_files(["src/app.gleam"])
  let assert Ok(args) = process.receive(seen, 100)
  assert args
    == wire.args([
      #("server", m.StringValue("")),
      #("root", m.StringValue("")),
      #("outlines", m.ArrayValue([m.StringValue("src/app.gleam")])),
      #("targets", m.ArrayValue([])),
    ])
  dispatch.reset()
}

/// `target_at` carries the line it was given, which is the whole difference
/// between it and `target`.
pub fn target_at_carries_its_line_test() {
  assert lsp_sql.target_at("Greet", "src/util.gleam", 12)
    == lsp_sql.Target("Greet", "src/util.gleam", Some(12))
  assert lsp_sql.target("Greet", "src/util.gleam")
    == lsp_sql.Target("Greet", "src/util.gleam", None)
}

/// `references` runs the documented join and returns typed rows ordered by
/// seed and then by position: path first, then line within it.
pub fn references_reads_the_documented_join_test() {
  let assert Ok(observation) =
    referenced_observation(fn() {
      lsp_sql.collect_seeds([], [lsp_sql.target("main", "src/app.gleam")])
    })
  let assert Ok(references) = lsp_sql.references(observation)
  assert references
    == [
      lsp_sql.Reference("main", "/work/src/app.gleam", 4, 7, "  main()"),
      lsp_sql.Reference("main", "/work/src/util.gleam", 9, 1, "fn main() {"),
      lsp_sql.Reference("main", "/work/src/util.gleam", 12, 3, "  main()"),
    ]
}

/// A capture whose `"references"` table is empty answers `[]`, not an error,
/// while the seed it was asked about stays recorded. The request and the
/// answer are separable on purpose: `metadata(...).targets` says what was
/// asked, and `metadata(...).withheld` says whether a location the server did
/// know was withheld — which is why an empty answer needs both read before it
/// means "nothing references this".
pub fn references_answers_empty_when_the_join_finds_nothing_test() {
  dispatch.install(channel.Channel(call: fn(_, _, _) { Ok(batch()) }))
  let assert Ok(observation) =
    lsp_sql.collect_seeds([], [
      lsp_sql.target("main", "src/app.gleam"),
    ])
  let assert Ok(references) = lsp_sql.references(observation)
  assert references == []

  // The seed is still recorded as requested, which is what distinguishes
  // "asked and found nothing" from "never asked".
  assert lsp_sql.metadata(observation).targets
    == [lsp_sql.Target("main", "/work/src/app.gleam", None)]
  assert lsp_sql.metadata(observation).withheld == 3
  dispatch.reset()
}

/// `query_text` renders every storage class: NULL as the text `NULL`, an
/// integer as its printed value, a real as its printed value, and text as
/// itself. A row's width is therefore always the statement's projected width,
/// which is what makes `string.join` over a row safe.
pub fn query_text_renders_every_storage_class_test() {
  let assert Ok(observation) =
    referenced_observation(fn() { lsp_sql.collect_files(["src/app.gleam"]) })
  let assert Ok(rows) =
    lsp_sql.query_text(
      observation,
      "SELECT asked_line, line, ?, symbol, path FROM targets",
      [lsp_sql.Real(1.5)],
    )
  assert rows == [["NULL", "1", "1.5", "main", "/work/src/app.gleam"]]
}

/// `query_one` answers `Some` for a one-column row and `None` for no row, so a
/// caller reads an aggregate without unpacking a table.
pub fn query_one_answers_one_value_or_none_test() {
  let assert Ok(observation) =
    referenced_observation(fn() { lsp_sql.collect_files(["src/app.gleam"]) })
  assert lsp_sql.query_one(
      observation,
      "SELECT count(*) FROM \"references\"",
      [],
    )
    == Ok(Some("3"))
  assert lsp_sql.query_one(
      observation,
      "SELECT name FROM symbols WHERE name = 'absent'",
      [],
    )
    == Ok(None)
}

/// A statement whose row is not one column is a `DecodeFailed` rather than a
/// silent pick of the first cell: the statement and the caller would otherwise
/// disagree about the question with nothing saying so.
pub fn query_one_refuses_a_wider_row_test() {
  let assert Ok(observation) =
    referenced_observation(fn() { lsp_sql.collect_files(["src/app.gleam"]) })
  let assert Error(lsp_sql.DecodeFailed(row, reason)) =
    lsp_sql.query_one(observation, "SELECT symbol, path FROM targets", [])
  assert row == 0
  assert reason == "expected exactly one column"
}

/// The budget is `query`'s and is passed through unchanged: a statement that
/// asks for more than thirty-two columns is refused, not quietly shortened, so
/// a wrapper never turns a refusal into a shorter answer.
pub fn query_text_keeps_the_column_budget_test() {
  let assert Ok(observation) =
    referenced_observation(fn() { lsp_sql.collect_files(["src/app.gleam"]) })
  let wide =
    "SELECT " <> string.join(list.repeat("1", 33), ", ") <> " FROM targets"
  // The bridge reports an over-wide projection as SQLite's own "too many
  // columns in result set" rather than as the `column_limit` code, so this
  // pins the refusal a caller actually gets. What matters here is that the
  // wrapper passes a refusal through and never shortens the answer.
  let assert Error(lsp_sql.InvalidQuery(_)) =
    lsp_sql.query_text(observation, wide, [])
}
