import eval/split
import eval/task
import gleam/int
import gleam/list
import gleam/string

fn sample(tags: List(String)) -> task.Task {
  task.Task(
    id: "abc",
    name: "n",
    prompt: "p",
    workspace: task.Inline(files: []),
    verifier: task.ExpectedFiles(expected: []),
    tags:,
    provenance: task.HandWritten(author: "t"),
  )
}

// Pinned vectors: the SHA-256 of `salt <> family`, first byte mod ten, worked
// out independently of this code. A change to the hash, the slice of digest
// or the thresholds changes one of them.
pub fn split_assignment_is_stable_test() {
  assert split.assign("salt", "packages/core/json") == split.Holdout
  assert split.assign("salt", "packages/core/msgpack") == split.Tune
  assert split.assign("salt", "packages/prompt/pack") == split.Validate
  assert split.assign("salt", "packages/x/m4") == split.Validate
  assert split.assign("salt", "packages/x/m2") == split.Holdout
  assert split.assign("salt", "packages/x/m11") == split.Tune
  assert split.assign("other", "packages/core/json") == split.Tune
  assert split.assign("", "") == split.Validate
}

pub fn split_proportions_test() {
  let splits =
    list.repeat(Nil, 10_000)
    |> list.index_map(fn(_, index) {
      split.assign("s", "packages/p/m" <> int.to_string(index))
    })
  let count = fn(wanted) { list.count(splits, fn(found) { found == wanted }) }

  assert count(split.Tune) > 5700 && count(split.Tune) < 6300
  assert count(split.Validate) > 1700 && count(split.Validate) < 2300
  assert count(split.Holdout) > 1700 && count(split.Holdout) < 2300
}

pub fn holdout_admit_is_refused_test() {
  assert split.admissible(split.Tune) == Ok(split.Tune)
  assert split.admissible(split.Validate) == Ok(split.Validate)
  let assert Error(reason) = split.admissible(split.Holdout)
  assert string.contains(reason, "holdout")
}

pub fn family_comes_from_the_tag_or_the_id_test() {
  assert split.family(sample(["x", "family:packages/core/json", "family:z"]))
    == "packages/core/json"
  assert split.family(sample(["x"])) == "abc"
  assert split.family(sample(["family:"])) == "abc"
}
