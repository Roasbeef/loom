# protocol-change/132: the owner's page lists directories below the owner's home

**Status**: ACCEPTED 2026-11-23. The owner asked for a folder picker in the
web composer and accepted protocol changes for this UI work in the same session.
**Affects**: one new read the owner's operating home page may ask of the daemon,
`home.Folders.browse`, answered by `client/daemon/folder_listing`; the types
`web_view/folder_browse.Listing`, `Child`, `Cut` and `Refusal`; a new composer
target, `composer.Picked`. No wire frame, control-socket command, stored record,
event or `loom.toml` key changes. No clause of the home socket's admission
changes (see "Who may ask").
**Amends**: [074](074-web-new-folder-sessions.md) (typed folders): a folder may now also be named by
choosing it from a listing, and it is judged by the same rules at creation.
[051](051-web-view-route.md): the picker's buttons are clicks beneath
`home.table_path`, which the owner's home socket already admits.

## Problem

"Choose a folder…" in the composer's Code list opened a typed path field, and
the owner does not want to type paths. A browser's file dialog cannot help: it
returns a file the browser holds, not a path on the daemon's machine, and the
daemon is where the session's files are. The desktop app draws a Finder panel
because it runs on the daemon's machine. The web view has to draw its own picker,
and a picker needs the daemon to say which directories exist. That lists the
owner's files to a browser, so it needs a bounded, owner-only rule of its own.

## What was considered

- **List any directory the daemon's user can read.** Rejected. The page would be
  a file browser for the machine. A session may only start below the owner's
  home (`creations.inside`), so nothing outside it can be chosen, and a listing
  of it would only be information.
- **The browser sends an absolute path and the daemon lists it.** Rejected. A
  path is the one thing a page must not be trusted to name. The page sends a
  trail of directory names relative to the home, and the daemon resolves it.
- **A new control-socket command, so the desktop can use it too.** Rejected. The
  desktop has `NSOpenPanel`. The web view's in-process call is the whole need.
- **A native `<input type="file" webkitdirectory>`.** Rejected: it uploads the
  folder's contents to the page and yields no path on the daemon's machine.
- **List files too, to show what is in a folder.** Rejected. A choice is a
  folder, and names of files are more of the owner's data than the choice needs.
  A child that is a Git repository is marked, with one `stat` of its `.git`.

## Decision

**The request.** `home.Folders` gains

```gleam
browse: fn(List(String), fn(folder_browse.Answer) -> Nil) -> Nil
```

The first argument is a trail: directory names below the home, outermost first,
`[]` for the home itself. It returns at once and answers from the daemon's own
task, as the other reads of `Folders` do.

**Who may ask.** `Folders` is `Some` only for the daemon's owner on a page minted
to operate (`ui_socket.home_folders_capability`), the same rule as the recent
folders and the creation, and `ui_socket.browse_for` runs the owner check
(`authorized_owner`) again on every call. A member's page, an observer's page and
an operator's page that is not the owner's hold no `browse` and draw no picker.
The path is the web view's in-process call only: no control-socket command exists.

**What the daemon does with a trail**, in this order, each refusal fixed words
that never echo the trail or the filesystem's error:

1. Every component must be non-empty, not `.` or `..`, free of `/` and control
   characters, and at most 255 bytes. The trail has at most `depth_limit` = 8
   components. Otherwise `NotAFolder` or `TooDeep`.
2. The home is read from `HOME` and made canonical (`new_folder.home`); the trail
   is joined to it and the result is made canonical again, which resolves every
   symbolic link. A symlink that leaves the home therefore resolves outside it
   and is refused, and one that stays inside is listed under the directory it
   names. The canonical path must be the home or satisfy `creations.inside`,
   which refuses a hidden component and `~/Library`. Otherwise `NotAFolder`.
3. The canonical path must be at most `depth_limit` below the home. A symlink
   that makes it deeper is `TooDeep`.
4. The directory is read with `bootstrap.list_directory_bounded` at
   `entry_limit` = 1000 entries. A directory with more is `TooMany`; any other
   read failure is `Unreadable`. Neither says which entry or why.
5. Names that start with `.` are dropped. Each remaining name is made canonical
   too and kept only if it is a directory that is the home or inside it, so a
   child that is a symlink out of the home, a file, a dangling link or an
   unreadable directory is not listed. The names are sorted without regard to
   case, and at most `shown_limit` = 200 are returned. A listing that reached the
   cap says `CutShort`, and a listing at `depth_limit` returns no children and
   says `AtDepthLimit`.

At most `inspect_limit` = 300 names are made canonical in one listing, counting
those refused, so a directory of links out costs 300 resolutions and no more; the
listing then says `CutShort`. The whole read runs under a 5 second deadline and
answers `Unreadable` when it expires, and the home is read only after the owner
check. A canonical trail that holds a name `component_ok` refuses, or is not a
directory as spelled, is `NotAFolder`.

The answer is `Listing(trail, children, cut)`, where `trail` is the canonical
trail the page shows as a breadcrumb, and each child is a name and whether it
holds a `.git`. Hidden directories are never listed, because a session cannot
start in one, so a switch to show them would only offer choices the creation
refuses.

