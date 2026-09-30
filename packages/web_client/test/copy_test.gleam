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
