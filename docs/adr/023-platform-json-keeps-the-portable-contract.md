# ADR-023: platform JSON keeps the portable contract

**Status**: accepted · **Date**: 2026-11-09 · **Spec ref**: §0.2, Part 1.1

## The question

The November 9 profile identified substantial JSON allocation. An exploratory
OTP callback decoder built the same ordered value with duplicate/depth checks,
while measuring much less valid-input decoding work and allocation. Earlier
comparisons measured successive Loom implementations, not this alternative.
Owning an inspectable value type does not require owning the parser.

## Decision

**Keep the reference codec and types in pure core, and select the implementation
at byte boundaries.** `json_codec.Codec` provides typed callbacks, `portable()`
and `platform()`. Convenience functions use the selected implementation without
constructing a record per document. Erlang selects the OTP decoder through one confined FFI;
JavaScript uses the existing Gleam bodies. No mutable global backend is added.

Native callbacks construct ordered `JsonValue` records directly, reject duplicate
decoded keys, enforce `json.max_depth`, normalize scalar wrappers and reject
trailing content. Native refusals delegate to the reference parser for exact
`CorruptionReport` fields, source positions and context. Encoding uses the
reference implementation on every target, preserving exact bytes by construction.
An experimental OTP encoder improved large escaped text but its compatibility
scan slowed compact object fixtures substantially; it is not selected.

Zero-valued native floats also delegate to the reference parser. OTP normalizes
exponent-only negative zero before its callback and loses the original sign;
recovering it would require a second lexer. The fallback uses the original text.

This is the owner's explicitly authorized JSON exception to the general
no-FFI-for-speed rule. Only `json_codec/internal/ffi_json` declares externals;
core, machine, prompt and the other portable packages keep their current rules.
The callbacks are fixed trusted code over data, never model-supplied code.

## Why

Moving an external into core would break its pure portable boundary. Using
default OTP maps would lose order and duplicate evidence. Keeping only the
handwritten parser would retain the measured cost. A small internal package
avoids making storage and provider depend on the larger host package or each
other; it adds only core and stdlib, without a new third-party library.

## Consequences and adoption gates

Storage payloads, provider request/response/stream JSON and client command
decoding select the new boundary package. Typed schemas, persisted/wire shapes,
freshness checks and authorization stay with their existing owners. Pure callers
keep the reference implementation.

The cost is two implementations, an unchecked native value ABI and a second parse
after native rejection. Complete differential values/refusals, raw byte and
numeric edges, exact encoder bytes, output-binary ownership and semantic mutants
must guard that contract. A native-call witness must reject an implementation
that always falls back. Both Erlang and JavaScript suites must run in CI.

Adoption requires matched decoding and real-path performance, downstream native and
jailed end-to-end gates, and an independent review. The proof report must retain
coverage limits and distinguish parser allocation from retained memory or RSS.

The [fixed replay](../review/platform-json-2026-11-09.md) records the compatibility,
negative-control, ownership and real-storage evidence for adoption.
