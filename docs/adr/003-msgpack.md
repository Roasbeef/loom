# ADR-003 — msgpack for the framing protocol

**Status**: accepted · **Date**: 2026-08-24 · **Spec ref**: Part 1.4, Part 7

## Decision

- **Gleam side**: we write our own msgpack codec in `core`
  (`core/msgpack`), pure Gleam over bit arrays, covering exactly the subset
  the framing protocol uses: nil, bool, int (all widths), float64, str,
  bin, array, map. Decoding is a total decoder returning
  `Result(t, CorruptionReport)`; unknown or truncated input is a decode
  error, never a crash.
- **Go side**: `github.com/vmihailenco/msgpack/v5`, the mainstream
  maintained library.

## Why

There is no mature msgpack package on Hex for Gleam, and the wire boundary
is exactly where our conventions demand total decoders we control. The
needed subset is small — Gleam's bit-array pattern matching
(`<<0xdc, len:size(16), rest:bits>>`) makes the codec a few hundred lines
with property tests, which is cheaper than trusting an unmaintained dep at
a security boundary. On the Go side the opposite holds: vmihailenco/msgpack
is mature, widely deployed, and the helper is already trusted native code.

## Consequences

- Cross-language conformance is tested with golden frames: the Gleam test
  suite and the Go helper's tests share fixture files under `protocol/`
  encoding the same values, and each side asserts byte-exact encode and
  successful decode of the other's output.
- Extensions (timestamps, ext types) are out of scope; adding one requires
  updating this ADR and the golden fixtures.
