# Working with other people in Loom

This guide is for you if Loom is already running and you want to do one of
these things:

- open your sessions in a browser,
- share a session with a colleague,
- find out why a session cannot be shared,
- invite someone, and let them join,
- see who has access, and remove it.

It uses the web page first and gives the terminal command beside each step
where one exists. It does not explain how any of it works inside. The
[further reading](#further-reading) at the end does.

Some words used throughout:

- The **owner** is the person who runs the daemon (`loomd`) and made the
  sessions. This is you, if you are inviting people.
- A **member** is someone the owner invited to one or more sessions.
- A **role** is what a member may do in one session. An **observer** can
  follow the session and send nothing. An **operator** can send prompts,
  steer the agent, and answer approval requests. An operator's page offers
  "allow once" and "deny" on an approval, never "allow for the session".
- A **claim token** is the one-time secret an invitation produces. It starts
  with `loomclaim_`. The invitee pastes it to join.

Neither role can stop the daemon, see a session they were not invited to, or
reach another workspace.

## 1. Open Loom in a browser

The daemon serves the web page only when it was started with `--ui`, or when
`ui = true` is set in `~/.loom/loom.toml` under `[daemon]`. If a daemon is
running without it, `loom ui` says so and exits. It does not restart a daemon
other people may be using.

To open your home page, which lists all your sessions:

```bash
loom ui --open
```

To open one session directly, as an operator who can type into it:

```bash
loom ui --session SESSION_ID --operate --open
```

Without `--open` the command prints the link and you open it yourself.
Without `--operate`, a link for one session is read-only. Find a session's id
with `loom sessions list`.

### Why you cannot just visit the port

The daemon does not accept a plain visit to its address. Each link `loom ui`
prints carries a one-time ticket. It works once, within 60 seconds, and only
in the browser tab that opens it. If you open it a second time, in a new tab,
or after a restart of the daemon, you get a page saying the link has expired
or was already used. Run `loom ui` again for a new one.

The daemon listens only on the local machine. If your browser is on another
machine, reach the daemon through a local forward such as `ssh -L`, or through
a TLS proxy.

### Stay signed in for 30 days

When you open the home page with `loom ui`, Loom also signs that browser in
for 30 days. The sign-in is not extended when you use it.

To come back without running `loom` again, click your name in the top bar. The
panel that opens shows an address to bookmark. Opening that bookmark gives you
a home page again for up to 8 hours.

If you do not want the browser signed in, add `--no-remember`:

```bash
loom ui --no-remember --open
```

Clearing the browser's site data, or using a private window, loses the sign-in
on that browser. Run `loom ui` again.

### A bookmarked home can do less

A home page opened from the bookmark cannot make new access. It has no Admin
button, no "Sign in another device", and no Stop, Archive or Delete on a
session. The reason is that a bookmark is meant to live a long time, and
anything that grants access or destroys history should need a fresh
`loom ui`. The panel says so at the bottom: "This page was opened from a
bookmark. Run loom ui for a page that can manage sessions and people."

You can still create sessions, rename sessions, and rename yourself from a
bookmarked home.

### Sign in another device

On a home opened by `loom ui` (not from a bookmark), open the panel under your
name and press **Sign in another device**. It shows a link. Open the link on
the other device within 10 minutes. It works once, and signs that device in for
the time your own sign-in has left. It counts as one of your three grants an
hour (see [section 4](#4-invite-someone)).

### Sign out

In the same panel, each signed-in browser has a **Sign out** button, and
**Sign out everywhere** ends all of them. The row marked "This browser" is
the one you are using.

## 2. Your home page

The home lists every session you can see, grouped under its workspace. Each
row shows the session's name and a quiet line under it:

- `idle`, `working`, or `needs you` for a running session. A session that is
  running but has not reported what it is doing says `running`.
- `saved` for a session on disk that is not running.
- Your role, for sessions someone else owns (for example `idle · observer`).

Press a running session to open its page. Press a saved session to resume it.
You can resume a saved session only as its owner or as an operator. An
observer sees the row as plain text and is told to ask an operator.

### Search

Press Command-K (Control-K on Linux and Windows), or press the **Search**
chip in the top bar. Type part of a session's name or workspace, then press
Enter. The same box also goes to Home or Admin.

### Create a session

If you are the owner, each workspace heading has a **New session** button.
It opens a small form:

- A name, optional. Left blank, the session is named after the workspace's
  folder.
- A **Shareable** box. Tick it if you may want to invite people to this
  session. [Section 3](#3-private-and-shareable-sessions) explains it.

Press **Create session**. The new session opens. You can create ten sessions
an hour from one sign-in.

You can only create a session in a workspace you already have a session in.
The page never asks for a path.

### Rename, stop, archive, delete

These are owner actions, on the buttons at the right of a row.

- **Rename** works on any row.
- **Stop** appears on a running row. If the session is working or needs you,
  Stop asks you to confirm.
- **Archive** and **Delete** appear on a saved row. Archive takes the session
  out of the list. You can undo it from a terminal: open the session picker with `/sessions`, press `a` to show archived sessions, and press Enter on the session to restore it. Delete asks "Delete this
  session? This cannot be undone." and then removes it.

A running session offers no Archive or Delete. Stop it first. Stop, Archive
and Delete need a home opened with `loom ui`, not from a bookmark.

## 3. Private and shareable sessions

Every session is one of two kinds. The home and the admin page use these
words.

**Private** is the default for a session made from the terminal, and for a
session made on the web without the Shareable box. A private session shares
the workspace's notes, memory and history with your other sessions in the
same workspace. That is useful for you. It is the reason the session cannot
be shared: an invitee would see that shared layer, which holds material from
sessions they were never invited to.

**Shareable** is a session that keeps its own notes, memory and history. It
shares none of them with the rest of the workspace, so it can be shared
safely. The cost is that, from then on, the session no longer gets the
workspace's shared notes and memory. It starts with its own empty set.

You can invite people only to a shareable session. If you try a private one,
the page says: "Private session: it shares the workspace's notes and history,
so it cannot be shared. Sessions created with Shareable can be."

### Make a new session shareable

Tick **Shareable** when you create it, as in section 2. Or, from a terminal,
create it as you normally would and then make it shareable as below.

### Make an existing session shareable

A "Make shareable" button on the admin page and on the session's Session tab
is coming. It is not in this release. Until then, use the terminal. Stop the
session first, then:

```bash
loomd access isolate SESSION_ID --share-existing-transcript
```

Then resume the session by pressing its row on the home. You can find the
session id with `loom sessions list`.

Read the flag's name carefully. It gives the session its own notes and memory
from now on, but it keeps the transcript the session already has. That
transcript may include things the agent recalled from your private notes
earlier. Anyone you invite later will see all of it. The flag is your
statement that you are willing to share that history.

## 4. Invite someone

Do this on a **fresh** home, one you opened with `loom ui`. A home opened from
a bookmark has no Admin button, because a bookmark cannot make new access.

1. On the home, press **Admin**.
2. In **Sessions**, press the session you want to share. Its row says how many
   people hold it, and whether it is shareable or private. Under it, **Members
   of** that session appear.
3. In the invitation form, optionally type the person's name, and choose a
   role:
   - **Observer: can follow.** They watch. They send nothing.
   - **Operator: can send and approve.** They send prompts and steer the
     agent, and they answer approval requests.
4. Press **Create invitation**.

If the session is private, there is no form, only the sentence from section 3.

The page now shows the invitation once, in boxes you can copy:

- **Claim address**: a page the invitee opens in a browser to join. It ends
  in `/ui/claim`.
- **Claim token**: the secret, starting with `loomclaim_`.
- **Command**: for an invitee who has `loom` installed and would rather join
  from a terminal.

The token is shown only here. Copy it now. If you lose it, rotate it (see
[section 6](#6-see-who-has-access-and-remove-it)).

The token is good for **60 minutes** and works **once**.

Send the address and the token to the person by some channel outside Loom:
email, chat, a phone call. Never paste them into a Loom session. Anything sent
into a session becomes part of its transcript, the agent can read it, and the
agent could use the token before the invitee does.

The address is built from the host you used to reach the admin page. If you
reached it as `localhost`, the address says `localhost` and means nothing to
your colleague. Reach the page through the address your colleague will use, or
give them the correct host yourself.

### The grant allowance

One sign-in may make **3 grants an hour**. These count as grants: an
invitation, a rotation, raising a member to operator, and "Sign in another
device". Lowering a role, removing a person, and revoking cost nothing. The
count is for your sign-in, not for the page, so opening another page does not
reset it.

When you reach the limit the page says, for example: "3 grants in the last
hour is the most a credential may make. The next is free at 14:25. Until then,
use loomd access from a terminal." The time is shown in your own time zone.

### Invite from the session page

If you are on a session's page and you are the owner, open the **Session**
tab. Under **People**, **Invite to this session** has two buttons, **Invite an
observer** and **Invite an operator**. They make the same kind of invitation,
valid for 60 minutes, and show the same boxes. You cannot choose a name here.
The invitee chooses theirs when they join. **Hide the token** clears the boxes
once you have copied them.

This control shares the same 3-an-hour allowance.

### Invite from a terminal

The terminal has no allowance, and gives a longer lifetime by default (24
hours):

```bash
loomd access invite SESSION_ID alice operator "Alice" \
  --claim-addr wss://loom.example.com/v2/control
```

The arguments are the session, an id for the person (`alice`), the role
(`operator` or `observer`) and their display name. `--ttl 30m` (or `7d` and so
on) sets the lifetime. The command prints one line of JSON with the `claim`
token and a `claim_command` that names the address but not the token. Send both
over a channel outside Loom.

## 5. Join as the invitee

You were sent a claim token and an address.

1. Open the address, which ends in `/ui/claim`, in your browser.
2. Paste the token into **Claim token**.
3. Type the name others should see in **Your name**. Leave it empty to keep the
   name the owner chose.
4. Press **Accept**.

You are signed in on that browser for 30 days and land on your home. It lists
only the sessions you were invited to, and each row ends with your role on it,
such as `idle · operator`. An observer sees the page for a session and can
follow it. An operator can also send prompts and answer approvals. You do not
get the Admin button, New session, or Stop, Archive and Delete.

Open the panel under your name and bookmark the address shown, so you can
return without a new invitation.

Each token works once. If you lose the page after pressing Accept, before it
finished loading, the token is already used. Ask the owner for a new
invitation.

### If you have `loom` installed

You can join from a terminal instead:

```bash
loom claim --addr wss://loom.example.com/v2/control
```

It asks for the token and `--name "Your Name"` sets your name. It keeps a
credential in `~/.loom/remotes/` and prints the sessions you were granted with
a `loom --addr ... --session ...` line to open one. It also prints a
fingerprint; read it to the owner over a second channel so they can confirm
the right person joined. A claim made in the browser gives a browser sign-in
only. It does not let you use `loom` in a terminal.

### Rename yourself

Click your name in the top bar. At the top of the panel is **Your name**. Type
a new name and submit. Other people see the new name the next time their page
reads it.

## 6. See who has access, and remove it

Open **Admin** from a fresh home (section 4). The page lasts **15 minutes**.
A pill in the bar counts down ("ends in 14m"). When it ends, press **Admin** on
the home for another page. **Home** at the right of the bar takes you back to
the home you came from; press **Admin** there for another page. If that home
has ended too, run `loom ui` for a new one.

### People

**People** lists everyone Loom knows, with a count and how many are invited.
Each row says what the person can sign in with:

- `active · key ABCD… · joined 3 days ago`: they claimed their invitation.
- `invited · claim open, 42 min left`: the token was made and not yet used.
- `invitation expired`: nobody used it in time.
- `no credential`: they have none now.

Under a person who has browser sign-ins you see a **Sign-ins** list, with when
each was made, whether it came from a device link, and when it ends.

The buttons on a person's row:

- **Rename** changes the name shown for them. It costs no grant.
- **Rotate** voids their current credential or token and makes a new
  invitation for them. Use it if a token was lost or leaked, or if the wrong
  person used it. It costs one grant.
- **Revoke access** ends all of their credentials, browser sign-ins included.
  They can no longer sign in. Open pages close at their next update. A command
  they had already sent is not cancelled.
- **Void invitation** replaces Revoke access on a person who has not claimed
  yet, and ends the open token.
- **Revoke sign-in**, on one sign-in, ends only that browser.

Revoke and Void ask first: the first press arms the button, and a second
confirms.

### Sessions

Press a session under **Sessions** to see **Members of** it. Each member shows
their role and has:

- **Make operator** or **Make observer**, which moves them to the other role.
  Making someone an operator costs one grant. Lowering costs none.
- **Remove**, which takes them out of this session only. They keep any other
  session they hold.

"Nobody but the owner holds this session" means the session has no members.

### From a terminal

```bash
loom access list                          # everyone, one JSON line each
loom access show alice                    # every session alice can reach
loom access members SESSION_ID            # who holds one session
loom access signins alice                 # alice's browser sign-ins
loomd access set-role SESSION_ID alice observer
loomd access revoke SESSION_ID alice      # remove from one session
loomd access rotate alice                 # new token, old one voided
loomd access revoke-credentials alice     # end all of alice's credentials
loomd access revoke-login alice FINGERPRINT
```

`loom access` and `loomd access` take the same commands. `loom access` can
also reach a daemon on another host with `--addr` and `--token-file`; see
[Running Loom](../running.md).

## 7. A read-only link for someone who only watches

To let a person watch one session without making an account for them, make a
read-only link:

```bash
loom ui --session SESSION_ID
```

Without `--operate`, the link is for an observer. Send it to the person. It
works once, within 60 seconds, in one browser tab, and the page it opens lasts
up to 8 hours. Run the command again for another person or another page.

Be aware of what this is. The page runs as your own account, with the role
capped at observer. It does not create a member, it is not listed on the admin
page, and it does not sign their browser in. Anything that ends your access
also ends it. Each of your pages for one session counts toward a limit of four
at a time, and a fifth ends the oldest. For anything longer-lived, or for
anyone you want to see by name, invite them instead.

## 8. When something goes wrong

**"This link has expired or was already used."** A `loom ui` link works once,
within 60 seconds. Press **Go back** on that page if the page you used it for
is still in your history. Otherwise run `loom ui` again.

**There is no Admin button.** The home was opened from a bookmark, or the
person is not the owner. Run `loom ui --open` and use that home.

**"Private session: it shares the workspace's notes and history, so it cannot
be shared."** Make the session shareable (section 3).

**"This session is not shared yet. Stop it, isolate its transcript from a
terminal with loomd access isolate, and resume it."** The same cause, shown
when you press an invite button on a private session.

**"... grants in the last hour is the most a credential may make."** You used
the hour's three grants. Wait for the time shown, or use `loomd access invite`
from a terminal.

**"This claim has expired."** The invitee waited more than 60 minutes (24
hours from a terminal). Make a new invitation.

**"This claim has already been used."** Someone redeemed it, or the person
already holds a credential. If it was not the invitee, rotate the person on
the admin page.

**"That name cannot be used."** A name is not blank, is at most 256 bytes,
and holds no control characters. Nothing was claimed, so try again.

**"This page has ended."** A page lasts at most 8 hours, and ends sooner if the
daemon restarted or someone opened too many pages. Open a new one.

**"Your access to this session was revoked or changed."** The owner removed
you, changed your role, or revoked your credentials. Ask the owner.

**"This browser is not signed in."** Your sign-in ended, was signed out, or
does not match this browser (cleared storage, a private window, a different
profile). Run `loom ui`, or, if you were invited, ask for a new invitation and
accept it at `/ui/claim`.

## Further reading

- [Running Loom](../running.md) has the command-line details, including the
  remote administration options and the daemon settings.
- [Several operators on one session](../architecture/multiplayer.md) explains
  how identity, roles, invitations and claims work.
- [Protocol change 065](../../protocol-change/065-web-workspace-mode.md)
  records how the home page, browser sign-in, browser claim and admin page
  were designed.
