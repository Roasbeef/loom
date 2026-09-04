import core/json
import core/message
import etui/backend
import etui/buffer
import etui/geometry.{Position}
import etui/keys
import etui/span
import etui/style
import etui/widgets/block
import etui/widgets/textarea as text_area
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import simplifile
import snapshot_test
import tui
import tui/agents
import tui/bootstrap
import tui/command
import tui/composer
import tui/connection
import tui/frame
import tui/image_drop
import tui/internal/ffi_file
import tui/internal/workspace_file
import tui/markdown
import tui/model_selector
import tui/protocol.{ModelInfo, Strand}
import tui/recording
import tui/sessions
import tui/text_hygiene
import tui/theme
import tui/virtual_backend
import tui/workspace
import tui_test/ffi_term
import tui_test/gateway

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

pub fn elapsed_label_reads_like_a_clock_test() {
  assert tui.elapsed_label(0) == ""
  assert tui.elapsed_label(1) == " (1s)"
  assert tui.elapsed_label(59) == " (59s)"
  assert tui.elapsed_label(60) == " (1m 00s)"
  assert tui.elapsed_label(65) == " (1m 05s)"
  assert tui.elapsed_label(754) == " (12m 34s)"
}

pub fn output_rate_is_tokens_over_streamed_seconds_test() {
  assert tui.output_rate(300, 2000) == Some(150)
  assert tui.output_rate(7, 1000) == Some(7)
  // A window under a second is no rate: a whole-part provider can land
  // a short reply as one burst, and 126 tokens over one millisecond
  // once showed as 126000 tok/s.
  assert tui.output_rate(126, 1) == None
  assert tui.output_rate(300, tui.output_rate_min_ms - 1) == None
  assert tui.output_rate(300, 0) == None
  assert tui.output_rate_label(Some(87)) == " · 87 tok/s"
  assert tui.output_rate_label(None) == ""
}

pub fn footer_rows_depend_on_the_width_alone_test() {
  // The thresholds are the sections' fixed caps summed, so the row count
  // is a property of the window and cannot move while a turn runs. A
  // 133-column pane is always two rows; a 200-column one is always one.
  assert tui.footer_rows(201) == 1
  assert tui.footer_rows(200) == 2
  assert tui.footer_rows(133) == 2
  assert tui.footer_rows(100) == 2
  assert tui.footer_rows(99) == 3
  assert tui.footer_rows(40) == 3
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
    tui.cached_frame(cached, screen, screen, fn() {
      panic as "a matching frame cache must not rebuild"
    })

  assert ffi_term.same_term(cached_buffer, reused)
  assert cursor == Ok(Position(2, 1))
}

pub fn cached_frame_keeps_a_deferred_frame_on_screen_test() {
  // A frame left stale to pace a burst must reach etui as the exact cached
  // term: the view rebuilding it would both undo the deferral and diff a
  // frame nobody stored. Visible revisions are settled when the event is
  // handled, which `frame_decision` pins.
  let screen = geometry.rect_new(0, 0, 8, 2)
  let cached_buffer = buffer.buffer_new(screen)
  let cached = #(cached_buffer, Error(Nil))
  let #(shown, _) =
    tui.cached_frame(cached, screen, screen, fn() {
      panic as "a deferred frame must not be rebuilt by the view"
    })
  assert ffi_term.same_term(cached_buffer, shown)
}

pub fn frame_decision_keeps_a_current_cache_test() {
  assert tui.frame_decision(tui.Paced, tui.FrameCurrent, 0)
    == tui.KeepCachedFrame
  assert tui.frame_decision(tui.FlushPoint, tui.FrameCurrent, 1000)
    == tui.KeepCachedFrame
}

pub fn frame_decision_paces_a_burst_test() {
  // Inside the interval a stale frame waits; at or past it, it renders. A
  // wheel flick decoded from one read therefore costs one frame per interval
  // rather than one per event.
  assert tui.frame_decision(tui.Paced, tui.FrameStale, 0) == tui.DeferFrame
  assert tui.frame_decision(tui.Paced, tui.FrameStale, 15) == tui.DeferFrame
  assert tui.frame_decision(tui.Paced, tui.FrameStale, 16) == tui.RenderFrame
  assert tui.frame_decision(tui.Paced, tui.FrameStale, 400) == tui.RenderFrame
}

