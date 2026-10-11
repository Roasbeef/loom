# protocol-change/082: switching a session's model profile

**Status**: ACCEPTED 2026-10-08 by the owner, who requested the feature; the
protocol delegation in `docs/execution.md` §7 does not cover new product
features, so acceptance was the owner's. **Affects**: two session commands, `profile_get`
and `profile_set`, and one snapshot, `profile` (the session wire of
`docs/client-protocol.md`); the catalogue's registration, which can now change
its `profile`; the `/profile` and `/model-profile` slash commands of the
terminal and the web page; and the catalogue parser, which refuses a profile
named `default`. No route, frame or event of Part 1 is removed.
**Raised by**: the owner's request for an easy way to change a live session's
model profile. **Builds on**: [076](076-config-profiles.md) (profiles in the
configuration, chosen when a session is created).

## Problem

076 lets an operator choose a model profile when a session is created, saves the
name with the session, and resolves it again at every open. It gives no way to
change the choice afterwards. A session that was started on the default roles
cannot move to `codex` without being abandoned, and `/model` does not stand in
for it: `/model` changes the model of one strand (or of every strand), while a
profile also decides the `subagent`, `plan`, `summarize`, `vision` and `advisor`
chains, which no command reaches.

## What was considered

### Replacing the gateway under the running session

The session's roles are read by many consumers, each of which captured what it
needed when the session opened: the provider gateway behind every request, the
subagent route that seeds a child strand (`serve.agency_config`), the
summarizer and block-summary routes, the compaction windows, and the advisor.
The advisor is the decisive one. A catalogue that routes no `advisor` role
produces no advisor wiring at all, "no tool, no hook, no strand, no actor"
(`serve`), so a profile that adds an advisor to a session opened without one
cannot be given its advisor by swapping a value. Replacing the pieces one by one
would add a mutable cell for every consumer and still leave this case open.
Rejected.

### Applying the profile at the next open and doing nothing now

Cheap, and consistent with 076, but it leaves the session on the old roles until
someone stops and reopens it. The owner asked for an immediate switch.
Rejected as the whole answer. It is kept as the failure mode: a switch whose
restart does not complete has still saved the profile.

### Saving the profile and restarting the session

Chosen. The profile is the registration's name for the roles, and the open that
already resolves it builds every consumer from the file as it stands. The switch
saves the new name and then stops and reopens the session, which is the stop and
resume `shareable` already runs for making a private session shareable. Nothing
new is built to resolve roles.

### Where the command lives

On the session wire next to `set_config`, as a session command, so that the
shared step runs it the same way in the terminal and on the page, and the page
needs no new route. A daemon control command (`sessions.set_profile`) was
considered and rejected: the page refuses every command that is not a session
command (`component.page_command`), so it would have needed a second path in
each host, for a switch that is always made from inside an attached session.

## Decision

### Commands

`profile_get` has an empty body and is answered by a `profile` snapshot.

`profile_set` carries one optional field:

```
"profile": "<name>"     # absent: the configuration's default roles
```

A present `profile` must satisfy `storage/catalogue.is_profile_name`. Null, the
empty string and a malformed name are refused as `bad_request`, never read as the
default. This is 076's rule for creation, for the same reason: a misspelled name
must not move a session onto the default roles. The default is the absent field,
and the terminal sends it for the word `default`.

The snapshot is

```
{"mode": "profile", "profile": "<name>", "available": ["a", "b"], "moved": 2}
```

`profile` is absent for the default roles. `available` is the profile names the
configuration defines when the request is answered, sorted; the default roles
are the absence of a profile and are not listed. `moved` is present only in the
reply to `profile_set`, as the number of strands the switch moved, and its
presence tells the client the session is restarting and the connection is about
to close.

### Authority

`profile_get` is a read. `profile_set` is the session owner's alone: an observer
is refused as for every write, and a member who is an operator is refused with
`forbidden`, as for remembering permissions (073). A switch restarts the session
for everyone attached and rewrites the owner's registration, which an operator
who may prompt and `/model` has no claim to.

### What a switch does, in order

1. The session must be idle. If any strand has a running operation the switch is
   refused with `conflict` and nothing changes. The restart stops the session,
   which would end the run and resume it, and a request in flight is not the
   switch's to interrupt. The operator waits for the run to settle or aborts it.
2. A switch to the profile the session already has answers with the listing and
   changes nothing.
3. The daemon loads the configuration with the profile applied
   (`client/daemon/profiles.load`). An unknown name is `bad_request` with 076's
   sentence naming the profiles that exist. Nothing has been written.
4. The strands to move are chosen (below), then the registration's profile is
   saved (`catalogue.set_profile`, one transaction that moves the revision). A
   refused save changes nothing.
5. The chosen strands' stored models are rewritten in one commit by the path
   `set_config` uses. Their thinking levels are left alone, for the reason
   `model_name` leaves them alone.
6. The `profile` snapshot is sent, carrying `moved`.
7. The daemon stops the session and opens it again in a process the session does
   not own (`client/daemon/restart`). The open builds the gateway, the subagent,
   summarizer and vision routes and the advisor from the saved profile.

