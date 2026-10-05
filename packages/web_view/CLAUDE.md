# web_view

## Purpose

The web view's host and view for one session: two Lustre server components
that drive `session_view`'s lane and draw the session's transcript lines as
HTML, and the documents served around them (the page shell, the ticket
exchange's hand-off page and the content security policy). What the page
loads besides Lustre's server-component runtime is in `priv/static/`, which
a release carries like any application's `priv`: the client components'
bundle, the Tailwind stylesheet and the two bootstrap scripts, all built
from `packages/web_client` by `make gen-client` and gated by `make
client-check`. It is phase 4 of issue #530: the same engine the terminal
runs, under a second host, with only the view differing
([ADR-014](../../docs/adr/014-second-runtime.md)).

The daemon serves it only when started with `loomd --ui`
([protocol-change/051](../../protocol-change/051-web-view-route.md)). The
package knows nothing of the daemon: the transport the lane writes through
is handed in by `packages/client`, which owns the routes, the tickets, the
page keys and nonces, and the relay into the session's gateway.

## Key Types

- `component.Start(socket)`: what the daemon supplies when it starts a
  component: the session ID, the catalogue's `Label(name, workspace)` for
  the heading (or `None`, which only tests pass), `workspace_digest` (the
  lower-case SHA-256 of the workspace path in hex, which the daemon computes
  in `client/daemon/ui_socket`, or an empty string; the frame writes it as
  the `workspace` attribute and `<loom-shell>` keys the reader's layout by it),
  the `snapshot.Expected` attachment every cut
  must match, a `Standing` (`reader`: `DaemonOwner` or `Participant`, so an
  observer-ceiling page the owner opened can be told to run `loom ui`; and
  `sharing`, the catalogue's scope for an owner's page, so a private session
  draws `invites.Unshareable`'s one sentence and no invitation button; the
  daemon reads it with the members read the admin page makes, no new frame;
  and `opening`, `FromBookmark` for an owner's page a bookmark opened, which is
  handed neither invitation nor make-shareable capability and draws
  `invites.Bookmarked`'s sentence; `component.unplaced` for fixtures), and a `Transport(socket)`. The heading shows the name (or
  `Session` and the ID's first eight characters) with the whole ID in a
  `title`, and the workspace's last segment with the whole path in a
  `title`.
- `component.Transport(socket)`: `connect(inbox, opened)`, which returns at
  once and answers on `opened`; `transmit(socket, frame)`; `shut(socket)`;
  `now()`, `sessions()`, the sidebar's read of the principal's sessions
  (the daemon's authorized catalogue read, `[]` on failure), and
  `open(id)`, a request to open another session that answers a
  `sessions.Answer` (a ticket's exchange path, or a `Declined` reason; an
  observer's page is always declined), and `invite`, an `Option` of a request
  to invite a person to the page's session in an `invites.Role` that answers
  an `invites.Answer`. `invite` is `Some` only on an owner's operator page
  (`ui_socket.Owning`), and so is `shareable`, an `Option` of a request that
  stops, isolates and resumes the page's private session as one task
  (protocol-change/065, the addendum on making a session shareable): it returns
  at once and its `grants.Answer` arrives as `MadeShareable`. The control's state
  is `shareables.Move` in `View.moving`, set only by `component.arm_shareable`,
  `disarm_shareable` and `make_shareable`, which sends the task only from
  `Confirming`. `home` is an `Option` of a request for a ticket to the
  principal's home (a `sessions.Answer` again, declined as `NoHome`); it is
  `Some` only on a page whose grant has `Workspace` reach, an observer's
  included, and the page draws the "Home" button only then. All run in the
  component's process.
- `component.Msg(socket)`: `Opened`, `Refused`, `TimerArmed`, `Arrived`
  (a batch of up to `arrival_batch` frames, reduced at once), `Ticked`
  (the deadline timer fired), `OlderRequested` (the "Load older" button, a
  read), `FocusRequested(strand)` (a strip chip, a change of what the page
  shows), `GoingHome` (the "Home" button, which carries nothing; the answer
  is `Homed(answer)`), `SessionsListed(entries)` (the sidebar read's own
  answer) and `Linked(answer)` (the daemon's answer to a request to open a
  session), `Homed(answer)` (to go home) and `Invited(answer)` (to invite),
  all four dispatched by an effect and carried by no handler. It holds no
  command. `component.older_path`, `component.home_path` (`0\t0\t1`, the
  Home button, the top bar's second child) and `component.strip_path` are the
  Lustre event paths the socket admits an observer's click at: the button,
  the Home button, and anything beneath the strip's chip list. The top bar
  always has that second child (`element.none()` without the capability), so
  the children after it keep their places; `component.switch(model)` is the
  hidden `<loom-switch>` both pages draw as the centre's last child (the
  observer's only with the capability). `component.sidebar_path` is where an
  operator page's session buttons are, and the observer's socket admits no
  click beneath it. `component.invite_path` (`0\t3\t2\t2`) is the invitation
  control's region in the Session pane, and only an owner's socket admits a
  click at or beneath it. `component.rename_path` (`0\t3\t2\t4`) is the
  rename control's, the pane's fifth child, admitted the same way and for a
  submit as well (protocol-change/067).
- **Subtitle and rename.** `sessions.Entry.subtitle` is the first line of the
  session's first prompt, which the daemon derived once. It is a person's own
  prompt, so the sidebar (`session-text` wrapping `session-name` and
  `session-subtitle`) and the home row (`home-subtitle`, leading the quiet
  line in place of the age) draw it as a text node and nothing else.
  `web_view/renames` holds the rename vocabulary (`Answer`, `Reason` with fixed
  words, the page's `Control`). The session page's control is
  `view/rename`, driven by `component.renaming` and `Transport.rename`, which
  returns at once and answers as `Renamed`; the daemon names the session and the
  principal and the page sends only the typed text. The home draws a Rename
  button after each row's own button when `Start.rename` is `Some`, and one open
  form in place of a row (`home_table.Rename`, `home.Edit`); a submit asks only
  for the row whose form is open. Neither control puts the current name in an
  attribute: the field is drawn by `rename.field()` inside a `<loom-rename>`
  (`web_client`), which copies the lead's text node (`rename.name_marker`, within
  `rename.scope_marker`) into the empty field in the browser. A home row's quiet
  line draws the activity word in its own `home-activity` span, the only part a
  needs-you row tints, and the create form's Shareable label is one word with a
  hint line beneath it.
- **Strand focus.** `component.focus(model, strand)` (`FocusRequested`) is
  `step.focus`, the shared step's change of strand, plus what only this host
  holds: the history read owed for the strand being left is dropped
  (`history_view.resume`) before its window parks, and paging starts again
  at `Tail`. The strand must be listed, must not be the active one, and the
  page must be `Connected`; otherwise nothing changes. Every derived input
  (`Projected.strand`, `Stripped.followed`) includes the active strand, so
  the projection and the strip are rebuilt by `refreshed`. `component.strand(model)`
  is the active strand and `component.primary` (`"main"`) is where a page
  starts. Prompts, steers, queues, interrupts and commands address it because
  the shared step's commands read `active_strand`. A prompt the daemon hands
  back for any strand of the session is kept, and the notice names the
  strand it was held for when that is not the one on screen.
- **The home page** (protocol-change/065). `web_view/home` is a server
  component bound to no session: `Start(name, ceiling, refresh_ms, sessions,
  open, resume)` with `sessions: fn() -> Listing` (`Listed(entries) | Unread |
  Closed(ending)`), read when the timer is wired and every `refresh_ms`
  (`home.refresh_ms`, 30 s), in the component's process. `Closed` ends the page
  (`Status`: `Connecting | Connected | Ended`) and stops the reads; `Unread`
  keeps the last list. The view is `shell.view(shell.Home, ...)`:
  `view/home_bar`, `sidebar.home(groups, open, resume)` (a "Home" entry, then the rows),
  `view/home_table` (a list per workspace: a heading with the shortened path
  and a count, and one item per session with a glyph, the name, and a quiet
  line of `working · created 2h ago` (`running` until the activity read answers; the
  word `resident` is not drawn) or `saved · 2h ago`; the UTC
  minute is the `time`'s `title`; `home_bar` draws the session bar's `pill`
  and `Tone`) and no panel; the stylesheet hides the panel column for the
  frame class `loom-home`. `view/switch.view(address)` draws the hidden
  `<loom-switch>` for both this page and the session page. The one input is a running session's row, in the
  table and in the sidebar: `home.Opening(id)` asks `Start.open` (in the
  component's process) for a ticket, and `Linked(answer)` becomes the `to`
  attribute of the centre's last child, a hidden `<loom-switch>`, or a refusal
  `home_table.Note` beside the row. The centre's first child is an empty node, so
  the table keeps its path; what the page says about a press is a `Note`
  (`view/notice` `Said` fades, `Refused` stays) drawn in the row it is about, in
  its workspace's heading when the row is gone, or under `Sessions`, and it
  never moves the list. `Model.opening` (a running row's open) and
  `Model.resuming` set the row's `Opening…` state and ignore a second press. `home.table_path` and `home.sidebar_path` are the two regions the
  daemon's socket admits a click beneath. A saved row is a button only on an
  `OperatorCeiling` page (`view/resume`): `home.Resuming(id)` calls
  `Start.resume(id, deliver)`, which starts the daemon's task and returns, sets
  `resuming` and draws the row "opening"; `deliver` dispatches `Linked` from
  the task. A second press, an observer ceiling and an ended page ask nothing.
  The owner's operator page also has `Start.create` (protocol-change/065, the
  fourth addendum): `Some` only for the owner at operator ceiling, and then
  `view/create` draws a "New session" button in each workspace head and the form
  (`name`, `shareable`) under the chosen one. `home.Choosing(workspace)` opens it
  (`create.Composing`), `home.Creating(workspace, name, sharing)` asks
  `Start.create(workspace, name, sharing, deliver)` and sets `create.Waiting`, and
  `Created(answer)` departs (a `creations.Ticketed` path into `departure`) or
  words the refusal (`creations.reason_words`). Only the open form's submit asks,
  and only once. `web_view/creations` holds `Sharing`, `Answer`, `Reason`,
  `chosen_name` (the one rule for a name) and `folder`. The submit's event is
  beneath `table_path`, a path the owner's socket admits and no other's.
  Every list that answers also starts `Start.activity(ids, deliver)` for the
  running sessions it lists (at most `home.activity_limit`, 24): it returns
  at once, the daemon asks the sessions in a task of its own, and the answer is
  `Observed(rows)`, one `sessions.Activity` (`NeedsYou | Working | Idle`) per
  session that answered, which the rows draw as words and a glyph hue; a row
  with none says only `running`. `Start.now` is the clock the ages count from,
  read once per list. `ending.Advice` (`lead`, `command`) is the ending's
  advice split, `advised`/`home_advised`; `advice` is it said as a sentence.
  `ending.home_headline` and
  `home_advice`, `ended.home`, `page.home_shell`, `home_path`,
  `home_exchange_path`, `home_refusal` word and address it. `home_test` reads
  all of it.
  The home's sign-ins (protocol-change/065, PR 8): `web_view/signins` holds
  `Signin` (fingerprint, issued, last resumed, expires, issued by), `Listing`,
  `Answer` (`Revoked | Linked(address) | Declined(reason)`) and the fixed words
  of each `Reason`. `Start` gains `signins`, `login` (the fingerprint of the login
  this page belongs to), `bookmark`, `sign_out`, `sign_out_all` and `device`
  (`Some` only for a fresh home). `view/signins` draws the region as the centre's
  third child, beneath `home.signins_path` (`0\t2\t2`), which is the account
  panel: it carries `data-popover="panel"`, the stylesheet floats it under the bar
  and hides it, and the bar's name (`home_bar.account`: a button marked
  `data-popover="toggle"` inside `<loom-popover wanted=...>`, whose `wanted` is
  `open` while a device link is on show) opens it with no server state. The panel
  holds a row for each login ("This browser" for the page's own) with "Sign out",
  "Sign out everywhere", the bookmark in `<loom-copy subject="bookmark">` for a
  remembered login, and on a fresh home "Sign in another device", whose link is
  shown once in `<loom-copy subject="device">` and hidden by "Done". The bar
  says nothing beside the name for an operator-ceiling page and `read-only link`
  for an observer-ceiling one (`home.ceiling_words`); `home_bar.ending` (the admin
  page's) draws the name and the lifetime pill. `sessions.Entry.role` is the principal's
  membership role in that session (`Operates | Observes`, none for the owner),
  filled by `ui_socket.with_roles` from `manager.authorized_roles`, and a row's
  quiet line ends with it. `sidebar.home` takes the activity answers, so a
  running row's sidebar word is the list's (`needs you` in the signal hue).
  `ends_in` rounds up, so a fresh sign-in reads `ends in 30d`. The list is read with each sessions read (and again after a
  sign-out); a press names the fingerprint the server drew. `page` also holds
  the resume page (`login_page`, `login_refused`), the exchange page that carries
  the login's key and nonce (`enter_remembered`), `login_prefix`,
  `login_home_path` and the `Forms` policy choice (`content_security_policy_for`;
  only the resume page and the claim form are `OwnForms`). The claim form
  (PR 9) is `claim_page(notice)`: two fields, no script, posting to
  `claim_path`, with the words for the name field and, after a refusal, one
  fixed paragraph from `claim_notice(ClaimNotice)`. `signins_test` and `page_test` read it. The admin page also lists each
  principal's sign-ins (`grants.Logins`, `Snapshot.logins`) beneath its row in
  `view/admin_people`, with the home's `view/signins.history` words and a
  two-step `grants.RevokeSignin`; `admin.Start.login` marks "This browser".

- **Renaming** (protocol-change/065, the tenth addendum). `web_view/names` holds
  the home's `Answer` (`Renamed(name) | Declined(reason)`), `Reason`
  (`NotAllowed | InvalidName | Unavailable`), `Control` and the fixed words.
  `Start` gains `who` (reads the principal's name with each list) and
  `rename_self` (`Some` for a page minted to operate); `Model` gains `name`,
  `naming` and `named`, and `Msg` gains `NameRead`, `NameSubmitted` and
  `NameAnswered`. `view/your_name` draws the "Your name" region as the account
  panel's first child (a text-node lead, `<loom-rename>`, one submit, keyed by
  `named`), and `view/signins.view` takes it as its last argument. The submit is
  beneath `home.signins_path`, which the socket now admits for a submit as well as a
  click. On the admin page `grants.Action` gains `Rename(principal, name)`,
  `admin.Model` gains `editing`, `Msg` gains `Editing` and `EditCancelled`, and
  `view/admin_people` draws a Rename button on every row and, for the open one, an
  in-row form as the row's last child; `view/admin_buttons.Presses` carries the
  three new messages. Names are text nodes only.

- **The owner's admin page** (protocol-change/065, the fifth addendum).
  `web_view/admin` is a server component in the home's frame
  (`shell.view(shell.Home, ..., shell.Unlisted, ...)`, `home_bar.with(title:
  "Admin", ...)`) with `Start(name, refresh_ms, read, act, now)`. `read(chosen,
  deliver)` and `act(action, deliver)` each start the daemon's task and return at
  once; their answers arrive as `Answered(serial, reading)` and `Acted(answer)`,
  effect-owned messages no handler carries. A read is a `grants.Reading`
  (`Read(Snapshot) | Unread | Closed(ending)`), numbered so an answer that was
  overtaken is dropped, and also the page's check that it may still be served
  (`Closed` ends it, `Unread` keeps the snapshot). The model holds one ask at a
  time (`waiting`), the armed revocation (`armed`, at most one), the chosen
  session, the last notice (a `notice.Spoken`: the action with its `Said` or
  `Refused` words, which decide where the line is drawn) and the claim an ask
  made (`claim`) until `Dismissed`. The claim is drawn beside the action that
  made it, never sticky (it opens with an empty `<loom-reveal>` that scrolls the
  box into view once): under the invitation form (`admin_claim.for_session`) or
  under the rotated person's row (`for_person`), each one fixed child of its
  parent so no path moves. The centre's first child is an empty place, so the
  body stays at `admin.body_path`. The invitation form is keyed by `Model.invited`
  (how many invitations were made), so each one opens it with an empty name field;
  `Snapshot.summaries` (`grants.Summary`: people, `more`, scope, read for every
  listed session by `ui_socket.admin_summaries`) is the line after each session's
  path (`grants.summary_words`). A `TooMany` refusal is `notice.Throttled`, whose
  time is a `<loom-time at=ms>` the browser words in its own zone, UTC in its
  `title` and light text. After a `TooMany` refusal the model keeps when a place frees
  (`Model.spent`), and until then `admin_buttons.Busy` is `Spent(words)`: the
  buttons that grant (`admin_buttons.granting`: Rotate, Make operator, Create
  invitation) carry the refusal's words in their `title` and still send, since
  the daemon decides.
  `Choosing(id)` reads that session's members; `Asking(action)` asks;
  `Arming(action)`/`Disarming` are a revocation's two presses. `web_view/grants`
  is the vocabulary: `Principal`, `Credential`, `Holder`, `Snapshot`, `Reading`,
  the `Action`s (`Invite`, `SetRole`, `RevokeMembership`, `RevokeCredentials`,
  `Rotate`, `RevokeSignin`, `Rename`, and `MakeShareable`, which `admin.update`
  sends only from the question its own button armed (`admin.confirmed`)), `Claim` (with `page`, the browser claim address), `Answer`
  (`Claimed | Changed | Declined`) and `Reason` with `reason_words` and
  `changed_words`; `TooMany(used, free_at_ms)` words the count and the UTC time
  the allowance frees, and `Selection.scope` (`creations.Sharing`) is the `scope`
  of the members read. `grants.short_identity` draws an identity as its prefix and
  eight characters. The views are `view/admin_people` (each person once, an open
  claim in its row, buttons by what the person holds), `view/admin_sessions` (the
  session chooser, a chosen session's members and the invitation form, whose
  `fields` is the one rule for what it may hold, or one sentence for a private
  session), `view/admin_claim` (the claim, once, via `share.handover`: the browser
  address, the token, then the `loom claim` command), `view/notice` (`Said` and
  `Refused` lines, placed beside what was acted on; the home adopts it later) and
  `view/admin_buttons` (`Busy`, `Presses`, the
  two-step `guarded` button). The body (`admin.body_path`, `"0\t2\t1"`) is the
  one region the socket admits an event beneath. The home's `Start.admin`
  (`Some` only for the owner's fresh operating home) draws `home_bar.admin`, the
  bar's last child (`home.admin_path`, `"0\t0\t5"`); `home.AdminRequested` asks
  the daemon's task, `AdminLinked` departs through the hidden `<loom-switch>`.
  `ending.admin_headline`/`admin_advised`/`admin_advice`, `ended.admin`,
  `page.admin_shell`/`admin_refusal`/`admin_path`/`admin_exchange_path` and
  `sessions.NoAdmin` word and address it. `admin_test`, `home_test`, `page_test`,
  `ending_test` and `grants_test` read all of it.
- **The session sidebar.** `web_view/sessions` holds `Entry`, `Residency`
  (`Live | Saved | Blocked`; `Blocked` is a saved row no page may resume),
  `Group` and `grouped(entries, current)` (the current
  session's workspace first, then by newest session, sessions newest first,
  ties by identity and path). `view/resume` is the one rule for a saved row
  (`Never | Offered(press, pending)`, `kind` giving `Text | Button | Opening`),
  shared by the sidebar and the home's table. `view/sidebar.view(groups, current, bars, open, resume)`
  draws it as the frame's second child (`aside.sidebar`, the left column;
  `element.none()` where a page draws none), memoized on the groups, the
  identity and the bars. `bars` is `sidebar.bars(component.strip(model))`: one
  `Bar(hue, pulse)` per listed strand and the advisor, drawn only on the
  current row as `span.dots > span.bar.hue-N[.w]` (decoration, `aria-hidden`,
  no handler). A `nav()` child, `element.none()` today, sits before the first
  group for the app's navigation. A row for a running
  session other than the one on screen is a `button.session-open` whose
  message is `open(id)`; a saved session is one whose message is the resume's
  `press(id)` on an operator page (`operator_page.Resuming`, which
  `component.resume` handles through `Transport.resume`); the current row is
  text, and so is a saved row while another resume is out. A workspace is a
  section whose label the stylesheet draws as a small uppercase eyebrow with
  the session count, and a hairline in the divider colour separates one
  section from the next (team feedback, 2026-09-29); the list's own heading
  is kept for assistive technology and not drawn. The
  component reads `Transport.sessions` on `Opened` and on a `Ticked` at
  least `sessions_refresh_ms` (30 s) after the last read, keeps at most
  `sessions.listed_limit` entries, and `component.session_groups(model)` is
  what the operator's page draws. The observer's page draws no sidebar:
  `ui_socket.listed_for` gives it an empty list without making the read
  (owner, 2026-09-29).
- **Stopping, archiving and deleting** (protocol-change/065, the addendum on
  session actions). `web_view/actions` holds `Action` (`Stop | Archive |
  Delete`), `Answer`, `Reason` (`NotOwner | Running | Unavailable`) with fixed
  words, and the row's `Stage` (`Calm | Confirming(session, action) | Working(session,
  action)`). `home.Start.manage` is `Some` only for the owner's fresh operating
  home (`ui_socket.home_manage_capability`); a page with `None` draws nothing and
  ignores `StopRequested`, `ArchiveRequested`, `DeleteRequested`,
  `StopConfirmed`, `DeleteConfirmed`, `ConfirmCancelled` and `ActionAnswered`. `home_table.Manage`
  draws `Stop` on a running row and `Archive`/`Delete` on a saved or blocked one (a
  blocked row says "needs attention", with a fixed title, not "saved") in
  a `home-acts` group after the row's own button (the paths beneath
  `home.table_path` are unchanged; the rename button is the group's first child),
  and Delete's first press replaces the row with the fixed question and a Delete
  and a Cancel (`home-confirm`). Stop does the same (`Stop this session
  mid-turn?`, neutral tint) when the page's own activity read has the row as
  working or needing the person, and acts at once otherwise; a confirmation
  acts only for the row and action that are confirming. The request is the daemon's task and its answer
  `ActionAnswered`, which words the notice and reads the list again. `home_test`
  reads it.
- **The admin page's pill.** `admin.Start.ends_at` is the instant the page ends
  (an in-daemon value); `home_bar.ending` draws `ends in <loom-elapsed
  remaining="...">` after the first read, and the body has no sentence about the
  page's lifetime. `admin_test` reads it.
- **The session switcher.** `view/switch.switcher()` draws the attribute-less
  `<loom-switcher>` after `<loom-switch>` as the centre's last child on the
  operator's page and the home; it reads the sidebar's buttons in the browser and
  presses the chosen one's own, so it adds no event and moves no path
  (protocol-change/051, the addendum on the session switcher). The `Search ⌘K`
  chip that opens it is drawn by `<loom-shell>`, not the server.
- **Document titles.** `page.shell` is titled `Loom` (`page.session_title`); the
  home and admin shells are `Home — Loom` and `Admin — Loom`. A session's name is
  never in the served title: `view/heading` draws a hidden `<loom-title>` as the
  bar's last child, which sets the tab title from the heading's text on the
  client (`page_test`, `heading_test` with a hostile name).
- **Entry documents.** `.ended-document` sits `margin-top:min(20vh,160px)` down
  the window (`scripts/web_client_css_check.sh`), `Accept` is the filled primary,
  and the resume page's help is the refused sign-in's two sentences: `loom ui` in
  a copy box, then a new invitation accepted at `/ui/claim`.
- **Switching sessions.** A switch is a navigation to a new page
  (protocol-change/051, the addendum on switching sessions). On the operator's
  page `operator_page.Opening(id)` (a sidebar button, or a peer message's Open
  button, `lane.Replies(reply:, open:)`, drawn only when
  `component.openable` finds the peer's session in the principal's live list)
  reaches `component.switch_to`, which asks `Transport.open` and folds the
  answer in as `Linked`. A ticket becomes `component.departure(model)`, the
  address the operator page writes into the `to` attribute of the hidden
  `<loom-switch>` (`packages/web_client`), the centre's last child so no
  admitted path moves; a refusal is worded in the composer's notice with
  `sessions.reason_words`. The observer's page has none of it: no sidebar, no
  Open button, no element, no handler beneath `component.sidebar_path`.
  `session_switch_test` reads it, and `session_isolation_test` shows a page
  built after another holds none of the other's text.
- **Inviting from the session page.** An owner's operator page draws an
  invitation control as the last child of the Session pane
  (protocol-change/051, the addendum on inviting from the session page).
  `web_view/invites` holds its vocabulary: `Role` (`Observer | Operator`,
  never an owner), `Invitation(principal, role, command, token,
  expires_in_ms)`, `Reason` (`NotOwner | TooMany | NotIsolated |
  Unavailable`) with the fixed words of `reason_words`, `Answer` (`Minted |
  Declined`), `claim_ttl_ms` (one hour) and `Share`, the control's state:
  `Withheld` (no capability, nothing drawn), `Ready`, `Asking`,
  `Showing(invitation)` and `Refused(reason)`. `Model.view.share` starts
  `Withheld` unless `Transport.invite` is `Some`. On the operator's page
  `operator_page.Inviting(role)` reaches `component.invite`, which moves
  `Ready` or `Refused` to `Asking` and asks the transport; `Invited(answer)`
  moves `Asking` to `Showing` or `Refused` and is dropped in any other state,
  so a token is only ever taken into a state that asked for one. A press in
  `Asking` or `Showing` asks nothing. `Dismissing` reaches
  `component.dismiss_invitation`, which replaces `Showing` and so drops the
  token from the model. `view/share` draws the control: two buttons, or the
  invitation with a `<loom-copy>` box for the command and for the token
  (`subject` and `text` attributes, no children) and fixed words for handing
  them over. The observer's view draws nothing there
  (`component.panel(model, focus, viewers, share)` takes `element.none()`).
  `invite_test` reads all of it.
- `component.Model(socket)` (opaque): two records, as the terminal's is.
  `shared` is `session_view/model.Shared(socket, Nil, Nil, Nil)`, the
  session state the shared step reads and writes: the lane, the inbox, the
  last capture, the strand's history window (`scrollback`), the agent rows,
  roster, cache ledger and notices, the approvals, the notice and the
  drafts the lane sent. `view` is what only this host holds: the transport
  and its deadline timer, how much history the page holds (`Paging`), the
  transcript blocks it holds and the turns laid out from them
  (`turns.Piece`), the agent `Strip`, the inputs each was built from, the
  connection `Status` (`Connecting`, `Connected`, `Ended(ending)`; the
  heading says "connected", not "following", which read as the scroll state
  and is the browser's, and "disconnected" with a notice under it once the
  page ended), the page's own refusal, the outcome of the last
  command, the returned prompts and the count of drafts a command consumed.
  The component writes `shared` in four places only: it trims the history
  window to the rows the page draws, it marks the window as wanting older
  rows, it empties `returned_drafts` once it has taken them, and it empties
  the notice and `answer` before it runs a command.
- `component.live_rows` (150) and `component.held_rows` (300): the page
  holds the newest `live_rows` rows of `main`, cut between turns
  (`turns.grouped`); once the reader loads older rows its limit is
  `held_rows`. `component.Paging` is `Tail | Paged | Full`, and only moves
  forward; `Full` means a paged page had to cut a whole turn, so it loads
  no more. `component.older(model)` asks for the rows below the oldest one
  held, as a `history` read on the page's lane; `component.top(model)` is
  the `lane.Top` the lane draws above its oldest row (`Beginning`,
  `Earlier`, `Loading`, `Full(rows)`).
- The view, one module per screen region under `web_view/view/`, laid out
  by `component.view` and `operator_page.view`. None of them imports
  `component`, which imports them, so each takes what it draws as its own
  types or plain values. `heading.view(session_id, home, name,
  workspace, status, tone, context, cost, notice)` draws the top bar (the brand,
  `home`, the workspace's path with the home directory as `~` and then the name as two
  spans, the status as a `.pill` whose class follows the `Tone`
  (`online | pending | ended`), the `ctx ~41%` estimate and the cost
  `transcript_lines.cost_words` words as `est $0.04` or `est —` when tokens
  were spent and none priced, each as a word and a `span.num`; a figure with no
  value is not drawn, so no `est` for an unpriced model and no `ctx` on the
  primary strand before its first turn), with the ended
  page's notice as its last child; `component.heading(model, going_home)` reads those
  values from the model, draws `heading.home_link(going_home)` as `home`
  when the transport has the capability, and stays the entry point both pages
  call.
  `shell.view(audience, bar, sidebar, centre, panel, needing, workspace)`
  draws the frame, the client element `<loom-shell sidebar="listed|none"
  needing="n" workspace="digest">` (`workspace` only when the host has a
  digest), and is where its
  order is written: the bar (0, `slot="bar"`), the sidebar (1, `slot="left"`,
  or `element.none()` when `shell.Unlisted`), the centre `main` (2, the
  default slot: the transcript first, then the dock or the observer's bar)
  and the strand panel (3, last, `slot="right"`). Each region puts its own
  slot attribute on its element. The `sidebar` word comes from the
  `shell.Sidebar` type, `Listed(element)` or `Unlisted`, so the element draws
  no button for a column the page lacks; the operator's page is `Unlisted`
  when its catalogue read listed nothing. `needing` is the number of strands
  waiting on a decision (`component.needing`, `session_view/strand_card`),
  which the element draws as the badge on the Strands tab; it is an integer
  the component counted and never session text. The server never renders
  whether a column is open or which tab shows: those are the reader's, in
  the element.
  `panel.view(count, strands, detail, changes, session, trace, nudges, commentary)` is the panel's `aside`, a
  tabbed panel of four panes, always all drawn and always in this order: the
  Strands pane (a title, then the strip's list), `changes.view`'s pane,
  `session_tab.view`'s pane and `trace.view`'s pane. `component.panel(model, focus, viewers, share)`
  builds it for both pages, the operator's passing `Some(viewers)` and the
  observer's `None`, and the operator's its invitation control (an owner's) or
  `element.none()` as `share`. The tab bar is not drawn here: `<loom-shell>` draws it, keeps which
  tab is chosen and hides the panes of the others with a custom state, so the
  server never learns which shows. The panel carries no decision control: its
  only handlers are the strand cards' focus clicks, a strand waiting on a
  decision reads `Needs approval` on its card, and the approval card that
  answers it stays in the dock, for the strand on screen only
  (`panel_test` pins all of it). `strip.view(strip, focus)` draws the cards
  (the agent strip, kept under its old name), memoized on the whole strip, and
  `strip.count` counts them;
  `lane.view(pieces, live, top, load, replies, marks)` draws the transcript
  lane, memoized per line, followed by the live region, with the line above its oldest row: a "Load older" button sending
  `load` and carrying the fixed `data-loom-older` marker while older rows
  exist, and words otherwise.
- **The timeline and the marker controls.** Each piece of the lane is a
  `div.tl-row` holding a `span.dot` (decoration, `aria-hidden`, in the hue of
  the strand the piece belongs to, on a line down the left edge) and the
  piece. `lane.Marks(active, hue, positions)` is what the lane needs to place
  them, built by `component.marks` from `strip.positions`: a piece of the
  strand on screen has no marker; a spawn's and a result's dot and the strand's
  `button.tag` in their heads belong to the child; a nudge's belong to the
  advisor; a peer's message belongs to no strand here. Where the strand is
  listed and is not on screen, the dot and tag carry `data-loom-focus`, the
  position of that strand's card, a number; otherwise the tag is plain text and
  the dot decoration. No such control has a handler. `<loom-shell>` hears the
  click and presses the card with `data-loom-card` of the same number
  (`strip.card_marker`, `strip.focus_marker`, `strip.focus_attribute`;
  protocol-change/051, the addendum on the marker relay). Position zero is
  `main`, because the strip lists `main` first. `crumb.view(session, strand)`
  is the breadcrumb, `component.crumb(model)` the centre's first child while a
  strand other than `main` is in focus and an empty node otherwise, so the
  transcript's path is the same either way (`older_path` is `0\t2\t1\t0\t0`);
  its `All strands` link is the marker `0`, the whole element carries
  `data-loom-crumb` (which the shell's `Escape` looks for) and a `kbd` hint
  says `Esc`. `strand_detail.view(chip)` is a strand's own view, the
  Strands pane's third child after the list while a strand other than `main`
  is in focus (`component.detail`): a `← Strands` link (the marker `0`), the
  mark (`strip.ring`: the cache ring or the avatar), the name and status line, the figures the card leaves out (Task,
  Model by its last path segment with the whole in a `title`, Context, which
  says `not reported` while unknown, Cache, Running, the rest only when known; the cache words are
  `cache_miss.outlook_label`'s and no others; no Cost, since the session keeps
  cost as one total) and the tools the strand ran lately. The pane carries the
  class `detailed`, which hides the title and the list in the stylesheet; the
  list stays in the page because the relay presses a card.
- **Rows of a turn's work.** A turn's fold holds a column of steps, each drawn
  by `view/fold_row` as one line and a body behind it. The line is a glyph for
  how the call stands (the word for it stays in the row, visually hidden), the
  verb, what it acted on and, for an edit, `+n −m`: the words are
  `session_view/step_words` (`Read calc.py`, `Edit calc.py +3 −1`, `Ran
  python3 -m unittest`, `Memory · 4 lines`, `Reasoning · 4s`), shared with the
  terminal, and a subject's tag (`Mono`, `Prose`, `Figure`) picks its face and
  never its text. The terminal's `Ctrl+g` shows a call's whole program and
  result and a reasoning block's whole text, and the page holds the same
  records: `component.relaned` asks `turns.pieces` for the expansions
  (`turns.Expand(expansion.capped)`), so they are built once per projection and
  never on a render. A `Step` carries its `full` rows, a `Memory` its message
  and a `Plain` or `Narrated` piece carries `thoughts`, the full form of each
  reasoning row by the row's key, all already cut. `fold_row` draws a row that
  has a body as one `<loom-expand>` (`web_client`): the line in a child with
  `slot="head"` and the body in one with `slot="body"`. The element draws the
  one chevron, so a row has one and no per-step "Expand" button; a row with no
  body (a call whose result adds nothing) draws no element and no chevron. The
  body is the full form when the page holds one and the rows the transcript
  draws under the call otherwise. A reasoning row's time is `Narrated.took`,
  from the record before the response to its own. No event, handler or socket
  read is involved: the text is already in the model, so opening a row is the
  browser's, as a fold's open state is, and it works on an observer's page. The
  bodies are in every viewer's document, so `view/expansion.capped` cuts the
  full rows to `max_lines` (300) lines and `max_characters` (8,000) characters
  per row and ends a cut row with one line saying so. The rows are memoized per
  line (`fold_row.line_row`). Session text is drawn as text nodes: a program is
  a Markdown code block, so a `<pre><code>` holding text.
- **Diffs.** Every diff the page draws goes through `view/diff`: the opened
  edit step (a `ToolPatch` line, drawn by `lane.line_element`) and the Changes
  tab. `session_view/diff_view` reads the text into lines of a closed kind and
  `view/diff` draws each as its own row: the old and new numbers in a quiet
  gutter, the sign, and the text in a span, all text nodes. Added lines are
  green with a green `+`, removed red with a red `−`, a hunk header sits in a
  quiet band. The two numbers and the sign are one `.diff-gutter` cell that is `position:sticky;left:0` on its row's own background, so the box scrolls sideways under a fixed gutter and never wraps. A diff is cut at
  `diff_view.max_lines` with `n more lines not shown`.
- **Prompts, spawns, results and reviews.** A person's message is
  `turns.Prompt`: `lane` draws its sender as a line of its own (`<span
  class="who-name">Owner</span> · operator`) above the words in a bubble. The
  name is session text; the role is the author's, never the reader's: `turns.authors`
  reads the capacity each principal is attached in from the presence rows
  (`View.peers`, owners and operators only, since an observer cannot send;
  `operator` wins when a principal holds both, as a terminal and a page do) and
  `turns.attributed` sets it on that principal's messages in
  `component.relaned`. A sender with no such attachment shows the name alone,
  so an observer's page and an operator's draw the same words for a message. A spawn is a line (`Spawned <tag> · purpose`)
  and a result is a line naming the child (`<tag> finished`) with the first
  line of the report, opened to the whole report when it runs longer
  (`fold_row.reading`); neither is a card. Reviews of the advisor that follow
  each other are one `turns.Commentary` that counts them, drawn `advisor · 2
  reviews`.
- **The live region.** `component.live(model)` turns the shared record's
  streams for the followed strand (`transcript_lines.display_streams`),
  `Shared.summaries` and the generation clock into `live.Row`s, and
  `lane.view(pieces, live, top, load, replies)` draws them through `view/live` as the
  lane's last keyed entry, keyed `live`. `live.Thinking(progress, elapsed_ms,
  headline)` is the reasoning row: `Reasoning · <loom-elapsed offset>`, with the
  line count as the row's `title` and the headline as text beneath it when one
  has been pushed; the thinking is not drawn. `live.Opened(elapsed_ms)` is the
  row before anything streams: while the followed strand's phase is `assistant`
  or `streaming` and no stream is held, `component.live` returns it alone,
  `Thinking · <loom-elapsed offset>` (the browser counts the reading on, so no
  server timer; before the generation clock starts it says `Thinking` alone; `component.clocked` starts the clock the first time the page sees the `assistant` phase in a capture, since the phase event that starts it is the terminal's, and ends it when another phase comes with no stream drawn), and the first fragment replaces it with `Reasoning` or the
  answer. The region is a row of the
  timeline with its own dot, which pulses while the region exists. `live.Answer(line)` is the answer so far,
  drawn by the lane's own assistant line. A tool call being composed is not
  drawn. `View.streams` holds what the page last drew and is maintained by
  `component.streamed`, which follows the record's streams and, when a
  pushed entry has cleared them, keeps the last ones while
  `transcript_lines.response_awaited` says their answer is still owed
  (entry not in the projected window, operation still running in the
  capture), so the committed row replaces the region in one patch. The
  page also drops a stream whose answer the projected window already holds (a capture before the push) and keeps a mid-answer attach's sampled preview until the pushed text is at least as long (`steadied`), where the terminal shrinks to the first fragment. The
  region opts out of the log's live announcement (`aria-live="off"`). No
  read or socket event is involved, and `page_events_test` and `older_path`
  are unchanged. `live_test` pins the rows, the hand-over and the patch
  size (107 to 268 bytes for a fragment on a page of 150 rows, the same
  within two bytes on a page of one; `delivery_test`: a burst is one patch
  of 576 to 668 bytes on the real runtime).
- `nudges.view(board)` draws the advisor's pending nudges
  (`Shared.nudges`, the terminal's "Advisor · pending, not delivered"), every
  body received oldest first as a text node and a `+n more waiting` line for the
  ones the server counted and did not send. It is read-only on both pages
  and holds no handler, because the queue has no accept or dismiss: the only
  operation on it is the `advisor_pending` read, and the primary's next run
  start drains it. It is the strand panel's last child, under the four panes,
  on every tab and on both pages (the 051 addendum of 2026-10-02 records the
  move out of the dock).
- `commentary.view(board)` draws the advisor's settled commentary
  (`Shared.advisor_history`, narrowed by `advisor_history.visible`: a board
  for `main` only) in the Strands pane under the strand cards as one closed
  native `<details>` whose summary is `Advisor · 3 reviews · last: <first
  line>`; inside, the newest three reviews, each a request label the
  projection worded and the advisor's text drawn through the lane's Markdown
  drawer (`markdown_view`), a `+n earlier reviews` count, and the board's
  not-loaded line. Read-only, no handler, hidden while the advisor is
  on screen (its own transcript already holds the same words as its ordinary
  entries) and below 980px. The lane draws no row for a review
  (`view/lane.rows` filters `turns.Commentary` out before a timeline row is
  built). The 051 addendum of 2026-10-02 records the move out of the lane,
  and its 2026-10-04 amendment the hairline's removal.
- `controls.session(bar)` draws the operator's controls in the Session pane,
  as its fourth child after the invitation control (so `invite_path` does not
  move; its own path is `component.session_controls_path`; the rename control
  is the fifth child, `component.rename_path`): the goal row in
  the terminal's words (`goal_view.row`) with the buttons its status offers
  (Pause while active, Resume while held or limited, Clear always, nothing to
  steer once complete) in a `control-actions arming` row keyed by the status,
  and one `<details>` holding a one-field form, Fork. `controls.dock(bar)` is
  the dock's one goal line, drawn only while a goal is active or paused, with
  its one steering button; otherwise an empty node. Stop and Set goal are
  gone: stopping is the terminal's Escape, and a goal is pinned by typing
  `/goal ...` in the composer, which the page parses as a command.
  `controls.Bar` carries the messages each button sends and the form's submit
  handler, since `operator_page` owns the message type. The observer's page
  draws none of it. The 051 addendum of 2026-10-03 records the move.
- The composer is a card of three rows: `To <tag>` (the strand's hue, no
  handler), the borderless editor, and a footer with the attach element
  (`<loom-attach>`, whose button is a `+` icon), the hint (`Cmd+Enter to
  send`, `Turn is busy · ` when busy), the notice, `Owner · operator`, the
  cache outlook and the Send, or Queue and Steer, buttons. The notice is
  keyed by `component.notice_serial`, which `operator_page.update` raises
  whenever the notice changed, so the stylesheet's fade starts for each new
  one; a `warned` notice does not fade. Its words come from
  `session_view/notice_words`, a closed table the terminal shares.
- An approval card is headed `<b>strand</b> wants to <approval.wants(tool)>`,
  with the strand from the escalation record's scope
  (`component.raised_on`) and the arming delay drawn as the `Arming…` note.
- A decided approval is a `turns.Decided` piece: `session_view/decisions`
  reads the approval ledger (`shared.approvals`) and the strands the
  captures saw pending requests raised on (`View.raised`), and
  `turns.with_decisions`, called by `component.pieces`, places each by the
  register sequence that committed it. The lane draws
  `p.decided` with the author, the verb and the tool as text nodes.
- `lane.Replies(fn(key) -> message)` or `NoReplies`, the last argument of
  `lane.view`. A peer card draws a `Reply to
  this peer` button after its body when the lane has replies, and the button
  sends the piece's key, never the peer's session or strand.
- `todo_panel.view(board, reviewers)` draws the terminal's pinned todo
  board and reviewer band on both pages, from plain values;
  `component.plan(model)` reads them: `Shared.todo_boards` at
  `Shared.active_strand`, and `reviewer_status.lines` over
  `Shared.reviewer_rows`, the terminal's own lines. The board is one line
  until the reader opens it, `Todo · 3 of 5 done · <active task>` (a board whose tasks are all closed is not
  drawn; the closed steps are in the turn's fold), the
  summary of a `<loom-fold>` (the browser keeps its open state, so a patch
  leaves it alone and an observer's page has it too); the line follows the
  strand the page shows because the board is that strand's. Opened, the phase holding the
  active task (`todo_list.focus`) is expanded with every task, each with the
  terminal's glyph (`✓ ▸ ○ ⊘ –`, hidden from assistive technology, with the
  status as a visually hidden word) and a blocked task's reason; the other
  phases are one row of `name ✓` or `name n/m`; the header carries the
  phase's count and `n/m done`; a board with every task closed is one row.
  The band's lines are drawn as they are, in a `pre-wrap` block under the
  board, and it is drawn without a board when a reviewer runs. The panel is
  memoized on the board and the lines, and is `element.none()` when there
  is neither. It is the dock's first child on the operator's page and sits
  between the lane and the bar on the observer's, so the lane's
  `older_path` is unchanged. The terminal's idle-advisor placeholder is not
  drawn.
- `trace.view(trace)` draws the Trace pane, the panel's fourth (after Session,
  before the nudges, so `strip_path` and `invite_path` do not move), on both
  pages from `component.trace(model)`, the `session_view/trace_view` fold of
  the same records `relaned` folds the Changes board from. It lists the
  session's `code_mode` programs. The newest program also lists the rows of
  the protocol-change/060 call record its result carried (`Program.calls`, as
  text nodes under `trace-calls`), and a program with no record lists none; the
  pane's last line says so (`trace_view.capability_calls_recorded`). The newest
  program leads with its state chip, result excerpt and a collapsed `Budget`
  `<details>`; earlier programs are rows under it. Labels and excerpts are
  text nodes, a state's class is one of three literals chosen from the closed
  `State`, there is no handler, and the pane is memoized on the trace. With
  no program it is the heading and one line saying so.
- `changes.view(board)` draws the Changes pane, the panel's second, on both
  pages from `component.changes(model)`, the board `session_view/changes_view`
  folds from the records of the window the page projects (`relaned` builds it
  with the transcript, so a message that moved neither costs no fold). Its
  heading is `Changes · 2 files · +14 -2` with `from this session's edits`
  under it, then one `<details>` per file with the first open. Paths and diff
  rows are text nodes; a row's class is one of four literals chosen from the
  fold's `Kind`; a file the session only wrote reads `written · N lines` where
  an edit's counts go. It has no handler and is memoized on the board. With no edit
  it is the heading and one line saying so, so the pane is always drawn and
  the panes after it never move. It reads no worktree: the daemon serves
  worktree bytes to an Owner binding only.
- `session_tab.view(goal, cost, jobs, viewers, workspace, share, controls, rename)`
  draws the Session pane, the panel's third. Its children are the title, a
  memoized `div.session-rows` of groups, `share`, `controls` and `rename`, in
  that order so the three controls' paths never move (`invite_path`,
  `session_controls_path`, `rename_path`). The groups read Session (the name
  with its Rename control, then the workspace), People (the viewers, then the
  invitation buttons), Goal (the terminal's own row, `goal_view.row`, or `none`,
  then its buttons), Fork, Jobs and Cost, each under an eyebrow heading and with
  no rules. The DOM order is not that order: the stylesheet makes the pane a
  flex column, the rows wrapper and the controls section `display:contents`, and
  gives each piece an `order` (`.pane-session`). The viewers are
  `session_view/session_summary` (one line per principal: `Owner · owner,
  operator · 3 pages · you`) and the cost is the figure with `estimated`, or a
  dash alone for an unpriced session. The page holds no creation time, so none
  is drawn. Schedules are not a row: the shared record keeps a schedule
  listing only as transcript lines the page does not draw. The component asks
  for the jobs on a `Ticked` when the page opened or last asked
  `jobs_refresh_ms` (10 s) ago and no answer is outstanding. The clock starts
  when the page opens, so the first tick-driven ask comes ten seconds later,
  after the startup reads, and the page's lane stays in the terminal's engine
  state through them. This is the tick-driven ask only: the lane also requests
  a read whenever a run's completion changes, `lane_fold`. The tick marks
  `Shared.jobs_refresh` as requested and
  the shared step sends the `live_jobs` read once the lane is ready
  (`surfaces.service_jobs_read`). The read is one of the gateway's
  `read_only` commands, every role may send it, and its answer is a snapshot
  the lane folds like any other, so it adds no event and no accepted page
  event. A refused read is not repeated before the interval passes
  (`View.jobs_asked_at`), and a board for another strand than the one shown
  reads as not read yet. Viewers are drawn on the operator's page and never on
  the observer's, which is handed `None` (a default the design note adopted,
  open to an owner override). Job commands, viewer names and the goal are
  text nodes.
- `strip.Strip` and `strip.Chip`: the listed agents (`line`,
  positional `hue`, the `cache` outlook `cache_watch.shown` allows with its
  label, `running_ms`, how long its operation had run when the strip was
  built, and the agent row's `model` and `recent` tools), the advisor's chip
  and the settled strands (`settled`, at most `strip.settled_limit`, in
  reverse row order, and `earlier`, the count of older ones). The component builds them and `strip.view` draws
  them. `strip.hue_class` and `strip.ring_class` map a hue and an outlook to
  literal classes. `Strip.followed` is the strand the strip marks as current
  (`component.strand(model)`). `strip.view(strip, focus)` draws each chip as
  `li > button.chip-hit` whose click is `focus(name)`, the name the strip was
  built with, holding a mark (`strip.ring`: for a held outlook the ring, its
  shape, the state's glyph inside and the outlook's words as a literal
  `title`; for none, `strip.avatar`, a disc with the name's first letter as a
  text node; both hidden from a screen reader), the name and one status line
  (`session_view/strand_card.status_line`, in the attention colour for a
  strand that needs approval). A card carries no clock and no figure: those
  are the strand's own view's. It carries `data-loom-card`, its position
  (`strip.positions` numbers the cards, the listed chips in order, the
  advisor, then the settled cards, for the cards and the lane). Settled
  strands are the list's last item, `li.settled-group` holding a native
  `details` (closed until the reader opens it; the browser owns the state and
  nothing persists it) whose cards are the same buttons, each saying how the
  strand ended in words and carrying no duration, because the roster's clock
  for a finished operation keeps running and no capture records when an
  operation ended. `+n earlier` is text, not a control. The list's children
  are keyed by fixed words (`card-<n>`, `advisor`, `settled`) so the group is
  the same element when a live strand starts or settles. A settled card is
  not counted by `strip.count` (the title and the tab's badge speak of live
  strands). Focusing one makes it the active strand, which the roster lists
  with the live cards, so it leaves the group until the reader goes back.
- `code_view.block(language, text)`: a code fence's body as one `span` per
  line, each token a `span` whose class (`tok-kw`, `tok-type`, `tok-str`,
  `tok-num`, `tok-com`, `tok-add`, `tok-del`, `tok-meta`) is a
  literal chosen by a `case` over `session_view/code_tokens.CodeKind`. The
  token's text is a text node and the fence's language tag only selects the
  scanner. A `code_mode` program is a fenced `gleam` block, so the lane's
  program body and an answer's fence share it; a line the scanner has no
  class for is one text node. The rows are memoized per line, so a streamed
  delta scans only the line being written.
- `markdown_view.blocks(tree)`: the elements for an answer's Markdown,
  drawn from `session_view/markdown`'s tree, the tree the terminal's
  `tui/markdown` also draws. `view/lane` uses it for the speakers the
  terminal renders as Markdown (assistant, reasoning, tool detail) and for
  the bodies of the result, nudge and peer cards, which are agent prose
  the terminal draws as tool-detail rows; every other row stays a `pre`.
  The three message speakers (`sent-message`, `strand-message`,
  `peer-message`) are among those: their text is a heading line and a
  body, and a `pre` keeps the heading a line of its own. So are the two
  program blocks (`program-running`, `program-failure`), whose text is
  already laid out line by line, and an image's row (`image-row`).
  The model holds no trees. `lane.view` draws every transcript line and
  card body inside its own `element.memo` keyed on that line or body, with
  no memo around them (`lane.rows`), so a line is parsed and drawn when it
  first appears and Lustre reuses its element after that. Lustre forgets
  memos nested inside a memo that hit and redraws a keyed subtree whose
  key changed, which is why the memos are leaves and why `turns` keys a
  turn's work by its input (`docs/lustre.md`, "A memo inside a memo that
  hit is forgotten"). `lane_memo_test` counts the lines a render draws.
- `component.{submit, decide}`: the two inputs, wrapped as the shared
  step's commands (`step.update` with `Acted`). `submit` checks the draft's
  emptiness and length, which are the page socket's limits, and then parses
  it with `command.parse_with_skills`. `component.page_command` is the one
  place that names what the page does not run: a `command.Surface` and
  `command.AddDirectory` (`/add-dir`, `/add-write-dir`, which name a path on
  the daemon's host) are refused with a `Warned` notice and never sent, and
  every other `command.Session` runs through `commands.act` as the terminal
  runs it, so `/compact` is a compaction and `/models` is refused. The page
  loads no skills catalogue, so a skill's slash command is refused as
  unknown. `Answer` is `AllowOnce | Deny`; a page never offers remembering
  a grant for the session. A decision takes `outbound.mutation_refusal`'s
  refusals like any mutation, and the card stays when it is refused.
- `component.control(model, Control)` and `component.reply(model, key)`:
  the page's session controls and its peer reply. A `component.Control` is
  `PauseGoal`, `ResumeGoal`, `ClearGoal` or `Fork(name)`. The goal buttons
  and the fork form are `msg.Control(command)`
  (`session_view/commands.control`): the same dispatch as a typed draft, with
  no draft, so the composer's text and `component.drafts` are untouched. The
  form's text goes after `/fork ` and through `command.parse`, and `forking`
  checks what came back: a fork or the command's own complaint that a name
  is missing. `View.sent_forms` counts forms whose command the lane accepted
  (`outbound.mutation_refusal` said none and the command mutates, so it went out
  or was queued behind a read), and the form is keyed by it, so an accepted
  form comes back closed and empty and a refused one keeps its text.
  `component.reply` finds the `turns.Peer` piece by the engine's key, drafts
  `Reply to the peer message from session S, strand T, with peer_send: `, and
  appends it to `View.returned` beside the daemon's returned prompts, so
  `<loom-composer>` puts it in an empty editor or after the draft and never over
  it. The terminal has no reply command: the model answers a peer under the
  owner's link with `peer_send`, at the operator's prompt. Nothing is sent by
  `reply`. A `turns.Sibling` piece (a strand of the same session) is a
  `sibling-card` headed `strand · <id>` with no receipt and no Reply, since
  no peer link exists to answer through. `component.pending_nudges(model)` and `component.goal(model)` read
  `Shared.nudges` and `Shared.goal`.
- `operator_page.Msg(socket)`: `Observed(component.Msg)`, `Submitted(text,
  delivery, images)`, `Decided(id, seq, answer)`, `Controlled(component.Control)` and
  `Replying(key)`. The lane's "Load older"
  button sends `Observed(component.OlderRequested)`.
  `composition(fields)` is the total decoder of the composer form's
  fields (one `draft`, at most one `delivery` and at most one `images`, a JSON
  array of base64 strings, and nothing else), and `control_text(fields)` of a
  control form's: exactly one `text` field.
- `image` (protocol-change/051, the addendum on images): the transcript's
  images as the page addresses them and the daemon serves them. `address(session,
  ref, position)` is the one `src` the view builds, relative to the page's own
  address; `drawn` is the four raster types; `plausible_ref` is the shape check
  the route makes before it asks the page for anything; `serve(image)` checks
  what the daemon will answer with (raster type, base64, at most 20 MiB, and a
  magic number that says the declared type: `Served` or `NotAnImage` or
  `TooLarge`). For the composer it holds `admit(encoded)`, which decodes each
  image `<loom-attach>` submitted, reads its type from its bytes, bounds the
  count (4) and the total (8 MiB) and returns the shared step's
  `pasted_image.Image`s or the notice, and `limits_attribute()`, the
  daemon's numbers and types as the element's `limits` attribute.
  `component.ImageRequested(ref, position, reply)` is the daemon's question
  (sent with `lustre.dispatch`, so no browser frame can produce one); the
  component answers from `turns.picture` over its pieces. `lane.view` takes the
  session's identity and draws a `<details><img>` per drawn image after a row's
  text and a step's detail; `component.submit` takes the images, refuses a
  steer that has any, and sets them as the shared step's attachments for that
  one submit and clears them after.
- `completion.rows()` and `completion.table()`: the slash commands the
  composer offers, built from `session_view/command.suggestions` (the
  one-word commands, and the argument rows of every word that has some once
  its space is typed) less the rows `component.page_command` refuses, as one
  JSON string for the composer element's `commands` attribute. The names and
  hints are the terminal's and no session text is in it.
- `component.Returned(number, text)`, `component.returns(model)` and
  `component.returned(model)`: a held prompt the daemon handed back for
  `main` (protocol-change/038), taken from `Shared.returned_drafts` at the
  end of every message (`taken`), numbered, and kept, the latest
  all of them, for the composer's element. `component.reply` adds the start
  of a peer reply to the same list, so the element treats a reply as a
  returned prompt (put in an empty editor, or after the draft, once, by
  number), and the notice about returned prompts is the daemon's alone.
  `step.update`
  leaves `returned_drafts` alone (`forget_surfaces` no longer clears it), so
  the page is the host that empties it. A prompt for another strand or
  session is named in the notice and not kept.
- `ending.Ending` (`PageEnded`, `AccessRevoked`, `SessionStopped`,
  `NotOpen`, `DaemonNotReady`, `LinkExpired`, `ConnectionFailed`): why a page
  has no session, as a closed type. `PageEnded` means eight hours ran out, the
  daemon restarted, or the page was the oldest of `ending.max_pages` (four)
  when a newer link opened; a newer link ends nothing below that bound. `headline` and `advice(ending,
  session_id)` are fixed strings, so no peer, session or error text reaches
  the page. `reason` and `from_reason(given, otherwise)` are the two halves
  of the hop through the reason string `connection_event.Closed` carries
  (`from_reason` is total: a string that names no ending gets the caller's
  fallback, which the component sets to `ConnectionFailed`, or `NotOpen` for
  a refused open). `close(ending)` is `Final` (close 1000, which Lustre's
  client runtime does not retry) or `Retry` (4000, which it does), read by
  `client/daemon/ui_socket`. `view/ended.view(option(ending), session_id)` draws
  the notice, a `section` with two paragraphs, or `element.none()`.
- `page`: the shell, whose `<lustre-server-component>` holds a fixed
  paragraph (`waiting_notice(session_id)`) as light-DOM content, which the
  client runtime hides when it mounts and which so shows exactly while the
  page has no session; `refusal(ending, session_id)`, the document a
  refused page request is answered with; the exchange page (`enter(next, nonce)`), the asset
  names (`stylesheet_asset`, `enter_asset`, `page_asset`, `client_asset`, `favicon_asset` (linked from every
  document's head by `icon_link`),
  `runtime_asset`) and where each is on disk (`static_file`,
  `runtime_file`), the keyed paths (`keyed_prefix`, `session_path`) and
  `content_security_policy(host)`.

## Relationships

- **Depends on**: `session_view` (the shared step and its record, the
  lane, the inbox, `commands`, `history_view`, `transcript.branch_blocks`,
  `turns`, `approval`, the line types), `core` (the
  origin label; JSON in tests), `lustre == 5.7.1`, `houdini == 1.2.1`,
  `gleam_erlang`.
- **Depended on by**: `client`, whose `client/daemon/ui_socket` starts one
  component per browser connection and whose router serves `page`'s
  documents.

## Traffic

- The component's mailbox receives the open's outcome (mapped to `Opened`
  or `Refused`), `connection_event.Message`s from the transport (the
  mapping drains up to `arrival_batch` waiting frames into one `Arrived`),
  and a `Nil` from its one deadline timer, armed for the lane's
  `session_channel.next_due` (mapped to `Ticked`). Each source is one
  `server_component.select` from `init`, so its subjects belong to the
  component's process. Every message reaches the shared step as
  `step.update`: `Arrived` is `msg.Arrived` then a tick, `Ticked` and
  `Opened` are a tick, and a command is `Acted`. The step folds each lane
  update into `shared` (captures, history pages, usage and the cache
  ledger, streams, refusals, acknowledgements), as it does for the
  terminal. The page then derives what it draws from `shared` (see the
  invariants). The notice is an outcome and never the shared record's `notice`, which any
  event replaces and which would say "advisor_pending sent" on every page
  load. `Said` is what the shared step worded when the page ran the
  operator's command (`View.outcome`, read at once, after the notice and
  `Shared.answer` were emptied so that a silent command leaves nothing) or
  the daemon's reply to it (`Shared.answer`, which only another reply
  writes); the page's own refusals are `Warned`.
- Out on the lane, besides the lane's own snapshot requests and the
  operator's commands: at most one request at a time. The shared step's
  reads go out as the terminal's do, one after another and each when the
  one before is answered: the strand's notes (a first capture, to seed a
  todo board, which the todo panel draws), the session's context (a first
  capture, a configuration change and the end of each operation), the
  advisor's pending nudges and the goal. Also the `history` read
  (`session_channel.history`) for at most 100 sequences below the oldest
  record the page holds. The summary labels' read is not sent.
- The page renders `web_client`'s custom elements by tag:
  `<loom-elapsed offset>` in a strand's own view and in the live reasoning row, `<loom-fold>` around a settled
  turn's work, `<loom-expand>` around a step or reasoning row with a body, and `<loom-follow>` around the lane and `<loom-shell>` around the page. The stylesheet pins the
  page's frame (`<loom-shell>`: the top bar across the full width, and under
  it the sessions' sidebar, the centre and the strand panel; the dock or the
  observer's bar at the bottom of the centre, the page itself never
  scrolling) and makes `<loom-follow>` the scroll container between them
  and the dock. The element's two buttons hide and show the sidebar and the
  panel (a hidden column is `inert`, so its content leaves the tab order),
  with nothing kept across a reload. Below 1212px the sidebar is a drawer over the page
  (opened by its bar button or Command/Control B, never saved), and below 980px the
  panel becomes a row of cards under the bar. It keeps the
  newest row in view while the reader is at the bottom, shows a "Jump to
  latest" button while they are not, and keeps the reader's place when a
  press of "Load older" brings rows in above them. They run in the browser
  and send the server nothing. The operator's editor is drawn inside
  `<loom-composer commands returned>`, which lists the slash commands as
  the draft grows, sends the draft on Command or Control with Enter (by
  submitting the composer form), and puts a returned prompt in the editor.
  Its inputs are the `commands` table, the `returned` count and the
  returned prompts as text-node children in a `returned` slot, numbered by
  `data-n`; the editor stays the uncontrolled textarea, and keeps its place
  when a return arrives.
- An operator's page also receives Lustre's `EventFired` for its handlers:
  a click on an approval button, on one of the controls or on a peer card's
  Reply, and the submit of the composer form or of one of the two control
  forms. They are the clicks and submits `ui_socket.operator_accepts` admits
  already, so the page adds no event.
  The composer element's keys and list add no event: the send key calls
  `requestSubmit`, which raises the same submit, and `page_events_test` pins
  that the operator's page registers only clicks and submits.
- Outputs leave through the transport only: `Transmit` and `Shut`, in the
  lane's order, inside one `effect.from`.

## Invariants

- **No session logic here.** What a frame means, when to catch up, which
  lines a capture becomes, how a lane folds into turns, which agents a strip
  lists, what the cache may claim and what an operator's input becomes on
  the wire are `session_view`'s.
- **Derive from inputs that moved, never per render or per tick.** The
  blocks and pieces are rebuilt only when the capture, the history window,
  the cache notices, the agent rows or the paging differ from what the last
  projection read (`Projected`), and the strip only when its inputs
  (`Stripped`, less the roster's clock) or a drawn cache label did. An idle
  refresh that brings back the capture already drawn projects nothing. The
  shared record's `render_revision` is not the signal: it moves for stream
  fragments (which change the live region below, not a projection) and
  tool tails the page does not draw, and a page that re-projected on each
  would project once per batch of a streaming answer.
  Logic that decides something about the session belongs to `session_view`,
  where the terminal uses it too.
- **Event-driven delivery, one render per burst.** `Arrived` files its
  batch and then ticks, which drains every filed frame in arrival order and
  runs the lane's tick; there is no periodic tick. Lustre renders once per
  message whatever it changed, so the batching has to happen in the
  selector's mapping, before `update`. `update` reads the transport's clock
  once, at its top, and the step reads none. After every transition `rearm`
  cancels the one timer and arms it for the lane's `next_due`; `update`
  performs that itself, because the `Timer` handle must stay in the model
  (ADR-013, the addendum on event-driven delivery). `component_test` pins
  the reduction; `delivery_test` counts the renders a burst costs on the
  real runtime and watches the timer fire.
- **The page's rows are bounded.** The page holds at most `live_rows`
  rows, or `held_rows` once paged, plus at most one block when the newest
  turn alone is longer than the limit; loading older rows past the limit
  is refused (`Full`), never allowed to grow the page. Once rows are cut,
  the history window is trimmed to the oldest record drawn
  (`history_view.retain_from`), so what a capture projects is in
  proportion to the page. The page starts at a turn's input whenever it
  can, so prepending older rows and sliding the window leave every held
  turn's key, and its lines' memos, as they were (`lane_memo_test`). The
  undrawn end of a turn whose input is older stays in the window so the
  next read goes below it, and counts as cut once it alone no longer fits.
- **One read at a time.** The history read goes out only when the lane has
  no request out (`session_channel.history` refuses a busy lane); until
  then the demand stays `Wanted` and every reduction offers it again. While
  a read is out the history window is frozen, and the reply, a refusal or
  the lane's failure is what ends it. The button is offered only while
  there are sequences below the window to read.
- **One ordered effect.** The lane's outputs are performed in one
  `effect.from`, never split across `effect.batch`, which does not order.
- **The page keeps no facts the step recorded for surfaces it lacks.** The
  step's tick drops them itself; the component drops the ones a command
  recorded (`step.forget_surfaces`) after it has read `DraftTaken`, the only
  one it reads, and the ones `apply` folds. A list that nothing empties
  would grow for the life of the page. `step.forget_surfaces` leaves
  `returned_drafts` alone, because a held prompt the daemon hands back is
  its last copy: the page takes it into `component.returned` and empties
  the list, and the composer's element puts it back in the editor.
- **Which application runs is which commands exist.** An observer's page is
  `component.app()`, whose message type holds no command and whose view
  attaches the lane's "Load older" click (`OlderRequested`, a read) and one
  click per strip chip (`FocusRequested`, a change of what the page shows,
  built from the name the strip was drawn with); its bar is a fixed text
  node. The page socket admits from an observer only a click at
  `component.older_path` or beneath `component.strip_path`
  (protocol-change/051, the addenda on history paging and strand focus), and
  `page_events_test` pins that the observer's handlers are exactly those.
  The sidebar and every other region add none. The strand panel is the
  frame's last child, so a region added after it does not move an admitted
  path; the redesign's shell moved both constants once (`older_path` is
  `0\t2\t0\t0\t0`, `strip_path` `0\t3\t1\t0`; the tabbed panel moved
  `strip_path` again, to `0\t3\t0\t1\t0`, because the Strands pane is the
  panel's first child; the breadcrumb's place moved `older_path` to
  `0\t2\t1\t0\t0`), and `page_events_test` and `ui_socket_test` pin
  them. The transcript's dots and tags, the breadcrumb and the strand view's
  back link add none: they carry a marker, the shell presses a card, and
  `page_events_test` pins that the handler table still holds only the cards
  and the older button with markers drawn. An operator's page is
  `operator_page.app()`. Since S5 the draft its composer carries is parsed
  as the terminal parses it, so the page sends any session command a draft
  names (`/fork`, `/model`, `/goal ...` and the rest of `command.Session`),
  not only a prompt, except adding a directory, which `page_command` refuses
  (protocol-change/051, the addendum "the operator page runs session
  commands"). Its controls (the
  goal's buttons, the Fork form) and its peer Reply button run the same
  commands, chosen by a click or a submit instead of typed (the addendum
  "the page's session controls, the pending nudges and the peer reply", and
  the addendum of 2026-10-02 that removed Stop and Set goal), so the page's
  operations are still exactly `command.Session` less adding a directory, and its events are
  still the clicks and submits the socket admits. What bounds them is the
  attachment's role, capped at operator, which the gateway enforces. The
  daemon's gateway refuses an observer's mutation independently, and the
  engine refuses one on an observer's attachment as a third layer.
- **A control never takes the composer's draft, and a form is cleared only
  when it sent.** A control's command is `msg.Control`, which sets no
  submission marker and drops `DraftTaken`, so pressing Fork or Clear goal
  while the operator is typing leaves the composer as it was
  (`component.drafts` does not move). The two forms hold the command's own
  text, so they are keyed by `sent_forms`, which rises when the lane accepts
  the command (sent, or queued behind a read, whose frame moves the request
  identity only when the reply lands), and a refusal (no name, an observer's attachment, a busy
  lane) keeps what was typed.
- **The controls draw at fixed places.** The goal's row is keyed by the
  goal's status and carries `arming`, the 600 ms refusal of clicks the
  approval card uses, so a status change that swaps Pause for Resume cannot
  take a click aimed at the old button. The composer stays last in the dock,
  with the approvals directly above it.
- **No handler or attribute from session text.** Button messages carry the
  daemon's escalation identity and sequence; cards are keyed by sequence
  (every storage write takes its own), rows by the engine's `transcript.Row` key. Text is only ever
  `html.text`; nothing uses `unsafe_raw_html`. Rendered Markdown keeps the
  same rule: a link is `<loom-link>` holding its label and its destination as
  two text children, never an `href` (the browser element validates the
  destination and draws the anchor, 051's addendum on clickable links); a Markdown image is text and is never loaded; an ordered list's numbers
  and a fence's language are text; classes come from closed types.
- **An approval card is drawn from the record alone** (`approval.presentation`),
  in its own region outside the transcript, directly above the composer in
  the dock, the footer at the bottom of the pinned frame. A card
  appearing grows the dock upward and never moves the composer, the
  transcript above it shrinks by as much, and the region's height is
  capped so it scrolls on its own. The region carries
  `data-loom-approvals` (`operator_page.approvals_marker`), which
  `<loom-shell>`'s key rule reads: no key acts with its target inside it. No
  card carries a strand marker. With nothing pending
  the region is `element.none()`, so the composer's path does not change
  when a card appears. The action row carries `arming`: for 600 ms after
  a card is inserted the stylesheet refuses clicks on it and dims the
  buttons, and cards keyed by sequence keep their node so a patch never
  restarts it; reduced motion drops only the dimming. Deny comes first; each button
  names the tool; nothing has `autofocus`; the composer's submit never
  decides an approval; a decision is sent only for the record still pending
  at the drawn sequence (`operator.drawn`).
- **The todo panel never covers the transcript and carries no handler.**
  It is in the flow of the pinned frame, so the transcript shrinks by its
  height; the stylesheet caps it (`max-height: 28vh`) and it scrolls
  inside. Its text is session text, drawn as text nodes; its classes are a
  closed set chosen from the status, never from a string.
- **The list offers only what Send would run.** `completion` drops a row
  exactly when `component.page_command` refuses the command it names, so
  there is no second list of what the page refuses; a row that takes an
  argument is judged with one, since the command alone is a usage message.
- **A returned prompt is never dropped and never replaces a draft.** The
  editor is not keyed by returns, so a return leaves what the operator is
  typing; the element decides whether the text is the draft or follows it.
- **The composer form is decoded totally.** One `draft`, at most one
  `delivery` of `prompt` or `steer`, nothing else; anything more refuses
  the event.
- **No inline script or style** in any served document, so the policy can
  refuse both.
- **Class names are complete literal strings.** Tailwind builds the
  stylesheet from the classes this package's source spells, read as text
  (`packages/web_client/src/web_client.css` names it with `@source`). A
  class built by concatenation is missing from the output. `priv/static` is
  generated: run `make gen-client` after changing a class.

A `goal_changed` arrival drives the shared session lane's owed `goal_get`
without waiting for a tick (protocol-change/056). The resulting correlated
`Auxiliary(GoalSnapshot)` is accepted by the lane; the operator page renders
the refreshed goal through the shared step. `component_test` proves the
observer stays Connected after that read, so adding a terminal
surface does not leave the second host with an incompatible reducer path.

## Deep Docs

- `docs/architecture/web-view.md`: the architecture map: the request path
  from `loom ui` to a live socket, the processes per page, the two
  components, and the security layers.
- `docs/design-notes/web-ui.md`: the working spec for where the page is
  going (an exploration, not a commitment).
- `docs/adr/014-second-runtime.md`: one engine, two views, and option C in
  the web host.
- `protocol-change/051-web-view-route.md`: the routes, authentication, the
  relay, and the operator addendum (page keys, nonces, ceilings, cards).
- `docs/lustre.md`: how Lustre 5.7.1 server components work, how they map
  onto this package, `ui_socket` and `ui_relay`, the view's security and
  accessibility rules, and the checklist for a change here.
