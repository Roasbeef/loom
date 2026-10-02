//// Observation metadata preserves document mutation history even when a later
//// sync restores the same text. The actor's incarnation remains private.

import core/json
import gleam/option.{None}
import lsp/client
import lsp/jsonrpc
import support/fake_server

pub fn document_versions_detect_changes_even_when_text_is_restored_test() {
  let fake =
    fake_server.start(
      json.Object([#("textDocumentSync", json.Int(1))]),
      Nil,
      fn(state, inbound) {
        case inbound {
          jsonrpc.ServerRequest(id:, ..) -> #(state, [
            fake_server.Reply(fake_server.response(id, json.Null)),
          ])
          jsonrpc.Notification(..) | jsonrpc.Response(..) -> #(state, [])
        }
      },
    )
  let options = client.options("fake", "/work", "gleam")
  let assert Ok(actor) = client.start(fake_server.seam(fake), options)
    as "start the client"
  let path = "/work/a.gleam"
  let assert Ok(Nil) = client.sync(actor, [client.Change(path, "first")])
    as "sync a source"
  let assert Ok(before) = client.observation_state(actor, 1000)
    as "read the first state"
  let assert Ok(Nil) =
    client.sync(actor, [
      client.Change(path, "second"),
      client.Change(path, "first"),
    ])
    as "restore source text after an intervening change"
  let assert Ok(after) = client.observation_state(actor, 1000)
    as "read the later state"
  assert before.generation == after.generation
  assert before.revision < after.revision
  let assert [old] = before.documents as "the source is open"
  let assert [current] = after.documents as "the source remains open"
  assert old.text == current.text
  assert old.version < current.version
  assert after.failure == None
  assert after.busy == []
  client.stop(actor, 1000)
}

pub fn client_incarnations_have_distinct_observation_tokens_test() {
  let capabilities = json.Object([])
  let script = fn(state: Nil, _inbound) { #(state, []) }
  let first = fake_server.start(capabilities, Nil, script)
  let second = fake_server.start(capabilities, Nil, script)
  let options = client.options("fake", "/work", "gleam")
  let assert Ok(a) = client.start(fake_server.seam(first), options)
    as "start the first actor"
  let assert Ok(b) = client.start(fake_server.seam(second), options)
    as "start the second actor"
  let assert Ok(a_state) = client.observation_state(a, 1000)
    as "read the first token"
  let assert Ok(b_state) = client.observation_state(b, 1000)
    as "read the second token"
  assert a_state.generation != b_state.generation
  client.stop(a, 1000)
  client.stop(b, 1000)
}
