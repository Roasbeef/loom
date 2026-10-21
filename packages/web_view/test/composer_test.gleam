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
