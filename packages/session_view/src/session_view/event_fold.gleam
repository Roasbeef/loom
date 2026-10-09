//// The event fold: what one pushed event does to the session state.
////
//// `apply_event` handles each event the daemon pushes: stream fragments,
//// tool output tails, durable entries, strand phases, usage and the prompt
//// cache it reveals, and the replies to side-surface reads. It takes and
//// returns the shared record alone (`session_view/model`), so any host of
//// the session can run the same fold, and it reads no host state.
////
//// Live streams stay separate from durable entries because the server may
//// replay the settled entry after its fragments; the stream is dropped when
//// its entry lands, so the answer is never shown twice.
////
//// Some events used to write the terminal's own state at the point they were
//// applied: the editor and viewport on a workspace switch, the model
//// selector's list, the cache outlook label, the notes panel's selection and
//// the summary's job cursor. The fold records each of those as a
//// `SurfaceFact` in `Shared.surface_facts` instead, in the order it
//// happened, and the terminal applies them after the call that recorded
//// them (`inbound.settle_surfaces`), so its writes land where they did. The
//// lane fold calls this module once per pushed event, and the terminal's
//// strand switch and model selector call `select_workspace` and
//// `select_model` directly.
////
//// The functions here call `outbound`'s and `surfaces`' functions over the
//// shared record and no other function of either module.
////
//// ## Flow
////
//// `apply_event` → `receive_stream` → `receive_usage_observation` → `settle_usage` → `select_workspace`
////
//// 1. `apply_event` matches the pushed `protocol.Event` and builds the next
////    record. Snapshots replace what they describe; `EntryAdded` extends the
////    durable records and clears the stream its entry settles.
//// 2. `streams_before_end` and `receive_stream` keep the live fragments of one
////    provider request, replacing them together when a new request starts.
//// 3. `receive_tail` and `retire_recorded_tail` keep the tool output tails and
////    drop each one when its call's result is committed.
//// 4. `receive_usage_observation` admits a usage push by its sequence, and
////    `settle_usage` takes the output rate and generation clock from it.
//// 5. `watch_cache` starts the cache clock; `settle_pending_cache` finishes
////    the comparison once a cut covers the sequence, and `note_cache_miss`
////    records a miss.
//// 6. Every arm but the silent ones then goes through the second match in
////    `apply_event`, which marks activity and invalidates the frame.
//// 7. The public functions after the fold serve the hosts directly:
////    `send_prompt_to`, `expect_own_turn` and `settle_own_turn` for a prompt's
////    echo, `leave_session` and `select_workspace` for a change of target.
////
//// `apply_event` dispatches the decoded event and returns a new shared record.
//// For operation completion, follow `set_strand_phase` and `settle_interrupt`.
//// Goal boards are handed to the shared surface reducer from `apply_event`.
//// `GoalChanged` is already consumed by the lane before this fold.
//// An interrupt marker can retire here while the captured queue stays held.

import core/accounting
import core/entry
import core/json
import core/message
import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import session_view/advisor_history
import session_view/agent_roster
import session_view/block_summary
import session_view/cache_miss
import session_view/cache_watch
import session_view/composer
import session_view/context_view
import session_view/history_view
import session_view/live_jobs
import session_view/model.{
  type Shared, Attached, Disconnected, HoldGoalReport, Interrupt, JobsReplaced,
  ModelsListed, NotesArrived, OutlookCleared, Preview, Replaying, ReturnedDraft,
  SessionSynchronized, Shared, WorkspaceSwitched,
} as session_model
import session_view/operator
import session_view/outbound
import session_view/protocol.{Strand}
import session_view/queue_request
import session_view/shared_set
import session_view/stream_identity
import session_view/surfaces
import session_view/todo_board
import session_view/transcript_line.{
  type Stream, type Submission, type ToolTail, Assistant, CacheNotice,
  HeldPrompt, Interjection, Line, Stream, System, ToolTail, User,
}
import session_view/transcript_lines
import session_view/worktree_view

