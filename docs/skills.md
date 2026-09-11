# Markdown skills

Loom discovers user skill libraries and loads instructions into model context
when they are selected, following the
[Agent Skills format](https://agentskills.io/specification).

## Discovery and completion

The daemon's configured home supplies these locations, in precedence order:
`.agents/skills`, `.agents/skill`, `.claude/skills`, and `.Claude/skills`.
Each skill is a direct child directory containing `SKILL.md`. Symbolic aliases
of the same directory or file contribute one entry. A distinct document using
an already loaded name produces a warning, and the first document wins.
Malformed YAML or supported metadata also produces a boot warning.

The terminal fetches names, descriptions and argument hints from the attached
daemon. Type `/` or a command prefix, select a row, and press Tab to complete
it. Enter also completes a selected row; enter arguments or press Enter again
to invoke it. Built-in commands retain their names when a skill claims one.

The catalogue is captured when the session runtime is assembled. Restarting
that runtime refreshes files. Existing sessions retain their active tool names;
start a new session to receive newly introduced tools such as `load_skill`.
There is no filesystem watcher.

## A minimal skill

Create `~/.agents/skills/explain-change/SKILL.md`:

```markdown
---
name: explain-change
description: Explain a code change and its validation to a reviewer.
argument-hint: "[change or question]"
---
Explain $ARGUMENTS from the source and available test results. State the
behavior before and after, and distinguish evidence from assumptions.
```

After starting a new session runtime, type `/explain-ch` and press Tab. Add
arguments and submit, for example `/explain-change the queue editor`.
The model can also select this skill automatically from its description.

To make a skill explicit-only, add `disable-model-invocation: true`. To permit
model selection while hiding its slash command, add `user-invocable: false`.
These are independent settings.

## Progressive disclosure

The model initially sees only the available names and descriptions in the
`load_skill` tool definition. When a description matches the task, it calls
`load_skill` with the name and arguments. The result supplies the complete
captured `SKILL.md`, including its source path. Bodies of unselected skills
never enter context. Referenced files in `references/`, `scripts/` or `assets/`
remain on-demand reads or executions through ordinary tools and permissions.

An explicit `/skill-name arguments` loads that skill directly. Loom expands it
before admitting the user prompt or placing it in the queue. The selected
instructions, timestamp, author and remaining content blocks stay together
while queued, even if the file changes before the turn begins.

Loom substitutes the literal `$ARGUMENTS` marker. It does not execute embedded
shell snippets while loading, interpret another harness's execution metadata,
or treat `allowed-tools` as a permission grant. The existing broker remains
authoritative for subsequent actions.

## Metadata

`glaml` parses YAML frontmatter. `name` and `description` are required strings.
Names contain lowercase Unicode letters or numbers separated by single hyphens,
contain at most 64 codepoints, and match their parent directory. Descriptions
contain at most 1024 codepoints. Optional `license`, `compatibility`, and
string-to-string `metadata` are retained in the activated document. Compatibility
text is limited to 500 codepoints.

Loom also recognizes `argument-hint` (a string), `user-invocable: false` (hide and
refuse the slash command), and `disable-model-invocation: true` (require an
explicit invocation). Both invocation modes are enabled by default. Quote YAML
strings that contain a colon followed by a space or begin with collection
syntax, such as `argument-hint: "[subject]"`.

Each document is limited to 64 KiB and each location to 256 directory entries.
Expanded instructions are limited to 256 KiB, measured before substituting
repeated arguments. Metadata pages fit the existing response frame bound and
carry no instruction bodies. [Protocol 027](../protocol-change/027-markdown-skills.md)
defines their wire format.
