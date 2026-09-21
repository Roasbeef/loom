# 045: Shared durable notes in code mode

Status: accepted for implementation within the owner's requested notes work.

## Problem

The default workspace code-mode surface cannot import cap/strand. Although
orchestration programs can use strand.note and strand.notes, an ordinary
workspace program cannot persist structured analysis to the agent blackboard.
The source API alone therefore does not establish the default agent's access.

## Decision

A host with an Agency installs a narrow notes door when selecting its code-mode
seams, including WorkspaceOnly. The door holds only the existing note and notes
callbacks. It adds cap/notes to that host's workspace and orchestration imports,
and derives descriptions, routing, and admission limits from the same door.
Unconfigured hosts, extensions, and resident hooks do not gain this module.
The existing strand APIs and their return keys remain unchanged.

The new API is notes.put(key, value), notes.get(key), and notes.list(prefix).
Caller-owned write keys retain their 128-character bound. Namespace-qualified
read prefixes allow 4096 characters, including nested child strand names;
this same read-prefix bound applies to agent_notes.
Put writes the caller's own namespace through Agency, retaining result schema
checks. Get and list address keys relative to agent/, and list returns that
same relative form. Get filters prefix-query results by exact full key. Missing
and JSON null remain distinct. Values must have a lossless JSON representation.
These are session-scoped, durable, last-write-wins registers, not cross-session
memory or transactional read-modify-write operations. Writes notify nobody.

cap/fs.read recognizes the exact note:// prefix and calls notes.read with its
opaque suffix. The host serializes that exact note as JSON. The URI is never
resolved as a filesystem path. Missing cells produce not_found. Virtual paths
are read-only: write, edit, and directory enumeration refuse them in the cap
facade. There is no OS mount; shell tools need an explicit workspace copy.

Each execution admits 256 notes.put calls and 64 each of notes.get, notes.list,
and notes.read, for at most 192 new scan admissions. The legacy orchestration
aliases retain their separate limits. A stored value or list reply is limited to 1 MiB of
encoded JSON, excluding the fixed get reply envelope; larger values fail explicitly and belong in artifacts or files.
No arbitrary-register, lifecycle, or cross-session authority is added.

## Alternatives and cost

Enabling all of cap/strand in workspace code mode would also grant spawning
and messaging. Requiring a model round trip through agent_note would still
force the model to copy the data being persisted. A filesystem mount would
require a separate publication and cleanup lifecycle. The selected design adds
one optional data door, one facade, and one router over existing persistence.

A read-only design consultation checked caller binding, exact key lookup,
extension exclusion, and admission limits. It recommended a separate notes.read
wire operation so virtual reads cannot bypass their own quota. Implementation
validation and the independent final review are recorded with the change.
