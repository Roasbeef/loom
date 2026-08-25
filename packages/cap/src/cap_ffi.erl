%% FFI shim for the cap prelude.
%%
%% Confinement (spec §0.2): the only Erlang the cap package reaches lives
%% here, and every Gleam @external that binds it sits in a
%% `cap/internal/ffi_*.gleam` module. The one capability provided is a
%% process-global, set-once slot for the capability Channel — the boot
%% module installs it before running the program, and every cap function
%% (in any task worker or actor process) reads it back. `persistent_term`
%% is the right primitive: VM-global, readable from every process at
%% local-memory speed, and written once per execution.

-module(cap_ffi).
-export([put_channel/1, get_channel/0]).

-define(KEY, {cap, channel}).

%% Store the channel term. Overwrites any prior value (a kept-alive
%% satellite re-installs with each invocation's fresh token).
put_channel(Channel) ->
    persistent_term:put(?KEY, Channel),
    nil.

%% Read the channel term, converting the not-installed case into a Gleam
%% `Result` rather than a `badarg` crash.
get_channel() ->
    case persistent_term:get(?KEY, undefined) of
        undefined -> {error, nil};
        Channel -> {ok, Channel}
    end.
