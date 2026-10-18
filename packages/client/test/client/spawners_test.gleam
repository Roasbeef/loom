//// The `[spawners.<name>]` tables are strict, total and absent by default
//// (protocol-change/084). A spawner is a pinned distribution peer under a name
//// with exactly one placement, a profile, a tool ceiling and four limits, so a
//// table that says anything else is refused wherever the file is read, and the
//// refusal names the key.

import client/catalog
import client/spawners.{InDirectory, InPool, OnExecutor, Spawner}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const distribution =
  "[distribution]
node = \"box@100.64.0.9\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"laptop@100.64.0.5\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[[distribution.peers]]
node = \"desk@100.64.0.6\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000002\"

[[distribution.peers]]
node = \"runner@100.64.0.7\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000003\"

[executors.runner]
node = \"runner@100.64.0.7\"

[pools.linux]
executors = [\"runner\"]

[profiles.cheap-review.roles]
main = [\"fast\"]
"

// The smallest table that is accepted: the node, one placement and a profile.
const minimal =
  "[spawners.laptop]
node = \"laptop@100.64.0.5\"
executor = \"runner\"
workspace = \"loom\"
profile = \"cheap-review\"
"

fn with(table: String) -> String {
  distribution <> "\n" <> table
}

fn refused(text: String, fragment: String) {
  let assert Error(reason) = spawners.parse(text)
    as "the table is refused by its own parser"
  assert string.contains(reason, fragment)
}

// The `minimal` table with one line added to it.
fn minimal_with(line: String) -> String {
  with(minimal <> line <> "\n")
}

// A table named `laptop` whose placement lines are `placement`.
fn placed(placement: String) -> String {
  with("[spawners.laptop]
node = \"laptop@100.64.0.5\"
profile = \"cheap-review\"
" <> placement <> "\n")
}

pub fn an_absent_table_configures_no_spawner_test() {
  assert spawners.parse("") == Ok([])
  assert spawners.parse(distribution) == Ok([])
  assert spawners.from_document(dict.new()) == Ok([])
}

pub fn a_table_may_state_every_key_test() {
  let text =
    with(
      "[spawners.laptop]
node = \"laptop@100.64.0.5\"
executor = \"runner\"
workspace = \"loom\"
profile = \"cheap-review\"
tools = [\"fs_read\", \"bash\", \"agent_note\", \"agent_send\"]
max_depth = 2
max_sessions = 16
max_within_s = 3600
default_within_s = 600
retain_s = 7200
token_budget_per_day = 5000000
child_token_budget = 200000
max_per_day = 20
transcript = \"visible\"
",
    )
  assert spawners.parse(text)
    == Ok([
      Spawner(
        name: "laptop",
        node: "laptop@100.64.0.5",
        placement: OnExecutor(executor: "runner", workspace: "loom"),
        profile: "cheap-review",
        tools: ["fs_read", "bash", "agent_note", "agent_send"],
        max_depth: 2,
        max_sessions: 16,
        max_within_s: 3600,
        default_within_s: 600,
        retain_s: 7200,
        idle_close_s: 3600,
        token_budget_per_day: Some(5_000_000),
        child_token_budget: Some(200_000),
        max_per_day: Some(20),
        transcript: spawners.Visible,
      ),
    ])
}

pub fn omitted_keys_take_the_documented_defaults_test() {
  let assert Ok([spawner]) = spawners.parse(with(minimal))
  assert spawner.tools == spawners.default_tools()
  assert spawner.max_depth == 1
  assert spawner.max_sessions == 4
  assert spawner.max_within_s == 14_400
  assert spawner.default_within_s == 1800
  assert spawner.retain_s == 604_800
  assert spawner.idle_close_s == 3600

  // A spawner's children keep their transcripts on this machine unless the
  // table says otherwise (protocol-change/090).
  assert spawner.transcript == spawners.Hidden

  // The metering keys default to no bound, which is a spawner as it was before
  // the keys existed.
  assert spawner.token_budget_per_day == None
  assert spawner.child_token_budget == None
  assert spawner.max_per_day == None
  assert !spawners.metered(spawner)
}

pub fn any_one_metering_key_makes_a_spawner_metered_test() {
  let metered = fn(line) {
    let assert Ok([spawner]) = spawners.parse(minimal_with(line))
    spawners.metered(spawner)
  }
  assert metered("token_budget_per_day = 1000")
  assert metered("child_token_budget = 1000")
  assert metered("max_per_day = 3")
}

pub fn a_metering_key_is_a_positive_integer_test() {
  refused(
    minimal_with("token_budget_per_day = 0"),
    "spawners.laptop.token_budget_per_day must be positive",
  )
  refused(
    minimal_with("child_token_budget = -5"),
    "spawners.laptop.child_token_budget must be positive",
  )
  refused(
    minimal_with("max_per_day = \"ten\""),
    "spawners.laptop.max_per_day must be an integer",
  )
  refused(
    minimal_with("max_per_day = 2.5"),
    "spawners.laptop.max_per_day must be an integer",
  )
}

pub fn the_default_ceiling_leaves_out_what_reaches_beyond_the_session_test() {
  let tools = spawners.default_tools()
  assert list.contains(tools, "bash")
  assert list.contains(tools, "fs_edit")
  assert list.contains(tools, "agent_note")
  assert list.contains(tools, "agent_send")
  assert !list.contains(tools, "agent_spawn")
  assert !list.contains(tools, "remember")
  assert !list.contains(tools, "peer_send")
  assert !list.contains(tools, "peer_roster")
  assert !list.contains(tools, "schedule_create")
  assert !list.contains(tools, "schedule_cancel")
}

pub fn a_placement_is_an_executor_a_pool_or_a_directory_test() {
  let assert Ok([on_executor]) =
    spawners.parse(placed("executor = \"runner\"\nworkspace = \"loom\""))
  assert on_executor.placement
    == OnExecutor(executor: "runner", workspace: "loom")

  let assert Ok([in_pool]) =
    spawners.parse(placed("pool = \"linux\"\nworkspace = \"loom\""))
  assert in_pool.placement == InPool(pool: "linux", workspace: "loom")

  let assert Ok([in_directory]) =
    spawners.parse(placed("directory = \"/srv/loom/scratch\""))
  assert in_directory.placement == InDirectory(path: "/srv/loom/scratch")
}

pub fn the_list_is_sorted_and_resolves_by_name_and_by_node_test() {
  let text = with(minimal <> "
[spawners.desk]
node = \"desk@100.64.0.6\"
directory = \"/srv/loom/desk\"
profile = \"cheap-review\"
")
  let assert Ok([first, second] as configured) = spawners.parse(text)
  assert first.name == "desk"
  assert second.name == "laptop"
  assert spawners.find(configured, "laptop") == Ok(second)
  assert spawners.find(configured, "box") == Error(Nil)
  assert spawners.by_node(configured, "desk@100.64.0.6") == Ok(first)
  assert spawners.by_node(configured, "runner@100.64.0.7") == Error(Nil)
}

pub fn standing_follows_the_table_and_a_removed_table_is_removed_test() {
  let text =
    with(
      "[spawners.laptop]
node = \"laptop@100.64.0.5\"
executor = \"runner\"
workspace = \"loom\"
profile = \"cheap-review\"
max_within_s = 3600
retain_s = 7200
idle_close_s = 120
",
    )
  let assert Ok(configured) = spawners.parse(text)
  assert spawners.standing(configured, "laptop")
    == spawners.Configured(retain_ms: 7_200_000, idle_close_ms: 120_000)

  // A spawner whose table was removed can send nothing more.
  assert spawners.standing(configured, "gone") == spawners.Removed
}

pub fn idle_close_must_be_a_positive_integer_test() {
  refused(
    with(
      "[spawners.laptop]
node = \"laptop@100.64.0.5\"
executor = \"runner\"
workspace = \"loom\"
profile = \"cheap-review\"
idle_close_s = 0
",
    ),
    "spawners.laptop.idle_close_s must be positive",
  )
}

// `transcript` is one of two words. A typo is refused and never read as
// either, so a misspelt `hidden` cannot open a child's transcript.
pub fn transcript_is_visible_or_hidden_test() {
  let assert Ok([visible]) =
    spawners.parse(minimal_with("transcript = \"visible\""))
  assert visible.transcript == spawners.Visible
  let assert Ok([hidden]) =
    spawners.parse(minimal_with("transcript = \"hidden\""))
  assert hidden.transcript == spawners.Hidden
  refused(
    minimal_with("transcript = \"hiden\""),
    "spawners.laptop.transcript must be",
  )
}

pub fn a_node_that_is_not_a_pinned_peer_is_refused_by_name_test() {
  refused(
    with(
      "[spawners.laptop]
node = \"stranger@10.0.0.9\"
executor = \"runner\"
workspace = \"loom\"
profile = \"cheap-review\"
",
    ),
    "spawners.laptop.node stranger@10.0.0.9 is not a peer of this node: pin it in [[distribution.peers]]",
  )
}

pub fn spawners_without_a_distribution_table_are_refused_test() {
  refused(
    "[spawners.laptop]\nnode = \"laptop@100.64.0.5\"\ndirectory = \"/srv\"\n",
    "spawners needs a [distribution] table naming its peers",
  )
}

pub fn two_names_for_one_node_are_refused_test() {
  refused(with(minimal <> "
[spawners.phone]
node = \"laptop@100.64.0.5\"
directory = \"/srv/loom/phone\"
profile = \"cheap-review\"
"), "spawners.phone.node laptop@100.64.0.5 is already the node of spawners.laptop")
}

pub fn exactly_one_placement_is_required_test() {
  refused(
    placed(""),
    "spawners.laptop needs a placement: executor with workspace, pool with workspace, or directory",
  )
  let more = "spawners.laptop names more than one placement"
  refused(
    placed("executor = \"runner\"\npool = \"linux\"\nworkspace = \"loom\""),
    more,
  )
  refused(
    placed("executor = \"runner\"\ndirectory = \"/srv\"\nworkspace = \"loom\""),
    more,
  )
  refused(placed("pool = \"linux\"\ndirectory = \"/srv\""), more)
  refused(
    placed(
      "executor = \"runner\"\npool = \"linux\"\ndirectory = \"/srv\"\nworkspace = \"loom\"",
    ),
    more,
  )
}

pub fn a_placement_must_resolve_and_carry_the_workspace_it_needs_test() {
  refused(
    placed("executor = \"ghost\"\nworkspace = \"loom\""),
    "spawners.laptop.executor ghost is not a configured [executors.<name>]",
  )
  refused(
    placed("pool = \"ghost\"\nworkspace = \"loom\""),
    "spawners.laptop.pool ghost is not a configured [pools.<name>]",
  )
  refused(
    placed("executor = \"runner\""),
    "spawners.laptop.workspace is required with executor",
  )
  refused(
    placed("pool = \"linux\""),
    "spawners.laptop.workspace is required with pool",
  )
  refused(
    placed("directory = \"/srv\"\nworkspace = \"loom\""),
    "spawners.laptop.workspace is not used with directory",
  )
  refused(
    placed("executor = \"runner\"\nworkspace = \"a/b\""),
    "spawners.laptop.workspace is not a workspace name",
  )
}

pub fn a_directory_is_absolute_and_has_no_parent_segment_test() {
  refused(
    placed("directory = \"srv/loom\""),
    "spawners.laptop.directory must be an absolute path",
  )
  refused(
    placed("directory = \"/srv/../etc\""),
    "spawners.laptop.directory must not contain a .. segment",
  )
}

pub fn a_profile_is_required_and_must_be_configured_test() {
  refused(
    with(
      "[spawners.laptop]
node = \"laptop@100.64.0.5\"
directory = \"/srv\"
",
    ),
    "spawners.laptop.profile is required",
  )
  refused(
    with(
      "[spawners.laptop]
node = \"laptop@100.64.0.5\"
directory = \"/srv\"
profile = \"ghost\"
",
    ),
    "spawners.laptop.profile ghost is not a configured [profiles.<name>]",
  )
}

pub fn the_tool_ceiling_is_a_nonempty_list_of_distinct_names_test() {
  let words = "spawners.laptop.tools must be a nonempty array of tool names"
  refused(minimal_with("tools = []"), words)
  refused(minimal_with("tools = \"bash\""), words)
  refused(minimal_with("tools = [\"bash\", 1]"), words)
  refused(minimal_with("tools = [\"\"]"), words)
  refused(
    minimal_with("tools = [\"bash\", \"grep\", \"bash\"]"),
    "spawners.laptop.tools lists bash more than once",
  )
}

pub fn a_session_cap_above_the_executor_scope_limit_is_refused_test() {
  let assert Ok([sixteen]) = spawners.parse(minimal_with("max_sessions = 16"))
  assert sixteen.max_sessions == 16
  refused(
    minimal_with("max_sessions = 17"),
    "spawners.laptop.max_sessions 17 is above 16, the number of scopes an executor admits",
  )
}

pub fn a_limit_must_be_a_positive_integer_test() {
  refused(
    minimal_with("max_sessions = 0"),
    "spawners.laptop.max_sessions must be positive",
  )
  refused(
    minimal_with("max_depth = 0"),
    "spawners.laptop.max_depth must be positive",
  )
  refused(
    minimal_with("max_within_s = -5"),
    "spawners.laptop.max_within_s must be positive",
  )
  refused(
    minimal_with("max_depth = \"1\""),
    "spawners.laptop.max_depth must be an integer",
  )
  refused(
    minimal_with("retain_s = 1.5"),
    "spawners.laptop.retain_s must be an integer",
  )
}

pub fn the_default_deadline_may_not_exceed_the_cap_test() {
  let assert Ok([equal]) =
    spawners.parse(minimal_with(
      "max_within_s = 600\ndefault_within_s = 600\nretain_s = 600",
    ))
  assert equal.default_within_s == 600
  refused(
    minimal_with("max_within_s = 600\ndefault_within_s = 601\nretain_s = 600"),
    "spawners.laptop.default_within_s (601) is above max_within_s (600)",
  )

  // The default of half an hour is not written in the file, and the refusal
  // still names it, so the owner knows which value to change.
  refused(
    minimal_with("max_within_s = 600\nretain_s = 600"),
    "spawners.laptop.default_within_s (1800) is above max_within_s (600)",
  )
}

pub fn retention_may_not_be_shorter_than_the_longest_child_test() {
  refused(
    minimal_with("max_within_s = 7200\ndefault_within_s = 60\nretain_s = 7199"),
    "spawners.laptop.retain_s (7199) is below max_within_s (7200)",
  )

  // The default retention of a week is below a cap of eight days.
  refused(
    minimal_with("max_within_s = 691200"),
    "spawners.laptop.retain_s (604800) is below max_within_s (691200)",
  )
}

pub fn a_malformed_table_is_refused_with_the_key_it_names_test() {
  refused(
    with("[spawners.Laptop]\nnode = \"laptop@100.64.0.5\"\n"),
    "spawners.Laptop is not a spawner name",
  )
  refused(
    with(
      "[spawners.laptop]\ndirectory = \"/srv\"\nprofile = \"cheap-review\"\n",
    ),
    "spawners.laptop.node is required",
  )
  refused(
    with(
      "[spawners.laptop]\nnode = 1\ndirectory = \"/srv\"\nprofile = \"cheap-review\"\n",
    ),
    "spawners.laptop.node must be a string",
  )
  refused(
    minimal_with("host = \"x\""),
    "unknown key `host` in [spawners.laptop] (allowed: node, executor, pool, directory, workspace, profile, tools, max_depth, max_sessions, max_within_s, default_within_s, retain_s, idle_close_s, token_budget_per_day, child_token_budget, max_per_day, transcript)",
  )
  refused(
    with("[spawners]\nlaptop = \"laptop@100.64.0.5\"\n"),
    "spawners.laptop must be a table",
  )
  refused("spawners = \"laptop\"\n", "spawners must be a table")
  refused(
    with(
      "[spawners."
      <> string.repeat("a", 33)
      <> "]\nnode = \"laptop@100.64.0.5\"\n",
    ),
    "is not a spawner name",
  )
}

pub fn the_catalogue_parser_refuses_what_the_spawner_parser_refuses_test() {
  // The catalogue validates the table before it looks for any model, so a typo
  // is refused by every reader of the file and not only at startup.
  let text = minimal_with("max_sessions = 17")
  let assert Error(reason) = catalog.parse(text)
  assert string.contains(reason, "spawners.laptop.max_sessions 17 is above 16")

  // A valid table passes the top-level check: the next complaint is the
  // missing models, not an unknown `spawners` key.
  let assert Error(without_models) = catalog.parse(with(minimal))
  assert without_models == "the catalogue needs a [models.<name>] table"
}
