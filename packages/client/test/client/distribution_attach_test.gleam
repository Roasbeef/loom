//// The pure half of `loom distribution attach-file` (protocol-change/096):
//// where the five files sit, the standard options file that names them, and
//// the recipe printed for a person.

import client/distribution_attach
import client/distribution_plan
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn the_files_sit_directly_in_the_directory_test() {
  let files = distribution_attach.files_in("/home/me/attach")
  assert files.ca == "/home/me/attach/ca.pem"
  assert files.certificate == "/home/me/attach/tool.pem"
  assert files.key == "/home/me/attach/tool.key"
  assert files.cookie == "/home/me/attach/.erlang.cookie"
  assert files.options == "/home/me/attach/ssl_dist.conf"
  assert files.node == "/home/me/attach/node"
}

pub fn the_primary_recipe_is_the_pickglass_attach_dir_form_test() {
  let files = distribution_attach.files_in("/a")
  let one = distribution_attach.instructions(files, "me@h", ["x@h"])
  assert string.contains(one, "pickglass attach --node x@h --attach-dir '/a'")
  let none = distribution_attach.instructions(files, "me@h", [])
  assert string.contains(none, "pickglass attach --node <daemon node>")
}

pub fn the_options_file_is_client_only_standard_erlang_test() {
  let files = distribution_attach.files_in("/a")
  let assert Ok(text) = distribution_attach.options(files)
  assert text == "%% coding: utf-8
[{client, [{cacertfile, \"/a/ca.pem\"}, {certfile, \"/a/tool.pem\"}, {keyfile, \"/a/tool.key\"}, {verify, verify_peer}, {versions, ['tlsv1.3', 'tlsv1.2']}]}].
"
  assert !string.contains(text, "server")
  assert !string.contains(text, "verify_fun")
  assert !string.contains(text, "loom")
}

pub fn a_path_an_erlang_string_cannot_hold_is_refused_test() {
  list_of_bad()
  |> each_refused
}

fn list_of_bad() -> List(String) {
  ["/a\"b", "/a\\b", "/a\nb", "/a" <> "\u{0}" <> "b"]
}

fn each_refused(paths: List(String)) -> Nil {
  case paths {
    [] -> Nil
    [path, ..rest] -> {
      let assert Error(reason) =
        distribution_attach.options(distribution_attach.files_in(path))
      assert string.contains(reason, "cannot hold")
      each_refused(rest)
    }
  }
}

pub fn a_path_with_a_space_is_kept_and_quoted_for_the_shell_test() {
  let files = distribution_attach.files_in("/home/me/my attach")
  let assert Ok(text) = distribution_attach.options(files)
  assert string.contains(text, "\"/home/me/my attach/ca.pem\"")
  let recipe =
    distribution_attach.instructions(files, "me@127.0.0.1", ["loom@hub"])
  assert string.contains(recipe, "HOME='/home/me/my attach' erl")
  assert string.contains(
    recipe,
    "-ssl_dist_optfile '/home/me/my attach/ssl_dist.conf'",
  )
  assert string.contains(
    recipe,
    "-name me@127.0.0.1 -hidden -dist_listen false -remsh loom@hub",
  )
}

pub fn the_recipe_asks_for_the_daemon_node_when_there_is_not_exactly_one_test() {
  let files = distribution_attach.files_in("/a")
  let recipe = distribution_attach.instructions(files, "me@h", ["x@h", "y@h"])
  assert string.contains(recipe, "-remsh <daemon node>")
  assert string.contains(recipe, "observer:start()")
}

pub fn only_a_ledger_member_can_have_the_tool_role_test() {
  assert distribution_plan.member_role_from_word("tool")
    == Ok(distribution_plan.Tool)
  assert distribution_plan.role_word(distribution_plan.Tool) == "tool"

  // A plan or a bundle holds daemons, so its reader does not know the word.
  assert result.is_error(distribution_plan.role_from_word("tool"))
}

pub fn every_recipe_keeps_the_tool_hidden_and_not_listening_test() {
  let files = distribution_attach.files_in("/a")
  let recipe = distribution_attach.instructions(files, "me@h", ["x@h"])
  let commands =
    string.split(recipe, "\n")
    |> list.filter(fn(line) { string.contains(line, "-proto_dist") })
  assert list.length(commands) == 3
  assert list.all(commands, fn(line) {
    string.contains(line, "-hidden -dist_listen false")
  })
}

pub fn the_attach_root_is_the_override_or_below_home_test() {
  assert distribution_attach.attach_root(None, "/h") == "/h/.pickglass/attach"
  assert distribution_attach.attach_root(Some(""), "/h")
    == "/h/.pickglass/attach"
  assert distribution_attach.attach_root(Some("/r"), "/h") == "/r"
}

pub fn only_a_plain_word_is_a_directory_name_test() {
  assert distribution_attach.is_directory_name("inspector")
  assert !distribution_attach.is_directory_name("")
  assert !distribution_attach.is_directory_name(".hidden")
  assert !distribution_attach.is_directory_name("a/b")
}

pub fn the_pickglass_lines_use_attach_and_never_promise_a_bare_attach_test() {
  let text = distribution_attach.pickglass_lines("/r", "tool", "x@h")
  assert string.contains(text, "pickglass attach --node x@h --attach tool")
  assert string.contains(text, "--attach-dir '/r/tool'")
  assert !string.contains(text, "only")
}
