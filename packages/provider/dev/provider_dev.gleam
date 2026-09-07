//// Explicit, paid public Responses API smoke; never an automatic test.
////
//// Set OPENAI_API_KEY and LOOM_RESPONSES_MODEL, then run `gleam dev` from
//// packages/provider under a 90-second outer process deadline. The endpoint,
//// prompt, output cap and no-tool policy are fixed. An absent model or key
//// refuses before preparing work; this runner never discovers credentials.
//// The only accepted model is gpt-4.1-mini-2025-04-14, whose documented
//// context window is 1,047,576 tokens. Other model facts are not guessed.
////
//// The original drain monitor is installed before begin. One 60-second
//// terminal deadline is followed by cancellation and a five-second drain
//// observation, even after failure. A timeout is reported as unconfirmed,
//// never as successful cleanup. Output excludes request data and raw errors.

import core/clock
import core/codec
import core/json
import core/message
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import provider/gateway
import provider/http
import provider/model
import provider/secret
import provider/stream
import weft/poll

const smoke_model = "gpt-4.1-mini-2025-04-14"

/// Sends one small text request only when invoked explicitly.
///
/// ## Examples
///
/// With the two environment variables set, run from packages/provider:
/// `python3 ../../scripts/with_timeout.py 90 -- gleam dev`.
pub fn main() -> Nil {
  let secrets = secret.env()
  let verdict = case
    secret.lookup(secrets, "LOOM_RESPONSES_MODEL"),
    secret.lookup(secrets, "OPENAI_API_KEY")
  {
    Ok(selected), Ok(key) if selected == smoke_model && key != "" ->
      run(selected, secrets)
    _, _ ->
      Error(
        "Not sent: set the exact smoke model and a nonempty OPENAI_API_KEY.",
      )
  }

  // This dev-only assertion intentionally makes a failed smoke exit nonzero.
  // Its value is a constant safe verdict, never the request or live response.
  let assert Ok(Nil) = verdict as "Responses live smoke failed"
  Nil
}

fn run(selected: String, secrets: secret.SecretStore) -> Result(Nil, String) {
  let resolved =
    model.ResolvedModel(
      provider: "openai",
      model_id: selected,
      thinking: model.ThinkingOff,
      context_window: 1_047_576,
      max_output_tokens: 128,
    )
  let gw =
    gateway.new(http.httpc_transport(), secrets, clock.fixed(0))
    |> gateway.add_provider(gateway.OpenAiResponsesProvider(
      name: "openai",
      base_url: "https://api.openai.com/v1",
      api_key_secret: "OPENAI_API_KEY",
    ))
    |> gateway.with_attempt_timeout(60_000)
  let prepared =
    gateway.prepare(
      gw,
      model.ProviderRequest(
        target: model.ForResolved(resolved),
        system: None,
        messages: [
          message.UserMessage(
            content: [
              message.UserText("Reply with exactly: Responses smoke OK", None),
            ],
            timestamp: 0,
            origin: None,
          ),
        ],
        tools: [],
        max_output_tokens: Some(128),
      ),
    )
  let witness = stream.watch_drain(prepared.handle)
  prepared.begin()

  // Deltas are optional display data. Discarding them avoids retaining a second
  // answer and does not extend the absolute terminal deadline.
  let outcome =
    poll.until(within: 60_000, every: 1, attempt: fn() {
      case stream.next(prepared.handle, within: 0) {
        Ok(stream.Delta(_)) | Error(Nil) -> poll.Retry
        Ok(stream.Settled(..) as terminal) -> poll.Done(terminal)
        Ok(stream.Failed(..) as terminal) -> poll.Done(terminal)
      }
    })
  stream.cancel(prepared.handle)
  let drained = stream.await_drain(witness, within: 5000)
  case drained {
    stream.Drained -> io.println("drain: confirmed")
    stream.TimedOut -> io.println_error("drain: unconfirmed timeout")
    stream.ProofLost -> io.println_error("drain: original witness lost")
  }
  let terminal_result = case outcome {
    poll.Answered(terminal) -> print_terminal(terminal)
    poll.Expired -> Error("terminal: deadline expired")
    poll.Failed(Nil) -> Error("terminal: observation failed")
  }
  case drained {
    stream.Drained -> terminal_result
    stream.TimedOut -> Error("drain: unconfirmed timeout")
    stream.ProofLost -> Error("drain: original witness lost")
  }
}

fn print_terminal(terminal: stream.StreamEvent) -> Result(Nil, String) {
  case terminal {
    stream.Settled(settled, usage) -> {
      // Unexpected content is never printed. The exact success text is public
      // fixture data, so neither arbitrary output nor replay metadata can
      // disclose credentials through this runner's diagnostics.
      case stream.message(settled) {
        message.AssistantMessage(stop_reason:, ..) -> {
          io.println("terminal: " <> stop_category(stop_reason))
        }
        message.UserMessage(..)
        | message.ToolResultMessage(..)
        | message.CustomMessage(..) -> Nil
      }
      io.println("usage: " <> json.to_string(codec.encode_usage(usage)))
      case stream.message(settled) {
        message.AssistantMessage(
          stop_reason: message.Stop,
          content: [message.AssistantText("Responses smoke OK", _)],
          ..,
        ) -> {
          io.println("Responses smoke OK")
          Ok(Nil)
        }
        message.AssistantMessage(..)
        | message.UserMessage(..)
        | message.ToolResultMessage(..)
        | message.CustomMessage(..) ->
          Error("terminal: expected Stop with the exact smoke answer")
      }
    }
    stream.Failed(error) -> Error("terminal: " <> failure_category(error))
    stream.Delta(_) -> Error("terminal: unexpected delta")
  }
}

fn stop_category(reason: message.StopReason) -> String {
  case reason {
    message.Pending -> "pending"
    message.Stop -> "stop"
    message.Length -> "length"
    message.ToolUse -> "tool use"
    message.Errored -> "error"
    message.Aborted -> "aborted"
    message.Deferred -> "deferred"
  }
}

fn failure_category(error: stream.ProviderError) -> String {
  case error {
    stream.ProviderCancelled -> "cancelled"
    stream.CancellationUnconfirmed -> "cancellation unconfirmed"
    stream.DrainProofLost -> "drain proof lost"
    stream.TransportFailed(_) -> "transport failed"
    stream.HttpError(status:, ..) -> "HTTP " <> int.to_string(status)
    stream.StreamError(..) -> "provider stream error"
    stream.StreamDisconnected(_) -> "stream disconnected"
    stream.MalformedStream(_) -> "malformed stream"
    stream.UnmappedStopReason(_) -> "unmapped stop reason"
    stream.NoIdentity(_) -> "no identity"
    stream.UnknownProvider(_) -> "unknown provider"
    stream.NoSecret(..) -> "missing secret"
  }
}