pub fn frame_decision_flushes_at_a_tick_or_resize_test() {
  // The tick that follows a drained queue renders whatever was deferred, no
  // matter how recently the previous frame was drawn.
  assert tui.frame_decision(tui.FlushPoint, tui.FrameStale, 0)
    == tui.RenderFrame
  assert tui.frame_decision(tui.FlushPoint, tui.FrameStale, 3)
    == tui.RenderFrame
}

pub fn paced_poll_timeout_shortens_the_wait_for_a_deferred_frame_test() {
  assert tui.paced_poll_timeout(tui.FrameDeferred, 0) == 8
  assert tui.paced_poll_timeout(tui.FrameDeferred, 320) == 8
  assert tui.paced_poll_timeout(tui.FrameSettled, 0) == 40
  assert tui.paced_poll_timeout(tui.FrameSettled, 320) == 400
}

pub fn panel_inner_trims_the_border_test() {
  assert tui.panel_inner(geometry.rect_new(0, 1, 10, 5))
    == geometry.rect_new(1, 2, 8, 3)
  assert tui.panel_inner(geometry.rect_new(0, 0, 1, 1))
    == geometry.rect_new(1, 1, 0, 0)
}

pub fn panel_border_matches_the_block_it_replaces_test() {
  // The border-only draw must put the same bytes on the wire as etui's block
  // over a blank canvas; only the interior clear is gone.
  let cases = [
    #(geometry.rect_new(0, 0, 12, 4), " transcript / main "),
    #(geometry.rect_new(2, 1, 30, 6), " transcript / main "),
    #(geometry.rect_new(0, 0, 8, 3), " a much longer title than fits "),
    #(geometry.rect_new(0, 0, 2, 2), ""),
  ]
  list.each(cases, fn(case_) {
    let #(area, title) = case_
    let screen = geometry.rect_new(0, 0, 32, 8)
    let expected =
      block.block_new()
      |> block.with_border(block.Rounded)
      |> block.with_colors(theme.quiet, style.Default)
      |> block.with_title(title, block.Top)
      |> block.render(buffer.buffer_new(screen), area, _)
    let actual =
      buffer.buffer_new(screen)
      |> tui.render_panel_border(area, title, theme.quiet)
    assert buffer.to_ansi(actual) == buffer.to_ansi(expected)
  })
}

pub fn panel_border_preserves_prepainted_interior_test() {
  let screen = geometry.rect_new(0, 0, 12, 4)
  let inside = Position(3, 2)
  let painted =
    buffer.buffer_new(screen)
    |> buffer.set_string(inside, "kept", theme.current_bold())
  let drawn =
    tui.render_panel_border(painted, screen, " transcript ", theme.quiet)

  // The border renderer must leave both the content and style untouched.
  assert buffer.get_cell(drawn, inside) == buffer.get_cell(painted, inside)
}

pub fn panel_border_draws_nothing_when_too_small_test() {
  let screen = geometry.rect_new(0, 0, 4, 4)
  let blank = buffer.buffer_new(screen)
  let drawn =
    tui.render_panel_border(
      blank,
      geometry.rect_new(0, 0, 1, 3),
      "t",
      theme.quiet,
    )
  assert ffi_term.same_term(blank, drawn)
}

pub fn cached_frame_rebuilds_for_resize_test() {
  let before = geometry.rect_new(0, 0, 8, 2)
  let after = geometry.rect_new(0, 0, 9, 2)
  let cached_buffer = buffer.buffer_new(before)
  let replacement = buffer.buffer_new(after)
  let #(rebuilt, cursor) =
    tui.cached_frame(#(cached_buffer, Ok(Position(1, 1))), before, after, fn() {
      #(replacement, Ok(Position(1, 1)))
    })

  assert ffi_term.same_term(replacement, rebuilt)
  assert cursor == Ok(Position(1, 1))
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
  // A closed argument vocabulary keeps the palette open past the space.
  assert list.map(command.suggestions("/effort "), fn(s) { s.command })
    == [
      "/effort off", "/effort minimal", "/effort low", "/effort medium",
      "/effort high", "/effort xhigh", "/effort max",
    ]
  assert list.map(command.suggestions("/effort hi"), fn(s) { s.command })
    == ["/effort high"]
  assert command.suggestions("/effort nope") == []
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

/// The operator's schedule surface: a listing with no argument, and a
/// cancellation whose target defaults to the strand being watched.
pub fn schedule_commands_test() {
  assert command.parse("/schedules") == command.Schedules
  assert command.parse("/unschedule poll")
    == command.Unschedule(name: "poll", target: None)
  assert command.parse("/unschedule poll sub:main/x")
    == command.Unschedule(name: "poll", target: Some("sub:main/x"))
  assert command.parse("/unschedule") == command.MissingArgument("unschedule")
  assert command.suggestions("/unsch")
    == [command.Suggestion("/unschedule", "retire one schedule", True)]
}

