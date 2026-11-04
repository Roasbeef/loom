# protocol-change/108: pinning any role when a session is created

**Status**: PROPOSED 2026-11-03. **Affects**: the control command
`sessions.create` (one optional request field, two refusal codes of which one
is new), the catalogue's registration and schema (one column replaces
another), the `profile` snapshot (one optional field), `profile_set` (which
now carries the pins through a switch), and the new-session forms of the web
home and of Loom Desktop. No route, frame or event of Part 1 is added or
removed, and the `loom.toml` format does not change.
**Raised by**: the owner's request of 2026-11-03 that the new-session forms of
Loom Desktop and the web home choose a model per role, such as `vision` and
`main`, without first writing a profile into `loom.toml`.
**Builds on**: [076](076-config-profiles.md) (the `profile` field and its
storage and re-resolution), [080](080-session-model-choice.md) (the `model`
field, which pins `main` alone) and [082](082-session-profile-switch.md)
(`profile_set` and `catalog.retargets`).

## Problem

`sessions.create` can route a session's roles in two ways. `profile` names a
`[profiles.<name>.roles]` table that the owner wrote into the file beforehand.
`model` replaces the `main` chain with one `[models.<key>]` entry. Every other
role, `subagent`, `plan`, `summarize`, `vision`, `advisor` and `router`, comes
from `[roles]` or from the chosen profile, and no creation request can change
it.

A form that lets a person start a session with `main` on one model and `vision`
on another therefore has to ask them to write a profile first. That is the
duplication 080 removed for `main`: the profile would say nothing except "these
roles are these models". The case that prompted the request is the common one.
The default `main` is a text-only entry, the person has an image to attach, and
they want a vision-capable entry for that session only.

## What was considered

### One more field per role

`vision`, `subagent` and the rest as top-level fields beside `model`. Rejected.
It adds six fields to a command that already carries a dozen, each needing its
own decoder arm, catalogue column and conflict comparison, and a seventh role
would repeat all of it. The roles are a closed set that `catalog.parse_role`
already enumerates, so the set belongs in one value.

### A `roles` object that replaces `model`

Remove `model` and make `roles.main` the only way to pin `main`. Rejected. 080
is implemented, the web form and the control command send `model` today, and a
removal is a break for no gain. `model` stays and means exactly `roles.main`.

### Storing a generated profile

Writing a `[profiles.pin-<id>]` table into the user's file or into a side
file. Rejected for the reasons 080 gave for generated profiles, and for a
further one: the daemon would write the owner's configuration on behalf of a
request.

### Storing the resolved role set

Rejected as in 076 and 080. A renamed or removed entry would not reach the
session, and the stored copy would be a second source of truth.

### An optional `roles` object, stored as keys and resolved at every open

Chosen. It extends the mechanism 076 and 080 built (an optional field checked
against the configuration before an identity is reserved, stored by key,
resolved again at every open) from one role to the closed set of seven.

## Decision

### Meaning of the choice

A session's role set is computed in this order:

1. the configuration's `[roles]`;
2. if a profile was chosen, with that profile's roles laid over it (076);
3. with each pinned role replaced by the one-entry chain `[<key>]`.

Step 3 replaces `model` of 080 and includes it: `model` is another spelling of
the pin `main`. Only a pinned role changes. An unpinned role keeps the chain
steps 1 and 2 gave it. Each pinned chain is that one entry and has no
fallbacks, as 080 stated for `main`: a retryable failure on the pinned model
does not move to the next entry of the default chain. Pins do not interact with
one another; any entry may be pinned to any role, and the same entry may be
pinned to several.

`catalog.select_model(catalog, key)` becomes a special case of a new
`catalog.select_roles(catalog, pins)`, which returns the catalogue with those
roles rewritten, or a refusal. The one place a session loads its configuration
applies it after `select_profile`, so the gateway, the `models` listing, the
strand seeding, the vision admission, the advisor wiring and the project router
all follow it as they follow a profile.

### Wire

`sessions.create` gains one optional request field:

```
"roles": { "<role>": "<key>", ... }   # absent: no pins beyond `model`
```

- The object's names are drawn from `main`, `subagent`, `plan`, `summarize`,
  `vision`, `advisor` and `router`, the names `catalog.parse_role` accepts. Each
  value must satisfy `storage/catalogue.is_model_key`, as `model` does.
