//// What the session page's "make shareable" control is doing (protocol-change/065,
//// the addendum on making a session shareable).
////
//// A session created private cannot be shared, and the page says so where the
//// invitation buttons would be (`invites.Unshareable`). For the owner's page the
//// same place offers one button that stops the session, moves it to its own
//// history and resumes it, as one task in the daemon. That task changes a
//// running session, so the button asks first, in place, and the question lives
//// only in the page's server-side model: a browser can press the button, and can
//// press the confirm that follows it, and can send nothing else.
////
//// The control is a second, smaller machine beside the invitation control's own
//// state. The invitation control decides whether the buttons or the sentence are
//// drawn; this decides what the sentence's button is doing.
////
//// ## Transitions
////
//// <!-- transitions: shareables.Move -->
////
//// | state | the button is pressed | Make shareable is pressed | Cancel is pressed | the daemon answers |
//// | --- | --- | --- | --- | --- |
//// | `Withheld` | nothing | nothing | nothing | nothing |
//// | `Idle` | `Confirming` | nothing | nothing | nothing |
//// | `Confirming` | stays `Confirming` | `Making`, and the task starts | `Idle` | nothing |
//// | `Making` | nothing | nothing | nothing | `Idle` when it was done, `Refused` when it was not |
//// | `Refused` | `Confirming` | nothing | `Idle` | nothing |

import web_view/grants

/// The control's state.
pub type Move {
  /// The page's principal cannot make the session shareable, or the session
  /// already can be shared. The page draws no control.
  Withheld

  /// The button is drawn and waits to be pressed.
  Idle

  /// The button was pressed once. The page asks the question in its place and
  /// waits for the confirm or for Cancel.
  Confirming

  /// The task is running in the daemon. The button is gone and the page says the
  /// session is being made shareable. A press meanwhile asks nothing, so one
  /// confirm starts at most one task.
  Making

  /// The daemon made nothing shareable, or left the session short of resumed,
  /// and the page says why in the reason's fixed words (`grants.reason_words`).
  Refused(reason: grants.Reason)
}
