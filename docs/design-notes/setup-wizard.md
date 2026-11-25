# A setup wizard and a way to find things

Status: **proposal, 2026-11-24.** It writes no code. The owner asked: "loom project init — I can't do it from ui/desktop app? we should work on intro usage there or rather like a setup wizard or w/e". The [mockup](setup-wizard/mockup.html) draws the wizard at 1440 and 375 pixels, in light and dark.

In this note, we separate what a new person has to do today (section 2, each row checked against the code) from what we propose (sections 3 to 5) and the order of the work (section 6). Desktop files are in the sibling repository `loom-desktop` at its `origin/main` (`efb5bc3`). They are cited as `App/Sources/...` with line numbers where it matters, and `make doc-check` does not verify those.

## 1. The problem

Project creation exists in both clients. The web view's "New project" button is in the "Projects" folder (`web_view/view/projects.gleam:200`), and loom-desktop has a New Project sheet (`App/Sources/NewProjectSheet.swift`). Both call `projects.propose` and then `projects.create`, as `loom project init` does (`tui/project_settings_cli.gleam:125`). The feature is not missing. Three things hide it:

- **The desktop sidebar draws Projects only when a project exists.** `App/Sources/RootView.swift:159` wraps the entry in `if !model.projectStates.isEmpty`. A person with no project has no entry. The sheet that makes the first project is behind that entry's empty state (the "No projects" view in `ProjectsView.swift`). The other doors are the command palette and a Mission Control card (`MissionViews.swift:724`), and neither is visible to someone who does not already know the name.
- **The web view's Projects folder reads as one more filter.** It is the last row of the inbox rail, after four attention groups (`web_view/inbox_rule.gleam:584`), drawn on every page that holds the projects capability (`web_view/home.gleam:8449`).
- **Nothing tells a new person the order of things.** The web first-session pane says only that no model is listed in the configuration file (`web_view/view/new_session.gleam:449`), which describes a file, and it is drawn only while the daemon lists no model and no session exists.

The fix is two parts: a way to find things (section 5), and one guided path through setup (section 3) whose state is derived from the daemon, so a person who did half of it by hand sees the other half.

## 2. What a new user does today

The zero-config rule is that a new person gets a working baseline with no config edits, and that settings are derived before they are asked for. The baseline exists for the model. With no `--config` and no `<state-dir>/loom.toml`, the daemon builds one catalogue entry named anthropic from the LOOM_* variables, with the key variable ANTHROPIC_API_KEY and the default model claude-opus-5 (`client/serve.gleam:2331`, and the default model at `client/serve.gleam:2297`). A missing key does not stop the daemon; the request fails in-band (`docs/configuration.md`, "`[models.<name>]`"). So the first failure a new person meets is a failed turn, not a setup screen. How the file is found is in `docs/configuration.md`, "How the file is found": `loomd` reads none without `--config`, and `loom` reads `<state-dir>/loom.toml` if it exists.

| # | Step | Where it lives today | Web | Desktop |
| --- | --- | --- | --- | --- |
| 1 | Model and provider key | ANTHROPIC_API_KEY in the daemon's environment, or a model table whose key-variable setting points at an environment variable. A key is never written in the file; the secrets table can fetch one by command. | Read only. The Model chip lists the file's keys, and a first-run note says what the page cannot see (`web_view/view/new_session.gleam:456`). | Read only. Session settings has a "Model profile" picker (`SessionSettingsSheet.swift:52`). |
| 2 | Model roles (`main`, `subagent`, `summarize`, `router`) | `[roles]` and `[profiles.<name>.roles]` in `loom.toml`. | None. | None. |
| 3 | A folder or workspace | The new-session form: a folder on the daemon's machine, or a `[workspaces.<name>]` name on an executor. | Yes. A picker walks the daemon's directories (`web_view/folder_browse.gleam`, protocol-change/132). | Yes. `FolderPickerView.swift`, used at `NewSessionSheet.swift:305`. |
| 4 | The worktree option | Per session, off unless chosen. There is no default key. The workspace table's mode key sets it for an executor workspace. | A checkbox (`web_view/view/new_session.gleam:919`). | A toggle (`NewSessionSheet.swift:431`) whose state is per sheet (`:63`). |
| 5 | A project | `loom project init`, which proposes `check` and `setup` and asks (`packages/tui/src/tui.gleam:2082`). | "New project": folder, proposal, confirmation (`web_view/project_create.gleam`). | The New Project sheet, in the same two steps. |
| 6 | A project's setup and check afterward | `loom project set <key> <value>`; five keys are per project (`docs/configuration.md`, "Per-project settings"). | Only at creation. No page edits them later. | At creation, and in a settings panel (`ProjectControls.swift:88`). |
| 7 | Publish with `gh auth` | `loom project set publish pull_request --publish-to <url>`, with `gh` logged in on the daemon's machine. The host looks for the gh executable on the search path (`client/project_publish.gleam:264`). | None. | The settings panel can write `publishTo` (`ProjectControls.swift:189`). Nothing checks the `gh` login. |
| 8 | A GitHub source and rules | `[[project.source]]` and `[[project.rule]]`, read once at start. | None. | None. |
| 9 | A Jev key | `[jev] api_key_env`, default `JEV_API_KEY`, resolved when the daemon starts. The table is in progress (`design-notes/project-jev-routing.md:100`) and is not yet in `docs/configuration.md`. | None. | None. |
| 10 | Executors and machines | `[executors.<name>]`, `[pools.<name>]`, `loom vm up`, `loom executor ...`. | The Admin page lists machines (`web_view/view/admin_machines.gleam`). | A Machines entry, drawn only with more than one daemon (`RootView.swift:164`), and "Connect a Daemon" (`AddDaemonSheet`). |
| 11 | Sharing and people | Invitations and claims; a session is private until made shareable. | Admin page: people, invitations, access roles (`web_view/view/sidebar.gleam:955`). | `PeopleSheet.swift`, and a Shareable toggle on a new session (`NewSessionSheet.swift:164`). |

