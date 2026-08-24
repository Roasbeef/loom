%% Test-only Erlang shims for the conformance suite (never shipped in
%% src). Used by the feature-detected e2e tests to find and drive the Go
%% toolchain and to derive never-repeating entropy seeds; see
%% test/support/internal/ffi_shell.gleam.
-module(conformance_test_ffi).

-export([find_executable/1, os_cmd/1, unique_integer/0, get_env/1]).

%% os:find_executable/1 — PATH lookup for feature detection.
find_executable(Name) ->
    case os:find_executable(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

%% os:cmd/1 — run a shell command, capturing stdout. Test-only; the
%% production execution path is the broker's jailed helper.
os_cmd(Command) ->
    unicode:characters_to_binary(os:cmd(unicode:characters_to_list(Command))).

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
