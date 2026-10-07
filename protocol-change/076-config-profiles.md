# protocol-change/076: model profiles in the configuration

**Status**: IMPLEMENTED 2026-10-06. **Affects**: the control command
`sessions.create` (one optional request field, one refusal code), the catalogue
schema (version 9, one column), the `[profiles]` table of `loom.toml`, the
terminal's launch flags (`--model-profile`), and the web home's new-session
forms. No route, frame or event of Part 1 is added or removed.
**Raised by**: the owner's ruling of 2026-10-06, that one configuration file
should be able to serve several model sets, chosen per session.
**Builds on**: [074](074-web-new-folder-sessions.md) (session creation from the
web home and the catalogue's version 8), [055](055-operator-startup-diagnostics.md) (the
bounded startup reason a refused open reports), and
[051](051-web-view-route.md) (what a page may draw).

## Problem

An operator who uses several model sets keeps several configuration files, for
example `loom.toml`, `loom-glm.toml` and `loom-gemini.toml`. They differ in the
`[roles]` table and in a few `[models.*]` entries. Everything else is the same:
the workspace mounts, the tools table, MCP servers, language servers, rules,
secrets and the model definitions themselves. Each file repeats all of it, so a
change to a mount or a model's context window is made two or three times, and the
copies drift.

A session already stores the configuration path it was created with
(`Registration.configuration`), and `loom --config <file>` chooses one at
creation. So separate files do work for a terminal. They do not work for the web
home, whose new-session form has no way to name a file, and they do not remove
the duplication.

## What was considered

### Separate files, as now

Rejected as the answer, kept as the mechanism it already is. It works, but each
file must carry every shared setting. A file chosen by path is also a stronger
act than the web owner page should offer: the page would be naming a path on the
daemon's host.

### Switching models inside a session

A session's strands can already be switched to any catalogue entry with `/model`
(the `set_config` command with a `model_name`). Rejected as the answer. It
changes one strand's model, after the session exists. It does not change
`subagent`, `plan`, `summarize`, `advisor` or `vision`, which are resolved from
the gateway's role table for the whole session, so a session that starts on one
model set still reaches the other roles of the default set. It also leaves no
record of which set the session was meant to use, so a resume starts again from
the default.

### Profiles in the one file, chosen at creation

Chosen. A profile is a named set of role overrides inside the same file. It
removes the duplication, because everything but the roles is shared by
construction. It is chosen when the session is created, from the terminal or from
the web form, and the choice is stored with the session.

### Where the roles are resolved

Two designs were considered for what is stored.

- **Store the resolved roles.** Rejected. A later edit of the file, such as a
  renamed model or a changed fallback chain, would not reach the session, and the
  stored copy would be a second source of truth for roles.
- **Store the profile's name and resolve it again whenever the session opens.**
  Chosen. The file stays the only source of truth for what a profile means. The
  cost is stated under "Cost".

## Decision

### The file

`loom.toml` may hold a table of profiles, each of which overrides roles:

```toml
[roles]
main = ["baseten-glm-5-3"]
subagent = ["baseten-deepseek-v41-flash"]
vision = ["gemini-flash"]

[profiles.deepseek.roles]
main = ["baseten-deepseek-v41-flash"]
summarize = ["baseten-deepseek-v41-flash"]
```

A profile's role set is the default `[roles]` table with each role the profile
names replaced, chain for chain. A role the profile does not name keeps the
default's chain. In the example, `deepseek` routes `main` and `summarize` to the
named entry, and inherits `subagent` and `vision`. A chain is replaced whole and
never merged with the default's.

The catalogue parser (`client/catalog.parse`) checks every profile when the file
loads, so a mistake in a profile nobody has chosen yet still refuses the file:

- A profile name is a lowercase letter followed by lowercase letters, numbers,
  `_` or `-`, at most 32 characters (`storage/catalogue.is_profile_name`). It is
  the one grammar for the table key, the wire field and the stored column.
- A profile table has one key, `roles`, and it must name at least one role. Any
  other key is refused with the message the rest of the catalogue gives an unknown
  key.
