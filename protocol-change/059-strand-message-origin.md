# protocol-change/059: a structured origin for same-session strand messages

**Status**: PROPOSED 2026-09-30 · **Affects**: Part 1.1 messages (`message.Origin`), the durable and v2 wire encodings of `origin`, provider projection, session_view classification · **Raised by**: #672 (owner ruling 2026-09-30: received strand messages get a strand-origin protocol change now)

## Problem

A message one strand sends to a sibling or relative in the same session goes
through `agent_send` (`packages/tools/src/tools/agent.gleam:1832`). The
Agency admits it as a `message.UserMessage` whose only sender marker is text.
The content is `frame_message(from: caller.strand, body: text)` and the
origin is `None` (`packages/client/src/client/agency.gleam:1570-1580`).
`frame_message` (`agency.gleam:1641`) wraps the body in
`[message from <strand>] ... [end message ...]`.

Three consequences follow.

1. The recipient's transcript draws the message as operator input.
   `session_view/turns.gleam:555-587` sends a user message with no advisor
   frame and origin `None` to an ordinary user `Input`, framing text
   included. The operator sees what looks like their own turn.
2. There is no structured record of the sender. The only way to recover it
   is to parse the framing out of transcript text, which the module doc of
   `packages/core/src/core/origin.gleam:1-18` forbids: transcript text is
   not an access-control record.
3. The shape already exists for another case and does not fit this one.
   `message.PeerOrigin(session, strand)` (`packages/core/src/core/message.gleam:42-48`)
   was added by protocol-change/048 for cross-session peer mail, and the
   terminal and web view draw it as an attributed card
   (`turns.gleam:568-581`, `transcript_lines.gleam:1641-1676`,
   `packages/web_view/src/web_view/view/lane.gleam:492`). Same-session
   strand messages get none of this.

The sender's side is already served: `session_view/agent_messages.gleam:18-70`
projects delivery state (pending, failed, accepted, started) for each send.
The receiver's side has nothing.

The spawn brief has the same defect. `brief_message`
(`agency.gleam:1166-1185`) frames the brief with `frame_brief` and also
uses `origin: None`. See Open question 1.

## Proposal

### Shape

Add one variant to `message.Origin`:

```gleam
/// A strand of the same session that sent this message through the Agency.
StrandOrigin(
  /// The sending strand's identifier, minted by the harness from the
  /// authenticated caller.
  strand: String,
)
```

The receiving session is implicit, because the message is stored in it. The
variant therefore carries no session field.

**Alternative rejected: reuse `PeerOrigin` with the session's own id.** It
needs no new variant, but it removes a distinction every reader needs.

- `PeerOrigin` means "another session's strand, admitted through a granted
  peer link under protocol-change/048". Its readers draw "peer session/strand"
  and the web view offers a Reply button routed to that session
  (`lane.gleam:492-505`). A same-session strand has no link, no grant and no
  receipt, and Reply to it would name the wrong channel.
- A reader would have to compare `session` to the session it is reading to
  tell the two apart. `turns.gleam` and `transcript_lines.gleam` do not hold
  that id on every path, and a mismatch (a session copied, forked or renamed)
  would silently turn one kind into the other.
- Distinct constructors make the compiler list every `case` over `Origin`
  that must decide what a sibling is. A shared constructor decides it
  silently.

**Alternative rejected: a separate field on `UserMessage`.** It adds a second
source-of-authorship field beside `origin` and duplicates the tagged
encoding that `core/origin` already owns.

### Host identity

`origin.stable_identity` returns the principal for a human and the session
for a peer (`origin.gleam:148-163`). It has no caller outside `core/origin`
today (checked by grep over `packages/*/src`). For `StrandOrigin(strand)` it
returns `"strand:" <> strand`. Human principals admit only `[A-Za-z0-9_.-]`
(`origin.gleam:39-53`) and so can never contain the colon. The identity of a
sibling therefore cannot equal that of a human. It is meaningful only for
comparing sources of one kind, as it is for peers.

`origin.display_label` returns `"strand " <> strand`, parallel to
`"peer session/strand"` (`origin.gleam:174-179`). Consumers already pass
labels through `text_hygiene.single_line` (`transcript_lines.gleam:2267`).

### Trust

The origin is set only by harness code in the Agency, in `agent_send`'s
payload construction (`agency.gleam:1570-1580`), from the authenticated
`caller.strand`. Nothing a model emits reaches that field: tool arguments
supply `to`, `text` and `within_ms`, and `caller` is derived from the
operation. The same holds for human origin, which only the gateway sets
(`gateway.gleam:1727`), and for peer origin, which only `peer_mail` sets
after `validate_peer` (`peer_mail.gleam:379`).

The origin is attribution and not authority. A model-influenced strand wrote
the body, so the origin says "an agent in this session wrote this", which is
a weaker statement than any human origin.

