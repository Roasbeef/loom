%% Replay compiled baseline and candidate paths in one non-distributed VM.
%% Time untraced runs and measure cumulative heap words separately.
-module(bounded_read_replay).
-export([main/0, invoke/3]).

invoke(Module, Function, Args) -> apply(Module, Function, Args).

main() ->
    try
        nonode@nohost = node(),
        Baseline = os:getenv("REPLAY_BASELINE"),
        Snapshot = 'storage@snapshot',
        Sqlite = 'storage@internal@snapshot_sqlite',
        Feed = 'client@attention_feed',
        Gateway = 'client@gateway',
        Aliases = #{Snapshot => baseline_snapshot, Sqlite => baseline_sqlite,
                    Feed => baseline_feed},
        [load(rewrite(forms(beam(Baseline, M)), Aliases), maps:get(M, Aliases))
         || M <- [Snapshot, Sqlite, Feed]],
        load_missing(forms(beam(Baseline, Gateway)), baseline_missing),
        load_missing(forms(code:which(Gateway)), candidate_missing),

        lists:foreach(fun snapshot/1, [0, 1, 16, 64, 256, 257, 1024]),
        %% The 40-item stress fixtures cover optional fields and JSON escapes.
        Rows = [row(A,S,F,Text) || A <- [0,1,8,40], S <- [0,1,8,40],
                 F <- [0,1,8,40], Text <- [<<>>, <<"hello">>, text(), binary:copy(text(),16)]],
        [begin Expected = baseline_feed:shed(Row), Expected = Feed:shed(Row) end || Row <- Rows],
        io:format("INBOX_EXACT rows=~p~n", [length(Rows)]),
        measure(inbox_small, baseline_feed, Feed, shed, [row(1,1,1,<<"hi">>)], 500),
        measure(inbox_full, baseline_feed, Feed, shed, [row(40,40,40,text())], 24),
        measure(inbox_mixed, baseline_feed, Feed, shed, [row(32,30,40,text())], 24),
        measure(inbox_one_section, baseline_feed, Feed, shed, [row(0,0,40,text())], 80),

        Ids = [<<"host/", (integer_to_binary(I))/binary>> || I <- lists:seq(1,8)],
        Cells = [cell(<<"remote-escalation/host/", (integer_to_binary(I))/binary>>)
                 || I <- lists:seq(1,16)],
        Cases = [[], lists:sublist(Cells,1), Cells, lists:reverse(Cells),
                 [cell(<<"escalation/host/3">>),cell(<<"escalation/local">>)]],
        [begin Args = [{escalations, [<<"local">>, <<"lost">>|Ids]}, cut(Cs)],
            Expected = baseline_missing:missing(hd(Args),lists:last(Args)),
            Expected = candidate_missing:missing(hd(Args),lists:last(Args))
         end || Cs <- Cases],
        measure(escalations_mixed, baseline_missing, candidate_missing, missing,
            [{escalations, Ids}, cut(lists:sublist(Cells,4))], 1000),
        measure(escalations_missing, baseline_missing, candidate_missing, missing,
            [{escalations, Ids}, cut(lists:nthtail(8,Cells))], 1000),
        halt(0)
    catch C:R:S ->
        io:format(standard_error, "~p:~p ~p~n", [C,R,S]),
        halt(1)
    end.

beam(Path, Module) -> filename:join(Path, atom_to_list(Module) ++ ".beam").
forms(Path) ->
    {ok,{_,[{abstract_code,{raw_abstract_v1,Forms}}]}} = beam_lib:chunks(Path,[abstract_code]),
    Forms.

load(Forms, Module) ->
    {ok,Module,Binary} = compile:forms(Forms,[binary]),
    {module,Module} = code:load_binary(Module,"replay",Binary).

