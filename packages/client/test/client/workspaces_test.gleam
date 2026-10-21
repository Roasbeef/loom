//// The `[workspaces.<name>]` tables are strict, total and absent by default
//// (protocol-change/078). A table names a directory an executor serves, so a
//// name outside the registered-workspace grammar, a relative root or a key the
//// table does not know is refused wherever the file is read.

import client/catalog
import client/workspaces
import gleam/dict
import gleam/list
import gleam/string

const distribution =
  "[distribution]
node = \"executor@10.0.0.2\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"owner@10.0.0.1\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"
"

fn refused(text: String, fragment: String) {
  let assert Error(reason) = workspaces.parse(text)
    as "the table is refused by its own parser"
  assert string.contains(reason, fragment)
}

pub fn an_absent_table_configures_no_workspace_test() {
  assert workspaces.parse("") == Ok([])
  assert workspaces.parse(distribution) == Ok([])
  assert workspaces.from_document(dict.new()) == Ok([])
}

pub fn each_table_names_one_root_and_the_list_is_sorted_test() {
  let text = distribution <> "
[workspaces.loom]
root = \"/srv/checkouts/loom\"

[workspaces.alpha]
root = \"/srv/checkouts/alpha\"
"
  assert workspaces.parse(text)
    == Ok([
      workspaces.shared("alpha", "/srv/checkouts/alpha"),
      workspaces.shared("loom", "/srv/checkouts/loom"),
    ])
  let assert Ok(configured) = workspaces.parse(text)
  assert workspaces.find(configured, "loom")
    == Ok(workspaces.shared("loom", "/srv/checkouts/loom"))
  assert workspaces.find(configured, "elsewhere") == Error(Nil)
}

pub fn workspaces_need_a_distribution_table_test() {
  refused(
    "[workspaces.loom]\nroot = \"/srv/loom\"\n",
    "workspaces needs a [distribution] table",
  )
}

pub fn a_root_must_be_one_absolute_unambiguous_path_test() {
  refused(
    distribution <> "[workspaces.loom]\nroot = \"srv/loom\"\n",
    "workspaces.loom.root must be an absolute path",
  )
  refused(
    distribution <> "[workspaces.loom]\nroot = \"/srv/../etc\"\n",
    "workspaces.loom.root must not contain a .. segment",
  )
}

pub fn names_keys_and_types_are_checked_with_the_full_key_test() {
  refused(
    distribution <> "[workspaces.\"a/b\"]\nroot = \"/srv\"\n",
    "workspaces.a/b is not a workspace name",
  )
  refused(
    distribution <> "[workspaces.loom]\nroot = \"/srv\"\nkind = \"rw\"\n",
    "unknown key `kind` in [workspaces.loom] (allowed: root, mode, base)",
  )
  refused(
    distribution <> "[workspaces.loom]\nroot = 4\n",
    "workspaces.loom.root must be a string",
  )
  refused(
    distribution <> "[workspaces.loom]\n",
    "workspaces.loom.root is required",
  )
  refused("workspaces = 3\n", "workspaces must be a table")
}

pub fn the_catalogue_parser_refuses_a_bad_workspaces_table_too_test() {
  let assert Error(reason) =
    catalog.parse("[workspaces.loom]\nroot = \"relative\"\n")
  assert string.contains(
    reason,
    "workspaces.loom.root must be an absolute path",
  )
}

pub fn lsp_tables_parse_without_a_model_catalogue_test() {
  assert catalog.parse_lsp("") == Ok([])
  let assert Error(reason) = catalog.parse_lsp("lsp = 3\n")
  assert string.contains(reason, "lsp must be a table")
}

// --- mode and base (protocol-change/095) ---------------------------------------

fn table(extra: String) -> String {
  distribution <> "[workspaces.loom]\nroot = \"/srv/loom\"\n" <> extra
}

pub fn a_table_with_no_mode_is_shared_test() {
  assert workspaces.parse(table(""))
    == Ok([workspaces.Workspace("loom", "/srv/loom", workspaces.Shared)])
  assert workspaces.parse(table("mode = \"shared\"\n"))
    == Ok([workspaces.shared("loom", "/srv/loom")])
}

pub fn worktree_mode_starts_each_branch_at_head_unless_told_otherwise_test() {
  assert workspaces.parse(table("mode = \"worktree\"\n"))
    == Ok([
      workspaces.Workspace("loom", "/srv/loom", workspaces.Worktree("HEAD")),
    ])
  assert workspaces.parse(table("mode = \"worktree\"\nbase = \"origin/main\"\n"))
    == Ok([
      workspaces.Workspace(
        "loom",
        "/srv/loom",
        workspaces.Worktree("origin/main"),
      ),
    ])
}

pub fn a_base_needs_worktree_mode_test() {
  refused(
    table("base = \"origin/main\"\n"),
    "workspaces.loom.base needs mode = \"worktree\"",
  )
  refused(
    table("mode = \"shared\"\nbase = \"origin/main\"\n"),
    "workspaces.loom.base needs mode = \"worktree\"",
  )
}

pub fn a_mode_is_one_of_two_words_test() {
  refused(
    table("mode = \"copy\"\n"),
    "workspaces.loom.mode must be \"shared\" or \"worktree\"",
  )
  refused(table("mode = 2\n"), "workspaces.loom.mode must be a string")
}

pub fn a_base_cannot_be_read_by_git_as_an_option_or_hold_a_space_test() {
  list.each(["", "-D", "--detach", "a b", "tab\there"], fn(base) {
    let text =
      table("mode = \"worktree\"\nbase = \"" <> escaped(base) <> "\"\n")
    refused(text, "workspaces.loom.base must be a branch, tag or commit name")
  })
  refused(
    table("mode = \"worktree\"\nbase = 3\n"),
    "workspaces.loom.base must be a string",
  )
}

fn escaped(text: String) -> String {
  text
  |> string.replace("\t", "\\t")
}

pub fn the_census_word_for_a_mode_is_the_configuration_word_test() {
  assert workspaces.mode_word(workspaces.Shared) == "shared"
  assert workspaces.mode_word(workspaces.Worktree("HEAD")) == "worktree"
}
