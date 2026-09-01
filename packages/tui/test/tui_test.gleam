import core/json
import core/message
import etui/buffer
import etui/geometry.{Position}
import etui/keys
import etui/span
import etui/style
import etui/widgets/textarea as text_area
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import simplifile
import tui
import tui/agents
import tui/command
import tui/composer
import tui/connection
import tui/image_drop
import tui/internal/ffi_file
import tui/internal/workspace_file
import tui/markdown
import tui/model_selector
import tui/protocol.{ModelInfo, Strand}
import tui/theme
import tui/workspace
import tui_test/ffi_term

pub fn main() {
  gleeunit.main()
}

pub fn prompt_test() {
  assert command.parse("hello") == command.Prompt("hello")
}

pub fn websocket_startup_panic_becomes_an_error_test() {
  let result =
    connection.start_safely(fn() { panic as "dependency initialiser crashed" })

  let assert Error(reason) = result
  assert string.starts_with(reason, "websocket startup crashed:")
}

pub fn websocket_startup_return_is_preserved_test() {
  assert connection.start_safely(fn() { Ok(42) }) == Ok(42)
  assert connection.start_safely(fn() { Error("handshake refused") })
    == Error("handshake refused")
}

pub fn websocket_startup_has_a_bounded_wait_test() {
  let result =
    connection.start_safely_within(
      fn() {
        process.sleep(20)
        Ok(42)
      },
      1,
    )

  assert result == Error("websocket startup timed out")
}

pub fn usage_footer_keeps_input_output_cache_and_cost_visible_test() {
  let usage =
    message.Usage(
      input: 12_345,
      output: 678,
      cache_read: 90_000,
      cache_write: 123,
      cache_write_1h: None,
      reasoning: Some(40),
      total_tokens: 103_146,
      cost: message.UsageCost(0.01, 0.02, 0.003, 0.004, 0.037),
    )

  assert tui.usage_summary(usage) == "in 12k · out 678 · cache 90k/123 · $0.037"
}

pub fn footer_stacks_only_when_all_sections_do_not_fit_test() {
  let project =
    span.line_plain(
      " ~/.codex/worktrees/loom-etui-idle-perf (client/etui-idle-loop) ",
    )
  let usage = span.line_plain(" in 875k · out 54k · cache 5m/0 · $0.0 ")
  let model_name = span.line_plain(" baseten-kimi-k3 ")
  let status = span.line_plain(" 0 live / 3 agents · connected ")
  let needed =
    span.line_width(project)
    + span.line_width(usage)
    + span.line_width(model_name)
    + span.line_width(status)
    + 1

  assert tui.footer_rows(needed, project, model_name, usage, status) == 1
  assert tui.footer_rows(needed - 1, project, model_name, usage, status) == 2
  assert tui.footer_rows(133, project, model_name, usage, status) == 2
  assert tui.footer_rows(40, project, model_name, usage, status) == 3
  assert tui.footer_rows(180, project, model_name, usage, status) == 1
  assert tui.transcript_height(40, 3, 2) == 32
  assert tui.transcript_height(40, 3, 3) == 31
  assert tui.transcript_height(40, 3, 1) == 33
  assert tui.viewport_height_changed(
    tui.transcript_height(40, 3, 2),
    tui.transcript_height(40, 3, 1),
  )
}

pub fn workspace_path_abbreviates_macos_and_linux_homes_test() {
  assert workspace.path_label("/Users/alice/gocode/src/repo")
    == "~/gocode/src/repo"
  assert workspace.path_label("/home/alice/gocode/src/repo")
    == "~/gocode/src/repo"
  assert workspace.path_label("/srv/loom") == "/srv/loom"
}

pub fn workspace_branch_decodes_symbolic_and_detached_heads_test() {
  assert workspace.branch_from_head("ref: refs/heads/client/footer\n")
    == Some("client/footer")
  assert workspace.branch_from_head(
      "0123456789abcdef0123456789abcdef01234567\n",
    )
    == Some("01234567")
  assert workspace.branch_from_head("not-a-commit\n") == None
  assert workspace.branch_from_head("ref: refs/heads/unsafe\nname\n") == None
  assert workspace.branch_from_head("\n") == None
}

pub fn workspace_metadata_read_is_descriptor_bounded_test() {
  let path = "build/tui-workspace-metadata.txt"
  let assert Ok(Nil) =
    simplifile.write_bits(to: path, bits: <<"thirteen bytes":utf8>>)
  let oversized = workspace_file.read_small_regular(path, 12)
  let exact = workspace_file.read_small_regular(path, 14)
  let _ = simplifile.delete(path)

  assert oversized == Error(Nil)
  let assert Ok(contents) = exact
  assert bit_array.to_string(contents) == Ok("thirteen bytes")
}

