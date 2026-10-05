//// What `<loom-copy>` decides (`web_client/copy_rule`): which texts it may put
//// on the clipboard, and the words on its button.

import gleam/list
import gleam/string
import web_client/copy_rule

const token =
  "loomclaim_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

const command = "loom claim --addr ws://127.0.0.1:4000/v2/control"

pub fn the_two_fixed_words_are_the_subjects_test() {
  assert copy_rule.subject("command") == Ok(copy_rule.Command)
  assert copy_rule.subject("token") == Ok(copy_rule.Token)
}

// Any other word is no subject, whatever it resembles.
pub fn any_other_subject_is_refused_test() {
  list.each(
    ["", "Token", "tokens", "command ", "other", "loomclaim_"],
    fn(word) {
      assert copy_rule.subject(word) == Error(Nil)
    },
  )
}

pub fn the_daemons_command_and_token_are_copyable_test() {
  assert copy_rule.text(copy_rule.Command, command) == Ok(command)
  assert copy_rule.text(copy_rule.Token, token) == Ok(token)

  // A secure address and a bracketed loopback one have the same shape.
  let secure = "loom claim --addr wss://loom.example.com/v2/control"
  assert copy_rule.text(copy_rule.Command, secure) == Ok(secure)
  let literal = "loom claim --addr ws://[::1]:4000/v2/control"
  assert copy_rule.text(copy_rule.Command, literal) == Ok(literal)

  // Upper-case hexadecimal digits are hexadecimal.
  let upper = "loomclaim_" <> string.uppercase(string.repeat("ab12", 16))
  assert copy_rule.text(copy_rule.Token, upper) == Ok(upper)
}

// A newline pasted into a terminal runs what came before it, so a value with
// one is never copied, and neither is a second command, a quote, a space in
// the address or a control character.
pub fn anything_else_is_not_copyable_as_a_command_test() {
  list.each(
    [
      "",
      "loom claim --addr ",
      "loom claim --addr ws://127.0.0.1:4000/v2/control\nrm -rf ~",
      "loom claim --addr ws://127.0.0.1:4000/v2/control\r",
      "loom claim --addr ws://127.0.0.1:4000/v2/control; rm -rf ~",
      "loom claim --addr ws://127.0.0.1:4000/v2/control && echo hi",
      "loom claim --addr 'ws://127.0.0.1:4000/v2/control'",
      "loom claim --addr $(id)",
      "loom claim --addr ws://a b",
      "loom claim --addr ws://127.0.0.1:4000/v2/control\u{7}",
      "sh -c loom claim --addr ws://127.0.0.1:4000/v2/control",
      " loom claim --addr ws://127.0.0.1:4000/v2/control",
      "loom claim --token loomclaim_abc",
      token,
    ],
    fn(value) {
      assert copy_rule.text(copy_rule.Command, value) == Error(Nil)
    },
  )
  assert copy_rule.text(
      copy_rule.Command,
      "loom claim --addr " <> string.repeat("a", 257),
    )
    == Error(Nil)
}

pub fn anything_else_is_not_copyable_as_a_token_test() {
  list.each(
    [
      "",
      "loomclaim_",
      "loomclaim_" <> string.repeat("a", 63),
      "loomclaim_" <> string.repeat("a", 65),
      "loomclaim_" <> string.repeat("g", 64),
      "loomclaim_" <> string.repeat("a", 64) <> "\n",
      "loomclaim_" <> string.repeat("a", 64) <> " ",
      " " <> token,
      "xloomclaim_" <> string.repeat("a", 64),
      string.repeat("a", 64),
      command,
    ],
    fn(value) {
      assert copy_rule.text(copy_rule.Token, value) == Error(Nil)
    },
  )
}

// A subject decides the shape: a token is not a command and a command is not a
// token, so a mismatched pair copies nothing.
pub fn the_subject_decides_the_shape_test() {
  assert copy_rule.text(copy_rule.Token, command) == Error(Nil)
  assert copy_rule.text(copy_rule.Command, token) == Error(Nil)
}

