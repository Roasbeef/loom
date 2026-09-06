# ADR-009 — Record terminal attempts before replaying adoption

**Status**: accepted · **Date**: 2026-09-05 · **Supersedes**: nothing · **Relates to**: protocol-change/015

## The question

The terminal keeps its current conversation while it validates a replacement.
Both sockets can issue request 1 and capture 1:1. The old recording format
records untagged incoming frames, so it cannot say which connection produced
a cut or whether the terminal adopted that connection.

## Decision

**New recordings use local format 2 and terminal-local attempt identities.**
A recording identifies each attempt's expected session, epoch and incarnation;
issued requests; raw incoming frames; and adoption or closure. Adoption is
recorded only after the terminal commits the validated replacement.

Request markers contain identity, command kind and bounded selectors: snapshot
identity/index, catch-up cursor, or at most eight exact escalation identities.
They contain no prompt body, credentials, URL, headers, configuration values or
approval grants. Incoming frames retain the server's existing encoding.

Replay keeps at most one current attempt and one candidate. It validates the
same transfer bounds and requires an issued request before its response. Only
an adoption marker replaces the visible session. Failed or closed candidates
release their buffers; late frames from a replaced attempt cannot repaint the
new view. Mixed historical and version-2 recordings are rejected.

## Why

Inferring connection identity from request or snapshot identifiers was rejected
because these identifiers are local to each connection. Synthesizing legacy
snapshot events was rejected because it would test a presentation adapter
instead of the live v2 decoder. A separate replay socket actor would introduce
an effect and ownership problem into an otherwise local replay.

## Consequences

The recorder, terminal channel, attachment boundary and virtual backend share
typed attempt events. Replay opens no connection, starts no daemon and sends
no mutation. Historical untagged recordings remain readable through their
replay-only decoder. This is a local recording format change, not a change to
the gateway protocol. Tests must cover overlapping identities, rejected
candidates, adoption ordering, missing credits and mixed formats.