/// Applies one pushed event to the session state.
///
/// Every event that changes what is drawn, and every reply, marks activity
/// and invalidates the painted frame after its own arm. A commit notice, a
/// metadata change, a resumed marker, an ignored frame and a returned draft
/// do neither: the first four draw nothing, and the returned draft's notice
/// already invalidates what it changes.
///
/// ## Examples
///
/// ```gleam
/// let shared = event_fold.apply_event(shared, protocol.StrandsSnapshot([]))
/// ```
@internal
pub fn apply_event(
  shared: Shared(socket, recorder, source, replay_source),
  event: protocol.Event,
) -> Shared(socket, recorder, source, replay_source) {
  let updated = case event {
    protocol.FullSnapshot(session:, strands:, entries:, usage:) -> {
      let target = case shared.session == session {
        True -> shared.active_strand
        False -> "main"
      }
      let shared = select_workspace(shared, session, target)

      // The snapshot replaces every row the transcript drew, so the
      // terminal drops its gutters and returns its viewport to the tail when
      // it applies the fact, after the workspace switch recorded above.
      Shared(
        ..session_model.record_surface(shared, SessionSynchronized),
        session:,
        active_strand: target,
        strands:,
        usage:,
        records: list.reverse(entries),
        streams: [],
        // A new session or strand has its own generations; the previous
        // view's start time is not theirs.
        generation_started_ms: None,
        tool_tails: [],
        record_cache_epoch: shared.record_cache_epoch + 1,
        compact_call_cache: dict.new(),
        compact_entry_cache: dict.new(),
        // The snapshot is the server's own account of the strand, so it
        // already carries every submission the daemon committed while this
        // client was away — the gateway holds its queue across a disconnect
        // and drains it regardless. An echo kept across the rebuild would sit
        // under the committed copy of itself.
        queued: [],
        awaiting_outcome: None,
        pending_records: [],
        record_cache_valid: False,
        submitting: None,
        notice: "session synchronized",
        transcript: [Line(System, "attached to session " <> session)],
      )
      |> session_model.invalidate_transcript
    }
    protocol.StrandsSnapshot(strands:) -> shared_set.strands(shared, strands)
    protocol.SkillsSnapshot(page:) -> {
      let previous = case page.offset {
        0 -> []
        _ -> shared.skills
      }
      case page.offset == list.length(previous) {
        False ->
          session_model.append_error(
            shared,
            "skill catalogue page arrived out of order",
          )
        True -> {
          let loaded =
            shared_set.skills(shared, list.append(previous, page.commands))
          case page.next {
            None -> loaded
            Some(offset) ->
              outbound.send_frame(
                loaded,
                protocol.skills(loaded.next_id, offset),
              )
          }
        }
      }
    }
    protocol.ModelsSnapshot(models:) -> {
      // An open model selector lists what the daemon just named. The
      // selector is the terminal's, so the fact carries the list and the
      // model it marks as current, and the terminal refreshes the selector
      // when it applies the fact.
      Shared(
        ..session_model.record_surface(
          shared,
          ModelsListed(models:, current: shared.current_model),
        ),
        models:,
        notice: int.to_string(list.length(models)) <> " models loaded",
      )
      |> outbound.send_frame(protocol.skills(shared.next_id, 0))
    }
    protocol.SchedulesSnapshot(schedules:) ->
      append_schedules(shared, schedules)

    // The page's own read of what the session remembers, so the board is kept
    // for the host to draw and nothing is written to the transcript.
    protocol.PermissionsSnapshot(board:) ->
      shared_set.remembered(shared, Some(board))
    protocol.ConfigSnapshot(model_name:, directories:) -> {
      let shared = case model_name {
        Some(name) -> {
          let selected = select_model(shared, name)
          shared_set.notice(selected, "model: " <> name)
        }
        None -> shared
      }
      case directories {
        None -> shared
        Some(value) ->
          shared_set.notice(
            shared,
            "Session directory access: " <> json.to_string(value),
          )
      }
    }
    protocol.LiveJobsSnapshot(board) -> receive_jobs(shared, board)
    protocol.AdvisorPendingSnapshot(board) ->
      surfaces.receive_advisor_nudges(shared, board)

    // Labels change the words of rows the record cache already holds, so
    // the cache is rebuilt; its entry-level keys carry the labels, which
    // limits the re-projection to the entries whose labels moved.
    protocol.BlockSummariesSnapshot(labels:) ->
      shared
      |> shared_set.summaries(block_summary.receive_board(
        shared.summaries,
        labels,
      ))
      |> shared_set.record_cache_valid(False)
      |> session_model.invalidate_transcript
    protocol.BlockSummarized(subject:, text:) ->
      receive_block_summary(shared, subject, text)
    protocol.GoalSnapshot(board) -> surfaces.receive_goal(shared, board)
    protocol.ContextSnapshot(observation) ->
      shared_set.context(
        shared,
        context_view.receive(
          shared.context,
          session_model.queue_owner(shared),
          observation,
        ),
      )
    protocol.WorktreeSnapshot(observation) ->
      shared_set.worktree(
        shared,
        worktree_view.receive(
          shared.worktree,
          session_model.queue_owner(shared),
          observation,
        ),
      )
      |> session_model.invalidate_transcript
    protocol.QueuedInputSnapshot(document) -> {
      let owner = session_model.queue_owner(shared)
      let namespace = session_model.queue_namespace(shared)

      // Only the answer to the read this client issued may fill the
      // editor; any other document leaves both halves as they were.
      case
        queue_request.receive(shared.queue_request, owner, namespace, document)
      {
        Ok(request) ->
          shared
          |> shared_set.queue_request(request)
          |> shared_set.queue_notices(
            list.append(shared.queue_notices, [
              queue_request.Received(owner:, namespace:, document:),
            ]),
          )
        Error(Nil) -> shared
      }
    }
    protocol.NotesSnapshot(board) -> {
      // Every notes read may carry a strand's todo board, whichever surface
      // asked for it, so the panel is seeded before the notes view decides
      // whether this read is its own.
      let shared =
        shared_set.todo_boards(
          shared,
          todo_board.seed(shared.todo_boards, board),
        )

      // Whether the board is the one a notes surface shows, and so whether
      // it replaces `note_board` and says so, is the terminal's to decide:
      // the notes target is the agent inspector's strand when its Notes tab
      // is open. The terminal decides it when it applies the fact.
      session_model.record_surface(shared, NotesArrived(board))
    }
    protocol.EntryAdded(record:) -> {
      let protocol.EntryRecord(strand:, ..) = record
      let updated =
        Shared(
          ..shared,
          records: [record, ..shared.records],
          todo_boards: todo_board.remember(shared.todo_boards, [record]),
          streams: transcript_lines.clear_streams(shared.streams, strand),
          tool_tails: retire_recorded_tail(shared.tool_tails, record),
          pending_records: case strand == shared.active_strand {
            True -> [record, ..shared.pending_records]
            False -> shared.pending_records
          },
          // A committed user turn on this strand is the daemon draining the
          // head of its queue, so the echo standing in for it goes away.
          queued: case strand == shared.active_strand {
            True -> drained_echoes(shared.queued, record)
            False -> shared.queued
          },
        )
      let updated = surfaces.retire_delivered_nudges(updated, record)

      case strand == shared.active_strand {
        True -> session_model.invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.StreamDelta(strand:, operation:, generation:, kind:, text:) -> {
      // The generation clock normally started when the strand entered
      // its `assistant` phase (see `OperationChanged`); a fragment that
      // finds it unset is the fallback, for a phase sequence that never
      // said so. Later fragments, and other strands, leave it alone.
      let generation_started_ms = generation_clock(shared, strand)
      let streams =
        receive_stream(
          streams_before_end(shared, strand, operation, generation, kind),
          strand,
          operation,
          generation,
          kind,
          text,
        )

      let updated =
        shared
        |> shared_set.streams(streams)
        |> shared_set.generation_started_ms(generation_started_ms)
        |> shared_set.notice(case kind {
          "end" -> "request finished"
          _ -> "streaming " <> kind
        })
      case strand == shared.active_strand {
        True -> session_model.invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.OperationChanged(strand:, phase:) -> {
      let submitting = case shared.submitting {
        Some(target) if target == strand -> None
        other -> other
      }
      let strands = set_strand_phase(shared.strands, strand, phase)

      // The rate's clock starts when the request goes out, not when the
      // first fragment lands. A provider that streams whole parts —
      // Gemini does — can deliver a short reply as one burst at the end
      // of a generation, and a clock started on that burst measured a
      // millisecond and reported six-figure tokens per second.
      //
      // Settlement is not the only way a generation ends. A refused or
      // aborted request never reports usage, so its start time would
      // outlive it and be read as the next generation's. A turn that
      // finishes (`done`) drops the clock of its own strand, and an
      // `assistant` phase entered from any other phase begins a new
      // generation and restarts it. A repeated `assistant` transition
      // is the same generation and leaves the clock alone.
      let generation_started_ms = case phase, strand == shared.active_strand {
        "done", True -> None
        "assistant", True ->
          case strand_was_generating(shared.strands, strand) {
            True -> generation_clock(shared, strand)
            False -> Some(shared.stamp.now_ms)
          }
        _other, _ -> shared.generation_started_ms
      }

      let updated =
        shared
        |> shared_set.submitting(submitting)
        |> shared_set.strands(strands)
        |> shared_set.generation_started_ms(generation_started_ms)
        |> shared_set.streams(case phase == "done" {
          True -> transcript_lines.clear_streams(shared.streams, strand)
          False -> shared.streams
        })
        |> shared_set.tool_tails(case phase == "done" {
          True -> clear_tails(shared.tool_tails, strand)
          False -> shared.tool_tails
        })
        |> shared_set.notice(strand <> ": " <> phase)
      let settled = settle_interrupt(updated, strand, phase)
      case phase == "done" && strand == shared.active_strand {
        True -> session_model.invalidate_transcript(settled)
        False -> settled
      }
    }

    // A tail replaces the one it supersedes rather than joining a list:
    // the frame carries the whole window, so the newest is the only one
    // worth drawing, and the region cannot grow with the command's output.
    protocol.ToolOutput(
      strand:,
      operation:,
      step:,
      source_index:,
      call_id:,
      stream:,
      text:,
      total_bytes:,
    ) -> {
      let updated =
        shared_set.tool_tails(
          shared,
          receive_tail(
            shared.tool_tails,
            ToolTail(
              strand:,
              operation:,
              step:,
              source_index:,
              call_id:,
              stream:,
              text:,
              total_bytes:,
            ),
          ),
        )
      case strand == shared.active_strand {
        True -> session_model.invalidate_transcript(updated)
        False -> updated
      }
    }
    protocol.UsageChanged(
      strand:,
      seq:,
      operation:,
      usage: settled,
      last_usage:,
    ) ->
      case seq {
        Some(seq) ->
          receive_usage_observation(shared, strand, seq, operation, last_usage)
        None -> receive_usage(shared, strand, settled, last_usage)
      }

    protocol.EscalationPending(id:, tool:, preview: _) ->
      session_model.append_error(
        shared,
        "approval required for " <> tool <> " [" <> id <> "]",
      )

    // The refusal answers whatever this terminal last submitted, because the
    // conversation channel carries one mutation at a time. A prompt refused
    // for a full hold queue commits no entry, so its echo is retired here or
    // never.
    protocol.ServerError(code:, message:) ->
      session_model.append_error(
        {
          let discarded = outbound.discard_own_turn(shared)
          shared_set.submitting(discarded, None)
        },
        code <> ": " <> message,
      )

    // A commit notice and a metadata change say only that the next capture
    // will differ. `session_view/session_channel` acts on them by capturing; there is
    // nothing for a renderer to draw from the frame itself.
    protocol.Committed(..) | protocol.MetadataChanged | protocol.GoalChanged ->
      shared

    // A resumed marker names a stream that continues from a cut this
    // terminal already holds. The lane reports it as its own update, so a
    // frame arriving outside one is nothing to paint.
    protocol.Resumed(_) -> shared
    protocol.Ignored(_) -> shared

    // The draining daemon handed a held prompt back, unsent. The held
    // queue is memory-only, so this push is the draft's last copy: restore
    // it into the composer rather than letting the operator's text die
    // with the daemon. An empty composer takes the text outright; an
    // occupied one keeps what the operator is typing, and the return is
    // appended below it — both are theirs, and neither may be lost.
    // The return carries no attachment bytes. Its count tells the operator
    // which images must be reattached before submitting the restored draft.
    protocol.HeldInputReturned(strand:, kind:, text:, attachment_count:, ..) ->
      restore_returned_draft(shared, strand, kind, text, attachment_count)
  }
  case event {
    protocol.Committed(..) | protocol.MetadataChanged | protocol.GoalChanged ->
      updated
    protocol.Resumed(_) -> updated
    protocol.HeldInputReturned(..) -> updated
    protocol.Ignored(_) -> updated
    protocol.FullSnapshot(..)
    | protocol.StrandsSnapshot(..)
    | protocol.ModelsSnapshot(..)
    | protocol.SkillsSnapshot(..)
    | protocol.NotesSnapshot(..)
    | protocol.QueuedInputSnapshot(..)
    | protocol.ContextSnapshot(..)
    | protocol.WorktreeSnapshot(..)
    | protocol.LiveJobsSnapshot(..)
    | protocol.AdvisorPendingSnapshot(..)
    | protocol.BlockSummariesSnapshot(..)
    | protocol.BlockSummarized(..)
    | protocol.GoalSnapshot(..)
    | protocol.SchedulesSnapshot(..)
    | protocol.PermissionsSnapshot(..)
    | protocol.ConfigSnapshot(..)
    | protocol.EntryAdded(..)
    | protocol.StreamDelta(..)
    | protocol.ToolOutput(..)
    | protocol.OperationChanged(..)
    | protocol.UsageChanged(..)
    | protocol.EscalationPending(..)
    | protocol.ServerError(..) ->
      updated
      |> session_model.mark_activity
      |> session_model.invalidate_frame
  }
}

// A live-jobs board, taken into the session state when it answers this
// attachment's read, which `surfaces.receive_jobs` shows by clearing
// `jobs_awaiting`. The summary's job cursor is the terminal's, and it follows
// the job it pointed at in the board being replaced, so a taken board is
// recorded with the board it replaces for the terminal to move the cursor.
fn receive_jobs(
  shared: Shared(socket, recorder, source, replay_source),
  board: live_jobs.Board,
) -> Shared(socket, recorder, source, replay_source) {
  let received = surfaces.receive_jobs(shared, board)
  case received.jobs_awaiting == shared.jobs_awaiting {
    True -> received
    False ->
      session_model.record_surface(
        received,
        JobsReplaced(previous: shared.jobs, board:),
      )
  }
}

// A pushed summarizer label (protocol 050). A settled label rewrites a row
// the record cache holds, and so does a live one whose response has already
// committed, because the committed block borrows it until its own label
// arrives. Any other live label belongs to a row in the transient tail,
// which every projection rebuilds, and leaves the record cache standing.
fn receive_block_summary(
  shared: Shared(socket, recorder, source, replay_source),
  subject: block_summary.Subject,
  text: String,
) -> Shared(socket, recorder, source, replay_source) {
  let summaries = block_summary.receive(shared.summaries, subject, text)
  let recorded = case subject {
    block_summary.SettledBlock(..) -> True
    block_summary.LiveStream(generation:, ..) ->
      transcript_lines.response_recorded(shared.records, generation)
  }
  let valid = shared.record_cache_valid && !recorded
  shared
  |> shared_set.summaries(summaries)
  |> shared_set.record_cache_valid(valid)
  |> session_model.invalidate_transcript
}

// Restores a custody-returned prompt as a local draft (protocol-change/038).
//
// The daemon held the prompt only in memory, so the returned text must be
// retained before the socket closes. The return is session state first: it
// joins `Shared.returned_drafts`, addressed to the session and strand that
// submitted it, and the notice names the strand and the images the text
// cannot carry, so nothing about the return is invisible. The terminal moves
// it into the editor it owns, in `inbound.restore_returned_drafts`, when it
// applies this event, so the composer holds the text before the next frame
// arrives.
fn restore_returned_draft(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  kind: String,
  text: String,
  attachment_count: Int,
) -> Shared(socket, recorder, source, replay_source) {
  let returned = ReturnedDraft(session: shared.session, strand:, text:)
  let shared =
    Shared(
      ..shared,
      returned_drafts: list.append(shared.returned_drafts, [returned]),
    )
  let images = case attachment_count {
    0 -> ""
    n ->
      " · "
      <> int.to_string(n)
      <> " attachment(s) stayed on the dead daemon — re-attach them"
  }
  session_model.append_notice(
    shared,
    "daemon returned the "
      <> kind
      <> " prompt held for "
      <> strand
      <> " — restored as a draft"
      <> images,
  )
}

// One line per schedule, in the listing's own order — the operator's
// standing tables first, then what the session grew. `owner` is printed
// rather than derived: "operator" and a strand that happens to be called
// something similar are told apart by the server and never here.
fn append_schedules(
  shared: Shared(socket, recorder, source, replay_source),
  rows: List(protocol.ScheduleRow),
) -> Shared(socket, recorder, source, replay_source) {
  case rows {
    [] -> session_model.append_system(shared, "no schedules")
    rows -> {
      let listed =
        list.fold(rows, shared, fn(shared, row) {
          session_model.append_system(shared, schedule_line(row))
        })
      shared_set.notice(
        listed,
        int.to_string(list.length(rows)) <> " schedules",
      )
    }
  }
}

fn schedule_line(row: protocol.ScheduleRow) -> String {
  string.join(
    [
      row.name,
      row.target,
      row.owner,
      row.when,
      int.to_string(row.fired) <> " fired",
      case row.wake {
        protocol.WakesIdle -> "wakes"
        protocol.SteersOnly -> "steers"
      },
    ],
    "  ",
  )
}

fn set_strand_phase(
  strands: List(protocol.Strand),
  target: String,
  phase: String,
) -> List(protocol.Strand) {
  list.map(strands, fn(strand) {
    let Strand(id:, ..) = strand
    case id == target, phase {
      True, "done" -> Strand(..strand, live_phase: None)
      True, _ -> Strand(..strand, live_phase: Some(phase))
      False, _ -> strand
    }
  })
}

// Whether the strand's last reported phase was already `assistant`, which
// makes a further `assistant` transition a repeat rather than a new
// generation.
fn strand_was_generating(
  strands: List(protocol.Strand),
  target: String,
) -> Bool {
  list.any(strands, fn(strand) {
    strand.id == target && strand.live_phase == Some("assistant")
  })
}

// A client attaching near completion may have only a sampled preview, with
// no later delta before end. Transfer that exact sample into the bounded live
// region before adding the end marker; an older request's sample cannot qualify.
fn streams_before_end(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  operation: String,
  generation: String,
  kind: String,
) -> List(Stream) {
  use <- bool.guard(
    kind != "end"
      || stream_identity.response_entry(generation) == None
      || list.any(shared.streams, fn(stream) { stream.strand == strand }),
    shared.streams,
  )
  let preview =
    option.then(shared.captured, fn(captured) { captured.1.preview })
  case preview {
    Some(sample)
      if sample.operation == operation && sample.generation == generation
    ->
      case transcript_lines.response_recorded(shared.records, generation) {
        True -> shared.streams
        False -> [
          transcript_lines.preview_stream(strand, sample),
          ..shared.streams
        ]
      }
    _ -> shared.streams
  }
}

// A provider request owns all its fragment kinds. A new request replaces
// them together; an old terminal can retire only its own request. Completion
// comes from the same observer as deltas, independent of snapshot timing.
fn receive_stream(
  streams: List(Stream),
  strand: String,
  operation: String,
  generation: String,
  kind: String,
  text: String,
) -> List(Stream) {
  // Completion is final for this exact request. Late fragments cannot
  // reopen it, while a successor still replaces the whole old generation.
  use <- bool.guard(
    kind != "end"
      && list.any(streams, fn(stream) {
      stream.strand == strand
      && stream.operation == operation
      && stream.generation == generation
      && stream.kind == "end"
    }),
    streams,
  )
  case kind {
    "end" -> {
      let newer =
        list.any(streams, fn(stream) {
          stream.strand == strand
          && {
            stream.operation != operation || stream.generation != generation
          }
        })
      case newer {
        True -> streams
        False -> {
          // A named response remains visible until its exact record replaces
          // it. The marker suppresses stale previews without copying text.
          let retained =
            list.filter(streams, fn(stream) {
              stream.strand != strand
              || {
                stream.kind != "end"
                && stream_identity.response_entry(generation) != None
              }
            })
          [Stream(strand, operation, generation, "end", [], 0), ..retained]
        }
      }
    }
    _ -> {
      let retained =
        list.filter(streams, fn(stream) {
          stream.strand != strand
          || {
            stream.operation == operation
            && stream.generation == generation
            && stream.kind != "end"
          }
        })
      append_stream(retained, strand, operation, generation, kind, text)
    }
  }
}

fn append_stream(
  streams: List(Stream),
  strand: String,
  operation: String,
  generation: String,
  kind: String,
  fragment: String,
) -> List(Stream) {
  let fragment = owned(fragment)
  let width = string.byte_size(fragment)
  case streams {
    [] -> [
      Stream(
        strand:,
        operation:,
        generation:,
        kind:,
        fragments: [fragment],
        bytes: width,
      ),
    ]
    [
      Stream(
        strand: owner,
        operation: current_op,
        generation: current_generation,
        kind: stream_kind,
        fragments: current,
        bytes: held,
      ),
      ..rest
    ] ->
      case owner == strand && stream_kind == kind {
        // A fragment from a later operation replaces the previous answer
        // rather than continuing it. Tool-call fragments never accumulate at
        // all: only the latest name is renderable until the entry commits.
        True -> {
          let #(fragments, bytes) = case
            kind == "tool_call" || current_op != operation
          {
            True -> #([fragment], width)
            False -> bounded([fragment, ..current], held + width)
          }
          [
            Stream(strand:, operation:, generation:, kind:, fragments:, bytes:),
            ..rest
          ]
        }
        False -> [
          Stream(
            strand: owner,
            operation: current_op,
            generation: current_generation,
            kind: stream_kind,
            fragments: current,
            bytes: held,
          ),
          ..append_stream(rest, strand, operation, generation, kind, fragment)
        ]
      }
  }
}

// A delta's text is a slice of the whole frame the socket delivered, so a
// model that keeps the slice keeps the frame: an answer of a hundred thousand
// tokens pinned a hundred thousand frames, which is most of what the resident
// terminals were made of. Rebuilding the string owns its bytes and lets the
// frame go, and at token size the copy is a few dozen bytes. This is the same
// reason, and the same remedy, as `gateway.preview_text`.
fn owned(text: String) -> String {
  text |> string.to_utf_codepoints |> string.from_utf_codepoints
}

// Past the budget the fragments are collapsed into one holding the newest
// bytes. Dropping the oldest one at a time would be the length of the answer
// per token; collapsing pays that once per budget's worth of tokens and
// leaves a single fragment for the next batch to accumulate against. What the
// reader loses is the head of an answer that has not committed yet, and the
// durable record replaces the whole region the moment it does.
//
// The trigger is twice what the collapse keeps, and the headroom is the whole
// point: collapsing back to exactly the limit would put the next token over
// it again, and the amortised cost would be the copy paid per token rather
// than once per budget. So the region is bounded by twice `live_stream_limit`
// rather than by it, and that is the number the invariant states.
//
// The newest bytes are a slice of the joined answer, so keeping the slice
// would keep all of it: twice the limit held to show the limit. They are
// copied out, as `owned` does for a delta, once per collapse.
fn bounded(fragments: List(String), bytes: Int) -> #(List(String), Int) {
  case bytes <= transcript_lines.live_stream_limit * 2 {
    True -> #(fragments, bytes)
    False -> {
      let newest =
        fragments
        |> list.reverse
        |> string.concat
        |> newest_bytes(transcript_lines.live_stream_limit)
        |> owned
      #([newest], string.byte_size(newest))
    }
  }
}

// The trailing `limit` bytes, backing off to the next character boundary when
// the cut would land inside a multi-byte one. Four attempts covers the widest
// UTF-8 sequence.
fn newest_bytes(text: String, limit: Int) -> String {
  let bytes = bit_array.from_string(text)
  let size = bit_array.byte_size(bytes)
  newest_suffix(bytes, int.max(0, size - limit), 4)
}

fn newest_suffix(bytes: BitArray, from: Int, attempts: Int) -> String {
  case attempts {
    0 -> ""
    _ -> {
      let taken =
        bit_array.slice(bytes, from, bit_array.byte_size(bytes) - from)
        |> result.try(bit_array.to_string)
      case taken {
        Ok(text) -> text
        Error(_) -> newest_suffix(bytes, from + 1, attempts - 1)
      }
    }
  }
}

// The tails this strand's calls are printing, newest frame winning per
// `{strand, operation, step, source_index, call_id, stream}`. Order is kept stable — a
// replaced tail keeps its place and a new key goes to the end — so two
// streams of one command do not swap positions on screen every time one
// of them speaks.
fn receive_tail(tails: List(ToolTail), incoming: ToolTail) -> List(ToolTail) {
  let same_key = fn(tail: ToolTail) {
    tail.strand == incoming.strand
    && tail.operation == incoming.operation
    && tail.step == incoming.step
    && tail.source_index == incoming.source_index
    && tail.call_id == incoming.call_id
    && tail.stream == incoming.stream
  }
  case list.any(tails, same_key) {
    True ->
      list.map(tails, fn(tail) {
        case same_key(tail) {
          True -> incoming
          False -> tail
        }
      })
    False ->
      case list.length(tails) >= transcript_lines.max_tool_tails {
        True -> list.append(list.drop(tails, 1), [incoming])
        False -> list.append(tails, [incoming])
      }
  }
}

fn clear_tails(tails: List(ToolTail), strand: String) -> List(ToolTail) {
  list.filter(tails, fn(tail) { tail.strand != strand })
}

fn retire_recorded_tail(
  tails: List(ToolTail),
  record: protocol.EntryRecord,
) -> List(ToolTail) {
  let protocol.EntryRecord(strand:, entry:) = record
  case entry {
    entry.MessageEntry(
      message: message.ToolResultMessage(tool_call_id:, ..),
      ..,
    ) ->
      list.filter(tails, fn(tail) {
        tail.strand != strand || tail.call_id != tool_call_id
      })
    _ -> tails
  }
}

// Everything one usage row changes about the model.
//
// The row arrives once per settled generation, so this is both the moment
// the output rate is known and the moment the prompt cache can be judged.
// An unknown zero snapshot carries accounting uncertainty but no new reading.
// Both readings are per event rather than cumulative, which is why they sit
// here rather than in the status-line arithmetic over `model.usage`.
fn receive_usage(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  settled: message.Usage,
  last_usage: Option(message.Usage),
) -> Shared(socket, recorder, source, replay_source) {
  let usage = accounting.add_usage(shared.usage, settled)
  case option.then(last_usage, accounting.observed_usage) {
    None -> Shared(..shared, usage:)
    Some(last) -> receive_final_usage(shared, strand, last, usage)
  }
}

// A fallback total updates the ledger, while output rate and cache readings
// belong only to the final attempt retained beside it.
fn receive_final_usage(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  settled: message.Usage,
  usage: message.Usage,
) -> Shared(socket, recorder, source, replay_source) {
  let updated =
    settle_usage(
      shared,
      strand,
      settled,
      transcript_lines.tokens(usage.total_tokens) <> " tokens",
    )
  watch_cache(shared_set.usage(updated, usage), strand, settled)
}

// A network push is an observation of one durable row, not a second owner of
// session totals. A capture may already include its sequence, or a delayed
// push may arrive after that capture; only the capture sets cumulative usage.
// Sequence identity prevents duplicate pushes from resetting the cache clock.
// The cache comparison waits for a cut that covers this sequence, since a
// remote model change can reach the socket before its configuration capture.
// Which rows the ledger admits, holds and compares is `cache_watch`'s rule,
// shared with the web view.
fn receive_usage_observation(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  seq: Int,
  operation: Option(String),
  last_usage: Option(message.Usage),
) -> Shared(socket, recorder, source, replay_source) {
  case option.then(last_usage, accounting.observed_usage) {
    None -> shared
    Some(settled) ->
      receive_final_observation(shared, strand, seq, operation, settled)
  }
}

fn receive_final_observation(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  seq: Int,
  operation: Option(String),
  settled: message.Usage,
) -> Shared(socket, recorder, source, replay_source) {
  let covered = option.map(shared.captured, fn(shown) { { shown.0 }.next_seq })
  case
    cache_watch.admit(
      shared.cache,
      strand,
      seq,
      operation,
      settled,
      shared.stamp.now_ms,
      covered,
    )
  {
    Error(Nil) -> shared
    Ok(cache) -> {
      // A row newer than any this strand has shown is the agent's current
      // context size. The ledger's sequence guard is what keeps a delayed
      // push from replacing a newer reading in the strip.
      let observed =
        shared
        |> shared_set.cache(cache)
        |> shared_set.roster(agent_roster.observe_usage(
          shared.roster,
          strand,
          operation,
          agent_roster.context(settled),
        ))
        |> settle_usage(
          strand,
          settled,
          transcript_lines.tokens(settled.total_tokens) <> " tokens this turn",
        )
      case covered {
        Some(next_seq) -> settle_pending_cache(observed, next_seq)
        None -> observed
      }
    }
  }
}

/// Settles the pushed usage rows a cut covers.
///
/// A cut covers every committed row below `next_seq` and supplies the model
/// configuration needed to compare its usage safely. The ledger settles the
/// rows it covers; each miss they reveal becomes a notice, in the order the
/// ledger reports them.
///
/// ## Examples
///
/// ```gleam
/// let shared = event_fold.settle_pending_cache(shared, cut.next_seq)
/// ```
@internal
pub fn settle_pending_cache(
  shared: Shared(socket, recorder, source, replay_source),
  next_seq: Int,
) -> Shared(socket, recorder, source, replay_source) {
  let #(cache, missed) =
    cache_watch.settle(shared.cache, next_seq, cache_timing(shared))
  list.fold(missed, shared_set.cache(shared, cache), fn(current, found) {
    note_cache_miss(current, found.strand, found.miss)
  })
}

// The output rate and generation clock are per-row readings in both legacy
// replay and live observations. Their common settlement does not touch the
// cumulative usage figure, whose owner depends on the delivery path.
fn settle_usage(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  settled: message.Usage,
  notice: String,
) -> Shared(socket, recorder, source, replay_source) {
  // The settlement's own output count over the time since the request went
  // out. A settlement whose clock never started (a refusal, an empty turn)
  // leaves the last rate standing. `generation_clock` starts the clock only
  // for the active strand's own row, so only that strand's settlement may
  // read it or clear it — a sub-agent's row arriving mid-generation must
  // not report its own output over the primary's window, and must not stop
  // the primary's clock out from under it.
  let #(output_rate_tps, generation_started_ms) = case
    strand == shared.active_strand,
    shared.peer,
    shared.generation_started_ms
  {
    False, _, _ -> #(shared.output_rate_tps, shared.generation_started_ms)

    // The window is this client's own clock from the request going out to
    // the settlement, and a replay spends that window playing a file rather
    // than waiting on a provider. `output_rate_min_ms` already discards the
    // short ones, so a brief replay would report nothing anyway; a long one
    // would report how fast the replay ran. Declining outright is the same
    // rule that stops a replay echoing a prompt.
    True, Replaying, _ | True, Disconnected, _ -> #(
      shared.output_rate_tps,
      None,
    )

    True, Attached, Some(started) | True, Preview, Some(started) -> #(
      transcript_lines.output_rate(
        settled.output,
        shared.stamp.now_ms - started,
      ),
      None,
    )
    True, Attached, None | True, Preview, None -> #(
      shared.output_rate_tps,
      None,
    )
  }
  shared
  |> shared_set.generation_started_ms(generation_started_ms)
  |> shared_set.output_rate_tps(output_rate_tps)
  |> shared_set.notice(notice)
}