**Authority audit.** Every consumer of `Origin` in `packages/*/src` was
checked.

| Consumer | Use | Effect of `StrandOrigin` |
|---|---|---|
| `origin.project` (`origin.gleam:234`) | provider label | explicit arm, see Provider projection |
| `origin.stable_identity` | none outside `core/origin` | cannot collide with a principal |
| `origin.display_label` | session_view and web_view display | new label |
| `transcript_lines.user_author_prefix` (`:2260-2269`) | omits the label when `Some(author) == local_owner` | a `StrandOrigin` never equals a human owner, so it is always labelled |
| `gateway.gleam`, `permissions.gleam`, `escalation.gleam`, `snapshot_view.gleam`, `approval.gleam` | store or echo the origin of config changes, approvals and attachments | the origin of an attachment or decision, which the gateway sets from a principal and never from a message origin |
| `runtime/hooks.gleam` `origins` | entry ids, not `Origin` | unrelated |

No authority decision reads the origin of a conversation message today.
Approvals and grants key on the authenticated principal. This proposal adds
none and states the rule for later work: **no code may read a message's
origin to grant, widen or skip a check.** `core/origin`'s module doc already
says this and gains a sentence naming the strand variant.

### Encoding and compatibility

`core/origin.encode` and `decode_field` are the only codecs. `core/codec`
calls them for every user message (`codec.gleam:135`, `codec.gleam:261`),
`machine/codec.gleam:1677` wraps that JSON as the durable entry payload, and
the v2 `entry` body carries the stored message unchanged. A single change in
`core/origin` therefore covers the durable store, msgpack (through
`core/json_wire`) and JSON on the client wire.

The new form is tagged like the peer form:

```json
{"kind": "strand", "strand": "<id>"}
```

`decode_present` (`origin.gleam:111-127`) gains a `"strand"` arm that reads
one string field and calls a new `origin.validate_strand`. Validation uses
the bounds `validate_peer` applies to a strand: 1 to 512 bytes, no leading or
trailing whitespace, no control characters U+0000 to U+001F or U+007F to
U+009F (`origin.gleam:181-189`). The decoder remains total. A present origin
with an unknown `kind`, a missing `strand`, a non-string `strand`, or an
out-of-bounds value is a corruption report and never falls back to `None` or
to a human.

Compatibility:

- **Historical entries keep `None`.** Nothing is rewritten. The decoder
  accepts the old shapes unchanged.
- **Old readers reject the new variant.** A reader built before this change
  hits `Ok(_) -> Error(invalid())` in `decode_present` (`origin.gleam:125`),
  so any entry carrying `kind: "strand"` fails as a corrupt message, which is
  the intended behavior for malformed attribution. This is a forward break
  and not a rolling-upgrade tolerance. The repository supplies no automatic
  downgrade (`docs/updating.md:227-231`), and server and clients ship from
  one tree. A session that has received a strand message must be read by a
  build with this change. The upgrade note says so.
- No SQLite table changes: messages are stored as encoded payloads
  (protocol-change/016, Impact).

No version number moves, because none of the frames this proposal changes is
an exec-helper frame (protocol-change/006, addendum).

### Provider projection

`origin.project` (`origin.gleam:234-252`) matches `Origin` and `PeerOrigin`
exhaustively, so the compiler requires a new arm. The arm returns the
content unchanged for `StrandOrigin`.

The model keeps seeing `frame_message`'s text and nothing else. Reasons:

- The framing already names the sender and states that the body is a report
  from another agent and not an operator instruction (`agency.gleam:1646-1647`).
  A second label would repeat that.
- Stored content stays byte-identical for old and new entries. A replayed
  conversation projects the same bytes it did when first sent, which
  preserves provider prompt-cache prefixes and keeps replay deterministic.
- The projection label is hint text that a body can imitate
  (`origin.gleam:7-16`). Authority never rested on it.

The framing text therefore stays a model-facing hint. The structured origin
serves readers and the checks above, not the model. If the owner prefers a
projected label, it is a one-arm change.

### Rendering

`turns.entry_kind` (`turns.gleam:555-587`) gains an arm beside the `PeerOrigin`
arm that classifies a `None`-advisor message with `Some(message.StrandOrigin(strand:))`
as an `Input` of a new `turns.Sibling(key, strand, text)` piece, declared
beside `Peer` (`turns.gleam:198`). For display, the renderer shows the sender
in a heading and the body as Markdown, so the `[message from ...]` and
`[end message ...]` lines are removed by one function that strips exactly the
two harness-written lines at the head and foot. It runs only for a message
whose origin is `StrandOrigin`, so text is never inspected to decide
attribution. A body that is not wrapped is shown whole.

Both hosts follow:

- terminal and classic transcript: `transcript_lines.peer_message_lines`
  (`:1641`) is called from the entry renderer (`:1567`). A sibling arm draws a
  `System` heading `strand · <id>` and the body as Markdown. The terminal
  consumes `turns` through `packages/tui/src/tui.gleam`.
