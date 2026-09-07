%% BEAM-level memory census of a running loomd, taken from a separate node.
%%
%% This module is diagnostic tooling, not part of the server. It never runs
%% inside the daemon: every measurement is an rpc:call of a standard OTP MFA,
%% so the daemon needs no probe code loaded and no diagnostics endpoint. See
%% docs/design-notes/daemon-memory.md for what the numbers were used to decide.
-module(mem_report).
-export([main/1]).

main([NodeStr, Label, Mode]) ->
    Node = list_to_atom(NodeStr),
    pong = net_adm:ping(Node),
    collect(Node, Mode),
    io:format("### cut: ~s  (~s)~n", [Label, NodeStr]),
    memory(Node),
    carriers(Node),
    ets(Node),
    processes(Node),
    io:format("~n"),
    erlang:halt(0, [{flush, true}]).

%% A full sweep of every process, so the next census reports what is reachable
%% rather than what the collector has not yet reached.
collect(Node, "collect") ->
    Pids = rpc:call(Node, erlang, processes, []),
    [rpc:call(Node, erlang, garbage_collect, [Pid]) || Pid <- Pids],
    ok;
collect(_Node, _Mode) ->
    ok.

%% erlang:memory/0 is the VM's own account of what it believes is live.
memory(Node) ->
    Mem = rpc:call(Node, erlang, memory, []),
    io:format("erlang:memory/0~n"),
    [io:format("  ~-20s ~12.3f MiB~n", [atom_to_list(K), V / 1048576])
     || {K, V} <- Mem],
    ok.

%% Carriers are what the allocators hold from the OS. A total far above
%% erlang:memory/0 is the signature of retained-but-unused address space.
carriers(Node) ->
    case rpc:call(Node, instrument, carriers, []) of
        {ok, {_Sched, _Cnt, Carriers}} ->
            Totals = lists:foldl(fun carrier/2, #{}, Carriers),
            io:format("instrument:carriers/0 (allocator: carrier bytes / in use)~n"),
            Sorted = lists:reverse(lists:keysort(2, [{A, S, U} || {A, {S, U}} <- maps:to_list(Totals)])),
            [io:format("  ~-20s ~12.3f MiB carrier ~12.3f MiB used~n",
                       [atom_to_list(A), S / 1048576, U / 1048576])
             || {A, S, U} <- Sorted],
            io:format("  ~-20s ~12.3f MiB carrier ~12.3f MiB used~n",
                      [ "TOTAL"
                      , lists:sum([S || {_, S, _} <- Sorted]) / 1048576
                      , lists:sum([U || {_, _, U} <- Sorted]) / 1048576]);
        Other ->
            io:format("instrument:carriers/0 unavailable: ~p~n", [Other])
    end,
    ok.

carrier({Alloc, _Origin, Size, Blocks, _Hist}, Acc) ->
    Used = lists:sum([B || {_Type, B, _} <- normalise(Blocks)]),
    maps:update_with(Alloc, fun({S, U}) -> {S + Size, U + Used} end, {Size, Used}, Acc);
carrier(_, Acc) ->
    Acc.

normalise(Blocks) when is_list(Blocks) -> Blocks;
normalise(_) -> [].

%% ETS holds session state outside process heaps, so it is counted separately.
ets(Node) ->
    Tables = rpc:call(Node, ets, all, []),
    Sized = [{rpc:call(Node, ets, info, [T, memory]),
              rpc:call(Node, ets, info, [T, name]),
              rpc:call(Node, ets, info, [T, size])} || T <- Tables],
    Words = [{W, N, C} || {W, N, C} <- Sized, is_integer(W)],
    Total = lists:sum([W || {W, _, _} <- Words]) * erlang:system_info(wordsize),
    io:format("ets: ~p tables, ~.3f MiB total~n", [length(Tables), Total / 1048576]),
    Top = lists:sublist(lists:reverse(lists:keysort(1, Words)), 8),
    [io:format("  ~8.3f MiB ~p rows  ~p~n",
               [W * erlang:system_info(wordsize) / 1048576, C, N])
     || {W, N, C} <- Top],
    ok.

%% The top heaps name a process if one term is the owner of the growth, and
%% the grouping names a *shape* of process when the cost is spread over many.
processes(Node) ->
    Pids = rpc:call(Node, erlang, processes, []),
    Rows = lists:filtermap(fun(Pid) -> row(Node, Pid) end, Pids),
    Total = lists:sum([M || {M, _, _, _, _, _} <- Rows]),
    io:format("processes: ~p live, ~.3f MiB of heaps~n", [length(Rows), Total / 1048576]),

    Grouped = lists:foldl(fun({M, _, _, _, _, Who}, Acc) ->
                                  maps:update_with(Who, fun({C, S}) -> {C + 1, S + M} end,
                                                   {1, M}, Acc)
                          end, #{}, Rows),
    ByCost = lists:reverse(lists:keysort(2, [{W, S, C} || {W, {C, S}} <- maps:to_list(Grouped)])),
    io:format("  grouped by initial call, heaviest first~n"),
    [io:format("    ~10.3f MiB over ~p process(es)  ~p~n", [S / 1048576, C, W])
     || {W, S, C} <- lists:sublist(ByCost, 12)],

    Sorted = lists:sublist(lists:reverse(lists:keysort(1, Rows)), 20),
    io:format("  top 20 individual processes~n"),
    [io:format("    ~10.3f MiB heap=~p min_heap=~p mq=~p bin=~.3f MiB ~p~n",
               [M / 1048576, H, MH, Q, B / 1048576, Who])
     || {M, H, MH, Q, B, Who} <- Sorted],
    ok.

row(Node, Pid) ->
    Info = rpc:call(Node, erlang, process_info, [Pid, [memory, heap_size, min_heap_size,
                                                       message_queue_len, binary,
                                                       registered_name, dictionary,
                                                       initial_call]]),
    case Info of
        undefined -> false;
        {badrpc, _} -> false;
        List ->
            Get = fun(K, D) -> case lists:keyfind(K, 1, List) of {K, V} -> V; _ -> D end end,
            Bin = lists:sum([S || {_, S, _} <- Get(binary, [])]),
            {true, {Get(memory, 0), Get(heap_size, 0), Get(min_heap_size, 0),
                    Get(message_queue_len, 0), Bin, who(Get)}}
    end.

%% proc_lib records the real entry point in the dictionary; the raw
%% initial_call of every OTP process is the same three-arity stub.
who(Get) ->
    case Get(registered_name, []) of
        [] ->
            Dict = Get(dictionary, []),
            case lists:keyfind('$initial_call', 1, Dict) of
                {_, Call} -> Call;
                false -> Get(initial_call, undefined)
            end;
        Name ->
            Name
    end.
