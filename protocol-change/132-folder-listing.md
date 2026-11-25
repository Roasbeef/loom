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
`home.Folders.index`, answered by `client/daemon/folder_listing.index_in`; the types
`web_view/folder_browse.Entry`, `Index`, `Reach` and `IndexAnswer` and the functions
`needle`, `rank` and `hit_trail`; the composer's `Seek`, `Choice` and `Choices`, the
target `composer.Project`, the messages `ChoseFound` and `Entered` and the function
`composer.indexing`; and one client element, `<loom-picklist>`. No wire frame,
control-socket command, stored record, event or `loom.toml` key changes, and no
clause of the home socket's admission changes (see "Admission" below).

**Problem.** The owner finds a folder by walking the picker one directory at a
time, or by typing a path. Neither is quick for a folder they know by name. The
Code list should work as one search field over the places a session may start:
type a few letters of a name and press Enter.

**What was considered.**

- **Filter only the lists the page already holds.** Rejected as the whole answer.
  The remembered folders and the projects are held and are filtered that way, but a
  folder with no session in it is in neither, and it is the one the owner is looking
  for.
- **A walk of the home for each keystroke.** This was the first design and it is
  withdrawn. A review measured an owner's home at 1, 65, 613, 2404, 5053 and 9222
  directories per level, so a 2000-directory budget ran out inside the third level
  and no repository at depth five was ever found. Raising the budget does not fix
  it, because the hit cap also ends the walk on shallow matches, and a walk for each
  keystroke has no bound on how many run at once, each costing tens of thousands of
  file calls. The failure is the shape, so the shape changed.
- **Resolve every directory the walk meets, as a listing does.** Rejected for the
  same cost. The walk instead follows no symbolic link: a directory is entered only
  when `lstat` says it is a real directory. Every directory it can reach is then
  inside the canonical home by construction, and a link out of the home, to a
  hidden folder or to a file is not entered and not reported.
- **An index kept by the daemon for each attachment.** Rejected. It needs a process
  and a lifetime of its own on the daemon. The page is already a process in the
  daemon with a lifetime, so it holds the index, and the daemon keeps no state.
- **A branch row, "Branch  main >", on the chosen folder.** Left out. The daemon
  gives the web view no read of a folder's branches, and a session does not start on
  a chosen branch: its worktree takes a branch of its own (`client/worktrees`). A
  branch choice would need both a read and a rule for what a session does with it.
- **A "No folder" row.** Left out. A session needs a workspace, and `composer.started`
  holds Start until one is chosen. A session with none is a different feature.

**Decision.**

**One index, ranked in the page.** `home.Folders` gains

```gleam
index: fn(List(String), fn(folder_browse.IndexAnswer) -> Nil) -> Nil
```