Three things follow. Steps 2, 8 and 9 are file-only on both clients, and step 1 can be read but not set. Step 6 differs by client, so the same project is more editable on desktop than on the web. Step 7 has no check anywhere: a person turns publishing on, and the first sign of a missing `gh` login is a ticket that waits for a person with a reason.

The wizard assumes a running, configured daemon (the owner's ruling, 2026-11-24), so steps 1, 2 and 9's key handling are not wizard work. Whoever started the daemon has already set its model and key, and the wizard neither tests a model nor takes a key. What the clients can already read is thin: the control socket's `hello` carries the daemon's build version (`client/daemon/server.gleam:3091`), and the web page holds the model keys the file lists. Neither reports which model the `main` role uses. `models.list` (protocol-change/109, an open PR) is the read that would.

## 3. The wizard

A page in the web view, reached as "Get started" at the top of the rail, then the same in desktop. It opens by itself the first time, which means when the daemon has no session and no project and the client has not recorded a dismissal. Once every step is done or skipped, the rail entry hides. It is a list, not a modal sequence: each step has a state word, an action and a Skip, so a person can do step 3 before step 1.

It opens with a **status line** that has no actions: the daemon is ready, its version, and the model the `main` role uses once a read reports it (see section 2). Then five steps. Every state is derived from what exists, so a re-run shows what is done:

| Step | State comes from | Action |
| --- | --- | --- |
| 1. Default folder | The client's remembered folder, else the folders the daemon already lists. | The existing folder picker. |
| 2. Worktree default | The client's remembered choice, off if none. | Two choices that say what each does: work in the folder, or in a worktree of it. |
| 3. First project (optional) | `projects.list`; done when one holds the default folder. | The existing New project flow, embedded: proposed `check` and `setup` with the reason beside each, editable, then a dry run. |
| 4. GitHub publish (optional) | Whether `gh` is found and what its `auth status` returned, read by the daemon. | "Check", which shows the account and the repository's `origin`; on a yes, `projects.set_settings` with `--publish-to`. |
| 5. Extras (optional) | Whether the `summarize` role is set, and whether the `[jev]` table is present. | One small panel each, each skippable. |

**Dry run of the check.** `projects.create` already builds the template, runs `setup` with the network on, and runs `check` once, offline, on the clean base commit (`docs/configuration.md`, "The template"). So the wizard needs no new run. After Create it shows that build's outcome: building, passed, or failed with the last 4000 characters the board already keeps for a setup failure. Whether the board reports "building" as its own state, and not only a failure or a waiting check (`session_view/project_board.gleam:152`), is to be confirmed in slice 3. If it does not, the addition is a field on `projects.board`, not a new command.

**No keys.** The wizard never takes, stores or shows a credential. The Jev step reports whether the variable the table names is set, and that is all.

**A skipped step writes nothing.** The client remembers it, so the wizard stops offering it on open.

## 4. What the wizard writes, and where

| Setting | Written to | By |
| --- | --- | --- |
| Check, setup, publish, `max_workers`, protected paths | The project's ledger, no restart. | `projects.set_settings` (exists). |
| A project's existence | The project table. | `projects.create` (exists). |
| Default folder, worktree default, "dismissed", skipped steps | The client: `localStorage` on the web, read and written inside try/catch so the page works when it fails, and `UserDefaults` on desktop. Not the daemon, because they are one person's habits on one device. | The client. |
| The `summarize` role, the `[jev]` table | `loom.toml`. | A new owner-only command (below). |

Only the last row is new. The existing route for editing the file is protocol-change/092: a configuration edit is a proposal of kind `config`, the owner approves it in the proposals review, the loader checks the text when it is filed and again when it is approved, the write is atomic, and a watcher reopens sessions when they are idle. Only a model files such a proposal (`propose` with `target: "config"`), and the target is "the session's own configuration path".

**Proposed protocol change (would be 135; 134 is the session timeline's).** Two owner-only commands, gated as `projects.*` is (`client/daemon/ui_socket.gleam:3052`, `client/daemon/ui_socket.gleam:5235`):

- `setup.github` (read). Whether `gh` is found and what `gh auth status` returned, as a closed set of words. It spends nothing and returns no token.
- `setup.propose_config` (write, by proposal). The browser sends a choice from a closed list, `set_role{role, model}` or `enable_jev{}`, never TOML text. The daemon renders the text from fixed templates and files it as a `config` proposal through 092's queue, and the owner approves the exact diff in the review both clients already draw.

A daemon started without a file has nothing to propose against, so the extras step says so and does not offer the edit. It does not create the file. A reload reopens each idle session (protocol-change/092, "What it costs"), so the wizard files its edits as one proposal at the end.

## 5. Discoverability fixes

These do not depend on the wizard and ship first.

1. **Projects always present.** In the desktop sidebar, draw the entry whenever a connected daemon has answered `projects.list` (`projectsAnswered`), not only when a project exists; the web rail already draws it, but its empty state should offer the action. With no project it has no badge. The desktop change is one condition at `RootView.swift:159`.
2. **Empty states that say what to do.** The web Projects line says what a project is (`web_view/view/projects.gleam:178`) and should also say what to do: "A project is one router for one repository. Choose a folder and Loom proposes how to check its work." Desktop's "No projects" view gets the same sentence. Mission Control with no session says how to start one.
3. **A first-session hint.** After the first successful session, while no project exists, one dismissible line in the inbox: "Loom can also route a repository's work as tickets. Set up a project." It shows once, the client records it, and it does not return after a dismissal.
4. **A Get started entry.** At the top of the web rail and in desktop's sidebar and palette. It shows "2 of 5 done" from the wizard's own derivation and hides when every step is done or skipped.
5. **Help links.** Each step and empty state points at the section of `docs/configuration.md` it summarizes. The web view cannot use `href` (`docs/lustre.md`, protocol-change/051), so a link is a button that opens the page's own help route; desktop opens the URL.
6. **One word for each kind of role.** "Roles" means model routing in `loom.toml` and access on the Admin page. The wizard says "model roles" and "access roles", never the bare word.

## 6. Slices

Web first, then desktop. Each slice is one PR with captures from a live daemon started on a throwaway state directory and port.

| Slice | Contents | Exit criteria |
| --- | --- | --- |
| **1. Find it (small)** | Web: Projects entry always in the rail, empty states that offer New project, the first-session hint, and the Get started page as a **read-only checklist** built only from reads that exist (status line, remembered default folder, worktree default, projects). Desktop, in its own PR: Projects always in the sidebar with an empty state offering New Project (5.1). | A fresh daemon with no session and no project shows the entry, the empty state and a checklist whose rows are right. Web gates and `make doc-check` exit 0; desktop `make test`, `app` and `parity` exit 0. Captures. |
| **2. Entry and dismissal** | The rail entry's count, hiding when done or skipped, the palette command, skipped steps remembered. | A dismissal survives a reload and a failing `localStorage`. The entry's count equals the checklist's. |
| **3. The project step** | The embedded New project flow with an editable proposal and the template outcome. | A fixture repository with a passing `check` ends "passed", and one with a failing `check` ends "failed" with the daemon's text. |
| **4. GitHub** | Protocol change 135's `setup.github`, the `gh` step and `--publish-to`. | Publishing cannot be turned on while `gh` reports logged out. No reply holds a token. |
| **5. Extras** | `setup.propose_config` through 092: the `summarize` role, and `[jev]` once its table lands. | The approval shows the exact diff. A text that does not load changes nothing. |
| **6. Desktop port** | The wizard in SwiftUI over the same commands, made to feel native in the pass the owner asked for after web parity. | The desktop checklist and the web's agree state by state on a shared daemon. |

## 7. What this does not settle

- Which read reports the `main` role's model: `models.list` (109) or a field on `hello`.
- Whether "Get started" is a page or a drawer on a phone. The mockup draws a page.
- A first run against a remote daemon. The wizard configures the daemon the page is connected to, and desktop's "Connect a Daemon" stays its own sheet.