// Folds one row into its strand's cache watch and raises any notice it
// reveals.
//
// The clock is the terminal's own, the same one the frame pacing and the
// throughput reading use, because the gap being measured is wall time the
// operator spent away and no server field reports it. A replay plays its
// file far faster than the session originally ran, so the gaps it would
// measure are not the gaps that happened; it observes nothing.
fn watch_cache(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  settled: message.Usage,
) -> Shared(socket, recorder, source, replay_source) {
  let #(cache, missed) =
    cache_watch.observe(
      shared.cache,
      strand,
      settled,
      shared.stamp.now_ms,
      cache_timing(shared),
    )
  let watched = shared_set.cache(shared, cache)
  case missed {
    None -> watched
    Some(found) -> note_cache_miss(watched, found.strand, found.miss)
  }
}

// A watch describes one provider's prefix. A model change cannot inherit its
// horizon or compare the new provider's first row with the old provider's
// last row. Clear only the affected strand, leaving its historical notices
// and other strands' watches in place.
fn forget_cache(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
) -> Shared(socket, recorder, source, replay_source) {
  let shared =
    shared_set.cache(shared, cache_watch.forget(shared.cache, strand))

  // The footer's outlook label is the terminal's, and it describes the
  // active strand's watch alone, so only forgetting that one clears it.
  case strand == shared.active_strand {
    True -> session_model.record_surface(shared, OutlookCleared)
    False -> shared
  }
}

