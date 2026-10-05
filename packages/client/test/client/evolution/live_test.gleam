//// Generation tests observe ordering and withheld custody rather than reports.

import client/evolution/live
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import client/evolution/store
import core/clock
import core/json as core_json
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should

fn selection(generation: Int) -> record.Selection {
  let candidate = record_test.candidate()
  record.Selection(
    candidate.id,
    record.evidence_placeholder(),
    candidate.scope,
    candidate.name,
    generation,
  )
}

fn generation(
  selection: record.Selection,
  retire: fn() -> Result(Nil, String),
) -> live.Generation {
  live.Generation(
    selection:,
    tools: [],
    hooks: None,
    retire: retirement.repeat(retire),
    inventory: fn() { Ok(core_json.Null) },
    validate: fn() { Ok(Nil) },
  )
}

fn owner(
  stage: fn(record.Selection) -> Result(live.Generation, store.Refusal),
  adopt: fn(record.Selection) -> Result(Nil, store.Refusal),
) -> live.Live {
  let assert Ok(owner) =
    live.start(
      live.Config(clock: clock.fixed(0), stage:, adopt:, recover: fn() {
        Ok(None)
      }),
    )
    as "generation owner starts without native resources"
  owner
}

fn transition(
  selected: record.Selection,
  commit: fn() -> Result(record.Selection, store.Refusal),
) -> live.Transition {
  live.Transition(
    "request-" <> int.to_string(selected.generation),
    10_000,
    selected,
    commit,
  )
}

pub fn predecessor_native_retirement_precedes_selection_and_audit_test() {
  let events = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        Ok(
          generation(selected, fn() {
            process.send(events, "retire")
            Ok(Nil)
          }),
        )
      },
      fn(_) {
        process.send(events, "audit")
        Ok(Nil)
      },
    )
  let first = selection(1)
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  process.receive(events, 1000) |> should.equal(Ok("audit"))
  let next = selection(2)
  live.activate(
    owner,
    transition(next, fn() {
      process.send(events, "commit")
      Ok(next)
    }),
    1000,
  )
  |> should.equal(Ok(next))
  process.receive(events, 1000) |> should.equal(Ok("retire"))
  process.receive(events, 1000) |> should.equal(Ok("commit"))
  process.receive(events, 1000) |> should.equal(Ok("audit"))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}

pub fn unconfirmed_retirement_pins_custody_and_refuses_additional_staging_test() {
  let staged = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        process.send(staged, selected.generation)
        let retire = case selected.generation {
          1 -> fn() { Error("withheld native exit") }
          _ -> fn() { Ok(Nil) }
        }
        Ok(generation(selected, retire))
      },
      fn(_) { Ok(Nil) },
    )
  let first = selection(1)
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  let next = selection(2)
  let refused = live.activate(owner, transition(next, fn() { Ok(next) }), 1000)
  case refused {
    Error(store.CleanupUnconfirmed(..)) -> Nil
    _ -> panic as "cleanup must refuse promotion"
  }
  live.activate(
    owner,
    transition(selection(3), fn() { Ok(selection(3)) }),
    1000,
  )
  |> result.is_error
  |> should.be_true
  process.receive(staged, 1000) |> should.equal(Ok(1))
  process.receive(staged, 1000) |> should.equal(Ok(2))
  process.receive(staged, 0) |> should.equal(Error(Nil))
}

pub fn failed_predecessor_has_one_owned_retirement_obligation_test() {
  let retired = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        Ok(
          generation(selected, fn() {
            process.send(retired, selected.generation)
            case selected.generation {
              1 -> Error("withheld predecessor exit")
              _ -> Ok(Nil)
            }
          }),
        )
      },
      fn(_) { Ok(Nil) },
    )
  let first = selection(1)
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  let next = selection(2)
  live.activate(owner, transition(next, fn() { Ok(next) }), 1000)
  |> result.is_error
  |> should.be_true
  process.receive(retired, 1000) |> should.equal(Ok(1))
  process.receive(retired, 1000) |> should.equal(Ok(2))

  // Closing retries the held predecessor once. The prepared successor already
  // retired, and the predecessor's transported refusal is not another owner.
  live.close(owner, 1000) |> result.is_error |> should.be_true
  process.receive(retired, 1000) |> should.equal(Ok(1))
  process.receive(retired, 0) |> should.equal(Error(Nil))
}

