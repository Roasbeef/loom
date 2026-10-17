//// The commands the Admin page's machine pages show (`web_view/operator_commands`):
//// the exact text of each, and that no name, however hostile, can turn a copied
//// command into a different command.

import gleam/list
import gleam/string
import web_view/machines
import web_view/operator_commands

pub fn each_command_is_its_fixed_words_with_the_names_filled_in_test() {
  assert operator_commands.renew("box") == Ok("loom distribution renew box")
  assert operator_commands.revoke("box")
    == Ok("loom distribution revoke box --reason 'REASON'")
  assert operator_commands.enroll(
      "box",
      "loom@box.example.net",
      machines.Executor,
      "hub",
    )
    == Ok(
      "loom distribution enroll box --node loom@box.example.net --role executor --links hub",
    )
  assert operator_commands.enroll(
      "hub2",
      "h2@10.0.0.4",
      machines.Orchestrator,
      "hub",
    )
    == Ok(
      "loom distribution enroll hub2 --node h2@10.0.0.4 --role orchestrator --links hub",
    )
  assert operator_commands.release("0198c1aa-0000-7000-8000-0000000000aa")
    == Ok("loomd executor release 0198c1aa-0000-7000-8000-0000000000aa")
}

// A node that is only a directory member has no role to enroll as.
pub fn a_member_only_node_cannot_be_enrolled_test() {
  assert operator_commands.enroll("m", "m@h", machines.Member, "hub")
    == Error(Nil)
}

// A name with anything a shell treats as syntax is one quoted word: the quote
// inside it is closed, escaped and reopened, so what follows it is still data.
pub fn a_hostile_name_stays_one_word_test() {
  assert operator_commands.quote("it's") == Ok("'it'\\''s'")
  assert operator_commands.quote("a b") == Ok("'a b'")

  // The same vectors as the browser rule's tests: a word that begins with an
  // equals sign is expanded by zsh, and a comma splits a `--links` list.
  assert operator_commands.renew("=ls") == Ok("loom distribution renew '=ls'")
  assert operator_commands.renew("a,b") == Ok("loom distribution renew 'a,b'")
  assert operator_commands.quote("a;rm -rf ~") == Ok("'a;rm -rf ~'")
  assert operator_commands.quote("$(id)") == Ok("'$(id)'")
  assert operator_commands.quote("`id`") == Ok("'`id`'")
  assert operator_commands.quote("a > b") == Ok("'a > b'")
  assert operator_commands.quote("x' ; echo pwned ; '")
    == Ok("'x'\\'' ; echo pwned ; '\\'''")
  assert operator_commands.renew("x'; rm -rf ~; echo '")
    == Ok("loom distribution renew 'x'\\''; rm -rf ~; echo '\\'''")
  assert operator_commands.release("a\\") == Ok("loomd executor release 'a\\'")
}

// A name that cannot be made one safe word gets no command at all: an empty
// name, a newline, any control or non-ASCII character, a name the program would
// read as an option, and one over the bound.
pub fn a_name_that_cannot_be_quoted_gets_no_command_test() {
  list.each(
    [
      "",
      "a\nrm -rf ~",
      "a\rb",
      "a\u{0}b",
      "a\u{7}b",
      "café",
      "a\u{202e}b",
      "--force",
      "-x",
      string.repeat("a", operator_commands.word_limit + 1),
    ],
    fn(name) {
      assert operator_commands.quote(name) == Error(Nil)
      assert operator_commands.renew(name) == Error(Nil)
      assert operator_commands.revoke(name) == Error(Nil)
      assert operator_commands.enroll(name, "n@h", machines.Executor, "hub")
        == Error(Nil)
      assert operator_commands.enroll("n", name, machines.Executor, "hub")
        == Error(Nil)
      assert operator_commands.enroll("n", "n@h", machines.Executor, name)
        == Error(Nil)
      assert operator_commands.release(name) == Error(Nil)
    },
  )
  assert operator_commands.quote(string.repeat(
      "a",
      operator_commands.word_limit,
    ))
    == Ok(string.repeat("a", operator_commands.word_limit))
}

// Quoting can make a name longer, so a command whose words together pass the
// bound the browser holds it to is withheld.
pub fn a_command_over_the_bound_is_withheld_test() {
  let quotes = string.repeat("'", operator_commands.word_limit)
  assert operator_commands.enroll(quotes, quotes, machines.Executor, quotes)
    == Error(Nil)
}
