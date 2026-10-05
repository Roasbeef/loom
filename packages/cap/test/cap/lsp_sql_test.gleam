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