pub fn schedule_frames_test() {
  assert protocol.schedules(10)
    == "{\"v\":1,\"id\":10,\"cmd\":\"schedules\",\"body\":{}}"
  assert protocol.schedule_cancel(11, "main", "heartbeat")
    == "{\"v\":1,\"id\":11,\"cmd\":\"schedule_cancel\",\"body\":"
    <> "{\"target\":\"main\",\"name\":\"heartbeat\"}}"
}

/// The fixture the server's own conformance corpus pins, decoded by the
/// client's total decoder: the two implementations are kept compatible
/// by these bytes rather than by discipline. The wake flag is the wire's
/// one boolean and becomes two variants here, so a polarity flip would
/// fail this rather than mislead an operator.
pub fn schedules_snapshot_decodes_the_pinned_fixture_test() {
  let frame =
    "{\"v\":1,\"reply_to\":19,\"event\":\"snapshot\",\"body\":"
    <> "{\"mode\":\"schedules\",\"schedules\":["
    <> "{\"name\":\"nightly\",\"target\":\"main\",\"owner\":\"operator\","
    <> "\"when\":\"every 3600s, at most 24 times\",\"wake\":true,"
    <> "\"fired\":7,\"body\":\"summarize what changed today\"},"
    <> "{\"name\":\"heartbeat\",\"target\":\"sub:main/reviewer-abc123\","
    <> "\"owner\":\"main\",\"when\":\"every 300s, at most 20 times\","
    <> "\"wake\":false,\"fired\":2,"
    <> "\"body\":\"report where the review has got to\"}]}}"
  assert protocol.decode_event(frame)
    == Ok(
      protocol.SchedulesSnapshot(schedules: [
        protocol.ScheduleRow(
          name: "nightly",
          target: "main",
          owner: "operator",
          when: "every 3600s, at most 24 times",
          wake: protocol.WakesIdle,
          fired: 7,
          body: "summarize what changed today",
        ),
        protocol.ScheduleRow(
          name: "heartbeat",
          target: "sub:main/reviewer-abc123",
          owner: "main",
          when: "every 300s, at most 20 times",
          wake: protocol.SteersOnly,
          fired: 2,
          body: "report where the review has got to",
        ),
      ]),
    )

  // A `wake` of the wrong type is a refused body, not a defaulted one.
  let assert Error(reason) =
    protocol.decode_event(
      "{\"v\":1,\"event\":\"snapshot\",\"body\":{\"mode\":\"schedules\","
      <> "\"schedules\":[{\"name\":\"n\",\"target\":\"main\","
      <> "\"owner\":\"main\",\"when\":\"once\",\"wake\":1,"
      <> "\"fired\":0,\"body\":\"b\"}]}}",
    )
  assert reason == "wake must be a boolean"
}

pub fn sessions_command_opens_a_selectable_local_catalogue_test() {
  assert command.parse("/sessions") == command.Sessions
  assert command.suggestions("/sess")
    == [command.Suggestion("/sessions", "switch local sessions", False)]

  let first = bootstrap.SessionChoice("alpha", "/work/alpha", "/state/a.db")
  let second = bootstrap.SessionChoice("beta", "/work/beta", "/state/b.db")
  let state = sessions.new([first, second], "/state/b.db")
  assert state.selected == 1
  let assert sessions.Continue(wrapped) = sessions.update(keys.Down, state)
    as "Down keeps the selector open"
  assert wrapped.selected == 0
  assert sessions.update(keys.Enter, wrapped) == sessions.Choose(first)
}

pub fn session_selector_paths_keep_their_tails_test() {
  assert text_hygiene.fit_tail("/home/me/work/project", 10) == "…k/project"
  assert text_hygiene.fit_tail("/short", 10) == "/short"
  assert text_hygiene.fit_tail("/short", 6) == "/short"
  assert text_hygiene.fit_tail("/short", 0) == ""
  assert text_hygiene.fit_tail("/short", 1) == "…"
}

pub fn session_selector_uses_database_identity_test() {
  let first =
    bootstrap.SessionChoice("review", "/work/project", "/state/review.db")
  let second =
    bootstrap.SessionChoice(
      "review",
      "/work/project",
      "/state/review.archive.db",
    )
  let state = sessions.new([first, second], "/state/review.archive.db")
  assert state.selected == 1
}

