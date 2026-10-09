# protocol-change/080: choosing a session's main model at creation

**Status**: IMPLEMENTED 2026-10-08. **Affects**: the control command
`sessions.create` (one optional request field, one refusal code), the catalogue
schema (version 10, one column), and the web home's new-session forms. No route,
frame or event of Part 1 is added or removed, and the `loom.toml` format does
not change.
**Raised by**: the owner's request of 2026-10-08, that the web new-session form
offer the daemon's configured models directly. The owner's file defines no
`[profiles.*]` tables, so the form of 076 draws no select at all, and the only
way to start a web session on a model other than the default `main` is to edit
the file.
**Builds on**: [076](076-config-profiles.md) (the profile field, its
validation, storage and re-resolution, which this change repeats for a second
field), [074](074-web-new-folder-sessions.md) (session creation from the web
home) and [051](051-web-view-route.md) (what a page may draw).

## Problem

`[roles]` routes `main` to one chain of `[models.<key>]` entries, and a session
starts on the head of that chain. A session on another model today needs one of:

- a second configuration file, chosen with `loom --config`, which a web form
  cannot name;
- a `[profiles.<name>.roles]` table in the file that routes `main` to the
  model, one profile per model, written by hand; or
- `/model` inside the session, which changes one strand after the session exists
  and leaves no record of the intent, so a resume starts again from the default.

The owner has many `[models.*]` entries and one `[roles]` table. Writing a
profile for each entry in order to choose it from the form is duplication of the
kind 076 set out to remove: the profile would say nothing but "main is this
model".

## What was considered

### One select that lists profiles and models together

A single "Model" select with the default, then profiles, then models, and a
closed sum type `DefaultRoles | Profile(name) | Model(key)` for the choice.
This has the smallest form and no combined state. Rejected. It cannot express
"the `review` profile's roles, with `main` on this model", and it changes the
type of the existing `profile` field on the wire, in the catalogue and in every
signature that 076 added, instead of adding to them. The combination is the
reason a profile exists, so removing it is a loss and not a simplification.

### Storing the model inside the `profile` column or the profile name

Writing `model:<key>` into the profile column, or generating a profile from the
key. Rejected. The profile column is held to the profile-name grammar by the
decoder, the catalogue and `Registration`'s check, and a model key is not a
profile name (it is any TOML key, with no grammar). Loosening the column would
weaken the check that stops a damaged value from reading as the default roles.

### A generated profile for each model

Having `catalog.parse` add a profile `model-<key>` for every entry. Rejected.
It fills the profile list the web form draws with entries nobody wrote, and a
profile name has a 32 character bound a model key does not.

### Storing the resolved model

Rejected for the reason 076 gave: a renamed or removed entry would not reach the
session, and the stored copy would be a second source of truth. The key is
stored and resolved again on every open.

### A second optional field, stored and resolved like the first

Chosen. The model is independent of the profile and composes with it by a rule
that fits in one sentence (below), so the two fields have no invalid
combination and no precedence to remember. The mechanism is the one 076
built: an optional wire field checked against the configuration before an
identity is reserved, one catalogue column, and a resolution step in the
session's own configuration load.

## Decision

### Meaning of the choice

A session's role set is computed in this order:

1. the configuration's `[roles]`;
2. if a profile was chosen, with that profile's roles laid over it (076);
3. if a model was chosen, with the `main` role replaced by the one-entry chain
   `[<key>]`.

Only `main` changes. `subagent`, `plan`, `summarize`, `vision` and `advisor`
keep the chain steps 1 and 2 gave them. The chosen model's own `[models.<key>]`
entry is used as written, so its endpoint, context window, output ceiling and
thinking level are the entry's. The `main` chain becomes that one entry and has
no fallbacks: a retryable failure on the chosen model does not move to the next
entry of the default chain. This is stated on the form's reference page
(`docs/configuration.md`) and is the cost of "this model, exactly".