Every failure after step 3 leaves a session that works. A strand holding a model
that heads no role of the saved profile is dispatched as exactly that model
(`wiring.request_target`), and the saved name is read by the next open. A restart
that fails is logged (`daemon.profile_restart_failed`) and leaves the session
running on its old roles with the new profile saved for its next open.

### Which strands move, and `/model`

A strand follows a role while its stored model is the head of that role's chain,
because that is the model the role seeded it with. `catalog.retargets` compares
the role tables of the profile being left and the profile being entered and lists
the strand-bearing roles (`main`, `subagent`, `advisor`, in that order) whose head
changed. A strand holding the old head of one of them moves to the new head of
that role, and the first listed role wins a tie, as `wiring.routed_role` already
resolves one.

A strand chosen by hand with `/model` holds a model that heads no role of the
profile being left, so it is left where it is: **an explicit per-strand choice
keeps winning over a profile switch**, which is what 076 already said of a
resume. The stored model is the only record of whether a strand was chosen, so a
hand choice of an entry that happens to head a role is indistinguishable from
following it and moves with it. A model chosen for a strand is not recorded
anywhere else, and a second record would be the machinery this avoids.

### Child strands and the advisor strand

A child strand that is already running does not exist during a switch, because the
switch is refused while any strand runs. A child that is idle holds the model it
was seeded with, moves with the `subagent` head if it holds it, and otherwise stays.
A child spawned after the restart is seeded from the new `subagent` route. The
advisor strand is created once and found again by a later open
(`advisor.ensure_strand`), so it is retargeted like any other strand: its stored
model is the old `advisor` head and moves to the new one. No lifecycle is added
for children.

### The word `default`

`/profile default` selects the default roles. No spelling for "no profile" existed
at the command line beyond omitting `--model-profile`, and the web form labels the
choice "Default". `default` is therefore reserved: `catalog.parse` refuses a
`[profiles.default]` table with a sentence that says why, so the word can never
name a profile and the command never has to guess. 076 shipped two days earlier
and no configuration is known to use the name. `--model-profile default` is not a
profile name at creation either, and is refused as an unknown profile.

### Commands in the terminal and on the page

`/profile` and its alias `/model-profile` are session commands (`session_view/command`).
Both hosts run them through the shared step, so they appear in the palette, the
help text and the page's completion table without a host change.

- `/profile` sends `profile_get` and writes the answer to the transcript: the
  current profile, then the names that can be switched to, with `default` first.
- `/profile <name>` and `/profile default` send `profile_set` and write what was
  saved and how many strands moved.
- The palette completes `/profile default`. The names are the daemon's and are
  not known to the client until `/profile` is answered, so they are not offered as
  completions; the page's completion table is an attribute and carries no daemon
  text (051).

When the socket closes the terminal's existing reconnect tries to reattach the
same session. That attempt can arrive while the daemon is still stopping the
session, in which case it is spent with a pointer to `/sessions`, which opens the
session again. The
page shows the session-stopped notice it shows for any stop, and the owner
reloads it, as after making a session shareable (065).

## Cost

- A switch restarts the session. Connections close and background jobs end with
  the incarnation, as on any stop; schedules and held state resume from what the
  session persisted (`docs/architecture/sessions.md`). This is the price of
  rebuilding every consumer of roles by the path that already exists.
- The switch is refused while any strand runs, so it cannot be used to change
  roles in the middle of a long run. The operator aborts, or waits.
- A registration's profile is no longer immutable. A creation retried under the
  same request key after a switch carries the original profile and is a
  `conflict`, as a retry with any other changed field is. The window is a retry
  after a lost reply, which the switch's own restart makes unlikely to coincide.
- A hand-chosen model that equals a role's head moves with the role. The stored
  model is the only record there is.
- The page has no profile picker. `/profile` prints the names, and a name is
  typed. A picker would put the daemon's names in a control the page draws, with
  the rules 051 sets for them, for a command used rarely.
- `default` is reserved, which is a (small) tightening of 076's grammar.
- `Settings` gains `profile_desk` and the hub gains a field for it, so every
  construction of `serve.Settings` in the tests carries it.

## Verification

Tests pin: the command's decoder (absent is the default, null, empty and malformed
names are refused) and the snapshot's round trip; the hub's conduct (no daemon is
`unsupported`, the listing, a switch that saves, moves and restarts in that order,
a strand chosen with `/model` left alone, `default` clearing the profile, the
current profile answering with a listing, an unknown name refused with nothing
written, a refused save moving nothing, a running strand refusing the switch, and
a member refused); `catalog.retargets` and the refusal of a `default` profile;
`profiles.load`; the catalogue's `set_profile`, which survives a restart; the
registry's save followed by a restart handing the next open's builder the saved
profile, a failed reopen leaving the session saved with the profile kept, and the
detached process reporting its failure; that a stored switch changes what the next
open routes by, with an omitted role inheriting `[roles]`; and, in the terminal and
on the page, the parse of both spellings, their palette and help entries, the frame
each sends and the transcript lines the answers write.
