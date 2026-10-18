//// The listed web-view origins (protocol-change/052): which entries of
//// `[daemon] ui_origins` parse and how they are normalized, which `Host`
//// headers name a listed origin, and how the origin a request is admitted
//// under chooses its socket rule, its cookie names and attributes, and its
//// content security policy.

import client/daemon/ui_http
import client/daemon/ui_origin
import gleam/dict
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import qcheck
import tom

// The origin most of this file is checked against: a daemon behind
// Tailscale Serve on a fixed HTTPS port.
const served = "https://obelisk.tail0a99b.ts.net:8443"

fn listed(entry: String) -> ui_origin.Origin {
  let assert Ok(origin) = ui_origin.parse(entry) as "the entry parses"
  origin
}

fn get(headers: List(#(String, String))) {
  let base =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/ui/sessions/s")
  list.fold(headers, base, fn(request, header) {
    request.set_header(request, header.0, header.1)
  })
}

// --- the entry grammar -------------------------------------------------------

// A good entry is normalized the way a browser writes it: the scheme and host
// lowercased, a lone trailing slash dropped, and the default port left out.
pub fn a_good_entry_is_normalized_as_a_browser_writes_it_test() {
  let shown = fn(entry) {
    ui_origin.parse(entry) |> result.map(ui_origin.to_string)
  }
  assert shown(served) == Ok(served)
  assert shown("HTTPS://Obelisk.Tail0a99b.TS.net:8443/")
    == Ok("https://obelisk.tail0a99b.ts.net:8443")
  assert shown("https://loom.example.com") == Ok("https://loom.example.com")
  assert shown("https://loom.example.com:443") == Ok("https://loom.example.com")
  assert shown("https://100.64.0.7:8443") == Ok("https://100.64.0.7:8443")
  assert shown("https://[fd7a:115c:a1e0::1]:8443")
    == Ok("https://[fd7a:115c:a1e0::1]:8443")
  assert ui_origin.host(listed(served)) == "obelisk.tail0a99b.ts.net:8443"
  assert ui_origin.host(listed("https://loom.example.com:443"))
    == "loom.example.com"
}

// A bad entry is refused with words that name it, so the daemon's startup
// error points at the line to fix.
pub fn a_bad_entry_is_refused_naming_it_test() {
  let refused = [
    "http://obelisk.tail0a99b.ts.net:8443",
    "obelisk.tail0a99b.ts.net:8443",
    "wss://obelisk.tail0a99b.ts.net:8443",
    "https://",
    "https:///",
    "https://obelisk.tail0a99b.ts.net:8443/ui",
    "https://obelisk.tail0a99b.ts.net:8443//",
    "https://obelisk.tail0a99b.ts.net:8443?x=1",
    "https://obelisk.tail0a99b.ts.net:8443#top",
    "https://owner@obelisk.tail0a99b.ts.net:8443",
    "https://obelisk.tail0a99b.ts.net:0",
    "https://obelisk.tail0a99b.ts.net:65536",
    "https://obelisk.tail0a99b.ts.net:+8443",
    "https://obelisk.tail0a99b.ts.net:",
    "https://obelisk.tail0a99b.ts.net:84:43",
    "https://obelisk..ts.net",
    "https://-obelisk.ts.net",
    "https://obelisk_box.ts.net",
    "https://obelisk.ts.net.",
    "https://ob%65lisk.ts.net",
    "https://[fd7a::1",
    "https://[]:8443",
    "https://[::1]:8443",
    "https://localhost:8443",
    "https://127.0.0.1:8443",
    "https://obelisk.ts.net :8443",
  ]
  list.each(refused, fn(entry) {
    let assert Error(reason) = ui_origin.parse(entry) as "the entry is refused"
    assert string.contains(reason, "\"" <> entry <> "\"")
    assert string.starts_with(reason, "ui_origins entry ")
  })
  let assert Error(http) = ui_origin.parse("http://box.example")
    as "http is refused"
  assert string.contains(http, "must use https")
}

// The `[daemon]` table's list: absent is empty, a repeated origin is kept
// once, and a value that is not an array of good strings is refused.
pub fn the_daemon_table_lists_the_origins_test() {
  let read = fn(text) {
    let assert Ok(document) = tom.parse(text) as "the fixture is TOML"
    ui_origin.from_document(document)
    |> result.map(list.map(_, ui_origin.to_string))
  }
  assert ui_origin.from_document(dict.new()) == Ok([])
  assert read("[daemon]\nui = true\n") == Ok([])
  assert read("[daemon]\nui_origins = []\n") == Ok([])
  assert read(
      "[daemon]\nui_origins = [\"" <> served <> "\", \"" <> served <> "/\"]\n",
    )
    == Ok([served])
  assert read("[daemon]\nui_origins = \"" <> served <> "\"\n")
    == Error("daemon.ui_origins must be an array of strings")
  assert read("[daemon]\nui_origins = [1]\n")
    == Error("daemon.ui_origins entries must be strings")
  assert read("[daemon]\nui_origins = [\"http://box.example\"]\n")
    |> result.is_error
  let many =
    list.repeat("\"https://box.example\"", ui_origin.max_origins + 1)
    |> string.join(", ")
  assert read("[daemon]\nui_origins = [" <> many <> "]\n") |> result.is_error
}

// --- which Host names a listed origin ----------------------------------------

// The listed name matches in any letter case and only on its own port; an
// explicit `:443` is the default port, and a trailing dot is another name.
pub fn a_host_names_a_listed_origin_exactly_test() {
  let origin = listed(served)
  assert ui_origin.names_host(origin, "obelisk.tail0a99b.ts.net:8443")
  assert ui_origin.names_host(origin, "OBELISK.tail0a99b.ts.net:8443")
  assert !ui_origin.names_host(origin, "obelisk.tail0a99b.ts.net")
  assert !ui_origin.names_host(origin, "obelisk.tail0a99b.ts.net:443")
  assert !ui_origin.names_host(origin, "obelisk.tail0a99b.ts.net.:8443")
  assert !ui_origin.names_host(origin, "evil.obelisk.tail0a99b.ts.net:8443")
  assert !ui_origin.names_host(origin, "obelisk.tail0a99b.ts.net:8443:443")
  assert !ui_origin.names_host(origin, "obelisk.tail0a99b.ts.net:8443/")
  let default = listed("https://loom.example.com")
  assert ui_origin.names_host(default, "loom.example.com")
  assert ui_origin.names_host(default, "loom.example.com:443")
  assert !ui_origin.names_host(default, "loom.example.com:8443")
}

// The seed the port property draws from, fixed so a failure repeats.
const port_seed = 52

// Any port but 443 round-trips through an entry, and the listed name on any
// other port is refused.
pub fn every_port_is_kept_and_only_its_own_matches_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(200)
    |> qcheck.with_seed(qcheck.seed(port_seed))
  let ports =
    qcheck.tuple2(qcheck.bounded_int(1, 65_535), qcheck.bounded_int(1, 65_535))
  qcheck.run(config, ports, fn(pair) {
    let #(port, other) = pair
    let entry = "https://box.example:" <> int.to_string(port)
    let origin = listed(entry)
    let expected = case port {
      443 -> "https://box.example"
      _ -> entry
    }
    assert ui_origin.to_string(origin) == expected
    assert ui_origin.names_host(origin, "box.example:" <> int.to_string(port))
    assert ui_origin.names_host(origin, "box.example:" <> int.to_string(other))
      == { port == other }
  })
}

