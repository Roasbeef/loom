# Request-scoped live streams

Status: implementation of the approved developer-experience fixes.

## Problem

An operation contains multiple provider requests: answers before and after tool
batches, retries, and deferred polls. Operation identity alone concatenates
separate answers and leaves thinking and tool-argument indicators on screen.
A snapshot may arrive after a later request has already begun streaming.

## Decision

`stream_delta` gains an optional `generation` string. The host derives it from
the durable request kind, step or task ID, attempt, and poll or summary index.
Every new host delta supplies it. A terminal drops all older fragment kinds
when a new request starts on that strand. Missing identity remains accepted
for historical recordings.

The `end` kind carries the same operation and generation without a text or
argument payload. The existing provider observer emits it on either terminal
outcome. It retires only that request's fragments; it cannot retire a newer
request. The terminal keeps an empty identity marker so a late preview cannot
resurrect an earlier request. A different identity alone does not establish
preview freshness. An exact captured `strand.last_result` retires fragments
even when a relay failure bypassed its presentation observer. This register is
latest-wins; absence or an unrelated result is not retirement evidence.
Previews carry generation and content kind, are
owned by their observer, and are projected directly from each cut rather than
stored as delta history. Releasing the current observer clears its sample.

The terminal marker is an ephemeral presentation event, not evidence of durable
settlement or completed effect cleanup. Coherent cuts remain authoritative.

## Alternatives and cost

Clearing on any new entry loses a newer answer when an older snapshot arrives.
Clearing on operation completion misses every tool round and retry. A second
client-generated counter cannot identify requests across a reconnect.

The change adds a bounded identifier to each delta and one terminal frame per
request. Historical recordings retain their previous operation-only behavior.
