%% Test-only Erlang shims for the broker suite (never shipped in src).
%% Used by the feature-detected integration test to find and drive the
%% Go toolchain; see test/broker/support/shell.gleam.
-module(broker_test_ffi).

-export([find_executable/1, os_cmd/1]).

%% os:find_executable/1 — PATH lookup for feature detection.
find_executable(Name) ->
    case os:find_executable(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

%% os:cmd/1 — run a shell command, capturing stdout. Test-only; the
%% production spawn path goes through erlang ports in broker_ffi.
os_cmd(Command) ->
    unicode:characters_to_binary(os:cmd(unicode:characters_to_list(Command))).
