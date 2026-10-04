# protocol-change/066: a session subtitle, and renaming from the page

**Status**: ACCEPTED 2026-10-04 · **Affects**: control v2 session metadata
(`sessions.list`, `sessions.get` and every reply that carries a session),
catalogue schema version 5, the web view's operator page and home ·
**Raised by**: owner ruling of 2026-10-04 ("auto subtitle + rename"), after the
workspace home listed every session of a workspace as the same workspace and
branch · **Implemented**: storage catalogue, daemon manager and hub, control
codecs, web view

## Problem

Sessions in one workspace read alike. The home page and the sidebar draw a
session's display name, which is whatever the creator typed or the host
defaulted to, and a created-age line. Several sessions started from the same
workspace therefore differ by nothing a person recognizes. Renaming fixes it,
but only from a terminal: `sessions.rename` (protocol-change/019) is a control
command, and a person on the web page has no way to send it.

## Considered

**A nullable `subtitle` column on `catalogue_sessions`.** This is the shape the
home-page design note proposed. The row is the immutable creation record:
reserving a creation again compares the stored row to the request, and the
display name already lives in a side table for that reason (019). A column
would put a value that changes after creation into the compared row, so a
creation retry after the first prompt would read as a conflict. A side table
keyed by session ID keeps the retry rule untouched.

**Deriving the subtitle when a page asks.** The daemon would read each
session's first user entry on every list. That opens conversation files from a
metadata read, which the catalogue exists to avoid, and a session that is not
resident would need its file opened to be listed.

**Rewriting the subtitle as the conversation moves on.** A subtitle that tracks
the latest prompt or a model summary gives a person a moving label and costs a
model call or a write per turn. The owner asked for a stable label that tells
sessions apart; the display name is the place a person changes it.

**A new control command for the page's rename.** The page is in the daemon's
process and already calls the registry directly for tickets and invitations.
Reusing the registry's rename call, with the page's credential, gives one
authority check for the terminal and the page and adds nothing to the wire.

## Decision

**Accepted.**

*Wire.* Session metadata gains one optional member, `subtitle`, a string of at
most 60 characters. A session with none omits it. A client that does not know
the member reads the rest of the row as before, and a client that knows it
treats a missing member, `null`, a value that is not a string, and a string that
is empty or over the bound all as no subtitle, so a display aid never fails a
listing. No command changes and the control protocol version stays 2.

*Storage.* Catalogue version 5 adds `catalogue_session_subtitles`, keyed by
session ID, holding one nonblank string of at most 60 code points. A version 1
to 4 catalogue gains the table in the same transaction that moves its version.
The subtitle and the catalogue revision commit together, and deleting a session
deletes its subtitle.

*Writing it.* The daemon derives the subtitle from the session's first
accepted human prompt on the main strand and never writes it again. The session's
hub reports the prompt's first text block, as typed and before any skill
expansion, from the two places it accepts a prompt: a prompt the runtime
admits at once, and a held prompt or steer that it submits when the strand
goes idle. It reports once and without waiting. The registry applies the report
in its own turn, so the write is ordered with every other catalogue change, and
the catalogue keeps the first subtitle it is given. A message with no text, or a
prompt that reduces to nothing, writes nothing and the next prompt may still
seed it. Existing sessions keep no subtitle and draw the created age as before.

The derivation takes the first nonblank line, collapses each run of whitespace to
one space, removes controls and the zero-width and direction-changing code points
that `session_view/text_hygiene` replaces, and cuts to 60 characters. A line that
is too long is cut at the last word that fits and ends in an ellipsis that counts
toward the limit. One word longer than the limit is cut where it reaches it. A
cut never splits a character drawn as one.

*Trust.* The subtitle is a person's own words and is the one catalogue field
derived from a prompt, so it is handled as model-adjacent text. It reaches the
page only as a text node, never as an attribute, a class, a key or a title, and
the reduction above removes the characters that would reorder the words around
it.

*Renaming from the page.* The page's rename is the registry's existing
owner-checked rename, called with the credential the page was admitted under.
The page sends one value, the new name. The daemon re-derives everything else at
the moment of the click: the page must still be open, the credential must still
authenticate, its principal must be the daemon's owner, the session is the
page's own (or, on the home, the one the row's handler names, which the daemon
validates as a canonical identity and the catalogue must hold), and the registry
checks the owner and the daemon epoch again before it writes. A member operator's
page does not draw the control and its socket does not admit the event. The call
runs in a task off the page's runtime, as resuming a session does. The name is
judged by the rule 019 states (1 to 256 bytes, nonblank, no control characters)
and also refuses zero-width and direction-changing characters, as invitee names
do. That check now lives in `catalogue.rename`, so the terminal's rename is held
to it too.

## Cost

One more catalogue version, one more table, and a migration for catalogues at
versions 1 to 4. One member added to a frame every client already decodes. A
`Registration` gains a field, which touches every place that builds one, and the
terminal's `Session` gains the same field, which touches its fixtures.

The invisible-character set includes U+200D, so a ZWJ emoji sequence in a subtitle draws as separate glyphs and a display name containing one is refused, the same policy as `session_view/text_hygiene`.

A rename that used to succeed with a zero-width or direction-changing character
in the name now fails, and names already stored with one still read. A session
whose first prompt is an image alone is subtitled by the next prompt with text.
The hub's report is a cast, so a catalogue write that fails (the session was
deleted first, or the database refused it) leaves the session without a subtitle
and nobody is told. That is the same state every existing session is in, and each
page draws it.

The page's rename adds an admitted event path for an owner's page, which the
socket pins beside the invitation control's, and a second one on the home. A
member's page and an observer's admit neither. No existing admitted path moves.
