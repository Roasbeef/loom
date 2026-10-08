//// Nightly resolution runs the production metadata and manifest path against
//// an injected GitHub transport. A fixture can write only declared responses;
//// unexpected URLs fail rather than reaching the real network.

import core/json
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should
import simplifile
import tui/update/files
import tui/update/options
import tui/update/source

const api = "https://api.github.com/repos/Roasbeef/loom/"

const newest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const previous = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

const outside = "cccccccccccccccccccccccccccccccccccccccc"

pub fn nightly_is_exclusive_but_accepts_other_update_options_test() {
  let assert Ok(parsed) =
    options.parse(["--nightly", "--check", "--client", "slim"])
    as "nightly choices parse"
  parsed.selection |> should.equal(options.Nightly)
  parsed.action |> should.equal(options.Check)
  for_conflicts([["--version", "v0.2.0"], ["--commit", previous], ["--nightly"]])
}

fn for_conflicts(conflicts) {
  list.each(conflicts, fn(conflict) {
    options.parse(list.append(["--nightly"], conflict)) |> should.be_error
    options.parse(list.append(conflict, ["--nightly"])) |> should.be_error
  })
}

pub fn nightly_selects_main_history_instead_of_release_order_test() {
  resolve([
    #(api <> "commits/main", commit(newest)),
    #(
      api <> "releases?per_page=30&page=1",
      releases([
        release(outside, False),
        release(previous, False),
        release(newest, False),
      ]),
    ),
    #(history(1), commits([newest, previous])),
    #(asset(newest), manifest(newest)),
  ])
  |> selected(newest)
}

pub fn nightly_falls_back_past_unpublished_head_and_draft_test() {
  resolve([
    #(api <> "commits/main", commit(newest)),
    #(
      api <> "releases?per_page=30&page=1",
      releases([
        release(outside, False),
        release(newest, True),
        release(previous, False),
      ]),
    ),
    #(history(1), commits([newest, previous])),
    #(asset(previous), manifest(previous)),
  ])
  |> selected(previous)
}

pub fn nightly_paginates_both_inventories_with_a_pinned_head_test() {
  resolve([
    #(api <> "commits/main", commit(newest)),
    #(
      api <> "releases?per_page=30&page=1",
      releases(list.repeat(release(outside, False), 30)),
    ),
    #(
      api <> "releases?per_page=30&page=2",
      releases([release(previous, False)]),
    ),
    #(history(1), commits(list.repeat(newest, 30))),
    #(history(2), commits([previous])),
    #(asset(previous), manifest(previous)),
  ])
  |> selected(previous)
}

