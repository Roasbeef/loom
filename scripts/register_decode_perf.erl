%% Matched real SQLite actors. Timing is untraced; root-only call_memory
%% measures heap allocation separately. GC and state reads target fixtures only.
-module(register_decode_perf).
-export([main/1]).

main([Baseline]) ->
    try run(Baseline), halt(0)
    catch C:R:S -> io:format("FAILED ~p:~p ~p~n", [C,R,S]), halt(1) end.

run(Baseline) ->
    {ok,{_,[{abstract_code,{raw_abstract_v1,Forms}}]}} = beam_lib:chunks(Baseline,[abstract_code]),
    Renamed = [case F of {attribute,L,module,_} -> {attribute,L,module,register_decode_baseline}; X -> X end || F <- Forms],
    {ok,register_decode_baseline,Bin} = compile:forms(Renamed,[binary]),
    {module,register_decode_baseline} = code:load_binary(register_decode_baseline,"baseline",Bin),
    io:format("VM otp=~s word_bytes=~p schedulers=~p~n",[erlang:system_info(otp_release),erlang:system_info(wordsize),erlang:system_info(schedulers_online)]),
    bound_mutations(),
    lists:foreach(fun({Name,Rows,Value,N}) ->
        Bytes = byte_size('core@json':to_string(Value)),
        lists:foreach(fun(Mode) ->
            lists:foreach(fun(Round) ->
                Mods = case Round rem 2 of 1 -> [register_decode_baseline,'storage@sqlite']; 0 -> ['storage@sqlite',register_decode_baseline] end,
                lists:foreach(fun(M) -> trial(Name,Rows,Value,N,Bytes,Mode,Round,M) end,Mods)
            end,lists:seq(1,4))
        end,[point,list])
    end,[{"scalar",8,{int,1},1000},
         {"structured4k",8,document(32),200},
         {"structured16k",8,document(128),80},
         {"dense",4,{array,lists:duplicate(8192,null)},40},
         {"entry_overflow",80,document(1),80},
         {"byte_overflow",8,document(512),16},
         {"oversized",1,{string,binary:copy(<<"x">>,300000)},8}]).

document(N) -> {array,[{object,[{<<"index">>,{int,I}},
    {<<"text">>,{string,binary:copy(<<"text \" and newline\n ",240,159,152,128>>,4)}}]} || I <- lists:seq(1,N)]}.