pub fn queued_session_result_wins_over_timeout_test() {
  let status =
    sessions.start_with(
      "queued",
      fn(_frames) { Error("arrived before timeout") },
      within: 5000,
    )
  assert wait_for_switch(status, 5000)
    == Ok(sessions.Failed("queued", "arrived before timeout"))
}

pub fn session_attempts_have_isolated_mailboxes_test() {
  let stale =
    sessions.start_with(
      "stale",
      fn(_frames) { Error("stale result") },
      within: 5000,
    )
  let assert Ok(sessions.Failed("stale", "stale result")) =
    wait_for_switch(stale, 5000)
  let current =
    sessions.start_with(
      "new",
      fn(_frames) {
        process.sleep(5000)
        Error("never")
      },
      within: 5000,
    )
  assert sessions.receive(current) == Error(Nil)
  sessions.cancel(current)
}

// A subject delivers to the process that created it, and receiving on one
// owned by another process panics. The frame inbox a replacement socket writes
// to must therefore belong to the terminal from the moment the attempt starts,
// not to the task that opens the socket.
pub fn session_switch_frames_are_owned_by_the_terminal_test() {
  let root = "build/tui-session-frames"
  let choice =
    bootstrap.SessionChoice(
      "missing",
      root <> "/missing-workspace",
      root <> "/missing.db",
    )
  let options =
    bootstrap.Options(
      workspace: choice.workspace,
      session_file: choice.session_file,
      server: root <> "/no-such-loomd",
      state_directory: root <> "/state",
      config: "",
    )
  let status = sessions.start(choice, options)
  let assert sessions.Resolving(frames:, ..) = status
    as "start should return an in-flight attempt"
  assert process.subject_owner(frames) == Ok(process.self())
  assert connection.receive(frames) == Error(Nil)
  let assert Ok(sessions.Failed("missing", _)) = wait_for_switch(status, 5000)
    as "a missing workspace should fail resolution"
  let _ = simplifile.delete(root)
}

pub fn failed_session_attempt_discards_queued_frames_test() {
  let status =
    sessions.start_with(
      "failed",
      fn(frames) {
        process.send(frames, connection.Connected)
        process.send(frames, connection.Incoming("{}"))
        Error("connect refused")
      },
      within: 5000,
    )
  let assert sessions.Resolving(frames:, ..) = status
  assert wait_for_switch(status, 5000)
    == Ok(sessions.Failed("failed", "connect refused"))
  assert connection.receive(frames) == Error(Nil)
}

pub fn crashed_session_worker_becomes_a_typed_result_test() {
  let status =
    sessions.start_with(
      "crashed",
      fn(frames) {
        process.send(frames, connection.Connected)
        process.kill(process.self())
        Error("unreachable")
      },
      within: 5000,
    )
  let assert sessions.Resolving(frames:, ..) = status
  let assert Ok(sessions.WorkerCrashed("crashed", reason)) =
    wait_for_switch(status, 5000)
    as "a killed task should surface as a crash"
  assert string.contains(reason, "Killed")
  assert connection.receive(frames) == Error(Nil)
}

// The deadline is weft's: it kills the task and joins it before the outcome
// is delivered, so by the time the terminal reads the timeout the socket the
// task may have opened is already gone and its queued frames are dropped.
pub fn timed_out_session_attempt_discards_late_results_test() {
  let alive = process.new_subject()
  let status =
    sessions.start_with(
      "late",
      fn(frames) {
        process.send(frames, connection.Connected)
        process.send(alive, process.self())
        process.sleep(5000)
        Error("never")
      },
      within: 50,
    )
  let assert sessions.Resolving(frames:, ..) = status
  let assert Ok(task) = process.receive(alive, 1000)
  assert wait_for_switch(status, 5000)
    == Ok(sessions.Failed("late", "session startup timed out"))
  assert connection.receive(frames) == Error(Nil)
  assert process.is_alive(task) == False
}

