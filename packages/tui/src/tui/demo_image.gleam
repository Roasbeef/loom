//// One image in the `--demo` transcript, so the drawn box can be seen end to
//// end in a real terminal.
////
//// The demo is a preview with no session behind it, so its transcript is
//// lines and has no entries. A box is drawn from an image found again in the
//// strand's entries, so the demo seeds three: a prompt, the call that read
//// `plots/latency.png`, and the result that returned it. The image is a
//// complete 480 by 280 PNG, a bar chart in flat colours that is under two
//// kilobytes, so a picture drawn at the wrong size or place is obvious.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/list
import gleam/option.{None}
import session_view/model as _
import session_view/protocol
import session_view/shared_set
import tui/inbound
import tui/model.{type Model, Model}

/// The demo model with the image's three entries added to main's records.
///
/// ## Examples
///
/// ```gleam
/// let model = demo_image.seed(model)
/// ```
pub fn seed(model: Model) -> Model {
  Model(
    ..model,
    shared: shared_set.records(
      model.shared,
      list.map(entries(), fn(value) {
        protocol.EntryRecord(strand: "main", entry: value)
      }),
    ),
  )
}

fn entries() -> List(entry.Entry) {
  [
    message_entry(
      1,
      message.UserMessage(
        [message.UserText("Look at plots/latency.png.", None)],
        1,
        None,
      ),
    ),
    message_entry(
      2,
      message.AssistantMessage(
        [
          message.AssistantToolCall(message.ToolCall(
            "demo-read",
            "fs_read",
            json.Object([#("path", json.String("plots/latency.png"))]),
            None,
            None,
          )),
        ],
        "demo",
        "baseten",
        "moonshotai/Kimi-K3",
        None,
        None,
        None,
        inbound.zero_usage(),
        message.Stop,
        None,
        None,
        None,
        None,
        2000,
      ),
    ),
    message_entry(
      3,
      message.ToolResultMessage(
        "demo-read",
        "fs_read",
        [message.ToolResultImage(data: chart(), mime_type: "image/png")],
        None,
        None,
        None,
        False,
        3000,
      ),
    ),
  ]
}

fn message_entry(n: Int, value: message.AgentMessage) -> entry.Entry {
  entry.MessageEntry(
    ids.mint_entry(ids.generator(clock.fixed(n), n)).0,
    None,
    n,
    n * 1000,
    value,
    False,
  )
}

/// The demo's image, as base64: a complete 480 by 280 PNG bar chart in flat
/// colours. The tests use it too, so it exists once.
///
/// ## Examples
///
/// ```gleam
/// assert string.starts_with(demo_image.chart(), "iVBORw0KGgo")
/// ```
pub fn chart() -> String {
  "iVBORw0KGgoAAAANSUhEUgAAAeAAAAEYCAIAAAALd7K2AAAHHklEQVR42u3Yu6kCYRSFUcsQ"
  <> "DGxkKpgWBgswMbMNezCxC8EqTGzA0MRYQ0FQxONjO67N18Avl3UPMziZmVnkBn4CMzNAm5kZ"
  <> "oM3Megb0cDSWJH0xQEsSoCVJgJYkQEuSAC1JgAa0JAFakgRoSQK0JAnQkgRoSRKgJUmAliRA"
  <> "S5IALUmAliQBWpIADWhJArQkCdCSUjtEDtCSBGhASwI0oCUJ0ICWBGhASxKgAS0J0IAGtCRA"
  <> "A1qSAA1oSYAGtCQBGtCSAA1oQEsCNKAlCdCAlgRoQEsSoAEtCdCA9tcjCdCAlgRoQANaEqAB"
  <> "LUmABrQkQANakgANaEmABjSgJQEa0JIEaEBLAjSgJQnQgJYEaEADWhKgAS0J0IAGtCRA9wXo"
  <> "pu0k6a1lAp3z+7igJbmgfeKQJEADWhKgAS3pc21Wx8AADWhJgAY0oCVAAxrQkgANaEBLgAY0"
  <> "oCUBGtCAlgANaEBLAjSgAS0J0IAGtARoQANaEqABDWgJ0IAGtCRAAxrQkgANaEBLgAY0oCUB"
  <> "GtCAlgANaEBLAjSgAS0BGtCAlgRoQANaEqABDWgJ0IAGtCRAAxrQEqABDWhJgAY0oCUBGtCA"
  <> "lgANaEBLAjSgAS0BGtCAlgRoQANaAjSgAQ1oCdCABrQkQAMa0BKgAQ1oSYAGNKAlQAMa0NJv"
  <> "NdvtAwM0oAEtARrQgJYADWhAA1oCNKABDWgBGtCABrQEaEADGtACNKABDWgJ0IAGNKAlQAMa"
  <> "0BKgAQ1oQEuABjSgAS1AAxrQgJYADWhAA1oCNKABLQEa0IAGtARoQAP6sqbtpJ8uE+jKizKB"
  <> "rrwoE+icv2EXtFzQLmgXtE8cEqABDWhAS4AGNKAlQAMa0ICWAA1oQANagAY0oAEtARrQgAa0"
  <> "AA1oQANaAjSgAQ1oCdCABrQEaEADGtASoAENaEAL0IAGNKAlQAMa0ICWAA1oQEuABjSgAS0B"
  <> "GtCABrQADWhAA1oCNKABDWg91mK7DAzQgAY0oAVoQAMa0AI0oAENaEAL0IAGNKAFaEADGtCA"
  <> "FqABDWhAAwvQgAY0oAEtQAMa0IAGtAANaEADWoAGNKABDWgBGtCABrQADWhAAxrQAjSgAQ1o"
  <> "QAvQgAY0oAVoQAMa0IAWoAENaEAL0IAGNKABLUADGtCABjSgAQ1oQANagAY0oAENaAEa0IAG"
  <> "tAANaEADGtACNKABDWgBGtCABjSgBWhAAxrQgBagAQ1oQAvQgAY0oAEtQAMa0IAWoAENaEAD"
  <> "WoAGNKABDWhAAxrQgAa0AA1oQAMa0AI0oAENaAEa0IAGNKAFaEADGtACNKABDeg0oJu2051O"
  <> "62lglRdlAl15USbQlRdlAl15USbQQc64oJ/8zxYJtAvaBe2C9olDgAY0oAENaEADGtCABjSg"
  <> "AQ1oQAMa0IAGNKABDWhAAxrQgAY0oAENaEADGtCABjSgAQ1oQAvQgAY0oAENaEADGtCABjSg"
  <> "AQ1oQAMa0IAGNKABDWhAAxrQgAa0AA1oQAMa0IAGNKABDWhAAxrQgAY0oAENaEADGtCABjSg"
  <> "AQ1oQAMa0IAGNKABDWhAAxrQgAY0oAENaEADGtCABjSgAQ1oQAMa0IAGNKABDWhAAxrQgAY0"
  <> "oAENaAEa0IAGNKABDWhAAxrQgAY0oAENaEADGtCABjSgAQ1oQAMa0IAGNKABDWhAAxrQgAY0"
  <> "oAENaEADGtCABjSgAQ1oQAMa0IAGNKABDegb7SfzwAANaEADGtCABjSgAQ1oQAMa0IAGNKAB"
  <> "DWhAAxrQgAY0oAENaEADGtCABjSgAQ1oQAMa0IAGNKABDWhAAxrQgAY0oAENaEADGtCABjSg"
  <> "AQ1oQAMa0IAGNKABDWhAAxrQgAY0oAENaEADGtCABjSgAQ1oQAMa0IAGNKABDWhAAxrQgAY0"
  <> "oAENaEADGtCABjSgAQ1oQAMa0IDuI9BN272wTKArL8oEuvKiTKArL8oEuvKiTKArL8oE+rX6"
  <> "lZxxQbugXdAuaBe0TxyABjSgAQ1oQAMa0IAGNKABDWhAAxrQgAY0oAENaEADGtCABjSgAQ1o"
  <> "QAMa0IAGNKABDWhAAxrQgAY0oAENaEADGtCABjSgAQ1oQAMa0IAGNKABDWhAAxrQgAY0oAEN"
  <> "aEADGtCABjSgAQ1oQAMa0IAGNKABDWhAAxrQgAY0oAENaEADGtCABjSgAQ1oQAMa0IAGNKAB"
  <> "DWhAAxrQgAY0oAENaEADGtCABjSgAQ1oQAMa0IAGNKABDWhAAxrQgAY0oAENaEADGtCABjSg"
  <> "AQ1oQAMa0IAGNKABDWhAAxrQgAY0oAENaEADGtCABjSgAQ1oQAMa0IAGNKABDWhAAxrQgAY0"
  <> "oAEN6D8AWpIEaEkCtCQJ0JIEaEBLEqAlSYCWJEBLkgAtSYCWJAFakgRoSQK0JAnQkgRoSRKg"
  <> "JQnQ10CbmVnOAG1mBmgzMwO0mVkPdgai/WxNFkeYrQAAAABJRU5ErkJggg=="
}
