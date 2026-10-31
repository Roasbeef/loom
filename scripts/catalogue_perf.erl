%% Matched catalogue fixtures, with untraced timing and separate query/allocation
%% counters. Every database and GC target belongs to this disposable benchmark.
-module(catalogue_perf).
-export([main/1, source_walk/4, validate_names/3]).

main([Baseline]) ->
    try
        load_baseline(Baseline),
        io:format("VM otp=~s word_bytes=~p schedulers=~p baseline=~s~n",
            [erlang:system_info(otp_release),erlang:system_info(wordsize),
             erlang:system_info(schedulers_online),string:trim(read_revision(Baseline))]),
        lists:foreach(fun({Count,N}) -> source_case(Count,N) end,
                      [{0,40},{1,40},{25,20},{100,8},{250,3},{511,2}]),
        lists:foreach(fun({Name,Names,N}) -> validator_case(Name,Names,N) end,
            [{short,[<<"deepseek">>,<<"glm-5_3">>,<<"a">>],20000},
             {maximum,[binary:copy(<<"a1_-">>,8)],10000},
             {invalid,[<<>>,<<"9lives">>,<<"A">>,<<"caf",195,169>>,
                       binary:copy(<<"a">>,33)],10000}]),
        halt(0)
    catch C:R:S -> io:format("FAILED ~p:~p ~p~n",[C,R,S]),halt(1) end.

read_revision(Directory) ->
    {ok,B}=file:read_file(filename:join(Directory,"revision")),binary_to_list(B).

load_baseline(Directory) ->
    Names = #{'storage@catalogue'=>catalogue_perf_baseline,
              'storage@domain'=>catalogue_perf_domain_baseline,
              'storage@sql'=>catalogue_perf_sql_baseline},
    lists:foreach(fun(M) ->
        Path=filename:join(Directory,atom_to_list(M)++".beam"),
        {ok,{M,[{abstract_code,{raw_abstract_v1,Forms}}]}}=beam_lib:chunks(Path,[abstract_code]),
        Target=maps:get(M,Names),
        {ok,Target,Bin}=compile:forms(rename(Forms,Names),[binary]),
        {module,Target}=code:load_binary(Target,Path,Bin)
    end,['storage@sql','storage@catalogue','storage@domain']),
    {module,'storage@domain'}=code:ensure_loaded('storage@domain').

rename(T,Names) when is_tuple(T) -> list_to_tuple([rename(X,Names)||X<-tuple_to_list(T)]);
rename(L,Names) when is_list(L) -> [rename(X,Names)||X<-L];
rename(A,Names) when is_atom(A) -> maps:get(A,Names,A);
rename(X,_) -> X.

source_case(Count,N) ->
    {ok,Store}='storage@catalogue':open(<<":memory:">>),
    DomainId = <<"workspace:/catalogue-perf">>,
    Domain={domain,DomainId,workspace_private,<<"/catalogue-perf">>,<<>>,
            <<"/catalogue-perf/memory.db">>,<<"/catalogue-perf/search.db">>},
    %% An empty domain still exists, just as a shared domain after isolation.
    {ok,Anchor}='storage@catalogue':reserve(Store,registration(Count+1000)),
    {ok,Domain}='storage@domain':bind(Store,element(2,Anchor),Domain),
    Expected=lists:sort([begin
        Record=registration(I),
        {ok,Record}='storage@domain':reserve_session(Store,Record,Domain),
        {ok,_}='storage@catalogue':confirm(Store,element(2,Record)),
        {element(2,Record),element(3,Record)}
    end||I<-lists:seq(1,Count)]),
    lists:foreach(fun(Round) ->
        Modes=case Round rem 2 of 1->[baseline,candidate];0->[candidate,baseline] end,
        Measured=lists:map(fun(Mode) ->
            {C,D}=modules(Mode),
            Run=fun() -> Expected=source_walk(C,D,Store,DomainId) end,
            Run(),
            Timing=timing(N,Run),
            Queries=query_count(Run),
            Words=allocation(source_walk,4,fun()->repeat(N,Run) end),
            Pages=Count div 100+1,
            ExpectedQueries=case erlang:function_exported(D,source_records,3) of
                true->Pages*2;false->Pages*2+Count*6 end,
            ExpectedQueries=Queries,
            io:format("SOURCE mode=~p round=~p sources=~p n=~p queries=~p ~s words=~p bytes=~p~n",
                [Mode,Round,Count,N,Queries,Timing,Words,Words*8]),
            {Mode,Words}
        end,Modes),
        require_improvement(Count,Measured)
    end,lists:seq(1,5)),
    {ok,nil}='storage@catalogue':close(Store).