pub fn nightly_rejects_absent_off_main_or_mismatched_builds_test() {
  let base = [#(api <> "commits/main", commit(newest))]
  resolve(list.append(base, [#(api <> "releases?per_page=30&page=1", "[]")]))
  |> should.be_error
  resolve(
    list.append(base, [
      #(
        api <> "releases?per_page=30&page=1",
        releases([release(outside, False)]),
      ),
      #(history(1), commits([newest, previous])),
    ]),
  )
  |> should.be_error
  resolve(
    list.append(base, [
      #(
        api <> "releases?per_page=30&page=1",
        releases([release(newest, False)]),
      ),
      #(history(1), commits([newest])),
      #(asset(newest), manifest(previous)),
    ]),
  )
  |> should.be_error
}

pub fn nightly_metadata_failures_do_not_fall_back_to_stable_test() {
  resolve([]) |> should.be_error
  resolve([#(api <> "commits/main", "{}")]) |> should.be_error
  resolve([
    #(api <> "commits/main", commit(newest)),
    #(api <> "releases?per_page=30&page=1", "{}"),
  ])
  |> should.be_error
}

pub fn nightly_search_limits_fail_closed_test() {
  let pages =
    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    |> list.map(fn(page) {
      #(
        api <> "releases?per_page=30&page=" <> int.to_string(page),
        releases(list.repeat(release(outside, False), 30)),
      )
    })
  resolve([
    #(api <> "commits/main", commit(newest)),
    #(history(1), commits([newest, previous])),
    ..pages
  ])
  |> should.equal(Error("no published nightly build in recent main history"))
  let pages =
    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    |> list.map(fn(page) { #(history(page), commits(list.repeat(newest, 30))) })
  resolve([
    #(api <> "commits/main", commit(newest)),
    #(
      api <> "releases?per_page=30&page=1",
      releases([release(previous, False)]),
    ),
    ..pages
  ])
  |> should.equal(Error("nightly search exceeded 300 main commits"))
}

pub fn nightly_keeps_working_after_three_hundred_releases_test() {
  let pages =
    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    |> list.map(fn(page) {
      #(
        api <> "releases?per_page=30&page=" <> int.to_string(page),
        releases(list.repeat(release(previous, False), 30)),
      )
    })
  resolve([
    #(api <> "commits/main", commit(newest)),
    #(history(1), commits([newest, previous])),
    #(asset(previous), manifest(previous)),
    ..pages
  ])
  |> selected(previous)
}

pub fn nightly_cannot_bypass_main_selection_with_local_or_mirror_test() {
  list.each(
    [
      ["--from", "/tmp"],
      ["--manifest-url", "https://example.invalid/manifest-linux-x86_64.json"],
    ],
    fn(extra) {
      let assert Ok(choices) = options.parse(list.append(["--nightly"], extra))
        as "conflict is checked before transport"
      source.resolve(choices, "linux-x86_64", "/tmp", fn(_, _, _) {
        Error("transport should not run")
      })
      |> should.equal(Error(
        "--nightly selects GitHub main; it cannot use --from or --manifest-url",
      ))
    },
  )
}

fn selected(outcome: Result(source.Release, String), expected: String) {
  let assert Ok(release) = outcome as "nightly resolves the production manifest"
  release.manifest.commit |> should.equal(expected)
  release.manifest.tag |> should.equal("commit-" <> expected)
}

fn resolve(responses) {
  let assert Ok(stage) = files.staging("/tmp") as "private fixture stage"
  let assert Ok(choices) = options.parse(["--nightly", "--check"])
    as "nightly fixture choices"
  let outcome =
    source.resolve(choices, "linux-x86_64", stage, fn(url, destination, _) {
      case string.ends_with(url, ".asc") {
        True -> Ok(source.Absent)
        False -> {
          use body <- result.try(
            list.key_find(responses, url)
            |> result.map_error(fn(_) { "unexpected fixture URL: " <> url }),
          )
          use Nil <- result.try(
            simplifile.write(destination, body)
            |> result.map_error(fn(_) { "fixture write failed" }),
          )
          Ok(source.Present)
        }
      }
    })
  let assert Ok(Nil) = simplifile.delete(stage) as "fixture cleanup"
  outcome
}

fn commit(sha) {
  json.to_string(json.Object([#("sha", json.String(sha))]))
}

fn commits(shas) {
  "[" <> string.join(list.map(shas, commit), ",") <> "]"
}

fn releases(values) {
  json.to_string(json.Array(values))
}

fn release(sha, draft) {
  json.Object([
    #("tag_name", json.String("commit-" <> sha)),
    #("draft", json.Bool(draft)),
    #("published_at", json.String("2026-10-08T08:23:00Z")),
    #("prerelease", json.Bool(True)),
  ])
}

fn history(page) {
  api <> "commits?sha=" <> newest <> "&per_page=30&page=" <> int.to_string(page)
}

fn asset(sha) {
  "https://github.com/Roasbeef/loom/releases/download/commit-"
  <> sha
  <> "/manifest-linux-x86_64.json"
}

fn manifest(sha) {
  let artifacts =
    list.map(["server", "client", "slim"], fn(component) {
      json.Object([
        #("component", json.String(component)),
        #("name", json.String(component <> ".tar.gz")),
        #("root", json.String(component)),
        #("size", json.Int(1)),
        #("sha256", json.String(string.repeat("a", 64))),
      ])
    })
  json.to_string(
    json.Object([
      #("schema", json.Int(1)),
      #("repository", json.String("Roasbeef/loom")),
      #("tag", json.String("commit-" <> sha)),
      #("version", json.String("0.2.0")),
      #("commit", json.String(sha)),
      #("platform", json.String("linux-x86_64")),
      #("artifacts", json.Array(artifacts)),
    ]),
  )
}
