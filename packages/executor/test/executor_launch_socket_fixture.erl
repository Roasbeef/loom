%% Test-only Erlang shims for the codemode package: a client end of the cap
%% socket (so the launcher's real listener can be driven from a test without
%% a jailed node), plus the PATH lookup the feature-detected end-to-end
%% suite uses to find the toolchain. Production code never reaches any of
%% this.
-module(executor_launch_socket_fixture).

-export([
    connect_unix/1,
    peer_send/2,
    peer_recv/2,
    peer_close/1,
    find_executable/1,
    now_ms/0,
    get_env/1,
    closer_waiting/1
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
    try gen_tcp:close(Socket) of
        _ -> nil
    catch
        _:_ -> nil
    end.

%% os:find_executable/1 — feature detection for gleam and erl.
find_executable(Name) ->
    case os:find_executable(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

%% erlang:system_time/1 — the end-to-end suite runs against real wall
%% deadlines (a jailed node dies at one), so it needs the real clock.
now_ms() ->
    erlang:system_time(millisecond).

%% os:getenv/1 — the launcher suite selects a short, non-/tmp scratch
%% directory when a checkout is too deep for a Unix socket path.
get_env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.


%% A waiting close caller has already sent its original Stop(Some) request.
%% Inspect only that caller's bounded stack, never the opaque channel state.
closer_waiting(Pid) ->
    case process_info(Pid, [status, current_stacktrace]) of
        [{status, waiting}, {current_stacktrace, Frames}] ->
            lists:any(fun
                ({'executor@remote@launch_channel', _, _, _}) -> true;
                (_) -> false
            end, Frames);
        _ -> false
    end.
