//// A `code_mode` program that completed, as the transcript draws it.
////
//// The program is one titled block from the moment its call is drawn until
//// the result arrives, so these tests pin the block's rows: the title with
//// its call count, the same opening lines a running block shows, the call
//// record's rows, and a preview of the value in place of JSON cut at a
//// column. A result with no record is drawn without the calls rows, and the
//// expanded view still shows the whole program above the whole result.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/usage_evidence
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/block_summary
import session_view/transcript_line.{
  type Line, Line, ProgramRunning, ProgramSettled, ToolCall, ToolDetail,
  ToolResult,
}
import session_view/transcript_lines

const program =
  "import cap/lsp\nimport cap/fs\n\npub fn main() {\n  let refs = lsp.references(\"proxy.go\")\n  Ok(refs)\n}\n"

fn minted(n: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), n)).0
}

fn call_entry() -> entry.Entry {
  call_entry_with([])
}

fn call_entry_with(extra: List(#(String, json.JsonValue))) -> entry.Entry {
  entry.MessageEntry(
    minted(1),
    None,
    1,
    1000,
    message.AssistantMessage(
      [
        message.AssistantText("Checking the proxy.", None),
        message.AssistantToolCall(message.ToolCall(
          "c1",
          "code_mode",
          json.Object([#("program", json.String(program)), ..extra]),
          None,
          None,
        )),
      ],
      "scene",
      "provider",
      "model",
      None,
      None,
      None,
      message.Usage(
        0,
        0,
        0,
        0,
        None,
        None,
        0,
        message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
        usage_evidence.none(),
      ),
      message.Stop,
      None,
      None,
      None,
      None,
      1000,
    ),
    False,
  )
}

fn result_entry(details: Option(json.JsonValue)) -> entry.Entry {
  entry.MessageEntry(
    minted(2),
    None,
    2,
    2000,
    message.ToolResultMessage(
      "c1",
      "code_mode",
      [message.ToolResultText("the text", None)],
      details,
      None,
      None,
      False,
      2000,
    ),
    False,
  )
}

fn record() -> json.JsonValue {
  let assert Ok(calls) =
    json.parse(
      "{\"started_unix_ms\":1,\"elapsed_ms\":90,\"total\":6,\"failed\":0,\"cancelled\":0,\"unsettled\":0,\"items\":[{\"cap\":\"lsp.references\",\"args\":\"proxy.go\",\"status\":\"ok\",\"start_ms\":1,\"duration_ms\":17},{\"cap\":\"fs.read\",\"args\":\"a.go\",\"status\":\"ok\",\"start_ms\":20,\"duration_ms\":2}]}",
    )
    as "the fixture is well-formed JSON"
  calls
}

fn details(
  value: json.JsonValue,
  calls: List(#(String, json.JsonValue)),
) -> Option(json.JsonValue) {
  Some(
    json.Object(list.append(
      [#("status", json.String("completed")), #("value", value)],
      calls,
    )),
  )
}

// The rows the call's block is drawn as once the result is joined to it.
fn settled(result: entry.Entry) -> List(Line) {
  settled_call(call_entry(), result)
}

fn settled_call(call: entry.Entry, result: entry.Entry) -> List(Line) {
  let found = transcript_lines.joined([call, result])
  transcript_lines.joined_entry_lines(
    call,
    None,
    block_summary.new(),
    found,
    None,
  )
}

fn text_of(rows: List(Line), speaker: transcript_line.Speaker) -> String {
  let assert Ok(Line(_, text)) =
    list.find(rows, fn(row) { row.speaker == speaker })
    as "the block is among the rows"
  text
}

pub fn a_settled_program_keeps_its_frame_and_names_its_value_test() {
  let value =
    json.Object([
      #("outline_proxy_go", json.Array([json.Int(1), json.Int(2)])),
      #(
        "hover",
        json.String("func (p *Proxy) Serve(ctx context.Context) error"),
      ),
      #("ok", json.Bool(True)),
      #("extra", json.Int(4)),
    ])
  let rows = settled(result_entry(details(value, [#("calls", record())])))
  assert text_of(rows, ProgramSettled)
    == string.join(
      [
        "✓ code_mode · completed · 6 calls",
        "ran for 90ms",
        "PROGRAM · 7 lines, 4 shown",
        "  1 │ import cap/lsp",
        "  2 │ import cap/fs",
        "  4 │ pub fn main() {",
        "  5 │   let refs = lsp.references(\"proxy.go\")",
        "",
        "CALLS · 6 calls · 0 failed",
        "✓ lsp.references  proxy.go",
        "✓ fs.read         a.go",
        "… 4 more calls",
        "",
        "RESULT · object · 4 keys",
        "  outline_proxy_go: list(2)",
        "  hover: \"func (p *Proxy) Serve(ctx context.Conte…\"",
        "  ok: true",
        "  … 1 more key",
      ],
      "\n",
    )
}

// The running block and the settled one open with the same program rows, so
// the block does not change under the reader when the result arrives.
pub fn the_settled_block_opens_as_the_running_one_does_test() {
  let running =
    transcript_lines.joined_entry_lines(
      call_entry(),
      None,
      block_summary.new(),
      transcript_lines.joined([call_entry()]),
      None,
    )
  let done = settled(result_entry(details(json.Null, [])))
  let opening = fn(rows, speaker) {
    text_of(rows, speaker)
    |> string.split("\n")
    |> list.drop(2)
    |> list.take(5)
  }
  assert opening(running, ProgramRunning) == opening(done, ProgramSettled)
}

pub fn a_list_result_names_its_length_and_first_element_test() {
  let value =
    json.Array([
      json.Object([#("name", json.String("Serve")), #("line", json.Int(9))]),
      json.Object([]),
    ])
  assert transcript_lines.value_preview(value)
    == ["RESULT · list · 2 items", "  first: object(2 keys)"]
  assert transcript_lines.value_preview(json.Array([])) == ["RESULT · []"]
}

pub fn a_scalar_result_is_shown_as_it_is_test() {
  assert transcript_lines.value_preview(json.Int(42)) == ["RESULT · 42"]
  assert transcript_lines.value_preview(json.String("done"))
    == ["RESULT · \"done\""]
  assert transcript_lines.value_preview(json.Object([])) == ["RESULT · {}"]
}

pub fn a_result_with_no_call_record_has_no_calls_section_test() {
  let rows = settled(result_entry(details(json.String("done"), [])))
  let text = text_of(rows, ProgramSettled)
  assert string.starts_with(text, "✓ code_mode · completed\n\nPROGRAM · ")
  assert !string.contains(text, "CALLS")
  assert string.ends_with(text, "\n\nRESULT · \"done\"")
}

pub fn a_result_with_no_value_previews_its_text_test() {
  let bare = Some(json.Object([#("status", json.String("completed"))]))
  let rows = settled(result_entry(bare))
  assert string.ends_with(
    text_of(rows, ProgramSettled),
    "\n\nRESULT · \"the text\"",
  )
}

// Without details the result is not a recorded completion, so the call
// keeps the generic rows it always had.
pub fn a_result_with_no_details_draws_no_block_test() {
  let rows = settled(result_entry(None))
  assert !list.any(rows, fn(row) { row.speaker == ProgramSettled })
}

pub fn the_expanded_view_shows_the_whole_program_above_the_result_test() {
  let value = json.Object([#("ok", json.Bool(True))])
  let call_rows =
    transcript_lines.entry_lines(call_entry(), True, None, block_summary.new())
  let result_rows =
    transcript_lines.entry_lines(
      result_entry(details(value, [#("calls", record())])),
      True,
      None,
      block_summary.new(),
    )
  let assert [Line(ToolCall, "code_mode"), Line(ToolDetail, source)] =
    list.drop(call_rows, list.length(call_rows) - 2)
  assert string.contains(source, "```gleam\nimport cap/lsp")
  assert string.contains(source, "  Ok(refs)\n}")
  let assert [Line(ToolResult, _), Line(ToolDetail, result), ..] = result_rows
  assert string.starts_with(result, "result\n\n```json\n")
}

// A launch carries a program and succeeds with a handle: the program was
// admitted, not run, so the call keeps its generic rows.
pub fn a_successful_launch_draws_no_settled_block_test() {
  let handle = json.Object([#("handle", json.String("job-1"))])
  let launch = call_entry_with([#("mode", json.String("launch"))])
  let rows = settled_call(launch, result_entry(details(handle, [])))
  assert !list.any(rows, fn(row) { row.speaker == ProgramSettled })
  assert !list.any(rows, fn(row) { row.speaker == ProgramRunning })
}

// A text result is shown as text, not as the JSON that escapes it.
pub fn a_text_result_is_quoted_not_json_escaped_test() {
  assert transcript_lines.value_preview(json.String("one\ntwo \"q\""))
    == ["RESULT · \"one two \"q\"\""]
}
