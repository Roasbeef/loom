# Jevelin discovery fixture

`jev.json` is the complete `tools/list` result captured from the installed
self-contained Jevelin MCP server on October 1, 2026. Its source checkout was
at `307b7e4d5c5720ebd070cc0bd2868cdf66f0cada`; the launcher selected
`shipment.VfXBrd`. Capture initialized a stdio client with protocol version
`2025-06-18`, sent the initialized notification, listed the four tools, and
closed stdin. The process exited zero with no pending frames or diagnostics.

Discovery used a dummy credential and made no upstream HTTP request. The
fixture contains tool descriptions and schemas, with no credential or local
filesystem path. It preserves the real heterogeneous content alternatives,
nullable optional fields, and Choice/Score/Noul discriminated records.

The codegen tests render these schemas, and the client integration test
executes the complete mixed-batch program in `docs/jev-mcp.md` against them.
That test records the request before returning deterministic structured
answers; compilation refusals must produce no recorded request.
