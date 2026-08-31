# protocol-change/010 - ClientGateway accepts prompt content blocks

**Status**: PROPOSED - **Affects**: Part 1 ClientGateway command vocabulary -
**Raised by**: issue #114 eTUI image drag and drop

## Problem

The durable message schema already supports `UserImage(data, mime_type)`, and
both provider adapters already translate that block into their upstream image
shape. ClientGateway cannot admit one. Its `prompt`, `steer`, and `follow_up`
commands carry only `{strand, text}`, so a native client has no frozen wire
form for an image selected by the operator.

This gap is visible in a terminal client. Terminals report a dropped file as
bracketed paste containing its local path. The eTUI can identify the file,
read it, validate its type and size, and encode its bytes. It cannot turn those
bytes into a user turn without either losing the image as plain text or
inventing an undocumented command body.

Adding an optional field to `prompt` looks smaller, but it fails badly under
version skew. An older gateway ignores fields it does not know after decoding
the required text. A new client could therefore appear to submit an image
while the old server silently drops it. The wire needs a command an old server
will refuse.

## Proposal

Add one ClientGateway command:

```text
prompt_content {
  strand: string,
  content: [<core codec UserBlock, verbatim>]
}
```

The corresponding in-VM constructor is:

```gleam
PromptContent(strand: String, content: List(message.UserBlock))
```

The command has these laws:

- `content` must be non-empty.
- Every item is decoded by the total `core/codec` user-block decoder. Unknown
  block types, invalid base64, empty MIME types, and fields of the wrong type
  refuse the whole command as `bad_request`.
- The gateway preserves block order and admits exactly one `UserMessage`.
- The existing `prompt {strand, text}` command is unchanged. Text-only clients
  keep their byte-for-byte wire form.
- `steer` and `follow_up` remain text-only in this change. An image submission
  while a strand is live is refused by the client with a local explanation;
  broadening live-operation semantics belongs in a separate proposal.
- An older gateway returns `unknown_command` for `prompt_content`. It never
  reports success after dropping the image.

## Terminal client behavior

The eTUI treats a paste as an image drop only when all of these are true:

1. The paste resolves to exactly one local path after removing terminal quote
   or backslash-space escaping. The path text is never evaluated by a shell.
2. The target is a regular file.
3. Its magic bytes identify PNG, JPEG, GIF, or WebP. The filename extension is
   not trusted as the MIME authority.
4. The encoded file is at most 20 MiB. Oversized files are refused before a
   prompt frame is built.

The composer shows the filename, media type, and byte size as a removable
attachment. The local path is presentation state only. Submission sends a
`UserText` block when the editor is non-empty followed by each `UserImage`
block in drop order. The durable transcript later renders the server-owned
message, not a client-side optimistic copy.

Ordinary pasted paths, unsupported files, and multiple pasted tokens remain
text. A read failure leaves the editor untouched and shows a local error.

## Impact

- `client/protocol` gains one additive command constructor and total decoder.
- `client/gateway` admits the decoded blocks through the same operation path
  as `prompt` instead of constructing a text block itself.
- Golden protocol fixtures cover text-only stability, content-block round
  trip, malformed blocks, an empty list, and old-command refusal behavior.
- `tui_gleam` gains image attachments, bounded file reads, MIME sniffing,
  base64 encoding, and a `prompt_content` encoder.
- Provider and durable entry formats do not change.

## Decision

Pending approval. The alternatives are to add optional images to `prompt`,
which can silently lose data against an older gateway, or to embed a data URL
in text, which changes the model-visible prompt and bypasses the typed image
path the rest of Loom already implements. A separate additive command is the
smallest version-skew-safe extension.
