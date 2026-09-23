//// The agent workspace projects durable collaboration facts and peer origins.
////
//// Execution custody, input readiness, peer links, and workflow intents come
//// from one coherent session cut. Peer messages come from authenticated entry
//// origins on the selected branch. None of these observations proves that a
//// recipient processed a message or that a workflow step completed.

import core/entry
import core/json.{type JsonValue}
import core/message
import core/register
import etui/span
import etui/style
import etui/text
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/order
import gleam/result
import gleam/string
import tui/snapshot
import tui/snapshot_view
import tui/text_hygiene
import tui/theme

type Execution {
  Execution(
    id: String,
    strand: String,
    phase: String,
    result: JsonValue,
    seq: Int,
  )
}

type Link {
  Link(source: String, session: String, target: String)
}

type Workflow {
  Workflow(key: String, strand: String, name: String, version: String)
}

type Step {
  Step(run: String, name: String)
}

type PeerMessage {
  PeerMessage(session: String, strand: String, body: String, seq: Int)
}

/// Renders bounded evidence for one inspected strand without changing it.
///
/// ## Examples
///
/// ```gleam
/// // collaboration_view.lines(view, window, "main", 80)
/// ```
@internal
pub fn lines(
  view: snapshot_view.View,
  window: snapshot.Window,
  strand: String,
  width: Int,
) -> List(span.Line) {
  let facts =
    list.filter(view.cells, fn(cell) { cell.namespace == register.FactCustom })
  let executions =
    facts
    |> list.filter(fn(cell) {
      string.starts_with(cell.key, "client/async/record/")
    })
    |> list.filter_map(fn(cell) { execution(cell.value, cell.seq) })
    |> list.filter(fn(item) { item.strand == strand })
    |> list.sort(fn(a, b) {
      case live(a.phase), live(b.phase) {
        True, False -> order.Lt
        False, True -> order.Gt
        _, _ -> int.compare(b.seq, a.seq)
      }
    })
  let links =
    facts
    |> list.filter(fn(cell) {
      string.starts_with(cell.key, "client/peers/link/")
    })
    |> list.filter_map(fn(cell) { link(cell.value) })
    |> list.filter(fn(item) { item.source == strand })
  let workflows =
    facts
    |> list.filter(fn(cell) {
      string.starts_with(cell.key, "client/workflow/run/")
    })
    |> list.filter_map(fn(cell) { workflow(cell.key, cell.value) })
    |> list.filter(fn(item) { item.strand == strand })
  let steps =
    facts
    |> list.filter(fn(cell) {
      string.starts_with(cell.key, "client/workflow/step/")
    })
    |> list.filter_map(fn(cell) { step(cell.value) })
  let messages = peer_messages(view, window, strand)
  list.flatten([
    [
      heading("COLLABORATION · " <> strand, width),
      quiet(
        int.to_string(list.length(messages))
          <> " peer entries · "
          <> int.to_string(
          list.length(list.filter(executions, fn(item) { live(item.phase) })),
        )
          <> " live executions · "
          <> int.to_string(list.length(links))
          <> " outgoing links",
        width,
      ),
    ],
    peer_lines(messages, width),
    execution_lines(executions, facts, width),
    link_lines(links, width),
    workflow_lines(workflows, steps, width),
  ])
}

fn live(phase: String) -> Bool {
  phase == "starting" || phase == "running" || phase == "draining"
}

fn execution(value: JsonValue, seq: Int) -> Result(Execution, Nil) {
  use fields <- result.try(object(value))
  use id <- result.try(field_text(fields, "id"))
  use strand <- result.try(field_text(fields, "strand"))
  use phase <- result.try(field_text(fields, "phase"))
  use payload <- result.try(list.key_find(fields, "result"))
  case phase {
    "starting" | "running" | "draining" | "finished" | "lost" ->
      Ok(Execution(id, strand, phase, payload, seq))
    _ -> Error(Nil)
  }
}

fn link(value: JsonValue) -> Result(Link, Nil) {
  use fields <- result.try(object(value))
  use source <- result.try(field_text(fields, "source_strand"))
  use session <- result.try(field_text(fields, "session"))
  use target <- result.try(field_text(fields, "strand"))
  Ok(Link(source, session, target))
}

fn workflow(key: String, value: JsonValue) -> Result(Workflow, Nil) {
  use fields <- result.try(object(value))
  use strand <- result.try(field_text(fields, "strand"))
  use name <- result.try(field_text(fields, "name"))
  use version <- result.try(field_text(fields, "version"))
  Ok(Workflow(key, strand, name, version))
}

fn step(value: JsonValue) -> Result(Step, Nil) {
  use fields <- result.try(object(value))
  use run <- result.try(field_text(fields, "run"))
  use name <- result.try(field_text(fields, "name"))
  Ok(Step(run, name))
}

fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), Nil) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(Nil)
  }
}

fn field_text(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, Nil) {
  case list.key_find(fields, key) {
    Ok(json.String(value)) if value != "" -> Ok(value)
    _ -> Error(Nil)
  }
}

fn peer_messages(
  view: snapshot_view.View,
  window: snapshot.Window,
  strand: String,
) -> List(PeerMessage) {
  snapshot_view.branch(view, window, strand).records
  |> list.filter_map(fn(record) {
    case record.strand, record.entry {
      target,
        entry.MessageEntry(
          message: message.UserMessage(
            origin: Some(message.PeerOrigin(source_session, source_strand)),
            content: content,
            ..,
          ),
          seq: seq,
          ..,
        )
        if target == strand
      -> {
        let body =
          content
          |> list.filter_map(fn(block) {
            case block {
              message.UserText(value, _) -> Ok(value)
              message.UserImage(..) -> Error(Nil)
            }
          })
          |> string.join("\n")
        Ok(PeerMessage(source_session, source_strand, body, seq))
      }
      _, _ -> Error(Nil)
    }
  })
  |> list.take(8)
}