pub fn footer_status_preserves_transient_operator_feedback_test() {
  assert tui.footer_status("0 live / 3 agents", "queued after main")
    == "0 live / 3 agents · queued after main"
}

pub fn footer_status_sanitizes_untrusted_server_text_test() {
  assert tui.footer_status("0 live", "\u{1b}[31mhostile\nnotice")
    == "0 live · hostile notice"
}

pub fn footer_status_omits_the_dedicated_model_label_test() {
  assert tui.footer_status("0 live / 3 agents", "model: baseten-kimi-k3")
    == "0 live / 3 agents"
}

pub fn active_indicator_advances_at_a_readable_cadence_test() {
  assert tui.activity_glyph(0) == "◐"
  assert tui.activity_glyph(3) == "◓"
  assert tui.activity_glyph(6) == "◑"
  assert tui.activity_glyph(9) == "◒"
  assert tui.activity_glyph(12) == "◐"
}

pub fn cached_frame_reuses_the_exact_buffer_term_test() {
  let screen = geometry.rect_new(0, 0, 8, 2)
  let cached_buffer = buffer.buffer_new(screen)
  let cached = #(cached_buffer, Ok(Position(2, 1)))
  let #(reused, cursor) =
    tui.cached_frame(cached, screen, 7, screen, 7, fn() {
      panic as "a matching frame cache must not rebuild"
    })

  assert ffi_term.same_term(cached_buffer, reused)
  assert cursor == Ok(Position(2, 1))
}

pub fn cached_frame_rebuilds_after_visible_revisions_test() {
  let screen = geometry.rect_new(0, 0, 8, 2)
  let cached_buffer = buffer.buffer_new(screen)
  let cached = #(cached_buffer, Error(Nil))
  let changes = [
    "transcript",
    "input and cursor",
    "overlay",
    "status",
    "activity indicator",
  ]

  list.each(changes, fn(label) {
    let replacement =
      buffer.set_string(
        buffer.buffer_new(screen),
        Position(0, 0),
        label,
        style.new(style.Default, style.Default, style.none()),
      )
    let #(rebuilt, _) =
      tui.cached_frame(cached, screen, 7, screen, 8, fn() {
        #(replacement, Error(Nil))
      })
    assert ffi_term.same_term(replacement, rebuilt)
    assert !ffi_term.same_term(cached_buffer, rebuilt)
  })
}

