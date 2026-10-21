//// The `[spawners.<name>]` tables are strict, total and absent by default
//// (protocol-change/084). A spawner is a pinned distribution peer under a name
//// with exactly one placement, a profile, a tool ceiling and four limits, so a
//// table that says anything else is refused wherever the file is read, and the
//// refusal names the key.

import broker/policy
import client/approval_ceiling
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
        approval_ceiling: None,
        transcript: spawners.Visible,
        spawn_on: [],
        top_level: None,
      ),
    ])
}

pub fn omitted_keys_take_the_documented_defaults_test() {
  let assert Ok([spawner]) = spawners.parse(with(minimal))
  assert spawner.tools == spawners.default_tools(1)
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
  let tools = spawners.default_tools(1)
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

pub fn a_deeper_spawner_holds_the_spawn_tool_by_default_test() {
  // A depth above one lets a child start children of its own, so the default
  // ceiling holds the tool that does it, and still none that reaches beyond the
  // delegate session.
  let tools = spawners.default_tools(2)
  assert list.contains(tools, "agent_spawn")
  assert !list.contains(tools, "remember")
  assert !list.contains(tools, "peer_send")
  assert list.filter(tools, fn(name) { name != "agent_spawn" })
    == spawners.default_tools(1)

  let assert Ok([deep]) = spawners.parse(minimal_with("max_depth = 3"))
  assert list.contains(deep.tools, "agent_spawn")

  // An explicit ceiling is the owner's own and is kept as written.
  let assert Ok([written]) =
    spawners.parse(minimal_with("max_depth = 2\ntools = [\"bash\"]"))
  assert written.tools == ["bash"]
}

pub fn spawn_on_lists_where_a_child_may_spawn_test() {
  let assert Ok([plain]) = spawners.parse(with(minimal))
  assert plain.spawn_on == []

  let assert Ok([deep]) =
    spawners.parse(minimal_with("max_depth = 2\nspawn_on = [\"third\"]"))
  assert deep.spawn_on == ["third"]

  // A list under a depth of one could never be used, since no child there may
  // spawn, and it is refused rather than ignored.
  refused(
    minimal_with("spawn_on = [\"third\"]"),
    "spawners.laptop.spawn_on needs max_depth above 1",
  )
  refused(
    minimal_with("max_depth = 2\nspawn_on = [\"third\", \"third\"]"),
    "spawners.laptop.spawn_on lists third more than once",
  )
  refused(
    minimal_with("max_depth = 2\nspawn_on = [\"Third@x\"]"),
    "spawners.laptop.spawn_on Third@x is not an orchestrator name",
  )
  refused(
    minimal_with("max_depth = 2\nspawn_on = \"third\""),
    "spawners.laptop.spawn_on must be an array of orchestrator names",
  )
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
    "unknown key `host` in [spawners.laptop] (allowed: node, executor, pool, directory, workspace, profile, tools, max_depth, max_sessions, max_within_s, default_within_s, retain_s, idle_close_s, token_budget_per_day, child_token_budget, max_per_day, approval_ceiling, transcript, spawn_on, top_level)",
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

// --- the approval ceiling (protocol-change/089) --------------------------------

fn ceiling_of(table: String) -> approval_ceiling.Ceiling {
  let assert Ok([spawner]) =
    spawners.parse(with(
      minimal <> "[spawners.laptop.approval_ceiling]\n" <> table,
    ))
    as "the ceiling table is accepted"
  let assert Some(ceiling) = spawner.approval_ceiling
    as "the spawner carries the ceiling it was given"
  ceiling
}

pub fn a_table_with_no_ceiling_has_none_test() {
  let assert Ok([spawner]) = spawners.parse(with(minimal))
  assert spawner.approval_ceiling == None
}

pub fn an_empty_ceiling_table_is_a_ceiling_that_admits_nothing_test() {
  let ceiling = ceiling_of("")
  assert ceiling == approval_ceiling.nothing()
  assert !approval_ceiling.admits(ceiling, policy.GrantEnv("HOME"))
}

pub fn a_ceiling_may_state_every_key_test() {
  let ceiling =
    ceiling_of(
      "writable_roots = [\"/srv/work\", \"/var/tmp/\"]
readable_roots = [\"/usr/share\"]
network = [\"registry.npmjs.org:443\"]
env = [\"NPM_TOKEN\"]
scratch = [\"tmpfs\", \"/srv/scratch\"]
limits = { wall_s = 600, mem_bytes = 1073741824 }
",
    )
  assert ceiling
    == approval_ceiling.Ceiling(
      writable_roots: ["/srv/work", "/var/tmp"],
      readable_roots: ["/usr/share"],
      network: approval_ceiling.Hosts(["registry.npmjs.org:443"]),
      env: ["NPM_TOKEN"],
      limits: [#(policy.MemBytes, 1_073_741_824), #(policy.WallSeconds, 600)],
      scratch: [
        approval_ceiling.TmpfsScratch,
        approval_ceiling.ScratchUnder("/srv/scratch"),
      ],
    )
}

pub fn the_limits_may_be_their_own_table_test() {
  let assert Ok([spawner]) =
    spawners.parse(with(
      minimal <> "[spawners.laptop.approval_ceiling.limits]\nwall_s = 60\n",
    ))
  let assert Some(ceiling) = spawner.approval_ceiling
  assert ceiling.limits == [#(policy.WallSeconds, 60)]
}

pub fn a_malformed_ceiling_is_refused_with_the_key_it_names_test() {
  let place = "spawners.laptop.approval_ceiling"
  let bad = fn(line: String, fragment: String) {
    refused(with(minimal <> "[" <> place <> "]\n" <> line <> "\n"), fragment)
  }
  bad("host = \"x\"", "unknown key `host` in " <> place)
  bad("writable_roots = \"/srv\"", place <> ".writable_roots must be an array")
  bad(
    "writable_roots = [\"srv\"]",
    place <> ".writable_roots must be an absolute",
  )
  bad("writable_roots = [\"/srv/../etc\"]", "must not contain a .. segment")
  bad("readable_roots = [\"/srv//x\"]", "must not contain a . segment")
  bad("network = \"all\"", place <> ".network must be \"any\" or an array")
  bad("network = [\"example.com\"]", "entry example.com is not host:port")
  bad("network = [\"example.com:0\"]", "is not host:port")
  bad("env = [\"\"]", place <> ".env must not hold an empty name")
  bad("limits = { speed = 3 }", "unknown key `speed` in " <> place <> ".limits")
  bad("limits = { wall_s = 0 }", place <> ".limits.wall_s must be positive")
  bad(
    "limits = { wall_s = \"1\" }",
    place <> ".limits.wall_s must be an integer",
  )
  bad("limits = 3", place <> ".limits must be a table")
  bad("scratch = [\"nowhere\"]", "scratch entry must be an absolute path")
  refused(
    minimal_with("approval_ceiling = \"yes\""),
    "spawners.laptop.approval_ceiling must be a table",
  )
}

pub fn a_ceiling_admits_a_grant_inside_it_and_refuses_one_outside_it_test() {
  let ceiling =
    ceiling_of(
      "writable_roots = [\"/srv/work\"]
readable_roots = [\"/usr/share\"]
network = [\"registry.npmjs.org:443\"]
env = [\"NPM_TOKEN\"]
scratch = [\"tmpfs\"]
limits = { wall_s = 600 }
",
    )
  let admits = approval_ceiling.admits(ceiling, _)

  // A root is admitted at or under a listed path, on a segment boundary.
  assert admits(policy.GrantWritableRoot("/srv/work"))
  assert admits(policy.GrantWritableRoot("/srv/work/a/b"))
  assert !admits(policy.GrantWritableRoot("/srv/workshop"))
  assert !admits(policy.GrantWritableRoot("/srv/work/../etc"))
  assert !admits(policy.GrantWritableRoot("/etc"))

  // Reading is implied by writing, and not the other way round.
  assert admits(policy.GrantReadableRoot("/usr/share/doc"))
  assert admits(policy.GrantReadableRoot("/srv/work/x"))
  assert !admits(policy.GrantReadableRoot("/usr"))

  // A proxy grant is admitted when every host it lists is listed; full network
  // and an unlisted host are not.
  assert admits(
    policy.GrantNetwork(policy.NetworkProxy(
      allow: ["registry.npmjs.org:443"],
      proxy: "p",
    )),
  )
  assert !admits(
    policy.GrantNetwork(policy.NetworkProxy(
      allow: ["registry.npmjs.org:443", "evil.example:443"],
      proxy: "p",
    )),
  )
  assert !admits(policy.GrantNetwork(policy.NetworkFull))
  assert admits(policy.GrantNetwork(policy.NetworkOff))

  assert admits(policy.GrantEnv("NPM_TOKEN"))
  assert !admits(policy.GrantEnv("AWS_SECRET_ACCESS_KEY"))

  // A limit is admitted up to its maximum, never as unlimited, and only for a
  // field the ceiling names.
  assert admits(policy.GrantLimit(policy.WallSeconds, 600))
  assert !admits(policy.GrantLimit(policy.WallSeconds, 601))
  assert !admits(policy.GrantLimit(policy.WallSeconds, 0))
  assert !admits(policy.GrantLimit(policy.MemBytes, 1))

  assert admits(policy.GrantScratch(policy.ScratchTmpfs))
  assert !admits(policy.GrantScratch(policy.ScratchPath("/srv/scratch")))
}

pub fn any_network_admits_every_network_grant_test() {
  let ceiling = ceiling_of("network = \"any\"")
  assert approval_ceiling.admits(
    ceiling,
    policy.GrantNetwork(policy.NetworkFull),
  )
  assert approval_ceiling.admits(
    ceiling,
    policy.GrantNetwork(policy.NetworkProxy(allow: ["a:1"], proxy: "p")),
  )
}

pub fn admitted_keeps_the_grants_the_ceiling_admits_in_order_test() {
  let ceiling = ceiling_of("env = [\"A\", \"B\"]")
  let grants = [
    policy.GrantEnv("A"),
    policy.GrantEnv("C"),
    policy.GrantEnv("B"),
  ]
  assert approval_ceiling.admitted(ceiling, grants)
    == [policy.GrantEnv("A"), policy.GrantEnv("B")]
  assert !approval_ceiling.admits_all(ceiling, grants)
  assert approval_ceiling.admits_all(ceiling, [policy.GrantEnv("A")])
}

pub fn the_root_path_admits_every_absolute_path_test() {
  let ceiling = ceiling_of("writable_roots = [\"/\"]")
  assert approval_ceiling.admits(ceiling, policy.GrantWritableRoot("/etc/x"))
}

pub fn the_catalogue_parser_refuses_a_malformed_ceiling_too_test() {
  let assert Error(reason) =
    catalog.parse(with(
      minimal <> "[spawners.laptop.approval_ceiling]\nnetwork = \"all\"\n",
    ))
  assert string.contains(
    reason,
    "spawners.laptop.approval_ceiling.network must be",
  )
}

// --- top_level (protocol-change/094) -----------------------------------------

// The `minimal` table followed by a `top_level` table of the given lines.
fn top_level(lines: String) -> String {
  with(minimal <> "\n[spawners.laptop.top_level]\n" <> lines <> "\n")
}

pub fn a_spawner_has_no_top_level_table_by_default_test() {
  let assert Ok([spawner]) = spawners.parse(with(minimal))
  assert spawner.top_level == None
}

pub fn an_empty_top_level_table_offers_nothing_and_takes_the_defaults_test() {
  let assert Ok([spawner]) = spawners.parse(top_level(""))
  assert spawner.top_level
    == Some(spawners.TopLevel(
      executors: [],
      pools: [],
      folders: spawners.RecentFolders,
      profiles: None,
      max_sessions: 8,
      max_per_hour: 10,
      approval_ceiling: None,
    ))
}

pub fn a_top_level_table_may_state_every_key_test() {
  let text =
    top_level(
      "executors = [\"runner\"]
pools = [\"linux\"]
folders = \"none\"
profiles = [\"cheap-review\"]
max_sessions = 64
max_per_hour = 3

[spawners.laptop.top_level.approval_ceiling]
writable_roots = [\"/home/exedev\"]
network = \"any\"",
    )
  let assert Ok([spawner]) = spawners.parse(text)
  let assert Some(table) = spawner.top_level
  assert table.executors == ["runner"]
  assert table.pools == ["linux"]
  assert table.folders == spawners.NoFolders
  assert table.profiles == Some(["cheap-review"])
  assert table.max_sessions == 64
  assert table.max_per_hour == 3
  assert table.approval_ceiling
    == Some(
      approval_ceiling.Ceiling(
        ..approval_ceiling.nothing(),
        writable_roots: ["/home/exedev"],
        network: approval_ceiling.AnyNetwork,
      ),
    )
}

pub fn an_empty_ceiling_table_is_present_and_admits_nothing_test() {
  let text = top_level("[spawners.laptop.top_level.approval_ceiling]")
  let assert Ok([spawner]) = spawners.parse(text)
  let assert Some(table) = spawner.top_level
  assert table.approval_ceiling == Some(approval_ceiling.nothing())
}

pub fn a_top_level_table_refuses_what_it_does_not_understand_test() {
  refused(top_level("owner = true"), "unknown key `owner`")
  refused(top_level("list = \"owner\""), "unknown key `list`")
  refused(
    top_level("executors = [\"nowhere\"]"),
    "spawners.laptop.top_level.executors nowhere",
  )
  refused(
    top_level("executors = [\"runner\", \"runner\"]"),
    "lists runner more than once",
  )
  refused(top_level("executors = \"runner\""), "must be an array of names")
  refused(top_level("pools = [\"nowhere\"]"), "top_level.pools nowhere")
  refused(top_level("profiles = [\"nowhere\"]"), "top_level.profiles nowhere")
  refused(top_level("folders = \"typed\""), "must be \"none\" or \"recent\"")
  refused(top_level("folders = 1"), "folders must be a string")
  refused(top_level("max_sessions = 0"), "max_sessions must be positive")
  refused(top_level("max_sessions = 65"), "max_sessions 65 is above 64")
  refused(top_level("max_sessions = \"8\""), "max_sessions must be an integer")
  refused(top_level("max_per_hour = 0"), "max_per_hour must be positive")
  refused(
    top_level("[spawners.laptop.top_level.approval_ceiling]\nroots = []"),
    "unknown key `roots`",
  )
  refused(
    with(minimal <> "top_level = 1\n"),
    "spawners.laptop.top_level must be a table",
  )
}

pub fn the_top_level_table_is_checked_wherever_the_file_is_read_test() {
  let assert Error(reason) =
    catalog.parse(top_level("executors = [\"nowhere\"]"))
  assert string.contains(reason, "top_level.executors nowhere")
}
