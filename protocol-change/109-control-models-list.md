# protocol-change/109: listing a configuration's models over the control socket

**Status**: PROPOSED 2026-11-04. **Affects**: the control endpoint (one new
owner-only command, `models.list`, with its reply event) and nothing else. No
frame, event or field of an existing command changes, and the `loom.toml`
format does not change.
**Raised by**: [108](108-session-role-pins.md), which deferred "a control read
for `[models]` keys, their vision flag and the roles they serve, for clients
without the home socket", and the owner's request of 2026-11-04 that Loom
Desktop offer per-role pins.
**Builds on**: [076](076-config-profiles.md) (profiles),
[080](080-session-model-choice.md) (model keys) and 108 (role pins).

## Problem

108 lets `sessions.create` pin any role to a `[models.<key>]` entry. A form that
offers the pins has to know, before a session exists, which keys the
configuration defines and which of them read images, because a `vision` pin to a
text-only entry is refused. The web home learns this from its own socket's
upgrade (`Start.models` and `Start.readers`). Loom Desktop has no home socket.
Its only other source today is to try a creation and read the refusal, which
names the keys that exist but not which of them read images, and which reserves
nothing only when it fails.

The existing control reads do not answer it. `models` (section 5.4) is a
session's snapshot and needs a session. `profile_get` is the same. Both would
require creating a session in order to ask what the new session could be.

## What was considered

### Send the configuration's text to the client

Rejected. The file holds base URLs, key variable names and pricing, which the
client has no need to see, and the client would have to parse TOML and apply
the daemon's rules for which entries are valid pin targets. Two parsers would
drift.

### A flag on the existing `sessions.create` refusal

Make the unknown-model refusal list the vision-capable keys too. Rejected. A
refusal is the wrong place for discovery: the form would have to provoke one to
draw itself, and the message is prose that clients must not parse.

### Extend `hello` with the daemon's configuration

Rejected. The configuration a session loads is chosen per creation (the
`configuration` field), so the daemon's own file is not the file the form is
about, and `hello` is sent before the client has chosen anything.

### A read command that takes the configuration path

Chosen. It asks the question `sessions.create` asks of the same file, answers it
with the daemon's parser and its own rules, and returns only the facts a person
chooses by.

## Decision

### Wire

```
request: {"v":2,"id":N,"cmd":"models.list","body":{"configuration":"/abs/path/loom.toml"}}
reply:   {"v":2,"reply_to":N,"event":"models.list","body":{
           "models":[{"key":"opus","model_id":"claude-opus-5","dialect":"anthropic",
                      "vision":true,"roles":["main"]}],
           "profiles":["codex","review"]}}
```

- `configuration` is required: a non-empty string of at most 4096 bytes. An
  absent, empty, over-long or non-string value is a malformed request
  (`bad_request`), and is never read as the daemon's own configuration. A client
  that wants the daemon's own file names its path.
- The path is canonicalized on the daemon's host as `sessions.create`
  canonicalizes a configuration. A path that cannot be canonicalized is refused
  `invalid_configuration` with the message `request refused`, the words that
  command uses. A file that cannot be read or does not parse is refused
  `unusable_configuration` with the daemon's startup wording as the message, as
  `sessions.create` words it.
- `models` holds every `[models.<key>]` entry whose key satisfies
  `storage/catalogue.is_model_key`, the test that decides whether a key can be
  pinned. An entry whose key fails it is left out, as `catalog.model_keys`
  leaves it out. Each row carries:
  - `key`, the table key;
  - `model_id`, the provider's identifier;
  - `dialect`, spelled as the `models` snapshot spells it;
  - `vision`, a JSON boolean that is always present and is true exactly when
    the key is in `catalog.vision_model_keys`, the list the creation check
    uses for a `vision` pin;
  - `roles`, the default roles whose chain lists the key, in the canonical role
    order, which is what the session `models` snapshot reports for the same
    file with no profile and no pin.
- `profiles` holds the `[profiles.<name>]` names, an empty array when the file
  defines none.
- Both arrays are in the order the catalogue keeps, which is sorted by key and
  by name, not the order of the file. The parsed catalogue does not retain
  file order, and sorting makes the reply stable across edits that only move
  tables.
- No base URL, key variable name, price, limit or other endpoint detail is
  returned.
- The command is owner-only. A member principal receives `forbidden` before the
  path is looked at, so a member cannot probe the host's filesystem. It is a
  read, so it is served during a drain as the other reads are (section 3.17).
- It reserves nothing and writes nothing. The file is read on every request and
  nothing is cached, because the file is an ordinary one the owner edits.

### Not decided here

A `roles` list that reflects a profile or a pin is not offered: the form is
choosing them, and `sessions.create` applies them. The reply describes the
file as it stands.

## Cost

- One command, one decoder arm and one reply body to keep in
  `docs/client-protocol.md` section 3.33.
- The file is parsed once more per request. The form asks when it is opened or
  when the owner picks another configuration, which is rare, and the file is
  small.
- An owner can ask the daemon to read any file path the daemon's user can
  read, and learn whether it is a loadable configuration and, if not, the
  parser's message. `sessions.create` already does the same with its
  `configuration` field, and a member cannot reach either.
- A daemon that predates this change refuses the command as malformed
  (`bad_request`, an unsupported control command). A client that meets that
  falls back to offering the `main` role alone, or to provoking the refusal of
  a creation.
- The ordering is by key rather than by file position. A client that wants the
  file's order has no way to recover it from this command.
