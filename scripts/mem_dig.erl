%% Names the term behind a heavy process heap, by walking the process state.
%%
%% Diagnostic tooling. The module is injected into the target node for the
%% duration of one census so the walk happens where the term lives; nothing
%% large crosses distribution. See docs/design-notes/daemon-memory.md.
-module(mem_dig).
-export([main/1, report/1]).

main([NodeStr]) ->
    Node = list_to_atom(NodeStr),
    pong = net_adm:ping(Node),
    {module, _} = code:ensure_loaded(mem_dig),
    {_, Bin, File} = code:get_object_code(mem_dig),
    {module, _} = rpc:call(Node, code, load_binary, [mem_dig, File, Bin]),
    io:format("~s", [rpc:call(Node, mem_dig, report, [8], 300000)]),
    erlang:halt(0, [{flush, true}]).

report(Top) ->
    Rows = [{element(2, erlang:process_info(P, memory)), P}
            || P <- erlang:processes(), erlang:process_info(P, memory) =/= undefined],
    Heavy = lists:sublist(lists:reverse(lists:sort(Rows)), Top),
    lists:flatten([one(P, M) || {M, P} <- Heavy]).

one(Pid, Memory) ->
    Head = io_lib:format("~n--- ~p  ~.3f MiB~n", [Pid, Memory / 1048576]),
    case catch sys:get_state(Pid, 5000) of
        {'EXIT', Why} ->
            [Head, io_lib:format("    state unavailable: ~p~n", [Why])];
        State ->
            Bins = lists:reverse(lists:sort(binaries(State, []))),
            Total = lists:sum([S || {S, _} <- Bins]),
            [Head,
             io_lib:format("    state flat_size ~.3f MiB (what one copy costs),"
                           " ~p large binaries totalling ~.3f MiB~n",
                           [erts_debug:flat_size(State) * 8 / 1048576,
                            length(Bins), Total / 1048576]),
             [io_lib:format("      ~10.3f MiB  ~p...~n", [S / 1048576, P])
              || {S, P} <- lists:sublist(Bins, 6)],
             descend(State, 0)]
    end.

%% The heaviest child at each level, down to the leaf. A term copied per
%% process is named by the path that leads to its bulk, not by its root.
descend(_Term, Depth) when Depth > 14 ->
    [];
descend(Term, Depth) ->
    Line = io_lib:format("      ~s~s  ~.3f MiB~n",
                         [lists:duplicate(Depth, $ ), shape(Term),
                          erts_debug:flat_size(Term) * 8 / 1048576]),
    case children(Term) of
        [] ->
            [Line, io_lib:format("      ~s= ~P~n",
                                 [lists:duplicate(Depth, $ ), Term, 8])];
        Kids ->
            Biggest = hd(lists:reverse(lists:keysort(1,
                          [{erts_debug:flat_size(K), K} || K <- Kids]))),
            [Line, descend(element(2, Biggest), Depth + 1)]
    end.

children(T) when is_tuple(T) -> tuple_to_list(T);
children(L) when is_list(L) -> L;
children(M) when is_map(M) -> maps:to_list(M);
children(F) when is_function(F) ->
    case erlang:fun_info(F, env) of
        {env, Env} -> Env;
        _ -> []
    end;
children(_) -> [].

shape(T) when is_tuple(T), tuple_size(T) > 0, is_atom(element(1, T)) ->
    io_lib:format("tuple/~p ~p", [tuple_size(T), element(1, T)]);
shape(T) when is_tuple(T) -> io_lib:format("tuple/~p", [tuple_size(T)]);
shape(L) when is_list(L) -> io_lib:format("list/~p", [length(L)]);
shape(M) when is_map(M) -> io_lib:format("map/~p ~p", [map_size(M), lists:sublist(maps:keys(M), 6)]);
shape(F) when is_function(F) -> io_lib:format("fun ~p", [erlang:fun_info(F, module)]);
shape(B) when is_binary(B) -> io_lib:format("binary/~p", [byte_size(B)]);
shape(A) when is_atom(A) -> io_lib:format("atom ~p", [A]);
shape(_) -> "leaf".

%% Every sizeable binary in the term, largest first, with a readable prefix so
%% the payload can be recognised rather than guessed at.
binaries(B, Acc) when is_binary(B) ->
    case byte_size(B) >= 65536 of
        true -> [{byte_size(B), binary:part(B, 0, min(120, byte_size(B)))} | Acc];
        false -> Acc
    end;
binaries([H | T], Acc) -> binaries(T, binaries(H, Acc));
binaries(T, Acc) when is_tuple(T) -> binaries(tuple_to_list(T), Acc);
binaries(M, Acc) when is_map(M) -> binaries(maps:to_list(M), Acc);
binaries(F, Acc) when is_function(F) ->
    case erlang:fun_info(F, env) of
        {env, Env} -> binaries(Env, Acc);
        _ -> Acc
    end;
binaries(_, Acc) -> Acc.