/// Records the strand's current model, forgetting the cache watch when the
/// model changed, since a cache written by one model does not serve another.
/// Forgetting the active strand's watch records `OutlookCleared`.
///
/// ## Examples
///
/// ```gleam
/// let shared = event_fold.select_model(shared, "claude-sonnet")
/// ```
@internal
pub fn select_model(
  shared: Shared(socket, recorder, source, replay_source),
  name: String,
) -> Shared(socket, recorder, source, replay_source) {
  let shared = case name == shared.current_model {
    True -> shared
    False -> forget_cache(shared, shared.active_strand)
  }
  shared_set.current_model(shared, name)
}

// Whether the instants this terminal hands the ledger are wall time: a
// replay's are not, and it observes nothing.
fn cache_timing(
  shared: Shared(socket, recorder, source, replay_source),
) -> cache_watch.Timing {
  case replaying(shared) {
    True -> cache_watch.Replayed
    False -> cache_watch.Live
  }
}

// A replay has no idle time of its own to report.
fn replaying(shared: Shared(socket, recorder, source, replay_source)) -> Bool {
  case shared.peer {
    Replaying -> True
    Attached | Preview | Disconnected -> False
  }
}

// Files one cache-miss row against the strand's transcript.
//
// The row is anchored to the records the strand already holds rather than
// appended to the local notice block, so it stays under the turn it
// explains as later entries arrive. A new row changes the projection, so
// the record cache is dropped whether or not the strand is the visible one:
// switching to it later must find the row in place.
fn note_cache_miss(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  miss: cache_miss.CacheMiss,
) -> Shared(socket, recorder, source, replay_source) {
  // A strand holding no record has nowhere to put the row: a window that
  // retained nothing, or a strand whose history this connection never
  // fetched. A notice anchored to no entry would never be drawn, so it is
  // not raised at all.
  case transcript_lines.newest_entry(shared.records, strand) {
    None -> shared
    Some(after_entry) ->
      Shared(
        ..{
          shared
          |> shared_set.record_cache_valid(False)
        },
        cache_notices: list.append(shared.cache_notices, [
          CacheNotice(
            strand:,
            after_entry:,
            text: cache_watch.notice_text(miss),
          ),
        ]),
      )
      |> session_model.invalidate_transcript
      |> session_model.invalidate_frame
  }
}