- Anything else is a malformed request and is refused by the decoder, never
  read as "no choice": a value that is not an object, a name outside the seven
  (including a role the file does not route, since a pin may add a route), a
  non-string value, an empty or over-long key, and a repeated role name. A
  misspelled role must not create a session whose pin silently did nothing.
  The object may hold at most seven pairs, which the closed name set already
  implies.
- An empty object is the same as an absent field. The decoder normalizes both
  to no pins so that a retry cannot differ from the original by spelling.
- **`model` and `roles.main` together.** `model` is read as `roles.main`. If both
  appear and name the same key the request is valid and is treated as one pin.
  If they name different keys the request is refused as malformed, with a
  message that names both. Neither wins silently, because a client that sent two
  different answers to the same question has a bug that a silent precedence
  would hide.
- **Order of checks.** The owner check runs first, then the shape checks above,
  then, before an identity is reserved, the configuration the session will load
  (the file the request names, or the daemon's own `--config`) is read and
  checked in this order: `profile`, then each pin in the order `main`,
  `subagent`, `plan`, `summarize`, `vision`, `advisor`, `router`. The first
  failure is the refusal, so a request with two mistakes is told of one and the
  order is stable.
- **`unknown_model`.** A pinned key the configuration does not define is
  refused with the existing code. The message adds the role:
  `unknown model "x" for role "vision"; the configuration defines: a, b`, or
  `... defines no models`. A request with only `model` keeps 080's wording
  without the role, so existing clients and tests see no change.
- **`unsuitable_model`** (new code). A key the configuration defines but that
  cannot serve the role is refused with this code and a message that names the
  role, the key and the reason. Today the only reason is the one the file
  decoder already enforces for a `vision` chain: the entry declares
  `vision = false`. The message is
  `model "x" cannot serve role "vision": it declares vision = false; a vision
  role must name an entry that reads images`. The check is
  `catalog.vision_chain_all_read` applied to the pinned chain, so the
  decoder's rule and the pin's rule are one function. It runs when a pin is
  applied and not only at creation (below), because `override_roles` bypasses
  the parse-time check. No other role is refused for capability: a text-only
  `main` is already routed images through the `vision` role, and a role with no
  strand-independent need has no declared flag to check.
- A configuration that cannot be read or parsed is the existing
  `unusable_configuration`, now also when only `roles` is sent.
- A retry under the same `request_key` must repeat the pins. The comparison is
  between normalized values, so `{"model":"a"}` and `{"roles":{"main":"a"}}` are
  the same request. A different set of pins, including one more or one fewer, is
  `conflict`, as a different profile is.
- The `sessions.create` reply, `sessions.list` and `sessions.get` are unchanged.

A daemon that predates this change ignores an unknown `roles` field and would
create a session on the default roles. A client that needs the pin to hold
MUST NOT assume it did on an older daemon. The daemon's `hello` reports the
protocol version and no capability list, so a client reads the stored pins back
from `profile_get` after creation (below) and treats their absence as an old
daemon. Neither first-party client can meet an old daemon with the field: the
web page is served by the daemon that checks it, and Loom Desktop ships against
the daemon it speaks to.

### Storage

`catalogue_sessions` currently holds 080's `model` column. This change replaces
it by one column, so that the creation record has one place that names a pin:

```sql
ALTER TABLE catalogue_sessions ADD COLUMN pins TEXT NOT NULL DEFAULT ''
  CHECK(length(CAST(pins AS BLOB)) <= 1024);
UPDATE catalogue_sessions SET pins = json_object('main', model) WHERE model != '';
ALTER TABLE catalogue_sessions DROP COLUMN model;
```

`pins` is the empty string for no pins and otherwise a JSON object from role
name to key, written by the codec that already encodes registration payloads
with its names in the fixed role order. `is_model_key` imposes no grammar on a
key, so the column does not use a delimiter format. The bound of 1024 bytes
holds seven pairs with the longest role name and a 64-byte key, with room for
escaping. Every existing row reads as it did: a session with `model = a`
becomes the single pin `main = a`.

`Registration` carries `pins: List(#(Role, String))` in the fixed role order
in place of `model: Option(String)`. It is part of the immutable creation
record and is read by the same queries. A stored value that does not decode to
the closed role set and valid keys fails the read with `Invalid`, as a damaged
profile does, and is never read as "no pins".

The catalogue stores keys and never the role set they resolved to, and the
registration's pins are not changed by `profile_set`.

### Resolution at every open

`serve.resolve_managed` passes `registration.pins` to `with_choice`, which
applies `select_profile` and then `select_roles`. This is the same code path as
creation, so a check that passes at creation is the check applied at open:

- A key the file no longer defines fails the open with 080's startup reason
  (055): `<path>: unknown model "x" for role "vision"; the configuration
  defines: ...`. The session is not opened on the default roles, and restoring
  the entry makes it openable again.
- An entry the file now declares `vision = false`, pinned to `vision`, fails the
  open with the `unsuitable_model` sentence in the same way.
- A configuration with no file (the environment-only configuration) and any pin
  fails the open, as 080 does for a model.

A strand switched with `/model` keeps its own stored model across a resume, as
under 076 and 080. A pin decides the model that heads a role and therefore the
model a new strand is seeded with; it does not override a choice made for one
strand afterwards.

### What `profile_set` does to pinned roles

A pin is laid over the profile, so a pinned role does not change when the
profile does: after a switch the pinned role still resolves to the pinned entry
and every unpinned role follows the new profile. `profile_set` therefore
builds both catalogues it compares (the profile being left and the profile
being entered) with the session's pins applied, which is the one change to its
steps in 082. `catalog.retargets` then finds the head of a pinned role equal on
both sides and leaves its strands alone. A strand that follows `main` while
`main` is pinned stays on the pinned model, and a strand that follows
`subagent` or `advisor` while those are unpinned moves as before. No pin is
dropped, rewritten or reported as moved.

`profile_set` needs no new check. A profile changes role chains and cannot
change `[models]`, which is where the pinned keys are looked up, so a switch
cannot make a pin invalid. A pin that became invalid because the file was edited
is reported by the open that follows the switch, as it would be by any open.

There is no command to change a pin after creation. The registration's pins are
immutable, as `model` was. A person who wants different pins starts a session
with them, and a `/model` choice for one strand remains available. A later
change (`pins_set`, parallel to `profile_set`) would reuse the restart 082
built and is not part of this one.

### What the snapshots report

- **`profile` snapshot** (section 5.2, replies to `profile_get` and
  `profile_set`) gains an optional `pins` object mapping each pinned role to its
  key, in the fixed role order. It is absent when the session has no pins. A
  pin is reported by the key the registration stores, whether or not the key
  still resolves. This is how a client shows the pins on an existing session and
  how it detects a daemon that ignored `roles`.
- **`models` snapshot** (section 5.4) is unchanged. Its `roles` and `active`
  fields already come from the catalogue the session was opened with, so a
  pinned role is reported on exactly the entry it is pinned to, and the entries
  it displaced no longer list it. A client that needs to tell a pin from a
  profile route reads `profile`.
- `sessions.list` and `sessions.get` do not carry pins, for the reason 080 gave
  for the model: the list pages many sessions and the pins belong to the one
  that is open.

### Forms

The web home and Loom Desktop need the model keys and each entry's vision flag
to draw a select per role before a session exists. The web home gets keys from
the home socket's upgrade (080, `Start.models`), and that list gains each
entry's `vision` flag as a closed two-variant value, `Reads` or `TextOnly`, so
the page can offer only readers for `vision`. No base URL, key variable, model
identifier or pricing is added; the page still receives keys and the flag
alone. The daemon checks again at creation, so a stale page is told in fixed
words and never gets a wrong session.

Loom Desktop has no home socket. It is not given a new read command by this
change: it learns the keys and flags from the configuration the user already
chose by file path, or by trying the creation and showing the daemon's refusal,
which names the keys that exist. A control read that lists the keys and flags
is the clean answer and is deferred to a separate proposal (see "Not in this
change") so this one stays the size of a single field.

## Not in this change

- A control read for `[models]` keys, their vision flag and the roles they
  serve, for clients without the home socket.
- A command that changes pins after creation.
- `loom --role vision=<key>` for the terminal. The terminal can reach each
  role through `--model-profile` and `/model`.
- Capability checks for roles other than `vision`.
- Display names for models.

## Cost

- The catalogue gains a migration that replaces a column. `Registration`'s
  `model` field is replaced by `pins`, so every construction of a registration
  in the tests changes, and the compiler finds them all. A downgrade to a
  daemon of 080's schema loses the pins, because it knows only `model`; the
  catalogue version moves to 21 so an older binary refuses the file and does
  not read it wrongly.
- A pinned role has no fallbacks, as `main` did under 080. A pinned `vision`
  that fails does not walk an image to another model, which is the intent.
- Pins cannot be changed on a live session, and a session whose file has
  dropped a pinned entry cannot open until the entry returns. Both follow
  080's choice and are stated in `docs/configuration.md`.
- A new refusal code, `unsuitable_model`, joins `docs/client-protocol.md`
  section 3.7. A client that does not know it shows the `message`, as for any
  unknown code.
- The `roles` object adds up to seven keys to every creation request, checked
  before any identity is reserved. The check reads the configuration once, as
  `profile` and `model` do, so there is no new read per role. The request size
  is bounded by the existing frame limit and by the closed role set, so a
  caller cannot make the daemon store or compare an unbounded value.
- A pin to `advisor` or `router` on a configuration that routes neither adds
  that role's wiring to the session (082 notes that an unrouted advisor builds
  no wiring). That is intended; the pin is the route.
- The migration's data step is run once and is the only place the old `model`
  column is read.

## Implementation sketch

Not implemented by this proposal. The change touches:

- `packages/client/src/client/catalog.gleam`: `select_roles`, `select_model`
  as `select_roles` with one pin, `unsuitable_model` wording, and the vision
  check reused from `vision_chain_all_read`.
- `packages/client/src/client/daemon/protocol.gleam`: `CreateSession` gains
  `roles`; the decoder (shape checks, `model` and `roles.main` agreement) and
  the encoder.
- `packages/client/src/client/daemon/server.gleam`: `create_session` check
  order and the `unknown_model` and `unsuitable_model` mapping;
  `packages/client/src/client/daemon/profiles.gleam`: `with_choice` over pins.
- `packages/client/src/client/serve.gleam`: `resolve_managed` and the
  `profile_set` catalogue pair so that both apply the pins.
- `packages/storage/src/storage/catalogue.gleam` and
  `packages/storage/sql/`: the `pins` column and migration (version 21),
  `Registration.pins`, the codec and its `Invalid` case; regenerate the SQL
  modules with `make gen-sql`.
- `packages/client/src/client/gateway.gleam`: the `profile` snapshot's `pins`;
  `packages/client/src/client/protocol.gleam` for the snapshot type.
- The web home (`packages/web_view` and the creation capability): `creations.Roles`
  carries the pins and the form draws a select per role.
- `docs/client-protocol.md` sections 3.7, 4.9.30 and 5.2, `docs/configuration.md`
  ("Choosing a model for one session"), and `docs/architecture/sessions.md`.
- Tests: `select_roles` (only pinned roles change, composition with a profile,
  the vision refusal), the decoder (every refusal above, `model` and
  `roles.main` agreement and disagreement, empty object), retry equivalence and
  conflict, the migration of an existing `model`, damaged-value refusal, an open
  that fails on a removed or newly text-only entry, `profile_set` leaving a
  pinned strand in place, and the `pins` field of the snapshot.

## Implementation note: what the web form chose

The web home's composer offers two of the seven roles, `main` (as before) and
`vision`, as a section of its existing Model list; the other five reach the
daemon through `roles` only. The old create forms keep their one Main model
select. The vision flag reaches the page as a second list, `Start.readers`, the
keys among `Start.models` that read images, and not as a flag on each entry:
every consumer of `Start.models` keeps its type, and the page learns the same
fact. Another orchestrator's offers (`orchestrators.Offers`) do not carry it, so
the composer offers no vision section there and a creation on it never carries a
vision key. The daemon checks the pin again at creation either way.

## Verification

The properties to pin are the ones in the sketch's test list. In addition, a
live drive against `loomd` with a real configuration should create a session
with `main` and `vision` pinned to different entries, send an image, resume the
session after a restart, switch its profile, and edit the file to remove the
`vision` entry and confirm the open fails with the stated reason.
