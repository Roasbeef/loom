# protocol-change/097 — reconnect failed session pages

**Status**: ACCEPTED 2026-10-21 · **Affects**: protocol 051's page close
semantics · **Raised by**: recurring disconnected pages during active work ·
**Implemented**: client + web_view.

## Problem

`ConnectionFailed` closed the browser socket with 1000, which Lustre treats
as final. A page-to-gateway request that exceeded six seconds therefore left
a still-authorized page disconnected until reload. A lane that closed itself
after a deadline or protocol failure was worse: its relay detached without
telling the browser socket to close, so no browser reconnect was attempted.

Not replaying an unacknowledged command is necessary: it may have committed.
That uncertainty does not prevent establishing a new connection and reading
the current session state.

## Proposal

```text
ending.close(ConnectionFailed): Final -> Retry
active relay receives Shut: detach -> report ConnectionFailed and detach
```

A failed request still retires its relay. The browser's existing backoff
opens a new authenticated page socket, component and session lane. The lane
starts with a subscription and snapshot, with no commands copied from the
retired lane. Sent commands remain of unknown outcome; commands waiting in
the retired relay are discarded. No automatic command retry is introduced.

The relay rechecks authorization before reporting a recoverable failure.
An expired page, revoked credential or changed role remains final. Component
teardown uses its monitor and detaches without asking a departed browser to
reconnect. A stopped session remains a final ending.

`daemon.page_request_failed` records the session and connection identifiers,
request byte count, elapsed request time, gateway reason and diagnosed ending.
The gateway distinguishes no reply from a dead process. The record contains
no frame contents. `daemon.page_connection_ended` records the boundary that
ended the relay: request failure, lane close, gateway close or gateway death.
Page cookies, keys, nonces and credentials are absent from both records.

## Impact

The relay, upgrade diagnostics and gateway request wrapper change in client.
The close classification and session-page advice change in web_view. No wire
fields, accepted browser events, credential lifetimes or storage formats
change. The earlier protocol 051 table and close-code discussion are superseded
only for `ConnectionFailed` and the lane's explicit close.

The regression holds delivery after a real prompt commits, waits for the real
request timeout, reconnects with a fresh relay, and verifies one durable prompt
and no replay of the command queued behind it. A component regression verifies
that a new lane issues a subscription rather than the unacknowledged prompt.
The diagnostic assertion checks the timeout classification and payload omission.

## Decision

**Accepted.** The owner requested reconnect recovery, failure logging and a
no-replay regression. Retrying the failed request was rejected because its
outcome is unknown; increasing its deadline alone would leave the same final
failure at a later time. Reuse Lustre's existing reconnect and fresh page
admission rather than introduce a second retry loop.