pub fn cached_frame_rebuilds_for_resize_test() {
  let before = geometry.rect_new(0, 0, 8, 2)
  let after = geometry.rect_new(0, 0, 9, 2)
  let cached_buffer = buffer.buffer_new(before)
  let replacement = buffer.buffer_new(after)
  let #(rebuilt, cursor) =
    tui.cached_frame(
      #(cached_buffer, Ok(Position(1, 1))),
      before,
      4,
      after,
      4,
      fn() { #(replacement, Ok(Position(1, 1))) },
    )

  assert ffi_term.same_term(replacement, rebuilt)
  assert cursor == Ok(Position(1, 1))
}

pub fn cached_frame_rebuilds_for_cursor_revision_test() {
  let screen = geometry.rect_new(0, 0, 8, 2)
  let cached_buffer = buffer.buffer_new(screen)
  let replacement = buffer.buffer_new(screen)
  let #(rebuilt, cursor) =
    tui.cached_frame(
      #(cached_buffer, Ok(Position(1, 1))),
      screen,
      4,
      screen,
      5,
      fn() { #(replacement, Ok(Position(3, 1))) },
    )

  assert ffi_term.same_term(replacement, rebuilt)
  assert !ffi_term.same_term(cached_buffer, rebuilt)
  assert cursor == Ok(Position(3, 1))
}

pub fn adaptive_poll_enters_quiet_only_after_hysteresis_test() {
  assert tui.poll_timeout_for(0) == 40
  assert tui.poll_timeout_for(319) == 40
  assert tui.poll_timeout_for(320) == 400

  let after_seven_ticks =
    [1, 2, 3, 4, 5, 6, 7]
    |> list.fold(0, fn(quiet_for, _) {
      tui.next_quiet_for(quiet_for, 40, False)
    })
  assert after_seven_ticks == 280
  assert tui.poll_timeout_for(after_seven_ticks) == 40
  let quiet = tui.next_quiet_for(after_seven_ticks, 40, False)
  assert quiet == 320
  assert tui.poll_timeout_for(quiet) == 400
}

pub fn adaptive_poll_activity_immediately_restores_fast_cadence_test() {
  let reset = tui.next_quiet_for(320, 400, True)
  assert reset == 0
  assert tui.poll_timeout_for(reset) == 40
}

pub fn slash_command_palette_filters_and_completes_test() {
  let suggestions = command.suggestions("/str")
  assert suggestions
    == [
      command.Suggestion("/strands", "list session strands", False),
      command.Suggestion("/strand", "switch the active strand", True),
    ]
  assert command.selected(suggestions, 1) == Some("/strand ")
  assert command.suggestions("ordinary prompt") == []
  assert command.suggestions("/strand main") == []
  assert tui.command_palette_escape(keys.Escape)
  assert !tui.command_palette_escape(keys.Char("x"))
}

pub fn models_test() {
  assert command.parse("/models") == command.Models
  assert command.parse("/model") == command.Models
}

pub fn agents_test() {
  assert command.parse("/agents") == command.Agents
}

pub fn agent_inspector_selection_wraps_and_resolves_a_strand_test() {
  let strands = [
    Strand("main", Some("main"), None),
    Strand("sub:review", Some("review"), Some("assistant")),
  ]

  assert agents.move_selection(0, 2, False) == 1
  assert agents.move_selection(1, 2, True) == 0
  assert agents.selected_strand(strands, 1) == Some("sub:review")
  assert agents.selected_strand(strands, 2) == None

  let long = [
    Strand("0", None, None),
    Strand("1", None, None),
    Strand("2", None, None),
    Strand("3", None, None),
    Strand("4", None, None),
    Strand("5", None, None),
    Strand("6", None, None),
  ]
  let #(visible, offset) = agents.selection_window(long, 6, 3)
  assert offset == 4
  assert agents.selected_strand(visible, 2) == Some("6")
}

pub fn notes_test() {
  assert command.parse("/notes") == command.Notes
}

pub fn details_test() {
  assert command.parse("/details") == command.Details
}

pub fn steer_and_queue_commands_test() {
  assert command.parse("/steer use the new constraint")
    == command.Steer("use the new constraint")
  assert command.parse("/queue review the result")
    == command.Queue("review the result")
  assert command.parse("/queue") == command.MissingArgument("queue")
}

pub fn steer_and_follow_up_frames_test() {
  assert protocol.steer(7, "main", "now")
    == "{\"v\":1,\"id\":7,\"cmd\":\"steer\",\"body\":{\"strand\":\"main\",\"text\":\"now\"}}"
  assert protocol.follow_up(8, "main", "later")
    == "{\"v\":1,\"id\":8,\"cmd\":\"follow_up\",\"body\":{\"strand\":\"main\",\"text\":\"later\"}}"
}

pub fn config_readback_frame_test() {
  assert protocol.config(6, "main")
    == "{\"v\":1,\"id\":6,\"cmd\":\"set_config\",\"body\":{\"strand\":\"main\",\"config\":{}}}"
}

pub fn model_argument_test() {
  assert command.parse(" /model baseten-kimi-k3 ")
    == command.Model("baseten-kimi-k3")
}

pub fn missing_argument_test() {
  assert command.parse("/fork") == command.MissingArgument("fork")
}

pub fn unknown_command_test() {
  assert command.parse("/dance now") == command.Unknown("dance")
}

pub fn model_selector_accepts_initials_test() {
  let models = [
    ModelInfo("baseten-kimi-k3", "openai", "moonshotai/Kimi-K3", [], ["main"]),
    ModelInfo(
      "baseten-glm-5-3-flash",
      "openai",
      "zai-org/GLM-5.3-Flash",
      [],
      [],
    ),
  ]
  let state = model_selector.State(models:, query: "glm53f", selected: 0)
  assert model_selector.update(keys.Enter, state)
    == model_selector.Choose("baseten-glm-5-3-flash")
  let assert model_selector.Continue(next) =
    model_selector.update(keys.Down, state)
  assert model_selector.update(keys.Enter, next)
    == model_selector.Choose("baseten-glm-5-3-flash")
}

pub fn transcript_scroll_clamps_at_the_live_tail_test() {
  assert tui.scroll_offset(12, True, 3) == 15
  assert tui.scroll_offset(12, False, 3) == 9
  assert tui.scroll_offset(2, False, 3) == 0
}

pub fn transcript_scroll_clamps_at_the_oldest_viewport_test() {
  assert tui.bounded_scroll_offset(80, 50, 20) == 30
  assert tui.bounded_scroll_offset(3, 10, 20) == 0
  assert tui.viewport_height_changed(18, 21)
  assert !tui.viewport_height_changed(21, 21)
}

pub fn streaming_output_preserves_the_scrollback_anchor_test() {
  assert tui.anchored_scroll_offset(0, 20, 23) == 0
  assert tui.anchored_scroll_offset(8, 20, 23) == 11
  assert tui.anchored_scroll_offset(2, 20, 17) == 0
}

pub fn prompt_history_restores_the_unsent_draft_test() {
  let history = ["newest", "older"]
  let #(index, draft, value) =
    tui.history_selection(history, 0, "", "unsent draft", True)
  assert #(index, draft, value) == #(1, "unsent draft", "newest")

  let #(index, draft, value) =
    tui.history_selection(history, index, draft, value, True)
  assert #(index, draft, value) == #(2, "unsent draft", "older")

  let #(index, draft, value) =
    tui.history_selection(history, index, draft, value, False)
  assert #(index, draft, value) == #(1, "unsent draft", "newest")

  assert tui.history_selection(history, index, draft, value, False)
    == #(0, "unsent draft", "unsent draft")
}

pub fn large_paste_becomes_a_compact_attachment_test() {
  let text = string.repeat("x", 2000)

  assert composer.classify(text)
    == composer.Compact(composer.Attachment(text:, estimated_tokens: 500))
  assert composer.summary([
      composer.Attachment(text:, estimated_tokens: 500),
    ])
    == Some("pasted ~500 tokens")
}

pub fn line_heavy_paste_becomes_a_compact_attachment_test() {
  let text = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight"

  let assert composer.Compact(_) = composer.classify(text)
}

pub fn compact_paste_expands_without_changing_its_bytes_test() {
  let pasted = "first\nsecond\nthird"
  let attachments = [composer.Attachment(pasted, 5)]

  assert composer.expand("summarize this", attachments)
    == "summarize this\n\nfirst\nsecond\nthird"
  assert composer.expand("", attachments) == pasted
}

pub fn compact_user_turn_is_reversible_in_detail_mode_test() {
  let text = string.repeat("four", 500)
  let collapsed = composer.transcript_text(text, False)

  assert string.contains(collapsed, "[~500 tokens · Ctrl+G to expand]")
  assert string.length(collapsed) < string.length(text)
  assert composer.transcript_text(text, True) == text
}

pub fn backspace_drops_only_the_newest_paste_test() {
  let first = composer.Attachment("first", 2)
  let second = composer.Attachment("second", 2)

  assert composer.drop_last([first, second]) == [first]
  assert composer.drop_last([]) == []
}

pub fn dropped_path_parsing_never_performs_shell_expansion_test() {
  assert image_drop.pasted_path("/tmp/one\\ two.png")
    == Some("/tmp/one two.png")
  assert image_drop.pasted_path("'/tmp/one two.png'")
    == Some("/tmp/one two.png")
  assert image_drop.pasted_path("/tmp/one.png /tmp/two.png") == None
  assert image_drop.pasted_path("$(touch /tmp/never)") == None
}

pub fn image_magic_and_size_admission_test() {
  assert image_drop.media_type(<<
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    >>)
    == Some("image/png")
  assert image_drop.media_type(<<0xFF, 0xD8, 0xFF>>) == Some("image/jpeg")
  assert image_drop.media_type(<<"GIF89a":utf8>>) == Some("image/gif")
  assert image_drop.media_type(<<"RIFF":utf8, 0:32, "WEBP":utf8>>)
    == Some("image/webp")
  assert image_drop.media_type(<<"not an image":utf8>>) == None
  assert image_drop.size_allowed(image_drop.max_image_bytes)
  assert !image_drop.size_allowed(image_drop.max_image_bytes + 1)
}

pub fn supported_image_paste_keeps_path_out_of_the_wire_block_test() {
  let path = "build/tui-golden-drop.png"
  let bytes = <<
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x01,
  >>
  let assert Ok(Nil) = simplifile.write_bits(to: path, bits: bytes)
  let assert Ok(Some(image)) = image_drop.load_paste(path)
  let _ = simplifile.delete(path)
  let image_drop.Image(filename:, mime_type:, byte_size:, data:, ..) = image
  assert filename == "tui-golden-drop.png"
  assert mime_type == "image/png"
  assert byte_size == bit_array.byte_size(bytes)
  let content = tui.image_prompt_content("inspect this", [image])
  assert content
    == [
      message.UserText("inspect this", None),
      message.UserImage(data, mime_type),
    ]
  let frame = protocol.prompt_content(18, "main", content)
  assert !string.contains(frame, path)
  assert frame
    == "{\"v\":1,\"id\":18,\"cmd\":\"prompt_content\",\"body\":{\"strand\":\"main\",\"content\":[{\"type\":\"text\",\"text\":\"inspect this\"},{\"type\":\"image\",\"data\":\"iVBORw0KGgoB\",\"mimeType\":\"image/png\"}]}}"
}

pub fn unsupported_regular_file_stays_ordinary_text_test() {
  let path = "build/tui-golden-drop.txt"
  let assert Ok(Nil) =
    simplifile.write_bits(to: path, bits: <<"ordinary text":utf8>>)
  let result = image_drop.load_paste(path)
  let _ = simplifile.delete(path)

  assert result == Ok(None)
}

pub fn bounded_image_read_refuses_growth_past_the_limit_test() {
  let path = "build/tui-bounded-drop.bin"
  let assert Ok(Nil) =
    simplifile.write_bits(to: path, bits: <<"thirteen bytes":utf8>>)
  let result = ffi_file.read_bounded(path, 12)
  let _ = simplifile.delete(path)

  assert result == Error("file exceeds the bounded read limit")
}

pub fn file_read_worker_has_a_bounded_wait_test() {
  let result =
    ffi_file.read_safely_within(
      fn() {
        process.sleep(20)
        Ok(<<>>)
      },
      1,
    )

  assert result == Error("file read timed out")
}

pub fn image_attachment_summary_sanitizes_the_filename_test() {
  let image =
    test_image("\u{1b}]0;spoof\u{7}\u{1b}[31mred.png\u{1b}[0m\nnext", 1)

  assert composer.summary([composer.ImageAttachment(image)])
    == Some("red.png next · image/png · 1 B")
}

pub fn image_attachment_layout_measures_terminal_cells_test() {
  assert tui.attachment_width("界.png", 20) == 9
  assert tui.attachment_width("界.png", 8) == 6
}

pub fn image_attachments_have_count_and_aggregate_byte_limits_test() {
  let assert Ok(one) =
    composer.admit_attachment([], composer.ImageAttachment(test_image("1", 1)))
  let assert Ok(two) =
    composer.admit_attachment(one, composer.ImageAttachment(test_image("2", 1)))
  let assert Ok(three) =
    composer.admit_attachment(two, composer.ImageAttachment(test_image("3", 1)))
  let assert Ok(four) =
    composer.admit_attachment(
      three,
      composer.ImageAttachment(test_image("4", 1)),
    )

  assert composer.admit_attachment(
      four,
      composer.ImageAttachment(test_image("5", 1)),
    )
    == Error("a prompt may attach at most four images")

  let full =
    composer.ImageAttachment(test_image(
      "full",
      composer.max_image_attachment_bytes,
    ))
  let assert Ok(at_limit) = composer.admit_attachment([], full)
  assert composer.admit_attachment(
      at_limit,
      composer.ImageAttachment(test_image("overflow", 1)),
    )
    == Error("a prompt may attach at most 20 MiB of images")
}

pub fn image_attachments_keep_drop_order_and_remove_the_newest_test() {
  let first =
    image_drop.Image(
      local_path: "/tmp/a.png",
      filename: "a.png",
      mime_type: "image/png",
      byte_size: 1,
      data: "YQ==",
    )
  let second =
    image_drop.Image(
      local_path: "/tmp/b.jpg",
      filename: "b.jpg",
      mime_type: "image/jpeg",
      byte_size: 1,
      data: "Yg==",
    )
  let attachments = [
    composer.ImageAttachment(first),
    composer.ImageAttachment(second),
  ]

  assert composer.images(attachments) == [first, second]
  assert composer.drop_last(attachments) == [composer.ImageAttachment(first)]
  assert composer.summary(attachments)
    == Some("a.png image/png 1 B · b.jpg image/jpeg 1 B")
  assert tui.image_prompt_content("", composer.images(attachments))
    == [
      message.UserImage("YQ==", "image/png"),
      message.UserImage("Yg==", "image/jpeg"),
    ]
}

fn test_image(filename: String, byte_size: Int) -> image_drop.Image {
  image_drop.Image(
    local_path: "/tmp/" <> filename,
    filename:,
    mime_type: "image/png",
    byte_size:,
    data: "YQ==",
  )
}

pub fn image_submission_is_refused_while_the_strand_is_live_test() {
  assert tui.image_prompt_allowed(False)
  assert !tui.image_prompt_allowed(True)
}

pub fn code_mode_program_renders_as_gleam_test() {
  let arguments =
    json.Object([
      #(
        "program",
        json.String(
          "import cap/report\n\npub fn main() {\n  report.text(\"live\")\n}",
        ),
      ),
    ])

  assert tui.code_mode_program("code_mode", arguments, False)
    == Some(
      "```gleam\nimport cap/report\n\npub fn main() {\n  report.text(\"live\")\n}\n```",
    )
}

pub fn code_mode_program_preview_is_bounded_test() {
  let arguments =
    json.Object([
      #(
        "program",
        json.String(
          "line-01\nline-02\nline-03\nline-04\nline-05\nline-06\nline-07\nline-08\nline-09\nline-10\nline-11\nline-12\nline-13",
        ),
      ),
    ])
  let assert Some(collapsed) =
    tui.code_mode_program("code_mode", arguments, False)
  let assert Some(expanded) =
    tui.code_mode_program("code_mode", arguments, True)

  assert !string.contains(collapsed, "line-13")
  assert string.contains(collapsed, "// …")
  assert string.contains(expanded, "line-13")
}

