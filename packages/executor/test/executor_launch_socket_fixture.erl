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
    confirmation_worker/2,
    adoption_gate/2,
    cancel_adoption_gate/1,
    continue_adoption_gate/1,
    adoption_clock/2,
    release_adoption_gate/1,
    adoption_witness/1,
    peer_closed/1,
    kill_channel_owner_and_join_leaves/1
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


%% Pin this bounded schedule to one scheduler. The channel runs at max
%% priority while the managed run remains normal. Its injected clock queues
%% Stop before startup; cancellation suspends the exact linked run process.
%% With the historical relay, the leaves process already-queued Stop messages
%% before adoption. With Witnessed, Ready may already have admitted activation. No timing sleep controls the order.
%% The owning channel releases the scheduler block on its close callback;
%% OTP also releases it if that channel itself dies.
adoption_gate(Fault, Ready) ->
    Gate = ets:new(launch_adoption_gate, [public, set]),
    true = ets:insert(Gate, [{fault, Fault}, {ready, Ready}, {calls, 0}]),
    Gate.

adoption_clock(Gate, Now) ->
    Count = ets:update_counter(Gate, calls, 1),
    case Count of
        5 ->
            Leaves = paused_channel_leaves(self()),
            2 = length(Leaves),
            {subject, _Pid, Ref} = channel_commands(Leaves),
            erlang:system_flag(multi_scheduling, block),
            Previous = process_flag(priority, max),
            put({adoption_priority, Gate}, Previous),
            [{fault, Fault}] = ets:lookup(Gate, fault),
            case Fault of
                close_before_adoption -> ok;
                lose_leaf_before_adoption -> exit(hd(Leaves), kill)
            end,
            self() ! {Ref, {stop, none}},
            true = ets:insert(Gate, {witness, Leaves}),
            Now;
        _ -> Now
    end.

%% The channel's only PID link is the exact original managed run. It is the
%% historical relay or the current witnessed scope; neither can consume its
%% queued cancellation while this max-priority channel controls the scheduler.
cancel_adoption_gate(Gate) ->
    {links, Links} = process_info(self(), links),
    [Relay] = [Pid || Pid <- Links, is_pid(Pid)],
    true = erlang:suspend_process(Relay),
    true = ets:insert(Gate, [{relay, Relay}, {owner, self()}]),
    [{ready, {subject, Test, Ref}}] = ets:lookup(Gate, ready),
    Test ! {Ref, nil},
    receive {Gate, continue} -> ok after 1000 -> ok end,
    true = erlang:resume_process(Relay),
    true = ets:delete(Gate, relay),
    nil.

%% A system roundtrip follows all earlier stop messages in each leaf mailbox.
%% The historical relay cannot adopt until these queued stops have landed.
%% Witnessed may already have admitted the reader's accept, which blocks OTP
%% system traffic; its scope monitor already owns that leaf, so skip that wait.
continue_adoption_gate(Gate) ->
    [{witness, Leaves}] = ets:lookup(Gate, witness),
    lists:foreach(fun(Pid) ->
        case process_info(Pid, current_stacktrace) of
            {current_stacktrace, Frames} ->
                case lists:any(fun
                    ({codemode_ffi, accept_unix, _, _}) -> true;
                    ({prim_inet, accept0, _, _}) -> true;
                    (_) -> false
                end, Frames) of
                    true -> ok;
                    false -> try sys:get_state(Pid, 1000) catch _:_ -> nil end
                end;
            undefined -> ok
        end
    end, Leaves),
    [{owner, Owner}] = ets:lookup(Gate, owner),
    Owner ! {Gate, continue},
    nil.

%% These are only this channel's two paused leaves, authenticated by their
%% proc_lib parent and exact reader/writer state constructors. There is no
%% global choice of an unrelated process and no modified production state.
paused_channel_leaves(Owner) ->
    lists:filter(fun(Pid) ->
        case process_info(Pid, dictionary) of
            {dictionary, Dictionary} ->
                case proplists:get_value('$ancestors', Dictionary) of
                    [Owner | _] ->
                        case proc_lib:translate_initial_call(Pid) of
                            {'weft@state_machine', _, _} -> channel_leaf(Pid);
                            _ -> false
                        end;
                    _ -> false
                end;
            _ -> false
        end
    end, processes()).

channel_leaf(Pid) ->
    try sys:get_state(Pid, 1000) of
        {read_accepting, Reader} when element(1, Reader) =:= channel_reader -> true;
        {nil, Writer} when element(1, Writer) =:= channel_writer -> true;
        _ -> false
    catch _:_ -> false end.

channel_commands([Leaf | _]) ->
    {_Phase, State} = sys:get_state(Leaf, 1000),
    case element(1, State) of
        channel_reader -> element(7, State);
        channel_writer -> element(4, State)
    end.

release_adoption_gate(Gate) ->
    case erase({adoption_priority, Gate}) of
        undefined -> nil;
        Previous ->
            case ets:lookup(Gate, relay) of
                [{relay, Relay}] -> try erlang:resume_process(Relay) catch _:_ -> nil end;
                [] -> ok
            end,
            process_flag(priority, Previous),
            erlang:system_flag(multi_scheduling, unblock),
            nil
    end.

adoption_witness(Gate) ->
    case ets:lookup(Gate, witness) of
        [{witness, Leaves}] ->
            case lists:all(fun(Pid) -> not is_process_alive(Pid) end, Leaves) of
                true -> {ok, nil};
                false -> {error, nil}
            end;
        _ -> {error, nil}
    end.

peer_closed(Socket) ->
    case gen_tcp:recv(Socket, 0, 1000) of
        {error, closed} -> {ok, nil};
        _ -> {error, nil}
    end.


%% The two leaf actors have no descendants. Observe their original monitors
%% before killing the channel owner; the relay and scope must cancel them
%% without any further channel message handler being available.
kill_channel_owner_and_join_leaves({owner, {subject, Owner, _Ref}}) ->
    Leaves = [Pid || Pid <- processes(),
        case process_info(Pid, dictionary) of
            {dictionary, Dictionary} ->
                case {proplists:get_value('$ancestors', Dictionary),
                      proc_lib:translate_initial_call(Pid)} of
                    {[Owner | _], {'weft@state_machine', _, _}} -> true;
                    _ -> false
                end;
            _ -> false
        end],
    2 = length(Leaves),
    {links, Links} = process_info(Owner, links),
    [Scope] = [Pid || Pid <- Links, is_pid(Pid)],
    OriginalChildren = lists:usort([Scope | Leaves]),
    %% No additional idle cancellation signal may outlive this owner.
    DirectChildren = [Pid || Pid <- processes(),
        case process_info(Pid, dictionary) of
            {dictionary, Dictionary} ->
                case proplists:get_value('$ancestors', Dictionary) of
                    [Owner | _] -> true;
                    _ -> false
                end;
            _ -> false
        end],
    true = lists:sort(DirectChildren) =:= lists:sort(OriginalChildren),
    Watches = [{Pid, monitor(process, Pid)} || Pid <- OriginalChildren],
    exit(Owner, kill),
    Result = lists:all(fun({Pid, Watch}) ->
        receive
            {'DOWN', Watch, process, Pid, Reason} ->
                Pid =/= Scope orelse Reason =:= normal
        after 1500 -> false end
    end, Watches),
    lists:foreach(fun({_Pid, Watch}) -> demonitor(Watch, [flush]) end, Watches),
    case Result of true -> {ok, nil}; false -> {error, nil} end.
