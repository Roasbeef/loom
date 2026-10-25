import client/secrets
import core/json
import eval/git
import eval/repos
import eval/task.{type Task, ExpectedFiles, GitTree, HandWritten, Task}
import gleam/result
import gleam/string
import support/scripted

fn sh(command: String) -> String {
  let assert Ok(capture) =
    secrets.host_runner()(["bash", "-c", command <> " 2>&1"], 60_000)
  let assert 0 = capture.status as command

  string.trim(capture.output)
}

// A one-commit repository, and its commit and tree ids.
fn clone_source(name: String) -> #(String, String, String) {
  let repo = scripted.scratch(name)
  let quoted = git.shell_quote(repo)

  sh("cd " <> quoted <> " && git init -q && printf 'one\\n' > one.txt")
  sh(
    "cd "
    <> quoted
    <> " && git add -A && git -c user.name=t -c user.email=t@t commit -q -m first",
  )

  #(
    repo,
    sh("git -C " <> quoted <> " rev-parse HEAD"),
    sh("git -C " <> quoted <> " rev-parse 'HEAD^{tree}'"),
  )
}

fn named(repository: String, commit: String, tree: String) -> Task {
  task.mint(Task(
    id: "",
    name: "repos",
    prompt: "p",
    workspace: GitTree(repository, commit, tree, []),
    verifier: ExpectedFiles([]),
    tags: [],
    provenance: HandWritten("test"),
  ))
}

pub fn repository_name_charset_test() {
  assert repos.valid_name("loom")
  assert repos.valid_name("a")
  assert repos.valid_name("0-9-a")
  assert repos.valid_name(string.repeat("a", 64))

  assert !repos.valid_name("")
  assert !repos.valid_name(string.repeat("a", 65))
  assert !repos.valid_name("-loom")
  assert !repos.valid_name("--upload-pack=x")
  assert !repos.valid_name("Loom")
  assert !repos.valid_name("lo om")
  assert !repos.valid_name("ext::sh")
  assert !repos.valid_name("a/b")
  assert !repos.valid_name("a\u{0}")

  assert repos.add(repos.empty(), "-loom", "/srv/loom") |> result.is_error
}

pub fn resolver_refuses_unsafe_paths_test() {
  let refuses = fn(spec) { repos.from_flags([spec]) |> result.is_error }

  assert !refuses("loom=/srv/git/loom")
  assert !refuses("loom=/srv/a=b")
  assert refuses("loom=relative/path")
  assert refuses("loom=https://example.invalid/loom.git")
  assert refuses("loom=--upload-pack=touch /x")
  assert refuses("loom=/srv/-evil")
  assert refuses("loom=/srv/ext::sh -c x")
  assert refuses("loom=/srv/a\u{0}b")
  assert refuses("loom=/" <> string.repeat("a", 1024))
  assert refuses("loom")
  assert refuses("Loom=/srv/loom")
  assert refuses("loom=")

  // Two paths for one name would make flag order choose the clone.
  assert repos.from_flags(["loom=/a", "loom=/b"]) |> result.is_error
}

pub fn resolver_refuses_tree_mismatch_test() {
  let #(repo, commit, tree) = clone_source("resolver-mismatch")
  let assert Ok(known) = repos.from_flags(["loom=" <> repo])
  let runner = secrets.host_runner()

  assert repos.resolve(known, runner, "loom", commit, tree) == Ok(repo)

  let wrong = string.repeat("0", 40)
  let assert Error(reason) = repos.resolve(known, runner, "loom", commit, wrong)
  assert string.contains(reason, "tree mismatch")

  // A commit the clone does not hold is refused, and so is a name nobody mapped.
  let absent = repos.resolve(known, runner, "loom", wrong, tree)
  assert result.is_error(absent)
  let assert Error(unmapped) =
    repos.resolve(known, runner, "other", commit, tree)
  assert string.contains(unmapped, "--repo other=")
}

pub fn task_id_ignores_where_the_clone_lives_test() {
  let #(first, commit, tree) = clone_source("identity-first")
  let second = scripted.scratch("identity-second") <> "/copy"
  sh(
    "git clone -q " <> git.shell_quote(first) <> " " <> git.shell_quote(second),
  )

  let one = named("loom", commit, tree)
  let two = named("loom", commit, tree)
  assert one.id == two.id

  let assert Ok(at_first) = repos.from_flags(["loom=" <> first])
  let assert Ok(at_second) = repos.from_flags(["loom=" <> second])
  let runner = secrets.host_runner()

  // Same task, two clones, two paths: both resolve and neither moves the id.
  assert repos.resolve(at_first, runner, "loom", commit, tree) == Ok(first)
  assert repos.resolve(at_second, runner, "loom", commit, tree) == Ok(second)
  assert first != second
  assert string.contains(task.to_json(one) |> task_text, first) == False
}

fn task_text(value) -> String {
  json.to_string(value)
}
