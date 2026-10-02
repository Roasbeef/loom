# Code-mode prompt cues

This change is based on `f84842d17bc3230c2a796f136d222b5179b5be28`.
[Pi's code-mode tool](https://github.com/earendil-works/pi/blob/7fbbd5f4a1d982bb02d63472dde0774fa639f99b/packages/coding-agent/src/extensions/codemode/tool.ts)
places an executable alternative and resolved result shape beside a direct
tool. Loom adopts that placement for its five core workspace tools. The host
checks the default seam's import permission and serviced capability together.
The hints preserve the differences between native and capability reads, edits
and process execution.

The revised `loom-default-13` system pack starts planned batches immediately.
The third extraction probe remains a fallback. Discovery before unfamiliar
programs, bounded concurrency, completeness checks and warning-free compilation
remain explicit. A compile rejection preserves diagnostics and states that the
program did not run. Existing recipes, module indices and public types remain.

## Rebase integration

PR #683 is rebased onto `5fbcda3ad473338d810376177d85153f23900106`.
The combined prompt is `loom-default-13`, retaining main's LSP investigation
paragraph and detailed compiler-import/repair advice beside the immediate
batching cues. Prompt length has no hard 8,500-byte limit: the client test
checks completeness and substantive content without an arbitrary upper bound.
Useful batching and judgment guidance remains explicit even when it adds bytes.
The size comparison below belongs to the original
`3e3d38563bc3e45d0f41e8e62fce5c05bfcdcdf7` implementation against `f84842d17`;
it is not a new size measurement of the integrated prompt.

## Size comparison

The fixture serializes the five core tools and `code_mode` through the Anthropic
adapter, with both production seam kinds, the default policy plus notes, and
background execution. Both phases use identical host offers. Extensions,
configured MCP surfaces and other optional tools are absent. The comparison
uses UTF-8 bytes, not estimated tokens or a provider token counter.

| Surface | Before | After | Difference |
| --- | ---: | ---: | ---: |
| `code_mode` description | 44,240 | 43,947 | -293 |
| Serialized six-tool array | 55,223 | 55,876 | +653 |
| Tool-index snippets, joined with newlines | 1,815 | 1,644 | -171 |
| System pack's `tool_discipline` section | 2,096 | 1,833 | -263 |
| Sum of those model-facing surfaces, counting the description only within the array | 59,134 | 59,353 | +219 |

The new call hints add 946 bytes. They appear only in descriptions, avoiding a
second copy in the tool index. Repeated selection prose shrinks, but generated
public types still dominate the description. This is no evidence of fewer
model turns, fewer compile errors or improved task latency. That needs a
matched model evaluation on the same tasks.

## Validation

The focused registry suite passed all 16 tests. Its host matrix covers absent
code mode, missing import permission, missing service and an alternate-only
capability. Direct editor and process differences are checked beside the call
hints. The pure prompt suite passed all 101 tests. The affected gate, independent
review and hosted verification are recorded after they finish.

[PR #673](https://github.com/Roasbeef/loom/pull/673) owns calling instrumentation.
[PR #433](https://github.com/Roasbeef/loom/pull/433) owns the reduced tool roster.
This change adds neither instrumentation nor a new discovery mechanism.