trial(Name,Rows,Value,N,_Bytes,Mode,Round,M) ->
    Path = list_to_binary("build/register-perf-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".db"),
    {ok,Store} = M:open(M:config(Path,<<"fixture">>),'core@clock':fixed(1000)),
    Keys = [integer_to_binary(I) || I <- lists:seq(1,Rows)],
    Values = [case Value of {int,1} -> {int,I}; _ ->
        {object,[{<<"slot">>,{int,I}},{<<"payload">>,Value}]} end || I <- lists:seq(1,Rows)],
    Bytes = lists:max([byte_size('core@json':to_string(V)) || V <- Values]),
    Writes = [{set_register,fact_custom,K,{register_value,V}} || {K,V} <- lists:zip(Keys,Values)],
    {ok,_} = 'storage@storage':commit(Store,{tx,Writes,[]}),
    {ok,Pid} = 'gleam@erlang@process':subject_owner(element(2,Store)),
    Run = fun(I) -> case Mode of
        point -> Index = (I rem Rows)+1, Expected = lists:nth(Index,Values),
                 {ok,{some,{register,{register_value,Expected},_}}} = 'storage@storage':get_register(Store,fact_custom,lists:nth(Index,Keys));
        list -> {ok,Found} = 'storage@storage':list_registers(Store,fact_custom,none),
                Rows = length(Found), true = lists:all(fun({K,{register,{register_value,V},_}}) -> V =:= proplists:get_value(K,lists:zip(Keys,Values)) end,Found)
    end end,
    ColdN = case Mode of point -> Rows; list -> 1 end,
    {ColdR0,_} = erlang:statistics(reductions),
    {ColdUs,_} = timer:tc(fun() -> repeat(ColdN,Run) end),
    {ColdR1,_} = erlang:statistics(reductions),
    io:format("COLD name=~s module=~s mode=~s round=~p n=~p us=~p vm_reductions=~p~n",[Name,M,Mode,Round,ColdN,ColdUs,ColdR1-ColdR0]),
    repeat(Rows*2,Run),
    {reductions,R0} = process_info(Pid,reductions),
    {Us,_} = timer:tc(fun() -> repeat(N,Run) end),
    {reductions,R1} = process_info(Pid,reductions),
    CpuN = case N >= 40 of true -> max(N,500); false -> N end,
    {Cpu0,_} = erlang:statistics(runtime),
    repeat(CpuN,Run),
    {Cpu1,_} = erlang:statistics(runtime),
    {ok,P} = tprof:start(#{type=>call_memory,session=>register_decode_perf}),
    Words = try
        tprof:set_pattern(P,M,handle_open,2),
        tprof:enable_trace(P,Pid,#{set_on_spawn=>false}),
        repeat(N,Run), tprof:pause(P),
        #{all:={_,W,_}} = tprof:inspect(tprof:collect(P),total,{measurement,descending}), W
    after tprof:stop(P) end,
    erlang:trace_pattern({'core@json',parse,1},true,[call_count]),
    repeat(N,Run),
    {call_count,ParseCalls} = erlang:trace_info({'core@json',parse,1},call_count),
    erlang:trace_pattern({'core@json',parse,1},false,[call_count]),
    %% The isolated actor is quiescent here; GC is never directed at live Loom.
    erlang:garbage_collect(Pid),
    {memory,Mem} = process_info(Pid,memory),
    StateWords = erts_debug:flat_size(sys:get_state(Pid)),
    {ok,nil} = 'storage@storage':close(Store),
    erlang:garbage_collect(Pid),
    {memory,ClosedMem} = process_info(Pid,memory),
    ClosedWords = erts_debug:flat_size(sys:get_state(Pid)),
    {ok,nil} = M:retire_closed(element(2,Store)),
    io:format("RESULT name=~s module=~s mode=~s round=~p rows=~p payload_bytes=~p n=~p us=~p vm_cpu_ms=~p cpu_n=~p reductions=~p heap_words=~p parse_calls=~p actor_bytes=~p state_flat_words=~p closed_actor_bytes=~p closed_state_flat_words=~p~n",
        [Name,M,Mode,Round,Rows,Bytes,N,Us,Cpu1-Cpu0,CpuN,R1-R0,Words,ParseCalls,Mem,StateWords,ClosedMem,ClosedWords]),
    [file:delete(<<Path/binary,S/binary>>) || S <- [<<>>,<<"-wal">>,<<"-shm">>]], ok.

repeat(0,_) -> ok;
repeat(N,F) -> F(N), repeat(N-1,F).

%% Mutants are loaded only in this disposable benchmark VM, not the daemon.
bound_mutations() ->
    {ok,{_,[{abstract_code,{raw_abstract_v1,Forms}}]}} = beam_lib:chunks(code:which('storage@internal@register_cache'),[abstract_code]),
    lists:foreach(fun({Name,Constant}) ->
        Mut = mutate(Forms,Name,Constant),
        {ok,Name,Bin} = compile:forms(Mut,[binary]),
        {module,Name} = code:load_binary(Name,"bound-mutant",Bin),
        1 = inventory_count('storage@internal@register_cache',Constant),
        true = inventory_count(Name,Constant) > 1
    end,[{register_count_mutant,64},{register_bytes_mutant,262144}]),
    io:format("BOUND_MUTATIONS rejected=2~n").

mutate({attribute,L,module,_},Name,_) -> {attribute,L,module,Name};
mutate({integer,L,N},_,N) -> {integer,L,1000000000};
mutate(T,Name,N) when is_tuple(T) -> list_to_tuple([mutate(X,Name,N) || X <- tuple_to_list(T)]);
mutate(L,Name,N) when is_list(L) -> [mutate(X,Name,N) || X <- L];
mutate(X,_,_) -> X.

inventory_count(M,Limit) ->
    Blobs = case Limit of
        64 -> [integer_to_binary(I) || I <- lists:seq(1,65)];
        262144 -> ['core@json':to_string({string,binary:copy(<<C>>,140000)}) || C <- [$a,$b]]
    end,
    Final = lists:foldl(fun(B,Cache) -> {ok,{_,Next}}=M:read(Cache,B), Next end,M:new(),Blobs),
    map_size(element(2,Final)).
