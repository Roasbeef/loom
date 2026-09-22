//// The prompt-cache notice as the terminal draws it.
////
//// These tests drive the shipped event handler over the wire, on an
//// injected clock, so what they check is the whole path: two `usage` frames
//// on one strand, the detector between them, and the row that lands in the
//// transcript under the turn that paid for the miss. The detector's own
//// thresholds are swept in `cache_miss_test`.

import core/json
import core/message
import etui/backend
import etui/geometry
import etui/widgets/textarea
import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/strand
import tui
import tui/attachment
import tui/cache_miss
import tui/connection
import tui/frame
import tui/protocol
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import tui/workspace
import tui_test/gateway
import tui_test/pushed

// A quarter-million token prefix, priced at a dollar per million tokens for
// a cached read. The figures are round so the row's text is exact rather
// than approximately exact.
fn held_prefix() -> message.Usage {
  message.Usage(
    input: 0,
    output: 400,
    cache_read: 250_000,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 250_400,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.004,
      cache_read: 0.25,
      cache_write: 0.0,
      total: 0.254,
    ),
  )
}

// The same prefix read again from cold, at five dollars per million tokens:
// four dollars per million more than the cached read, which over a quarter
// of a million tokens is exactly one dollar.
fn re_read_prefix() -> message.Usage {
  message.Usage(
    input: 0,
    output: 400,
    cache_read: 0,
    cache_write: 250_000,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 250_400,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.004,
      cache_read: 0.0,
      cache_write: 1.25,
      total: 1.254,
    ),
  )
}

const expected_row = "Cache miss after 10m idle: 250k tokens re-billed (~$1.00)"

fn initial(now: Int) -> tui.Model {
  tui.new_model_with_clock(
    connection.new_inbox(),
    workspace.Context(path: "/work", branch: None),
    fn() { now },
  )
}

fn at(model: tui.Model, now: Int) -> tui.Model {
  tui.Model(..model, monotonic_time_ms: fn() { now })
}

fn deliver(model: tui.Model, wire: String) -> tui.Model {
  process.send(model.inbox, connection.Incoming(wire))
  tui.update(backend.Tick, model)
}

fn text(model: tui.Model) -> String {
  render_text(model, 120, 40)
}

fn render_text(model: tui.Model, width: Int, height: Int) -> String {
  let model = tui.update(backend.Resize(width, height), model)
  let #(buffer, _) = tui.view(model, geometry.rect_new(0, 0, width, height))
  frame.buffer_to_text(buffer)
}

// A first turn whose request read the cached prefix, ten minutes ago.
fn after_the_first_turn() -> tui.Model {
  initial(0)
  |> deliver(gateway.user_entry("main", "carry on", 1))
  |> deliver(gateway.assistant_entry("main", "first answer", 2))
  |> deliver(gateway.usage_row("main", held_prefix()))
}

// The turn after the pause, whose request paid for the prefix again.
fn after_the_second_turn(model: tui.Model) -> tui.Model {
  model
  |> at(600_000)
  |> deliver(gateway.user_entry("main", "still there", 3))
  |> deliver(gateway.assistant_entry("main", "second answer", 4))
  |> deliver(gateway.usage_row("main", re_read_prefix()))
}

pub fn two_usage_rows_across_a_pause_draw_the_row_test() {
  let quiet = after_the_first_turn()
  assert !string.contains(text(quiet), "Cache miss")

  let drawn = text(after_the_second_turn(quiet))
  assert string.contains(drawn, expected_row)

  // The row explains the turn above it, so it follows the answer whose
  // request missed rather than heading the transcript.
  let assert Ok(#(above, _)) = string.split_once(drawn, "Cache miss")
    as "the row is on screen"
  assert string.contains(above, "second answer")
}

pub fn an_unpriced_model_keeps_the_row_and_drops_the_money_test() {
  let free = message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0)
  let drawn =
    initial(0)
    |> deliver(gateway.user_entry("main", "carry on", 1))
    |> deliver(gateway.assistant_entry("main", "first answer", 2))
    |> deliver(gateway.usage_row(
      "main",
      message.Usage(..held_prefix(), cost: free),
    ))
    |> at(600_000)
    |> deliver(gateway.assistant_entry("main", "second answer", 4))
    |> deliver(gateway.usage_row(
      "main",
      message.Usage(..re_read_prefix(), cost: free),
    ))
    |> text

  // The status line prices the session elsewhere on screen, so what must be
  // absent is the row's own parenthetical rather than every dollar sign.
  assert string.contains(
    drawn,
    "Cache miss after 10m idle: 250k tokens re-billed",
  )
  assert !string.contains(drawn, "re-billed (~$")
}