fn execution_lines(
  executions: List(Execution),
  facts: List(snapshot_view.Cell),
  width: Int,
) -> List(span.Line) {
  let rows =
    executions
    |> list.take(8)
    |> list.flat_map(fn(item) {
      let ready =
        list.find(facts, fn(cell) {
          cell.key == "client/async/ready/" <> item.id
        })
        |> result.map(fn(cell) { readiness(cell.value) })
        |> result.unwrap("Input endpoints not published")
      let outcome = case item.phase, item.result {
        "lost", json.String(reason) -> " · " <> reason
        _, _ -> ""
      }
      [
        accent(
          "◆ " <> item.id <> " · " <> item.phase <> outcome,
          width,
          case item.phase {
            "lost" -> theme.danger
            "running" -> theme.current
            _ -> theme.paper
          },
        ),
        quiet("  " <> ready, width),
      ]
    })
  section(
    "BACKGROUND EXECUTIONS",
    rows,
    "No captured execution for this strand.",
    list.length(executions),
    width,
  )
}

fn readiness(value: JsonValue) -> String {
  case object(value) {
    Ok(fields) ->
      case list.key_find(fields, "endpoints") {
        Ok(json.Array(values)) ->
          "Ready: "
          <> string.join(
            list.filter_map(values, fn(value) {
              case value {
                json.String(name) -> Ok(name)
                _ -> Error(Nil)
              }
            }),
            ", ",
          )
        _ -> "Input endpoints unavailable"
      }
    _ -> "Input endpoints unavailable"
  }
}

fn link_lines(links: List(Link), width: Int) -> List(span.Line) {
  let rows =
    links
    |> list.take(8)
    |> list.map(fn(item) {
      accent("→ " <> item.session <> "/" <> item.target, width, theme.current)
    })
  list.append(
    section(
      "OUTGOING PEER LINKS",
      rows,
      "No outgoing link captured for this strand.",
      list.length(links),
      width,
    ),
    case links {
      [] -> []
      _ -> [quiet("Wake scope is not in this captured source link.", width)]
    },
  )
}

fn workflow_lines(
  workflows: List(Workflow),
  steps: List(Step),
  width: Int,
) -> List(span.Line) {
  let rows =
    workflows
    |> list.take(6)
    |> list.flat_map(fn(item) {
      let own = list.filter(steps, fn(step) { step.run == item.key })
      [
        accent("◇ " <> item.name <> " · " <> item.version, width, theme.paper),
        quiet(
          "  " <> int.to_string(list.length(own)) <> " recorded step intents",
          width,
        ),
        ..list.map(list.take(own, 3), fn(step) {
          quiet("    · " <> step.name, width)
        })
      ]
    })
  section(
    "NAMED WORKFLOWS",
    rows,
    "No named workflow captured for this strand.",
    list.length(workflows),
    width,
  )
}

fn peer_lines(messages: List(PeerMessage), width: Int) -> List(span.Line) {
  let rows =
    messages
    |> list.take(6)
    |> list.flat_map(fn(item) {
      [
        raised("← stored #" <> int.to_string(item.seq), width, theme.current),
        raised("  " <> item.session <> "/" <> item.strand, width, theme.paper),
        ..wrapped("  " <> bound(item.body, 1024), width)
      ]
    })
  list.append(
    section(
      "PEER MESSAGES",
      rows,
      "No peer-authored entry in the loaded branch.",
      list.length(messages),
      width,
    ),
    [
      quiet(
        "Loaded branch may include inherited entries; stored does not mean read.",
        width,
      ),
    ],
  )
}

fn section(
  title: String,
  rows: List(span.Line),
  empty: String,
  count: Int,
  width: Int,
) -> List(span.Line) {
  [
    span.line_plain(""),
    heading(title <> " · " <> int.to_string(count), width),
    ..case rows {
      [] -> [quiet(empty, width)]
      _ -> rows
    }
  ]
}

fn wrapped(value: String, width: Int) -> List(span.Line) {
  let lines =
    value
    |> text_hygiene.multiline
    |> string.split("\n")
    |> list.flat_map(fn(row) { text.wrap(row, int.max(1, width - 2)) })
  let shown =
    lines
    |> list.take(12)
    |> list.map(fn(row) { raised(row, width, theme.paper) })
  case list.drop(lines, 12) {
    [] -> shown
    _ -> list.append(shown, [quiet("  … continued in transcript", width)])
  }
}

fn bound(value: String, limit: Int) -> String {
  case string.length(value) > limit {
    True -> string.slice(value, 0, limit) <> " … [excerpt]"
    False -> value
  }
}

fn heading(value: String, width: Int) -> span.Line {
  accent(value, width, theme.signal)
}

fn quiet(value: String, width: Int) -> span.Line {
  accent(value, width, theme.quiet)
}

fn accent(value: String, width: Int, color: style.Color) -> span.Line {
  span.line_new([
    span.span_styled(
      text.truncate(text_hygiene.single_line(value), int.max(1, width), "…"),
      style.new(color, theme.graphite, style.none()),
    ),
  ])
}

fn raised(value: String, width: Int, color: style.Color) -> span.Line {
  span.line_new([
    span.span_styled(
      value
        |> text_hygiene.single_line
        |> text.truncate(int.max(1, width), "…")
        |> text.pad_right(int.max(1, width)),
      style.new(color, theme.raised, style.none()),
    ),
  ])
}
