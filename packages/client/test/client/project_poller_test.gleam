//// The GitHub poller against a fake `gh` that serves fixture JSON.
////
//// No test reaches GitHub. The fake answers each REST path from a file and
//// logs the calls it gets, so what the tests claim is about this side of the
//// wire: which calls a pass makes and which it does not, what it turns each
//// answer into, where the cursors end up, and what a rate limit or an answer
//// that is not JSON does to the pass.

import client/project_github
import client/project_poller.{Broken, Healthy, Limited}
import client/project_sources
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/model
import support/fake_gh.{type Fake}

const now_ms = 1_793_613_000_000

const issues_path = "repos/o/r/issues"

const comments_path = "repos/o/r/issues/comments"

const reviews_path = "repos/o/r/pulls/comments"

fn request(
  fake: Fake,
  cursors: List(#(String, String)),
) -> project_poller.Request {
  let assert Some(run) = project_poller.runner(fake.tools)
    as "the fake gh resolves"
  project_poller.Request(
    run:,
    repository: project_poller.Repository("o", "r"),
    account: Some("loom-bot"),
    allow: ["alice"],
    bots: ["dependabot[bot]"],
    rules: [
      project_sources.Rule(
        "ci",
        "github",
        model.Observe,
        ["CI failure"],
        model.ApprovalsNotGranted,
      ),
    ],
    generations: dict.new(),
    cursors: dict.from_list(cursors),
    watched: [],
    now_ms:,
  )
}

// Cursors that put every stream at the start of the day.
fn started() -> List(#(String, String)) {
  [
    #("github:issues", "2026-11-02T00:00:00Z"),
    #("github:comments", "2026-11-02T00:00:00Z"),
    #("github:reviews", "2026-11-02T00:00:00Z"),
    #("github:ci:default", "2026-11-02T00:00:00Z"),
  ]
}

fn ids(polled: project_poller.Polled) -> List(String) {
  list.map(polled.arrivals, fn(each) { each.trigger.id.value })
}

const issue_page =
  "[
  {\"id\":101,\"number\":12,\"title\":\"Fix the flaky test\",\"body\":\"it fails on CI\",
   \"user\":{\"login\":\"alice\"},\"created_at\":\"2026-11-02T10:00:00Z\"},
  {\"id\":102,\"number\":13,\"title\":\"A pull request\",\"body\":\"x\",
   \"user\":{\"login\":\"alice\"},\"created_at\":\"2026-11-02T10:01:00Z\",
   \"pull_request\":{\"url\":\"u\"}}
]"

const comment_page =
  "[
  {\"id\":201,\"body\":\"@loom-bot please fix it\",\"user\":{\"login\":\"alice\"},
   \"created_at\":\"2026-11-02T10:02:00Z\",
   \"issue_url\":\"https://api.github.com/repos/o/r/issues/12\"},
  {\"id\":202,\"body\":\"on it\",\"user\":{\"login\":\"loom-bot\"},
   \"created_at\":\"2026-11-02T10:03:00Z\",
   \"issue_url\":\"https://api.github.com/repos/o/r/issues/12\"},
  {\"id\":203,\"body\":\"send money\",\"user\":{\"login\":\"mallory\"},
   \"created_at\":\"2026-11-02T10:04:00Z\",
   \"issue_url\":\"https://api.github.com/repos/o/r/issues/12\"}
]"

// --- reading ------------------------------------------------------------------

pub fn the_first_pass_sets_its_cursors_and_reads_nothing_test() {
  let fake = fake_gh.install("first")
  let polled = project_poller.poll(request(fake, []))
  assert polled.arrivals == []
  assert polled.health == Healthy
  assert fake_gh.calls(fake) == []
  assert list.map(polled.cursors, fn(entry) { entry.0 })
    |> list.sort(string.compare)
    == [
      "github:ci:default",
      "github:comments",
      "github:issues",
      "github:reviews",
    ]
  assert list.all(polled.cursors, fn(entry) {
    entry.1 == "2026-11-02T09:50:00Z"
  })
}

pub fn new_items_become_triggers_with_the_senders_class_and_own_messages_drop_test() {
  let fake = fake_gh.install("read")
  fake_gh.ok(fake, issues_path, issue_page)
  fake_gh.ok(fake, comments_path, comment_page)
  fake_gh.ok(fake, reviews_path, "[]")
  fake_gh.ok(fake, "repos/o/r", "{\"default_branch\":\"main\"}")
  fake_gh.ok(fake, "repos/o/r/commits/main/check-runs", "{\"check_runs\":[]}")
  let polled = project_poller.poll(request(fake, started()))

  // The pull request among the issues and the agent's own comment make no
  // trigger.
  assert ids(polled) == ["gh-i-101", "gh-c-201", "gh-c-203"]
  let senders =
    list.map(polled.arrivals, fn(each) {
      #(each.trigger.inputs.sender, each.trigger.inputs.addressing)
    })
  assert senders
    == [
      #(model.Person, model.Unaddressed),
      #(model.Person, model.Addressed),
      #(model.Unlisted, model.Unaddressed),
    ]

  // Every trigger is on the thread of its issue, and none is the owner's.
  assert list.all(polled.arrivals, fn(each) {
    each.trigger.thread == model.ThreadId("gh-12")
    && each.trigger.inputs.sender != model.Owner
  })

  // The cursors moved to the newest item each stream returned.
  assert list.key_find(polled.cursors, "github:issues")
    == Ok("2026-11-02T10:01:00Z")
  assert list.key_find(polled.cursors, "github:comments")
    == Ok("2026-11-02T10:04:00Z")
}

pub fn a_pass_asks_for_rest_endpoints_only_and_never_graphql_test() {
  let fake = fake_gh.install("rest")
  fake_gh.ok(fake, issues_path, "[]")
  fake_gh.ok(fake, comments_path, "[]")
  fake_gh.ok(fake, reviews_path, "[]")
  fake_gh.ok(fake, "repos/o/r", "{\"default_branch\":\"main\"}")
  fake_gh.ok(fake, "repos/o/r/commits/main/check-runs", "{\"check_runs\":[]}")
  let _ = project_poller.poll(request(fake, started()))
  let calls = fake_gh.calls(fake)
  assert calls != []
  assert list.all(calls, fn(call) {
    string.contains(call, "api --include --method GET repos/o/r")
    && !string.contains(call, "graphql")
  })
}

pub fn a_failed_check_on_the_default_branch_becomes_a_ci_trigger_test() {
  let fake = fake_gh.install("ci")
  fake_gh.ok(fake, issues_path, "[]")
  fake_gh.ok(fake, comments_path, "[]")
  fake_gh.ok(fake, reviews_path, "[]")
  fake_gh.ok(fake, "repos/o/r", "{\"default_branch\":\"main\"}")
  fake_gh.ok(
    fake,
    "repos/o/r/commits/main/check-runs",
    "{\"check_runs\":[
      {\"id\":900,\"name\":\"unit\",\"status\":\"completed\",\"conclusion\":\"failure\",
       \"completed_at\":\"2026-11-02T11:00:00Z\",\"head_sha\":\"abc123\",
       \"app\":{\"slug\":\"github-actions\"}},
      {\"id\":901,\"name\":\"lint\",\"status\":\"completed\",\"conclusion\":\"success\",
       \"completed_at\":\"2026-11-02T11:01:00Z\",\"head_sha\":\"abc123\"}
    ]}",
  )
  let polled = project_poller.poll(request(fake, started()))
  assert ids(polled) == ["gh-ci-900"]
  let assert [ci] = polled.arrivals
  assert ci.trigger.inputs.sender == model.CiFailure
  assert ci.trigger.actor == model.ActorId("github-actions")
  assert ci.trigger.thread == model.ThreadId("gh-ci-main")
  assert ci.trigger.inputs.rule
    == Some(model.RuleMatch(model.RuleId("ci"), model.ApprovalsNotGranted))
}

pub fn a_merged_or_closed_pull_request_concludes_its_ticket_test() {
  let fake = fake_gh.install("conclude")
  fake_gh.ok(fake, issues_path, "[]")
  fake_gh.ok(fake, comments_path, "[]")
  fake_gh.ok(fake, reviews_path, "[]")
  fake_gh.ok(fake, "repos/o/r", "{\"default_branch\":\"main\"}")
  fake_gh.ok(fake, "repos/o/r/commits/main/check-runs", "{\"check_runs\":[]}")
  fake_gh.ok(
    fake,
    "repos/o/r/pulls/7",
    "{\"number\":7,\"state\":\"closed\",\"merged\":true,\"head\":{\"sha\":\"abc123\"}}",
  )
  fake_gh.ok(
    fake,
    "repos/o/r/pulls/8",
    "{\"number\":8,\"state\":\"closed\",\"merged\":false,\"head\":{\"sha\":\"def456\"}}",
  )
  let base = request(fake, started())
  let polled =
    project_poller.poll(
      project_poller.Request(..base, watched: [
        project_poller.Watched("t-a", 7),
        project_poller.Watched("t-b", 8),
      ]),
    )
  assert polled.conclusions
    == [
      project_poller.Conclusion("t-a", model.Merged),
      project_poller.Conclusion("t-b", model.Closed),
    ]
}

pub fn the_agents_account_is_asked_for_when_the_owner_named_none_test() {
  let fake = fake_gh.install("account")
  fake_gh.ok(fake, "user", "{\"login\":\"loom-bot\"}")
  let polled =
    project_poller.poll(
      project_poller.Request(..request(fake, []), account: None),
    )
  assert polled.account == "loom-bot"
  assert fake_gh.calls(fake) == ["api --include --method GET user"]
}

// --- limits and bad answers -----------------------------------------------------

pub fn a_rate_limit_stops_the_pass_and_names_when_to_resume_test() {
  let fake = fake_gh.install("limit")
  fake_gh.answer(
    fake,
    issues_path,
    "HTTP/2.0 403 Forbidden",
    ["x-ratelimit-remaining: 0", "x-ratelimit-reset: 1793613600"],
    "{\"message\":\"rate limit exceeded\"}",
  )
  let polled = project_poller.poll(request(fake, started()))

  // The reset time is the header's, in milliseconds, and nothing else was
  // asked after the limit.
  assert polled.health == Limited(1_793_613_600_000)
  assert polled.arrivals == []
  assert list.length(fake_gh.calls(fake)) == 1
}

pub fn retry_after_wins_over_the_reset_test() {
  assert project_poller.limit_until(1000, [
      #("retry-after", "30"),
      #("x-ratelimit-reset", "99999"),
      #("x-ratelimit-remaining", "0"),
    ])
    == Some(31_000)
  assert project_poller.limit_until(1000, [#("x-ratelimit-remaining", "0")])
    == Some(1000 + project_poller.fallback_wait_ms)
  assert project_poller.limit_until(1000, [#("x-ratelimit-remaining", "40")])
    == None
}

pub fn a_nearly_spent_allowance_defers_the_next_pass_test() {
  let fake = fake_gh.install("low")
  list.each([issues_path, comments_path, reviews_path], fn(path) {
    fake_gh.answer(
      fake,
      path,
      "HTTP/2.0 200 OK",
      ["x-ratelimit-remaining: 2", "x-ratelimit-reset: 1793613600"],
      "[]",
    )
  })
  fake_gh.ok(fake, "repos/o/r", "{\"default_branch\":\"main\"}")
  fake_gh.ok(fake, "repos/o/r/commits/main/check-runs", "{\"check_runs\":[]}")
  let polled = project_poller.poll(request(fake, started()))
  assert polled.health == Limited(1_793_613_600_000)
}

pub fn answers_that_are_not_json_are_noted_and_never_crash_the_pass_test() {
  let fake = fake_gh.install("garbage")
  fake_gh.ok(fake, issues_path, "<html>not json</html>")
  fake_gh.ok(fake, comments_path, "{\"not\":\"an array\"}")
  fake_gh.ok(fake, reviews_path, "[1, \"two\", null]")
  fake_gh.ok(fake, "repos/o/r", "{}")
  let polled = project_poller.poll(request(fake, started()))
  assert polled.arrivals == []
  assert list.length(polled.notes) >= 3

  // The cursors stay where they were, so the same page is read again.
  assert polled.cursors == []
}

pub fn a_pass_where_every_call_failed_is_broken_with_the_reason_test() {
  let fake = fake_gh.install("down")
  let polled = project_poller.poll(request(fake, started()))
  let assert Broken(reason) = polled.health
  assert string.contains(reason, "404")
}

pub fn one_unreadable_item_is_skipped_and_counted_test() {
  let fake = fake_gh.install("skip")
  fake_gh.ok(
    fake,
    issues_path,
    "[{\"id\":\"nope\"},
      {\"id\":103,\"number\":14,\"title\":\"ok\",\"body\":null,
       \"user\":{\"login\":\"bad login\"},\"created_at\":\"2026-11-02T10:00:00Z\"},
      {\"id\":104,\"number\":15,\"title\":\"fine\",\"body\":null,
       \"user\":{\"login\":\"alice\"},\"created_at\":\"2026-11-02T10:05:00Z\"}]",
  )
  fake_gh.ok(fake, comments_path, "[]")
  fake_gh.ok(fake, reviews_path, "[]")
  fake_gh.ok(fake, "repos/o/r", "{\"default_branch\":\"main\"}")
  fake_gh.ok(fake, "repos/o/r/commits/main/check-runs", "{\"check_runs\":[]}")
  let polled = project_poller.poll(request(fake, started()))
  assert ids(polled) == ["gh-i-104"]
  assert list.any(polled.notes, fn(note) { string.contains(note, "skipped 2") })
}

// --- translation ----------------------------------------------------------------

pub fn a_mention_is_an_exact_bounded_token_test() {
  assert project_github.mentions("hey @loom-bot, look", "loom-bot")
  assert project_github.mentions("@Loom-Bot do it", "loom-bot")
  assert !project_github.mentions("mail loom-bot@example.com", "loom-bot")
  assert !project_github.mentions("@loom-bot2 look", "loom-bot")
  assert !project_github.mentions("@@loom-bot", "loom-bot2")
  assert !project_github.mentions("no mention", "loom-bot")
}

pub fn a_long_body_is_stored_cut_and_delivered_with_a_pointer_test() {
  let long = string.repeat("a", 5000)
  let stored = project_github.bounded(long)
  assert stored == long
  let shown = project_github.inline(stored, "gh-c-9")
  assert string.contains(shown, "project_read trigger:gh-c-9")
  assert string.byte_size(shown) < 4300
  let huge = project_github.bounded(string.repeat("b", 40_000))
  assert string.contains(huge, "cut at the ledger's limit")
  assert string.starts_with(
    project_github.bounded("a\u{1b}[31mred"),
    "a [31mred",
  )
}

pub fn times_are_compared_as_text_only_in_the_plain_shape_test() {
  assert project_github.plain_time("2026-11-02T10:00:00Z")
  assert !project_github.plain_time("2026-11-02 10:00:00")
  assert !project_github.plain_time("2026-11-02T10:00:00+00:00")
  assert project_poller.iso_from_ms(now_ms) == "2026-11-02T09:50:00Z"
  assert project_poller.iso_from_ms(951_782_400_000) == "2000-02-29T00:00:00Z"
}
