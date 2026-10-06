# protocol-change/074: a session in a folder that has none, from the web home

**Status**: IMPLEMENTED 2026-10-06. **Affects**: one admitted event shape on the
home page's socket (a `submit` whose fields are `path`, `name` and `shareable`,
at a path the owner's socket already admits), the page-side vocabulary
`web_view/creations` (a `Place` and two reasons), the catalogue schema (version
8, one table), and the rule recorded in
[065](065-web-workspace-mode.md)'s section "Where a browser-created session may
point". No frozen Part 1 interface changes: no route, no control command and no
wire frame is added or changed. **Raised by**: the owner's ruling of 2026-10-06,
that the home page may open a new session in a folder that holds none yet.
**Builds on**: [065](065-web-workspace-mode.md) (the home, the fourth pull
request's create-session form, the owner-only capabilities),
[051](051-web-view-route.md) (what a page may draw and what the runtime may
wait for), and the approval and sandbox model in
[docs/architecture/approvals.md](../docs/architecture/approvals.md) and
[effects.md](../docs/architecture/effects.md).

## Problem

Until now a browser could start a session only in a workspace the owner already
held one in. 065 chose that deliberately: a path field for a stolen owner page
"could create a session in any directory the daemon can read and prompt it", and
the owner confirmed the rejection. The cost showed up the first time the owner
used the web home alone. A project with no session cannot be started from the
browser, and neither can one whose sessions were all archived or deleted, so the
home was a list of what already existed and a terminal was needed for every new
folder.

## What was considered

### Which directories

- **Any directory the daemon can read.** This is what the terminal does, since
  `loom` in a directory starts a session there. Rejected for a browser. The
  difference is who can type: the terminal is the owner's own shell, and the
  page may be a cookie in another browser.
- **A directory inside the owner's home directory, chosen.** It matches where
  people keep projects, and it bounds the reach of a stolen cookie to what a
  user-level agent could already touch without leaving the owner's own files. It
  is judged after resolving symbolic links and `..`, so how a path is spelled
  decides nothing. The home directory itself is refused, because a session's
  workspace is writable and the home directory holds every dotfile the owner
  has. A folder is refused when any segment below home begins with a dot. That
  keeps a session out of `~/.ssh`, `~/.aws`, `~/.config`, `~/.claude` and the
  daemon's default state directory, where its own conversation is kept. It also
  refuses a project nested under a hidden folder, which is rare and which the
  terminal still allows.
- **A configured list of allowed roots.** Rejected as machinery for a rare
  need. The home directory is a root every owner has and no one configures.

### Where the folders are remembered

- **Browser storage.** Rejected by the owner's ruling and by the problem: the
  list would differ between devices and vanish with the browser's data, and a
  page may not trust it anyway.
- **The daemon, in the catalogue, chosen.** A table of workspace paths in the
  catalogue, which already holds the small facts that belong to the daemon and
  to no session. It is bounded, ordered by a sequence and not a clock, and
  survives a restart. It is fed by `server.create_session`, which the control
  command and every page share, so a folder the owner started in from a
  terminal is offered on the web as well.
- **A reserved fact in a session's register.** Rejected. The list belongs to no
  session and must outlive all of them.
- **A file beside the catalogue.** Rejected. It would be a second persistence
  mechanism, with its own atomic write and its own corruption story, for a table
  of ten rows.

### Who is offered it

The pages that may already create: the owner's page at Operator ceiling, and no
other. It is the rule `view/create.Create` and `ui_socket.home_create_capability`
already state, and the recent-folders capability uses the same function
(`home_folders_capability`). A member's page, an observer-ceiling page and a
page that has ended are shown nothing, and the daemon refuses their forged
events for who they are, before the path is read. A fresh-home-only rule (as
Stop, Archive and Delete have) was considered and rejected: a home resumed by a
bookmark may already create in every workspace it lists, and withholding this one
would be a distinction without a different outcome.

## Decision

The home draws a section "Other folders" after the lists, for a page that may
create and has read its list. It holds one control, "New session in another
folder", and the folders the daemon remembers that no group already shows.

**The form for a typed folder.** One path field, the same optional name and the
same Shareable box as the workspace's form. This is the first form in which the
workspace is a field, so its decoder (`view/create.typed_fields`) is as strict as
the workspace form's: exactly one `path`, exactly one `name`, at most one
`shareable` whose value is `on`, and no other field, so a repeat or an extra
field drops the event. The path is only text until the daemon has judged it, and
it is never drawn back: not in an attribute, not as a row key, and not in a
refusal, whose words are fixed (`creations.reason_words`). The form sits inside
the sessions region, beneath `home.table_path`, so the owner's socket admits it
as it admits the other submits. Nothing is added to the socket's admission.

**What the daemon does, at the press.** In a weft task, never in the Lustre
runtime (`ui_socket.create_task`):

1. The page is open, its ceiling is Operator, and its credential still
   authenticates as the principal it was admitted for, who is the owner
   (`authorized_owner`, shared with the recent-folders reads). Each is
   `NotOwner`.
2. The path is resolved to a canonical workspace (`client/daemon/new_folder`):
   the text must be nonempty, at most 4096 bytes and free of control,
   zero-width and direction-changing characters; a leading `~` is the daemon
   user's home directory, and `~user` and a relative path are refused; the path
   is made canonical, which fails for one that does not exist or is not a
   directory; the canonical folder must lie strictly inside the canonical home
   directory and have no segment below it that begins with a dot
   (`creations.inside`); and it must be owned by the user who owns the home
   directory, with read, write and search permission for its owner. A path that
   is not a usable folder is `NotAFolder`, and one that is usable but not allowed
   is `OutsideHome`.
3. The name is chosen against the canonical folder, so a blank name is the
   folder's own name (`creations.chosen_name`).
4. The credential's creation allowance is spent (ten an hour), and the session is
   created by the same `server.create_session` as every other creation, then
   opened and ticketed as before.

A workspace the owner already holds a session in is judged as before and is not
judged again against home: the owner started it there.

**Recent folders.** The catalogue's version 8 adds `catalogue_recent_folders`,
and `catalogue.remember_folder`, `recent_folders` and `forget_folder` keep it:

- **Where it lives.** In the catalogue, a table keyed by an autoincrement
  sequence with the workspace as a unique column. It is the daemon's, so it is the
  same on every device and survives a restart.
- **What goes in.** `server.create_session` remembers the canonical workspace once
  the session exists, whichever surface asked, so a creation from a terminal or a
  control client is remembered too. A creation that failed leaves no row.
- **Order, duplicates and bound.** Remembering a folder deletes any earlier row
  for it, inserts it as the newest and trims to ten, in one transaction. Recency
  is the sequence and not a clock. The sequence is also the entry's identity: the
  page keys its rows by it and names it to forget one, and remembering a folder
  again retires the old identity, so a press that was in flight when the list
  changed reaches the same entry or nothing.
- **What the page lists.** The entries inside the home directory that no group
  already shows (`ui_socket.recent_for`; a folder outside home is left out
  because pressing it could only be refused). Each has a "New session" button,
  which opens the usual form under it, and "Forget this folder", which removes the
  entry (`forget_for`). Both reads and the forget run in a task after the same
  owner check as a creation.
- **Judged again at use.** A press on a remembered folder is a `Drawn` place, and
  the daemon accepts it only if the owner holds a session there or the folder is
  still remembered. A remembered folder is then judged exactly as a typed path is,
  so one that was deleted, moved, replaced by a link out of home or made
  unwritable since is refused with the same plain sentence. The entry stays until
  the owner forgets it.

**Why a stolen cookie matters more now, and what bounds it.** Before this change
a stolen owner cookie could start an agent only in a workspace the owner already
ran one in. Now it can start one in any usable, non-hidden folder inside the
owner's home directory, ten an hour, and prompt it at operator role. That is a
real widening, and 065's rejection said so. It is bounded by the model that
already bounds every session, which this change does not touch:

- the session's sandbox base is the workspace-write default of
  [docs/loom-design.md](../docs/loom-design.md): the workspace and scratch are
  writable, the rest of the filesystem is read-only, the network is off, and
  `.git` internals, `.env` and credential paths are protected and never
  writable. The folder's contents are therefore what the agent can change, and
  the home directory itself and every hidden folder are not available to be one;
- anything wider is a sandbox escalation that stops at an approval a person
  answers, bound to the call (docs/architecture/approvals.md);
- the reach is the owner's own home directory, which a user-level process could
  already read, and the page cannot choose a folder it cannot name from outside:
  every canonical path is judged for where it ends up, so a link planted in home
  to somewhere else gains nothing;
- creation is rate-limited per credential, logged as `daemon.session_created`
  with the principal and session, and refused for every page but the owner's.

What it does not bound: a stolen owner cookie can have an agent write inside any
usable, non-hidden folder in home, and read what the default base lets a session
read, which includes the host filesystem
([docs/architecture/effects.md](../docs/architecture/effects.md)). Reading was
already open to a session in any workspace the owner has; the new reach is
writing in the folders of home that no session referenced before.

## Cost

- One table in the catalogue (version 8) and three functions over it. Three
  catalogue messages in the registry, each a single transaction.
- A `Place` in `web_view/creations` (`Drawn` or `Typed`), two reasons with fixed
  words (`NotAFolder`, `OutsideHome`), and `create_for` and `create_task` take the
  folder check as a parameter, so the tests give a home of their own.
- The home page: a section, two states in `view/create.State`, four messages and
  one capability (`Start.folders`), memoized on the section's list.
- `client/daemon/new_folder`, which asks the filesystem through the existing
  `bootstrap.canonical_directory` and `simplifile`. No new Erlang is added.
- The check "owned by the home directory's owner" stands in for "the daemon's
  user", which saves asking the operating system for an identity and is exact in
  the only deployment that matters, where the daemon is the owner's own process.
- The hidden-folder rule refuses a few legitimate projects. The terminal still
  opens a session in any of them.
- A folder remembered from another surface that is outside home is never listed on
  the page, so it cannot be offered and refused.
- A race between the check and the creation (a folder swapped for a link between
  them) is closed by `server.create_session`, which canonicalizes the workspace
  again and refuses one that is no longer a directory. It does not repeat the
  home check, so a swap to a link out of home inside that window is possible for
  an attacker who can already write inside the owner's home, which is not an
  attacker this feature needs to stop.

## Verification

Tests pin the form's decoder (exactly one `path`, one `name`, at most one
`shareable`, and a refusal of an extra field, a repeat and a forged `path` on the
workspace form); the pure rules (`typed_path`, `expanded`, `inside`); the
filesystem rules against real directories (accepted in canonical form,
outside-after-resolution refused for a link and for `..`, home itself, a hidden
folder, a missing path, a file, a dangling link, a relative path, `~user`, a
control character, an over-long path, and a folder the owner cannot write); that
only the owner's operator page is handed the controls and the capability; that a
forged typed creation from a member's page or an observer-ceiling page is refused
as `NotOwner` and creates nothing; that a typed path creates in the canonical
folder and remembers it; that recents are bounded, ordered, deduplicated, survive
a reopen and lose a forgotten entry; that a remembered folder deleted since is
refused at the press; and that a path is drawn only as a text node, never an
attribute or a key.