- Each role name and each chain is checked by the same code as `[roles]`, with the
  table's own path in the message (`profiles.deepseek.roles.main names "x", which
  is not in [models]`). A `vision` chain must still list only entries that read
  images.
- `[profiles]` is a top-level table the catalogue's key check accepts. A file
  without it parses as before.

A parsed `Catalog` carries `profiles`, each already merged into a complete role
set. `catalog.select_profile` returns the catalogue with `roles` replaced by the
chosen profile's set, or a refusal naming the profiles that exist. Every consumer
of roles reads `Catalog.roles`, or the gateway `catalog.gateway` builds from it,
so a catalogue returned by `select_profile` is consistent everywhere.

### Where roles are resolved, and why sessions do not interfere

Each session's builder loads the configuration itself (`serve.resolve_managed`
calls `resolve`, which calls `load_config` and `catalog.gateway`) and holds the
resulting `Settings`, gateway and catalogue for that session alone. The daemon
holds no role table. Profile resolution is one more step of that load: when the
registration stores a profile, `load_config` applies `select_profile` to the
catalogue before the gateway is built. Two sessions on different profiles under
one daemon therefore build two catalogues and two gateways from the same file and
share nothing.

The consumers of roles, each of which reads its own session's gateway or
catalogue and none of which reads a daemon-wide table:

| Consumer | Where it reads roles |
|---|---|
| `main`: the model a new strand starts on, its window and output ceiling | `Settings.model`, from `catalog.main_model` of the session's catalogue |
| `main`, `subagent`, `plan`, `summarize` dispatch | `wiring.request_target` and `provider_gateway.resolve` over `Settings.gateway` |
| `subagent` for a child strand | `provider_gateway.resolve(settings.gateway, Subagent)` in `serve` |
| `advisor` | `serve.advisor_settings` over `Settings.gateway` and `Settings.catalog` |
| `vision` | `client/wiring` (`gateway.resolve(config.gateway, Vision)`) and `client/blocksummary` over the session's gateway and catalogue |
| the `models` listing's role columns | `gateway.catalog_listing` over the session's catalogue |

One consumer is not per session and does not use the profile: the shared
workspace domain's maintenance (`serve.build_domain`, which distills notes
for a workspace). It is built from the configuration the domain was created with,
with the default roles, because several sessions on different profiles share one
workspace domain. A test pins that two sessions built from one file with
different profiles route different main models, and that neither affects the other.

### Wire

`sessions.create` gains one optional request field:

```
"profile": "<name>"     # absent: the configuration's default roles
```

- A present `profile` must satisfy `is_profile_name`. Any other value, including
  an empty string, is a malformed request and is refused by the decoder, never
  read as the default. This is deliberate: a misspelled profile must not create a
  default-roles session.
- Before an identity is reserved, `server.create_session` checks that the
  configuration the session will load defines the profile. That is the file the
  request names (canonicalized, as today), or the daemon's own `--config` when the
  request names none. A daemon with neither defines no profiles.
- A refusal is `{"code": "unknown_profile", "message": "unknown profile \"x\";
  the configuration defines: a, b"}`, or "defines no profiles", or the worded
  failure of reading the file. This is the one control refusal whose message is
  not the fixed "request refused", because the person who mistyped the name needs
  the names that exist. The owner check runs first, so only the owner receives it.
  No registration is reserved for a refused request.
- The `sessions.create` reply is unchanged. `sessions.list` and `sessions.get`
  carry no profile.
- Retrying a request under the same `request_key` must repeat the profile. A
  different profile, or none, is `conflict`, as a different workspace or name is.

The terminal sends the field only when `--model-profile` was given, so a daemon
that predates profiles receives the request it always did.

### Storage

The catalogue is at version 9. `catalogue_sessions` gains one column:

```sql
ALTER TABLE catalogue_sessions ADD COLUMN profile TEXT NOT NULL DEFAULT ''
  CHECK(length(CAST(profile AS BLOB)) <= 64);
```

The empty string is no profile, and it is what every existing row reads as, so
the migration changes no session's behaviour. `Registration` carries
`profile: Option(String)`. It is part of the immutable creation record, written by
the same insert as the rest, and read by the same queries (`find`, the owner's
page and the member's page), so a retry compares it without a second read.
The catalogue stores a name and never the roles it resolved to.

A stored value that is not a profile name fails the read with `Invalid`. It is
never read as "no profile", because that would open a session that was created
under a profile on the default roles without saying so.

### Resume

Every open resolves the profile again against the configuration as it then
stands (`serve.resolve_managed` passes `registration.profile`). If the file no
longer defines the profile, the open fails and the registration's startup reason
(055) carries the message, with the file's path:
`/home/o/.loom/loom.toml: unknown profile "deepseek"; the configuration defines:
glm`. The session is not opened on the default roles. Restoring the profile to the file makes the session openable
again, because the registration still names it. A session whose profile needs a configuration file
and finds none (the environment-only configuration) fails the same way.

A strand that was switched with `/model` keeps its own stored model across a
resume. The profile decides the roles, not the model of a strand that already has
one.

### Terminal

`loom --model-profile <name>` asks for the profile when the terminal creates a
session. It is kept with the other local launch options, beside `--config`, and
applies to creation only: opening an existing registration keeps that
registration's profile. A launch that names a profile and opens an existing session says so in one
transcript line, so the flag is not silently ignored. A value that begins with `-` is refused so a forgotten
name does not consume the next flag.

The flag is not `--profile`. The native launcher already consumes `--profile`
(distribution.md, "Installing for live profiling"): it takes no value, enables a
BEAM distribution node, and is removed from the argument list before the
application starts. A `--profile <name>` would leave the application a stray
word after the launcher removed the flag. Choosing a distinct spelling needs no
change to the launcher and no rule for guessing whether the next word is a value.
If the owner prefers `--profile <name>`, the launcher's flag has to be renamed or
made to take an optional value first, and that is a separate change.

### Web

The owner's new-session forms (a workspace's form and the form for another
folder) draw a select named `profile` after the Shareable box when the daemon's
configuration defines profiles. It lists "Default" and then each profile in sorted
order. It is drawn only on a page that holds the creation capability, which is the
owner's page minted to operate, and on no other.

- **Names are text nodes.** A profile name is the daemon's text, so it is the
  label of an `<option>` and never an attribute (051). An option's `value` is its
  position in the list the page was given, and the form's decoder
  (`view/create.fields_with_profile`) turns the submitted position back into the
  name from that same list. The browser can choose among the names the page drew
  and name no other. A position outside the list, a name where a position goes, a
  repeated `profile` field, and a `profile` field on a page that offered none all
  drop the event.
- **Where the list comes from.** `Start.profiles` is read by the home socket's
  upgrade (`server.HomeAttachment.profiles`, which reads the daemon's
  configuration through `client/daemon/profiles`) when the page opens, and is
  empty for a page that cannot create. The component also ignores a creation
  naming a profile it was not told of.
- **The daemon decides.** `create_for` passes the profile to the same
  `server.create_session` the control command uses, which checks it against the
  configuration when the creation runs. A profile removed since the page opened is
  refused with `UnknownProfile`, whose fixed words are "That model profile is not
  in the configuration now. Reload the page."
- The page does not display a session's profile after creation.

## Cost

- One column and a migration in the catalogue, and `Registration` gains a field,
  so every construction of a registration in the tests carries it.
- `manager.Creation`, the control command `CreateSession` and the terminal's
  `CreateSession` and attach job each gain a field. The compiler found every
  construction. `Catalog` gains `profiles`, and `Start` and `create.Offered` gain
  the profile list.
- A profile can only replace roles. It cannot change a model definition, the
  tools, MCP servers, language servers, workspace mounts, rules or secrets, which
  stay shared. This is the point, and it is also the limit.
- Editing the file changes what an existing session's profile means at its next
  open. A session created under `deepseek` follows the file's current `deepseek`
  roles. Removing the profile makes the session unopenable until it is restored,
  and the failure says so. This was chosen over copying roles into the catalogue,
  which would be a second source of truth, and over a silent fall back to the
  default roles.
- The web list of names is read when the page opens, so a file edited after that
  shows the old names until the page is reloaded. The daemon checks again at
  creation, so the effect is a refusal in fixed words and never a wrong session.
- The workspace domain's maintenance uses the default roles whatever profiles the
  workspace's sessions use.
- The terminal flag is `--model-profile`, which differs from the owner's spelling
  `--profile` for the reason given above.
- `loomd --session ... --config ...` (the single-session server) has no profile
  flag. Only the daemon's managed sessions have profiles.
- The control refusal for an unknown profile is the one refusal whose message is
  not fixed text. It is owner-only and names profile names, which are not secrets.

## Verification

Tests pin: the merge (replaced chains whole, omitted roles inherited, canonical
order); the load-time refusals (an undefined model, an unknown role, an unknown
key in a profile table, an invalid name, a table with no roles, a vision chain that
names a text-only entry); the unknown-profile message with and without profiles;
that two gateways built from one parsed file route different main models and
neither follows the other; the catalogue's migration, retry conflict, restart
persistence and refusal of a damaged value; the control decoder (optional, grammar
refused, never read as the default); the daemon's refusal over the wire with the
known names and no reservation; that a retry must repeat the profile; that every
open, including one after a stop, builds from the stored profile; that two
registrations on different profiles resolve different main models, and that one
whose profile was removed is refused and not defaulted; the terminal flag, its
refusal of a flag-shaped value, that a bare `--profile` is still unknown there, and
that the job carries the profile; and, for the page, that the select exists only
when profiles exist and only on a page that may create, that a name is a text node
and never an attribute, and that the decoder admits only offered positions.

## Addendum 2026-10-06: showing the model on the web page

The profile of a session decides which model each role runs, and the web page
drew none of it. A reader could not tell which model set a session was created
under. The page now names the model, with no new wire field.

Every strand's configuration in the capture already names the catalogue entry
that chose its model (`ModelIdentity.provider`, which the daemon writes from the
entry's name) beside the upstream identifier (`model_id`). A session created under
a profile writes those entries, so the capture already says which model set is
running. The page reads the entry's name with `agent_view.catalogue_name` and draws
it as plain text:

- Beside the session's name in the top bar, the main strand's entry.
- On the card of any other strand whose entry differs from the main strand's: the
  advisor, and a sub-agent whose role routes elsewhere. A strand on the main
  strand's entry draws nothing, and so does a strand, or a main strand, whose
  configuration the capture does not hold, since an unknown model is not evidence
  of another one.

The summarizer is a role and not a strand in the capture, so it has no card and
the page does not draw its model. The strand's own view already lists the
upstream identifier, shortened, and keeps doing so.

The name is the owner's text from the configuration file and is drawn only as a
text node. The terminal's identity line already shows the active strand's model,
by the last segment of its upstream identifier, and is unchanged.
