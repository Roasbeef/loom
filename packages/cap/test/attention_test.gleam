//// The attention facade marshals the tools' own arguments and returns the id
//// the host answers with.

import cap/attention
import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/report
import gleam/option.{None, Some}

pub fn an_ask_marshals_every_kind_as_the_tool_takes_it_test() {
  let questions = [
    attention.confirm("Retry?"),
    attention.choose("Which?", [
      attention.Alternative(
        label: "a",
        note: Some("Does a."),
        emphasis: attention.Recommended,
      ),
      attention.alternative("b"),
    ]),
    attention.choose_many(
      "Several?",
      [attention.alternative("x"), attention.alternative("y")],
      min: 0,
      max: 2,
    ),
    attention.checklist("Any?", [
      attention.alternative("p"),
      attention.alternative("q"),
    ]),
    attention.fill("Where?", attention.FilePath),
  ]
  dispatch.install(
    channel.Channel(call: fn(cap, args, _deadline) {
      assert cap == "attention.ask"
      assert wire.string_field(args, "to") == Ok("sub:main/a")
      assert wire.string_field(args, "why") == Ok("Because.")
      let assert Ok(held) = wire.field(args, "questions")
      assert held
        == report.list([
          report.object([
            #("prompt", report.string("Retry?")),
            #("kind", report.string("confirm")),
          ]),
          report.object([
            #("prompt", report.string("Which?")),
            #("kind", report.string("choice")),
            #(
              "options",
              report.list([
                report.object([
                  #("label", report.string("a")),
                  #("note", report.string("Does a.")),
                  #("recommended", report.bool(True)),
                ]),
                report.object([#("label", report.string("b"))]),
              ]),
            ),
          ]),
          report.object([
            #("prompt", report.string("Several?")),
            #("kind", report.string("multiple")),
            #(
              "options",
              report.list([
                report.object([#("label", report.string("x"))]),
                report.object([#("label", report.string("y"))]),
              ]),
            ),
            #("min", report.int(0)),
            #("max", report.int(2)),
          ]),
          report.object([
            #("prompt", report.string("Any?")),
            #("kind", report.string("checklist")),
            #(
              "options",
              report.list([
                report.object([#("label", report.string("p"))]),
                report.object([#("label", report.string("q"))]),
              ]),
            ),
          ]),
          report.object([
            #("prompt", report.string("Where?")),
            #("kind", report.string("fill")),
            #("format", report.string("path")),
          ]),
        ])
      Ok(report.object([#("id", report.string("ask-0123456789"))]))
    }),
  )
  assert attention.ask(questions, to: Some("sub:main/a"), why: Some("Because."))
    == Ok("ask-0123456789")
}

pub fn an_ask_leaves_out_what_it_was_not_given_test() {
  dispatch.install(
    channel.Channel(call: fn(_cap, args, _deadline) {
      assert wire.string_field(args, "to") != Ok("anything")
      assert wire.field(args, "to") != Ok(report.string(""))
      Ok(report.object([#("id", report.string("ask-0000000001"))]))
    }),
  )
  assert attention.ask([attention.confirm("Sure?")], to: None, why: None)
    == Ok("ask-0000000001")
}

pub fn a_notice_marshals_its_kind_path_and_line_test() {
  dispatch.install(
    channel.Channel(call: fn(cap, args, _deadline) {
      assert cap == "attention.notice"
      assert wire.string_field(args, "kind") == Ok("question")
      assert wire.string_field(args, "text") == Ok("Why is this slow?")
      assert wire.string_field(args, "path") == Ok("src/a.gleam")
      assert wire.int_field(args, "line") == Ok(7)
      Ok(report.object([#("id", report.string("find-0123456789"))]))
    }),
  )
  assert attention.notice(
      attention.Wondering,
      "Why is this slow?",
      path: Some("src/a.gleam"),
      line: Some(7),
    )
    == Ok("find-0123456789")
}

pub fn a_refusal_and_a_dead_channel_keep_their_words_test() {
  dispatch.install(
    channel.Channel(call: fn(_cap, _args, _deadline) {
      Error(channel.Denied("attention_full", "32 asks are already open"))
    }),
  )
  let assert Error(denied) =
    attention.ask([attention.confirm("x?")], to: None, why: None)
  assert denied
    == attention.AttentionDenied("attention_full", "32 asks are already open")
  assert attention.error_text(denied)
    == "attention_full: 32 asks are already open"

  dispatch.install(
    channel.Channel(call: fn(_cap, _args, _deadline) {
      Error(channel.Unreachable("no channel"))
    }),
  )
  assert attention.notice(attention.Idea, "x", path: None, line: None)
    == Error(attention.AttentionUnavailable("no channel"))
}

pub fn a_reply_without_an_id_is_unavailable_test() {
  dispatch.install(
    channel.Channel(call: fn(_cap, _args, _deadline) { Ok(report.object([])) }),
  )
  let assert Error(attention.AttentionUnavailable(_)) =
    attention.ask([attention.confirm("x?")], to: None, why: None)
}
