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

// The claim box's address copies only the browser claim address: `http://`, a
// loopback host and port, and `/ui/claim` with nothing after it.
pub fn the_claim_address_subject_copies_only_the_claim_page_test() {
  assert copy_rule.subject("claim-address") == Ok(copy_rule.ClaimPage)
  let address = "http://127.0.0.1:4000/ui/claim"
  assert copy_rule.text(copy_rule.ClaimPage, address) == Ok(address)
  let bracketed = "http://[::1]:4000/ui/claim"
  assert copy_rule.text(copy_rule.ClaimPage, bracketed) == Ok(bracketed)
  list.each(
    [
      "",
      "http://127.0.0.1:4000/ui/claim/",
      "http://127.0.0.1:4000/ui/claim?x=1",
      "http://127.0.0.1:4000/ui/claim\nrm -rf ~",
      "https://127.0.0.1:4000/ui/claim",
      "http:///ui/claim",
      "http://127.0.0.1:4000/x/ui/claim",
      "http://evil.example/ cat /ui/claim",
      " http://127.0.0.1:4000/ui/claim",
      "http://" <> string.repeat("a", 65) <> "/ui/claim",
      command,
      token,
    ],
    fn(value) {
      assert copy_rule.text(copy_rule.ClaimPage, value) == Error(Nil)
    },
  )
  assert copy_rule.text(copy_rule.Command, address) == Error(Nil)
  assert copy_rule.words(copy_rule.ClaimPage, copy_rule.Idle) == "Copy address"
  assert copy_rule.words(copy_rule.ClaimPage, copy_rule.Copied)
    == "Address copied"
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

// The launch box on the owner's home copies the command that reaches a session
// on another orchestrator, and only that shape: `loom --addr`, an address or the
// placeholder for none, `--session`, an identity and the fixed ending.
pub fn the_launch_subject_copies_only_the_command_for_a_session_test() {
  assert copy_rule.subject("launch") == Ok(copy_rule.Launch)
  let ending = " --token-file <owner token file on that host>"
  let id = "0198c1aa-0000-7000-8000-000000000002"
  let line =
    "loom --addr ws://10.0.0.4:7000/v2/control --session " <> id <> ending
  assert copy_rule.text(copy_rule.Launch, line) == Ok(line)
  let unknown = "loom --addr <its control address> --session " <> id <> ending
  assert copy_rule.text(copy_rule.Launch, unknown) == Ok(unknown)
  list.each(
    [
      "",
      "loom --addr  --session " <> id <> ending,
      "loom --addr ws://h:1 --session " <> ending,
      "loom --addr ws://h:1 --session " <> id,
      "loom --addr ws://h:1 --session " <> id <> ending <> "; rm -rf ~",
      "loom --addr ws://h:1 --session " <> id <> ending <> "\nrm -rf ~",
      "loom --addr ws://h:1;rm --session " <> id <> ending,
      "loom --addr ws://h:1 --session " <> id <> "x" <> ending,
      "loom --addr ws://h:1 --session " <> id <> " --token-file /etc/passwd",
      "loom --addr <something else> --session " <> id <> ending,
      "loom --addr ws://h:1 --session " <> string.repeat("a", 65) <> ending,
      " loom --addr ws://h:1 --session " <> id <> ending,
      "sudo loom --addr ws://h:1 --session " <> id <> ending,
    ],
    fn(value) {
      assert copy_rule.text(copy_rule.Launch, value) == Error(Nil)
    },
  )
  assert copy_rule.words(copy_rule.Launch, copy_rule.Idle) == "Copy command"
}

// The Admin page's machine pages show the commands an operator runs, and the box
// copies exactly those shapes: the fixed words and flags, with each name one
// shell word that is bare or single-quoted.
pub fn the_operate_subject_copies_only_the_operator_commands_test() {
  assert copy_rule.subject("operate") == Ok(copy_rule.Operate)
  list.each(
    [
      "loom distribution renew laptop",
      "loom distribution renew laptop --bundle-dir /opt/loom/bundle",
      "loom distribution revoke laptop --reason 'RETIRED'",
      "loom distribution revoke 'it'\\''s' --reason 'RETIRED'",

      // What `web_view/operator_commands` writes for a hostile name.
      "loom distribution renew 'x'\\''; rm -rf ~; echo '\\'''",
      "loomd executor release 'a\\'",
      "loom distribution enroll box --node loom@box.example.net --role executor --links hub",
      "loom distribution enroll hub2 --node loom@hub2.example.net --role orchestrator --links hub",
      "loomd executor release 0198c1aa-0000-7000-8000-000000000002",
    ],
    fn(value) {
      assert copy_rule.text(copy_rule.Operate, value) == Ok(value)
    },
  )
  assert copy_rule.words(copy_rule.Operate, copy_rule.Idle) == "Copy command"
  assert copy_rule.words(copy_rule.Operate, copy_rule.Copied)
    == "Command copied"
}

// A name that is not one word, a second command, a substitution, a redirection,
// an unquoted quote, a control character, a non-ASCII character, an option of the
// program, or any other command is no command.
pub fn the_operate_subject_refuses_anything_else_test() {
  list.each(
    [
      "",
      "loom distribution renew",
      "loom distribution renew a b",
      "loom distribution renew a;rm",
      "loom distribution renew a && echo hi",
      "loom distribution renew a | cat",
      "loom distribution renew $(id)",
      "loom distribution renew `id`",
      "loom distribution renew a>b",
      "loom distribution renew a'b",
      "loom distribution renew 'a",
      "loom distribution renew 'a'b'",
      "loom distribution renew a\\b",
      "loom distribution renew a\\ b",
      "loom distribution renew --force",
      "loom distribution renew '--force'",
      "loom distribution renew a\nrm -rf ~",
      "loom distribution renew a\r",
      "loom distribution renew 'a\nb'",
      "loom distribution renew 'a\u{7}b'",
      "loom distribution renew caf\u{e9}",
      "loom distribution renew 'a\u{202e}b'",
      "loom distribution renew  a",
      "loom distribution renew a ",
      " loom distribution renew a",
      "loom distribution renew a --force",
      "loom distribution renew a --bundle-dir",
      "loom distribution revoke a",
      "loom distribution revoke a --reason",
      "loom distribution revoke a --reason x --force",
      "loom distribution enroll a --node n --role root --links h",
      "loom distribution enroll a --role executor --node n --links h",
      "loom distribution enroll a --node n --role executor",
      "loomd executor release",
      "loomd executor release a b",
      "loomd executor release --state-dir /",
      "loom distribution install a",
      "sudo loom distribution renew a",
      "rm -rf ~",
    ],
    fn(value) {
      assert copy_rule.text(copy_rule.Operate, value) == Error(Nil)
    },
  )
  assert copy_rule.text(
      copy_rule.Operate,
      "loom distribution renew " <> string.repeat("a", 257),
    )
    == Error(Nil)
  assert copy_rule.text(
      copy_rule.Operate,
      "loom distribution renew 'a'" <> string.repeat("'\\''", 300),
    )
    == Error(Nil)
}
