//// The new-session composer's rules (`web_view/composer`).
////
//// These tests pin the page's half of "the page only offers": every choice a
//// message carries is checked against the lists the page was drawn from, so a
//// target, a profile or a model the page did not draw changes nothing; the
//// browser's text (a name, a path, a workspace, a search) is bounded and judged
//// before it can become a place; one creation is out at a time; and the default
//// target, the recent places and the summary sentence are written from what the
//// page holds.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import web_view/composer.{type Offers, Offers}
import web_view/creations
import web_view/listing
import web_view/placements
import web_view/sessions.{type Entry, Entry, Live}

fn offers() -> Offers {
  Offers(
    machine: "laptop",
    folders: ["/src/loom", "/src/weft"],
    cards: placements.listed(["exec", "gpu"], ["linux"]),
    profiles: ["fast"],
    models: ["glm"],
    agent: composer.Here,
    here: "laptop",
    agents: [
      composer.Candidate(
        composer.Here,
        "laptop",
        composer.Choosable("The daemon serving this page"),
      ),
    ],
    typing: composer.MayType,
  )
}

fn reported(offers: Offers, workspaces: List(String)) -> Offers {
  Offers(
    ..offers,
    cards: placements.after(
      placements.Reported(
        placements.Placements(
          executors: [
            placements.Executor(
              "exec",
              Some(placements.Report(
                state: placements.Ready,
                platform: None,
                enforcement: None,
                toolchains: [],
                free_scopes: None,
                workspaces:,
                contradiction: None,
              )),
            ),
          ],
          pools: [],
        ),
      ),
    ),
  )
}

fn update(
  state: composer.State,
  message: composer.Msg,
  offers: Offers,
) -> #(composer.State, composer.Intent) {
  composer.update(state, message, offers, [])
}

