%% Test-only Erlang shim for the conformance suite (never shipped in
%% src). Used by the e2e tests to derive never-repeating entropy seeds;
%% see test/support/internal/ffi_shell.gleam.
-module(conformance_test_ffi).

-export([unique_integer/0]).

%% erlang:unique_integer/1 — strictly increasing, never repeats within a
%% VM lifetime; the entropy source the e2e wiring injects (spec-gaps
%% WP-E item 6: id-generator seeds must never repeat in-session).
unique_integer() ->
    erlang:unique_integer([positive, monotonic]).
