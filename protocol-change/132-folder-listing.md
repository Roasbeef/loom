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
