//// The page shell loads the client components' bundle as a module from the
//// page's own origin, every asset the daemon serves from this package is
//// under its `priv/static`, and the content security policy is the one
//// protocol-change/051 specifies, spelled out here so that a change to it
//// fails and has to be argued in a 051 addendum. That the served bytes are
//// the priv files, under this policy, is `client/ui_route_test`'s claim.

import gleam/list
import gleam/string
import web_view/ending
import web_view/page

pub fn the_shell_loads_the_bundle_and_the_stylesheet_from_this_origin_test() {
  let shell = page.shell("S")
  assert string.contains(
    shell,
    "<script type=\"module\" src=\"/ui/assets/web_client.mjs\"></script>",
  )
  assert string.contains(
    shell,
    "<link rel=\"stylesheet\" href=\"/ui/assets/web_client.css\">",
  )

  // Nothing inline: every script and the stylesheet are files.
  assert !string.contains(shell, "<style")
  assert !string.contains(shell, "<script>")
}

pub fn every_owned_asset_is_in_this_packages_priv_test() {
  list.each(
    [
      page.stylesheet_asset,
      page.enter_asset,
      page.page_asset,
      page.client_asset,
    ],
    fn(name) {
      let assert Ok(path) = page.static_file(name)
        as "web_view's priv directory is found"
      assert string.ends_with(path, "/priv/static/" <> name)
    },
  )
}

pub fn the_policy_is_the_one_051_specifies_test() {
  assert page.content_security_policy("127.0.0.1:4000")
    == "default-src 'none'; script-src 'self'; style-src 'self'; "
    <> "style-src-attr 'unsafe-inline'; connect-src 'self' ws://127.0.0.1:4000; "
    <> "img-src 'self'; base-uri 'none'; form-action 'none'; "
    <> "frame-ancestors 'none'"
}

// A page whose socket the daemon refuses is empty, and a browser cannot read
// why: a refused handshake is a bare failure. The shell therefore carries
// its own paragraph inside the component, which Lustre's client runtime
// hides when it attaches the component's shadow root, on the first tree it
// receives. It is fixed text with no script.
pub fn the_shell_says_why_a_page_that_never_connects_is_empty_test() {
  let shell = page.shell("0192ab")
  let assert Ok(#(_, inside)) =
    string.split_once(shell, "<lustre-server-component>")
    as "the component is in the shell"
  let assert Ok(#(waiting, _)) =
    string.split_once(inside, "</lustre-server-component>")
    as "the component closes"
  assert string.contains(waiting, "not connected to the session")
  assert string.contains(waiting, "loom ui --session 0192ab")
  assert string.contains(waiting, "session may not be open")
  assert !string.contains(waiting, "<script")
}

pub fn the_waiting_paragraph_escapes_what_it_was_given_test() {
  let shell = page.shell("<img src=x>")
  assert !string.contains(shell, "<img")
  assert string.contains(shell, "&lt;img")
}

// The document a browser gets for a page that cannot be served is the
// ending's words and nothing else: no script, no reason text of the
// daemon's, and the session identity escaped.
pub fn a_refused_page_document_says_the_ending_and_what_to_do_test() {
  list.each(ending.all(), fn(reason) {
    let document = page.refusal(reason, "0192ab")
    assert string.contains(document, ending.headline(reason))
    assert string.contains(document, "role=\"alert\"")
    assert string.contains(document, "/ui/assets/web_client.css")
    assert !string.contains(document, "<script")
  })
  let hostile = page.refusal(ending.PageEnded, "<script>alert(1)</script>")
  assert !string.contains(hostile, "<script")
}
