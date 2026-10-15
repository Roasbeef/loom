# Strand notes in the web view

The notes browser has its own Notes tab in the existing panel. It keeps the transcript
and composer visible while a reader searches the focused strand's current
notes, opens one value, and returns to the list.

## Candidate selection

The owner requested three independent mockups, from Luna, Sol and Astra,
followed by a separate Astra selection. The selector chose Sol's key-first
index and readable/raw reader, with Astra's return navigation: preserve the
query and list position and restore keyboard focus to the opened row.

| Candidate | Screenshot | Assessment |
| --- | --- | --- |
| Luna | [Candidate](https://github.com/Roasbeef/loom/pull/990#issue-5858249484) | Quiet index, but removes existing shell controls and includes ages absent from the notes data. |
| Sol | [Candidate](https://github.com/Roasbeef/loom/pull/990#issue-5858249484) | Chosen. Stable keys, revisions, complete/excerpt labels and source inspection map directly to the current notes read. |
| Astra | [Candidate](https://github.com/Roasbeef/loom/pull/990#issue-5858249484) | Strong return navigation. Its extra titles, reconstructed example source and automatic panel widening are excluded from the implementation. |

The owner subsequently requested a dedicated Notes tab so advisor information
does not clutter the reader. The production adaptation retains the existing
resizable panel and adds Notes after its current tabs. It compresses the
mockup's introduction to fit the default panel width and
uses a chevron for opening a note within the panel.

## Data and navigation

The existing `notes` command supplies a bounded `notes_view.Board`: strand,
snapshot revision, total cell count and the available notes in server order.
Each note has a key, value revision, original text and complete/excerpt marker.
The browser adds no timestamps, editing, persistence route or full-value read.

Complete values use the shared structured-note and todo presentation. Excerpts
remain literal, including when their prefix happens to parse. Raw inspection
shows the exact supplied text. When the board omits cells, search applies only
to the available notes and the displayed count says so.

A strand change clears the query and selection. A late reply for another strand
cannot replace the displayed board. Refresh resolves a selected key against the
replacement board, returning to the index if that key is absent. Notes events
are read-only and preserve the existing shell and daemon authorization boundaries.

## Production captures

Screenshots are published in the PR description and kept out of the source tree.

The final UI was captured from the actual production Lustre components and
generated browser assets, connected over a real WebSocket to disposable fixture
notes. These are representative data, not an operator's session.

| View | Screenshot |
| --- | --- |
| Dedicated Notes tab and index | [Desktop index](https://github.com/Roasbeef/loom/pull/990#issue-5858249484) |
| Readable note detail | [Desktop reader](https://github.com/Roasbeef/loom/pull/990#issue-5858249484) |
| Narrow layout | [Mobile](https://github.com/Roasbeef/loom/pull/990#issue-5858249484) |
| Empty board | [Empty notes](https://github.com/Roasbeef/loom/pull/990#issue-5858249484) |
