//// The line format: every event round-trips, and every malformed line is
//// refused by name.

import gepa.{type Event}
import gepa/budget
import gepa/log
import gepa/verdict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck

fn text() -> qcheck.Generator(String) {
  // Plain text and the characters the escape covers, with a few more
  // that could collide with the syntax.
  qcheck.from_generators(qcheck.string(), [
    qcheck.return(" "),
    qcheck.return("a b,c;d=e\\f\ng\th\r\ni"),
    qcheck.return("\\s\\n\\\\"),
    qcheck.return("ünïcödé 🙂"),
    qcheck.return(""),
  ])
}

fn id() -> qcheck.Generator(String) {
  qcheck.map(text(), fn(t) { "id-" <> t })
}

fn float() -> qcheck.Generator(Float) {
  qcheck.from_generators(qcheck.bounded_float(-1000.0, 1000.0), [
    qcheck.return(0.0),
    qcheck.return(1.0e-7),
    qcheck.return(123_456.789),
  ])
}

fn score() -> qcheck.Generator(gepa.Score) {
  use task <- qcheck.bind(id())
  use value <- qcheck.bind(float())
  use feedback <- qcheck.map(text())
  gepa.Score(task:, value:, feedback:)
}

fn measured() -> qcheck.Generator(gepa.Measured) {
  use candidate <- qcheck.bind(id())
  use scores <- qcheck.map(qcheck.generic_list(
    score(),
    qcheck.bounded_int(0, 3),
  ))
  gepa.Measured(candidate:, scores:)
}

