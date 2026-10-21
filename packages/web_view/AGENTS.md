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
  `now()`, `sessions(deliver)`, which starts the sidebar's read of the
  principal's sessions (the daemon's authorized catalogue read, `[]` on
  failure) in the daemon's own task and returns at once, the list arriving
  as `SessionsListed` through `deliver`, and
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
  included, and the page draws the "Home" button only then. All but
  `sessions`, `resume` and `rename` run in the component's process; those
  three start a task and answer as a message, so the runtime never waits on
  the registry for them.
- **Context breakdown** (protocol-change/075). The `ctx ~41%` figure is a native
  `<details>` whose body is `view/context_breakdown.panel(state, Actions(refresh,
  compact))`: headline, basis words, stacked bar (`split`: system prompt, tools,
  messages, what the provider counted beyond them, reserve, free), the tokens until
  auto-compact and a closed, bounded item list (`tools`, `kinds`). The inventory
  is a leaf memo keyed by the item list and omitted count, so stream arrivals
  reuse grouping without caching actions, freshness or usage figures. Everything is a
  text node over `context_view.State`. Refresh is `component.ContextRefreshRequested`
  at `component.context_refresh_path`, which the observer's socket admits;
  Compact now is `component.CompactStrand` (a `Control`, `/compact` through the
  shared step) and only the operator's page draws it. The `<details>` carries
  `data-dismiss="keep"` and is followed by an empty `<loom-dismiss>` sibling
  (`web_client/dismiss`), which closes it on an outside press or Escape; it is a
  sibling and not a wrapper so the buttons keep their tree paths. The panel's
  fixed position stops short of the strand column from 980 px up (its right edge is
  `calc(var(--panel-width, 340px) + 12px)`: `<loom-shell>` sets `--panel-width` on
  its frame, 340 px until the reader drags the panel's grip, `0px` while closed). A usage
  row inside the 30 s pacing window is deferred to the window's end
  (`context_view.State.deferred_until_ms`), and `rearm` wakes the page for it.
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
  submit as well (protocol-change/067). `component.remembered_path`
  (`0\t3\t2\t5`) is the operator's list of remembered permissions, the pane's
  sixth child (protocol-change/073); the operator socket admits clicks beneath
  it and the observer's admits none. `component.peers_path` (`0\t3\t2\t6`) is the
  owner's peer-link section, the pane's seventh and last child
  (protocol-change/077); only an owner's socket admits an event beneath it.
- **Peer links** (protocol-change/077). `peer_links` holds the vocabulary
  (`Request`: `Read`, `Link`, `Unlink`; `Answer`: `Listed`, `Changed`,
  `Declined` with a fixed `Reason`; `Board`/`Row`, `Reverse` for the Both
  directions toggle) and the controls' state machine (`Control`: `Withheld` or
  `Offered(board, asking, step, note)`; `Press`). `Transport.peers` is `Some`
  only on an owner's operating page. `component.peering` applies a `Press`:
  `PickSession` takes the name from the page's own sidebar list (running sessions
  other than this one), `AskUnlink` opens only for a row the board holds, and
  `ConfirmUnlink` builds edges from the board with `peer_links.edges`;
  `component.linking` takes the one text field (the target strand) from the
  `Linking` message and judges it. `peers_due` reads on open, on a tick past
  `peers_refresh_ms` (15 s) and on a focus change, and a `Changed` answer reads at
  once. `view/peer_links` draws every name and strand as a text node; the
  section is `element.none()` on a page without the capability. Member and
  observer pages never read a board.
