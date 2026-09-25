# README assets

## Logo

The open-weave logo is reconstructed from the selected project artwork as
font-independent SVG geometry. `loom-logo-light.svg` is the horizontal lockup
for light backgrounds; `loom-logo-dark.svg` uses an ivory wordmark and crossbars
for dark backgrounds. The README selects between them using a `picture` element.

`loom-mark.svg` is the standalone amber-and-charcoal symbol.
`loom-mark-white.svg` is its monochrome counterpart for dark backgrounds.
Crossing gaps remain transparent in every version.

## Terminal capture

`code-mode.png` shows the native terminal at commit `4807bcb1`, connected to an
isolated local daemon. A scripted Anthropic-compatible provider supplied the
assistant text and a `code_mode` call. No external model API or existing user
session was used.

The program was vetted, compiled offline, and executed through the production
code-mode pipeline. It used `cap/task.parallel_map` and `cap/fs.read` to read
three sample Markdown files. The recorded tool result returned four lines for
each file. The macOS enforcement report remains visible in the capture.

The image renders an actual 116-by-48 terminal frame from
`tmux capture-pane -e -p` with its ANSI colors and Menlo typeface. Transcript text,
results, and UI elements were not composited or rewritten for the image.

## Peer-link captures

`peer-links-chooser.png`, `peer-links-confirm.png`, and `peer-links-linked.png`
show the native 116-by-38 terminal at post-split code commit `0e3fae3f`. Two
sample sessions were resident in the same isolated daemon. The operator
selected **Review target** from `/sessions`, keeping **Coordinator / main** as
the source, then pressed `l`. The operator entered the target's exact `main`
strand, explicitly selected the `may_wake` permission, and created the link.
No model request was sent.

Each image renders an actual full-color `tmux capture-pane -e -p` frame with
`docs/design-notes/tui-agent-workspace/render_capture.py`. The UI content was
not composited or rewritten.
