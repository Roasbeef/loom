//// What `<loom-dismiss>` decides: whether a press or a key closes the
//// disclosure it wraps.
////
//// The context figure in the bar is a native `<details>` (protocol-change/075).
//// The browser opens and closes it from its summary and knows nothing about
//// the rest of the page, so a panel left open stayed open over the strand
//// panel's tabs until the figure was pressed again. Whether a disclosure is
//// open is a fact about the browser, so closing it costs the server nothing
//// and never renders for it.
////
//// The server marks the disclosure with the fixed attribute `data-dismiss`
//// and the one word `keep`. A click is read only by the marks of the nodes it
//// passed through, never by a node's text, class or position: a press that
//// passed through the mark is inside the disclosure and leaves it as it is, so
//// the Refresh and Compact buttons do not close the panel they sit in, and a
//// press that did not is outside it and closes it. Escape closes it too, and
//// no other key does.
////
//// The module imports neither Lustre nor the DOM binding, so the tests load it
//// under Node.

import gleam/list

/// What a press or a key asks of the disclosure.
pub type Verdict {
  /// Close the disclosure. Closing one that is already closed changes nothing.
  Close

  /// Leave the disclosure as it is.
  Keep
}

/// What a node a click passed through is, by the server's fixed `data-dismiss`
/// attribute.
pub type Mark {
  /// The disclosure's own element.
  Inside
}

/// The mark a `data-dismiss` value names, or a refusal for any other word.
///
/// ## Examples
///
/// ```gleam
/// assert dismiss_rule.mark("keep") == Ok(dismiss_rule.Inside)
/// ```
pub fn mark(value: String) -> Result(Mark, Nil) {
  case value {
    "keep" -> Ok(Inside)
    _ -> Error(Nil)
  }
}

/// The verdict for a click that passed through nodes carrying `marks`.
///
/// ## Examples
///
/// ```gleam
/// assert dismiss_rule.after_click([]) == dismiss_rule.Close
/// ```
pub fn after_click(marks: List(Mark)) -> Verdict {
  case list.contains(marks, Inside) {
    True -> Keep
    False -> Close
  }
}

/// The verdict for a key. Escape closes the disclosure and no other key does.
///
/// ## Examples
///
/// ```gleam
/// assert dismiss_rule.after_key("Escape") == dismiss_rule.Close
/// ```
pub fn after_key(key: String) -> Verdict {
  case key {
    "Escape" -> Close
    _ -> Keep
  }
}
