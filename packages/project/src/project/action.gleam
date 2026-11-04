//// What a person may do with a ticket right now, decided once by the engine so
//// that no client derives it.
////
//// A terminal that offered a retry only for a blocked or failed ticket, and a
//// web page that offered a button only for a ticket it had not seen end, each
//// reimplemented a rule the engine already enforces, and the two disagreed
//// with the engine and with each other. The list here is the engine's own
//// answer: an action is available exactly when the event that performs it
//// would be accepted and would change the ticket. The statem check holds the
//// two together by applying every action's event to every ticket it reaches.
////
//// | action | the event | available when |
//// | --- | --- | --- |
//// | `Answer` | `Answered` | the ticket is open and a question is open |
//// | `Close` | `PersonClosed` | the ticket is open |
//// | `Retry` | `RetryRequested` | the ticket is open, has no session and is not already in line for one |
//// | `Publish` | `PersonPublished` | the ticket is open and has a head |
//// | `Stop` | `PersonStopped` | the mandate stands |
////
//// Open means the mandate stands and the ticket has not ended. The host may
//// withdraw `Publish` further, because whether the project lets it push is
//// the owner's setting and not the engine's.

import gleam/list
import gleam/option.{None}
import project/model.{Asking, NoQuestion, Satisfied}
import project/state.{type Ticket, Granted}

/// Something a person can do with a ticket.
pub type Action {
  /// Answer the worker's open question.
  Answer

  /// Accept the work and close the ticket, keeping its mandate.
  Close

  /// Ask for a new worker.
  Retry

  /// Publish the ticket's head past the check.
  Publish

  /// Withdraw the mandate for good.
  Stop
}

/// The actions a ticket offers now, in the order a client lists them.
///
/// ## Examples
///
/// ```gleam
/// // -> [Close, Retry, Publish, Stop] for an idle ticket with a head
/// ```
pub fn available(ticket: Ticket) -> List(Action) {
  let open = ticket.authority == Granted && ticket.outcome == None

  [
    #(Answer, open && asking(ticket)),
    #(Close, open),
    #(
      Retry,
      open
        && state.active_assignment(ticket) == None
        && ticket.demand == Satisfied,
    ),
    #(Publish, open && ticket.head != None),
    #(Stop, ticket.authority == Granted),
  ]
  |> list.filter(fn(offer) { offer.1 })
  |> list.map(fn(offer) { offer.0 })
}

fn asking(ticket: Ticket) -> Bool {
  case ticket.question {
    Asking(_) -> True
    NoQuestion -> False
  }
}

/// The action's word on the wire.
///
/// ## Examples
///
/// ```gleam
/// assert action.word(action.Close) == "close"
/// ```
pub fn word(action: Action) -> String {
  case action {
    Answer -> "answer"
    Close -> "close"
    Retry -> "retry"
    Publish -> "publish"
    Stop -> "stop"
  }
}
