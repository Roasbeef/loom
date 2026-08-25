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
-export([
    put_channel/1,
    get_channel/0,
    getenv/1,
    read_file/1,
    connect_unix/1,
    socket_recv/1,
    socket_send/2,
    socket_close/1
]).

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

%% -- production transport (J3) -------------------------------------------
%%
%% The satellite's whole link to the host: one AF_UNIX stream socket, plus
%% the environment/file reads that locate it and the cap token. Each shim
%% converts to Gleam conventions at the boundary — {ok, X} | {error, nil},
%% exceptions caught — so cap/runtime stays total.

%% os:getenv/1 returns false | string(); normalize to {ok, Binary}.
getenv(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% file:read_file/1 for the private cap-token file. Any error (missing,
%% unreadable) is normalized to {error, nil}.
read_file(Path) ->
    case file:read_file(unicode:characters_to_list(Path)) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.

%% gen_tcp:connect/3 to a {local, Path} AF_UNIX address. Binary frames,
%% passive mode (the Gleam deframer owns frame boundaries via recv), raw
%% packets. Not AF_INET, and no distribution: the one link the jail allows.
connect_unix(Path) ->
    try
        Options = [binary, {active, false}, {packet, raw}],
        case gen_tcp:connect({local, unicode:characters_to_list(Path)}, 0, Options) of
            {ok, Socket} -> {ok, Socket};
            {error, _} -> {error, nil}
        end
    catch
        _:_ -> {error, nil}
    end.

%% gen_tcp:recv/2 with length 0: block until some bytes arrive on the
%% passive socket and return whatever is available. A closed or faulted
%% socket becomes {error, nil}, which the reader treats as end of stream.
socket_recv(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} -> {ok, Data};
        {error, _} -> {error, nil}
    end.

%% gen_tcp:send/2 — write bytes to the channel. A closed socket becomes
%% {error, nil} so the channel actor settles in-band instead of crashing.
socket_send(Socket, Bytes) ->
    case gen_tcp:send(Socket, Bytes) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

%% gen_tcp:close/1 — idempotent from the caller's view.
socket_close(Socket) ->
    _ = gen_tcp:close(Socket),
    nil.
