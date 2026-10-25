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

/// A code point from the ranges that have broken a grapheme- or
/// code-unit-based codec: the separators, backslashes, combining marks,
/// the zero-width joiner, CRLF, Latin-1, and astral characters.
fn tricky_codepoint() -> qcheck.Generator(Int) {
  qcheck.from_generators(qcheck.bounded_int(0x20, 0x7E), [
    qcheck.bounded_int(0x300, 0x36F),
    qcheck.bounded_int(0x1F600, 0x1F64F),
    qcheck.bounded_int(0xA0, 0x2FF),
    pick([
      0x5C, 0x20, 0x0A, 0x0D, 0x09, 0x2C, 0x3B, 0x3D, 0x200D, 0x301, 0x7B, 0x7D,
      0x75,
    ]),
  ])
}

fn text() -> qcheck.Generator(String) {
  // Plain text, the characters the escape covers, and strings built from
  // the tricky code points, including ones that start with a combining
  // mark or a joiner.
  qcheck.from_generators(qcheck.string(), [
    qcheck.generic_list(tricky_codepoint(), qcheck.bounded_int(0, 6))
      |> qcheck.map(from_codes),
    qcheck.return("\n\u{301}"),
    qcheck.return("\u{301}x"),
    qcheck.return(" \u{301}"),
    qcheck.return(",\u{301}"),
    qcheck.return(";\u{301}"),
    qcheck.return("\\\u{301}"),
    qcheck.return(" \u{200D}"),
    qcheck.return("a b,c;d=e\\f\ng\th\r\ni"),
    qcheck.return("\\s\\n\\\\\\u{41}"),
    qcheck.return("ünïcödé 🙂"),
    qcheck.return(""),
  ])
}

fn from_codes(codes: List(Int)) -> String {
  codes |> list.filter_map(string.utf_codepoint) |> string.from_utf_codepoints
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
  use finish <- qcheck.bind(pick([gepa.Complete, gepa.Truncated, gepa.Unknown]))
  use of <- qcheck.bind(qcheck.bounded_int(1, 4))
  use proposal <- qcheck.map(qcheck.bounded_int(1, of))
  gepa.Reflected(step:, cost:, ref:, finish:, proposal:, of:)
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

  // A width-one reflection writes the row it wrote before steps had a
  // width, and a row of that shape reads back as proposal one of one.
  let old_line = "reflected v=1 step=1 cost=0.001 ref=in/out finish=complete"
  assert log.encode(gepa.Reflected(1, 0.001, "in/out", gepa.Complete, 1, 1))
    == old_line
  assert log.decode(old_line)
    == Ok(gepa.Reflected(1, 0.001, "in/out", gepa.Complete, 1, 1))
  assert log.encode(gepa.Reflected(1, 0.001, "in/out", gepa.Complete, 2, 3))
    == old_line <> " proposal=2 of=3"
  assert log.decode(old_line <> " proposal=1 of=1")
    == Ok(gepa.Reflected(1, 0.001, "in/out", gepa.Complete, 1, 1))
  assert log.encode(gepa.Minted("c", "p", 2, "a slot", "x,y;z\n"))
    == "minted v=1 candidate=c parent=p step=2 slot=a\\sslot text=x\\cy\\pz\\n"
  assert log.encode(gepa.Refused(3, None, "nothing"))
    == "refused v=1 step=3 reason=nothing"
}

/// The golden lines: the same bytes on both targets for the values that
/// told the two apart, each read back to its value.
pub fn tricky_values_encode_to_the_same_ascii_on_both_targets_test() {
  let golden = [
    #("\n\u{301}", "\\n\\u{301}"),
    #("\u{301}x", "\\u{301}x"),
    #(" \u{301}", "\\s\\u{301}"),
    #(",\u{301}", "\\c\\u{301}"),
    #(";\u{301}", "\\p\\u{301}"),
    #("\\\u{301}", "\\\\\\u{301}"),
    #(" \u{200D}", "\\s\\u{200d}"),
    #("\r\n", "\\r\\n"),
    #("é🙂", "\\u{e9}\\u{1f642}"),
    #("a=b", "a=b"),
    #("{u}", "{u}"),
    #("", ""),
  ]

  list.each(golden, fn(pair) {
    let line = "minted v=1 candidate=c parent=p step=1 slot=s text=" <> pair.1
    assert log.encode(gepa.Minted("c", "p", 1, "s", pair.0)) == line
    assert log.decode(line) == Ok(gepa.Minted("c", "p", 1, "s", pair.0))

    // Every line is printable ASCII, so no target can split it two ways.
    assert list.all(string.to_utf_codepoints(line), fn(cp) {
      let code = string.utf_codepoint_to_int(cp)
      code >= 0x20 && code <= 0x7E
    })
  })

  // A list of tricky ids keeps its separators escaped inside each atom.
  let tasks = [" \u{301}", ",\u{301}", ";\u{301}"]
  let event = gepa.Evaluated(gepa.Validate, 1, "c", tasks, 0.0, "", [], 0.0)
  assert string.contains(
    log.encode(event),
    "tasks=\\s\\u{301},\\c\\u{301},\\p\\u{301}",
  )
  assert log.decode(log.encode(event)) == Ok(event)
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
    "minted v=1 candidate=c parent=p step=1 slot=s text=\\u{zz}",
    "malformed",
  )
  refused(
    "minted v=1 candidate=c parent=p step=1 slot=s text=\\u{41",
    "malformed",
  )
  refused(
    "minted v=1 candidate=c parent=p step=1 slot=s text=\\u{d800}",
    "names no code point",
  )
  refused(
    "minted v=1 candidate=c parent=p step=1 slot=s text=é",
    "outside printable ASCII",
  )
  refused(
    "minted v=1 candidate=c parent=p step=1 slot=s text=a\u{301}",
    "outside printable ASCII",
  )
  refused(
    "evaluated v=1 stage=validate step=1 candidate=c tasks=a cap=NaN.0 ref= cost=0.0",
    "number",
  )
  refused(
    "evaluated v=1 stage=validate step=1 candidate=c tasks=a cap=Infinity.0 ref= cost=0.0",
    "number",
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
  refused(
    "reflected v=1 step=1 cost=0.0 ref= finish=unknown proposal=2 of=1",
    "proposal i of n",
  )
  refused(
    "reflected v=1 step=1 cost=0.0 ref= finish=unknown proposal=0 of=2",
    "proposal i of n",
  )

  // A whole log stops at the first bad line and names it, and a text whose
  // last row has no newline is a tear, not a shorter log.
  let assert Error(reason) =
    log.parse("stopped v=1 reason=steps\nstopped v=1\n")
  assert string.starts_with(reason, "search row 2: ")
  assert log.parse("") == Ok([])
  assert log.parse("stopped v=1 reason=steps\nstopped v=1 reason=")
    == Error("the log's last row is torn")
  assert log.parse("stopped v=1 reason=steps")
    == Error("the log's last row is torn")
  assert log.parse("stopped v=1 reason=steps\n")
    == Ok([gepa.Stopped(budget.Steps)])
}
