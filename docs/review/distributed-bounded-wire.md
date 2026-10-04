# Shared bounded MessagePack preflight

The command-offer boundary needs the executor's existing MessagePack bounds
without importing executor codecs into broker code. The scanner now lives in
pure core/bounded_msgpack. It retains the same fixed limits: 256 KiB total,
16 levels of depth, 2,048 nodes, 128 entries per container, 8 KiB strings and
128 KiB binary fields. Trailing data is refused before ordinary decoding.

The executor maps every preflight or semantic decoding failure to its existing
Invalid result. Encoding still encodes and validates the resulting bytes, and
nested native frames receive their own preflight. The extraction introduces
no configurable limits, effects, dependencies or command API.

Root independently ran the full core and executor gates in the isolated
candidate worktree: 167 core and 159 executor tests passed, and the command
exited zero. Worker format, lint and documentation gates also exited zero.
The initial executor attempts lacked downloaded dependencies and the local
helper; those setup failures were resolved before the complete successful run.
No dependency manifest changed.

Nine core tests cover exact limits and one-over refusal, aggregate sibling
node consumption, truncated lengths, unsupported values, non-byte-aligned
input, trailing data, duplicate map keys and nonfinite floats. Two executor
controls retain wire behavior. Bypassing raw preflight compiled but failed six
intended limit assertions; three other controls passed. Source restoration was
byte-exact before review and the final gates.

Independent review found no actionable findings. It compared the extracted
scanner with the pinned original, checked every frozen file digest and traced
nested decoding callers. These logical bounds are not an equivalent resident
memory guarantee. JavaScript execution, command-offer assembly and separate-host
product acceptance are outside this component result.