`catalog.select_model(catalog, key)` returns the catalogue with `roles`
rewritten that way, or a refusal naming the keys that exist. It is applied after
`select_profile` in the one place a session loads its configuration, so the
gateway, the `models` listing, the main model a new strand starts on and the
vision admission all follow it, as they follow a profile (076, "Where roles are
resolved").

No new validation of the `main` chain is needed: any `[models.<key>]` entry is a
valid `main` model. A text-only entry chosen as `main` is already handled by the
`vision` role.

### Wire

`sessions.create` gains one optional request field:

```
"model": "<key>"     # absent: the main chain the profile or configuration gives
```

- A present `model` must satisfy `storage/catalogue.is_model_key`: one to 64
  bytes of text. There is no further grammar because a `[models.<key>]` key has
  none, and the configuration is the authority on which keys exist. Any other
  value, including the empty string or a non-string, is a malformed request and
  is refused by the decoder, never read as "no choice". A misspelled model must
  not create a default-model session.
- Before an identity is reserved, `server.create_session` checks, after the
  profile check, that the configuration the session will load defines the model.
  It is the file the request names, or the daemon's own `--config` when the
  request names none. A daemon with neither defines no models.
- A refusal is `{"code": "unknown_model", "message": "unknown model \"x\"; the
  configuration defines: a, b"}`, or "defines no models". A configuration that
  cannot be read or parsed is the existing `unusable_configuration`. Like
  `unknown_profile` this is a refusal whose message is not "request refused",
  because the person who mistyped the key needs the keys that exist; it is
  owner-only because the owner check runs first, and the keys are not secrets.
  No registration is reserved for a refused request.
- A retry under the same `request_key` must repeat the model. A different model,
  or none, is `conflict`, as a different profile is.
- The `sessions.create` reply, `sessions.list` and `sessions.get` are unchanged
  and carry no model.

The decoder does not reject fields it does not know, so a daemon that predates
this change would read a `model` field as absent and create a session on the
default model. Neither client in this repository can meet that daemon with the
field: the web page is served by the daemon that checks it, and the terminal
sends no `model` (see "Not in this change").

### Storage

The catalogue is at version 10. `catalogue_sessions` gains one column:

```sql
ALTER TABLE catalogue_sessions ADD COLUMN model TEXT NOT NULL DEFAULT ''
  CHECK(length(CAST(model AS BLOB)) <= 64);
```

The empty string is no choice and is what every existing row reads as, so the
migration changes no session's behaviour. `Registration` carries
`model: Option(String)` beside `profile`, part of the immutable creation record,
read by the same queries. The catalogue stores the key and never the role set it
resolved to. A stored value that is not a model key fails the read with
`Invalid`, as a damaged profile does, and is never read as "no choice".

### Resume

Every open resolves the model again against the configuration as it then stands
(`serve.resolve_managed` passes `registration.model`). If the file no longer
defines the key, the open fails and the registration's startup reason (055)
carries `<path>: unknown model "x"; the configuration defines: ...`. The
session is not opened on the default model, and restoring the entry makes it
openable again. A model choice with no configuration file (the environment-only
configuration) fails the same way. A strand that was switched with `/model`
keeps its own stored model across a resume, as under 076.

### Web

The owner's new-session forms (a workspace's form and the form for another
folder) draw a second select named `model`, labelled "Main model", after the
profile select (or after the Shareable box when there are no profiles). It lists
"Default" and then each key in sorted order. It is drawn only when the daemon's
configuration defines at least one model that satisfies `is_model_key`, and only
on a page that holds the creation capability. A configuration file that loads
defines at least one model, so the owner's page always draws the select when the
daemon has a file; the environment-only configuration has no file, so it offers
no key and the form is unchanged. It is independent of the profile select: a form may draw either, both, or neither.

- **Keys are text nodes.** As for profiles (051), a key is the label of an
  `<option>` and never an attribute. An option's `value` is its position in the
  list the page was given, and the form's decoder turns the position back into
  the key from that same list. A position outside the list, a key where a
  position goes, a repeated `model` field, and a `model` field on a page that
  offered none all drop the event.
- **Nothing beyond the key is sent to the browser.** The page is given key
  strings. It is not given a model's base URL, key variable, model identifier,
  pricing or limits.
- **Where the list comes from.** `Start.models` is read by the home socket's
  upgrade (`server.HomeAttachment.models`, from `client/daemon/profiles`) when
  the page opens, and is `[]` for a page that cannot create. The component also
  ignores a creation naming a key it was not told of.
- **The daemon decides.** `create_for` passes the key to the same
  `server.create_session` the control command uses. A key removed since the page
  opened is refused with `creations.UnknownModel`, whose fixed words are "That
  model is not in the configuration now. Reload the page."
- The profile and model of a creation travel together as one value,
  `creations.Roles(profile, model)`, in the messages, the decoders and the
  creation capability, so a signature takes one choice and not two.
- The observer socket admits no event it did not admit before. The form's
  existing `submit` event carries the extra field, and the home socket's
  admission of that event is unchanged (070).

### Not in this change

- No `loom --model <key>` terminal flag. The terminal can already choose a model
  with `/model` and a role set with `--model-profile`. Adding the flag is the same
  size of change again (the terminal's wire encoder and launch options) and was
  not asked for.
- The page does not display the stored choice after creation. The top bar
  already names the main strand's catalogue entry (076, addendum).
- No display name for a model. The key is the text the owner wrote.

## Cost

- One column and a migration, and `Registration` gains a field, so every
  construction of a registration in the tests carries it.
- `manager.Creation`, the control command `CreateSession`, the home attachment
  and `Start` each gain a field. The compiler finds every construction.
- A model key longer than 64 bytes is not offered by the web form and cannot be
  sent by the control command. This is a limit on one field and not on the
  configuration, which still loads such a key.
- The chosen `main` chain has no fallbacks.
- Editing the file changes what an existing session's choice means at its next
  open: a renamed entry makes the session unopenable until it is restored, and
  the failure says so. The alternative of a silent fall back to the default was
  rejected in 076 for the same reason.
- The web list of keys is read when the page opens, so a file edited after that
  shows the old keys until the page is reloaded. The daemon checks again at
  creation, so the effect is a refusal in fixed words and never a wrong session.
- A daemon can no longer be sent an unknown `model` value that it ignores: a
  present value is validated. An older daemon still ignores the field.

## Verification

Tests pin: `select_model` (only `main` changes, the chain is exactly the key,
composition with a profile in either file order, a refusal naming the keys); the
unknown-model message with and without keys; the decoder (optional, bounded,
empty and non-string refused); the catalogue's migration, retry conflict,
restart persistence and refusal of a damaged value; the daemon's refusal over the
wire with the known keys and no reservation; that every open builds from the
stored model and that a removed key refuses the open and is not defaulted; for the
page, that the select exists only when keys exist and only on a page that may
create, that a key is a text node and never an attribute, that the decoder admits
only offered positions, that a profile and a model are carried together, that the
component ignores a key it was not told of, and that the page holds nothing of a
model but its key.
