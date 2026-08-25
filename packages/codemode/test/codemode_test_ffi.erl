%% Test-only Erlang shims for the codemode package: a client end of the cap
%% socket (so the launcher's real listener can be driven from a test without
%% a jailed node), plus the shell lookups the feature-detected end-to-end
%% suite uses to find and build the Go helper. Production code never reaches
%% any of this.
-module(codemode_test_ffi).

-export([
    connect_unix/1,
    peer_send/2,
    peer_recv/2,
    peer_close/1,
    find_executable/1,
    os_cmd/1,
    now_ms/0
]).

%% The same connect the real satellite makes (cap_ffi:connect_unix/1):
%% {local, Path}, binary, passive, raw packets.
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

peer_send(Socket, Bytes) ->
    case gen_tcp:send(Socket, Bytes) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

peer_recv(Socket, TimeoutMs) ->
    case gen_tcp:recv(Socket, 0, TimeoutMs) of
        {ok, Data} -> {ok, Data};
        {error, _} -> {error, nil}
    end.

peer_close(Socket) ->
    _ = (catch gen_tcp:close(Socket)),
    nil.

%% os:find_executable/1 — feature detection for the Go toolchain.
find_executable(Name) ->
    case os:find_executable(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

%% os:cmd/1 — test-only, for driving `go build` and locating tools.
os_cmd(Command) ->
    unicode:characters_to_binary(os:cmd(unicode:characters_to_list(Command))).

%% erlang:system_time/1 — the end-to-end suite runs against real wall
%% deadlines (a jailed node dies at one), so it needs the real clock.
now_ms() ->
    erlang:system_time(millisecond).