/// Formats the server-reported session usage for the terminal footer.
/// The generation clock after an event that may start it: started now
/// if the event is the active strand's and no clock is running, otherwise
/// left as it was. Two events may start it — the `assistant` phase, and
/// the first fragment as a fallback — and whichever comes first wins.
fn generation_clock(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
) -> Option(Int) {
  case shared.generation_started_ms, strand == shared.active_strand {
    None, True -> Some(shared.stamp.now_ms)
    started, _ -> started
  }
}

/// The local submitting marker closes the interval between writing a prompt
/// frame and receiving its first operation transition. Websocket ordering then
/// lets an immediate Escape place abort after prompt on the same connection,
/// even though the server's live phase has not reached the view yet.
///
/// ## Examples
///
/// ```gleam
/// let shared = event_fold.send_prompt_to(shared, "main", "carry on")
/// ```
@internal
pub fn send_prompt_to(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  text: String,
) -> Shared(socket, recorder, source, replay_source) {
  let sent = {
    let expected = expect_own_turn(shared, HeldPrompt(text))
    expected
    |> shared_set.submitting(Some(strand))
    |> shared_set.notice("prompt sent to " <> strand)
  }
  case shared.peer {
    Attached ->
      outbound.send_via(sent, fn(lane, now) {
        operator.submit(
          lane,
          shared.next_id,
          strand,
          text,
          operator.Prompt,
          now,
        )
      })

    // The server echoed this turn back as an entry, and the recording has
    // it. Drawing a local copy here would show the operator's line twice.
    Replaying -> sent
    Disconnected ->
      session_model.append_error(shared, "no conversation is attached")
    Preview ->
      shared
      |> shared_set.transcript(
        list.append(shared.transcript, [
          Line(User, composer.transcript_text(text, shared.details_expanded)),
          Line(Assistant, "Design-preview echo received."),
        ]),
      )
      |> shared_set.record_cache_valid(False)
      |> shared_set.notice("prompt accepted")
      |> session_model.invalidate_transcript
  }
}