rewrite({attribute,L,module,M}, A) -> {attribute,L,module,maps:get(M,A,M)};
rewrite({atom,L,M}, A) -> {atom,L,maps:get(M,A,M)};
rewrite(T,A) when is_tuple(T) -> list_to_tuple([rewrite(X,A) || X <- tuple_to_list(T)]);
rewrite(L,A) when is_list(L) -> [rewrite(X,A) || X <- L];
rewrite(X,_) -> X.

%% Compile only the missing-ID expression from the real gateway on each side.
%% The two free variables are the transfer window and the already-admitted cut.
load_missing(Forms, Module) ->
    [Capture] = [F || F={function,_,captured_transfer,6,_} <- Forms],
    [Expression] = missing_expression(Capture),
    load([{attribute,1,module,Module},{attribute,1,export,[{missing,2}]},
          {function,1,missing,2,[{clause,1,[{var,1,'Window'},{var,1,'Cut@1'}],
            [],[Expression]}]}], Module).

missing_expression({tuple,_,[{bin,_,[{bin_element,_,{string,_,"missing"},_,_}]},Value]}) ->
    [Value];
missing_expression(T) when is_tuple(T) -> missing_expression(tuple_to_list(T));
missing_expression([H|T]) -> missing_expression(H) ++ missing_expression(T);
missing_expression(_) -> [].

text() -> <<"head with \"quote\" and backslash \\ plus a line\n", 240,159,152,128>>.
row(A,S,F,T) ->
    {row,{some,3},
     {section,100,[{ask_item,integer_to_binary(I),<<"sub">>,I,T,2} || I <- lists:seq(A,1,-1)]},
     {section,140,[{find_item,integer_to_binary(I),<<"sub">>,risk,I,T,
                   {some,{<<"path">>,{some,9}}}} || I <- lists:seq(F,1,-1)]},
     {section,80,[{stuck,<<"sub">>,{some,I},T,none,{some,<<"parent">>},
                   integer_to_binary(I)} || I <- lists:seq(S,1,-1)]}}.
cell(Key) -> {cell,fact_custom,Key,{register,{register_value,null},1}}.
cut(Cells) -> {cut,1,nil,Cells,0,[]}.

snapshot(Count) ->
    Dir = os:getenv("REPLAY_FIXTURES"),
    Path = list_to_binary(filename:join(Dir, integer_to_list(Count) ++ ".db")),
    {ok,Store} = 'storage@sqlite':open('storage@sqlite':config(Path,<<"replay">>),
        'core@clock':fixed(1000)),
    Writes = [{set_register,fact_custom,<<"cell/",(integer_to_binary(I))/binary>>,
        {register_value,{object,[{<<"slot">>,{int,I}},
                                 {<<"text">>,{string,text()}}]}}}
        || I <- lists:seq(1,Count)],
    {ok,_} = 'storage@storage':commit(Store,{tx,Writes,[]}),
    {ok,nil} = 'storage@storage':close(Store),
    {ok,nil} = 'storage@sqlite':retire_closed(element(2,Store)),
    {ok,Conn} = sqlight:open(Path),
    Plan = {plan,[{selection,fact_custom,<<"cell/">>,all}],[],0},
    Args = [Conn,Plan],
    {ok,{cut,_,_,Cells,_,_}} = Expect = baseline_sqlite:capture(Conn,Plan),
    Count = length(Cells),
    Expect = 'storage@internal@snapshot_sqlite':capture(Conn,Plan),
    BaseQueries = queries(baseline_sqlite, Args),
    NewQueries = queries('storage@internal@snapshot_sqlite', Args),
    io:format("SQLITE rows=~p queries_before=~p queries_after=~p~n",
        [Count, BaseQueries, NewQueries]),
    true = NewQueries =< BaseQueries,
    true = Count < 64 orelse NewQueries * 10 =< BaseQueries,
    measure(Count, baseline_sqlite, 'storage@internal@snapshot_sqlite', capture, Args,
        max(15, 1200 div max(1,Count))),
    exact_refusals(Count, Conn, Plan, Cells),
    _ = sqlight:close(Conn).