// --- the origin a request is admitted under ----------------------------------

// The admission matrix. Loopback is admitted with or without a list, as 051
// admits it; a listed origin only with its own host and port; and no
// forwarded header ever changes the answer.
pub fn the_host_check_resolves_one_page_origin_test() {
  let origin = listed(served)
  let at = fn(headers) { ui_http.page_origin(get(headers), [origin]) }
  assert at([#("host", "127.0.0.1:4000")])
    == Ok(ui_http.Loopback("127.0.0.1:4000"))
  assert ui_http.page_origin(get([#("host", "[::1]:4000")]), [])
    == Ok(ui_http.Loopback("[::1]:4000"))
  assert at([#("host", "obelisk.tail0a99b.ts.net:8443")])
    == Ok(ui_http.Remote(origin))
  assert at([#("host", "Obelisk.Tail0a99b.ts.net:8443")])
    == Ok(ui_http.Remote(origin))
  assert at([#("host", "obelisk.tail0a99b.ts.net:9443")]) == Error(Nil)
  assert at([#("host", "obelisk.tail0a99b.ts.net")]) == Error(Nil)
  assert at([#("host", "evil.example")]) == Error(Nil)
  assert at([]) == Error(Nil)
  assert ui_http.page_origin(
      get([#("host", "obelisk.tail0a99b.ts.net:8443")]),
      [],
    )
    == Error(Nil)

  // A request that names a foreign host and claims the listed one, or
  // loopback, in a forwarded header is still the foreign host.
  let forwarded = [
    #("x-forwarded-host", "obelisk.tail0a99b.ts.net:8443"),
    #("forwarded", "host=obelisk.tail0a99b.ts.net:8443;proto=https"),
    #("x-forwarded-proto", "https"),
  ]
  assert at([#("host", "evil.example"), ..forwarded]) == Error(Nil)
  assert at([
      #("host", "evil.example"),
      #("x-forwarded-host", "127.0.0.1:4000"),
    ])
    == Error(Nil)

  // A loopback request that carries forwarded headers stays loopback.
  assert at([#("host", "127.0.0.1:4000"), ..forwarded])
    == Ok(ui_http.Loopback("127.0.0.1:4000"))
}

// The socket's `Origin` rule follows the page origin: `http://` and the
// loopback host, or the listed `https` origin byte for byte.
pub fn the_socket_origin_rule_follows_the_page_origin_test() {
  let remote = ui_http.Remote(listed(served))
  let loopback = ui_http.Loopback("127.0.0.1:4000")
  let from = fn(origin, sent) {
    ui_http.origin_matches(get([#("origin", sent)]), origin)
  }
  assert from(remote, served)
  assert !from(remote, "http://obelisk.tail0a99b.ts.net:8443")
  assert !from(remote, "https://obelisk.tail0a99b.ts.net:9443")
  assert !from(remote, "https://obelisk.tail0a99b.ts.net")
  assert !from(remote, "https://evil.tail0a99b.ts.net:8443")
  assert !from(remote, "http://127.0.0.1:4000")
  assert from(loopback, "http://127.0.0.1:4000")
  assert !from(loopback, served)
  assert ui_http.address(remote) == served
  assert ui_http.socket_origin(remote) == "wss://obelisk.tail0a99b.ts.net:8443"
  assert ui_http.socket_origin(loopback) == "ws://127.0.0.1:4000"
}

// The cookies follow the page origin too: their names, the `Secure`
// attribute, and which name a request is read by. The paths stay keyed.
pub fn the_cookies_follow_the_page_origin_test() {
  let remote = ui_http.Remote(listed(served))
  let loopback = ui_http.Loopback("127.0.0.1:4000")
  assert ui_http.set_cookie("abc", "k1", remote)
    == "__Secure-loom_ui=abc; HttpOnly; SameSite=Strict; Path=/ui/p/k1; Secure"
  assert ui_http.set_cookie("abc", "k1", loopback)
    == "loom_ui=abc; HttpOnly; SameSite=Strict; Path=/ui/p/k1"
  assert ui_http.set_login_cookie("loomb1:t", "k2", 60, remote)
    == "__Secure-loom_login=loomb1:t; HttpOnly; SameSite=Strict; Path=/ui/l/k2; Max-Age=60; Secure"
  assert ui_http.set_login_cookie("loomb1:t", "k2", 60, loopback)
    == "loom_login=loomb1:t; HttpOnly; SameSite=Strict; Path=/ui/l/k2; Max-Age=60"

  // Each origin reads its own name and ignores the other's.
  let both =
    get([
      #(
        "cookie",
        "loom_ui=a; __Secure-loom_ui=b; loom_login=c; __Secure-loom_login=d",
      ),
    ])
  assert ui_http.session_cookies(both, remote) == ["b"]
  assert ui_http.session_cookies(both, loopback) == ["a"]
  assert ui_http.login_cookies(both, remote) == ["d"]
  assert ui_http.login_cookies(both, loopback) == ["c"]
}

// The policy's socket scheme follows the page origin, and nothing else in
// the policy differs.
pub fn the_policy_names_wss_on_a_listed_origin_test() {
  let policy = fn(origin) {
    let assert Ok(text) =
      ui_http.secured(response.new(200), origin)
      |> response.get_header("content-security-policy")
      as "the policy is present"
    text
  }
  let remote = policy(ui_http.Remote(listed(served)))
  let loopback = policy(ui_http.Loopback("127.0.0.1:4000"))
  assert string.contains(
    remote,
    "connect-src 'self' wss://obelisk.tail0a99b.ts.net:8443;",
  )
  assert string.contains(loopback, "connect-src 'self' ws://127.0.0.1:4000;")
  assert string.replace(
      remote,
      "wss://obelisk.tail0a99b.ts.net:8443",
      "ws://127.0.0.1:4000",
    )
    == loopback
}