registration(I) ->
    {Session,_}='core@ids':mint_session('core@ids':generator('core@clock':fixed(1000),I)),
    Id='core@ids':session_id_to_string(Session),
    {registration,Id,<<"/catalogue-perf/",Id/binary,".db">>,<<"/catalogue-perf">>,
     <<"Source">>,<<>>,{some,<<"profile-1">>},none,<<>>,<<>>,1,Id,reserved,none}.

modules(baseline) -> {catalogue_perf_baseline,catalogue_perf_domain_baseline};
modules(candidate) -> {'storage@catalogue','storage@domain'}.

%% The baseline executes the original two-stage registry read: validated source
%% IDs, then a second registration lookup for each path. The candidate's one
%% bounded source page supplies those validated paths directly. Mailbox transit
%% is intentionally excluded; real registry tests exercise that integration.
source_walk(C,D,Store,DomainId) -> source_walk(C,D,Store,DomainId,<<>>,[]).
source_walk(C,D,Store,DomainId,After,Acc) ->
    Records=case erlang:function_exported(D,source_records,3) of
        true->{ok,Found}=D:source_records(Store,DomainId,After),Found;
        false->{ok,Ids}=D:sources(Store,DomainId,After),
               [begin {ok,R}=C:get(Store,Id),R end||Id<-Ids]
    end,
    Rows=[{element(2,R),element(3,R)}||R<-Records],
    case length(Rows) of
        100 -> source_walk(C,D,Store,DomainId,element(1,lists:last(Rows)),Acc++Rows);
        _ -> Acc++Rows
    end.

validator_case(Name,Names,N) ->
    Expected=[catalogue_perf_baseline:is_profile_name(B)||B<-Names],
    lists:foreach(fun(Round) ->
        Modes=case Round rem 2 of 1->[baseline,candidate];0->[candidate,baseline] end,
        Measured=lists:map(fun(Mode) ->
            {M,_}=modules(Mode),
            Expected=[M:is_profile_name(B)||B<-Names],
            Run=fun()->validate_names(M,Names,N) end,
            Run(),Timing=timing(1,Run),
            Words=allocation(validate_names,3,Run),
            io:format("VALIDATOR case=~p mode=~p round=~p n=~p names=~p ~s words=~p bytes=~p~n",
                [Name,Mode,Round,N,length(Names),Timing,Words,Words*8]),
            {Mode,Words}
        end,Modes),
        require_improvement(1,Measured)
    end,lists:seq(1,5)).

validate_names(_,_,0) -> ok;
validate_names(M,Names,N) ->
    [M:is_profile_name(B)||B<-Names],validate_names(M,Names,N-1).

%% Runtime CPU includes the fixture's SQLite worker; reductions here belong to
%% the caller alone. Wall time has no tracing enabled. The VM has one scheduler.
timing(N,Run) ->
    erlang:garbage_collect(),
    {reductions,R0}=process_info(self(),reductions),
    {memory,MemoryBefore}=process_info(self(),memory),
    {Cpu0,_}=erlang:statistics(runtime),
    {Us,_}=timer:tc(fun()->repeat(N,Run) end),
    {Cpu1,_}=erlang:statistics(runtime),
    {reductions,R1}=process_info(self(),reductions),
    {memory,MemoryAfter}=process_info(self(),memory),
    lists:flatten(io_lib:format("us=~p cpu_ms=~p reductions=~p heap_before_bytes=~p heap_after_bytes=~p",[Us,Cpu1-Cpu0,R1-R0,MemoryBefore,MemoryAfter])).

query_count(Run) ->
    MFA={sqlight,query,4},
    erlang:trace_pattern(MFA,true,[call_count]),
    try Run(),{call_count,N}=erlang:trace_info(MFA,call_count),N
    after erlang:trace_pattern(MFA,false,[call_count]) end.

%% One traced root includes its untraced descendants without summing overlapping
%% per-function totals. The tracing VM and fixtures are never the live daemon.
allocation(F,A,Run) ->
    {ok,P}=tprof:start(#{type=>call_memory,session=>catalogue_perf}),
    try
        tprof:set_pattern(P,?MODULE,F,A),
        tprof:enable_trace(P,self(),#{set_on_spawn=>false}),
        Run(),tprof:pause(P),
        #{all:={_,Words,_}}=tprof:inspect(tprof:collect(P),total,{measurement,descending}),Words
    after tprof:stop(P) end.

repeat(0,_) -> ok;
repeat(N,F) -> F(),repeat(N-1,F).

%% Allocation and query bounds gate the benchmark; elapsed time remains a
%% reported measurement because scheduler contention is outside this fixture.
require_improvement(Count,Measured) ->
    case {os:getenv("CATALOGUE_PERF_EXPECT_IMPROVED"),Count} of
        {"yes",N} when N>0 ->
            Baseline=proplists:get_value(baseline,Measured),
            Candidate=proplists:get_value(candidate,Measured),
            true=Candidate*2<Baseline;
        _ -> ok
    end.