fn pick(choices: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = choices
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn event() -> qcheck.Generator(Event) {
  qcheck.from_generators(seeded(), [
    evaluated(),
    reflected(),
    minted(),
    refused(),
    judged(),
    qcheck.map(
      pick([budget.Steps, budget.Budget, budget.Reflections, budget.Candidates]),
      gepa.Stopped,
    ),
  ])
}

fn seeded() -> qcheck.Generator(Event) {
  use candidate <- qcheck.bind(id())
  use components <- qcheck.map(qcheck.generic_list(
    qcheck.tuple2(id(), text()),
    qcheck.bounded_int(0, 3),
  ))
  gepa.Seeded(candidate:, components:)
}

fn evaluated() -> qcheck.Generator(Event) {
  use stage <- qcheck.bind(
    pick([
      gepa.SeedValidate,
      gepa.ParentMinibatch,
      gepa.ChildMinibatch,
      gepa.Validate,
      gepa.Confirm,
    ]),
  )
  use step <- qcheck.bind(qcheck.bounded_int(0, 50))
  use candidate <- qcheck.bind(id())
  use tasks <- qcheck.bind(qcheck.generic_list(id(), qcheck.bounded_int(0, 4)))
  use cap <- qcheck.bind(float())
  use ref <- qcheck.bind(text())
  use measured <- qcheck.bind(qcheck.generic_list(
    measured(),
    qcheck.bounded_int(0, 2),
  ))
  use cost <- qcheck.map(float())
  gepa.Evaluated(
    stage:,
    step:,
    candidate:,
    tasks:,
    cap:,
    ref:,
    measured:,
    cost:,
  )
}

fn reflected() -> qcheck.Generator(Event) {
  use step <- qcheck.bind(qcheck.bounded_int(0, 50))
  use cost <- qcheck.bind(float())
  use ref <- qcheck.bind(text())
  use finish <- qcheck.map(pick([gepa.Complete, gepa.Truncated, gepa.Unknown]))
  gepa.Reflected(step:, cost:, ref:, finish:)
}

fn minted() -> qcheck.Generator(Event) {
  use candidate <- qcheck.bind(id())
  use parent <- qcheck.bind(id())
  use step <- qcheck.bind(qcheck.bounded_int(0, 50))
  use slot <- qcheck.bind(text())
  use text <- qcheck.map(text())
  gepa.Minted(candidate:, parent:, step:, slot:, text:)
}

fn refused() -> qcheck.Generator(Event) {
  use step <- qcheck.bind(qcheck.bounded_int(0, 50))
  use candidate <- qcheck.bind(
    qcheck.from_generators(qcheck.return(None), [qcheck.map(id(), Some)]),
  )
  use reason <- qcheck.map(text())
  gepa.Refused(step:, candidate:, reason:)
}

fn judged() -> qcheck.Generator(Event) {
  use candidate <- qcheck.bind(id())
  use against <- qcheck.bind(id())
  use basis <- qcheck.bind(
    pick([verdict.OnMinibatch, verdict.OnValidate, verdict.OnConfirm]),
  )
  use acceptance <- qcheck.bind(
    pick([
      verdict.Improved,
      verdict.Harmed,
      verdict.Inconclusive,
      verdict.Incomplete,
    ]),
  )
  use disposition <- qcheck.bind(
    pick([
      verdict.Incumbent,
      verdict.Joined,
      verdict.ParetoOnly,
      verdict.Discarded,
      verdict.Unsettled,
      verdict.Refused,
      verdict.ScreenedOut,
      verdict.Confirmed,
      verdict.Unconfirmed,
    ]),
  )
  use ref <- qcheck.map(text())
  gepa.Judged(candidate:, against:, basis:, acceptance:, disposition:, ref:)
}

pub fn every_event_round_trips_through_the_codec_test() {
  use event <- qcheck.given(event())
  let line = log.encode(event)

  assert log.decode(line) == Ok(event)
  assert !string.contains(line, "\n")
  assert log.parse(log.render([event, event])) == Ok([event, event])
}

pub fn a_fixed_line_is_stable_test() {
  assert log.encode(gepa.Stopped(budget.Steps)) == "stopped v=1 reason=steps"
  assert log.encode(gepa.Minted("c", "p", 2, "a slot", "x,y;z\n"))
    == "minted v=1 candidate=c parent=p step=2 slot=a\\sslot text=x\\cy\\pz\\n"
  assert log.encode(gepa.Refused(3, None, "nothing"))
    == "refused v=1 step=3 reason=nothing"
}

pub fn malformed_lines_are_refused_by_name_test() {
  let refused = fn(line: String, naming: String) {
    let assert Error(reason) = log.decode(line)
    assert string.contains(reason, naming)
  }

  refused("", "empty")
  refused("stopped v=2 reason=steps", "version")
  refused("stopped reason=steps", "missing field \"v\"")
  refused("danced v=1 reason=steps", "unknown log row kind")
  refused("stopped v=1 reason=steps extra=1", "unexpected field")
  refused("stopped v=1 reason=steps reason=steps", "repeated field")
  refused("stopped v=1 reason", "malformed field")
  refused("stopped v=1 reason=nope", "unknown stop reason")
  refused("minted v=1 candidate=c parent=p step=-1 slot=s text=t", "negative")
  refused("minted v=1 candidate=c parent=p step=x slot=s text=t", "integer")
  refused("minted v=1 candidate= parent=p step=1 slot=s text=t", "nonempty")
  refused(
    "minted v=1 candidate=c parent=p step=1 slot=s text=t\\q",
    "unknown escape",
  )
  refused(
    "minted v=1 candidate=c parent=p step=1 slot=s text=t\\",
    "lone backslash",
  )
  refused(
    "evaluated v=1 stage=validate step=1 candidate=c tasks=a cap=x ref= cost=0.0",
    "number",
  )
  refused(
    "evaluated v=1 stage=validate step=1 candidate=c tasks=a cap=1.0 ref= cost=0.0 measured=c;t,1.0",
    "a score is",
  )
  refused(
    "evaluated v=1 stage=validate step=1 candidate=c tasks=a,,b cap=1.0 ref= cost=0.0",
    "nonempty",
  )
  refused("seeded v=1 candidate=c component=a", "a name and a text")

  // A whole log stops at the first bad line and names it.
  let assert Error(reason) =
    log.parse("stopped v=1 reason=steps\nstopped v=1\n")
  assert string.starts_with(reason, "search row 2: ")
  assert log.parse("") == Ok([])
}
