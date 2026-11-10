# json_codec

## Purpose

Platform-selected JSON at harness byte boundaries. The ordered value type and
reference implementation remain in pure core; Erlang uses OTP callbacks and
JavaScript uses the reference Gleam bodies. Typed schemas belong to callers.

## Key Types

- `json_codec.Codec` holds parse and serialization callbacks without mutable
  selection or authority. `portable()` explicitly selects core; `platform()`
  selects the target binding. Default helpers avoid a record per document.
- `core/json.JsonValue` and `core/corruption.CorruptionReport` retain their
  existing meaning. No alternate native value or error vocabulary escapes.

## Relationships

- **Depends on**: core for types, reference operations and the depth limit;
  gleam_stdlib otherwise. qcheck and gleeunit are test dependencies.
- **Depended on by**: storage for persisted payload bytes; provider for request,
  response and SSE JSON; client for command decoding and existing encoding
  calls. The pure core/machine/prompt graph does not depend on this package.
- **FFI**: `json_codec/internal/ffi_json` binds `json_codec_ffi.erl`, which calls
  OTP `json:decode/3` with fixed native callbacks. ADR-023
  records this scoped exception. It receives data, never arbitrary callbacks.

## Traffic

No owned processes, messages, I/O, commits or register access. Callers pass text
or `JsonValue` synchronously; typed decoding and authority remain with them.

## Invariants

- Native success preserves order, duplicate refusal, scalar wrapping, UTF-8
  and depth bounds. `json.max_depth` is passed in rather than duplicated.
- Refusals are complete reference reports. No partial native value is exposed.
- Zero-valued native floats delegate to the reference parser because OTP can
  erase the sign of an exponent-only negative zero before its callback.
- Encoding uses the reference implementation on both targets, preserving exact
  float spelling, ordered/duplicate hand-built keys and lowercase control escapes.
- JavaScript uses the pure bodies. No external or dependency is added to core.
- Differential tests and native-call witnesses must catch missing checks and
  an implementation that always falls back.

## Deep Docs

- [README](README.md): components, target selection, parsing and encoding flows,
  ownership and verification.
- [ADR-023](../../docs/adr/023-platform-json-keeps-the-portable-contract.md):
  alternatives, costs and adoption gates.
- [Root CLAUDE.md](../../CLAUDE.md): repository rules and documentation map.