fn wait_for_switch(
  status: sessions.SwitchStatus,
  remaining_ms: Int,
) -> Result(sessions.Message, Nil) {
  case sessions.receive(status), remaining_ms <= 0 {
    Ok(message), _ -> Ok(message)
    Error(Nil), True -> Error(Nil)
    Error(Nil), False -> {
      process.sleep(10)
      wait_for_switch(status, remaining_ms - 10)
    }
  }
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
  assert command.parse("/effort") == command.MissingArgument("effort")
  assert command.parse("/effort high") == command.Effort("high")
  assert command.help_text() |> string.contains("/effort <level>")
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

pub fn model_selector_keeps_its_selected_row_inside_the_overlay_test() {
  let models =
    indices(12)
    |> list.map(fn(index) {
      let active = case index == 11 {
        True -> ["main"]
        False -> []
      }
      ModelInfo(
        "provider-catalogue-entry-" <> int.to_string(index),
        "anthropic",
        "claude-sonnet-4-5-20250929",
        [],
        active,
      )
    })
  let screen = geometry.rect_new(0, 0, 44, 16)
  let state = model_selector.State(models:, query: "", selected: 11)
  let painted = model_selector.render(buffer.buffer_new(screen), screen, state)

  // Every catalogue row is wider than the overlay. A wrapping render spends
  // the window on the rows above the cursor, so both the cursor and the role
  // badge that belongs to it disappear from the frame entirely.
  let assert Ok(marker_row) = symbol_row(painted, screen, "▸")
    as "the selected catalogue row must survive the overlay clip"
  let assert Ok(badge_row) = symbol_row(painted, screen, "●")
    as "the selected row's role badge must survive the overlay clip"
  assert marker_row == badge_row
}

pub fn agent_inspector_rows_stay_inside_the_overlay_test() {
  let strands =
    indices(8)
    |> list.map(fn(index) {
      Strand(
        "sub:worker-" <> int.to_string(index),
        Some(
          "a strand name long enough to wrap this narrow inspector several"
          <> " times over and steal the rows below it "
          <> int.to_string(index),
        ),
        Some("assistant"),
      )
    })
  let screen = geometry.rect_new(0, 0, 40, 20)
  let painted =
    agents.render_overlay(
      buffer.buffer_new(screen),
      screen,
      strands,
      "sub:worker-0",
      7,
    )

  // The inspector reserves three rows per strand and two more for its
  // footer. Wrapped names break that arithmetic, and the selection and the
  // key legend are the two things pushed off the bottom when it breaks.
  let assert Ok(_) = symbol_row(painted, screen, "▸")
    as "the selected strand must survive the inspector clip"
  let assert Ok(_) = symbol_row(painted, screen, "↑")
    as "the inspector footer must survive the inspector clip"
}

fn indices(count: Int) -> List(Int) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) { index })
}