pub fn the_browsers_answer_is_a_state_test() {
  assert copy_rule.after(Ok(Nil)) == copy_rule.Copied
  assert copy_rule.after(Error(Nil)) == copy_rule.Failed
}

// The button says what it copies, what came of it, and what to do when the
// browser refused, in fixed words.
pub fn the_words_are_fixed_and_say_what_happened_test() {
  assert copy_rule.words(copy_rule.Command, copy_rule.Idle) == "Copy command"
  assert copy_rule.words(copy_rule.Token, copy_rule.Idle) == "Copy token"
  assert copy_rule.words(copy_rule.Command, copy_rule.Copied)
    == "Command copied"
  assert copy_rule.words(copy_rule.Token, copy_rule.Copied) == "Token copied"
  assert copy_rule.words(copy_rule.Token, copy_rule.Failed)
    == "Copy failed. Select the text and copy it."
}

// The ended page's box copies the command that mints a fresh link, and only
// that: `loom ui`, alone or for one session's canonical identity.
pub fn the_link_subject_copies_only_the_ui_command_test() {
  assert copy_rule.subject("link") == Ok(copy_rule.Link)
  let session = "loom ui --session 0198a2f4-7c3b-7d11-9e6a-5b0c2d4e8f10"
  assert copy_rule.text(copy_rule.Link, "loom ui") == Ok("loom ui")
  assert copy_rule.text(copy_rule.Link, session) == Ok(session)
  list.each(
    [
      "",
      "loom ui ",
      "loom ui --session ",
      "loom ui\nrm -rf ~",
      "loom ui; rm -rf ~",
      "loom ui --session abc; id",
      "loom ui --session $(id)",
      "loom ui --session abc def",
      "loom ui --session " <> string.repeat("a", 65),
      " loom ui",
      "sh loom ui",
      command,
      token,
    ],
    fn(value) {
      assert copy_rule.text(copy_rule.Link, value) == Error(Nil)
    },
  )

  // The link is not a command or a token, and neither is it the link.
  assert copy_rule.text(copy_rule.Command, "loom ui") == Error(Nil)
  assert copy_rule.text(copy_rule.Token, "loom ui") == Error(Nil)
  assert copy_rule.words(copy_rule.Link, copy_rule.Idle) == "Copy command"
}

// The home's device-link box copies the exchange address a fresh home's ticket
// makes, and only that shape: `http://`, a loopback host and port,
// `/ui/home?ticket=` and the ticket's 64 lowercase hexadecimal digits
// (protocol-change/065, PR 8).
pub fn the_device_subject_copies_only_an_exchange_address_test() {
  assert copy_rule.subject("device") == Ok(copy_rule.Device)
  let ticket = string.repeat("ab", 32)
  let link = "http://127.0.0.1:4000/ui/home?ticket=" <> ticket
  assert copy_rule.text(copy_rule.Device, link) == Ok(link)
  let bracketed = "http://[::1]:4000/ui/home?ticket=" <> ticket
  assert copy_rule.text(copy_rule.Device, bracketed) == Ok(bracketed)
  list.each(
    [
      "",
      "http://127.0.0.1:4000/ui/home?ticket=" <> string.repeat("ab", 31),
      "http://127.0.0.1:4000/ui/home?ticket=" <> string.repeat("ab", 33),
      "http://127.0.0.1:4000/ui/home?ticket=" <> string.uppercase(ticket),
      "https://127.0.0.1:4000/ui/home?ticket=" <> ticket,
      "http:///ui/home?ticket=" <> ticket,
      "http://127.0.0.1:4000/ui/sessions/abc?ticket=" <> ticket,
      "http://127.0.0.1:4000/ui/home?ticket=" <> ticket <> "\nrm -rf ~",
      "http://127.0.0.1:4000/ui/home?ticket=" <> ticket <> "&x=1",
      "http://127.0.0.1:4000/x/ui/home?ticket=" <> ticket,
      "http://evil.example/ cat /ui/home?ticket=" <> ticket,
      " http://127.0.0.1:4000/ui/home?ticket=" <> ticket,
      "http://" <> string.repeat("a", 65) <> "/ui/home?ticket=" <> ticket,
      command,
      token,
      "loom ui",
    ],
    fn(value) {
      assert copy_rule.text(copy_rule.Device, value) == Error(Nil)
    },
  )
  assert copy_rule.text(copy_rule.Link, link) == Error(Nil)
  assert copy_rule.words(copy_rule.Device, copy_rule.Idle) == "Copy link"
  assert copy_rule.words(copy_rule.Device, copy_rule.Copied) == "Link copied"
}