**What the page keeps.** The page holds the listing it last drew, and a press
sends only an index into it: `Descended(index)`, `Ascended(depth)` and
`ChosePicked`. The server builds the next request from its own listing, so the
browser never names a path, and an index outside the listing changes nothing. The
page ignores an answer whose requested trail is not the one it is waiting for.

**The choice.** `ChosePicked` sets `composer.Picked(trail)`, which the composer
turns into the typed place `~/` and the trail. The daemon judges that exactly as
a typed path (`new_folder.check`) when the session is created: canonical,
inside the home, not hidden, not the daemon's state folder, owned and writable.
The listing is advice; the creation is the check.

**Admission.** Every button of the picker is a click beneath `home.table_path`,
and its search-free form has no input. `home_accepts` and `home_owner_accepts`
admit clicks by path prefix, so no admitted path changes. A member's or an
observer's home draws no picker and, if a frame named one of its paths, has no
handler there.

## What it costs

- The owner's page can learn the names of directories below the home, and
  whether each holds a `.git`. An owner can already read them. A page whose
  credential leaked could read them too, as it can already read the owner's
  session transcripts and start sessions in the home.
- Up to 1000 directory reads and 200 `stat`s of `.git` per press, in a task that
  dies with the page. A directory of more than 1000 entries cannot be browsed;
  the owner types its path, which stays reachable under "Type a path instead".
- A folder outside the home still needs the typed path, and is refused there as
  it was.
- A symlinked directory is listed under its link's name and the breadcrumb shows
  where it really is, which may differ from the name pressed.
- The listing is a snapshot. A directory removed after it was read is refused at
  creation with the fixed words of `creations.NotAFolder`.

## Verification

`folder_listing_test` exercises the daemon's half on a temporary tree: the entry
bound, the depth bound, a symlink out of the home and a link to a file, a trail
outside the home, a hidden directory, `Library`, an unreadable directory, and a
repository mark. `composer_test` and `home_composer_test` cover the picker's
model, a forged index, and the view for the owner against an observer's home.
`ui_socket_test` covers `browse_for` for a member and for the owner.

## Addendum (2026-11-24): searching the folders below the home

**Affects**: one further read of the owner's operating home page,
`home.Folders.find`, answered by `client/daemon/folder_listing.find_in`; the types
`web_view/folder_browse.Hit`, `Found`, `Reach` and `FindAnswer` and the functions
`needle`, `matches` and `hit_trail`; the composer's `Seek`, `Choice` and
`Choices`, the target `composer.Project`, the messages `ChoseFound` and
`Entered` and the intent `Find`; and one client element, `<loom-picklist>`. No wire
frame, control-socket command, stored record, event or `loom.toml` key changes,
and no clause of the home socket's admission changes (see "Admission" below).

**Problem.** The owner finds a folder by walking the picker one directory at a
time, or by typing a path. Neither is quick for a folder they know by name. The
Code list should work as one search field over the places a session may start:
type a few letters of a name and press Enter.

**What was considered.**

- **Filter only the lists the page already holds.** Rejected as the whole answer.
  The remembered folders and the projects are held and are filtered that way, but a
  folder with no session in it is in neither, and it is the one the owner is looking
  for.
- **Index the home when the daemon starts.** Rejected. It holds a copy of the
  owner's directory tree in memory or in the catalogue, goes stale at once and
  needs a watcher to stay right. A search that walks at the press costs a few
  milliseconds on a home of ordinary size and is bounded.
- **Reuse `browse`, walking with it from the page.** Rejected. It is one directory
  per round trip and resolves each child with a process, which a search over
  thousands of directories cannot afford.
- **Resolve every directory the walk meets, as a listing does.** Rejected for the
  same cost. The walk instead follows no symbolic link: a directory is entered only
  when `lstat` says it is a real directory. Every directory it can reach is then
  inside the canonical home by construction, and a link out of the home, to a
  hidden folder or to a file is not entered and not reported.
- **A branch row, "Branch  main >", on the chosen folder.** Left out. The daemon
  gives the web view no read of a folder's branches, and a session does not start on
  a chosen branch: its worktree takes a branch of its own (`client/worktrees`). A
  branch choice would need both a read and a rule for what a session does with it.
- **A "No folder" row.** Left out. A session needs a workspace, and `composer.started`
  holds Start until one is chosen. A session with none is a different feature.

**Decision.**

**The request.** `home.Folders` gains

```gleam
find: fn(String, fn(folder_browse.FindAnswer) -> Nil) -> Nil
```

The argument is the fragment `folder_browse.needle` made of the owner's text:
trimmed, lowercase, one line, from `needle_min` = 2 to `needle_limit` = 64
characters. The page asks only for a fragment that passes, and the daemon judges it
again, so a fragment that does not is `NotAFolder`, which no page of ours sends.
It returns at once and answers from the daemon's own task under the same 5 second
deadline as a listing, answering `Unreadable` when it expires.

