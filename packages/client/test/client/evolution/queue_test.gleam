//// Queue tests hold staging open to observe the native admission boundary.

import client/evolution/live
import client/evolution/queue
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import core/clock
import core/json
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should
import weft/poll

pub fn staging_returns_immediately_and_deduplicates_one_native_commit_test() {
  let gates = process.new_subject()
  let events = process.new_subject()
  let selected = selection()
  let assert Ok(owner) =
    live.start(
      live.Config(
        clock: clock.fixed(0),
        stage: fn(selection) {
          let gate = process.new_subject()
          process.send(gates, gate)
          process.send(events, "stage")
          process.receive(gate, 2000) |> should.equal(Ok(Nil))
          Ok(
            live.Generation(
              selection:,
              inventory: fn() { Ok(json.Null) },
              tools: [],
              hooks: None,
              retire: retirement.repeat(fn() {
                process.send(events, "retire")
                Ok(Nil)
              }),
              validate: fn() { Ok(Nil) },
            ),
          )
        },
        adopt: fn(_) { Ok(Nil) },
        recover: fn() { Ok(None) },
      ),
    )
    as "native owner starts"
  let assert Ok(front) = queue.start(owner, clock.fixed(0))
    as "front door starts"
  let transition =
    live.Transition("request", 10_000, selected, fn() {
      process.send(events, "commit")
      Ok(selected)
    })
  queue.enqueue(front, transition, "native signature")
  |> should.equal(Ok(queue.Queued("request")))
  process.receive(events, 1000) |> should.equal(Ok("stage"))
  let assert Ok(gate) = process.receive(gates, 1000)
    as "stage owns its gate subject"
  queue.poll(front, "request")
  |> should.equal(Ok(Some(queue.Running("request"))))
  queue.enqueue(front, transition, "native signature")
  |> should.equal(Ok(queue.Running("request")))
  queue.enqueue(front, transition, "changed signature")
  |> result.is_error
  |> should.be_true
  queue.enqueue(
    front,
    live.Transition(..transition, request_id: "second"),
    "second",
  )
  |> result.is_error
  |> should.be_true
  process.receive(events, 0) |> should.equal(Error(Nil))

  // Releasing staging permits exactly one commit and terminal receipt.
  process.send(gate, Nil)
  poll.until(within: 2000, every: 5, attempt: fn() {
    case queue.poll(front, "request") {
      Ok(Some(queue.Completed(selection))) -> poll.Done(selection)
      Ok(Some(queue.Running(_))) | Ok(Some(queue.Queued(_))) -> poll.Retry
      _ -> poll.Fail("transition did not complete")
    }
  })
  |> should.equal(poll.Answered(selected))
  process.receive(events, 1000) |> should.equal(Ok("commit"))
  queue.enqueue(front, transition, "native signature")
  |> should.equal(Ok(queue.Completed(selected)))
  queue.poll(front, "unknown") |> should.equal(Ok(None))
  process.receive(events, 0) |> should.equal(Error(Nil))
  queue.close(front) |> should.equal(Ok(Nil))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
  process.receive(events, 1000) |> should.equal(Ok("retire"))
}

pub fn expired_or_unbounded_request_never_allocates_a_staging_job_test() {
  let events = process.new_subject()
  let assert Ok(owner) =
    live.start(
      live.Config(
        clock: clock.fixed(100),
        stage: fn(selection) {
          process.send(events, Nil)
          Ok(
            live.Generation(
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
  let assert Ok(front) = queue.start(owner, clock.fixed(100))
    as "front door starts"
  let selected = selection()
  let expired = live.Transition("expired", 100, selected, fn() { Ok(selected) })
  queue.enqueue(front, expired, "signature")
  |> result.is_error
  |> should.be_true
  queue.enqueue(
    front,
    live.Transition(..expired, expires_at: 120_101),
    "signature",
  )
  |> result.is_error
  |> should.be_true
  process.receive(events, 0) |> should.equal(Error(Nil))
  queue.close(front) |> should.equal(Ok(Nil))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
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
