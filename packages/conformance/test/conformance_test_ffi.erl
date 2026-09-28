%% Test-only Erlang shims for the conformance suite (never shipped in
%% src). Used by the e2e tests to derive never-repeating entropy seeds
%% and by the soak suites to read their opt-in variables; see
%% test/support/internal/ffi_shell.gleam.
-module(conformance_test_ffi).

-export([unique_integer/0, get_env/1]).

%% erlang:unique_integer/1 — strictly increasing, never repeats within a
%% VM lifetime; the entropy source the e2e wiring injects (spec-gaps
%% WP-E item 6: id-generator seeds must never repeat in-session).
unique_integer() ->
    erlang:unique_integer([positive, monotonic]).

%% os:getenv/1 — the soak suite is opt-in, and an environment variable is
%% how a developer or a nightly job says so.
get_env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