fn entry(id: String, workspace: String, created_at: Int) -> Entry {
  Entry(
    id:,
    name: "session " <> id,
    workspace:,
    created_at:,
    residency: Live,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

// Opening a chip shows its list and closes any other. Opening the Code list owes a
// read of the placements, so what it says of each executor is current, and a
// second press closes it again.
pub fn a_chip_opens_its_list_and_the_code_list_reads_the_placements_test() {
  let #(state, intent) =
    update(composer.new(), composer.Toggled(composer.CodeChip), offers())
  assert state.open == composer.Showing(composer.CodeChip)
  assert intent == composer.ReadPlacements

  let #(state, intent) =
    update(state, composer.Toggled(composer.ModelChip), offers())
  assert state.open == composer.Showing(composer.ModelChip)
  assert intent == composer.Stay

  let #(state, _) =
    update(state, composer.Toggled(composer.ModelChip), offers())
  assert state.open == composer.Shut
}

// A target the page drew is chosen and closes the list. A folder, an executor, a
// pool or a workspace the page did not draw is refused: the state is as it was.
pub fn a_target_the_page_did_not_draw_changes_nothing_test() {
  let opened =
    update(composer.new(), composer.Toggled(composer.CodeChip), offers()).0

  let #(chosen, _) =
    update(opened, composer.ChoseTarget(composer.Folder("/src/weft")), offers())
  assert chosen.target == Some(composer.Folder("/src/weft"))
  assert chosen.open == composer.Shut

  let forged = [
    composer.Folder("/etc"),
    composer.OnExecutor("elsewhere", None),
    composer.InPool("nowhere", None),
    composer.OnExecutor("exec", Some("a/b")),
  ]
  list.each(forged, fn(target) {
    let #(after, intent) =
      update(opened, composer.ChoseTarget(target), offers())
    assert after == opened
    assert intent == composer.Stay
  })
}

// Where the daemon listed an executor's workspaces only those are offered, and
// where it listed none a name that could be typed is.
pub fn an_executors_workspaces_are_offered_as_it_reported_them_test() {
  let known = reported(offers(), ["repo"])
  assert composer.offered(known, composer.OnExecutor("exec", Some("repo")))
  assert !composer.offered(known, composer.OnExecutor("exec", Some("other")))
  assert !composer.offered(known, composer.OnExecutor("exec", None))

  let unknown = offers()
  assert composer.offered(unknown, composer.OnExecutor("exec", None))
  assert composer.offered(unknown, composer.OnExecutor("exec", Some("any")))
  assert !composer.offered(
    unknown,
    composer.OnExecutor("exec", Some("../escape")),
  )
}

// A profile or a model is chosen only if the daemon listed it. The Model list
// stays open so both can be chosen, and the default is always offered.
pub fn a_profile_or_model_the_daemon_did_not_list_asks_nothing_test() {
  let state = composer.new()

  let #(state, _) = update(state, composer.ChoseProfile(Some("fast")), offers())
  assert state.roles.profile == Some("fast")

  let #(after, _) =
    update(state, composer.ChoseProfile(Some("secret")), offers())
  assert after.roles.profile == Some("fast")

  let #(state, _) = update(state, composer.ChoseModel(Some("glm")), offers())
  assert state.roles == creations.Roles(Some("fast"), Some("glm"))

  let #(after, _) = update(state, composer.ChoseModel(Some("other")), offers())
  assert after.roles == state.roles

  let #(state, _) = update(state, composer.ChoseModel(None), offers())
  assert state.roles.model == None
}

// Search text applies only while the Code list is open, drops control characters
// and is cut to its bound on a character boundary.
pub fn the_search_text_is_bounded_and_clean_test() {
  let shut = update(composer.new(), composer.Searched("loom"), offers()).0
  assert shut.search == ""

  let open =
    update(composer.new(), composer.Toggled(composer.CodeChip), offers()).0
  let #(typed, _) = update(open, composer.Searched("lo\u{0}o\nm"), offers())
  assert typed.search == "loom"

  let long = string.repeat("é", 100)
  let #(cut, _) = update(open, composer.Searched(long), offers())
  assert string.byte_size(cut.search) <= composer.search_limit
  assert string.byte_size(cut.search) == composer.search_limit
}

// A start asks only when a target is in force, nothing is out and the form has what
// the target needs. One creation is out at a time.
pub fn a_start_asks_once_for_the_place_the_form_describes_test() {
  let chosen =
    update(
      composer.new(),
      composer.ChoseTarget(composer.Folder("/src/loom")),
      offers(),
    ).0

  let #(out, intent) =
    update(chosen, composer.Started("review", composer.Nothing), offers())
  assert intent
    == composer.Create(
      creations.Drawn("/src/loom"),
      "review",
      "review",
      creations.default_roles,
    )
  assert out.sending == composer.Out

  // A second press while one is out asks nothing.
  let #(again, intent) =
    update(out, composer.Started("again", composer.Nothing), offers())
  assert intent == composer.Stay
  assert again == out

  // The daemon's refusal puts the words on the form and frees the button.
  let refused = composer.refused(out, "That folder is not available.")
  assert refused.sending == composer.Ready
  assert refused.refusal == Some("That folder is not available.")
}

// Without a target, with nothing drawn, a start asks nothing.
pub fn a_start_with_no_place_asks_nothing_test() {
  let empty = Offers(..offers(), folders: [])
  let #(state, intent) =
    update(composer.new(), composer.Started("x", composer.Nothing), empty)
  assert intent == composer.Stay
  assert state == composer.new()
}

// A typed folder asks for a path, judged before it is sent; an executor that
// reported no workspaces asks for a name, held to the registered-name rule; a
// stale choice of roles is refused at the start as well.
pub fn typed_text_is_judged_before_it_becomes_a_place_test() {
  assert composer.place(composer.TypedFolder, composer.Path(" ~/code/app "))
    == Ok(creations.Typed("~/code/app"))
  assert composer.place(composer.TypedFolder, composer.Path("a\nb"))
    |> result_is_error
  assert composer.place(composer.TypedFolder, composer.Nothing)
    |> result_is_error

  assert composer.place(
      composer.OnExecutor("exec", None),
      composer.Workspace("app"),
    )
    == Ok(creations.Registered("exec", "app"))
  assert composer.place(
      composer.OnExecutor("exec", None),
      composer.Workspace("/etc/app"),
    )
    |> result_is_error
  assert composer.place(
      composer.InPool("linux", None),
      composer.Workspace(" app "),
    )
    == Ok(creations.Pooled("linux", "app"))
  assert composer.place(composer.InPool("linux", Some("app")), composer.Nothing)
    == Ok(creations.Pooled("linux", "app"))
}

fn result_is_error(outcome: Result(a, b)) -> Bool {
  case outcome {
    Ok(_) -> False
    Error(_) -> True
  }
}

// The words of a refused form are fixed here, and a refused path leaves the state
// ready with the words to show.
pub fn a_form_missing_its_field_says_what_it_needs_test() {
  let typed =
    update(composer.new(), composer.ChoseTarget(composer.TypedFolder), offers()).0
  let #(state, intent) =
    update(typed, composer.Started("", composer.Nothing), offers())
  assert intent == composer.Stay
  assert state.sending == composer.Ready
  assert state.refusal == Some("Type the folder's path, or choose another.")
}

// With nothing chosen the page falls back to the newest place a session worked in,
// then to the first folder it drew. A choice the page no longer offers falls back
// the same way.
pub fn the_default_target_is_the_newest_place_test() {
  let recent = composer.recents([entry("B", "/src/weft", 9)], "laptop")
  assert composer.chosen(composer.new(), offers(), recent)
    == Some(composer.Folder("/src/weft"))
  assert composer.chosen(composer.new(), offers(), [])
    == Some(composer.Folder("/src/loom"))

  let stale =
    composer.State(..composer.new(), target: Some(composer.Folder("/gone")))
  assert composer.chosen(stale, offers(), [])
    == Some(composer.Folder("/src/loom"))
  assert composer.chosen(composer.new(), Offers(..offers(), folders: []), [])
    == None
}

// The places sessions worked in are distinct, newest first and at most three, each
// with the names of the sessions that used it, and local folders come from the
// sessions that run on the daemon's own host.
pub fn the_recent_places_are_distinct_newest_first_and_bounded_test() {
  let rows = [
    entry("A", "/w/one", 9),
    entry("B", "/w/two", 8),
    entry("C", "/w/one", 7),
    entry("D", "/w/three", 6),
    entry("E", "/w/four", 5),
  ]
  let recent = composer.recents(rows, "laptop")

  assert list.map(recent, fn(each) { each.target })
    == [
      composer.Folder("/w/one"),
      composer.Folder("/w/two"),
      composer.Folder("/w/three"),
    ]
  let assert [first, ..] = recent
  assert first.names == ["session A", "session C"]
  assert first.place.agent == "laptop"
  assert first.place.code == listing.Folder("/w/one")

  let remote = Entry(..entry("R", "repo", 10), executor: Some("exec"))
  let assert [newest, ..] = composer.recents([remote, ..rows], "laptop")
  assert newest.target == composer.OnExecutor("exec", Some("repo"))
}

// The folders offered are the daemon's own sessions' directories, newest first,
// then the remembered folders no session shows, with none twice and none from an
// executor.
pub fn the_folders_offered_are_local_and_distinct_test() {
  let rows = [
    entry("A", "/w/one", 9),
    Entry(..entry("R", "repo", 8), executor: Some("exec")),
    entry("B", "/w/one", 7),
  ]
  let remembered = [
    creations.Recent(1, "/w/two"),
    creations.Recent(2, "/w/one"),
  ]

  assert composer.folders_offered(rows, remembered) == ["/w/one", "/w/two"]
}

// The sentence says where the agent runs and where commands run, with the names it
// is about marked, for each kind of target.
pub fn the_sentence_says_where_the_agent_and_its_commands_run_test() {
  assert composer.sentence("laptop", Some(composer.Folder("/a/b/c")))
    == [
      composer.Plain("The agent runs on "),
      composer.Named("laptop"),
      composer.Plain(". "),
      composer.Plain("Commands run on "),
      composer.Named("laptop"),
      composer.Plain(", in "),
      composer.Named("…/b/c"),
      composer.Plain("."),
    ]

  let remote =
    composer.sentence("laptop", Some(composer.OnExecutor("exec", Some("repo"))))
  assert list.contains(remote, composer.Named("exec"))
  assert list.contains(remote, composer.Named("repo"))

  let none = composer.sentence("laptop", None)
  assert list.contains(none, composer.Plain(". Choose where the code is."))
}

// The chips' words.
pub fn the_chip_words_say_what_is_chosen_test() {
  assert composer.target_words(composer.OnExecutor("exec", Some("repo")))
    == "exec · repo"
  assert composer.target_words(composer.InPool("linux", Some("repo")))
    == "linux pool · repo"
  assert composer.target_words(composer.TypedFolder) == "a folder you type"
  assert composer.role_words(creations.default_roles) == "default"
  assert composer.role_words(creations.Roles(None, Some("glm")))
    == "default · glm"
  assert composer.hint(["a", "b", "c", "d"]) == "a, 3 more"
  assert composer.hint(["a", "b"]) == "a, b"
}

// A session is named by the first line of its first message that has any text:
// trimmed, made safe for one line and cut to a bound on a character boundary. A
// message with no text gives no name, so the daemon's default applies.
pub fn the_name_is_the_first_line_of_the_message_test() {
  assert composer.session_name("fix the retry test") == "fix the retry test"
  assert composer.session_name("\n   \n  fix the retry test  \nthen the docs")
    == "fix the retry test"
  assert composer.session_name("") == ""
  assert composer.session_name("  \n \t ") == ""

  // A control or direction character never reaches the name the daemon judges.
  let cleaned = composer.session_name("a\u{0}b\u{202e}c")
  assert !string.contains(cleaned, "\u{0}")
  assert !string.contains(cleaned, "\u{202e}")

  // The cap is in characters, never in the middle of one.
  let long = composer.session_name(string.repeat("é", 300))
  assert string.length(long) == composer.name_limit
  assert long == string.repeat("é", composer.name_limit)
}

// A start carries the message and the name the message gives, and trims the
// message's ends; an empty message still starts a session, with none to send.
pub fn a_start_carries_the_message_and_its_name_test() {
  let chosen =
    update(
      composer.new(),
      composer.ChoseTarget(composer.Folder("/src/loom")),
      offers(),
    ).0

  let #(_, intent) =
    update(
      chosen,
      composer.Started(
        "\n  fix the retry test\nthen the docs \n",
        composer.Nothing,
      ),
      offers(),
    )
  assert intent
    == composer.Create(
      creations.Drawn("/src/loom"),
      "fix the retry test",
      "fix the retry test\nthen the docs",
      creations.default_roles,
    )

  let #(_, intent) =
    update(chosen, composer.Started("  ", composer.Nothing), offers())
  assert intent
    == composer.Create(
      creations.Drawn("/src/loom"),
      "",
      "",
      creations.default_roles,
    )
}

// A message past the bound asks nothing and says so in words, and the session is
// not created, so no text is lost to a bound the person could not see.
pub fn a_message_past_the_bound_is_refused_on_the_form_test() {
  let chosen =
    update(
      composer.new(),
      composer.ChoseTarget(composer.Folder("/src/loom")),
      offers(),
    ).0
  let long = string.repeat("a", composer.prompt_limit + 1)

  let #(state, intent) =
    update(chosen, composer.Started(long, composer.Nothing), offers())
  assert intent == composer.Stay
  assert state.sending == composer.Ready
  let assert Some(words) = state.refusal
  assert string.contains(words, "too long")

  let exact = string.repeat("a", composer.prompt_limit)
  let #(_, intent) =
    update(chosen, composer.Started(exact, composer.Nothing), offers())
  assert intent != composer.Stay
}

// A session kept without its message offers the person its page, once; nothing
// departs before they press, and a page with no such session offers nothing.
pub fn an_unsent_session_is_opened_only_on_a_press_test() {
  let state = composer.unsent(composer.new(), "/ui/sessions/S?ticket=T")
  assert state.sending == composer.Ready
  let #(_, intent) = update(state, composer.OpenedUnsent, offers())
  assert intent == composer.Depart("/ui/sessions/S?ticket=T")

  let #(_, intent) = update(composer.new(), composer.OpenedUnsent, offers())
  assert intent == composer.Stay
}

// A profile or model the daemon no longer lists, after the person chose it, stops
// the start with words, and nothing is created.
pub fn a_role_no_longer_offered_says_so_on_the_form_test() {
  let chosen =
    update(
      composer.new(),
      composer.ChoseTarget(composer.Folder("/src/loom")),
      offers(),
    ).0
  let chosen = update(chosen, composer.ChoseProfile(Some("fast")), offers()).0

  let gone = Offers(..offers(), profiles: [])
  let #(state, intent) =
    update(chosen, composer.Started("go", composer.Nothing), gone)
  assert intent == composer.Stay
  assert state.sending == composer.Ready
  let assert Some(words) = state.refusal
  assert string.contains(words, "no longer offered")
}

// The offers of a daemon that relays for a box, which answered, and a second
// orchestrator, which did not.
fn with_orchestrators(offers: Offers) -> Offers {
  Offers(..offers, agents: [
    composer.Candidate(
      composer.Here,
      "laptop",
      composer.Choosable("The daemon serving this page"),
    ),
    composer.Candidate(
      composer.Orchestrator("box"),
      "box",
      composer.Choosable("1 working"),
    ),
    composer.Candidate(composer.Orchestrator("slow"), "slow", composer.Checking),
    composer.Candidate(
      composer.Orchestrator("gone"),
      "gone",
      composer.Unavailable("the orchestrator is not reachable"),
    ),
  ])
}

// The Agent chip's rows are the only machines a message can choose, and only a
// row that can be chosen: one that is still being checked, one that did not
// answer and one the page never drew change nothing.
pub fn only_a_drawn_machine_that_answered_can_be_chosen_test() {
  let held = with_orchestrators(offers())

  let #(state, _) =
    update(
      composer.new(),
      composer.ChoseAgent(composer.Orchestrator("box")),
      held,
    )
  assert state.agent == composer.Orchestrator("box")
  assert state.open == composer.Shut

  list.each(["slow", "gone", "nowhere"], fn(name) {
    let #(state, _) =
      update(
        composer.new(),
        composer.ChoseAgent(composer.Orchestrator(name)),
        held,
      )
    assert state.agent == composer.Here
  })

  // This daemon is always a row, and choosing it returns to it.
  let #(back, _) = update(state, composer.ChoseAgent(composer.Here), held)
  assert back.agent == composer.Here
}

// Opening the Agent chip owes a read of every orchestrator, and opening the Code
// chip owes a read of the one that is the agent, or of this daemon's placements.
pub fn the_chips_owe_the_reads_for_the_agent_in_force_test() {
  let held = with_orchestrators(offers())

  let #(_, intent) =
    update(composer.new(), composer.Toggled(composer.AgentChip), held)
  assert intent == composer.ReadAgents

  let on_box =
    update(
      composer.new(),
      composer.ChoseAgent(composer.Orchestrator("box")),
      held,
    ).0
  let #(_, intent) = update(on_box, composer.Toggled(composer.CodeChip), held)
  assert intent == composer.ReadOn("box")

  let #(_, intent) =
    update(composer.new(), composer.Toggled(composer.CodeChip), held)
  assert intent == composer.ReadPlacements
}

// The box's offers, as the page holds them once the box is the agent: one folder,
// one executor workspace, one profile, and no typed folder.
fn box_offers() -> Offers {
  Offers(
    ..with_orchestrators(offers()),
    machine: "box",
    folders: ["/srv/app"],
    cards: placements.listed(["exec"], []),
    profiles: ["default"],
    models: [],
    agent: composer.Orchestrator("box"),
    typing: composer.MayNotType,
  )
}

// A start on a box is a create on that box, for a place it offered, with the
// message trimmed and no name: the box names its own sessions.
pub fn a_start_on_a_box_is_a_create_there_test() {
  let state =
    composer.State(
      ..composer.new(),
      agent: composer.Orchestrator("box"),
      target: Some(composer.Folder("/srv/app")),
    )
  let #(state, intent) =
    update(
      state,
      composer.Started("  fix it  ", composer.Nothing),
      box_offers(),
    )

  assert intent
    == composer.CreateOn(
      "box",
      creations.Drawn("/srv/app"),
      "fix it",
      creations.default_roles,
    )
  assert state.sending == composer.Out
}

// A box is never given a path the page typed, and a start whose agent stopped
// answering asks nothing and says so.
pub fn a_box_is_never_given_a_typed_path_test() {
  let state =
    composer.State(
      ..composer.new(),
      agent: composer.Orchestrator("box"),
      target: Some(composer.TypedFolder),
    )

  assert !composer.offered(box_offers(), composer.TypedFolder)

  // The forged target is not in force, so the default (the box's folder) is.
  assert composer.chosen(state, box_offers(), [])
    == Some(composer.Folder("/srv/app"))

  let gone =
    Offers(..box_offers(), agents: [
      composer.Candidate(
        composer.Orchestrator("box"),
        "box",
        composer.Unavailable("the orchestrator is not reachable"),
      ),
    ])
  let #(state, intent) =
    update(state, composer.Started("go", composer.Nothing), gone)
  assert intent == composer.Stay
  let assert Some(words) = state.refusal
  assert string.contains(words, "not answering")
}

// A switch keeps the workspace choice the new machine offers and clears a folder,
// since the same path on another machine is another folder, and a profile or model
// the new machine does not list goes back to the default.
pub fn a_switch_keeps_what_the_new_machine_offers_test() {
  let on_exec =
    composer.State(
      ..composer.new(),
      target: Some(composer.OnExecutor("exec", Some("repo"))),
      roles: creations.Roles(Some("fast"), Some("glm")),
    )
  let held =
    Offers(
      ..box_offers(),
      cards: reported(box_offers(), ["repo"]).cards,
      profiles: ["fast"],
      models: [],
    )
  let kept = composer.kept(on_exec, held)
  assert kept.target == Some(composer.OnExecutor("exec", Some("repo")))
  assert kept.roles == creations.Roles(Some("fast"), None)

  let on_folder =
    composer.State(..composer.new(), target: Some(composer.Folder("/srv/app")))
  assert composer.kept(on_folder, held).target == None

  let missing =
    composer.State(
      ..composer.new(),
      target: Some(composer.OnExecutor("other", Some("repo"))),
    )
  assert composer.kept(missing, held).target == None
}

// The sentence for a box says that this page relays.
pub fn the_sentence_for_a_box_says_the_page_relays_test() {
  let pieces =
    composer.sentence_for(
      composer.Orchestrator("box"),
      "box",
      Some(composer.Folder("/srv/app")),
    )
  assert list.last(pieces)
    == Ok(composer.Plain(" This page relays it: approvals come here."))
  assert composer.sentence_for(composer.Here, "laptop", None)
    == composer.sentence("laptop", None)
}

// A box has no default profile, so a switch to one names the first profile it
// lists, which is what its create sends, and a switch back to this daemon drops a
// profile this daemon does not list.
pub fn a_switch_to_a_box_names_its_first_profile_test() {
  let fresh = composer.new()

  assert composer.kept(fresh, box_offers()).roles.profile == Some("default")

  let chosen =
    composer.State(..fresh, roles: creations.Roles(Some("fast"), None))
  let two = Offers(..box_offers(), profiles: ["default", "fast"])
  assert composer.kept(chosen, two).roles.profile == Some("fast")

  let none = Offers(..box_offers(), profiles: [])
  assert composer.kept(fresh, none).roles.profile == None

  let back = composer.kept(composer.kept(fresh, box_offers()), offers())
  assert back.roles.profile == None
}

// An empty first message is allowed for a box exactly as it is for this daemon: the
// start is a create that sends no message, and the box names the session itself.
pub fn an_empty_message_starts_a_box_session_without_a_message_test() {
  let state =
    composer.State(
      ..composer.new(),
      agent: composer.Orchestrator("box"),
      target: Some(composer.Folder("/srv/app")),
    )
  let #(_, intent) =
    update(state, composer.Started("   ", composer.Nothing), box_offers())

  assert intent
    == composer.CreateOn(
      "box",
      creations.Drawn("/srv/app"),
      "",
      creations.default_roles,
    )

  // The local composer does the same: `Create` with an empty prompt.
  let here = composer.State(..state, agent: composer.Here)
  let #(_, local) =
    update(here, composer.Started("   ", composer.Nothing), box_offers())
  let assert composer.Create(prompt: "", ..) = local
}