/// Records one submission this terminal made to a running active strand, so
/// that the entry it eventually produces is accounted for.
///
/// For a `HeldPrompt` the record is also what the operator sees. A prompt
/// submitted to a running strand does not become an entry until the daemon
/// drains it, which is a whole turn away. Without a local copy the operator's
/// line simply vanishes for as long as the run lasts, and the natural reading
/// is that the keystroke was lost — which is what sent people looking for the
/// bug this answers. The echo is drawn under the live tail and retired by the
/// entry it stands for.
///
/// `Preview` draws its own echo and `Disconnected` sent nothing, so neither
/// records anything here. An idle strand does not either: nothing is held, its
/// entry is already on its way back, and two copies would be worse than a slow
/// one.
/// An attached submission waits in `awaiting_outcome` for the daemon's answer,
/// because a refusal is a real outcome here and the echo has to go back with
/// it. A replay has no daemon to answer, so its submission joins the list at
/// once and the recording's own entry retires it.
///
/// ## Examples
///
/// ```gleam
/// let shared = event_fold.expect_own_turn(shared, HeldPrompt("carry on"))
/// ```
@internal
pub fn expect_own_turn(
  shared: Shared(socket, recorder, source, replay_source),
  submission: Submission,
) -> Shared(socket, recorder, source, replay_source) {
  case shared.peer, session_model.active_strand_live(shared) {
    Attached, True ->
      shared_set.awaiting_outcome(shared, Some(submission))
      |> session_model.invalidate_transcript
    Replaying, True ->
      shared_set.queued(shared, in_commit_order(shared.queued, submission))
      |> session_model.invalidate_transcript
    Attached, False | Replaying, False | Preview, _ | Disconnected, _ -> shared
  }
}