pub fn expired_request_never_stages_or_commits_test() {
  let events = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        process.send(events, Nil)
        Ok(generation(selected, fn() { Ok(Nil) }))
      },
      fn(_) { Ok(Nil) },
    )
  let selected = selection(1)
  let expired =
    live.Transition("expired", 0, selected, fn() {
      process.send(events, Nil)
      Ok(selected)
    })
  live.activate(owner, expired, 1000) |> should.equal(Error(store.Busy))
  process.receive(events, 0) |> should.equal(Error(Nil))
}

pub fn failed_adoption_never_publishes_and_retires_staged_generation_test() {
  let retired = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        Ok(
          generation(selected, fn() {
            process.send(retired, Nil)
            Ok(Nil)
          }),
        )
      },
      fn(_) { Error(store.Unavailable("audit write failed")) },
    )
  let selected = selection(1)
  live.activate(owner, transition(selected, fn() { Ok(selected) }), 1000)
  |> result.is_error
  |> should.be_true
  process.receive(retired, 1000) |> should.equal(Ok(Nil))
  live.catalogue(owner)
  |> result.map(fn(active) {
    case active {
      None -> True
      Some(_) -> False
    }
  })
  |> should.equal(Ok(True))
}

pub fn uncertain_author_test_retirement_blocks_every_later_allocation_test() {
  let staged = process.new_subject()
  let owner =
    owner(
      fn(selected) {
        process.send(staged, Nil)
        Ok(generation(selected, fn() { Ok(Nil) }))
      },
      fn(_) { Ok(Nil) },
    )
  live.evaluate(owner, fn() {
    Error(store.CleanupUnconfirmed(
      "held helper",
      retirement.repeat(fn() { Error("held") }),
    ))
  })
  |> result.is_error
  |> should.be_true
  let next = selection(1)
  live.activate(owner, transition(next, fn() { Ok(next) }), 1000)
  |> result.is_error
  |> should.be_true
  process.receive(staged, 0) |> should.equal(Error(Nil))
}

pub fn failed_selection_cas_rebuilds_committed_predecessor_before_return_test() {
  let events = process.new_subject()
  let first = selection(1)
  let assert Ok(owner) =
    live.start(
      live.Config(
        clock: clock.fixed(0),
        stage: fn(selected) {
          Ok(
            generation(selected, fn() {
              process.send(events, "retire")
              Ok(Nil)
            }),
          )
        },
        adopt: fn(_) { Ok(Nil) },
        recover: fn() {
          process.send(events, "recover")
          Ok(Some(generation(first, fn() { Ok(Nil) })))
        },
      ),
    )
    as "native generation owner starts"
  live.activate(owner, transition(first, fn() { Ok(first) }), 1000)
  |> should.equal(Ok(first))
  live.activate(
    owner,
    transition(selection(2), fn() { Error(store.Stale) }),
    1000,
  )
  |> should.equal(Error(store.Stale))
  process.receive(events, 1000) |> should.equal(Ok("retire"))
  process.receive(events, 1000) |> should.equal(Ok("retire"))
  process.receive(events, 1000) |> should.equal(Ok("recover"))
  live.catalogue(owner)
  |> result.map(fn(active) {
    option.map(active, fn(current) { current.selection.generation })
  })
  |> should.equal(Ok(Some(1)))
  live.close(owner, 1000) |> should.equal(Ok(Nil))
}
