%% Compare complete pure projections and provider request construction with exact
%% saved baseline BEAMs in one disposable VM. Allocation is measured separately
%% from untraced timing and CPU; none of these numbers measures live daemon RSS.
-module(request_preparation_perf).
-export([main/1]).

main([Baseline]) ->
    try
        load_baseline(filename:join(Baseline,"provider@image_budget.beam"),image_budget_baseline),
        load_baseline(filename:join(Baseline,"harness@provider.beam"),request_baseline),
        io:format("VM otp=~s word_bytes=~p schedulers=~p~n",[erlang:system_info(otp_release),erlang:system_info(wordsize),erlang:system_info(schedulers_online)]),
        lists:foreach(fun(Count)->
            lists:foreach(fun(Reading)->request_trials(Count,Reading) end,[text_only,reads_images]),
            budget_trials(Count)
        end,[8,128,1024]),
        halt(0)
    catch C:R:S -> io:format("FAILED ~p:~p ~p~n",[C,R,S]),halt(1) end.

load_baseline(Path,Name) ->
    {ok,{_,[{abstract_code,{raw_abstract_v1,Forms}}]}}=beam_lib:chunks(Path,[abstract_code]),
    Renamed=[case F of {attribute,L,module,_}->{attribute,L,module,Name}; X->X end || F<-Forms],
    {ok,Name,Bin}=compile:forms(Renamed,[binary]),
    {module,Name}=code:load_binary(Name,"baseline",Bin).

request_trials(Count,Reading) ->
    {Provider,Spec,Retire}='harness@provider_test':request_fixture(Count,Reading),
    try
        lists:foreach(fun({Kind,Messages})->
            ActualSpec=setelement(7,Spec,Messages),
            Expected=request_baseline:request(Provider,ActualSpec),
            Expected='harness@provider':request(Provider,ActualSpec),
            Label=atom_to_list(Reading)++"/"++Kind,
            matched(Label,Count,2,[{request_baseline,request},{'harness@provider',request}],
                fun(M)->fun()->M:request(Provider,ActualSpec) end end)
        end,[{"text",element(7,Spec)},{"one-image",element(7,Spec)++[image()]}])
    after nil=Retire() end.

budget_trials(Count) ->
    Messages=lists:duplicate(Count,{user_message,[{user_text,<<"ordinary text">>,none}],1,{some,{origin,<<"fixture">>,<<"Fixture">>}}}),
    lists:foreach(fun({Label,Context,Limit,Protected})->
        Expected=image_budget_baseline:project(Context,Limit,Protected),
        Expected='provider@image_budget':project(Context,Limit,Protected),
        matched(Label,Count,3,[{image_budget_baseline,project},{'provider@image_budget',project}],
            fun(M)->fun()->M:project(Context,Limit,Protected) end end)
    end,[{"budget/text",Messages,8,0},
         {"budget/within",Messages++[image()],8,100},
         {"budget/refused",Messages++lists:duplicate(9,image()),8,9},
         {"budget/trimmed",lists:duplicate(9,image())++Messages,8,0},
         {"budget/invalid",Messages,0,0}]).

image() -> {user_message,[{user_image,<<"cGljdHVyZQ==">>,<<"image/png">>}],1,{some,{origin,<<"fixture">>,<<"Fixture">>}}}.

matched(Label,Count,Arity,Modules,Build) ->
    lists:foreach(fun(Round)->
        Ordered=case Round rem 2 of 1->Modules; 0->lists:reverse(Modules) end,
        lists:foreach(fun({Module,Function})->trial(Label,Count,Round,Module,Function,Arity,Build(Module)) end,Ordered)
    end,lists:seq(1,4)).

trial(Label,Count,Round,Module,Function,Arity,Run) ->
    N=2000,
    repeat(100,Run),
    {reductions,R0}=process_info(self(),reductions),
    {Cpu0,_}=statistics(runtime),
    {Us,_}=timer:tc(fun()->repeat(N,Run) end),
    {Cpu1,_}=statistics(runtime),
    {reductions,R1}=process_info(self(),reductions),
    {ok,P}=tprof:start(#{type=>call_memory,session=>request_preparation_perf}),
    Words=try
        tprof:set_pattern(P,Module,Function,Arity),
        tprof:enable_trace(P,self(),#{set_on_spawn=>false}),
        repeat(N,Run),tprof:pause(P),
        #{all:={_,W,_}}=tprof:inspect(tprof:collect(P),total,{measurement,descending}),W
    after tprof:stop(P) end,
    io:format("RESULT name=~s messages=~p round=~p module=~s calls=~p us=~p cpu_ms=~p reductions=~p allocated_words=~p allocated_bytes=~p~n",[Label,Count,Round,Module,N,Us,Cpu1-Cpu0,R1-R0,Words,Words*erlang:system_info(wordsize)]).

repeat(0,_) -> ok;
repeat(N,Run) -> Run(),repeat(N-1,Run).