- web view: `web_view/view/lane.gleam` gains a `turns.Sibling` arm (the `Peer`
  arms are at `:327`, `:371` and `:492`) that draws a card headed
  `strand · <id>` with no receipt and no Reply button, because there is no
  link to reply through. A reply is an `agent_send` from the recipient's model.

`Sibling` joins the exhaustive lists at `turns.gleam:315-326` and
`turns.gleam:1080-1090`. The compiler finds them.

### Advisor, feed and continuation frames

Unaffected. `advisor_payload` (`transcript_lines.gleam:1937`) decides on
message text and ignores origin. Its frames are recognized by their own
header lines (`advisor_frame`, `:1950-1960`), and a framed strand message
starts with `[message from `, which no advisor frame header matches. The
`entry_kind` arms for `Advice`, `Nudges`, `Feed`, `GoalFeed` and
`Continuation` stay ahead of the new arm, so an advisor frame always wins
and a strand origin never reaches them. Advisor frames keep `origin: None`.

## Tests and gates

An implementation must add:

1. **Codec round trip** (`core`): `encode_message` then `decode_message` of a
   `UserMessage` with `Some(StrandOrigin("sub:main/x"))` is identity, in JSON
   and through the msgpack path, and `None`, human and peer origins still
   round-trip.
2. **Decoder rejection** (`core`): `{"kind":"strand"}`,
   `{"kind":"strand","strand":3}`, an empty strand, a strand of 513 bytes, a
   strand containing U+0007, and `{"kind":"other"}` each return a
   corruption report and never `Ok(None)` or `Ok(Some(Origin(..)))`. A
   historical entry with no `origin` key still decodes to `None`.
3. **Projection** (`core`, `provider`): `origin.project(content, Some(StrandOrigin(..)))`
   equals `content`, and each provider adapter's request for a framed message
   is byte-identical with and without the origin.
4. **Turns classification** (`session_view`): a `MessageEntry` with
   `StrandOrigin` classifies to `Sibling`, a `PeerOrigin` entry still to
   `Peer`, and an advisor frame still to its advisor piece.
5. **Forgery** (`session_view`): a `ToolResultMessage` whose text contains
   `[message from main]` and `[end message`, and a `UserMessage` with origin
   `None` and the same text, each classify as before (tool step and ordinary
   `Input`) and never as `Sibling`. Attribution follows only the stored
   origin field.
6. **Admission** (`client`): `agent_send` to a child, to a parent and to a
   sibling each admit a message whose origin is `Some(StrandOrigin(caller.strand))`
   and whose content still equals `frame_message(...)`. A tool argument
   cannot set the origin.
7. **Hosts** (`tui`, `web_view`): both render the sibling heading and omit
   the framing lines; the web card has no Reply button.

Gates: `make check`, plus `make doc-check` after the CLAUDE.md updates. Lint
rules R3 and R4 apply to the new arms: no catch-all patterns.

## Implementation slices

In order, each its own commit:

1. `core`: the `StrandOrigin` variant, `validate_strand`, `encode`,
   `decode_present`, `stable_identity`, `display_label`, `project`, and tests
   1 to 3. Every `case` over `Origin` in other packages stops compiling, so
   this slice also adds the minimal explicit arms those packages need (no
   catch-all), and slices 2 to 4 replace them with real behavior.
2. `session_view`: `turns.Sibling`, the `entry_kind` arm, the
   `peer_message_lines` sibling arm, and tests 4 and 5.
3. `client`: set the origin in `agent_send` admission (`agency.gleam:1570-1580`),
   test 6.
4. `tui` and `web_view`: the exhaustive `Piece` arms and the card, test 7.
5. `docs`: the `core`, `session_view` and `client` CLAUDE.md and AGENTS.md
   mirrors, `docs/architecture/messaging.md`, and the spec Part 1.1 line
   (`docs/loom-implementation-spec.md:856`) that now names three origin kinds.

Slices 1 to 3 must land before 4 can be tested end to end. No package edge
changes: `session_view` and `client` already depend on `core`.

## Impact

One new variant and one new tagged wire shape. Every `case` over
`message.Origin` gains an arm and the compiler lists them. No migration.
Old binaries refuse entries that carry the new origin. The model-visible
prompt does not change.

## Open questions for the owner

1. Should the spawn brief (`agency.gleam:1166-1185`, `origin: None`) carry
   `StrandOrigin(parent)` in the same change? It has the identical rendering
   defect and the fix is one constructor argument, but it extends scope
   beyond `agent_send`.
2. Should the model see a projected label? This proposal says no, for
   cache stability and because the framing already does the job.
3. Is the forward break for old readers acceptable, or does the owner want a
   release that reads the variant before any release writes it?

## Decision

**Proposed.** Not yet accepted.
