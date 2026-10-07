//// Exact consent is the only transition that reaches the configuration writer.

import core/json
import gleam/erlang/process
import gleam/list
import gleam/string
import support/fake_broker
import support/memory_fs
import tools/configuration
import tools/tool

fn args() {
  json.Object([
    #("action", json.String("edit")),
    #("path", json.String("/home/loom.toml")),
    #("digest", json.String("base")),
    #("old", json.String("old")),
    #("new", json.String("new")),
  ])
}

fn exercise(decision: tool.Escalated) {
  let events = process.new_subject()
  let base =
    fake_broker.ctx(
      workspace: "/w",
      filesystem: memory_fs.filesystem(memory_fs.start()),
      now: 0,
      script: [],
      recorded: process.new_subject(),
    )
  let ctx =
    tool.Ctx(..base, raise_refusal: fn(refusal: tool.RaisedRefusal) {
      assert refusal.denial.wanted == []
        as "configuration asks for no sandbox authority"
      process.send(events, "asked")
      decision
    })
  let door =
    configuration.Door(
      read: fn() { Error("unused") },
      validate: fn(_) { Ok(Nil) },
      apply: fn(_) {
        process.send(events, "saved")
        Ok("reloaded")
      },
    )
  #(configuration.tool(door).run(ctx, args()), events)
}

pub fn denied_proposal_never_reaches_writer_test() {
  let #(outcome, events) = exercise(tool.Settle)
  assert outcome.is_error as "a refusal settles with an error"
  assert process.receive(events, 0) == Ok("asked") as "consent was requested"
  assert process.receive(events, 0) == Error(Nil) as "the writer did not run"
}

pub fn exact_empty_grant_consent_reaches_writer_once_test() {
  let #(outcome, events) = exercise(tool.Resume([]))
  assert !outcome.is_error as "the approved edit succeeds"
  assert process.receive(events, 0) == Ok("asked")
    as "the request precedes writing"
  assert process.receive(events, 0) == Ok("saved")
    as "the exact approved edit is saved"
  assert process.receive(events, 0) == Error(Nil) as "no second save occurs"
}

pub fn oversized_proposal_never_asks_or_writes_test() {
  let events = process.new_subject()
  let base =
    fake_broker.ctx(
      workspace: "/w",
      filesystem: memory_fs.filesystem(memory_fs.start()),
      now: 0,
      script: [],
      recorded: process.new_subject(),
    )
  let ctx =
    tool.Ctx(..base, raise_refusal: fn(_) {
      process.send(events, "asked")
      tool.Resume([])
    })
  let door =
    configuration.Door(
      read: fn() { Error("unused") },
      validate: fn(_) {
        process.send(events, "validated")
        Ok(Nil)
      },
      apply: fn(_) {
        process.send(events, "saved")
        Ok("saved")
      },
    )
  let assert json.Object(fields) = args()
    as "the fixture arguments are an object"
  let outcome =
    configuration.tool(door).run(
      ctx,
      json.Object(
        list.map(fields, fn(pair) {
          case pair.0 {
            "new" -> #("new", json.String(string.repeat("x", 3000)))
            _ -> pair
          }
        }),
      ),
    )
  assert outcome.content
    == [
      tool.text_block(
        "invalid arguments: the complete edit must fit the 2 KiB approval preview; propose a smaller edit",
      ),
    ]
    as "the size guard itself refuses the complete edit"
  assert outcome.is_error as "a hidden or incomplete preview is rejected"
  assert process.receive(events, 0) == Error(Nil)
    as "nothing crosses the bounded proposal boundary"
}

pub fn read_exposes_proposal_identity_in_model_visible_content_test() {
  let ctx =
    fake_broker.ctx(
      workspace: "/w",
      filesystem: memory_fs.filesystem(memory_fs.start()),
      now: 0,
      script: [],
      recorded: process.new_subject(),
    )
  let door =
    configuration.Door(
      read: fn() {
        Ok(configuration.Document("/home/loom.toml", "sha256:base", "model = 1"))
      },
      validate: fn(_) { Error("unused") },
      apply: fn(_) { Error("unused") },
    )
  let outcome =
    configuration.tool(door).run(
      ctx,
      json.Object([#("action", json.String("read"))]),
    )
  assert outcome.content
    == [
      tool.text_block(
        "File: \"/home/loom.toml\"\nDigest: sha256:base\n\nConfiguration:\nmodel = 1",
      ),
    ]
    as "the provider sees the exact identity needed for its next proposal"
}