The page asks for the index when the Code list opens (`composer.indexing`), and the
index is one `folder_browse.Index`: the canonical home, a list of `Entry` (a trail
and the directory's lower-case name) and whether the build looked everywhere. Typing
asks the daemon for nothing. Each keystroke ranks the held index in memory
(`folder_browse.rank`, about 6 to 11 ms for 17,000 entries). The page holds one
request at a time: it is `Indexing` from the ask until the answer, and nothing asks
again meanwhile, so no number of keystrokes starts a second build.

**Lifetime.** The index belongs to the page and lives for `index_ttl_ms` = 5 minutes
from the page's clock when it arrived. The next open of the list after that asks for
a new one, and the old one stays drawn until it arrives. A build that was refused is
asked for again at the next open, and an index already held survives a refused
refresh. The page ends and the index with it.

**The seeds.** The one argument is the page's remembered folders. The daemon reads
the parent of each of them (when it lies below the home) before the rest of the home,
so a container of repositories, such as `~/gocode/src/github.com/roasbeef`, is
indexed first however wide the rest of the home is. A seed is a hint, not a path to
trust: each component of its parent is checked from the home down as a visible real
directory, and one that passes through a link, lies outside the home or is hidden is
not read.

**Who may ask.** The same rule as `browse`: `Folders` is `Some` only for the
daemon's owner on a page minted to operate, and `ui_socket.index_for` runs
`authorized_owner` on every call before it reads the home. A member's page, an
observer's page and an operator's page that is not the owner's are refused as
`NotAFolder`, in the words a missing folder gets, so the answer does not say which
it was. It runs in a task of its own, never on the socket's process, under a 5 second
deadline that answers `Unreadable` when it expires.

**What the daemon does**, in this order:

1. The home is read from `HOME` and made canonical (`new_folder.home`), only after
   the owner check.
2. The walk is breadth first from the seeds' parents and then the home. At each
   directory it reads the entries under `entry_limit`, drops names that start with
   `.`, names `component_ok` refuses and a first-level `Library`, and keeps only
   those that `lstat` reports as real directories.
3. A directory that holds a `.git`, or sits below one, lists only its children that
   hold a `.git` themselves, which are its worktrees and sub-repositories, but the
   walk keeps descending, so a repository inside a container inside a repository is
   still found.
4. A directory named `node_modules`, `_build`, `build` or `target` is an entry, since
   the owner may look for it by name, but is not entered.
5. The walk lists at most `index_depth` = 6 levels, reads at most
   `index_visit_limit` = 20,000 directories, holds at most `index_entry_limit` =
   60,000 entries and runs at most `index_ms` = 4 seconds. Any of them ends the build
   with what it has, saying `Stopped`; the entry bound is checked between
   directories, so the last directory read may carry the count past it by up to
   `entry_limit`. A build that ran out of directories says `Covered`. The page says
   "Not every folder was searched" for a `Stopped` index.

Every entry is a real directory below the home that is not hidden, which is also what
`creations.inside` accepts, and the creation judges it again.

**Ranking.** `folder_browse.rank` keeps the best `find_limit` = 20, not the first
twenty it meets: an exact name, then a name that starts with the fragment, then any
name that holds it, the shallower first within a kind, then the trail in order. A
fragment that holds a slash is looked for in the whole trail, so `code/app` finds the
`app` below `code`. `needle` removes a leading `~/`, so a pasted `~/code/app` is the
same search, and requires two characters.

**What the page keeps.** The page holds the ranking it last drew, and a press names an
index into it (`ChoseFound(index)`), which `folder_browse.hit_trail` turns into a
trail, so the browser names no path, and an index outside the ranking changes
nothing. A found folder becomes `composer.Picked(trail)`, which reaches the daemon as
the typed `~/` path that `new_folder.check` judges when the session is created,
exactly as a folder chosen in the picker does. The listing is advice; the creation is
the check. A found folder is left out of the Folders rows only when a remembered
folder drawn above it is the same directory, compared as whole paths with the home
the daemon sent, so `~/loom` is not hidden by `~/work/loom`.

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
is on the page it puts the focus in the search field (again when the list returns from
the folder picker), moves the focus down and up the rows with the arrow keys and
presses the list's own scrim on Escape, except for a key that belongs to an input
method's composition. It reads no attribute and sends the server nothing: moving focus
changes no fact the server holds, and the scrim press is the ordinary click the server
already answers. Enter on a focused row is that row's button.

**Admission.** The search field's `input` and `submit` and every row's `click` are
beneath `home.table_path`. `home_owner_accepts` admits `input` and `submit` by path
prefix and `click` by path prefix, so no admitted path changes. A member's or an
observer's home draws no search and, if a frame named one of its paths, has no
handler there.

**What it costs.**

- The owner's page can learn the names of directories below the home, and, from the
  index, all of them at once. An owner can already read them, and a page whose
  credential leaked could already list them one directory at a time through
  `browse`. The index makes that faster, not wider: it reports nothing a chain of
  `browse` presses does not, and it skips what `browse` hides.
- One build of up to 20,000 directory reads and as many `lstat` calls for each open
  of the list that finds no young index, in a task that dies with the page. Built on
  the BEAM against a names-only tree of 17,358 directories shaped like the owner's
  home (1, 65, 613, 2404, 5053 and 9222 directories per level) it took about 1.0
  second and listed 17,090 entries, and ranking them took 6 to 11 ms. A cold file
  cache is slower and is bounded by the 4 second limit.
- Up to 60,000 entries held in the page's memory, each a trail of at most six names
  that are shared with the directory listing they came from, for five minutes.
- A folder deeper than six levels, inside a directory the build does not enter, or
  beyond a bound of a very large home is found through "Open folder..." or a typed
  path, and the list says when the build stopped.
- A link to a folder is not found by name, since the walk follows none. The folder it
  points to is found under its own name if it lies inside the home.
- The index is a snapshot. A folder created after it was built is not offered for up
  to five minutes, and one removed is refused at creation with the fixed words of
  `creations.NotAFolder`.

**Verification.** `folder_listing_test` exercises the build on a temporary tree: the
ranking order, a hidden folder, `Library`, a file, a link out of the home and one
inside it with a real folder beside them as a positive control, a folder named like
build output being an entry and nothing under it, a fragment with a slash, the depth
bound at six and seven, each of the visit, entry and time bounds with a match beyond
it, the checkout rule, and a container of repositories that is found only when the
remembered folders seed the walk, with a seed through a link refused. `ui_route_test`
covers `index_for` for the owner, an observer, a member and a page that has ended, and
that the home is not read for a refused page. `folder_search_test` covers the model
(one ask on open and none for a keystroke or while one is out, the lifetime, the
retry after a refusal, the ranking and its cap, the order of the rows, the whole-path
dedupe, Enter, a forged index, projects) and the page (the rows as text, escaped
markup in a name, the notes, and every handler beneath the admitted region).
`picklist_test` covers the key rules.
