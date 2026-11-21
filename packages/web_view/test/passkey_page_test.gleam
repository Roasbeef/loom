//// The documents of the passkey ceremonies (protocol-change/127): the sign-in
//// page, the registration page and their two refusals. They are fixed text with
//// the daemon's own values in data attributes, no inline script and no inline
//// style, and nothing a request said.

import gleam/string
import web_view/page

// The sign-in page names its challenge and relying party in data attributes of
// the one form, posts to the fixed address, and loads its script as an asset.
pub fn the_sign_in_page_carries_a_challenge_and_posts_to_its_own_address_test() {
  let html = page.signin_page("chall", "box.example")
  assert string.contains(html, "data-challenge=\"chall\"")
  assert string.contains(html, "data-rp-id=\"box.example\"")
  assert string.contains(html, "action=\"/ui/signin\"")
  assert string.contains(html, "method=\"post\"")
  assert string.contains(html, "src=\"/ui/assets/web_view_signin.js\"")
  assert string.contains(html, "name=\"id\"")
  assert string.contains(html, "name=\"cdj\"")
  assert string.contains(html, "name=\"ad\"")
  assert string.contains(html, "name=\"sig\"")
}

// There is no inline script, no inline handler and no inline style, so the
// policy `script-src 'self'` and `style-src 'self'` holds for the page.
pub fn neither_page_has_inline_script_or_style_test() {
  let documents = [
    page.signin_page("c", "h"),
    page.passkey_page("k", "c", "h", "u", "n"),
    page.signin_refused(),
    page.passkey_refused(),
  ]
  list_each(documents, fn(html) {
    assert !string.contains(html, "<script>")
    assert !string.contains(html, "onclick")
    assert !string.contains(html, "<style")
    assert !string.contains(html, "style=\"")
  })
}

// Every value the daemon wrote is escaped, whatever it holds.
pub fn the_daemons_values_are_escaped_test() {
  let html =
    page.passkey_page("k\"><b>", "c\"><i>", "h\"><u>", "u\"><s>", "n\"><em>")
  assert !string.contains(html, "<b>")
  assert !string.contains(html, "<i>")
  assert !string.contains(html, "<u>")
  assert !string.contains(html, "<s>")
  assert !string.contains(html, "<em>")
  assert string.contains(html, "&lt;")
}

// The registration page posts under its own key, which is where its page's
// cookie is scoped, and carries the fields the script fills.
pub fn the_registration_page_posts_under_its_own_key_test() {
  let html = page.passkey_page("abc", "chall", "box.example", "user", "Olive")
  assert string.contains(html, "action=\"/ui/p/abc/passkey\"")
  assert string.contains(html, "data-key=\"abc\"")
  assert string.contains(html, "data-user=\"user\"")
  assert string.contains(html, "data-name=\"Olive\"")
  assert string.contains(html, "src=\"/ui/assets/web_view_passkey.js\"")
  assert string.contains(html, "name=\"nonce\"")
  assert string.contains(html, "name=\"pk\"")
  assert string.contains(html, "name=\"label\"")
  assert string.contains(html, "ES256")
}

pub fn the_passkey_path_is_under_the_pages_key_test() {
  assert page.passkey_path("abc") == "/ui/p/abc/passkey"
  assert page.signin_path == "/ui/signin"
}

// A refusal echoes nothing the request said and says how to go on.
pub fn the_refusals_are_fixed_words_test() {
  let signin = page.signin_refused()
  assert string.contains(signin, "This passkey could not sign you in.")
  assert string.contains(signin, "loom ui")
  assert string.contains(signin, "href=\"/ui/signin\"")
  let registration = page.passkey_refused()
  assert string.contains(registration, "No passkey was added.")
  assert string.contains(registration, "loom ui")
}

// The document at `/` points a browser with no login at the sign-in page.
pub fn the_root_page_names_the_sign_in_page_test() {
  let html = page.root_page("loom ui")
  assert string.contains(html, "href=\"/ui/signin\"")
  assert string.contains(html, "sign in with a passkey")
}

fn list_each(items: List(a), run: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [first, ..rest] -> {
      run(first)
      list_each(rest, run)
    }
  }
}
