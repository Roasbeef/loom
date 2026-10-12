# Terminal and web view

Loom has two interfaces, and both are clients of the same daemon. The terminal client `loom` is a native program. The web view is a page that `loomd` serves from the same process. A prompt typed in one appears in the other, and an approval answered in either settles the question in both.

## The terminal

```sh
cd ~/src/my-project
loom
```

`loom` finds the shared local daemon and authenticates to it, or starts `loomd` after checking that it can claim the private endpoint. It then shows the session picker. The daemon is shared across workspaces, so several terminals can attach to the same session or work in independent ones. A terminal never loads a workspace's configuration implicitly, and it never runs the server from the workspace, because repository content is not launch authority.

Useful launch options are `--workspace`, `--session <id>`, `--state-dir`, `--config <loom.toml>` and `--model-profile <name>`. An explicit `--session` opens that saved session without the picker. `loom --demo` draws a canned preview with no daemon and no network.

### The composer

Type and press Enter to send. On a busy strand, Enter sends a `prompt`, which the daemon holds and runs after the current operation. Tab switches the draft to a `steer`, which goes to the front of the queue and stops the observed operation. Escape interrupts current work, and the daemon keeps your queued turns. A large paste becomes a compact attachment chip and is expanded only when sent. A pasted path to a PNG, JPEG, GIF or WebP file of up to 20 MiB becomes an image attachment, up to four per prompt.

Typing `/` opens a palette of commands. These are the ones you will use first:

| Command | What it does |
|---|---|
| `/sessions` | Return to the session picker. On a resident session, `l` links it to the attached strand. |
| `/model` | Choose another model from your catalogue for the active strand. |
| `/profile <name>` | Switch the session to a model profile. |
| `/diff` | Show a Git view of the session's changes. |
| `/agents` or F2 | Show every strand, one row each, with their activity and messages. |
| `/notes` | Show the session's notes. |
| `/queue` or Alt+q | Inspect and edit queued input. |
| `/summary` | Show completion evidence, usage and live jobs. |
| `/context` | Show how the context window is spent. |
| `/goal` | Show or set a pinned goal, when an advisor is configured. |
| `/approvals` | Reopen a pending approval. |
| `/access` | Show who can reach the daemon. The owner only. |
| `/add-dir PATH`, `/add-write-dir PATH` | Add a directory to the running session. |

### Approvals

When a call needs more access, the terminal opens a dialog with the exact action, the requesting strand and the exact grants. No choice is preselected. Choose allow once, allow for the session, or deny. The [approvals page](#/docs/approvals-and-sandboxing) explains what each one authorizes.

### Reconnecting and remote daemons

A local terminal holds two WebSocket connections to the daemon: one for control, which lists and manages sessions, and one for the conversation. If the conversation socket closes, the terminal makes one automatic attempt to find or relaunch the daemon and reattach the same session. If that fails, it says so and points you at `/sessions`. The terminal never resends a command whose reply was lost. It keeps a notice that names the command instead, because it cannot know whether the daemon admitted it.

To attach to a daemon on another machine, carry the connection through a secure tunnel or a TLS proxy and use a credential authorized for that session. A terminal attached this way does not reconnect on its own.

```sh
loom --addr wss://loom.example.com/v2/control \
  --token-file ~/.loom/remotes/loom.example.com/credential --session SESSION_ID
```

The daemon itself binds only to loopback.

## The web view

The web view is off by default. Turn it on with `loomd --ui`, or with `ui = true` under `[daemon]` in `loom.toml`. Then ask for a link:

```sh
loom ui --open                          # your home page, which lists your sessions
loom ui --session SESSION_ID --operate --open   # one session, as an operator
```

If no daemon is running, `loom ui` starts one with the view enabled. If a running daemon has it disabled, `loom ui` says so and exits, because it never restarts a daemon that other people may be using.

Each link works once, within 60 seconds, and only in the browser tab that opens it. A page is an observer's unless you pass `--operate`, and even an operator page never carries more than operator authority. Opening your home page signs that browser in for 30 days, and `--no-remember` skips the sign-in.

The browser runs only Lustre's small client runtime. The page itself is a Lustre server component that runs inside the daemon and drives the same session lane and transcript projection as the terminal. No credential, session state or session logic reaches the browser.

### What the page shows

The home page lists your sessions grouped by workspace, with a line under each: `idle`, `working`, `needs you`, or `saved`. As the owner you can create sessions, stop a running one, rename, archive or delete saved ones, and open the admin page to manage member roles and revoke credentials.

Inside a session, the page shows a live transcript with collapsible tool steps and diffs, strand inspection, and an advisor commentary rail. Operators can steer runs, address a specific subagent from the composer, and answer approval cards.

## Sharing a session

The owner invites people to a session in one of two roles:

- An **operator** can send prompts, steer the agent and answer approval requests. An operator's page offers allow once and deny, and never allow for the session.
- An **observer** can follow the session and send nothing.

Neither role can stop the daemon, see a session they were not invited to, or reach another workspace. A session must be shareable first. The owner can tick a box when creating it, or run `loomd access isolate SESSION --share-existing-transcript` for an existing one.

```sh
loomd access invite SESSION_ID alice operator Alice \
  --claim-addr wss://loom.example.com/v2/control
```

The command prints one line of JSON with a single-use `claim` token that starts with `loomclaim_`. Send the token to the invitee over a channel outside Loom. The invitee redeems it:

```sh
loom claim --addr wss://loom.example.com/v2/control
```

Invitees without `loom` installed can redeem a claim in a browser at `/ui/claim` on the daemon. After a claim is redeemed, compare the credential's fingerprint with the invitee over a second channel before you rely on the new member. `loom access list` and `loom access show <name>` show who holds access.

A browser on another machine reaches the daemon through a tunnel such as `ssh -L`. The daemon never listens on anything but loopback.

## Read more

- [`docs/guide/multiplayer.md`](https://github.com/Roasbeef/loom/blob/main/docs/guide/multiplayer.md): a step-by-step guide to working with other people.
- [`docs/architecture/terminal.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/terminal.md): how the terminal client is built.
- [`docs/architecture/web-view.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/web-view.md): the routes, authentication and security layers.
- [`docs/architecture/multiplayer.md`](https://github.com/Roasbeef/loom/blob/main/docs/architecture/multiplayer.md): access, roles and ordering.
