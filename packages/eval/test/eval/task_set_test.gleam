//// The committed task set is portable: it names its repository, never a
//// host path, and every file in it decodes under the task format's own
//// total decoder.

import eval/task
import gleam/list
import gleam/string
import simplifile

const set_directory = "tasks/loom-history-v1"

// The fragments that would bind a file to the machine that produced it.
const host_paths = ["/home/", "/root/"]

fn names() -> List(String) {
  let assert Ok(names) = simplifile.read_directory(set_directory)
    as "the committed task set exists"

  list.sort(names, string.compare)
}

pub fn committed_task_set_is_portable_test() {
  let names = names()
  let tasks = list.filter(names, string.ends_with(_, ".json"))

  assert tasks != []
  assert list.contains(names, "prove.jsonl")

  // No file, task or proof line, carries a host path.
  list.each(names, fn(name) {
    let assert Ok(text) = simplifile.read(set_directory <> "/" <> name)
    list.each(host_paths, fn(fragment) {
      assert !string.contains(text, fragment) as { name <> " has " <> fragment }
    })
  })

  // Every task file loads, verifies its own id and names a logical repository.
  list.each(tasks, fn(name) {
    let assert Ok(loaded) = task.load(set_directory <> "/" <> name)
    case loaded.workspace {
      task.GitTree(repository:, ..) -> {
        assert repository == "loom"
      }
      task.Inline(..) -> Nil
    }
  })

  // The proofs cover exactly the tasks committed, none more.
  let assert Ok(proofs) = simplifile.read(set_directory <> "/prove.jsonl")
  let lines = string.split(string.trim(proofs), "\n")
  assert list.length(lines) == list.length(tasks)
  assert list.all(tasks, fn(name) {
    let id = string.drop_end(name, 5)
    list.any(lines, string.contains(_, id))
  })
}