**Who may ask.** The same rule as `browse`: `Folders` is `Some` only for the
daemon's owner on a page minted to operate, and `ui_socket.find_for` runs
`authorized_owner` on every call before it reads the home. A member's page, an
observer's page and an operator's page that is not the owner's are refused as
`NotAFolder`, in the words a missing folder gets, so the answer does not say which
it was.

**What the daemon does with a fragment**, in this order:

1. The fragment is judged by `folder_browse.needle`.
2. The home is read from `HOME` and made canonical (`new_folder.home`), only after
   the owner check.
3. The walk is breadth first from the home, so a match near the home is found before
   one deep in a checkout. At each directory it reads the entries under
   `entry_limit` (a directory over it is passed over, not reported), drops names
   that start with `.`, names `component_ok` refuses and a first-level `Library`,
   and keeps only those that `lstat` reports as real directories.
4. A kept directory is a hit when `folder_browse.matches` says its name holds the
   fragment, or, for a fragment that holds a slash, when its trail below the home
   does. A directory named `node_modules`, `_build`, `build` or `target` may be a
   hit but is not entered, since its contents are build output no session starts
   in.
5. The walk stops, saying `Stopped`, at `find_limit` = 20 hits or `visit_limit` =
   2000 directories read, and does not enter a directory deeper than `find_depth`
   = 6 below the home, which is inside `depth_limit` so every hit is a trail a
   creation takes. A walk that ran out of directories says `Covered`.
6. Each hit is a trail and whether the directory holds a `.git`, one `stat` for each
   of at most 20 hits.

**What the page keeps.** The page holds the hits it last drew, and a press names an
index into them (`ChoseFound(index)`), which `folder_browse.hit_trail` turns into a
trail, so the browser names no path, and an index outside the hits changes nothing.
A hit becomes `composer.Picked(trail)`, which reaches the daemon as the typed `~/`
path that `new_folder.check` judges when the session is created, exactly as a folder
chosen in the picker does. The listing is advice; the creation is the check. An
answer is applied only while the page waits for that fragment, so a slow answer
never overwrites a newer one, and while a newer answer is out the last hits stay
drawn, narrowed to the fragment now typed.

**Projects.** The owner's projects are listed under their own heading when the
daemon listed them to the home (`Offers.projects`, from the boards the page already
reads under protocol-change/106). A project is a workspace the daemon wrote, so
`composer.Project(workspace)` is offered only when that list holds it, and the
creation judges it as a typed path, as it judges a picked folder. Nothing new is read.

**Enter.** The search field is in a form, and Enter submits it. The submit is an
event beneath `home.table_path`, which the owner's socket already admits, and the
composer turns it into the choice of the first row of the list, in the list's order:
the remembered folders, then the found ones, then the projects.

**The keyboard.** `<loom-picklist>` is a client element that wraps the list. While it
is on the page it puts the focus in the search field, moves the focus down and up the
rows with the arrow keys and presses the list's own scrim on Escape. It reads no
attribute and sends the server nothing: moving focus changes no fact the server
holds, and the scrim press is the ordinary click the server already answers.
Enter on a focused row is that row's button.

**Admission.** The search field's `input` and `submit` and every row's `click` are
beneath `home.table_path`. `home_owner_accepts` admits `input` and `submit` by path
prefix and `click` by path prefix, so no admitted path changes. A member's or an
observer's home draws no search and, if a frame named one of its paths, has no
handler there.

**What it costs.**

- The owner's page can learn the names of directories below the home that hold a
  fragment, and whether each holds a `.git`. An owner can already read them, and a
  page whose credential leaked could already list them one directory at a time
  through `browse`. The search makes that faster, not wider: it reports nothing a
  chain of `browse` presses does not, and it skips what `browse` hides.
- Up to 2000 directory reads and as many `lstat` calls per keystroke that changes the
  fragment, in a task that dies with the page. A person typing five letters starts
  up to four walks; each is bounded, and one that is overtaken still runs to its end
  or its deadline. A home with more than 2000 directories above `find_depth` is
  searched shallowest first and says `Stopped`.
- A folder deeper than `find_depth`, or inside a directory the search does not enter,
  is found through "Open folder…" or a typed path.
- A link to a folder is not found by name, since the search follows none. The folder
  it points to is found under its own name if it lies inside the home.
- The results are a snapshot. A folder removed after the walk is refused at creation
  with the fixed words of `creations.NotAFolder`.

**Verification.** `folder_listing_test` exercises the walk on a temporary tree:
order shallowest first, case, a Git mark, a hidden folder, `Library`, a file, build
output, a link out of the home and a link inside it, a fragment with a slash, a
fragment that is too short or holds a control character, the hit cap and the depth
bound. `ui_route_test` covers `find_for` for the owner, an observer, a member and a
page that has ended, that the home is not read for a refused page, and the deadline.
`folder_search_test` covers the composer's model (one ask for a fragment, none for a
short one or a page that may not type, stale answers dropped, narrowing, the order of
the rows, a found folder shown by a remembered one left out, Enter, a forged index,
projects) and the page (the rows as text, escaped markup in a name, the notes, and
every handler beneath the admitted region). `picklist_test` covers the key rules.
