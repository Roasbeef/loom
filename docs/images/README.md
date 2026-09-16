# README terminal capture

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