- **Allowing for the session, and what it kept** (protocol-change/073).
  Owner only: `component.may_remember` (the owner's `Standing.reader`) gates the
  session button, the list, `want_permissions`, `ask_forget` and the click; a
  member's page offers allow once and deny, and the gateway refuses the same
  commands from a member.
  `component.Answer` is `AllowOnce | AllowForSession | Deny`. The card offers
  `Allow <tool> for this session` after allow once only where
  `approval.rememberable` holds, and `component.decide` asks again at the click
  (`operator.decision` refuses a record that is not eligible) and echoes the
  drawn sequence, digest and grants with `scope: "session"`. The Session pane's
  list of what the session remembers is `view/remembered`, drawn from
  `Shared.remembered` (`session_view/remembered.Board`, which the shared step reads
  with `permissions` and replaces from every `permission_forget` answer) and
  `web_view/remembered.State`: `asked_at`, the open question `Armed(key, forget)`
  and the `Login`s the daemon said have ended. A Forget button's message
  (`operator_page.AskingForget(armed)`) carries the question as the list looked
  when it was drawn, so the second press (`ConfirmingForget`) sends exactly that
  and nothing the browser chose. `component.want_permissions` marks the read owed
  on the operator page's own cadence (`remembered.refresh_ms`, 30 s) and after an
  approval for the session; `component.judge_logins` asks `Transport.logins`
  (`None` on an observer's page) which sign-ins the list names have ended, and the
  answer arrives as `LoginsJudged`. Every path, command, tool, strand and name is a
  text node, and none is a key, a class or an attribute.
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
  (`history_view.resume`) before its window parks, and the row limit
  (`Paging`) parks beside the window in `View.parked_paging`, keyed by strand
  name, so returning to a strand restores its depth; a strand not yet left
  starts at `Tail`. The strand must be listed, must not be the active one, and the
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
  open, resume)` with `sessions: fn(fn(Listing) -> Nil) -> Nil` (`Listed(entries) |
  Unread | Closed(ending)`), started when the timer is wired and every
  `refresh_ms` (`home.refresh_ms`, 30 s) and answered from the daemon's task
  as `Refreshed` (after which `signins` and `who`, the same shape, are started
  and the timer armed) or, after an action, `Answered`; the runtime waits on
  none of them (`ui_socket.read_task`). Each read is numbered (`Model.reads`,
  `home.reads`) and both answers carry their read's number, so a timer's read
  still in flight when an action read again is dropped when it lands rather
  than putting the removed row back, and a dropped `Refreshed` still arms the
  timer. `Closed` ends the page
  (`Status`: `Connecting | Connected | Ended`) and stops the reads; `Unread`
  keeps the last list. The view is `shell.view(shell.Home, ...)`:
  `view/home_bar`, `sidebar.home(groups, open, resume)` (a "Home" entry, then the rows),
  `view/home_table` (a list per project: a heading with the project's directory name
  (`sessions.titles`) and a count, and one item per session with a glyph, the name, and a quiet
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
  `chosen_name` (the one rule for a name) and `folder`.
  A folder with no session (protocol-change/074): `Start.create` takes a
  `creations.Place`, `Drawn(workspace)` or `Typed(path)`, and `Start.folders`
  (`home.Folders(recent, forget)`, `Some` where `create` is) reads the owner's
  remembered folders after each list (`FoldersRead`) and forgets one by identity
  (`Forgetting(id)`). `view/folders` draws the section after the lists: the
  one "New session" button (`OpeningElsewhere`, state `create.Elsewhere`, then
  `CreatingElsewhere(path, name, sharing)` and `create.Sending`) and the remembered folders no group shows, keyed by
  `creations.Recent.id`, each with the usual form (`Choosing`) and "Forget this
  folder". `create.typed_fields` accepts exactly one `path`, one `name`, at most
  one `shareable` and nothing else; `typed_fields_with_roles` also reads at most
  one `folder`, the position of a remembered folder in the select beside the path
  field (a typed path wins). `creations.typed_path`, `expanded` and `inside`
  are the pure half of the rule for a typed path; the daemon holds the filesystem
  half. A path is drawn only as a text node, never an attribute or a key, and a
  refusal is one fixed sentence per reason (`NotAFolder`, `OutsideHome`,
  `HomeItself`, `HiddenFolder`, `StateFolder`). A refusal's place is
  `home_table.Elsewhere`, drawn under the section's heading row. The submit's event is
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
  only the resume page, the claim form and the exchange's confirmation are
  `OwnForms`). `exchange_confirmation(opening, staying, address, ticket)` is
  that confirmation: no script, one form posting the ticket in a hidden field
  to `exchange_action(opening)`, with words chosen by `Opening`
  (`OpensSession`, `OpensHome`, `OpensAdmin`) and `Staying` (`StaysSignedIn`,
  `ForThisPage`). The claim form
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
- **The placement revamp, slice S1** (`docs/design-notes/placement-revamp.md`,
  issue #1055). One sidebar and one composer replace the page-by-page lists and
  the "Runs on" cards, over today's backend: the agent machine is always the
  serving daemon, and nothing in a frozen interface changed. `web_view/listing` is
  the pure half of the sidebar: `Bucket` (`NeedsYou`, `Working`, `Idle`, `Saved`)
  from `Entry.residency` and the activity read, `Place` (`agent`, and `Code`:
  `Folder(path)` or `Registered(executor, workspace)`), `Filter` (`Everywhere` or
  `On(machine)`), `pills` (an executor some session uses, with a count, and the
  daemon's own only when it would not match every row), and `chosen`, the one place
  a press becomes a filter: it admits only a name that a pill carries, so a forged
  one is refused. `view/sidebar` takes a `Page` (`machine`, `filter`, the pills'
  and the "New session" button's messages, `administering`, `managing`, `who`, and
  `doors`: `RowsOpen` where a row opens its session, `RowsShown` on the admin page,
  which mints no ticket) beside the groups, and draws the same column on the home, a
  session page and the admin page: the daemon's name, "New session", the pills, the
  groups, the folded saved sessions, a native `<details>` for the quiet rows past
  `listing.idle_shown`, a row menu (`details.row-menu`) that holds the archive
  control and, on the home, "Rename, move or delete" (which shows the list), and a
  foot. A row's second line is the tag `agent → code`; the subtitle is a third line.
  The component carries `Standing.machine` (the serving daemon's name:
  `server.page_machine`, the node name when distributed and the host name when
  not), `View.filter`, `component.narrow`, `widen` and `waiting_count`, and
  `operator_page.Narrowing`/`Widening`. `view/placement` is the header's placement
  strip (`heading.view`'s `placement`, before the hidden `<loom-title>`): "Agent
  on" the daemon, "Commands on" the executor and workspace or the folder, drawn
  only from the sidebar's row for the session on screen. `<loom-shell>` takes a
  `waiting` attribute (`shell.view`'s last argument, capped at ten), which the
  stylesheet draws as the count on the sidebar's menu button.
  The home opens the owner on the composer (`home.Pane`: `NewSession` or
  `SessionList`; `ShowingNew`, `ShowingList`). `web_view/composer` holds the
  composer's state and rules: `Chip`, `Target` (`Folder`, `TypedFolder`,
  `OnExecutor`, `InPool`), `Offers` (the lists the page was drawn from), `update`
  (a choice is honoured only if `offered`; a start asks only once, only with a
  target, and only for `place`, which judges typed text with
  `creations.typed_path` and `registered_name`), `recents`, `folders_offered` and
  `sentence`. `view/new_session` draws it at `home.table_path`, so the owner's
  socket admits its clicks and its one submit there as before, and the code
  picker's search is the one `input` the owner's socket now admits
  (`ui_socket.home_event`), beneath that region only. Every row is a button whose
  message carries a value the server built; the form's decoder (`new_session.fields`)
  takes exactly the name field and the one more field the chosen target needs. The
  composer creates through `Start.create` with `creations.Private`, so the server
  re-checks the place, the profile and the model as the old form's did. The old form
  and list stay reachable through "Show the full session list" until S4. The admin
  page opens on the Machines tab (`admin.Part`), has the sidebar (`Start.machine`,
  `Start.activity`; `admin.sidebar_path`, whose clicks `admin_accepts` admits) and a
  machine's "Show its sessions", which narrows the sidebar in place.
  The composer's box is the session's first message. `Start.create` takes the
  message as its fifth argument; `ui_socket.create_with` (which `create_for`
  wraps with no message) creates the session exactly as before, opens it, and then
  calls `send` once, for the new session, when the message is not empty:
  `first_message_for` resolves the session as the page's principal and
  `first_prompt` attaches to its gateway with the page's authority capped at
  Operator, subscribes as a page's lane does, sends the one `prompt` frame to the
  main strand and detaches. The text rides inside a JSON string, so it is stored as
  a user message and never interpreted. The session is named from the message's
  first line (`composer.session_name`: trimmed, made safe for one line, at most
  `composer.name_limit` characters). A session that was created and opened but did
  not take the message is kept: the answer is `creations.Unsent(path)`, and the
  composer draws one line and an "Open the session" button, which departs with the
  ticket held in `composer.State.unsent` and never drawn. A message past
  `composer.prompt_limit` is refused on the form before anything is created.
  `upgrade_home` takes `gateway_of`, the one place the concrete instance's gateway
  is read. The bar's own Admin button is not drawn where the sidebar has one in its
  foot, and the bar's brand gives way to the sidebar's top line on a wide window.
- **The session sidebar.** `web_view/sessions` holds `Entry`, `Residency`
  (`Live | Saved | Blocked | FailedStart(reason) | Moving(to)`; `Blocked` is a
  saved row no page may resume, `FailedStart` is a blocked row whose creation
  failed and whose cleaned reason is drawn as a text node (protocol-change/093),
  and `Moving` is a saved row the daemon is handing to the orchestrator
  `to`, drawn as text that says "moving to <to>" with no resume, rename, archive,
  delete or stop (the Admin drawer's row says "moving to <to>" and offers no Make
  shareable); a session that has moved is not an entry, since its new owner lists
  it),
  `Group` and `grouped(entries)` (groups by project: `Entry.project`
  is the repository root the daemon found for the workspace, `None` for one that is
  no repository, and `project_of` falls back to the workspace; the groups
  alphabetical by directory name, ignoring case, never by the session on screen,
  so selecting a session moves nothing; sessions newest first,
  ties by identity and path). `Group.workspace` is where "New session" under the
  heading creates (the project's own checkout when a session runs there, else the
  newest session's workspace, always one the catalogue lists). `titles(groups)` is
  each heading: the directory name, `parent/name` for two projects that share one,
  the whole path if that still collides. `worktree(entry)` is the worktree's
  directory name when a session's workspace is not its project. `view/resume` is the one rule for a saved row
  (`Never | Offered(press, pending)`, `kind` giving `Text | Button | Opening`),
  shared by the sidebar and the home's table. `view/sidebar.view(groups, current, activity, open, resume)`
  draws it as the frame's second child (`aside.sidebar`, the left column;
  `element.none()` where a page draws none), memoized on the groups, the
  identity and the activity. The sidebar draws no strand bars (the Strands panel
  owns strand state). A `nav()` child, `element.none()` today, sits before the first
  group for the app's navigation. A row for a running
  session other than the one on screen is a `button.session-open` whose
  message is `open(id)`; a saved session is one whose message is the resume's
  `press(id)` on an operator page (`operator_page.Resuming`, which
  `component.resume` handles through `Transport.resume`); the current row is
  text, and so is a saved row while another resume is out. The sidebar lists
  running sessions only: the saved ones (and `Blocked`) sit after the groups in
  `div.saved-region`, behind a `<loom-saved>` that holds the quiet "N saved"
  button (`data-saved="toggle"`, no handler), in a `div.saved-panel` the
  stylesheet hides until the element publishes the custom state `shown`. They
  stay in the document, so the switcher still reads their `.session-open`
  buttons; a saved session that is the page on screen is listed above like any
  current row. A project is a
  section whose label the stylesheet draws as a small uppercase eyebrow with
  the session count, and a hairline in the divider colour separates one
  section from the next (team feedback, 2026-09-29); the list's own heading
  is kept for assistive technology and not drawn. A running row's word and dot follow the home's activity
  read: after each list arrives (`SessionsListed`) the component asks `Transport.activity(ids, deliver)` (an
  async task, never in the page runtime; the daemon's `server.home_activity` with
  the page's own credential, so a member hears only of sessions they hold) and
  `ActivityObserved` sets `View.activity`, so the session page says `working`,
  `idle` or `needs you` (classes `residency live working|idle|needs-you`, drawn
  as accent pulse, quiet, signal hue), and `running` until a session is named.
  The read cannot tell an approval from a failed run: `needs you` covers both.
  The read repeats on a `Ticked` every `activity_refresh_ms` (5 s,
  `View.activity_asked_at`), apart from the list's 30 s, and asks nothing while
  the page holds no list. The page's own row never takes the read's answer:
  `component.session_activity` replaces it with `live_activity`, the strip's
  strand statuses (`needing() > 0`, or main failed with nothing running, is
  `NeedsYou`; a working or waiting strand is `Working`; otherwise `Idle`), so
  the row never lags the Strands panel; before a first capture the read's
  answer stands. The page cannot see whether its tab is visible, so the 5 s
  read runs whether or not it is. The
  component starts `Transport.sessions` on `Opened` and on a `Ticked` at
  least `sessions_refresh_ms` (30 s) after the last read (the read runs in
  the daemon's task and lands as `SessionsListed`; a read that is slow or
  never answers leaves the page working with an empty sidebar,
  `sidebar_test`), keeps at most
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
  `StopConfirmed`, `DeleteConfirmed`, `ConfirmCancelled` and `ActionAnswered`. `home_table.Manage` (`Unmanaged | Withheld | Managed`; `Withheld` is the owner's bookmark home, which has `Start.rename` and no `Start.manage`, and draws one `p.home-withheld` sentence after the lists saying Admin, Stop, Archive and Delete are only on the home `loom ui` opens; the home's row buttons sit in three fixed grid columns, Rename first)
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
- **Archiving from the sidebar** (protocol-change/065, the addendum on archiving
  from the sidebar). `view/archiving` (`Archiving(message)`: `Never | Offered(ask,
  confirm, cancel, stage)`) is what a page passes `sidebar.view` and `sidebar.home`
  as their last argument. `Offered` draws `button.session-archive` after each
  other row's own button (a 24px square holding `×`, its `aria-label` and `title`
  `Archive` on a saved or blocked row and `Stop and archive` on a running one; the
  row reserves a right-padding column for it, so it never covers the name, dot or
  activity word, hover and focus reveal it in the stylesheet, and it stays in
  the tab order) and, while the row is asking, `li.session.confirming` holding the
  question (`div.session-confirm`: a fixed sentence, the session's name as a text
  node, a confirm and a Cancel). A running row whose activity read is working or
  needs-you asks `Stop this session mid-turn, then archive it?` (`archiving.Turn`,
  `MidTurn | AtRest`, derived in `sidebar.turn`). The session on screen has no button and a `title`
  that says why. The memo key includes `archiving.stage`. `archiving.action(entry)`
  is the action a press means (`StopArchive` for `Live`, `Archive` otherwise) and
  is read from the page's own list, never from the message; `archiving.confirmed`
  gives the action a confirm may act on only when the open question is the
  sidebar's for that session. The home reuses its `acting` stage (`home.Msg`
  `SidebarArchiveAsked`, `SidebarArchiveConfirmed`, `ConfirmCancelled`;
  `home_table.in_row` treats the sidebar's two actions as calm so the table does
  not draw the same question). The session page has `Transport.manage` (the home's
  capability from `home_manage_capability`), `View.archiving`, `component.ask_archive`,
  `confirm_archive`, `cancel_archive`, `Msg.ManageAnswered` (effect-owned, which
  words the composer's notice and reads the list again) and
  `operator_page.AskingArchive | ConfirmingArchive | CancellingArchive`. The new
  action `actions.StopArchive` is one daemon task (`manage_for` stops, waits for
  the session to be saved, archives). `sidebar_archive_test` reads it.
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
  holds the newest turns of `main` whose drawn rows fit `live_rows`, cut
  between turns (`turns.grouped`); once the reader loads older turns its limit is
  `held_rows`. The limit counts drawn rows: a settled turn is its prompt, its
  answer and one divider, and its steps are drawn only while the reader has
  its fold open (below). `component.Paging` is `Tail | Paged | Crowded | Full |
  Browsing`. `Full` and `Crowded` describe pressure on the live turn-summary
  view; both still offer Load older. Another press enters `Browsing`, as does
  an older press on a running turn already filling `live_rows`. `browse_at`
  freezes the displayed record suffix or starts a read at the oldest held
  summary. `browsed` draws the oldest blocks that fit `held_rows` and lowers
  the frozen endpoint when newer records leave the page. The shared
  `history_view` bounds retained records to 600 and payload to 16 MiB; range
  reads use its existing correlated `Wanted` / `Pending` demand. New captures
  continue updating live metadata and never move that historical endpoint.
  The last historical group remains open even if the live operation settles,
  because the endpoint may cut a turn. No live preview is drawn below it.
  `latest_at` retires the historical demand, clears historical fold state and
  projects the newest captured tail. A late history reply cannot attach.
  The history mode parks with each strand's window.
- **Return from history.** `lane.navigable` places the return button at
  `component.latest_path` (`0\t2\t1\t0\t1`), beside the fixed older path,
  on both pages and even at the beginning. Its `data-loom-latest` marker is
  fixed. `<loom-follow history="reading">` keeps the floating Jump to latest
  offered regardless of scroll gap, and activates that server handler on a
  jump or composer send. The observer socket admits only a click at that
  exact path (protocol-change/051, the history browsing addendum).
- **Lazy folds** (protocol-change/070, `session_view/fold_budget`) and
  **turn summaries** (protocol-change/071, `session_view/turn_ledger`). A closed
  turn is not kept as records. `relaned` closes every turn of the history window
  whose records are all in it and that nothing will be added to (every turn but
  the newest, and the newest once its strand settles) into a `turn_ledger.Sealed`
  (`View.sealed`, newest first, held to `fold_budget.sealed_bytes` of text beside
  the row limit), drops the window's records up to the newest
  closed turn's last (`frontier`, `trimmed`), and draws the closed turns from
  their summaries and the window's turns from its blocks. The window holds the
  running turn and nothing older, so a turn of a thousand records costs the page
  what a turn of two does. The row limit counts what is drawn: `fold_budget.fit`
  takes the weights of the window's turns and then the closed turns, newest
  first, and the closed turns that do not fit are dropped from `View.sealed`
  (`Paging` goes `Full` when a paged page had to cut). A closed turn's divider is
  `Folded` (no steps), `Reading` (open, steps not here yet) or `Unfolded(hidden)`
  (open, with the newest steps read for it). `View.steps` holds the steps of
  each open fold by its number, `View.folds` the open numbers most recently
  opened first, and both are cut to the folds `fit` grants.
  The page reads when it wants something, one read at a time (`View.purpose`:
  `Resting | ForOlder | ForLead | ForTail | ForSteps(fold)`), through the history
  window's scan (`history_view.scan`), which walks the strand's own parent
  links a page of at most a hundred records at a time (`history_lineage`,
  protocol-change/072) and keeps what it reads apart from the window. `begun`, at the end of a projection, starts the first of: `ForTail`,
  the strand's newest turns, when the window holds none of the strand's records
  and no turn is closed (`unread_tail`). A gateway's cut is the newest records of
  the whole session, so another strand that wrote past a settled one (the advisor
  reviewing it) leaves the leaf below the cut, and an empty window is not an empty
  strand: it reads from the leaf, as the turns below the window are read, once
  (a refusal sets `Completion` to `Spent`, and the page then offers Load older,
  whose press reads from the leaf again; a cut that names no leaf is the
  beginning). Another strand's records between the strand's own cost the walk
  nothing, so a strand sparse among the session's sequences is read as a dense
  one is; a read that finds nothing below what the scan holds ends it
  (`Bottomed`). `ForLead`, the start
  of the turn the window began inside (a page opened on a settled session holds
  only the end of its newest turn, and draws nothing for it until the start is
  read, so the divider's figures are the turn's), `ForSteps`, the newest
  `fold_rows` rows of steps of an open fold of a closed turn (from the turn's
  last record, which the summary holds), and `ForOlder`, after a press of "Load
  older" (`View.older: Pressed`, from the parent of the oldest closed turn's
  first record, until ten whole turns, the strand's first record or the scan's
  bound). Each read begins with the records the page already holds, the cut and
  the window, and asks the daemon only for what those do not settle; when they
  settle it the projection runs again in the same message (`relaid`, `Answered`).
  The read is sent by `serviced` at the end of the message that wanted it, the
  step's tick, and a reply folds in as any frame does, so a scan is a chain of
  messages and no timer. A refused or lost read is given up (`abandoned`): the
  press can be made again, a lead is drawn as far as it is known
  (`View.completion: Spent`, also what a read that ended before the turn's input
  leaves, so older closed turns are untouched; it holds for that lead only and
  is `Untried` again once the lead has been closed, `completion_after`), and a
  fold says how many steps it did not show. Records that arrive after a closed turn with no input of
  their own are read with that turn again (`lead_of`, `beside`). A parked
  strand's closed turns are dropped with its window. No block the closed
  turns cover reaches the window's groups (`uncovered`, in `laid_out`): the
  advisor's commentary is projected from the capture's whole window and keeps
  blocks older than the newest closed turn's end. Before this, such a block
  stayed in the window as a group of its own, the count of closed groups no
  longer matched the groups dropped, and the newest closed turn was drawn from
  its summary and from the window again (`closed_turn_test`).
  `FoldToggled(fold)` opens or closes a fold (`folded_at`): it acts only on a
  `Connected` page with a cut and only on a number that is the id of a fold the
  page draws, as `OlderRequested` acts only on a page that is reading, and a
  press on a closed turn's fold reads no more than that fold's own steps. The
  divider is a button (`lane.divider`) with the fixed `data-loom-fold` marker;
  both pages draw it with `lane.Folds`, and an observer's socket admits its click
  at `component.fold_click`'s exact path; the events admitted are the same as
  under 070. A message the shared projection shortened (a long paste, an
  injected message) is drawn by `lane.message_row` as that row and a
  `button.message-toggle` after it, in one `div.message`; `MessageToggled(key)`
  (the block's key, drawn into the handler) opens or closes it (`messaged`),
  acts only on a `Connected` page and only on a key `turns.abridges` finds in
  the lane, and keeps at most `open_messages` open in `View.said`, newest first,
  which a focus change clears. The whole text is read from the entry the block
  holds (`turns.abridged`), so a sealed turn needs no read, is cut by
  `expansion.capped` and is drawn only while open. Observer sockets admit the
  button's click at `component.message_click`'s two exact paths (the protocol-change/070 addendum on messages).
  A step still running draws `Running · ` and `<loom-elapsed since>` from
  `turns.Step.since` (`fold_row.step`), and the composer's hint draws a pulsing
  `span.busy-dot` while a turn runs (`operator_page.busy_mark`); the stylesheet's
  reduced-motion rule stills both. `component.top(model)` is the `lane.Top` the lane draws above its
  oldest row (`Beginning`, `Earlier`, `Loading` while the page reads turns,
  `Full(rows)`); the strands a reader left park their closed turns with their
  paging (`View.parked_sealed`). The Changes and Trace boards and the newest tool
  result are joined from the closed turns' and the window's
  (`changes_view.append`, `trace_view.append`, `turn_ledger.latest_result`), and
  a cache miss noticed after its turn closed is drawn after the turn's pieces
  (`late_misses`). `component.rows` and `lines` are the rows the page draws, with
  a closed turn's work as one divider row, and not the transcript's whole lines.
- The view, one module per screen region under `web_view/view/`, laid out
  by `component.view` and `operator_page.view`. None of them imports
  `component`, which imports them, so each takes what it draws as its own
  types or plain values. `heading.view(session_id, home, name,
  workspace, model, status, tone, context, breakdown, cost, notice)` draws the top bar (the brand,
  `home`, the workspace's path with the home directory as `~` and then the name as two
  spans, the name in a `span.session-title` that also holds the main strand's
  model as quiet `span.session-model` text (`component.heading` reads it from
  the capture: `agent_view.catalogue_name`, the catalogue entry named in the
  strand's configuration; the `h1` keeps the name alone, which
  `<loom-title>` reads, and the wrapper keeps the bar's child positions), the status as a `.pill` whose class follows the `Tone`
  (`online | pending | ended`), the `ctx ~41%` estimate and the cost
  `transcript_lines.cost_words` words as `est $0.04` or `est —` when tokens
  were spent and none priced, and the last timed generation's `87 tok/s`
  (`session_view/model.output_rate_tps`, `rate`, drawn only once the selected strand has a complete timed settlement), each as a word and a `span.num`; a figure with no
  value is not drawn, so no `est` for an unpriced model and no `ctx` on the
  primary strand before its first turn), with the ended
  page's notice as its last child; `component.heading(model, going_home, context_actions)` reads those
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
  exist, and words otherwise. The `<loom-follow>` around it carries
  `data-strand-key`, `marks.key`, a small number the page assigns each strand
  the first time it shows it (`View.strand_keys`, never the name), under which the element keeps the reader's
  scroll place per strand (protocol-change/051, the addendum on the strand key).
- **The timeline and the marker controls.** Each piece of the lane is a
  `div.tl-row` holding a `span.dot` (decoration, `aria-hidden`, in the hue of
  the strand the piece belongs to, on a line down the left edge) and the
  piece. `lane.Marks(active, hue, positions, key)` is what the lane needs to place
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
- **Program cards.** A foreground `code_mode` call is not a row but a card
  (`view/program_card`, drawn by `lane.item_element` when `turns.Step.program`
  is set; the projection is `session_view/program_card`). The card is a native
  `<details>`: closed it is one line (the outcome sentence, chips for writes,
  commands, requests and failures, the call count, the time), and a program
  that failed or whose calls did draws open. Its sections are Program (the
  first four lines, the whole program behind a control when the host kept it),
  Calls (a timeline row per run of consecutive calls with a bar of two bounded
  percentages, opening to the redacted summary, error code and timing the
  record holds) and Result or Error (a compiler's diagnostic laid out with its
  line marked). A running program shows its opening and a `<loom-elapsed>`
  counted from `Step.since`; the record is written at settlement, so it has no
  calls yet. The whole program and value are cut by the same `Expansion` as an
  expanded row, so a sealed turn draws only the opening. The card has no
  handler, all session text is a text node, and a class comes from a closed
  type. There is no copy button: a client element that writes server-chosen
  text to the clipboard needs its own ruling under protocol-change/051.
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
  `Shared.summaries`, the generation clock and the inputs the daemon holds
  for the strand (the capture's `pending_inputs`, through
  `transcript_lines.held_inputs`, the terminal's rule) into `live.Row`s, and
  `lane.view(pieces, live, top, load, replies)` draws them through `view/live` as the
  lane's last keyed entry, keyed `live`. `live.Thinking(progress, text,
  elapsed_ms, headline)` is the reasoning row, drawn by `fold_row.live_reasoning`
  as a `<loom-expand kind="live">`: `Reasoning · <loom-elapsed offset>` and a
  one-line Markdown preview of the latest line, with the reasoning so far
  behind the chevron. The body is drawn a paragraph at a time, cut at the last
  blank line, so each render's `draw` memo holds for the earlier paragraphs and
  only the one still being written is parsed. The line count is the row's
  `title`, and the headline is text beneath it when one has been pushed. A
  settled reasoning row is `kind="settled"` and carries `handoff="yes"` only
  when it is the lane's newest settled reasoning row (`lane.newest_thought`),
  `handoff="no"` otherwise; an open live row publishes
  `data-reasoning-open-until` on the document element and the settled row that
  arrives takes it and opens (`web_client/expand`). A settled reasoning block of
  every speaker shape (`ReasoningDigest` with or without `thoughts`,
  `Reasoning`, `SummarizedReasoning`) is drawn by `lane.reasoning_row`:
  `step_words.reasoning_of` heading (`Reasoning (summarized)`, the line count
  when there is more to open, the time), a one-line preview, and the text as
  Markdown behind the chevron. A summarized block whose label is longer than
  that one line (`lane.summary_row`) opens with the whole label first, then
  the block's own text; the heading still counts the block's lines.
  `live.Opened(elapsed_ms)` is the
  row before anything streams: while the followed strand's phase is `assistant`
  or `streaming` and no stream is held, `component.live` returns it alone,
  `Thinking · <loom-elapsed offset>` (the browser counts the reading on, so no
  server timer; before the generation clock starts it says `Thinking` alone).
  The first fragment replaces it with `Reasoning` or the answer. The shared
  `generation_rate` ledger observes captures for every strand, and focus reads
  the selected strand's existing clock without resetting it. Joining an already
  running request starts a partial observation window and leaves its
  full-request TPS unmeasured. The region is a row of the
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
  of 576 to 668 bytes on the real runtime). `live.Held(text, words)` rows
  follow the streams: one per input the daemon holds for the strand on
  screen, a steer not yet folded in or a prompt queued behind the turn,
  the daemon's excerpt of the person's words and beneath it
  `transcript_lines.held_words` (`steer · runs next`, `queued · after this
  turn`), both text nodes in a quiet `div.held`. A capture lists them, so a
  message the daemon took but has not run is on the page from the capture
  that first lists it until the one that no longer does; no read or socket
  event is added (`live_test` pins the row's arrival and departure).
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
- A settled reasoning row shows the summarizer's label as the terminal does
  (`Reasoning (summarized) · N lines · T`, the label as the preview, the block's
  own text behind the chevron). `component.pieces` applies the labels from
  `Shared.summaries` on every read (`session_view/turn_labels.apply`), so a block
  that streamed with a live label keeps it when it settles and until its stored
  label arrives, and a sealed turn or an opened fold shows a label that arrives
  later with nothing re-sealed. `relaned` marks the long reasoning blocks the
  pieces draw as wanted (`labels_wanted`, `turn_labels.keys`), so blocks that
  arrived through a lineage read or an opened fold are read like the window's;
  the shared step's tick sends the `block_summaries` read (at most
  `block_summary.max_blocks` names, each block asked once per attachment), and
  `serviced` ticks when one is owed. The lane draws the label only as a text
  node (`lane.summary_row`).
- A decided approval is a `turns.Decided` piece: `session_view/decisions`
  reads the approval ledger (`shared.approvals`) and the strands the
  captures saw pending requests raised on (`View.raised`), and
  `turns.with_decisions`, called by `component.pieces`, places each by the
  register sequence that committed it. The lane draws
  `p.decided` with the author, the verb and the tool as text nodes.
  A page opened after a decision never saw the request pending, so it reads
  `escalations_decided` once (`View.decided`, `component.decisions_read`,
  sent when the lane is idle after the capture's own reads and never queued)
  and folds the answer into the ledger as an exact lookup would. The record's
  own scope names the strand, so the row is the one a page that watched the
  decision draws; the ledger is keyed by escalation id, so a decision seen
  live and read again is one row. The read is `protocol-change/015`'s
  decided-approvals addendum.
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
  summary of a `<loom-fold>` (the one place the element is still used for
  its own local state: the browser keeps its open state, so a patch
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
- The Changes pane reads the workspace for an owner's or an operator's page
  (protocol-change/051, the addendum of 2026-10-05). `Transport.worktree` is
  `None` on an observer's page and otherwise a capability that returns at once
  and answers as `Worktreed`; `web_view/worktrees` holds `Read`, `Asking`,
  `latest_result` and the timings. `component.observed`, run at the end of every
  message, asks once when the page opens and again after a tool result the last
  read did not see, at most once in `worktrees.refresh_ms`, never while one is
  out unless it has been out `lost_ms`. `changes.view(board, window, read)`
  draws `view/worktree` for a board of a checkout and otherwise the edit board
  below, with one sentence when the read was refused, failed or found no
  checkout. Everything in a board is a text node; a failure's text is never
  forwarded.
- `changes.view(board, window, read)` draws the edit board as the Changes pane, the panel's second, on both
  pages from `component.changes(model)`, the board `session_view/changes_view`
  folds from the records of the window the page projects (`relaned` builds it
  with the transcript, so a message that moved neither costs no fold). Its
  heading is `Changes · 2 files · +14 -2` with `from this session's edits`
  under it (omitted when a reason sentence already says it), then one `<details>` per file with the first open. Paths and diff
  rows are text nodes; a row's class is one of four literals chosen from the
  fold's `Kind`; a file the session only wrote reads `written · N lines` where
  an edit's counts go. It has no handler and is memoized on the board. With no edit
  it is the heading and one line saying so, so the pane is always drawn and
  the panes after it never move. It reads no worktree: the daemon serves
  worktree bytes to an Owner binding only.
- `session_tab.view(goal, cost, jobs, viewers, workspace, share, controls, rename, remembered)`
  draws the Session pane, the panel's third. Its children are the title, a
  memoized `div.session-rows` of groups, `share`, `controls`, `rename` and
  `remembered`, in that order so the controls' paths never move (`invite_path`,
  `session_controls_path`, `rename_path`, `remembered_path`). The groups read Session (the name
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
  built, the agent row's `model` and `recent` tools, and `own_model`, the
  catalogue name of the strand's model when it is not `main`'s, which the card
  draws as plain `span.chip-model` text under its status), the advisor's chip
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
  body, and a `pre` keeps the heading a line of its own. So are the three
  program blocks (`program-running`, `program-settled`, `program-failure`), whose text is
  already laid out line by line, and an image's row (`image-row`).
  The model holds no trees. `lane.view` draws every transcript line and
  card body inside its own `element.memo` keyed on that line or body, with
  no memo around them (`lane.rows`), so a line is parsed and drawn when it
  first appears and Lustre reuses its element after that. A failed step
  instead keeps its refusal and remaining rows in one leaf keyed on its
  words and rows (`fold_row.step_body`). It draws those rows directly, so
  unchanged failures repeat neither joins nor Unicode trims, and it nests
  no line memos. `render_work_test` checks repeated hits, invalidation and
  escaped output. Lustre forgets
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
  no peer link exists to answer through. Peer and sibling pieces hold the
  whole message; `lane.message_body` draws one the composer would shorten as
  its collapsed line with a client-side `<loom-expand>` to the whole text (cut
  by `expansion.capped`), so opening it asks the daemon for nothing.
  `component.pending_nudges(model)` and `component.goal(model)` read
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
  JSON text in the composer element's `commands` slot. `completion.table_with`
  adds the daemon's model and profile names, captured in `component.Start`
  when an operator page opens. `/model` continues into those argument rows.
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
  `client/daemon/ui_socket`. `ConnectionFailed`, `NotOpen` and `DaemonNotReady`
  retry; access revocation, an ended page and a stopped session stay final.
  Protocol-change/097 makes a failed page reconnect with a fresh lane and
  snapshot without replaying a command of unknown outcome. Its advice states
  automatic recovery rather than asking for a new link. `operator_page_test`
  verifies that a new component subscribes without reissuing the old prompt.
  `view/ended.view(option(ending), session_id)` draws
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
  `content_security_policy(socket)`, whose argument is the page's whole socket
  origin, `ws://<loopback host>` or `wss://<listed host>`, which the daemon
  derives from the origin the request was admitted under
  (protocol-change/052).

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
  advisor's pending nudges and the goal. Also the strand's lineage read
  (`session_channel.lineage`, `history_lineage`) for at most 100 of the strand's
  own records from the parent of the oldest one the page lacks, and, for the
  history window's own demand, which this host does not make, the terminal's
  `history` interval read. The summary labels' read is not sent.
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
  `<loom-composer returned refused>`, which lists the slash commands as
  the draft grows, sends the draft on Command or Control with Enter (by
  submitting the composer form), puts a returned prompt in the editor, and
  shows a pressed draft as a pending line until the server takes it.
  Its inputs are the `commands` table, the `returned` count, the
  returned prompts as text-node children in a `returned` slot, numbered by
  `data-n`, and the `refused` count (`component.refusals`: the submits the
  page or the lane's admission check refused with the draft kept), which
  tells the element a press was refused while the editor stayed; the editor stays the
  uncontrolled textarea, and keeps its place when a return arrives. A taken
  draft replaces the editor and the element with it, which is how the
  pending line leaves.
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
- **The page's rows are bounded.** The page draws at most `live_rows`
  rows, or `held_rows` once paged, plus `fold_budget.fold_rows` for open folds (a settled turn costs its prompt, answer and
  divider, and an open fold its steps), plus at most one block when the newest
  turn alone is longer than the limit; loading older rows past the limit
  is refused (`Full`), never allowed to grow the page. The records of a folded
  turn stay in the history window, so the model holds them though the runtime
  retains none of their elements; a read adds at most a hundred records. Once rows are cut,
  the history window is trimmed to the oldest record drawn
  (`history_view.retain_from`), so what a capture projects is in
  proportion to the page. The page starts at a turn's input whenever it
  can, so prepending older rows and sliding the window leave every held
  turn's key, and its lines' memos, as they were (`lane_memo_test`). The
  undrawn end of a turn whose input is older stays in the window so the
  next read goes below it, and counts as cut once it alone no longer fits.
- **One read at a time.** The lineage read goes out only when the lane has
  no request out (`session_channel.lineage` refuses a busy lane); until
  then the demand stays `Owed` and every reduction offers it again. The
  reply, a refusal or the lane's failure is what ends it. The button is
  offered only while the strand has turns below the ones the page holds. The
  lane says it is loading until the first cut has arrived, and says the
  conversation begins only when a read of the strand found it.
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
  attaches the lane's "Load older" click (`OlderRequested`, a read), one
  click per strip chip (`FocusRequested`, a change of what the page shows,
  built from the name the strip was drawn with) and one per settled turn's
  divider (`FoldToggled`, which draws or drops steps of records the page
  already holds); its bar is a fixed text
  node. The page socket admits from an observer only a click at
  `component.older_path`, beneath `component.strip_path` or at a divider's
  exact path (`component.fold_click`; protocol-change/051, the addenda on
  history paging and strand focus, and 070), and
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

The proposals review is the Session pane's eighth child
(`component.proposals_path`). It is drawn and read only where
`may_review_proposals` holds, Approve asks first, and `confirm_approval`
re-checks the held board before it sends. A `history_search` step needs no
component of its own: it is the generic step row plus `recall_view` rows.

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

## Remote children in the context panel (protocol-change/084)

`context_breakdown.panel_with_remote(state, remote, actions)` is `panel` plus a
section after the board that lists the children that ran on other orchestrators,
one row for each orchestrator (`remote_usage_words.entry`, text nodes). `panel`
is `panel_with_remote` with no entries, and `component.heading` passes
`model.shared.remote_usage`.

## Remote children and the peek (protocol-change/090)

`component.strip_of` lists `agent_roster.remote_rows` after the session's rows,
and `view/strip` names a placed card `<child> @ <orchestrator>` with a quiet
`chip-seen` line once its glance is a minute old. `focus_at` sends a remote
child's card to `peek_at`, which runs `command.Peek` through `commanded` as a
control (`msg.Control`), and every other card to `focus_strand_at` after
closing any peek. `detail` draws `view/peek` while `shared.peek` is open: the
strand view's back link, the framing lines, and each entry's speaker and words
as text nodes (`peek-*` classes). No new event class, path, scope or CSP change.
Tests: `remote_peek_test`.

## Model profiles in the new-session forms (protocol 076)

`Start.profiles` is the list of profile names the daemon's configuration defines,
read when the page opens and `[]` unless `Start.create` is `Some`.
`view/create.Offered` carries it, and both forms draw a `profile` select after the
Shareable box only when it is not empty. A profile name is the daemon's text, so
it is an option's label and never an attribute; an option's value is its position
in the list, and `create.fields_with_profile` / `typed_fields_with_profile` turn
the submitted position back into the name from that same list, refusing a
position outside it, a name, a repeat, and a `profile` field on a form that
offered none. `home.Creating` and `home.CreatingElsewhere` carry the chosen
`Option(String)`, the component ignores a profile that is not in `Start.profiles`,
and `Start.create` passes it to the daemon. The daemon checks it again against its
configuration; a profile removed since is `creations.UnknownProfile`, whose fixed
words say to reload the page.

### Model keys beside profiles (protocol 080)

`Start.models` is the list of `[models.<key>]` keys the daemon's configuration
defines, read with the profile names and `[]` unless `Start.create` is `Some`.
`view/create.Offered.models` carries it, and both forms draw a "Main model"
select (`name="model"`) after the profile select only when it is not empty. The
select is independent of the profile one: a form may draw either, both or
neither. Keys are drawn exactly as profile names are (a text node, a position as
the value, the profile row's stylesheet classes), and `create.fields_with_roles` /
`typed_fields_with_roles` read each field against its own list, so a position
offered for profiles is never read as a model. The profile and the model travel
together as one `creations.Roles(profile, model)` (`creations.default_roles` is
neither): `home.Creating`, `home.CreatingElsewhere`, the `Start.create` closure
and `create.Offered`'s submits all take it, and `home.offered_roles` checks both
fields against the page's lists. Only the key string reaches the page; no URL,
key variable, upstream identifier or pricing does. A key removed since the page
opened is `creations.UnknownModel`, whose fixed words say to reload the page.

## Sessions on an executor (protocol 078)

`Start.executors` and `Start.pools` are the `[executors.<name>]` and
`[pools.<name>]` names the daemon was configured with, `[]` unless `Start.create`
is `Some` (`ui_socket.upgrade_home` copies `server.HomeAttachment.executors` and
`.pools`, the daemon's startup capture, so no read is made for the names). When
either is not empty the one "New session" form (`create.new_form`) opens with a
"Runs on" choice, and `create.State` gains `Chosen(choice)` (an executor or a pool
chosen, its workspace form drawn) and `Dispatching(choice)` (creation out), which
behave as `Elsewhere` (this machine, the default) and `Sending` do. There is no
separate button and no `Remote` state: `home.ChoosingHere` returns to this machine.
The workspace form for a choice is a select of the workspaces that place
registered (`name=workspace`, values are positions into
`placements.workspaces(cards, choice)`, decoded by `create.remote_fields`) and the
optional session name; a place with no known workspace draws a note and a text field for the name
(`create.typed_workspace_field`, held to `creations.registered_name` by
`remote_fields`), and the daemon's refusal returns on the form. There is no Shareable box, because the daemon makes a session on an
executor or in a pool session-only, and the profile and model selects are the same
as on the folder form (`create.remote_fields_with_roles`). `Start.machine` is the
daemon's own name, worded `<name> (this machine)` on the first card.

## Executor and pool cards (protocol-change/085)

The "Runs on" choice draws a card for this machine and then for each executor and
each pool (`create.places`, `here_card`, `executor_card`, `pool_card`), in the
configuration's order, executors first: the name, the kind, a state pill, the
facts, and a Choose button. The cards come from
`placements.Cards`: `placements.listed` builds them from the names alone
(`Readiness` `Checking`), and the daemon's read replaces them
(`placements.after`, which marks the cards `Checked`; the daemon's read always
carries a report, so the page has no value for a read that gave nothing). The
state is `placements.State` (`Ready`, `Degraded`, `Full`, `Down`) drawn in the
pill tints the page already has (`placements.pill_class`: `online`, `pending` for
a degraded executor, `ended` for a full or a down one), so no colour is added. An
executor that answered also carries `free_scopes` and `contradiction` in its
`placements.Report`, and its card draws them as two paragraphs ("N scopes free."
and the words of the contradiction) beside the operator's declaration, each a text
node. A state is advice: the panel never refuses a card because of it,
a `Down` executor can be chosen, and the panel says so in a line above the
cards; the daemon decides again when the session opens. The fact of an executor
is what its operator declared (worded as a claim); a pool's are how many of its
admitted executors were reached and the order a first open tries them, which
health does not change.

`Start.placements` starts the read: `home.OpeningElsewhere` (when the daemon has
any place) numbers it
(`Model.place_reads`) and runs it through `placing`, an `effect.from` that hands
the daemon a function and returns at once; the answer is
`home.PlacementsRead(serial, read)`, dropped when a newer read overtook it, and
no browser can send it. The daemon side is `ui_socket.upgrade_home`, which gives
the page `read_task(deliver, attachment.placements)`, so the up to one second the
connections take is spent in a weft run and never in the page's runtime. The
read is `server.HomeAttachment.placements`, which is
`client/deployment.placed` (the executors alone) reduced by
`deployment.for_page`; the page is told a state, a declaration and a trial order
and no node name, address or key.

A card's button sends `home.ChoosingPlace(choice)`, with `placements.Choice` =
`OnExecutor(name)` | `InPool(name)` built by the server from the names it holds,
so the browser names no text; the component honours it only while the form is
open, no creation is out, and `placements.offers` finds the card. The chosen
placement is the page's state, not a field of the form: `create.remote_fields`
accepts exactly one `workspace` (a position), one `name` and the two optional
selects, so a forged `executor` or `pool` field is an extra field and refuses the
event, and `home.CreatingRemote(workspace, name, roles)` asks the daemon only from
`Chosen`. `placements.Report.workspaces` and `PoolReport.workspaces` carry the
names the select offers (`deployment.for_page` fills them from the executors'
reports). The cards are a keyed list whose keys
are positions (`e0`, `p1`), never a name: the lists are the daemon's startup
capture and cannot change while the page is open. No event class is added: a card
is a click beneath the sessions list's section, where the home already admits
one (`ui_socket_test.a_card_needs_no_new_event_class_test`). Every name and platform
is a text node and no class is built from one.

`creations.Place` gains `Registered(executor, workspace)` and
`Pooled(pool, workspace)`. `creations.registered_name` is the one rule for the
text (trimmed, 1 to 128 bytes, no `/`, no control, zero-width or
direction-changing character), applied by the daemon (`ui_socket.placed`) and not
by the page, whose text field is the browser's. The daemon never statts,
canonicalizes or creates the name on its own host; the executor or pool is judged
by `server.create_session`, whose `executor_unknown` and `pool_unknown` are
`creations.UnknownExecutor` and `creations.UnknownPool`, and a bad name is
`creations.InvalidWorkspaceName`. `ui_socket.create_for` forces the session-only
scope for either place whatever the sharing was, and a pooled creation carries
the pool and no executor (`ui_socket.pool_of`), so the daemon picks the executor
when the session first opens. A session made and not opened (the executor
unreachable) is the existing `Unstarted`, which shows the owner's own startup
reason, for example `executor_unavailable: ...`.

`sessions.Entry` gains `executor: Option(String)`, filled from the registration
(`ui_socket.listed_entry`) and never from a page. A remote entry's group key and
heading is `executor:name` (`sessions.project_of`), so two executors that each
register `app` are two groups; it has no project (`ui_socket.with_projects` skips
it) and no worktree, and its group draws no "New session" button, because a
directory's button creates a `Drawn` place and the daemon would refuse a name it
holds no folder for. The sidebar and the home draw the key as the heading.
Tests are `executor_form_test` (the cards, their states, the choice, the
messages, the decoder, the lists, a stale read) and, in `client`, `ui_route_test`
(`create_for` for an executor and a pool), `ui_socket_test` (admission) and
`deployment_test` (`placed` and `for_page`), the daemon's half.

## Large result access

`tool_result` renders links to immutable result records, a bounded escaped page
and full JSON download navigation (protocol change 079). Both joined steps and
orphan result blocks offer those links. `view/expansion` uses `utf8_window` to
keep its preview within 8,000 UTF-8 bytes without grapheme-scanning the complete
output. The viewer's 16,000-byte windows partition complete codepoints; its
requests and storage reads belong to client, not to the component or this
package. No browser websocket event or component reader was added.

## `/profile` on the page (protocol 082)

The page runs `/profile` and `/model-profile` because they are session commands
(`component.page_command` passes every `command.Session`), so no component, route
or asset changed. `completion.rows` offers both spellings and `/profile default`
automatically. `completion.table_with` adds configured profiles under both
spellings and configured model keys under `/model`, as escaped slotted text. The answer is written to the transcript as text by the
shared fold. A switch restarts the session, so the page shows the session-stopped
notice and the owner reloads it, as after making a session shareable. A member
operator is refused `forbidden` by the hub, which the page shows as the refusal.

## Model and profile completion

The operator page captures configured model keys and profile names once at
socket admission (`ui_socket.admit`, `component.Start.completion_models` and
`completion_profiles`); observer pages receive empty lists. These are suggestions,
not authority: the existing model and profile commands validate at execution.
The composer keeps the full JSON table as escaped text in its `commands` slot.
`CommandsChanged` and connection setup read that child through existing DOM
bindings; `Configured` replaces the table and resets its selection without
changing the draft. Prefix matching, keyboard selection and click selection
use `composer_rule` as before. Reopen the page to refresh configuration names.

## Inline held-input controls (protocol 088)

`view/queue_input.State` owns the page's selected complete document and
`Ready`, `Saving`, or `Unknown` delivery state. `component.QueueAction` runs
its controls through the shared lane; `queue_request.Notice` is consumed before
`step.forget_surfaces` clears it. `lane.WithQueue` offers the row renderer only
on the operator page. Live rows are keyed by opaque queue identity, so removing
a neighboring row cannot rebind the editor. Excerpts never populate it.

The textarea is uncontrolled: unsaved keystrokes remain in the browser during
server patches. A failed save retains text, an uncertain save locks resubmission,
and a selected row that leaves the capture retains its draft until cancellation.
Save checks attachment, namespace, identity, revision and explicit editability.
The browser supplies only one bounded `text` form field; it cannot choose a
queue identity or revision. Observers draw held text without mutation controls.
## Strand notes

The appended Notes pane is `component.notes_path` (`0\t3\t5`), after all existing
panel children; its search input is exactly `component.notes_search_path`
(`0\t3\t5\t2\t0`). `notes.State` holds one focused strand's bounded board,
query, selected key, read progress and presentation cache. Snapshot adoption
projects previews and safe Markdown once, and assigns numeric row identities
that survive filtering and refresh. The view (`view/notes`) keeps the index
mounted while detail is open. Keys and values are text nodes; Raw value is the
supplied text and Excerpt never enters a parser.

`component.NotesPressed(strand, press)` and `NotesSearched(strand, query)` reject
handlers from a former scope. Refresh uses `Shared.notes_requested` through the
existing lane, coalesces repeated presses and reports unavailable reads. The web
host uses `step.update_retaining_surfaces`, adopts matching `NotesArrived` facts
in `settled`, then calls `step.forget_surfaces`. Focus resets notes state; a
same-strand replacement resolves selection against its current keys. The Notes
tab hides both advisor commentary and pending nudges, preserving their DOM
positions and behavior on the other tabs.

`notes_test` drives a real notes request, refusal, retry and snapshot reply,
checks focus and stale handlers, and pins the actual Lustre handler table and
numeric row paths. It also covers partial boards, raw text, literal excerpts,
search, refresh selection and markup-looking content.

## Side questions (protocol 087)

The operator composer parses `/btw` through the shared command grammar even
when its delivery mode is Steer. `operator_page.side_panel` draws a bounded,
scrollable aside outside the transcript, with escaped plain text and explicit
refresh, cancellation, clear and close controls. Main transcript updates and
approval controls remain available. Follow-ups use `/btw <question>` in the
composer. Observer pages expose no side-query controls.

`component.btw_state` reads this private state through the opaque host model.
`component.rearm` includes `surfaces.btw_due`, so a quiet main session does not
leave a side answer unobserved. Closing the panel does not cancel inference, and
a late board preserves its hidden visibility. The operator-page fixture verifies
that an ask during a running turn sends `btw`, never a main prompt or steer.

## Sessions on other orchestrators (protocol-change/085)

The owner's operating home draws a group, "On other orchestrators", after "Other
folders". `docs/architecture/web-view.md` ("Sessions on other orchestrators") is the
account.

- `web_view/elsewhere` is the page's vocabulary: `Group(name, address, hearing)` with
  `Hearing` (`Answered(rows, more) | Silent`), `Row(session_id, workspace, name,
  status, executor, executor_node)` with the closed `Status` and its fixed `word`, `Read` (`Heard |
  Unread`), `append` (joins a later page, up to `max_rows`) and `launch`
  (`session_view/launch_words`). It carries the executor node of a row, which the Admin page matches to a machine, and no
  credential.
- `home.Start.elsewhere` is `Some(home.Elsewhere(groups, next))` exactly where `create`
  is. The model keeps `elsewhere`, `elsewhere_reads` (the number of the latest
  first-page read; `Refreshed` bumps it), `located` (the open detail) and `paging` (the
  group whose page is out). `ElsewhereRead(serial, read)` and `MoreRead(group, serial,
  read)` are the effect's own messages. `Locating(group, session)` is honoured only for
  a row the page holds (`holds_row`), `ShowingMore(group)` asks after the last row held
  (`next_cursor`) and only while no page is out, and `still_there` closes a detail whose
  row a later read removed.
- `view/elsewhere` draws the group: a name and address as quiet text, a row for each
  session with a "Where" button, the detail in a `<loom-copy subject="launch">` box, "No
  answer from this orchestrator." for a silent group, and "Show more". Every name and
  path is a text node, the classes are fixed words from the existing stylesheet, and the
  rows are keyed by position. `home_table.view` takes it after the folders section.
- No event class, scope, route or content security policy changed: the buttons are
  clicks beneath `home.table_path`. `home_test` pins the group, the silent line, the
  detail, "Show more" and the dropped stale page.

## The Admin page's machines (protocol-change/085, addenda 2026-10-16 and 2026-10-19)

The admin page draws a Deployment section below People and Sessions: a summary line,
the machines grouped by role (or one "This machine" card for a daemon with no
distribution), the pools, and a page for the machine the owner chose.
`docs/architecture/web-view.md` ("Deployment: the machines list and a page for each
machine") is the account.

- `web_view/machines` is the vocabulary and the total decoder: `Machine(name, node,
  roles, whose, here, link, ledgered)` with `Here` (`Dialled(findings) |
  NotLinkedFromHere`) and `Ledgered` (`Enrolled(standing) | NotListed | Unledgered`),
  `Findings`, `Snapshot`, `Detail` (the long lists of one node), `Reading` (`Heard |
  HeardOne | Unread`), `Held`, `Detailed`, `Tab`, `Distribution` (`Distributed |
  Standalone`, from the reply's optional `distribution`), `Pool` (from
  `placements.pools`), `Group` (`OrchestratorGroup | ExecutorGroup | MemberGroup`, by
  `group_of`), `Title` (by `title`: a standalone daemon's own row is its host name,
  the reply's optional `host`, labelled "This machine", or "This machine" alone; its
  node name the BEAM made up is never drawn), and the words
  (`summary_words`, `build_words`, `reason_words`, `age_words`, `pill_class`). `decode_overview` merges the document's
  nodes with the ledger's members by node name; `decode_detail` reads a read for one
  node. `text_limit` 256 and `list_limit` 128 bound it.
- `web_view/operator_commands` writes `renew`, `revoke`, `enroll` and `release`. `quote`
  makes a name one shell word, or an error (empty, over 256 bytes, not printable ASCII,
  leading dash); the browser's `copy_rule` `operate` subject holds the same grammar.
- `admin.Start` gains `deployment: fn(Option(String), fn(Reading) -> Nil)` and
  `elsewhere`. The model keeps `held`, `deployed` (the number of the latest deployment
  read; an older answer is dropped, and reads are not held to one at a time), `machine`
  (the chosen node), `tab`, `detail` and `listed`. `MachineChosen(node)` reads the node
  by its key unless it is the asking daemon or not dialled; `TabChosen` reads the other
  orchestrators for the Sessions tab; `MachineClosed` overtakes any read out. The
  deployment follows the timer, one read together with the people read.
- `view/admin_machines` is the section: the groups as tinted lists, each row a button
  with only the facts its group has (a fact not stated is left out, not a dash), and
  the pools; `view/admin_machine` is the page and its four tabs. One tree serves every
  width: no table cells, facts beside the name on a wide screen and stacked under it at
  640 px and narrower. Every name is a text node, the classes are fixed words and the
  only data-chosen ones are the pill tints and the `unlinked` modifier, rows are keyed
  by position, and every handler is a click beneath `admin.body_path`.
- `view/elsewhere.strip` is the one-line strip the owner's operating home draws in the
  first child of its centre, so `home.table_path` does not move.
- Tests: `machines_test` (decoder, bounds, words), `operator_commands_test` (the fixed
  text, hostile names), `admin_test` (the section, choosing a machine, each tab, an
  overtaken read, markup as text, handler paths), `stylesheet_test` (no accent bar or
  shadow) and `home_test` (the strip).


## Move and Abandon (protocol-change/085)

- **Move** is `actions.Destinations` then `actions.Move(to)`. `Destinations` reads
  and changes nothing: the daemon answers `Heard(candidates)` (the type is
  `session_view/move_candidates.Candidate`), `home.update` sets the stage to
  `Choosing(session, candidates)`, and `home_table.choosing` replaces the row's words
  with a button for each eligible destination and a line for each ineligible one.
  `MoveChosen(session, to)` opens `Confirming(session, Move(to))` only for a
  destination that stage was offered; `MoveConfirmed(session)` asks only for a row
  confirming a move. `Managed` gained `move`, `choose` and `confirm_move`, and a saved
  row with no executor draws Move disabled with `move_candidates.no_executor_words()`
  in its title. `Reason.NotMovable` has fixed words, and `Answer.Heard` is dropped by
  the session page's sidebar, which never asks for it.
- **Where it runs.** `component.Label` gained `executor` and `pool`;
  `session_tab.runs_on` words them (`runs on box (pool builders)`) under the workspace
  inside the Session group's rows, so the pane's children and their paths are
  unchanged. `ui_socket` fills them for an owner's page only.
- **Abandon** is `grants.AbandonMove(session)`, with `Reason.NotMember | NotMoving`.
  `admin_machine.Page` gained `arm`, `ask`, `disarm`, `armed`, `waiting` and `notice`;
  `abandoning` draws the button beside each move of the asking daemon when
  `snapshot.directory` is `Some` (it is a directory member), and the armed question
  reads "If bravo has already taken the session, the move finishes instead." It reuses
  the Admin page's `Arming`, `Asking` and `confirmed`, which treat it as an armed action
  like making a session shareable.

## Memory overview (protocol 087)

`view/memory` is the Session pane's ninth child, drawn on the owner's page only.
It has no handler, so no path is admitted beneath it. `component.want_memory`
owes the first read.

## Model test of paging and turn sealing

`test/paging_model_test.gleam` is a `statem` model-based test (dev
dependencies `statem` and `qcheck`) that drives `component.update` through
`page_fixture`/`lane_fixture` with a generated sequence of events: appended,
running, settled and resumed turns, "Load older" (alone, or with the gateway's
answers), "Jump to latest", a divider press, a tick, and the gateway answering
or refusing the page's reads. It checks, under one `Violation` tag each, the
drawn-row bound (`paging.rows`), one request out at a time
(`paging.one_read`), the lane saying it is loading while a press is owed its
rows (`paging.loading`), a press on a `Full` or `Crowded` page entering
`Browsing` (`paging.full`), the direction of the paging state
(`paging.moves`), and, in `finish`, that a second page opened on the settled
history draws the same dividers as the page that watched it
(`paging.divider`). A second test replays the generator and fails if it stops
reaching every paging state, an open fold, or a divider after a resumed turn.
It needs no Lustre runtime: the frames the page writes go to a subject the
test owns. The fixture's conversation continues only once, so a resume ends the
history.

## Mermaid fences (protocol-change/091)

`markdown_view` maps exactly a `mermaid` code fence to `<loom-mermaid>` with
one `pre.mermaid-source` text child. The portable Markdown tree is unchanged,
so the terminal retains its ordinary code-source view. No source becomes an
attribute, URL or markup in this package. The browser component owns a native
source disclosure, Copy source and the isolated rendering lifecycle.

`page` names two more fixed assets, `mermaid.html` and `mermaid.js`. The ordinary
page policy permits same-origin frames without relaxing scripts or styles.
The daemon gives only the renderer HTML its distinct sandboxed policy, which
allows its bundled script and inline diagram styles but no network resources,
forms or nested frames. See
[protocol-change/091](../../protocol-change/091-isolated-mermaid-diagrams.md).
`markdown_view_test` pins text escaping and exact fence dispatch; the real
browser drive is `scripts/web_mermaid_check.sh` against `scripts/web_seed`.

## The relayed session page (protocol-change/094, slice S2b)

The owner's operating page can be opened on one session that runs on another
orchestrator, at `/ui/p/<key>/orchestrators/<name>/sessions/<id>`. It is the home
component with a different centre, so the sidebar, the account panel and every
ticket stay the home's.

- `web_view/relayed` is the vocabulary: `Row` (name, `listing.Code`, `Activity`,
  `Need`s), `Need` (the box's request identity and `seq`, worded by
  `session_view/approval.presentation`, with `Ability` and `Remember`), `History`
  (`Shown | Unreadable`), `Read` (`Heard(row, history) | Unreached(why)`), `Outcome`
  (`Done | Refusal | Unknown`) and `Choice`. Everything in it is text from the box.
  `listing.Code` gained `Pooled(pool, workspace)` for a pool placement.
- `web_view/relayed_session` is the state machine: `State` (presence, row, history,
  `Reach`, `Sending`, `Acting`, `deciding`, `decided`, `notice`, `sent`), `heard`, `update` and the
  `replied`, `stopped`, `archived`, `decided` answers. A press is judged against the row
  the page last read: a reply once, a stop when calm, an archive after its question,
  a decision (whose "sent" line a later read clears once the request is no longer listed) only for a request the row lists at the revision the card showed that the
  ceiling lets the page decide (and for the session only when `Rememberable`).
- `view/relayed_session` draws the centre with the existing approval-card,
  placement-strip and composer markup. The reply form accepts exactly one `message`
  field (`reply_fields`). Every handler lies beneath `home.table_path`.
- `home.Start.visiting` is `Some(home.Visit(orchestrator, session, refresh_ms, read,
  send, stop, archive, decide))` only for this page. `Model` keeps `relay`,
  `relay_timer` and `relay_reads`. `RelayTimerReady`/`RelayTicked` read every
  `relay_refresh_ms` (5 s), `RelayRefreshed`/`RelayAnswered` carry a numbered read and
  `Relaying`, `RelaySent`, `RelayStopped`, `RelayArchived`, `RelayDecided` are the presses
  and their answers. Each answer is followed by a read. `Pane` gained `Relayed`.
- `page.relayed_shell` and `page.relayed_path` are the document and the address.

### Starting on another orchestrator and listing its sessions (second pull request)

- `web_view/orchestrators` is what the page holds of each orchestrator the daemon is
  configured with: a `Machine(orchestrator, offer, offer_reads, rows, reach, flight)`
  kept for each name, so an answer changes only its machine. `Offers` (folders as
  paths, `placements.Cards`, profiles, models), `Offer` (`Asking | Offering |
  Refusing(why)`), `OffersRead`, `Listed` (a sidebar row), `ListRead` (`Heard | Missed`),
  `Reach` (`Unasked | Fresh | Silent(why, last_ms)`), `Flight` (`Quiet | Out`) and
  `Founding` (`Founded | Unsent | Refused`) are the words. `ask_offers` numbers a read and
  keeps held offers while it refreshes; `offers_heard` drops an answer a newer read
  overtook; `begin_listing` returns the machines with no listing read out, so a slow
  box is asked one call at a time; `listing_heard` replaces rows or keeps them and the
  last good time (`Silent`); `held_row` is the check a press passes; `ordered` is
  needs-you, working, idle, each newest first.
- `composer` gained `Agent` (`Here | Orchestrator(name)`) in `State`, `ChoseAgent`,
  the intents `ReadAgents`, `ReadOn(orchestrator)` and `CreateOn(orchestrator, place,
  prompt, roles)`, and on `Offers` the agent in force, `here`, the Agent chip's
  `agents` (`Candidate(agent, name, Choosable | Checking | Unavailable)`) and `typing`
  (`MayType | MayNotType`: a box is never given a typed path). `choosable` gates
  `ChoseAgent` and `Started`; `kept` runs after the agent changes and keeps only an
  executor or pool workspace the new machine offers (a folder never carries over) and
  a profile or model it lists; `sentence_for` adds "This page relays it".
- `view/new_session` draws the Agent list from `offers.agents` (a button for
  `Choosable`, text with a reason otherwise), the box's offers as the Code list, one
  disabled row for this machine's folders ("box cannot read laptop's files"), and
  hides the recent places while a box is the agent. `Presses` gained `agent`.
- `home.Start.orchestrators` is `Some(home.Orchestrators(key, names, refresh_ms,
  offers, sessions, create))` only for the owner's operating page of a daemon with an
  `[orchestrators.<name>]`. `Model` keeps `machines` and `side_timer`. `SideTimerReady`
  and `SideTicked` start a read of every quiet machine and re-arm at a fixed interval
  (`side_reading`); `SideListed`, `OffersAnswered` and `Founded` are the effects' own
  messages; `OpeningRelayed(orchestrator, session)` is the sidebar row's press, honoured
  only for a row `held_row` finds, and departs for `page.relayed_path(key, ..)`. A
  `Founded` create departs the same way, or, `Unsent`, offers the session through
  `composer.unsent`. `home.composer_state` and `home.machines` read the state in tests.
- `view/sidebar.home` takes a `Relayed(sections, open)`: one `relayed-side-group` for
  each machine with rows or a silence, headed "On <name>", under a `relayed-side-note`
  line ("box not reachable, seen 2m ago") with the rows dimmed (`relayed-side-quiet`)
  when it is silent. A row is a `session-open` button; its tag's agent is the
  orchestrator. A session page's sidebar draws none. The classes are prefixed
  `relayed-side-` because `relayed-stale` already styles the relayed page's own line.
- Tests: `orchestrators_test` (state, a seeded ordering property), `composer_test` (agent
  choice, kept, typed folder), `home_orchestrators_test` (the chip, the switch, create,
  sidebar rows, unreachable box, one call at a time, admitted handlers).