/// Moves the submission awaiting its outcome into the list that waits for
/// its entry, because the daemon took it and will commit one.
///
/// ## Examples
///
/// ```gleam
/// let shared = event_fold.settle_own_turn(shared)
/// ```
@internal
pub fn settle_own_turn(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  case shared.awaiting_outcome {
    Some(submission) ->
      shared
      |> shared_set.queued(in_commit_order(shared.queued, submission))
      |> shared_set.awaiting_outcome(None)
    None -> shared
  }
}

/// Forgets the submissions an abort cancelled, keeping the ones it does not
/// reach.
///
/// The invariant this restores is the queue's: every submission in the list
/// is owed an entry. An abort breaks that for interjections alone, because
/// the steer and follow-up items still queued on the run are discarded with
/// the run instead of being committed. Left in place they would absorb the
/// entries the held prompts produce, and each prompt's echo would outlive the
/// line it stood for.
///
/// ## Examples
///
/// ```gleam
/// let shared = event_fold.abandon_interjections(shared)
/// ```
@internal
pub fn abandon_interjections(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  let held =
    list.filter(shared.queued, fn(submission) {
      case submission {
        Interjection -> False
        HeldPrompt(..) -> True
      }
    })

  // A submission still awaiting its outcome was sent to the same run, so an
  // interjection there is cancelled on the same grounds. A prompt keeps
  // waiting for the reply that is still coming for it.
  let awaiting = case shared.awaiting_outcome {
    Some(Interjection) -> None
    Some(HeldPrompt(..)) | None -> shared.awaiting_outcome
  }

  shared
  |> shared_set.queued(held)
  |> shared_set.awaiting_outcome(awaiting)
  |> session_model.invalidate_transcript
}