// Reports the first row holding one glyph. A row that the widget clipped
// leaves no cell behind at all, so an absent answer is the regression these
// overlay tests are written to catch.
fn symbol_row(
  painted: buffer.Buffer,
  screen: geometry.Rect,
  symbol: String,
) -> Result(Int, Nil) {
  indices(screen.size.height)
  |> list.find(fn(row) {
    indices(screen.size.width)
    |> list.any(fn(column) {
      buffer.cell_symbol(buffer.get_cell(painted, Position(column, row)))
      == symbol
    })
  })
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

// A heartbeat sits under both paste thresholds — seven lines and about a
// hundred tokens — so before it was recognised as an injection it printed
// in full, which is the whole reason this collapse exists rather than a
// lowered threshold that would also swallow ordinary pastes.
pub fn a_harness_injection_collapses_to_its_attribution_line_test() {
  let text =
    "[loom] scheduled heartbeat \"pulse\"\n\n"
    <> "This is standing operator configuration, firing automatically on a "
    <> "timer.\n\n--- begin scheduled heartbeat \"pulse\" ---\nbody\n"
    <> "--- end scheduled heartbeat \"pulse\" ---"
  let collapsed = composer.transcript_text(text, False)

  assert collapsed == "[loom] scheduled heartbeat \"pulse\"  [Ctrl+G to expand]"
  assert !string.contains(collapsed, "standing operator configuration")
  assert !string.contains(collapsed, "body")
  // Reversible, exactly like the paste bound above it.
  assert composer.transcript_text(text, True) == text
}

// The late marker rides on the attribution line precisely so it survives
// the collapse: it is the one fact about a fire that changes what the
// reader should do, and it would otherwise sit inside an unopened body.
pub fn a_late_heartbeat_says_so_while_collapsed_test() {
  let text = "[loom] scheduled heartbeat \"pulse\" (late)\n\nprose\n\nbody"

  assert composer.transcript_text(text, False)
    == "[loom] scheduled heartbeat \"pulse\" (late)  [Ctrl+G to expand]"
}

pub fn an_ordinary_turn_is_not_treated_as_an_injection_test() {
  assert composer.harness_injection_summary("ordinary turn") == None
  // The marker has to start the message, not merely appear in it.
  assert composer.harness_injection_summary("see [loom] here\nand here") == None
  assert composer.transcript_text("short", False) == "short"
}

// A one-line injection is already its own summary, so there is nothing to
// fold and no affordance to advertise.
pub fn a_single_line_injection_is_left_alone_test() {
  assert composer.harness_injection_summary("[loom] something") == None
  assert composer.transcript_text("[loom] something", False)
    == "[loom] something"
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

pub fn buffer_to_lines_skips_wide_continuation_cells_test() {
  let screen = geometry.rect_new(0, 0, 6, 2)
  let drawn =
    buffer.buffer_new(screen)
    |> buffer.set_string(
      Position(0, 0),
      "\u{4F60}\u{597D}",
      style.default_style(),
    )
    |> buffer.set_string(Position(0, 1), "ok", style.default_style())

  // Two wide glyphs fill four cells, and the two continuation markers must
  // not become spaces or the row would be wider than the terminal drew it.
  assert frame.buffer_to_lines(drawn) == ["\u{4F60}\u{597D}", "ok"]
  assert frame.buffer_to_text(drawn) == "\u{4F60}\u{597D}\nok"
}

pub fn a_script_draws_one_frame_per_event_test() {
  let inbox = connection.new_inbox()
  let model = quiet_model(inbox)
  let script =
    virtual_backend.script(
      backend.TerminalSize(width: 60, height: 12),
      [virtual_backend.Input(backend.KeyPress("/"))],
      inbox,
    )

  // The initial resize etui synthesizes, the scripted key, and the two
  // settling ticks: four iterations, four frames.
  let assert Ok(run) = tui.run_script(model, script)
  assert list.length(run.frames) == 4
  let assert Ok(last) = list.last(run.frames)
  assert string.contains(frame.buffer_to_text(last), "/details")
}

pub fn a_scripted_resize_moves_the_reported_size_test() {
  let inbox = connection.new_inbox()
  let script =
    virtual_backend.script(
      backend.TerminalSize(width: 40, height: 10),
      [virtual_backend.Input(backend.Resize(72, 20))],
      inbox,
    )
  let assert Ok(run) = tui.run_script(quiet_model(inbox), script)
  let assert Ok(last) = list.last(run.frames)
  assert list.length(frame.buffer_to_lines(last)) == 20
}

pub fn a_delivered_message_reaches_the_model_test() {
  let inbox = connection.new_inbox()
  let script =
    virtual_backend.script(
      backend.TerminalSize(width: 72, height: 14),
      [
        virtual_backend.Deliver(
          connection.Incoming(gateway.full_snapshot("demo")),
        ),
      ],
      inbox,
    )
  let assert Ok(run) = tui.run_script(quiet_model(inbox), script)
  let assert Ok(last) = list.last(run.frames)
  assert string.contains(frame.buffer_to_text(last), "attached to session")
}

// A model with the demo scaffolding removed, so a frame shows only what the
// script put there. The workspace is fixed rather than discovered: the footer
// prints it, and the checkout path is not a property of the client.
fn quiet_model(inbox: process.Subject(connection.Message)) -> tui.Model {
  tui.Model(
    ..tui.new_model(inbox, workspace.Context(path: "/w/demo", branch: None)),
    transcript: [],
    strands: [],
    agent_summary: agents.summary([]),
    notice: "ready",
  )
}

/// Every recordable shape survives the round trip, including the text that
/// a hand-rolled encoder would break on: a quote, a backslash, a newline,
/// and a codepoint outside the basic plane.
pub fn a_recording_line_round_trips_test() {
  let awkward = "a\"b\\c\nd\u{1F600}"
  let moments = [
    recording.Moment(0, recording.Key(text: "Enter")),
    recording.Moment(7, recording.Key(text: awkward)),
    recording.Moment(19, recording.Pasted(text: awkward)),
    recording.Moment(23, recording.Resized(width: 120, height: 40)),
    recording.Moment(
      31,
      recording.Scrolled(x: 4, y: 9, direction: recording.ScrollUp),
    ),
    recording.Moment(
      37,
      recording.Scrolled(x: 0, y: 0, direction: recording.ScrollDown),
    ),
    recording.Moment(41, recording.Arrived(connection.Connected)),
    recording.Moment(
      43,
      recording.Arrived(connection.Incoming(text: gateway.full_snapshot("s"))),
    ),
    recording.Moment(47, recording.Arrived(connection.Closed(reason: awkward))),
    recording.Moment(
      53,
      recording.Arrived(connection.NetworkFault(reason: awkward)),
    ),
  ]

  // One line each, and no line may contain a newline of its own or the
  // file would decode as more moments than were written.
  list.each(moments, fn(moment) {
    let line = recording.encode_line(moment)
    assert !string.contains(line, "\n")
    assert recording.decode_line(line) == Ok(moment)
  })
}

pub fn only_events_that_move_the_model_are_recorded_test() {
  assert recording.of_input(backend.Tick) == None
  assert recording.of_input(backend.MouseMove(1, 2)) == None
  assert recording.of_input(backend.MousePress(1, 2, backend.MouseLeft)) == None
  assert recording.of_input(backend.KeyPress("q"))
    == Some(recording.Key(text: "q"))
  assert recording.of_input(backend.MouseScroll(3, 4, True))
    == Some(recording.Scrolled(x: 3, y: 4, direction: recording.ScrollUp))
}

pub fn a_malformed_recording_line_is_a_worded_error_test() {
  assert recording.decode_line("not json")
    |> result.is_error
  assert recording.decode_line("[1,2]")
    == Error("a recording line must be a JSON object")
  assert recording.decode_line("{\"t\":\"key\",\"key\":\"a\"}")
    == Error("at must be an integer")
  assert recording.decode_line("{\"at\":1,\"t\":\"key\"}")
    == Error("key must be a string")
  assert recording.decode_line("{\"at\":1,\"t\":\"scroll\",\"x\":1,\"y\":2}")
    == Error("scroll needs a boolean \"up\"")
  assert recording.decode_line("{\"at\":1,\"t\":\"wheel\"}")
    == Error("unknown recording event \"wheel\"")
}

pub fn a_recording_file_decodes_in_order_test() {
  let path = "build/tui-recording-test.jsonl"
  let moments = [
    recording.Moment(0, recording.Resized(width: 72, height: 14)),
    recording.Moment(4, recording.Arrived(connection.Connected)),
    recording.Moment(9, recording.Key(text: "h")),
  ]
  let text =
    moments
    |> list.map(recording.encode_line)
    |> string.join("\n")
  let assert Ok(Nil) = simplifile.write(path, text <> "\n")

  // The trailing newline every appended file carries must not decode as a
  // fourth, empty moment.
  assert recording.decode_file(path) == Ok(moments)
  let assert Ok(Nil) = simplifile.delete(path)
}

// ─────────────────────────────────────────────────────────────────
// Frame snapshots
//
// Each of these drives the shipped loop under the virtual backend and pins
// the last frame it drew. They are the only tests that see the client the
// way an operator does, so they are written as scripts — keys and gateway
// frames — rather than as models assembled field by field, except where the
// state is one only a clock can produce.

// The three widths are the row-count thresholds `footer_rows` decides
// from: the sections' fixed caps summed, so a snapshot moves only when
// those caps or the sections' text do, never while a turn runs.
pub fn footer_snapshot_one_row_test() {
  snapshot_test.assert_snapshot(
    "footer-one-row",
    last_frame(quiet_model(connection.new_inbox()), 210, 12, []),
  )
}

pub fn footer_snapshot_two_rows_test() {
  snapshot_test.assert_snapshot(
    "footer-two-rows",
    last_frame(quiet_model(connection.new_inbox()), 133, 12, []),
  )
}

pub fn footer_snapshot_three_rows_test() {
  snapshot_test.assert_snapshot(
    "footer-three-rows",
    last_frame(quiet_model(connection.new_inbox()), 50, 12, []),
  )
}

pub fn usage_footer_snapshot_without_a_rate_test() {
  // A settlement that never streamed leaves the rate unknown, so the tail
  // of the usage row is the cost and nothing after it.
  let inbox = connection.new_inbox()
  snapshot_test.assert_snapshot(
    "usage-footer-plain",
    last_frame(quiet_model(inbox), 96, 12, [
      virtual_backend.Deliver(
        connection.Incoming(gateway.usage("main", 1200, 340, 0.0125)),
      ),
    ]),
  )
}

pub fn usage_footer_snapshot_with_a_rate_test() {
  // The rate is the one footer field a clock produces, so it is set on the
  // model rather than raced for over the wire.
  let inbox = connection.new_inbox()
  let timed = tui.Model(..quiet_model(inbox), output_rate_tps: Some(87))
  snapshot_test.assert_snapshot(
    "usage-footer-with-rate",
    last_frame(timed, 96, 12, [
      virtual_backend.Deliver(
        connection.Incoming(gateway.usage("main", 1200, 340, 0.0125)),
      ),
    ]),
  )
}

pub fn command_palette_snapshot_test() {
  let inbox = connection.new_inbox()
  snapshot_test.assert_snapshot(
    "command-palette-de",
    last_frame(quiet_model(inbox), 76, 18, typed("/de")),
  )
}

pub fn details_toggle_snapshot_test() {
  // Enter on the highlighted palette row runs the command, so this pins
  // the toggle's own label beside the agent count — the pair the status
  // section's forty-two cells have to hold without cutting either.
  let inbox = connection.new_inbox()
  let script = list.append(typed("/details"), [key("enter")])
  snapshot_test.assert_snapshot(
    "details-toggled",
    last_frame(quiet_model(inbox), 96, 14, script),
  )
}

pub fn transcript_snapshot_test() {
  let inbox = connection.new_inbox()
  snapshot_test.assert_snapshot(
    "transcript-turn-and-tool",
    last_frame(quiet_model(inbox), 84, 24, conversation_steps()),
  )
}

pub fn replay_round_trip_snapshot_test() {
  let path = "build/tui-replay-round-trip.jsonl"
  let text =
    conversation_moments()
    |> list.map(recording.encode_line)
    |> string.join("\n")
  let assert Ok(Nil) = simplifile.write(path, text <> "\n")

  // The same decode-and-drive path `loom replay` runs, so a change that
  // broke the command would fail here rather than in a manual check.
  let assert Ok(moments) = recording.decode_file(path)
  let assert Ok(frames) =
    tui.replay_steps(
      recording.to_steps(moments),
      backend.TerminalSize(width: 84, height: 24),
    )
  let assert Ok(last) = list.last(frames)
  let assert Ok(Nil) = simplifile.delete(path)

  snapshot_test.assert_snapshot("replay-transcript", frame.buffer_to_text(last))
}

/// A blank last row survives the golden round trip.
///
/// `write` appends one newline and the comparison takes one back off. An
/// asymmetric pair — stripping every trailing newline on read — would make
/// this frame permanently unmatchable against its own freshly written
/// golden, which is the shape of a bug this pins.
pub fn a_snapshot_keeps_a_blank_last_row_test() {
  let screen = geometry.rect_new(0, 0, 6, 3)
  snapshot_test.assert_snapshot(
    "blank-rows",
    frame.buffer_to_text(buffer.buffer_new(screen)),
  )
}

// One session's worth of traffic: an attach, a user turn, a tool call and
// its failing result, and a stream fragment that has not settled yet. The
// delta comes last because a settled entry clears its strand's fragments.
//
// Typed as inbound messages rather than as script steps, so the script and
// the recording below are both derived from it and neither can lose a
// field converting to the other.
fn conversation() -> List(connection.Message) {
  [
    connection.Connected,
    connection.Incoming(gateway.full_snapshot("demo")),
    connection.Incoming(gateway.user_entry("main", "run the tests", 1)),
    connection.Incoming(gateway.tool_call_entry(
      "main",
      "bash",
      "make check-tui",
      2,
    )),
    connection.Incoming(gateway.tool_result_entry(
      "main",
      "error: compilation failed\n  test/tui_test.gleam:12",
      3,
    )),
    connection.Incoming(gateway.stream_delta(
      "main",
      "text",
      "Looking at the failure now.",
    )),
  ]
}

fn conversation_steps() -> List(virtual_backend.Step) {
  list.map(conversation(), fn(message) { virtual_backend.Deliver(message:) })
}

// The same traffic as a recording, so the round-trip test writes a file the
// CLI would have written.
fn conversation_moments() -> List(recording.Moment) {
  conversation()
  |> list.index_map(fn(message, index) {
    recording.Moment(at_ms: index * 10, event: recording.Arrived(message:))
  })
}

fn typed(text: String) -> List(virtual_backend.Step) {
  text |> string.to_graphemes |> list.map(key)
}

fn key(name: String) -> virtual_backend.Step {
  virtual_backend.Input(backend.KeyPress(name))
}

// Every snapshot ends the same way: run the script on a fixed screen and
// take the frame the settling ticks flushed.
fn last_frame(
  model: tui.Model,
  width: Int,
  height: Int,
  steps: List(virtual_backend.Step),
) -> String {
  let script =
    virtual_backend.script(
      backend.TerminalSize(width:, height:),
      steps,
      model.inbox,
    )
  let assert Ok(run) = tui.run_script(model, script)
  let assert Ok(last) = list.last(run.frames)
  frame.buffer_to_text(last)
}
