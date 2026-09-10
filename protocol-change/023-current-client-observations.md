# Current notes and host tool availability

Status: implementation of the approved developer-experience improvements.

## Problem

The notes panel displays the latest run-start digest in the loaded transcript.
Notes written later are invisible until another run injects a digest. Tool
registration failures appear only in server logs, while the terminal cannot
distinguish an unavailable tool from one disabled on its selected strand.

## Decision

The read-only `notes` command takes a strand and returns a `snapshot` with mode
`notes`. Its `board` contains the strand, `as_of` session revision, total note
count, and newest-first rows with key, last-write sequence, text, and extent
(`complete` or `excerpt`). The gateway reads the board in one bounded storage
cut. Displayed values are at most 4096 UTF-8 bytes each; encoded rows consume at
most 48,000 bytes together. Omitted rows and excerpts are labelled explicitly.

This is an auxiliary read. A board exceeding the storage reader's byte or cell
limit refuses this view with `notes_too_large`, while ordinary conversation
capture and controls remain available. The terminal fetches when `/notes`
opens and when `r` refreshes the panel. It shows capture and write revisions;
the historical run-start fallback is labelled as historical.

Ordinary metadata cuts add optional `tool_availability`, containing actual
registered tool names and an optional `code_mode_issue` boot diagnostic. The
terminal combines registration with the selected strand's enabled tool names.
It reports enabled, disabled for this strand, unavailable with a reason, or host
availability not reported. A historical enabled-tool list alone cannot certify
current registration.

## Alternatives and cost

Adding every agent note to ordinary snapshots would let an oversized board
make the whole conversation unreadable. Mirroring notes into presentation
registers would add another durable write and a consistency obligation. The
auxiliary read uses the existing bounded reader and command-response lane,
without a new actor, timer, or storage interface.

These observations are for the human operator. They do not inject a notes
refresh into model context or change tool authorization.