// Places one submission where the daemon will commit it.
//
// Submission order is not commit order, which is the trap here. An
// interjection joins the run that is already open and commits during it,
// while every held prompt waits for that run to settle — so a steer typed
// after a prompt was queued still commits first. Keeping the list in commit
// order is what lets `drained_echoes` stay a drop of the head, and it is the
// list's whole invariant: interjections first, in the order they were made,
// then the held prompts in the order the daemon drains them.
fn in_commit_order(
  queued: List(Submission),
  submission: Submission,
) -> List(Submission) {
  case submission {
    HeldPrompt(..) -> list.append(queued, [submission])
    Interjection -> {
      let #(interjections, held) =
        list.split_while(queued, fn(earlier) {
          case earlier {
            Interjection -> True
            HeldPrompt(..) -> False
          }
        })
      list.flatten([interjections, [submission], held])
    }
  }
}

// Retires the oldest outstanding submission when a user turn commits on the
// strand it was made on.
//
// `in_commit_order` holds the list in the order the daemon commits these, so
// the head is what the entry belongs to, and an interjection at the head
// absorbs the entry without touching the echo behind it — which is the whole
// reason steers and follow-ups are recorded here at all. Matching on the text
// instead would have to reproduce the server's authorship prefix and its
// block layout, and would still pick the wrong entry for two identical
// prompts.
//
// A second operator's prompt or steer on the same strand still retires the
// head early. That costs a queued marker one turn of visibility, and the
// entry it stood for still arrives in its place.
fn drained_echoes(
  queued: List(Submission),
  record: protocol.EntryRecord,
) -> List(Submission) {
  let protocol.EntryRecord(entry: value, ..) = record
  case value {
    entry.MessageEntry(message: message.UserMessage(..), ..) ->
      list.drop(queued, 1)
    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> queued
  }
}

fn settle_interrupt(
  shared: Shared(socket, recorder, source, replay_source),
  strand: String,
  phase: String,
) -> Shared(socket, recorder, source, replay_source) {
  case phase == "done", shared.interrupt {
    True, Some(Interrupt(strand: target, pending:, ..)) ->
      case target == strand, pending {
        True, Some(text) ->
          send_prompt_to(shared_set.interrupt(shared, None), target, text)
        True, None ->
          shared
          |> shared_set.interrupt(None)
          |> shared_set.notice(target <> ": interrupted")
        False, _ -> shared
      }
    _, _ -> shared
  }
}

/// Releases the observations that belong to the attachment being left: the
/// advisor's nudges, the summarizer labels and the goal, with the reads that
/// would refresh them.
///
/// Session observations belong to the attachment that read them. Reusing the
/// common strand name "main" cannot transfer advice or a goal.
///
/// ## Examples
///
/// ```gleam
/// let shared = event_fold.leave_session(shared)
/// ```
@internal
pub fn leave_session(
  shared: Shared(socket, recorder, source, replay_source),
) -> Shared(socket, recorder, source, replay_source) {
  shared
  |> shared_set.nudges(None)
  |> shared_set.nudges_refresh(worktree_view.Settled)
  |> shared_set.nudges_awaiting(None)
  |> shared_set.nudges_request(None)
  |> shared_set.summaries(block_summary.new())
  |> shared_set.goal(None)
  |> shared_set.goal_refresh(worktree_view.Settled)
  |> shared_set.goal_awaiting(None)
  |> shared_set.goal_request(None)
  |> shared_set.goal_report(HoldGoalReport)
}

/// Moves the session state from one session and strand to another: parks
/// the departing strand's history window, restores the arriving one's, and
/// clears the boards a different session does not share.
///
/// The editor half of the switch is the terminal's. This records a
/// `WorkspaceSwitched` fact naming both keys, and the terminal parks its
/// editor, attachments and viewport under the departing key and restores the
/// arriving key's when it applies the fact. A switch to the session and strand
/// already shown changes nothing and records nothing.
///
/// ## Examples
///
/// ```gleam
/// let shared = event_fold.select_workspace(shared, shared.session, "worker")
/// ```
@internal
pub fn select_workspace(
  shared: Shared(socket, recorder, source, replay_source),
  session: String,
  strand: String,
) -> Shared(socket, recorder, source, replay_source) {
  use <- bool.guard(
    shared.session == session && shared.active_strand == strand,
    shared,
  )

  let same_session = shared.session == session
  let shared = case same_session {
    True -> shared
    False -> leave_session(shared)
  }

  // Before the first attachment there is no previous session to park in.
  // Bind that unassigned editor to the explicitly chosen session once;
  // later switches keep their existing session identities and own drafts.
  let draft_session = case shared.session {
    "" -> session
    previous -> previous
  }
  let departing = #(draft_session, shared.active_strand)
  let arriving = #(session, strand)

  // The history window parks under the same key as the terminal's editor.
  // A strand with no parked window restores an empty one, which is what a
  // parked workspace without one held before the two were split.
  let parked_scrollback =
    dict.insert(shared.parked_scrollback, departing, shared.scrollback)
  let restored_scrollback =
    dict.get(parked_scrollback, arriving)
    |> result.lazy_unwrap(history_view.empty)
  Shared(
    ..session_model.record_surface(
      shared,
      WorkspaceSwitched(departing:, arriving:, previous_session: shared.session),
    ),
    agent_rows: case same_session {
      True -> shared.agent_rows
      False -> []
    },
    agent_messages: case same_session {
      True -> shared.agent_messages
      False -> []
    },
    advisor_history: case same_session {
      True -> shared.advisor_history
      False -> advisor_history.Board(items: [], unloaded: None)
    },
    todo_boards: case same_session {
      True -> shared.todo_boards
      False -> dict.new()
    },
    todo_seed: case same_session {
      True -> shared.todo_seed
      False -> None
    },
    todo_asked: case same_session {
      True -> shared.todo_asked
      False -> set.new()
    },
    reviewer_rows: case same_session {
      True -> shared.reviewer_rows
      False -> []
    },
    scrollback: history_view.cancel(restored_scrollback),
    parked_scrollback: dict.delete(parked_scrollback, arriving),
    roster: case same_session {
      True -> shared.roster
      False -> agent_roster.new()
    },
  )
}