// The home's bookmark box copies the address that resumes a remembered login,
// and only that shape: `http://`, a loopback host and port, `/ui/l/`, the
// login key's 32 lowercase hexadecimal digits and `/home`. The bookmark is a
// bearer address, so a value that differs in any part is no value.
pub fn the_bookmark_subject_copies_only_a_login_address_test() {
  assert copy_rule.subject("bookmark") == Ok(copy_rule.Bookmark)
  let key = string.repeat("ab", 16)
  let bookmark = "http://127.0.0.1:4000/ui/l/" <> key <> "/home"
  assert copy_rule.text(copy_rule.Bookmark, bookmark) == Ok(bookmark)
  let bracketed = "http://[::1]:4000/ui/l/" <> key <> "/home"
  assert copy_rule.text(copy_rule.Bookmark, bracketed) == Ok(bracketed)
  list.each(
    [
      "",
      "http://127.0.0.1:4000/ui/l/" <> string.repeat("ab", 15) <> "/home",
      "http://127.0.0.1:4000/ui/l/" <> string.repeat("ab", 17) <> "/home",
      "http://127.0.0.1:4000/ui/l/" <> string.uppercase(key) <> "/home",
      "http://127.0.0.1:4000/ui/l/" <> string.repeat("g", 32) <> "/home",
      "http://127.0.0.1:4000/ui/l/" <> key,
      "http://127.0.0.1:4000/ui/l/" <> key <> "/home/",
      "http://127.0.0.1:4000/ui/l/" <> key <> "/home\nrm -rf ~",
      "http://127.0.0.1:4000/ui/l/" <> key <> "/home?x=1",
      "http://127.0.0.1:4000/ui/l/" <> key <> "/sessions",
      "https://127.0.0.1:4000/ui/l/" <> key <> "/home",
      "http:///ui/l/" <> key <> "/home",
      "http://127.0.0.1:4000/x/ui/l/" <> key <> "/home",
      "http://evil.example/ cat /ui/l/" <> key <> "/home",
      " http://127.0.0.1:4000/ui/l/" <> key <> "/home",
      "http://" <> string.repeat("a", 65) <> "/ui/l/" <> key <> "/home",
      "/ui/l/" <> key <> "/home",
      command,
      token,
      "http://127.0.0.1:4000/ui/home?ticket=" <> string.repeat("ab", 32),
    ],
    fn(value) {
      assert copy_rule.text(copy_rule.Bookmark, value) == Error(Nil)
    },
  )

  // A bookmark is not any of the other subjects' text, nor theirs its.
  assert copy_rule.text(copy_rule.Device, bookmark) == Error(Nil)
  assert copy_rule.text(copy_rule.Command, bookmark) == Error(Nil)
  assert copy_rule.words(copy_rule.Bookmark, copy_rule.Idle) == "Copy bookmark"
  assert copy_rule.words(copy_rule.Bookmark, copy_rule.Copied)
    == "Bookmark copied"
  assert copy_rule.words(copy_rule.Bookmark, copy_rule.Failed)
    == "Copy failed. Select the text and copy it."
}