exact_refusals(16, Conn, Plan, [First,Second|_]) ->
    %% Use the returned header order rather than assuming the dictionary order.
    %% These keys come from the local fixture, not from external input.
    {cell,_,Key1,_} = First,
    {cell,_,Key2,_} = Second,
    Update = fun(Key, SqlValue) ->
        {ok,_} = sqlight:exec(<<"UPDATE registers SET value=",SqlValue/binary,
           " WHERE key='",Key/binary,"'">>, Conn)
    end,
    Check = fun() ->
        {error,_} = Expected = baseline_sqlite:capture(Conn,Plan),
        Expected = 'storage@internal@snapshot_sqlite':capture(Conn,Plan),
        Expected
    end,
    Update(Key2, <<"'null'">>),
    {ok,_} = TextCut = baseline_sqlite:capture(Conn,Plan),
    TextCut = 'storage@internal@snapshot_sqlite':capture(Conn,Plan),
    Update(Key2, <<"7">>),
    {error,{storage_failure,{backend_fault,_}}} = Check(),
    Update(Key1, <<"x'ff'">>),
    {error,{storage_failure,{corrupt_row,_}}} = Check(),
    Update(Key1, <<"CAST(x'00' AS TEXT) || CAST(zeroblob(1048576) AS TEXT)">>),
    {error,{storage_failure,{corrupt_row,_}}} = Check(),
    io:format("SQLITE_EXACT stored_text,storage_type,earlier_corruption,nul_text~n");
exact_refusals(_,_,_,_) -> ok.

queries(Module, Args) ->
    MFA = {sqlight,query,4},
    erlang:trace_pattern(MFA, true,[call_count]),
    try
        {ok,_} = invoke(Module,capture,Args),
        {call_count,N} = erlang:trace_info(MFA,call_count),
        N
    after erlang:trace_pattern(MFA,false,[call_count]) end.

measure(Name, Base, Candidate, Function, Args, N) ->
    Expected = invoke(Base,Function,Args),
    Expected = invoke(Candidate,Function,Args),
    Samples = [begin
        Order = case I rem 2 of 0 -> [Candidate,Base]; 1 -> [Base,Candidate] end,
        maps:from_list([{M, timed(M,Function,Args,N)} || M <- Order])
    end || I <- lists:seq(1,6)],
    B = median([maps:get(Base,S) || S <- Samples]) / N,
    C = median([maps:get(Candidate,S) || S <- Samples]) / N,
    BW = allocated(Base,Function,Args,N) / N,
    CW = allocated(Candidate,Function,Args,N) / N,
    io:format("RESULT ~p us=~.3f->~.3f speedup=~.2f heap_words=~.3f->~.3f reduction=~.2f~n",
        [Name,B,C,B/C,BW,CW,BW/CW]).

timed(M,F,Args,N) ->
    repeat(3,M,F,Args),
    erlang:garbage_collect(),
    {Time,_} = timer:tc(fun() -> repeat(N,M,F,Args) end),
    Time.

allocated(M,F,Args,N) ->
    {ok,P} = tprof:start(#{type=>call_memory,session=>bounded_read_replay}),
    try
        tprof:set_pattern(P,?MODULE,invoke,3),
        tprof:enable_trace(P,self(),#{set_on_spawn=>false}),
        repeat(N,M,F,Args),
        tprof:pause(P),
        #{all:={_,Words,_}} = tprof:inspect(tprof:collect(P),total,{measurement,descending}),
        Words
    after tprof:stop(P) end.

median(X) ->
    Sorted = lists:sort(X),
    (lists:nth(3,Sorted) + lists:nth(4,Sorted)) / 2.
repeat(0,_,_,_) -> ok;
repeat(N,M,F,A) -> ?MODULE:invoke(M,F,A), repeat(N-1,M,F,A).
