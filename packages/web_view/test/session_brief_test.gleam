//// The session brief's wire codec (protocol-change/125).
////
//// A brief the daemon encodes must decode to the same value, over generated
//// briefs from a fixed seed. The decoder is total: a damaged section is absent
//// and the others survive, and a reply that is not a brief is no brief.

import core/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import qcheck
import web_view/session_brief as brief

const count = 200

const seed = 20_261_119

fn property(generator: qcheck.Generator(a), check: fn(a) -> Nil) -> Nil {
  qcheck.default_config()
  |> qcheck.with_test_count(count)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(generator, check)
}

fn time() -> qcheck.Generator(Int) {
  qcheck.bounded_int(0, 2_000_000_000_000)
}

// Mixes ascii, escapes, control characters and multi-byte codepoints, so the
// codec's escaping is exercised. Shrinks toward the empty string.
const palette = ["a", "Z", " ", "\"", "\\", "\n", "\u{0001}", "é", "漢", "😀"]

fn words() -> qcheck.Generator(String) {
  let character =
    qcheck.bounded_int(0, list.length(palette) - 1)
    |> qcheck.map(fn(index) {
      case list.drop(palette, index) {
        [chosen, ..] -> chosen
        [] -> "a"
      }
    })
  qcheck.generic_list(
    elements_from: character,
    length_from: qcheck.bounded_int(0, 8),
  )
  |> qcheck.map(string.concat)
}

fn maybe(generator: qcheck.Generator(a)) -> qcheck.Generator(Option(a)) {
  qcheck.map2(qcheck.bounded_int(0, 1), generator, fn(pick, value) {
    case pick {
      0 -> None
      _ -> Some(value)
    }
  })
}

fn few(generator: qcheck.Generator(a), most: Int) -> qcheck.Generator(List(a)) {
  qcheck.generic_list(
    elements_from: generator,
    length_from: qcheck.bounded_int(0, most),
  )
}

fn outcome() -> qcheck.Generator(brief.Outcome) {
  qcheck.map(qcheck.bounded_int(0, 2), fn(pick) {
    case pick {
      0 -> brief.Running
      1 -> brief.Succeeded
      _ -> brief.Failed
    }
  })
}

fn state() -> qcheck.Generator(brief.State) {
  qcheck.map(qcheck.bounded_int(0, 2), fn(pick) {
    case pick {
      0 -> brief.Working
      1 -> brief.Idle
      _ -> brief.Stopped
    }
  })
}

fn assistant() -> qcheck.Generator(brief.Assistant) {
  qcheck.map2(words(), time(), fn(text, at) {
    brief.Assistant(text: brief.untrusted(text), at:)
  })
}

fn step() -> qcheck.Generator(brief.Step) {
  qcheck.map4(time(), words(), words(), outcome(), fn(at, tool, text, outcome) {
    brief.Step(
      at:,
      tool: brief.untrusted(tool),
      words: brief.untrusted(text),
      outcome:,
    )
  })
}

fn strand() -> qcheck.Generator(brief.Strand) {
  qcheck.map3(words(), state(), maybe(time()), fn(name, state, since) {
    brief.Strand(name:, state:, since:)
  })
}

fn goal() -> qcheck.Generator(brief.Goal) {
  qcheck.map4(
    words(),
    words(),
    time(),
    time(),
    fn(objective, status, tokens_used, token_budget) {
      brief.Goal(objective:, status:, tokens_used:, token_budget:)
    },
  )
}

fn peer() -> qcheck.Generator(brief.Peer) {
  qcheck.map4(words(), words(), time(), words(), fn(session, strand, at, text) {
    brief.Peer(session:, strand:, at:, text: brief.untrusted(text))
  })
}

fn command() -> qcheck.Generator(brief.Command) {
  qcheck.map3(
    words(),
    qcheck.bounded_int(-300, 300),
    time(),
    fn(text, exit, at) {
      brief.Command(command: brief.untrusted(text), exit:, at:)
    },
  )
}

fn any_brief() -> qcheck.Generator(brief.Brief) {
  qcheck.map2(
    qcheck.tuple3(maybe(assistant()), few(step(), 5), few(strand(), 5)),
    qcheck.tuple3(maybe(goal()), few(peer(), 4), maybe(command())),
    fn(first, second) {
      brief.Brief(
        assistant: first.0,
        steps: first.1,
        strands: first.2,
        goal: second.0,
        peers: second.1,
        command: second.2,
      )
    },
  )
}

pub fn a_brief_round_trips_through_the_wire_test() {
  property(any_brief(), fn(value) {
    assert brief.decode(brief.to_json(value)) == Ok(value)
  })
}

pub fn model_text_carries_the_untrusted_mark_on_the_wire_test() {
  let value =
    brief.Brief(
      assistant: Some(brief.Assistant(brief.untrusted("hi"), 5)),
      steps: [
        brief.Step(
          1,
          brief.untrusted("bash"),
          brief.untrusted("Ran make"),
          brief.Running,
        ),
      ],
      strands: [],
      goal: None,
      peers: [brief.Peer("s", "main", 2, brief.untrusted("hello"))],
      command: Some(brief.Command(brief.untrusted("make"), 0, 3)),
    )
  let text = json.to_string(brief.to_json(value))
  let marks = list.length(string.split(text, "\"trust\":\"untrusted\"")) - 1
  assert marks == 4

  // The tool name of a call is the model's choice, so it is behind the type too.
  let assert [step] = value.steps
  assert brief.untrusted_text(step.tool) == "bash"
}
