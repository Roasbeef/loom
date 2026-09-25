import gleam/erlang/process
import mcp/call

// A callee that answers once with 42 and then exits normally.
fn answering_once() -> process.Subject(process.Subject(Int)) {
  let ready = process.new_subject()
  process.spawn(fn() {
    let inbox = process.new_subject()
    process.send(ready, inbox)
    let assert Ok(reply) = process.receive(inbox, 1000)
      as "the test sends one request"
    process.send(reply, 42)
  })
  let assert Ok(inbox) = process.receive(ready, 1000)
    as "the callee publishes its inbox"
  inbox
}

pub fn a_live_callee_answers_test() {
  let callee = answering_once()
  assert call.try_call(callee, waiting: 1000, sending: fn(reply) { reply })
    == Ok(42)
}

pub fn a_dead_callee_is_gone_not_a_crash_test() {
  let callee = answering_once()
  let assert Ok(42) =
    call.try_call(callee, waiting: 1000, sending: fn(reply) { reply })
    as "the first exchange is answered"

  // The callee has exited after its one answer; asking again must settle
  // as a value rather than exiting this test process.
  process.sleep(20)
  assert call.try_call(callee, waiting: 1000, sending: fn(reply) { reply })
    == Error(call.CalleeGone)
}

pub fn a_silent_callee_is_no_reply_test() {
  let inbox = process.new_subject()
  assert call.try_call(inbox, waiting: 10, sending: fn(reply) {
      let _ = reply
      Nil
    })
    == Error(call.NoReply)
}
