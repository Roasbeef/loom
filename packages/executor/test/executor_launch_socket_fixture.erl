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
    closer_waiting/1,
    retiring_adapter/2,
    native_control_count/1,
    journal_owner/1,
    confirmation_worker/2
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


%% This bounded probe couples only these fixtures to the private service Row.
%% sys returns weft's user state. Exact key/record/monitor validation prevents
%% killing a relay, helper, foreign actor, or a reconstructed historical owner.
retiring_adapter(Service, Key) when is_pid(Service), node(Service) =:= node() ->
    try sys:get_state(Service, 1000) of
        {state, _Config, _Generation, _Tickets, Rows, _Covered, _Subject,
         _Sequence, _Gate, _Close} when is_map(Rows) ->
            case maps:find(Key, Rows) of
                {ok, {row, _Digest, _Deadline,
                      {running, {subject, Pid, _Ref}, Pid}, _Stdin, _Bytes,
                      {awaiting_native, _Observer}, running_control,
                      {some, Monitor}, _ControlLost, _Confirmation}}
                  when is_pid(Pid), node(Pid) =:= node(), is_reference(Monitor) ->
                    case is_process_alive(Pid) of
                        true -> {ok, Pid};
                        false -> {error, nil}
                    end;
                _ -> {error, nil}
            end;
        _ -> {error, nil}
    catch _:_ -> {error, nil} end;
retiring_adapter(_, _) -> {error, nil}.

native_control_count(Service) when is_pid(Service), node(Service) =:= node() ->
    try sys:get_state(Service, 1000) of
        {state, _Config, _Generation, _Tickets, Rows, _Covered, _Subject,
         _Sequence, _Gate, _Close} when is_map(Rows) -> {ok, map_size(Rows)};
        _ -> {error, nil}
    catch _:_ -> {error, nil} end;
native_control_count(_) -> {error, nil}.


%% Identity-only projection of this fixture's original opened Journal term.
journal_owner({journal, {subject, Pid, _Ref}, _Scope})
  when is_pid(Pid), node(Pid) =:= node() -> {ok, Pid};
journal_owner(_) -> {error, nil}.

%% The original Row keeps its managed relay, which owns the scope and workers.
%% Walk only that bounded ownership chain and require the actual journal wait
%% stack before terminating a worker. No unrelated process is a candidate.
confirmation_worker(Service, Key) when is_pid(Service), node(Service) =:= node() ->
    try sys:get_state(Service, 1000) of
        {state, _Config, _Generation, _Tickets, Rows, _Covered, _Subject,
         _Sequence, _Gate, _Close} when is_map(Rows) ->
            case maps:find(Key, Rows) of
                {ok, {row, _Digest, _Deadline, _Running, _Stdin, _Bytes,
                      {positive_native, _Observer}, _Control, _Monitor, _Lost,
                      {confirming, _Reports, _Cancel, none, _Attempt, Relay}}}
                  when is_pid(Relay), node(Relay) =:= node() ->
                    waiting_worker([Relay], [Service], 4);
                _ -> {error, nil}
            end;
        _ -> {error, nil}
    catch _:_ -> {error, nil} end;
confirmation_worker(_, _) -> {error, nil}.

waiting_worker(_, _, 0) -> {error, nil};
waiting_worker([], _, _) -> {error, nil};
waiting_worker(Pids, Seen, Depth) when length(Pids) =< 32, length(Seen) =< 64 ->
    Candidates = [Pid || Pid <- lists:usort(Pids), is_pid(Pid),
                         node(Pid) =:= node(), not lists:member(Pid, Seen)],
    case lists:dropwhile(fun(Pid) -> not journal_waiting(Pid) end, Candidates) of
        [Worker | _] -> {ok, Worker};
        [] ->
            Next = lists:append([case process_info(Pid, links) of
                {links, Links} -> Links;
                _ -> []
            end || Pid <- Candidates]),
            waiting_worker(Next, Candidates ++ Seen, Depth - 1)
    end;
waiting_worker(_, _, _) -> {error, nil}.

journal_waiting(Pid) ->
    case process_info(Pid, [status, current_stacktrace]) of
        [{status, waiting}, {current_stacktrace, Frames}] ->
            lists:any(fun
                ({'executor@remote@journal', _, _, _}) -> true;
                (_) -> false
            end, Frames);
        _ -> false
    end.
