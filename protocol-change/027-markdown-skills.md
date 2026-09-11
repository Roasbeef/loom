# Loaded Markdown skills

Status: implementation of the requested user skill discovery and slash completion.
Format reference: [Agent Skills specification](https://agentskills.io/specification).
Affects the client command and snapshot surface in Part 1.6.

## Problem

The terminal's slash palette only knows built-in commands. The daemon does not
load Markdown skill libraries, so a name shown by another coding client cannot
select its instructions in Loom. Discovering files independently in each
terminal would give remote clients a different library from the model.

## Decision

The daemon captures skills at assembly from its configured home directory, in
this precedence order: `.agents/skills`, `.agents/skill`, `.claude/skills`, and
`.Claude/skills`. Missing locations are quiet. Canonical directory and file
identities suppress aliases; a distinct document claiming an existing name is
reported and the first wins. Each location contains at most 256 direct child
entries, and each `SKILL.md` is at most 64 KiB. Invalid documents produce boot
warnings instead of partial entries. Captured bodies remain unchanged until a
new session runtime assembly.

The new read-only `skills` command has body `{offset: Int}`. It requires a
subscribed attachment and is available to observers. The reply is a `snapshot`
with `mode: "skills"` and `board`:

```text
{offset, skills: [{name, description, argument_hint}], next: Int | null}
```

Rows are sorted by name and include only user-invocable skills. The offset is
between zero and the visible count, inclusive. Pages contain consecutive rows
whose encoded JSON array fits in 48,000 bytes, leaving room under the 64 KiB
response envelope bound. Descriptions are at most 1024 Unicode codepoints (at most 4096 UTF-8 bytes) and argument
hints at most 512, so one row always fits. A non-null next cursor equals the
offset plus the returned count and advances strictly. Clients clear the catalogue
when replacing their attachment, fetch pages after model discovery, and classify
recognized skill commands as prompts before checking mutation authority.

An explicit `/name arguments` uses the existing prompt, prompt-content, steer,
or follow-up command. At ingress, the daemon expands a recognized leading skill
name before queue admission. It preserves the author, timestamp and subsequent
content blocks. The held message captures the selected instructions; draining
or replaying it never reloads the file. Built-in terminal commands retain their
names when a skill collides. Unknown slash text remains ordinary input for
non-terminal clients. A known skill marked `user-invocable: false` refuses
explicit invocation.

The model's `load_skill` tool advertises and dispatches only skills without
`disable-model-invocation: true`. It returns the complete captured `SKILL.md` and its source
path, with literal `$ARGUMENTS` substitution. Both invocation paths treat Markdown
as instructions: loading does not evaluate embedded shell snippets, alter tool
permissions, or implement another harness's execution metadata. Relative
resources remain accessible through ordinary tools and their permissions.

## Alternatives and cost

A client-local loader would disagree with remote daemon ownership. A separate
mutating skill command would duplicate prompt admission, author attribution and
queue behavior. Sending bodies in catalogue pages would expose and transfer
instructions before selection. The shared capture and metadata-only read reuse
those existing boundaries, at the cost of refreshing libraries at session runtime
assembly rather than watching the filesystem during a session.

## YAML and validation

`glaml` and its `yamerl` dependency parse YAML; Loom validates the resulting
typed fields. Names contain at most 64 Unicode codepoints, are lowercase
alphanumeric words separated by single hyphens, and match the parent directory.
Descriptions contain 1-1024 codepoints. Optional compatibility text has a
500-codepoint limit, and metadata is a string-to-string mapping. Other harness
fields remain inert, apart from the documented invocation flags and argument
hint. A document may have an empty body. Expansion measures the substituted
size before allocation and refuses results larger than 256 KiB.

The initial model tool definition contains selectable names and descriptions,
not source bodies. Activation discloses the complete file, including optional
metadata. Referenced resources are neither eagerly read nor inserted into the
prompt; they remain ordinary, on-demand tool operations.
