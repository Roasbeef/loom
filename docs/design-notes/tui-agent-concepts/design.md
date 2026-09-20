# Loom TUI refresh: make agents visible and actionable

Design exploration, 20 September 2026. Source inspected: `Roasbeef/loom` at `1ab97ba5086cf2bef98fa69941306a427feeba68`. This is a proposal and interactive mockup, not an implemented Gleam patch. All mockup agent activity is illustrative.

## Recommendation

Keep Loom's amber identity, brighten the text, and organize the interface around the conversation and the work happening across strands. Make the agent workspace the main improvement: a task-oriented roster, a detail view for the selected strand, and a composer that explicitly names its recipient and delivery mode.

Use the Focus layout for ordinary conversation. Use the compact agent rail while parallel work is active. Expand `/agents` into a dedicated workspace when the operator wants to inspect tasks, find a result, respond to a question, or steer a particular strand. These are views over the same session, not separate products.

## What was actually checked

- Cloned the repository and inspected its README screenshot, `theme.gleam`, `agents.gleam`, `reviewer_status.gleam`, `tool_activity.gleam`, `markdown.gleam`, `protocol.gleam`, and the layout, transcript, footer, and keyboard handlers in `tui.gleam`.
- Built the TUI with released Gleam 1.18.1 and Erlang/OTP 29.0.5. The final build exited successfully.
- Ran the native `gleam run -- --demo` in a 116-column, 38-row terminal. Opened the agent rail with Shift+Tab and opened the model selector with `/model`.
- Captured a second native demo run through a pseudo-terminal. This confirmed the live renderer and agent rail. It did not exercise a provider-backed session, real parallel tool execution, or the sandbox.
- Reviewed the official repository screenshots/demo assets for Codex, Claude Code, pi, and oh-my-pi. Those assets depict particular versions; they are visual references, not proof of every current interaction.
- The tracked Loom checkout remained unchanged after the build and demo exploration.

## Why the current agent view feels limited

The basic `Strand` presentation record contains only `id`, optional `name`, and optional `live_phase`. The current rail gives each strand a name row, phase row, and blank row. Any absent live phase is drawn as `idle`. A `sub:` prefix adds a generic child indent; it is not a real parent/child topology.

The resulting view answers which strands exist and which have a phase. It cannot, by itself, reliably distinguish completed work, failure, waiting for another strand, a question for the operator, or a recovered strand whose state is incomplete. A brighter dot would leave that problem intact.

The useful starting point already exists in `reviewer_status.observe`: it joins captured operation state with a bounded task excerpt, current tool calls, and pending-input evidence. Generalize that kind of projection for the roster rather than inventing a second lifecycle inside the TUI.

## Proposed agent workspace

### Roster

Each row should expose a stable strand name, a short task brief, and the most useful current activity. For example: `palette` / `Refresh semantic colors` / `Running · make test-tui`.

Use explicit labels and distinct glyphs:

| State | Example | Meaning |
| --- | --- | --- |
| Working | `◉ Running checks` | An authoritative current operation is active. |
| Waiting | `◌ Waiting on 2 strands` | Work is blocked on a known dependency. Do not infer this from a quiet stream. |
| Needs input | `? Choose light background` | There is an actual pending question or approval. A question and an approval remain distinct in the detail view. |
| Finished | `✓ Result available` | The latest relevant operation has a recorded successful outcome. |
| Failed | `× Tool failed` | A recorded failure needs inspection. |
| Halted | `■ Halted` | An explicit stop or held-input state is recorded; preserve the distinction from idle (see #399). |
| Idle | `○ Idle` | There is no live operation and no stronger outcome presentation is justified. |
| Unknown | `— State unavailable` | The data needed for a more specific statement is not loaded or is stale. |

Keep roster order stable during navigation. Summarize attention at the top and provide a deliberate way to visit the next item needing attention. Do not continuously reorder the focused list as work changes.

Keep the advisor in a distinct section: its observation and verdict role is different from a worker's task. Preserve Loom's rule that the primary cannot negotiate with its advisor; do not add a generic message-to-advisor action by analogy with worker controls.

Advisor nudges must retain their full text in compact mode, including multiline and narrow-terminal cases (#447). A summary or badge is supplemental; it must not replace the nudge body or require expansion to read it. Keep pending and delivered states distinct. Treat the main/advisor split in #448 as a related experiment, not a settled default.

### Selected-strand detail

Show the task brief, state, latest useful update, recent tool activity, and a result or exact pending question. Start with a bounded summary; offer the full strand transcript when deeper inspection is needed.

Do not fabricate percent-complete bars for open-ended work. Elapsed time and the current action are useful only when supported by observed state. Model and token/cost details belong here when reliably attributable to this strand; they should not crowd every roster row.

### Inspection versus message target

Moving through the roster previews a strand without retargeting the composer. An explicit Open action changes the active strand. Always label the composer `To: <strand> · follow-up` or `To: <strand> · steer`, using Loom's actual submission semantics.

Preserve draft text and reading position per strand. An unsent draft for main must not silently become a message to a worker. Keep the selected strand's stable ID through roster refreshes; an index alone is not a durable target.

For a pending approval, open the existing exact-request approval surface. Preserve its captured ID, sequence, action, grants, and no-default-selection behavior. A roster badge must never become a broad or ambiguous Allow button.

### Narrow terminals

Reserve a meaningful transcript width before displaying a side rail. Below the minimum, show a compact activity summary and open the agent workspace as an overlay or full-width view. The browser mockup stacks regions on a phone for review; a terminal implementation should switch views instead of stacking a large roster above the conversation.

## Visual system

Vibrancy should come from readable semantic accents and clear activity transitions. Body text remains neutral, and only relevant status changes animate. Keep motion confined to actual work, respect reduced-motion settings, and avoid repainting settled transcript content for animation.

Suggested dark palette:

| Role | Hex | Use |
| --- | --- | --- |
| Canvas | `#11151C` | Main surface |
| Raised surface | `#1A202A` | Composer, selected row, tool detail |
| Primary text | `#E7EDF5` | Conversation and source |
| Secondary text | `#9DA6B5` | Metadata; no ANSI dim |
| Amber | `#FFBD69` | User input, focus, requests needing attention |
| Cyan | `#6EDBE8` | Active work and agent identity |
| Green | `#8ED6A1` | Confirmed success and additions |
| Violet | `#C6A7F2` | Advisor identity |
| Red | `#FF8E9B` | Failures and removals |
| Structural line | `#354050` | Dividers; not text |

Pair every color with a label or glyph. Check actual foreground/background pairs, plus light and 256-color variants. The present `quiet_text()` combines an already-muted RGB value with ANSI dim; both code comments and punctuation use it. Remove double dimming from readable text and give code punctuation its own legible treatment.

Remove the full transcript rectangle in the Focus layout. Keep a small gutter, consistent turn spacing, subtle user shading, and a distinct composer. Use separators where a region changes responsibility, not around every message.

## Tool and conversation improvements

- The present code-mode compact preview limit is 60 lines. Default successful calls to an activity/result summary; show a short source excerpt only when it helps, and retain full source and exact results through expansion.
- Keep errors and pending decisions visible. Do not collapse a failed invocation into the same quiet presentation as a successful read.
- Make tool state truthful. The generic `ToolCall` mark currently uses the success style; reserve a green check for known completion and use a neutral or active mark while the outcome is unknown.
- Prefer compact, meaningful output such as the three filename/count pairs over a raw JSON envelope when the result shape is known. Preserve access to the original output.
- Keep the current activity near the composer, with the target and interruption semantics visible. Put detailed token/cache accounting behind an inspector; retain useful model/context/cost information in a readable footer.
- Preserve semantic anchoring and scroll position as results arrive or details expand. A visual redesign must not break selection, copying, streamed-to-durable handoff, or the existing render pacing.

## Reference lessons

| Reference | Useful pattern for Loom |
| --- | --- |
| [Codex](https://github.com/openai/codex) | A conversation-first reading flow and visually grouped work summaries. |
| [Claude Code](https://github.com/anthropics/claude-code) | Compact action/result pairs and a clear current activity close to input. |
| [pi](https://github.com/earendil-works/pi/tree/main/packages/coding-agent) | A strong editor/footer boundary, expandable tools and thinking, and semantic theme roles. |
| [oh-my-pi](https://github.com/can1357/oh-my-pi) | Structured tool presentation, informative status, and explicit question surfaces. |

Loom's distinctive opportunity is the coordinated session: strands, collaborators, durable outcomes, and advisor state. Give those concepts a legible home without filling the conversation with permanent telemetry.

## Implementation order and data boundaries

1. **Readability pass:** `theme.gleam`, code punctuation in `markdown.gleam`, and header/footer styling. Split text contrast from structural-divider colors. Validate light/dark and ANSI fallback behavior.
2. **Agent presentation model:** factor a pure projection around the existing captured view. Audit which operation, result, pending-input, approval, and lineage facts are already available. Retain explicit unknown values when history is outside the capture. Do not derive a completed state from `live_phase == None`.
3. **Agent workspace and compact rail:** `agents.gleam` and the layout/keyboard/selection integration in `tui.gleam`. Separate inspected ID from active ID; preserve per-strand drafts and scroll anchors. Reuse the existing approval and transcript surfaces.
4. **Progressive disclosure:** tool previews, completed results, advisor details, and turn completion summaries. Keep source and execution provenance accessible.
5. **Data additions only where necessary:** real ancestry, stable unread/result acknowledgements, and per-strand usage may require additional data. Inspect existing captures first. Any frozen interface change needs the repository's protocol-change process; it is not a theme edit.

Meaningful acceptance checks: roster updates cannot redirect a draft; selection remains on the same strand through inserts/removals; operation completion is never inferred from inactivity; a pending approval opens the exact captured request; narrow layouts retain the active target and attention count; switching preserves the reading position; and compact output retains a path to full source/results.

Run the focused TUI gate, existing snapshot and replay checks, then the repository's required full gate before proposing a production patch. No production changes or commits were made during this design exploration.

## Related work

- [#448](https://github.com/Roasbeef/loom/issues/448): main/advisor split-pane exploration.
- [#447](https://github.com/Roasbeef/loom/issues/447): full nudge text in compact mode.
- [#399](https://github.com/Roasbeef/loom/issues/399): halted strands must not read as idle.
- [#373](https://github.com/Roasbeef/loom/issues/373): strand-scoped history paging and its protocol boundary.
- [#374](https://github.com/Roasbeef/loom/issues/374): splitting the TUI module; keep new presentation logic focused.
