//// `loom ui --device` and `loom ui --origin` (protocol-change/052, the
//// addendum): how the words parse, which listed origin a link is built on,
//// how the request and the `hello`'s origins cross the wire, and that the
//// QR code printed beside the link decodes back to it.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import qrkit/decode
import tui
import tui/daemon/protocol
import tui/device_code

const served = "https://obelisk.tail0a99b.ts.net:8443"

const other = "https://loom.example.com"

// --- the words ---------------------------------------------------------------

// `--device` asks for a device ticket on a listed origin, the only one unless
// `--origin` names one, and `--origin` alone moves an ordinary link onto a
// listed origin. Without either the link is the loopback one, as before.
pub fn device_and_origin_parse_test() {
  let assert Ok(device) = tui.view_request(["--device"])
  assert device.ticket == tui.DeviceTicket
  assert device.origin == tui.ListedOrigin(None)
  assert device.session == None

  let assert Ok(picked) =
    tui.view_request(["--origin", served, "--device", "--state-dir", "/s"])
  assert picked.ticket == tui.DeviceTicket
  assert picked.origin == tui.ListedOrigin(Some(served))

  let assert Ok(moved) =
    tui.view_request(["--session", "s", "--origin", served])
  assert moved.ticket == tui.PageTicket
  assert moved.origin == tui.ListedOrigin(Some(served))
  assert moved.session == Some("s")

  let assert Ok(plain) = tui.view_request([])
  assert plain.ticket == tui.PageTicket
  assert plain.origin == tui.LoopbackOrigin

  // Both spellings of the command reach the same parser.
  let assert Ok(spelled) = tui.launch_view(["--ui", "--device"])
  assert spelled.ticket == tui.DeviceTicket
}

// A device link opens the home and always sets a login, so it refuses a
// session and `--no-remember`; an `--origin` with no value is refused rather
// than read as loopback.
pub fn device_refuses_what_it_cannot_honour_test() {
  let assert Error(session) = tui.view_request(["--device", "--session", "s"])
    as "a device link names no session"
  assert string.contains(session, "--device")
  let assert Error(forget) = tui.view_request(["--device", "--no-remember"])
    as "a device link always signs in"
  assert string.contains(forget, "--no-remember")
  let assert Error(missing) = tui.view_request(["--device", "--origin"])
    as "an origin needs a value"
  assert string.contains(missing, "--origin")
}

// --- which listed origin -----------------------------------------------------

// No origin listed refuses and names the key to set; one listed is used; two
// listed need `--origin`; an asked origin is matched after the daemon's own
// normalization and must be listed.
pub fn the_listed_origin_is_chosen_or_refused_test() {
  let assert Error(none) = tui.listed_origin([], None) as "nothing is listed"
  assert string.contains(none, "ui_origins")
  assert string.contains(none, "[daemon]")
  let assert Error(_) = tui.listed_origin([], Some(served))
    as "nothing is listed, whatever is asked"

  assert tui.listed_origin([served], None) == Ok(served)
  assert tui.listed_origin([served], Some(served)) == Ok(served)

  let assert Error(several) = tui.listed_origin([served, other], None)
    as "two listed need a choice"
  assert string.contains(several, served)
  assert string.contains(several, other)
  assert string.contains(several, "--origin")

  assert tui.listed_origin([served, other], Some(other)) == Ok(other)
  assert tui.listed_origin(
      [served, other],
      Some("HTTPS://Loom.Example.com:443/"),
    )
    == Ok(other)
  assert tui.listed_origin([served, other], Some(served <> "/")) == Ok(served)

  let assert Error(unlisted) =
    tui.listed_origin([served, other], Some("https://evil.example"))
    as "an unlisted origin is refused"
  assert string.contains(unlisted, "https://evil.example")
  assert tui.listed_origin(
      [served],
      Some("http://obelisk.tail0a99b.ts.net:8443"),
    )
    |> result.is_error
}

pub fn the_device_lifetime_is_said_in_minutes_test() {
  assert tui.device_lifetime(600_000) == "10 minutes"
  assert tui.device_lifetime(60_000) == "1 minute"
  assert tui.device_lifetime(59_000) == "59 seconds"
}

// --- the wire ----------------------------------------------------------------

// A device link is `ui.link` with `device: true`, and the operator's page is
// named as for the home's link.
pub fn a_device_link_is_a_ui_link_with_device_set_test() {
  let epoch = protocol.Epoch("current")
  assert protocol.encode(1, protocol.UiDeviceLink(protocol.OperatorPage), epoch)
    == Ok(
      "{\"v\":2,\"id\":1,\"cmd\":\"ui.link\",\"body\":{\"device\":true,\"page\":\"operator\"}}",
    )
  assert protocol.encode(1, protocol.UiDeviceLink(protocol.ObserverPage), epoch)
    == Ok("{\"v\":2,\"id\":1,\"cmd\":\"ui.link\",\"body\":{\"device\":true}}")
  assert !protocol.mutates(protocol.UiDeviceLink(protocol.OperatorPage))
}

fn hello(ui: String) {
  protocol.decode(
    "{\"v\":2,\"event\":\"hello\",\"body\":{\"protocol\":2,\"epoch\":\"e\",\"principal\":\"owner\",\"limits\":{\"control_bytes\":65536},\"ui\":"
    <> ui
    <> "}}",
  )
}

// The hello's view keeps the listed origins; a daemon that lists none, or
// predates the field, is the empty list; a malformed list refuses the hello.
pub fn the_hello_keeps_the_listed_origins_test() {
  let view = fn(ui) {
    case hello(ui) {
      Ok(protocol.Greeting(greeting)) -> Ok(greeting.view)
      _ -> Error(Nil)
    }
  }
  assert view("{\"path\":\"/ui\",\"origins\":[\"" <> served <> "\"]}")
    == Ok(protocol.WebViewAt("/ui", [served]))
  assert view("{\"path\":\"/ui\"}") == Ok(protocol.WebViewAt("/ui", []))
  assert view("{\"path\":\"/ui\",\"origins\":[\"http://box.example\"]}")
    == Error(Nil)
  assert view("{\"path\":\"/ui\",\"origins\":\"" <> served <> "\"}")
    == Error(Nil)
  assert view("{\"path\":\"/ui\",\"origins\":[\"\"]}") == Error(Nil)
  let many = list.repeat("\"" <> served <> "\"", 17) |> string.join(",")
  assert view("{\"path\":\"/ui\",\"origins\":[" <> many <> "]}") == Error(Nil)
}

// --- the code ----------------------------------------------------------------

// The code drawn for a link decodes back to exactly that link, and every line
// of the drawing is black on white whatever the terminal's own colours are.
pub fn the_qr_code_decodes_back_to_the_link_test() {
  let link =
    served
    <> "/ui/home?ticket=6f1d0c9e2b7a4f3a8c5e1d0b9a7f6e5d4c3b2a1908f7e6d5c4b3a29180f7e6d5"
  let assert Ok(rows) = device_code.rows(link) as "the link encodes"
  let assert Ok(decoded) = decode.from_rows(rows) as "the code decodes"
  assert decode.text(decoded) == link

  let assert Ok(drawn) = device_code.render(link) as "the code draws"
  let lines = string.split(drawn, "\n")
  assert lines != []
  assert list.all(lines, fn(line) {
    string.starts_with(line, "\u{1b}[30;47m")
    && string.ends_with(line, "\u{1b}[0m")
  })
}
