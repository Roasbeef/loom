# An etui client for Loom

Status: working evaluation for issue #114, not an adoption decision.

## The question

Issue #114 left one fact unmeasured: an etui screen rendered in the original
container, but keyboard bytes never reached its Erlang backend. It also left
the likely next step, a Mork-to-etui markdown adapter, as an estimate rather
than running code.

The client in `packages/tui_gleam` answers both questions. In a Herdr PTY on
macOS, etui receives resize, character, arrow, Enter, Tab, Escape, and control
key events. The same process attaches to a real `packages/client` server,
subscribes to an existing session, decodes its durable entries, loads the live
model catalogue, and sends frozen ClientGateway commands. Mork parses assistant
markdown into etui spans with no HTML or ANSI intermediate.

The result keeps etui in contention. It does not yet justify replacing the Go
client: OTP 28 is required for the markdown path, and approval plus reconnect
semantics remain incomplete.

## What is running

The evaluation is a separate Gleam package rather than a rewrite in place.
That keeps the shipped client and its complete fake/conformance suite intact
while the candidate is measured against the real gateway.

The running path is:

```text
etui input and render loop
        |
        | immutable messages drained on Tick
        v
Stratus websocket actor
        |
        | ClientGateway v1 JSON
        v
packages/client server
        |
        +-- durable entries through core/codec
        +-- strand and live_op snapshots
        +-- configured model catalogue
```

The actor owns the socket. The terminal model owns presentation state. The
view performs no I/O, and the protocol module reuses `core/codec` for durable
entry bodies rather than translating them into another private message tree.

## Interaction vocabulary

The surface uses slash commands. `/model` opens a dedicated selector rather
than asking the operator to remember a model name. The selector searches name,
dialect, and provider model ID; it ranks exact, prefix, and substring matches
before initials-style fuzzy matches. Arrow keys wrap, Enter selects, and
Escape closes.

Agent visibility follows the same source-of-truth rule. A strand is the durable
agent identity already published by ClientGateway, and `live_op.phase` is its
current activity. `sub:` strands are shown as children. No client-side worker
registry competes with that state. The rail is hidden by default after live
feedback showed that it consumed too much of the chat surface. `Tab` reveals
it, while `/agents` opens the larger topology inspector.

Reasoning and tool traffic borrow the restrained hierarchy visible in Codex
and Charm's Crush rather than presenting every record at equal weight:

- assistant prose is rendered as CommonMark;
- reasoning is a dim summary row by default;
- tool calls and results are compact state rows with bounded previews;
- `Ctrl+G` or `/details` reveals the full durable reasoning and tool text;
- Page Up and Page Down move through a tail-following transcript viewport.

This keeps the normal reading path quiet. Detail remains reachable without
making a long tool result the visual center of the session.

## Visual references

The implementation reads the source and screenshots for
[Crush](https://github.com/charmbracelet/crush),
[Bubbles](https://github.com/charmbracelet/bubbles),
[Glamour](https://github.com/charmbracelet/glamour),
[Lip Gloss](https://github.com/charmbracelet/lipgloss), and
[Glow](https://github.com/charmbracelet/glow), plus the installed Prime Agent
client.

The pieces taken are structural rather than cosmetic. Crush contributes its
quiet chat plane, compact thought/tool rows, temporary detail expansion, and
centered model dialog. Bubbles contributes focused input ownership, viewport
navigation, and list wrapping. Glamour and Glow contribute markdown rhythm:
cyan hierarchy, restrained list markers, quote rails, code rails, and link
contrast. Lip Gloss contributes the centered overlay and status-strip
composition. Prime Agent contributes model search priority and a strand-like
running/idle/inactive agent summary.

Loom keeps its own palette: graphite framing, amber operator actions, cyan
agent activity, and red refusals. Color is redundant with marks and labels so
the interface remains legible on reduced-color terminals.

## Markdown and terminal safety

Mork 1.12.1 owns CommonMark parsing. The adapter walks its public `Document`
tree and emits styled etui lines for headings, paragraphs, emphasis, strong
text, code, lists, links, images, quotes, tables, thematic breaks, and hard
breaks. Links retain OSC 8 destinations where the terminal supports them.

Model text is normalized before parsing. C0 and C1 controls, DEL, bidi
formatting controls, zero-width formatters, variation selectors, BOM, and tag
characters become a visible replacement glyph. A model-authored ESC byte
therefore cannot become a terminal escape sequence. Tests assert this property
over representative hostile strings in addition to markdown structure and
link behavior.

Transient stream fragments are held separately from durable entries. When a
settled entry arrives for a strand, its fragments are dropped before render.
Without that separation, the final assistant answer appears twice at exactly
the point where it becomes durable.

## Open-source Baseten catalogue

`docs/examples/loom-baseten.toml` translates the non-secret model metadata
already used by the local pi and Prime Agent installations into Loom's existing
catalogue schema:

- Moonshot Kimi K3;
- DeepSeek V4 Flash 0731;
- GLM 5.3;
- GLM 5.3 Flash.

No provider schema change is needed. The models use Loom's existing OpenAI
dialect, `base_url`, `api_key_env`, context/output limits, thinking setting,
and role routes. The credential remains an environment reference and is not
copied into configuration, terminal state, or logs.

## Compatibility cost

The evaluated etui commit is pinned at
`699d2c0a1e7f5d2ae109b00927bd5484a056517a`. The pin includes input and raw
terminal fixes newer than etui 1.0.1 and avoids silently tracking a young API.
It requires Gleam 1.16 or newer.

Every Mork release checked from 1.2.2 through 1.12.1 states Gleam 1.13+ and OTP
28+ for the Erlang target because of PCRE2. Loom currently promises Gleam 1.11+
and OTP 27+. For that reason `tui_gleam` is opt-in and absent from the root
package and release lists. Adoption must either raise the repository floor or
choose a different markdown parser; this evaluation does neither silently.

On the current machine, a warm warning-free package build takes about 0.3
seconds and compile-plus-test takes about 0.4 seconds. The package test suite
and Loom's package-scoped lint run independently of the shipped TUI.

## Protocol coverage and remaining gates

The client currently sends `subscribe`, `prompt`, `models`, `set_config`,
`abort`, branch-scope `fork`, and standalone `compact`. It applies full,
strand, model, and config snapshots plus entry, stream, operation, usage,
escalation, and error events. Unknown event names remain forward-compatible.

Three gates remain before this can replace `packages/tui`:

1. Implement approvals without weakening protocol-change/007. The prompt must
   display a bounded, sanitized action, and approval must echo the exact action
   and grants. The current client only announces a pending escalation.
2. Implement resume/catch-up and disconnect request failure with the sparse
   sequence semantics documented by the Go client. A process that reconnects
   but loses or duplicates durable rows is not a replacement.
3. Decide the toolchain floor and release shape explicitly. Only then should
   the package enter root `PACKAGES`, replace `bin/loom-tui`, or change the
   distribution artifact.

The next useful slice is approval, followed by reconnect. Neither requires a
wire change. Adoption and the toolchain-floor change do require an explicit
architecture decision after those behavioral gates are green.
