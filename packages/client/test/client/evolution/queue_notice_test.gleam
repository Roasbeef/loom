//// The queue lists what it is working on and tells its host when a request
//// ends, so a board can show a pending row and redraw when it resolves.

import client/evolution/live
import client/evolution/queue
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import client/evolution/store
import core/clock
import core/json
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should

pub fn pending_lists_the_running_request_and_notice_follows_its_end_test() {
  let gates = process.new_subject()
  let noticed = process.new_subject()
  let selected = selection()
  let assert Ok(owner) =
    live.start(
      live.Config(
        clock: clock.fixed(0),
        stage: fn(selection) {
          let gate = process.new_subject()
          process.send(gates, gate)
          process.receive(gate, 2000) |> should.equal(Ok(Nil))
          Ok(
            live.Generation(
              mode: live.ReplacementOnly,
              selection:,
              inventory: fn() { Ok(json.Null) },
              tools: [],
              hooks: None,
              retire: retirement.repeat(fn() { Ok(Nil) }),
              validate: fn() { Ok(Nil) },
            ),
          )
        },
        adopt: fn(_) { Ok(Nil) },
        recover: fn() { Ok(None) },
      ),
    )
    as "native owner starts"
  let assert Ok(front) =
    queue.start_notifying(owner, clock.fixed(0), fn() {
      process.send(noticed, Nil)
    })
    as "notifying front door starts"
  queue.pending(front) |> should.equal(Ok([]))
  queue.enqueue(front, transition(selected), "native signature")
  |> should.equal(Ok(queue.Queued("request")))
  let assert Ok(gate) = process.receive(gates, 1000)
    as "staging owns its gate subject"
  queue.pending(front)
  |> should.equal(
    Ok([
      queue.Waiting(
        request_id: "request",
        phase: queue.Staging,
        candidate_id: selected.candidate_id,
        expires_at: 10_000,
      ),
    ]),
  )

  // Nothing is announced while the request is still staging.
  process.receive(noticed, 0) |> should.equal(Error(Nil))
  process.send(gate, Nil)
  process.receive(noticed, 2000) |> should.equal(Ok(Nil))

  // A reader the notice wakes finds the terminal receipt and an empty queue.
  queue.poll(front, "request")
  |> should.equal(Ok(Some(queue.Completed(selected))))
  queue.pending(front) |> should.equal(Ok([]))
  process.receive(noticed, 100) |> should.equal(Error(Nil))
  queue.close(front) |> should.equal(Ok(Nil))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

pub fn a_failed_request_is_noticed_too_test() {
  let noticed = process.new_subject()
  let selected = selection()
  let assert Ok(owner) =
    live.start(
      live.Config(
        clock: clock.fixed(0),
        stage: fn(_) { Error(store.Unavailable("staging failed")) },
        adopt: fn(_) { Ok(Nil) },
        recover: fn() { Ok(None) },
      ),
    )
    as "native owner starts"
  let assert Ok(front) =
    queue.start_notifying(owner, clock.fixed(0), fn() {
      process.send(noticed, Nil)
    })
    as "notifying front door starts"
  queue.enqueue(front, transition(selected), "native signature")
  |> should.be_ok
  process.receive(noticed, 2000) |> should.equal(Ok(Nil))
  let assert Ok(Some(queue.Failed(_))) = queue.poll(front, "request")
    as "the failure is the retained receipt"
  queue.close(front) |> should.equal(Ok(Nil))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

fn transition(selected: record.Selection) -> live.Transition {
  live.Transition("request", 10_000, selected, fn() { Ok(selected) }, fn() {
    Ok(None)
  })
}

fn selection() -> record.Selection {
  let candidate = record_test.candidate()
  record.Selection(
    candidate.id,
    record.evidence_placeholder(),
    candidate.scope,
    candidate.name,
    1,
  )
}