pub fn the_footer_states_the_cache_outlook_before_the_next_prompt_test() {
  // The outlook is the forward-looking counterpart of the miss row: the
  // tick folds the active strand's watch into the footer's cache label,
  // and the label repaints only when the reading moves. What is asserted
  // is both the model's label and the painted frame: an indicator hidden by
  // footer truncation cannot warn the operator. The seeded preview strands
  // are cleared first because a live strand suppresses the label.
  let quiet = after_the_first_turn() |> clear_strands

  let idle = tui.update(backend.Tick, at(quiet, 600_000))
  assert idle.cache_outlook == "cache idle 10m"
    as "an idle cache with no proven horizon reads as its growing pause"
  assert string.contains(text(idle), "cache idle 10m")
    as "the compact footer actually displays the warning"
  assert string.contains(render_text(idle, 40, 12), "cache idle 10m")
    as "a narrow terminal retains the warning before lower-priority figures"
  let expanded = tui.Model(..idle, details_expanded: True)
  assert string.contains(text(expanded), "cache idle 10m")
    as "the detailed footer also displays the warning"

  // Under the idle floor there is nothing to warn about, so the label
  // stays empty rather than counting toward an expiry nothing
  // established.
  let fresh = tui.update(backend.Tick, at(quiet, 30_000))
  assert fresh.cache_outlook == ""
    as "a short pause has no reading worth a label"

  // A live operation suppresses the label: the request in flight is
  // rewriting the prefix, so an expiry countdown would name a rollover
  // the request itself is about to reset.
  let live =
    tui.update(
      backend.Tick,
      tui.Model(..at(quiet, 600_000), strands: [
        protocol.Strand(
          id: "main",
          name: Some("main"),
          live_phase: Some("assistant"),
        ),
      ]),
    )
  assert live.cache_outlook == ""
    as "a running strand hides the countdown until it settles"

  // A proven split counts down instead: the same watch carried a
  // one-hour write, so the reading states what is holding and for how
  // much longer rather than the pause's age.
  let split =
    quiet
    |> fn(base) {
      tui.Model(
        ..base,
        cache_watch: dict.from_list([
          #("main", watch_with(cache_miss.Split)),
        ]),
      )
    }
    |> at(180_000)
    |> fn(base) { tui.update(backend.Tick, base) }
  assert split.cache_outlook == "cache tail ≤2m"
    as "a proven tail counts down to its expiry"
}

