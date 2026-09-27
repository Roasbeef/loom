//// Admits what the host received into the model, and reduces none of it.
////
//// The host receives traffic before each step: the conversation socket's
//// frames, the waiting attempt's frames, a replay's recorded events and the
//// background jobs' replies. Phase 2 of issue #530 put each into the buffer
//// or slot that waits for it (`runtime.receive`, `runtime.hold`), and the
//// reducers take from those buffers at fixed points: a tick drains them in a
//// fixed order, and a key drains the connection only after Escape has had
//// its chance to cancel a waiting command (ADR-010). This module is that
//// filing, as a pure function the step runs for `msg.Arrived`, so a host
//// that can only call `update`, a Lustre server component, delivers the
//// same traffic the terminal's host files directly.
////
//// Admission never reduces. It pushes a frame onto its inbox's buffer,
//// behind whatever the buffer already holds, and a job reply into the slot
//// that names its key. What the reducers later take is therefore exactly
//// what they took when the host filed the buffers itself, and every
//// ordering the drains keep is unchanged.
////
//// Admission never drops a frame for a reason of capacity. A dropped frame
//// is a gap in the lane's sequence, so the bound on what one step holds is
//// the host's to keep: the terminal's host reads no more from a mailbox
//// than a buffer has room for, and what it does not read waits in the
//// mailbox. A frame past the bound would be appended; the terminal's host
//// never sends one. A frame is dropped for one reason only: its source
//// subject is neither the adopted inbox's nor the waiting attempt's. An
//// adoption replaces the inbox whole, so such a frame came from a socket
//// the model no longer reads, and no message from a replaced inbox may
//// reach the reducer after the swap (the protocol model's S2).
////
//// A job reply whose slot no longer waits for it is dropped, and the two
//// that hold a resource queue its release, `CloseSocket` then `Discard` for
//// an attachment's `Prepared`, `CloseControl` for a relaunch's `Completed`
//// (`tui_model.release`). The release stays on the outbox, and the next
//// input's step returns it with its own effects, as it did in phase 2.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import tui/attachment
import tui/buffered
import tui/connection
import tui/job
import tui/model.{
  type Model, ActivityAsking, ActivityDue, ActivityResting, ControlRequest,
  Model, ReconnectAttempting, ReconnectIdle, ReconnectSpent,
} as tui_model
import tui/msg.{type Arrival}

/// Files each arrival, oldest first, into the buffer or slot that waits for
/// it.
///
/// ## Examples
///
/// ```gleam
/// let model = admission.admit(model, [msg.Frame(source, message)])
/// ```
@internal
pub fn admit(model: Model, arrivals: List(Arrival)) -> Model {
  list.fold(arrivals, model, admit_one)
}

fn admit_one(model: Model, arrival: Arrival) -> Model {
  case arrival {
    msg.Frame(source:, message:) -> admit_frame(model, source, message)
    msg.Replayed(event:) ->
      Model(..model, replay_inbox: buffered.push(model.replay_inbox, event))
    msg.JobReplied(arrival:) -> admit_reply(model, arrival)
  }
}

// The adopted inbox is asked first. A frame from the waiting attempt's
// socket goes to the attempt, which keeps it for the adopted lane if it
// arrives after the capture. Anything else came from a replaced socket.
fn admit_frame(
  model: Model,
  source: Subject(connection.Message),
  message: connection.Message,
) -> Model {
  case source == buffered.sender(model.inbox) {
    True -> Model(..model, inbox: buffered.push(model.inbox, message))
    False ->
      case attachment.push_frame(model.candidate, source, message) {
        Ok(candidate) -> Model(..model, candidate:)
        Error(Nil) -> model
      }
  }
}

// A reply goes to the slot of its kind only when that slot names the
// reply's key. Otherwise it belongs to a job no reducer waits for any more,
// one that was cancelled or whose slot moved on; that comparison of keys is
// the only fence a job reply passes.
fn admit_reply(model: Model, arrival: job.Arrival) -> Model {
  let admitted = case arrival {
    job.ControlArrived(key:, reply:) -> admit_control(model, key, reply)
    job.ReconnectArrived(key:, reply:) -> admit_reconnect(model, key, reply)
    job.ActivityArrived(key:, reply:) -> admit_activity(model, key, reply)
    job.ConfigurationArrived(key:, reply:) ->
      admit_configuration(model, key, reply)
    job.AttachArrived(key:, reply:) ->
      attachment.admit(model.candidate, key, reply)
      |> result.map(fn(candidate) { Model(..model, candidate:) })
  }
  case admitted {
    Ok(model) -> model
    Error(Nil) -> tui_model.release(model, arrival)
  }
}

fn admit_control(
  model: Model,
  key: job.Key,
  reply: job.ControlReply,
) -> Result(Model, Nil) {
  case model.control_request {
    None -> Error(Nil)
    Some(run) ->
      job.admit(run.job, key, reply)
      |> result.map(fn(awaiting) {
        Model(
          ..model,
          control_request: Some(ControlRequest(..run, job: awaiting)),
        )
      })
  }
}

fn admit_reconnect(
  model: Model,
  key: job.Key,
  reply: job.ReconnectReply,
) -> Result(Model, Nil) {
  case model.reconnect {
    ReconnectIdle | ReconnectSpent -> Error(Nil)
    ReconnectAttempting(job: awaiting) ->
      job.admit(awaiting, key, reply)
      |> result.map(fn(awaiting) {
        Model(..model, reconnect: ReconnectAttempting(awaiting))
      })
  }
}

fn admit_activity(
  model: Model,
  key: job.Key,
  reply: job.ActivityReply,
) -> Result(Model, Nil) {
  case model.activity_poll {
    ActivityDue | ActivityResting(..) -> Error(Nil)
    ActivityAsking(job: awaiting, asked:) ->
      job.admit(awaiting, key, reply)
      |> result.map(fn(awaiting) {
        Model(..model, activity_poll: ActivityAsking(awaiting, asked))
      })
  }
}

fn admit_configuration(
  model: Model,
  key: job.Key,
  reply: job.ConfigurationReply,
) -> Result(Model, Nil) {
  case model.configuring {
    None -> Error(Nil)
    Some(awaiting) ->
      job.admit(awaiting, key, reply)
      |> result.map(fn(awaiting) { Model(..model, configuring: Some(awaiting)) })
  }
}