pub fn bash_tool_call_shows_the_command_not_its_json_envelope_test() {
  let arguments =
    json.Object([#("command", json.String("gleam test --target erlang"))])

  assert tui.tool_call_summary("bash", arguments, False)
    == "Bash(gleam test --target erlang)"
  assert tui.tool_call_summary("bash", arguments, True)
    == "Bash($ gleam test --target erlang)"
}

pub fn live_tool_call_hides_partial_json_arguments_test() {
  assert tui.live_tool_call_summary("bash") == "bash · preparing arguments…"
}

pub fn markdown_diff_lines_have_distinct_styles_test() {
  let assert [
    _,
    span.Line(spans: [_, span.Span(style: removed, ..)], ..),
    span.Line(spans: [_, span.Span(style: added, ..)], ..),
    ..
  ] = markdown.render("```diff\n-old\n+new\n```")

  assert removed == theme.diff_removed()
  assert added == theme.diff_added()
}

pub fn modal_quiet_style_does_not_dim_its_background_test() {
  let style.Style(modifier:, bg:, ..) = theme.overlay_quiet()
  assert style.is_none(modifier)
  assert bg == theme.graphite
}

pub fn injected_agent_notes_are_recognized_as_machine_context_test() {
  let value =
    message.UserMessage(
      content: [
        message.UserText(
          text: "Your own notes for strand `main`, newest first — quoted.\n```agent-notes\nperf/cache = true\n```",
          text_signature: None,
        ),
      ],
      timestamp: 1,
    )

  assert tui.agent_notes_payload(value) == Some("perf/cache = true")
}

pub fn ordinary_user_text_is_not_mistaken_for_agent_notes_test() {
  let value =
    message.UserMessage(
      content: [message.UserText(text: "show my notes", text_signature: None)],
      timestamp: 1,
    )

  assert tui.agent_notes_payload(value) == None
}

pub fn long_prompt_wraps_without_changing_its_source_test() {
  let source = "check out the current diff and explain the remaining work"
  let state = text_area.state_from_string(source)
  let view = tui.input_view_state(state, 12)

  assert text_area.value(state) == source
  assert view.lines
    == [
      "check out th",
      "e current di",
      "ff and expla",
      "in the remai",
      "ning work",
    ]
  assert view.cursor_y == 4
  assert view.cursor_x == 9
}

pub fn prompt_cursor_moves_to_the_next_visual_row_at_a_wrap_boundary_test() {
  let state = text_area.state_from_string("abcdefghijkl")
  let view = tui.input_view_state(state, 12)

  assert view.lines == ["abcdefghijkl", ""]
  assert view.cursor_y == 1
  assert view.cursor_x == 0
}

pub fn prompt_wrap_uses_terminal_cells_for_wide_graphemes_test() {
  let state = text_area.state_from_string("ab界cd")
  let view = tui.input_view_state(state, 4)

  assert view.lines == ["ab界", "cd"]
  assert view.cursor_y == 1
  assert view.cursor_x == 2
}
