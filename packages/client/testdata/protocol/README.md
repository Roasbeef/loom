# Golden protocol fixtures

One canonical JSON envelope per file: `cmd_*.json` are client-to-server
commands, `event_*.json` are server-to-client events. The gateway
conformance suite decodes, re-encodes, and compares each one.

These files are the **conformance fixtures for ClientGateway** (WP-L): the
gateway's protocol tests must decode every `cmd_*` fixture
and produce byte-equivalent (modulo key order) encodings of every
`event_*` fixture. Treat any change here as a protocol change.