/// A local model change cannot inherit another provider's cache horizon.
pub fn changing_the_model_discards_the_old_watch_before_the_next_row_test() {
  let base = after_the_first_turn() |> clear_strands
  let watched =
    tui.Model(
      ..base,
      cache_watch: dict.from_list([#("main", watch_with(cache_miss.Split))]),
    )
  let shown = tui.update(backend.Tick, at(watched, 180_000))
  assert shown.cache_outlook == "cache tail ≤2m"

  let requested =
    tui.Model(
      ..shown,
      input: textarea.state_from_string("/model another-provider"),
    )
  let switched = tui.update(backend.KeyPress("enter"), requested)
  assert dict.get(switched.cache_watch, "main") == Error(Nil)
    as "a new provider has no prior cache baseline or proven horizon"
  assert switched.cache_outlook == ""
    as "the old provider's countdown disappears with the switch"

  let next =
    switched
    |> at(600_000)
    |> deliver(gateway.assistant_entry("main", "new provider answer", 3))
    |> deliver(gateway.usage_row("main", re_read_prefix()))
  assert next.cache_notices == []
    as "the new provider's first row cannot be compared to the old prefix"
}

// A captured configuration is authoritative even when another terminal
// changed it. Keeping model identity separate from other configuration fields
// lets a reasoning-setting change preserve a valid cache watch.
fn captured_view(provider: String, reasoning: strand.ThinkingLevel) {
  snapshot_view.View(
    [protocol.Strand("main", Some("main"), None)],
    dict.new(),
    dict.from_list([
      #(
        "main",
        snapshot_view.Configuration(
          strand.StrandConfiguration(
            strand.ModelIdentity(provider, "shared-model"),
            reasoning,
            [],
          ),
          None,
        ),
      ),
    ]),
    dict.new(),
    initial(0).usage,
    snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    [],
    [],
    None,
    Some([]),
    None,
  )
}

pub fn captured_provider_switch_discards_only_changed_model_evidence_test() {
  let base = after_the_first_turn() |> clear_strands
  let initial =
    tui.Model(
      ..base,
      cache_watch: dict.from_list([#("main", watch_with(cache_miss.Split))]),
    )
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected(initial.session, "epoch", "instance"),
        "peer",
        message.Origin("operator", "Operator"),
        snapshot.Owner,
      ),
      1,
      json.Object([]),
      snapshot.empty(),
      None,
    )
  let first =
    tui.apply_channel_update(
      initial,
      session_channel.Captured(
        cut,
        captured_view("provider-a", strand.ThinkingOff),
        session_channel.Notified,
      ),
    )
  let same_provider =
    tui.apply_channel_update(
      first,
      session_channel.Captured(
        snapshot.Captured(
          ..cut,
          metadata: json.Object([#("capture", json.Int(2))]),
        ),
        captured_view("provider-a", strand.ThinkingHigh),
        session_channel.Notified,
      ),
    )
  assert dict.get(same_provider.cache_watch, "main") != Error(Nil)
    as "changing reasoning effort does not erase the provider's watch"

  let switched =
    tui.apply_channel_update(
      same_provider,
      session_channel.Captured(
        snapshot.Captured(
          ..cut,
          metadata: json.Object([#("capture", json.Int(3))]),
        ),
        captured_view("provider-b", strand.ThinkingHigh),
        session_channel.Notified,
      ),
    )
  assert dict.get(switched.cache_watch, "main") == Error(Nil)
    as "same model ID under another provider is a different cache"
  assert switched.cache_outlook == ""
}

// The preview model's strand roster, emptied: an idle session has no live
// operation, and the outlook's suppression is keyed on one.
fn clear_strands(model: tui.Model) -> tui.Model {
  tui.Model(..model, strands: [])
}

// A watch holding the priced prefix at time zero under the stated horizon.
fn watch_with(horizon: cache_miss.HourHead) -> cache_miss.Watch {
  let usage = case horizon {
    cache_miss.Unproven -> held_prefix()
    cache_miss.Split ->
      message.Usage(..held_prefix(), cache_write_1h: Some(1000))
  }
  let assert #(_, Some(watch)) = cache_miss.observe(None, usage, 0)
  watch
}

pub fn a_subagent_strand_never_feeds_the_primary_detector_test() {
  // The sub-agent's own strand misses while `main` sits on its cached
  // prefix. Its row belongs to its own transcript, and its rows must not
  // become the baseline the primary is judged against.
  let sub = "sub:main/audit"
  let crossed =
    after_the_first_turn()
    |> deliver(gateway.assistant_entry(sub, "sub answer", 5))
    |> deliver(gateway.usage_row(sub, held_prefix()))
    |> at(600_000)
    |> deliver(gateway.usage_row(sub, re_read_prefix()))

  assert !string.contains(text(crossed), "Cache miss")

  // `main`'s own second row still reports the whole prefix, which it could
  // not do if the sub-agent's rows had displaced its baseline.
  let drawn =
    crossed
    |> deliver(gateway.assistant_entry("main", "second answer", 6))
    |> deliver(gateway.usage_row("main", re_read_prefix()))
    |> text
  assert string.contains(drawn, expected_row)
}

pub fn a_reattach_does_not_redraw_the_row_test() {
  // The notice is memory-only. A fresh model fed the same durable history
  // shows the conversation and none of the transient rows, which is what
  // "not durable" has to mean on screen.
  let drawn = text(after_the_second_turn(after_the_first_turn()))
  assert string.contains(drawn, expected_row)

  let reattached =
    initial(600_000)
    |> deliver(gateway.user_entry("main", "carry on", 1))
    |> deliver(gateway.assistant_entry("main", "first answer", 2))
    |> deliver(gateway.user_entry("main", "still there", 3))
    |> deliver(gateway.assistant_entry("main", "second answer", 4))
    |> text
  assert string.contains(reattached, "second answer")
  assert !string.contains(reattached, "Cache miss")
}

pub fn a_row_raised_inside_a_tool_group_follows_the_group_test() {
  // A usage event can land between a tool call and its result. The compact
  // projection joins those two, so the row has to follow the whole group
  // rather than cut it in half and leave the call pending.
  let drawn =
    initial(0)
    |> deliver(gateway.user_entry("main", "carry on", 1))
    |> deliver(gateway.assistant_entry("main", "first answer", 2))
    |> deliver(gateway.usage_row("main", held_prefix()))
    |> at(600_000)
    |> deliver(gateway.tool_call_entry("main", "bash", "call-1", 3))
    |> deliver(gateway.usage_row("main", re_read_prefix()))
    |> deliver(gateway.tool_result_ok_entry("main", "call output", 4))
    |> text

  assert string.contains(drawn, expected_row)

  // The joined group reports one call and no unfinished work above the row.
  let assert Ok(#(above, _)) = string.split_once(drawn, "Cache miss")
    as "the row is on screen"
  assert string.contains(above, "tools · 1 call")
}

// A `snapshot_begin` naming an arbitrary session rather than the fixed "A"
// `tui_test/pushed` bakes in, which is what lets this fixture drive an
// actual session switch instead of a same-session reattach.
fn begin_for(
  session: String,
  id: Int,
  transfer_id: String,
  next_seq: Int,
) -> connection.Message {
  pushed.reply(
    id,
    "snapshot_begin",
    json.Object([
      #("snapshot_id", json.String(transfer_id)),
      #("session_id", json.String(session)),
      #("epoch", json.String("epoch")),
      #("incarnation", json.String("incarnation")),
      #("connection_id", json.String("connection")),
      #(
        "origin",
        json.Object([
          #("principal", json.String("alice")),
          #("name", json.String("Alice")),
        ]),
      ),
      #("role", json.String("operator")),
      #("next_seq", json.Int(next_seq)),
      #("oldest_seq", json.Null),
      #("window", json.String("recent")),
      #("complete_history", json.Bool(False)),
      #("record_bytes_limit", json.Int(snapshot.record_limit)),
      #("fragment_bytes_limit", json.Int(snapshot.piece_limit)),
    ]),
  )
}

fn piece_for(id: Int, transfer_id: String, data: String) -> connection.Message {
  pushed.reply(
    id,
    "snapshot_chunk",
    json.Object([
      #("snapshot_id", json.String(transfer_id)),
      #("index", json.Int(0)),
      #("kind", json.String("metadata")),
      #("record_id", json.String("metadata")),
      #("record_seq", json.Null),
      #("total_bytes", json.Int(string.byte_size(data))),
      #("offset", json.Int(0)),
      #(
        "data",
        json.String(bit_array.base64_encode(bit_array.from_string(data), True)),
      ),
    ]),
  )
}

fn finish_for(
  id: Int,
  transfer_id: String,
  next_seq: Int,
) -> connection.Message {
  pushed.reply(
    id,
    "snapshot_end",
    json.Object([
      #("snapshot_id", json.String(transfer_id)),
      #("index", json.Int(1)),
      #("next_seq", json.Int(next_seq)),
      #("more_after", json.Null),
    ]),
  )
}

// One completed, empty transfer for an arbitrary session: its begin, its
// single metadata fragment carrying no history, and its end.
fn transfer_for(
  session: String,
  first: Int,
  transfer_id: String,
  next_seq: Int,
) -> List(connection.Message) {
  [
    begin_for(session, first, transfer_id, next_seq),
    piece_for(first + 1, transfer_id, pushed.metadata()),
    finish_for(first + 2, transfer_id, next_seq),
  ]
}

// Drives a real session switch through `candidate_outcome`, the same path
// the terminal takes when the operator picks a different session: a fresh
// channel is credited with the new session's first cut, and that cut is
// handed over as an `attachment.Adopted` outcome exactly as `attachment`
// itself would report it.
fn adopt_session(model: tui.Model, session: String) -> tui.Model {
  let channel =
    session_channel.replay(snapshot.Expected(session, "epoch", "incarnation"))
  let #(replacement, updates) =
    list.fold(
      transfer_for(session, 1, "1:1", 10),
      #(channel, []),
      fn(acc, incoming) {
        let #(next, changes) = session_channel.receive(acc.0, incoming)
        #(next, list.append(acc.1, changes))
      },
    )
  let assert [session_channel.Captured(cut, view, _)] = updates
    as "the switch's first cut is fully validated"
  tui.candidate_outcome(
    model,
    attachment.idle(),
    Some(attachment.Adopted(
      replacement,
      cut,
      view,
      connection.new_inbox(),
      workspace.Context("/work-" <> session, None),
      "Session " <> session,
      None,
    )),
  )
}

pub fn a_session_switch_resets_the_watch_and_its_notices_test() {
  // Seed a watch and a drawn notice on session A's "main" strand.
  let seeded = after_the_second_turn(after_the_first_turn())
  assert string.contains(text(seeded), expected_row)
  assert seeded.cache_watch != dict.new()
  assert seeded.cache_notices != []

  // Adopt session B through the real `candidate_outcome` path the terminal
  // takes on every session switch. Every session's primary strand is also
  // named "main", so a watch or a notice carried over from A would be
  // judged against the wrong baseline: B's first request would be compared
  // to A's last row and drawn as a miss it never suffered. A live channel
  // delivers its own usage rows only through a credited catch-up rather
  // than the unsolicited push `tui_test/gateway` builds, so what this test
  // can check directly is the state the switch itself must clear.
  let switched = adopt_session(seeded, "B")

  assert switched.cache_watch == dict.new()
    as "a session switch must drop the previous session's cache watch"
  assert switched.cache_notices == []
    as "a session switch must drop the previous session's cache notices"

  // The transcript itself is also replaced, so the drawn notice from A does
  // not linger on screen either.
  assert !string.contains(text(switched), "Cache miss")
}
